# frozen_string_literal: true

require_relative "../../test_helper"

class CyborgPresentationRendererTest < Minitest::Test
  def setup
    @view_model = {
      "version" => "1.0", "run" => {"id" => "run-1", "status" => "completed"},
      "sections" => [
        {"name" => "DO", "heading" => "DO", "items" => [
          {"id" => "action-1", "summary" => "Send reply", "state" => "open", "age" => "1h",
           "markers" => ["🚨"], "links" => ["https://github.example/reply"]}
        ]}
      ],
      "warnings" => ["analysis.cost_uncertain"],
      "usage" => {"certainty" => "unknown"},
      "footer" => "Edit the skill."
    }
    @markdown = Cyborg::Presentation::MarkdownRenderer.new
    @json = Cyborg::Presentation::JsonRenderer.new
  end

  def test_markdown_and_json_expose_identical_items_links_states_order_and_warnings
    markdown = @markdown.render(@view_model)
    json = JSON.parse(@json.render(@view_model))

    assert_operator markdown.index("## DO"), :<, markdown.index("analysis.cost_uncertain")
    item = @view_model.fetch("sections").first.fetch("items").first
    item.each_value { |value| assert_includes markdown, value.to_s unless value.is_a?(Array) || value.is_a?(Hash) }
    assert_includes markdown, item.fetch("id")
    assert_includes markdown, item.fetch("links").first
    assert_equal @view_model.fetch("sections"), json.fetch("sections")
    assert_equal @view_model.fetch("warnings"), json.fetch("warnings")
    assert_equal "Edit the skill.", markdown.lines.last.chomp
  end

  def test_renderers_do_not_mutate_or_require_database_access
    before = Marshal.load(Marshal.dump(@view_model))

    @markdown.render(@view_model)
    @json.render(@view_model)

    assert_equal before, @view_model
  end
end
