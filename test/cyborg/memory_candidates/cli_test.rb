# frozen_string_literal: true

require_relative "../../test_helper"
require "open3"
require "rbconfig"
require "stringio"

class CliTest < Minitest::Test
  RecordingQueue = Struct.new(:events) do
    def enqueue(event)
      events << event
      "/tmp/job.json"
    end
  end

  def test_enqueue_cli_normalizes_provider_input
    queue = RecordingQueue.new([])
    input = JSON.generate(
      "session_id" => "session-1",
      "turn_id" => "turn-2",
      "transcript_path" => "/tmp/transcript.jsonl",
      "cwd" => "/project",
      "hook_event_name" => "SessionEnd",
      "reason" => "other"
    )

    status = Cyborg::MemoryCandidates::EnqueueCLI.new(
      harness: "codex",
      stdin: StringIO.new(input),
      env: {},
      queue: queue,
      now: -> { Time.utc(2026, 8, 12, 20, 0, 0) }
    ).run

    assert_equal 0, status
    assert_equal "codex", queue.events.first.fetch("harness")
    assert_equal "turn-2", queue.events.first.fetch("turn_id")
  end

  def test_enqueue_cli_fails_open_when_disabled_or_input_is_malformed
    queue = RecordingQueue.new([])

    disabled = Cyborg::MemoryCandidates::EnqueueCLI.new(
      harness: "claude_code",
      stdin: StringIO.new("{}"),
      env: {"CYBORG_MEMORY_CANDIDATES_ENABLED" => "false"},
      queue: queue
    ).run
    malformed = Cyborg::MemoryCandidates::EnqueueCLI.new(
      harness: "claude_code",
      stdin: StringIO.new("not json"),
      env: {},
      queue: queue
    ).run

    assert_equal 0, disabled
    assert_equal 0, malformed
    assert_empty queue.events
  end

  def test_extract_cli_accepts_normalized_json_and_reports_zero_without_backend
    build_memory_project do |root|
      transcript_path = write_transcript(root, [["user", "Thanks"], ["assistant", "You're welcome"]])
      stdout = StringIO.new

      status = Cyborg::MemoryCandidates::ExtractCLI.new(
        stdin: StringIO.new(JSON.generate(normalized_event(root, transcript_path))),
        stdout: stdout,
        env: {}
      ).run

      assert_equal 0, status
      assert_equal({"candidate_ids" => []}, JSON.parse(stdout.string))
    end
  end

  def test_default_queue_spawns_worker_without_waiting_for_it
    Dir.mktmpdir do |tmpdir|
      worker = File.join(tmpdir, "worker.rb")
      marker = File.join(tmpdir, "finished")
      File.write(worker, <<~RUBY)
        require "json"
        sleep 0.8
        event = JSON.parse(File.read(ARGV.fetch(0)))
        File.write(event.fetch("test_marker"), "done")
      RUBY
      event = normalized_event(tmpdir, File.join(tmpdir, "transcript.jsonl"))
      queue = Cyborg::MemoryCandidates::Queue.new(queue_dir: File.join(tmpdir, "queue"), worker_path: worker)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      job_path = queue.enqueue(event.merge("test_marker" => marker))
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_operator elapsed, :<, 0.5
      assert_path_exists job_path
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      sleep 0.02 until File.exist?(marker) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      assert_path_exists marker
    end
  end

  private

  def normalized_event(root, transcript_path)
    {
      "schema_version" => 1,
      "event" => "session_end",
      "harness" => "codex",
      "session_id" => "session-1",
      "transcript_path" => transcript_path,
      "cwd" => root,
      "reason" => "other",
      "received_at" => "2026-08-12T20:00:00Z"
    }
  end
end
