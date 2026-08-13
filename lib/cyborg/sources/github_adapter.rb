# frozen_string_literal: true

require "json"
require "uri"
require_relative "../errors"
require_relative "../process_runner"
require_relative "contracts"
require_relative "github_normalizer"

module Cyborg
  # Read-only GitHub source backed by the user's existing `gh` authentication.
  # Every invocation is an explicit argv array and every response is bounded
  # before Ruby parses it.
  class GithubAdapter
    DEFAULT_HOSTNAME = "github.com"
    DEFAULT_GH = "gh"
    DEFAULT_PER_PAGE = 100
    DEFAULT_MAX_PAGES = 10
    DEFAULT_MAX_RECORDS = 500
    DEFAULT_MAX_RESPONSE_BYTES = 1_048_576
    DEFAULT_TIMEOUT = 30
    READ_METHOD = "GET"
    FAILURE_CODES = %w[github.binary_missing github.unauthenticated github.api_unavailable github.invalid_response].freeze

    attr_reader :gh, :hostname, :adapter_version

    def initialize(
      runner: ProcessRunner.new, gh: DEFAULT_GH, hostname: DEFAULT_HOSTNAME,
      repository_allowlist: [], organization_allowlist: [], repositories: nil, organizations: nil,
      per_page: DEFAULT_PER_PAGE, timeout: DEFAULT_TIMEOUT, account_identity: nil,
      adapter_version: "github-1", env: {}, limits: {}
    )
      @runner = runner
      @gh = gh.to_s
      @hostname = GithubNormalizer.new(hostname:).hostname
      @repository_allowlist = Array(repositories || repository_allowlist)
      @organization_allowlist = Array(organizations || organization_allowlist)
      @per_page = positive_integer(per_page, "per_page")
      @per_page = [@per_page, 100].min
      @timeout = timeout.to_f
      raise ArgumentError, "timeout must be positive" unless @timeout.positive?
      @account_identity = account_identity&.to_s
      @adapter_version = adapter_version.to_s
      @env = env || {}
      @limits = normalize_limits(limits)
      @last_login = nil
    end

    def health_check(context)
      source_name = context_value(context, :source_name, "github")
      account_identity = context_value(context, :account_identity, @account_identity)
      checked_at = context_value(context, :window_end_utc, nil)
      begin
        response = capture(auth_argv, context)
      rescue Errno::ENOENT, Errno::EACCES
        return health(source_name, account_identity, "github.binary_missing", checked_at)
      rescue ArgumentError
        return health(source_name, account_identity, "github.invalid_response", checked_at)
      end

      code = if response_truncated?(response)
        "github.invalid_response"
      elsif response_timed_out?(response)
        "github.api_unavailable"
      elsif !response_success?(response)
        "github.unauthenticated"
      else
        @last_login = login_from_auth(response_output(response))
        nil
      end
      return health(source_name, account_identity, code, checked_at) if code

      SourceHealth.new(
        source_name: source_name, account_identity: account_identity || @last_login,
        status: "healthy", code: nil, remediation: nil, checked_at:, message: nil
      )
    end

    def fetch(context)
      started_at = context_value(context, :window_start_utc, nil)
      completed_at = context_value(context, :window_end_utc, started_at)
      source_name = context_value(context, :source_name, "github")
      account_identity = context_value(context, :account_identity, @account_identity || @last_login)
      health_status = health_check(context)
      unless health_status.status == "healthy"
        return failure_result(source_name, account_identity || health_status.account_identity, started_at, completed_at, health_status.code)
      end

      normalizer = normalizer_for(context)
      records = []
      max_pages = bounded_limit(context_limit(context, :max_pages), @limits.fetch("max_pages", DEFAULT_MAX_PAGES))
      max_records = bounded_limit(context_limit(context, :max_records), @limits.fetch("max_records", DEFAULT_MAX_RECORDS))
      per_page = [context_value(context, :filters, {}).fetch("per_page", @per_page).to_i, 100].min
      per_page = @per_page unless per_page.positive?
      page = page_from_cursor(context_value(context, :prior_cursor, nil)) || 1
      partial = false
      last_page = page
      fetched_pages = 0

      max_pages.times do |offset|
        page = page_from_cursor(context_value(context, :prior_cursor, nil)) || 1 if offset.zero?
        response = api_json(notification_argv(page, per_page), context)
        unless response.is_a?(Array)
          raise Failure.new("github.invalid_response")
        end

        response.each do |notification|
          break if records.length >= max_records
          next unless notification.is_a?(Hash)
          next unless normalizer.include_notification?(notification)
          next unless normalizer.allowed_repository?(notification)

          metadata = metadata_for(notification, context)
          record = normalizer.normalize(notification, context:, metadata:)
          if record.nil?
            partial = true
            break
          end
          if record && %w[github_issue github_pr].include?(record.canonical_target_type) && record.canonical_target_id.nil?
            partial = true
            break
          end
          records << record if record
        end
        last_page = page
        fetched_pages += 1

        break if partial

        if records.length >= max_records && response.length >= per_page
          partial = true
          break
        end
        more_pages = response.length >= per_page
        unless more_pages
          break
        end
        if offset == max_pages - 1
          partial = true
          break
        end
        page += 1
      end

      next_cursor = if partial
        context_value(context, :prior_cursor, nil)
      else
        "page:#{last_page + 1}"
      end
      if partial
        RetrievalResult.new(
          source_name:, account_identity: account_identity || @last_login, status: "degraded", data_status: "fresh",
          cache_reason: nil, started_at:, completed_at:, records:, next_cursor:,
          error: error_for("github.invalid_response")
        )
      else
        RetrievalResult.new(
          source_name:, account_identity: account_identity || @last_login, status: "healthy", data_status: "fresh",
          cache_reason: nil, started_at:, completed_at:, records:, next_cursor:, error: nil
        )
      end
    rescue Failure => error
      failure_result(source_name, account_identity || @last_login, started_at, completed_at, error.code)
    rescue JSON::ParserError, URI::InvalidURIError, KeyError, TypeError, ArgumentError
      failure_result(source_name, account_identity || @last_login, started_at, completed_at, "github.invalid_response")
    rescue Errno::ENOENT, Errno::EACCES
      failure_result(source_name, account_identity || @last_login, started_at, completed_at, "github.binary_missing")
    end

    private

    class Failure < StandardError
      attr_reader :code

      def initialize(code)
        @code = code.to_s
        super(@code)
      end
    end

    def auth_argv
      [@gh, "auth", "status", "--active", "--hostname", @hostname]
    end

    def notification_argv(page, per_page)
      [@gh, "api", "--hostname", @hostname, "--method", READ_METHOD,
       "/notifications?all=true&participating=false&per_page=#{per_page}&page=#{page}"]
    end

    def pull_request_argv(path)
      [@gh, "api", "--hostname", @hostname, "--method", READ_METHOD, path]
    end

    def capture(argv, context)
      @runner.capture(
        argv:, timeout: context_limit(context, :max_seconds) || @timeout,
        max_bytes: context_limit(context, :max_response_bytes) || DEFAULT_MAX_RESPONSE_BYTES,
        env: @env
      )
    end

    def api_json(argv, context)
      response = capture(argv, context)
      raise Failure.new("github.invalid_response") if response_truncated?(response)
      raise Failure.new("github.api_unavailable") if response_timed_out?(response) || !response_success?(response)

      JSON.parse(response_output(response))
    end

    def metadata_for(notification, context)
      notification = stringify_hash(notification)
      subject = stringify_hash(notification["subject"] || {})
      return {} unless trusted_subject_url?(subject["url"])
      path = api_path(subject["url"])
      return {} unless path

      type = notification["type"].to_s.downcase
      subject_type = subject["type"].to_s.downcase
      return {} unless path.include?("/pulls/") || path.include?("/issues/") || type.casecmp?("pullrequest") || type.include?("review") || type.include?("comment") || subject_type.include?("pull") || subject_type.include?("issue")

      metadata = api_json(pull_request_argv(path), context)
      raise Failure.new("github.invalid_response") unless metadata.is_a?(Hash)

      metadata
    end

    def trusted_subject_url?(value)
      uri = URI.parse(value.to_s)
      uri.scheme == "https" && [@hostname, "api.#{@hostname}"].include?(uri.host) && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
    rescue URI::InvalidURIError
      false
    end

    def api_path(value)
      uri = URI.parse(value.to_s)
      path = uri.path.to_s.sub(%r{\A/}, "")
      return nil unless path.match?(%r{\Arepos/[^/\s]+/[^/\s]+/(?:pulls|issues)/\d+\z}) || path.match?(%r{\Arepos/[^/\s]+/[^/\s]+/(?:pulls|issues)/\d+/[^/\s]+\z})

      "/#{path}"
    rescue URI::InvalidURIError
      nil
    end

    def normalizer_for(context)
      filters = context_value(context, :filters, {})
      GithubNormalizer.new(
        hostname: @hostname,
        repository_allowlist: narrowed_allowlist(@repository_allowlist, filters["repositories"] || filters["repository_allowlist"]),
        organization_allowlist: narrowed_allowlist(@organization_allowlist, filters["organizations"] || filters["organization_allowlist"])
      )
    end

    def narrowed_allowlist(configured, requested)
      requested = Array(requested).map { |value| value.to_s.strip.downcase }.reject(&:empty?).uniq
      configured = Array(configured).map { |value| value.to_s.strip.downcase }.reject(&:empty?).uniq
      return requested if configured.empty?
      return configured if requested.empty?

      intersection = configured & requested
      intersection.empty? ? ["__cyborg_no_repository_match__"] : intersection
    end

    def bounded_limit(requested, ceiling)
      requested.nil? ? ceiling : [requested, ceiling].min
    end

    def normalize_limits(value)
      raise ArgumentError, "limits must be a hash" unless value.is_a?(Hash)

      value.each_with_object({}) do |(key, item), result|
        raise ArgumentError, "limits must be positive integers" unless item.is_a?(Integer)

        integer = item
        raise ArgumentError, "limits must be positive integers" unless integer.positive?

        result[key.to_s] = integer if %w[max_pages max_records].include?(key.to_s)
      rescue ArgumentError, TypeError
        raise ArgumentError, "limits must be positive integers"
      end
    end

    def page_from_cursor(cursor)
      match = cursor.to_s.match(/\Apage:(\d+)\z/)
      match && match[1].to_i
    end

    def context_limit(context, method)
      return nil unless context.respond_to?(method)

      value = context.public_send(method)
      value.nil? ? nil : Integer(value)
    end

    def context_value(context, method, fallback)
      context.respond_to?(method) ? context.public_send(method) : fallback
    end

    def response_output(response)
      response.respond_to?(:stdout) ? response.stdout.to_s : response.fetch(:stdout).to_s
    end

    def response_success?(response)
      return response.success? if response.respond_to?(:success?)

      status = response.respond_to?(:status) ? response.status : response[:status]
      status.to_i.zero?
    end

    def response_timed_out?(response)
      response.respond_to?(:timed_out) ? response.timed_out : response.fetch(:timed_out, false)
    end

    def response_truncated?(response)
      response.respond_to?(:truncated) ? response.truncated : response.fetch(:truncated, false)
    end

    def login_from_auth(output)
      begin
        parsed = JSON.parse(output)
        return nil unless parsed.is_a?(Hash)
        return parsed["login"].to_s unless parsed["login"].to_s.empty?
        return parsed.dig("user", "login").to_s unless parsed.dig("user", "login").to_s.empty?
      rescue JSON::ParserError
        nil
      end
      match = output.match(/account\s+([A-Za-z0-9][A-Za-z0-9_-]*)/i)
      match && match[1]
    end

    def health(source_name, account_identity, code, checked_at)
      SourceHealth.new(
        source_name:, account_identity: account_identity || @last_login, status: code ? "failed" : "healthy",
        code:, remediation: code && remediation_for(code), checked_at:, message: nil
      )
    end

    def failure_result(source_name, account_identity, started_at, completed_at, code)
      RetrievalResult.new(
        source_name:, account_identity: account_identity || @last_login, status: "failed", data_status: "none",
        cache_reason: nil, started_at:, completed_at:, records: [], next_cursor: nil, error: error_for(code)
      )
    end

    def error_for(code)
      RetrievalError.new(code:, message: safe_message_for(code), remediation: remediation_for(code))
    end

    def safe_message_for(code)
      {
        "github.binary_missing" => "the configured GitHub CLI is unavailable",
        "github.unauthenticated" => "the configured GitHub CLI has no active account for this host",
        "github.api_unavailable" => "the GitHub API request was unavailable or timed out",
        "github.invalid_response" => "the GitHub response was malformed or exceeded configured bounds"
      }.fetch(code.to_s, "the GitHub source could not be retrieved")
    end

    def remediation_for(code)
      case code.to_s
      when "github.binary_missing"
        "Install an executable gh CLI and retry."
      when "github.unauthenticated"
        "Authenticate gh for the configured GitHub host and retry."
      when "github.api_unavailable"
        "Retry GitHub retrieval later."
      when "github.invalid_response"
        "Review GitHub response bounds and source configuration."
      end
    end

    def stringify_hash(value)
      return {} unless value.is_a?(Hash)

      value.each_with_object({}) { |(key, item), result| result[key.to_s] = item.is_a?(Hash) ? stringify_hash(item) : item }
    end

    def positive_integer(value, name)
      integer = Integer(value)
      raise ArgumentError, "#{name} must be positive" unless integer.positive?

      integer
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{name} must be a positive integer"
    end
  end
end
