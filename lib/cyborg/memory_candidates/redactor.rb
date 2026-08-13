# frozen_string_literal: true

module Cyborg
  module MemoryCandidates
    class Redactor
      REDACTION = "[REDACTED]"
      SECRET_PATTERNS = [
        /-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/m,
        /\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b/,
        /\b(?:ghp|github_pat)_[A-Za-z0-9_]{20,}\b/,
        /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/,
        /\bAKIA[A-Z0-9]{16}\b/,
        /\bBearer\s+[A-Za-z0-9._~+\/-]+=*\b/i,
        /\b(?:api[_-]?key|access[_-]?token|password)\s*[:=]\s*[^\s,;]+/i
      ].freeze
      INSTRUCTION_PATTERNS = [
        /ignore\s+(?:all\s+|any\s+|the\s+)?previous\s+instructions/i,
        /(?:reveal|persist|print|repeat)\s+(?:the\s+)?(?:system|developer)\s+(?:message|prompt)/i,
        /<\/?(?:system|developer|assistant)>/i,
        /you are (?:chatgpt|claude|codex)/i
      ].freeze

      def redact(value)
        case value
        when String
          SECRET_PATTERNS.reduce(value) { |text, pattern| text.gsub(pattern, REDACTION) }
        when Array
          value.map { |item| redact(item) }
        when Hash
          value.to_h { |key, item| [key, redact(item)] }
        else
          value
        end
      end

      def suspicious_instruction?(value)
        strings(value).any? { |text| INSTRUCTION_PATTERNS.any? { |pattern| pattern.match?(text) } }
      end

      private

      def strings(value)
        case value
        when String then [value]
        when Array then value.flat_map { |item| strings(item) }
        when Hash then value.values.flat_map { |item| strings(item) }
        else []
        end
      end
    end
  end
end
