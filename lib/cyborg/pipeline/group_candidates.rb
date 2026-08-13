# frozen_string_literal: true

require_relative "../bridge/canonical_json"
require_relative "evidence_builder"
require_relative "support"

module Cyborg
  module Pipeline
    # Groups records using only deterministic identities.  Semantic grouping
    # remains an analysis task; this class merely exposes bounded candidates
    # and the questions that still need interpretation.
    class GroupCandidates
      VERSION = "1.0".freeze
      DEFAULT_MAX_GROUPS = 500

      def initialize(evidence_builder: nil, trusted_hosts: [], maximum_evidence: EvidenceBuilder::DEFAULT_MAX_EVIDENCE,
                     max_groups: DEFAULT_MAX_GROUPS, **options)
        unless options.empty?
          raise ArgumentError, "unknown options: #{options.keys.join(", ")}"
        end

        @evidence_builder = evidence_builder || EvidenceBuilder.new(
          trusted_hosts:, maximum_evidence:
        )
        @max_groups = positive_integer(max_groups, "max_groups")
      end

      def call(records = nil, **options)
        records ||= options.delete(:records)
        rows = Array(records)
        grouped = {}

        rows.each do |record|
          evidence = @evidence_builder.call(record)
          fingerprint = fingerprint_for(record)
          identity = deterministic_identity(record, fingerprint)
          group_key = Bridge::CanonicalJSON.sha256(identity)
          entry = (grouped[group_key] ||= {
            key: group_key,
            identity: identity,
            fingerprint: fingerprint,
            records: [],
            evidence: [],
            exact_fingerprint: true
          })
          entry[:records] << record
          entry[:evidence].concat(evidence)
          entry[:exact_fingerprint] &&= fingerprint == entry[:fingerprint]
        end

        grouped.sort_by { |key, _entry| key }.first(@max_groups).map do |_key, entry|
          records_for_group = entry[:records]
          evidence = entry[:evidence].uniq { |item| item.fetch("evidence_id") }.sort_by { |item| item.fetch("evidence_id") }
          source_record_ids = records_for_group.map { |record| Support.source_record_id(record) }.sort
          representative = records_for_group.min_by do |record|
            [Support.selected_time(record).to_s, Support.source_name(record), Support.source_record_id(record)]
          end
          identity = entry[:identity]
          exact = entry[:exact_fingerprint] && records_for_group.map { |record| fingerprint_for(record) }.uniq.length == 1

          {
            "group_id" => "group-#{entry[:key]}",
            "group_key" => entry[:key],
            "source_record_ids" => source_record_ids,
            "record_kinds" => records_for_group.map { |record| Support.record_kind(record) }.uniq.sort,
            "content_fingerprint" => entry[:fingerprint],
            "canonical_target_type" => identity["canonical_target_type"],
            "canonical_target_id" => identity["canonical_target_id"],
            "representative" => record_summary(representative),
            "evidence_ids" => evidence.map { |item| item.fetch("evidence_id") },
            "evidence" => evidence,
            "unresolved_questions" => unresolved_questions(records_for_group, exact, identity)
          }
        end
      end

      private

      def deterministic_identity(record, fingerprint)
        target_type = Support.value(record, :canonical_target_type)
        target_id = Support.value(record, :canonical_target_id)
        # An explicit canonical target is the strongest deterministic identity.
        # Fingerprints still distinguish unrelated records without a target.
        if Support.nonempty(target_type) && Support.nonempty(target_id)
          {
            "identity_type" => "canonical_target",
            "canonical_target_type" => target_type.to_s,
            "canonical_target_id" => target_id.to_s
          }
        else
          {
            "identity_type" => "content",
            "source_name" => Support.source_name(record),
            "account_identity" => Support.account_identity(record),
            "record_kind" => Support.record_kind(record),
            "content_fingerprint" => fingerprint
          }
        end
      end

      def fingerprint_for(record)
        supplied = Support.fingerprint(record)
        return supplied unless supplied.empty?

        Bridge::CanonicalJSON.sha256(
          "record_kind" => Support.record_kind(record),
          "title" => Support.value(record, :title),
          "summary" => Support.value(record, :summary),
          "structured_fields" => Support.structured_fields(record),
          "participants" => Array(Support.value(record, :participants, [])),
          "owner_identity" => Support.value(record, :owner_identity),
          "canonical_target_type" => Support.value(record, :canonical_target_type),
          "canonical_target_id" => Support.value(record, :canonical_target_id),
          "deep_link" => Support.value(record, :deep_link),
          "event_at" => Support.value(record, :event_at),
          "latest_reply_at" => Support.value(record, :latest_reply_at)
        )
      end

      def record_summary(record)
        return {} unless record

        {
          "source_record_id" => Support.source_record_id(record),
          "source_name" => Support.source_name(record),
          "account_identity" => Support.account_identity(record),
          "record_kind" => Support.record_kind(record),
          "title" => Support.value(record, :title),
          "summary" => Support.value(record, :summary),
          "event_at" => Support.canonical_time(Support.value(record, :event_at)),
          "latest_reply_at" => Support.canonical_time(Support.value(record, :latest_reply_at))
        }
      end

      def unresolved_questions(records, exact, identity)
        return [] if exact

        questions = []
        questions << "Do these records describe one actionable commitment?" if records.length > 1
        if identity["identity_type"] != "canonical_target"
          questions << "What canonical subject should anchor this candidate?"
        end
        questions
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
