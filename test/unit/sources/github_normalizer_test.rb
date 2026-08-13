# frozen_string_literal: true

require_relative "../../test_helper"
require "cyborg/sources/github_normalizer"

class CyborgGithubNormalizerTest < Minitest::Test
  def setup
    @normalizer = Cyborg::GithubNormalizer.new(hostname: "github.example")
    @context = Cyborg::RetrievalContext.new(
      source_name: "github", account_identity: "octocat",
      window_start_utc: "2026-08-12T00:00:00Z", window_end_utc: "2026-08-13T00:00:00Z",
      display_timezone: "UTC", limits: {max_records: 10}, filters: {}
    )
  end

  def test_normalizes_review_request_with_node_id_target_and_trusted_link
    record = @normalizer.normalize(
      {
        "id" => "review-and-ci", "reason" => "review_requested", "type" => "PullRequest",
        "subject" => {"title" => "Review this", "url" => "https://api.github.example/repos/acme/cyborg/pulls/42"},
        "repository" => {"full_name" => "acme/cyborg", "node_id" => "repo-node", "owner" => {"login" => "acme"}},
        "updated_at" => "2026-08-12T12:00:00Z"
      },
      context: @context,
      metadata: {
        "node_id" => "pull-node", "number" => 42, "title" => "Review this",
        "html_url" => "https://github.example/acme/cyborg/pull/42",
        "user" => {"login" => "author"}, "body" => "Please review",
        "updated_at" => "2026-08-12T12:00:00Z"
      }
    )

    assert_equal "review-and-ci", record.source_record_id
    assert_equal "review_request", record.record_kind
    assert_equal "github.example:repo-node:pull-node", record.canonical_target_id
    assert_equal "https://github.example/acme/cyborg/pull/42", record.deep_link
    assert_equal "author", record.owner_identity
    assert_equal "event_at", record.timestamp_kind
    assert_equal "review_requested", record.structured_fields.fetch("reason")
    assert_equal "Review this", record.title
    assert_equal "Please review", record.summary
    assert_equal "please review", record.evidence.first.excerpt.downcase
  end

  def test_rejects_untrusted_deep_link_and_uses_safe_constructed_url
    record = @normalizer.normalize(
      {
        "id" => "unsafe", "reason" => "mention", "type" => "IssueComment",
        "subject" => {"title" => "A comment", "url" => "https://api.github.example/repos/acme/cyborg/issues/42"},
        "repository" => {"full_name" => "acme/cyborg", "node_id" => "repo-node"},
        "updated_at" => "2026-08-12T12:00:00Z"
      },
      context: @context,
      metadata: {
        "node_id" => "issue-node", "number" => 42,
        "html_url" => "https://evil.example/acme/cyborg/issues/42",
        "user" => {"login" => "author"}, "body" => "Mentioned you",
        "updated_at" => "2026-08-12T12:00:00Z"
      }
    )

    assert_equal "https://github.example/acme/cyborg/issues/42", record.deep_link
    assert_equal record.deep_link, record.evidence.first.source_url
  end

  def test_ci_activity_is_filtered_but_another_reason_is_not
    ci = {"reason" => "ci_activity", "type" => "CheckSuite", "repository" => {"full_name" => "acme/cyborg"}}
    mixed = ci.merge("id" => "mixed", "reason" => "review_requested", "type" => "PullRequest")

    refute @normalizer.include_notification?(ci)
    assert @normalizer.include_notification?(mixed)
  end

  def test_comment_reason_in_reason_array_sets_latest_reply_timestamp
    record = @normalizer.normalize(
      {
        "id" => "comment", "reasons" => ["ci_activity", "comment"], "type" => "IssueComment",
        "subject" => {"title" => "A comment", "url" => "https://api.github.example/repos/acme/cyborg/pulls/42"},
        "repository" => {"full_name" => "acme/cyborg", "node_id" => "repo-node"},
        "updated_at" => "2026-08-12T12:00:00Z"
      },
      context: @context,
      metadata: {
        "node_id" => "pull-node", "number" => 42, "title" => "A comment",
        "html_url" => "https://github.example/acme/cyborg/pull/42", "body" => "Reply",
        "updated_at" => "2026-08-12T12:30:00Z"
      }
    )

    assert_equal "2026-08-12T12:30:00Z", record.latest_reply_at
    assert_equal "latest_reply_at", record.timestamp_kind
  end

  def test_normalizes_mentions_replies_and_assignments_to_stable_record_kinds
    [
      ["mention", "Issue", "mention"],
      ["comment", "IssueComment", "comment"],
      ["assign", "Issue", "assignment"],
      ["review", "PullRequestReview", "review"]
    ].each do |reason, type, expected_kind|
      record = @normalizer.normalize(
        {
          "id" => "#{reason}-record", "reason" => reason, "type" => type,
          "subject" => {"title" => "A #{reason}", "url" => "https://api.github.example/repos/acme/cyborg/pulls/42"},
          "repository" => {"full_name" => "acme/cyborg", "node_id" => "repo-node"},
          "updated_at" => "2026-08-12T12:00:00Z"
        },
        context: @context,
        metadata: {
          "node_id" => "pull-node", "number" => 42, "title" => "A #{reason}",
          "html_url" => "https://github.example/acme/cyborg/pull/42",
          "user" => {"login" => "octocat"}, "body" => "#{reason} body",
          "updated_at" => "2026-08-12T12:30:00Z"
        }
      )

      assert_equal expected_kind, record.record_kind, reason
      assert_equal "github_pr", record.canonical_target_type, reason
      assert_equal "github.example:repo-node:pull-node", record.canonical_target_id, reason
    end
  end

  def test_comment_reason_sets_latest_reply_timestamp_even_when_type_is_pull_request
    record = @normalizer.normalize(
      {
        "id" => "reply", "reason" => "comment", "type" => "PullRequest",
        "subject" => {"title" => "A reply", "url" => "https://api.github.example/repos/acme/cyborg/pulls/42"},
        "repository" => {"full_name" => "acme/cyborg", "node_id" => "repo-node"},
        "updated_at" => "2026-08-12T12:00:00Z"
      },
      context: @context,
      metadata: {
        "node_id" => "pull-node", "number" => 42, "title" => "A reply",
        "html_url" => "https://github.example/acme/cyborg/pull/42", "body" => "Reply",
        "updated_at" => "2026-08-12T12:30:00Z"
      }
    )

    assert_equal "2026-08-12T12:30:00Z", record.latest_reply_at
    assert_equal "latest_reply_at", record.timestamp_kind
  end

  def test_only_known_actionable_reasons_are_included
    refute @normalizer.include_notification?({"reason" => "ci_activity"})
    refute @normalizer.include_notification?({"reason" => "random_unrelated_reason"})
    assert @normalizer.include_notification?({"reasons" => ["ci_activity", "mention"]})
  end

  def test_comment_on_a_users_pull_request_uses_pull_request_target_identity
    record = @normalizer.normalize(
      {
        "id" => "users-pr-comment", "reason" => "comment", "type" => "IssueComment",
        "subject" => {"title" => "A comment", "url" => "https://api.github.example/repos/acme/cyborg/pulls/42"},
        "repository" => {"full_name" => "acme/cyborg", "node_id" => "repo-node"},
        "updated_at" => "2026-08-12T12:00:00Z"
      },
      context: @context,
      metadata: {
        "node_id" => "pull-node", "number" => 42, "title" => "My pull request",
        "html_url" => "https://github.example/acme/cyborg/pull/42",
        "user" => {"login" => "octocat"}, "body" => "A reply",
        "updated_at" => "2026-08-12T12:30:00Z"
      }
    )

    assert_equal "github_pr", record.canonical_target_type
    assert_equal "github.example:repo-node:pull-node", record.canonical_target_id
    assert_equal "octocat", record.owner_identity
    assert_equal "2026-08-12T12:30:00Z", record.latest_reply_at
  end

  def test_query_or_userinfo_on_same_host_is_not_a_trusted_deep_link
    record = @normalizer.normalize(
      {
        "id" => "unsafe-url", "reason" => "mention", "type" => "PullRequest",
        "subject" => {"title" => "Mention", "url" => "https://api.github.example/repos/acme/cyborg/pulls/42"},
        "repository" => {"full_name" => "acme/cyborg", "node_id" => "repo-node"}
      },
      context: @context,
      metadata: {
        "node_id" => "pull-node", "number" => 42,
        "html_url" => "https://octocat@github.example/acme/cyborg/pull/42?token=secret",
        "body" => "Mention"
      }
    )

    assert_equal "https://github.example/acme/cyborg/pull/42", record.deep_link
  end

  def test_issue_target_requires_both_repository_and_issue_node_ids
    record = @normalizer.normalize(
      {
        "id" => "missing-node", "reason" => "mention", "type" => "Issue",
        "subject" => {"title" => "Mention", "url" => "https://api.github.example/repos/acme/cyborg/issues/7"},
        "repository" => {"full_name" => "acme/cyborg", "node_id" => "repo-node"}
      },
      context: @context,
      metadata: {"number" => 7, "title" => "Mention", "body" => "Mention"}
    )

    assert_nil record
  end

  def test_numeric_rest_id_is_not_used_as_stable_target_identity
    record = @normalizer.normalize(
      {
        "id" => "numeric-id", "reason" => "mention", "type" => "Issue",
        "subject" => {"title" => "Mention", "url" => "https://api.github.example/repos/acme/cyborg/issues/7"},
        "repository" => {"full_name" => "acme/cyborg", "node_id" => "repo-node"}
      },
      context: @context,
      metadata: {"id" => 12345, "number" => 7, "title" => "Mention", "body" => "Mention"}
    )

    assert_nil record
  end

  def test_actionable_record_with_missing_or_hostile_subject_identity_is_excluded
    [
      {"title" => "Missing URL"},
      {"title" => "Hostile", "url" => "https://evil.example/repos/acme/cyborg/issues/7"},
      {"title" => "Missing number", "url" => "https://api.github.example/repos/acme/cyborg/issues/not-a-number"}
    ].each do |subject|
      record = @normalizer.normalize(
        {
          "id" => "invalid-subject", "reason" => "mention", "type" => "Issue",
          "subject" => subject,
          "repository" => {"full_name" => "acme/cyborg", "node_id" => "repo-node"}
        },
        context: @context,
        metadata: {"node_id" => "issue-node", "number" => 7, "title" => "Mention", "body" => "Mention"}
      )

      assert_nil record
    end
  end

  def test_whitespace_node_ids_are_invalid_and_never_emitted_as_target_identity
    ["repo-node", "issue-node"].each do |blank_id|
      repository = {"full_name" => "acme/cyborg", "node_id" => "repo-node"}
      metadata = {"node_id" => "issue-node", "number" => 7, "title" => "Mention", "body" => "Mention"}
      blank_id == "repo-node" ? repository["node_id"] = "  " : metadata["node_id"] = "\t"

      record = @normalizer.normalize(
        {
          "id" => "blank-node", "reason" => "mention", "type" => "Issue",
          "subject" => {"title" => "Mention", "url" => "https://api.github.example/repos/acme/cyborg/issues/7"},
          "repository" => repository
        },
        context: @context,
        metadata: metadata
      )

      assert_nil record, blank_id
    end
  end
end
