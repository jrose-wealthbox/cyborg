# frozen_string_literal: true

require "digest"
require "fileutils"
require "tmpdir"

module Cyborg
  module MemoryCandidates
    class Repository
      attr_reader :memory_root

      def initialize(project_root)
        @project_root = File.expand_path(project_root)
        @memory_root = File.join(@project_root, "docs/memory")
      end

      def entries
        %w[decisions learnings candidates].flat_map do |directory|
          Dir[File.join(memory_root, directory, "*.md")]
        end.filter_map { |path| MemoryEntry.read(path) }
      end

      def find_by_fingerprint(fingerprint)
        entries.find { |entry| entry.fingerprint == fingerprint }
      end

      def find_equivalent(candidate)
        entries.find do |entry|
          entry.fingerprint == candidate.fingerprint || entry.claim_key == candidate.metadata.fetch("candidate_claim_key")
        end
      end

      def find_by_id(id)
        entries.find { |entry| entry.id == id }
      end

      def catalog(limit: 200)
        prioritized_entries.first(limit).map do |entry|
          metadata = entry.metadata
          {
            "id" => entry.id,
            "type" => metadata["type"],
            "status" => entry.status,
            "title" => metadata["title"],
            "summary" => metadata["summary"],
            "components" => Array(metadata["components"])
          }
        end
      end

      def persist(candidate)
        existing = find_equivalent(candidate)
        return existing.status == "candidate" ? existing.id : nil if existing

        with_lock do
          existing = find_equivalent(candidate)
          return existing.status == "candidate" ? existing.id : nil if existing

          write_candidate_and_index(candidate)
        end
        candidate.id
      rescue SystemCallError
        nil
      end

      def rebuild_index
        FileUtils.mkdir_p(memory_root)
        atomic_write(index_path, IndexRenderer.new(memory_root).render(entries))
      end

      def replace_entry(entry, destination:, contents:)
        with_lock do
          raise Errno::EEXIST, destination if destination != entry.path && File.exist?(destination)

          replace_entry_and_index(entry, destination, contents)
        end
        true
      rescue StandardError
        false
      end

      private

      def write_candidate_and_index(candidate)
        directory = File.join(memory_root, "candidates")
        FileUtils.mkdir_p(directory)
        path = File.join(directory, "#{candidate.id}.md")
        candidate_created = !File.exist?(path)
        candidate_temp = write_temp(path, candidate.to_markdown)

        preview_entry = MemoryEntry.read(candidate_temp).with_path(path)
        index_contents = IndexRenderer.new(memory_root).render(entries + [preview_entry])
        index_temp = write_temp(index_path, index_contents)

        File.rename(candidate_temp, path)
        File.rename(index_temp, index_path)
      rescue StandardError
        FileUtils.rm_f(path) if candidate_created && path
        raise
      ensure
        FileUtils.rm_f(candidate_temp) if candidate_temp
        FileUtils.rm_f(index_temp) if index_temp
      end

      def index_path
        File.join(memory_root, "INDEX.md")
      end

      def replace_entry_and_index(entry, destination, contents)
        original_moved = false
        replacement_installed = false
        FileUtils.mkdir_p(File.dirname(destination))
        replacement_temp = write_temp(destination, contents)
        replacement_entry = MemoryEntry.read(replacement_temp)
        raise ArgumentError, "replacement is not a valid memory entry" unless replacement_entry

        replacement_entry = replacement_entry.with_path(destination)
        new_entries = entries.reject { |existing| existing.id == entry.id } + [replacement_entry]
        index_temp = write_temp(index_path, IndexRenderer.new(memory_root).render(new_entries))
        backup = "#{entry.path}.transition-#{Process.pid}-#{rand(1_000_000)}"

        File.rename(entry.path, backup)
        original_moved = true
        File.rename(replacement_temp, destination)
        replacement_installed = true
        File.rename(index_temp, index_path)
        FileUtils.rm_f(backup)
      rescue StandardError
        FileUtils.rm_f(destination) if replacement_installed
        File.rename(backup, entry.path) if original_moved && File.exist?(backup)
        raise
      ensure
        FileUtils.rm_f(replacement_temp) if replacement_temp
        FileUtils.rm_f(index_temp) if index_temp
      end

      def atomic_write(path, contents)
        temp = write_temp(path, contents)
        File.rename(temp, path)
      ensure
        FileUtils.rm_f(temp) if temp
      end

      def write_temp(target, contents)
        FileUtils.mkdir_p(File.dirname(target))
        path = "#{target}.tmp-#{Process.pid}-#{rand(1_000_000)}"
        File.open(path, "wb", 0o600) do |file|
          file.write(contents)
          file.flush
          file.fsync
        end
        path
      end

      def with_lock
        digest = Digest::SHA256.hexdigest(@project_root)
        lock_path = File.join(Dir.tmpdir, "cyborg-memory-candidates-#{digest}.lock")
        File.open(lock_path, "w", 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      def prioritized_entries
        entries.sort do |left, right|
          rank = status_rank(left.status) <=> status_rank(right.status)
          next rank unless rank.zero?

          right.metadata["updated_at"].to_s <=> left.metadata["updated_at"].to_s
        end
      end

      def status_rank(status)
        {"active" => 0, "candidate" => 1}.fetch(status, 2)
      end
    end
  end
end
