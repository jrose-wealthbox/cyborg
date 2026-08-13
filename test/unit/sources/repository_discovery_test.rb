# frozen_string_literal: true

require_relative "../../test_helper"
require "open3"
require "cyborg/process_runner"
require "cyborg/sources/repository_discovery"

class CyborgRepositoryDiscoveryTest < Minitest::Test
  def setup
    @root = Pathname.new(Dir.mktmpdir("cyborg-git-discovery"))
    @repo_a = @root.join("a")
    @repo_b = @root.join("nested", "b")
    @outside = Pathname.new(Dir.mktmpdir("cyborg-git-outside")).join("outside")
    [@repo_a, @repo_b, @outside].each { |path| init_repo(path) }
    @discovery = Cyborg::RepositoryDiscovery.new(timeout: 2)
  end

  def teardown
    FileUtils.rm_rf(@root)
    FileUtils.rm_rf(@outside.dirname)
  end

  def test_discovery_does_not_follow_symlinks_or_exceed_limits
    File.symlink(@outside.to_s, @root.join("linked-repo").to_s)

    repositories = @discovery.call(roots: [@root], explicit_paths: [], max_depth: 2, max_repositories: 2)

    assert_equal [@repo_a, @repo_b], repositories
    refute_includes repositories, @outside
  end

  def test_explicit_repository_is_allowed_without_scanning_an_implicit_home
    assert_equal [@outside], @discovery.call(roots: [], explicit_paths: [@outside], max_depth: 0, max_repositories: 1)
  end

  def test_rejects_gitdir_symlink_escaping_scan_root
    escaped = @root.join("escaped")
    FileUtils.mkdir_p(escaped)
    File.symlink(@outside.join(".git").to_s, escaped.join(".git").to_s)

    repositories = @discovery.call(roots: [@root], explicit_paths: [], max_depth: 2, max_repositories: 10)

    refute_includes repositories, escaped
  end

  def test_rejects_git_file_indirection_escaping_scan_root
    escaped = @root.join("indirected")
    FileUtils.mkdir_p(escaped)
    File.write(escaped.join(".git"), "gitdir: #{@outside.join(".git")}\n")

    repositories = @discovery.call(roots: [@root], explicit_paths: [], max_depth: 2, max_repositories: 10)

    refute_includes repositories, escaped
  end

  def test_accepts_legitimate_worktree_under_an_explicit_root
    worktree = @root.join("worktree")
    run_git(@repo_a, "worktree", "add", "--quiet", "-b", "fixture-worktree", worktree.to_s)

    repositories = @discovery.call(roots: [@root], explicit_paths: [], max_depth: 2, max_repositories: 10)

    assert_includes repositories, worktree
  end

  private

  def init_repo(path)
    FileUtils.mkdir_p(path)
    run_git(path, "init", "--quiet")
    run_git(path, "config", "user.email", "author@example.test")
    run_git(path, "config", "user.name", "Author")
    File.write(path.join("README"), "fixture\n")
    run_git(path, "add", "README")
    run_git(path, "commit", "--quiet", "-m", "fixture")
  end

  def run_git(path, *args)
    _stdout, stderr, status = Open3.capture3("git", "-C", path.to_s, *args)
    raise stderr unless status.success?
  end
end
