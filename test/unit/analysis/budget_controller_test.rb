# frozen_string_literal: true

require_relative "../../test_helper"

class CyborgAnalysisBudgetControllerTest < Minitest::Test
  def setup
    @controller = Cyborg::Analysis::BudgetController.new
  end

  def test_required_tasks_reserve_before_optional_tasks
    optional = task(id: "optional-reflection", required: false, cost_micros: 4_000_000)
    required = task(id: "required-extraction", required: true, cost_micros: 2_000_000)

    plan = @controller.reserve(tasks: [optional, required], ceiling_micros: 5_000_000)

    assert_equal ["required-extraction"], plan.launchable_required.map(&:task_id)
    assert_equal "skipped_budget", plan.status_for("optional-reflection")
    assert_equal 2_000_000, plan.reserved_micros
  end

  def test_no_new_task_launches_at_reserved_plus_reported_ceiling
    task = task(id: "another", cost_micros: 1_000_000)
    plan = @controller.reserve(tasks: [task], ceiling_micros: 5_000_000)
    plan = plan.with_reported_micros(4_000_000)

    refute @controller.allow_launch?(plan, task: task)
  end

  def test_releases_unused_reservation_and_allows_later_reserved_work
    first = task(id: "first", cost_micros: 4_000_000)
    second = task(id: "second", required: false, cost_micros: 2_000_000)
    plan = @controller.reserve(tasks: [first, second], ceiling_micros: 5_000_000)

    assert_equal "skipped_budget", plan.status_for("second")
    plan = plan.release("first")
    plan = @controller.reserve_into(plan, tasks: [second])

    assert_equal "reserved", plan.status_for("second")
    assert_equal 2_000_000, plan.reserved_micros
  end

  def test_stale_price_catalog_is_a_warning
    catalog = Cyborg::Analysis::PriceCatalog.new(
      provider: "fixture", model: "fixture-model", input_micros_per_token: 1,
      output_micros_per_token: 2, last_verified_at: Time.utc(2026, 8, 1)
    )
    controller = Cyborg::Analysis::BudgetController.new(
      price_catalog: catalog, now: Time.utc(2026, 8, 13)
    )

    plan = controller.reserve(tasks: [task], ceiling_micros: 5_000_000)

    assert_includes plan.warnings, "analysis.stale_price_catalog"
  end

  def test_allow_launch_rejects_unreserved_or_changed_tasks
    original = task(id: "task", cost_micros: 1_000)
    plan = @controller.reserve(tasks: [original], ceiling_micros: 5_000_000)

    refute @controller.allow_launch?(plan, task: task(id: "invented"))
    refute @controller.allow_launch?(plan, task: task(id: "task", cost_micros: 2_000))
    assert @controller.allow_launch?(plan, task: original)
  end

  private

  def task(id: "task", required: true, cost_micros: 1_000)
    Cyborg::Analysis::AnalysisTask.new(
      id:, capability: "cheap_structured_extraction", dependency_ids: [], required:,
      packet_fingerprint: "packet", maximum_output_bytes: 512,
      reservation: {cost_micros: cost_micros}
    )
  end
end
