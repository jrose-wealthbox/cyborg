# frozen_string_literal: true

require_relative "../test_helper"

class RedactorTest < Minitest::Test
  def setup
    @redactor = Cyborg::Redactor.new
  end

  def test_redacts_authorization_and_credential_shaped_keys_recursively
    value = {
      "headers" => {"Authorization" => "Bearer top-secret"},
      "api_key" => "key-value",
      "credentials" => {"access_token" => "token-value", "username" => "safe"},
      "env" => {"OPENAI_API_KEY" => "sk-proj-never-log-this", "LANG" => "en_US"}
    }

    redacted = @redactor.call(value)

    assert_equal "[REDACTED]", redacted.fetch("headers").fetch("Authorization")
    assert_equal "[REDACTED]", redacted.fetch("api_key")
    assert_equal "[REDACTED]", redacted.fetch("credentials").fetch("access_token")
    assert_equal "[REDACTED]", redacted.fetch("env").fetch("OPENAI_API_KEY")
    assert_equal "safe", redacted.fetch("credentials").fetch("username")
    assert_equal "en_US", redacted.fetch("env").fetch("LANG")
  end

  def test_redacts_prompt_source_body_and_command_stderr_fields
    value = {
      "prompt" => "private prompt body",
      "prompt_body" => "another private prompt body",
      "source_body" => "message body",
      "stderr" => "command diagnostics",
      "nested" => [{"body" => "raw source body"}]
    }

    redacted = @redactor.call(value)

    assert_equal "[REDACTED]", redacted.fetch("prompt")
    assert_equal "[REDACTED]", redacted.fetch("prompt_body")
    assert_equal "[REDACTED]", redacted.fetch("source_body")
    assert_equal "[REDACTED]", redacted.fetch("stderr")
    assert_equal "[REDACTED]", redacted.fetch("nested").first.fetch("body")
  end

  def test_redacts_known_secret_values_inside_otherwise_safe_strings
    value = "Authorization: Bearer abcdefghijklmnop; token=sk-proj-abcdefghijklmnopqrstuvwxyz123456"

    redacted = @redactor.call(value)

    refute_includes redacted, "abcdefghijklmnop"
    refute_includes redacted, "sk-proj-abcdefghijklmnopqrstuvwxyz123456"
    assert_equal 2, redacted.scan("[REDACTED]").length
  end

  def test_does_not_mutate_input
    value = {"api_key" => "secret"}

    @redactor.call(value)

    assert_equal "secret", value.fetch("api_key")
  end
end
