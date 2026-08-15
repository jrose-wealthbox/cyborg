# frozen_string_literal: true

require_relative "../../test_helper"

class CyborgBootstrapAssetsTest < Minitest::Test
  def test_packaged_assets_match_repository_examples
    assert_equal File.binread(File.expand_path("../../../config/example.toml", __dir__)),
      Cyborg::Bootstrap::Assets.config_bytes
    assert_equal JSON.parse(File.read(File.expand_path("../../../test/fixtures/sources/fixture-records.json", __dir__))),
      JSON.parse(Cyborg::Bootstrap::Assets.fixture_bytes)
  end
end
