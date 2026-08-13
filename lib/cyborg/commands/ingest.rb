# frozen_string_literal: true

module Cyborg
  module Commands
    class Ingest < Base
      def call(argv)
        options = parse_options(argv, required: %w[run lease-file input])
        run_id = options.fetch("run")
        lease_file = options.fetch("lease-file")
        with_mutation_lease(run_id:, lease_file:) do
          run = run_repository.find(run_id)
          raise InvalidArtifact.new("run.not_found", exit_status: 65) unless run
          store = store_for_lease(lease_file)
          input_path = Pathname(options.fetch("input")).expand_path
          payload = load_envelope(store:, path: input_path, expected_type: "retrieval_responses", run_id:)
          responses = payload.is_a?(Hash) ? (payload["responses"] || payload[:responses] || []) : payload
          raise InvalidArtifact.new("bridge.invalid_responses", exit_status: 65) unless responses.is_a?(Array)

          requests = retrieval_requests(store:, run_id:)
          request_by_id = requests.to_h { |request| [request.fetch("id"), request] }
          ingested = []
          pending = {}
          responses.each do |raw_response|
            response = normalize(raw_response)
            request_id = response["request_id"].to_s
            request = request_by_id[request_id]
            raise InvalidArtifact.new("bridge.unknown_request", exit_status: 65) unless request

            response_payload = {"responses" => [response]}
            filename = "retrieval-response-#{safe_request_id(request_id)}.json"
            existing_path = store.root.join(run_id, filename)
            if File.exist?(existing_path)
              existing = load_envelope(store:, path: existing_path, expected_type: "retrieval_responses", run_id:)
              if Bridge::CanonicalJSON.dump(existing) != Bridge::CanonicalJSON.dump(response_payload)
                store.record_validation_failure!(
                  run_id:, code: "bridge.changed_response", command: "ingest", request_id:,
                  submitted_payload_sha256: Bridge::CanonicalJSON.sha256(response_payload),
                  existing_payload_sha256: Bridge::CanonicalJSON.sha256(existing), at: container.clock.now
                )
                raise InvalidArtifact.new("bridge.changed_response", exit_status: 65)
              end
              next
            end

            previous = pending[request_id]
            if previous
              if Bridge::CanonicalJSON.dump(previous.fetch(:payload)) != Bridge::CanonicalJSON.dump(response_payload)
                record_changed_response!(store:, run_id:, request_id:, submitted: response_payload, existing: previous.fetch(:payload))
                raise InvalidArtifact.new("bridge.changed_response", exit_status: 65)
              end
              next
            end
            pending[request_id] = {request:, response:, payload: response_payload, filename:}
          end

          pending.values.group_by { |item| [item.fetch(:request).fetch("source_name"), item.fetch(:request)["account_identity"]] }.each_value do |group|
            registration = registration_for(group.first.fetch(:request).fetch("source_name"), group.first.fetch(:request)["account_identity"])
            prior = persisted_group_responses(store:, run_id:, requests:, request: group.first.fetch(:request))
            values = prior + group.map { |item| item.fetch(:response) }
            result = aggregate_result(values, request_by_id)
            SourceIngestor.new(db:).ingest(run:, registration:, result:)
            group.each do |item|
              write_envelope(
                store:, run_id:, filename: item.fetch(:filename), type: "retrieval_responses", payload: item.fetch(:payload)
              )
              ingested << item.fetch(:request).fetch("id")
            end
          end
          stdout.puts safe_json("run_id" => run_id, "status" => run.status, "ingested" => ingested)
          0
        end
      end

      private

      def retrieval_requests(store:, run_id:)
        path = store.root.join(run_id, "retrieval-requests.json")
        payload = load_envelope(store:, path:, expected_type: "retrieval_requests", run_id:)
        raise InvalidArtifact.new("bridge.invalid_requests", exit_status: 65) unless payload.is_a?(Array)

        payload.map { |value| normalize(value) }
      end

      def safe_request_id(value)
        unless value.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/)
          raise InvalidArtifact.new("bridge.unsafe_request_id", exit_status: 65)
        end
        value
      end

      def record_changed_response!(store:, run_id:, request_id:, submitted:, existing:)
        store.record_validation_failure!(
          run_id:, code: "bridge.changed_response", command: "ingest", request_id:,
          submitted_payload_sha256: Bridge::CanonicalJSON.sha256(submitted),
          existing_payload_sha256: Bridge::CanonicalJSON.sha256(existing), at: container.clock.now
        )
      end

      def persisted_group_responses(store:, run_id:, requests:, request:)
        requests.filter_map do |candidate|
          next unless candidate.fetch("source_name") == request.fetch("source_name")
          next unless candidate["account_identity"].to_s == request["account_identity"].to_s

          path = store.root.join(run_id, "retrieval-response-#{safe_request_id(candidate.fetch("id"))}.json")
          begin
            path.lstat
          rescue Errno::ENOENT
            next
          end
          payload = load_envelope(store:, path:, expected_type: "retrieval_responses", run_id:)
          values = payload.is_a?(Hash) ? payload["responses"] : nil
          raise InvalidArtifact.new("bridge.invalid_response", exit_status: 65) unless values.is_a?(Array) && values.length == 1

          response = normalize(values.fetch(0))
          raise InvalidArtifact.new("bridge.request_mismatch", exit_status: 65) unless response["request_id"].to_s == candidate.fetch("id").to_s

          response
        end
      end

      def aggregate_result(values, request_by_id)
        results = values.map do |response|
          request = request_by_id.fetch(response.fetch("request_id"))
          retrieval_result(response, request)
        end
        statuses = results.map(&:status)
        data_statuses = results.map(&:data_status).uniq
        successful = results.reject { |result| result.status == "failed" }
        status = if successful.empty?
          "failed"
        elsif statuses.include?("failed") || statuses.include?("degraded") || data_statuses.length > 1
          "degraded"
        else
          "healthy"
        end
        successful_data_statuses = successful.map(&:data_status).uniq
        data_status = if successful.empty?
          "none"
        elsif successful_data_statuses == ["cached"]
          "cached"
        else
          "fresh"
        end
        errors = results.filter_map(&:error)
        error = errors.first
        error ||= RetrievalError.new(
          code: "bridge.aggregate_response", message: "host responses for one source were not uniformly healthy",
          remediation: "retry the source batch"
        ) unless status == "healthy"
        cursors = results.map(&:next_cursor)
        cursor = cursors.uniq.length == 1 ? cursors.first : nil
        RetrievalResult.new(
          source_name: results.first.source_name, account_identity: results.first.account_identity,
          status:, data_status:, cache_reason: if data_status == "cached"
            status == "healthy" ? results.first.cache_reason : "failure_fallback"
          end,
          started_at: results.map { |result| Time.iso8601(result.started_at) }.min,
          completed_at: results.map { |result| Time.iso8601(result.completed_at) }.max,
          records: results.flat_map(&:records), next_cursor: cursor, error:
        )
      rescue KeyError, ArgumentError => error
        raise InvalidArtifact.new("bridge.invalid_response", error.message, exit_status: 65)
      end

      def retrieval_result(response, request)
        status = response.fetch("status")
        data_status = response["data_status"] || (status == "failed" ? "none" : "fresh")
        error = response["error"]
        error_value = if error
          error = normalize(error)
          RetrievalError.new(code: error.fetch("code"), message: error["message"], remediation: error["remediation"])
        end
        RetrievalResult.new(
          source_name: request.fetch("source_name"), account_identity: request["account_identity"], status:, data_status:,
          cache_reason: response["cache_reason"], started_at: response["started_at"] || request.fetch("window_start_utc"),
          completed_at: response["completed_at"] || request.fetch("window_end_utc"),
          records: Array(response["records"]).map { |record| normalized_record(record) }, next_cursor: response["next_cursor"],
          error: error_value
        )
      rescue KeyError, ArgumentError => error
        raise InvalidArtifact.new("bridge.invalid_response", error.message, exit_status: 65)
      end

      def normalized_record(raw)
        value = normalize(raw)
        evidence = Array(value["evidence"]).map do |item|
          item = normalize(item)
          EvidenceDraft.new(
            source_url: item.fetch("source_url"), source_label: item.fetch("source_label"), excerpt: item["excerpt"],
            field_path: item["field_path"], evidence_at: item.fetch("evidence_at"), relation: item.fetch("relation", "context")
          )
        end
        NormalizedRecord.new(
          source_record_id: value.fetch("source_record_id"), record_kind: value.fetch("record_kind"), title: value["title"],
          summary: value["summary"], structured_fields: value["structured_fields"] || {}, participants: value["participants"] || [],
          owner_identity: value["owner_identity"], canonical_target_type: value["canonical_target_type"],
          canonical_target_id: value["canonical_target_id"], deep_link: value["deep_link"], event_at: value["event_at"],
          latest_reply_at: value["latest_reply_at"], observed_at: value["observed_at"], timestamp_kind: value["timestamp_kind"],
          content_fingerprint: value["content_fingerprint"] || Bridge::CanonicalJSON.sha256(value), evidence:
        )
      rescue KeyError, ArgumentError => error
        raise InvalidArtifact.new("bridge.invalid_record", error.message, exit_status: 65)
      end
    end
  end
end
