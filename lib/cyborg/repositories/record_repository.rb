# frozen_string_literal: true

require_relative "base"

module Cyborg
  module Repositories
    class RecordRepository < Base
      def create_or_update_record(attributes)
        attrs = attributes.to_h
        validate_timestamps!(attrs, %i[event_at latest_reply_at observed_at first_seen_at last_observed_at])
        identity = attrs.slice(:source_name, :account_identity, :source_record_id, :record_kind)
        existing = db[:observed_records].where(identity).first
        if existing
          mutable = attrs.reject do |key, _value|
            %i[id source_name account_identity source_record_id record_kind first_seen_at].include?(key)
          end
          db[:observed_records].where(id: existing.fetch(:id)).update(mutable)
          observed_record(existing.fetch(:id))
        else
          db[:observed_records].insert(attrs)
          observed_record(attrs.fetch(:id))
        end
      end

      alias upsert_record create_or_update_record

      def observed_record(id)
        value(ObservedRecord, row(db[:observed_records], id))
      end

      def records_for_snapshot(snapshot_id)
        db[:snapshot_records].join(:observed_record_versions, id: :record_version_id).join(
          :observed_records, id: :observed_record_id
        ).where(snapshot_id:).select_all(:observed_records).all.map { |record| value(ObservedRecord, record) }
      end

      def create_version(attributes)
        attrs = attributes.to_h
        validate_timestamps!(attrs, %i[created_at])
        existing = db[:observed_record_versions].where(
          observed_record_id: attrs.fetch(:observed_record_id),
          content_fingerprint: attrs.fetch(:content_fingerprint)
        ).first
        return version(existing.fetch(:id)) if existing

        db[:observed_record_versions].insert(attrs)
        version(attrs.fetch(:id))
      end

      alias upsert_version create_version

      def version(id)
        value(ObservedRecordVersion, row(db[:observed_record_versions], id))
      end

      def attach_to_snapshot(snapshot_id:, record_version_id:)
        db[:snapshot_records].insert(snapshot_id:, record_version_id:)
        true
      end

      def create_evidence(attributes)
        attrs = attributes.to_h
        validate_timestamps!(attrs, %i[evidence_at])
        db[:evidence].insert(attrs)
        evidence(attrs.fetch(:id))
      end

      def evidence(id)
        value(Evidence, row(db[:evidence], id))
      end
    end
  end
end
