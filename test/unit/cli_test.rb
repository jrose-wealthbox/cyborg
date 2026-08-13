# frozen_string_literal: true

require_relative "../test_helper"

class CyborgCLITest < Minitest::Test
  def setup
    @out = StringIO.new
    @err = StringIO.new
  end

  def test_version_is_machine_readable
    status = Cyborg::CLI.start(["version"], stdout: @out, stderr: @err, env: {})

    assert_equal 0, status
    assert_equal({"version" => Cyborg::VERSION}, JSON.parse(@out.string))
    assert_empty @err.string
  end

  def test_unknown_command_is_usage_error
    status = Cyborg::CLI.start(["surprise"], stdout: @out, stderr: @err, env: {})

    assert_equal 64, status
    assert_empty @out.string
    assert_match "cli.unknown_command", @err.string
  end
end
