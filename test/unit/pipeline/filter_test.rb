# frozen_string_literal: true

require_relative "../../test_helper"
require "cyborg/pipeline/filter"

class CyborgPipelineFilterTest < Minitest::Test
  def test_filters_by_window_repository_allowlist_and_selected_age_timestamp
    filter = Cyborg::Pipeline::Filter.new(
      window_start_utc: "2026-08-12T00:00:00Z",
      window_end_utc: "2026-08-13T00:00:00Z",
      filters: {"repositories" => ["acme/cyborg"]}
    )

    records = [
      record(id: "inside", event_at: "2026-08-11T00:00:00Z", latest_reply_at: "2026-08-12T12:00:00Z"),
      record(id: "wrong-repository", event_at: "2026-08-12T12:00:00Z", repository: "other/project"),
      record(id: "outside", event_at: "2026-08-14T00:00:00Z")
    ]

    assert_equal ["inside"], filter.call(records).map(&:source_record_id)
  end

  def test_filter_order_is_stable_for_different_input_order
    filter = Cyborg::Pipeline::Filter.new(
      window_start_utc: "2026-08-12T00:00:00Z", window_end_utc: "2026-08-13T00:00:00Z"
    )
    records = [record(id: "b"), record(id: "a")]

    assert_equal %w[a b], filter.call(records.reverse).map(&:source_record_id)
    assert_equal filter.call(records), filter.call(records.reverse)
  end

  private

  def record(id:, event_at: "2026-08-12T12:00:00Z", latest_reply_at: nil, repository: "acme/cyborg")
    Cyborg::NormalizedRecord.new(
      source_record_id: id, record_kind: "notification", title: id, summary: id,
      structured_fields: {"repository" => repository, "reason" => "review_requested"},
      participants: [], owner_identity: "me@example.com", canonical_target_type: "github_pr",
      canonical_target_id: "target-#{id}", deep_link: "https://github.example/acme/cyborg/pull/1",
      event_at:, latest_reply_at:, observed_at: "2026-08-12T12:00:00Z", timestamp_kind: "event_at",
      content_fingerprint: "fingerprint-#{id}", evidence: []
    )
  end
end
