# frozen_string_literal: true

require "json"
require "time"
require_relative "../errors"

module Cyborg
  module SourceContracts
    module_function

    def immutable(value)
      case value
      when Hash
        value.each { |key, item| immutable(key); immutable(item) }
      when Array
        value.each { |item| immutable(item) }
      end
      value.freeze
    end

    def stringify(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), result| result[key.to_s] = stringify(item) }
      when Array
        value.map { |item| stringify(item) }
      else
        value
      end
    end

    def fetch_limit(limits, *keys)
      keys.each do |key|
        value = limits[key.to_s] || limits[key.to_sym]
        return Integer(value) unless value.nil?
      end
      nil
    rescue ArgumentError, TypeError
      raise ArgumentError, "source limits must be non-negative integers"
    end

    def canonical_time(value, field:)
      return nil if value.nil?
      return value.utc.iso8601 if value.respond_to?(:utc)

      parsed = Time.iso8601(value.to_s)
      parsed.utc.iso8601
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{field} must be an RFC3339 timestamp"
    end

    def validate_retrieval_result(value)
      value = value.dup
      status, data_status, cache_reason = value.values_at(2, 3, 4)
      raise ArgumentError, "unsupported retrieval status" unless %w[healthy degraded failed].include?(status.to_s)
      raise ArgumentError, "unsupported data status" unless %w[fresh cached none].include?(data_status.to_s)
      unless cache_reason.nil? || %w[policy_hit failure_fallback].include?(cache_reason.to_s)
        raise ArgumentError, "unsupported cache reason"
      end
      if data_status.to_s == "cached" && cache_reason.nil?
        raise ArgumentError, "cached data requires a cache reason"
      end

      value[6] = canonical_time(value[6], field: "completed_at") unless value[6].nil?
      value[5] = canonical_time(value[5], field: "started_at") unless value[5].nil?
      value[7] = Array(value[7])
      value
    end

    def value_class(name, members, defaults: {}, validator: nil, &block)
      klass = Data.define(*members)
      generated_new = klass.method(:new)
      constructor = Module.new do
        define_method(:new) do |*args, **kwargs|
          values = if args.empty?
            unknown = kwargs.keys.map(&:to_sym) - members
            raise ArgumentError, "unknown #{name} fields: #{unknown.join(", ")}" unless unknown.empty?

            members.map { |member| kwargs.key?(member) ? kwargs[member] : defaults[member] }
          else
            args
          end
          values = validator.call(values) if validator
          values.each { |value| SourceContracts.immutable(value) unless value.nil? }
          generated_new.call(*values)
        end
      end
      klass.singleton_class.prepend(constructor)
      klass.class_eval(&block) if block
      klass
    end

  end

  RetrievalError = SourceContracts.value_class(
    "RetrievalError", %i[code message remediation], defaults: {message: nil, remediation: nil}
  )

  RetrievalContext = SourceContracts.value_class(
    "RetrievalContext",
    %i[source_name account_identity window_start_utc window_end_utc display_timezone prior_cursor limits cache_policy filters capabilities],
    defaults: {prior_cursor: nil, limits: {}, cache_policy: "ordinary", filters: {}, capabilities: []}
  ) do
    def max_pages
      SourceContracts.fetch_limit(limits, "max_pages")
    end

    def max_records
      SourceContracts.fetch_limit(limits, "max_records")
    end

    def max_response_bytes
      SourceContracts.fetch_limit(limits, "max_response_bytes", "max_bytes")
    end

    alias max_bytes max_response_bytes

    def max_seconds
      SourceContracts.fetch_limit(limits, "max_seconds")
    end
  end

  RetrievalResult = SourceContracts.value_class(
    "RetrievalResult",
    %i[source_name account_identity status data_status cache_reason started_at completed_at records next_cursor error],
    defaults: {cache_reason: nil, records: [], next_cursor: nil, error: nil},
    validator: ->(value) { SourceContracts.validate_retrieval_result(value) }
  ) do
    STATUSES = %w[healthy degraded failed].freeze
    DATA_STATUSES = %w[fresh cached none].freeze
    CACHE_REASONS = %w[policy_hit failure_fallback].freeze

  end
  RetrievalRequest = SourceContracts.value_class(
    "RetrievalRequest",
    %i[id run_id source_name account_identity capability adapter_version window_start_utc window_end_utc display_timezone prior_cursor operation parameters max_pages max_records max_response_bytes required],
    defaults: {prior_cursor: nil, parameters: {}, max_pages: nil, max_records: nil, max_response_bytes: nil, required: false}
  ) do
    alias request_id id
  end

  RetrievalResponse = SourceContracts.value_class(
    "RetrievalResponse",
    %i[request_id run_id source_name account_identity status data_status started_at completed_at records next_cursor error],
    defaults: {data_status: "fresh", records: [], next_cursor: nil, error: nil}
  )

  EvidenceDraft = SourceContracts.value_class(
    "EvidenceDraft",
    %i[source_url source_label excerpt field_path evidence_at relation],
    defaults: {excerpt: nil, field_path: nil, relation: "context"}
  ) do
    def to_h
      members.each_with_object({}) { |member, result| result[member] = public_send(member) }
    end
  end

  NormalizedRecord = SourceContracts.value_class(
    "NormalizedRecord",
    %i[source_record_id record_kind title summary structured_fields participants owner_identity canonical_target_type canonical_target_id deep_link event_at latest_reply_at observed_at timestamp_kind content_fingerprint evidence],
    defaults: {
      title: nil, summary: nil, structured_fields: {}, participants: [], owner_identity: nil,
      canonical_target_type: nil, canonical_target_id: nil, deep_link: nil, latest_reply_at: nil,
      observed_at: nil, timestamp_kind: nil, content_fingerprint: nil, evidence: []
    }
  ) do
    def structured_fields_json
      JSON.generate(structured_fields)
    end

    def participants_json
      JSON.generate(participants)
    end
  end

  SourceHealth = SourceContracts.value_class(
    "SourceHealth",
    %i[source_name account_identity status code remediation checked_at message],
    defaults: {code: nil, remediation: nil, checked_at: nil, message: nil}
  )

  Registration = SourceContracts.value_class(
    "Registration",
    %i[source_name adapter_version account_identity transport capabilities filters limits credential_strategy health_checks cursor_policy cache_policy retention_class allowed_fields operations parameters required enabled],
    defaults: {
      adapter_version: "unknown", account_identity: nil, transport: "direct", capabilities: [],
      filters: {}, limits: {}, credential_strategy: "external", health_checks: [], cursor_policy: "proposed",
      cache_policy: "ordinary", retention_class: "standard", allowed_fields: [], operations: {},
      parameters: {}, required: false, enabled: true
    }
  ) do
    def required?
      required == true
    end

    def operation_for(capability)
      operation = operations[capability.to_s] || operations[capability.to_sym]
      unless operation.is_a?(String) && !operation.empty?
        raise Cyborg::UsageError.new("source.operation_not_allowlisted", "operation is not allowlisted for #{source_name}")
      end
      operation
    end

    def parameters_for(capability)
      value = parameters[capability.to_s] || parameters[capability.to_sym] || parameters
      SourceContracts.stringify(value.is_a?(Hash) ? value : {})
    end

    def max_pages
      SourceContracts.fetch_limit(limits, "max_pages")
    end

    def max_records
      SourceContracts.fetch_limit(limits, "max_records")
    end

    def max_response_bytes
      SourceContracts.fetch_limit(limits, "max_response_bytes", "max_bytes")
    end
  end
end
