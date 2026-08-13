# frozen_string_literal: true

require "date"
require "yaml"

module Cyborg
  module MemoryCandidates
    class MemoryEntry
      attr_reader :metadata, :path, :contents

      def self.read(path)
        contents = File.read(path)
        match = contents.match(/\A---\n(.*?)\n---\n/m)
        return unless match

        metadata = YAML.safe_load(match[1], permitted_classes: [Date, Time])
        return unless metadata.is_a?(Hash) && metadata["id"].is_a?(String)

        new(path:, contents:, metadata:)
      rescue Psych::Exception, SystemCallError
        nil
      end

      def initialize(path:, contents:, metadata:)
        @path = path
        @contents = contents
        @metadata = metadata
      end

      def id
        metadata.fetch("id")
      end

      def status
        metadata.fetch("status", "unknown")
      end

      def fingerprint
        metadata["candidate_fingerprint"]
      end

      def claim_key
        metadata["candidate_claim_key"] || Candidate.claim_key(metadata)
      rescue KeyError, TypeError
        nil
      end

      def body
        contents.sub(/\A---\n.*?\n---\n/m, "")
      end

      def with_path(new_path)
        self.class.new(path: new_path, contents:, metadata:)
      end

      def self.render(metadata, body)
        frontmatter = YAML.dump(metadata).sub(/\A---\s*\n/, "---\n")
        "#{frontmatter}---\n#{body}"
      end
    end
  end
end
