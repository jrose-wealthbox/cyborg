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
    FileUtils.remove_entry(@cli_tmpdir) if @cli_tmpdir
  end

  def test_one_hundred_identical_runs_reuse_validated_analysis
    task = Cyborg::Analysis::AnalysisTask.new(
      id: "fixture-task", capability: "cheap_structured_extraction", dependency_ids: [], required: true,
      packet_fingerprint: "packet-fingerprint", maximum_output_bytes: 8_192,
      reservation: Cyborg::Analysis::Reservation.new(cost_micros: 1)
    )
    task_payload = task.to_h.transform_keys(&:to_s).merge("reservation" => task.reservation.to_h.transform_keys(&:to_s))
    packet = {"records" => [], "tasks" => [task_payload], "allowed_action_kinds" => ["review"],
              "maximum_claim_count" => 25, "maximum_output_bytes" => 8_192}
    backend = CountingFixtureBackend.new(path: File.expand_path("../fixtures/e2e/analysis-result.json", __dir__))
    orchestrator = Cyborg::Analysis::Orchestrator.new(db: @db, now: Time.iso8601(NOW))
    100.times do |index|
      run_id = "run-#{index + 1}"
      insert_run(run_id)
      execution = orchestrator.execute(run_id:, packet: packet.merge("run_id" => run_id), tasks: [task], backend:, ceiling_micros: 2)
      assert_equal [task.id], execution.outcomes.keys
    end
    assert_equal 1, backend.calls
    assert_equal 1, @db[:analysis_results].count
    assert_equal 100, @db[:usage_records].where(task_id: task.id).count
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
    assert_equal "healthy", @db[:source_snapshots].where(run_id: run.id, source_name: "local_git").get(:status)
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
    views = 2.times.map do |index|
      run = insert_run("run-#{index + 1}")
      outcome = Cyborg::Analysis::ResultValidator.new.validate(packet: {"run_id" => run.id, "records" => [], "allowed_action_kinds" => ["review"], "maximum_claim_count" => 5, "maximum_output_bytes" => 1000}, result: {"claims" => [claim(evidence_ids: ["missing"])]})
      result = publish(run, outcome)
      assert_empty @db[:inferred_actions].all
      assert_includes result.view_model.fetch("warnings").join(" "), "analysis.rejected"
      result.view_model
    end
    assert_equal views[0].except("run"), views[1].except("run")
  end

  def test_failed_runs_advance_neither_latest_renderable_pointer_nor_source_baseline
    old = insert_run("run-old", status: "completed", completed_at: "2026-08-13T11:00:00Z")
    @db[:source_snapshots].insert(id: "snapshot-old", run_id: old.id, source_name: "github", account_identity: "me",
                                  adapter_version: "1", started_at: "2026-08-13T10:59:00Z", completed_at: "2026-08-13T11:00:00Z",
                                  status: "healthy", data_status: "fresh", cursor_disposition: "advance", proposed_cursor: "old-cursor", record_count: 0)
    @db[:source_baselines].insert(source_name: "github", account_identity: "me", activated_snapshot_id: "snapshot-old",
                                  activated_at: "2026-08-13T11:00:00Z", cursor: "old-cursor")
    @db[:application_state].insert(key: "latest_renderable_run_id", value: old.id, updated_at: "2026-08-13T11:00:00Z")
    run = insert_run("run-1")
    insert_snapshot(run.id, "github", status: "healthy", data_status: "fresh", proposed_cursor: "g-2", cursor_disposition: "advance")
    assert_raises(Sequel::ConstraintViolation) do
      Cyborg::Runs::Publisher.new(db: @db, now: Time.iso8601(LATER)).fail_after!(:presentation_insert).publish(run:, analysis: {"claims" => [], "usage" => {"certainty" => "unknown", "records" => []}})
    end
    assert_equal "run-old", @db[:application_state].where(key: "latest_renderable_run_id").get(:value)
    assert_equal "old-cursor", @db[:source_baselines].where(source_name: "github", account_identity: "me").get(:cursor)
    assert_equal "snapshot-old", @db[:source_baselines].where(source_name: "github", account_identity: "me").get(:activated_snapshot_id)
    assert_equal "running", @db[:runs].where(id: run.id).get(:status)
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
    read = Queue.new
    committed = Queue.new
    writer = Thread.new do
      read.pop
      Cyborg::Actions::StateMachine.new(db: @db, now: Time.iso8601(LATER)).transition(action_id: action.id, command: "acknowledge", origin: "manual")
      committed << true
    end
    observer = lambda do |event:, run_id:, actions:|
      assert_equal :before_reconciliation, event
      assert_equal run.id, run_id
      assert_equal "open", actions.find { |row| row.fetch("id") == action.id }.fetch("user_state")
      read << true
      committed.pop
    end
    result = Cyborg::Runs::Publisher.new(db: @db, now: Time.iso8601(LATER), publication_observer: observer).publish(
      run:, analysis: {"claims" => [], "usage" => {"certainty" => "unknown", "records" => []}}
    )
    writer.join
    item = result.view_model.fetch("sections").flat_map { |section| section.fetch("items") }.find { |value| value["id"] == action.id }
    assert_equal "acknowledged", item.fetch("state")
    assert_equal "acknowledged", @db[:inferred_actions].where(id: action.id).get(:user_state)
    assert_equal 1, @db[:inferred_actions].where(id: action.id).get(:state_version)
  end

  def test_budget_exhaustion_skips_optional_work_and_keeps_reservation_auditable
    insert_run("run-1")
    tasks = 2.times.map do |index|
      Cyborg::Analysis::AnalysisTask.new(id: "task-#{index}", capability: "cheap_structured_extraction", dependency_ids: [], required: index.zero?, packet_fingerprint: "fp-#{index}", maximum_output_bytes: 1000, reservation: Cyborg::Analysis::Reservation.new(cost_micros: 80))
    end
    controller = Cyborg::Analysis::BudgetController.new
    plan = controller.reserve(tasks:, ceiling_micros: 80)
    assert_equal "reserved", plan.status_for("task-0")
    assert_equal "skipped_budget", plan.status_for("task-1")
    assert_equal 80, plan.reserved_micros
    assert_equal ["task-0"], plan.launchable_required.map(&:id)
    refute controller.allow_launch?(plan, task: tasks.last)
    graph = Cyborg::Analysis::TaskGraph.new(tasks:)
    assert_equal ["task-0"], graph.ready_tasks.select { |task| plan.status_for(task.id) == "reserved" }.map(&:id)
    recorder = Cyborg::Analysis::UsageRecorder.new(db: @db, now: Time.iso8601(NOW))
    recorder.record(run_id: "run-1", task_id: "task-0", session_id: "task-0", reservation: tasks.first.reservation,
                    cost_micros: 80, certainty: "provider_reported")
    assert_equal 80, recorder.summary(run_id: "run-1").reported_cost_micros
    assert_empty graph.ready_tasks(completed_ids: ["task-0"], launched_ids: ["task-1"])

    executable_tasks = [
      tasks.first.with(reservation: Cyborg::Analysis::Reservation.new(cost_micros: 40)),
      tasks.last.with(required: false, reservation: Cyborg::Analysis::Reservation.new(cost_micros: 80))
    ]
    backend = CountingFixtureBackend.new(path: File.expand_path("../fixtures/e2e/analysis-result.json", __dir__))
    executable_packet_tasks = executable_tasks.map do |task|
      task.to_h.transform_keys(&:to_s).merge("reservation" => task.reservation.to_h.transform_keys(&:to_s))
    end
    execution = Cyborg::Analysis::Orchestrator.new(db: @db, now: Time.iso8601(NOW)).execute(
      run_id: "run-1", packet: {"run_id" => "run-1", "records" => [], "tasks" => executable_packet_tasks,
                                 "allowed_action_kinds" => ["review"], "maximum_claim_count" => 25,
                                 "maximum_output_bytes" => 8_192}, tasks: executable_tasks, backend:, ceiling_micros: 80
    )
    assert_equal ["task-0"], execution.launched_task_ids
    assert_empty execution.reservation_plan.launchable_optional
    assert_equal 1, backend.calls
    assert_equal "analysis-run-1", @db[:usage_records].where(id: "analysis-run-1").get(:id)
    assert_equal "analysis-run-1", @db[:usage_records].where(id: "analysis-run-1-task-0").get(:parent_session_id)
  end

  def test_orchestrator_reconciles_provider_usage_and_rolls_back_partial_failure
    insert_run("run-usage")
    usage_task = analysis_task("usage-task", required: true, cost: 7)
    backend = ReportingBackend.new
    execution = Cyborg::Analysis::Orchestrator.new(db: @db, now: Time.iso8601(NOW)).execute(
      run_id: "run-usage", packet: orchestrator_packet("run-usage", [usage_task]), tasks: [usage_task], backend:, ceiling_micros: 10
    )
    usage = @db[:usage_records].where(id: "analysis-run-usage-usage-task").first
    assert_equal 3, usage.fetch(:input_tokens)
    assert_equal 5, usage.fetch(:output_tokens)
    assert_equal 7, usage.fetch(:cost_micros)
    assert_equal "provider_reported", usage.fetch(:certainty)
    assert_equal 0, execution.reservation_plan.reservation_for(usage_task.id)
    assert_equal "released", execution.reservation_plan.status_for(usage_task.id)

    insert_run("run-failure")
    first = analysis_task("first", required: true, cost: 1)
    second = analysis_task("second", required: true, cost: 1)
    failing = ReportingBackend.new(fail_task: second.id)
    assert_raises(Cyborg::UsageError) do
      Cyborg::Analysis::Orchestrator.new(db: @db, now: Time.iso8601(NOW)).execute(
        run_id: "run-failure", packet: orchestrator_packet("run-failure", [first, second]),
        tasks: [first, second], backend: failing, ceiling_micros: 10
      )
    end
    assert_equal 0, @db[:analysis_results].where(run_id: "run-failure").count
    assert_equal 0, @db[:usage_records].where(run_id: "run-failure").count
    assert_equal 2, failing.calls
  end

  def test_provider_cost_reconciles_ceiling_before_next_ready_launch
    insert_run("run-ceiling")
    first = analysis_task("ceiling-first", required: true, cost: 1)
    second = analysis_task("ceiling-second", required: false, cost: 1)
    backend = ReportingBackend.new
    execution = Cyborg::Analysis::Orchestrator.new(db: @db, now: Time.iso8601(NOW)).execute(
      run_id: "run-ceiling", packet: orchestrator_packet("run-ceiling", [first, second]),
      tasks: [first, second], backend:, ceiling_micros: 3
    )
    assert_equal [first.id], execution.launched_task_ids
    assert_empty execution.cached_task_ids
    assert_equal 1, backend.calls
    assert_equal 7, execution.reservation_plan.reported_micros
    assert_equal 0, execution.reservation_plan.reserved_micros
    assert_equal "released", execution.reservation_plan.status_for(second.id)
    skipped_usage = @db[:usage_records].where(id: "analysis-run-ceiling-#{second.id}").first
    assert_equal "reserved", skipped_usage.fetch(:certainty)
    assert_equal 0, skipped_usage.fetch(:reserved_cost_micros)
    assert_equal 0, @db[:usage_records].where(task_id: second.id, certainty: "provider_reported").count
  end

  def test_markdown_and_json_renderers_preserve_persisted_semantics
    run = insert_run("run-1")
    insert_snapshot(run.id, "github", status: "healthy", data_status: "fresh")
    result = publish(run)
    markdown = Cyborg::Presentation::MarkdownRenderer.new.render(result.view_model)
    json = Cyborg::Presentation::JsonRenderer.new.render(result.view_model)
    parsed = JSON.parse(json)
    assert_equal normalize_render(parsed), normalize_render(result.view_model)
    assert_equal normalize_render(parsed), parse_markdown_render(markdown)
  end

  def test_complete_fixture_retrieval_snapshot_packet_validation_reconciliation_publication_flow
    env = cli_env
    status, output, error = cli(["prepare", "--config", env.fetch("CYBORG_CONFIG"), "--profile", "default", "--artifact-dir", @artifact_dir], env:)
    assert_equal 0, status, error
    prepared = JSON.parse(output)
    run_id = prepared.fetch("run_id")
    requests = JSON.parse(File.read(prepared.fetch("retrieval_requests"))).fetch("payload")
    request = requests.fetch(0)
    source = JSON.parse(File.read(File.expand_path("../fixtures/sources/fixture-records.json", __dir__)))
    response_payload = {"responses" => [{"request_id" => request.fetch("id"), "status" => "healthy", "data_status" => "fresh",
                                          "started_at" => NOW, "completed_at" => LATER, "next_cursor" => source.fetch("next_cursor"), "records" => source.fetch("records")}]}
    store = Cyborg::Bridge::ArtifactStore.new(root: @artifact_dir)
    store.write(run_id:, filename: "host-responses.json", envelope: Cyborg::Bridge::Envelope.build(type: "retrieval_responses", run_id:, payload: response_payload, created_at: Time.iso8601(NOW)))
    status, = cli(["ingest", "--config", env.fetch("CYBORG_CONFIG"), "--run", run_id, "--lease-file", prepared.fetch("lease_file"), "--input", File.join(@artifact_dir, run_id, "host-responses.json")], env:)
    assert_equal 0, status
    status, packet_output, error = cli(["analysis-packet", "--config", env.fetch("CYBORG_CONFIG"), "--run", run_id, "--lease-file", prepared.fetch("lease_file")], env:)
    assert_equal 0, status, error
    packet_path = JSON.parse(packet_output).fetch("output")
    packet = JSON.parse(File.read(packet_path)).fetch("payload")
    assert_equal run_id, packet.fetch("run_id")
    analysis_db = Cyborg::Database.connect(path: File.join(env.fetch("CYBORG_STATE_DIR"), "cyborg.sqlite3"))
    task = Cyborg::Analysis::AnalysisTask.new(
      id: "fixture-task", capability: "cheap_structured_extraction", dependency_ids: [], required: true,
      packet_fingerprint: "fixture-packet", maximum_output_bytes: 8_192,
      reservation: Cyborg::Analysis::Reservation.new(cost_micros: 1)
    )
    backend = Cyborg::Analysis::FixtureBackend.new(path: File.expand_path("../fixtures/e2e/analysis-result.json", __dir__))
    execution = Cyborg::Analysis::Orchestrator.new(db: analysis_db, now: Time.iso8601(NOW)).execute(
      run_id:, packet:, tasks: [task], backend:, ceiling_micros: 2
    )
    assert_equal [task.id], execution.launched_task_ids
    outcome = execution.outcomes.fetch(task.id)
    analysis_payload = {"claims" => outcome.claims, "task_results" => [{"id" => task.id, "task_id" => task.id,
      "capability" => task.capability, "dependency_ids" => [], "status" => "succeeded", "claims" => [], "usage" => nil}],
      "usage" => {"records" => [], "certainty" => "unknown"}, "backend_metadata" => outcome.backend_metadata}
    analysis_db.disconnect
    analysis_path = File.join(@artifact_dir, run_id, "analysis-result.json")
    store.write(run_id:, filename: "analysis-result.json", envelope: Cyborg::Bridge::Envelope.build(type: "analysis_result", run_id:, payload: analysis_payload, created_at: Time.iso8601(NOW)))
    status, output, error = cli(["record-result", "--config", env.fetch("CYBORG_CONFIG"), "--run", run_id, "--lease-file", prepared.fetch("lease_file"), "--input", analysis_path], env:)
    assert_equal 0, status, error
    status, rendered, error = cli(["render", "--config", env.fetch("CYBORG_CONFIG"), "--run", run_id, "--format", "json"], env:)
    assert_equal 0, status, error
    assert_equal "completed", JSON.parse(output).fetch("status"), output
    refute_empty JSON.parse(rendered).fetch("sections")
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

  class CountingFixtureBackend
    attr_reader :calls
    def initialize(**kwargs)
      @backend = Cyborg::Analysis::FixtureBackend.new(**kwargs)
      @calls = 0
    end
    def analyze(**kwargs)
      @calls += 1
      @backend.analyze(**kwargs)
    end
  end

  class ReportingBackend
    attr_reader :calls

    def initialize(fail_task: nil)
      @fail_task = fail_task
      @calls = 0
    end

    def analyze(packet:, task:, reservation:)
      @calls += 1
      raise Cyborg::UsageError.new("analysis.backend_failed") if task.id == @fail_task

      Cyborg::Analysis::AnalysisOutcome.new(
        claims: [],
        usage: {"certainty" => "provider_reported", "records" => [{"id" => "provider-#{task.id}", "run_id" => packet.fetch("run_id"),
          "task_id" => task.id, "session_id" => "provider-#{task.id}", "input_tokens" => 3,
          "output_tokens" => 5, "cost_micros" => 7, "certainty" => "provider_reported",
          "created_at" => NOW}]},
        backend_metadata: {"backend" => "reporting-fixture", "provenance" => "offline-fixture"}
      )
    end
  end

  def analysis_task(id, required:, cost:)
    Cyborg::Analysis::AnalysisTask.new(
      id:, capability: "cheap_structured_extraction", dependency_ids: [], required:,
      packet_fingerprint: "packet-#{id}", maximum_output_bytes: 8_192,
      reservation: Cyborg::Analysis::Reservation.new(cost_micros: cost)
    )
  end

  def orchestrator_packet(run_id, tasks)
    payloads = tasks.map { |task| task.to_h.transform_keys(&:to_s).merge("reservation" => task.reservation.to_h.transform_keys(&:to_s)) }
    {"run_id" => run_id, "records" => [], "tasks" => payloads, "allowed_action_kinds" => ["review"],
     "maximum_claim_count" => 25, "maximum_output_bytes" => 8_192}
  end

  def normalize_render(view)
    {
      "sections" => view.fetch("sections").map do |section|
        {"name" => section.fetch("name"), "items" => section.fetch("items").map do |item|
          {"id" => item.fetch("id"), "state" => item.fetch("state", nil), "links" => Array(item.fetch("links", [])).sort}
        end}
      end,
      "warnings" => Array(view.fetch("warnings", []))
    }
  end

  def parse_markdown_render(markdown)
    sections = []
    warnings = []
    current = nil
    markdown.each_line do |line|
      line = line.chomp
      if line.start_with?("## ")
        name = line.delete_prefix("## ").sub("⚠️ ", "")
        if name == "WARNINGS"
          current = nil
        else
          current = {"name" => name, "items" => []}
          sections << current
        end
      elsif line.start_with?("- ") && current
        match = line.match(/\[(?<id>[^\]]+)\].*— (?<state>\S+)/)
        next unless match
        current.fetch("items") << {"id" => match[:id], "state" => match[:state], "links" => line.scan(/\[source\]\(([^)]+)\)/).flatten.sort}
      elsif line.start_with?("- ") && !current
        warnings << line.delete_prefix("- ")
      end
    end
    {"sections" => sections, "warnings" => warnings}
  end

  def cli_env
    @cli_tmpdir ||= Dir.mktmpdir("cyborg-cli")
    @artifact_dir ||= File.join(@cli_tmpdir, "artifacts")
    config = File.join(@cli_tmpdir, "config.toml")
    unless File.file?(config)
      File.write(config, <<~TOML)
        [runtime]
        profile = "default"
        [budget]
        ceiling_micros = 5000000
        [analysis.tasks.fixture-task]
        capability = "cheap_structured_extraction"
        required = true
        packet_fingerprint = "fixture-packet"
        maximum_output_bytes = 8192
        [analysis.tasks.fixture-task.reservation]
        cost_micros = 1
        [cache]
        ordinary_ttl_seconds = 1800
        expensive_ttl_seconds = 14400
        [calendar.profiles.default]
        timezone = "UTC"
        [sources.fixture]
        enabled = true
        adapter = "fixture"
        account = "fixture"
        transport = "host_bridge"
        required = true
        path = "test/fixtures/sources/fixture-records.json"
        [sources.fixture.limits]
        max_records = 2
        max_response_bytes = 65536
      TOML
    end
    {"HOME" => @cli_tmpdir, "CYBORG_CONFIG" => config, "CYBORG_STATE_DIR" => File.join(@cli_tmpdir, "state")}
  end

  def cli(argv, env:)
    stdout = StringIO.new
    stderr = StringIO.new
    status = Cyborg::CLI.start(argv, stdout:, stderr:, env:)
    [status, stdout.string, stderr.string]
  end
end
