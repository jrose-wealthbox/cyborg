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

  def test_loading_contracts_with_warnings_enabled_is_pristine
    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-w", "-Ilib", "-e", 'require "cyborg/sources/contracts"'
    )

    assert_predicate status, :success?
    assert_empty stderr
  end
end
