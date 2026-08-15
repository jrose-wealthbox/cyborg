# frozen_string_literal: true

require_relative "../test_helper"

class CyborgRepeatedRunTest < Minitest::Test
  def test_one_hundred_repeated_cache_lookups_have_one_validated_entry
    tmpdir = Dir.mktmpdir("cyborg-repeated-run")
    db = Cyborg::Database.connect(path: File.join(tmpdir, "cyborg.sqlite3"))
    db.migrate!
    task = Cyborg::Analysis::AnalysisTask.new(
      id: "task-1", capability: "cheap_structured_extraction", dependency_ids: [], required: true,
      packet_fingerprint: "packet-fp", maximum_output_bytes: 8192,
      reservation: Cyborg::Analysis::Reservation.new(cost_micros: 1)
    )
    backend = Class.new do
      attr_reader :calls
      def initialize(path)
        @backend = Cyborg::Analysis::FixtureBackend.new(path:)
        @calls = 0
      end
      def analyze(**kwargs)
        @calls += 1
        @backend.analyze(**kwargs)
      end
    end.new(File.expand_path("../fixtures/e2e/analysis-result.json", __dir__))
    orchestrator = Cyborg::Analysis::Orchestrator.new(db:, now: Time.iso8601("2026-08-13T12:00:00Z"))
    100.times do |index|
      run_id = "run-#{index + 1}"
      db[:runs].insert(id: run_id, profile: "default", execution_mode: "interactive", status: "completed", window_start_utc: "2026-08-13T11:00:00Z", window_end_utc: "2026-08-13T12:00:00Z", display_timezone: "UTC", configuration_fingerprint: "config", created_at: "2026-08-13T11:00:00Z", completed_at: "2026-08-13T12:00:00Z")
      task_payload = task.to_h.transform_keys(&:to_s).merge("reservation" => task.reservation.to_h.transform_keys(&:to_s))
      packet = {"run_id" => run_id, "records" => [], "tasks" => [task_payload], "allowed_action_kinds" => ["review"],
                "maximum_claim_count" => 25, "maximum_output_bytes" => 8_192}
      orchestrator.execute(run_id:, packet:, tasks: [task], backend:, ceiling_micros: 2)
    end
    assert_equal 1, backend.calls
    assert_equal 1, db[:analysis_results].count
    assert_equal 100, db[:usage_records].where(task_id: task.id).count
    assert_equal 100, db[:usage_records].where(task_id: task.id).count
  ensure
    db&.disconnect
    FileUtils.remove_entry(tmpdir) if tmpdir
  end

  def test_one_hundred_bridge_packet_lookups_keep_one_expensive_entry
    tmpdir = Dir.mktmpdir("cyborg-bridge-repeated-run")
    db = Cyborg::Database.connect(path: File.join(tmpdir, "cyborg.sqlite3"))
    db.migrate!
    cache = Cyborg::Analysis::BridgeCache.new(db:, expensive_ttl_seconds: 14_400)
    packet = {
      "packet_version" => "1.0", "run_id" => "run-1", "prompt_version" => "prompt-1",
      "configuration_version" => "config-1",
      "versions" => {"packet" => "1.0", "prompt" => "prompt-1", "configuration" => "config-1", "task" => "1.0"},
      "records" => [], "tasks" => [], "allowed_action_kinds" => ["review"],
      "maximum_claim_count" => 25, "maximum_output_bytes" => 8_192, "action_state_version" => 0
    }
    result = {"claims" => [], "usage" => {}, "task_results" => [], "backend_metadata" => {}}
    cache.store(packet:, result:, backend_identity: "coding-harness", run_id: "run-1", now: Time.utc(2026, 8, 14, 12))

    100.times do |index|
      assert_equal result, cache.fetch(
        packet: packet.merge("run_id" => "run-#{index + 2}"), backend_identity: "coding-harness",
        now: Time.utc(2026, 8, 14, 12, 1)
      )
    end
    assert_equal 1, db[:cache_entries].where(stage: "bridge_analysis").count
  ensure
    db&.disconnect
    FileUtils.remove_entry(tmpdir) if tmpdir
  end
end
