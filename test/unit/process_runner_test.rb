# frozen_string_literal: true

require_relative "../test_helper"
require "rbconfig"
require "cyborg/process_runner"

class CyborgProcessRunnerTest < Minitest::Test
  def setup
    @runner = Cyborg::ProcessRunner.new
  end

  def test_capture_is_argv_only_and_does_not_invoke_a_shell
    result = @runner.capture(
      argv: [RbConfig.ruby, "-e", "print ARGV.fetch(0)", "literal; echo escaped"],
      timeout: 2, max_bytes: 128, env: {}
    )

    assert_predicate result, :success?
    assert_equal "literal; echo escaped", result.stdout
  end

  def test_capture_truncates_output_at_the_configured_combined_byte_bound
    result = @runner.capture(
      argv: [RbConfig.ruby, "-e", "print '0123456789'"], timeout: 2, max_bytes: 5, env: {}
    )

    assert result.truncated
    assert_operator result.stdout.bytesize + result.stderr.bytesize, :<=, 5
    refute_predicate result, :success?
  end

  def test_capture_marks_a_child_that_exceeds_the_wall_clock_bound
    result = @runner.capture(
      argv: [RbConfig.ruby, "-e", "sleep 1"], timeout: 0.05, max_bytes: 128, env: {}
    )

    assert result.timed_out
    refute_predicate result, :success?
  end
end
