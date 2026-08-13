# frozen_string_literal: true

require_relative "../../test_helper"
require "cyborg/process_runner"
require "cyborg/sources/github_adapter"

class CyborgGithubAdapterTest < Minitest::Test
  ProcessReply = Struct.new(:stdout, :stderr, :status, :timed_out, :truncated, keyword_init: true) do
    def success?
      status.to_i.zero? && !timed_out && !truncated
    end
  end

  class FakeRunner
    attr_reader :argv

    def initialize(replies)
      @replies = replies
      @argv = []
    end

    def capture(argv:, timeout:, max_bytes:, env:)
      @argv << argv
      value = @replies.find do |key, _reply|
        key.is_a?(Regexp) ? argv.last.to_s.match?(key) : key.is_a?(String) && argv.last.to_s.include?(key)
      end&.last
      value = @replies.fetch(:default) unless value
      value.respond_to?(:call) ? value.call(argv, timeout, max_bytes, env) : value
    end
  end

  def setup
    @context = Cyborg::RetrievalContext.new(
      source_name: "github", account_identity: "octocat",
      window_start_utc: "2026-08-12T00:00:00Z", window_end_utc: "2026-08-13T00:00:00Z",
      display_timezone: "UTC", prior_cursor: nil,
      limits: {max_pages: 2, max_records: 10, max_response_bytes: 100_000},
      filters: {}
    )
    @runner = FakeRunner.new(
      /(?:\?|&)page=2(?:&|\z)/ => reply(fixture("github/notifications-page-2.json")),
      "notifications?" => reply(fixture("github/notifications-page-1.json")),
      "/pulls/42" => reply(fixture("github/pull-request.json")),
      :default => reply("[]")
    )
    @adapter = Cyborg::GithubAdapter.new(
      runner: @runner, gh: "/usr/local/bin/gh", hostname: "github.example", per_page: 2
    )
  end

  def test_fetch_uses_only_read_only_bounded_gh_api_calls
    result = @adapter.fetch(@context)

    assert_equal "healthy", result.status
    assert_operator result.records.length, :<=, @context.max_records
    assert @runner.argv.all? { |argv| argv.first(2) == ["/usr/local/bin/gh", "api"] || argv.first(3) == ["/usr/local/bin/gh", "auth", "status"] }
    refute @runner.argv.flatten.any? { |arg| %w[POST PATCH PUT DELETE].include?(arg) }
  end

  def test_ci_only_notification_is_excluded_but_review_request_is_retained
    records = @adapter.fetch(@context).records

    refute records.any? { |record| record.source_record_id == "ci-only" }
    assert records.any? { |record| record.source_record_id == "review-and-ci" }
  end

  def test_health_codes_distinguish_missing_binary_and_authentication
    missing = Cyborg::GithubAdapter.new(runner: MissingRunner.new, gh: "/missing/gh", hostname: "github.example")
    health = missing.health_check(@context)
    assert_equal "github.binary_missing", health.code

    unauthenticated_runner = FakeRunner.new(:default => reply("", "not logged in", 1))
    adapter = Cyborg::GithubAdapter.new(runner: unauthenticated_runner, gh: "gh", hostname: "github.example")
    assert_equal "github.unauthenticated", adapter.health_check(@context).code
  end

  def test_partial_page_holds_prior_cursor
    partial_context = @context.with(prior_cursor: "page:1", limits: {max_pages: 1, max_records: 10, max_response_bytes: 100_000})
    result = @adapter.fetch(partial_context)

    assert_equal "degraded", result.status
    assert_equal "github.invalid_response", result.error.code
    assert_equal "page:1", result.next_cursor
  end

  def test_short_final_page_is_healthy_when_page_budget_is_reached
    context = @context.with(prior_cursor: "page:2", limits: {max_pages: 1, max_records: 10, max_response_bytes: 100_000})
    result = @adapter.fetch(context)

    assert_equal "healthy", result.status
    assert_equal "page:3", result.next_cursor
    assert_nil result.error
  end

  def test_allowlists_are_applied_before_records_are_emitted
    adapter = Cyborg::GithubAdapter.new(
      runner: @runner, gh: "gh", hostname: "github.example", per_page: 2,
      repository_allowlist: ["other/repository"]
    )
    assert_empty adapter.fetch(@context).records
  end

  def test_organization_allowlist_is_applied_before_records_are_emitted
    adapter = Cyborg::GithubAdapter.new(
      runner: @runner, gh: "gh", hostname: "github.example", per_page: 2,
      organization_allowlist: ["other-org"]
    )

    assert_empty adapter.fetch(@context).records
  end

  def test_api_failure_and_timeout_use_api_unavailable_code
    api_failure = FakeRunner.new(
      "notifications?" => reply("service unavailable", "", 1),
      :default => reply(File.read(File.expand_path("../../fixtures/github/authenticated.json", __dir__)))
    )
    failure = Cyborg::GithubAdapter.new(runner: api_failure, gh: "gh", hostname: "github.example").fetch(@context)
    assert_equal "github.api_unavailable", failure.error.code

    timeout = FakeRunner.new(
      "notifications?" => reply("", "", nil, true),
      :default => reply(File.read(File.expand_path("../../fixtures/github/authenticated.json", __dir__)))
    )
    timed_out = Cyborg::GithubAdapter.new(runner: timeout, gh: "gh", hostname: "github.example").fetch(@context)
    assert_equal "github.api_unavailable", timed_out.error.code
  end

  def test_malformed_or_oversized_api_response_uses_invalid_response_code
    malformed = FakeRunner.new(
      "notifications?" => reply(fixture("github/malformed.json")),
      :default => reply(fixture("github/authenticated.json"))
    )
    malformed_result = Cyborg::GithubAdapter.new(runner: malformed, gh: "gh", hostname: "github.example").fetch(@context)
    assert_equal "github.invalid_response", malformed_result.error.code

    oversized = FakeRunner.new(
      "notifications?" => reply("[#{'{}' * 200}]", "", 0, false, true),
      :default => reply(fixture("github/authenticated.json"))
    )
    oversized_result = Cyborg::GithubAdapter.new(runner: oversized, gh: "gh", hostname: "github.example").fetch(@context)
    assert_equal "github.invalid_response", oversized_result.error.code
  end

  def test_record_limit_holds_cursor_when_a_full_page_is_truncated
    context = @context.with(prior_cursor: "page:1", limits: {max_pages: 2, max_records: 1, max_response_bytes: 100_000})
    result = @adapter.fetch(context)

    assert_equal "degraded", result.status
    assert_equal 1, result.records.length
    assert_equal "page:1", result.next_cursor
    assert_equal "github.invalid_response", result.error.code
  end

  def test_configured_hostname_is_used_for_every_read_only_request
    @adapter.fetch(@context)

    assert @runner.argv.all? { |argv| argv.include?("--hostname") && argv.include?("github.example") }
  end

  def test_issue_comment_notification_on_a_pull_request_fetches_pull_request_metadata
    notifications = JSON.generate([
      {
        "id" => "users-pr-comment", "reason" => "comment", "type" => "IssueComment",
        "subject" => {"title" => "A reply", "url" => "https://api.github.example/repos/acme/cyborg/pulls/42"},
        "repository" => {"full_name" => "acme/cyborg", "node_id" => "repo-node"},
        "updated_at" => "2026-08-12T12:00:00Z"
      }
    ])
    runner = FakeRunner.new(
      "notifications?" => reply(notifications),
      "/pulls/42" => reply(fixture("github/pull-request.json")),
      :default => reply(fixture("github/authenticated.json"))
    )

    result = Cyborg::GithubAdapter.new(runner:, gh: "gh", hostname: "github.example", per_page: 2).fetch(@context)
    record = result.records.fetch(0)

    assert_equal "github_pr", record.canonical_target_type
    assert_equal "github.example:repo-node:pull-node", record.canonical_target_id
    assert_equal "2026-08-12T11:00:00Z", record.latest_reply_at
  end

  def test_issue_mention_fetches_issue_metadata_and_uses_issue_node_identity
    notifications = JSON.generate([
      {
        "id" => "issue-mention", "reason" => "mention", "type" => "Issue",
        "subject" => {"title" => "Mention", "url" => "https://api.github.example/repos/acme/cyborg/issues/7"},
        "repository" => {"full_name" => "acme/cyborg", "node_id" => "repo-node"}
      }
    ])
    issue = JSON.generate(
      "node_id" => "issue-node", "number" => 7, "title" => "Mention",
      "html_url" => "https://github.example/acme/cyborg/issues/7", "body" => "Please help"
    )
    runner = FakeRunner.new(
      "notifications?" => reply(notifications),
      "/issues/7" => reply(issue),
      :default => reply(fixture("github/authenticated.json"))
    )

    result = Cyborg::GithubAdapter.new(runner:, gh: "gh", hostname: "github.example", per_page: 2).fetch(@context)
    record = result.records.fetch(0)

    assert_equal "github_issue", record.canonical_target_type
    assert_equal "github.example:repo-node:issue-node", record.canonical_target_id
    assert_equal "https://github.example/acme/cyborg/issues/7", record.deep_link
  end

  def test_issue_assignment_fetches_issue_metadata_as_read_only_activity
    notifications = JSON.generate([
      {
        "id" => "issue-assignment", "reason" => "assign", "type" => "Issue",
        "subject" => {"title" => "Assigned", "url" => "https://api.github.example/repos/acme/cyborg/issues/8"},
        "repository" => {"full_name" => "acme/cyborg", "node_id" => "repo-node"}
      }
    ])
    issue = JSON.generate("node_id" => "assigned-issue-node", "number" => 8, "title" => "Assigned", "html_url" => "https://github.example/acme/cyborg/issues/8")
    runner = FakeRunner.new("notifications?" => reply(notifications), "/issues/8" => reply(issue), :default => reply(fixture("github/authenticated.json")))

    result = Cyborg::GithubAdapter.new(runner:, gh: "gh", hostname: "github.example", per_page: 2).fetch(@context)

    assert_equal "assignment", result.records.fetch(0).record_kind
    assert_equal "github.example:repo-node:assigned-issue-node", result.records.fetch(0).canonical_target_id
    assert runner.argv.any? { |argv| argv.last.to_s.include?("/issues/8") && argv.include?("GET") }
  end

  def test_missing_issue_node_id_degrades_with_invalid_response
    notifications = JSON.generate([
      {
        "id" => "missing-issue-node", "reason" => "mention", "type" => "Issue",
        "subject" => {"title" => "Mention", "url" => "https://api.github.example/repos/acme/cyborg/issues/7"},
        "repository" => {"full_name" => "acme/cyborg", "node_id" => "repo-node"}
      }
    ])
    runner = FakeRunner.new("notifications?" => reply(notifications), "/issues/7" => reply(JSON.generate("number" => 7, "title" => "Mention")), :default => reply(fixture("github/authenticated.json")))

    result = Cyborg::GithubAdapter.new(runner:, gh: "gh", hostname: "github.example", per_page: 2).fetch(@context)

    assert_equal "degraded", result.status
    assert_equal "github.invalid_response", result.error.code
    assert_empty result.records
  end

  def test_missing_or_hostile_issue_subject_identity_degrades_without_unsafe_record
    notifications = JSON.generate([
      {
        "id" => "bad-subject", "reason" => "mention", "type" => "Issue",
        "subject" => {"title" => "Bad", "url" => "https://evil.example/repos/acme/cyborg/issues/7"},
        "repository" => {"full_name" => "acme/cyborg", "node_id" => "repo-node"}
      }
    ])
    runner = FakeRunner.new(
      "notifications?" => reply(notifications),
      "/issues/7" => reply(JSON.generate("node_id" => "issue-node", "number" => 7, "title" => "Bad")),
      :default => reply(fixture("github/authenticated.json"))
    )

    result = Cyborg::GithubAdapter.new(runner:, gh: "gh", hostname: "github.example", per_page: 2).fetch(@context)

    assert_equal "degraded", result.status
    assert_equal "github.invalid_response", result.error.code
    assert_empty result.records
  end

  def test_context_filters_cannot_expand_configured_allowlist_and_excluded_repo_skips_metadata
    notifications = JSON.generate([
      {
        "id" => "excluded", "reason" => "mention", "type" => "Issue",
        "subject" => {"title" => "Excluded", "url" => "https://api.github.example/repos/other/project/issues/9"},
        "repository" => {"full_name" => "other/project", "node_id" => "other-repo-node"}
      }
    ])
    runner = FakeRunner.new(
      "notifications?" => reply(notifications),
      "/issues/9" => reply(fixture("github/malformed.json")),
      :default => reply(fixture("github/authenticated.json"))
    )
    context = @context.with(filters: {"repositories" => ["other/project"]})
    adapter = Cyborg::GithubAdapter.new(
      runner:, gh: "gh", hostname: "github.example", per_page: 2,
      repository_allowlist: ["acme/cyborg"]
    )

    result = adapter.fetch(context)

    assert_empty result.records
    refute runner.argv.any? { |argv| argv.last.to_s.include?("/issues/9") }
  end

  def test_registration_limits_are_hard_ceilings_over_large_context_limits
    adapter = Cyborg::GithubAdapter.new(
      runner: @runner, gh: "gh", hostname: "github.example", per_page: 2,
      limits: {max_pages: 1, max_records: 1}
    )
    context = @context.with(prior_cursor: "page:1", limits: {max_pages: 99, max_records: 99, max_response_bytes: 100_000})

    result = adapter.fetch(context)

    assert_equal "degraded", result.status
    assert_equal "page:1", result.next_cursor
    assert_equal 1, result.records.length
    assert_equal 1, runner_page_requests(@runner).length
  end

  def runner_page_requests(runner)
    runner.argv.select { |argv| argv.first(2) == ["gh", "api"] && argv.last.to_s.include?("/notifications?") }
  end

  private

  def fixture(path)
    File.read(File.expand_path("../../fixtures/#{path}", __dir__))
  end

  def reply(stdout, stderr = "", status = 0, timed_out = false, truncated = false)
    ProcessReply.new(stdout:, stderr:, status:, timed_out:, truncated:)
  end

  class MissingRunner
    def capture(**)
      raise Errno::ENOENT, "No such file or directory - gh"
    end
  end
end
