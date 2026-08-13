# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:observed_records, strict: true) do
      String :id, text: true, primary_key: true
      String :source_name, text: true, null: false
      String :account_identity, text: true, null: false
      String :source_record_id, text: true, null: false
      String :record_kind, text: true, null: false
      String :title, text: true
      String :summary, text: true
      String :structured_fields_json, text: true
      String :participants_json, text: true
      String :owner_identity, text: true
      String :canonical_target_type, text: true
      String :canonical_target_id, text: true
      String :deep_link, text: true
      String :event_at, text: true, null: false
      String :latest_reply_at, text: true
      String :observed_at, text: true, null: false
      String :timestamp_kind, text: true, null: false
      String :content_fingerprint, text: true, null: false
      String :first_seen_at, text: true, null: false
      String :last_observed_at, text: true, null: false

      index %i[source_name account_identity source_record_id record_kind], unique: true
      index %i[source_name account_identity]
    end

    create_table(:observed_record_versions, strict: true) do
      String :id, text: true, primary_key: true
      foreign_key :observed_record_id, :observed_records, type: String, text: true, null: false
      String :content_fingerprint, text: true, null: false
      String :payload_json, text: true, null: false
      String :created_at, text: true, null: false

      index %i[observed_record_id content_fingerprint], unique: true
      index :observed_record_id
    end

    create_table(:snapshot_records, strict: true) do
      foreign_key :snapshot_id, :source_snapshots, type: String, text: true, null: false
      foreign_key :record_version_id, :observed_record_versions, type: String, text: true, null: false

      primary_key %i[snapshot_id record_version_id]
    end

    create_table(:evidence, strict: true) do
      String :id, text: true, primary_key: true
      foreign_key :observed_record_version_id, :observed_record_versions, type: String, text: true, null: false
      String :source_url, text: true, null: false
      String :source_label, text: true, null: false
      String :excerpt, text: true
      String :field_path, text: true
      String :evidence_at, text: true, null: false
      String :relation, text: true, null: false, default: "context"

      constraint(:evidence_relation, Sequel.lit("relation IN ('supports', 'contradicts', 'context')"))
      index :observed_record_version_id
    end

    create_table(:action_series, strict: true) do
      String :id, text: true, primary_key: true
      String :current_subject_key, text: true, null: false
      Integer :identity_version, null: false
      String :action_kind, text: true, null: false
      String :canonical_subject_type, text: true, null: false
      String :canonical_subject_id, text: true, null: false
      String :normalized_owner_identity, text: true
      String :normalized_thread_or_target_identity, text: true
      String :created_at, text: true, null: false
      String :updated_at, text: true, null: false

      index :current_subject_key, unique: true
      index %i[current_subject_key identity_version], unique: true
    end

    create_table(:inferred_actions, strict: true) do
      String :id, text: true, primary_key: true
      foreign_key :series_id, :action_series, type: String, text: true, null: false
      Integer :occurrence_number, null: false
      String :inference_status, text: true, null: false, default: "active"
      String :action_kind, text: true, null: false
      String :summary, text: true, null: false
      String :related_people_json, text: true
      String :related_projects_json, text: true
      String :due_at, text: true
      column :confidence, :real, null: false
      String :user_state, text: true, null: false, default: "open"
      String :snoozed_until, text: true
      Integer :state_version, null: false, default: 0
      String :first_seen_at, text: true, null: false
      String :last_seen_at, text: true, null: false
      String :terminal_at, text: true

      constraint(:inferred_actions_occurrence_number, Sequel.lit("occurrence_number > 0"))
      constraint(:inferred_actions_confidence, Sequel.lit("confidence >= 0 AND confidence <= 1"))
      constraint(:inferred_actions_inference_status,
        Sequel.lit("inference_status IN ('active', 'stale', 'superseded')"))
      constraint(:inferred_actions_user_state,
        Sequel.lit("user_state IN ('open', 'acknowledged', 'snoozed', 'done', 'dismissed')"))
      index %i[series_id occurrence_number], unique: true
      index %i[user_state inference_status]
    end

    create_table(:action_key_aliases, strict: true) do
      String :subject_key, text: true, primary_key: true
      foreign_key :series_id, :action_series, type: String, text: true, null: false
      Integer :identity_version, null: false
      String :created_at, text: true, null: false

      index :subject_key, unique: true
      index :series_id
    end

    create_table(:action_evidence, strict: true) do
      foreign_key :action_id, :inferred_actions, type: String, text: true, null: false
      foreign_key :evidence_id, :evidence, type: String, text: true, null: false
      foreign_key :first_seen_run_id, :runs, type: String, text: true, null: false
      foreign_key :last_seen_run_id, :runs, type: String, text: true, null: false
      String :first_seen_at, text: true, null: false
      String :last_seen_at, text: true, null: false

      primary_key %i[action_id evidence_id]
    end

    create_table(:action_transitions, strict: true) do
      primary_key :id
      foreign_key :action_id, :inferred_actions, type: String, text: true, null: false
      String :from_state, text: true, null: false
      String :to_state, text: true, null: false
      String :changed_at, text: true, null: false
      String :origin, text: true, null: false
      Integer :state_version, null: false

      index %i[action_id changed_at]
    end

    create_table(:action_successors, strict: true) do
      foreign_key :predecessor_action_id, :inferred_actions, type: String, text: true, null: false
      foreign_key :successor_action_id, :inferred_actions, type: String, text: true, null: false
      String :created_at, text: true, null: false

      primary_key %i[predecessor_action_id successor_action_id]
      index :predecessor_action_id, unique: true
      index :successor_action_id, unique: true
      constraint(:action_successors_not_self, Sequel.lit("predecessor_action_id <> successor_action_id"))
    end
  end
end
