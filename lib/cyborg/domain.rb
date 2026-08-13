# frozen_string_literal: true

module Cyborg
  Run = Data.define(
    :id, :profile, :execution_mode, :status, :window_start_utc, :window_end_utc,
    :display_timezone, :configuration_fingerprint, :created_at, :completed_at,
    :prior_renderable_run_id, :captured_action_state_version, :prompt_version,
    :backend_capability, :usage_summary_json
  )

  SourceSnapshot = Data.define(
    :id, :run_id, :source_name, :account_identity, :adapter_version, :started_at,
    :completed_at, :status, :data_status, :cache_reason, :error_code,
    :error_remediation, :record_count, :proposed_cursor, :cursor_disposition,
    :prior_activated_snapshot_id
  )

  ObservedRecord = Data.define(
    :id, :source_name, :account_identity, :source_record_id, :record_kind, :title,
    :summary, :structured_fields_json, :participants_json, :owner_identity,
    :canonical_target_type, :canonical_target_id, :deep_link, :event_at,
    :latest_reply_at, :observed_at, :timestamp_kind, :content_fingerprint,
    :first_seen_at, :last_observed_at
  )

  ObservedRecordVersion = Data.define(
    :id, :observed_record_id, :content_fingerprint, :payload_json, :created_at
  )

  Evidence = Data.define(
    :id, :observed_record_version_id, :source_url, :source_label, :excerpt,
    :field_path, :evidence_at, :relation
  )

  ActionSeries = Data.define(
    :id, :current_subject_key, :identity_version, :action_kind,
    :canonical_subject_type, :canonical_subject_id, :normalized_owner_identity,
    :normalized_thread_or_target_identity, :created_at, :updated_at
  )

  InferredAction = Data.define(
    :id, :series_id, :occurrence_number, :inference_status, :action_kind,
    :summary, :related_people_json, :related_projects_json, :due_at, :confidence,
    :user_state, :snoozed_until, :state_version, :first_seen_at, :last_seen_at,
    :terminal_at
  )

  PresentationResult = Data.define(:id, :run_id, :profile, :view_model_json, :created_at)

  module Domain
    module_function

    def from_row(type, row)
      return nil unless row

      type.new(*type.members.map { |member| row[member] })
    end
  end
end
