# frozen_string_literal: true

require "sequel"
require "sequel/extensions/migration"
require_relative "bootstrap/safe_filesystem"

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

    def connect(path:, busy_timeout_ms: BUSY_TIMEOUT_MS, filesystem: Bootstrap::SafeFilesystem.new,
      before_open: nil, before_connect: nil)
      timeout = Integer(busy_timeout_ms)
      raise ArgumentError, "busy timeout must be positive and bounded" unless timeout.positive? && timeout <= 30_000

      database_path = path.to_s
      filesystem.install(path: database_path, bytes: "", mode: 0o600)
      identity = filesystem.regular_file_identity(path: database_path)
      validate_identity!(identity)
      hook = before_open || before_connect
      if hook
        case hook.arity
        when 0 then hook.call
        when 1 then hook.call(database_path)
        else hook.call(database_path, identity)
        end
      end

      db = Sequel.sqlite(
        database_path,
        max_connections: 4,
        after_connect: lambda do |connection|
          ensure_identity!(filesystem, database_path, identity)
          connection.execute("PRAGMA foreign_keys = ON")
          connection.execute("PRAGMA journal_mode = WAL")
          connection.execute("PRAGMA busy_timeout = #{timeout}")
          connection.execute("PRAGMA synchronous = NORMAL")
        end
      )
      db.extend(ConnectionMethods)
      db
    rescue DatabaseError
      raise
    rescue InvalidConfiguration => error
      raise DatabaseError.new(error.code == "config.persistence" ? "database.persistence" : "database.unsafe_path")
    rescue Sequel::Error, SQLite3::Exception => error
      raise error.cause if error.cause.is_a?(DatabaseError)

      raise Cyborg::DatabaseError.new("database.connect", error.message)
    end

    def validate_identity!(identity)
      mode = identity.mode & 0o777
      unless identity.uid == Process.uid && mode == 0o600
        raise DatabaseError.new("database.unsafe_path")
      end
    end

    def ensure_identity!(filesystem, path, expected)
      actual = filesystem.regular_file_identity(path:)
      unless actual.dev == expected.dev && actual.ino == expected.ino && actual.uid == expected.uid &&
          (actual.mode & 0o777) == 0o600
        raise DatabaseError.new("database.unsafe_path")
      end
      true
    rescue InvalidConfiguration
      raise DatabaseError.new("database.unsafe_path")
    end
  end
end
