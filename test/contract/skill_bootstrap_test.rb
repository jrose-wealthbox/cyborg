# frozen_string_literal: true

require_relative "../test_helper"

class CyborgSkillBootstrapContractTest < Minitest::Test
  SKILL_PATH = File.expand_path("../../skills/cyborg/SKILL.md", __dir__)
  BRIDGE_PATH = File.expand_path("../../skills/cyborg/references/bridge-protocol.md", __dir__)
  README_PATH = File.expand_path("../../README.md", __dir__)

  def setup
    @skill = File.read(SKILL_PATH)
    @bridge = File.read(BRIDGE_PATH)
    @readme = File.read(README_PATH)
  end

  def test_skill_bootstraps_before_prepare_and_branches_on_cli_analysis_status
    init_position = @skill.index("bin/cyborg init")
    prepare_position = @skill.index("cyborg prepare")
    refute_nil init_position, "the skill must validate/bootstrap with init"
    refute_nil prepare_position, "the skill must retain the prepare bridge step"
    assert_operator init_position, :<, prepare_position
    assert_match(/every invocation/i, @skill)
    assert_match(/explicit(?:ly)?[- ]user.*--config|--config.*precedence/i, @skill)
    assert_match(/analysis_status/, @skill)
    assert_match(/required.*host.*analysis.*record-result/m, @skill)
    assert_match(/cached.*analysis_result.*record-result/m, @skill)
    assert_match(/do not (?:open|read|copy|parse|rewrite).*payload/i, @skill)
  end

  def test_skill_forbids_shell_bootstrap_and_parallel_presentation
    refute_match(/(?:mkdir|cp)\s+.*(?:config|state)|export\s+CYBORG_CONFIG/i, @skill)
    refute_match(/(?:use|create|set|write|export)\s+.{0,50}(?:temporary|ad hoc)\s+.{0,30}(?:config|state)/i, @skill)
    assert_match(/verbatim stdout.*render|render.*verbatim stdout/m, @skill)
    assert_match(/lease.*protected|protected.*lease/i, @skill)
  end

  def test_bridge_documents_init_cache_schemas_and_artifact_separation
    assert_match(/status.*initialized.*ready/m, @bridge)
    assert_match(/Init exits[\s\S]*`78` for invalid configuration/i, @bridge)
    assert_match(/no[- ]overwrite|never overwrites.*existing|unchanged.*existing|existing.*unchanged/i, @bridge)
    assert_match(/analysis_status.*required.*cached/m, @bridge)
    assert_match(/persistent default.*disposable artifact|default state.*artifact root/im, @bridge)
  end

  def test_readme_one_prompt_setup_does_not_require_manual_file_or_env_setup
    one_prompt = @readme[@readme.index("## Run through a coding harness")..]
    refute_match(/mkdir|cp\s+.*(?:config|fixture)|export\s+CYBORG_CONFIG/i, one_prompt)
    assert_match(/cyborg init|automatic.*init|initializ/i, one_prompt)
    assert_match(/manual.*init|bin\/cyborg init/i, @readme)
  end
end
