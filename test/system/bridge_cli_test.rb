# frozen_string_literal: true

require_relative "../test_helper"
require "open3"
require "sqlite3"

class CyborgBridgeCLITest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("cyborg-bridge-cli")
    @state = File.join(@tmpdir, "state")
    @artifacts = File.join(@tmpdir, "artifacts")
    @config = File.join(@tmpdir, "config.toml")
    File.write(@config, <<~TOML)
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

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_prepare_packet_record_result_and_latest_render_workflow
    prepared = run_cli("prepare", "--profile", "default", "--artifact-dir", @artifacts)
    assert_equal 0, prepared[:status], prepared[:stderr]
    handoff = JSON.parse(prepared[:stdout])
    run_id = handoff.fetch("run_id")
    lease_file = handoff.fetch("lease_file")
    assert File.file?(lease_file)
    refute_includes prepared[:stdout], File.read(lease_file).strip
    assert_equal "running", handoff.fetch("status")

    packet_path = File.join(@artifacts, run_id, "analysis-packet.json")
    packet = run_cli("analysis-packet", "--run", run_id, "--lease-file", lease_file, "--output", packet_path)
    assert_equal 0, packet[:status], packet[:stderr]
    packet_document = JSON.parse(File.read(packet_path))
    assert_equal "analysis_packet", packet_document.fetch("artifact_type")

    result_path = File.join(@artifacts, run_id, "analysis-result.json")
    result_payload = {"claims" => [], "usage" => {}, "task_results" => [], "backend_metadata" => {}}
    result_document = Cyborg::Bridge::Envelope.build(
      type: "analysis_result", run_id:, payload: result_payload, created_at: Time.now.utc
    )
    File.write(result_path, Cyborg::Bridge::CanonicalJSON.dump(result_document))
    recorded = run_cli("record-result", "--run", run_id, "--lease-file", lease_file, "--input", result_path)
    assert_equal 0, recorded[:status], recorded[:stderr]
    assert_equal "completed", JSON.parse(recorded[:stdout]).fetch("status")
    refute File.exist?(lease_file)
    duplicate = run_cli("record-result", "--run", run_id, "--lease-file", lease_file, "--input", result_path)
    assert_equal 0, duplicate[:status], duplicate[:stderr]

    rendered_json = run_cli("render", "--format", "json")
    assert_equal 0, rendered_json[:status], rendered_json[:stderr]
    assert_equal run_id, JSON.parse(rendered_json[:stdout]).dig("run", "id")

    rendered_markdown = run_cli("render", "--run", run_id, "--format", "markdown")
    assert_equal 0, rendered_markdown[:status], rendered_markdown[:stderr]
    assert_includes rendered_markdown[:stdout], "# CYBORG"
  end

  def test_unsupported_option_is_usage_error
    result = run_cli("prepare", "--unexpected", "value")

    assert_equal 64, result[:status]
    assert_empty result[:stdout]
    assert_includes result[:stderr], "cli.unsupported_option"
  end

  def test_prepare_rejects_undocumented_execution_mode
    result = run_cli("prepare", "--profile", "default", "--artifact-dir", @artifacts, "--execution-mode", "host")

    assert_equal 64, result[:status]
    assert_empty result[:stdout]
    assert_includes result[:stderr], "cli.unsupported_option"
  end

  def test_second_prepare_reports_active_lease
    first = run_cli("prepare", "--profile", "default", "--artifact-dir", @artifacts)
    assert_equal 0, first[:status], first[:stderr]

    second = run_cli("prepare", "--profile", "default", "--artifact-dir", @artifacts)
    assert_equal 75, second[:status]
    assert_includes second[:stderr], "run.lease_busy"
  end

  def test_abandon_releases_unfinished_run
    prepared = run_cli("prepare", "--profile", "default", "--artifact-dir", @artifacts)
    handoff = JSON.parse(prepared[:stdout])

    abandoned = run_cli(
      "runs", "abandon", "--run", handoff.fetch("run_id"), "--lease-file", handoff.fetch("lease_file"),
      "--reason", "user cancelled"
    )

    assert_equal 0, abandoned[:status], abandoned[:stderr]
    assert_equal "failed", JSON.parse(abandoned[:stdout]).fetch("status")
    refute File.exist?(handoff.fetch("lease_file"))
  end

  def test_required_host_response_must_be_ingested_before_packet
    File.open(@config, "a") do |file|
      file.write(<<~TOML)

        [sources.github]
        enabled = true
        adapter = "github"
        transport = "host_bridge"
        account = "me"
        required = true
        capabilities = ["notifications"]
        [sources.github.operations]
        notifications = "github.notifications.read"
      TOML
    end
    prepared = run_cli("prepare", "--profile", "default", "--artifact-dir", @artifacts)
    assert_equal 0, prepared[:status], prepared[:stderr]
    handoff = JSON.parse(prepared[:stdout])
    run_id = handoff.fetch("run_id")
    request_document = JSON.parse(File.read(handoff.fetch("retrieval_requests")))
    request = request_document.fetch("payload").fetch(0)
    packet = run_cli("analysis-packet", "--run", run_id, "--lease-file", handoff.fetch("lease_file"))
    assert_equal 64, packet[:status]
    assert_includes packet[:stderr], "bridge.required_response_missing"

    forged_response_path = File.join(@artifacts, run_id, "retrieval-response-#{request.fetch("id")}.json")
    forged_payload = {
      "responses" => [{
        "request_id" => request.fetch("id"), "status" => "healthy", "data_status" => "fresh",
        "started_at" => request.fetch("window_start_utc"), "completed_at" => request.fetch("window_end_utc"),
        "records" => [], "next_cursor" => "page:2"
      }]
    }
    forged_envelope = Cyborg::Bridge::Envelope.build(
      type: "retrieval_responses", run_id:, payload: forged_payload, created_at: Time.now.utc
    )
    File.write(forged_response_path, Cyborg::Bridge::CanonicalJSON.dump(forged_envelope))
    forged_packet = run_cli("analysis-packet", "--run", run_id, "--lease-file", handoff.fetch("lease_file"))
    assert_equal 64, forged_packet[:status]
    assert_includes forged_packet[:stderr], "bridge.required_response_missing"
    File.delete(forged_response_path)

    response_payload = {
      "responses" => [{
        "request_id" => request.fetch("id"), "status" => "healthy", "data_status" => "fresh",
        "started_at" => request.fetch("window_start_utc"), "completed_at" => request.fetch("window_end_utc"),
        "records" => [{
          "source_record_id" => "host-record", "record_kind" => "notification", "title" => "Host record",
          "summary" => "A bounded host record", "structured_fields" => {"repository" => "acme/cyborg"},
          "participants" => [], "owner_identity" => "me", "canonical_target_type" => "github_issue",
          "canonical_target_id" => "issue-1", "deep_link" => "https://github.example/acme/cyborg/issues/1",
          "event_at" => request.fetch("window_end_utc"), "observed_at" => request.fetch("window_end_utc"),
          "timestamp_kind" => "event_at", "content_fingerprint" => "host-fp",
          "evidence" => [{"source_url" => "https://github.example/acme/cyborg/issues/1", "source_label" => "GitHub",
                          "evidence_at" => request.fetch("window_end_utc"), "relation" => "supports"}]
        }], "next_cursor" => nil
      }]
    }
    response_path = File.join(@artifacts, run_id, "host-responses.json")
    envelope = Cyborg::Bridge::Envelope.build(type: "retrieval_responses", run_id:, payload: response_payload, created_at: Time.now.utc)
    File.write(response_path, Cyborg::Bridge::CanonicalJSON.dump(envelope))
    ingested = run_cli("ingest", "--run", run_id, "--lease-file", handoff.fetch("lease_file"), "--input", response_path)
    assert_equal 0, ingested[:status], ingested[:stderr]
    duplicate = run_cli("ingest", "--run", run_id, "--lease-file", handoff.fetch("lease_file"), "--input", response_path)
    assert_equal 0, duplicate[:status], duplicate[:stderr]
    changed_payload = response_payload.dup
    changed_payload["responses"] = Marshal.load(Marshal.dump(response_payload.fetch("responses")))
    changed_payload["responses"].first["next_cursor"] = "page:2"
    changed_envelope = Cyborg::Bridge::Envelope.build(type: "retrieval_responses", run_id:, payload: changed_payload, created_at: Time.now.utc)
    File.write(response_path, Cyborg::Bridge::CanonicalJSON.dump(changed_envelope))
    changed = run_cli("ingest", "--run", run_id, "--lease-file", handoff.fetch("lease_file"), "--input", response_path)
    assert_equal 65, changed[:status]
    audit_path = File.join(@artifacts, run_id, "artifact-audit.json")
    audit = JSON.parse(File.read(audit_path))
    assert_equal "bridge.changed_response", audit.fetch("entries").last.fetch("code")
    assert_equal request.fetch("id"), audit.fetch("entries").last.fetch("request_id")
    refute_includes File.read(audit_path), "page:2"
    packet = run_cli("analysis-packet", "--run", run_id, "--lease-file", handoff.fetch("lease_file"))
    assert_equal 0, packet[:status], packet[:stderr]
    packet_document = JSON.parse(File.read(File.join(@artifacts, run_id, "analysis-packet.json")))
    assert_equal 1, packet_document.fetch("payload").fetch("records").length
  end

  def test_sequential_host_batches_for_one_source_account_share_one_snapshot
    File.open(@config, "a") do |file|
      file.write(<<~TOML)

        [sources.github]
        enabled = true
        adapter = "github"
        transport = "host_bridge"
        account = "me"
        required = true
        capabilities = ["notifications", "mentions", "reviews"]
        [sources.github.operations]
        notifications = "github.notifications.read"
        mentions = "github.mentions.read"
        reviews = "github.reviews.read"
      TOML
    end

    prepared = run_cli("prepare", "--profile", "default", "--artifact-dir", @artifacts)
    assert_equal 0, prepared[:status], prepared[:stderr]
    handoff = JSON.parse(prepared[:stdout])
    run_id = handoff.fetch("run_id")
    requests = JSON.parse(File.read(handoff.fetch("retrieval_requests"))).fetch("payload")
    assert_equal 3, requests.length

    responses = requests.each_with_index.map do |request, index|
      {
        "request_id" => request.fetch("id"), "status" => "healthy", "data_status" => "fresh",
        "started_at" => request.fetch("window_start_utc"), "completed_at" => request.fetch("window_end_utc"),
        "records" => [{
          "source_record_id" => "shared-batch-record", "record_kind" => "notification",
          "title" => index < 2 ? "Shared batch record" : "Conflicting batch record", "summary" => "A bounded batch record",
          "structured_fields" => {"batch" => index + 1}, "participants" => [], "owner_identity" => "me",
          "event_at" => request.fetch("window_end_utc"), "observed_at" => request.fetch("window_end_utc"),
          # Deliberately reuse a claimed fingerprint for a changed payload. The
          # bridge must recompute identity from canonical record content.
          "timestamp_kind" => "event_at", "content_fingerprint" => "shared-batch-fp"
        }], "next_cursor" => "capability:#{index + 1}"
      }
    end

    first_path = File.join(@artifacts, run_id, "batch-one.json")
    first_envelope = Cyborg::Bridge::Envelope.build(
      type: "retrieval_responses", run_id:, payload: {"responses" => [responses.fetch(0)]}, created_at: Time.now.utc
    )
    File.write(first_path, Cyborg::Bridge::CanonicalJSON.dump(first_envelope))
    first = run_cli("ingest", "--run", run_id, "--lease-file", handoff.fetch("lease_file"), "--input", first_path)
    assert_equal 0, first[:status], first[:stderr]

    forged_path = File.join(@artifacts, run_id, "retrieval-response-#{requests.fetch(1).fetch("id")}.json")
    forged_envelope = Cyborg::Bridge::Envelope.build(
      type: "retrieval_responses", run_id:, payload: {"responses" => [responses.fetch(1)]}, created_at: Time.now.utc
    )
    File.write(forged_path, Cyborg::Bridge::CanonicalJSON.dump(forged_envelope))
    forged_third_path = File.join(@artifacts, run_id, "retrieval-response-#{requests.fetch(2).fetch("id")}.json")
    forged_third_envelope = Cyborg::Bridge::Envelope.build(
      type: "retrieval_responses", run_id:, payload: {"responses" => [responses.fetch(2)]}, created_at: Time.now.utc
    )
    File.write(forged_third_path, Cyborg::Bridge::CanonicalJSON.dump(forged_third_envelope))
    blocked = run_cli("analysis-packet", "--run", run_id, "--lease-file", handoff.fetch("lease_file"))
    assert_equal 64, blocked[:status]
    assert_includes blocked[:stderr], "bridge.required_response_missing"

    second_path = File.join(@artifacts, run_id, "batch-two.json")
    second_envelope = Cyborg::Bridge::Envelope.build(
      type: "retrieval_responses", run_id:, payload: {"responses" => [responses.fetch(2)]}, created_at: Time.now.utc
    )
    File.write(second_path, Cyborg::Bridge::CanonicalJSON.dump(second_envelope))
    second = run_cli("ingest", "--run", run_id, "--lease-file", handoff.fetch("lease_file"), "--input", second_path)
    assert_equal 0, second[:status], second[:stderr]

    database = SQLite3::Database.new(File.join(@state, "cyborg.sqlite3"))
    snapshot_count = database.get_first_value("SELECT COUNT(*) FROM source_snapshots WHERE run_id = ?", run_id)
    record_count = database.get_first_value("SELECT COUNT(*) FROM snapshot_records WHERE snapshot_id IN (SELECT id FROM source_snapshots WHERE run_id = ?)", run_id)
    membership_count = database.get_first_value("SELECT COUNT(*) FROM source_snapshot_requests WHERE run_id = ?", run_id)
    observed_record_count = database.get_first_value("SELECT COUNT(*) FROM observed_records WHERE source_name = 'github' AND account_identity = 'me'")
    selected_title = database.get_first_value("SELECT title FROM observed_records WHERE source_name = 'github' AND account_identity = 'me'")
    version_count = database.get_first_value("SELECT COUNT(*) FROM observed_record_versions")
    database.close
    assert_equal 1, snapshot_count
    assert_equal 1, record_count
    assert_equal 2, membership_count
    assert_equal 1, observed_record_count
    assert_equal "Conflicting batch record", selected_title
    assert_equal 2, version_count

    duplicate = run_cli("ingest", "--run", run_id, "--lease-file", handoff.fetch("lease_file"), "--input", second_path)
    assert_equal 0, duplicate[:status], duplicate[:stderr]

    still_blocked = run_cli("analysis-packet", "--run", run_id, "--lease-file", handoff.fetch("lease_file"))
    assert_equal 64, still_blocked[:status]
    assert_includes still_blocked[:stderr], "bridge.required_response_missing"

    # B has a valid-looking standard-path artifact, but it was never ingested.
    # Ingesting it explicitly should be the only event that establishes B's
    # membership and unblocks the required source.
    batch_b_path = File.join(@artifacts, run_id, "batch-b.json")
    batch_b_envelope = Cyborg::Bridge::Envelope.build(
      type: "retrieval_responses", run_id:, payload: {"responses" => [responses.fetch(1)]}, created_at: Time.now.utc
    )
    File.write(batch_b_path, Cyborg::Bridge::CanonicalJSON.dump(batch_b_envelope))
    batch_b = run_cli("ingest", "--run", run_id, "--lease-file", handoff.fetch("lease_file"), "--input", batch_b_path)
    assert_equal 0, batch_b[:status], batch_b[:stderr]

    changed_response = responses.fetch(0).merge("next_cursor" => "capability:changed")
    changed_path = File.join(@artifacts, run_id, "batch-changed.json")
    changed_envelope = Cyborg::Bridge::Envelope.build(
      type: "retrieval_responses", run_id:, payload: {"responses" => [changed_response]}, created_at: Time.now.utc
    )
    File.write(changed_path, Cyborg::Bridge::CanonicalJSON.dump(changed_envelope))
    changed = run_cli("ingest", "--run", run_id, "--lease-file", handoff.fetch("lease_file"), "--input", changed_path)
    assert_equal 65, changed[:status]

    packet = run_cli("analysis-packet", "--run", run_id, "--lease-file", handoff.fetch("lease_file"))
    assert_equal 0, packet[:status], packet[:stderr]
  end

  def test_prepare_ingests_bounded_fixture_source_without_network
    fixture_path = File.expand_path("../fixtures/sources/fixture-records.json", __dir__)
    File.open(@config, "a") do |file|
      file.write(<<~TOML)

        [sources.fixture]
        enabled = true
        adapter = "fixture"
        account = "fixture"
        path = "#{fixture_path}"
        [sources.fixture.limits]
        max_records = 2
        max_response_bytes = 65536
      TOML
    end

    prepared = run_cli("prepare", "--profile", "default", "--artifact-dir", @artifacts)
    assert_equal 0, prepared[:status], prepared[:stderr]
    handoff = JSON.parse(prepared[:stdout])
    database = SQLite3::Database.new(File.join(@state, "cyborg.sqlite3"))
    count = database.get_first_value("SELECT COUNT(*) FROM observed_records")
    database.close
    assert_equal 2, count

    packet = run_cli("analysis-packet", "--run", handoff.fetch("run_id"), "--lease-file", handoff.fetch("lease_file"))
    assert_equal 0, packet[:status], packet[:stderr]
    packet_document = JSON.parse(File.read(File.join(@artifacts, handoff.fetch("run_id"), "analysis-packet.json")))
    assert_equal 2, packet_document.fetch("payload").fetch("records").length
  end

  def test_schema_valid_but_rejected_analysis_publishes_degraded_result
    prepared = run_cli("prepare", "--profile", "default", "--artifact-dir", @artifacts)
    assert_equal 0, prepared[:status], prepared[:stderr]
    handoff = JSON.parse(prepared[:stdout])
    run_id = handoff.fetch("run_id")
    packet = run_cli("analysis-packet", "--run", run_id, "--lease-file", handoff.fetch("lease_file"))
    assert_equal 0, packet[:status], packet[:stderr]
    result_payload = {"claims" => [{"unexpected" => true}], "usage" => {}, "task_results" => [], "backend_metadata" => {}}
    result_path = File.join(@artifacts, run_id, "rejected-result.json")
    envelope = Cyborg::Bridge::Envelope.build(type: "analysis_result", run_id:, payload: result_payload, created_at: Time.now.utc)
    File.write(result_path, Cyborg::Bridge::CanonicalJSON.dump(envelope))

    result = run_cli("record-result", "--run", run_id, "--lease-file", handoff.fetch("lease_file"), "--input", result_path)
    assert_equal 0, result[:status], result[:stderr]
    assert_equal "degraded", JSON.parse(result[:stdout]).fetch("status")
  end

  private

  def run_cli(*arguments)
    env = {
      "CYBORG_CONFIG" => @config,
      "CYBORG_STATE_DIR" => @state,
      "CYBORG_ARTIFACT_DIR" => @artifacts,
      "RUBYOPT" => nil
    }
    stdout, stderr, status = Open3.capture3(env, File.expand_path("../../bin/cyborg", __dir__), *arguments)
    {stdout:, stderr:, status: status.exitstatus}
  end
end
