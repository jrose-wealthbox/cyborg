# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "motherbrain"

class MotherbrainReorganizationTest < Minitest::Test
  def test_uses_portable_namespace_and_configuration_prefix
    assert_equal "MOTHERBRAIN_CANDIDATE_BACKEND", Motherbrain::Candidates::CommandBackend::ENV_KEY
  end

  def test_keeps_memory_data_at_the_host_project_root
    Dir.mktmpdir do |project_root|
      repository = Motherbrain::Candidates::Repository.new(project_root)

      assert_equal File.join(project_root, "docs/memory"), repository.memory_root
    end
  end
end
