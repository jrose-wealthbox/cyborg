# frozen_string_literal: true

require_relative "../../test_helper"
require "open3"
require "cyborg/sources/local_git_adapter"

class CyborgLocalGitAdapterTest < Minitest::Test
  def setup
    @root = Pathname.new(Dir.mktmpdir("cyborg-local-git"))
    @repo = @root.join("repo")
    FileUtils.mkdir_p(@repo)
    git("init", "--quiet")
    git("config", "user.email", "author@example.test")
    git("config", "user.name", "Author")
    git("config", "user.signingkey", "signing@example.test")
    File.write(@repo.join("text"), "one\n")
    git("add", "text")
    git("commit", "--quiet", "-m", "base")
    git("checkout", "-q", "-b", "feature/current")
    File.write(@repo.join("text"), "one\ntwo\n")
    File.write(@repo.join("binary"), "\x00\x01".b)
    git("add", "text", "binary")
    git("commit", "--quiet", "-m", "hostile; message")
    @commit = git_capture("rev-parse", "HEAD").strip
    @context = Cyborg::RetrievalContext.new(
      source_name: "local_git", account_identity: "author@example.test",
      window_start_utc: "2020-01-01T00:00:00Z", window_end_utc: "2099-01-01T00:00:00Z",
      display_timezone: "UTC", cache_policy: "expensive",
      filters: {"author_emails" => ["author@example.test"], "primary_branch" => "main"},
      limits: {max_records: 10, max_repositories: 4, max_response_bytes: 65_536, max_seconds: 5}
    )
    @adapter = Cyborg::LocalGitAdapter.new(roots: [@root], timeout: 2)
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def test_fetch_returns_unique_authored_commit_with_branch_and_churn
    result = @adapter.fetch(@context)
    record = result.records.find { |item| item.source_record_id == @commit }

    assert_equal "healthy", result.status
    refute_nil record
    assert_equal "feature/current", record.structured_fields.fetch("display_branch")
    assert_operator record.structured_fields.fetch("additions"), :>=, 1
    assert_operator record.structured_fields.fetch("deletions"), :>=, 0
    assert_operator record.structured_fields.fetch("binary_files"), :>=, 1
    assert_equal "hostile; message", record.title
  end

  def test_fetch_is_cached_for_expensive_reflection
    first = @adapter.fetch(@context)
    second = @adapter.fetch(@context)

    assert_equal "fresh", first.data_status
    assert_equal "cached", second.data_status
    assert_equal "policy_hit", second.cache_reason
  end

  def test_unconfigured_roots_produce_no_records
    context = @context.with(filters: {"author_emails" => ["author@example.test"]})
    result = Cyborg::LocalGitAdapter.new.fetch(context)

    assert_empty result.records
    assert_equal "healthy", result.status
  end

  def test_same_commit_in_two_repositories_is_emitted_once_per_repository
    second = @root.join("second")
    FileUtils.cp_r(@repo.to_s, second.to_s)
    context = @context.with(limits: {max_records: 10, max_repositories: 4, max_response_bytes: 65_536, max_seconds: 5})
    result = Cyborg::LocalGitAdapter.new(roots: [@root], timeout: 2).fetch(context)

    records = result.records.select { |item| item.source_record_id == @commit }
    assert_equal 2, records.length
    assert_equal 2, records.map { |item| item.structured_fields.fetch("repository_identity") }.uniq.length
  end

  def test_authored_timestamp_controls_window_not_commit_timestamp
    git("commit", "--quiet", "--allow-empty", "--date", "2024-01-01T12:00:00Z", "-m", "authored-in-window")
    authored = git_capture("rev-parse", "HEAD").strip
    context = @context.with(
      window_start_utc: "2024-01-01T00:00:00Z", window_end_utc: "2024-01-01T23:59:59Z"
    )

    result = Cyborg::LocalGitAdapter.new(roots: [@root], timeout: 2).fetch(context)

    assert_includes result.records.map(&:source_record_id), authored
  end

  def test_literal_arrow_filename_is_not_counted_as_rename
    literal = @repo.join("literal => name")
    File.write(literal, "one\n")
    git("add", literal.basename.to_s)
    git("commit", "--quiet", "-m", "literal filename")
    commit = git_capture("rev-parse", "HEAD").strip
    result = Cyborg::LocalGitAdapter.new(roots: [@root], timeout: 2).fetch(@context)
    record = result.records.find { |item| item.source_record_id == commit }

    assert_equal 0, record.structured_fields.fetch("rename_only_files")
  end

  private

  def git(*args)
    _stdout, stderr, status = Open3.capture3("git", "-C", @repo.to_s, *args)
    raise stderr unless status.success?
  end

  def git_capture(*args)
    stdout, stderr, status = Open3.capture3("git", "-C", @repo.to_s, *args)
    raise stderr unless status.success?

    stdout
  end
end
