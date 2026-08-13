# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"
require "securerandom"
require "time"

module Cyborg
  module Bridge
    class ArtifactStore
      DEFAULT_MAX_BYTES = 1_048_576
      DEFAULT_AUDIT_ENTRIES = 100
      AUDIT_FILENAME = "artifact-audit.json"

      attr_reader :root, :max_bytes

      def initialize(root: nil, directory: nil, artifact_dir: nil, path: nil, max_bytes: DEFAULT_MAX_BYTES, max_size: nil,
                     retention_seconds: nil, audit_entries: DEFAULT_AUDIT_ENTRIES)
        root ||= directory || artifact_dir || path
        raise ArgumentError, "artifact root is required" if root.nil?

        @root = Pathname(root).expand_path
        @max_bytes = Integer(max_size || max_bytes)
        @retention_seconds = retention_seconds
        @audit_entries = Integer(audit_entries)
        raise ArgumentError, "max_bytes must be positive" unless @max_bytes.positive?
        raise ArgumentError, "audit_entries must be positive" unless @audit_entries.positive?

        ensure_directory(@root)
      end

      def write(run_id:, filename:, envelope:)
        run_id = safe_segment(run_id, "run_id")
        filename = safe_filename(filename)
        unless envelope.is_a?(Hash)
          raise Cyborg::InvalidArtifact.new("bridge.invalid_envelope", exit_status: 65)
        end

        expected_type = envelope["artifact_type"]
        Envelope.validate!(envelope, expected_type: expected_type, expected_run_id: run_id)
        bytes = CanonicalJSON.dump(envelope).encode(Encoding::UTF_8)
        if bytes.bytesize > @max_bytes
          raise Cyborg::UnsafeArtifact.new("bridge.oversized_file", exit_status: 65)
        end

        directory = @root.join(run_id)
        ensure_directory(directory)
        target = directory.join(filename)
        atomic_write(target, bytes)
        target
      end

      def read(path:, expected_type:, expected_run_id:)
        path = Pathname(path)
        ensure_path_is_beneath_root!(path)
        stat = safe_lstat(path)
        unless stat.file?
          raise Cyborg::UnsafeArtifact.new("bridge.unsafe_file", exit_status: 65)
        end
        if stat.size > @max_bytes
          raise Cyborg::UnsafeArtifact.new("bridge.oversized_file", exit_status: 65)
        end

        document = JSON.parse(File.binread(path.to_s))
        Envelope.validate!(document, expected_type: expected_type, expected_run_id: expected_run_id)
      rescue JSON::ParserError, EncodingError
        raise Cyborg::InvalidArtifact.new("bridge.invalid_json", exit_status: 65)
      end

      # Removes payload files older than the retention window and writes only
      # bounded, redacted metadata to a per-run audit file.
      def cleanup!(now: Time.now.utc, retention_seconds: @retention_seconds)
        return [] if retention_seconds.nil?

        cutoff = now - Integer(retention_seconds)
        removed = []
        each_run_directory do |run_directory|
          Dir.children(run_directory.to_s).each do |entry|
            next if entry == AUDIT_FILENAME || entry.start_with?(".")

            path = run_directory.join(entry)
            stat = safe_lstat(path, raise_on_missing: false)
            next unless stat&.file?

            metadata = metadata_for(path, expected_run_id: run_directory.basename.to_s)
            next unless Time.iso8601(metadata.fetch("created_at")) < cutoff

            append_audit(run_directory, metadata.merge("deleted_at" => now.utc.iso8601))
            File.delete(path.to_s)
            removed << path
          end
        end
        removed
      end

      alias cleanup cleanup!

      private

      def ensure_directory(path)
        begin
          stat = path.lstat
          if stat.symlink? || !stat.directory?
            raise Cyborg::UnsafeArtifact.new("bridge.unsafe_file", exit_status: 65)
          end
        rescue Errno::ENOENT
          FileUtils.mkdir_p(path.to_s)
        end
        File.chmod(0o700, path.to_s)
        path
      end

      def each_run_directory
        Dir.children(@root.to_s).each do |entry|
          path = @root.join(entry)
          stat = safe_lstat(path, raise_on_missing: false)
          yield path if stat&.directory? && !stat.symlink?
        end
      end

      def safe_lstat(path, raise_on_missing: true)
        stat = path.lstat
        if stat.symlink?
          raise Cyborg::UnsafeArtifact.new("bridge.unsafe_file", exit_status: 65)
        end
        stat
      rescue Errno::ENOENT
        raise if raise_on_missing

        nil
      end

      def ensure_path_is_beneath_root!(path)
        absolute = path.expand_path
        root_absolute = @root.expand_path
        unless absolute == root_absolute || absolute.to_s.start_with?("#{root_absolute}#{File::SEPARATOR}")
          raise Cyborg::UnsafeArtifact.new("bridge.unsafe_path", exit_status: 65)
        end

        relative_parts = absolute.relative_path_from(root_absolute).each_filename.to_a
        current = root_absolute
        relative_parts[0...-1].each do |part|
          current = current.join(part)
          stat = current.lstat
          if stat.symlink? || !stat.directory?
            raise Cyborg::UnsafeArtifact.new("bridge.unsafe_file", exit_status: 65)
          end
        end
      rescue ArgumentError, Errno::ENOENT
        raise Cyborg::UnsafeArtifact.new("bridge.unsafe_path", exit_status: 65)
      end

      def safe_segment(value, label)
        segment = value.to_s
        unless segment.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/)
          raise Cyborg::UnsafeArtifact.new("bridge.unsafe_path", "Invalid #{label}", exit_status: 65)
        end
        segment
      end

      def safe_filename(value)
        filename = value.to_s
        unless filename.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/)
          raise Cyborg::UnsafeArtifact.new("bridge.unsafe_path", "Invalid filename", exit_status: 65)
        end
        filename
      end

      def atomic_write(target, bytes)
        temporary = target.dirname.join(".#{target.basename}.tmp-#{Process.pid}-#{SecureRandom.hex(8)}")
        begin
          File.open(temporary.to_s, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
            file.binmode
            file.write(bytes)
            file.flush
            file.fsync
          end
          File.chmod(0o600, temporary.to_s)
          File.rename(temporary.to_s, target.to_s)
          begin
            File.open(target.dirname.to_s, "r") { |directory| directory.fsync }
          rescue SystemCallError
            # Directory fsync is not available on every supported filesystem;
            # the file itself was flushed and fsynced before the rename.
          end
        ensure
          File.delete(temporary.to_s) if File.exist?(temporary.to_s)
        end
      end

      def metadata_for(path, expected_run_id:)
        stat = safe_lstat(path)
        unless stat.file?
          raise Cyborg::UnsafeArtifact.new("bridge.unsafe_file", exit_status: 65)
        end
        if stat.size > @max_bytes
          raise Cyborg::UnsafeArtifact.new("bridge.oversized_file", exit_status: 65)
        end

        document = JSON.parse(File.binread(path.to_s))
        Envelope.validate!(document, expected_type: document["artifact_type"], expected_run_id: expected_run_id)
        {
          "run_id" => document.fetch("run_id"),
          "artifact_type" => document.fetch("artifact_type"),
          "created_at" => document.fetch("created_at"),
          "payload_sha256" => document.fetch("payload_sha256")
        }
      rescue JSON::ParserError, EncodingError
        raise Cyborg::InvalidArtifact.new("bridge.invalid_json", exit_status: 65)
      end

      def append_audit(directory, entry)
        path = directory.join(AUDIT_FILENAME)
        current = read_audit_entries(path)
        current = current.is_a?(Array) ? current : []
        current = current.map { |item| Redactor.new.call(item) }
        current << Redactor.new.call(entry)
        current = current.last(@audit_entries)
        bytes = bounded_audit_bytes(current, entry)
        atomic_write(path, bytes)
      end

      def read_audit_entries(path)
        stat = safe_lstat(path, raise_on_missing: false)
        return [] if stat.nil?
        unless stat.file?
          raise Cyborg::UnsafeArtifact.new("bridge.unsafe_file", exit_status: 65)
        end
        if stat.size > @max_bytes
          raise Cyborg::UnsafeArtifact.new("bridge.oversized_file", exit_status: 65)
        end

        document = JSON.parse(File.binread(path.to_s))
        document.fetch("entries", [])
      rescue JSON::ParserError, EncodingError, KeyError
        raise Cyborg::InvalidArtifact.new("bridge.invalid_json", exit_status: 65)
      end

      def bounded_audit_bytes(entries, fallback)
        current = entries.dup
        loop do
          bytes = CanonicalJSON.dump({"entries" => current}).encode(Encoding::UTF_8)
          return bytes if bytes.bytesize <= @max_bytes
          break if current.length <= 1

          current.shift
        end

        # Keep a bounded, redacted diagnostic even when a pre-existing entry
        # contains unexpectedly large optional fields.
        safe_fallback = Redactor.new.call(fallback).slice("run_id", "artifact_type", "created_at", "payload_sha256", "deleted_at")
        bytes = CanonicalJSON.dump({"entries" => [safe_fallback]}).encode(Encoding::UTF_8)
        raise Cyborg::UnsafeArtifact.new("bridge.oversized_file", exit_status: 65) if bytes.bytesize > @max_bytes

        bytes
      end
    end
  end
end
