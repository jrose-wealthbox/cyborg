# frozen_string_literal: true

require_relative "../../test_helper"

class BridgeArtifactStoreTest < Minitest::Test
  RUN_ID = "018f5f62-3ef4-7d31-9e6d-8f6dfeddb847"

  def setup
    @tmpdir = Dir.mktmpdir("cyborg-artifacts-")
    @root = Pathname(@tmpdir).join("artifacts")
    @store = Cyborg::Bridge::ArtifactStore.new(root: @root, max_bytes: 4_096, retention_seconds: 60)
    @payload = {"result" => "valid", "items" => [1, 2, 3]}
    @envelope = Cyborg::Bridge::Envelope.build(
      type: "analysis_result",
      run_id: RUN_ID,
      payload: @payload,
      created_at: Time.utc(2026, 8, 12, 20)
    )
    @valid_path = @store.write(run_id: RUN_ID, filename: "analysis-result.json", envelope: @envelope)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_write_and_read_round_trip_payload
    assert_equal @payload, @store.read(path: @valid_path, expected_type: "analysis_result", expected_run_id: RUN_ID)
  end

  def test_writer_protects_directory_and_file_modes
    assert_equal 0o700, (@valid_path.dirname.stat.mode & 0o7777)
    assert_equal 0o600, (@valid_path.stat.mode & 0o7777)
  end

  def test_reader_rejects_a_symlink
    link_path = @valid_path.dirname.join("link.json")
    File.symlink(@valid_path, link_path)

    error = assert_raises(Cyborg::UnsafeArtifact) do
      @store.read(path: link_path, expected_type: "analysis_result", expected_run_id: RUN_ID)
    end

    assert_equal "bridge.unsafe_file", error.code
  end

  def test_reader_rejects_a_symlinked_run_directory
    outside = Pathname(@tmpdir).join("outside")
    FileUtils.mkdir_p(outside)
    linked_path = outside.join("analysis-result.json")
    FileUtils.cp(@valid_path, linked_path)
    run_directory = @root.join(RUN_ID)
    FileUtils.remove_entry(run_directory)
    File.symlink(outside, run_directory)

    error = assert_raises(Cyborg::UnsafeArtifact) do
      @store.read(path: run_directory.join("analysis-result.json"), expected_type: "analysis_result", expected_run_id: RUN_ID)
    end

    assert_equal "bridge.unsafe_file", error.code
  end

  def test_writer_rejects_a_symlinked_run_directory
    outside = Pathname(@tmpdir).join("outside")
    FileUtils.mkdir_p(outside)
    run_directory = @root.join(RUN_ID)
    FileUtils.remove_entry(run_directory)
    File.symlink(outside, run_directory)

    error = assert_raises(Cyborg::UnsafeArtifact) do
      @store.write(run_id: RUN_ID, filename: "replacement.json", envelope: @envelope)
    end

    assert_equal "bridge.unsafe_file", error.code
  end

  def test_reader_rejects_oversized_file_before_parsing
    oversized_path = @valid_path.dirname.join("oversized.json")
    File.binwrite(oversized_path, "{" + ("x" * 4_096))

    error = assert_raises(Cyborg::UnsafeArtifact) do
      @store.read(path: oversized_path, expected_type: "analysis_result", expected_run_id: RUN_ID)
    end

    assert_equal "bridge.oversized_file", error.code
  end

  def test_write_replaces_existing_artifact_atomically
    replacement = Cyborg::Bridge::Envelope.build(
      type: "analysis_result",
      run_id: RUN_ID,
      payload: {"result" => "replacement"},
      created_at: Time.utc(2026, 8, 12, 20, 1)
    )

    replaced_path = @store.write(run_id: RUN_ID, filename: "analysis-result.json", envelope: replacement)

    assert_equal @valid_path, replaced_path
    assert_equal({"result" => "replacement"}, @store.read(path: replaced_path, expected_type: "analysis_result", expected_run_id: RUN_ID))
    refute Dir[@valid_path.dirname.join("*.tmp").to_s].any?
  end

  def test_cleanup_removes_expired_payload_and_keeps_bounded_redacted_audit_metadata
    old_envelope = Cyborg::Bridge::Envelope.build(
      type: "analysis_result",
      run_id: "old-run",
      payload: {"authorization" => "Bearer should-not-survive"},
      created_at: Time.utc(2026, 8, 12, 18)
    )
    old_path = @store.write(run_id: "old-run", filename: "old.json", envelope: old_envelope)

    @store.cleanup!(now: Time.utc(2026, 8, 12, 20), retention_seconds: 60)

    refute_path_exists old_path
    audit_path = old_path.dirname.join("artifact-audit.json")
    assert_path_exists audit_path
    audit = JSON.parse(File.read(audit_path))
    assert_equal "old-run", audit.fetch("entries").first.fetch("run_id")
    refute_includes File.read(audit_path), "should-not-survive"
  end
end
