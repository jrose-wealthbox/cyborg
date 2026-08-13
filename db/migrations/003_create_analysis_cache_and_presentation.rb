# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:analysis_results, **Cyborg::Database.strict_table_options(self)) do
      String :id, text: true, primary_key: true
      foreign_key :run_id, :runs, type: String, text: true, null: false
      String :task_id, text: true, null: false
      String :input_fingerprint, text: true, null: false
      String :output_fingerprint, text: true
      String :validation_status, text: true, null: false
      String :backend_metadata_json, text: true
      String :result_json, text: true
      String :created_at, text: true, null: false
      String :completed_at, text: true

      constraint(:analysis_results_validation_status,
        Sequel.lit("validation_status IN ('pending', 'valid', 'invalid', 'degraded')"))
      index %i[run_id task_id input_fingerprint], unique: true
      index :run_id
    end

    create_table(:presentation_results, **Cyborg::Database.strict_table_options(self)) do
      String :id, text: true, primary_key: true
      foreign_key :run_id, :runs, type: String, text: true, null: false
      String :profile, text: true, null: false
      String :view_model_json, text: true, null: false
      String :created_at, text: true, null: false

      index %i[run_id profile], unique: true
    end

    create_table(:cache_entries, **Cyborg::Database.strict_table_options(self)) do
      String :id, text: true, primary_key: true
      String :stage, text: true, null: false
      String :cache_key, text: true, null: false
      String :cache_class, text: true, null: false
      String :input_fingerprint, text: true, null: false
      String :source_versions_json, text: true
      String :configuration_fingerprint, text: true
      String :model_identity, text: true
      String :created_at, text: true, null: false
      String :expires_at, text: true, null: false
      String :invalidated_at, text: true
      String :invalidation_reason, text: true
      String :payload_json, text: true, null: false

      index %i[stage cache_key], unique: true
      index :expires_at
    end

    create_table(:usage_records, **Cyborg::Database.strict_table_options(self)) do
      String :id, text: true, primary_key: true
      foreign_key :run_id, :runs, type: String, text: true, null: false
      String :task_id, text: true
      String :session_id, text: true
      foreign_key :parent_session_id, :usage_records, type: String, text: true
      Integer :reserved_cost_micros, null: false, default: 0
      Integer :input_tokens
      Integer :output_tokens
      Integer :cost_micros
      String :certainty, text: true, null: false
      String :created_at, text: true, null: false

      constraint(:usage_records_costs, Sequel.lit("reserved_cost_micros >= 0 AND (cost_micros IS NULL OR cost_micros >= 0)"))
      constraint(:usage_records_certainty,
        Sequel.lit("certainty IN ('reserved', 'provider_reported', 'locally_estimated', 'unknown')"))
      index :run_id
      index :session_id
    end

    create_table(:application_state, **Cyborg::Database.strict_table_options(self)) do
      String :key, text: true, primary_key: true
      String :value, text: true, null: false
      String :updated_at, text: true, null: false
    end
  end
end
