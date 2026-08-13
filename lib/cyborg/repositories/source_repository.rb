# frozen_string_literal: true

require_relative "base"
require "securerandom"

module Cyborg
  module Repositories
    class SourceRepository < Base
      def create_snapshot(attributes = nil, run: nil, registration: nil, result: nil, cursor_disposition: nil, **options)
        attrs = if attributes
          attributes.to_h
        elsif result
          result_attrs = result.to_h
          registration_attrs = registration.respond_to?(:to_h) ? registration.to_h : {}
          run_attrs = run.respond_to?(:to_h) ? run.to_h : {}
          {
            id: result_attrs[:id] || SecureRandom.uuid,
            run_id: run_attrs[:id] || run&.id,
            source_name: result_attrs[:source_name] || registration_attrs[:source_name] || registration&.source_name,
            account_identity: result_attrs[:account_identity] || registration_attrs[:account_identity] || registration&.account_identity,
            adapter_version: result_attrs[:adapter_version] || registration_attrs[:adapter_version] || registration&.adapter_version,
            started_at: result_attrs[:started_at], completed_at: result_attrs[:completed_at],
            status: result_attrs[:status], data_status: result_attrs[:data_status], cache_reason: result_attrs[:cache_reason],
            error_code: result_attrs.dig(:error, :code), error_remediation: result_attrs.dig(:error, :remediation),
            record_count: Array(result_attrs[:records]).length, proposed_cursor: result_attrs[:next_cursor],
            cursor_disposition: cursor_disposition || "hold", prior_activated_snapshot_id: options[:prior_activated_snapshot_id]
          }
        else
          options
        end
        db[:source_snapshots].insert(attrs)
        snapshot(attrs.fetch(:id))
      end

      def snapshot(id)
        value(SourceSnapshot, row(db[:source_snapshots], id))
      end

      def snapshots_for_run(run_id)
        db[:source_snapshots].where(run_id:).order(:source_name, :account_identity).all.map do |record|
          value(SourceSnapshot, record)
        end
      end

      def baseline_for(source_name, account_identity)
        record = db[:source_baselines].where(source_name:, account_identity:).first
        record && record.merge(activated_snapshot: snapshot(record.fetch(:activated_snapshot_id)))
      end

      def activate_baseline(source_name:, account_identity:, snapshot_id:, activated_at:, cursor: nil)
        values = {source_name:, account_identity:, activated_snapshot_id: snapshot_id, activated_at:, cursor:}
        db[:source_baselines].insert_conflict(
          target: %i[source_name account_identity],
          update: values.reject { |key, _| %i[source_name account_identity].include?(key) }
        ).insert(values)
        baseline_for(source_name, account_identity)
      end
    end
  end
end
