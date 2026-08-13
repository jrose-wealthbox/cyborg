# frozen_string_literal: true

require "digest"
require "json"
require "stringio"
require "tmpdir"

module Motherbrain
  module Candidates
    module Configuration
      module_function

      def enabled?(env)
        !%w[0 false no off].include?(env.fetch("MOTHERBRAIN_CANDIDATES_ENABLED", "true").downcase)
      end

      def timeout_seconds(env)
        bounded_integer(env["MOTHERBRAIN_CANDIDATE_TIMEOUT_SECONDS"], default: 20, min: 1, max: 60)
      end

      def max_transcript_bytes(env)
        bounded_integer(env["MOTHERBRAIN_CANDIDATE_MAX_BYTES"], default: TranscriptReader::DEFAULT_MAX_BYTES, min: 4096, max: 1024 * 1024)
      end

      def max_messages(env)
        bounded_integer(env["MOTHERBRAIN_CANDIDATE_MAX_MESSAGES"], default: TranscriptReader::DEFAULT_MAX_MESSAGES, min: 10, max: 500)
      end

      def bounded_integer(value, default:, min:, max:)
        number = Integer(value || default)
        number.clamp(min, max)
      rescue ArgumentError, TypeError
        default
      end
      private_class_method :bounded_integer
    end

    class EnqueueCLI
      MAX_HOOK_INPUT_BYTES = 64 * 1024

      def initialize(harness:, stdin: $stdin, env: ENV, queue: nil, now: -> { Time.now.utc })
        @harness = harness
        @stdin = stdin
        @env = env
        @queue = queue
        @now = now
      end

      def run
        return 0 unless Configuration.enabled?(@env)

        raw = @stdin.read(MAX_HOOK_INPUT_BYTES + 1)
        return 0 if raw.bytesize > MAX_HOOK_INPUT_BYTES

        event = HookNormalizer.call(harness: @harness, payload: JSON.parse(raw), now: @now.call)
        return 0 unless event

        (@queue || default_queue(event)).enqueue(event)
        0
      rescue StandardError
        0
      end

      private

      def default_queue(event)
        root_digest = Digest::SHA256.hexdigest(File.expand_path(event.fetch("cwd")))
        queue_dir = @env["MOTHERBRAIN_CANDIDATE_QUEUE_DIR"] || File.join(Dir.tmpdir, "motherbrain-memory-candidates", root_digest)
        worker_path = @env["MOTHERBRAIN_CANDIDATE_WORKER"] || File.expand_path("../../../bin/memory-candidate-worker", __dir__)
        Queue.new(queue_dir:, worker_path:)
      end
    end

    class ExtractCLI
      MAX_EVENT_BYTES = 64 * 1024

      def initialize(stdin: $stdin, stdout: $stdout, env: ENV, backend: nil)
        @stdin = stdin
        @stdout = stdout
        @env = env
        @backend = backend
      end

      def run
        ids = extract
        @stdout.puts(JSON.generate("candidate_ids" => ids))
        0
      rescue StandardError
        @stdout.puts(JSON.generate("candidate_ids" => []))
        0
      end

      private

      def extract
        return [] unless Configuration.enabled?(@env)

        raw = @stdin.read(MAX_EVENT_BYTES + 1)
        return [] if raw.bytesize > MAX_EVENT_BYTES

        event = JSON.parse(raw)
        root = event.fetch("cwd")
        reader = TranscriptReader.new(
          max_bytes: Configuration.max_transcript_bytes(@env),
          max_messages: Configuration.max_messages(@env)
        )
        Extractor.new(
          project_root: root,
          backend: @backend || CommandBackend.from_environment(@env),
          timeout_seconds: Configuration.timeout_seconds(@env),
          transcript_reader: reader
        ).call(event)
      rescue JSON::ParserError, KeyError, TypeError
        []
      end
    end

    class WorkerCLI
      def initialize(job_path:, env: ENV)
        @job_path = job_path
        @env = env
      end

      def run
        raw = File.read(@job_path, ExtractCLI::MAX_EVENT_BYTES + 1)
        ExtractCLI.new(stdin: StringIO.new(raw), stdout: StringIO.new, env: @env).run
        0
      rescue StandardError
        0
      ensure
        FileUtils.rm_f(@job_path)
      end
    end
  end
end
