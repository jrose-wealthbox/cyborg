# frozen_string_literal: true

require "json"
require "securerandom"
require_relative "contracts"
require_relative "../repositories/source_repository"
require_relative "../repositories/record_repository"

module Cyborg
  class SourceIngestor
    def initialize(db:, source_repository: nil, record_repository: nil)
      @db = db
      @sources = source_repository || Repositories::SourceRepository.new(db)
      @records = record_repository || Repositories::RecordRepository.new(db)
    end

    def ingest(run:, registration:, result:)
      unless result.source_name.to_s == registration.source_name.to_s && result.account_identity.to_s == registration.account_identity.to_s
        raise ArgumentError, "retrieval result does not match source registration"
      end
      disposition = result.complete_fresh? ? "advance" : "hold"
      baseline = @sources.baseline_for(registration.source_name, registration.account_identity)

      @db.transaction do
        snapshot = @sources.create_snapshot(
          run:, registration:, result:, cursor_disposition: disposition,
          prior_activated_snapshot_id: baseline&.fetch(:activated_snapshot_id)
        )
        result.records.each { |record| persist_record(snapshot, run, registration, record) }
        snapshot
      end
    end

    private

    def persist_record(snapshot, run, registration, record)
      record = sanitize_record(record, registration)
      observed_at = record.observed_at || snapshot.completed_at || snapshot.started_at
      event_at = record.event_at || record.latest_reply_at || observed_at
      payload = payload_for(record, event_at, observed_at)
      existing = @db[:observed_records].where(source_name: registration.source_name, account_identity: registration.account_identity, source_record_id: record.source_record_id, record_kind: record.record_kind).first
      local_id = existing ? existing.fetch(:id) : SecureRandom.uuid
      observed = @records.create_or_update_record(
        id: local_id, source_name: registration.source_name, account_identity: registration.account_identity,
        source_record_id: record.source_record_id, record_kind: record.record_kind, title: record.title,
        summary: record.summary, structured_fields_json: record.structured_fields_json,
        participants_json: record.participants_json, owner_identity: record.owner_identity,
        canonical_target_type: record.canonical_target_type, canonical_target_id: record.canonical_target_id,
        deep_link: record.deep_link, event_at: event_at, latest_reply_at: record.latest_reply_at,
        observed_at: observed_at, timestamp_kind: record.timestamp_kind,
        content_fingerprint: record.content_fingerprint, first_seen_at: observed_at, last_observed_at: observed_at
      )
      version = @records.create_version(
        id: SecureRandom.uuid, observed_record_id: observed.id, content_fingerprint: record.content_fingerprint,
        payload_json: JSON.generate(payload), created_at: observed_at
      )
      @records.attach_to_snapshot(snapshot_id: snapshot.id, record_version_id: version.id) unless @db[:snapshot_records].where(snapshot_id: snapshot.id, record_version_id: version.id).first
      Array(record.evidence).each do |draft|
        attrs = draft.to_h
        next if @db[:evidence].where(observed_record_version_id: version.id, source_url: attrs[:source_url], field_path: attrs[:field_path], excerpt: attrs[:excerpt], evidence_at: attrs[:evidence_at]).first

        @records.create_evidence(
          id: SecureRandom.uuid, observed_record_version_id: version.id, source_url: attrs.fetch(:source_url),
          source_label: attrs.fetch(:source_label), excerpt: attrs[:excerpt], field_path: attrs[:field_path],
          evidence_at: attrs.fetch(:evidence_at), relation: attrs.fetch(:relation, "context")
        )
      end
    end

    def sanitize_record(record, registration)
      allowed = Array(registration.allowed_fields).map(&:to_s)
      return record if allowed.empty?

      structured_fields = record.structured_fields.each_with_object({}) do |(key, value), result|
        result[key] = value if allowed.include?(key.to_s)
      end
      evidence = if allowed.include?("evidence")
        record.evidence.map do |draft|
          draft.with(
            excerpt: allowed.include?("excerpt") ? draft.excerpt : nil,
            field_path: allowed.include?("field_path") ? draft.field_path : nil
          )
        end
      else
        []
      end
      record.with(
        title: allowed.include?("title") ? record.title : nil,
        summary: allowed.include?("summary") ? record.summary : nil,
        structured_fields: structured_fields,
        participants: allowed.include?("participants") ? record.participants : [],
        owner_identity: allowed.include?("owner_identity") ? record.owner_identity : nil,
        canonical_target_type: allowed.include?("canonical_target_type") ? record.canonical_target_type : nil,
        canonical_target_id: allowed.include?("canonical_target_id") ? record.canonical_target_id : nil,
        deep_link: allowed.include?("deep_link") ? record.deep_link : nil,
        evidence:
      )
    end

    def payload_for(record, event_at, observed_at)
      payload = {
        "source_record_id" => record.source_record_id,
        "record_kind" => record.record_kind,
        "event_at" => event_at,
        "latest_reply_at" => record.latest_reply_at,
        "observed_at" => observed_at,
        "timestamp_kind" => record.timestamp_kind,
        "content_fingerprint" => record.content_fingerprint
      }
      {
        "title" => record.title, "summary" => record.summary, "structured_fields" => record.structured_fields,
        "participants" => record.participants, "owner_identity" => record.owner_identity,
        "canonical_target_type" => record.canonical_target_type, "canonical_target_id" => record.canonical_target_id,
        "deep_link" => record.deep_link
      }.each { |key, value| payload[key] = value unless value.nil? }
      payload
    end
  end
end
