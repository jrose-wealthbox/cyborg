# frozen_string_literal: true

require_relative "../../test_helper"

class CyborgAnalysisTaskGraphTest < Minitest::Test
  def test_tasks_are_immutable_and_use_abstract_capabilities
    task = task(id: "extract", capability: "cheap_structured_extraction")

    assert_predicate task, :frozen?
    assert_predicate task.dependency_ids, :frozen?
    assert_predicate task.reservation, :frozen?
    assert_raises(FrozenError) { task.capability.replace("gpt-4o") }
    assert_raises(ArgumentError) { Cyborg::Analysis::AnalysisTask.new(**task.to_h.merge(capability: "gpt-4o")) }
  end

  def test_graph_rejects_unknown_dependencies_and_cycles
    assert_raises(ArgumentError) do
      Cyborg::Analysis::TaskGraph.new(tasks: [task(id: "child", dependency_ids: ["missing"])])
    end

    first = task(id: "first", dependency_ids: ["second"])
    second = task(id: "second", dependency_ids: ["first"])
    error = assert_raises(ArgumentError) { Cyborg::Analysis::TaskGraph.new(tasks: [first, second]) }
    assert_match(/cycle/i, error.message)
  end

  def test_graph_reports_only_dependency_ready_tasks
    first = task(id: "first")
    second = task(id: "second", dependency_ids: ["first"])
    third = task(id: "third", dependency_ids: ["first", "second"])
    graph = Cyborg::Analysis::TaskGraph.new(tasks: [third, second, first])

    assert_equal ["first"], graph.ready_tasks.map(&:id)
    assert_equal ["second"], graph.ready_tasks(completed_ids: ["first"]).map(&:id)
    assert_equal ["third"], graph.ready_tasks(completed_ids: %w[first second]).map(&:id)
    assert_empty graph.ready_tasks(completed_ids: ["first"], launched_ids: ["second"])
  end

  def test_task_rejects_non_positive_output_bound_and_invalid_reservation
    assert_raises(ArgumentError) { task(maximum_output_bytes: 0) }
    assert_raises(ArgumentError) { task(reservation: {cost_micros: -1}) }
    assert_raises(ArgumentError) { task(packet_fingerprint: "") }
  end

  def test_reservation_derives_and_validates_integer_micro_cost
    derived = Cyborg::Analysis::Reservation.new(
      input_tokens: 10, output_tokens: 4,
      input_micros_per_token: 100, output_micros_per_token: 200
    )
    assert_equal 1_800, derived.cost_micros

    assert_raises(ArgumentError) do
      Cyborg::Analysis::Reservation.new(
        cost_micros: 1, input_tokens: 10, output_tokens: 4,
        input_micros_per_token: 100, output_micros_per_token: 200
      )
    end
  end

  private

  def task(id: "task", capability: "medium_reasoning", dependency_ids: [], required: true,
           packet_fingerprint: "packet-fingerprint", maximum_output_bytes: 1_024,
           reservation: {cost_micros: 1_000})
    Cyborg::Analysis::AnalysisTask.new(
      id:, capability:, dependency_ids:, required:, packet_fingerprint:,
      maximum_output_bytes:, reservation:
    )
  end
end
