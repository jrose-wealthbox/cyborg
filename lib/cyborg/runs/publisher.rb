# frozen_string_literal: true

require "json"
require "securerandom"
require "time"

module Cyborg
  module Runs
    PublishedRun = Data.define(:run, :view_model, :presentation, :warnings)

    # Commits the externally visible result of a run as one database unit. The
    # renderer never participates in this transaction: it receives only the
    # immutable persisted view model after publication succeeds.
    class Publisher
      attr_reader :db, :now

      def initialize(db:, now: nil, clock: nil, footer: nil, profile: "default",
                     reconciler: nil, view_model_builder: nil, usage_recorder: nil, trusted_hosts: [])
        @db = db
        @now = now || (clock.respond_to?(:now) ? clock.now : Time.now.utc)
        @now = @now.is_a?(Time) ? @now.utc : Time.iso8601(@now.to_s).utc
        @profile = profile.to_s
        @footer = footer
        @runs = Repositories::RunRepository.new(db)
        @sources = Repositories::SourceRepository.new(db)
        @records = Repositories::RecordRepository.new(db)
        @analyses = Repositories::AnalysisRepository.new(db)
        @presentations = Repositories::PresentationRepository.new(db)
        @reconciler = reconciler || Actions::Reconciler.new(db:, now: @now)
        @builder = view_model_builder || Presentation::ViewModelBuilder.new(now: @now, footer:, trusted_hosts:)
        @trusted_hosts = trusted_hosts
        @usage = usage_recorder || Analysis::UsageRecorder.new(db:, now: @now)
        @failure_stage = nil
      end

      def fail_after!(stage)
        @failure_stage = stage.to_sym
        self
      end

      def publish(run:, analysis:)
        run_id = value(run, :id)
        raise PersistenceError.new("run.not_found") unless @runs.find(run_id)

        result = nil
        db.transaction(mode: :immediate) do
          persisted_run = @runs.find(run_id)
          raise PersistenceError.new("run.not_found") unless persisted_run
          raise PersistenceError.new("run.not_publishable") unless persisted_run.status == "running"

          claims = Array(value(analysis, :claims, "claims"))
          reconciliation = @reconciler.call(run: persisted_run, claims: claims)
          analysis_warnings = rejected_analysis_warnings(analysis)
          persist_analysis(run_id:, analysis:, claims:, warnings: reconciliation.warnings + analysis_warnings)
          usage_summary = persist_usage(run_id:, usage: value(analysis, :usage, "usage"))
          snapshots = snapshots_for_view(run_id)
          actions = actions_for_view
          records = records_for_view(snapshots)
          warnings = Array(reconciliation.warnings) + analysis_warnings + Array(value(analysis, :warnings, "warnings"))
          warnings.concat(source_warnings(snapshots))
          warnings << "analysis.cost_uncertain" if usage_summary.fetch("certainty") == "unknown"
          view_model = @builder.call(
            run: run_hash(@runs.find(run_id)), snapshots:, records:, actions:, warnings:, usage: usage_summary
          )
          persist_presentation(run_id:, view_model:)
          maybe_fail!(:presentation_insert)
          activate_eligible_baselines(snapshots)
          status = snapshots.any? { |snapshot| snapshot.fetch("status") != "healthy" } || !analysis_warnings.empty? ? "degraded" : "completed"
          updated_run = @runs.update_status(
            id: run_id, status:, completed_at: @now.utc.iso8601,
            usage_summary_json: Bridge::CanonicalJSON.dump(usage_summary)
          )
          @runs.set_latest_renderable!(run_id:, updated_at: @now.utc.iso8601)
          result = PublishedRun.new(
            run: updated_run, view_model:, presentation: @presentations.for_run(run_id: run_id, profile: @profile).first,
            warnings: warnings.freeze
          )
        end
        result
      end

      private

      def persist_analysis(run_id:, analysis:, claims:, warnings:)
        raw = {
          "claims" => claims.map { |claim| normalize(claim) },
          "warnings" => warnings.map { |warning| normalize(warning) },
          "backend_metadata" => normalize(value(analysis, :backend_metadata, "backend_metadata") || {})
        }
        input_fingerprint = Bridge::CanonicalJSON.sha256(raw.fetch("claims"))
        result_json = Bridge::CanonicalJSON.dump(raw)
        row = {
          id: SecureRandom.uuid, run_id:, task_id: "publication", input_fingerprint:,
          output_fingerprint: Bridge::CanonicalJSON.sha256(raw), validation_status: warnings.empty? ? "valid" : "degraded",
          backend_metadata_json: Bridge::CanonicalJSON.dump(raw.fetch("backend_metadata")), result_json:,
          created_at: @now.utc.iso8601, completed_at: @now.utc.iso8601
        }
        db[:analysis_results].insert_conflict(
          target: %i[run_id task_id input_fingerprint], update: row.reject { |key, _| %i[id run_id task_id input_fingerprint].include?(key) }
        ).insert(row)
        @analyses.for_run(run_id).find { |candidate| candidate[:task_id] == "publication" && candidate[:input_fingerprint] == input_fingerprint }
      end

      def persist_usage(run_id:, usage:)
        raw = normalize(usage || {})
        Array(raw["records"]).each_with_index do |record, index|
          value_record = normalize(record)
          session_id = value_record["session_id"] || "publication-#{index}"
          existing = db[:usage_records].where(run_id:, session_id:).first
          next if existing

          @usage.record(
            run_id:, task_id: value_record["task_id"], session_id:, parent_session_id: value_record["parent_session_id"],
            reserved_cost_micros: value_record["reserved_cost_micros"], input_tokens: value_record["input_tokens"],
            output_tokens: value_record["output_tokens"], cost_micros: value_record["cost_micros"],
            certainty: value_record["certainty"], id: value_record["id"]
          )
        end
        summary = @usage.summary(run_id:)
        result = {
          "certainty" => summary.certainty, "reserved_cost_micros" => summary.reserved_cost_micros,
          "reported_cost_micros" => summary.reported_cost_micros,
          "provider_reported_cost_micros" => summary.provider_reported_cost_micros,
          "locally_estimated_cost_micros" => summary.locally_estimated_cost_micros,
          "unknown_cost_micros" => [summary.unknown_cost_micros, raw["unknown_cost_micros"].to_i].max,
          "warnings" => summary.warnings
        }
        result["certainty"] = raw["certainty"] if raw["certainty"] == "unknown"
        result
      end

      def snapshots_for_view(run_id)
        @sources.snapshots_for_run(run_id).map do |snapshot|
          hash = snapshot_hash(snapshot)
          prior = prior_fresh_snapshot(hash)
          hash["last_fresh_refresh"] = prior.completed_at if prior
          hash["last_fresh_refresh"] = snapshot.completed_at if eligible_fresh_snapshot?(hash) && hash["last_fresh_refresh"].nil?
          hash
        end
      end

      def records_for_view(snapshots)
        snapshots.flat_map do |snapshot|
          prior = prior_fresh_snapshot(snapshot)
          prior_ids = prior ? prior_record_ids(prior.id) : []
          @records.records_for_snapshot(snapshot.fetch("id")).uniq(&:id).map do |record|
            hash = record_hash(record)
            hash["first_seen_after_baseline"] = first_seen_after_baseline?(record, prior, prior_ids)
            hash
          end
        end
      end

      def first_seen_after_baseline?(record, prior, prior_ids)
        return false unless prior
        return false if prior_ids.include?(record.id)
        return false unless record.first_seen_at && prior.completed_at

        Time.iso8601(record.first_seen_at.to_s) > Time.iso8601(prior.completed_at.to_s)
      rescue ArgumentError, TypeError
        false
      end

      def prior_record_ids(snapshot_id)
        db[:snapshot_records].join(:observed_record_versions, id: :record_version_id).where(snapshot_id:).select_map(:observed_record_id).uniq
      end

      def prior_fresh_snapshot(snapshot)
        snapshot = snapshot.is_a?(Hash) ? snapshot : snapshot_hash(snapshot)
        id = snapshot["prior_activated_snapshot_id"]
        id ||= @sources.baseline_for(snapshot["source_name"], snapshot["account_identity"])&.fetch(:activated_snapshot_id, nil)
        return nil unless id

        candidate = @sources.snapshot(id)
        candidate if candidate && candidate.status == "healthy" && candidate.data_status == "fresh"
      end

      def eligible_fresh_snapshot?(snapshot)
        snapshot["status"] == "healthy" && snapshot["data_status"] == "fresh" &&
          snapshot["cursor_disposition"] == "advance" && nonblank?(snapshot["proposed_cursor"])
      end

      def actions_for_view
        db[:inferred_actions].order(:series_id, :occurrence_number).all.map do |row|
          action = row.transform_keys(&:to_s)
          urls = db[:action_evidence].join(:evidence, id: :evidence_id).where(action_id: row.fetch(:id)).select_map(:source_url)
          action["source_url"] = urls.first if urls.first
          action
        end
      end

      def persist_presentation(run_id:, view_model:)
        row = {id: SecureRandom.uuid, run_id:, profile: @profile,
               view_model_json: Bridge::CanonicalJSON.dump(view_model), created_at: @now.utc.iso8601}
        db[:presentation_results].insert_conflict(
          target: %i[run_id profile], update: row.reject { |key, _| %i[id run_id profile].include?(key) }
        ).insert(row)
      end

      def activate_eligible_baselines(snapshots)
        snapshots.each do |snapshot|
          next unless snapshot["status"] == "healthy" && snapshot["data_status"] == "fresh"
          next unless snapshot["cursor_disposition"] == "advance" && nonblank?(snapshot["proposed_cursor"])

          @sources.activate_baseline(
            source_name: snapshot.fetch("source_name"), account_identity: snapshot.fetch("account_identity"),
            snapshot_id: snapshot.fetch("id"), activated_at: @now.utc.iso8601, cursor: snapshot.fetch("proposed_cursor")
          )
        end
      end

      def source_warnings(snapshots)
        snapshots.filter_map do |snapshot|
          next if snapshot["status"] == "healthy"

          "source.#{snapshot["source_name"]}.#{snapshot["status"]}: last fresh refresh=#{snapshot["last_fresh_refresh"] || "unknown"}; cached=#{snapshot["data_status"] == "cached"}; remediation=#{snapshot["error_remediation"] || "none"}; inference impact=#{snapshot["inference_impact"] || "may be incomplete"}"
        end
      end

      def rejected_analysis_warnings(analysis)
        return [] unless analysis.respond_to?(:accepted?) && !analysis.accepted?

        code = value(analysis, :code, "code")
        [code ? "analysis.rejected.#{code}" : "analysis.rejected"]
      end

      def maybe_fail!(stage)
        return unless @failure_stage == stage

        @failure_stage = nil
        raise Sequel::ConstraintViolation, "injected publication failure"
      end

      def value(object, key, alternate = nil)
        return nil if object.nil?
        return object.public_send(key) if object.respond_to?(key)
        hash = object.respond_to?(:to_h) ? object.to_h : object
        hash[key] || (alternate && hash[alternate]) || hash[key.to_s]
      end

      def normalize(value)
        case value
        when Hash then value.each_with_object({}) { |(key, item), result| result[key.to_s] = normalize(item) }
        when Array then value.map { |item| normalize(item) }
        when Time then value.utc.iso8601
        when Data then value.to_h.each_with_object({}) { |(key, item), result| result[key.to_s] = normalize(item) }
        else value
        end
      end

      def run_hash(run)
        normalize(run)
      end

      def snapshot_hash(snapshot)
        normalize(snapshot)
      end

      def record_hash(record)
        normalize(record)
      end

      def nonblank?(value)
        value.is_a?(String) && !value.strip.empty?
      end
    end
  end
end
