# frozen_string_literal: true

require "time"

module RedhawksSchedule
  # US Eastern wall-clock helpers.
  #
  # ActiveSupport's Time.zone is unavailable here — lib/ stays free of Rails so
  # it can be unit tested on a machine with no Discourse checkout — so this
  # implements the US federal rule directly. Every digest decision depends on
  # the Eastern date, and 59% of feed events are date-only Eastern dates, so
  # doing this in UTC would land digests on the wrong day.
  module Eastern
    STANDARD_OFFSET = -5 * 60 * 60
    DAYLIGHT_OFFSET = -4 * 60 * 60
    DAY_NAMES = %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday].freeze

    module_function

    def dst?(utc)
      utc = utc.utc
      utc >= dst_start(utc.year) && utc < dst_end(utc.year)
    end

    def offset(utc)
      dst?(utc) ? DAYLIGHT_OFFSET : STANDARD_OFFSET
    end

    # A Time carrying Eastern wall-clock values. Its own zone label is
    # meaningless — read the components, never the offset.
    def local(utc)
      utc.utc + offset(utc)
    end

    def day_name(utc)
      DAY_NAMES[local(utc).wday]
    end

    def iso_week(utc)
      local(utc).strftime("%G-W%V")
    end

    def start_of_day(utc)
      wall = local(utc)
      midnight = Time.utc(wall.year, wall.month, wall.day)
      midnight - offset(utc)
    end

    # Second Sunday in March, 02:00 local standard == 07:00 UTC.
    def dst_start(year)
      Time.utc(year, 3, nth_sunday(year, 3, 2), 7)
    end

    # First Sunday in November, 02:00 local daylight == 06:00 UTC.
    def dst_end(year)
      Time.utc(year, 11, nth_sunday(year, 11, 1), 6)
    end

    def nth_sunday(year, month, nth)
      first = Time.utc(year, month, 1)
      first_sunday = 1 + ((7 - first.wday) % 7)
      first_sunday + (nth - 1) * 7
    end
  end
end
