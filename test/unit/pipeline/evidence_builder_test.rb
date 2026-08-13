# frozen_string_literal: true

require_relative "../../test_helper"
require "cyborg/pipeline/evidence_builder"

class CyborgPipelineEvidenceBuilderTest < Minitest::Test
  def test_evidence_ids_are_stable_and_untrusted_urls_are_not_emitted
    builder = Cyborg::Pipeline::EvidenceBuilder.new(trusted_hosts: ["github.example"])
    first = builder.call(record)
    second = builder.call(record)

    assert_equal first, second
    assert_equal 1, first.length
    assert_equal "https://github.example/acme/cyborg/pull/1", first.first.fetch("source_url")
    refute first.first.fetch("source_url").include?("evil.example")
    refute first.first.fetch("excerpt").include?("ghp_")
  end

  def test_different_record_ids_keep_duplicate_evidence_ids_distinct
    builder = Cyborg::Pipeline::EvidenceBuilder.new(trusted_hosts: ["github.example"])
    one = builder.call(record(source_record_id: "one")).first.fetch("evidence_id")
    two = builder.call(record(source_record_id: "two")).first.fetch("evidence_id")

    refute_equal one, two
  end

  private

  def record(source_record_id: "one")
    evidence = Cyborg::EvidenceDraft.new(
      source_url: "https://evil.example/steal?token=ghp_12345678901234567890",
      source_label: "GitHub", excerpt: "Review ghp_12345678901234567890",
      field_path: "body", evidence_at: "2026-08-12T12:00:00Z", relation: "supports"
    )
    Cyborg::NormalizedRecord.new(
      source_record_id:, record_kind: "notification", title: "Review", summary: "Review",
      structured_fields: {}, participants: [], owner_identity: "me", canonical_target_type: "github_pr",
      canonical_target_id: "target", deep_link: "https://github.example/acme/cyborg/pull/1",
      event_at: "2026-08-12T12:00:00Z", observed_at: "2026-08-12T12:01:00Z",
      timestamp_kind: "event_at", content_fingerprint: "fingerprint", evidence: [evidence]
    )
  end
end
