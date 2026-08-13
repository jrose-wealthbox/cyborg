# frozen_string_literal: true

require_relative "../test_helper"

class CyborgActionReconcilerTest < Minitest::Test
  NOW = "2026-08-13T12:00:00Z"
  LATER = "2026-08-14T12:00:00Z"
  AFTER = "2026-08-15T12:00:00Z"

  def setup
    @tmpdir = Dir.mktmpdir("cyborg-action-reconcile-test")
    @db = Cyborg::Database.connect(path: File.join(@tmpdir, "cyborg.sqlite3"))
    @db.migrate!
    insert_run("run-1", NOW)
    insert_evidence("e1", NOW)
    insert_evidence("e2", AFTER)
    insert_evidence("e3", LATER)
    @reconciler = Cyborg::Actions::Reconciler.new(db: @db, now: Time.iso8601(NOW))
    @state_machine = Cyborg::Actions::StateMachine.new(db: @db, now: Time.iso8601(LATER))
  end

  def teardown
    @db.disconnect
    FileUtils.remove_entry(@tmpdir)
  end

  def test_reconciliation_creates_stable_series_and_updates_current_inference_without_user_state_change
    first = @reconciler.call(run: run_value("run-1", NOW), claims: [claim(evidence_ids: ["e1"])])
    action = first.actions.fetch(0)
    assert_equal 1, action.occurrence_number
    assert_equal "open", action.user_state

    @state_machine.transition(action_id: action.id, command: "acknowledge", origin: "cli")
    second = @reconciler.call(run: run_value("run-1", LATER), claims: [claim(summary: "Updated", evidence_ids: %w[e1 e3])])
    updated = second.actions.fetch(0)

    assert_equal action.id, updated.id
    assert_equal "acknowledged", updated.user_state
    assert_equal 1, updated.state_version
    assert_equal "Updated", updated.summary
    assert_equal 2, @db[:action_evidence].where(action_id: action.id).count
  end

  def test_new_evidence_does_not_reopen_done_occurrence
    action = @reconciler.call(run: run_value("run-1", NOW), claims: [claim(evidence_ids: ["e1"]) ]).actions.fetch(0)
    @state_machine.transition(action_id: action.id, command: "done", origin: "cli")

    result = @reconciler.call(run: run_value("run-1", AFTER), claims: [claim(summary: "Later wording", evidence_ids: ["e2"])])
    current = result.actions.fetch(0)

    assert_equal action.id, current.id
    assert_equal "done", current.user_state
    assert_equal 1, current.occurrence_number
    assert_equal "Later wording", current.summary
  end

  def test_new_commitment_with_later_unknown_anchor_creates_successor_and_supersedes_predecessor
    predecessor = @reconciler.call(run: run_value("run-1", NOW), claims: [claim(evidence_ids: ["e1"]) ]).actions.fetch(0)
    @state_machine.transition(action_id: predecessor.id, command: "done", origin: "cli")

    result = @reconciler.call(
      run: run_value("run-1", AFTER),
      claims: [claim(summary: "New commitment", evidence_ids: ["e2"], new_commitment: true)]
    )
    successor = result.actions.find { |action| action.occurrence_number == 2 }
    predecessor_after = Cyborg::Repositories::ActionRepository.new(@db).action(predecessor.id)

    assert_equal 2, result.actions.length
    assert_equal 2, successor.occurrence_number
    assert_equal "open", successor.user_state
    assert_equal "superseded", predecessor_after.inference_status
    assert_equal 1, @db[:action_successors].count
    assert_equal({predecessor_action_id: predecessor.id, successor_action_id: successor.id},
                 @db[:action_successors].first.slice(:predecessor_action_id, :successor_action_id))
  end

  def test_new_commitment_with_anchor_known_before_terminal_records_ambiguity
    action = @reconciler.call(run: run_value("run-1", NOW), claims: [claim(evidence_ids: ["e1"]) ]).actions.fetch(0)
    @state_machine.transition(action_id: action.id, command: "done", origin: "cli")

    result = @reconciler.call(
      run: run_value("run-1", AFTER),
      claims: [claim(evidence_ids: ["e1"], new_commitment: true)]
    )

    assert_equal 1, result.actions.length
    assert_equal "actions.ambiguous_successor", result.warnings.fetch(0).fetch("code")
    assert_equal "done", result.actions.fetch(0).user_state
    assert_equal 0, @db[:action_successors].count
  end

  def test_alias_subject_key_reuses_existing_series
    claim_value = claim(evidence_ids: ["e1"])
    first = @reconciler.call(run: run_value("run-1", NOW), claims: [claim_value]).actions.fetch(0)
    series = Cyborg::Repositories::ActionRepository.new(@db).series(first.series_id)
    alias_key = Cyborg::Actions::SubjectKey.call(
      identity_version: 2, action_kind: "review", subject_type: "github_pull_request",
      subject_id: "node-42", owner_identity: "me@example.com", target_identity: "acme/cyborg#42"
    )
    @db[:action_key_aliases].insert(subject_key: alias_key, series_id: series.id, identity_version: 2, created_at: NOW)
    aliased_claim = claim_value.merge("identity_version" => 2)

    # A claim with its legacy identity version resolves through the registered alias.
    result = @reconciler.call(run: run_value("run-1", LATER), claims: [aliased_claim])

    assert_equal first.id, result.actions.fetch(0).id
    assert_equal 1, @db[:action_series].count
  end

  private

  def insert_run(id, created_at)
    @db[:runs].insert(
      id:, profile: "default", execution_mode: "interactive", status: "running",
      window_start_utc: created_at, window_end_utc: AFTER, display_timezone: "UTC",
      configuration_fingerprint: "config", created_at:
    )
  end

  def run_value(id, created_at)
    {id:, created_at:, completed_at: created_at}
  end

  def insert_evidence(id, at)
    @db[:observed_records].insert(
      id: "record-#{id}", source_name: "github", account_identity: "me@example.com",
      source_record_id: id, record_kind: "notification", event_at: at, observed_at: at,
      timestamp_kind: "event_at", content_fingerprint: "fp-#{id}", first_seen_at: at, last_observed_at: at
    )
    @db[:observed_record_versions].insert(
      id: "version-#{id}", observed_record_id: "record-#{id}", content_fingerprint: "vfp-#{id}",
      payload_json: "{}", created_at: at
    )
    @db[:evidence].insert(
      id:, observed_record_version_id: "version-#{id}", source_url: "https://github.example/acme/cyborg/pull/42",
      source_label: "GitHub", excerpt: id, evidence_at: at, relation: "supports"
    )
  end

  def claim(summary: "Review", evidence_ids: ["e1"], new_commitment: false)
    {
      "action_kind" => "review", "summary" => summary,
      "canonical_subject_type" => "github_pull_request", "canonical_subject_id" => "node-42",
      "owner_identity" => "me@example.com", "thread_or_target_identity" => "acme/cyborg#42",
      "anchor_evidence_id" => evidence_ids.first, "evidence_ids" => evidence_ids, "confidence" => 0.9,
      "people" => [], "projects" => [], "new_commitment" => new_commitment
    }
  end
end
