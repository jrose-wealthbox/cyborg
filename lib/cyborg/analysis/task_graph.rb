# frozen_string_literal: true

require_relative "contracts"
require "set"

module Cyborg
  module Analysis
    class TaskGraph
      attr_reader :tasks

      def initialize(tasks:)
        values = Array(tasks)
        unless values.all? { |task| task.is_a?(AnalysisTask) }
          raise ArgumentError, "tasks must contain AnalysisTask values"
        end
        if values.map(&:id).uniq.length != values.length
          raise ArgumentError, "task IDs must be unique"
        end

        @tasks = values.sort_by(&:id).freeze
        @by_id = @tasks.to_h { |task| [task.id, task] }.freeze
        validate_dependencies!
        freeze
      end

      def task(id)
        @by_id[id.to_s]
      end

      def ready_tasks(completed_ids: [], launched_ids: [])
        completed = Array(completed_ids).map(&:to_s).to_h { |id| [id, true] }
        launched = Array(launched_ids).map(&:to_s).to_h { |id| [id, true] }
        @tasks.select do |task|
          !completed.key?(task.id) && !launched.key?(task.id) &&
            task.dependency_ids.all? { |dependency_id| completed.key?(dependency_id) }
        end
      end

      alias ready ready_tasks

      def dependency_ready?(task_or_id, completed_ids: [])
        value = task_or_id.is_a?(AnalysisTask) ? task_or_id : task(task_or_id)
        return false unless value && (@by_id[value.id].equal?(value) || @by_id[value.id] == value)

        Array(completed_ids).map(&:to_s).to_set.superset?(value.dependency_ids.to_set)
      end

      private

      def validate_dependencies!
        @tasks.each do |task|
          unknown = task.dependency_ids - @by_id.keys
          raise ArgumentError, "task #{task.id} has unknown dependency #{unknown.first}" unless unknown.empty?
          raise ArgumentError, "task #{task.id} cannot depend on itself" if task.dependency_ids.include?(task.id)
        end

        visiting = {}
        visited = {}
        @tasks.each { |task| visit(task.id, visiting, visited) }
      end

      def visit(id, visiting, visited)
        return if visited[id]
        raise ArgumentError, "task dependency cycle detected at #{id}" if visiting[id]

        visiting[id] = true
        task(id).dependency_ids.each { |dependency_id| visit(dependency_id, visiting, visited) }
        visiting.delete(id)
        visited[id] = true
      end
    end
  end
end
