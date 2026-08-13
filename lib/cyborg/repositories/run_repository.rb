# frozen_string_literal: true

require_relative "base"

module Cyborg
  module Repositories
    class RunRepository < Base
      TABLE = :runs

      def create(attributes = nil, **options)
        attrs = (attributes || options).to_h
        db[TABLE].insert(attrs)
        find(attrs.fetch(:id))
      end

      def find(id)
        value(Run, row(db[TABLE], id))
      end

      def update(id, attributes)
        db[TABLE].where(id:).update(attributes)
        find(id)
      end

      def update_status(id:, status:, completed_at: nil, usage_summary_json: nil)
        update(id, status:, completed_at:, usage_summary_json:)
      end

      def all(status: nil)
        dataset = db[TABLE].order(:created_at)
        dataset = dataset.where(status:) if status
        dataset.all.map { |record| value(Run, record) }
      end

      def latest_renderable
        pointer = db[:application_state].where(key: "latest_renderable_run_id").get(:value)
        pointer && find(pointer)
      end

      alias latest_renderable_run latest_renderable

      def latest_renderable_id
        db[:application_state].where(key: "latest_renderable_run_id").get(:value)
      end

      def set_latest_renderable!(run_id:, updated_at:)
        db[:application_state].insert_conflict(target: :key, update: {value: run_id, updated_at:}).insert(
          key: "latest_renderable_run_id", value: run_id, updated_at:
        )
        find(run_id)
      end
    end
  end
end
