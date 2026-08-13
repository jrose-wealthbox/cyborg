# frozen_string_literal: true

module Cyborg
  module Commands
    class RecordResult < Base
      def call(argv)
        options = parse_options(argv, required: %w[run lease-file input])
        run_id = options.fetch("run")
        lease_file = options.fetch("lease-file")
        run = run_repository.find(run_id)
        raise InvalidArtifact.new("run.not_found", exit_status: 65) unless run
        store = store_for_lease(lease_file)
        if run.status != "running"
          document = load_document(store:, path: Pathname(options.fetch("input")).expand_path, run_id:)
          input_fingerprint = Bridge::CanonicalJSON.sha256(document)
          return idempotent_result!(store:, run_id:, document:, input_fingerprint:)
        end

        with_mutation_lease(run_id:, lease_file:) do
          run = run_repository.find(run_id)
          raise InvalidArtifact.new("run.not_found", exit_status: 65) unless run
          raise PersistenceError.new("run.not_publishable") unless run.status == "running"

          document = load_document(store:, path: Pathname(options.fetch("input")).expand_path, run_id:)
          packet = analysis_packet(store:, run_id:)
          validated = Analysis::ResultValidator.new.validate(packet:, result: document.fetch("payload"))
          result = Runs::Publisher.new(
            db:, now: container.clock.now, footer: container.config.footer,
            trusted_hosts: trusted_hosts
          ).publish(run:, analysis: validated)
          remember_result(store:, run_id:, document:)
          lease_manager.release_verified!(run_id:, lease_file:)
          stdout.puts safe_json("run_id" => run_id, "status" => result.run.status, "presentation_id" => result.presentation.id,
                                "warnings" => result.warnings)
          0
        end
      end

      private

      def load_document(store:, path:, run_id:)
        # Analysis results are always envelopes; only the payload is passed to
        # the complete validator, preserving the artifact fingerprint check.
        artifact = load_envelope(store:, path:, expected_type: "analysis_result", run_id:)
        {"payload" => artifact, "envelope" => artifact}
      end

      def analysis_packet(store:, run_id:)
        path = store.root.join(run_id, "analysis-packet.json")
        load_envelope(store:, path:, expected_type: "analysis_packet", run_id:)
      end

      def recorded_result_path(store, run_id)
        store.root.join(run_id, "recorded-analysis.sha256.json")
      end

      def same_recorded_result?(store:, run_id:, input_fingerprint:)
        path = recorded_result_path(store, run_id)
        return false unless File.file?(path)

        payload = load_envelope(store:, path:, expected_type: "analysis_result", run_id:)
        payload.fetch("payload_sha256") == input_fingerprint
      rescue JSON::ParserError, KeyError, InvalidArtifact
        false
      end

      def idempotent_result!(store:, run_id:, document:, input_fingerprint:)
        unless same_recorded_result?(store:, run_id:, input_fingerprint:)
          raise InvalidArtifact.new("bridge.changed_response", exit_status: 65)
        end
        Repositories::PresentationRepository.new(db).for_run(run_id: run_id, profile: run_repository.find(run_id).profile).first
        stdout.puts safe_json("run_id" => run_id, "status" => run_repository.find(run_id).status, "presentation" => presentation_path(store:, run_id:))
        0
      end

      def remember_result(store:, run_id:, document:)
        payload = {"payload_sha256" => Bridge::CanonicalJSON.sha256(document)}
        write_envelope(store:, run_id:, filename: "recorded-analysis.sha256.json", type: "analysis_result", payload: payload)
      end

      def presentation_path(store:, run_id:)
        store.root.join(run_id, "presentation.json").to_s
      end
    end
  end
end
