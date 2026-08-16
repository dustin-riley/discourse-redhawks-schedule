# Gameday Post Content Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refresh the gameday thread and digest post copy into a scannable emoji info board that degrades gracefully when the feed is sparse.

**Architecture:** All changes land in one pure module, `lib/redhawks_schedule/gameday_composer.rb`. The body is assembled from independent segments joined by blank lines, so any missing field drops its whole segment rather than leaving an empty label. A sport→emoji lookup gives each post visual identity with no images. No scheduling code, Rails, HTTP, or persistence is touched.

**Tech Stack:** Ruby (pure module), RSpec run on the dev Mac against `spec/lib/`.

## Global Constraints

- **Ruby 2.6-compatible only.** The dev Mac runs system Ruby 2.6.10. No `filter_map`, `Hash#except`, endless methods, or rightward assignment.
- **No ActiveSupport matchers in pure specs.** No `be_in`, `in?`, `blank?`. Use plain matchers or `satisfy {}`.
- **The composer stays pure.** No Rails, HTTP, persistence, or clock. `now` is never read here.
- **No images.** Text and emoji only.
- **Run specs with:** `~/.gem/ruby/2.6.0/bin/rspec spec/lib` (rspec is user-scoped, not on PATH). Do **not** run `rspec spec/` — it loads the container-only `spec/jobs/` file and aborts.
- **Titles are unchanged.** `thread_title` and `digest_title` keep their current form; promo lives in the body only.

---

### Task 1: Sport→emoji lookup

**Files:**
- Modify: `lib/redhawks_schedule/gameday_composer.rb` (add constant + `sport_emoji` method inside `module_function`)
- Test: `spec/lib/gameday_composer_spec.rb` (add a `.sport_emoji` describe block)

**Interfaces:**
- Consumes: nothing.
- Produces: `GamedayComposer.sport_emoji(sport) -> String` — returns the mapped emoji for a feed sport string, or `"🗓️"` for anything unmapped. Consumed by Tasks 2 and 3.

The map keys are the exact sport strings the parser emits (confirmed against the live feed: `Football`, `Hockey`, `Men's Basketball`, `Women's Basketball`, `Women's Soccer`, `Women's Volleyball`, `Field Hockey`, `Track & Field, Cross Country`). Additional plausible spellings for sports not in this season's feed are included so a future season renders cleanly; every unknown still falls back safely.

- [ ] **Step 1: Write the failing test**

Add to `spec/lib/gameday_composer_spec.rb`, inside the top-level `describe` block:

```ruby
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/lib/gameday_composer_spec.rb -e "sport_emoji"`
Expected: FAIL with `NoMethodError: undefined method 'sport_emoji'`.

- [ ] **Step 3: Add the constant and method**

In `lib/redhawks_schedule/gameday_composer.rb`, add the constant just below the `IFRAME` constant:

```ruby
    SPORT_EMOJI = {
      "Football" => "🏈",
      "Hockey" => "🏒",
      "Ice Hockey" => "🏒",
      "Men's Basketball" => "🏀",
      "Women's Basketball" => "🏀",
      "Men's Soccer" => "⚽",
      "Women's Soccer" => "⚽",
      "Volleyball" => "🏐",
      "Women's Volleyball" => "🏐",
      "Baseball" => "⚾",
      "Softball" => "🥎",
      "Field Hockey" => "🏑",
      "Men's Tennis" => "🎾",
      "Women's Tennis" => "🎾",
      "Men's Golf" => "⛳",
      "Women's Golf" => "⛳",
      "Men's Cross Country" => "🏃",
      "Women's Cross Country" => "🏃",
      "Track & Field, Cross Country" => "🏃",
      "Track & Field" => "🏃",
    }.freeze
    DEFAULT_EMOJI = "🗓️"
```

Add the method inside `module_function` (order among the helpers does not matter):

```ruby
    def sport_emoji(sport)
      SPORT_EMOJI.fetch(sport, DEFAULT_EMOJI)
    end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/lib/gameday_composer_spec.rb -e "sport_emoji"`
Expected: PASS (2 examples).

- [ ] **Step 5: Commit**

```bash
git add lib/redhawks_schedule/gameday_composer.rb spec/lib/gameday_composer_spec.rb
git commit -m "Add a sport-to-emoji lookup to the gameday composer"
```

---

### Task 2: Rebuild the thread body as an emoji info board

**Files:**
- Modify: `lib/redhawks_schedule/gameday_composer.rb` (rewrite `thread_body`; add `headline`, `when_where`, `watch_line`, `thread_links`, `time_suffix`; refactor `when_line`; update `stream_block`; delete `detail_lines` and `link_line`)
- Test: `spec/lib/gameday_composer_spec.rb` (rewrite the `.thread_body` describe block)

**Interfaces:**
- Consumes: `sport_emoji(sport)` from Task 1; existing `matchup`, `side`, `Eastern.local`.
- Produces: `thread_body(event) -> String`. New helper `time_suffix(event) -> String` (`" · 7:00 PM ET"` or `" · Time TBA"`), consumed by Task 3's `digest_when`.

The body is a list of segments — headline, when/where block, watch line, stream embed, links line — with `nil`/empty segments dropped, joined by `"\n\n"`. Segment order matches the spec: watch line above the embed, links last.

- [ ] **Step 1: Rewrite the `.thread_body` spec block**

Replace the entire `describe ".thread_body" do ... end` block in `spec/lib/gameday_composer_spec.rb` with:

```ruby
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
```

- [ ] **Step 2: Run the block to verify it fails**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/lib/gameday_composer_spec.rb -e "thread_body"`
Expected: FAIL — the current body has no emoji markers, so `include` assertions miss.

- [ ] **Step 3: Rewrite the thread composer code**

In `lib/redhawks_schedule/gameday_composer.rb`, replace `thread_body` and its helpers. Replace the whole `def thread_body ... end` with:

```ruby
    def thread_body(event)
      broadcast = event[:broadcast] || {}

      segments = [
        headline(event),
        when_where(event),
        watch_line(broadcast),
        stream_block(broadcast),
        thread_links(event, broadcast),
      ]

      segments.compact.reject(&:empty?).join("\n\n")
    end

    def headline(event)
      line = "#{sport_emoji(event[:sport])} **#{matchup(event)}**"
      line += " · #{event[:promo]}" if event[:promo]
      line
    end

    def when_where(event)
      lines = ["📅 #{when_line(event)}"]
      lines << "📍 #{event[:location]}" if event[:location]
      lines.join("\n")
    end

    def watch_line(broadcast)
      parts = []
      parts << "📺 #{broadcast[:tv]}" if broadcast[:tv]
      parts << "📻 #{broadcast[:radio]}" if broadcast[:radio]
      return nil if parts.empty?

      parts.join(" · ")
    end

    def thread_links(event, broadcast)
      links = []
      links << "🎟️ [Tickets](#{broadcast[:tickets]})" if broadcast[:tickets]
      links << "📊 [Live stats](#{broadcast[:livestats]})" if broadcast[:livestats]
      links << "🔊 [Listen live](#{broadcast[:audio]})" if broadcast[:audio]
      links << "🔗 [Game page](#{event[:url]})" if event[:url]
      return nil if links.empty?

      links.join(" · ")
    end
```

Refactor `when_line` to share the time logic, and add `time_suffix`. Replace the existing `when_line` with:

```ruby
    def when_line(event)
      "#{Eastern.local(event[:start_utc]).strftime('%A, %B %-d')}#{time_suffix(event)}"
    end

    def time_suffix(event)
      return " · Time TBA" unless event[:time_known]

      " · #{Eastern.local(event[:start_utc]).strftime('%-I:%M %p')} ET"
    end
```

Update `stream_block` so the plain-link case gains the ▶️ marker (the iframe case is unchanged):

```ruby
    def stream_block(broadcast)
      return format(IFRAME, broadcast[:video_embed]) if broadcast[:video_embed]
      return "▶️ [Watch the stream](#{broadcast[:video]})" if broadcast[:video]

      nil
    end
```

Delete the now-unused `detail_lines` and `link_line` methods entirely.

- [ ] **Step 4: Run the block to verify it passes**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/lib/gameday_composer_spec.rb -e "thread_body"`
Expected: PASS (10 examples).

- [ ] **Step 5: Commit**

```bash
git add lib/redhawks_schedule/gameday_composer.rb spec/lib/gameday_composer_spec.rb
git commit -m "Rebuild the gameday thread body as an emoji info board"
```

---

### Task 3: Restyle the weekly digest body to match

**Files:**
- Modify: `lib/redhawks_schedule/gameday_composer.rb` (rewrite `digest_body`; add `digest_when`)
- Test: `spec/lib/gameday_composer_spec.rb` (rewrite the `.digest_body` describe block)

**Interfaces:**
- Consumes: `sport_emoji(sport)` from Task 1; `time_suffix(event)` and `side(event)` from earlier tasks.
- Produces: `digest_body(sport, events) -> String`. `digest_title` is unchanged.

The header gains the sport emoji and bolding (`🏑 **Field Hockey — this week**`) — the topic title already carries the dated "week of…" form, so the body header does not repeat a date it has no `now` to compute. Rows use a short date (`Fri, Sep 4`), drop the location, and keep the livestats link with a 📊 marker.

- [ ] **Step 1: Rewrite the `.digest_body` spec block**

Replace the entire `describe ".digest_body" do ... end` block with:

```ruby
  describe ".digest_body" do
    it "heads the digest with the sport emoji and name" do
      body = described_class.digest_body("Field Hockey", [event(sport: "Field Hockey")])
      expect(body.lines.first.strip).to eq("🏑 **Field Hockey — this week**")
    end

    it "lists each game on its own line with a short date" do
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

      expect(body).to include("- 📅 Fri, Sep 4 · 1:00 PM ET — vs Michigan State")
      expect(body).to include("- 📅 Sun, Sep 6 · Time TBA — at Ohio")
    end

    it "carries a live stats link into the row when present" do
      body = described_class.digest_body(
        "Field Hockey",
        [event(sport: "Field Hockey", broadcast: { livestats: "https://example.com/stats" })],
      )
      expect(body).to include("· 📊 [Live stats](https://example.com/stats)")
    end
  end
```

- [ ] **Step 2: Run the block to verify it fails**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/lib/gameday_composer_spec.rb -e "digest_body"`
Expected: FAIL — current header is `Field Hockey games this week:` and rows use the long date without markers.

- [ ] **Step 3: Rewrite the digest composer code**

Replace the existing `digest_body` with:

```ruby
    def digest_body(sport, events)
      lines = ["#{sport_emoji(sport)} **#{sport} — this week**", ""]

      events.each do |event|
        line = "- 📅 #{digest_when(event)} — #{side(event)} #{event[:opponent]}"

        stats = (event[:broadcast] || {})[:livestats]
        line += " · 📊 [Live stats](#{stats})" if stats

        lines << line
      end

      lines.join("\n")
    end

    def digest_when(event)
      "#{Eastern.local(event[:start_utc]).strftime('%a, %b %-d')}#{time_suffix(event)}"
    end
```

- [ ] **Step 4: Run the block to verify it passes**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/lib/gameday_composer_spec.rb -e "digest_body"`
Expected: PASS (3 examples).

- [ ] **Step 5: Run the whole pure suite to confirm nothing else regressed**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/lib`
Expected: PASS, 0 failures. (The `.digest_title` and `.thread_title` blocks are untouched and still pass.)

- [ ] **Step 6: Commit**

```bash
git add lib/redhawks_schedule/gameday_composer.rb spec/lib/gameday_composer_spec.rb
git commit -m "Restyle the weekly gameday digest to match the thread info board"
```

---

## Verifying on the live forum (after merge)

The composer is spec-covered on the dev Mac, but the real render — emoji, embed, badge spacing — is worth an eyeball. After deploying (container rebuild, per the repo CLAUDE.md), hit the existing admin test endpoint (`POST /redhawks-gameday-test.json`) to post the next real gameday thread as Swoop Bot and read it on the forum. No new verification tooling is needed; this reuses what the test-endpoint work already built.

## Notes for the implementer

- The source file already carries `# frozen_string_literal: true` and is UTF-8; emoji string literals are fine.
- `event()` in the spec helper does not set `:promo`, so `event[:promo]` is `nil` by default — the "omits promo" test relies on this.
- Segments are joined with `"\n\n"`; never emit fixed blank lines between groups, or a collapsed segment leaves a double blank.
