# frozen_string_literal: true

require "time"
require_relative "../../lib/redhawks_schedule/eastern"

RSpec.describe RedhawksSchedule::Eastern do
  describe ".dst?" do
    it "is standard time in January" do
      expect(described_class.dst?(Time.utc(2026, 1, 15, 12))).to be(false)
    end

    it "is daylight time in July" do
      expect(described_class.dst?(Time.utc(2026, 7, 15, 12))).to be(true)
    end

    # 2026: second Sunday in March is the 8th; DST starts 07:00 UTC.
    it "is standard one minute before the March switch" do
      expect(described_class.dst?(Time.utc(2026, 3, 8, 6, 59))).to be(false)
    end

    it "is daylight at the March switch" do
      expect(described_class.dst?(Time.utc(2026, 3, 8, 7, 0))).to be(true)
    end

    # 2026: first Sunday in November is the 1st; DST ends 06:00 UTC.
    it "is daylight one minute before the November switch" do
      expect(described_class.dst?(Time.utc(2026, 11, 1, 5, 59))).to be(true)
    end

    it "is standard at the November switch" do
      expect(described_class.dst?(Time.utc(2026, 11, 1, 6, 0))).to be(false)
    end
  end

  describe ".local" do
    it "shifts by five hours in winter" do
      expect(described_class.local(Time.utc(2026, 12, 1, 17)).hour).to eq(12)
    end

    it "shifts by four hours in summer" do
      expect(described_class.local(Time.utc(2026, 7, 1, 16)).hour).to eq(12)
    end

    it "lands on the previous Eastern day for a late-evening UTC instant" do
      local = described_class.local(Time.utc(2026, 9, 5, 1))
      expect([local.month, local.day, local.hour]).to eq([9, 4, 21])
    end
  end

  describe ".day_name" do
    it "names the Eastern day, not the UTC day" do
      # 2026-09-05 01:00 UTC is Friday 2026-09-04 21:00 Eastern.
      expect(described_class.day_name(Time.utc(2026, 9, 5, 1))).to eq("Friday")
    end
  end

  describe ".iso_week" do
    it "formats the ISO week of the Eastern date" do
      expect(described_class.iso_week(Time.utc(2026, 9, 4, 17))).to eq("2026-W36")
    end
  end

  describe ".start_of_day" do
    it "returns Eastern midnight as a UTC instant" do
      # Midnight Eastern on 2026-09-04 (EDT, -4) is 04:00 UTC.
      expect(described_class.start_of_day(Time.utc(2026, 9, 4, 17)))
        .to eq(Time.utc(2026, 9, 4, 4))
    end

    it "resolves the offset at midnight, not at the given instant, on the spring-forward date" do
      # DST starts 2026-03-08 at 07:00 UTC (2am local standard), so
      # midnight Eastern on the 8th is still EST (-5) even though the
      # instant passed in is already after the switch (EDT, -4).
      expect(described_class.start_of_day(Time.utc(2026, 3, 8, 12)))
        .to eq(Time.utc(2026, 3, 8, 5))
    end

    it "resolves the offset at midnight, not at the given instant, on the fall-back date" do
      # DST ends 2026-11-01 at 06:00 UTC (2am local daylight), so
      # midnight Eastern on the 1st is still EDT (-4) even though the
      # instant passed in is already after the switch (EST, -5).
      expect(described_class.start_of_day(Time.utc(2026, 11, 1, 12)))
        .to eq(Time.utc(2026, 11, 1, 4))
    end
  end
end
