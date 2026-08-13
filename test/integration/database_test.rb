# frozen_string_literal: true

require_relative "../test_helper"

class CyborgDatabaseTest < Minitest::Test
  TABLES = %i[
    runs run_leases source_snapshots source_baselines observed_records
    observed_record_versions snapshot_records evidence action_series inferred_actions
    action_key_aliases action_evidence action_transitions action_successors analysis_results
    presentation_results cache_entries usage_records application_state
  ].freeze

  def setup
    @tmpdir = Dir.mktmpdir("cyborg-database-test")
    @path = File.join(@tmpdir, "cyborg.sqlite3")
    @db = Cyborg::Database.connect(path: @path)
    @db.migrate!
  end

  def teardown
    @db.disconnect
    FileUtils.remove_entry(@tmpdir)
  end

  def test_database_enforces_foreign_keys_wal_and_bounded_busy_timeout
    assert_equal 1, @db.get(Sequel.lit("PRAGMA foreign_keys"))
    assert_equal "wal", @db.get(Sequel.lit("PRAGMA journal_mode")).downcase
    timeout = @db.get(Sequel.lit("PRAGMA busy_timeout")).to_i
    assert_operator timeout, :>, 0
    assert_operator timeout, :<=, 30_000
  end

  def test_schema_contains_every_v1_table
    assert_empty TABLES - @db.tables
  end

  def test_schema_uses_strict_tables_when_sqlite_supports_them
    sql = @db.fetch(Sequel.lit("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'runs'")).get(:sql)
    assert_match(/\bSTRICT\s*\z/i, sql)
  end

  def test_run_lease_is_a_singleton_and_foreign_keys_are_enforced
    @db[:runs].insert(id: "run-1", profile: "default", execution_mode: "interactive", status: "running",
      window_start_utc: "2026-08-12T00:00:00Z", window_end_utc: "2026-08-13T00:00:00Z",
      display_timezone: "America/New_York", configuration_fingerprint: "a", created_at: "2026-08-12T00:00:00Z")
    @db[:run_leases].insert(id: 1, run_id: "run-1", token_fingerprint: "a", created_at: "2026-08-12T00:00:00Z",
      heartbeat_at: "2026-08-12T00:00:00Z", expires_at: "2026-08-12T00:10:00Z")
    assert_raises(Sequel::UniqueConstraintViolation) do
      @db[:run_leases].insert(id: 1, run_id: "run-1", token_fingerprint: "b", created_at: "2026-08-12T00:00:00Z",
        heartbeat_at: "2026-08-12T00:00:00Z", expires_at: "2026-08-12T00:10:00Z")
    end
    @db[:run_leases].delete
    assert_raises(Sequel::ForeignKeyConstraintViolation) do
      @db[:run_leases].insert(id: 1, run_id: "missing", token_fingerprint: "b", created_at: "2026-08-12T00:00:00Z",
        heartbeat_at: "2026-08-12T00:00:00Z", expires_at: "2026-08-12T00:10:00Z")
    end
  end

  def test_source_baseline_and_snapshot_identity_are_unique
    insert_run("run-1")
    snapshot = {
      id: "snapshot-1", run_id: "run-1", source_name: "github", account_identity: "me@example.com",
      adapter_version: "1", started_at: "2026-08-12T00:00:00Z", completed_at: "2026-08-12T00:01:00Z",
      status: "healthy", data_status: "fresh", cursor_disposition: "advance", record_count: 0
    }
    @db[:source_snapshots].insert(snapshot)
    assert_raises(Sequel::UniqueConstraintViolation) { @db[:source_snapshots].insert(snapshot.merge(id: "snapshot-2")) }
    @db[:source_baselines].insert(source_name: "github", account_identity: "me@example.com",
      activated_snapshot_id: "snapshot-1", activated_at: "2026-08-12T00:01:00Z")
    assert_raises(Sequel::UniqueConstraintViolation) do
      @db[:source_baselines].insert(source_name: "github", account_identity: "me@example.com",
        activated_snapshot_id: "snapshot-1", activated_at: "2026-08-12T00:01:00Z")
    end
  end

  def test_record_version_series_alias_and_action_evidence_identities_are_unique
    insert_run("run-1")
    insert_source_snapshot
    @db[:observed_records].insert(id: "record-1", source_name: "github", account_identity: "me@example.com",
      source_record_id: "42", record_kind: "notification", event_at: "2026-08-12T00:00:00Z",
      observed_at: "2026-08-12T00:01:00Z", timestamp_kind: "event_at", content_fingerprint: "fp",
      first_seen_at: "2026-08-12T00:01:00Z", last_observed_at: "2026-08-12T00:01:00Z")
    @db[:observed_record_versions].insert(id: "version-1", observed_record_id: "record-1", content_fingerprint: "fp",
      payload_json: "{}", created_at: "2026-08-12T00:01:00Z")
    assert_raises(Sequel::UniqueConstraintViolation) do
      @db[:observed_record_versions].insert(id: "version-2", observed_record_id: "record-1", content_fingerprint: "fp",
        payload_json: "{}", created_at: "2026-08-12T00:01:00Z")
    end
    @db[:snapshot_records].insert(snapshot_id: "snapshot-1", record_version_id: "version-1")
    @db[:evidence].insert(id: "evidence-1", observed_record_version_id: "version-1", source_url: "https://github.com/x/y/42",
      source_label: "GitHub", excerpt: "review", evidence_at: "2026-08-12T00:00:00Z", relation: "supports")
    @db[:action_series].insert(id: "series-1", current_subject_key: "subject", identity_version: 1,
      action_kind: "respond", canonical_subject_type: "github_pr", canonical_subject_id: "42",
      created_at: "2026-08-12T00:01:00Z", updated_at: "2026-08-12T00:01:00Z")
    @db[:inferred_actions].insert(id: "action-1", series_id: "series-1", occurrence_number: 1,
      inference_status: "active", action_kind: "respond", summary: "Reply", confidence: 0.9,
      user_state: "open", state_version: 0, first_seen_at: "2026-08-12T00:01:00Z",
      last_seen_at: "2026-08-12T00:01:00Z")
    assert_raises(Sequel::UniqueConstraintViolation) do
      @db[:inferred_actions].insert(id: "action-2", series_id: "series-1", occurrence_number: 1,
        inference_status: "active", action_kind: "respond", summary: "Reply", confidence: 0.9,
        user_state: "open", state_version: 0, first_seen_at: "2026-08-12T00:01:00Z",
        last_seen_at: "2026-08-12T00:01:00Z")
    end
    @db[:action_key_aliases].insert(subject_key: "old-subject", series_id: "series-1", identity_version: 1,
      created_at: "2026-08-12T00:01:00Z")
    assert_raises(Sequel::UniqueConstraintViolation) do
      @db[:action_key_aliases].insert(subject_key: "old-subject", series_id: "series-1", identity_version: 1,
        created_at: "2026-08-12T00:01:00Z")
    end
    @db[:action_evidence].insert(action_id: "action-1", evidence_id: "evidence-1",
      first_seen_run_id: "run-1", last_seen_run_id: "run-1", first_seen_at: "2026-08-12T00:01:00Z",
      last_seen_at: "2026-08-12T00:01:00Z")
    assert_raises(Sequel::UniqueConstraintViolation) do
      @db[:action_evidence].insert(action_id: "action-1", evidence_id: "evidence-1",
        first_seen_run_id: "run-1", last_seen_run_id: "run-1", first_seen_at: "2026-08-12T00:01:00Z",
        last_seen_at: "2026-08-12T00:01:00Z")
    end
  end

  def test_one_presentation_per_run_and_profile
    insert_run("run-1")
    @db[:presentation_results].insert(id: "presentation-1", run_id: "run-1", profile: "default",
      view_model_json: "{}", created_at: "2026-08-12T00:01:00Z")
    assert_raises(Sequel::UniqueConstraintViolation) do
      @db[:presentation_results].insert(id: "presentation-2", run_id: "run-1", profile: "default",
        view_model_json: "{}", created_at: "2026-08-12T00:01:00Z")
    end
  end

  def test_domain_values_are_immutable
    value = Cyborg::Run.new("run-1", "default", "interactive", "running", "start", "end", "UTC", "fp", "created", nil, nil, 0, nil, nil, nil)
    assert_predicate value, :frozen?
  end

  private

  def insert_run(id)
    @db[:runs].insert(id:, profile: "default", execution_mode: "interactive", status: "running",
      window_start_utc: "2026-08-12T00:00:00Z", window_end_utc: "2026-08-13T00:00:00Z",
      display_timezone: "America/New_York", configuration_fingerprint: "a", created_at: "2026-08-12T00:00:00Z")
  end

  def insert_source_snapshot
    @db[:source_snapshots].insert(id: "snapshot-1", run_id: "run-1", source_name: "github",
      account_identity: "me@example.com", adapter_version: "1", started_at: "2026-08-12T00:00:00Z",
      completed_at: "2026-08-12T00:01:00Z", status: "healthy", data_status: "fresh",
      cursor_disposition: "advance", record_count: 0)
  end
end
