# frozen_string_literal: true

require_relative "../test_helper"
require "cyborg/pipeline/analysis_packet_builder"

class CyborgAnalysisPacketContractTest < Minitest::Test
  def setup
    @builder = Cyborg::Pipeline::AnalysisPacketBuilder.new(
      trusted_hosts: ["github.example"], maximum_bytes: 262_144, maximum_claim_count: 25,
      maximum_output_bytes: 8_192, prompt_version: "prompt-1"
    )
    @run = Cyborg::Run.new(
      "run-1", "default", "interactive", "running", "2026-08-12T00:00:00Z",
      "2026-08-13T00:00:00Z", "UTC", "config-1", "2026-08-12T12:00:00Z", nil, nil,
      7, "prompt-1", "cheap_structured_extraction", nil
    )
    @reservation = {"ceiling_micros" => 5_000_000, "reserved_micros" => 100_000, "remaining_micros" => 4_900_000}
  end

  def test_packet_is_bounded_and_marks_source_text_untrusted
    packet = @builder.call(
      run: @run, records: [record("one")], actions: [action], tasks: [task], reservation: @reservation
    )

    assert_operator Cyborg::Bridge::CanonicalJSON.dump(packet).bytesize, :<=, 262_144
    assert_equal true, packet.fetch("source_fields_are_untrusted_data")
    assert_empty packet.to_s.scan(/(?:ghp_|sk-[A-Za-z0-9]{20,})/)
    assert_equal %w[follow_up investigate respond review], packet.fetch("allowed_action_kinds")
    assert_equal 7, packet.fetch("existing_actions").first.fetch("state_version")
    assert_equal "prompt-1", packet.fetch("versions").fetch("prompt")
  end

  def test_exact_duplicates_share_one_group_but_keep_all_evidence
    packet = @builder.call(
      run: @run, records: [record("one"), record("two")], actions: [], tasks: [], reservation: @reservation
    )

    assert_equal 1, packet.fetch("group_candidates").length
    assert_equal 2, packet.fetch("group_candidates").first.fetch("evidence_ids").length
    assert_equal %w[one two], packet.fetch("group_candidates").first.fetch("source_record_ids")
  end

  def test_packet_rejects_credential_shaped_values_everywhere
    hostile = record("ghp_12345678901234567890")
    hostile = hostile.with(
      source_record_id: "safe-ghp_12345678901234567890",
      owner_identity: "sk-proj-abcdefghijklmnopqrstuvwxyz123456",
      canonical_target_id: "target-ghp_12345678901234567890",
      deep_link: "https://github.example/ghp_12345678901234567890"
    )
    packet = @builder.call(run: @run, records: [hostile], actions: [action], tasks: [task], reservation: @reservation)

    refute_match(/ghp_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,}/, Cyborg::Bridge::CanonicalJSON.dump(packet))
  end

  def test_packet_is_canonical_for_reordered_inputs
    records = [record("two"), record("one")]
    actions = [action.merge("id" => "action-2", "current_subject_key" => "subject-2"), action]
    tasks = [task.merge("id" => "task-2"), task]
    first = @builder.call(run: @run, records: records, actions: actions, tasks: tasks, reservation: @reservation)
    second = @builder.call(run: @run, records: records.reverse, actions: actions.reverse, tasks: tasks.reverse, reservation: @reservation)

    assert_equal Cyborg::Bridge::CanonicalJSON.dump(first), Cyborg::Bridge::CanonicalJSON.dump(second)
  end

  def test_packet_rejects_malformed_action_rows
    error = assert_raises(ArgumentError) do
      @builder.call(run: @run, records: [], actions: [{"id" => "missing-state"}], tasks: [], reservation: @reservation)
    end

    assert_match(/action/, error.message)
  end

  def test_packet_rejects_unsafe_action_kinds_and_state_version
    assert_raises(ArgumentError) { Cyborg::Pipeline::AnalysisPacketBuilder.new(allowed_action_kinds: ["review", "sk-proj-abcdefghijklmnopqrstuvwxyz123456"]) }
    assert_raises(ArgumentError) do
      @builder.call(run: @run, records: [], actions: [action.merge("state_version" => "7")], tasks: [], reservation: @reservation)
    end
  end

  def test_packet_rejects_unknown_action_states_and_blank_subject
    assert_raises(ArgumentError) { @builder.call(run: @run, records: [], actions: [action.merge("current_subject_key" => " ")], tasks: [], reservation: @reservation) }
    assert_raises(ArgumentError) { @builder.call(run: @run, records: [], actions: [action.merge("user_state" => "mystery")], tasks: [], reservation: @reservation) }
    assert_raises(ArgumentError) { @builder.call(run: @run, records: [], actions: [action.merge("inference_status" => "mystery")], tasks: [], reservation: @reservation) }
  end

  def test_packet_rejects_missing_or_unsupported_existing_action_kind
    assert_raises(ArgumentError) do
      @builder.call(run: @run, records: [], actions: [action.reject { |key, _| key == "action_kind" }], tasks: [], reservation: @reservation)
    end
    assert_raises(ArgumentError) do
      @builder.call(run: @run, records: [], actions: [action.merge("action_kind" => "unknown")], tasks: [], reservation: @reservation)
    end
  end

  def test_packet_deduplicates_task_dependency_ids
    packet = @builder.call(
      run: @run, records: [], actions: [],
      tasks: [task.merge("dependency_ids" => %w[d2 d1 d2 d1])], reservation: @reservation
    )

    assert_equal %w[d1 d2], packet.fetch("tasks").first.fetch("dependency_ids")
  end

  def test_packet_sorts_valid_evidence_links_before_selecting_deep_link
    first = record("links").with(deep_link: nil, evidence: [
      Cyborg::EvidenceDraft.new(source_url: "https://github.example/z", source_label: "GitHub", excerpt: "z", field_path: "body", evidence_at: "2026-08-12T12:00:00Z", relation: "supports"),
      Cyborg::EvidenceDraft.new(source_url: "https://github.example/a", source_label: "GitHub", excerpt: "a", field_path: "body", evidence_at: "2026-08-12T12:00:00Z", relation: "supports")
    ])
    second = first.with(evidence: first.evidence.reverse)
    p1 = @builder.call(run: @run, records: [first], actions: [action], tasks: [task.merge("dependency_ids" => %w[d2 d1])], reservation: @reservation)
    p2 = @builder.call(run: @run, records: [second], actions: [action], tasks: [task.merge("dependency_ids" => %w[d1 d2])], reservation: @reservation)

    assert_equal "https://github.example/a", p1.fetch("records").first.fetch("deep_link")
    assert_equal Cyborg::Bridge::CanonicalJSON.dump(p1), Cyborg::Bridge::CanonicalJSON.dump(p2)
    assert_equal %w[d1 d2], p1.fetch("tasks").first.fetch("dependency_ids")
  end

  def test_packet_recursive_secret_scan_finds_no_key_or_value
    packet = @builder.call(run: @run, records: [record("safe")], actions: [action.merge("metadata" => {"api_key" => "sk-proj-abcdefghijklmnopqrstuvwxyz123456"})], tasks: [task], reservation: @reservation)
    walk = lambda do |value|
      case value
      when Hash then value.flat_map { |key, item| [key, walk.call(item)] }.flatten
      when Array then value.flat_map { |item| walk.call(item) }
      else value.to_s
      end
    end
    refute_match(/api[_-]?key|ghp_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,}/i, walk.call(packet).join("\n"))
  end

  def test_evidence_ids_survive_reordering_and_insertion
    evidence_one = Cyborg::EvidenceDraft.new(source_url: "https://github.example/a", source_label: "GitHub", excerpt: "one", field_path: "body", evidence_at: "2026-08-12T12:00:00Z", relation: "supports")
    evidence_two = Cyborg::EvidenceDraft.new(source_url: "https://github.example/b", source_label: "GitHub", excerpt: "two", field_path: "body", evidence_at: "2026-08-12T12:00:00Z", relation: "supports")
    base = record("stable").with(evidence: [evidence_one, evidence_two])
    inserted = base.with(evidence: [evidence_two, evidence_one, evidence_one.with(relation: "context")])
    builder = Cyborg::Pipeline::EvidenceBuilder.new(trusted_hosts: ["github.example"])

    ids = builder.call(base).select { |row| row.fetch("relation") == "supports" }.to_h { |row| [row.fetch("excerpt"), row.fetch("evidence_id")] }
    reordered_ids = builder.call(inserted).select { |row| row.fetch("relation") == "supports" }.to_h { |row| [row.fetch("excerpt"), row.fetch("evidence_id")] }
    assert_equal ids.fetch("one"), reordered_ids.fetch("one")
    assert_equal ids.fetch("two"), reordered_ids.fetch("two")
  end

  private

  def record(id)
    evidence = Cyborg::EvidenceDraft.new(
      source_url: "https://github.example/acme/cyborg/pull/1", source_label: "GitHub",
      excerpt: "Review ghp_12345678901234567890", field_path: "body",
      evidence_at: "2026-08-12T12:00:00Z", relation: "supports"
    )
    Cyborg::NormalizedRecord.new(
      source_record_id: id, record_kind: "notification", title: "Review", summary: "Review",
      structured_fields: {"repository" => "acme/cyborg"}, participants: [], owner_identity: "me",
      canonical_target_type: "github_pr", canonical_target_id: "target", deep_link: "https://github.example/acme/cyborg/pull/1",
      event_at: "2026-08-12T12:00:00Z", observed_at: "2026-08-12T12:01:00Z",
      timestamp_kind: "event_at", content_fingerprint: "same-fingerprint", evidence: [evidence]
    )
  end

  def action
    {"id" => "action-1", "series_id" => "series-1", "current_subject_key" => "subject-1",
     "action_kind" => "review", "summary" => "Review", "inference_status" => "active",
     "user_state" => "open", "state_version" => 7, "confidence" => 0.9}
  end

  def task
    {"id" => "task-1", "capability" => "cheap_structured_extraction", "dependency_ids" => [],
     "required" => true, "maximum_output_bytes" => 8_192}
  end
end
