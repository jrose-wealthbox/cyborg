# frozen_string_literal: true

require_relative "../bridge/canonical_json"
require_relative "../errors"
require_relative "../redactor"
require_relative "group_candidates"
require_relative "support"

module Cyborg
  module Pipeline
    # Builds the only source-data shape allowed to cross into host-mediated
    # analysis.  All policy that can be deterministic stays here: bounds,
    # action categories, trusted URLs, evidence IDs, and captured action
    # state.  Source fields are explicitly marked as data, never instructions.
    class AnalysisPacketBuilder
      VERSION = "1.0".freeze
      DEFAULT_MAXIMUM_BYTES = 262_144
      DEFAULT_MAXIMUM_CLAIM_COUNT = 25
      DEFAULT_MAXIMUM_OUTPUT_BYTES = 8_192
      DEFAULT_MAXIMUM_FIELD_BYTES = 4_096
      ACTION_KINDS = %w[review respond follow_up investigate].freeze

      attr_reader :maximum_bytes, :maximum_claim_count, :maximum_output_bytes, :prompt_version

      def initialize(trusted_hosts: [], maximum_bytes: DEFAULT_MAXIMUM_BYTES,
                     maximum_claim_count: DEFAULT_MAXIMUM_CLAIM_COUNT,
                     maximum_output_bytes: DEFAULT_MAXIMUM_OUTPUT_BYTES,
                     maximum_excerpt_bytes: EvidenceBuilder::DEFAULT_MAX_EXCERPT_BYTES,
                     maximum_field_bytes: DEFAULT_MAXIMUM_FIELD_BYTES,
                     prompt_version: "prompt-1", evidence_builder: nil,
                     group_candidates: nil, redactor: nil, allowed_action_kinds: ACTION_KINDS,
                     **options)
        unless options.empty?
          raise ArgumentError, "unknown options: #{options.keys.join(", ")}"
        end

        @maximum_bytes = positive_integer(maximum_bytes, "maximum_bytes")
        @maximum_claim_count = positive_integer(maximum_claim_count, "maximum_claim_count")
        @maximum_output_bytes = positive_integer(maximum_output_bytes, "maximum_output_bytes")
        @maximum_excerpt_bytes = positive_integer(maximum_excerpt_bytes, "maximum_excerpt_bytes")
        @maximum_field_bytes = positive_integer(maximum_field_bytes, "maximum_field_bytes")
        @prompt_version = prompt_version.to_s
        raise ArgumentError, "prompt_version is required" if @prompt_version.empty?

        @redactor = redactor || Cyborg::Redactor.new
        @evidence_builder = evidence_builder || EvidenceBuilder.new(
          trusted_hosts:, maximum_excerpt_bytes:
        )
        @group_candidates = group_candidates || GroupCandidates.new(
          evidence_builder: @evidence_builder, trusted_hosts:
        )
        @allowed_action_kinds = Array(allowed_action_kinds).map(&:to_s).reject(&:empty?).uniq.freeze
        raise ArgumentError, "allowed_action_kinds cannot be empty" if @allowed_action_kinds.empty?
      end

      def call(run:, records:, actions:, tasks:, reservation:)
        records = Array(records)
        evidence_by_record = records.each_with_object({}) do |record, result|
          result[Support.source_record_id(record)] = @evidence_builder.call(record)
        end
        groups = @group_candidates.call(records).map { |group| sanitize_value(group) }
        packet_records = records.map do |record|
          record_payload(record, evidence_by_record.fetch(Support.source_record_id(record), []))
        end

        configuration_version = run_value(run, :configuration_fingerprint, "")
        run_id = run_value(run, :id, "")
        payload = {
          "packet_version" => VERSION,
          "run_id" => run_id.to_s,
          "prompt_version" => @prompt_version,
          "configuration_version" => configuration_version.to_s,
          "versions" => {
            "packet" => VERSION,
            "prompt" => @prompt_version,
            "configuration" => configuration_version.to_s,
            "task" => "1.0"
          },
          "allowed_action_kinds" => @allowed_action_kinds,
          "records" => packet_records,
          "existing_actions" => Array(actions).map { |action| action_payload(action) },
          "group_candidates" => groups,
          "unresolved_questions" => groups.flat_map { |group| Array(group["unresolved_questions"]) }.uniq,
          "tasks" => Array(tasks).map { |task| task_payload(task) },
          "reservation" => sanitize_value(reservation),
          "maximum_claim_count" => @maximum_claim_count,
          "maximum_output_bytes" => @maximum_output_bytes,
          "limits" => {
            "maximum_bytes" => @maximum_bytes,
            "maximum_claim_count" => @maximum_claim_count,
            "maximum_output_bytes" => @maximum_output_bytes,
            "maximum_excerpt_bytes" => @maximum_excerpt_bytes
          },
          "action_state_version" => run_value(run, :captured_action_state_version, 0),
          "source_fields_are_untrusted_data" => true
        }

        canonical = Bridge::CanonicalJSON.dump(payload)
        raise Cyborg::PacketTooLarge if canonical.bytesize > @maximum_bytes

        payload
      end

      private

      def record_payload(record, evidence)
        fields = @redactor.call(Support.structured_fields(record))
        deep_link = evidence.map { |item| item["source_url"] }.compact.first
        {
          "source_record_id" => Support.source_record_id(record),
          "source_name" => Support.source_name(record),
          "account_identity" => Support.account_identity(record),
          "record_kind" => Support.record_kind(record),
          "title" => bounded(Support.value(record, :title)),
          "summary" => bounded(Support.value(record, :summary)),
          "structured_fields" => sanitize_value(fields),
          "participants" => sanitize_value(Array(Support.value(record, :participants, []))),
          "owner_identity" => bounded(Support.value(record, :owner_identity)),
          "canonical_target_type" => bounded(Support.value(record, :canonical_target_type), 256),
          "canonical_target_id" => bounded(Support.value(record, :canonical_target_id), 512),
          "deep_link" => deep_link,
          "event_at" => Support.canonical_time(Support.value(record, :event_at)),
          "latest_reply_at" => Support.canonical_time(Support.value(record, :latest_reply_at)),
          "observed_at" => Support.canonical_time(Support.value(record, :observed_at)),
          "timestamp_kind" => bounded(Support.value(record, :timestamp_kind), 128),
          "content_fingerprint" => bounded(Support.value(record, :content_fingerprint), 128),
          "evidence_ids" => evidence.map { |item| item.fetch("evidence_id") },
          "evidence" => evidence
        }
      end

      def action_payload(action)
        value = sanitize_value(action)
        value = {} unless value.is_a?(Hash)
        # Keep the state fields explicit even when a repository returns a
        # narrow value object.  Unknown metadata remains available but is
        # redacted and bounded by sanitize_value.
        value
      end

      def task_payload(task)
        value = sanitize_value(task)
        value = {} unless value.is_a?(Hash)
        value["dependency_ids"] = Array(value["dependency_ids"]).map(&:to_s)
        value
      end

      def run_value(run, field, default = nil)
        Support.value(run, field, default)
      end

      def sanitize_value(value)
        case value
        when Hash
          redacted = @redactor.call(value)
          redacted.each_with_object({}) do |(key, item), result|
            result[key.to_s] = sanitize_value(item)
          end
        when Array
          value.map { |item| sanitize_value(item) }
        when Time
          value.utc.iso8601
        when String
          bounded(@redactor.call(value))
        when NilClass, TrueClass, FalseClass, Integer, Float
          value
        else
          if value.respond_to?(:to_h)
            sanitize_value(value.to_h)
          else
            bounded(value.to_s)
          end
        end
      end

      def bounded(value, bytes = @maximum_field_bytes)
        return nil if value.nil?

        Support.bounded_string(@redactor.call(value.to_s), bytes)
      end

      def positive_integer(value, field)
        unless value.is_a?(Integer) && value.positive?
          raise ArgumentError, "#{field} must be a positive integer"
        end
        value
      end
    end
  end
end
