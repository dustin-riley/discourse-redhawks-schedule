# frozen_string_literal: true

require "time"
require_relative "../../lib/redhawks_schedule/gameday_composer"

RSpec.describe RedhawksSchedule::GamedayComposer do
  def event(overrides = {})
    {
      id: "20845",
      sport: "Football",
      opponent: "Ohio",
      home_away: "home",
      start_utc: Time.utc(2026, 11, 11, 0, 0),
      time_known: true,
      location: "Oxford, Ohio",
      url: "https://miamiredhawks.com/calendar.aspx?game_id=20845",
      broadcast: {},
    }.merge(overrides)
  end

  describe ".thread_title" do
    it "reads as a home matchup with the Eastern date" do
      expect(described_class.thread_title(event)).to eq("Football vs Ohio — Nov 10")
    end

    it "reads as an away matchup" do
      title = described_class.thread_title(event(home_away: "away", opponent: "Cincinnati"))
      expect(title).to eq("Football at Cincinnati — Nov 10")
    end
  end

  describe ".thread_body" do
    it "leads with the sport emoji, matchup, and promo when present" do
      body = described_class.thread_body(event(promo: "Homecoming"))
      expect(body.lines.first.strip).to eq("🏈 **Football vs Ohio** · Homecoming")
    end

    it "omits the promo separator when there is no promo" do
      body = described_class.thread_body(event)
      expect(body.lines.first.strip).to eq("🏈 **Football vs Ohio**")
    end

    it "shows the Eastern kickoff and location with markers" do
      body = described_class.thread_body(event)
      expect(body).to include("📅 Tuesday, November 10 · 7:00 PM ET")
      expect(body).to include("📍 Oxford, Ohio")
    end

    it "says Time TBA when the feed announced no time" do
      body = described_class.thread_body(event(time_known: false))
      expect(body).to include("📅 Tuesday, November 10 · Time TBA")
      expect(body).to_not include("PM ET")
    end

    it "combines TV and radio on one watch line" do
      body = described_class.thread_body(
        event(broadcast: { tv: "ESPN2/ESPNU", radio: "Miami Radio Network" }),
      )
      expect(body).to include("📺 ESPN2/ESPNU · 📻 Miami Radio Network")
    end

    it "shows TV alone when there is no radio" do
      body = described_class.thread_body(event(broadcast: { tv: "ESPN2/ESPNU" }))
      expect(body).to include("📺 ESPN2/ESPNU")
      expect(body).to_not include("📻")
    end

    it "embeds the player when the stream is framable" do
      body = described_class.thread_body(
        event(broadcast: { video_embed: "https://miamiredhawks.com/showcase/embed.aspx?Live=630&type=Live" }),
      )
      expect(body).to include(
        '<iframe src="https://miamiredhawks.com/showcase/embed.aspx?Live=630&type=Live"',
      )
    end

    it "links the stream plainly when it is not framable" do
      body = described_class.thread_body(event(broadcast: { video: "https://youtube.com/watch?v=abc" }))
      expect(body).to include("▶️ [Watch the stream](https://youtube.com/watch?v=abc)")
      expect(body).to_not include("<iframe")
    end

    it "collects tickets, live stats, listen-live, and the game page onto one links line" do
      body = described_class.thread_body(
        event(
          broadcast: {
            audio: "https://miamiredhawks.com/listen",
            livestats: "https://miamiredhawks.com/sidearmstats/football/summary",
            tickets: "https://redhawktix.evenue.net/events/FBSE",
          },
        ),
      )
      expect(body).to include(
        "🎟️ [Tickets](https://redhawktix.evenue.net/events/FBSE) · " \
        "📊 [Live stats](https://miamiredhawks.com/sidearmstats/football/summary) · " \
        "🔊 [Listen live](https://miamiredhawks.com/listen) · " \
        "🔗 [Game page](https://miamiredhawks.com/calendar.aspx?game_id=20845)",
      )
    end

    it "degrades to headline, when, where, and game page when the feed is bare" do
      body = described_class.thread_body(event)
      expect(body).to_not include("📺")
      expect(body).to_not include("📻")
      expect(body).to_not include("<iframe")
      expect(body).to_not include("🎟️")
      expect(body).to include("🔗 [Game page](https://miamiredhawks.com/calendar.aspx?game_id=20845)")
    end
  end

  describe ".digest_title" do
    it "names the sport and the Eastern week" do
      title = described_class.digest_title("Field Hockey", Time.utc(2026, 9, 4, 17))
      expect(title).to eq("Field Hockey — week of September 4")
    end
  end

  describe ".digest_body" do
    it "lists each game on its own line" do
      body = described_class.digest_body(
        "Field Hockey",
        [
          event(sport: "Field Hockey", opponent: "Michigan State", start_utc: Time.utc(2026, 9, 4, 17)),
          event(
            sport: "Field Hockey",
            opponent: "Ohio",
            home_away: "away",
            start_utc: Time.utc(2026, 9, 6, 19),
            time_known: false,
          ),
        ],
      )

      expect(body).to include("Friday, September 4 · 1:00 PM ET — vs Michigan State")
      expect(body).to include("Sunday, September 6 · Time TBA — at Ohio")
    end

    it "carries a live stats link into the line when present" do
      body = described_class.digest_body(
        "Field Hockey",
        [event(sport: "Field Hockey", broadcast: { livestats: "https://example.com/stats" })],
      )
      expect(body).to include("[Live stats](https://example.com/stats)")
    end
  end

  describe ".sport_emoji" do
    it "maps known feed sports to their emoji" do
      expect(described_class.sport_emoji("Football")).to eq("🏈")
      expect(described_class.sport_emoji("Hockey")).to eq("🏒")
      expect(described_class.sport_emoji("Women's Basketball")).to eq("🏀")
      expect(described_class.sport_emoji("Field Hockey")).to eq("🏑")
      expect(described_class.sport_emoji("Track & Field, Cross Country")).to eq("🏃")
    end

    it "falls back to a neutral marker for an unmapped sport" do
      expect(described_class.sport_emoji("Kayaking")).to eq("🗓️")
    end
  end
end
