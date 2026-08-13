# frozen_string_literal: true

require_relative "../test_helper"
require "json"

class CyborgV1AcceptanceTest < Minitest::Test
  NOW = "2026-08-13T12:00:00Z"
  LATER = "2026-08-13T12:30:00Z"

  def setup
    @tmpdir = Dir.mktmpdir("cyborg-v1-acceptance")
    @db = Cyborg::Database.connect(path: File.join(@tmpdir, "cyborg.sqlite3"))
    @db.migrate!
  end

  def teardown
    @db.disconnect
    FileUtils.remove_entry(@tmpdir)
  end

  def test_one_hundred_identical_runs_reuse_validated_analysis
    insert_run("run-1")
    repository = Cyborg::Repositories::AnalysisRepository.new(@db)
    calls = 0
    100.times do
      cached = repository.find_cached(task_id: "task-1", input_fingerprint: "same")
      unless cached
        calls += 1
        repository.create(id: "analysis-1", run_id: "run-1", task_id: "task-1", input_fingerprint: "same",
                          output_fingerprint: "out", validation_status: "valid", result_json: "{}", created_at: NOW)
      end
    end
    assert_equal 1, calls
    assert_equal 1, @db[:analysis_results].count
  end

  def test_github_failure_preserves_local_git_and_publishes_degraded_source_health
    run = insert_run("run-1")
    insert_snapshot(run.id, "github", status: "failed", data_status: "none", error_code: "github.timeout", error_remediation: "retry")
    insert_snapshot(run.id, "local_git", status: "healthy", data_status: "fresh", proposed_cursor: "git-2", cursor_disposition: "advance")
    result = publish(run)
    assert_equal "degraded", result.run.status
    assert_includes result.view_model.fetch("sections").first.fetch("heading"), "SOURCE HEALTH"
    assert_includes result.view_model.fetch("warnings").join(" "), "source.github.failed"
    assert_equal "git-2", @db[:source_baselines].where(source_name: "local_git").get(:cursor)
  end

  def test_completed_evidence_does_not_reopen_a_completed_action
    run = insert_run("run-1")
    evidence("e1", NOW)
    action = reconcile(run, evidence_ids: ["e1"])
    Cyborg::Actions::StateMachine.new(db: @db, now: Time.iso8601(NOW)).transition(action_id: action.id, command: "done", origin: "acceptance")
    reconciled = reconcile(run, evidence_ids: ["e1"])
    assert_equal "done", reconciled.user_state
    assert_equal action.id, reconciled.id
  end

  def test_later_evidence_creates_and_links_supported_successor
    run = insert_run("run-1")
    evidence("e1", NOW)
    evidence("e2", LATER)
    action = reconcile(run, evidence_ids: ["e1"])
    Cyborg::Actions::StateMachine.new(db: @db, now: Time.iso8601(NOW)).transition(action_id: action.id, command: "done", origin: "acceptance")
    result = Cyborg::Actions::Reconciler.new(db: @db, now: Time.iso8601(LATER)).call(
      run:, claims: [claim(evidence_ids: ["e2"], new_commitment: true)]
    )
    successor = result.actions.find { |value| value.occurrence_number == 2 }
    assert_equal "open", successor.user_state
    assert_equal action.id, @db[:action_successors].first.fetch(:predecessor_action_id)
  end

  def test_malformed_artifacts_persist_no_partial_claims_or_publication_state
    run = insert_run("run-1")
    validator = Cyborg::Analysis::ResultValidator.new
    outcome = validator.validate(packet: {"run_id" => run.id, "records" => [], "allowed_action_kinds" => ["review"], "maximum_claim_count" => 5, "maximum_output_bytes" => 1000}, result: {"claims" => "not-an-array"})
    assert_equal false, outcome.accepted?
    assert_empty @db[:inferred_actions].all
    assert_empty @db[:presentation_results].all
  end

  def test_unknown_evidence_produces_deterministic_degraded_view_without_claim_mutation
    run = insert_run("run-1")
    outcome = Cyborg::Analysis::ResultValidator.new.validate(packet: {"run_id" => run.id, "records" => [], "allowed_action_kinds" => ["review"], "maximum_claim_count" => 5, "maximum_output_bytes" => 1000}, result: {"claims" => [claim(evidence_ids: ["missing"])]})
    result = publish(run, outcome)
    assert_equal "degraded", result.run.status
    assert_empty @db[:inferred_actions].all
    assert_includes result.view_model.fetch("warnings").join(" "), "analysis.rejected"
  end

  def test_failed_runs_advance_neither_latest_renderable_pointer_nor_source_baseline
    run = insert_run("run-1", status: "failed", completed_at: LATER)
    insert_snapshot(run.id, "github", status: "failed", data_status: "none", error_code: "github.timeout")
    assert_nil @db[:application_state].where(key: "latest_renderable_run_id").first
    assert_nil @db[:source_baselines].first
  end

  def test_degraded_runs_advance_only_eligible_healthy_fresh_source_baselines
    run = insert_run("run-1")
    insert_snapshot(run.id, "github", status: "healthy", data_status: "fresh", proposed_cursor: "g-2", cursor_disposition: "advance")
    insert_snapshot(run.id, "slack", status: "degraded", data_status: "fresh", error_code: "slack.partial")
    publish(run)
    assert_equal "g-2", @db[:source_baselines].where(source_name: "github").get(:cursor)
    assert_nil @db[:source_baselines].where(source_name: "slack").first
  end

  def test_ordinary_cache_invalidation_preserves_expensive_and_full_bypasses_both
    repository = Cyborg::Repositories::CacheRepository.new(@db)
    %w[ordinary expensive].each { |kind| repository.store(id: "cache-#{kind}", stage: "analysis", cache_key: kind, cache_class: kind, input_fingerprint: kind, created_at: NOW, expires_at: LATER, payload: {}) }
    policy = Cyborg::CachePolicy.new(ordinary_ttl_seconds: 1800, expensive_ttl_seconds: 14400)
    policy.invalidate(repository:, classes: :ordinary, invalidated_at: NOW, command: "cyborg-no-cache", reason: "test")
    assert @db[:cache_entries].where(cache_class: "ordinary").get(:invalidated_at)
    assert_nil @db[:cache_entries].where(cache_class: "expensive").get(:invalidated_at)
    policy.invalidate(repository:, classes: :full, invalidated_at: LATER, command: "cyborg-no-cache-even-expensive", reason: "test")
    assert_equal 2, @db[:cache_entries].where { invalidated_at !~ nil }.count
  end

  def test_concurrent_manual_action_transition_survives_reconciliation_and_publication
    run = insert_run("run-1")
    evidence("e1", NOW)
    action = reconcile(run, evidence_ids: ["e1"])
    Cyborg::Actions::StateMachine.new(db: @db, now: Time.iso8601(LATER)).transition(action_id: action.id, command: "acknowledge", origin: "manual")
    result = publish(run)
    item = result.view_model.fetch("sections").flat_map { |section| section.fetch("items") }.find { |value| value["id"] == action.id }
    assert_equal "acknowledged", item.fetch("state")
  end

  def test_budget_exhaustion_skips_optional_work_and_keeps_reservation_auditable
    tasks = 2.times.map do |index|
      Cyborg::Analysis::AnalysisTask.new(id: "task-#{index}", capability: "cheap_structured_extraction", dependency_ids: [], required: index.zero?, packet_fingerprint: "fp-#{index}", maximum_output_bytes: 1000, reservation: Cyborg::Analysis::Reservation.new(cost_micros: 80))
    end
    plan = Cyborg::Analysis::BudgetController.new.reserve(tasks:, ceiling_micros: 80)
    assert_equal "reserved", plan.status_for("task-0")
    assert_equal "skipped_budget", plan.status_for("task-1")
    assert_equal 80, plan.reserved_micros
  end

  def test_markdown_and_json_renderers_preserve_persisted_semantics
    run = insert_run("run-1")
    insert_snapshot(run.id, "github", status: "healthy", data_status: "fresh")
    result = publish(run)
    markdown = Cyborg::Presentation::MarkdownRenderer.new.render(result.view_model)
    json = Cyborg::Presentation::JsonRenderer.new.render(result.view_model)
    parsed = JSON.parse(json)
    assert_equal result.view_model.fetch("sections").map { |section| section.fetch("name") }, parsed.fetch("sections").map { |section| section.fetch("name") }
    result.view_model.fetch("sections").flat_map { |section| section.fetch("items") }.each { |item| assert_includes markdown, item.fetch("id") }
    result.view_model.fetch("warnings").each { |warning| assert_includes parsed.fetch("warnings"), warning }
  end

  def test_complete_fixture_retrieval_snapshot_packet_validation_reconciliation_publication_flow
    run = insert_run("run-1")
    registration = Cyborg::Registration.new(source_name: "fixture", adapter_version: "fixture-1", account_identity: "fixture", transport: "direct", capabilities: ["records"], filters: {}, limits: {}, credential_strategy: "none", health_checks: [], cursor_policy: "proposed", cache_policy: "ordinary", retention_class: "standard", allowed_fields: [], operations: {}, parameters: {}, required: false)
    context = Cyborg::RetrievalContext.new(source_name: "fixture", account_identity: "fixture", window_start_utc: NOW, window_end_utc: LATER, display_timezone: "UTC", limits: {"max_records" => 2, "max_bytes" => 65_536}, cache_policy: "ordinary", filters: {}, capabilities: [])
    result = Cyborg::FixtureAdapter.new(path: File.expand_path("../fixtures/sources/fixture-records.json", __dir__)).fetch(context)
    snapshot = Cyborg::SourceIngestor.new(db: @db).ingest(run:, registration:, result:)
    assert_equal "advance", snapshot.cursor_disposition
    records = Cyborg::Repositories::RecordRepository.new(@db).records_for_snapshot(snapshot.id).map { |record| record.to_h }
    packet = Cyborg::Pipeline::AnalysisPacketBuilder.new.call(run:, records:, actions: [], tasks: [], reservation: {})
    assert_equal run.id, packet.fetch("run_id")
    fixture_result = JSON.parse(File.read(File.expand_path("../fixtures/e2e/analysis-result.json", __dir__)))
    validated = Cyborg::Analysis::ResultValidator.new.validate(packet:, result: fixture_result)
    refute_instance_of Cyborg::Analysis::ResultValidator::RejectedAnalysis, validated
    publication = publish(run, validated)
    assert_equal "completed", publication.run.status
    assert_equal publication.view_model, JSON.parse(Cyborg::Presentation::JsonRenderer.new.render(publication.view_model))
  end

  private

  def insert_run(id, status: "running", completed_at: nil)
    Cyborg::Repositories::RunRepository.new(@db).create(id:, profile: "default", execution_mode: "interactive", status:, window_start_utc: NOW, window_end_utc: LATER, display_timezone: "UTC", configuration_fingerprint: "config", created_at: NOW, completed_at:)
  end

  def insert_snapshot(run_id, source, status:, data_status:, proposed_cursor: nil, cursor_disposition: "hold", error_code: nil, error_remediation: nil)
    @db[:source_snapshots].insert(id: "snapshot-#{source}", run_id: run_id.to_s, source_name: source, account_identity: "me", adapter_version: "1", started_at: NOW, completed_at: LATER, status:, data_status:, cache_reason: nil, error_code:, error_remediation:, record_count: 0, proposed_cursor:, cursor_disposition:)
  end

  def publish(run, analysis = {"claims" => [], "usage" => {"certainty" => "unknown", "records" => []}, "backend_metadata" => {}})
    Cyborg::Runs::Publisher.new(db: @db, now: Time.iso8601(LATER), trusted_hosts: ["github.example"]).publish(run:, analysis:)
  end

  def evidence(id, at)
    @db[:observed_records].insert(id: "record-#{id}", source_name: "github", account_identity: "me", source_record_id: id, record_kind: "review", event_at: at, observed_at: at, timestamp_kind: "event_at", content_fingerprint: "fp-#{id}", first_seen_at: at, last_observed_at: at)
    @db[:observed_record_versions].insert(id: "version-#{id}", observed_record_id: "record-#{id}", content_fingerprint: "fp-#{id}", payload_json: "{}", created_at: at)
    @db[:evidence].insert(id:, observed_record_version_id: "version-#{id}", source_url: "https://github.example/#{id}", source_label: "GitHub", evidence_at: at, relation: "supports")
  end

  def reconcile(run, evidence_ids:, new_commitment: false)
    Cyborg::Actions::Reconciler.new(db: @db, now: Time.iso8601(NOW)).call(run:, claims: [claim(evidence_ids:, new_commitment:)]).actions.last
  end

  def claim(evidence_ids:, new_commitment: false)
    {"action_kind" => "review", "summary" => "Review", "canonical_subject_type" => "github_pull_request", "canonical_subject_id" => "node-42", "owner_identity" => "me", "thread_or_target_identity" => "repo#42", "anchor_evidence_id" => evidence_ids.first, "evidence_ids" => evidence_ids, "confidence" => 0.9, "people" => [], "projects" => [], "new_commitment" => new_commitment}
  end
end
