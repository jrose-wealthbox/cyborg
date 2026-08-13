# frozen_string_literal: true

require_relative "../process_runner"

module Cyborg
  # Chooses one human-readable local branch for an authored commit without
  # claiming that all refs represent separate activity.
  class GitAttribution
    DEFAULT_TIMEOUT = 5
    BRANCH_BYTES = 32_768

    def initialize(runner: ProcessRunner.new, git: "git", primary_branch: nil, timeout: DEFAULT_TIMEOUT)
      @runner = runner
      @git = git.to_s
      @primary_branch = normalize_branch(primary_branch)
      @timeout = timeout.to_f
      raise ArgumentError, "timeout must be positive" unless @timeout.positive?
    end

    def branch_for(commit:, repository:, primary_branch: @primary_branch)
      commit = commit.to_s
      repository = repository.to_s
      return "detached" unless commit.match?(/\A[0-9a-f]{40}\z/i)

      branches = branches_containing(commit, repository)
      return "detached" if branches.empty?

      current = current_branch(repository)
      return current if current && branches.include?(current)

      primary = normalize_branch(primary_branch)
      return primary if primary && branches.include?(primary)

      branches.first || "detached"
    end

    private

    def current_branch(repository)
      result = capture([@git, "-C", repository, "branch", "--show-current"])
      return nil unless result

      value = output(result).delete_suffix("\n")
      value.empty? ? nil : value
    end

    def branches_containing(commit, repository)
      result = capture([
        @git, "-C", repository, "for-each-ref", "--contains", commit,
        "--sort=-committerdate", "--format=%(refname:short)%00%(committerdate:unix)", "refs/heads"
      ])
      return [] unless result

      output(result).each_line.filter_map do |line|
        name, timestamp = line.chomp.split("\x00", 2)
        name = name.to_s
        timestamp = timestamp.to_s
        next if name.empty? || !timestamp.match?(/\A-?\d+\z/)

        name
      end.uniq
    end

    def capture(argv)
      result = @runner.capture(argv:, timeout: @timeout, max_bytes: BRANCH_BYTES, env: {})
      return nil unless result.respond_to?(:success?) && result.success?
      return nil if result.respond_to?(:truncated) && result.truncated
      return nil if result.respond_to?(:timed_out) && result.timed_out

      result
    rescue Errno::ENOENT, Errno::EACCES, ArgumentError
      nil
    end

    def output(result)
      if result.respond_to?(:stdout)
        result.stdout.to_s.force_encoding(Encoding::UTF_8).scrub
      elsif result.respond_to?(:fetch)
        result.fetch(:stdout).to_s.force_encoding(Encoding::UTF_8).scrub
      else
        String.new
      end
    end

    def normalize_branch(value)
      value = value.to_s
      value = value.delete_prefix("refs/heads/")
      value.empty? ? nil : value
    end
  end
end
