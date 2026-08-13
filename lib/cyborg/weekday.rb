# frozen_string_literal: true

require_relative "errors"

module Cyborg
  # Canonical weekday normalization shared by configuration and calendar
  # validation. Ruby's String#to_i is intentionally not used here because it
  # silently turns names and malformed values into Sunday.
  module Weekday
    NAMES = %w[sunday monday tuesday wednesday thursday friday saturday].freeze
    ALIASES = {
      "sunday" => 0, "sun" => 0, "0" => 0,
      "monday" => 1, "mon" => 1, "1" => 1,
      "tuesday" => 2, "tue" => 2, "2" => 2,
      "wednesday" => 3, "wed" => 3, "3" => 3,
      "thursday" => 4, "thu" => 4, "4" => 4,
      "friday" => 5, "fri" => 5, "5" => 5,
      "saturday" => 6, "sat" => 6, "6" => 6
    }.freeze

    module_function

    def normalize(value, error_code: "config.invalid_weekend_day")
      key = case value
      when Integer then value.to_s
      when String, Symbol then value.to_s.strip.downcase
      end
      weekday = ALIASES[key]
      return weekday unless weekday.nil?

      raise InvalidConfiguration.new(error_code, "invalid weekday")
    end
  end
end
