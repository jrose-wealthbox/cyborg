# frozen_string_literal: true

require_relative "base"

module Cyborg
  module Repositories
    class PresentationRepository < Base
      def create(attributes)
        attrs = attributes.to_h
        db[:presentation_results].insert(attrs)
        find(attrs.fetch(:id))
      end

      def find(id)
        value(PresentationResult, row(db[:presentation_results], id))
      end

      def for_run(run_id:, profile: nil)
        dataset = db[:presentation_results].where(run_id:)
        dataset = dataset.where(profile:) if profile
        dataset.all.map { |record| value(PresentationResult, record) }
      end

      def latest(profile:)
        record = db[:presentation_results].where(profile:).order(Sequel.desc(:created_at)).first
        value(PresentationResult, record)
      end
    end
  end
end
