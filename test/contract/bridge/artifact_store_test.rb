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

  def test_reader_rejects_a_file_replaced_with_a_symlink_at_read_boundary
    backup_path = @valid_path.dirname.join("analysis-result.backup.json")
    File.rename(@valid_path, backup_path)
    File.symlink(backup_path, @valid_path)

    error = assert_raises(Cyborg::UnsafeArtifact) do
      @store.read(path: @valid_path, expected_type: "analysis_result", expected_run_id: RUN_ID)
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

  def test_reader_does_not_expose_raw_parser_errors
    malformed_path = @valid_path.dirname.join("malformed.json")
    File.binwrite(malformed_path, '{"secret":"do-not-echo"')

    error = assert_raises(Cyborg::InvalidArtifact) do
      @store.read(path: malformed_path, expected_type: "analysis_result", expected_run_id: RUN_ID)
    end

    assert_equal "bridge.invalid_json", error.code
    assert_equal "bridge.invalid_json", error.message
    refute_includes error.message, "do-not-echo"
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

  def test_cleanup_redacts_existing_audit_entries_before_reemitting_them
    old_envelope = Cyborg::Bridge::Envelope.build(
      type: "analysis_result", run_id: "audit-run", payload: {"ok" => true}, created_at: Time.utc(2026, 8, 12, 18)
    )
    @store.write(run_id: "audit-run", filename: "old.json", envelope: old_envelope)
    audit_path = @root.join("audit-run", "artifact-audit.json")
    File.write(audit_path, JSON.generate("entries" => [{"run_id" => "old", "stderr" => "secret stderr"}]))
    File.chmod(0o600, audit_path)

    @store.cleanup!(now: Time.utc(2026, 8, 12, 20), retention_seconds: 60)

    audit = File.read(@root.join("audit-run", "artifact-audit.json"))
    refute_includes audit, "secret stderr"
    assert_includes audit, "[REDACTED]"
  end

  def test_cleanup_rejects_a_symlinked_audit_file
    outside = Pathname(@tmpdir).join("outside-audit.json")
    File.write(outside, JSON.generate("entries" => []))
    audit_path = @valid_path.dirname.join("artifact-audit.json")
    File.delete(audit_path) if File.exist?(audit_path)
    File.symlink(outside, audit_path)
    old_envelope = Cyborg::Bridge::Envelope.build(
      type: "analysis_result", run_id: RUN_ID, payload: {"ok" => true}, created_at: Time.utc(2026, 8, 12, 18)
    )
    @store.write(run_id: RUN_ID, filename: "old.json", envelope: old_envelope)

    error = assert_raises(Cyborg::UnsafeArtifact) do
      @store.cleanup!(now: Time.utc(2026, 8, 12, 20), retention_seconds: 60)
    end

    assert_equal "bridge.unsafe_file", error.code
  end

  def test_cleanup_remains_anchored_when_run_path_is_replaced_after_metadata_validation
    old_envelope = Cyborg::Bridge::Envelope.build(
      type: "analysis_result", run_id: "swap-run", payload: {"ok" => true},
      created_at: Time.utc(2026, 8, 12, 18)
    )
    old_path = @store.write(run_id: "swap-run", filename: "old.json", envelope: old_envelope)
    outside = Pathname(@tmpdir).join("outside")
    FileUtils.mkdir_p(outside)
    outside_file = outside.join("old.json")
    FileUtils.cp(old_path, outside_file)
    run_directory = old_path.dirname
    saved_directory = Pathname(@tmpdir).join("saved-run")

    @store.singleton_class.prepend(Module.new do
      define_method(:metadata_for_fd) do |run_fd:, filename:, expected_run_id:|
        metadata = super(run_fd:, filename:, expected_run_id:)
        return metadata unless expected_run_id == "swap-run"
        File.rename(run_directory, saved_directory)
        File.symlink(outside, run_directory)
        metadata
      end
    end)

    @store.cleanup!(now: Time.utc(2026, 8, 12, 20), retention_seconds: 60)

    assert_path_exists outside_file
    refute_path_exists saved_directory.join("old.json")
    assert_path_exists saved_directory.join("artifact-audit.json")
    assert_path_exists run_directory
    assert File.symlink?(run_directory)
    audit = JSON.parse(File.read(saved_directory.join("artifact-audit.json")))
    assert_equal "swap-run", audit.fetch("entries").first.fetch("run_id")
  ensure
    FileUtils.remove_entry(run_directory) if run_directory && File.symlink?(run_directory)
    FileUtils.remove_entry(saved_directory) if saved_directory && File.exist?(saved_directory)
    FileUtils.remove_entry(outside) if outside && File.exist?(outside)
  end

  def test_cleanup_rejects_an_oversized_existing_audit_file_before_parsing
    audit_path = @valid_path.dirname.join("artifact-audit.json")
    File.binwrite(audit_path, "{" + ("x" * 4_096))
    old_envelope = Cyborg::Bridge::Envelope.build(
      type: "analysis_result", run_id: RUN_ID, payload: {"ok" => true}, created_at: Time.utc(2026, 8, 12, 18)
    )
    @store.write(run_id: RUN_ID, filename: "old.json", envelope: old_envelope)

    error = assert_raises(Cyborg::UnsafeArtifact) do
      @store.cleanup!(now: Time.utc(2026, 8, 12, 20), retention_seconds: 60)
    end

    assert_equal "bridge.oversized_file", error.code
  end

  def test_cleanup_rejects_oversized_payload_before_parsing
    old_path = @valid_path.dirname.join("oversized-old.json")
    File.binwrite(old_path, "{" + ("x" * 4_096))

    error = assert_raises(Cyborg::UnsafeArtifact) do
      @store.cleanup!(now: Time.utc(2026, 8, 12, 20), retention_seconds: 60)
    end

    assert_equal "bridge.oversized_file", error.code
  end

  def test_cleanup_rejects_non_object_json_payload_without_raw_type_errors
    non_object_path = @valid_path.dirname.join("array.json")
    File.write(non_object_path, "[]")

    error = assert_raises(Cyborg::InvalidArtifact) do
      @store.cleanup!(now: Time.utc(2026, 8, 12, 20), retention_seconds: 60)
    end

    assert_equal "bridge.invalid_envelope", error.code
    assert_equal "bridge.invalid_envelope", error.message
  end

  def test_cleanup_rejects_non_object_json_audit_without_raw_type_errors
    audit_path = @valid_path.dirname.join("artifact-audit.json")
    File.write(audit_path, "[]")
    old_envelope = Cyborg::Bridge::Envelope.build(
      type: "analysis_result", run_id: RUN_ID, payload: {"ok" => true}, created_at: Time.utc(2026, 8, 12, 18)
    )
    @store.write(run_id: RUN_ID, filename: "old.json", envelope: old_envelope)

    error = assert_raises(Cyborg::InvalidArtifact) do
      @store.cleanup!(now: Time.utc(2026, 8, 12, 20), retention_seconds: 60)
    end

    assert_equal "bridge.invalid_envelope", error.code
    assert_equal "bridge.invalid_envelope", error.message
  end

  def test_cleanup_validates_payload_fingerprint_before_deleting
    old_envelope = Cyborg::Bridge::Envelope.build(
      type: "analysis_result", run_id: RUN_ID, payload: {"ok" => true}, created_at: Time.utc(2026, 8, 12, 18)
    )
    old_path = @store.write(run_id: RUN_ID, filename: "tampered.json", envelope: old_envelope)
    tampered = JSON.parse(File.read(old_path))
    tampered["payload_sha256"] = "0" * 64
    File.write(old_path, JSON.generate(tampered))

    error = assert_raises(Cyborg::InvalidArtifact) do
      @store.cleanup!(now: Time.utc(2026, 8, 12, 20), retention_seconds: 60)
    end

    assert_equal "bridge.payload_hash_mismatch", error.code
    assert_path_exists old_path
  end
end
