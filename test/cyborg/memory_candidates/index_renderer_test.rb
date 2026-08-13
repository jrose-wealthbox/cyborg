# frozen_string_literal: true

require_relative "../../test_helper"

class IndexRendererTest < Minitest::Test
  def test_orders_accepted_entries_by_verification_and_update_descending
    build_memory_project do |root|
      memory_root = File.join(root, "docs/memory")
      older = memory_entry(memory_root, "ADR-older", verified: "2026-08-01T00:00:00Z", updated: "2026-08-10T00:00:00Z")
      newer = memory_entry(memory_root, "ADR-newer", verified: "2026-08-11T00:00:00Z", updated: "2026-08-11T00:00:00Z")

      index = Cyborg::MemoryCandidates::IndexRenderer.new(memory_root).render([older, newer])

      assert_operator index.index("ADR-newer"), :<, index.index("ADR-older")
    end
  end

  private

  def memory_entry(memory_root, id, verified:, updated:)
    Cyborg::MemoryCandidates::MemoryEntry.new(
      path: File.join(memory_root, "decisions/#{id}.md"),
      contents: "",
      metadata: {
        "id" => id,
        "type" => "decision",
        "status" => "active",
        "updated_at" => updated,
        "last_verified_at" => verified,
        "components" => ["docs/memory"],
        "summary" => "Summary for #{id}"
      }
    )
  end
end
