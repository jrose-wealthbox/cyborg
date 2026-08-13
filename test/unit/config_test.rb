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
end
