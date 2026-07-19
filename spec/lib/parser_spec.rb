# frozen_string_literal: true

require "time"
require_relative "../../lib/redhawks_schedule/parser"

RSpec.describe RedhawksSchedule::Parser do
  # Every event in the fixture starts after this instant.
  BEFORE_SEASON = Time.utc(2026, 7, 1)

  def wrap(items)
    <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <rss version="2.0"
           xmlns:ev="http://purl.org/rss/1.0/modules/event/"
           xmlns:s="http://sidearmsports.com/schemas/cal_rss/1.0/">
        <channel>#{items}</channel>
      </rss>
    XML
  end

  let(:timed_item) do
    wrap(<<~XML)
      <item>
        <title>8/16 7:00 PM Miami University Women's Soccer at Xavier</title>
        <link>https://miamiredhawks.com/calendar.aspx?game_id=20926&amp;sport_id=16</link>
        <ev:location>Cincinnati, Ohio</ev:location>
        <ev:startdate>2026-08-16T23:00:00.0000000Z</ev:startdate>
        <ev:enddate>2026-08-17T01:00:00.0000000Z</ev:enddate>
        <s:opponentlogo>https://miamiredhawks.com/images/logos/Xavier_.png</s:opponentlogo>
        <s:opponent>Xavier</s:opponent>
        <s:gameid>20926</s:gameid>
        <s:gamepromoname></s:gamepromoname>
      </item>
    XML
  end

  subject(:event) { described_class.parse(timed_item, now: BEFORE_SEASON).first }

  it "extracts the sport from the title" do
    expect(event[:sport]).to eq("Women's Soccer")
  end

  it "marks 'at' games as away" do
    expect(event[:home_away]).to eq("away")
  end

  it "prefers s:opponent over the title remainder" do
    expect(event[:opponent]).to eq("Xavier")
  end

  it "parses the start time as UTC" do
    expect(event[:start_utc]).to eq(Time.utc(2026, 8, 16, 23, 0, 0))
  end

  it "marks timed events as time_known" do
    expect(event[:time_known]).to be(true)
  end

  it "carries location, logo, id and url through" do
    expect(event[:location]).to eq("Cincinnati, Ohio")
    expect(event[:opponent_logo]).to end_with("Xavier_.png")
    expect(event[:id]).to eq("20926")
    expect(event[:url]).to include("game_id=20926")
  end

  it "blanks an empty promo name rather than returning an empty string" do
    expect(event[:promo]).to be_nil
  end

  context "with a 'vs' title" do
    let(:home) do
      wrap(<<~XML)
        <item>
          <title>8/8 7:00 PM Miami University Women's Soccer vs Purdue Fort Wayne (Exhibition)</title>
          <ev:startdate>2026-08-08T23:00:00.0000000Z</ev:startdate>
          <s:opponent>Purdue Fort Wayne (Exhibition)</s:opponent>
        </item>
      XML
    end

    it "marks it home" do
      expect(described_class.parse(home, now: BEFORE_SEASON).first[:home_away]).to eq("home")
    end
  end

  context "with a date-only start (59% of the real feed)" do
    let(:date_only) do
      wrap(<<~XML)
        <item>
          <title>8/29 Miami University Men's Golf vs Virtues Intercollegiate- Virtues Golf Club</title>
          <ev:startdate>2026-08-29</ev:startdate>
          <ev:enddate>2026-08-29</ev:enddate>
          <s:opponent>Virtues Intercollegiate- Virtues Golf Club</s:opponent>
        </item>
      XML
    end

    subject(:event) { described_class.parse(date_only, now: BEFORE_SEASON).first }

    it "sets time_known false" do
      expect(event[:time_known]).to be(false)
    end

    it "still parses the sport despite the missing time in the title" do
      expect(event[:sport]).to eq("Men's Golf")
    end

    it "anchors the start to midnight UTC on that calendar date" do
      expect(event[:start_utc]).to eq(Time.utc(2026, 8, 29, 0, 0, 0))
    end
  end

  context "with non-zero fractional seconds" do
    let(:fractional) do
      wrap(<<~XML)
        <item>
          <title>8/28 8:00 PM Miami University Football at Middle Tennessee</title>
          <ev:startdate>2026-08-28T00:00:00.0000001Z</ev:startdate>
        </item>
      XML
    end

    it "parses rather than raising" do
      expect(described_class.parse(fractional, now: BEFORE_SEASON).first[:start_utc])
        .to eq(Time.utc(2026, 8, 28, 0, 0, 0))
    end
  end

  describe "against the real 2026-07-18 snapshot" do
    let(:xml) { File.read(File.join(__dir__, "../fixtures/calendar.rss")) }
    let(:events) { described_class.parse(xml, now: BEFORE_SEASON) }

    it "finds every sport present in the feed" do
      expect(events.map { |e| e[:sport] }.uniq).to contain_exactly(
        "Hockey", "Men's Golf", "Women's Volleyball", "Women's Soccer", "Football"
      )
    end

    it "splits time_known the way the feed does" do
      expect(events.sum { |e| e[:days] }).to eq(141)
      known = events.select { |e| e[:time_known] }.sum { |e| e[:days] }
      expect(known).to eq(58)
    end
  end
end
