# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:source_snapshot_requests, **Cyborg::Database.strict_table_options(self)) do
      foreign_key :snapshot_id, :source_snapshots, type: String, text: true, null: false
      foreign_key :run_id, :runs, type: String, text: true, null: false
      String :source_name, text: true, null: false
      String :account_identity, text: true, null: false
      String :request_id, text: true, null: false
      String :response_payload_sha256, text: true, null: false
      String :ingested_at, text: true, null: false

      primary_key %i[snapshot_id request_id]
      index %i[run_id source_name account_identity request_id]
      index :request_id
    end
  end
end
