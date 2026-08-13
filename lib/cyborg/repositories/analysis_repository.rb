# frozen_string_literal: true

require_relative "base"

module Cyborg
  module Repositories
    class AnalysisRepository < Base
      def create(attributes)
        attrs = attributes.to_h
        db[:analysis_results].insert(attrs)
        find(attrs.fetch(:id))
      end

      def find(id)
        db[:analysis_results].where(id:).first
      end

      def for_run(run_id)
        db[:analysis_results].where(run_id:).order(:task_id).all
      end

      def find_cached(task_id:, input_fingerprint:)
        db[:analysis_results].where(task_id:, input_fingerprint:, validation_status: "valid").first
      end
    end
  end
end
