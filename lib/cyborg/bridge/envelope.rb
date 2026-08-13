# frozen_string_literal: true

require "time"

module Cyborg
  module Bridge
    module Envelope
      SUPPORTED_TYPES = %w[
        retrieval_requests
        retrieval_responses
        analysis_packet
        analysis_result
      ].freeze
      SUPPORTED_SCHEMA_MAJOR = 1
      SUPPORTED_SCHEMA_MINOR = 0
      REQUIRED_FIELDS = %w[schema_version artifact_type run_id created_at payload_sha256 payload].freeze

      module_function

      def build(type:, run_id:, payload:, created_at:)
        unless SUPPORTED_TYPES.include?(type.to_s)
          raise Cyborg::InvalidArtifact.new("bridge.unknown_type", exit_status: 65)
        end

        {
          "schema_version" => "#{SUPPORTED_SCHEMA_MAJOR}.#{SUPPORTED_SCHEMA_MINOR}",
          "artifact_type" => type.to_s,
          "run_id" => run_id.to_s,
          "created_at" => normalize_created_at(created_at),
          "payload_sha256" => CanonicalJSON.sha256(payload),
          "payload" => payload
        }
      end

      def validate!(document, expected_type:, expected_run_id:)
        unless document.is_a?(Hash)
          raise invalid("bridge.invalid_envelope", "Envelope must be a JSON object")
        end

        missing = REQUIRED_FIELDS.reject { |field| document.key?(field) }
        unless missing.empty?
          raise invalid("bridge.missing_field")
        end

        validate_schema_version!(document.fetch("schema_version"))
        artifact_type = document.fetch("artifact_type")
        unless SUPPORTED_TYPES.include?(artifact_type)
          raise invalid("bridge.unknown_type")
        end
        if artifact_type != expected_type.to_s
          raise invalid("bridge.type_mismatch", "Unexpected artifact type")
        end

        if document.fetch("run_id") != expected_run_id.to_s
          raise invalid("bridge.run_mismatch", "Unexpected run ID")
        end

        validate_created_at!(document.fetch("created_at"))
        digest = document.fetch("payload_sha256")
        unless digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)
          raise invalid("bridge.payload_hash_mismatch", "Invalid payload fingerprint")
        end

        actual_digest = CanonicalJSON.sha256(document.fetch("payload"))
        unless digest == actual_digest
          raise invalid("bridge.payload_hash_mismatch", "Payload fingerprint does not match payload")
        end

        document.fetch("payload")
      rescue KeyError
        raise invalid("bridge.missing_field")
      end

      def validate_schema_version!(version)
        match = version.is_a?(String) && version.match(/\A(0|[1-9]\d*)\.(0|[1-9]\d*)\z/)
        unless match && match[1].to_i == SUPPORTED_SCHEMA_MAJOR && match[2].to_i <= SUPPORTED_SCHEMA_MINOR
          raise invalid("bridge.unsupported_version")
        end
      end
      private_class_method :validate_schema_version!

      def validate_created_at!(value)
        unless value.is_a?(String)
          raise invalid("bridge.invalid_created_at", "created_at must be RFC 3339 text")
        end

        time = Time.iso8601(value)
        unless time.utc.iso8601 == value
          raise invalid("bridge.invalid_created_at")
        end
      rescue ArgumentError
        raise invalid("bridge.invalid_created_at")
      end
      private_class_method :validate_created_at!

      def normalize_created_at(value)
        time = case value
               when Time then value
               when String then Time.iso8601(value)
               else
                 raise ArgumentError, "created_at must be a Time or RFC 3339 string"
               end
        time.utc.iso8601
      rescue ArgumentError
        raise invalid("bridge.invalid_created_at")
      end
      private_class_method :normalize_created_at

      def invalid(code, _message = nil)
        Cyborg::InvalidArtifact.new(code, code, exit_status: 65)
      end
      private_class_method :invalid
    end
  end
end
