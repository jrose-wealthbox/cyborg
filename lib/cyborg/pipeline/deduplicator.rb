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
        def source_record_ids = @records.map { |r| Support.source_record_id(r) }
        def evidence = @records.flat_map { |r| Array(Support.value(r, :evidence, [])) }
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
        groups.sort_by { |key, _| key }.map { |key, data| Group.new(key:, representative: data[:representative], records: data[:records], content_fingerprint: data[:fingerprint]) }
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
    end
  end
end
