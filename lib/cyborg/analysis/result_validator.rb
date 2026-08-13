# frozen_string_literal: true

require "time"
require "uri"

require_relative "../bridge/canonical_json"
require_relative "../redactor"
require_relative "contracts"

module Cyborg
  module Analysis
    # The only boundary at which model-produced analysis becomes durable
    # application data.  Validation is deliberately fail-closed: a result is
    # either an AnalysisOutcome or a redacted RejectedAnalysis with no claims.
    class ResultValidator
      CLAIM_FIELDS = %w[
        action_kind summary subject_type subject_id canonical_subject_type canonical_subject_id
        owner_identity thread_or_target_identity target_identity anchor_evidence_id evidence_ids
        confidence due_at people projects new_commitment rationale task_id capability dependency_ids
        source_url source_urls requested_operation requested_operations
      ].freeze
      RESULT_FIELDS = %w[claims usage backend_metadata tasks].freeze
      USAGE_FIELDS = %w[
        run_id task_id session_id parent_session_id reserved_cost_micros input_tokens output_tokens
        cost_micros certainty created_at records warnings reported_cost_micros
        provider_reported_cost_micros locally_estimated_cost_micros unknown_cost_micros
      ].freeze
      TASK_RESULT_FIELDS = %w[id task_id capability dependency_ids status claims usage].freeze
      CERTAINTIES = %w[reserved provider_reported locally_estimated unknown].freeze
      DEFAULT_MAXIMUM_DETAILS_BYTES = 512
      MAXIMUM_TEXT_BYTES = 4_096
      MAXIMUM_LIST_LENGTH = 100
      UNSET = Object.new.freeze

      Claim = Data.define(
        :action_kind, :summary, :canonical_subject_type, :canonical_subject_id,
        :owner_identity, :thread_or_target_identity, :anchor_evidence_id, :evidence_ids,
        :confidence, :due_at, :people, :projects, :new_commitment, :rationale,
        :task_id, :capability, :dependency_ids, :source_url, :source_urls
      ) do
        alias subject_type canonical_subject_type
        alias subject_id canonical_subject_id
        alias target_identity thread_or_target_identity

        def to_h
          members.each_with_object({}) { |member, result| result[member.to_s] = public_send(member) }
        end

        def self.from_h(value)
          hash = value.transform_keys(&:to_s)
          subject_type = hash["canonical_subject_type"] || hash["subject_type"]
          subject_id = hash["canonical_subject_id"] || hash["subject_id"]
          new(
            hash["action_kind"], hash["summary"], subject_type, subject_id,
            hash["owner_identity"], hash["thread_or_target_identity"] || hash["target_identity"],
            hash["anchor_evidence_id"], Array(hash["evidence_ids"]), hash["confidence"],
            hash["due_at"], Array(hash["people"]), Array(hash["projects"]),
            hash.fetch("new_commitment", false), hash["rationale"], hash["task_id"],
            hash["capability"], Array(hash["dependency_ids"]), hash["source_url"],
            Array(hash["source_urls"])
          )
        end
      end

      RejectedAnalysis = Data.define(:code, :accepted_claims, :details) do
        alias claims accepted_claims

        def accepted?
          false
        end
      end

      class ValidationFailure < StandardError
        attr_reader :code, :field

        def initialize(code, field = nil)
          @code = code
          @field = field
          super(code)
        end
      end

      def initialize(redactor: nil, maximum_details_bytes: DEFAULT_MAXIMUM_DETAILS_BYTES)
        @redactor = redactor || Cyborg::Redactor.new
        @maximum_details_bytes = positive_integer(maximum_details_bytes, "maximum_details_bytes")
      end

      def validate(packet:, result:)
        begin
          packet = normalize_hash(packet, "packet")
          result = normalize_hash(result, "result")
          unknown_result_fields = result.keys - RESULT_FIELDS
          fail!("analysis.unknown_field", unknown_result_fields.first) unless unknown_result_fields.empty?
          limits = validate_packet(packet)
          raw_claims = required(result, "claims")
          fail!("analysis.invalid_result", "claims") unless raw_claims.is_a?(Array)
          fail!("analysis.claim_limit", "claims") if raw_claims.length > limits.fetch(:maximum_claim_count)
          result_bytes = canonical_bytes(result)
          fail!("analysis.output_too_large") if result_bytes > limits.fetch(:maximum_output_bytes)

          evidence = evidence_index(packet)
          tasks = task_index(packet)
          claims = raw_claims.map do |raw_claim|
            validate_claim(raw_claim, packet:, evidence:, tasks:)
          end
          usage = validate_usage(result.fetch("usage", {}), packet:, tasks:)
          validate_task_results(result.fetch("tasks", []), packet:, tasks:) if result.key?("tasks")
          metadata = safe_metadata(result.fetch("backend_metadata", {}))

          AnalysisOutcome.new(claims: claims, usage:, backend_metadata: metadata)
        rescue ValidationFailure => error
          rejected(error.code, error.field)
        rescue StandardError
          # Never expose parser errors, object inspection, prompt text, or
          # source excerpts in a persisted rejection.
          rejected("analysis.invalid_result")
        end
      end

      private

      def validate_packet(packet)
        allowed = packet.fetch("allowed_action_kinds", default_action_kinds)
        fail!("analysis.invalid_packet", "allowed_action_kinds") unless allowed.is_a?(Array) && !allowed.empty? && allowed.all? { |item| item.is_a?(String) } && (allowed - default_action_kinds).empty?

        claim_limit = packet_value(packet, "maximum_claim_count", packet.dig("limits", "maximum_claim_count"))
        output_limit = packet_value(packet, "maximum_output_bytes", packet.dig("limits", "maximum_output_bytes"))
        fail!("analysis.invalid_packet", "maximum_claim_count") unless positive_integer?(claim_limit)
        fail!("analysis.invalid_packet", "maximum_output_bytes") unless positive_integer?(output_limit)
        fail!("analysis.invalid_packet", "run_id") unless nonblank?(packet["run_id"])
        fail!("analysis.invalid_packet", "records") unless packet["records"].is_a?(Array)

        {allowed_action_kinds: allowed, maximum_claim_count: claim_limit, maximum_output_bytes: output_limit}
      end

      def evidence_index(packet)
        packet.fetch("records").each_with_object({}) do |record, index|
          fail!("analysis.invalid_packet", "records") unless record.is_a?(Hash)
          declared = record.fetch("evidence_ids", [])
          fail!("analysis.invalid_packet", "evidence_ids") unless declared.is_a?(Array)
          declared.each { |id| fail!("analysis.invalid_packet", "evidence_ids") unless nonblank?(id) }
          Array(record["evidence"]).each do |item|
            fail!("analysis.invalid_packet", "evidence") unless item.is_a?(Hash)
            id = item["evidence_id"]
            fail!("analysis.invalid_packet", "evidence_id") unless nonblank?(id)
            fail!("analysis.invalid_packet", "evidence_id") unless declared.include?(id)
            url = item["source_url"]
            if url && !trusted_url?(url)
              fail!("analysis.invalid_packet", "source_url")
            end
            index[id] = {source_url: url}
          end
          declared.each { |id| index[id] ||= {source_url: nil} }
        end
      end

      def task_index(packet)
        Array(packet["tasks"]).each_with_object({}) do |task, index|
          fail!("analysis.invalid_packet", "tasks") unless task.is_a?(Hash)
          id = task["id"]
          capability = task["capability"]
          dependencies = task.fetch("dependency_ids", [])
          fail!("analysis.invalid_packet", "tasks") unless nonblank?(id) && CAPABILITIES.include?(capability.to_s)
          fail!("analysis.invalid_packet", "dependency_ids") unless dependencies.is_a?(Array) && dependencies.all? { |item| nonblank?(item) }
          index[id] = {capability: capability.to_s, dependency_ids: dependencies.map(&:to_s).uniq.sort}
        end
      end

      def validate_claim(raw_claim, packet:, evidence:, tasks:)
        claim = normalize_hash(raw_claim, "claim")
        unknown = claim.keys - CLAIM_FIELDS
        fail!("analysis.unknown_field", unknown.first) unless unknown.empty?
        action_kind = required_string(claim, "action_kind")
        allowed = packet.fetch("allowed_action_kinds", default_action_kinds)
        fail!("analysis.unsupported_action_kind", "action_kind") unless allowed.include?(action_kind)

        summary = required_string(claim, "summary")
        subject_type = aliased_string(claim, "canonical_subject_type", "subject_type")
        subject_id = aliased_string(claim, "canonical_subject_id", "subject_id")
        anchor = required_string(claim, "anchor_evidence_id")
        evidence_ids = required_array(claim, "evidence_ids")
        fail!("analysis.schema", "evidence_ids") unless evidence_ids.all? { |item| nonblank?(item) }
        evidence_ids = evidence_ids.map(&:to_s).uniq.sort
        missing = evidence_ids.reject { |id| evidence.key?(id) }
        fail!("analysis.unknown_evidence", "evidence_ids") unless missing.empty?
        fail!("analysis.missing_anchor_evidence", "anchor_evidence_id") unless evidence_ids.include?(anchor)

        confidence = claim["confidence"]
        fail!("analysis.invalid_confidence", "confidence") unless confidence.is_a?(Numeric) && confidence.finite? && confidence >= 0 && confidence <= 1
        due_at = canonical_date_time(claim["due_at"]) if claim.key?("due_at")
        people = bounded_string_list(claim["people"], "people") if claim.key?("people")
        projects = bounded_string_list(claim["projects"], "projects") if claim.key?("projects")
        new_commitment = claim.fetch("new_commitment", false)
        fail!("analysis.schema", "new_commitment") unless [true, false].include?(new_commitment)
        rationale = bounded_text(claim["rationale"], "rationale", required: false)
        source_url, source_urls = validate_links(claim, evidence)
        if claim.key?("requested_operation") && !claim["requested_operation"].nil?
          fail!("analysis.source_write_forbidden", "requested_operation")
        end
        if claim.key?("requested_operations") && !Array(claim["requested_operations"]).empty?
          fail!("analysis.source_write_forbidden", "requested_operations")
        end

        task_id = claim["task_id"]
        capability = claim["capability"]
        dependency_ids = claim.fetch("dependency_ids", [])
        if task_id
          fail!("analysis.undeclared_task", "task_id") unless tasks.key?(task_id)
          task = tasks.fetch(task_id)
          fail!("analysis.capability_mismatch", "capability") unless capability.to_s == task.fetch(:capability)
          fail!("analysis.dependency_mismatch", "dependency_ids") unless dependency_ids.is_a?(Array)
          normalized_dependencies = dependency_ids.map(&:to_s).uniq.sort
          fail!("analysis.dependency_mismatch", "dependency_ids") unless normalized_dependencies == task.fetch(:dependency_ids)
          dependency_ids = normalized_dependencies
        else
          fail!("analysis.schema", "dependency_ids") unless dependency_ids.is_a?(Array)
          dependency_ids = dependency_ids.map(&:to_s).uniq.sort
        end

        Claim.new(
          action_kind, summary, subject_type, subject_id,
          optional_string(claim["owner_identity"]),
          optional_string(claim["thread_or_target_identity"] || claim["target_identity"]),
          anchor, evidence_ids, confidence, due_at, people || [], projects || [], new_commitment,
          rationale, task_id, capability, dependency_ids, source_url, source_urls
        ).tap { |value| deep_freeze(value) }
      end

      def validate_links(claim, evidence)
        urls = []
        urls << claim["source_url"] if claim.key?("source_url") && !claim["source_url"].nil?
        if claim.key?("source_urls")
          fail!("analysis.untrusted_url", "source_urls") unless claim["source_urls"].is_a?(Array)
          urls.concat(claim["source_urls"])
        end
        urls.each do |url|
          fail!("analysis.untrusted_url", "source_url") unless url.is_a?(String) && trusted_url?(url) && evidence.values.any? { |item| item[:source_url] == url }
        end
        [urls.first, urls.uniq]
      end

      def validate_usage(raw_usage, packet:, tasks:)
        usage = normalize_hash(raw_usage, "usage")
        unknown = usage.keys - USAGE_FIELDS
        fail!("analysis.invalid_usage", unknown.first) unless unknown.empty?
        if usage.key?("run_id") && usage["run_id"] != packet["run_id"]
          fail!("analysis.invalid_usage", "run_id")
        end
        records = usage.fetch("records", [])
        fail!("analysis.invalid_usage", "records") unless records.is_a?(Array)
        normalized_records = records.map { |record| validate_usage_record(record, packet:, tasks:) }
        %w[reserved_cost_micros input_tokens output_tokens cost_micros reported_cost_micros
           provider_reported_cost_micros locally_estimated_cost_micros unknown_cost_micros].each do |field|
          validate_nonnegative_integer(usage[field], field) if usage.key?(field)
        end
        certainty = usage["certainty"]
        validate_usage_values(usage, certainty, "usage") if certainty
        result = usage.dup
        result["records"] = normalized_records
        result["certainty"] = certainty.to_s if certainty
        result["created_at"] = usage_date(result["created_at"]) if result.key?("created_at")
        if result.key?("warnings")
          fail!("analysis.invalid_usage", "warnings") unless result["warnings"].is_a?(Array) && result["warnings"].length <= MAXIMUM_LIST_LENGTH && result["warnings"].all? { |warning| warning.is_a?(String) && warning.bytesize <= MAXIMUM_TEXT_BYTES }
        end
        deep_freeze(result)
      end

      def validate_usage_record(record, packet:, tasks:)
        value = normalize_hash(record, "usage record")
        unknown = value.keys - USAGE_FIELDS
        fail!("analysis.invalid_usage", unknown.first) unless unknown.empty?
        if value.key?("run_id") && value["run_id"] != packet["run_id"]
          fail!("analysis.invalid_usage", "run_id")
        end
        if value.key?("task_id") && value["task_id"] && !tasks.key?(value["task_id"])
          fail!("analysis.invalid_usage", "task_id")
        end
        %w[reserved_cost_micros input_tokens output_tokens cost_micros].each do |field|
          validate_nonnegative_integer(value[field], field) if value.key?(field)
        end
        validate_usage_values(value, value["certainty"], "usage record")
        value["created_at"] = usage_date(value["created_at"]) if value.key?("created_at")
        deep_freeze(value)
      end

      def validate_usage_values(value, certainty, field)
        fail!("analysis.invalid_usage", field) unless CERTAINTIES.include?(certainty.to_s)
        if %w[provider_reported locally_estimated].include?(certainty.to_s)
          %w[input_tokens output_tokens cost_micros].each do |key|
            fail!("analysis.invalid_usage", key) unless value[key].is_a?(Integer) && value[key] >= 0
          end
        end
        if certainty.to_s == "reserved" && %w[input_tokens output_tokens cost_micros].any? { |key| value.key?(key) && !value[key].nil? }
          fail!("analysis.invalid_usage", field)
        end
      end

      def validate_task_results(raw_tasks, packet:, tasks:)
        fail!("analysis.invalid_result", "tasks") unless raw_tasks.is_a?(Array)
        raw_tasks.each do |raw_task|
          task = normalize_hash(raw_task, "task")
          fail!("analysis.unknown_field", "task") unless (task.keys - TASK_RESULT_FIELDS).empty?
          id = task["id"] || task["task_id"]
          fail!("analysis.undeclared_task", "task_id") unless tasks.key?(id)
          expected = tasks.fetch(id)
          fail!("analysis.capability_mismatch", "capability") unless task["capability"].to_s == expected[:capability]
          dependencies = task.fetch("dependency_ids", [])
          fail!("analysis.dependency_mismatch", "dependency_ids") unless dependencies.is_a?(Array) && dependencies.map(&:to_s).uniq.sort == expected[:dependency_ids]
        end
      end

      def canonical_date_time(value)
        fail!("analysis.invalid_date") unless value.is_a?(String)
        Time.iso8601(value).utc.iso8601
      rescue ArgumentError, TypeError
        fail!("analysis.invalid_date")
      end

      def usage_date(value)
        fail!("analysis.invalid_usage", "created_at") unless value.is_a?(String)
        Time.iso8601(value).utc.iso8601
      rescue ArgumentError, TypeError
        fail!("analysis.invalid_usage", "created_at")
      end

      def bounded_string_list(value, field)
        fail!("analysis.schema", field) unless value.is_a?(Array) && value.length <= MAXIMUM_LIST_LENGTH
        value.map { |item| bounded_text(item, field) }.uniq.freeze
      end

      def bounded_text(value, field, required: false)
        if value.nil? && !required
          return nil
        end
        fail!("analysis.missing_field", field) if required && !nonblank?(value)
        fail!("analysis.schema", field) unless value.is_a?(String) && value.bytesize <= MAXIMUM_TEXT_BYTES
        value
      end

      def required_string(hash, field)
        value = hash[field]
        fail!("analysis.missing_field", field) unless nonblank?(value)
        bounded_text(value, field, required: true)
      end

      def aliased_string(hash, canonical, alias_name)
        canonical_value = hash[canonical]
        alias_value = hash[alias_name]
        if canonical_value && alias_value && canonical_value != alias_value
          fail!("analysis.schema", canonical)
        end
        value = canonical_value || alias_value
        fail!("analysis.missing_field", canonical) unless nonblank?(value)
        bounded_text(value, canonical, required: true)
      end

      def optional_string(value)
        return nil if value.nil?

        fail!("analysis.schema") unless value.is_a?(String) && value.bytesize <= MAXIMUM_TEXT_BYTES
        value
      end

      def required_array(hash, field)
        value = hash[field]
        fail!("analysis.missing_field", field) unless value.is_a?(Array)
        value
      end

      def normalize_hash(value, field)
        fail!("analysis.invalid_result", field) unless value.is_a?(Hash)
        value.each_with_object({}) do |(key, item), normalized|
          normalized_key = key.to_s
          fail!("analysis.schema", field) if normalized.key?(normalized_key)
          normalized[normalized_key] = item
        end
      end

      def safe_metadata(value)
        metadata = normalize_hash(value, "backend_metadata")
        deep_safe_metadata(metadata)
      end

      def deep_safe_metadata(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, item), result|
            key_name = key.to_s
            next if key_name.match?(Cyborg::Redactor::BODY_KEY) || key_name.match?(Cyborg::Redactor::SENSITIVE_KEY)
            safe_key = key_name.byteslice(0, MAXIMUM_TEXT_BYTES)
            result[@redactor.call(safe_key)] = deep_safe_metadata(item)
          end
        when Array
          value.first(MAXIMUM_LIST_LENGTH).map { |item| deep_safe_metadata(item) }
        when String
          @redactor.call(value)[0, MAXIMUM_TEXT_BYTES]
        when NilClass, TrueClass, FalseClass, Integer, Float
          value
        else
          value.to_s[0, MAXIMUM_TEXT_BYTES]
        end.tap { |safe| deep_freeze(safe) }
      end

      def rejected(code, field = nil)
        details = {"code" => code}
        safe_field = field.to_s
        if field && safe_field.match?("\\A[a-zA-Z0-9_]+\\z") && !safe_field.match?(Cyborg::Redactor::BODY_KEY) && !safe_field.match?(Cyborg::Redactor::SENSITIVE_KEY) && safe_field.bytesize <= 128
          details["field"] = safe_field
        end
        details = deep_safe_metadata(details)
        details = {"code" => code}.freeze unless canonical_bytes(details) <= @maximum_details_bytes
        RejectedAnalysis.new(code, [].freeze, details)
      end

      def canonical_bytes(value)
        Bridge::CanonicalJSON.dump(value).bytesize
      rescue StandardError
        fail!("analysis.invalid_result")
      end

      def required(hash, field)
        fail!("analysis.missing_field", field) unless hash.key?(field)
        hash.fetch(field)
      end

      def packet_value(hash, key, fallback)
        hash.key?(key) ? hash[key] : fallback
      end

      def default_action_kinds
        if defined?(Cyborg::Pipeline::AnalysisPacketBuilder::ACTION_KINDS)
          Cyborg::Pipeline::AnalysisPacketBuilder::ACTION_KINDS
        else
          %w[review respond follow_up investigate]
        end
      end

      def trusted_url?(value)
        return false unless value.is_a?(String)
        uri = URI.parse(value)
        uri.scheme == "https" && !uri.host.to_s.empty? && uri.userinfo.nil?
      rescue URI::InvalidURIError
        false
      end

      def positive_integer(value, _field)
        raise ArgumentError unless positive_integer?(value)

        value
      end

      def positive_integer?(value)
        value.is_a?(Integer) && value.positive?
      end

      def validate_nonnegative_integer(value, field)
        fail!("analysis.invalid_usage", field) unless value.is_a?(Integer) && value >= 0
      end

      def nonblank?(value)
        value.is_a?(String) && !value.strip.empty?
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each { |key, item| deep_freeze(key); deep_freeze(item) }
        when Array
          value.each { |item| deep_freeze(item) }
        end
        value.freeze
      end

      def fail!(code, field = nil)
        raise ValidationFailure.new(code, field)
      end
    end

    Claim = ResultValidator::Claim unless const_defined?(:Claim, false)
    RejectedAnalysis = ResultValidator::RejectedAnalysis unless const_defined?(:RejectedAnalysis, false)
  end

  Claim = Analysis::Claim unless const_defined?(:Claim, false)
  RejectedAnalysis = Analysis::RejectedAnalysis unless const_defined?(:RejectedAnalysis, false)
end
