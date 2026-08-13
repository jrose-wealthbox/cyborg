# frozen_string_literal: true

require "json"
require_relative "../bridge/canonical_json"
require_relative "../bridge/envelope"
require_relative "../errors"
require_relative "contracts"

module Cyborg
  module Analysis
    class FixtureBackend
      DEFAULT_MAXIMUM_BYTES = 1_048_576

      attr_reader :path, :maximum_bytes

      def initialize(path:, maximum_bytes: DEFAULT_MAXIMUM_BYTES)
        @path = File.expand_path(path.to_s).freeze
        @maximum_bytes = Contracts.strict_integer(maximum_bytes, "maximum_bytes", minimum: 1)
        freeze
      end

      def analyze(packet:, task:, reservation:)
        raise ArgumentError, "task must be an AnalysisTask" unless task.is_a?(AnalysisTask)
        unless reservation.is_a?(Reservation) && reservation == task.reservation
          raise ArgumentError, "reservation must match the task reservation"
        end

        bytes = File.open(path, "rb") { |file| file.read(maximum_bytes + 1) }
        if bytes.bytesize > maximum_bytes
          raise Cyborg::UsageError.new("analysis.output_too_large", "fixture result exceeds backend byte bound")
        end
        document = JSON.parse(bytes)
        payload = if document.is_a?(Hash) && document["artifact_type"] == "analysis_result"
          run_id = packet_value(packet, :run_id)
          Bridge::Envelope.validate!(document, expected_type: "analysis_result", expected_run_id: run_id)
        else
          document
        end
        raise Cyborg::UsageError.new("analysis.invalid_fixture", "fixture result must be an object") unless payload.is_a?(Hash)

        if Bridge::CanonicalJSON.dump(payload).bytesize > task.maximum_output_bytes
          raise Cyborg::UsageError.new("analysis.output_too_large", "fixture result exceeds task output bound")
        end
        claims = payload.fetch("claims", [])
        usage = payload.fetch("usage", {})
        metadata = payload.fetch("backend_metadata", {}).merge("backend" => "fixture")
        AnalysisOutcome.new(claims:, usage:, backend_metadata: metadata)
      rescue JSON::ParserError, EncodingError => error
        raise Cyborg::UsageError.new("analysis.invalid_fixture", error.message)
      rescue Errno::ENOENT => error
        raise Cyborg::UsageError.new("analysis.fixture_unavailable", error.message)
      end

      private

      def packet_value(packet, key)
        packet.is_a?(Hash) ? (packet[key.to_s] || packet[key]) : packet.public_send(key)
      end
    end
  end
end
