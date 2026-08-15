# frozen_string_literal: true

require_relative "../../test_helper"
require "cyborg/analysis/bridge_cache"

class CyborgBridgeCacheTest < Minitest::Test
  NOW = Time.utc(2026, 8, 14, 12, 0, 0)

  def setup
    @tmpdir = Dir.mktmpdir("cyborg-bridge-cache")
    @db = Cyborg::Database.connect(path: File.join(@tmpdir, "cyborg.sqlite3"))
    @db.migrate!
    @cache = Cyborg::Analysis::BridgeCache.new(
      db: @db, expensive_ttl_seconds: 14_400
    )
  end

  def teardown
    @db&.disconnect
    FileUtils.remove_entry(@tmpdir) if @tmpdir
  end

  def test_fetch_reuses_only_the_same_run_independent_packet
    packet = packet(run_id: "run-1")
    result = valid_result

    assert @cache.store(packet:, result:, backend_identity: "coding-harness", run_id: "run-1", now: NOW)
    assert_equal result, @cache.fetch(packet:, backend_identity: "coding-harness", now: NOW + 1)
    assert_equal result, @cache.fetch(packet: packet.merge("run_id" => "run-2"), backend_identity: "coding-harness", now: NOW + 1)
    assert_equal result, @cache.fetch(
      packet: packet.merge("run_id" => "run-2", "created_at" => "2026-08-14T12:01:00Z"),
      backend_identity: "coding-harness", now: NOW + 1
    )
  end

  def test_fetch_misses_when_reusable_packet_or_backend_changes
    packet = packet(run_id: "run-1")
    @cache.store(packet:, result: valid_result, backend_identity: "coding-harness", run_id: "run-1", now: NOW)

    {
      "records" => packet.merge("records" => [packet.fetch("records").first.merge("content_fingerprint" => "changed")]),
      "evidence" => packet.merge("records" => [packet.fetch("records").first.merge("evidence_ids" => ["e2"])]),
      "tasks" => packet.merge("tasks" => [packet.fetch("tasks").first.merge("id" => "task-2")]),
      "action state" => packet.merge("action_state_version" => 2),
      "prompt version" => packet.merge("prompt_version" => "prompt-2"),
      "configuration version" => packet.merge("configuration_version" => "config-2")
    }.each do |label, changed_packet|
      assert_nil @cache.fetch(packet: changed_packet, backend_identity: "coding-harness", now: NOW + 1), label
    end
    assert_nil @cache.fetch(packet:, backend_identity: "other-backend", now: NOW + 1)
  end

  def test_expired_and_invalidated_entries_miss
    packet = packet(run_id: "run-1")
    @cache.store(packet:, result: valid_result, backend_identity: "coding-harness", run_id: "run-1", now: NOW)
    assert_nil @cache.fetch(packet:, backend_identity: "coding-harness", now: NOW + 14_400)

    @cache.store(packet:, result: valid_result, backend_identity: "coding-harness", run_id: "run-1", now: NOW)
    @db[:cache_entries].update(invalidated_at: (NOW + 1).iso8601)
    assert_nil @cache.fetch(packet:, backend_identity: "coding-harness", now: NOW + 2)
  end

  def test_corrupt_payload_misses_without_exposing_or_reusing_it
    packet = packet(run_id: "run-1")
    @cache.store(packet:, result: valid_result, backend_identity: "coding-harness", run_id: "run-1", now: NOW)
    @db[:cache_entries].update(payload_json: "not-json")

    assert_nil @cache.fetch(packet:, backend_identity: "coding-harness", now: NOW + 1)
  end

  def test_cached_payload_contains_only_bounded_result_data
    packet = packet(run_id: "run-1")
    result = valid_result.merge("task_results" => [{"task_id" => "task-1", "status" => "succeeded"}])
    @cache.store(packet:, result:, backend_identity: "coding-harness", run_id: "run-1", now: NOW)

    row = @db[:cache_entries].first
    payload = JSON.parse(row.fetch(:payload_json))
    assert_equal result, payload
    refute_includes row.fetch(:payload_json), "lease"
    refute_includes row.fetch(:payload_json), "retrieval"
  end

  private

  def packet(run_id:)
    {
      "packet_version" => "1.0", "run_id" => run_id, "prompt_version" => "prompt-1",
      "configuration_version" => "config-1",
      "versions" => {"packet" => "1.0", "prompt" => "prompt-1", "configuration" => "config-1", "task" => "1.0"},
      "records" => [{"source_record_id" => "record-1", "content_fingerprint" => "record-fp", "evidence_ids" => ["e1"]}],
      "tasks" => [{"id" => "task-1", "capability" => "cheap_structured_extraction"}],
      "action_state_version" => 1, "lease" => "must-not-be-cached"
    }
  end

  def valid_result
    {"claims" => [], "usage" => {}, "task_results" => [], "backend_metadata" => {}}
  end
end
