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
          cached_payload = bridge_cache.fetch(
            packet:, backend_identity: analysis_backend_identity, now: container.clock.now
          )
          cached = cached_payload && equivalent_cached_result?(cached_payload, document.fetch("payload"))
          publication_analysis = cached ? analysis_without_provider_cost(validated, run_id:) : validated
          result = nil
          db.transaction(mode: :immediate) do
            result = Runs::Publisher.new(
              db:, now: container.clock.now, footer: container.config.footer,
              trusted_hosts: trusted_hosts
            ).publish(run:, analysis: publication_analysis)
            if cacheable_result?(validated, result) && !cached
              bridge_cache.store(
                packet:, result: document.fetch("payload"), backend_identity: analysis_backend_identity,
                run_id:, now: container.clock.now
              )
            end
          end
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
        repair_bridge_cache!(store:, run_id:, document:)
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

      def cacheable_result?(validated, published)
        return false if validated.respond_to?(:accepted?) && !validated.accepted?

        published.run.status == "completed"
      end

      def analysis_without_provider_cost(validated, run_id:)
        return validated if validated.respond_to?(:accepted?) && !validated.accepted?

        Analysis::AnalysisOutcome.new(
          claims: validated.claims, usage: locally_estimated_usage(validated.usage, run_id:),
          backend_metadata: validated.backend_metadata
        )
      end

      def locally_estimated_usage(usage, run_id:)
        return {} unless usage.is_a?(Hash) && usage.any?

        value = JSON.parse(JSON.generate(usage))
        records = Array(value["records"])
        return value if records.empty?

        value["certainty"] = "locally_estimated"
        value["run_id"] = run_id if value.key?("run_id")
        value["records"] = records.map do |record|
          record = record.merge("certainty" => "locally_estimated", "run_id" => run_id)
          record["id"] = "cached-#{run_id}-#{record.fetch("id")}" if record["id"]
          record["session_id"] = "cached-#{run_id}-#{record.fetch("session_id")}" if record["session_id"]
          record["parent_session_id"] = nil if record.key?("parent_session_id")
          record
        end
        value
      end

      def equivalent_cached_result?(cached, submitted)
        normalize_cached_result(cached) == normalize_cached_result(submitted)
      end

      def normalize_cached_result(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, item), result|
            name = key.to_s
            result[name] = if name == "run_id"
              "<run>"
            else
              normalize_cached_result(item)
            end
          end
        when Array
          value.map { |item| normalize_cached_result(item) }
        else
          value
        end
      end

      def repair_bridge_cache!(store:, run_id:, document:)
        run = run_repository.find(run_id)
        return unless run&.status == "completed"

        packet = analysis_packet(store:, run_id:)
        return if bridge_cache.fetch(packet:, backend_identity: analysis_backend_identity, now: container.clock.now)
        return if bridge_cache.entry_present?(packet:, backend_identity: analysis_backend_identity)

        validated = Analysis::ResultValidator.new.validate(packet:, result: document.fetch("payload"))
        return if validated.respond_to?(:accepted?) && !validated.accepted?

        bridge_cache.store(
          packet:, result: document.fetch("payload"), backend_identity: analysis_backend_identity,
          run_id:, now: container.clock.now
        )
      rescue Cyborg::Error, KeyError, JSON::ParserError
        nil
      end

    end
  end
end
