# frozen_string_literal: true

require_relative "../../test_helper"
require "open3"
require "rbconfig"

class CommandBackendTest < Minitest::Test
  def test_invokes_configured_command_with_json_and_parses_candidates
    Dir.mktmpdir do |tmpdir|
      script = File.join(tmpdir, "backend.rb")
      File.write(script, <<~RUBY)
        require "json"
        packet = JSON.parse($stdin.read)
        puts JSON.generate("candidates" => [{"type" => "learning", "title" => packet.fetch("marker")}])
      RUBY
      backend = Motherbrain::Candidates::CommandBackend.new([RbConfig.ruby, script])

      result = backend.analyze(packet: {"marker" => "received"}, timeout_seconds: 2)

      assert_equal "received", result.fetch("candidates").first.fetch("title")
    end
  end

  def test_nonzero_exit_malformed_output_and_timeout_fail_open
    Dir.mktmpdir do |tmpdir|
      failing = File.join(tmpdir, "failing.rb")
      malformed = File.join(tmpdir, "malformed.rb")
      slow = File.join(tmpdir, "slow.rb")
      File.write(failing, "exit 3\n")
      File.write(malformed, "puts \'not json\'\n")
      File.write(slow, "sleep 2\n")

      assert_nil Motherbrain::Candidates::CommandBackend.new([RbConfig.ruby, failing]).analyze(packet: {}, timeout_seconds: 1)
      assert_nil Motherbrain::Candidates::CommandBackend.new([RbConfig.ruby, malformed]).analyze(packet: {}, timeout_seconds: 1)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_nil Motherbrain::Candidates::CommandBackend.new([RbConfig.ruby, slow]).analyze(packet: {}, timeout_seconds: 0.1)
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
    end
  end

  def test_from_environment_requires_an_explicit_command
    assert_nil Motherbrain::Candidates::CommandBackend.from_environment({})
    assert_instance_of Motherbrain::Candidates::CommandBackend,
      Motherbrain::Candidates::CommandBackend.from_environment("MOTHERBRAIN_CANDIDATE_BACKEND" => "ruby backend.rb")
  end
end
