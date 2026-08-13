# frozen_string_literal: true

require_relative "../test_helper"

class CyborgRepeatedRunTest < Minitest::Test
  def test_one_hundred_repeated_cache_lookups_have_one_validated_entry
    tmpdir = Dir.mktmpdir("cyborg-repeated-run")
    db = Cyborg::Database.connect(path: File.join(tmpdir, "cyborg.sqlite3"))
    db.migrate!
    db[:runs].insert(id: "run-1", profile: "default", execution_mode: "interactive", status: "completed", window_start_utc: "2026-08-13T11:00:00Z", window_end_utc: "2026-08-13T12:00:00Z", display_timezone: "UTC", configuration_fingerprint: "config", created_at: "2026-08-13T11:00:00Z", completed_at: "2026-08-13T12:00:00Z")
    backend_calls = 0
    repository = Cyborg::Repositories::AnalysisRepository.new(db)
    100.times do
      cached = repository.find_cached(task_id: "task-1", input_fingerprint: "packet-fp")
      unless cached
        backend_calls += 1
        repository.create(id: "cached-result", run_id: "run-1", task_id: "task-1", input_fingerprint: "packet-fp",
                          output_fingerprint: "result-fp", validation_status: "valid", result_json: "{}", created_at: "2026-08-13T12:00:00Z")
      end
    end
    assert_equal 1, backend_calls
    assert_equal 1, db[:analysis_results].count
  ensure
    db&.disconnect
    FileUtils.remove_entry(tmpdir) if tmpdir
  end
end
