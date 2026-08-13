# frozen_string_literal: true

require_relative "../test_helper"

class CyborgRunLifecycleTest < Minitest::Test
  NOW = Time.utc(2026, 8, 13, 12, 0, 0)

  def setup
    @tmpdir = Dir.mktmpdir("cyborg-run-lifecycle-test")
    @database_path = File.join(@tmpdir, "cyborg.sqlite3")
    @lock_file = File.join(@tmpdir, "state.lock")
    @lease_file = File.join(@tmpdir, "lease.token")
    @db = Cyborg::Database.connect(path: @database_path)
    @db.migrate!
    @clock = Cyborg::FrozenClock.new(NOW)
    @lifecycle = Cyborg::Runs::RunLifecycle.new(
      @db,
      clock: @clock,
      lease_timeout_seconds: 60,
      lease_file: @lease_file,
      lock_file: @lock_file
    )
  end

  def teardown
    @db.disconnect
    FileUtils.remove_entry(@tmpdir)
  end

  def test_start_persists_running_run_and_lease_without_plaintext_token
    run = @lifecycle.start(
      profile: "default", execution_mode: "interactive", window: window,
      configuration_fingerprint: "configuration-fingerprint", prompt_version: "prompt-1",
      backend_capability: "fixture"
    )

    assert_equal "running", run.status
    assert_equal "default", run.profile
    assert_equal "interactive", run.execution_mode
    assert_equal "configuration-fingerprint", run.configuration_fingerprint
    assert_equal "prompt-1", run.prompt_version
    assert_equal "fixture", run.backend_capability
    assert_equal 1, @db[:runs].count
    assert_equal 1, @db[:run_leases].count
    token = File.read(@lease_file).chomp
    refute_includes @db[:run_leases].first.values.join(" "), token
  end

  def test_abandonment_marks_run_failed_releases_lease_and_does_not_publish
    run = start_run

    abandoned = @lifecycle.abandon(run_id: run.id, reason: "user cancelled")

    assert_equal "failed", abandoned.status
    assert_equal "failed", @db[:runs].where(id: run.id).get(:status)
    metadata = JSON.parse(@db[:runs].where(id: run.id).get(:usage_summary_json))
    assert_equal "run.abandoned", metadata.fetch("error_code")
    assert_equal "user cancelled", metadata.fetch("reason")
    assert_empty @db[:run_leases].all
    refute File.exist?(@lease_file)
    assert_nil @db[:application_state].where(key: "latest_renderable_run_id").first
    assert_empty @db[:presentation_results].where(run_id: run.id).all
    assert_empty @db[:source_baselines].all
  end

  def test_abandonment_does_not_store_lease_token_in_metadata
    run = start_run
    token = File.read(@lease_file).chomp

    @lifecycle.abandon(run_id: run.id, reason: "cancel #{token}")

    refute_includes @db[:runs].where(id: run.id).get(:usage_summary_json), token
  end

  def test_expired_lease_is_failed_before_new_run_starts
    old_run = start_run
    expired = Cyborg::Runs::RunLifecycle.new(
      @db,
      clock: Cyborg::FrozenClock.new(NOW + 61),
      lease_timeout_seconds: 60,
      lease_file: File.join(@tmpdir, "new-lease.token"),
      lock_file: @lock_file
    )

    new_run = expired.start(
      profile: "default", execution_mode: "interactive", window: window,
      configuration_fingerprint: "configuration-fingerprint", prompt_version: "prompt-1",
      backend_capability: "fixture"
    )

    assert_equal "failed", @db[:runs].where(id: old_run.id).get(:status)
    assert_equal "run.lease_expired", JSON.parse(@db[:runs].where(id: old_run.id).get(:usage_summary_json)).fetch("error_code")
    assert_equal "running", new_run.status
  end

  private

  def start_run
    @lifecycle.start(
      profile: "default", execution_mode: "interactive", window: window,
      configuration_fingerprint: "configuration-fingerprint", prompt_version: "prompt-1",
      backend_capability: "fixture"
    )
  end

  def window
    Cyborg::TimeWindow.new(NOW - 86_400, NOW + 86_399, "UTC")
  end
end
