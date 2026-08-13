# frozen_string_literal: true

require_relative "base"
require "json"

module Cyborg
  module Repositories
    class CacheRepository < Base
      def fetch(stage:, cache_key:, now:)
        now = now.utc.iso8601 if now.respond_to?(:utc)
        record = db[:cache_entries].where(stage:, cache_key:).where { expires_at > now }.where(invalidated_at: nil).first
        record && record.merge(payload: JSON.parse(record.fetch(:payload_json)))
      end

      def store(attributes)
        attrs = attributes.to_h
        payload = attrs.delete(:payload)
        attrs[:payload_json] ||= JSON.generate(payload) if payload
        db[:cache_entries].insert_conflict(
          target: %i[stage cache_key],
          update: attrs.reject { |key, _| %i[stage cache_key].include?(key) }
        ).insert(attrs)
        db[:cache_entries].where(stage: attrs.fetch(:stage), cache_key: attrs.fetch(:cache_key)).first
      end

      def invalidate(stage:, cache_key:, invalidated_at:, reason:)
        db[:cache_entries].where(stage:, cache_key:).update(invalidated_at:, invalidation_reason: reason)
        true
      end
    end
  end
end
