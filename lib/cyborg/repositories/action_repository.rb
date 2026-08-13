# frozen_string_literal: true

require_relative "base"

module Cyborg
  module Repositories
    class ActionRepository < Base
      def create_series(attributes)
        attrs = attributes.to_h
        validate_timestamps!(attrs, %i[created_at updated_at])
        db[:action_series].insert(attrs)
        series(attrs.fetch(:id))
      end

      def series(id)
        value(ActionSeries, row(db[:action_series], id))
      end

      def find_series_by_subject(subject_key)
        record = db[:action_series].where(current_subject_key: subject_key).first
        record ||= db[:action_series].join(:action_key_aliases, series_id: :id).where(
          Sequel[:action_key_aliases][:subject_key] => subject_key
        ).select_all(:action_series).first
        record && value(ActionSeries, record)
      end

      def add_alias(attributes)
        db[:action_key_aliases].insert(attributes.to_h)
        true
      end

      def create_action(attributes)
        attrs = attributes.to_h
        validate_timestamps!(attrs, %i[first_seen_at last_seen_at due_at terminal_at snoozed_until])
        db[:inferred_actions].insert(attrs)
        action(attrs.fetch(:id))
      end

      def action(id)
        value(InferredAction, row(db[:inferred_actions], id))
      end

      def update_action(id:, attributes:)
        validate_timestamps!(attributes.to_h, %i[first_seen_at last_seen_at due_at terminal_at snoozed_until])
        db[:inferred_actions].where(id:).update(attributes.to_h)
        action(id)
      end

      def actions_for_series(series_id)
        db[:inferred_actions].where(series_id:).order(:occurrence_number).all.map do |record|
          value(InferredAction, record)
        end
      end

      def attach_evidence(action_id:, evidence_id:, attributes: {})
        db[:action_evidence].insert({action_id:, evidence_id:}.merge(attributes.to_h))
        true
      end

      def transition(attributes)
        attrs = attributes.to_h
        validate_timestamps!(attrs, %i[changed_at])
        db[:action_transitions].insert(attrs)
        true
      end

      def link_successor(predecessor_action_id:, successor_action_id:, created_at:)
        validate_timestamp!(created_at, field: :created_at)
        db[:action_successors].insert(predecessor_action_id:, successor_action_id:, created_at:)
        true
      end
    end
  end
end
