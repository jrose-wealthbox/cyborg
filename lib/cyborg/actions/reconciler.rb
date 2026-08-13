# frozen_string_literal: true

require "json"
require "securerandom"
require "time"

require_relative "subject_key"
require_relative "../bridge/canonical_json"
require_relative "../repositories/action_repository"

module Cyborg
  module Actions
    ReconciliationResult = Data.define(:actions, :warnings)

    class Reconciler
      attr_reader :db, :now, :identity_version

      def initialize(db:, now: nil, clock: nil, identity_version: SubjectKey::IDENTITY_VERSION,
                     action_repository: nil)
        @db = db
        @actions = action_repository || Cyborg::Repositories::ActionRepository.new(db)
        source_now = now || (clock.respond_to?(:now) ? clock.now : Time.now.utc)
        @now = canonical_time(source_now, "now")
        @identity_version = identity_version
      end

      def call(run:, claims:)
        run_id = run_value(run, :id)
        observed_at = canonical_time(run_value(run, :completed_at) || run_value(run, :created_at) || now, "run time").utc.iso8601
        warnings = []
        actions = []
        db.transaction(mode: :immediate) do
          Array(claims).each_with_index do |claim, index|
            actions.concat(reconcile_claim(run_id:, observed_at:, claim:, warnings:, index:))
          end
        end
        ReconciliationResult.new(actions.uniq(&:id).freeze, warnings.freeze)
      end

      private

      def reconcile_claim(run_id:, observed_at:, claim:, warnings:, index:)
        action_kind = required_claim(claim, "action_kind")
        subject_type = required_claim(claim, "canonical_subject_type", "subject_type")
        subject_id = required_claim(claim, "canonical_subject_id", "subject_id")
        owner = claim_value(claim, "owner_identity")
        target = claim_value(claim, "thread_or_target_identity") || claim_value(claim, "target_identity")
        identity_version = claim_value(claim, "identity_version") || identity_version_value
        key = SubjectKey.call(
          identity_version:, action_kind:, subject_type:, subject_id:,
          owner_identity: owner, target_identity: target
        )
        series = @actions.find_series_by_subject(key)
        if series.nil?
          return [create_initial_action(
            run_id:, observed_at:, key:, identity_version:, action_kind:, subject_type:, subject_id:,
            owner:, target:, claim:
          )]
        end

        current = @actions.actions_for_series(series.id).last
        fail_action("actions.series_without_occurrence") unless current
        evidence_ids = claim_evidence_ids(claim)
        evidence = evidence_rows(evidence_ids)
        if terminal?(current) && claim_value(claim, "new_commitment") == true
          if successor_allowed?(current, claim, evidence)
            return create_successor(
              run_id:, observed_at:, series:, predecessor: current, key:, identity_version:,
              action_kind:, subject_type:, subject_id:, owner:, target:, claim:, evidence_ids:
            )
          end
          warnings << {
            "code" => "actions.ambiguous_successor", "action_id" => current.id,
            "claim_index" => index, "reason" => "successor conditions are not provable"
          }
        end

        update_inference(current, claim, observed_at:)
        attach_evidence(action_id: current.id, evidence_ids:, run_id:, observed_at:)
        [@actions.action(current.id)]
      end

      def create_initial_action(run_id:, observed_at:, key:, identity_version:, action_kind:, subject_type:, subject_id:, owner:, target:, claim:)
        series_id = SecureRandom.uuid
        @actions.create_series(
          id: series_id, current_subject_key: key, identity_version:, action_kind:,
          canonical_subject_type: SubjectKey.normalize(subject_type), canonical_subject_id: SubjectKey.normalize(subject_id),
          normalized_owner_identity: SubjectKey.normalize(owner),
          normalized_thread_or_target_identity: SubjectKey.normalize(target), created_at: observed_at, updated_at: observed_at
        )
        action = create_occurrence(
          series_id:, occurrence_number: 1, action_kind:, claim:, observed_at:, user_state: "open"
        )
        attach_evidence(action_id: action.id, evidence_ids: claim_evidence_ids(claim), run_id:, observed_at:)
        @actions.action(action.id)
      end

      def create_successor(run_id:, observed_at:, series:, predecessor:, key:, identity_version:, action_kind:, subject_type:, subject_id:, owner:, target:, claim:, evidence_ids:)
        successor = create_occurrence(
          series_id: series.id, occurrence_number: predecessor.occurrence_number + 1,
          action_kind:, claim:, observed_at:, user_state: "open"
        )
        @actions.update_action(id: predecessor.id, attributes: {inference_status: "superseded", last_seen_at: observed_at})
        @db[:action_series].where(id: series.id).update(updated_at: observed_at)
        @actions.link_successor(predecessor_action_id: predecessor.id, successor_action_id: successor.id, created_at: observed_at)
        attach_evidence(action_id: successor.id, evidence_ids:, run_id:, observed_at:)
        [@actions.action(predecessor.id), @actions.action(successor.id)]
      end

      def create_occurrence(series_id:, occurrence_number:, action_kind:, claim:, observed_at:, user_state:)
        action_id = SecureRandom.uuid
        @actions.create_action(
          id: action_id, series_id:, occurrence_number:, inference_status: "active", action_kind:,
          summary: required_claim(claim, "summary"), related_people_json: json_array(claim_value(claim, "people")),
          related_projects_json: json_array(claim_value(claim, "projects")), due_at: canonical_optional_time(claim_value(claim, "due_at")),
          confidence: numeric_claim(claim, "confidence"), user_state:, snoozed_until: nil, state_version: 0,
          first_seen_at: observed_at, last_seen_at: observed_at, terminal_at: nil
        )
      end

      def update_inference(action, claim, observed_at:)
        @actions.update_action(
          id: action.id,
          attributes: {
            inference_status: terminal?(action) ? action.inference_status : "active",
            summary: required_claim(claim, "summary"),
            related_people_json: json_array(claim_value(claim, "people")),
            related_projects_json: json_array(claim_value(claim, "projects")),
            due_at: canonical_optional_time(claim_value(claim, "due_at")), confidence: numeric_claim(claim, "confidence"),
            last_seen_at: observed_at
          }
        )
      end

      def attach_evidence(action_id:, evidence_ids:, run_id:, observed_at:)
        evidence_ids.each do |evidence_id|
          fail_action("actions.unknown_evidence") unless @db[:evidence].where(id: evidence_id).first
          existing = @db[:action_evidence].where(action_id:, evidence_id:).first
          if existing
            @db[:action_evidence].where(action_id:, evidence_id:).update(last_seen_run_id: run_id, last_seen_at: observed_at)
          else
            @db[:action_evidence].insert(
              action_id:, evidence_id:, first_seen_run_id: run_id, last_seen_run_id: run_id,
              first_seen_at: observed_at, last_seen_at: observed_at
            )
          end
        end
      end

      def successor_allowed?(action, claim, evidence)
        return false unless action.terminal_at
        anchor_id = claim_value(claim, "anchor_evidence_id")
        anchor = evidence.find { |row| row.fetch(:id) == anchor_id }
        return false unless anchor
        return false unless anchor[:evidence_at] && anchor[:evidence_at] > action.terminal_at

        !@db[:action_evidence].where(action_id: action.id, evidence_id: anchor_id).where { first_seen_at <= action.terminal_at }.count.positive?
      end

      def evidence_rows(ids)
        @db[:evidence].where(id: ids).all.map { |row| {id: row.fetch(:id), evidence_at: row.fetch(:evidence_at)} }
      end

      def claim_evidence_ids(claim)
        ids = claim_value(claim, "evidence_ids")
        fail_action("actions.invalid_claim") unless ids.is_a?(Array) && !ids.empty? && ids.all? { |id| id.is_a?(String) && !id.strip.empty? }
        ids.map(&:to_s).uniq
      end

      def required_claim(claim, canonical, alias_name = nil)
        value = claim_value(claim, canonical)
        value = claim_value(claim, alias_name) if value.nil? && alias_name
        fail_action("actions.invalid_claim") unless value.is_a?(String) && !value.strip.empty?
        value
      end

      def numeric_claim(claim, field)
        value = claim_value(claim, field)
        fail_action("actions.invalid_claim") unless value.is_a?(Numeric) && value.finite? && value >= 0 && value <= 1
        value
      end

      def canonical_optional_time(value)
        return nil if value.nil?

        canonical_time(value, "due_at").utc.iso8601
      rescue ArgumentError, TypeError
        fail_action("actions.invalid_claim")
      end

      def json_array(value)
        Array(value).map(&:to_s).uniq.sort.then { |items| JSON.generate(items) }
      end

      def claim_value(claim, field)
        if claim.respond_to?(field)
          claim.public_send(field)
        elsif claim.is_a?(Hash)
          claim[field] || claim[field.to_sym]
        end
      end

      def run_value(run, field)
        if run.respond_to?(field)
          run.public_send(field)
        elsif run.is_a?(Hash)
          run[field.to_s] || run[field]
        end
      end

      def identity_version_value
        identity_version
      end

      def terminal?(action)
        %w[done dismissed].include?(action.user_state)
      end

      def canonical_time(value, field)
        (value.is_a?(Time) ? value : Time.iso8601(value.to_s)).utc
      rescue ArgumentError, TypeError
        raise ArgumentError, "#{field} must be an RFC3339 timestamp"
      end

      def fail_action(code)
        raise Cyborg::UsageError.new(code)
      end
    end
  end

  Action = InferredAction unless const_defined?(:Action, false)
end
