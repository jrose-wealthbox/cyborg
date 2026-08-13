# frozen_string_literal: true

require "time"

module Cyborg
  class CachePolicy
    CACHE_CLASSES = %w[ordinary expensive].freeze

    def initialize(ordinary_ttl_seconds:, expensive_ttl_seconds:)
      @ttls = {"ordinary" => Integer(ordinary_ttl_seconds), "expensive" => Integer(expensive_ttl_seconds)}
      raise ArgumentError, "cache TTLs must be non-negative" if @ttls.values.any?(&:negative?)
      freeze
    end

    def ttl(cache_class)
      @ttls.fetch(cache_class.to_s) { raise ArgumentError, "unsupported cache class" }
    end

    def expires_at(cache_class:, now:)
      timestamp = now.respond_to?(:to_time) ? now.to_time : Time.iso8601(now.to_s)
      (timestamp.utc + ttl(cache_class)).iso8601
    end

    def invalidate(repository:, stage:, cache_key:, invalidated_at:, command:, run_id: nil, reason:)
      repository.invalidate(stage:, cache_key:, invalidated_at:, command:, run_id:, reason:)
    end
  end
end
