# frozen_string_literal: true

module Cyborg
  module Commands
    class AnalysisPacket < Base
      def call(argv)
        options = parse_options(argv, required: %w[run lease-file], optional: %w[output])
        run_id = options.fetch("run")
        lease_file = options.fetch("lease-file")
        verify_and_renew!(run_id:, lease_file:)
        run = run_repository.find(run_id)
        raise InvalidArtifact.new("run.not_found", exit_status: 65) unless run
        store = store_for_lease(lease_file)
        required_response_check(store:, run_id:)
        capture_action_state!(run_id)
        run = run_repository.find(run_id)
        tasks, reservation = tasks_and_reservation
        records = filtered_records(run)
        packet = Pipeline::AnalysisPacketBuilder.new(
          trusted_hosts:, prompt_version: run.prompt_version || "prompt-1",
          maximum_claim_count: config_limit("maximum_claim_count", 25),
          maximum_output_bytes: config_limit("maximum_output_bytes", 8_192),
          maximum_bytes: config_limit("maximum_bytes", 262_144)
        ).call(run:, records:, actions: actions_for_packet, tasks:, reservation:)
        path = output_path(store:, run_id:, requested: options["output"], default_filename: "analysis-packet.json")
        write_envelope(store:, run_id:, filename: path.basename.to_s, type: "analysis_packet", payload: packet)
        stdout.puts safe_json("run_id" => run_id, "status" => run_repository.find(run_id).status, "output" => path.to_s)
        0
      end

      private

      def required_response_check(store:, run_id:)
        requests = retrieval_requests(store:, run_id:)
        requests.each do |request|
          next unless request["required"] == true

          filename = "retrieval-response-#{request.fetch("id")}.json"
          path = store.root.join(run_id, filename)
          unless File.file?(path)
            raise UsageError.new("bridge.required_response_missing")
          end
        end
      end

      def retrieval_requests(store:, run_id:)
        path = store.root.join(run_id, "retrieval-requests.json")
        payload = load_envelope(store:, path:, expected_type: "retrieval_requests", run_id:)
        raise InvalidArtifact.new("bridge.invalid_requests", exit_status: 65) unless payload.is_a?(Array)

        payload.map { |value| normalize(value) }
      end

      def filtered_records(run)
        source_repository.snapshots_for_run(run.id).flat_map do |snapshot|
          context = RetrievalContext.new(
            source_name: snapshot.source_name, account_identity: snapshot.account_identity,
            window_start_utc: run.window_start_utc, window_end_utc: run.window_end_utc,
            display_timezone: run.display_timezone, limits: {}, filters: {}, capabilities: []
          )
          Pipeline::Filter.new(
            window_start_utc: run.window_start_utc, window_end_utc: run.window_end_utc,
            source_name: snapshot.source_name, max_records: snapshot.record_count.zero? ? 1 : snapshot.record_count
          ).call(record_repository.records_for_snapshot(snapshot.id), context:)
        end.map { |record| record_payload(record) }
      end

      def config_limit(key, fallback)
        value = container.config.to_h.dig("analysis", key) || container.config.to_h.dig("analysis", "limits", key)
        value.is_a?(Integer) && value.positive? ? value : fallback
      end

      def capture_action_state!(run_id)
        max_version = db[:inferred_actions].max(:state_version).to_i
        db[:runs].where(id: run_id).update(captured_action_state_version: max_version)
      end
    end
  end
end
