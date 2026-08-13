# frozen_string_literal: true

require_relative "../test_helper"

class CyborgMigrationTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("cyborg-migration-test")
    @db = Cyborg::Database.connect(path: File.join(@tmpdir, "cyborg.sqlite3"))
  end

  def teardown
    @db.disconnect
    FileUtils.remove_entry(@tmpdir)
  end

  def test_migrations_are_idempotent
    assert_equal true, @db.migrate!
    first_tables = @db.tables.sort
    assert_equal true, @db.migrate!
    assert_equal first_tables, @db.tables.sort
    assert_equal [5], @db[:schema_info].select_map(:version)
  end

  def test_immediate_transaction_returns_block_value_and_rolls_back_on_error
    @db.migrate!
    result = @db.transaction(mode: :immediate) do |connection|
      refute_nil connection
      @db[:application_state].insert(key: "example", value: "value", updated_at: "2026-08-12T00:00:00Z")
      :committed
    end
    assert_equal :committed, result
    assert_equal "value", @db[:application_state].get(:value)

    assert_raises(RuntimeError) do
      @db.transaction(mode: :immediate) do
        @db[:application_state].update(value: "rolled-back", updated_at: "2026-08-12T00:00:00Z")
        raise "rollback"
      end
    end
    assert_equal "value", @db[:application_state].get(:value)
  end

  def test_strict_table_options_follow_sqlite_capability
    assert_equal true, Cyborg::Database.strict_tables_supported?("3.53.2")
    assert_equal false, Cyborg::Database.strict_tables_supported?("3.36.0")
    assert_equal({strict: true}, Cyborg::Database.strict_table_options(@db))
  end
end
