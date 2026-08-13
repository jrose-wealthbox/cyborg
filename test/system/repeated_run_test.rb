# frozen_string_literal: true

require_relative "../test_helper"

class CyborgRepeatedRunTest < Minitest::Test
  def test_one_hundred_repeated_cache_lookups_have_one_validated_entry
    tmpdir = Dir.mktmpdir("cyborg-repeated-run")
    db = Cyborg::Database.connect(path: File.join(tmpdir, "cyborg.sqlite3"))
    db.migrate!
    db[:runs].insert(id: "run-1", profile: "default", execution_mode: "interactive", status: "completed", window_start_utc: "2026-08-13T11:00:00Z", window_end_utc: "2026-08-13T12:00:00Z", display_timezone: "UTC", configuration_fingerprint: "config", created_at: "2026-08-13T11:00:00Z", completed_at: "2026-08-13T12:00:00Z")
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
    repository = Cyborg::Repositories::AnalysisRepository.new(db)
    100.times do
      cached = repository.find_cached(task_id: task.id, input_fingerprint: task.packet_fingerprint)
      unless cached
        outcome = backend.analyze(packet: {"run_id" => "run-1"}, task:, reservation: task.reservation)
        repository.create(id: "cached-result", run_id: "run-1", task_id: task.id, input_fingerprint: task.packet_fingerprint,
                          output_fingerprint: Cyborg::Bridge::CanonicalJSON.sha256(outcome.to_h), validation_status: "valid",
                          result_json: Cyborg::Bridge::CanonicalJSON.dump(outcome.to_h), created_at: "2026-08-13T12:00:00Z")
      end
    end
    assert_equal 1, backend.calls
    assert_equal 1, db[:analysis_results].count
  ensure
    db&.disconnect
    FileUtils.remove_entry(tmpdir) if tmpdir
  end
end
