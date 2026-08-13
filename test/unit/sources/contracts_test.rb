# frozen_string_literal: true

require_relative "../../test_helper"
require "open3"
require "rbconfig"
require "cyborg/sources/contracts"
require "cyborg/sources/registry"

class CyborgSourceContractsTest < Minitest::Test
  def test_contract_values_are_immutable_and_registration_preserves_policy_metadata
    record = Cyborg::NormalizedRecord.new(
      source_record_id: "42", record_kind: "notification", title: "Review",
      summary: "Please review", structured_fields: {"repository" => "cyborg"},
      participants: ["me@example.com"], owner_identity: "me@example.com",
      canonical_target_type: "github_pr", canonical_target_id: "42",
      deep_link: "https://github.example/cyborg/pull/42",
      event_at: "2026-08-12T00:00:00Z", latest_reply_at: nil,
      observed_at: "2026-08-12T00:01:00Z", timestamp_kind: "event_at",
      content_fingerprint: "fingerprint", evidence: []
    )

    assert_predicate record, :frozen?
    assert_predicate record.structured_fields, :frozen?
    assert_predicate record.participants, :frozen?

    source = {
      "github" => {
        "enabled" => true, "adapter" => "github", "account" => "me@example.com",
        "transport" => "host_bridge", "capabilities" => ["notifications"],
        "credential_strategy" => "host_session", "health_checks" => ["auth"],
        "cursor_policy" => "proposed", "cache_policy" => "ordinary",
        "retention_class" => "standard", "allowed_fields" => ["title", "summary"],
        "operations" => {"notifications" => "github.notifications.read"},
        "filters" => {"unread_only" => true}, "limits" => {"max_records" => 10},
        "required" => true, "adapter_version" => "github-2"
      }
    }
    config = Struct.new(:sources).new(source)
    registration = Cyborg::SourceRegistry.enabled(config).fetch(0)

    assert_equal "github", registration.source_name
    assert_equal "github-2", registration.adapter_version
    assert_equal "me@example.com", registration.account_identity
    assert_equal "host_bridge", registration.transport
    assert_equal ["notifications"], registration.capabilities
    assert_equal({"unread_only" => true}, registration.filters)
    assert_equal "github.notifications.read", registration.operation_for("notifications")
    assert_equal true, registration.required?
    assert_predicate registration, :frozen?
  end

  def test_registry_never_enables_unconfigured_or_disabled_sources
    config = Struct.new(:sources).new({
      "github" => {"enabled" => false},
      "slack" => {"enabled" => true, "adapter" => "slack"}
    })

    assert_equal ["slack"], Cyborg::SourceRegistry.enabled(config).map(&:source_name)
  end

  def test_result_and_context_validate_cache_reason_and_status_contracts
    context = Cyborg::RetrievalContext.new(
      source_name: "fixture", account_identity: "test", window_start_utc: "2026-08-12T00:00:00Z",
      window_end_utc: "2026-08-13T00:00:00Z", display_timezone: "UTC", prior_cursor: "cursor-1",
      limits: {"max_pages" => 2, "max_records" => 3, "max_bytes" => 512},
      cache_policy: "ordinary", filters: {}
    )
    result = Cyborg::RetrievalResult.new(
      source_name: "fixture", account_identity: "test", status: "healthy",
      data_status: "cached", cache_reason: "policy_hit", started_at: context.window_start_utc,
      completed_at: context.window_end_utc, records: [], next_cursor: "cursor-2", error: nil
    )

    assert_equal 2, context.max_pages
    assert_equal 3, context.max_records
    assert_equal 512, context.max_response_bytes
    assert_predicate result, :frozen?
    assert_predicate result.records, :frozen?
    assert_raises(ArgumentError) do
      Cyborg::RetrievalResult.new(
        source_name: "fixture", account_identity: "test", status: "healthy",
        data_status: "cached", cache_reason: "failure_fallback", started_at: "a",
        completed_at: "b", records: [], next_cursor: "x", error: nil
      )
    end
  end

  def test_retrieval_result_cross_validates_status_data_and_cache_reason
    valid = [
      ["healthy", "fresh", nil, nil],
      ["healthy", "cached", "policy_hit", nil],
      ["degraded", "fresh", nil, "source.partial"],
      ["degraded", "cached", "failure_fallback", "source.unavailable"],
      ["failed", "none", nil, "source.unavailable"]
    ]
    valid.each do |status, data_status, cache_reason, error_code|
      result = retrieval_result(status:, data_status:, cache_reason:, error_code:)
      assert_equal status, result.status
    end

    invalid = [
      ["failed", "fresh", nil, "source.unavailable"],
      ["healthy", "cached", "failure_fallback", nil],
      ["degraded", "cached", "policy_hit", "source.partial"],
      ["healthy", "fresh", "policy_hit", nil],
      ["failed", "none", "failure_fallback", "source.unavailable"],
      ["degraded", "fresh", nil, nil],
      ["failed", "none", nil, nil]
    ]
    invalid.each do |status, data_status, cache_reason, error_code|
      assert_raises(ArgumentError) do
        retrieval_result(status:, data_status:, cache_reason:, error_code:)
      end
    end
  end

  def test_retrieval_context_rejects_invalid_or_zero_operation_limits
    base = {
      source_name: "fixture", account_identity: "test", window_start_utc: "2026-08-12T00:00:00Z",
      window_end_utc: "2026-08-13T00:00:00Z", display_timezone: "UTC", cache_policy: "ordinary", filters: {}
    }
    assert_raises(ArgumentError) { Cyborg::RetrievalContext.new(**base, limits: {max_records: -1}) }
    assert_raises(ArgumentError) { Cyborg::RetrievalContext.new(**base, limits: {max_pages: "many"}) }
    assert_raises(ArgumentError) { Cyborg::RetrievalContext.new(**base, limits: {max_response_bytes: 0}) }
  end

  def test_retrieval_context_requires_actual_integer_limits
    base = {
      source_name: "fixture", account_identity: "test", window_start_utc: "2026-08-12T00:00:00Z",
      window_end_utc: "2026-08-13T00:00:00Z", display_timezone: "UTC", cache_policy: "ordinary", filters: {}
    }

    assert_raises(ArgumentError) { Cyborg::RetrievalContext.new(**base, limits: {max_pages: 1.5}) }
    assert_raises(ArgumentError) { Cyborg::RetrievalContext.new(**base, limits: {max_records: 2.9}) }
    assert_raises(ArgumentError) { Cyborg::RetrievalContext.new(**base, limits: {max_bytes: "4096"}) }
    assert_equal 3, Cyborg::RetrievalContext.new(**base, limits: {max_pages: 3}).max_pages
  end

  def test_source_health_validates_status_and_failure_metadata
    %w[healthy degraded failed disabled].each do |status|
      error_code = status == "healthy" ? nil : "source.#{status}"
      health = Cyborg::SourceHealth.new(
        source_name: "fixture", account_identity: "test", status:, code: error_code,
        remediation: status == "healthy" ? nil : "retry", checked_at: "2026-08-12T00:00:00Z", message: nil
      )
      assert_equal status, health.status
      assert_equal "2026-08-12T00:00:00Z", health.checked_at
    end

    assert_raises(ArgumentError) do
      Cyborg::SourceHealth.new(source_name: "fixture", account_identity: "test", status: "unknown")
    end
    assert_raises(ArgumentError) do
      Cyborg::SourceHealth.new(source_name: "fixture", account_identity: "test", status: "failed")
    end
    assert_raises(ArgumentError) do
      Cyborg::SourceHealth.new(source_name: "fixture", account_identity: "test", status: "healthy", code: "source.ok")
    end
  end

  def test_loading_contracts_with_warnings_enabled_is_pristine
    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-w", "-Ilib", "-e", 'require "cyborg/sources/contracts"'
    )

    assert_predicate status, :success?
    assert_empty stderr
  end

  private

  def retrieval_result(status:, data_status:, cache_reason:, error_code:)
    Cyborg::RetrievalResult.new(
      source_name: "fixture", account_identity: "test", status:, data_status:, cache_reason:,
      started_at: "2026-08-12T00:00:00Z", completed_at: "2026-08-12T00:01:00Z", records: [],
      next_cursor: "cursor-1", error: error_code && Cyborg::RetrievalError.new(code: error_code)
    )
  end
end
