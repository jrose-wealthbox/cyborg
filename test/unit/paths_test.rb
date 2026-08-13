# frozen_string_literal: true

require_relative "../test_helper"

class CyborgPathsTest < Minitest::Test
  def test_environment_state_directory_overrides_configured_state_directory
    config = Cyborg::Config.load(
      path: File.expand_path("../fixtures/config/minimal.toml", __dir__),
      env: {}
    )

    paths = Cyborg::Paths.resolve(config: config, env: {"CYBORG_STATE_DIR" => "/tmp/cyborg-state"})

    assert_equal "/tmp/cyborg-state", paths.state.to_s
    assert_equal "/tmp/cyborg-state/cyborg.sqlite3", paths.database.to_s
    assert_equal "/tmp/cyborg-state/artifacts", paths.artifacts.to_s
    assert_equal "/tmp/cyborg-state/logs", paths.logs.to_s
    assert_equal "/tmp/cyborg-state/state.lock", paths.lock.to_s
  end

  def test_config_environment_variable_wins_over_default_path
    Tempfile.create(["cyborg-config", ".toml"]) do |file|
      file.write("[runtime]\ntimezone = \"UTC\"\n")
      file.flush
      config = Cyborg::Config.load(path: nil, env: {"CYBORG_CONFIG" => file.path})
      assert_equal File.expand_path(file.path), config.path.to_s
      assert_equal "UTC", config.profile.timezone
    end
  end
end
