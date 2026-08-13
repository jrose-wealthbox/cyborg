# frozen_string_literal: true

require "securerandom"
require "time"
require_relative "contracts"

module Cyborg
  module Analysis
    UsageTreeNode = Data.define(:record, :children)

    class UsageRecorder
      attr_reader :db, :now

      def initialize(db:, now: nil, clock: nil)
        @db = db
        source_now = now || (clock.respond_to?(:now) ? clock.now : Time.now.utc)
        @now = Contracts.canonical_time(source_now, "now")
      end

      def record(run_id:, task_id: nil, session_id: nil, parent_session_id: nil,
                 reservation: nil, reserved_cost_micros: nil, input_tokens: nil,
                 output_tokens: nil, cost_micros: nil, certainty: nil, id: nil, created_at: nil)
        reserved = reservation_cost(reservation, reserved_cost_micros)
        certainty ||= cost_micros.nil? ? "reserved" : "provider_reported"
        record_value = UsageRecord.new(
          id: id || SecureRandom.uuid, run_id:, task_id:, session_id:, parent_session_id:,
          reserved_cost_micros: reserved, input_tokens:, output_tokens:, cost_micros:,
          certainty:, created_at: created_at || now
        )
        db[:usage_records].insert(row_for(record_value))
        find(record_value.id)
      end

      alias record_usage record

      def update(session_id:, **attributes)
        row = db[:usage_records].where(session_id:).first
        raise ArgumentError, "usage session not found" unless row

        allowed = %i[reserved_cost_micros input_tokens output_tokens cost_micros certainty task_id parent_session_id]
        changes = attributes.select { |key, _value| allowed.include?(key.to_sym) }
        values = row.merge(changes.transform_keys(&:to_sym))
        validated = UsageRecord.new(**value_attributes(values))
        db[:usage_records].where(id: row.fetch(:id)).update(row_for(validated))
        find(row.fetch(:id))
      end

      def release(session_id:, amount_micros: nil)
        dataset = db[:usage_records].where(session_id:)
        rows = dataset.all
        rows.each do |row|
          current = row.fetch(:reserved_cost_micros).to_i
          amount = amount_micros.nil? ? current : [current, Contracts.strict_integer(amount_micros, "amount_micros")].min
          dataset.where(id: row.fetch(:id)).update(reserved_cost_micros: current - amount)
          amount_micros = [amount_micros - amount, 0].max unless amount_micros.nil?
          break if amount_micros == 0
        end
        rows.map { |row| find(row.fetch(:id)) }
      end

      alias release_reservation release

      def find(id)
        row = db[:usage_records].where(id:).first
        row && UsageRecord.new(**value_attributes(row))
      end

      def children(parent_session_id)
        db[:usage_records].where(parent_session_id:).order(:id).all.map { |row| UsageRecord.new(**value_attributes(row)) }
      end

      def hierarchy(run_id:)
        records = db[:usage_records].where(run_id:).order(:id).all.map { |row| UsageRecord.new(**value_attributes(row)) }
        by_parent = records.group_by(&:parent_session_id)
        records.select { |record| record.parent_session_id.nil? }.map do |record|
          build_tree(record, by_parent)
        end
      end

      def summary(run_id:)
        records = db[:usage_records].where(run_id:).order(:id).all.map { |row| UsageRecord.new(**value_attributes(row)) }
        reserved = records.sum(&:reserved_cost_micros)
        reported = records.select(&:reported?).sum { |record| record.cost_micros.to_i }
        certainty = certainty_for(records)
        warnings = certainty == "unknown" ? ["analysis.cost_uncertain"] : []
        UsageSummary.new(
          records:, reserved_cost_micros: reserved, reported_cost_micros: reported,
          certainty:, warnings:
        )
      end

      def outcome(claims: [], run_id:, backend_metadata: {})
        summary = summary(run_id:)
        AnalysisOutcome.new(
          claims:, usage: {
            "records" => summary.records.map { |record| usage_hash(record) },
            "reserved_cost_micros" => summary.reserved_cost_micros,
            "reported_cost_micros" => summary.reported_cost_micros,
            "certainty" => summary.certainty,
            "warnings" => summary.warnings
          }, backend_metadata:
        )
      end

      private

      def reservation_cost(reservation, explicit)
        return Contracts.strict_integer(explicit, "reserved_cost_micros") unless explicit.nil?
        return 0 if reservation.nil?

        value = reservation.respond_to?(:cost_micros) ? reservation.cost_micros : reservation.to_h.fetch(:cost_micros) { reservation.to_h.fetch("cost_micros") }
        Contracts.strict_integer(value, "reserved_cost_micros")
      end

      def row_for(record)
        {
          id: record.id, run_id: record.run_id, task_id: record.task_id, session_id: record.session_id,
          parent_session_id: record.parent_session_id, reserved_cost_micros: record.reserved_cost_micros,
          input_tokens: record.input_tokens, output_tokens: record.output_tokens, cost_micros: record.cost_micros,
          certainty: record.certainty, created_at: record.created_at.utc.iso8601
        }
      end

      def value_attributes(row)
        keys = %i[id run_id task_id session_id parent_session_id reserved_cost_micros input_tokens output_tokens cost_micros certainty created_at]
        keys.to_h { |key| [key, row[key]] }
      end

      def build_tree(record, by_parent)
        UsageTreeNode.new(record, by_parent.fetch(record.id, []).map { |child| build_tree(child, by_parent) }.freeze)
      end

      def certainty_for(records)
        return "unknown" if records.empty?
        return "unknown" if records.any? { |record| record.certainty == "unknown" || record.certainty == "reserved" }
        return "provider_reported" if records.all? { |record| record.certainty == "provider_reported" }
        return "locally_estimated" if records.all? { |record| record.certainty == "locally_estimated" }

        "unknown"
      end

      def usage_hash(record)
        record.members.each_with_object({}) do |member, result|
          value = record.public_send(member)
          result[member.to_s] = value.is_a?(Time) ? value.utc.iso8601 : value
        end
      end
    end
  end
end
