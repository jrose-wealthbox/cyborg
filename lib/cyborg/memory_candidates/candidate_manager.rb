# frozen_string_literal: true

module Cyborg
  module MemoryCandidates
    class CandidateManager
      def initialize(project_root, now: -> { Time.now.utc })
        @repository = Repository.new(project_root)
        @now = now
      end

      def promote(id)
        entry = pending_candidate(id)
        return unless entry

        timestamp = @now.call.utc
        promoted_id = promoted_id_for(entry, timestamp)
        metadata = entry.metadata.merge(
          "id" => promoted_id,
          "status" => "active",
          "updated_at" => timestamp.iso8601,
          "last_verified_at" => timestamp.iso8601,
          "promoted_from" => entry.id,
          "promoted_at" => timestamp.iso8601
        )
        body = entry.body.sub(
          /## Candidate notice\n\n.*?\n\n(?=## )/m,
          ""
        )
        directory = metadata.fetch("type") == "decision" ? "decisions" : "learnings"
        destination = File.join(@repository.memory_root, directory, "#{promoted_id}.md")

        promoted_id if @repository.replace_entry(entry, destination:, contents: MemoryEntry.render(metadata, body))
      end

      def dismiss(id, reason:)
        entry = pending_candidate(id)
        return unless entry
        return unless reason.is_a?(String) && !reason.strip.empty?

        timestamp = @now.call.utc.iso8601
        metadata = entry.metadata.merge(
          "status" => "dismissed",
          "updated_at" => timestamp,
          "dismissed_at" => timestamp,
          "dismissal_reason" => reason.strip
        )

        entry.id if @repository.replace_entry(
          entry,
          destination: entry.path,
          contents: MemoryEntry.render(metadata, entry.body)
        )
      end

      private

      def pending_candidate(id)
        entry = @repository.find_by_id(id)
        entry if entry&.status == "candidate" && File.dirname(entry.path) == File.join(@repository.memory_root, "candidates")
      end

      def promoted_id_for(entry, timestamp)
        prefix = entry.metadata.fetch("type") == "decision" ? "ADR" : "LRN"
        slug = entry.metadata.fetch("title").downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-+\z/, "")[0, 50].to_s.gsub(/-+\z/, "")
        slug = "memory-entry-#{entry.fingerprint.to_s.delete_prefix("sha256:")[0, 8]}" if slug.empty?
        base = "#{prefix}-#{timestamp.strftime("%Y%m%d")}-#{slug}"
        return base unless @repository.find_by_id(base)

        "#{base}-#{entry.fingerprint.to_s.delete_prefix("sha256:")[0, 8]}"
      end
    end
  end
end
