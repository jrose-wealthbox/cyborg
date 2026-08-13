# frozen_string_literal: true

require_relative "../../test_helper"
require "cyborg/sources/contracts"
require "cyborg/sources/host_request_builder"

class CyborgHostRequestBuilderTest < Minitest::Test
  def setup
    @run = Cyborg::Run.new(
      "run-1", "default", "interactive", "running", "2026-08-12T00:00:00Z",
      "2026-08-13T00:00:00Z", "UTC", "config", "2026-08-12T00:00:00Z", nil,
      nil, 0, "prompt-1", "cheap_structured_extraction", nil
    )
    @registration = Cyborg::Registration.new(
      source_name: "github", adapter_version: "github-2", account_identity: "me@example.com",
      transport: "host_bridge", capabilities: ["notifications"], filters: {"unread_only" => true},
      limits: {"max_pages" => 3, "max_records" => 20, "max_bytes" => 4096},
      credential_strategy: "host_session", health_checks: ["auth"], cursor_policy: "proposed",
      cache_policy: "ordinary", retention_class: "standard", allowed_fields: ["title"],
      operations: {"notifications" => "github.notifications.read"}, parameters: {}, required: true
    )
    @context = Cyborg::RetrievalContext.new(
      source_name: "github", account_identity: "me@example.com", window_start_utc: @run.window_start_utc,
      window_end_utc: @run.window_end_utc, display_timezone: "UTC", prior_cursor: "cursor-1",
      limits: {"max_pages" => 5, "max_records" => 50, "max_bytes" => 8192},
      cache_policy: "ordinary", filters: {}
    )
  end

  def test_call_emits_allowlisted_bounded_requests
    request = Cyborg::HostRequestBuilder.new.call(run: @run, registrations: [@registration], context: @context).fetch(0)

    assert_equal "github.notifications.read", request.operation
    assert_equal 3, request.max_pages
    assert_equal 20, request.max_records
    assert_equal 4096, request.max_response_bytes
    assert_equal "cursor-1", request.prior_cursor
    assert_equal true, request.required
    assert_equal({"unread_only" => true}, request.parameters.fetch("filters"))
  end

  def test_call_rejects_registration_without_an_allowlisted_operation
    registration = @registration.with(operations: {})
    assert_raises(Cyborg::UsageError) do
      Cyborg::HostRequestBuilder.new.call(run: @run, registrations: [registration], context: @context)
    end
  end
end
