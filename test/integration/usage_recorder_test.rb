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

  def test_releases_reservation_when_provider_usage_becomes_known
    row = @recorder.record(
      run_id: "run-1", task_id: "extract", session_id: "extract-session",
      reserved_cost_micros: 4_000, certainty: "reserved"
    )

    updated = @recorder.update(
      session_id: row.session_id, input_tokens: 10, output_tokens: 4,
      cost_micros: 1_500, certainty: "provider_reported"
    )

    assert_equal 0, updated.reserved_cost_micros
    summary = @recorder.summary(run_id: "run-1")
    assert_equal 0, summary.reserved_cost_micros
    assert_equal 1_500, summary.provider_reported_cost_micros
    assert_equal 0, summary.locally_estimated_cost_micros
    assert_equal 0, summary.unknown_cost_micros
  end

  def test_separates_estimated_and_unknown_costs
    @recorder.record(
      run_id: "run-1", session_id: "provider", cost_micros: 1_500,
      certainty: "provider_reported"
    )
    @recorder.record(
      run_id: "run-1", session_id: "estimated", cost_micros: 700,
      certainty: "locally_estimated"
    )
    @recorder.record(
      run_id: "run-1", session_id: "unknown", cost_micros: 300,
      certainty: "unknown"
    )

    summary = @recorder.summary(run_id: "run-1")

    assert_equal 1_500, summary.provider_reported_cost_micros
    assert_equal 700, summary.locally_estimated_cost_micros
    assert_equal 300, summary.unknown_cost_micros
    assert_equal 1_500, summary.reported_cost_micros
    assert_equal "unknown", summary.certainty
  end

  def test_rejects_provider_reported_usage_without_known_cost
    assert_raises(ArgumentError) do
      @recorder.record(run_id: "run-1", session_id: "provider", certainty: "provider_reported")
    end
  end

  def test_rejects_reserved_certainty_with_actual_usage
    assert_raises(ArgumentError) do
      Cyborg::Analysis::UsageRecord.new(
        id: "known-cost", run_id: "run-1", reserved_cost_micros: 0,
        cost_micros: 1_500, certainty: "reserved", created_at: @recorder.now
      )
    end

    assert_raises(ArgumentError) do
      Cyborg::Analysis::UsageRecord.new(
        id: "known-tokens", run_id: "run-1", reserved_cost_micros: 0,
        input_tokens: 10, certainty: "reserved", created_at: @recorder.now
      )
    end
  end

  def test_update_requires_explicit_certainty_when_usage_arrives
    row = @recorder.record(
      run_id: "run-1", session_id: "pending-session",
      reserved_cost_micros: 4_000, certainty: "reserved"
    )

    assert_raises(ArgumentError) do
      @recorder.update(session_id: row.session_id, cost_micros: 1_500)
    end
    unchanged = @recorder.find(row.id)
    assert_nil unchanged.cost_micros
    assert_equal 4_000, unchanged.reserved_cost_micros
    assert_equal "reserved", unchanged.certainty

    updated = @recorder.update(
      session_id: row.session_id, cost_micros: 1_500,
      certainty: "provider_reported"
    )
    assert_equal 1_500, updated.cost_micros
    assert_equal 0, updated.reserved_cost_micros
    assert_equal 1_500, @recorder.summary(run_id: "run-1").provider_reported_cost_micros
  end

  def test_rejects_parent_session_from_another_run
    @db[:runs].insert(
      id: "run-2", profile: "default", execution_mode: "interactive", status: "running",
      window_start_utc: "2026-08-12T00:00:00Z", window_end_utc: "2026-08-13T00:00:00Z",
      display_timezone: "UTC", configuration_fingerprint: "config", created_at: "2026-08-12T00:00:00Z"
    )
    parent = @recorder.record(run_id: "run-1", session_id: "parent")

    assert_raises(ArgumentError) do
      @recorder.record(run_id: "run-2", session_id: "child", parent_session_id: parent.id)
    end
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
