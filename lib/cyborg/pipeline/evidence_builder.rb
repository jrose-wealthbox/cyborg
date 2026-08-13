# frozen_string_literal: true

require "uri"
require_relative "../bridge/canonical_json"
require_relative "../errors"
require_relative "../redactor"
require_relative "support"

module Cyborg
  module Pipeline
    # Turns source-owned evidence drafts into a small, provider-neutral shape.
    # The source payload is untrusted: only links on an explicitly configured
    # HTTPS host are retained and excerpts are redacted and byte bounded.
    class EvidenceBuilder
      VERSION = "1.0".freeze
      DEFAULT_MAX_EXCERPT_BYTES = 1_024
      DEFAULT_MAX_EVIDENCE = 50

      attr_reader :trusted_hosts, :maximum_excerpt_bytes

      def initialize(trusted_hosts: [], maximum_excerpt_bytes: DEFAULT_MAX_EXCERPT_BYTES,
                     max_excerpt_bytes: nil, maximum_evidence: DEFAULT_MAX_EVIDENCE,
                     max_evidence: nil, redactor: nil, **options)
        unless options.empty?
          raise ArgumentError, "unknown options: #{options.keys.join(", ")}"
        end

        @trusted_hosts = normalize_hosts(trusted_hosts)
        @maximum_excerpt_bytes = positive_integer(max_excerpt_bytes || maximum_excerpt_bytes, "maximum_excerpt_bytes")
        @maximum_evidence = positive_integer(max_evidence || maximum_evidence, "maximum_evidence")
        @redactor = redactor || Cyborg::Redactor.new
      end

      def call(record = nil, **options)
        record ||= options.delete(:record)
        raise ArgumentError, "record is required" unless record

        drafts = Array(Support.value(record, :evidence, []))
        # A normalized record's deep link is the canonical target URL.  It is
        # preferred over a draft URL because drafts may carry source text or a
        # mutable URL supplied by an adapter.
        record_url = trusted_url(Support.value(record, :deep_link))
        source_record_id = redact_and_bound(Support.source_record_id(record), 512)
        record_kind = Support.record_kind(record)
        source_name = redact_and_bound(Support.source_name(record), 256)
        account_identity = Support.account_identity(record)
        account_identity = Support.value(record, :owner_identity) if account_identity.empty?
        account_identity = redact_and_bound(account_identity, 256)

        drafts.first(@maximum_evidence).filter_map do |draft|
          draft_hash = Support.as_hash(draft)
          draft_url = trusted_url(Support.hash_value(draft_hash, :source_url))
          source_url = record_url || draft_url
          excerpt = redact_and_bound(Support.hash_value(draft_hash, :excerpt))
          source_label = redact_and_bound(Support.hash_value(draft_hash, :source_label), 256)
          field_path = redact_and_bound(Support.hash_value(draft_hash, :field_path), 256)
          evidence_at = Support.canonical_time(Support.hash_value(draft_hash, :evidence_at))
          relation = redact_and_bound(Support.hash_value(draft_hash, :relation), 128)

          # Keep evidence even when its URL is not trusted: the evidence ID
          # and excerpt can still explain why a record was considered, while
          # `source_url: nil` prevents an unsafe link from crossing the
          # analysis boundary.
          identity = {
            "source_record_id" => source_record_id,
            "source_name" => source_name,
            "account_identity" => account_identity,
            "record_kind" => record_kind,
            "source_url" => source_url,
            "source_label" => source_label,
            "excerpt" => excerpt,
            "field_path" => field_path,
            "evidence_at" => evidence_at,
            "relation" => relation
          }

          {
            "evidence_id" => "evidence-#{Bridge::CanonicalJSON.sha256(identity)}",
            "source_record_id" => source_record_id,
            "source_url" => source_url,
            "source_label" => source_label,
            "excerpt" => excerpt,
            "field_path" => field_path,
            "evidence_at" => evidence_at,
            "relation" => relation
          }
        end
      end

      def trusted_url?(url)
        !trusted_url(url).nil?
      end

      def trusted_url(url)
        return nil unless url.is_a?(String) && !url.empty?

        uri = URI.parse(url)
        return nil unless uri.scheme == "https" && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?

        host = uri.host.to_s.downcase
        return nil if host.empty? || !@trusted_hosts.include?(host)

        # A trusted host does not make a credential-bearing path safe.
        # Reject rather than redact URLs so no ambiguous link crosses the
        # boundary and callers cannot accidentally follow a modified URL.
        return nil unless @redactor.call(uri.to_s) == uri.to_s

        uri.to_s
      rescue URI::InvalidURIError
        nil
      end

      private

      def normalize_hosts(hosts)
        Array(hosts).filter_map do |host|
          value = host.to_s.strip.downcase
          next if value.empty?

          begin
            value = URI.parse(value).host if value.include?("://")
          rescue URI::InvalidURIError
            value = nil
          end
          value unless value.to_s.empty? || value.include?("/") || value.include?(" ")
        end.uniq.freeze
      end

      def redact_and_bound(value, limit = @maximum_excerpt_bytes)
        return nil if value.nil?

        redacted = @redactor.call(value.to_s)
        Support.bounded_string(redacted, limit)
      end

      def positive_integer(value, field)
        unless value.is_a?(Integer) && value.positive?
          raise ArgumentError, "#{field} must be a positive integer"
        end
        value
      end
    end
  end
end
