# frozen_string_literal: true

require_relative "../../test_helper"

class QueueTest < Minitest::Test
  def test_enqueues_idempotently_and_dispatches_without_running_worker_inline
    Dir.mktmpdir do |queue_dir|
      calls = []
      spawner = lambda do |worker_path, job_path|
        calls << [worker_path, job_path]
        1234
      end
      event = normalized_event

      first = Cyborg::MemoryCandidates::Queue.new(
        queue_dir: queue_dir,
        worker_path: "/project/bin/memory-candidate-worker",
        spawner: spawner
      ).enqueue(event)
      second = Cyborg::MemoryCandidates::Queue.new(
        queue_dir: queue_dir,
        worker_path: "/project/bin/memory-candidate-worker",
        spawner: spawner
      ).enqueue(event.merge("received_at" => "2026-08-12T18:31:00Z"))

      assert_equal first, second
      assert_equal event, JSON.parse(File.read(first))
      assert_equal 2, calls.length
      assert_equal ["/project/bin/memory-candidate-worker", first], calls.first
    end
  end

  def test_returns_nil_when_queue_cannot_be_written
    Dir.mktmpdir do |tmpdir|
      file_instead_of_directory = File.join(tmpdir, "queue")
      File.write(file_instead_of_directory, "occupied")

      result = Cyborg::MemoryCandidates::Queue.new(
        queue_dir: file_instead_of_directory,
        worker_path: "/worker",
        spawner: ->(*) { flunk "worker should not be dispatched" }
      ).enqueue(normalized_event)

      assert_nil result
    end
  end

  private

  def normalized_event
    {
      "schema_version" => 1,
      "event" => "session_end",
      "harness" => "claude_code",
      "session_id" => "session-123",
      "transcript_path" => "/tmp/session.jsonl",
      "cwd" => "/work/project",
      "reason" => "other",
      "received_at" => "2026-08-12T18:30:00Z"
    }
  end
end
