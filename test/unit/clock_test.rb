# frozen_string_literal: true

require_relative "../test_helper"

class CyborgClockTest < Minitest::Test
  def test_clock_returns_a_time
    assert_instance_of Time, Cyborg::Clock.new.now
  end

  def test_frozen_clock_returns_the_configured_time
    time = Time.utc(2026, 8, 12, 14, 30, 0)
    clock = Cyborg::FrozenClock.new(time)

    assert_equal time, clock.now
    assert_same clock.now, clock.now
  end
end
