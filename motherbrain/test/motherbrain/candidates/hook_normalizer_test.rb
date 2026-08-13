# frozen_string_literal: true

require_relative "../../test_helper"

class HookNormalizerTest < Minitest::Test
  def setup
    @now = Time.utc(2026, 8, 12, 18, 30, 0)
  end

  def test_normalizes_claude_code_session_end_payload
    payload = {
      "session_id" => "claude-session-123",
      "transcript_path" => "/tmp/claude-session.jsonl",
      "cwd" => "/work/project",
      "hook_event_name" => "SessionEnd",
      "reason" => "prompt_input_exit",
      "provider_only_field" => "discard me"
    }

    normalized = Motherbrain::Candidates::HookNormalizer.call(
      harness: "claude_code",
      payload: payload,
      now: @now
    )

    assert_equal(
      {
        "schema_version" => 1,
        "event" => "session_end",
        "harness" => "claude_code",
        "session_id" => "claude-session-123",
        "transcript_path" => "/tmp/claude-session.jsonl",
        "cwd" => "/work/project",
        "reason" => "prompt_input_exit",
        "received_at" => "2026-08-12T18:30:00Z"
      },
      normalized
    )
  end

  def test_normalizes_codex_session_end_payload
    payload = {
      "session_id" => "codex-session-456",
      "turn_id" => "turn-789",
      "transcript_path" => "/tmp/codex-session.jsonl",
      "cwd" => "/work/project",
      "hook_event_name" => "SessionEnd",
      "reason" => "other"
    }

    normalized = Motherbrain::Candidates::HookNormalizer.call(
      harness: "codex",
      payload: payload,
      now: @now
    )

    assert_equal "codex", normalized.fetch("harness")
    assert_equal "turn-789", normalized.fetch("turn_id")
    assert_equal "other", normalized.fetch("reason")
  end

  def test_returns_nil_for_unknown_harness_or_malformed_payload
    assert_nil Motherbrain::Candidates::HookNormalizer.call(
      harness: "unknown",
      payload: {},
      now: @now
    )

    assert_nil Motherbrain::Candidates::HookNormalizer.call(
      harness: "claude_code",
      payload: {"hook_event_name" => "Stop"},
      now: @now
    )
  end
end
