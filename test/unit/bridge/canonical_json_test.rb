# frozen_string_literal: true

require_relative "../../test_helper"

class BridgeCanonicalJSONTest < Minitest::Test
  CanonicalJSON = Cyborg::Bridge::CanonicalJSON

  def test_canonical_dump_sorts_nested_keys_and_normalizes_time
    value = {"z" => {"b" => 2, "a" => 1}, "at" => Time.parse("2026-08-12 16:00:00 -0400")}

    assert_equal '{"at":"2026-08-12T20:00:00Z","z":{"a":1,"b":2}}', CanonicalJSON.dump(value)
  end

  def test_canonical_dump_retains_array_order
    assert_equal '[{"a":1,"b":2},1,"last"]', CanonicalJSON.dump([{"b" => 2, "a" => 1}, 1, "last"])
  end

  def test_canonical_dump_rejects_non_finite_numbers
    error = assert_raises(Cyborg::InvalidArtifact) { CanonicalJSON.dump(Float::NAN) }

    assert_equal "bridge.non_finite_number", error.code
  end

  def test_canonical_dump_rejects_non_string_and_non_symbol_object_keys
    error = assert_raises(Cyborg::InvalidArtifact) { CanonicalJSON.dump({1 => "not deterministic"}) }

    assert_equal "bridge.invalid_json_key", error.code
  end

  def test_sha256_is_the_digest_of_canonical_utf8_bytes
    value = {"message" => "café", "values" => [3, 2, 1]}

    assert_equal Digest::SHA256.hexdigest('{"message":"café","values":[3,2,1]}'), CanonicalJSON.sha256(value)
  end
end
