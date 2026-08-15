# frozen_string_literal: true

require_relative "../test_helper"
require "open3"
require "sqlite3"

class CyborgInitCLITest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("cyborg-init-cli")
    @home = File.join(@tmpdir, "home")
    @outside = File.join(@tmpdir, "outside")
    @cwd = File.join(@tmpdir, "cwd")
    FileUtils.mkdir_p([@home, @outside, @cwd])
    @bin = File.expand_path("../../bin/cyborg", __dir__)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_init_creates_persistent_defaults_and_is_idempotent
    first = run_cli("init")

    assert_equal 0, first.fetch(:status), first.fetch(:stderr)
    assert_empty first.fetch(:stderr)
    document = parse_single_json_line(first.fetch(:stdout))
    assert_equal "initialized", document.fetch("status")
    assert_equal %w[config fixture database], document.fetch("created")

    config_before = File.binread(document.fetch("config_path"))
    second = run_cli("init")

    assert_equal 0, second.fetch(:status), second.fetch(:stderr)
    assert_empty second.fetch(:stderr)
    second_document = parse_single_json_line(second.fetch(:stdout))
    assert_equal "ready", second_document.fetch("status")
    assert_empty second_document.fetch("created")
    assert_equal config_before, File.binread(document.fetch("config_path"))
  end

  def test_explicit_config_overrides_environment_config
    environment_config = File.join(@tmpdir, "environment.toml")
    explicit_config = File.join(@tmpdir, "explicit.toml")
    write_minimal_config(environment_config)
    write_minimal_config(explicit_config)

    result = run_cli("init", "--config", explicit_config, env: {"CYBORG_CONFIG" => environment_config})

    assert_equal 0, result.fetch(:status), result.fetch(:stderr)
    document = parse_single_json_line(result.fetch(:stdout))
    assert_equal File.expand_path(explicit_config), document.fetch("config_path")
    assert_path_exists explicit_config
    refute_path_exists File.join(@home, ".config", "cyborg", "config.toml")
  end

  def test_init_works_outside_repository_cwd
    result = run_cli("init", chdir: @cwd)

    assert_equal 0, result.fetch(:status), result.fetch(:stderr)
    document = parse_single_json_line(result.fetch(:stdout))
    assert_equal File.join(@home, ".config", "cyborg", "config.toml"), document.fetch("config_path")
  end

  def test_init_rejects_extra_duplicate_and_missing_options
    cases = [
      ["extra", %w[init extra]],
      ["duplicate", ["init", "--config", File.join(@tmpdir, "one.toml"), "--config", File.join(@tmpdir, "two.toml")]],
      ["missing", %w[init --config]]
    ]

    cases.each do |name, arguments|
      result = run_cli(*arguments)

      assert_equal 64, result.fetch(:status), name
      assert_empty result.fetch(:stdout), name
      assert_includes result.fetch(:stderr), "cli.", name
    end
  end

  def test_invalid_existing_config_is_preserved
    config_path = File.join(@home, ".config", "cyborg", "config.toml")
    FileUtils.mkdir_p(File.dirname(config_path))
    File.chmod(0o700, File.join(@home, ".config"))
    File.chmod(0o700, File.dirname(config_path))
    File.binwrite(config_path, "not = [toml")
    before = File.binread(config_path)

    result = run_cli("init")

    assert_equal 78, result.fetch(:status)
    assert_empty result.fetch(:stdout)
    assert_includes result.fetch(:stderr), "config.invalid_toml"
    assert_equal before, File.binread(config_path)
  end

  def test_symlinked_config_parent_is_rejected_without_writing_outside_home
    File.symlink(@outside, File.join(@home, ".config"))

    result = run_cli("init")

    assert_equal 78, result.fetch(:status)
    assert_empty result.fetch(:stdout)
    assert_includes result.fetch(:stderr), "config.unsafe_path"
    refute_path_exists File.join(@outside, "cyborg", "config.toml")
  end

  def test_symlinked_config_final_path_is_rejected_without_overwriting_target
    config_path = File.join(@home, ".config", "cyborg", "config.toml")
    outside_config = File.join(@outside, "config.toml")
    FileUtils.mkdir_p(File.dirname(config_path))
    File.chmod(0o700, File.join(@home, ".config"))
    File.chmod(0o700, File.dirname(config_path))
    File.binwrite(outside_config, "keep")
    File.symlink(outside_config, config_path)

    result = run_cli("init")

    assert_equal 78, result.fetch(:status)
    assert_empty result.fetch(:stdout)
    assert_includes result.fetch(:stderr), "config.unsafe_path"
    assert_equal "keep", File.binread(outside_config)
  end

  def test_permission_failure_is_a_configuration_error
    state = File.join(@home, "state")
    FileUtils.mkdir_p(state)
    File.chmod(0o500, state)
    config_path = File.join(@tmpdir, "permission.toml")
    write_minimal_config(config_path)

    result = run_cli("init", "--config", config_path, env: {"CYBORG_STATE_DIR" => state})

    assert_equal 78, result.fetch(:status)
    assert_empty result.fetch(:stdout)
    assert_includes result.fetch(:stderr), "config."
  end

  def test_init_database_has_no_application_rows_and_success_is_compact_json
    result = run_cli("init")

    assert_equal 0, result.fetch(:status), result.fetch(:stderr)
    assert_empty result.fetch(:stderr)
    refute_includes result.fetch(:stdout), "\n\n"
    assert_equal 1, result.fetch(:stdout).lines.length
    document = parse_single_json_line(result.fetch(:stdout))
    database = SQLite3::Database.new(document.fetch("database_path"))
    begin
      %w[sources source_snapshots observed_records runs presentation_results publications].each do |table|
        next unless database.table_info(table).any?

        assert_empty database.execute("SELECT * FROM #{table}"), table
      end
    ensure
      database.close
    end
  end

  def test_init_installs_private_file_and_directory_modes
    document = parse_single_json_line(run_cli("init").fetch(:stdout))

    assert_equal 0o700, File.stat(document.fetch("state_dir")).mode & 0o777
    %w[config_path fixture_path database_path].each do |key|
      assert_equal 0o600, File.stat(document.fetch(key)).mode & 0o777, key
    end
    assert_equal 0o700, File.stat(File.dirname(document.fetch("config_path"))).mode & 0o777
  end

  private

  def parse_single_json_line(stdout)
    assert_equal 1, stdout.lines.length
    JSON.parse(stdout)
  end

  def run_cli(*arguments, env: {}, chdir: nil)
    base_env = {"HOME" => @home, "CYBORG_CONFIG" => nil, "RUBYOPT" => nil}.merge(env)
    options = chdir ? {chdir:} : {}
    stdout, stderr, status = Open3.capture3(base_env, @bin, *arguments, **options)
    {stdout:, stderr:, status: status.exitstatus}
  end

  def write_minimal_config(path)
    File.write(path, <<~TOML)
      [runtime]
      profile = "default"
      timezone = "UTC"
      lease_timeout_seconds = 600
      analysis_timeout_seconds = 300

      [budget]
      ceiling_micros = 5000000

      [cache]
      ordinary_ttl_seconds = 1800
      expensive_ttl_seconds = 14400

      [calendar.profiles.default]
      timezone = "UTC"
      weekend_days = ["saturday", "sunday"]
      easter = false
    TOML
  end
end
