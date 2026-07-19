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

  describe "filtering and ordering" do
    let(:mixed) do
      wrap(<<~XML)
        <item>
          <title>1/10 7:00 PM Miami University Hockey vs Denver</title>
          <ev:startdate>2027-01-10T00:00:00.0000000Z</ev:startdate>
          <s:opponent>Denver</s:opponent>
        </item>
        <item>
          <title>8/16 7:00 PM Miami University Women's Soccer at Xavier</title>
          <ev:startdate>2026-08-16T23:00:00.0000000Z</ev:startdate>
          <s:opponent>Xavier</s:opponent>
        </item>
      XML
    end

    it "sorts ascending by start time" do
      events = described_class.parse(mixed, now: BEFORE_SEASON)
      expect(events.map { |e| e[:opponent] }).to eq(%w[Xavier Denver])
    end

    it "drops events that already started" do
      events = described_class.parse(mixed, now: Time.utc(2026, 12, 1))
      expect(events.map { |e| e[:opponent] }).to eq(["Denver"])
    end

    it "keeps a date-only event through the end of its day, Eastern" do
      xml = wrap(<<~XML)
        <item>
          <title>8/29 Miami University Football vs Ohio</title>
          <ev:startdate>2026-08-29</ev:startdate>
          <s:opponent>Ohio</s:opponent>
        </item>
      XML

      # The feed's "2026-08-29" is an Eastern calendar date, but it parses to
      # midnight UTC — which is 8pm Eastern on Aug 28. A plain 24-hour window
      # would therefore hide this game at 8pm Eastern on Aug 29, while it may
      # still be being played.
      #
      # 11pm Eastern on game day — must still be listed:
      expect(described_class.parse(xml, now: Time.utc(2026, 8, 30, 3, 0))).not_to be_empty
      # 3am Eastern the next morning — the day is over:
      expect(described_class.parse(xml, now: Time.utc(2026, 8, 30, 7, 0))).to be_empty
    end
  end

  describe "multi-day collapsing" do
    def golf_day(date)
      <<~XML
        <item>
          <title>#{date[5, 2].to_i}/#{date[8, 2].to_i} Miami University Men's Golf vs MAC Championship- Talis Park</title>
          <ev:startdate>#{date}</ev:startdate>
          <ev:enddate>#{date}</ev:enddate>
          <s:opponent>MAC Championship- Talis Park</s:opponent>
        </item>
      XML
    end

    it "merges consecutive days into one entry with a day count" do
      xml = wrap(golf_day("2027-04-30") + golf_day("2027-05-01") + golf_day("2027-05-02"))
      events = described_class.parse(xml, now: BEFORE_SEASON)

      expect(events.length).to eq(1)
      expect(events.first[:days]).to eq(3)
      expect(events.first[:start_utc]).to eq(Time.utc(2027, 4, 30))
      expect(events.first[:end_utc]).to eq(Time.utc(2027, 5, 2))
    end

    it "does NOT merge separate series against the same opponent" do
      xml = wrap(<<~XML)
        <item>
          <title>11/7 7:00 PM Miami University Hockey vs Western Michigan</title>
          <ev:startdate>2026-11-07T00:00:00.0000000Z</ev:startdate>
          <s:opponent>Western Michigan</s:opponent>
        </item>
        <item>
          <title>2/13 7:00 PM Miami University Hockey vs Western Michigan</title>
          <ev:startdate>2027-02-13T00:00:00.0000000Z</ev:startdate>
          <s:opponent>Western Michigan</s:opponent>
        </item>
      XML

      expect(described_class.parse(xml, now: BEFORE_SEASON).length).to eq(2)
    end

    it "does not merge different sports that happen to share a date" do
      xml = wrap(<<~XML)
        <item>
          <title>8/28 7:00 PM Miami University Women's Soccer vs Ohio</title>
          <ev:startdate>2026-08-28T23:00:00.0000000Z</ev:startdate>
          <s:opponent>Ohio</s:opponent>
        </item>
        <item>
          <title>8/28 6:00 PM Miami University Women's Volleyball vs Ohio</title>
          <ev:startdate>2026-08-28T22:00:00.0000000Z</ev:startdate>
          <s:opponent>Ohio</s:opponent>
        </item>
      XML

      expect(described_class.parse(xml, now: BEFORE_SEASON).length).to eq(2)
    end

    it "merges tournament days even when another sport sorts between them" do
      # The regression case. Two golf days 17 hours apart with a soccer match
      # in between: an implementation that only compares against the previous
      # row leaves these as two rows instead of one.
      xml = wrap(
        golf_day("2026-08-29") + <<~XML + golf_day("2026-08-30")
          <item>
            <title>8/29 7:00 PM Miami University Women's Soccer vs Butler</title>
            <ev:startdate>2026-08-29T23:00:00.0000000Z</ev:startdate>
            <s:opponent>Butler</s:opponent>
          </item>
        XML
      )

      events = described_class.parse(xml, now: BEFORE_SEASON)
      golf = events.select { |e| e[:sport] == "Men's Golf" }

      expect(golf.length).to eq(1)
      expect(golf.first[:days]).to eq(2)
    end

    it "reduces the real feed from 141 items to 101 rows" do
      xml = File.read(File.join(__dir__, "../fixtures/calendar.rss"))
      events = described_class.parse(xml, now: BEFORE_SEASON)

      expect(events.length).to eq(101)
      expect(events.count { |e| e[:days] > 1 }).to eq(36)
      # Nothing is dropped by collapsing — every original item is accounted for.
      expect(events.sum { |e| e[:days] }).to eq(141)
    end

    it "leaves no two rows for the same matchup within the merge window" do
      xml = File.read(File.join(__dir__, "../fixtures/calendar.rss"))
      events = described_class.parse(xml, now: BEFORE_SEASON)

      last_end = {}
      leaks =
        events.count do |event|
          key = [event[:sport], event[:opponent]]
          previous_end = last_end[key]
          last_end[key] = event[:end_utc]
          previous_end && (event[:start_utc] - previous_end) <= 48 * 60 * 60
        end

      expect(leaks).to eq(0)
    end
  end

  describe "malformed input" do
    it "returns empty for non-XML" do
      expect(described_class.parse("<html><body>502 Bad Gateway</body></html>")).to eq([])
    end

    it "returns empty for an empty string" do
      expect(described_class.parse("")).to eq([])
    end

    it "returns empty for nil" do
      expect(described_class.parse(nil)).to eq([])
    end

    it "skips items with no start date but keeps the rest" do
      xml = wrap(<<~XML)
        <item>
          <title>8/16 7:00 PM Miami University Women's Soccer at Xavier</title>
        </item>
        <item>
          <title>8/20 7:00 PM Miami University Women's Soccer vs Morehead State</title>
          <ev:startdate>2026-08-20T23:00:00.0000000Z</ev:startdate>
          <s:opponent>Morehead State</s:opponent>
        </item>
      XML

      events = described_class.parse(xml, now: BEFORE_SEASON)
      expect(events.map { |e| e[:opponent] }).to eq(["Morehead State"])
    end

    it "skips items whose start date is an unparseable string" do
      xml = wrap(<<~XML)
        <item>
          <title>8/16 7:00 PM Miami University Hockey vs Denver</title>
          <ev:startdate>not a date</ev:startdate>
        </item>
      XML

      expect(described_class.parse(xml, now: BEFORE_SEASON)).to eq([])
    end

    it "tolerates a literal TBA timestamp" do
      xml = wrap(<<~XML)
        <item>
          <title>8/16 Miami University Hockey vs Denver</title>
          <ev:startdate>TBA</ev:startdate>
        </item>
      XML

      expect { described_class.parse(xml, now: BEFORE_SEASON) }.not_to raise_error
    end

    it "handles a title with no vs/at separator by treating it as the sport" do
      xml = wrap(<<~XML)
        <item>
          <title>8/16 Miami University Cross Country Championship</title>
          <ev:startdate>2026-08-16</ev:startdate>
        </item>
      XML

      event = described_class.parse(xml, now: BEFORE_SEASON).first
      expect(event[:sport]).to eq("Cross Country Championship")
      expect(event[:home_away]).to eq("home")
    end

    it "decodes HTML entities in titles" do
      xml = wrap(<<~XML)
        <item>
          <title>8/16 7:00 PM Miami University Women&#39;s Soccer at Xavier</title>
          <ev:startdate>2026-08-16T23:00:00.0000000Z</ev:startdate>
        </item>
      XML

      expect(described_class.parse(xml, now: BEFORE_SEASON).first[:sport]).to eq("Women's Soccer")
    end
  end
end
