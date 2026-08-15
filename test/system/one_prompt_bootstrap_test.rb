# frozen_string_literal: true

require_relative "../test_helper"
require "open3"

class CyborgOnePromptBootstrapTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("cyborg-one-prompt")
    @home = File.join(@tmpdir, "home")
    @artifacts = File.join(@tmpdir, "artifacts")
    FileUtils.mkdir_p([@home, @artifacts])
    @bin = File.expand_path("../../bin/cyborg", __dir__)
    @repo = File.expand_path("../..", __dir__)
    @captures = []
    @protected_lease_bytes = []
    @analysis_backend_call_count = 0
    @ad_hoc_paths_before = ad_hoc_state_paths
    @repo_status_before = git_capture("status", "--short", "--ignored")
    @repo_binary_diff_before = git_capture("diff", "--binary")
  end

  def teardown
    assert_equal @repo_status_before, git_capture("status", "--short", "--ignored")
    assert_equal @repo_binary_diff_before, git_capture("diff", "--binary")
    FileUtils.remove_entry(@tmpdir)
  end

  def test_init_run_rerun_and_clean_shell_render_use_persistent_defaults
    initialized = cli("init")
    assert_equal 0, initialized.fetch(:status), initialized.fetch(:stderr)
    init_document = JSON.parse(initialized.fetch(:stdout))
    assert_equal "initialized", init_document.fetch("status")
    config_path = init_document.fetch("config_path")
    default_config_path = File.join(@home, ".config", "cyborg", "config.toml")
    assert_equal default_config_path, config_path
    assert_path_exists config_path
    assert_path_exists init_document.fetch("fixture_path")
    assert_path_exists init_document.fetch("database_path")

    append_analysis_task(config_path)
    first = fixture_bridge_run
    config_bytes_after_first = File.binread(config_path)
    second = fixture_bridge_run

    rendered = clean_shell_cli("render", "--format", "markdown")
    assert_equal 0, rendered.fetch(:status), rendered.fetch(:stderr)
    assert_includes rendered.fetch(:stdout), "# CYBORG"
    assert_equal first.fetch("item_ids"), second.fetch("item_ids")
    assert_equal %w[required cached], [first.fetch("analysis_status"), second.fetch("analysis_status")]
    assert_equal 1, @analysis_backend_call_count
    assert_equal config_bytes_after_first, File.binread(default_config_path)
    assert_equal @ad_hoc_paths_before, ad_hoc_state_paths
    assert_path_exists File.join(@home, "Library", "Application Support", "CYBORG", "cyborg.sqlite3")

    scan_captures!
  end

  def test_existing_invalid_default_config_is_unchanged_and_fails_closed
    config_path = File.join(@home, ".config", "cyborg", "config.toml")
    FileUtils.mkdir_p(File.dirname(config_path))
    File.chmod(0o700, File.join(@home, ".config"))
    File.chmod(0o700, File.dirname(config_path))
    File.binwrite(config_path, "not = [toml")
    before = File.binread(config_path)

    result = cli("init")

    assert_equal 78, result.fetch(:status)
    assert_empty result.fetch(:stdout)
    assert_equal "config.invalid_toml", result.fetch(:stderr).strip
    assert_equal before, File.binread(config_path)
    assert_equal @ad_hoc_paths_before, ad_hoc_state_paths
    scan_captures!
  end

  private

  def fixture_bridge_run
    prepared = cli("prepare", "--profile", "default", "--artifact-dir", @artifacts)
    assert_equal 0, prepared.fetch(:status), prepared.fetch(:stderr)
    handoff = JSON.parse(prepared.fetch(:stdout))
    lease_file = handoff.fetch("lease_file")
    lease_bytes = File.binread(lease_file)
    @protected_lease_bytes << lease_bytes
    refute_includes prepared.fetch(:stdout), lease_bytes

    packet_command = cli("analysis-packet", "--run", handoff.fetch("run_id"), "--lease-file", lease_file)
    assert_equal 0, packet_command.fetch(:status), packet_command.fetch(:stderr)
    packet_status = JSON.parse(packet_command.fetch(:stdout))
    analysis_status = packet_status.fetch("analysis_status")
    assert_includes %w[required cached], analysis_status

    result_path = if analysis_status == "required"
      @analysis_backend_call_count += 1
      write_analysis_result(handoff.fetch("run_id"), packet_status.fetch("output"))
    else
      cached_path = packet_status.fetch("analysis_result")
      assert_path_exists cached_path
      cached_path
    end
    recorded = cli(
      "record-result", "--run", handoff.fetch("run_id"), "--lease-file", lease_file, "--input", result_path
    )
    assert_equal 0, recorded.fetch(:status), recorded.fetch(:stderr)

    rendered = cli("render", "--run", handoff.fetch("run_id"), "--format", "markdown")
    assert_equal 0, rendered.fetch(:status), rendered.fetch(:stderr)
    item_ids = rendered.fetch(:stdout).lines.filter_map { |line| line[/\[([^\]]+)\]/, 1] }
    refute_empty item_ids
    {"item_ids" => item_ids, "analysis_status" => analysis_status}
  ensure
    @captures.concat([prepared, packet_command, recorded, rendered].compact.flat_map { |value| value.values_at(:stdout, :stderr) })
  end

  def write_analysis_result(run_id, packet_path)
    packet = JSON.parse(File.binread(packet_path)).fetch("payload")
    task = packet.fetch("tasks").fetch(0)
    payload = {
      "claims" => [],
      "usage" => {},
      "task_results" => [{
        "id" => task.fetch("id"), "task_id" => task.fetch("id"), "capability" => task.fetch("capability"),
        "dependency_ids" => task.fetch("dependency_ids", []), "status" => "succeeded", "claims" => [], "usage" => nil
      }],
      "backend_metadata" => {"backend" => "fixture"}
    }
    path = File.join(@artifacts, run_id, "host-analysis-result.json")
    envelope = Cyborg::Bridge::Envelope.build(type: "analysis_result", run_id:, payload:, created_at: Time.now.utc)
    File.binwrite(path, Cyborg::Bridge::CanonicalJSON.dump(envelope))
    path
  end

  def append_analysis_task(config_path)
    File.open(config_path, "a") do |file|
      file.write(<<~TOML)

        [analysis.tasks.task-1]
        capability = "cheap_structured_extraction"
        required = true
        reservation_micros = 1
      TOML
    end
  end

  def cli(*arguments)
    env = {
      "HOME" => @home, "PATH" => ENV.fetch("PATH"), "LANG" => "C", "LC_ALL" => "C",
      "CYBORG_RALPH_ARTIFACTS" => @artifacts, "CYBORG_CONFIG" => nil, "CYBORG_STATE_DIR" => nil,
      "CYBORG_DATABASE" => nil, "CYBORG_ARTIFACT_DIR" => nil, "CYBORG_LOG_DIR" => nil,
      "CYBORG_LOCK_FILE" => nil, "RUBYOPT" => nil
    }
    stdout, stderr, status = Open3.capture3(env, @bin, *arguments)
    value = {stdout:, stderr:, status: status.exitstatus}
    @captures.concat([stdout, stderr])
    value
  end

  def clean_shell_cli(*arguments)
    env = {
      "HOME" => @home, "PATH" => ENV.fetch("PATH"), "LANG" => "C", "LC_ALL" => "C",
      "CYBORG_CONFIG" => nil, "CYBORG_STATE_DIR" => nil, "CYBORG_DATABASE" => nil,
      "CYBORG_ARTIFACT_DIR" => nil, "CYBORG_LOG_DIR" => nil, "CYBORG_LOCK_FILE" => nil, "RUBYOPT" => nil
    }
    stdout, stderr, status = Open3.capture3(env, @bin, *arguments)
    value = {stdout:, stderr:, status: status.exitstatus}
    @captures.concat([stdout, stderr])
    value
  end

  def git_capture(*arguments)
    stdout, stderr, status = Open3.capture3("git", "-C", @repo, *arguments)
    assert_equal 0, status.exitstatus, stderr
    stdout
  end

  def ad_hoc_state_paths
    [
      "/tmp/cyborg-state", "/private/tmp/cyborg-state", "/private/tmp/cyborg-config.toml",
      File.join(@repo, "cyborg.sqlite3"), File.join(@repo, "state")
    ].select { |path| File.exist?(path) }
  end

  def scan_captures!
    raw = @captures.join("\n")
    redacted = Cyborg::Redactor.new.call(raw)
    secret_pattern = /-----BEGIN .*PRIVATE KEY-----|Bearer\s+\S+|\b(?:sk|ghp|xox[baprs])[-_][A-Za-z0-9_-]{10,}/i
    key_pattern = /(?:authorization|api[_-]?key|access[_-]?token|password|secret|credential)\s*[:=]\s*\S+/i
    refute_match(secret_pattern, raw)
    refute_match(key_pattern, raw)
    refute_match(secret_pattern, redacted)
    refute_match(key_pattern, redacted)
    @protected_lease_bytes.each { |lease| refute_includes raw, lease }
  end
end
