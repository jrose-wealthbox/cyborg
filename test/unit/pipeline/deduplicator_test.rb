# frozen_string_literal: true

require_relative "../../test_helper"
require "cyborg/pipeline/deduplicator"

class CyborgPipelineDeduplicatorTest < Minitest::Test
  def test_exact_content_duplicates_have_one_representative_and_preserve_all_members
    records = [record("source-a"), record("source-b")]

    result = Cyborg::Pipeline::Deduplicator.new.call(records)

    assert_equal 1, result.length
    assert_equal %w[source-a source-b], result.first.fetch("source_record_ids")
    assert_equal "same-fingerprint", result.first.fetch("content_fingerprint")
  end

  def test_different_fingerprints_are_not_deduplicated
    result = Cyborg::Pipeline::Deduplicator.new.call([record("a"), record("b", fingerprint: "other")])

    assert_equal 2, result.length
    assert_equal %w[a b], result.map { |item| item.fetch("source_record_ids").first }
  end

  private

  def record(id, fingerprint: "same-fingerprint")
    Cyborg::NormalizedRecord.new(
      source_record_id: id, record_kind: "notification", title: "Title", summary: "Summary",
      structured_fields: {"repository" => "acme/cyborg"}, participants: [], owner_identity: "me",
      canonical_target_type: "github_pr", canonical_target_id: "target", deep_link: nil,
      event_at: "2026-08-12T12:00:00Z", observed_at: "2026-08-12T12:01:00Z",
      timestamp_kind: "event_at", content_fingerprint: fingerprint, evidence: []
    )
  end
end
