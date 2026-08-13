# frozen_string_literal: true

require_relative "../../test_helper"
require "cyborg/sources/contracts"
require "cyborg/sources/fixture_adapter"

class CyborgFixtureAdapterTest < Minitest::Test
  FIXTURE = File.expand_path("../../fixtures/sources/fixture-records.json", __dir__)

  def context(max_records: 10, max_bytes: 10_000)
    Cyborg::RetrievalContext.new(
      source_name: "fixture", account_identity: "test", window_start_utc: "2026-08-12T00:00:00Z",
      window_end_utc: "2026-08-13T00:00:00Z", display_timezone: "UTC", prior_cursor: nil,
      limits: {"max_pages" => 1, "max_records" => max_records, "max_bytes" => max_bytes},
      cache_policy: "ordinary", filters: {}
    )
  end

  def test_fetch_normalizes_bounded_local_records
    result = Cyborg::FixtureAdapter.new(path: FIXTURE).fetch(context)

    assert_equal "healthy", result.status
    assert_equal "fresh", result.data_status
    assert_equal 2, result.records.length
    assert_equal "fixture-1", result.records.first.source_record_id
    assert_equal "event_at", result.records.first.timestamp_kind
    assert_equal "fixture-cursor-2", result.next_cursor
  end

  def test_fetch_rejects_payloads_above_record_bound
    error = assert_raises(Cyborg::SourceLimitError) { Cyborg::FixtureAdapter.new(path: FIXTURE).fetch(context(max_records: 1)) }
    assert_equal "source.record_limit_exceeded", error.code
  end

  def test_fetch_rejects_payloads_above_byte_bound
    error = assert_raises(Cyborg::SourceLimitError) { Cyborg::FixtureAdapter.new(path: FIXTURE).fetch(context(max_bytes: 10)) }
    assert_equal "source.response_too_large", error.code
  end
end
