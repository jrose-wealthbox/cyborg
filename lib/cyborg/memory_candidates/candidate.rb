# frozen_string_literal: true

require "digest"
require "json"
require "yaml"

module Cyborg
  module MemoryCandidates
    class Candidate
      COMMON_FIELDS = %w[type title summary rationale tags components evidence].freeze
      TYPE_FIELDS = {
        "decision" => %w[decision context alternatives consequences revisit_when],
        "learning" => %w[observation insight implication verification]
      }.freeze
      ARRAY_FIELDS = %w[tags components evidence alternatives consequences].freeze

      attr_reader :metadata

      def self.build(raw:, event:, transcript:, extracted_at:, redactor: Redactor.new)
        return unless raw.is_a?(Hash)
        return if redactor.suspicious_instruction?(raw)

        sanitized = redactor.redact(raw)
        type = sanitized["type"]
        required = COMMON_FIELDS + TYPE_FIELDS.fetch(type) { return }
        return unless required.all? { |field| valid_field?(field, sanitized[field]) }

        new(sanitized, event, transcript, extracted_at)
      end

      def self.fingerprint(raw)
        type = raw.fetch("type")
        fields = (COMMON_FIELDS + TYPE_FIELDS.fetch(type)).to_h { |field| [field, raw[field]] }
        canonical = canonicalize(fields)
        "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical))}"
      end

      def self.claim_key(raw)
        claim = %w[type title summary].to_h { |field| [field, raw[field]] }
        normalized = canonicalize(claim).transform_values { |value| value.downcase }
        "sha256:#{Digest::SHA256.hexdigest(JSON.generate(normalized))}"
      end

      def self.valid_field?(field, value)
        if ARRAY_FIELDS.include?(field)
          value.is_a?(Array) && !value.empty? && value.all? { |item| item.is_a?(String) && !item.strip.empty? }
        else
          value.is_a?(String) && !value.strip.empty?
        end
      end
      private_class_method :valid_field?

      def self.canonicalize(value)
        case value
        when Hash
          value.keys.sort.to_h { |key| [key, canonicalize(value[key])] }
        when Array
          value.map { |item| canonicalize(item) }
        when String
          value.strip.gsub(/\s+/, " ")
        else
          value
        end
      end
      private_class_method :canonicalize

      def initialize(data, event, transcript, extracted_at)
        @data = data
        fingerprint = self.class.fingerprint(data)
        prefix = data.fetch("type") == "decision" ? "ADR" : "LRN"
        @metadata = {
          "id" => "#{prefix}-CAND-#{fingerprint.delete_prefix("sha256:")[0, 16]}",
          "type" => data.fetch("type"),
          "status" => "candidate",
          "title" => data.fetch("title"),
          "summary" => data.fetch("summary"),
          "created_at" => extracted_at,
          "updated_at" => extracted_at,
          "last_verified_at" => nil,
          "tags" => data.fetch("tags"),
          "components" => data.fetch("components"),
          "supersedes" => [],
          "superseded_by" => nil,
          "candidate_fingerprint" => fingerprint,
          "candidate_claim_key" => self.class.claim_key(data),
          "candidate_harness" => event.fetch("harness"),
          "candidate_session_id" => event.fetch("session_id"),
          "candidate_transcript_sha256" => transcript.fetch("sha256"),
          "candidate_extracted_at" => extracted_at,
          "candidate_rationale" => data.fetch("rationale")
        }
      end

      def id
        metadata.fetch("id")
      end

      def fingerprint
        metadata.fetch("candidate_fingerprint")
      end

      def to_markdown
        frontmatter = YAML.dump(metadata).sub(/\A---\s*\n/, "---\n")
        "#{frontmatter}---\n#{body}"
      end

      private

      def body
        sections = [
          [@data.fetch("title"), nil],
          ["Candidate notice", "This entry was extracted automatically from session evidence. It is searchable but is not authoritative until explicitly promoted."],
          [@data.fetch("type") == "decision" ? "Decision" : "Observation", @data.fetch(@data.fetch("type") == "decision" ? "decision" : "observation")]
        ]

        if @data.fetch("type") == "decision"
          sections.concat([
            ["Context", @data.fetch("context")],
            ["Alternatives considered", bullets(@data.fetch("alternatives"))],
            ["Consequences", bullets(@data.fetch("consequences"))],
            ["Evidence", bullets(@data.fetch("evidence"))],
            ["Revisit when", @data.fetch("revisit_when")]
          ])
        else
          sections.concat([
            ["Cause or insight", @data.fetch("insight")],
            ["Implication", @data.fetch("implication")],
            ["Verification", @data.fetch("verification")],
            ["Evidence", bullets(@data.fetch("evidence"))]
          ])
        end

        sections.map do |heading, content|
          content ? "## #{heading}\n\n#{content}" : "# #{heading}"
        end.join("\n\n") + "\n"
      end

      def bullets(items)
        items.map { |item| "- #{item}" }.join("\n")
      end
    end
  end
end
