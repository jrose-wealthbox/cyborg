# frozen_string_literal: true

require_relative "contracts"
require_relative "task_graph"

module Cyborg
  module Analysis
    # A functional reservation ledger. Each operation returns a new frozen
    # plan so a caller can retain the exact pre-launch state for audit.
    class ReservationPlan
      attr_reader :ceiling_micros, :entries, :reported_micros, :released_micros, :warnings

      def initialize(ceiling_micros:, entries: {}, tasks: {}, reported_micros: 0,
                     released_micros: 0, warnings: [], reserved_micros: nil)
        @ceiling_micros = Contracts.strict_integer(ceiling_micros, "ceiling_micros")
        @reported_micros = Contracts.strict_integer(reported_micros, "reported_micros")
        @released_micros = Contracts.strict_integer(released_micros, "released_micros")
        @entries = entries.each_with_object({}) do |(id, entry), result|
          result[id.to_s] = entry.is_a?(ReservationEntry) ? entry : ReservationEntry.new(**entry.to_h.transform_keys(&:to_sym))
        end
        @tasks = tasks.transform_keys(&:to_s).freeze
        @warnings = Array(warnings).map(&:to_s).uniq.sort.freeze
        @reserved_override = reserved_micros.nil? ? nil : Contracts.strict_integer(reserved_micros, "reserved_micros")
        @entries.freeze
        freeze
      end

      def reserved_micros
        @reserved_override || @entries.values.select(&:reserved?).sum(&:reserved_micros)
      end

      def spent_micros
        reported_micros
      end

      def committed_micros
        reserved_micros + reported_micros
      end

      def remaining_micros
        [ceiling_micros - committed_micros, 0].max
      end

      def status_for(task_id)
        entry = @entries[task_id.to_s]
        entry&.status
      end

      def reason_for(task_id)
        entry = @entries[task_id.to_s]
        entry&.reason
      end

      def reservation_for(task_id)
        @entries[task_id.to_s]&.reserved_micros
      end

      def task_for(task_id)
        @tasks[task_id.to_s]
      end

      def launchable_required
        launchable(required: true)
      end

      def launchable_optional
        launchable(required: false)
      end

      def skipped(task_id)
        status_for(task_id.to_s) == "skipped_budget"
      end

      def reserve(task)
        existing = @entries[task.id]
        raise ArgumentError, "task is already present in reservation plan" if existing&.reserved?

        entry = ReservationEntry.new(task_id: task.id, reserved_micros: task.reservation.cost_micros, status: "reserved")
        self.class.new(
          ceiling_micros:, entries: @entries.merge(task.id => entry), tasks: @tasks.merge(task.id => task),
          reported_micros:, released_micros:, warnings:
        )
      end

      def skip(task, reason = "budget.insufficient")
        raise ArgumentError, "task is already present in reservation plan" if @entries[task.id]&.reserved?

        entry = ReservationEntry.new(task_id: task.id, reserved_micros: 0, status: "skipped_budget", reason:)
        self.class.new(
          ceiling_micros:, entries: @entries.merge(task.id => entry), tasks: @tasks.merge(task.id => task),
          reported_micros:, released_micros:, warnings:
        )
      end

      def release(task_or_id)
        id = task_or_id.respond_to?(:id) ? task_or_id.id : task_or_id.to_s
        entry = @entries[id]
        return self unless entry&.reserved?

        released = entry.reserved_micros
        updated = ReservationEntry.new(task_id: id, reserved_micros: 0, status: "released", reason: "reservation.released")
        self.class.new(
          ceiling_micros:, entries: @entries.merge(id => updated), tasks: @tasks, reported_micros:,
          released_micros: released_micros + released, warnings:
        )
      end

      alias release_reservation release

      def with_reported_micros(amount)
        amount = Contracts.strict_integer(amount, "reported_micros")
        self.class.new(
          ceiling_micros:, entries:, tasks: @tasks, reported_micros: amount,
          released_micros:, warnings:
        )
      end

      def add_reported_micros(amount)
        with_reported_micros(reported_micros + Contracts.strict_integer(amount, "reported_micros"))
      end

      private

      def launchable(required:)
        @entries.values.filter_map do |entry|
          task = @tasks[entry.task_id]
          task if task && entry.reserved? && task.required == required
        end.sort_by(&:id)
      end
    end

    class BudgetController
      DEFAULT_CEILING_MICROS = Analysis::DEFAULT_CEILING_MICROS
      attr_reader :price_catalog, :now

      def initialize(price_catalog: nil, now: Time.now.utc, stale_after_seconds: PRICE_CATALOG_MAX_AGE_SECONDS)
        @price_catalog = price_catalog
        @now = Contracts.canonical_time(now, "now")
        @stale_after_seconds = Contracts.strict_integer(stale_after_seconds, "stale_after_seconds", minimum: 1)
      end

      def reserve(tasks:, ceiling_micros: DEFAULT_CEILING_MICROS)
        tasks = validate_tasks(tasks)
        plan = ReservationPlan.new(
          ceiling_micros:, warnings: catalog_warnings
        )
        reserve_into(plan, tasks:)
      end

      def reserve_into(plan, tasks:)
        unless plan.is_a?(ReservationPlan)
          raise ArgumentError, "plan must be a ReservationPlan"
        end

        ordered = validate_tasks(tasks).sort_by { |task| [task.required ? 0 : 1, task.id] }
        ordered.reduce(plan) do |current, task|
          next current if current.status_for(task.id) == "reserved"

          if current.remaining_micros >= task.reservation.cost_micros
            current.reserve(task)
          else
            current.skip(task)
          end
        end
      end

      def allow_launch?(reservation_plan, task:)
        return false unless reservation_plan.is_a?(ReservationPlan) && task.is_a?(AnalysisTask)
        return false unless reservation_plan.status_for(task.id) == "reserved"
        return false unless reservation_plan.task_for(task.id) == task

        reservation_plan.committed_micros < reservation_plan.ceiling_micros
      end

      def release(reservation_plan, task:)
        reservation_plan.release(task)
      end

      private

      def validate_tasks(tasks)
        values = Array(tasks)
        TaskGraph.new(tasks: values)
        values
      end

      def catalog_warnings
        return [] unless price_catalog

        price_catalog.stale?(now:, max_age_seconds: @stale_after_seconds) ? ["analysis.stale_price_catalog"] : []
      end
    end
  end
end
