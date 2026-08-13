# frozen_string_literal: true

require "json"
require "time"

module Cyborg
  module Pipeline
    module Support
      module_function

      def value(object, key, default = nil)
        if object.is_a?(Hash)
          return object[key] if object.key?(key)
          return object[key.to_s] if object.key?(key.to_s)
          return object[key.to_sym] if object.key?(key.to_sym)
        elsif object.respond_to?(key)
          return object.public_send(key)
        end
        default
      end

      def hash_value(object, *keys)
        keys.each do |key|
          result = value(object, key)
          return result unless result.nil?
        end
        nil
      end

      def as_hash(object)
        result = object.respond_to?(:to_h) ? object.to_h : object
        result.is_a?(Hash) ? result.each_with_object({}) { |(k, v), h| h[k.to_s] = v } : {}
      end

      def structured_fields(record)
        fields = hash_value(record, :structured_fields, :structured_fields_json)
        fields = JSON.parse(fields) if fields.is_a?(String)
        fields.is_a?(Hash) ? fields : {}
      rescue JSON::ParserError
        {}
      end

      def canonical_time(value)
        return nil if value.nil? || value.to_s.empty?
        (value.respond_to?(:utc) ? value.utc : Time.iso8601(value.to_s).utc).iso8601
      rescue ArgumentError, TypeError
        nil
      end

      def selected_time(record)
        canonical_time(hash_value(record, :latest_reply_at)) || canonical_time(hash_value(record, :event_at)) || canonical_time(hash_value(record, :observed_at))
      end

      def source_name(record) = hash_value(record, :source_name).to_s
      def account_identity(record) = hash_value(record, :account_identity).to_s
      def record_kind(record) = hash_value(record, :record_kind).to_s
      def source_record_id(record) = hash_value(record, :source_record_id, :id).to_s
      def fingerprint(record) = hash_value(record, :content_fingerprint).to_s
      def nonempty(value) = !value.nil? && !value.to_s.empty?

      def bounded_string(value, bytes)
        text = value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
        text.bytesize <= bytes ? text : text.byteslice(0, bytes).to_s.force_encoding(Encoding::UTF_8).scrub
      end

      def normalize_values(value)
        Array(value).map { |item| item.to_s.downcase.strip }.reject(&:empty?).uniq.sort
      end
    end
  end
end
