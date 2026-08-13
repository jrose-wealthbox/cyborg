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

    def invalidate(repository:, classes:, invalidated_at:, command:, run_id: nil, reason:, stage: nil, cache_key: nil)
      selected = normalize_classes(classes)
      repository.invalidate(
        classes: selected, stage:, cache_key:, invalidated_at:, command:, run_id:, reason:
      )
    end

    private

    def normalize_classes(classes)
      values = case classes.to_s
      when "full" then CACHE_CLASSES
      when "ordinary", "expensive" then [classes.to_s]
      else Array(classes).map(&:to_s)
      end
      values = CACHE_CLASSES if values.sort == CACHE_CLASSES.sort
      unless values.length.positive? && values.all? { |value| CACHE_CLASSES.include?(value) }
        raise ArgumentError, "unsupported cache class selection"
      end
      values.uniq
    end
  end
end
