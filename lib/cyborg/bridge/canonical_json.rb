# frozen_string_literal: true

require "digest"
require "json"
require "time"

module Cyborg
  module Bridge
    # A compact, deterministic JSON representation used for artifact and cache
    # fingerprints. Hash keys are normalized recursively while array order is
    # intentionally left untouched.
    module CanonicalJSON
      module_function

      def dump(value)
        JSON.generate(normalize(value), ascii_only: false)
      rescue JSON::GeneratorError, EncodingError => error
        raise Cyborg::InvalidArtifact.new("bridge.invalid_json", error.message, exit_status: 65)
      end

      def sha256(value)
        Digest::SHA256.hexdigest(dump(value).encode(Encoding::UTF_8))
      end

      def normalize(value)
        case value
        when Hash
          normalized = value.each_with_object({}) do |(key, item), result|
            normalized_key = normalize_key(key)
            if result.key?(normalized_key)
              raise Cyborg::InvalidArtifact.new("bridge.duplicate_key", exit_status: 65)
            end

            result[normalized_key] = normalize(item)
          end
          normalized.sort_by { |key, _item| key }.to_h
        when Array
          value.map { |item| normalize(item) }
        when Time
          value.utc.iso8601
        when Float
          unless value.finite?
            raise Cyborg::InvalidArtifact.new("bridge.non_finite_number", exit_status: 65)
          end

          value
        when String
          value.encode(Encoding::UTF_8)
        when NilClass, TrueClass, FalseClass, Integer
          value
        else
          raise Cyborg::InvalidArtifact.new("bridge.invalid_json_value", exit_status: 65)
        end
      end

      def normalize_key(key)
        case key
        when String, Symbol
          key.to_s.encode(Encoding::UTF_8)
        else
          key.to_s.encode(Encoding::UTF_8)
        end
      rescue EncodingError => error
        raise Cyborg::InvalidArtifact.new("bridge.invalid_json_key", error.message, exit_status: 65)
      end
      private_class_method :normalize_key
    end
  end
end
