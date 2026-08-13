# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"
require "securerandom"
require "time"
require_relative "../clock"
require_relative "../domain"
require_relative "../errors"
require_relative "../repositories/base"

module Cyborg
  # The opaque lease handle deliberately does not expose the lease token.  A
  # token is held only by the protected file returned to the host workflow;
  # the database stores its SHA-256 fingerprint.
  class Lease
    attr_reader :run_id, :lease_file, :created_at, :heartbeat_at, :expires_at

    def initialize(run_id, lease_file, expires_at, heartbeat_at: nil, created_at: nil)
      @run_id = run_id.to_s.freeze
      @lease_file = Pathname(lease_file).expand_path.freeze
      @created_at = created_at
      @heartbeat_at = heartbeat_at
      @expires_at = expires_at
      freeze
    end
  end

  module Runs
    # Coordinates the durable singleton lease and its protected token file.
    # Every state mutation takes the short OS lock before entering an
    # IMMEDIATE SQLite transaction.  SQLite remains the authority if a caller
    # bypasses the lock (for example, after a process crash).
    class LeaseManager
      DEFAULT_LEASE_TIMEOUT_SECONDS = 600
      TOKEN_BYTES = 32
      TOKEN_PATTERN = /\A[0-9a-f]{64}\z/.freeze
      TOKEN_FILE_MODE = 0o600
      CANONICAL_UTC_TIMESTAMP = Repositories::Base::CANONICAL_UTC_TIMESTAMP

      attr_reader :db, :clock, :lease_timeout_seconds, :lock_file

      def initialize(database = nil, db: nil, clock: Clock.new,
                      lease_timeout_seconds: DEFAULT_LEASE_TIMEOUT_SECONDS,
                      lease_timeout: nil, timeout_seconds: nil,
                      lock_file: nil, lock_path: nil, **options)
        database ||= options.delete(:database)
        raise ArgumentError, "unknown options: #{options.keys.join(", ")}" unless options.empty?
        @db = database || db
        raise ArgumentError, "database is required" unless @db

        @clock = clock
        timeout = lease_timeout || timeout_seconds || lease_timeout_seconds
        @lease_timeout_seconds = Integer(timeout)
        raise ArgumentError, "lease timeout must be positive" unless @lease_timeout_seconds.positive?

        database_path = @db.opts[:database]
        lock_path = lock_file || lock_path || (database_path && "#{database_path}.lock")
        raise ArgumentError, "lock_file is required when database has no path" unless lock_path

        @lock_file = Pathname(lock_path).expand_path.freeze
        @known_lease_files = {}
        ensure_lock_parent!
      end

      def acquire(run_id:, lease_file:)
        run_id = run_id.to_s
        path = normalize_lease_file(lease_file)
        token = SecureRandom.hex(TOKEN_BYTES)
        now = canonical_time(@clock.now)
        created_at = now.utc.iso8601
        expires_at = (now + @lease_timeout_seconds).utc.iso8601
        fingerprint = Digest::SHA256.hexdigest(token)
        inserted = false

        with_os_lock do
          begin
            @db.transaction(mode: :immediate) do
              row = @db[:run_leases].first
              if row
                if lease_active?(row, now)
                  raise Cyborg::LeaseBusy.new("run.lease_busy", "an active briefing run already owns the lease")
                end

                fail_expired_row!(row, now)
              end

              # The foreign key deliberately verifies that callers cannot
              # mint a lease for a run which was not persisted first.
              @db[:run_leases].insert(
                id: 1, run_id:, token_fingerprint: fingerprint,
                created_at:, heartbeat_at: created_at, expires_at:
              )
              inserted = true
            end

            write_token_exclusively(path, token)
            @known_lease_files[run_id] = path
          rescue Exception
            # A committed DB lease without its token file is unusable.  Keep
            # the singleton available if filesystem creation fails.
            remove_inserted_lease(run_id, fingerprint) if inserted
            raise
          end
        end

        Lease.new(run_id, path, Time.iso8601(expires_at), heartbeat_at: now, created_at: now)
      end

      def verify!(run_id:, lease_file:)
        with_verified_lease(run_id:, lease_file:) { |lease| lease }
      end

      # Runs a lease-owned mutation while retaining the OS lock used to verify
      # the token.  This prevents a verify-then-mutate race where a different
      # owner could release and reacquire the singleton between two calls.
      def with_verified_lease(run_id:, lease_file:)
        run_id = run_id.to_s
        path = normalize_lease_file(lease_file)
        fingerprint = token_fingerprint(path)
        now = canonical_time(@clock.now)

        with_os_lock do
          row = @db[:run_leases].first
          unless row && row[:run_id].to_s == run_id && secure_equal?(row[:token_fingerprint].to_s, fingerprint)
            raise invalid_lease("run.invalid_lease")
          end

          unless lease_active?(row, now)
            @db.transaction(mode: :immediate) { fail_expired_row!(@db[:run_leases].first, now) }
            raise invalid_lease("run.lease_expired")
          end

          @known_lease_files[run_id] = path
          yield lease_from_row(row, path)
        end
      end

      def renew!(run_id:, lease_file:)
        run_id = run_id.to_s
        path = normalize_lease_file(lease_file)
        fingerprint = token_fingerprint(path)
        now = canonical_time(@clock.now)
        heartbeat_at = now.utc.iso8601
        expires_at = (now + @lease_timeout_seconds).utc.iso8601

        with_os_lock do
          result = @db.transaction(mode: :immediate) do
            row = @db[:run_leases].first
            unless row && row[:run_id].to_s == run_id && secure_equal?(row[:token_fingerprint].to_s, fingerprint)
              raise invalid_lease("run.invalid_lease")
            end
            unless lease_active?(row, now)
              fail_expired_row!(row, now)
              raise invalid_lease("run.lease_expired")
            end

            @db[:run_leases].where(id: 1).update(heartbeat_at:, expires_at:)
            @db[:run_leases].first
          end
          @known_lease_files[run_id] = path
          lease_from_row(result, path)
        end
      end

      def release!(run_id:, lease_file:)
        run_id = run_id.to_s
        path = normalize_lease_file(lease_file)
        fingerprint = token_fingerprint(path)
        now = canonical_time(@clock.now)
        removed = false

        with_os_lock do
          @db.transaction(mode: :immediate) do
            row = @db[:run_leases].first
            unless row && row[:run_id].to_s == run_id && secure_equal?(row[:token_fingerprint].to_s, fingerprint)
              raise invalid_lease("run.invalid_lease")
            end
            if lease_active?(row, now)
              @db[:run_leases].where(id: 1).delete
              removed = true
            else
              fail_expired_row!(row, now)
              raise invalid_lease("run.lease_expired")
            end
          end

          delete_token_file(path) if removed
          @known_lease_files.delete(run_id)
        end
        removed
      end

      # Reclaims an expired singleton lease.  The old run is failed before the
      # row is removed, so a later acquire can never silently reuse it.
      def fail_expired_lease!
        now = canonical_time(@clock.now)
        with_os_lock do
          run = @db.transaction(mode: :immediate) do
            row = @db[:run_leases].first
            if row && !lease_active?(row, now)
              fail_expired_row!(row, now)
              @db[:runs].where(id: row[:run_id]).first
            end
          end
          delete_token_file(@known_lease_files.delete(run&.fetch(:id, nil))) if run
          run && Domain.from_row(Run, run)
        end
      end

      # Exposed for orchestration services that need one atomic DB mutation
      # alongside lease ownership.  It intentionally carries no token data.
      def with_lock(&block)
        with_os_lock(&block)
      end

      private

      def canonical_time(value)
        time = case value
               when Time then value
               when String then Time.iso8601(value)
               else raise ArgumentError, "clock must return Time"
               end
        time.utc
      rescue ArgumentError
        raise Cyborg::PersistenceError.new("database.invalid_timestamp")
      end

      def normalize_lease_file(value)
        raise ArgumentError, "lease_file is required" if value.nil?

        path = Pathname(value).expand_path
        ensure_lease_parent!(path)
        path
      end

      def ensure_lock_parent!
        ensure_directory(@lock_file.dirname)
      end

      def ensure_lease_parent!(path)
        ensure_directory(path.dirname)
      end

      def ensure_directory(path)
        begin
          stat = path.lstat
          raise Cyborg::UnsafeArtifact.new("bridge.unsafe_file", exit_status: 65) if stat.symlink? || !stat.directory?
          File.chmod(0o700, path.to_s)
        rescue Errno::ENOENT
          FileUtils.mkdir_p(path.to_s)
          File.chmod(0o700, path.to_s)
        end
      end

      def with_os_lock
        File.open(@lock_file.to_s, File::RDWR | File::CREAT, TOKEN_FILE_MODE) do |lock|
          File.chmod(TOKEN_FILE_MODE, @lock_file.to_s)
          lock.flock(File::LOCK_EX)
          begin
            yield
          ensure
            lock.flock(File::LOCK_UN)
          end
        end
      rescue Errno::EACCES, Errno::EAGAIN
          raise Cyborg::PersistenceError.new("run.lock_unavailable")
      end

      def lease_active?(row, now)
        expires_at = parse_canonical_timestamp(row.fetch(:expires_at), field: :expires_at)
        expires_at > now
      end

      def parse_canonical_timestamp(value, field:)
        unless value.is_a?(String) && CANONICAL_UTC_TIMESTAMP.match?(value)
          raise Cyborg::PersistenceError.new("database.invalid_timestamp", "#{field} must be a canonical UTC RFC3339 timestamp")
        end

        parsed = Time.iso8601(value)
        raise Cyborg::PersistenceError.new("database.invalid_timestamp") unless parsed.utc.iso8601 == value

        parsed
      rescue ArgumentError
        raise Cyborg::PersistenceError.new("database.invalid_timestamp")
      end

      def lease_from_row(row, path)
        Lease.new(
          row.fetch(:run_id), path,
          parse_canonical_timestamp(row.fetch(:expires_at), field: :expires_at),
          heartbeat_at: parse_canonical_timestamp(row.fetch(:heartbeat_at), field: :heartbeat_at),
          created_at: parse_canonical_timestamp(row.fetch(:created_at), field: :created_at)
        )
      end

      def fail_expired_row!(row, now)
        return unless row

        completed_at = now.utc.iso8601
        @db[:runs].where(id: row.fetch(:run_id)).update(
          status: "failed", completed_at:,
          usage_summary_json: JSON.generate("error_code" => "run.lease_expired")
        )
        @db[:run_leases].where(id: row.fetch(:id)).delete
        delete_token_file(@known_lease_files.delete(row.fetch(:run_id)))
      end

      def remove_inserted_lease(run_id, fingerprint)
        with_os_lock do
          @db.transaction(mode: :immediate) do
            row = @db[:run_leases].first
            if row && row[:run_id].to_s == run_id && row[:token_fingerprint].to_s == fingerprint
              @db[:run_leases].where(id: row[:id]).delete
            end
          end
        end
      rescue StandardError
        # Preserve the original filesystem exception.  A subsequent command
        # can still reclaim the expired/failed row safely.
        nil
      end

      def write_token_exclusively(path, token)
        stat = begin
          path.lstat
        rescue Errno::ENOENT
          nil
        end
        if stat && (stat.symlink? || !stat.file?)
          raise Cyborg::UnsafeArtifact.new("bridge.unsafe_file", exit_status: 65)
        end

        File.open(path.to_s, File::WRONLY | File::CREAT | File::EXCL, TOKEN_FILE_MODE) do |file|
          file.binmode
          file.write(token)
          file.write("\n")
          file.flush
          file.fsync
        end
        File.chmod(TOKEN_FILE_MODE, path.to_s)
      rescue Errno::EEXIST
        raise Cyborg::UnsafeArtifact.new("bridge.unsafe_file", "lease file already exists", exit_status: 65)
      rescue Errno::ELOOP, Errno::ENOTDIR, Errno::EISDIR
        raise Cyborg::UnsafeArtifact.new("bridge.unsafe_file", exit_status: 65)
      end

      def token_fingerprint(path)
        flags = File::RDONLY | File::NOFOLLOW
        File.open(path.to_s, flags) do |file|
          stat = file.stat
          unless stat.file? && (stat.mode & 0o777) == TOKEN_FILE_MODE
            raise invalid_lease("run.unsafe_lease_file")
          end
          if stat.size > TOKEN_BYTES * 2 + 1
            raise invalid_lease("run.invalid_lease")
          end

          token = file.read(TOKEN_BYTES * 2 + 2).to_s
          token = token.delete_suffix("\n")
          unless TOKEN_PATTERN.match?(token)
            raise invalid_lease("run.invalid_lease")
          end
          Digest::SHA256.hexdigest(token)
        end
      rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR, Errno::EISDIR
        raise invalid_lease("run.invalid_lease")
      end

      def delete_token_file(path)
        return unless path

        path = Pathname(path)
        begin
          stat = path.lstat
          return if stat.directory?

          File.delete(path.to_s)
        rescue Errno::ENOENT
          nil
        end
      end

      def secure_equal?(left, right)
        return false unless left.bytesize == right.bytesize

        result = 0
        left.bytes.zip(right.bytes) { |a, b| result |= (a ^ b) }
        result.zero?
      end

      def invalid_lease(code)
        Cyborg::InvalidArtifact.new(code, code, exit_status: 65)
      end
    end
  end

  LeaseManager = Runs::LeaseManager
end
