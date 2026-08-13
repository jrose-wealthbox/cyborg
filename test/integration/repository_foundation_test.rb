# frozen_string_literal: true

require_relative "../test_helper"

class CyborgRepositoryFoundationTest < Minitest::Test
  NOW = "2026-08-12T00:00:00Z"
  LATER = "2026-08-12T00:01:00Z"

  def setup
    @tmpdir = Dir.mktmpdir("cyborg-repository-test")
    @db = Cyborg::Database.connect(path: File.join(@tmpdir, "cyborg.sqlite3"))
    @db.migrate!
    @runs = Cyborg::Repositories::RunRepository.new(@db)
    @records = Cyborg::Repositories::RecordRepository.new(@db)
    @cache = Cyborg::Repositories::CacheRepository.new(@db)
    @actions = Cyborg::Repositories::ActionRepository.new(@db)
    insert_run("run-1", status: "completed")
    insert_source_snapshot
  end

  def teardown
    @db.disconnect
    FileUtils.remove_entry(@tmpdir)
  end

  def test_record_upsert_preserves_permanent_id_and_first_seen_timestamp
    @records.create_or_update_record(record_attributes(id: "record-1", summary: "old"))

    updated = @records.create_or_update_record(
      record_attributes(id: "record-2", summary: "new", first_seen_at: LATER, last_observed_at: LATER)
    )

    assert_equal "record-1", updated.id
    assert_equal NOW, updated.first_seen_at
    assert_equal "new", updated.summary
    assert_equal 1, @db[:observed_records].count
  end

  def test_record_version_upsert_is_idempotent_for_record_and_fingerprint
    @records.create_or_update_record(record_attributes(id: "record-1"))

    first = @records.create_version(
      id: "version-1", observed_record_id: "record-1", content_fingerprint: "fingerprint",
      payload_json: '{"summary":"first"}', created_at: NOW
    )
    second = @records.create_version(
      id: "version-2", observed_record_id: "record-1", content_fingerprint: "fingerprint",
      payload_json: '{"summary":"second"}', created_at: LATER
    )

    assert_equal "version-1", first.id
    assert_equal first.id, second.id
    assert_equal '{"summary":"first"}', @db[:observed_record_versions].get(:payload_json)
    assert_equal 1, @db[:observed_record_versions].count
  end

  def test_cache_invalidation_persists_timestamp_command_run_and_reason
    @cache.store(
      id: "cache-1", stage: "analysis", cache_key: "key-1", cache_class: "ordinary",
      input_fingerprint: "input", created_at: NOW, expires_at: LATER, payload: {"ok" => true}
    )

    @cache.invalidate(
      stage: "analysis", cache_key: "key-1", invalidated_at: LATER,
      command: "cyborg-no-cache", run_id: "run-1", reason: "user_requested"
    )

    row = @db[:cache_entries].first
    assert_equal LATER, row.fetch(:invalidated_at)
    assert_equal "cyborg-no-cache", row.fetch(:invalidation_command)
    assert_equal "run-1", row.fetch(:invalidation_run_id)
    assert_equal "user_requested", row.fetch(:invalidation_reason)
  end

  def test_cache_invalidation_rejects_noncanonical_timestamp
    assert_raises(Cyborg::PersistenceError) do
      @cache.invalidate(
        stage: "analysis", cache_key: "missing", invalidated_at: "2026-08-12T00:00:00-04:00",
        command: "cyborg-no-cache", reason: "user_requested"
      )
    end
  end

  def test_latest_renderable_rejects_running_and_failed_runs
    insert_run("running", status: "running")
    insert_run("failed", status: "failed")

    assert_raises(Cyborg::PersistenceError) do
      @runs.set_latest_renderable!(run_id: "running", updated_at: NOW)
    end
    assert_raises(Cyborg::PersistenceError) do
      @runs.set_latest_renderable!(run_id: "failed", updated_at: NOW)
    end
    assert_nil @runs.latest_renderable_id
  end

  def test_repository_timestamp_inputs_require_canonical_utc_z_strings
    assert_raises(Cyborg::PersistenceError) do
      @runs.set_latest_renderable!(run_id: "run-1", updated_at: "2026-08-11T20:00:00-04:00")
    end
    assert_raises(Cyborg::PersistenceError) do
      @cache.store(
        id: "cache-2", stage: "analysis", cache_key: "key-2", cache_class: "ordinary",
        input_fingerprint: "input", created_at: "2026-08-12T00:00:00+00:00", expires_at: LATER,
        payload: {"ok" => true}
      )
    end
  end

  def test_action_successor_foreign_keys_are_enforced
    assert_raises(Sequel::ForeignKeyConstraintViolation) do
      @db[:action_successors].insert(
        predecessor_action_id: "missing", successor_action_id: "also-missing", created_at: NOW
      )
    end
  end

  def test_action_alias_rejects_noncanonical_created_at
    insert_action_fixture
    assert_raises(Cyborg::PersistenceError) do
      @actions.add_alias(
        subject_key: "legacy-subject", series_id: "series-1", identity_version: 1,
        created_at: "2026-08-11T20:00:00-04:00"
      )
    end
  end

  def test_action_evidence_rejects_noncanonical_first_seen_at
    insert_action_fixture
    assert_raises(Cyborg::PersistenceError) do
      @actions.attach_evidence(
        action_id: "action-1", evidence_id: "evidence-1",
        attributes: {
          first_seen_run_id: "run-1", last_seen_run_id: "run-1",
          first_seen_at: "2026-08-11T20:00:00-04:00", last_seen_at: LATER
        }
      )
    end
  end

  def test_action_evidence_rejects_noncanonical_last_seen_at
    insert_action_fixture
    assert_raises(Cyborg::PersistenceError) do
      @actions.attach_evidence(
        action_id: "action-1", evidence_id: "evidence-1",
        attributes: {
          first_seen_run_id: "run-1", last_seen_run_id: "run-1",
          first_seen_at: NOW, last_seen_at: "2026-08-11T20:00:00-04:00"
        }
      )
    end
  end

  private

  def insert_run(id, status: "running")
    @db[:runs].insert(
      id:, profile: "default", execution_mode: "interactive", status:,
      window_start_utc: NOW, window_end_utc: LATER, display_timezone: "UTC",
      configuration_fingerprint: "configuration", created_at: NOW
    )
  end

  def insert_source_snapshot
    @db[:source_snapshots].insert(
      id: "snapshot-1", run_id: "run-1", source_name: "github", account_identity: "me@example.com",
      adapter_version: "1", started_at: NOW, completed_at: LATER, status: "healthy",
      data_status: "fresh", cursor_disposition: "advance", record_count: 0
    )
  end

  def insert_action_fixture
    @records.create_or_update_record(record_attributes(id: "record-1"))
    @records.create_version(
      id: "version-1", observed_record_id: "record-1", content_fingerprint: "evidence-fingerprint",
      payload_json: "{}", created_at: NOW
    )
    @records.create_evidence(
      id: "evidence-1", observed_record_version_id: "version-1", source_url: "https://github.com/x/y/42",
      source_label: "GitHub", excerpt: "review", evidence_at: NOW, relation: "supports"
    )
    @db[:action_series].insert(
      id: "series-1", current_subject_key: "subject", identity_version: 1,
      action_kind: "respond", canonical_subject_type: "github_pr", canonical_subject_id: "42",
      created_at: NOW, updated_at: NOW
    )
    @db[:inferred_actions].insert(
      id: "action-1", series_id: "series-1", occurrence_number: 1, inference_status: "active",
      action_kind: "respond", summary: "Reply", confidence: 0.9, user_state: "open",
      state_version: 0, first_seen_at: NOW, last_seen_at: NOW
    )
  end

  def record_attributes(id:, summary: "summary", first_seen_at: NOW, last_observed_at: NOW)
    {
      id:, source_name: "github", account_identity: "me@example.com", source_record_id: "42",
      record_kind: "notification", summary:, event_at: NOW, observed_at: NOW,
      timestamp_kind: "event_at", content_fingerprint: "record-fingerprint",
      first_seen_at:, last_observed_at:
    }
  end
end
