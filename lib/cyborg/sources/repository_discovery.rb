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
        add_repository(Pathname.new(value.to_s).expand_path, repositories, seen, max_repositories)
        break if repositories.length >= max_repositories
      end

      Array(roots).each do |value|
        break if repositories.length >= max_repositories

        root = Pathname.new(value.to_s).expand_path
        walk(root, 0, max_depth, repositories, seen, max_repositories)
      end

      repositories
    end

    private

    def walk(path, depth, max_depth, repositories, seen, max_repositories)
      return if repositories.length >= max_repositories
      return unless directory_without_symlink?(path)

      if repository?(path)
        add_repository(path, repositories, seen, max_repositories)
        return
      end
      return if depth >= max_depth

      Dir.children(path.to_s).sort.each do |entry|
        break if repositories.length >= max_repositories

        child = path.join(entry)
        next unless directory_without_symlink?(child)

        walk(child, depth + 1, max_depth, repositories, seen, max_repositories)
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

    def repository?(path)
      result = @runner.capture(
        argv: [@git, "-C", path.to_s, "rev-parse", "--git-dir"],
        timeout: @timeout, max_bytes: REV_PARSE_BYTES, env: {}
      )
      result.respond_to?(:success?) && result.success?
    rescue Errno::ENOENT, Errno::EACCES, ArgumentError
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
