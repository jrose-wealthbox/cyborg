# frozen_string_literal: true

require "json"
require "securerandom"

module Cyborg
  module Analysis
    # The production boundary for executing declared analysis work. It owns
    # dependency-ready launches, validated analysis caching, and usage ledger
    # rows; callers provide only a backend implementing #analyze.
    class Orchestrator
      Execution = Data.define(:outcomes, :reservation_plan, :launched_task_ids, :cached_task_ids)

      def initialize(db:, now: Time.now.utc, controller: BudgetController.new, usage_recorder: nil,
                     analyses: nil, validator: ResultValidator.new)
        @db = db
        @now = now.is_a?(Time) ? now.utc : Time.iso8601(now.to_s).utc
        @controller = controller
        @usage = usage_recorder || UsageRecorder.new(db:, now: @now)
        @analyses = analyses || Repositories::AnalysisRepository.new(db)
        @validator = validator
      end

      def execute(run_id:, packet:, tasks:, backend:, ceiling_micros: Analysis::DEFAULT_CEILING_MICROS)
        graph = TaskGraph.new(tasks:)
        plan = @controller.reserve(tasks:, ceiling_micros:)
        @db.transaction do
          parent_session = ensure_parent_session(run_id)
          completed = []
          outcomes = {}
          launched = []
          cached = []

          loop do
            progress = false
            graph.ready_tasks(completed_ids: completed).each do |task|
              next unless plan.status_for(task.id) == "reserved"
              next unless @controller.allow_launch?(plan, task:)

              progress = true
              cached_row = @analyses.find_cached(task_id: task.id, input_fingerprint: task.packet_fingerprint)
              if cached_row
                outcome = outcome_from(cached_row.fetch(:result_json))
                cached << task.id
              else
                outcome = validate_outcome(packet:, task:, outcome: backend.analyze(packet:, task:, reservation: task.reservation))
                persist_analysis(run_id:, task:, outcome:)
                launched << task.id
              end
              outcomes[task.id] = outcome
              reported_cost = record_usage(run_id:, task:, parent_session:, outcome:, cached: cached_row)
              plan = plan.add_reported_micros(reported_cost) if reported_cost.positive?
              plan = @controller.release(plan, task:)
              completed << task.id
            end
            break unless progress
          end

          required = tasks.select(&:required).map(&:id)
          tasks.reject { |task| completed.include?(task.id) }.each do |task|
            next unless plan.status_for(task.id) == "reserved"

            record_skipped_usage(run_id:, task:, parent_session:)
            @usage.release(session_id: "#{parent_session}-#{task.id}")
            plan = @controller.release(plan, task:)
          end
          missing = required - completed
          raise UsageError.new("analysis.required_task_not_launched") unless missing.empty?

          Execution.new(outcomes.freeze, plan, launched.freeze, cached.freeze)
        end
      end

      private

      def ensure_parent_session(run_id)
        id = "analysis-#{run_id}"
        return id if @db[:usage_records].where(id:).first

        @usage.record(id:, run_id:, session_id: id, certainty: "unknown", created_at: @now)
        id
      end

      def record_usage(run_id:, task:, parent_session:, outcome:, cached:)
        session_id = "#{parent_session}-#{task.id}"
        return 0 if @db[:usage_records].where(id: session_id).first

        usage = outcome.usage.is_a?(Hash) ? outcome.usage : {}
        reported = Array(usage["records"]).find { |record| record["task_id"].to_s == task.id.to_s } || Array(usage["records"]).first
        certainty = cached ? "locally_estimated" : reported&.fetch("certainty", usage.fetch("certainty", "unknown"))
        known_cost = reported && reported["cost_micros"]
        input_tokens = reported && reported["input_tokens"]
        output_tokens = reported && reported["output_tokens"]
        if %w[provider_reported locally_estimated].include?(certainty) &&
           [known_cost, input_tokens, output_tokens].all? { |value| value.is_a?(Integer) && value >= 0 }
          cost_micros = known_cost
        else
          certainty = "unknown"
          cost_micros = nil
          input_tokens = nil
          output_tokens = nil
        end
        @usage.record(
          id: session_id, run_id:, task_id: task.id, session_id:, parent_session_id: parent_session,
          input_tokens:, output_tokens:, cost_micros:, certainty:, created_at: @now
        )
        cached ? 0 : cost_micros.to_i
      end

      def record_skipped_usage(run_id:, task:, parent_session:)
        session_id = "#{parent_session}-#{task.id}"
        return if @db[:usage_records].where(id: session_id).first

        @usage.record(
          id: session_id, run_id:, task_id: task.id, session_id:, parent_session_id: parent_session,
          reserved_cost_micros: task.reservation.cost_micros, certainty: "reserved", created_at: @now
        )
      end

      def persist_analysis(run_id:, task:, outcome:)
        payload = outcome.to_h
        @analyses.create(
          id: SecureRandom.uuid, run_id:, task_id: task.id, input_fingerprint: task.packet_fingerprint,
          output_fingerprint: Bridge::CanonicalJSON.sha256(payload), validation_status: "valid",
          backend_metadata_json: Bridge::CanonicalJSON.dump(payload.fetch(:backend_metadata)),
          result_json: Bridge::CanonicalJSON.dump(payload), created_at: @now.iso8601, completed_at: @now.iso8601
        )
      end

      def validate_outcome(packet:, task:, outcome:)
        raw_usage = outcome.usage.is_a?(Hash) ? outcome.usage : {}
        usage = raw_usage.empty? ? {"records" => [], "certainty" => "unknown"} : raw_usage
        result = {
          "claims" => outcome.claims, "usage" => usage, "backend_metadata" => outcome.backend_metadata,
          "task_results" => [{"id" => task.id, "task_id" => task.id, "capability" => task.capability,
                               "dependency_ids" => task.dependency_ids, "status" => "succeeded",
                               "claims" => outcome.claims, "usage" => nil}]
        }
        task_packet = packet.merge(
          "tasks" => Array(packet["tasks"]).select { |declared| declared["id"].to_s == task.id.to_s }
        )
        validated = @validator.validate(packet: task_packet, result:)
        if validated.respond_to?(:accepted?) && !validated.accepted?
          raise UsageError.new("analysis.rejected.#{validated.code}")
        end

        validated
      end

      def outcome_from(json)
        payload = JSON.parse(json)
        AnalysisOutcome.new(
          claims: payload.fetch("claims", []), usage: payload.fetch("usage", {}),
          backend_metadata: payload.fetch("backend_metadata", {})
        )
      rescue JSON::ParserError, KeyError => error
        raise PersistenceError.new("analysis.cache_corrupt", error.message)
      end
    end
  end
end
