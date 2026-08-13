# frozen_string_literal: true

require "json"
require_relative "contracts"
require_relative "../bridge/canonical_json"

module Cyborg
  # A deliberately boring direct adapter used by deterministic tests and
  # development. It applies the same byte/record bounds as real adapters.
  class FixtureAdapter
    DEFAULT_PATH = File.expand_path("../../../test/fixtures/sources/fixture-records.json", __dir__).freeze

    attr_reader :path, :source_name, :account_identity, :adapter_version

    def initialize(path: DEFAULT_PATH, source_name: "fixture", account_identity: "fixture", adapter_version: "fixture-1")
      @path = path.to_s
      @source_name = source_name.to_s
      @account_identity = account_identity.to_s
      @adapter_version = adapter_version.to_s
    end

    def fetch(context)
      started_at = context.window_start_utc
      payload = File.binread(path)
      max_bytes = context.max_response_bytes
      if max_bytes && payload.bytesize > max_bytes
        raise SourceLimitError.new("source.response_too_large", "fixture response exceeds configured byte bound")
      end

      parsed = JSON.parse(payload)
      raw_records = parsed.is_a?(Hash) ? parsed.fetch("records", []) : parsed
      unless raw_records.is_a?(Array)
        raise SourceError.new("source.invalid_fixture", "fixture records must be an array")
      end
      max_records = context.max_records
      if max_records && raw_records.length > max_records
        raise SourceLimitError.new("source.record_limit_exceeded", "fixture response exceeds configured record bound")
      end

      records = raw_records.map { |raw| normalize(raw, context) }
      RetrievalResult.new(
        source_name: source_name,
        account_identity: account_identity,
        status: "healthy",
        data_status: "fresh",
        cache_reason: nil,
        started_at: started_at,
        completed_at: context.window_end_utc,
        records: records,
        next_cursor: parsed.is_a?(Hash) ? parsed["next_cursor"] : nil,
        error: nil
      )
    rescue JSON::ParserError => error
      raise SourceError.new("source.invalid_fixture", error.message)
    rescue Errno::ENOENT, Errno::EACCES => error
      raise SourceError.new("source.fixture_unavailable", error.message)
    end

    private

    def normalize(raw, context)
      unless raw.is_a?(Hash)
        raise SourceError.new("source.invalid_fixture", "fixture record must be an object")
      end
      value = raw.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
      event_at = value["event_at"] || value["latest_reply_at"] || context.window_end_utc
      observed_at = value["observed_at"] || context.window_end_utc
      latest_reply_at = value["latest_reply_at"]
      timestamp_kind = value["timestamp_kind"] || (latest_reply_at ? "latest_reply_at" : "event_at")
      evidence = Array(value["evidence"]).map do |draft|
        EvidenceDraft.new(
          source_url: draft.fetch("source_url"), source_label: draft.fetch("source_label"),
          excerpt: draft["excerpt"], field_path: draft["field_path"],
          evidence_at: draft.fetch("evidence_at", event_at), relation: draft.fetch("relation", "context")
        )
      end
      fingerprint_payload = value.reject { |key, _item| key == "evidence" || key == "content_fingerprint" }
      fingerprint = value["content_fingerprint"] || Bridge::CanonicalJSON.sha256(fingerprint_payload)

      NormalizedRecord.new(
        source_record_id: value.fetch("source_record_id"), record_kind: value.fetch("record_kind"),
        title: value["title"], summary: value["summary"], structured_fields: value["structured_fields"] || {},
        participants: value["participants"] || [], owner_identity: value["owner_identity"],
        canonical_target_type: value["canonical_target_type"], canonical_target_id: value["canonical_target_id"],
        deep_link: value["deep_link"], event_at: event_at, latest_reply_at: latest_reply_at,
        observed_at: observed_at, timestamp_kind: timestamp_kind, content_fingerprint: fingerprint,
        evidence: evidence
      )
    rescue KeyError => error
      raise SourceError.new("source.invalid_fixture", "fixture record is missing #{error.key}")
    end
  end
end
