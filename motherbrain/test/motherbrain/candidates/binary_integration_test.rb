# frozen_string_literal: true

require_relative "../../test_helper"
require "open3"
require "rbconfig"
require "shellwords"

class BinaryIntegrationTest < Minitest::Test
  def test_provider_neutral_command_extracts_candidate_end_to_end
    build_memory_project do |root|
      transcript_path = write_transcript(root, [["user", "Detached workers avoid SessionEnd timeouts."], ["assistant", "Record that architecture decision."]])
      backend_path = File.join(root, "backend.rb")
      File.write(backend_path, <<~RUBY)
        require "json"
        JSON.parse($stdin.read)
        puts JSON.generate("candidates" => [{
          "type" => "learning",
          "title" => "Session-end extraction must run outside teardown",
          "summary" => "A detached worker keeps provider hook teardown within its advisory time budget.",
          "rationale" => "Both supported providers enforce short SessionEnd execution windows.",
          "tags" => ["memory", "hooks"],
          "components" => ["motherbrain/bin/extract-memory-candidates"],
          "observation" => "Synchronous transcript analysis can exceed the SessionEnd hook budget.",
          "insight" => "Enqueueing before analysis separates teardown latency from model latency.",
          "implication" => "Keep provider adapters bounded and perform extraction in a detached worker.",
          "verification" => "The queue integration test observes the adapter return before its worker finishes.",
          "evidence" => ["Focused tests cover provider normalization and detached worker execution."]
        }])
      RUBY
      event = {
        "schema_version" => 1,
        "event" => "session_end",
        "harness" => "codex",
        "session_id" => "integration-session",
        "transcript_path" => transcript_path,
        "cwd" => root,
        "reason" => "other",
        "received_at" => "2026-08-13T00:00:00Z"
      }
      command = File.expand_path("../../../bin/extract-memory-candidates", __dir__)
      env = {
        "MOTHERBRAIN_CANDIDATE_BACKEND" => [RbConfig.ruby, backend_path].map { |argument| Shellwords.escape(argument) }.join(" ")
      }

      stdout, stderr, status = Open3.capture3(env, command, stdin_data: JSON.generate(event), chdir: root)

      assert status.success?, stderr
      ids = JSON.parse(stdout).fetch("candidate_ids")
      assert_equal 1, ids.length
      assert_path_exists File.join(root, "docs/memory/candidates/#{ids.first}.md")
      assert_includes File.read(File.join(root, "docs/memory/INDEX.md")), ids.first
    end
  end
end
