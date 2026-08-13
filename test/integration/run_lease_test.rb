# frozen_string_literal: true

require_relative "../test_helper"

class CyborgRunLeaseTest < Minitest::Test
  NOW = Time.utc(2026, 8, 13, 12, 0, 0)

  def setup
    @tmpdir = Dir.mktmpdir("cyborg-run-lease-test")
    @database_path = File.join(@tmpdir, "cyborg.sqlite3")
    @lock_file = File.join(@tmpdir, "state.lock")
    @lease_one = File.join(@tmpdir, "lease-one.token")
    @lease_two = File.join(@tmpdir, "lease-two.token")
    @db = Cyborg::Database.connect(path: @database_path)
    @db.migrate!
    @clock = Cyborg::FrozenClock.new(NOW)
    @manager = Cyborg::Runs::LeaseManager.new(
      @db,
      clock: @clock,
      lease_timeout_seconds: 60,
      lock_file: @lock_file
    )
    insert_run("run-1")
    insert_run("run-2")
  end

  def teardown
    @db.disconnect
    FileUtils.remove_entry(@tmpdir)
  end

  def test_second_active_lease_is_rejected
    @manager.acquire(run_id: "run-1", lease_file: @lease_one)

    error = assert_raises(Cyborg::LeaseBusy) do
      @manager.acquire(run_id: "run-2", lease_file: @lease_two)
    end

    assert_equal 75, error.exit_status
    assert File.exist?(@lease_one)
    refute File.exist?(@lease_two)
  end

  def test_lease_file_is_mode_0600_and_database_contains_only_fingerprint
    lease = @manager.acquire(run_id: "run-1", lease_file: @lease_one)
    token = File.read(@lease_one).chomp
    row = @db[:run_leases].first

    assert_equal lease.expires_at, Time.iso8601(row.fetch(:expires_at))
    assert_equal 0o600, File.stat(@lease_one).mode & 0o777
    assert_equal 64, token.length
    assert_match(/\A[0-9a-f]{64}\z/, token)
    assert_equal Digest::SHA256.hexdigest(token), row.fetch(:token_fingerprint)
    refute_includes row.values.join(" "), token
  end

  def test_wrong_token_cannot_mutate_run
    @manager.acquire(run_id: "run-1", lease_file: @lease_one)
    File.chmod(0o600, @lease_one)
    File.write(@lease_one, "wrong-token\n")

    assert_raises(Cyborg::InvalidArtifact) do
      @manager.verify!(run_id: "run-1", lease_file: @lease_one)
    end
  end

  def test_renewal_updates_heartbeat_and_expiry
    lease = @manager.acquire(run_id: "run-1", lease_file: @lease_one)
    renewed_clock = Cyborg::FrozenClock.new(NOW + 30)
    manager = Cyborg::Runs::LeaseManager.new(
      @db,
      clock: renewed_clock,
      lease_timeout_seconds: 60,
      lock_file: @lock_file
    )

    renewed = manager.renew!(run_id: "run-1", lease_file: @lease_one)
    row = @db[:run_leases].first

    assert_equal NOW + 30, renewed.heartbeat_at
    assert_equal NOW + 90, renewed.expires_at
    assert_equal NOW + 30, Time.iso8601(row.fetch(:heartbeat_at))
    assert_equal NOW + 90, Time.iso8601(row.fetch(:expires_at))
    assert_operator renewed.expires_at, :>, lease.expires_at
  end

  def test_release_deletes_database_lease_and_token_file
    @manager.acquire(run_id: "run-1", lease_file: @lease_one)

    @manager.release!(run_id: "run-1", lease_file: @lease_one)

    assert_empty @db[:run_leases].all
    refute File.exist?(@lease_one)
  end

  def test_expired_lease_fails_old_run_before_reacquisition
    @manager.acquire(run_id: "run-1", lease_file: @lease_one)
    expired_manager = Cyborg::Runs::LeaseManager.new(
      @db,
      clock: Cyborg::FrozenClock.new(NOW + 61),
      lease_timeout_seconds: 60,
      lock_file: @lock_file
    )

    expired_manager.acquire(run_id: "run-2", lease_file: @lease_two)

    old_run = @db[:runs].where(id: "run-1").first
    assert_equal "failed", old_run.fetch(:status)
    metadata = JSON.parse(old_run.fetch(:usage_summary_json))
    assert_equal "run.lease_expired", metadata.fetch("error_code")
    assert_empty @db[:run_leases].where(run_id: "run-1").all
    assert_equal "run-2", @db[:run_leases].get(:run_id)
  end

  def test_competing_database_connections_allow_only_one_active_lease
    db_one = Cyborg::Database.connect(path: @database_path)
    db_two = Cyborg::Database.connect(path: @database_path)
    manager_one = Cyborg::Runs::LeaseManager.new(db_one, clock: @clock, lock_file: @lock_file)
    manager_two = Cyborg::Runs::LeaseManager.new(db_two, clock: @clock, lock_file: @lock_file)
    results = Queue.new

    threads = [
      Thread.new do
        begin
          manager_one.acquire(run_id: "run-1", lease_file: @lease_one)
          results << :acquired
        rescue Cyborg::LeaseBusy
          results << :busy
        end
      end,
      Thread.new do
        begin
          manager_two.acquire(run_id: "run-2", lease_file: @lease_two)
          results << :acquired
        rescue Cyborg::LeaseBusy
          results << :busy
        end
      end
    ]
    threads.each(&:join)

    assert_equal [:acquired, :busy], [results.pop, results.pop].sort_by(&:to_s)
    assert_equal 1, @db[:run_leases].count
  ensure
    db_one&.disconnect
    db_two&.disconnect
  end

  private

  def insert_run(id)
    @db[:runs].insert(
      id:, profile: "default", execution_mode: "interactive", status: "running",
      window_start_utc: NOW.iso8601, window_end_utc: (NOW + 3600).iso8601,
      display_timezone: "UTC", configuration_fingerprint: "fingerprint",
      created_at: NOW.iso8601
    )
  end
end
