# frozen_string_literal: true

require "time"
require "date"

require_relative "../analysis/contracts"
require_relative "../clock"
require_relative "../repositories/action_repository"

module Cyborg
  module Actions
    class StateMachine
      TRANSITIONS = {
        "acknowledge" => {from: %w[open snoozed], to: "acknowledged"},
        "snooze" => {from: %w[open acknowledged snoozed], to: "snoozed"},
        "done" => {from: %w[open acknowledged snoozed], to: "done"},
        "dismiss" => {from: %w[open acknowledged snoozed], to: "dismissed"},
        "reopen" => {from: %w[acknowledged snoozed done dismissed], to: "open"}
      }.freeze
      RFC3339_DATETIME = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)\z/.freeze
      USER_STATES = %w[open acknowledged snoozed done dismissed].freeze

      attr_reader :db, :now

      def initialize(db:, now: nil, clock: nil, action_repository: nil)
        @db = db
        source_now = now || (clock.respond_to?(:now) ? clock.now : Time.now.utc)
        @now = canonical_time(source_now, "now")
        @actions = action_repository || Cyborg::Repositories::ActionRepository.new(db)
      end

      def transition(action_id:, command:, until_time: nil, origin:)
        command = command.to_s
        transition = TRANSITIONS[command]
        fail_action("actions.invalid_command") unless transition
        fail_action("actions.invalid_origin") unless origin.is_a?(String) && !origin.strip.empty?
        snoozed_until = command == "snooze" ? required_until(until_time) : nil

        db.transaction(mode: :immediate) do
          action = @actions.action(action_id)
          fail_action("actions.not_found") unless action
          target = transition.fetch(:to)
          if idempotent?(action, command, target, snoozed_until)
            next action
          end
          unless transition.fetch(:from).include?(action.user_state)
            fail_action("actions.invalid_transition")
          end

          changed_at = now.utc.iso8601
          attributes = {
            user_state: target,
            snoozed_until: target == "snoozed" ? snoozed_until : nil,
            terminal_at: %w[done dismissed].include?(target) ? changed_at : nil,
            state_version: action.state_version + 1
          }
          updated = @actions.update_action(id: action.id, attributes: attributes)
          @actions.transition(
            action_id: action.id, from_state: action.user_state, to_state: target,
            changed_at:, origin:, state_version: updated.state_version
          )
          updated
        end
      end

      def displayable?(action:, at: now)
        return false unless action && action.inference_status == "active"
        return false if %w[done dismissed].include?(action.user_state)
        return true unless action.user_state == "snoozed"

        return false if action.snoozed_until.nil?

        canonical_time(at, "at") >= canonical_time(action.snoozed_until, "snoozed_until")
      end

      private

      def idempotent?(action, command, target, snoozed_until)
        return false unless action.user_state == target
        return true unless command == "snooze"

        action.snoozed_until == snoozed_until
      end

      def required_until(value)
        fail_action("actions.snooze_requires_until") if value.nil?

        unless value.is_a?(Time) || (value.is_a?(String) && RFC3339_DATETIME.match?(value))
          fail_action("actions.invalid_until")
        end
        DateTime.iso8601(value.to_s) unless value.is_a?(Time)

        canonical_time(value, "until_time").utc.iso8601
      rescue ArgumentError, TypeError, Date::Error
        fail_action("actions.invalid_until")
      end

      def canonical_time(value, field)
        time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
        time.utc
      rescue ArgumentError, TypeError
        raise ArgumentError, "#{field} must be an RFC3339 timestamp"
      end

      def fail_action(code)
        raise Cyborg::UsageError.new(code)
      end
    end
  end
end
