# frozen_string_literal: true

require_relative "../test_helper"

class CyborgAnalysisResultValidatorTest < Minitest::Test
  RUN_ID = "run-1"

  def setup
    @validator = Cyborg::Analysis::ResultValidator.new
    @packet = packet
    @valid_result = JSON.parse(File.read(File.expand_path("../fixtures/analysis/valid-result.json", __dir__)))
  end

  def test_valid_result_returns_frozen_normalized_claims_and_safe_metadata
    outcome = @validator.validate(packet: @packet, result: @valid_result)

    assert_instance_of Cyborg::Analysis::AnalysisOutcome, outcome
    assert_equal 1, outcome.claims.length
    claim = outcome.claims.first
    assert_equal "review", claim.action_kind
    assert_equal "github_pull_request", claim.canonical_subject_type
    assert_equal "node-42", claim.canonical_subject_id
    assert_equal "e1", claim.anchor_evidence_id
    assert_equal ["e1"], claim.evidence_ids
    assert_predicate outcome, :frozen?
    assert_predicate claim, :frozen?
    assert_equal "fixture", outcome.backend_metadata.fetch("backend")
    refute outcome.backend_metadata.key?("prompt_body")
  end

  def test_one_unknown_evidence_id_rejects_every_claim
    result = @valid_result.merge(
      "claims" => [valid_claim, valid_claim.merge("evidence_ids" => ["missing"])]
    )

    rejection = @validator.validate(packet: @packet, result: result)

    assert_equal "analysis.unknown_evidence", rejection.code
    assert_empty rejection.accepted_claims
  end

  def test_source_text_cannot_request_a_write
    result = @valid_result.merge(
      "claims" => [valid_claim.merge("requested_operation" => "github.merge")]
    )

    rejection = @validator.validate(packet: @packet, result: result)

    assert_equal "analysis.source_write_forbidden", rejection.code
    assert_empty rejection.claims
  end

  def test_rejects_unsupported_action_kind_and_out_of_range_confidence
    assert_equal "analysis.unsupported_action_kind", reject(valid_claim.merge("action_kind" => "merge")).code
    assert_equal "analysis.invalid_confidence", reject(valid_claim.merge("confidence" => 1.1)).code
    assert_equal "analysis.invalid_confidence", reject(valid_claim.merge("confidence" => "0.8")).code
  end

  def test_rejects_missing_anchor_and_untrusted_url
    assert_equal "analysis.missing_anchor_evidence", reject(
      valid_claim.merge("anchor_evidence_id" => "e2")
    ).code
    assert_equal "analysis.untrusted_url", reject(
      valid_claim.merge("source_url" => "https://evil.example/payload")
    ).code
  end

  def test_rejects_claim_limit_and_output_limit
    limited_packet = packet.merge("maximum_claim_count" => 1, "maximum_output_bytes" => 256)
    assert_equal "analysis.claim_limit", @validator.validate(
      packet: limited_packet, result: @valid_result.merge("claims" => [valid_claim, valid_claim])
    ).code

    oversized = @valid_result.merge("claims" => [valid_claim.merge("summary" => "x" * 300)])
    assert_equal "analysis.output_too_large", @validator.validate(
      packet: limited_packet, result: oversized
    ).code
  end

  def test_rejects_missing_required_claim_fields_and_invalid_dates
    assert_equal "analysis.missing_field", reject(valid_claim.reject { |key, _| key == "summary" }).code
    assert_equal "analysis.invalid_date", reject(valid_claim.merge("due_at" => "tomorrow")).code
    assert_equal "analysis.invalid_date", reject(valid_claim.merge("due_at" => "2026-08-14")).code
  end

  def test_rejects_undeclared_task_capability_and_dependency
    assert_equal "analysis.undeclared_task", reject(valid_claim.merge("task_id" => "invented")).code
    assert_equal "analysis.capability_mismatch", reject(
      valid_claim.merge("capability" => "high_reasoning")
    ).code
    assert_equal "analysis.dependency_mismatch", reject(
      valid_claim.merge("dependency_ids" => ["unexpected"])
    ).code
  end

  def test_rejects_malformed_usage_without_persisting_claims
    result = @valid_result.merge(
      "claims" => [valid_claim, valid_claim],
      "usage" => {"certainty" => "provider_reported", "cost_micros" => "not-an-integer"}
    )

    rejection = @validator.validate(packet: @packet, result: result)

    assert_equal "analysis.invalid_usage", rejection.code
    assert_empty rejection.accepted_claims
  end

  def test_adversarial_instructions_in_evidence_are_data_not_operations
    adversarial = JSON.parse(File.read(File.expand_path("../fixtures/analysis/adversarial-result.json", __dir__)))

    outcome = @validator.validate(packet: @packet, result: adversarial)

    assert_equal 1, outcome.claims.length
    assert_match(/ignore previous instructions/i, outcome.claims.first.rationale)
  end

  def test_rejection_details_are_bounded_and_do_not_echo_source_or_prompt_bodies
    result = @valid_result.merge(
      "backend_metadata" => {"prompt_body" => "private prompt secret", "source_body" => "untrusted body"},
      "claims" => [valid_claim.merge("evidence_ids" => ["missing"])]
    )

    rejection = @validator.validate(packet: @packet, result: result)

    assert_equal "analysis.unknown_evidence", rejection.code
    refute_match(/private prompt|untrusted body|secret/i, rejection.details.to_s)
    assert_operator Cyborg::Bridge::CanonicalJSON.dump(rejection.details).bytesize, :<=, 512
  end

  private

  def valid_claim
    @valid_result.fetch("claims").first
  end

  def reject(claim)
    @validator.validate(packet: @packet, result: @valid_result.merge("claims" => [claim]))
  end

  def packet
    {
      "run_id" => RUN_ID,
      "allowed_action_kinds" => %w[follow_up investigate respond review],
      "records" => [
        {
          "source_record_id" => "record-1",
          "evidence_ids" => %w[e1 e2],
          "evidence" => [
            {"evidence_id" => "e1", "source_url" => "https://github.example/acme/cyborg/pull/42"},
            {"evidence_id" => "e2", "source_url" => "https://github.example/acme/cyborg/pull/42#discussion"}
          ]
        }
      ],
      "tasks" => [
        {"id" => "task-extract", "capability" => "cheap_structured_extraction", "dependency_ids" => [], "required" => true}
      ],
      "maximum_claim_count" => 25,
      "maximum_output_bytes" => 8_192,
      "limits" => {"maximum_claim_count" => 25, "maximum_output_bytes" => 8_192}
    }
  end
end
