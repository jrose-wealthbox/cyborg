# frozen_string_literal: true

require_relative "../../test_helper"
require "cyborg/sources/registry"

class CyborgSourceRegistryTest < Minitest::Test
  def test_rejects_fractional_or_string_limits
    {
      "max_pages" => 1.5,
      "max_records" => "12",
      "max_response_bytes" => 4096.5,
      "max_seconds" => "30",
      "command_timeout_seconds" => 15.5
    }.each do |key, value|
      assert_raises(ArgumentError) do
        Cyborg::SourceRegistry.enabled(source_config(key => value))
      end
    end
  end

  def test_preserves_integer_limits
    registration = Cyborg::SourceRegistry.enabled(
      source_config(
        max_pages: 2, max_records: 12, max_response_bytes: 4096,
        max_seconds: 30, command_timeout_seconds: 15
      )
    ).fetch(0)

    assert_equal 2, registration.max_pages
    assert_equal 12, registration.max_records
    assert_equal 4096, registration.max_response_bytes
    assert_equal({
      "max_pages" => 2, "max_records" => 12, "max_response_bytes" => 4096,
      "max_seconds" => 30, "command_timeout_seconds" => 15
    }, registration.limits)
  end

  private

  def source_config(limits)
    {"github" => {"enabled" => true, "adapter" => "github", "limits" => limits}}
  end
end
