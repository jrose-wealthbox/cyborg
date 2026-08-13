# frozen_string_literal: true

require_relative "../../test_helper"
require "open3"
require "cyborg/sources/git_attribution"

class CyborgGitAttributionTest < Minitest::Test
  def setup
    @repo = Pathname.new(Dir.mktmpdir("cyborg-git-attribution"))
    run_git("init", "--quiet")
    run_git("config", "user.email", "author@example.test")
    run_git("config", "user.name", "Author")
    File.write(@repo.join("file"), "one\n")
    run_git("add", "file")
    run_git("commit", "--quiet", "-m", "base")
    @base = capture("rev-parse", "HEAD").strip
    run_git("branch", "primary")
    run_git("checkout", "-q", "-b", "feature/current")
    File.write(@repo.join("file"), "one\ntwo\n")
    run_git("commit", "--quiet", "-am", "feature")
    @commit = capture("rev-parse", "HEAD").strip
    @attribution = Cyborg::GitAttribution.new(primary_branch: "primary", timeout: 2)
  end

  def teardown
    FileUtils.rm_rf(@repo)
  end

  def test_commit_is_counted_once_and_prefers_current_branch
    assert_equal "feature/current", @attribution.branch_for(commit: @commit, repository: @repo)
  end

  def test_primary_branch_is_used_when_current_branch_does_not_contain_commit
    run_git("checkout", "-q", "primary")
    assert_equal "primary", @attribution.branch_for(commit: @base, repository: @repo)
  end

  def test_detached_commit_is_unclassified_when_no_local_branch_contains_it
    run_git("checkout", "-q", "--detach", @commit)
    run_git("checkout", "-q", "--orphan", "unpublished")
    FileUtils.rm_f(@repo.join("file"))
    File.write(@repo.join("unpublished"), "unpublished\n")
    run_git("add", "unpublished")
    run_git("commit", "--quiet", "-m", "unpublished")
    unpublished = capture("rev-parse", "HEAD").strip
    run_git("checkout", "-q", "feature/current")
    run_git("branch", "-D", "unpublished")
    assert_equal "detached", @attribution.branch_for(commit: unpublished, repository: @repo)
  end

  private

  def run_git(*args)
    _stdout, stderr, status = Open3.capture3("git", "-C", @repo.to_s, *args)
    raise stderr unless status.success?
  end

  def capture(*args)
    stdout, stderr, status = Open3.capture3("git", "-C", @repo.to_s, *args)
    raise stderr unless status.success?

    stdout
  end
end
