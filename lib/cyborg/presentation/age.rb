# frozen_string_literal: true

require "time"

module Cyborg
  module Presentation
    module Age
      module_function

      def format(timestamp = nil, now: Time.now.utc, **options)
        timestamp ||= options[:timestamp]
        return nil if timestamp.nil? || timestamp.to_s.strip.empty?

        then_at = parse(timestamp)
        current = parse(now)
        seconds = (current - then_at).to_f
        future = seconds.negative?
        amount = seconds.abs.floor
        value = if amount < 60
          "#{amount}s"
        elsif amount < 3600
          "#{amount / 60}m"
        elsif amount < 86_400
          "#{amount / 3600}h"
        else
          "#{amount / 86_400}d"
        end
        future ? "in #{value}" : value
      rescue ArgumentError, TypeError
        nil
      end

      def parse(value)
        value.is_a?(Time) ? value.utc : Time.iso8601(value.to_s).utc
      end
      private_class_method :parse
    end
  end
end
