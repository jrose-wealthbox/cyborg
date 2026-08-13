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
end
