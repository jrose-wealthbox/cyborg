# frozen_string_literal: true

require_relative "base"
require "json"

module Cyborg
  module Repositories
    class CacheRepository < Base
      def fetch(stage:, cache_key:, now:)
        validate_timestamp!(now.respond_to?(:utc) ? now.utc.iso8601 : now, field: :now)
        now = now.utc.iso8601 if now.respond_to?(:utc)
        record = db[:cache_entries].where(stage:, cache_key:).where { expires_at > now }.where(invalidated_at: nil).first
        record && record.merge(payload: JSON.parse(record.fetch(:payload_json)))
      end

      def find(stage:, cache_key:)
        db[:cache_entries].where(stage:, cache_key:).first
      end

      def store(attributes)
        attrs = attributes.to_h
        validate_timestamps!(attrs, %i[created_at expires_at invalidated_at])
        payload = attrs.delete(:payload)
        attrs[:payload_json] ||= JSON.generate(payload) if payload
        db[:cache_entries].insert_conflict(
          target: %i[stage cache_key],
          update: attrs.reject { |key, _| %i[stage cache_key].include?(key) }
        ).insert(attrs)
        db[:cache_entries].where(stage: attrs.fetch(:stage), cache_key: attrs.fetch(:cache_key)).first
      end

      def invalidate(classes: nil, stage: nil, cache_key: nil, invalidated_at:, command:, run_id: nil, reason:)
        validate_timestamp!(invalidated_at, field: :invalidated_at)
        dataset = db[:cache_entries]
        dataset = dataset.where(stage:) unless stage.nil?
        dataset = dataset.where(cache_key:) unless cache_key.nil?
        unless classes.nil?
          values = Array(classes).map(&:to_s)
          unless values.length.positive? && values.all? { |value| %w[ordinary expensive].include?(value) }
            raise ArgumentError, "unsupported cache class selection"
          end
          dataset = dataset.where(cache_class: values.uniq)
        end
        dataset.update(
          invalidated_at:, invalidation_command: command, invalidation_run_id: run_id, invalidation_reason: reason
        )
        true
      end
    end
  end
end
