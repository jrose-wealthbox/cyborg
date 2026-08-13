# frozen_string_literal: true

require "timeout"

module Cyborg
  # The result of one bounded direct child-process invocation. `status` is the
  # process exit status when it is available; no command output is logged by
  # this class.
  ProcessResult = Data.define(:stdout, :stderr, :status, :timed_out, :truncated) do
    def success?
      status.to_i.zero? && !timed_out && !truncated
    end

    alias exit_status status
  end

  # Executes an argv array without a shell and applies a wall-clock and output
  # byte bound. The adapter layer decides which output, if any, is safe to
  # expose; this runner never persists or prints child output.
  class ProcessRunner
    DEFAULT_TIMEOUT = 30
    DEFAULT_MAX_BYTES = 1_048_576
    READ_SIZE = 16 * 1024
    POLL_SECONDS = 0.02

    def capture(argv:, timeout:, max_bytes:, env: {})
      argv = Array(argv)
      raise ArgumentError, "argv must contain a command" if argv.empty? || argv.any? { |value| !value.is_a?(String) || value.empty? }

      timeout = normalize_timeout(timeout)
      max_bytes = normalize_max_bytes(max_bytes)
      environment = normalize_env(env)
      stdout_reader, stdout_writer = IO.pipe
      stderr_reader, stderr_writer = IO.pipe
      pid = Process.spawn(environment, *argv, out: stdout_writer, err: stderr_writer, close_others: true)
      stdout_writer.close
      stderr_writer.close

      readers = {stdout_reader => String.new(encoding: Encoding::BINARY), stderr_reader => String.new(encoding: Encoding::BINARY)}
      outputs = readers.dup
      status = nil
      timed_out = false
      truncated = false
      deadline = monotonic_now + timeout

      until readers.empty? && status
        if timeout_expired?(deadline)
          timed_out = true
          terminate(pid)
        end

        ready = IO.select(readers.keys, nil, nil, POLL_SECONDS)
        Array(ready&.first).each do |reader|
          begin
            remaining = max_bytes - outputs.values.sum(&:bytesize)
            chunk = reader.read_nonblock([READ_SIZE, [remaining, 0].max + 1].min)
            if remaining.positive?
              outputs.fetch(reader) << chunk.byteslice(0, remaining)
              truncated = true if chunk.bytesize > remaining
            else
              truncated = true unless chunk.empty?
            end
            terminate(pid) if truncated
          rescue IO::WaitReadable
            next
          rescue EOFError
            reader.close unless reader.closed?
            readers.delete(reader)
          end
        end

        if status.nil?
          waited = Process.waitpid(pid, Process::WNOHANG)
          status = waited && $?
        end
      end

      ProcessResult.new(
        stdout: outputs.fetch(stdout_reader, String.new(encoding: Encoding::BINARY)),
        stderr: outputs.fetch(stderr_reader, String.new(encoding: Encoding::BINARY)),
        status: status&.exitstatus,
        timed_out: timed_out,
        truncated: truncated
      )
    rescue Errno::ENOENT
      raise
    ensure
      [stdout_reader, stdout_writer, stderr_reader, stderr_writer].compact.each do |io|
        io.close unless io.closed?
      end
      if pid && status.nil?
        terminate(pid)
        Process.waitpid(pid) rescue nil
      end
    end

    private

    def normalize_timeout(value)
      value = DEFAULT_TIMEOUT if value.nil?
      value = value.to_f
      raise ArgumentError, "timeout must be positive" unless value.positive?

      value
    end

    def normalize_max_bytes(value)
      value = DEFAULT_MAX_BYTES if value.nil?
      value = Integer(value)
      raise ArgumentError, "max_bytes must be positive" unless value.positive?

      value
    rescue ArgumentError, TypeError
      raise ArgumentError, "max_bytes must be a positive integer"
    end

    def normalize_env(value)
      return {} if value.nil?
      raise ArgumentError, "env must be a hash" unless value.is_a?(Hash)

      value.each_with_object({}) { |(key, item), result| result[key.to_s] = item.to_s }
    end

    def timeout_expired?(deadline)
      monotonic_now >= deadline
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def terminate(pid)
      Process.kill("TERM", pid)
      Process.kill("KILL", pid) rescue nil
    rescue Errno::ESRCH
      nil
    end
  end
end
