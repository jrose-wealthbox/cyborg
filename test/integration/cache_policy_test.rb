# frozen_string_literal: true

require_relative "../test_helper"
require "cyborg/analysis/cache_key"
require "cyborg/analysis/cache_policy"

class CyborgCachePolicyTest < Minitest::Test
  NOW = Time.utc(2026, 8, 12, 0, 0, 0)

  def test_same_normalized_content_has_same_analysis_key_despite_snapshot_and_order
    records = [
      {"source_record_id" => "b", "content_fingerprint" => "fp-b", "snapshot_id" => "b-snapshot"},
      {"source_record_id" => "a", "content_fingerprint" => "fp-a", "snapshot_id" => "a-snapshot"}
    ]
    first = key_for(records:, snapshot_id: "a")
    second = key_for(records: records.reverse, snapshot_id: "b")

    assert_equal first, second
  end

  def test_policy_uses_ordinary_and_expensive_ttls
    policy = Cyborg::CachePolicy.new(ordinary_ttl_seconds: 1_800, expensive_ttl_seconds: 14_400)

    assert_equal 1_800, policy.ttl("ordinary")
    assert_equal 14_400, policy.ttl("expensive")
    assert_equal "2026-08-12T00:30:00Z", policy.expires_at(cache_class: "ordinary", now: NOW)
    assert_equal "2026-08-12T04:00:00Z", policy.expires_at(cache_class: "expensive", now: NOW)
  end

  def test_invalidation_preserves_entry_and_audit_metadata
    tmpdir = Dir.mktmpdir("cyborg-cache-policy")
    db = Cyborg::Database.connect(path: File.join(tmpdir, "db.sqlite3"))
    db.migrate!
    db[:runs].insert(id: "run-1", profile: "default", execution_mode: "interactive", status: "running", window_start_utc: "2026-08-12T00:00:00Z", window_end_utc: "2026-08-12T01:00:00Z", display_timezone: "UTC", configuration_fingerprint: "config", created_at: "2026-08-12T00:00:00Z")
    repository = Cyborg::Repositories::CacheRepository.new(db)
    repository.store(id: "cache-1", stage: "analysis", cache_key: "key", cache_class: "ordinary", input_fingerprint: "input", created_at: "2026-08-12T00:00:00Z", expires_at: "2026-08-13T00:00:00Z", payload: {"ok" => true})
    policy = Cyborg::CachePolicy.new(ordinary_ttl_seconds: 1_800, expensive_ttl_seconds: 14_400)

    policy.invalidate(repository:, classes: :ordinary, stage: "analysis", cache_key: "key", invalidated_at: "2026-08-12T00:01:00Z", command: "cyborg-no-cache", run_id: "run-1", reason: "user_requested")

    row = db[:cache_entries].first
    assert_equal "cache-1", row[:id]
    assert_equal "cyborg-no-cache", row[:invalidation_command]
    assert_equal "run-1", row[:invalidation_run_id]
    assert_equal "user_requested", row[:invalidation_reason]
  ensure
    db&.disconnect
    FileUtils.remove_entry(tmpdir) if tmpdir
  end

  def test_ordinary_and_full_invalidation_select_cache_classes
    tmpdir = Dir.mktmpdir("cyborg-cache-classes")
    db = Cyborg::Database.connect(path: File.join(tmpdir, "db.sqlite3"))
    db.migrate!
    repository = Cyborg::Repositories::CacheRepository.new(db)
    %w[ordinary expensive].each do |cache_class|
      repository.store(
        id: "cache-#{cache_class}", stage: "analysis", cache_key: "key-#{cache_class}", cache_class:,
        input_fingerprint: "input-#{cache_class}", created_at: "2026-08-12T00:00:00Z",
        expires_at: "2026-08-13T00:00:00Z", payload: {cache_class:}
      )
    end
    policy = Cyborg::CachePolicy.new(ordinary_ttl_seconds: 1_800, expensive_ttl_seconds: 14_400)

    policy.invalidate(repository:, classes: :ordinary, invalidated_at: "2026-08-12T00:01:00Z", command: "cyborg-no-cache", reason: "user_requested")
    assert_equal "2026-08-12T00:01:00Z", db[:cache_entries].where(cache_class: "ordinary").get(:invalidated_at)
    assert_nil db[:cache_entries].where(cache_class: "expensive").get(:invalidated_at)

    policy.invalidate(repository:, classes: :full, invalidated_at: "2026-08-12T00:02:00Z", command: "cyborg-no-cache-even-expensive", reason: "user_requested")
    assert_equal "2026-08-12T00:02:00Z", db[:cache_entries].where(cache_class: "ordinary").get(:invalidated_at)
    assert_equal "2026-08-12T00:02:00Z", db[:cache_entries].where(cache_class: "expensive").get(:invalidated_at)
    assert_equal "cyborg-no-cache-even-expensive", db[:cache_entries].where(cache_class: "expensive").get(:invalidation_command)
  ensure
    db&.disconnect
    FileUtils.remove_entry(tmpdir) if tmpdir
  end

  def test_invalidation_rejects_unknown_or_empty_class_selection
    policy = Cyborg::CachePolicy.new(ordinary_ttl_seconds: 1_800, expensive_ttl_seconds: 14_400)

    assert_raises(ArgumentError) do
      policy.invalidate(repository: nil, classes: :unknown, invalidated_at: "2026-08-12T00:00:00Z", command: "x", reason: "user_requested")
    end
    assert_raises(ArgumentError) do
      policy.invalidate(repository: nil, classes: [], invalidated_at: "2026-08-12T00:00:00Z", command: "x", reason: "user_requested")
    end
  end

  private

  def key_for(records:, snapshot_id:)
    Cyborg::CacheKey.call(stage: "analysis", input: {"snapshot_id" => snapshot_id, "records" => records}, implementation_version: "1", config_fingerprint: "config", adapter_versions: {"github" => "1"}, prompt_version: "prompt", backend_identity: "host")
  end
end
