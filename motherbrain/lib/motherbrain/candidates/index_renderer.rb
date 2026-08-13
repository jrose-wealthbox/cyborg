# frozen_string_literal: true

module Motherbrain
  module Candidates
    class IndexRenderer
      def initialize(memory_root)
        @memory_root = memory_root
      end

      def render(entries)
        active, non_active = entries.partition { |entry| entry.status == "active" }
        candidates, historical = non_active.partition { |entry| entry.status == "candidate" }

        <<~MARKDOWN
          # Project memory index

          This is a compact retrieval catalog. Read the linked entry before using it for a consequential change.

          ## Accepted active memories

          #{table(active)}

          ## Candidates

          Candidates are searchable evidence with lower authority than accepted memories. Review and promote them explicitly before treating them as project truth.

          #{table(candidates)}

          ## Historical and dismissed memories

          #{table(historical)}
        MARKDOWN
      end

      private

      def table(entries)
        header = "| ID | Type | Status | Updated | Last verified | Topic/components | Summary | Entry |\n" \
          "| --- | --- | --- | --- | --- | --- | --- | --- |"
        rows = entries.sort_by { |entry| sort_key(entry) }.reverse.map { |entry| row(entry) }
        ([header] + rows).join("\n")
      end

      def sort_key(entry)
        metadata = entry.metadata
        [metadata["last_verified_at"].to_s, metadata["updated_at"].to_s, entry.id]
      end

      def row(entry)
        metadata = entry.metadata
        values = [
          entry.id,
          metadata["type"],
          entry.status,
          metadata["updated_at"],
          metadata["last_verified_at"] || "not verified",
          Array(metadata["components"]).join(", "),
          metadata["summary"],
          "[entry](#{relative_path(entry.path)})"
        ]
        "| #{values.map { |value| escape(value) }.join(" | ")} |"
      end

      def relative_path(path)
        path.delete_prefix("#{@memory_root}/")
      end

      def escape(value)
        value.to_s.gsub("|", "\\|").gsub(/\s+/, " ").strip
      end
    end
  end
end
