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

  def test_init_dispatches_before_building_the_normal_container
    cli = Cyborg::CLI.new(stdout: @out, stderr: @err, env: {"HOME" => Dir.mktmpdir("cyborg-cli-init")})
    cli.define_singleton_method(:build_container) { |_config_path| flunk "init must not build the normal container" }

    status = cli.dispatch(["init"])

    assert_equal 0, status
    assert_empty @err.string
    assert_equal "initialized", JSON.parse(@out.string).fetch("status")
  ensure
    FileUtils.remove_entry(cli.instance_variable_get(:@env).fetch("HOME")) if cli
  end

  def test_container_uses_private_bootstrap_state_directory
    home = Dir.mktmpdir("cyborg-cli-home")
    state = File.join(home, "state")
    config = File.expand_path("../fixtures/config/minimal.toml", __dir__)
    env = {"HOME" => home, "CYBORG_STATE_DIR" => state}
    cli = Cyborg::CLI.new(stdout: @out, stderr: @err, env: env)

    container = cli.send(:build_container, config)
    begin
      assert_equal 0o700, File.stat(state).mode & 0o777
    ensure
      container.db.disconnect
      FileUtils.remove_entry(home)
    end
  end

  def test_existing_group_readable_state_directory_is_rejected
    home = Dir.mktmpdir("cyborg-cli-home")
    state = File.join(home, "state")
    FileUtils.mkdir_p(state)
    File.chmod(0o755, state)
    config = File.expand_path("../fixtures/config/minimal.toml", __dir__)
    cli = Cyborg::CLI.new(stdout: @out, stderr: @err, env: {"HOME" => home, "CYBORG_STATE_DIR" => state})

    assert_raises(Cyborg::InvalidConfiguration) { cli.send(:build_container, config) }
  ensure
    FileUtils.remove_entry(home) if home && File.exist?(home)
  end
end
