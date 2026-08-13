# frozen_string_literal: true

require_relative "../../test_helper"

class CandidateManagerTest < Minitest::Test
  def setup
    @now = Time.utc(2026, 8, 13, 1, 2, 3)
  end

  def test_promotes_candidate_into_accepted_directory_and_updates_index
    build_memory_project do |root|
      candidate_path = write_candidate_entry(root, id: "ADR-CAND-abc123", type: "decision")
      manager = Motherbrain::Candidates::CandidateManager.new(root, now: -> { @now })

      promoted_id = manager.promote("ADR-CAND-abc123")

      assert_equal "ADR-20260813-detach-memory-extraction", promoted_id
      refute_path_exists candidate_path
      promoted_path = File.join(root, "docs/memory/decisions/#{promoted_id}.md")
      assert_path_exists promoted_path
      metadata, contents = read_memory_entry(promoted_path)
      assert_equal "active", metadata.fetch("status")
      assert_equal "ADR-CAND-abc123", metadata.fetch("promoted_from")
      assert_equal "2026-08-13T01:02:03Z", metadata.fetch("last_verified_at")
      refute_includes contents, "not authoritative until explicitly promoted"

      index = File.read(File.join(root, "docs/memory/INDEX.md"))
      assert index.lines.any? { |line| line.start_with?("| #{promoted_id} |") }
      refute index.lines.any? { |line| line.start_with?("| ADR-CAND-abc123 |") }
      assert_operator index.index(promoted_id), :<, index.index("## Candidates")
    end
  end

  def test_dismisses_candidate_in_place_and_moves_its_index_row_to_history
    build_memory_project do |root|
      candidate_path = write_candidate_entry(root, id: "LRN-CAND-def456", type: "learning")
      manager = Motherbrain::Candidates::CandidateManager.new(root, now: -> { @now })

      dismissed_id = manager.dismiss("LRN-CAND-def456", reason: "Already captured in a more specific entry.")

      assert_equal "LRN-CAND-def456", dismissed_id
      metadata, = read_memory_entry(candidate_path)
      assert_equal "dismissed", metadata.fetch("status")
      assert_equal "Already captured in a more specific entry.", metadata.fetch("dismissal_reason")
      index = File.read(File.join(root, "docs/memory/INDEX.md"))
      assert_operator index.index("## Historical and dismissed memories"), :<, index.index("LRN-CAND-def456")
    end
  end

  def test_rebuild_index_supports_manual_memory_without_any_hook_integration
    build_memory_project do |root|
      accepted = File.join(root, "docs/memory/learnings/LRN-20260801-manual.md")
      FileUtils.mkdir_p(File.dirname(accepted))
      File.write(accepted, entry_markdown(id: "LRN-20260801-manual", type: "learning", status: "active"))

      Motherbrain::Candidates::Repository.new(root).rebuild_index

      index = File.read(File.join(root, "docs/memory/INDEX.md"))
      assert index.lines.any? { |line| line.start_with?("| LRN-20260801-manual |") }
    end
  end

  def test_failed_in_place_transition_preserves_original_entry
    build_memory_project do |root|
      candidate_path = write_candidate_entry(root, id: "LRN-CAND-safe", type: "learning")
      original = File.binread(candidate_path)
      repository = Motherbrain::Candidates::Repository.new(root)
      entry = repository.find_by_id("LRN-CAND-safe")

      result = repository.replace_entry(entry, destination: candidate_path, contents: "not valid frontmatter")

      refute result
      assert_equal original, File.binread(candidate_path)
    end
  end

  private

  def write_candidate_entry(root, id:, type:)
    directory = File.join(root, "docs/memory/candidates")
    FileUtils.mkdir_p(directory)
    path = File.join(directory, "#{id}.md")
    File.write(path, entry_markdown(id:, type:, status: "candidate"))
    path
  end

  def entry_markdown(id:, type:, status:)
    <<~MARKDOWN
      ---
      id: #{id}
      type: #{type}
      status: #{status}
      title: Detach memory extraction
      summary: Session-end adapters enqueue work before detached extraction.
      created_at: '2026-08-12T19:00:00Z'
      updated_at: '2026-08-12T19:00:00Z'
      last_verified_at:
      tags: [memory, hooks]
      components: [docs/memory]
      supersedes: []
      superseded_by:
      candidate_fingerprint: sha256:abc123
      candidate_harness: codex
      candidate_session_id: session-123
      candidate_transcript_sha256: sha256:def456
      candidate_extracted_at: '2026-08-12T19:00:00Z'
      candidate_rationale: Session-end budgets are short.
      ---
      # Detach memory extraction

      ## Candidate notice

      This entry was extracted automatically from session evidence. It is searchable but is not authoritative until explicitly promoted.

      ## #{type == "decision" ? "Decision" : "Observation"}

      Keep hook work bounded.
    MARKDOWN
  end
end
