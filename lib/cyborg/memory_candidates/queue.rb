# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "rbconfig"

module Cyborg
  module MemoryCandidates
    class Queue
      def initialize(queue_dir:, worker_path:, spawner: nil)
        @queue_dir = queue_dir
        @worker_path = worker_path
        @spawner = spawner || method(:spawn_detached)
      end

      def enqueue(event)
        FileUtils.mkdir_p(@queue_dir, mode: 0o700)
        job_path = File.join(@queue_dir, "#{job_id(event)}.json")
        write_once(job_path, event)
        @spawner.call(@worker_path, job_path)
        job_path
      rescue SystemCallError, JSON::GeneratorError, TypeError
        nil
      end

      private

      def job_id(event)
        identity = event.reject { |key, _value| key == "received_at" }
        Digest::SHA256.hexdigest(JSON.generate(identity.sort.to_h))
      end

      def write_once(path, event)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(JSON.generate(event))
          file.flush
          file.fsync
        end
      rescue Errno::EEXIST
        # Session-end delivery is advisory and may repeat. The content-derived path makes replay safe.
      end

      def spawn_detached(worker_path, job_path)
        pid = Process.spawn(
          RbConfig.ruby,
          worker_path,
          job_path,
          in: File::NULL,
          out: File::NULL,
          err: File::NULL,
          pgroup: true
        )
        Process.detach(pid)
        pid
      end
    end
  end
end
