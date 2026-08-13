# frozen_string_literal: true

require "fileutils"
require "fiddle/import"
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

        document = JSON.parse(read_bounded_bytes(path))
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
        with_directory_fd(@root.to_s) do |root_fd|
          entries_for_fd(root_fd).each do |run_id|
            next if run_id.start_with?(".")

            with_openat_fd(root_fd, run_id) do |run_fd|
              entries_for_fd(run_fd).each do |entry|
            next if entry == AUDIT_FILENAME || entry.start_with?(".")

                metadata = metadata_for_fd(run_fd:, filename: entry, expected_run_id: run_id)
                next unless metadata
                next unless Time.iso8601(metadata.fetch("created_at")) < cutoff

                append_audit_fd(run_fd, metadata.merge("deleted_at" => now.utc.iso8601))
                unlinkat(run_fd, entry)
                removed << @root.join(run_id, entry)
              end
            end
          end
        end
        removed
      end

      alias cleanup cleanup!

      # Records bounded, redacted bridge-validation metadata without retaining
      # submitted source or analysis payloads. These entries share the audit
      # file used by retention cleanup and remain after payload cleanup.
      def record_validation_failure!(run_id:, code:, command:, at: Time.now.utc, **metadata)
        run_id = safe_segment(run_id, "run_id")
        now = at.is_a?(Time) ? at.utc.iso8601 : Time.iso8601(at.to_s).utc.iso8601
        directory = @root.join(run_id)
        ensure_directory(directory)
        append_audit(directory, {
          "run_id" => run_id, "artifact_type" => "bridge_validation_failure", "code" => code.to_s,
          "command" => command.to_s, "created_at" => now
        }.merge(metadata.transform_keys(&:to_s)))
        directory.join(AUDIT_FILENAME)
      rescue ArgumentError
        raise Cyborg::PersistenceError.new("bridge.invalid_audit_timestamp")
      end

      private

      module NativeCleanup
        extend Fiddle::Importer
        dlload Fiddle.dlopen(nil)
        extern "int open(const char *, int)"
        extern "int openat(int, const char *, int, int)"
        extern "int unlinkat(int, const char *, int)"
        extern "int renameat(int, const char *, int, const char *)"
        extern "int fchmod(int, int)"
      end

      CLEANUP_RDONLY = 0
      CLEANUP_WRONLY = 1
      CLEANUP_CREAT = 0x200
      CLEANUP_TRUNC = 0x400
      CLEANUP_EXCL = 0x800
      CLEANUP_NOFOLLOW = File::NOFOLLOW

      def with_directory_fd(path)
        fd = NativeCleanup.open(path.to_s, CLEANUP_RDONLY | CLEANUP_NOFOLLOW)
        raise Cyborg::UnsafeArtifact.new("bridge.unsafe_file", exit_status: 65) if fd.negative?

        io = IO.for_fd(fd, autoclose: true)
        raise Cyborg::UnsafeArtifact.new("bridge.unsafe_file", exit_status: 65) unless io.stat.directory?
        yield io.fileno
      rescue SystemCallError, IOError
        raise Cyborg::UnsafeArtifact.new("bridge.unsafe_file", exit_status: 65)
      ensure
        io&.close unless io&.closed?
      end

      def with_openat_fd(parent_fd, name)
        fd = NativeCleanup.openat(parent_fd, name.to_s, CLEANUP_RDONLY | CLEANUP_NOFOLLOW, 0)
        return if fd.negative? && cleanup_errno == Errno::ENOENT::Errno
        raise Cyborg::UnsafeArtifact.new("bridge.unsafe_file", exit_status: 65) if fd.negative?

        io = IO.for_fd(fd, autoclose: true)
        raise Cyborg::UnsafeArtifact.new("bridge.unsafe_file", exit_status: 65) unless io.stat.directory?
        yield io.fileno
      rescue SystemCallError, IOError
        raise Cyborg::UnsafeArtifact.new("bridge.unsafe_file", exit_status: 65)
      ensure
        io&.close unless io&.closed?
      end

      def entries_for_fd(fd)
        duplicate = IO.for_fd(fd, autoclose: false).dup
        duplicate.autoclose = false
        directory = Dir.for_fd(duplicate.fileno)
        directory.children
      ensure
        directory&.close
      end

      def metadata_for_fd(run_fd:, filename:, expected_run_id:)
        bytes = read_bounded_bytes_fd(run_fd, filename)
        return nil if bytes.nil?

        document = JSON.parse(bytes)
        unless document.is_a?(Hash)
          raise Cyborg::InvalidArtifact.new("bridge.invalid_envelope", exit_status: 65)
        end
        Envelope.validate!(document, expected_type: document["artifact_type"], expected_run_id: expected_run_id)
        {
          "run_id" => document.fetch("run_id"), "artifact_type" => document.fetch("artifact_type"),
          "created_at" => document.fetch("created_at"), "payload_sha256" => document.fetch("payload_sha256")
        }
      rescue JSON::ParserError, EncodingError
        raise Cyborg::InvalidArtifact.new("bridge.invalid_json", exit_status: 65)
      end

      def read_bounded_bytes_fd(parent_fd, filename, allow_missing: false)
        fd = NativeCleanup.openat(parent_fd, filename.to_s, CLEANUP_RDONLY | CLEANUP_NOFOLLOW, 0)
        if fd.negative?
          return nil if cleanup_errno == Errno::ENOENT::Errno
          raise Cyborg::UnsafeArtifact.new("bridge.unsafe_file", exit_status: 65)
        end
        io = IO.for_fd(fd, autoclose: true)
        stat = io.stat
        raise Cyborg::UnsafeArtifact.new("bridge.unsafe_file", exit_status: 65) unless stat.file?
        raise Cyborg::UnsafeArtifact.new("bridge.oversized_file", exit_status: 65) if stat.size > @max_bytes

        io.binmode
        bytes = io.read(@max_bytes + 1) || "".b
        raise Cyborg::UnsafeArtifact.new("bridge.oversized_file", exit_status: 65) if bytes.bytesize > @max_bytes
        bytes
      rescue SystemCallError, IOError
        raise Cyborg::UnsafeArtifact.new("bridge.unsafe_file", exit_status: 65)
      ensure
        io&.close unless io&.closed?
      end

      def append_audit_fd(run_fd, entry)
        current = read_audit_entries_fd(run_fd)
        current = current.is_a?(Array) ? current : []
        current = current.map { |item| Redactor.new.call(item) }
        current << Redactor.new.call(entry)
        bytes = bounded_audit_bytes(current.last(@audit_entries), entry)
        temp_name = ".artifact-audit-#{SecureRandom.hex(8)}.tmp"
        fd = NativeCleanup.openat(run_fd, temp_name, CLEANUP_WRONLY | CLEANUP_CREAT | CLEANUP_EXCL | CLEANUP_NOFOLLOW, 0o600)
        raise Cyborg::UnsafeArtifact.new("bridge.unsafe_file", exit_status: 65) if fd.negative?
        io = IO.for_fd(fd, autoclose: true)
        raise Cyborg::UnsafeArtifact.new("bridge.unsafe_file", exit_status: 65) unless NativeCleanup.fchmod(fd, 0o600).zero?
        io.binmode
        io.write(bytes)
        io.flush
        io.fsync
        io.close
        raise Cyborg::UnsafeArtifact.new("bridge.unsafe_file", exit_status: 65) unless NativeCleanup.renameat(run_fd, temp_name, run_fd, AUDIT_FILENAME).zero?
      rescue SystemCallError, IOError
        raise Cyborg::UnsafeArtifact.new("bridge.unsafe_file", exit_status: 65)
      ensure
        io&.close unless io&.closed?
        NativeCleanup.unlinkat(run_fd, temp_name, 0) if temp_name && fd && !fd.negative?
      end

      def read_audit_entries_fd(run_fd)
        bytes = read_bounded_bytes_fd(run_fd, AUDIT_FILENAME, allow_missing: true)
        return [] if bytes.nil?
        document = JSON.parse(bytes)
        raise Cyborg::InvalidArtifact.new("bridge.invalid_envelope", exit_status: 65) unless document.is_a?(Hash)
        entries = document.fetch("entries", [])
        raise Cyborg::InvalidArtifact.new("bridge.invalid_envelope", exit_status: 65) unless entries.is_a?(Array)
        entries
      rescue JSON::ParserError, EncodingError, KeyError
        raise Cyborg::InvalidArtifact.new("bridge.invalid_json", exit_status: 65)
      end

      def unlinkat(parent_fd, filename)
        return if NativeCleanup.unlinkat(parent_fd, filename.to_s, 0).zero?

        raise Cyborg::UnsafeArtifact.new("bridge.unsafe_file", exit_status: 65)
      end

      def cleanup_errno
        Fiddle.last_error
      end

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
        document = JSON.parse(read_bounded_bytes(path))
        unless document.is_a?(Hash)
          raise Cyborg::InvalidArtifact.new("bridge.invalid_envelope", exit_status: 65)
        end
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
        bytes = read_bounded_bytes(path, allow_missing: true)
        return [] if bytes.nil?

        document = JSON.parse(bytes)
        unless document.is_a?(Hash)
          raise Cyborg::InvalidArtifact.new("bridge.invalid_envelope", exit_status: 65)
        end

        entries = document.fetch("entries", [])
        unless entries.is_a?(Array)
          raise Cyborg::InvalidArtifact.new("bridge.invalid_envelope", exit_status: 65)
        end

        entries
      rescue JSON::ParserError, EncodingError, KeyError
        raise Cyborg::InvalidArtifact.new("bridge.invalid_json", exit_status: 65)
      end

      def read_bounded_bytes(path, allow_missing: false)
        flags = File::RDONLY | File::NOFOLLOW | File::NONBLOCK
        File.open(path.to_s, flags) do |file|
          stat = file.stat
          unless stat.file?
            raise Cyborg::UnsafeArtifact.new("bridge.unsafe_file", exit_status: 65)
          end
          if stat.size > @max_bytes
            raise Cyborg::UnsafeArtifact.new("bridge.oversized_file", exit_status: 65)
          end

          file.binmode
          bytes = file.read(@max_bytes + 1) || "".b
          if bytes.bytesize > @max_bytes
            raise Cyborg::UnsafeArtifact.new("bridge.oversized_file", exit_status: 65)
          end

          bytes
        end
      rescue Errno::ENOENT
        return nil if allow_missing

        raise Cyborg::UnsafeArtifact.new("bridge.unsafe_file", exit_status: 65)
      rescue Errno::ELOOP, Errno::ENOTDIR, Errno::EISDIR
        raise Cyborg::UnsafeArtifact.new("bridge.unsafe_file", exit_status: 65)
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
