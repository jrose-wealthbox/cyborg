# frozen_string_literal: true

require_relative "../test_helper"

class CyborgCalendarTest < Minitest::Test
  def setup
    config = Cyborg::Config.load(
      path: File.expand_path("../fixtures/config/minimal.toml", __dir__),
      env: {}
    )
    @calendar = Cyborg::BusinessCalendar.new(config: config)
  end

  def test_monday_window_spans_friday_through_tuesday
    window = @calendar.window(
      now: Time.parse("2026-08-10T08:00:00-04:00"),
      profile: "default"
    )

    assert_equal "2026-08-07T04:00:00Z", window.start_utc.iso8601
    assert_equal "2026-08-12T03:59:59Z", window.end_utc.iso8601
  end

  def test_window_resolves_dst_in_configured_timezone
    window = @calendar.window(
      now: Time.parse("2026-03-09T08:00:00-04:00"),
      profile: "default"
    )

    assert_equal "2026-03-06T05:00:00Z", window.start_utc.iso8601
    assert_equal "2026-03-11T03:59:59Z", window.end_utc.iso8601
  end

  def test_observed_fixed_holiday_makes_friday_before_saturday_new_years_day_closed
    path = Tempfile.new(["cyborg", ".toml"])
    path.write(<<~TOML)
      [calendar.profiles.default]
      timezone = "America/New_York"
      observed = true
      easter = false
    TOML
    path.flush
    config = Cyborg::Config.load(path: path.path, env: {})
    calendar = Cyborg::BusinessCalendar.new(config: config)

    refute calendar.business_day?(Date.new(2021, 12, 31))
    refute calendar.business_day?(Date.new(2022, 1, 1))
  ensure
    path&.close!
  end

  def test_holiday_override_can_reopen_a_date_and_easter_can_be_opted_in
    path = Tempfile.new(["cyborg", ".toml"])
    path.write(<<~TOML)
      [calendar.profiles.default]
      timezone = "UTC"
      weekend_days = []
      easter = true
      [calendar.profiles.default.overrides]
      "2026-12-25" = false
    TOML
    path.flush
    config = Cyborg::Config.load(path: path.path, env: {})
    calendar = Cyborg::BusinessCalendar.new(config: config)

    refute calendar.business_day?(Date.new(2026, 4, 3))
    assert calendar.business_day?(Date.new(2026, 12, 25))
  ensure
    path&.close!
  end

  def test_calendar_rejects_an_impossible_profile_instead_of_searching_forever
    impossible = Data.define(
      :name, :timezone, :working_hours, :weekend_days, :holidays, :observed,
      :easter, :overrides, :holiday_additions, :holiday_removals,
      :window_before_business_days, :window_after_business_days
    ).new(
      "impossible", "UTC", {"start" => "09:00", "end" => "17:00"},
      (0..6).to_a, [], true, false, {}, [], [], 1, 1
    )

    calendar = Cyborg::BusinessCalendar.new(profiles: {"impossible" => impossible})
    error = assert_raises(Cyborg::InvalidConfiguration) do
      calendar.window(now: Time.utc(2026, 8, 10), profile: "impossible")
    end
    assert_equal "config.no_business_day", error.code
  end
end
