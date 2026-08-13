# frozen_string_literal: true

module Motherbrain
  module Candidates
    class HookNormalizer
      SCHEMA_VERSION = 1
      HARNESSES = %w[claude_code codex].freeze
      REQUIRED_FIELDS = %w[session_id transcript_path cwd].freeze

      def self.call(harness:, payload:, now: Time.now.utc)
        return unless HARNESSES.include?(harness)
        return unless payload.is_a?(Hash)
        return if payload["hook_event_name"] && payload["hook_event_name"] != "SessionEnd"
        return unless REQUIRED_FIELDS.all? { |field| present_string?(payload[field]) }

        normalized = {
          "schema_version" => SCHEMA_VERSION,
          "event" => "session_end",
          "harness" => harness,
          "session_id" => payload.fetch("session_id"),
          "transcript_path" => payload.fetch("transcript_path"),
          "cwd" => payload.fetch("cwd"),
          "reason" => present_string?(payload["reason"]) ? payload["reason"] : "other",
          "received_at" => now.utc.iso8601
        }
        normalized["turn_id"] = payload["turn_id"] if harness == "codex" && present_string?(payload["turn_id"])
        normalized
      rescue KeyError, TypeError
        nil
      end

      def self.present_string?(value)
        value.is_a?(String) && !value.empty?
        private_class_method :present_string?
      end
    end
  end
end
