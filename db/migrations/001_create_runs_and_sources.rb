# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:runs, strict: true) do
      String :id, text: true, primary_key: true
      String :profile, text: true, null: false
      String :execution_mode, text: true, null: false
      String :status, text: true, null: false
      String :window_start_utc, text: true, null: false
      String :window_end_utc, text: true, null: false
      String :display_timezone, text: true, null: false
      String :configuration_fingerprint, text: true, null: false
      String :created_at, text: true, null: false
      String :completed_at, text: true
      foreign_key :prior_renderable_run_id, :runs, type: String, text: true
      Integer :captured_action_state_version, null: false, default: 0
      String :prompt_version, text: true
      String :backend_capability, text: true
      String :usage_summary_json, text: true

      constraint(:runs_status, Sequel.lit("status IN ('running', 'completed', 'degraded', 'failed')"))
      index :status
    end

    # A singleton row makes the active lease invariant structural.  Expiration
    # is handled by the run lifecycle, while this table prevents two owners.
    create_table(:run_leases, strict: true) do
      Integer :id, primary_key: true, default: 1
      foreign_key :run_id, :runs, type: String, text: true, null: false
      String :token_fingerprint, text: true, null: false
      String :created_at, text: true, null: false
      String :heartbeat_at, text: true, null: false
      String :expires_at, text: true, null: false

      constraint(:run_leases_singleton, Sequel.lit("id = 1"))
      index :run_id, unique: true
    end

    create_table(:source_snapshots, strict: true) do
      String :id, text: true, primary_key: true
      foreign_key :run_id, :runs, type: String, text: true, null: false
      String :source_name, text: true, null: false
      String :account_identity, text: true, null: false
      String :adapter_version, text: true, null: false
      String :started_at, text: true, null: false
      String :completed_at, text: true
      String :status, text: true, null: false
      String :data_status, text: true, null: false
      String :cache_reason, text: true
      String :error_code, text: true
      String :error_remediation, text: true
      Integer :record_count, null: false, default: 0
      String :proposed_cursor, text: true
      String :cursor_disposition, text: true, null: false, default: "hold"
      foreign_key :prior_activated_snapshot_id, :source_snapshots, type: String, text: true

      constraint(:source_snapshots_cursor_disposition,
        Sequel.lit("cursor_disposition IN ('advance', 'hold')"))
      index %i[run_id source_name account_identity], unique: true
      index %i[source_name account_identity]
    end

    create_table(:source_baselines, strict: true) do
      String :source_name, text: true, null: false
      String :account_identity, text: true, null: false
      foreign_key :activated_snapshot_id, :source_snapshots, type: String, text: true, null: false
      String :activated_at, text: true, null: false
      String :cursor, text: true

      primary_key %i[source_name account_identity]
      index %i[source_name account_identity], unique: true
    end
  end
end
