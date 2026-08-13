# frozen_string_literal: true

require "digest"

require_relative "../bridge/canonical_json"

module Cyborg
  module Actions
    module SubjectKey
      module_function

      IDENTITY_VERSION = 1

      def call(identity_version:, action_kind:, subject_type:, subject_id:, owner_identity: nil,
               target_identity: nil, thread_or_target_identity: nil, **_ignored)
        version = identity_version
        unless version.is_a?(Integer) && version.positive?
          raise ArgumentError, "identity_version must be a positive integer"
        end

        tuple = [
          version,
          required_identity(action_kind, "action_kind"),
          required_identity(subject_type, "subject_type"),
          required_identity(subject_id, "subject_id"),
          normalize(owner_identity),
          normalize(target_identity.nil? ? thread_or_target_identity : target_identity)
        ]
        Digest::SHA256.hexdigest(Cyborg::Bridge::CanonicalJSON.dump(tuple))
      end

      def normalize(value)
        return nil if value.nil?

        text = value.to_s.strip.downcase.gsub(/\s+/, " ")
        text.empty? ? nil : text
      end

      def required_identity(value, field)
        normalized = normalize(value)
        raise ArgumentError, "#{field} must be a nonblank identity" if normalized.nil?

        normalized
      end
      private_class_method :required_identity
    end
  end
end
