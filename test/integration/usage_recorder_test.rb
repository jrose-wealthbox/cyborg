# frozen_string_literal: true

require_relative "../test_helper"

class CyborgUsageRecorderTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("cyborg-usage-test")
    @db = Cyborg::Database.connect(path: File.join(@tmpdir, "cyborg.sqlite3"))
    @db.migrate!
    @db[:runs].insert(
      id: "run-1", profile: "default", execution_mode: "interactive", status: "running",
      window_start_utc: "2026-08-12T00:00:00Z", window_end_utc: "2026-08-13T00:00:00Z",
      display_timezone: "UTC", configuration_fingerprint: "config", created_at: "2026-08-12T00:00:00Z"
    )
    @recorder = Cyborg::Analysis::UsageRecorder.new(db: @db, now: Time.utc(2026, 8, 13))
  end

  def teardown
    @db.disconnect
    FileUtils.remove_entry(@tmpdir)
  end

  def test_records_parent_and_child_usage_with_certainty
    parent = @recorder.record(
      run_id: "run-1", session_id: "orchestration", reserved_cost_micros: 3_000,
      certainty: "unknown"
    )
    child = @recorder.record(
      run_id: "run-1", task_id: "extract", session_id: "host", parent_session_id: parent.id,
      reserved_cost_micros: 2_000, input_tokens: 10, output_tokens: 4, cost_micros: 1_500,
      certainty: "provider_reported"
    )

    assert_equal parent.id, child.parent_session_id
    assert_equal %w[host orchestration], @db[:usage_records].order(:session_id).select_map(:session_id)
    assert_equal "provider_reported", @recorder.find(child.id).certainty
    assert_equal [child], @recorder.children(parent.id)
  end

  def test_releases_unused_reservation_and_summarizes_uncertain_cost
    row = @recorder.record(
      run_id: "run-1", task_id: "optional", session_id: "optional-session",
      reserved_cost_micros: 4_000, certainty: "reserved"
    )
    @recorder.release(session_id: row.session_id)

    assert_equal 0, @recorder.find(row.id).reserved_cost_micros
    summary = @recorder.summary(run_id: "run-1")
    assert_equal 0, summary.reserved_cost_micros
    assert_equal "unknown", summary.certainty
  end

  def test_rejects_invalid_certainty_and_negative_usage
    assert_raises(ArgumentError) do
      @recorder.record(run_id: "run-1", session_id: "x", certainty: "guess")
    end
    assert_raises(ArgumentError) do
      @recorder.record(run_id: "run-1", session_id: "x", input_tokens: -1)
    end
  end
end
