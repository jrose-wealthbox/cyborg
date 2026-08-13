# frozen_string_literal: true

require_relative "../../test_helper"

class CyborgPresentationViewModelBuilderTest < Minitest::Test
  NOW = Time.utc(2026, 8, 13, 12, 0, 0)

  def setup
    @builder = Cyborg::Presentation::ViewModelBuilder.new(
      now: NOW, footer: "Edit the skill to change this briefing."
    )
  end

  def test_builds_immutable_action_first_view_with_health_age_markers_and_hidden_states
    view = @builder.call(
      run: run_value,
      snapshots: [degraded_snapshot],
      records: [
        record("record-new", event_at: "2026-08-13T10:00:00Z", first_seen_after_baseline: true),
        record("record-future", event_at: "2026-08-13T12:05:00Z")
      ],
      actions: [
        action("action-do", action_kind: "do", summary: "Send the reply", last_seen_at: "2026-08-13T11:50:00Z"),
        action("action-done", action_kind: "respond", user_state: "done", summary: "Already handled"),
        action("action-urgent", action_kind: "respond", summary: "Answer now", last_seen_at: "2026-08-13T11:55:00Z")
      ],
      warnings: ["analysis.cost_uncertain"],
      usage: {"certainty" => "unknown", "unknown_cost_micros" => 25}
    )

    assert_equal ["SOURCE HEALTH", "DO", "RESPOND", "PREP", "WAITING ON", "DECIDE", "CHANGED", "FYI"],
                 view.fetch("sections").map { |section| section.fetch("name") }
    assert_equal "⚠️ SOURCE HEALTH", view.fetch("sections").first.fetch("heading")

    items = view.fetch("sections").flat_map { |section| section.fetch("items") }
    ids = items.map { |item| item.fetch("id") }
    assert_includes ids, "action-do"
    assert_includes ids, "action-urgent"
    refute_includes ids, "action-done"
    assert_equal "🆕", items.find { |item| item.fetch("id") == "record-new" }.fetch("recency_marker")
    assert_equal "in 5m", items.find { |item| item.fetch("id") == "record-future" }.fetch("age")
    assert_includes items.find { |item| item.fetch("id") == "action-urgent" }.fetch("markers"), "🚨"
    assert_equal "unknown", view.fetch("usage").fetch("certainty")
    assert_equal "Edit the skill to change this briefing.", view.fetch("footer")
    assert_predicate view, :frozen?
    assert_predicate view.fetch("sections"), :frozen?
    assert_predicate items.first, :frozen?
  end

  def test_marker_precedence_keeps_urgency_independent_and_supports_switches
    builder = Cyborg::Presentation::ViewModelBuilder.new(
      now: NOW, recency_markers: false, urgency_markers: false
    )
    view = builder.call(
      run: run_value, snapshots: [healthy_snapshot], records: [],
      actions: [action("action-1", action_kind: "respond", last_seen_at: "2026-08-13T11:50:00Z")],
      warnings: [], usage: {}
    )

    item = view.fetch("sections").flat_map { |section| section.fetch("items") }.fetch(0)
    assert_empty item.fetch("markers")
    assert_nil item.fetch("recency_marker")
  end

  private

  def run_value
    {
      "id" => "run-1", "profile" => "default", "status" => "degraded",
      "completed_at" => "2026-08-13T12:00:00Z", "display_timezone" => "UTC"
    }
  end

  def healthy_snapshot
    {
      "id" => "snapshot-1", "source_name" => "github", "account_identity" => "me",
      "status" => "healthy", "data_status" => "fresh", "cache_reason" => nil,
      "completed_at" => "2026-08-13T11:59:00Z", "prior_activated_snapshot_id" => "old-snapshot"
    }
  end

  def degraded_snapshot
    healthy_snapshot.merge(
      "status" => "degraded", "data_status" => "cached", "cache_reason" => "failure_fallback",
      "error_code" => "github.timeout", "error_remediation" => "Retry GitHub later",
      "prior_activated_snapshot_id" => "old-snapshot"
    )
  end

  def record(id, event_at: "2026-08-13T11:00:00Z", first_seen_after_baseline: false)
    {
      "id" => id, "source_name" => "github", "account_identity" => "me", "source_record_id" => id,
      "record_kind" => "notification", "summary" => "Record #{id}", "event_at" => event_at,
      "latest_reply_at" => nil, "observed_at" => "2026-08-13T11:59:00Z",
      "timestamp_kind" => "event_at", "deep_link" => "https://github.example/#{id}",
      "first_seen_after_baseline" => first_seen_after_baseline
    }
  end

  def action(id, action_kind:, summary: "Action", user_state: "open", last_seen_at: "2026-08-13T11:00:00Z")
    {
      "id" => id, "action_kind" => action_kind, "summary" => summary,
      "user_state" => user_state, "inference_status" => "active", "state_version" => 0,
      "last_seen_at" => last_seen_at, "confidence" => 0.9,
      "source_url" => "https://github.example/#{id}"
    }
  end
end
