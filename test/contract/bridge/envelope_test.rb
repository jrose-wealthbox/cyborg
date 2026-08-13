# frozen_string_literal: true

require_relative "../../test_helper"

class BridgeEnvelopeTest < Minitest::Test
  Envelope = Cyborg::Bridge::Envelope
  RUN_ID = "018f5f62-3ef4-7d31-9e6d-8f6dfeddb847"
  TYPE = "analysis_result"

  def setup
    @payload = {
      "claims" => [{"subject" => "task", "status" => "open"}],
      "summary" => "A bounded result"
    }
    @created_at = Time.parse("2026-08-12 16:00:00 -0400")
    @document = Envelope.build(type: TYPE, run_id: RUN_ID, payload: @payload, created_at: @created_at)
  end

  def test_builds_protected_envelope_with_canonical_payload_fingerprint
    assert_equal({
      "schema_version" => "1.0",
      "artifact_type" => TYPE,
      "run_id" => RUN_ID,
      "created_at" => "2026-08-12T20:00:00Z",
      "payload_sha256" => Cyborg::Bridge::CanonicalJSON.sha256(@payload),
      "payload" => @payload
    }, @document)
  end

  def test_validate_returns_payload_for_supported_version
    assert_equal @payload, Envelope.validate!(@document, expected_type: TYPE, expected_run_id: RUN_ID)
  end

  def test_accepts_schema_version_1_0_and_ignores_unknown_optional_fields
    document = @document.merge("optional_future_metadata" => {"note" => "ignored"})

    assert_equal @payload, Envelope.validate!(document, expected_type: TYPE, expected_run_id: RUN_ID)
  end

  def test_rejects_unknown_artifact_type
    error = assert_raises(Cyborg::InvalidArtifact) do
      Envelope.build(type: "unknown", run_id: RUN_ID, payload: {}, created_at: @created_at)
    end

    assert_equal "bridge.unknown_type", error.code
  end

  def test_rejects_newer_minor_and_major_schema_versions
    ["1.1", "2.0"].each do |version|
      error = assert_raises(Cyborg::InvalidArtifact) do
        Envelope.validate!(@document.merge("schema_version" => version), expected_type: TYPE, expected_run_id: RUN_ID)
      end

      assert_equal "bridge.unsupported_version", error.code
    end
  end

  def test_rejects_numeric_and_noncanonical_schema_versions
    [1.0, "1.00"].each do |version|
      error = assert_raises(Cyborg::InvalidArtifact) do
        Envelope.validate!(@document.merge("schema_version" => version), expected_type: TYPE, expected_run_id: RUN_ID)
      end

      assert_equal "bridge.unsupported_version", error.code
    end
  end

  def test_rejects_noncanonical_non_utc_created_at_values
    ["2026-08-12T16:00:00-04:00", "2026-08-12T20:00:00+00:00"].each do |created_at|
      error = assert_raises(Cyborg::InvalidArtifact) do
        Envelope.validate!(@document.merge("created_at" => created_at), expected_type: TYPE, expected_run_id: RUN_ID)
      end

      assert_equal "bridge.invalid_created_at", error.code
    end
  end

  def test_error_messages_do_not_echo_untrusted_artifact_values
    error = assert_raises(Cyborg::InvalidArtifact) do
      Envelope.validate!(@document.merge("artifact_type" => "secret-token-value"), expected_type: TYPE, expected_run_id: RUN_ID)
    end

    assert_equal "bridge.unknown_type", error.message
    refute_includes error.message, "secret-token-value"
  end

  def test_rejects_payload_hash_mismatch
    error = assert_raises(Cyborg::InvalidArtifact) do
      Envelope.validate!(@document.merge("payload_sha256" => "0" * 64), expected_type: TYPE, expected_run_id: RUN_ID)
    end

    assert_equal "bridge.payload_hash_mismatch", error.code
  end

  def test_rejects_run_mismatch
    error = assert_raises(Cyborg::InvalidArtifact) do
      Envelope.validate!(@document, expected_type: TYPE, expected_run_id: "different-run")
    end

    assert_equal "bridge.run_mismatch", error.code
  end

  def test_rejects_expected_type_mismatch
    error = assert_raises(Cyborg::InvalidArtifact) do
      Envelope.validate!(@document, expected_type: "analysis_packet", expected_run_id: RUN_ID)
    end

    assert_equal "bridge.type_mismatch", error.code
  end
end
