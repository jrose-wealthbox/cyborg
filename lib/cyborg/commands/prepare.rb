# frozen_string_literal: true

require "securerandom"

module Cyborg
  module Commands
    class Prepare < Base
      def call(argv)
        options = parse_options(argv, required: %w[profile artifact-dir])
        profile = options.fetch("profile")
        artifact_root = Pathname(options.fetch("artifact-dir")).expand_path
        store = artifact_store(artifact_root)
        run_id = SecureRandom.uuid
        lease_path = store.root.join(run_id, "lease.token")
        lifecycle = Runs::RunLifecycle.new(
          db, clock: container.clock, lease_timeout_seconds: container.config.timeouts.lease_timeout_seconds,
          lease_file: lease_path, lock_file: container.paths.lock
        )
        window = profile_window(profile)
        run = lifecycle.start(
          profile:, execution_mode: "host", window:,
          configuration_fingerprint: container.config.fingerprint,
          prompt_version: container.config.to_h.dig("analysis", "prompt_version") || "prompt-1",
          backend_capability: container.config.to_h.dig("analysis", "backend") || "host", run_id:
        )
        requests = prepare_direct_sources(run:, window:)
        request_payload = requests.map { |request| normalize(request) }
        request_path, = write_envelope(
          store:, run_id: run.id, filename: "retrieval-requests.json", type: "retrieval_requests",
          payload: request_payload
        )
        # Keep the returned lease path truthful: RunLifecycle owns the token at
        # its configured path, which is the provisional path above.
        stdout.puts safe_json(
          "run_id" => run.id, "status" => run.status, "retrieval_requests" => request_path.to_s,
          "retrieval_requests_path" => request_path.to_s, "lease_file" => lease_path.to_s
        )
        0
      end

      private

      def prepare_direct_sources(run:, window:)
        requests = []
        registrations.each do |registration|
          context = retrieval_context(run:, registration:, window:)
          if registration.transport.to_s == "host_bridge"
            requests.concat(HostRequestBuilder.new.call(run:, registrations: [registration], context:))
            next
          end

          result = begin
            adapter_for(registration).fetch(context)
          rescue Cyborg::Error => error
            failed_retrieval_result(registration, context, error.code, "retry the source")
          rescue StandardError
            failed_retrieval_result(registration, context, "source.unavailable", "retry the source")
          end
          SourceIngestor.new(db:).ingest(run:, registration:, result:)
        end
        requests
      end
    end
  end
end
