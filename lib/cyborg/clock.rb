# frozen_string_literal: true

module Cyborg
  class Clock
    def now
      Time.now
    end
  end

  class FrozenClock < Clock
    def initialize(time = Time.now)
      @time = time
    end

    def now
      @time
    end
  end
end
