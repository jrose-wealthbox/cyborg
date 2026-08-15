# frozen_string_literal: true

require "json"
require "securerandom"
require "time"
require_relative "cache_key"
require_relative "cache_policy"
require_relative "../repositories/cache_repository"
require_relative "../pipeline/analysis_packet_builder"

module Cyborg
  module Analysis
    # Persistent cache for complete, validated host-bridge analysis results.
    # The packet fingerprint is deliberately independent of a run's identity,
    # while every stored value is only the bounded analysis result payload.
    class BridgeCache
      STAGE = "bridge_analysis".freeze
      CACHE_CLASS = "expensive".freeze
      RUN_SCOPED_FIELDS = %w[run_id created_at].freeze

      def initialize(db:, expensive_ttl_seconds:, repository: nil, policy: nil)
        @repository = repository || Repositories::CacheRepository.new(db)
        @policy = policy || CachePolicy.new(
          ordinary_ttl_seconds: 0, expensive_ttl_seconds:
        )
      end

      def fetch(packet:, backend_identity:, now:)
        key = cache_key(packet:, backend_identity:)
        row = @repository.fetch(stage: STAGE, cache_key: key, now:)
        return nil unless row && row[:cache_class].to_s == CACHE_CLASS
        return nil unless row[:input_fingerprint].to_s == input_fingerprint(packet)

        payload = row[:payload]
        payload.is_a?(Hash) ? payload : nil
      rescue JSON::ParserError, KeyError, TypeError, ArgumentError
        nil
      end

      def store(packet:, result:, backend_identity:, run_id:, now:)
        raise ArgumentError, "packet must be a Hash" unless packet.is_a?(Hash)
        raise ArgumentError, "result must be a Hash" unless result.is_a?(Hash)
        raise ArgumentError, "run_id must be a nonblank String" unless run_id.is_a?(String) && !run_id.strip.empty?

        timestamp = canonical_time(now)
        @repository.store(
          id: SecureRandom.uuid,
          stage: STAGE,
          cache_key: cache_key(packet:, backend_identity:),
          cache_class: CACHE_CLASS,
          input_fingerprint: input_fingerprint(packet),
          source_versions_json: Bridge::CanonicalJSON.dump(packet.fetch("versions")),
          configuration_fingerprint: packet.fetch("configuration_version").to_s,
          model_identity: backend_identity.to_s,
          created_at: timestamp,
          expires_at: @policy.expires_at(cache_class: CACHE_CLASS, now: timestamp),
          invalidated_at: nil, invalidation_command: nil, invalidation_run_id: nil, invalidation_reason: nil,
          payload: result
        )
        true
      end

      private

      def cache_key(packet:, backend_identity:)
        CacheKey.call(
          stage: STAGE,
          input: reusable_packet(packet),
          implementation_version: Pipeline::AnalysisPacketBuilder::VERSION,
          config_fingerprint: packet.fetch("configuration_version"),
          adapter_versions: packet.fetch("versions"),
          prompt_version: packet.fetch("prompt_version"),
          backend_identity:
        )
      end

      def input_fingerprint(packet)
        Bridge::CanonicalJSON.sha256(CacheKey.normalize(reusable_packet(packet)))
      end

      def reusable_packet(packet)
        unless packet.is_a?(Hash)
          raise ArgumentError, "packet must be a Hash"
        end

        packet.each_with_object({}) do |(key, value), result|
          result[key.to_s] = value unless RUN_SCOPED_FIELDS.include?(key.to_s)
        end
      end

      def canonical_time(value)
        timestamp = value.respond_to?(:to_time) ? value.to_time : Time.iso8601(value.to_s)
        timestamp.utc.iso8601
      rescue ArgumentError, TypeError
        raise ArgumentError, "now must be a Time or RFC 3339 timestamp"
      end
    end
  end
end
