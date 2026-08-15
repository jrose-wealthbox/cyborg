# frozen_string_literal: true

require "json"
require "pathname"
require "time"

module Cyborg
  module Commands
    class Base
      attr_reader :container, :stdout, :stderr

      def initialize(container:, stdout:, stderr:)
        @container = container
        @stdout = stdout
        @stderr = stderr
      end

      private

      def parse_options(argv, required: [], optional: [], flags: [])
        allowed = Array(required) + Array(optional) + Array(flags)
        result = {}
        values = Array(argv).dup
        until values.empty?
          token = values.shift
          unless token.start_with?("--")
            raise UsageError.new("cli.unexpected_argument")
          end

          name = token.delete_prefix("--")
          unless allowed.include?(name)
            raise UsageError.new("cli.unsupported_option")
          end
          raise UsageError.new("cli.duplicate_option") if result.key?(name)
          if flags.include?(name)
            result[name] = true
            next
          end

          value = values.shift
          raise UsageError.new("cli.missing_option_value") if value.nil? || value.start_with?("--")

          result[name] = value
        end
        missing = Array(required).reject { |name| result.key?(name) }
        raise UsageError.new("cli.missing_option") unless missing.empty?

        result
      end

      def db
        container.db
      end

      def run_repository
        @run_repository ||= Repositories::RunRepository.new(db)
      end

      def source_repository
        @source_repository ||= Repositories::SourceRepository.new(db)
      end

      def record_repository
        @record_repository ||= Repositories::RecordRepository.new(db)
      end

      def artifact_store(root = nil)
        Bridge::ArtifactStore.new(root: root || container.paths.artifacts)
      end

      def run_artifact_root(lease_file)
        Pathname(lease_file).expand_path.dirname.dirname
      end

      def store_for_lease(lease_file)
        configured = Pathname(container.paths.artifacts).expand_path
        lease_path = Pathname(lease_file).expand_path
        configured_string = configured.to_s
        root = if lease_path.to_s.start_with?("#{configured_string}#{File::SEPARATOR}")
          configured
        else
          run_artifact_root(lease_path)
        end
        artifact_store(root)
      end

      def lease_manager
        @lease_manager ||= Runs::LeaseManager.new(
          db, clock: container.clock, lease_timeout_seconds: container.config.timeouts.lease_timeout_seconds,
          lock_file: container.paths.lock
        )
      end

      def verify_and_renew!(run_id:, lease_file:)
        lease_manager.renew!(run_id:, lease_file:)
      end

      def with_mutation_lease(run_id:, lease_file:, &block)
        lease_manager.with_verified_lease(run_id:, lease_file:, &block)
      end

      def load_envelope(store:, path:, expected_type:, run_id:)
        store.read(path:, expected_type:, expected_run_id: run_id)
      end

      def write_envelope(store:, run_id:, filename:, type:, payload:, created_at: container.clock.now)
        envelope = Bridge::Envelope.build(type:, run_id:, payload:, created_at:)
        path = store.write(run_id:, filename:, envelope:)
        [path, envelope]
      end

      def output_path(store:, run_id:, requested:, default_filename:)
        filename = requested.nil? ? default_filename : Pathname(requested).basename.to_s
        unless filename.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/)
          raise UnsafeArtifact.new("bridge.unsafe_path", exit_status: 65)
        end
        target = store.root.join(run_id, filename).expand_path
        requested_path = requested && Pathname(requested).expand_path
        if requested_path && requested_path != target
          raise UnsafeArtifact.new("bridge.unsafe_path", exit_status: 65)
        end
        target
      end

      def normalize(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, item), result| result[key.to_s] = normalize(item) }
        when Array then value.map { |item| normalize(item) }
        when Time then value.utc.iso8601
        when Data then value.to_h.each_with_object({}) { |(key, item), result| result[key.to_s] = normalize(item) }
        else value
        end
      end

      def profile_window(profile_name)
        BusinessCalendar.new(config: container.config).window(now: container.clock.now, profile: profile_name)
      end

      def registrations
        SourceRegistry.enabled(container.config.source_options)
      end

      def registration_for(source_name, account_identity = nil)
        registration = registrations.find do |value|
          value.source_name == source_name.to_s && (account_identity.nil? || value.account_identity.to_s == account_identity.to_s)
        end
        raise InvalidArtifact.new("source.unknown_registration", exit_status: 65) unless registration

        registration
      end

      def retrieval_context(run:, registration:, window: nil)
        baseline = source_repository.baseline_for(registration.source_name, registration.account_identity)
        profile = window || profile_window(run.profile)
        RetrievalContext.new(
          source_name: registration.source_name, account_identity: registration.account_identity,
          window_start_utc: profile.start_utc.iso8601, window_end_utc: profile.end_utc.iso8601,
          display_timezone: profile.timezone, prior_cursor: baseline&.fetch(:cursor), limits: registration.limits,
          cache_policy: registration.cache_policy, filters: registration.filters, capabilities: registration.capabilities
        )
      end

      def adapter_for(registration)
        source = container.config.sources.fetch(registration.source_name)
        raw = container.config.source_options(registration.source_name)
        case source.adapter
        when "github"
          GithubAdapter.new(
            hostname: raw["hostname"] || raw["host"] || GithubAdapter::DEFAULT_HOSTNAME,
            repository_allowlist: raw["repositories"] || [], organization_allowlist: raw["organizations"] || [],
            account_identity: registration.account_identity, adapter_version: registration.adapter_version,
            limits: registration.limits
          )
        when "local_git", "git"
          LocalGitAdapter.new(
            repositories: raw["repositories"] || source.repositories, author_emails: Array(raw.dig("filters", "author_emails")),
            signing_identities: Array(raw.dig("filters", "signing_identities")), account_identity: registration.account_identity,
            adapter_version: registration.adapter_version, max_records: registration.max_records || LocalGitAdapter::DEFAULT_MAX_RECORDS,
            max_response_bytes: registration.max_response_bytes || LocalGitAdapter::DEFAULT_MAX_RESPONSE_BYTES,
            timeout: registration.limits["max_seconds"] || LocalGitAdapter::DEFAULT_TIMEOUT
          )
        when "fixture"
          fixture_path = raw["path"] || raw["fixture_path"] || FixtureAdapter::DEFAULT_PATH
          fixture_path = File.join(Dir.home, fixture_path.delete_prefix("~/")) if fixture_path.to_s.start_with?("~/")
          FixtureAdapter.new(
            path: fixture_path,
            source_name: registration.source_name, account_identity: registration.account_identity,
            adapter_version: registration.adapter_version
          )
        else
          raise InvalidConfiguration.new("config.unsupported_source_adapter")
        end
      end

      def failed_retrieval_result(registration, context, code, remediation = "retry the source")
        RetrievalResult.new(
          source_name: registration.source_name, account_identity: registration.account_identity,
          status: "failed", data_status: "none", cache_reason: nil,
          started_at: context.window_start_utc, completed_at: context.window_end_utc, records: [], next_cursor: nil,
          error: RetrievalError.new(code: code, remediation: remediation)
        )
      end

      def record_payload(record)
        value = normalize(record)
        value["evidence"] = db[:observed_record_versions].join(:evidence, observed_record_version_id: :id)
          .where(observed_record_id: value.fetch("id")).all.map { |row| normalize(row) }
        value
      end

      def records_for_run(run_id)
        source_repository.snapshots_for_run(run_id).flat_map do |snapshot|
          record_repository.records_for_snapshot(snapshot.id).map { |record| record_payload(record) }
        end
      end

      def actions_for_packet
        db[:inferred_actions].join(:action_series, id: :series_id).select_all(:inferred_actions)
          .select_append(Sequel[:action_series][:current_subject_key]).all.map do |row|
          normalize(row)
        end
      end

      def analysis_tasks
        configured = container.config.to_h.dig("analysis", "tasks") || container.config.to_h["tasks"] || []
        pairs = configured.is_a?(Hash) ? configured.map { |id, value| [id.to_s, value] } : Array(configured).map { |value| [value["id"], value] }
        pairs.filter_map do |id, raw|
          next unless raw.is_a?(Hash) && id && raw["capability"]
          reservation = raw["reservation"] || {"cost_micros" => raw["reservation_micros"] || raw["budget_micros"] || 0}
          reservation = Analysis::Reservation.new(**normalize(reservation).transform_keys(&:to_sym))
          Analysis::AnalysisTask.new(
            id:, capability: raw["capability"], dependency_ids: Array(raw["dependency_ids"]),
            required: raw.fetch("required", false), packet_fingerprint: raw["packet_fingerprint"] || Bridge::CanonicalJSON.sha256(raw),
            maximum_output_bytes: raw["maximum_output_bytes"] || 8_192, reservation:
          )
        end
      rescue ArgumentError => error
        raise InvalidConfiguration.new("config.invalid_analysis_tasks", error.message)
      end

      def reservation_payload(plan)
        {
          "ceiling_micros" => plan.ceiling_micros, "reserved_micros" => plan.reserved_micros,
          "reported_micros" => plan.reported_micros, "released_micros" => plan.released_micros,
          "remaining_micros" => plan.remaining_micros,
          "warnings" => plan.warnings,
          "entries" => plan.entries.transform_values { |entry| normalize(entry) }
        }
      end

      def trusted_hosts
        sources = container.config.source_options
        sources.filter_map do |name, source|
          next unless source.is_a?(Hash)
          source["hostname"] || source["host"] || (name.to_s == "github" ? GithubAdapter::DEFAULT_HOSTNAME : nil)
        end
      end

      def tasks_and_reservation
        tasks = analysis_tasks
        plan = Analysis::BudgetController.new.reserve(tasks:, ceiling_micros: container.config.budget.ceiling_micros)
        [tasks, reservation_payload(plan)]
      end

      def safe_json(value)
        Bridge::CanonicalJSON.dump(value)
      end

      def analysis_backend_identity
        container.config.to_h.dig("analysis", "backend_identity") || Config::DEFAULT_BACKEND_IDENTITY
      end

      def bridge_cache
        @bridge_cache ||= Analysis::BridgeCache.new(
          db:, expensive_ttl_seconds: container.config.cache.expensive_ttl_seconds
        )
      end
    end
  end
end
