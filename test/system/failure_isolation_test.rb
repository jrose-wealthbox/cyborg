# frozen_string_literal: true

require_relative "../test_helper"

class CyborgFailureIsolationTest < Minitest::Test
  NOW = "2026-08-13T12:00:00Z"

  def test_malformed_ingestion_rolls_back_all_source_rows
    tmpdir = Dir.mktmpdir("cyborg-failure-isolation")
    db = Cyborg::Database.connect(path: File.join(tmpdir, "cyborg.sqlite3"))
    db.migrate!
    db[:runs].insert(id: "run-1", profile: "default", execution_mode: "interactive", status: "running", window_start_utc: NOW, window_end_utc: NOW, display_timezone: "UTC", configuration_fingerprint: "config", created_at: NOW)
    registration = Cyborg::Registration.new(source_name: "fixture", adapter_version: "1", account_identity: "fixture", transport: "direct", capabilities: [], filters: {}, limits: {}, credential_strategy: "none", health_checks: [], cursor_policy: "proposed", cache_policy: "ordinary", retention_class: "standard", allowed_fields: [], operations: {}, parameters: {}, required: false)
    record = Cyborg::NormalizedRecord.new(source_record_id: "ok", record_kind: "notification", title: "ok", summary: "ok", structured_fields: {}, participants: [], owner_identity: nil, canonical_target_type: nil, canonical_target_id: nil, deep_link: nil, event_at: NOW, observed_at: NOW, timestamp_kind: "event_at", content_fingerprint: "fp", evidence: [])
    bad = Cyborg::RetrievalResult.new(source_name: "fixture", account_identity: "fixture", status: "healthy", data_status: "fresh", started_at: NOW, completed_at: NOW, records: [record, record.with(source_record_id: "bad", event_at: "not-a-time")], next_cursor: "cursor")
    assert_raises(Cyborg::PersistenceError) { Cyborg::SourceIngestor.new(db:).ingest(run: Cyborg::Repositories::RunRepository.new(db).find("run-1"), registration:, result: bad) }
    assert_equal 0, db[:source_snapshots].count
    assert_equal 0, db[:observed_records].count
    assert_equal 0, db[:evidence].count
  ensure
    db&.disconnect
    FileUtils.remove_entry(tmpdir) if tmpdir
  end
end
