# frozen_string_literal: true

require_relative "../test_helper"
require "cyborg/sources/contracts"
require "cyborg/sources/ingestor"

class CyborgSourceIngestorTest < Minitest::Test
  NOW = "2026-08-12T00:00:00Z"
  LATER = "2026-08-12T00:01:00Z"

  def setup
    @tmpdir = Dir.mktmpdir("cyborg-source-ingestor")
    @db = Cyborg::Database.connect(path: File.join(@tmpdir, "cyborg.sqlite3"))
    @db.migrate!
    @run_repository = Cyborg::Repositories::RunRepository.new(@db)
    @run_repository.create(
      id: "run-1", profile: "default", execution_mode: "interactive", status: "running",
      window_start_utc: NOW, window_end_utc: LATER, display_timezone: "UTC",
      configuration_fingerprint: "config", created_at: NOW
    )
    @run = @run_repository.find("run-1")
    @source = Cyborg::Registration.new(
      source_name: "github", adapter_version: "github-1", account_identity: "me@example.com",
      transport: "direct", capabilities: ["notifications"], filters: {}, limits: {},
      credential_strategy: "external", health_checks: [], cursor_policy: "proposed",
      cache_policy: "ordinary", retention_class: "standard", allowed_fields: [],
      operations: {}, parameters: {}, required: false
    )
    @ingestor = Cyborg::SourceIngestor.new(db: @db)
  end

  def teardown
    @db.disconnect
    FileUtils.remove_entry(@tmpdir)
  end

  def test_failed_or_cached_snapshot_holds_cursor_and_does_not_activate_baseline
    %w[failed cached].each_with_index do |mode, index|
      run = index.zero? ? @run : create_run("run-#{index + 2}")
      snapshot = @ingestor.ingest(run:, registration: @source, result: result_for(mode))
      assert_equal "hold", snapshot.cursor_disposition
      if mode == "failed"
        assert_equal "github.api_unavailable", @db[:source_snapshots].where(run_id: run.id).get(:error_code)
      end
      assert_nil @db[:source_baselines].first
    end
  end

  def test_fresh_snapshot_persists_version_evidence_and_only_proposes_cursor
    snapshot = @ingestor.ingest(run: @run, registration: @source, result: result_for("fresh"))

    assert_equal "advance", snapshot.cursor_disposition
    assert_equal "cursor-2", snapshot.proposed_cursor
    assert_equal 1, @db[:observed_records].count
    assert_equal 1, @db[:observed_record_versions].count
    assert_equal 1, @db[:snapshot_records].count
    assert_equal 1, @db[:evidence].count
    assert_nil @db[:source_baselines].first
    assert_equal "2026-08-12T00:00:00Z", @db[:evidence].get(:evidence_at)
  end

  def test_source_transaction_rolls_back_snapshot_record_version_and_evidence_together
    bad = result_for("fresh", records: [record, record.with(source_record_id: "bad", event_at: "not-a-time")])

    assert_raises(Cyborg::PersistenceError) { @ingestor.ingest(run: @run, registration: @source, result: bad) }
    assert_equal 0, @db[:source_snapshots].count
    assert_equal 0, @db[:observed_records].count
    assert_equal 0, @db[:observed_record_versions].count
    assert_equal 0, @db[:evidence].count
  end

  def test_exact_duplicate_records_share_one_record_version_and_snapshot_attachment
    duplicate = result_for("fresh", records: [record, record])
    @ingestor.ingest(run: @run, registration: @source, result: duplicate)

    assert_equal 1, @db[:observed_records].count
    assert_equal 1, @db[:observed_record_versions].count
    assert_equal 1, @db[:snapshot_records].count
  end

  private

  def create_run(id)
    @run_repository.create(
      id:, profile: "default", execution_mode: "interactive", status: "running",
      window_start_utc: NOW, window_end_utc: LATER, display_timezone: "UTC",
      configuration_fingerprint: "config", created_at: NOW
    )
  end

  def record
    Cyborg::NormalizedRecord.new(
      source_record_id: "42", record_kind: "notification", title: "Review", summary: "Please review",
      structured_fields: {"repository" => "cyborg"}, participants: ["me@example.com"],
      owner_identity: "me@example.com", canonical_target_type: "github_pr", canonical_target_id: "42",
      deep_link: "https://github.example/cyborg/pull/42", event_at: NOW, latest_reply_at: nil,
      observed_at: LATER, timestamp_kind: "event_at", content_fingerprint: "fp-42",
      evidence: [Cyborg::EvidenceDraft.new(source_url: "https://github.example/cyborg/pull/42", source_label: "GitHub", excerpt: "Please review", field_path: nil, evidence_at: NOW, relation: "supports")]
    )
  end

  def result_for(mode, records: [record])
    status, data_status, cache_reason = case mode
    when "failed" then ["failed", "none", nil]
    when "cached" then ["healthy", "cached", "policy_hit"]
    else ["healthy", "fresh", nil]
    end
    Cyborg::RetrievalResult.new(
      source_name: "github", account_identity: "me@example.com", status:, data_status:, cache_reason:,
      started_at: NOW, completed_at: LATER, records:, next_cursor: "cursor-2",
      error: mode == "failed" ? Cyborg::RetrievalError.new(code: "github.api_unavailable", message: "unavailable", remediation: "retry") : nil
    )
  end
end
