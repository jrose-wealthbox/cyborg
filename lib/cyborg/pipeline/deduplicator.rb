# frozen_string_literal: true

require_relative "../bridge/canonical_json"
require_relative "support"

module Cyborg
  module Pipeline
    class Deduplicator
      VERSION = "1.0".freeze

      class Group
        attr_reader :key, :representative, :records, :content_fingerprint
        def initialize(key:, representative:, records:, content_fingerprint:)
          @key, @representative, @records, @content_fingerprint = key, representative, records.freeze, content_fingerprint
          freeze
        end
        def source_record_ids = @records.map { |r| Support.source_record_id(r) }.sort
        def evidence
          @records.flat_map { |r| Array(Support.value(r, :evidence, [])) }
            .sort_by { |item| Bridge::CanonicalJSON.dump(Support.as_hash(item)) }
        end
        def fetch(name, *args) = to_h.fetch(name, *args)
        def [](name) = to_h[name.to_s] || to_h[name.to_sym]
        def to_h = {"group_id" => "group-#{key}", "key" => key, "representative" => representative, "records" => records, "source_record_ids" => source_record_ids, "content_fingerprint" => content_fingerprint, "evidence" => evidence}
      end

      def call(records = nil, **options)
        records ||= options.delete(:records)
        groups = {}
        Array(records).each do |record|
          fingerprint = fingerprint_for(record)
          tuple = [Support.source_name(record), Support.account_identity(record), Support.record_kind(record), fingerprint]
          key = Bridge::CanonicalJSON.sha256(tuple)
          groups[key] ||= {representative: record, records: [], fingerprint: fingerprint}
          groups[key][:records] << record
        end
        groups.sort_by { |key, _| key }.map do |key, data|
          members = data[:records].sort_by { |record| record_identity(record) }
          representative = members.min_by { |record| record_identity(record) }
          Group.new(key:, representative:, records: members, content_fingerprint: data[:fingerprint])
        end
      end

      private
      def fingerprint_for(record)
        fingerprint = Support.fingerprint(record)
        return fingerprint unless fingerprint.empty?
        Bridge::CanonicalJSON.sha256(
          "record_kind" => Support.record_kind(record), "title" => Support.value(record, :title), "summary" => Support.value(record, :summary),
          "structured_fields" => Support.structured_fields(record), "participants" => Array(Support.value(record, :participants, [])),
          "owner_identity" => Support.value(record, :owner_identity), "canonical_target_type" => Support.value(record, :canonical_target_type),
          "canonical_target_id" => Support.value(record, :canonical_target_id), "deep_link" => Support.value(record, :deep_link),
          "event_at" => Support.value(record, :event_at), "latest_reply_at" => Support.value(record, :latest_reply_at)
        )
      end

      def record_identity(record)
        Bridge::CanonicalJSON.dump(
          "source_name" => Support.source_name(record),
          "account_identity" => Support.account_identity(record),
          "source_record_id" => Support.source_record_id(record),
          "record_kind" => Support.record_kind(record),
          "content_fingerprint" => fingerprint_for(record),
          "canonical_target_type" => Support.value(record, :canonical_target_type),
          "canonical_target_id" => Support.value(record, :canonical_target_id)
        )
      end
    end
  end
end
