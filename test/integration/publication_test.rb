# frozen_string_literal: true

require_relative "../test_helper"

class CyborgPublicationTest < Minitest::Test
  NOW = "2026-08-13T12:00:00Z"
  LATER = "2026-08-13T12:01:00Z"

  def setup
    @tmpdir = Dir.mktmpdir("cyborg-publication-test")
    @db = Cyborg::Database.connect(path: File.join(@tmpdir, "cyborg.sqlite3"))
    @db.migrate!
    insert_run
    insert_snapshot("snapshot-github", source_name: "github", status: "healthy", data_status: "fresh", cursor_disposition: "advance")
    insert_snapshot("snapshot-slack", source_name: "slack", status: "failed", data_status: "none", cursor_disposition: "hold",
                    error_code: "slack.unavailable", error_remediation: "Reconnect Slack")
    insert_evidence
    @publisher = Cyborg::Runs::Publisher.new(db: @db, now: Time.iso8601(NOW), footer: "Edit the skill.")
  end

  def teardown
    @db.disconnect
    FileUtils.remove_entry(@tmpdir)
  end

  def test_publication_rolls_back_actions_baselines_pointer_and_view_together
    @publisher.fail_after!(:presentation_insert)

    assert_raises(Sequel::ConstraintViolation) do
      @publisher.publish(run: persisted_run, analysis: analysis)
    end

    assert_empty @db[:inferred_actions].all
    assert_empty @db[:analysis_results].all
    assert_empty @db[:presentation_results].all
    assert_empty @db[:usage_records].all
    assert_nil @db[:source_baselines].first
    assert_nil @db[:application_state].first
    assert_equal "running", @db[:runs].where(id: "run-1").get(:status)
  end

  def test_successful_publication_re_reads_user_state_activates_only_eligible_baselines_and_updates_pointer
    publisher = Cyborg::Runs::Publisher.new(db: @db, now: Time.iso8601(NOW))
    result = publisher.publish(run: persisted_run, analysis: analysis)

    assert_equal "degraded", result.run.status
    assert_equal "degraded", @db[:runs].where(id: "run-1").get(:status)
    assert_equal "run-1", @db[:application_state].where(key: "latest_renderable_run_id").get(:value)
    assert_equal "snapshot-github", @db[:source_baselines].where(source_name: "github").get(:activated_snapshot_id)
    assert_nil @db[:source_baselines].where(source_name: "slack").first
    assert_equal "run-1", @db[:presentation_results].where(run_id: "run-1").get(:run_id)
    assert_equal "open", result.view_model.fetch("sections").flat_map { |section| section.fetch("items") }.first.fetch("state")
  end

  def test_manual_transition_between_analysis_and_publication_is_preserved
    initial = Cyborg::Actions::Reconciler.new(db: @db, now: Time.iso8601(NOW)).call(
      run: persisted_run, claims: [claim]
    ).actions.fetch(0)
    Cyborg::Actions::StateMachine.new(db: @db, now: Time.iso8601(LATER)).transition(
      action_id: initial.id, command: "acknowledge", origin: "test"
    )

    publisher = Cyborg::Runs::Publisher.new(db: @db, now: Time.iso8601(LATER))
    result = publisher.publish(run: persisted_run, analysis: analysis)
    item = result.view_model.fetch("sections").flat_map { |section| section.fetch("items") }.find { |value| value.fetch("id") == initial.id }

    assert_equal "acknowledged", item.fetch("state")
    assert_equal 1, item.fetch("state_version")
  end

  def test_persisted_record_is_new_only_when_first_seen_after_prior_fresh_baseline
    insert_prior_baseline
    @db[:source_snapshots].where(id: "snapshot-github").update(prior_activated_snapshot_id: "snapshot-github-old")
    insert_record_for_snapshot(
      snapshot_id: "snapshot-github", id: "record-new", first_seen_at: "2026-08-13T11:30:00Z",
      event_at: "2026-08-13T09:00:00Z", deep_link: "https://github.example/review"
    )

    result = Cyborg::Runs::Publisher.new(db: @db, now: Time.iso8601(NOW), trusted_hosts: ["github.example"]).publish(
      run: persisted_run, analysis: analysis
    )
    item = result.view_model.fetch("sections").flat_map { |section| section.fetch("items") }.find { |value| value.fetch("id") == "record-new" }

    assert_equal "🆕", item.fetch("recency_marker")
  end

  def test_failed_source_without_prior_baseline_has_unknown_last_fresh_refresh
    result = Cyborg::Runs::Publisher.new(db: @db, now: Time.iso8601(NOW)).publish(
      run: persisted_run, analysis: analysis
    )
    health = result.view_model.fetch("source_health").find { |value| value.fetch("source") == "slack" }

    assert_nil health.fetch("last_fresh_refresh")
  end

  def test_publication_drops_adversarial_links_even_on_an_allowlisted_host
    insert_record_for_snapshot(
      snapshot_id: "snapshot-github", id: "record-adversarial", first_seen_at: NOW,
      deep_link: "https://github.example/review?token=secret"
    )

    result = Cyborg::Runs::Publisher.new(db: @db, now: Time.iso8601(NOW), trusted_hosts: ["github.example"]).publish(
      run: persisted_run, analysis: analysis
    )
    item = result.view_model.fetch("sections").flat_map { |section| section.fetch("items") }.find { |value| value.fetch("id") == "record-adversarial" }

    assert_empty item.fetch("links")
  end

  private

  def persisted_run
    Cyborg::Repositories::RunRepository.new(@db).find("run-1")
  end

  def insert_run
    @db[:runs].insert(
      id: "run-1", profile: "default", execution_mode: "interactive", status: "running",
      window_start_utc: NOW, window_end_utc: LATER, display_timezone: "UTC",
      configuration_fingerprint: "configuration", created_at: NOW, captured_action_state_version: 0
    )
  end

  def insert_snapshot(id, source_name:, status:, data_status:, cursor_disposition:, error_code: nil, error_remediation: nil)
    @db[:source_snapshots].insert(
      id:, run_id: "run-1", source_name:, account_identity: "me", adapter_version: "1",
      started_at: NOW, completed_at: LATER, status:, data_status:, cursor_disposition:,
      proposed_cursor: cursor_disposition == "advance" ? "cursor-2" : nil,
      error_code:, error_remediation:, record_count: 1
    )
  end

  def insert_evidence
    @db[:observed_records].insert(
      id: "record-1", source_name: "github", account_identity: "me", source_record_id: "42",
      record_kind: "notification", summary: "Review", event_at: NOW, observed_at: NOW,
      timestamp_kind: "event_at", content_fingerprint: "fp-1", first_seen_at: NOW, last_observed_at: NOW,
      deep_link: "https://github.example/review"
    )
    @db[:observed_record_versions].insert(
      id: "version-1", observed_record_id: "record-1", content_fingerprint: "vfp-1", payload_json: "{}", created_at: NOW
    )
    @db[:evidence].insert(
      id: "e1", observed_record_version_id: "version-1", source_url: "https://github.example/review",
      source_label: "GitHub", excerpt: "Review", evidence_at: NOW, relation: "supports"
    )
  end

  def insert_prior_baseline
    @db[:runs].insert(
      id: "run-old", profile: "default", execution_mode: "interactive", status: "completed",
      window_start_utc: "2026-08-12T00:00:00Z", window_end_utc: "2026-08-12T23:59:00Z", display_timezone: "UTC",
      configuration_fingerprint: "configuration", created_at: "2026-08-12T00:00:00Z", completed_at: "2026-08-12T11:00:00Z"
    )
    @db[:source_snapshots].insert(
      id: "snapshot-github-old", run_id: "run-old", source_name: "github", account_identity: "me", adapter_version: "1",
      started_at: "2026-08-12T10:59:00Z", completed_at: "2026-08-12T11:00:00Z", status: "healthy", data_status: "fresh",
      cursor_disposition: "advance", proposed_cursor: "cursor-1", record_count: 0
    )
    @db[:source_baselines].insert(
      source_name: "github", account_identity: "me", activated_snapshot_id: "snapshot-github-old",
      activated_at: "2026-08-12T11:00:00Z", cursor: "cursor-1"
    )
  end

  def insert_record_for_snapshot(snapshot_id:, id:, first_seen_at:, deep_link:, event_at: first_seen_at)
    @db[:observed_records].insert(
      id:, source_name: "github", account_identity: "me", source_record_id: id,
      record_kind: "notification", summary: id, event_at:, observed_at: first_seen_at,
      timestamp_kind: "event_at", content_fingerprint: "fp-#{id}", first_seen_at:, last_observed_at: first_seen_at,
      deep_link:
    )
    @db[:observed_record_versions].insert(
      id: "version-#{id}", observed_record_id: id, content_fingerprint: "vfp-#{id}", payload_json: "{}", created_at: first_seen_at
    )
    @db[:snapshot_records].insert(snapshot_id:, record_version_id: "version-#{id}")
  end

  def claim
    {
      "action_kind" => "review", "summary" => "Review pull request", "canonical_subject_type" => "github_pull_request",
      "canonical_subject_id" => "node-42", "owner_identity" => "me", "thread_or_target_identity" => "repo#42",
      "anchor_evidence_id" => "e1", "evidence_ids" => ["e1"], "confidence" => 0.9,
      "people" => [], "projects" => [], "new_commitment" => false
    }
  end

  def analysis
    {
      "claims" => [claim],
      "usage" => {"certainty" => "unknown", "records" => [], "unknown_cost_micros" => 25},
      "backend_metadata" => {"backend" => "fixture"}
    }
  end
end
