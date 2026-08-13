# frozen_string_literal: true

require_relative "../../test_helper"

class CyborgAnalysisFixtureBackendTest < Minitest::Test
  def test_reads_recorded_structured_result_without_network_access
    backend = Cyborg::Analysis::FixtureBackend.new(
      path: File.expand_path("../../fixtures/bridge/analysis-result-valid.json", __dir__)
    )
    outcome = backend.analyze(packet: {"run_id" => "018f5f62-3ef4-7d31-9e6d-8f6dfeddb847"}, task: task, reservation: task.reservation)

    assert_equal [], outcome.claims
    assert_equal "fixture", outcome.backend_metadata.fetch("backend")
    assert_predicate outcome, :frozen?
    assert_predicate outcome.backend_metadata, :frozen?
  end

  def test_requires_the_task_reservation
    backend = Cyborg::Analysis::FixtureBackend.new(
      path: File.expand_path("../../fixtures/bridge/analysis-result-valid.json", __dir__)
    )

    assert_raises(ArgumentError) do
      backend.analyze(packet: {"run_id" => "018f5f62-3ef4-7d31-9e6d-8f6dfeddb847"}, task: task, reservation: nil)
    end
    assert_raises(ArgumentError) do
      backend.analyze(
        packet: {"run_id" => "018f5f62-3ef4-7d31-9e6d-8f6dfeddb847"}, task: task,
        reservation: Cyborg::Analysis::Reservation.new(cost_micros: 2_000)
      )
    end
  end

  def test_rejects_fixture_output_over_the_task_bound
    Tempfile.create(["analysis-result", ".json"]) do |file|
      file.write(JSON.generate("claims" => [{"summary" => "too large"}]))
      file.flush
      backend = Cyborg::Analysis::FixtureBackend.new(path: file.path)

      error = assert_raises(Cyborg::UsageError) do
        backend.analyze(packet: {"run_id" => "run-1"}, task: task(maximum_output_bytes: 8), reservation: reservation)
      end
      assert_equal "analysis.output_too_large", error.code
    end
  end

  private

  def task(maximum_output_bytes: 512)
    Cyborg::Analysis::AnalysisTask.new(
      id: "fixture-task", capability: "cheap_structured_extraction", dependency_ids: [], required: true,
      packet_fingerprint: "packet", maximum_output_bytes:, reservation: reservation
    )
  end

  def reservation
    Cyborg::Analysis::Reservation.new(cost_micros: 1_000)
  end
end
