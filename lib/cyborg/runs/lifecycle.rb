# frozen_string_literal: true

require "json"
require "securerandom"
require "time"
require "pathname"
require_relative "../clock"
require_relative "../domain"
require_relative "../errors"
require_relative "../redactor"
require_relative "../repositories/run_repository"
require_relative "lease_manager"

module Cyborg
  module Runs
    # Owns the persisted run row around the multi-command host workflow.  The
    # lease manager remains the sole authority for token verification; this
    # service never publishes a view or activates a source cursor.
    class RunLifecycle
      DEFAULT_LEASE_TIMEOUT_SECONDS = LeaseManager::DEFAULT_LEASE_TIMEOUT_SECONDS

      attr_reader :db, :lease_manager, :lease_file

      def initialize(database = nil, db: nil, clock: Clock.new,
                     lease_manager: nil, lease_file: nil,
                     lease_timeout_seconds: DEFAULT_LEASE_TIMEOUT_SECONDS,
                     lease_timeout: nil, timeout_seconds: nil,
                     lock_file: nil, lock_path: nil, **options)
        database ||= options.delete(:database)
        raise ArgumentError, "unknown options: #{options.keys.join(", ")}" unless options.empty?
        @db = database || db
        raise ArgumentError, "database is required" unless @db

        @lease_file = Pathname(lease_file || default_lease_file).expand_path
        @lease_manager = lease_manager || LeaseManager.new(
          @db,
          clock:,
          lease_timeout_seconds:,
          lease_timeout:,
          timeout_seconds:,
          lock_file: lock_file,
          lock_path:
        )
        @runs = Repositories::RunRepository.new(@db)
        @clock = clock
      end

      def start(profile:, execution_mode:, window:, configuration_fingerprint:,
                prompt_version: nil, backend_capability: nil)
        now = canonical_time(@clock.now)
        run_id = SecureRandom.uuid
        prior_renderable_run_id = @runs.latest_renderable_id
        attributes = {
          id: run_id,
          profile: profile_name(profile),
          execution_mode: execution_mode.to_s,
          status: "running",
          window_start_utc: canonical_timestamp(window_value(window, :start_utc)),
          window_end_utc: canonical_timestamp(window_value(window, :end_utc)),
          display_timezone: window_value(window, :timezone).to_s,
          configuration_fingerprint: configuration_fingerprint.to_s,
          created_at: now.utc.iso8601,
          prior_renderable_run_id: prior_renderable_run_id,
          captured_action_state_version: 0,
          prompt_version: prompt_version,
          backend_capability: backend_capability
        }
        attributes.delete(:prior_renderable_run_id) if prior_renderable_run_id.nil?
        attributes.delete(:prompt_version) if prompt_version.nil?
        attributes.delete(:backend_capability) if backend_capability.nil?

        # The lease FK requires a run row before acquisition.  If another
        # process already owns the singleton lease, remove this unleased
        # candidate so failed starts do not accumulate visible runs.
        @runs.create(attributes)
        begin
          @lease_manager.acquire(run_id:, lease_file: @lease_file)
        rescue Exception
          @db.transaction(mode: :immediate) { @db[:runs].where(id: run_id).delete }
          raise
        end
        @runs.find(run_id)
      end

      def abandon(run_id:, reason:)
        run_id = run_id.to_s
        run = @runs.find(run_id)
        raise Cyborg::PersistenceError.new("run.not_found") unless run

        metadata = {
          "error_code" => "run.abandoned",
          "reason" => safe_reason(reason)
        }
        completed_at = canonical_time(@clock.now).utc.iso8601

        # Keep the status change and lease release in one immediate DB
        # transaction.  The token file is removed immediately afterward; it is
        # never needed to determine ownership once the DB row is gone.
        @lease_manager.with_verified_lease(run_id:, lease_file: @lease_file) do
          @db.transaction(mode: :immediate) do
            row = @db[:run_leases].first
            raise Cyborg::InvalidArtifact.new("run.invalid_lease", exit_status: 65) unless row && row[:run_id].to_s == run_id

            @db[:runs].where(id: run_id).update(
              status: "failed", completed_at:, usage_summary_json: JSON.generate(metadata)
            )
            @db[:run_leases].where(id: row[:id]).delete
          end

          remove_lease_file
        end
        @runs.find(run_id)
      end

      def fail_expired_lease!
        @lease_manager.fail_expired_lease!
      end

      private

      def default_lease_file
        database_path = @db.opts[:database]
        return "#{database_path}.lease" if database_path

        File.join(Dir.tmpdir, "cyborg-run.lease")
      end

      def profile_name(profile)
        profile.respond_to?(:name) ? profile.name.to_s : profile.to_s
      end

      def window_value(window, field)
        value = if window.respond_to?(field)
          window.public_send(field)
        elsif window.is_a?(Hash)
          window[field] || window[field.to_s]
        end
        raise ArgumentError, "window must provide #{field}" if value.nil?

        value
      end

      def canonical_time(value)
        time = case value
               when Time then value
               when String then Time.iso8601(value)
               else raise ArgumentError, "timestamp must be Time or RFC3339 text"
               end
        time.utc
      rescue ArgumentError
        raise Cyborg::PersistenceError.new("database.invalid_timestamp")
      end

      def canonical_timestamp(value)
        time = canonical_time(value)
        timestamp = time.utc.iso8601
        unless Repositories::Base::CANONICAL_UTC_TIMESTAMP.match?(timestamp)
          raise Cyborg::PersistenceError.new("database.invalid_timestamp")
        end
        timestamp
      end

      def safe_reason(reason)
        # Reasons are diagnostics, not a second secret channel.  Redact token
        # shaped values and cap the persisted string to a bounded size.
        value = Redactor.new.call(reason.to_s)
        value = value.gsub(/\b[0-9a-f]{64}\b/i, Redactor::REDACTION)
        value.byteslice(0, 512).to_s
      end

      def remove_lease_file
        path = @lease_file
        begin
          stat = path.lstat
          File.delete(path.to_s) unless stat.directory?
        rescue Errno::ENOENT
          nil
        end
      end
    end
  end

  RunLifecycle = Runs::RunLifecycle
end
