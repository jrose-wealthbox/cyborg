# frozen_string_literal: true

require "digest"
require "json"

module Cyborg
  module MemoryCandidates
    class TranscriptReader
      DEFAULT_MAX_BYTES = 256 * 1024
      DEFAULT_MAX_MESSAGES = 200
      ROLES = %w[user assistant].freeze

      def initialize(max_bytes: DEFAULT_MAX_BYTES, max_messages: DEFAULT_MAX_MESSAGES)
        @max_bytes = max_bytes
        @max_messages = max_messages
      end

      def read(path)
        return unless path.is_a?(String) && File.file?(path)

        raw = read_tail(path)
        messages = raw.lines.filter_map { |line| parse_message(line) }.last(@max_messages)
        return if messages.empty?

        {
          "messages" => messages,
          "sha256" => "sha256:#{Digest::SHA256.hexdigest(raw)}",
          "bytes_read" => raw.bytesize
        }
      rescue SystemCallError, ArgumentError
        nil
      end

      private

      def read_tail(path)
        File.open(path, "rb") do |file|
          offset = [file.size - @max_bytes, 0].max
          file.seek(offset)
          raw = file.read(@max_bytes) || ""
          raw = raw.split("\n", 2).last.to_s if offset.positive?
          raw.force_encoding(Encoding::UTF_8).scrub
        end
      end

      def parse_message(line)
        record = JSON.parse(line)
        claude_message(record) || codex_message(record)
      rescue JSON::ParserError, TypeError
        nil
      end

      def claude_message(record)
        role = record["type"]
        return unless ROLES.include?(role) && record["message"].is_a?(Hash)

        build_message(role, record.dig("message", "content"))
      end

      def codex_message(record)
        return unless record["type"] == "response_item" && record["payload"].is_a?(Hash)

        payload = record.fetch("payload")
        role = payload["role"]
        return unless payload["type"] == "message" && ROLES.include?(role)

        build_message(role, payload["content"])
      end

      def build_message(role, content)
        text = extract_text(content).strip
        return if text.empty?

        {"role" => role, "text" => text}
      end

      def extract_text(content)
        case content
        when String
          content
        when Array
          content.filter_map do |part|
            next unless part.is_a?(Hash)
            next unless %w[text input_text output_text].include?(part["type"])

            part["text"] if part["text"].is_a?(String)
          end.join("\n")
        else
          ""
        end
      end
    end
  end
end
