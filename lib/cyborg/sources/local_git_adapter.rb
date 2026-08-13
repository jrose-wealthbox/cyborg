# frozen_string_literal: true

require "time"
require_relative "../bridge/canonical_json"
require_relative "../process_runner"
require_relative "contracts"
require_relative "repository_discovery"
require_relative "git_attribution"

module Cyborg
  # Read-only authored-commit reflection over explicitly configured local Git
  # roots. Git output is bounded before parsing and is never passed to a shell.
  class LocalGitAdapter
    DEFAULT_GIT = "git"
    DEFAULT_TIMEOUT = 30
    DEFAULT_MAX_DEPTH = 3
    DEFAULT_MAX_REPOSITORIES = 100
    DEFAULT_MAX_RECORDS = 500
    DEFAULT_MAX_RESPONSE_BYTES = 1_048_576
    DEFAULT_CACHE_TTL_SECONDS = 14_400
    LOG_BYTES_OVERHEAD = 128

    attr_reader :adapter_version

    def initialize(
      runner: ProcessRunner.new, discovery: nil, attribution: nil, git: DEFAULT_GIT,
      roots: [], explicit_paths: [], repositories: nil, author_emails: [], signing_identities: [],
      primary_branch: nil, max_depth: DEFAULT_MAX_DEPTH, max_repositories: DEFAULT_MAX_REPOSITORIES,
      max_records: DEFAULT_MAX_RECORDS, max_response_bytes: DEFAULT_MAX_RESPONSE_BYTES,
      timeout: DEFAULT_TIMEOUT, account_identity: nil, adapter_version: "local-git-1",
      cache_ttl_seconds: DEFAULT_CACHE_TTL_SECONDS, clock: -> { Time.now.utc }
    )
      @runner = runner
      @git = git.to_s
      @timeout = positive_number(timeout, "timeout")
      @discovery = discovery || RepositoryDiscovery.new(runner: @runner, git: @git, timeout: @timeout)
      @attribution = attribution || GitAttribution.new(runner: @runner, git: @git, primary_branch:, timeout: @timeout)
      @roots = paths_from(roots)
      @explicit_paths = paths_from(explicit_paths) + paths_from(repositories)
      @author_emails = normalize_identities(author_emails)
      @signing_identities = normalize_identities(signing_identities)
      @primary_branch = primary_branch&.to_s
      @max_depth = non_negative_integer(max_depth, "max_depth")
      @max_repositories = positive_integer(max_repositories, "max_repositories")
      @max_records = positive_integer(max_records, "max_records")
      @max_response_bytes = positive_integer(max_response_bytes, "max_response_bytes")
      @account_identity = account_identity&.to_s
      @adapter_version = adapter_version.to_s
      @cache_ttl_seconds = positive_number(cache_ttl_seconds, "cache_ttl_seconds")
      @clock = clock
      @cache = {}
    end

    def fetch(context)
      started_at = context_value(context, :window_start_utc)
      completed_at = context_value(context, :window_end_utc, started_at)
      source_name = context_value(context, :source_name, "local_git").to_s
      account_identity = context_value(context, :account_identity, @account_identity)
      cache_key = cache_key_for(context)
      if expensive?(context)
        cached = cached_result(cache_key, started_at, completed_at)
        return cached if cached
      end

      filters = stringify_hash(context_value(context, :filters, {}))
      limits = stringify_hash(context_value(context, :limits, {}))
      roots = configured_paths(filters, ["roots", "repository_roots"], @roots)
      explicit_paths = configured_paths(filters, ["explicit_paths", "repositories"], @explicit_paths)
      repositories = @discovery.call(
        roots:, explicit_paths:, max_depth: configured_integer(filters, limits, "max_depth", @max_depth),
        max_repositories: configured_integer(filters, limits, "max_repositories", @max_repositories)
      )

      emails = configured_identities(filters, %w[author_emails author_email emails], @author_emails)
      signing_identities = configured_identities(filters, %w[signing_identities signing_identity], @signing_identities)
      primary_branch = filter_value(filters, "primary_branch") || @primary_branch
      max_records = configured_integer(filters, limits, "max_records", context_limit(context, :max_records) || @max_records)
      max_bytes = context_limit(context, :max_response_bytes) || @max_response_bytes
      timeout = [@timeout, context_limit(context, :max_seconds)].compact.min
      records = []
      partial = false
      seen_commits = {}

      repositories.each do |repository|
        break if records.length >= max_records

        commits, truncated = commits_for(
          repository:, context:, timeout:, max_bytes:, emails:, signing_identities:
        )
        partial ||= truncated
        remaining = max_records - records.length
        partial ||= commits.length > remaining
        commits.first(remaining).each do |commit|
          dedupe_key = [repository_identity_for(repository), commit.fetch(:id)]
          next if seen_commits[dedupe_key]

          seen_commits[dedupe_key] = true
          stats, stats_ok = stats_for(repository, commit.fetch(:id), timeout:, max_bytes:)
          partial ||= !stats_ok
          branch = @attribution.branch_for(commit: commit.fetch(:id), repository:, primary_branch:)
          records << normalize_commit(
            commit:, stats:, branch:, repository:, account_identity:, observed_at: completed_at
          )
        end
      end
      result = RetrievalResult.new(
        source_name:, account_identity:, status: partial ? "degraded" : "healthy", data_status: "fresh",
        cache_reason: nil, started_at:, completed_at:, records:, next_cursor: nil,
        error: partial ? RetrievalError.new(code: "local_git.partial", message: "bounded local Git reflection was partial") : nil
      )
      store_cache(cache_key, result) if expensive?(context) && result.status == "healthy"
      result
    rescue Errno::ENOENT, Errno::EACCES
      failure_result(source_name, account_identity, started_at, completed_at, "local_git.binary_missing")
    rescue ArgumentError, KeyError, TypeError
      failure_result(source_name, account_identity, started_at, completed_at, "local_git.invalid_response")
    end

    private

    def commits_for(repository:, context:, timeout:, max_bytes:, emails:, signing_identities:)
      argv = [
        @git, "-C", repository.to_s, "log", "--all", "--no-color", "--no-decorate", "--no-patch",
        "--format=%H%x00%aI%x00%ae%x00%GS%x00%GK%x00%GF%x00%cI%x00%s%x00"
      ]
      response = capture(argv, timeout:, max_bytes:)
      return [[], true] unless successful?(response)

      fields = output(response).split("\x00")
      commits = []
      fields.each_slice(8) do |id, authored_at, author_email, signer, key_id, fingerprint, committed_at, subject|
        next unless id.to_s.match?(/\A[0-9a-f]{40}\z/i)

        subject = subject.to_s.delete_suffix("\n")
        next unless identity_match?(author_email, signer, key_id, fingerprint, emails, signing_identities)
        next unless within_window?(authored_at, context)

        commits << {
          id: id.to_s.downcase, authored_at: canonical_time(authored_at), author_email: author_email.to_s,
          signer: signer.to_s, key_id: key_id.to_s, fingerprint: fingerprint.to_s,
          committed_at: canonical_time(committed_at), subject: bounded_text(subject)
        }
      end
      [commits.uniq { |commit| commit.fetch(:id) }, response_truncated?(response)]
    end

    def stats_for(repository, commit, timeout:, max_bytes:)
      status_response = capture([
        @git, "-C", repository.to_s, "diff-tree", "--no-commit-id", "--root", "-r", "--name-status", "-M", "-z", commit
      ], timeout:, max_bytes:)
      return [{additions: 0, deletions: 0, binary_files: 0, rename_only_files: 0, files_changed: 0}, false] unless successful?(status_response)

      rename_count = rename_count(output(status_response))
      response = capture([
        @git, "-C", repository.to_s, "show", "--numstat", "--format=", "--no-color", "--no-ext-diff",
        "-M", "--find-renames", commit
      ], timeout:, max_bytes:)
      return [{additions: 0, deletions: 0, binary_files: 0, rename_only_files: 0, files_changed: 0}, false] unless successful?(response)

      totals = {additions: 0, deletions: 0, binary_files: 0, rename_only_files: 0, files_changed: 0}
      output(response).each_line do |line|
        fields = line.chomp.split("\t", 3)
        next unless fields.length == 3

        additions, deletions, _path = fields
        if additions == "-" || deletions == "-"
          totals[:binary_files] += 1
          totals[:files_changed] += 1
          next
        end
        next unless additions.match?(/\A\d+\z/) && deletions.match?(/\A\d+\z/)

        totals[:additions] += additions.to_i
        totals[:deletions] += deletions.to_i
        totals[:files_changed] += 1
      end
      totals[:rename_only_files] = rename_count
      [totals, !response_truncated?(response)]
    rescue ArgumentError
      [{additions: 0, deletions: 0, binary_files: 0, rename_only_files: 0, files_changed: 0}, false]
    end

    def normalize_commit(commit:, stats:, branch:, repository:, account_identity:, observed_at:)
      repository_identity = repository_identity_for(repository)
      fields = {
        "repository" => repository_identity, "repository_identity" => repository_identity,
        "commit_id" => commit.fetch(:id), "display_branch" => branch,
        "author_email" => commit.fetch(:author_email), "signing_identity" => signing_identity_for(commit),
        "authored_at" => commit.fetch(:authored_at), "committed_at" => commit.fetch(:committed_at),
        "additions" => stats.fetch(:additions), "deletions" => stats.fetch(:deletions),
        "binary_files" => stats.fetch(:binary_files), "binary" => stats.fetch(:binary_files),
        "rename_only_files" => stats.fetch(:rename_only_files), "rename_only" => stats.fetch(:rename_only_files),
        "files_changed" => stats.fetch(:files_changed)
      }
      payload = {
        "source_record_id" => commit.fetch(:id), "record_kind" => "commit", "title" => commit.fetch(:subject),
        "summary" => commit.fetch(:subject), "structured_fields" => fields,
        "participants" => [commit.fetch(:author_email)].reject(&:empty?), "owner_identity" => account_identity || commit.fetch(:author_email),
        "event_at" => commit.fetch(:authored_at), "observed_at" => observed_at
      }
      NormalizedRecord.new(
        source_record_id: commit.fetch(:id), record_kind: "commit", title: commit.fetch(:subject),
        summary: commit.fetch(:subject), structured_fields: fields,
        participants: payload.fetch("participants"), owner_identity: payload.fetch("owner_identity"),
        canonical_target_type: "local_git_commit", canonical_target_id: "#{repository_identity}:#{commit.fetch(:id)}",
        deep_link: nil, event_at: commit.fetch(:authored_at), latest_reply_at: nil, observed_at:,
        timestamp_kind: "event_at", content_fingerprint: Bridge::CanonicalJSON.sha256(payload), evidence: []
      )
    end

    def repository_identity_for(repository)
      path = Pathname.new(repository.to_s).expand_path
      path.to_s
    end

    def signing_identity_for(commit)
      [commit.fetch(:signer), commit.fetch(:key_id), commit.fetch(:fingerprint)].find { |value| !value.to_s.empty? }
    end

    def configured_paths(filters, keys, fallback)
      values = keys.flat_map { |key| Array(filter_value(filters, key)) }
      values.empty? ? fallback : paths_from(values)
    end

    def paths_from(values)
      Array(values).filter_map do |value|
        value = value["path"] || value[:path] || value["root"] || value[:root] if value.is_a?(Hash)
        next if value.nil? || value.to_s.empty?

        Pathname.new(value.to_s).expand_path
      end.uniq
    end

    def configured_identities(filters, keys, fallback)
      values = keys.flat_map { |key| Array(filter_value(filters, key)) }.map(&:to_s).reject(&:empty?)
      values.empty? ? fallback : normalize_identities(values)
    end

    def identity_match?(author_email, signer, key_id, fingerprint, emails, signing_identities)
      return true if emails.any? && emails.include?(author_email.to_s.downcase)
      values = [signer, key_id, fingerprint].map { |value| value.to_s.downcase }
      signing_identities.any? { |identity| values.include?(identity) }
    end

    def within_window?(value, context)
      timestamp = Time.iso8601(value.to_s)
      start_at = Time.iso8601(timestamp_text(context_value(context, :window_start_utc)))
      end_at = Time.iso8601(timestamp_text(context_value(context, :window_end_utc)))
      timestamp >= start_at && timestamp <= end_at
    rescue ArgumentError, TypeError
      false
    end

    def canonical_time(value)
      Time.iso8601(value.to_s).utc.iso8601
    rescue ArgumentError, TypeError
      nil
    end

    def timestamp_text(value)
      return Time.now.utc.iso8601 if value.nil?
      return value.utc.iso8601 if value.respond_to?(:utc)

      value.to_s
    end

    def bounded_text(value)
      value = value.to_s
      return value if value.bytesize <= 4_096

      value.byteslice(0, 4_096).force_encoding(Encoding::UTF_8).scrub
    end

    def rename_count(value)
      fields = value.to_s.split("\x00")
      fields.each_with_index.count { |field, index| index.even? && field.to_s.start_with?("R") }
    end

    def capture(argv, timeout:, max_bytes:)
      @runner.capture(argv:, timeout:, max_bytes:, env: {})
    end

    def successful?(response)
      response.respond_to?(:success?) && response.success?
    end

    def response_truncated?(response)
      response.respond_to?(:truncated) && response.truncated
    end

    def output(response)
      value = if response.respond_to?(:stdout)
        response.stdout
      elsif response.respond_to?(:fetch)
        response.fetch(:stdout)
      else
        String.new
      end
      value.to_s.force_encoding(Encoding::UTF_8).scrub
    end

    def cache_key_for(context)
      [
        context_value(context, :source_name, "local_git"), context_value(context, :account_identity, @account_identity),
        context_value(context, :window_start_utc), context_value(context, :window_end_utc),
        context_value(context, :filters, {}), context_value(context, :limits, {}), @roots.map(&:to_s), @explicit_paths.map(&:to_s)
      ].inspect
    end

    def expensive?(context)
      context_value(context, :cache_policy, "ordinary").to_s == "expensive"
    end

    def cached_result(key, started_at, completed_at)
      entry = @cache[key]
      return nil unless entry
      return @cache.delete(key) if @clock.call.to_f >= entry.fetch(:expires_at)

      entry.fetch(:result).with(data_status: "cached", cache_reason: "policy_hit", started_at:, completed_at:)
    end

    def store_cache(key, result)
      @cache[key] = {expires_at: @clock.call.to_f + @cache_ttl_seconds, result:}
    end

    def failure_result(source_name, account_identity, started_at, completed_at, code)
      RetrievalResult.new(
        source_name:, account_identity:, status: "failed", data_status: "none", cache_reason: nil,
        started_at:, completed_at:, records: [], next_cursor: nil,
        error: RetrievalError.new(code:, message: "local Git retrieval failed")
      )
    end

    def context_value(context, method, fallback = nil)
      context.respond_to?(method) ? context.public_send(method) : fallback
    end

    def context_limit(context, method)
      return nil unless context.respond_to?(method)

      value = context.public_send(method)
      value.nil? ? nil : Integer(value)
    rescue ArgumentError, TypeError
      nil
    end

    def filter_value(filters, key)
      filters[key.to_s] || filters[key.to_sym]
    end

    def configured_integer(filters, limits, key, fallback)
      value = filter_value(filters, key) || filter_value(limits, key)
      value.nil? ? fallback : Integer(value)
    rescue ArgumentError, TypeError
      fallback
    end

    def stringify_hash(value)
      return {} unless value.is_a?(Hash)

      value.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
    end

    def normalize_identities(values)
      Array(values).map { |value| value.to_s.strip.downcase }.reject(&:empty?).uniq
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
