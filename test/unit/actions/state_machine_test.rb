# frozen_string_literal: true

require_relative "../../test_helper"

class CyborgActionsStateMachineTest < Minitest::Test
  NOW = "2026-08-13T12:00:00Z"
  LATER = "2026-08-14T12:00:00Z"

  def setup
    @tmpdir = Dir.mktmpdir("cyborg-action-state-test")
    @db = Cyborg::Database.connect(path: File.join(@tmpdir, "cyborg.sqlite3"))
    @db.migrate!
    @db[:runs].insert(
      id: "run-1", profile: "default", execution_mode: "interactive", status: "running",
      window_start_utc: NOW, window_end_utc: LATER, display_timezone: "UTC",
      configuration_fingerprint: "config", created_at: NOW
    )
    @db[:action_series].insert(
      id: "series-1", current_subject_key: "subject-1", identity_version: 1,
      action_kind: "review", canonical_subject_type: "github_pull_request", canonical_subject_id: "node-42",
      normalized_owner_identity: "me@example.com", normalized_thread_or_target_identity: "acme/cyborg#42",
      created_at: NOW, updated_at: NOW
    )
    @db[:inferred_actions].insert(
      id: "action-1", series_id: "series-1", occurrence_number: 1, inference_status: "active",
      action_kind: "review", summary: "Review", confidence: 0.9, user_state: "open",
      state_version: 0, first_seen_at: NOW, last_seen_at: NOW
    )
    @machine = Cyborg::Actions::StateMachine.new(db: @db, now: Time.iso8601(NOW))
  end

  def teardown
    @db.disconnect
    FileUtils.remove_entry(@tmpdir)
  end

  def test_allowed_transitions_increment_state_version_and_audit
    acknowledged = @machine.transition(action_id: "action-1", command: "acknowledge", origin: "cli")
    assert_equal "acknowledged", acknowledged.user_state
    assert_equal 1, acknowledged.state_version

    snoozed = @machine.transition(action_id: "action-1", command: "snooze", until_time: LATER, origin: "cli")
    assert_equal "snoozed", snoozed.user_state
    assert_equal LATER, snoozed.snoozed_until
    assert_equal 2, snoozed.state_version

    done = @machine.transition(action_id: "action-1", command: "done", origin: "cli")
    assert_equal "done", done.user_state
    assert_nil done.snoozed_until
    assert_equal NOW, done.terminal_at
    assert_equal 3, done.state_version
    assert_equal 3, @db[:action_transitions].count
    assert_equal ["open", "acknowledged", "snoozed"], @db[:action_transitions].order(:id).select_map(:from_state)
  end

  def test_repeated_requested_state_is_idempotent_without_audit_row
    first = @machine.transition(action_id: "action-1", command: "acknowledge", origin: "cli")
    second = @machine.transition(action_id: "action-1", command: "acknowledge", origin: "cli")

    assert_equal first, second
    assert_equal 1, @db[:action_transitions].count
    assert_equal 1, second.state_version
  end

  def test_snooze_requires_timestamp_and_expiration_does_not_mutate_state
    error = assert_raises(Cyborg::UsageError) do
      @machine.transition(action_id: "action-1", command: "snooze", origin: "cli")
    end
    assert_equal "actions.snooze_requires_until", error.code

    snoozed = @machine.transition(action_id: "action-1", command: "snooze", until_time: NOW, origin: "cli")
    assert_equal "snoozed", snoozed.user_state
    assert @machine.displayable?(action: snoozed, at: Time.iso8601(LATER))
    reloaded = Cyborg::Repositories::ActionRepository.new(@db).action("action-1")
    assert_equal snoozed, reloaded
    assert_equal 1, @db[:action_transitions].count
  end

  def test_rejects_disallowed_transition_and_reopen_clears_terminal_time
    @machine.transition(action_id: "action-1", command: "done", origin: "cli")
    error = assert_raises(Cyborg::UsageError) do
      @machine.transition(action_id: "action-1", command: "dismiss", origin: "cli")
    end
    assert_equal "actions.invalid_transition", error.code

    reopened = @machine.transition(action_id: "action-1", command: "reopen", origin: "cli")
    assert_equal "open", reopened.user_state
    assert_nil reopened.terminal_at
    assert_equal 2, reopened.state_version
  end

  def test_displayability_excludes_terminal_and_stale_actions
    action = Cyborg::Repositories::ActionRepository.new(@db).action("action-1")
    assert @machine.displayable?(action:, at: Time.iso8601(NOW))
    @db[:inferred_actions].where(id: action.id).update(inference_status: "stale")
    stale = Cyborg::Repositories::ActionRepository.new(@db).action(action.id)
    refute @machine.displayable?(action: stale, at: Time.iso8601(NOW))
  end
end
