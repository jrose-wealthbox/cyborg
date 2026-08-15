# frozen_string_literal: true

require_relative "../../test_helper"

class CyborgBootstrapInitializerTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir("cyborg-bootstrap")
    @initializer = Cyborg::Bootstrap::Initializer.new
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def test_first_call_installs_assets_migrates_database_and_reports_created_order
    result = @initializer.call(env: {"HOME" => @home})

    assert_equal "initialized", result.status
    assert_equal %w[config fixture database], result.created
    assert File.file?(result.config_path)
    assert File.file?(result.fixture_path)
    assert File.file?(result.database_path)
    assert_equal 0o600, File.stat(result.config_path).mode & 0o777
    assert_equal 0o600, File.stat(result.fixture_path).mode & 0o777
  end

  def test_existing_invalid_config_is_unchanged
    path = File.join(@home, ".config", "cyborg", "config.toml")
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, "not = [toml")
    before = File.binread(path)

    assert_raises(Cyborg::InvalidConfiguration) { @initializer.call(env: {"HOME" => @home}) }
    assert_equal before, File.binread(path)
  end

  def test_existing_valid_config_and_fixture_are_preserved
    config_path = File.join(@home, "custom-config.toml")
    fixture_path = File.join(@home, ".config", "cyborg", "fixture-records.json")
    config = File.read(File.expand_path("../../../config/example.toml", __dir__))
      .sub('path = "~/.config/cyborg/fixture-records.json"', "path = \"#{fixture_path}\"")
    fixture = '{"next_cursor":"custom","records":[]}'
    File.binwrite(config_path, config)
    FileUtils.mkdir_p(File.dirname(fixture_path))
    File.chmod(0o700, File.join(@home, ".config"))
    File.chmod(0o700, File.dirname(fixture_path))
    File.binwrite(fixture_path, fixture)

    result = @initializer.call(config_path:, env: {"HOME" => @home})

    assert_equal "initialized", result.status
    assert_equal ["database"], result.created
    assert_equal config, File.binread(config_path)
    assert_equal fixture, File.binread(fixture_path)
  end

  def test_missing_bootstrap_fixture_is_recovered_but_missing_custom_fixture_is_rejected
    result = @initializer.call(env: {"HOME" => @home})
    assert_equal File.join(@home, ".config", "cyborg", "fixture-records.json"), result.fixture_path
    assert_equal File.binread(File.expand_path("../../../test/fixtures/sources/fixture-records.json", __dir__)),
      File.binread(result.fixture_path)

    custom_config_path = File.join(@home, "custom.toml")
    custom_fixture_path = File.join(@home, "elsewhere", "fixture-records.json")
    config = File.read(File.expand_path("../../../config/example.toml", __dir__))
      .sub('path = "~/.config/cyborg/fixture-records.json"', "path = \"#{custom_fixture_path}\"")
    File.binwrite(custom_config_path, config)

    error = assert_raises(Cyborg::InvalidConfiguration) do
      @initializer.call(config_path: custom_config_path, env: {"HOME" => @home})
    end
    assert_equal "config.invalid_fixture_path", error.code
  end

  def test_invalid_fixture_target_is_rejected_without_guessing
    config_path = File.join(@home, "relative-fixture.toml")
    config = File.read(File.expand_path("../../../config/example.toml", __dir__))
      .sub('path = "~/.config/cyborg/fixture-records.json"', 'path = "fixture-records.json"')
    File.binwrite(config_path, config)

    error = assert_raises(Cyborg::InvalidConfiguration) do
      @initializer.call(config_path:, env: {"HOME" => @home})
    end
    assert_equal "config.invalid_fixture_path", error.code
  end

  def test_initialization_migrates_empty_database_without_application_rows
    result = @initializer.call(env: {"HOME" => @home})
    db = Cyborg::Database.connect(path: result.database_path)
    begin
      %i[sources source_snapshots observed_records runs publications].each do |table|
        next unless db.tables.include?(table)

        assert_empty db[table].all
      end
    ensure
      db.disconnect
    end
  end

  def test_database_sidecars_are_private_while_connection_is_live
    result = @initializer.call(env: {"HOME" => @home})
    db = Cyborg::Database.connect(path: result.database_path)
    begin
      db.fetch("SELECT 1").all
      %W[#{result.database_path} #{result.database_path}-wal #{result.database_path}-shm].each do |path|
        assert File.file?(path), "expected #{path}"
        assert_equal 0o600, File.stat(path).mode & 0o777
      end
    ensure
      db.disconnect
    end
  end

  def test_retry_after_post_config_failure_completes_without_replacing_config
    calls = 0
    filesystem = Class.new(Cyborg::Bootstrap::SafeFilesystem) do
      define_method(:install) do |**kwargs|
        calls += 1
        raise Cyborg::InvalidConfiguration.new("config.persistence") if calls == 2

        super(**kwargs)
      end
    end.new
    initializer = Cyborg::Bootstrap::Initializer.new(filesystem:)

    assert_raises(Cyborg::InvalidConfiguration) { initializer.call(env: {"HOME" => @home}) }
    result = Cyborg::Bootstrap::Initializer.new.call(env: {"HOME" => @home})

    assert_equal %w[fixture database], result.created
    assert File.file?(result.fixture_path)
    assert File.file?(result.database_path)
  end
end
