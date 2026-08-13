# frozen_string_literal: true

require_relative "../domain"
require "time"

module Cyborg
  module Repositories
    class Base
      CANONICAL_UTC_TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/.freeze

      attr_reader :db

      def initialize(db)
        @db = db
      end

      private

      def row(dataset, key)
        dataset.where(id: key).first
      end

      def values_for(type, attributes)
        type.members.each_with_object({}) do |member, values|
          values[member] = attributes[member] if attributes.key?(member)
        end
      end

      def value(type, attributes)
        Domain.from_row(type, attributes)
      end

      def validate_timestamps!(attributes, fields = nil)
        selected = fields || attributes.keys
        selected.each do |field|
          next unless attributes.key?(field)

          validate_timestamp!(attributes[field], field: field)
        end
        attributes
      end

      def validate_timestamp!(timestamp, field:)
        return nil if timestamp.nil?

        valid = timestamp.is_a?(String) && CANONICAL_UTC_TIMESTAMP.match?(timestamp) && Time.iso8601(timestamp).utc.iso8601 == timestamp
        return timestamp if valid

        raise Cyborg::PersistenceError.new("database.invalid_timestamp", "#{field} must be a canonical UTC RFC3339 timestamp")
      rescue ArgumentError
        raise Cyborg::PersistenceError.new("database.invalid_timestamp", "#{field} must be a canonical UTC RFC3339 timestamp")
      end
    end
  end
end
