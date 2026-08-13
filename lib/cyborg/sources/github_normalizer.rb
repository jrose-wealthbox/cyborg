# frozen_string_literal: true

require "uri"
require "time"
require_relative "contracts"
require_relative "../bridge/canonical_json"

module Cyborg
  # Converts untrusted GitHub notification/API payloads into the provider-
  # neutral source contract. It owns identity and URL policy so callers cannot
  # accidentally derive an action target from mutable display text.
  class GithubNormalizer
    CI_REASONS = %w[ci_activity].freeze
    INCLUDED_REASONS = %w[review_requested review_request assign assignment mention team_mention comment author review].freeze
    MAX_TEXT_BYTES = 4_096

    attr_reader :hostname

    def initialize(hostname:, repository_allowlist: [], organization_allowlist: [], repositories: nil, organizations: nil)
      @hostname = normalize_hostname(hostname)
      @repository_allowlist = normalize_allowlist(repositories || repository_allowlist)
      @organization_allowlist = normalize_allowlist(organizations || organization_allowlist)
    end

    def normalize(notification, context:, metadata: nil, pull_request: nil)
      notification = stringify_hash(notification)
      metadata = stringify_hash(metadata || pull_request || {})
      repository = stringify_hash(notification["repository"] || metadata["repository"] || {})
      subject = stringify_hash(notification["subject"] || {})
      full_name = repository["full_name"].to_s
      return nil unless repository_allowed?(full_name)

      reasons = notification_reasons(notification)
      return nil unless include_notification?(notification)

      type = notification["type"].to_s
      number = integer_value(metadata["number"]) || number_from_api_url(subject["url"])
      target_node_id = metadata["node_id"] || subject["node_id"]
      repository_node_id = repository["node_id"] || metadata.dig("repository", "node_id")
      target_type = target_type_for(type, metadata, subject)
      return nil unless target_type && valid_subject_identity?(subject["url"], number)
      return nil unless valid_node_id?(repository_node_id) && valid_node_id?(target_node_id)
      title = bounded_text(metadata["title"] || subject["title"] || full_name)
      summary = bounded_text(metadata["body"] || subject["title"] || notification["reason"])
      event_at = canonical_time(notification["updated_at"] || metadata["updated_at"] || metadata["created_at"] || context.window_end_utc)
      latest_reply_at = latest_reply_time(type, notification, metadata)
      deep_link = trusted_deep_link(metadata["html_url"], full_name, number, target_type)
      participants = participants_for(notification, metadata, repository)
      owner_identity = metadata.dig("user", "login")&.to_s
      structured_fields = structured_fields_for(notification, metadata, repository, reasons, number, target_node_id)
      evidence = deep_link ? [EvidenceDraft.new(
        source_url: deep_link, source_label: "GitHub", excerpt: bounded_text(summary),
        field_path: "summary", evidence_at: event_at, relation: "supports"
      )] : []
      payload = {
        "source_record_id" => notification["id"].to_s,
        "record_kind" => record_kind(type, reasons),
        "title" => title,
        "summary" => summary,
        "structured_fields" => structured_fields,
        "participants" => participants,
        "owner_identity" => owner_identity,
        "canonical_target_type" => target_type,
        "canonical_target_id" => stable_target_id(repository_node_id, target_node_id),
        "deep_link" => deep_link,
        "event_at" => event_at,
        "latest_reply_at" => latest_reply_at,
        "timestamp_kind" => latest_reply_at ? "latest_reply_at" : "event_at"
      }
      NormalizedRecord.new(
        source_record_id: notification["id"].to_s,
        record_kind: payload.fetch("record_kind"), title:, summary:, structured_fields:, participants:,
        owner_identity:, canonical_target_type: target_type,
        canonical_target_id: stable_target_id(repository_node_id, target_node_id), deep_link:,
        event_at:, latest_reply_at:, observed_at: context.window_end_utc,
        timestamp_kind: payload.fetch("timestamp_kind"),
        content_fingerprint: Bridge::CanonicalJSON.sha256(payload), evidence:
      )
    end

    alias normalize_notification normalize

    def include_notification?(notification)
      reasons = notification_reasons(stringify_hash(notification))
      return false if reasons.empty?
      (reasons & INCLUDED_REASONS).any?
    end

    def allowed_repository?(notification)
      repository = stringify_hash(notification)["repository"] || {}
      repository_allowed?(stringify_hash(repository)["full_name"])
    end

    def trusted_url?(url)
      uri = URI.parse(url.to_s)
      uri.scheme == "https" && uri.host == hostname && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
    rescue URI::InvalidURIError
      false
    end

    def stable_target_id(repository_node_id, target_node_id)
      return nil unless valid_node_id?(repository_node_id) && valid_node_id?(target_node_id)

      [hostname, repository_node_id, target_node_id].join(":")
    end

    def valid_node_id?(value)
      value.is_a?(String) && !value.strip.empty?
    end

    def valid_subject_identity?(url, number)
      return false unless number

      uri = URI.parse(url.to_s)
      return false unless uri.scheme == "https" && [hostname, "api.#{hostname}"].include?(uri.host)
      return false if uri.userinfo || uri.query || uri.fragment

      uri.path.to_s.match?(%r{/repos/[^/\s]+/[^/\s]+/(?:pulls|issues)/#{number}\z})
    rescue URI::InvalidURIError
      false
    end

    private

    def normalize_hostname(value)
      value = value.to_s.strip.downcase
      value = URI.parse(value).host if value.include?("://")
      value = value.to_s.strip.downcase
      raise ArgumentError, "GitHub hostname is required" if value.empty? || value.include?("/") || value.include?(" ")

      value.freeze
    rescue URI::InvalidURIError
      raise ArgumentError, "GitHub hostname is invalid"
    end

    def normalize_allowlist(values)
      Array(values).map { |value| value.to_s.strip.downcase }.reject(&:empty?).uniq.freeze
    end

    def repository_allowed?(full_name)
      owner, = full_name.to_s.split("/", 2)
      return false if !@repository_allowlist.empty? && !@repository_allowlist.include?(full_name.to_s.downcase)
      return false if !@organization_allowlist.empty? && !@organization_allowlist.include?(owner.to_s.downcase)

      true
    end

    def stringify_hash(value)
      return {} unless value.is_a?(Hash)

      value.each_with_object({}) { |(key, item), result| result[key.to_s] = item.is_a?(Hash) ? stringify_hash(item) : item }
    end

    def notification_reasons(notification)
      values = [notification["reason"]]
      values.concat(Array(notification["reasons"]))
      values.flatten.compact.map { |value| value.to_s.downcase }.reject(&:empty?).uniq
    end

    def target_type_for(type, metadata, subject)
      number = metadata["number"] || subject["number"]
      return "github_pr" if type.casecmp?("PullRequest") || metadata.key?("merged_at") || metadata.key?("requested_reviewers") || pull_request_url?(subject["url"])
      return "github_issue" if number

      nil
    end

    def record_kind(type, reasons)
      return "review_request" if reasons.include?("review_requested") || reasons.include?("review_request")
      return "assignment" if reasons.include?("assign") || reasons.include?("assignment")
      return "mention" if reasons.include?("mention") || reasons.include?("team_mention")
      return "review" if type.downcase.include?("review")
      return "comment" if type.downcase.include?("comment") || reasons.include?("comment") || reasons.include?("author")

      type.empty? ? "notification" : type.gsub(/([a-z])([A-Z])/, '\\1_\\2').downcase
    end

    def structured_fields_for(notification, metadata, repository, reasons, number, target_node_id)
      fields = {
        "notification_type" => notification["type"].to_s,
        "reason" => reasons.first,
        "reasons" => reasons,
        "repository" => repository["full_name"].to_s,
        "repository_node_id" => repository["node_id"],
        "target_node_id" => target_node_id,
        "number" => number,
        "comments" => metadata["comments"],
        "review_comments" => metadata["review_comments"],
        "reviews" => metadata["reviews"]
      }
      fields.delete_if { |_key, value| value.nil? }
      fields
    end

    def participants_for(notification, metadata, repository)
      values = []
      values << repository.dig("owner", "login")
      values << notification.dig("sender", "login")
      values << metadata.dig("user", "login")
      values.concat(Array(metadata["requested_reviewers"]).map { |item| item.is_a?(Hash) ? item["login"] : item })
      values.concat(Array(metadata["assignees"]).map { |item| item.is_a?(Hash) ? item["login"] : item })
      values.map { |value| value.to_s.strip }.reject(&:empty?).uniq.sort
    end

    def latest_reply_time(type, notification, metadata)
      reasons = notification_reasons(notification)
      return nil unless type.downcase.include?("comment") || type.downcase.include?("review") || (reasons & %w[comment review]).any?

      canonical_time(metadata["updated_at"] || metadata["created_at"] || notification["updated_at"])
    end

    def canonical_time(value)
      return nil if value.nil?

      Time.iso8601(value.to_s).utc.iso8601
    rescue ArgumentError
      nil
    end

    def number_from_api_url(url)
      path = URI.parse(url.to_s).path
      match = path.to_s.match(%r{/\d+/(?:pulls|issues|pull)/(?<number>\d+)\z}) || path.to_s.match(%r{/(?:pulls|issues|pull)/(?<number>\d+)\z})
      match && match[:number].to_i
    rescue URI::InvalidURIError
      nil
    end

    def pull_request_url?(url)
      URI.parse(url.to_s).path.to_s.match?(%r{/pulls/\d+\z})
    rescue URI::InvalidURIError
      false
    end

    def integer_value(value)
      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end

    def trusted_deep_link(candidate, full_name, number, target_type)
      return candidate.to_s if trusted_url?(candidate)
      return nil unless full_name.to_s.match?(/\A[^\s\/]+\/[^\s\/]+\z/) && number

      suffix = target_type == "github_pr" ? "pull" : "issues"
      "https://#{hostname}/#{full_name}/#{suffix}/#{number}"
    end

    def bounded_text(value)
      text = value.to_s
      return text if text.bytesize <= MAX_TEXT_BYTES

      text.byteslice(0, MAX_TEXT_BYTES).force_encoding(Encoding::UTF_8).scrub
    end
  end
end
