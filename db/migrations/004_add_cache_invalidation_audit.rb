# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:cache_entries) do
      add_column :invalidation_command, String, text: true
      add_foreign_key :invalidation_run_id, :runs, type: String, text: true
    end
  end
end
