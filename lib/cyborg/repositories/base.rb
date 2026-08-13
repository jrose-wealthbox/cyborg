# frozen_string_literal: true

require_relative "../domain"

module Cyborg
  module Repositories
    class Base
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
    end
  end
end
