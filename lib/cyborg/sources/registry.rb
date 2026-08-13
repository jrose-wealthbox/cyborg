# frozen_string_literal: true

require_relative "contracts"

module Cyborg
  # Converts resolved source configuration into explicit immutable runtime
  # registrations. Discovery and configuration are intentionally separate:
  # only entries marked enabled are returned to callers.
  class SourceRegistry
    DEFAULTS = {
      "github" => {
        "capabilities" => ["notifications"],
        "operations" => {"notifications" => "github.notifications.read"}
      },
      "local_git" => {
        "capabilities" => ["authored_activity"],
        "operations" => {"authored_activity" => "local_git.activity.read"}
      },
      "git" => {
        "capabilities" => ["authored_activity"],
        "operations" => {"authored_activity" => "local_git.activity.read"}
      }
    }.freeze

    class << self
      def enabled(config)
        new.enabled(config)
      end
    end

    def enabled(config)
      sources = config.respond_to?(:sources) ? config.sources : config
      return [] unless sources.respond_to?(:each)

      sources.each_with_object([]) do |(name, source), result|
        attributes = attributes_for(name, source)
        next unless truthy?(attributes["enabled"])

        result << Registration.new(
          source_name: name.to_s,
          adapter_version: attributes["adapter_version"] || "#{attributes.fetch("adapter", name)}-1",
          account_identity: attributes["account"]&.to_s,
          transport: attributes["transport"] || "direct",
          capabilities: Array(attributes["capabilities"] || defaults_for(attributes)["capabilities"]).map(&:to_s),
          filters: stringify(attributes["filters"] || {}),
          limits: normalize_limits(attributes["limits"] || {}),
          credential_strategy: attributes["credential_strategy"] || "external",
          health_checks: Array(attributes["health_checks"] || []).map(&:to_s),
          cursor_policy: attributes["cursor_policy"] || "proposed",
          cache_policy: attributes["cache_policy"] || "ordinary",
          retention_class: attributes["retention_class"] || "standard",
          allowed_fields: Array(attributes["allowed_fields"] || []).map(&:to_s),
          operations: stringify(attributes["operations"] || defaults_for(attributes)["operations"] || {}),
          parameters: stringify(attributes["parameters"] || {}),
          required: truthy?(attributes["required"]),
          enabled: true
        )
      end
    end

    private

    def attributes_for(name, source)
      raw = if source.respond_to?(:to_h)
        source.to_h
      elsif source.is_a?(Hash)
        source
      else
        {}
      end
      raw = stringify(raw)
      raw["name"] ||= name.to_s
      raw["adapter"] ||= name.to_s
      raw["enabled"] = source.enabled if source.respond_to?(:enabled) && !raw.key?("enabled")
      raw["account"] = source.account if source.respond_to?(:account) && !raw.key?("account")
      raw["filters"] = source.filters if source.respond_to?(:filters) && !raw.key?("filters")
      raw["limits"] = source.limits if source.respond_to?(:limits) && !raw.key?("limits")
      raw["required"] = source.required if source.respond_to?(:required) && !raw.key?("required")
      raw
    end

    def defaults_for(attributes)
      DEFAULTS.fetch(attributes.fetch("adapter"), {"capabilities" => ["records"], "operations" => {"records" => "#{attributes.fetch("adapter")}.records.read"}})
    end

    def normalize_limits(value)
      stringify(value).each_with_object({}) do |(key, limit), result|
        integer = Integer(limit)
        raise ArgumentError, "source limits must be non-negative" if integer.negative?

        result[key] = integer
      rescue ArgumentError, TypeError
        raise ArgumentError, "source limits must be non-negative integers"
      end
    end

    def stringify(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), result| result[key.to_s] = stringify(item) }
      when Array
        value.map { |item| stringify(item) }
      else
        value
      end
    end

    def truthy?(value)
      value == true || %w[true yes on 1].include?(value.to_s.downcase)
    end
  end
end
