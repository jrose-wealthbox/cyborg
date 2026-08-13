# frozen_string_literal: true

require_relative "../test_helper"
require "open3"
require "sqlite3"

class CyborgActionCLITest < Minitest::Test
  NOW = "2026-08-13T12:00:00Z"

  def setup
    @tmpdir = Dir.mktmpdir("cyborg-action-cli")
    @state = File.join(@tmpdir, "state")
    @artifacts = File.join(@tmpdir, "artifacts")
    @config = File.join(@tmpdir, "config.toml")
    FileUtils.mkdir_p([@state, @artifacts])
    write_config(@config)
    @action_ids = seed_actions
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_all_action_commands_and_idempotent_repeat_are_real_cli_transitions
    action_id = @action_ids.fetch(0)

    acknowledge = run_cli("actions", "acknowledge", action_id)
    assert_equal 0, acknowledge[:status], acknowledge[:stderr]
    assert_equal "acknowledged", JSON.parse(acknowledge[:stdout]).fetch("action").fetch("user_state")

    snooze = run_cli("actions", "snooze", action_id, "--until", "2026-08-14T12:00:00Z")
    assert_equal 0, snooze[:status], snooze[:stderr]
    assert_equal "snoozed", JSON.parse(snooze[:stdout]).fetch("action").fetch("user_state")

    reopen = run_cli("actions", "reopen", action_id)
    assert_equal 0, reopen[:status], reopen[:stderr]
    done = run_cli("actions", "done", action_id)
    assert_equal 0, done[:status], done[:stderr]
    reopen_done = run_cli("actions", "reopen", action_id)
    assert_equal 0, reopen_done[:status], reopen_done[:stderr]
    dismiss = run_cli("actions", "dismiss", action_id)
    assert_equal 0, dismiss[:status], dismiss[:stderr]

    repeat = run_cli("actions", "dismiss", action_id)
    assert_equal 0, repeat[:status], repeat[:stderr]

    database = SQLite3::Database.new(File.join(@state, "cyborg.sqlite3"))
    transitions = database.get_first_value("SELECT COUNT(*) FROM action_transitions WHERE action_id = ?", action_id)
    states = database.execute("SELECT to_state FROM action_transitions WHERE action_id = ? ORDER BY id", action_id).flatten
    database.close
    assert_equal 6, transitions
    assert_equal %w[acknowledged snoozed open done open dismissed], states
  end

  def test_snooze_requires_rfc3339_until_and_rejected_transition_is_durable_free
    action_id = @action_ids.fetch(1)
    missing = run_cli("actions", "snooze", action_id)
    assert_equal 64, missing[:status]
    assert_empty missing[:stdout]
    assert_includes missing[:stderr], "actions.snooze_requires_until"

    invalid = run_cli("actions", "snooze", action_id, "--until", "tomorrow")
    assert_equal 64, invalid[:status]
    assert_includes invalid[:stderr], "actions.invalid_until"

    done = run_cli("actions", "done", action_id)
    assert_equal 0, done[:status], done[:stderr]
    rejected = run_cli("actions", "actions", action_id)
    assert_equal 64, rejected[:status]
    assert_includes rejected[:stderr], "cli.unknown_action"

    rejected = run_cli("actions", "acknowledge", action_id)
    assert_equal 64, rejected[:status]
    assert_empty rejected[:stdout]
    assert_includes rejected[:stderr], "actions.invalid_transition"

    database = SQLite3::Database.new(File.join(@state, "cyborg.sqlite3"))
    transitions = database.get_first_value("SELECT COUNT(*) FROM action_transitions WHERE action_id = ?", action_id)
    state = database.get_first_value("SELECT user_state FROM inferred_actions WHERE id = ?", action_id)
    database.close
    assert_equal 1, transitions
    assert_equal "done", state
  end

  def test_snooze_rejects_timezone_less_invalid_calendar_and_trailing_timestamps
    invalid_values = [
      "2026-08-14T12:00:00",
      "2026-02-30T12:00:00Z",
      "2026-08-14T12:00:00Z trailing"
    ]

    invalid_values.each do |until_time|
      result = run_cli("actions", "snooze", @action_ids.fetch(0), "--until", until_time)
      assert_equal 64, result[:status]
      assert_empty result[:stdout]
      assert_includes result[:stderr], "actions.invalid_until"
    end

    database = SQLite3::Database.new(File.join(@state, "cyborg.sqlite3"))
    transitions = database.get_first_value(
      "SELECT COUNT(*) FROM action_transitions WHERE action_id = ?", @action_ids.fetch(0)
    )
    state = database.get_first_value("SELECT user_state FROM inferred_actions WHERE id = ?", @action_ids.fetch(0))
    database.close
    assert_equal 0, transitions
    assert_equal "open", state
  end

  def test_until_is_unsupported_for_non_snooze_actions_and_numeric_offset_is_valid
    unsupported = run_cli("actions", "done", @action_ids.fetch(0), "--until", "2026-08-14T12:00:00Z")
    assert_equal 64, unsupported[:status]
    assert_empty unsupported[:stdout]
    assert_includes unsupported[:stderr], "cli.unsupported_option"

    valid = run_cli("actions", "snooze", @action_ids.fetch(0), "--until", "2026-08-14T12:00:00+02:00")
    assert_equal 0, valid[:status], valid[:stderr]
    action = JSON.parse(valid[:stdout]).fetch("action")
    assert_equal "snoozed", action.fetch("user_state")
    assert_equal "2026-08-14T10:00:00Z", action.fetch("snoozed_until")
  end

  private

  def write_config(path)
    File.write(path, <<~TOML)
      [runtime]
      profile = "default"
      timezone = "UTC"
      lease_timeout_seconds = 600
      analysis_timeout_seconds = 300

      [budget]
      ceiling_micros = 5000000

      [cache]
      ordinary_ttl_seconds = 1800
      expensive_ttl_seconds = 14400

      [calendar.profiles.default]
      timezone = "UTC"
      weekend_days = ["saturday", "sunday"]
      easter = false
    TOML
  end

  def seed_actions
    database = Cyborg::Database.connect(path: File.join(@state, "cyborg.sqlite3"))
    database.migrate!
    repository = Cyborg::Repositories::RunRepository.new(database)
    repository.create(
      id: "action-run", profile: "default", execution_mode: "host", status: "completed",
      window_start_utc: NOW, window_end_utc: NOW, display_timezone: "UTC", configuration_fingerprint: "config",
      created_at: NOW, completed_at: NOW
    )
    action_repository = Cyborg::Repositories::ActionRepository.new(database)
    ids = 2.times.map do |index|
      series_id = "action-series-#{index}"
      action_id = "action-#{index}"
      action_repository.create_series(
        id: series_id, current_subject_key: "subject-#{index}", identity_version: 1, action_kind: "review",
        canonical_subject_type: "issue", canonical_subject_id: "issue-#{index}", normalized_owner_identity: "me",
        normalized_thread_or_target_identity: "repo/issue-#{index}", created_at: NOW, updated_at: NOW
      )
      action_repository.create_action(
        id: action_id, series_id:, occurrence_number: 1, inference_status: "active", action_kind: "review",
        summary: "Review #{index}", related_people_json: "[]", related_projects_json: "[]", due_at: nil,
        confidence: 0.9, user_state: "open", snoozed_until: nil, state_version: 0,
        first_seen_at: NOW, last_seen_at: NOW, terminal_at: nil
      )
      action_id
    end
    database.disconnect
    ids
  end

  def run_cli(*arguments)
    env = {"CYBORG_CONFIG" => @config, "CYBORG_STATE_DIR" => @state, "CYBORG_ARTIFACT_DIR" => @artifacts, "RUBYOPT" => nil}
    stdout, stderr, status = Open3.capture3(env, File.expand_path("../../bin/cyborg", __dir__), *arguments)
    {stdout:, stderr:, status: status.exitstatus}
  end
end
