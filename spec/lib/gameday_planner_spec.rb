# frozen_string_literal: true

require "time"
require_relative "../../lib/redhawks_schedule/gameday_planner"

RSpec.describe RedhawksSchedule::GamedayPlanner do
  NOW = Time.utc(2026, 9, 1, 12)

  def event(overrides = {})
    {
      id: "20845",
      sport: "Football",
      opponent: "Ohio",
      home_away: "home",
      start_utc: Time.utc(2026, 9, 5, 17),
      time_known: true,
      location: "Oxford, Ohio",
      broadcast: {},
    }.merge(overrides)
  end

  def plan(events, config, ledger = {}, now = NOW, limit = 5)
    described_class.plan(events: events, config: config, ledger: ledger, now: now, limit: limit)
  end

  describe "thread mode" do
    let(:config) do
      [{ sport: "Football", mode: "thread", category: [7], days_before: 5 }]
    end

    it "plans a thread once the game is inside the window" do
      result = plan([event], config)
      action = result[:actions].first

      expect(action[:kind]).to eq(:thread)
      expect(action[:key]).to eq("gameday:game:20845")
      expect(action[:category_id]).to eq(7)
      expect(action[:event][:opponent]).to eq("Ohio")
    end

    it "does not plan a thread before the window opens" do
      far = event(start_utc: Time.utc(2026, 9, 20, 17))
      expect(plan([far], config)[:actions]).to be_empty
    end

    # NOW is 8:00 AM Eastern on Sep 1; a game five days out opens its window at
    # Eastern midnight that same morning, so it is already eligible.
    it "opens the window at Eastern midnight days_before ahead" do
      boundary = event(start_utc: NOW + (5 * 24 * 60 * 60))
      expect(plan([boundary], config)[:actions].length).to eq(1)
    end

    it "is still closed a day earlier than that" do
      just_outside = event(start_utc: NOW + (6 * 24 * 60 * 60))
      expect(plan([just_outside], config)[:actions]).to be_empty
    end

    it "skips a game already in the ledger" do
      ledger = { "gameday:game:20845" => 991 }
      expect(plan([event], config, ledger)[:actions]).to be_empty
    end

    it "ignores sports that are not configured" do
      expect(plan([event(sport: "Men's Golf")], config)[:actions]).to be_empty
    end

    it "ignores sports configured off" do
      off = [{ sport: "Football", mode: "off", category: [7], days_before: 5 }]
      expect(plan([event], off)[:actions]).to be_empty
    end

    it "accepts string keys, as the site setting supplies them" do
      string_config = [
        { "sport" => "Football", "mode" => "thread", "category" => [7], "days_before" => 5 },
      ]
      expect(plan([event], string_config)[:actions].length).to eq(1)
    end

    it "reports configured sports that match no event" do
      config_with_ghost = config + [{ sport: "Croquet", mode: "thread", category: [7], days_before: 5 }]
      expect(plan([event], config_with_ghost)[:unmatched]).to eq(["Croquet"])
    end

    it "treats a missing days_before as same-day" do
      no_days = [{ sport: "Football", mode: "thread", category: [7] }]
      same_day = event(start_utc: NOW + (60 * 60))
      expect(plan([same_day], no_days)[:actions].length).to eq(1)
      expect(plan([event], no_days)[:actions]).to be_empty
    end
  end

  describe "burst cap" do
    let(:config) do
      [{ sport: "Football", mode: "thread", category: [7], days_before: 14 }]
    end

    let(:many) do
      (1..8).map do |n|
        event(id: "3000#{n}", start_utc: Time.utc(2026, 9, 1 + n, 17), opponent: "Team #{n}")
      end
    end

    it "creates no more than the limit in one run" do
      expect(plan(many, config)[:actions].length).to eq(5)
    end

    it "reports what it held back rather than dropping it" do
      expect(plan(many, config)[:deferred]).to eq(3)
    end

    it "takes the soonest games first" do
      ids = plan(many, config)[:actions].map { |a| a[:event][:id] }
      expect(ids).to eq(%w[30001 30002 30003 30004 30005])
    end
  end
end
