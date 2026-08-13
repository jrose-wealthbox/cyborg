# frozen_string_literal: true

require "date"
require "set"
require "time"
require "tzinfo"

module Cyborg
  TimeWindow = Data.define(:start_utc, :end_utc, :timezone)

  # Deterministic business-day policy. Source adapters consume a TimeWindow;
  # they do not know about holidays or the user's weekend.
  class BusinessCalendar
    WEEKDAYS = {
      "sunday" => 0, "monday" => 1, "tuesday" => 2, "wednesday" => 3,
      "thursday" => 4, "friday" => 5, "saturday" => 6
    }.freeze

    HOLIDAY_NAMES = {
      "new_years_day" => ->(year) { Date.new(year, 1, 1) },
      "martin_luther_king_jr_day" => ->(year) { nth_weekday(year, 1, 1, 3) },
      "juneteenth" => ->(year) { Date.new(year, 6, 19) },
      "independence_day" => ->(year) { Date.new(year, 7, 4) },
      "labor_day" => ->(year) { nth_weekday(year, 9, 1, 1) },
      "thanksgiving" => ->(year) { nth_weekday(year, 11, 4, 4) },
      "christmas" => ->(year) { Date.new(year, 12, 25) },
      "easter" => ->(year) { easter_sunday(year) },
      "good_friday" => ->(year) { easter_sunday(year) - 2 }
    }.freeze

    DEFAULT_HOLIDAYS = %w[
      new_years_day martin_luther_king_jr_day juneteenth independence_day labor_day
      thanksgiving christmas
    ].freeze

    def initialize(config: nil, profiles: nil, default_profile: "default")
      @profiles = if config
        config.profiles
      else
        profiles || {}
      end
      @default_profile = default_profile.to_s
    end

    def window(now:, profile: @default_profile)
      selected = resolve_profile(profile)
      timezone = TZInfo::Timezone.get(selected.timezone)
      local_now = timezone.to_local(now)
      local_date = local_now.to_date
      previous = shift_business_days(local_date, -selected.window_before_business_days, selected)
      following = shift_business_days(local_date, selected.window_after_business_days, selected)
      start_local = local_midnight(timezone, previous)
      end_local = local_midnight(timezone, following + 1) - 1
      TimeWindow.new(start_local.utc, end_local.utc, selected.timezone)
    end

    def business_day?(date, profile: @default_profile)
      selected = resolve_profile(profile)
      date = date.to_date
      !selected.weekend_days.include?(date.wday) && !holiday_dates(date.year, selected).include?(date)
    end

    def holiday?(date, profile: @default_profile)
      selected = resolve_profile(profile)
      holiday_dates(date.to_date.year, selected).include?(date.to_date)
    end

    private

    def resolve_profile(profile)
      profile = profile.name if profile.respond_to?(:name)
      selected = @profiles[profile.to_s]
      return selected if selected

      raise InvalidConfiguration.new("config.unknown_profile")
    end

    def shift_business_days(date, amount, profile)
      direction = amount.negative? ? -1 : 1
      remaining = amount.abs
      current = date
      while remaining.positive?
        current += direction
        remaining -= 1 if business_day_for?(current, profile)
      end
      current
    end

    def business_day_for?(date, profile)
      !profile.weekend_days.include?(date.wday) && !holiday_dates(date.year, profile).include?(date)
    end

    def local_midnight(timezone, date)
      timezone.local_time(date.year, date.month, date.day, 0, 0, 0)
    rescue TZInfo::PeriodNotFound
      # A timezone can theoretically skip midnight. Moving to the first valid
      # local instant preserves the date boundary instead of guessing an offset.
      timezone.local_time(date.year, date.month, date.day, 1, 0, 0)
    end

    def holiday_dates(year, profile)
      names = profile.holidays || DEFAULT_HOLIDAYS
      names = names.map { |name| normalize_holiday_name(name) }
      names += Array(profile.holiday_additions).map { |name| normalize_holiday_name(name) }
      names -= Array(profile.holiday_removals).map { |name| normalize_holiday_name(name) }
      names << "easter" << "good_friday" if profile.easter
      dates = Set.new

      (year - 1..year + 1).each do |holiday_year|
        names.each do |name|
          if HOLIDAY_NAMES.key?(name)
            actual = HOLIDAY_NAMES.fetch(name).call(holiday_year)
            dates.add(actual)
            if profile.observed && fixed_date_holiday?(name)
              dates.add(actual - 1) if actual.saturday?
              dates.add(actual + 1) if actual.sunday?
            end
          elsif name.match?(/\A\d{4}-\d{2}-\d{2}\z/)
            dates.add(Date.parse(name))
          end
        end
      end

      profile.overrides.each do |date_string, override|
        date = Date.parse(date_string.to_s)
        if holiday_override?(override)
          dates.add(date)
        else
          dates.delete(date)
        end
      rescue Date::Error
        raise InvalidConfiguration.new("config.invalid_holiday_overrides")
      end
      dates
    end

    def fixed_date_holiday?(name)
      %w[new_years_day juneteenth independence_day christmas].include?(name)
    end

    def holiday_override?(value)
      return value if value == true || value == false
      if value.is_a?(Hash)
        return holiday_override?(value["holiday"]) if value.key?("holiday")
        return holiday_override?(value["closed"]) if value.key?("closed")
        return !holiday_override?(value["business_day"]) if value.key?("business_day")
      end
      %w[holiday closed off true yes].include?(value.to_s.downcase)
    end

    def normalize_holiday_name(name)
      normalized = name.to_s.downcase.strip.gsub(/[’']/, "").gsub(/[^a-z0-9]+/, "_").sub(/\A_/, "").sub(/_\z/, "")
      {
        "new_year" => "new_years_day", "new_years" => "new_years_day",
        "mlk_day" => "martin_luther_king_jr_day", "martin_luther_king_day" => "martin_luther_king_jr_day",
        "july_4" => "independence_day", "independence" => "independence_day",
        "thanksgiving_day" => "thanksgiving", "christmas_day" => "christmas",
        "good_friday" => "good_friday"
      }.fetch(normalized, normalized)
    end

    class << self
      private

      def nth_weekday(year, month, weekday, occurrence)
        date = Date.new(year, month, 1)
        date += (weekday - date.wday) % 7
        date + ((occurrence - 1) * 7)
      end

      def easter_sunday(year)
        # Meeus/Jones/Butcher Gregorian computus, valid for modern calendar
        # years and independent of the host locale.
        a = year % 19
        b = year / 100
        c = year % 100
        d = b / 4
        e = b % 4
        f = (b + 8) / 25
        g = (b - f + 1) / 3
        h = (19 * a + b - d - g + 15) % 30
        i = c / 4
        k = c % 4
        l = (32 + 2 * e + 2 * i - h - k) % 7
        m = (a + 11 * h + 22 * l) / 451
        month = (h + l - 7 * m + 114) / 31
        day = ((h + l - 7 * m + 114) % 31) + 1
        Date.new(year, month, day)
      end
    end
  end
end
