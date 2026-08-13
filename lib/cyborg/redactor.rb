# frozen_string_literal: true

module Cyborg
  class Redactor
    REDACTION = "[REDACTED]"
    SENSITIVE_KEY = /authorization|api[_-]?key|access[_-]?token|password|secret|private[_-]?key|client[_-]?secret|\btoken\b/i
    PRIVATE_KEY = /-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/m
    SECRET_VALUE_PATTERNS = [
      PRIVATE_KEY,
      /\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b/,
      /\b(?:ghp|github_pat)_[A-Za-z0-9_]{20,}\b/,
      /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/,
      /\bAKIA[A-Z0-9]{16}\b/,
      /\bBearer\s+[A-Za-z0-9._~+\/-]+=*\b/i,
      /\b(?:authorization|api[_-]?key|access[_-]?token|password|secret|credential|token)\s*[:=]\s*[^\s,;]+/i,
      /\b(?:OPENAI|ANTHROPIC|AWS|AZURE|GITHUB|SLACK)_[A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD)\s*=\s*[^\s,;]+/i
    ].freeze
    BODY_KEY = /(?:^|_)(?:prompt(?:_body|_text)?|source(?:_body|_text)?|body|stderr|stdout|command_(?:output|stderr)|raw_(?:body|text)|content)$/i

    def call(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), redacted|
          key_name = key.to_s
          redacted[key] = if key_name.match?(SENSITIVE_KEY) || key_name.match?(BODY_KEY)
                            REDACTION
                          else
                            call(item)
                          end
        end
      when Array
        value.map { |item| call(item) }
      when String
        redact_known_secret_values(value)
      else
        value
      end
    end

    alias redact call

    private

    def redact_known_secret_values(value)
      SECRET_VALUE_PATTERNS.reduce(value.dup) { |text, pattern| text.gsub(pattern, REDACTION) }
    end
  end
end
