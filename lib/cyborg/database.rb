# frozen_string_literal: true

require "sequel"
require "sequel/extensions/migration"

module Cyborg
  module Database
    BUSY_TIMEOUT_MS = 5_000
    MIGRATIONS_PATH = File.expand_path("../../db/migrations", __dir__).freeze

    module ConnectionMethods
      def get(expression)
        if expression.is_a?(Sequel::LiteralString) && expression.to_s.start_with?("PRAGMA ")
          fetch(expression).single_value
        else
          super
        end
      end

      def migrate!(path: Cyborg::Database::MIGRATIONS_PATH)
        Sequel::Migrator.run(self, path)
        true
      end

      def transaction(mode: nil, **options, &block)
        options = options.dup
        options[:mode] = mode unless mode.nil?
        super(options, &block)
      end
    end

    module_function

    def strict_tables_supported?(version)
      numbers = version.to_s.split(".").first(3).map(&:to_i)
      (numbers <=> [3, 37, 0]) >= 0
    end

    def strict_table_options(db)
      strict_tables_supported?(db.fetch(Sequel.lit("SELECT sqlite_version() AS version")).get(:version)) ? {strict: true} : {}
    end

    def connect(path:, busy_timeout_ms: BUSY_TIMEOUT_MS)
      timeout = Integer(busy_timeout_ms)
      raise ArgumentError, "busy timeout must be positive and bounded" unless timeout.positive? && timeout <= 30_000

      db = Sequel.sqlite(
        path,
        max_connections: 4,
        after_connect: lambda do |connection|
          connection.execute("PRAGMA foreign_keys = ON")
          connection.execute("PRAGMA journal_mode = WAL")
          connection.execute("PRAGMA busy_timeout = #{timeout}")
          connection.execute("PRAGMA synchronous = NORMAL")
        end
      )
      db.extend(ConnectionMethods)
      db
    rescue Sequel::Error, SQLite3::Exception => error
      raise Cyborg::DatabaseError.new("database.connect", error.message)
    end
  end
end
