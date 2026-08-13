# frozen_string_literal: true

require "json"
require "open3"
require "shellwords"
require "timeout"

module Cyborg
  module MemoryCandidates
    class CommandBackend
      ENV_KEY = "CYBORG_MEMORY_CANDIDATE_BACKEND"
      MAX_OUTPUT_BYTES = 1024 * 1024

      def self.from_environment(env = ENV)
        command = env[ENV_KEY]
        return unless command.is_a?(String) && !command.strip.empty?

        argv = Shellwords.split(command)
        new(argv) unless argv.empty?
      rescue ArgumentError
        nil
      end

      def initialize(argv)
        @argv = argv
      end

      def analyze(packet:, timeout_seconds:)
        stdout_text = nil
        status = nil

        Open3.popen3(*@argv, pgroup: true) do |stdin, stdout, stderr, wait_thread|
          stdin.write(JSON.generate(packet))
          stdin.close
          stdout_reader = Thread.new { stdout.read(MAX_OUTPUT_BYTES + 1) }
          stderr_reader = Thread.new { stderr.read(MAX_OUTPUT_BYTES + 1) }

          begin
            Timeout.timeout(timeout_seconds) do
              stdout_text = stdout_reader.value
              stderr_reader.value
              status = wait_thread.value
            end
          rescue Timeout::Error
            terminate(wait_thread.pid)
            stdout_reader.kill
            stderr_reader.kill
            return nil
          end
        end

        return unless status&.success?
        return unless stdout_text && stdout_text.bytesize <= MAX_OUTPUT_BYTES

        JSON.parse(stdout_text)
      rescue JSON::ParserError, JSON::GeneratorError, SystemCallError, IOError
        nil
      end

      private

      def terminate(pid)
        # Kill the process group because configured backends may launch their own provider CLI subprocess.
        Process.kill("TERM", -pid)
        sleep 0.02
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
        nil
      end
    end
  end
end
