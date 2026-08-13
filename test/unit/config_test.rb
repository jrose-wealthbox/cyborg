# frozen_string_literal: true

require_relative "../test_helper"

class CyborgConfigTest < Minitest::Test
  def fixture(name)
    File.expand_path("../fixtures/#{name}", __dir__)
  end

  def test_loads_typed_values_and_fingerprints_resolved_configuration
    config = Cyborg::Config.load(path: fixture("config/minimal.toml"), env: {})

    assert_equal "default", config.profile_name
    assert_equal "America/New_York", config.profile.timezone
    assert_equal 1_800, config.cache.ordinary_ttl_seconds
    assert_equal 14_400, config.cache.expensive_ttl_seconds
    assert_equal 5_000_000, config.budget.ceiling_micros
    assert_match(/\A[0-9a-f]{64}\z/, config.fingerprint)
    assert_predicate config, :frozen?
  end

  def test_fingerprint_includes_all_recognized_non_secret_configuration_sections
    baseline = File.read(fixture("config/minimal.toml"))
    baseline_fingerprint = load_toml(baseline).fingerprint

    {
      "llm" => "[llm]\ncapability = \"medium_reasoning\"\n",
      "filters" => "[filters]\nunread_only = true\n",
      "database" => "[database]\nbusy_timeout_ms = 2500\n",
      "tasks" => "[tasks]\nreflection_enabled = true\n"
    }.each_value do |section|
      refute_equal baseline_fingerprint, load_toml("#{baseline}\n#{section}").fingerprint
    end
  end

  def test_fingerprint_changes_when_default_calendar_profile_selection_changes
    baseline = File.read(fixture("config/minimal.toml"))
    work_profile = <<~TOML

      [calendar]
      default_profile = "work"

      [calendar.profiles.work]
      timezone = "America/New_York"
      weekend_days = ["saturday", "sunday"]
    TOML

    refute_equal load_toml(baseline).fingerprint, load_toml("#{baseline}\n#{work_profile}").fingerprint
  end

  def test_fingerprint_is_immutable
    fingerprint = load_toml(File.read(fixture("config/minimal.toml"))).fingerprint

    assert_predicate fingerprint, :frozen?
    assert_raises(FrozenError) { fingerprint << "changed" }
  end

  def test_fingerprint_uses_canonical_key_order
    baseline = File.read(fixture("config/minimal.toml"))
    first = "[llm]\ncapability = \"medium_reasoning\"\nprovider = \"host\"\n"
    second = "[llm]\nprovider = \"host\"\ncapability = \"medium_reasoning\"\n"

    assert_equal load_toml("#{baseline}\n#{first}").fingerprint,
      load_toml("#{baseline}\n#{second}").fingerprint
  end

  def test_configuration_rejects_secret_shaped_keys
    error = assert_raises(Cyborg::InvalidConfiguration) do
      Cyborg::Config.load(path: fixture("config/invalid-secret.toml"), env: {})
    end

    assert_equal "config.secret_forbidden", error.code
  end

  def test_rejects_lease_shorter_than_analysis_timeout
    Tempfile.create(["cyborg", ".toml"]) do |file|
      file.write("[runtime]\nlease_timeout_seconds = 10\nanalysis_timeout_seconds = 11\n")
      file.flush

      error = assert_raises(Cyborg::InvalidConfiguration) do
        Cyborg::Config.load(path: file.path, env: {})
      end
      assert_equal "config.lease_too_short", error.code
    end
  end

  def test_rejects_required_reservations_above_the_run_ceiling
    Tempfile.create(["cyborg", ".toml"]) do |file|
      file.write(<<~TOML)
        [budget]
        ceiling_micros = 5000000
        [analysis]
        required_reservation_micros = 5000001
      TOML
      file.flush

      error = assert_raises(Cyborg::InvalidConfiguration) do
        Cyborg::Config.load(path: file.path, env: {})
      end
      assert_equal "config.budget_too_low", error.code
    end
  end

  def test_rejects_unknown_required_sections_and_invalid_enums
    Tempfile.create(["cyborg", ".toml"]) do |file|
      file.write("[required]\nnot_a_real_requirement = true\n")
      file.flush
      error = assert_raises(Cyborg::InvalidConfiguration) { Cyborg::Config.load(path: file.path, env: {}) }
      assert_equal "config.unknown_required_section", error.code
    end

    Tempfile.create(["cyborg", ".toml"]) do |file|
      file.write("[runtime]\nexecution_mode = \"telepathy\"\n")
      file.flush
      error = assert_raises(Cyborg::InvalidConfiguration) { Cyborg::Config.load(path: file.path, env: {}) }
      assert_equal "config.invalid_enum", error.code
    end
  end

  def test_rejects_missing_required_repository_root_and_preserves_source_limits
    Tempfile.create(["cyborg", ".toml"]) do |file|
      file.write(<<~TOML)
        [sources.local]
        adapter = "local_git"
        enabled = true
        repository_roots = ["/definitely/not/a/repository"]
        [sources.local.limits]
        max_records = 12
      TOML
      file.flush
      error = assert_raises(Cyborg::InvalidConfiguration) { Cyborg::Config.load(path: file.path, env: {}) }
      assert_equal "config.required_path_missing", error.code
    end
  end

  def test_rejects_working_hours_with_invalid_syntax_range_or_order
    [
      "start = \"9am\"\nend = \"17:00\"",
      "start = \"09:00\"\nend = \"25:00\"",
      "start = \"17:00\"\nend = \"09:00\""
    ].each do |working_hours|
      Tempfile.create(["cyborg", ".toml"]) do |file|
        file.write("[calendar.profiles.default.working_hours]\n#{working_hours}\n")
        file.flush

        error = assert_raises(Cyborg::InvalidConfiguration) do
          Cyborg::Config.load(path: file.path, env: {})
        end
        assert_equal "config.invalid_working_hours", error.code
      end
    end
  end

  def test_rejects_a_profile_with_no_possible_business_day
    Tempfile.create(["cyborg", ".toml"]) do |file|
      file.write(<<~TOML)
        [calendar.profiles.default]
        weekend_days = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
      TOML
      file.flush

      error = assert_raises(Cyborg::InvalidConfiguration) do
        Cyborg::Config.load(path: file.path, env: {})
      end
      assert_equal "config.no_business_day", error.code
    end
  end

  private

  def load_toml(contents)
    Tempfile.create(["cyborg", ".toml"]) do |file|
      file.write(contents)
      file.flush
      return Cyborg::Config.load(path: file.path, env: {})
    end
  end
end
