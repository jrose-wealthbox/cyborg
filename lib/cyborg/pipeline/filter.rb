# frozen_string_literal: true

require_relative "support"

module Cyborg
  module Pipeline
    class Filter
      VERSION = "1.0".freeze
      DEFAULT_MAX_RECORDS = 500
      CI_REASONS = %w[ci_activity check_suite check_run].freeze

      def initialize(window_start_utc: nil, window_end_utc: nil, filters: {}, max_records: nil, source_name: nil, **_options)
        @start_at = Support.canonical_time(window_start_utc)
        @end_at = Support.canonical_time(window_end_utc)
        @filters = stringify(filters)
        @max_records = max_records.nil? ? nil : positive(max_records, "max_records")
        @source_name = source_name&.to_s
      end

      def call(records = nil, context: nil, window_start_utc: nil, window_end_utc: nil, filters: nil, max_records: nil, **options)
        records ||= options.delete(:records) || Support.value(context, :records, [])
        start_at = Support.canonical_time(window_start_utc) || @start_at || Support.canonical_time(Support.value(context, :window_start_utc))
        end_at = Support.canonical_time(window_end_utc) || @end_at || Support.canonical_time(Support.value(context, :window_end_utc))
        policy = @filters.merge(stringify(filters || {}))
        limit = positive(max_records || @max_records || Support.value(context, :max_records) || DEFAULT_MAX_RECORDS, "max_records")
        Array(records).select { |record| eligible?(record, start_at, end_at, policy) }.sort_by { |record| sort_key(record) }.first(limit)
      end

      private

      def eligible?(record, start_at, end_at, filters)
        return false if @source_name && Support.source_name(record) != @source_name
        source_names = values(filters, "sources", "source_names")
        return false if source_names.any? && !source_names.include?(Support.source_name(record).downcase)
        kinds = values(filters, "record_kinds", "kinds", "include_kinds")
        return false if kinds.any? && !kinds.include?(Support.record_kind(record).downcase)
        excluded = values(filters, "exclude_record_kinds", "exclude_kinds")
        return false if excluded.include?(Support.record_kind(record).downcase)
        fields = Support.structured_fields(record)
        repository = (fields["repository"] || fields["repository_full_name"] || fields["repo"] || fields["full_name"]).to_s.downcase
        repositories = values(filters, "repositories", "repository_allowlist", "allowed_repositories")
        return false if repositories.any? && !repositories.include?(repository)
        organizations = values(filters, "organizations", "organization_allowlist", "allowed_organizations", "orgs")
        return false if organizations.any? && !organizations.include?(repository.split("/", 2).first)
        return false if truthy?(filters["unread_only"]) && !truthy?(fields["unread"])
        return false if truthy?(filters["exclude_ci_only"]) && ci_only?(record, fields)
        timestamp = Support.selected_time(record)
        return false if (start_at || end_at) && timestamp.nil?
        return false if start_at && timestamp < start_at
        return false if end_at && timestamp > end_at
        true
      end

      def ci_only?(record, fields)
        return false unless Support.source_name(record).casecmp?("github")
        reasons = Array(fields["reasons"] || fields["reason"]).map { |r| r.to_s.downcase }
        reasons.any? && (reasons - CI_REASONS).empty?
      end

      def sort_key(record)
        [Support.selected_time(record).to_s, Support.source_name(record), Support.account_identity(record), Support.record_kind(record), Support.source_record_id(record), Support.fingerprint(record)]
      end

      def values(filters, *keys)
        key = keys.find { |candidate| filters.key?(candidate) }
        key ? Support.normalize_values(filters[key]) : []
      end

      def stringify(value)
        value.is_a?(Hash) ? value.each_with_object({}) { |(k, v), h| h[k.to_s] = v } : {}
      end

      def truthy?(value) = value == true || %w[true 1 yes on].include?(value.to_s.downcase)
      def positive(value, field)
        raise ArgumentError, "#{field} must be a positive integer" unless value.is_a?(Integer) && value.positive?
        value
      end
    end
  end
end
