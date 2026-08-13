# frozen_string_literal: true

require "pathname"
require_relative "../process_runner"

module Cyborg
  # Finds repositories below caller-provided paths. It deliberately has no
  # implicit home-directory or current-directory behavior: roots and explicit
  # paths are the complete discovery scope.
  class RepositoryDiscovery
    DEFAULT_TIMEOUT = 5
    DEFAULT_MAX_DEPTH = 3
    DEFAULT_MAX_REPOSITORIES = 100
    REV_PARSE_BYTES = 4_096

    def initialize(runner: ProcessRunner.new, git: "git", timeout: DEFAULT_TIMEOUT)
      @runner = runner
      @git = git.to_s
      @timeout = positive_number(timeout, "timeout")
    end

    def call(roots:, explicit_paths:, max_depth: DEFAULT_MAX_DEPTH, max_repositories: DEFAULT_MAX_REPOSITORIES)
      max_depth = non_negative_integer(max_depth, "max_depth")
      max_repositories = positive_integer(max_repositories, "max_repositories")
      repositories = []
      seen = {}

      Array(explicit_paths).each do |value|
        path = Pathname.new(value.to_s).expand_path
        add_repository(path, repositories, seen, max_repositories) if repository?(path, path)
        break if repositories.length >= max_repositories
      end

      Array(roots).each do |value|
        break if repositories.length >= max_repositories

        root = Pathname.new(value.to_s).expand_path
        walk(root, 0, max_depth, repositories, seen, max_repositories, root)
      end

      repositories
    end

    private

    def walk(path, depth, max_depth, repositories, seen, max_repositories, allowed_root)
      return if repositories.length >= max_repositories
      return unless directory_without_symlink?(path)

      if repository?(path, allowed_root)
        add_repository(path, repositories, seen, max_repositories)
        return
      end
      return if depth >= max_depth

      Dir.children(path.to_s).sort.each do |entry|
        break if repositories.length >= max_repositories

        child = path.join(entry)
        next unless directory_without_symlink?(child)

        walk(child, depth + 1, max_depth, repositories, seen, max_repositories, allowed_root)
      end
    rescue Errno::EACCES, Errno::ENOENT, Errno::ENOTDIR
      nil
    end

    def add_repository(path, repositories, seen, max_repositories)
      return if repositories.length >= max_repositories
      return unless directory_without_symlink?(path)
      key = path.to_s
      return if seen[key]

      seen[key] = true
      repositories << path
    end

    def repository?(path, allowed_root)
      git_marker = path.join(".git")
      marker_stat = git_marker.lstat
      return false if marker_stat.symlink?

      result = @runner.capture(
        argv: [@git, "-C", path.to_s, "rev-parse", "--git-dir"],
        timeout: @timeout, max_bytes: REV_PARSE_BYTES, env: {}
      )
      return false unless result.respond_to?(:success?) && result.success?

      gitdir = resolve_gitdir(path, output(result))
      return false unless safely_within?(gitdir, allowed_root)

      common_result = @runner.capture(
        argv: [@git, "-C", path.to_s, "rev-parse", "--git-common-dir"],
        timeout: @timeout, max_bytes: REV_PARSE_BYTES, env: {}
      )
      return false unless common_result.respond_to?(:success?) && common_result.success?

      safely_within?(resolve_gitdir(path, output(common_result)), allowed_root)
    rescue Errno::ENOENT, Errno::EACCES, ArgumentError
      false
    end

    def output(result)
      result.respond_to?(:stdout) ? result.stdout.to_s.strip : result.fetch(:stdout).to_s.strip
    end

    def resolve_gitdir(path, value)
      candidate = Pathname.new(value.to_s)
      candidate = path.join(candidate) unless candidate.absolute?
      candidate.realpath
    end

    def safely_within?(candidate, root)
      candidate = Pathname.new(candidate.to_s).realpath
      root = Pathname.new(root.to_s).realpath
      candidate == root || candidate.to_s.start_with?(root.to_s + File::SEPARATOR)
    rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR
      false
    end

    def directory_without_symlink?(path)
      stat = path.lstat
      stat.directory? && !stat.symlink?
    rescue Errno::EACCES, Errno::ENOENT, Errno::ENOTDIR
      false
    end

    def positive_integer(value, name)
      raise ArgumentError, "#{name} must be a positive integer" unless value.is_a?(Integer) && value.positive?

      value
    end

    def non_negative_integer(value, name)
      raise ArgumentError, "#{name} must be a non-negative integer" unless value.is_a?(Integer) && value >= 0

      value
    end

    def positive_number(value, name)
      number = value.to_f
      raise ArgumentError, "#{name} must be positive" unless number.positive?

      number
    end
  end
end
