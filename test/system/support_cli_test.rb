# frozen_string_literal: true

require_relative "../test_helper"
require "open3"
require "sqlite3"

class CyborgSupportCLITest < Minitest::Test
  NOW = "2026-08-13T12:00:00Z"

  def setup
    @tmpdir = Dir.mktmpdir("cyborg-support-cli")
    @home = File.join(@tmpdir, "home")
    @state = File.join(@tmpdir, "state")
    @artifacts = File.join(@tmpdir, "artifacts")
    @config = File.join(@tmpdir, "config.toml")
    FileUtils.mkdir_p([@state, @artifacts])
    FileUtils.mkdir_p(File.join(@home, ".config", "cyborg"))
    write_config(@config)
    FileUtils.cp(@config, File.join(@home, ".config", "cyborg", "config.toml"))
    seed_cache
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_config_path_honors_environment_and_default_local_path
    configured = run_cli("config", "path", env: {"CYBORG_CONFIG" => @config})
    assert_equal 0, configured[:status], configured[:stderr]
    assert_equal File.expand_path(@config), configured[:stdout].strip

    defaulted = run_cli("config", "path", env: {"CYBORG_CONFIG" => nil})
    assert_equal 0, defaulted[:status], defaulted[:stderr]
    assert_equal File.join(@home, ".config", "cyborg", "config.toml"), defaulted[:stdout].strip
  end

  def test_cache_aliases_mark_selected_rows_and_preserve_audit_rows
    ordinary = run_executable("bin/cyborg-no-cache")
    assert_equal 0, ordinary[:status], ordinary[:stderr]
    rows = cache_rows
    assert rows.fetch("ordinary").fetch(:invalidated_at)
    assert_nil rows.fetch("expensive").fetch(:invalidated_at)
    assert_equal "cyborg-no-cache", rows.fetch("ordinary").fetch(:invalidation_command)
    assert_equal "user_requested", rows.fetch("ordinary").fetch(:invalidation_reason)

    full = run_executable("bin/cyborg-no-cache-even-expensive")
    assert_equal 0, full[:status], full[:stderr]
    rows = cache_rows
    assert rows.fetch("ordinary").fetch(:invalidated_at)
    assert rows.fetch("expensive").fetch(:invalidated_at)
    assert_equal "cyborg-no-cache-even-expensive", rows.fetch("expensive").fetch(:invalidation_command)
    assert_equal 2, rows.length
  end

  def test_support_commands_reject_extra_arguments
    result = run_cli("config", "path", "extra")
    assert_equal 64, result[:status]
    assert_empty result[:stdout]
    assert_includes result[:stderr], "cli.unexpected_argument"
  end

  def test_cache_invalidation_rejects_unknown_class_and_bounds_redacted_reason
    invalid = run_cli("cache", "invalidate", "--classes", "mystery")
    assert_equal 64, invalid[:status]
    assert_empty invalid[:stdout]
    assert_includes invalid[:stderr], "cli.invalid_cache_class"

    reason = run_cli(
      "cache", "invalidate", "--classes", "ordinary", "--reason", "token=super-secret-#{'x' * 400}"
    )
    assert_equal 0, reason[:status], reason[:stderr]
    database = SQLite3::Database.new(File.join(@state, "cyborg.sqlite3"))
    stored = database.get_first_value(
      "SELECT invalidation_reason FROM cache_entries WHERE cache_class = 'ordinary'"
    )
    database.close
    assert_operator stored.bytesize, :<=, 256
    refute_includes stored, "super-secret"
  end

  private

  def write_config(path)
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

  def seed_cache
    database = Cyborg::Database.connect(path: File.join(@state, "cyborg.sqlite3"))
    database.migrate!
    %w[ordinary expensive].each do |cache_class|
      database[:cache_entries].insert(
        id: "cache-#{cache_class}", stage: "analysis", cache_key: "key-#{cache_class}", cache_class:,
        input_fingerprint: "input-#{cache_class}", created_at: NOW, expires_at: "2026-08-14T12:00:00Z",
        payload_json: JSON.generate("cache_class" => cache_class)
      )
    end
    database.disconnect
  end

  def cache_rows
    database = SQLite3::Database.new(File.join(@state, "cyborg.sqlite3"))
    database.results_as_hash = true
    rows = database.execute("SELECT cache_class, invalidated_at, invalidation_command, invalidation_reason FROM cache_entries")
    database.close
    rows.to_h { |row| [row.fetch("cache_class"), row.transform_keys(&:to_sym)] }
  end

  def run_executable(name)
    run_command(File.expand_path("../../#{name}", __dir__), env: {})
  end

  def run_cli(*arguments, env: {})
    run_command(File.expand_path("../../bin/cyborg", __dir__), arguments, env:)
  end

  def run_command(command, arguments = [], env: {})
    base_env = {
      "CYBORG_CONFIG" => @config, "CYBORG_STATE_DIR" => @state, "CYBORG_ARTIFACT_DIR" => @artifacts,
      "HOME" => @home, "RUBYOPT" => nil
    }.merge(env)
    stdout, stderr, status = Open3.capture3(base_env, command, *arguments)
    {stdout:, stderr:, status: status.exitstatus}
  end
end
