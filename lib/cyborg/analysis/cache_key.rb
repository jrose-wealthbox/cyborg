# frozen_string_literal: true

require "digest"
require_relative "../bridge/canonical_json"

module Cyborg
  module CacheKey
    module_function

    def call(stage:, input:, implementation_version:, config_fingerprint:, adapter_versions:, prompt_version:, backend_identity:)
      payload = {
        "stage" => stage.to_s, "input" => normalize(input), "implementation_version" => implementation_version.to_s,
        "config_fingerprint" => config_fingerprint.to_s, "adapter_versions" => normalize(adapter_versions),
        "prompt_version" => prompt_version.to_s, "backend_identity" => backend_identity.to_s
      }
      Bridge::CanonicalJSON.sha256(payload)
    end

    def normalize(value, key = nil)
      value = value.to_h if value.respond_to?(:members) && value.respond_to?(:to_h)
      case value
      when Hash
        value.each_with_object({}) do |(raw_key, item), result|
          name = raw_key.to_s
          next if %w[snapshot_id snapshot_ids].include?(name)

          result[name] = normalize(item, name)
        end
      when Array
        values = value.map { |item| normalize(item) }
        if key == "records" || values.all? { |item| item.is_a?(Hash) && item.key?("content_fingerprint") }
          values.sort_by { |item| [item.is_a?(Hash) ? item.fetch("content_fingerprint", "") : "", Bridge::CanonicalJSON.dump(item)] }
        else
          values
        end
      else
        value
      end
    end
  end
end
