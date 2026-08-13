# frozen_string_literal: true

require_relative "../test_helper"

class CyborgErrorsTest < Minitest::Test
  def test_usage_error_has_stable_code_and_exit_status
    error = Cyborg::UsageError.new("cli.unknown_command")

    assert_equal "cli.unknown_command", error.code
    assert_equal 64, error.exit_status
  end

  def test_invalid_artifact_can_override_default_exit_status_explicitly
    error = Cyborg::InvalidArtifact.new("bridge.unknown_type", exit_status: 65)

    assert_equal "bridge.unknown_type", error.code
    assert_equal 65, error.exit_status
  end
end
