# Gameday Threads Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically open a Discourse topic per game — or one weekly digest per sport — from the athletics RSS calendar this plugin already fetches, embedding the stream where one is embeddable.

**Architecture:** All logic that decides *what* to post and *how it reads* lives in pure Ruby modules under `lib/redhawks_schedule/` with no Rails, no clock and no I/O, so it is testable on the dev Mac. A single scheduled job is a thin executor: load stored events, call the planner, call the composer, hand the result to `PostCreator`.

**Tech Stack:** Ruby, Discourse plugin API, Nokogiri, RSpec, PluginStore.

Spec: `docs/superpowers/specs/2026-08-05-gameday-threads-design.md`

## Global Constraints

- **Ruby 2.6 compatible.** The dev Mac runs system Ruby 2.6.10; the container runs 3.x. Do not use `filter_map`, `Hash#except`, endless method definitions, or rightward assignment. They pass in production and fail only locally.
- **No ActiveSupport in `lib/` or in `spec/lib/`.** No `blank?`, `present?`, `Time.zone`, `1.day`, `be_in`, `in?`. `app/` code runs inside Rails and may use them; their specs may not.
- **`lib/redhawks_schedule/parser.rb` stays free of Rails, HTTP and persistence.** Every new file in `lib/` holds to the same rule.
- Run tests with `~/.gem/ruby/2.6.0/bin/rspec spec/` — `rspec` is user-scoped and not on `PATH`.
- Deploying costs a container rebuild with real downtime. Batch everything; this plan is one deploy at the end.
- All wall-clock reasoning is `America/New_York`, never UTC.
- The plugin is for an **unofficial** fan site. No Miami University trademarks in any copy or asset.

## File Structure

| File | Kind | Responsibility |
|---|---|---|
| `lib/redhawks_schedule/parser.rb` | modify | Add `#events` (uncollapsed) and `broadcast` extraction |
| `lib/redhawks_schedule/eastern.rb` | create | Pure US Eastern offset, local time, day name, ISO week |
| `lib/redhawks_schedule/gameday_composer.rb` | create | Pure: event(s) → topic title and markdown body |
| `lib/redhawks_schedule/gameday_planner.rb` | create | Pure: (events, config, ledger, now) → actions |
| `app/services/redhawks_schedule/gameday_bot.rb` | create | Rails: resolve or create Swoop Bot, by stored id |
| `app/jobs/scheduled/post_redhawks_gameday.rb` | create | Rails: executes the plan |
| `app/jobs/scheduled/fetch_redhawks_schedule.rb` | modify | Also store uncollapsed events |
| `config/settings.yml` | modify | Per-sport configuration |
| `plugin.rb` | modify | Requires, store keys, `allowed_iframes` |
| `CLAUDE.md` | modify | Reword "one feature"; document new pieces |
| `spec/lib/eastern_spec.rb` | create | |
| `spec/lib/gameday_composer_spec.rb` | create | |
| `spec/lib/gameday_planner_spec.rb` | create | |
| `spec/lib/parser_spec.rb` | modify | Broadcast, embed URL, `#events` |

**Why composer and planner are separate:** the planner answers "does this game deserve a post right now", the composer answers "what does that post say". They change for unrelated reasons — the planner when scheduling rules change, the composer when the feed gains a field — and keeping them apart means a copy tweak cannot break scheduling.

---

### Task 1: Parse broadcast fields out of the description

The feed hides TV, radio, streaming and ticket links in `<description>`, delimited by a **literal backslash-n** (two characters, not a newline). `Parser#build_event` currently discards all of it.

**Files:**
- Modify: `lib/redhawks_schedule/parser.rb`
- Test: `spec/lib/parser_spec.rb`

**Interfaces:**
- Consumes: nothing (first task)
- Produces: every event hash gains `broadcast:` — a Hash with symbol keys drawn from `:video`, `:tv`, `:radio`, `:audio`, `:tickets`, `:livestats`. Absent labels are absent keys, so the hash is `{}` for most events.

- [ ] **Step 1: Write the failing test**

Add to `spec/lib/parser_spec.rb`, at the end of the top-level describe block:

```ruby
  describe "broadcast fields" do
    let(:broadcast_item) do
      wrap(<<~XML)
        <item>
          <title>11/10 7:00 PM Miami University Football vs Ohio</title>
          <description>Miami University Football vs Ohio\\nTV: ESPN2/ESPNU\\nRadio: Miami Radio Network\\nStreaming Audio: https://miamiredhawks.com/listen\\nTickets: https://redhawktix.evenue.net/events/FBSE\\n</description>
          <ev:startdate>2026-11-11T00:00:00.0000000Z</ev:startdate>
          <s:opponent>Ohio</s:opponent>
          <s:gameid>20845</s:gameid>
          <s:links>
            <s:livestats>https://miamiredhawks.com/sidearmstats/football/summary</s:livestats>
          </s:links>
        </item>
      XML
    end

    subject(:broadcast) do
      described_class.parse(broadcast_item, now: BEFORE_SEASON).first[:broadcast]
    end

    it "reads the TV network" do
      expect(broadcast[:tv]).to eq("ESPN2/ESPNU")
    end

    it "reads the radio network" do
      expect(broadcast[:radio]).to eq("Miami Radio Network")
    end

    it "keeps the whole URL when the value contains a colon" do
      expect(broadcast[:audio]).to eq("https://miamiredhawks.com/listen")
    end

    it "reads tickets" do
      expect(broadcast[:tickets]).to eq("https://redhawktix.evenue.net/events/FBSE")
    end

    it "reads livestats from s:links" do
      expect(broadcast[:livestats]).to eq("https://miamiredhawks.com/sidearmstats/football/summary")
    end

    it "drops the repeated title line rather than treating it as a label" do
      expect(broadcast.length).to eq(5)
    end

    it "is an empty hash when the feed carries nothing" do
      expect(described_class.parse(timed_item, now: BEFORE_SEASON).first[:broadcast]).to eq({})
    end
  end
```

Note the `\\n` in the heredoc: it produces the two-character sequence `\n` in the XML, which is what the real feed contains.

- [ ] **Step 2: Run test to verify it fails**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/lib/parser_spec.rb -e "broadcast fields"`
Expected: FAIL — `broadcast` is `nil`, so `broadcast[:tv]` raises `NoMethodError: undefined method '[]' for nil`.

- [ ] **Step 3: Write minimal implementation**

In `lib/redhawks_schedule/parser.rb`, add to the constants near `SEPARATOR`:

```ruby
    # The description repeats the title, then appends labelled lines delimited
    # by a LITERAL backslash-n — two characters, not a newline.
    DESCRIPTION_DELIMITER = "\\n"
    BROADCAST_LABELS = {
      "streaming video" => :video,
      "tv" => :tv,
      "radio" => :radio,
      "streaming audio" => :audio,
      "tickets" => :tickets,
    }.freeze
```

Add `broadcast: broadcast(item)` to the hash returned by `build_event`, then add these private methods:

```ruby
    def broadcast(item)
      found = {}

      # The first segment is the title repeated, never a labelled field.
      text(item, "description").split(DESCRIPTION_DELIMITER)[1..-1].to_a.each do |line|
        label, value = line.split(":", 2)
        next if value.nil?

        key = BROADCAST_LABELS[label.strip.downcase]
        next if key.nil?

        value = value.strip
        found[key] = value unless value.empty?
      end

      livestats = presence(text(item, "s:links/s:livestats"))
      found[:livestats] = livestats if livestats

      found
    end
```

`split(":", 2)` splits on the first colon only, so `https://…` survives intact.

- [ ] **Step 4: Run test to verify it passes**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/lib/parser_spec.rb`
Expected: PASS, including every pre-existing example.

- [ ] **Step 5: Commit**

```bash
git add lib/redhawks_schedule/parser.rb spec/lib/parser_spec.rb
git commit -m "Extract broadcast fields from the feed description"
```

---

### Task 2: Derive the embeddable player URL

The feed gives a `showcase?Live=630` link on `admin.miamiredhawks.com`. The framable player lives at a different host and path. Deriving it generalises from exactly one observed sample, so an unrecognised value must fall back to a plain link rather than produce a broken iframe.

**Files:**
- Modify: `lib/redhawks_schedule/parser.rb`
- Test: `spec/lib/parser_spec.rb`

**Interfaces:**
- Consumes: `broadcast[:video]` from Task 1
- Produces: `broadcast[:video_embed]` — the framable URL as a String, or the key is absent when the pattern does not match

- [ ] **Step 1: Write the failing test**

Add inside the `describe "broadcast fields"` block:

```ruby
    it "derives the framable player URL from a showcase link" do
      item = wrap(<<~XML)
        <item>
          <title>8/20 7:00 PM Miami University Women's Soccer vs Morehead State</title>
          <description>Miami University Women's Soccer vs Morehead State\\nStreaming Video: https://admin.miamiredhawks.com/showcase?Live=630\\n</description>
          <ev:startdate>2026-08-20T23:00:00.0000000Z</ev:startdate>
          <s:gameid>20927</s:gameid>
        </item>
      XML

      broadcast = described_class.parse(item, now: BEFORE_SEASON).first[:broadcast]

      expect(broadcast[:video_embed]).to eq(
        "https://miamiredhawks.com/showcase/embed.aspx?Live=630&type=Live",
      )
      expect(broadcast[:video]).to eq("https://admin.miamiredhawks.com/showcase?Live=630")
    end

    it "omits video_embed when the streaming video URL is an unfamiliar shape" do
      item = wrap(<<~XML)
        <item>
          <title>8/20 7:00 PM Miami University Women's Soccer vs Morehead State</title>
          <description>Miami University Women's Soccer vs Morehead State\\nStreaming Video: https://youtube.com/watch?v=abc123\\n</description>
          <ev:startdate>2026-08-20T23:00:00.0000000Z</ev:startdate>
          <s:gameid>20927</s:gameid>
        </item>
      XML

      broadcast = described_class.parse(item, now: BEFORE_SEASON).first[:broadcast]

      expect(broadcast.key?(:video_embed)).to be(false)
      expect(broadcast[:video]).to eq("https://youtube.com/watch?v=abc123")
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/lib/parser_spec.rb -e "derives the framable player URL"`
Expected: FAIL — `expected: "https://miamiredhawks.com/showcase/embed.aspx?Live=630&type=Live", got: nil`

- [ ] **Step 3: Write minimal implementation**

Add the constant:

```ruby
    # Only ONE event in the whole feed has ever carried a Streaming Video link,
    # so this pattern generalises from a single sample. A non-match must fall
    # back to a plain link — a wrong iframe is worse than a working link.
    SHOWCASE_LIVE_ID = /\/showcase\?Live=(\d+)/i
    EMBED_TEMPLATE = "https://miamiredhawks.com/showcase/embed.aspx?Live=%s&type=Live"
```

In `broadcast`, immediately before `found` is returned:

```ruby
      video = found[:video]
      if video
        match = SHOWCASE_LIVE_ID.match(video)
        found[:video_embed] = format(EMBED_TEMPLATE, match[1]) if match
      end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/lib/parser_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/redhawks_schedule/parser.rb spec/lib/parser_spec.rb
git commit -m "Derive the framable showcase player URL, with a fallback"
```

---

### Task 3: Expose uncollapsed events, and store them

`#parse` collapses multi-day tournaments into one row, which is right for the sidebar and wrong for gameday — a three-day series should be able to yield three threads. The fetch job must store both shapes, because the gameday job reads stored data and never re-fetches.

**Files:**
- Modify: `lib/redhawks_schedule/parser.rb`
- Modify: `app/jobs/scheduled/fetch_redhawks_schedule.rb`
- Modify: `plugin.rb`
- Test: `spec/lib/parser_spec.rb`

**Interfaces:**
- Consumes: nothing new
- Produces:
  - `RedhawksSchedule::Parser#events` → uncollapsed, upcoming, sorted Array of event Hashes (no `:days` key)
  - `RedhawksSchedule::Parser#parse` → unchanged: collapsed, each row carrying `:days`
  - `RedhawksSchedule::ALL_EVENTS_KEY` = `"all_events"` — PluginStore key holding the uncollapsed, serialized list

- [ ] **Step 1: Write the failing test**

Add to `spec/lib/parser_spec.rb`:

```ruby
  describe "#events" do
    let(:series) do
      wrap(<<~XML)
        <item>
          <title>10/2 Miami University Men's Golf vs Fall Invitational</title>
          <ev:startdate>2026-10-02</ev:startdate>
          <s:opponent>Fall Invitational</s:opponent>
          <s:gameid>30001</s:gameid>
        </item>
        <item>
          <title>10/3 Miami University Men's Golf vs Fall Invitational</title>
          <ev:startdate>2026-10-03</ev:startdate>
          <s:opponent>Fall Invitational</s:opponent>
          <s:gameid>30002</s:gameid>
        </item>
      XML
    end

    it "keeps each day of a series separate" do
      events = described_class.new(series, now: BEFORE_SEASON).events
      expect(events.length).to eq(2)
      expect(events.map { |e| e[:id] }).to eq(%w[30001 30002])
    end

    it "still collapses the same series in #parse" do
      rows = described_class.new(series, now: BEFORE_SEASON).parse
      expect(rows.length).to eq(1)
      expect(rows.first[:days]).to eq(2)
    end

    it "drops past events from #events" do
      after = Time.utc(2026, 12, 1)
      expect(described_class.new(series, now: after).events).to be_empty
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/lib/parser_spec.rb -e "#events"`
Expected: FAIL — `NoMethodError: undefined method 'events'`

- [ ] **Step 3: Write minimal implementation**

Replace the public `parse` method in `lib/redhawks_schedule/parser.rb`:

```ruby
    # Uncollapsed: one row per calendar item. Gameday threads want each day of
    # a series; the sidebar wants them merged, which is what #parse does.
    def events
      # `.map.compact` rather than `filter_map`: the dev Mac runs system Ruby
      # 2.6, where filter_map does not exist.
      rows = document.xpath("//channel/item").map { |item| build_event(item) }.compact
      upcoming(rows).sort_by { |e| [e[:start_utc], e[:sport]] }
    end

    def parse
      collapse(events)
    end
```

Delete the old body of `parse` and the now-duplicated comment above it.

In `plugin.rb`, extend the module:

```ruby
module ::RedhawksSchedule
  PLUGIN_NAME = "discourse-redhawks-schedule"
  STORE_KEY = "events"
  ALL_EVENTS_KEY = "all_events"
end
```

In `app/jobs/scheduled/fetch_redhawks_schedule.rb`, replace the single `PluginStore.set` with:

```ruby
      parser = ::RedhawksSchedule::Parser.new(body)
      generated_at = Time.now.utc.iso8601

      PluginStore.set(
        ::RedhawksSchedule::PLUGIN_NAME,
        ::RedhawksSchedule::STORE_KEY,
        { "generated_at" => generated_at, "events" => parser.parse.map { |e| serialize(e) } },
      )

      # Gameday threads need each day of a series, and read stored data rather
      # than re-fetching, so the uncollapsed list is stored alongside.
      PluginStore.set(
        ::RedhawksSchedule::PLUGIN_NAME,
        ::RedhawksSchedule::ALL_EVENTS_KEY,
        { "generated_at" => generated_at, "events" => parser.events.map { |e| serialize(e) } },
      )
```

and delete the now-unused `events = ::RedhawksSchedule::Parser.parse(body)` line above it.

- [ ] **Step 4: Run test to verify it passes**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/`
Expected: PASS — the whole file, confirming `#parse` behaviour is unchanged for the sidebar.

- [ ] **Step 5: Commit**

```bash
git add lib/redhawks_schedule/parser.rb app/jobs/scheduled/fetch_redhawks_schedule.rb plugin.rb spec/lib/parser_spec.rb
git commit -m "Expose uncollapsed events and store them for gameday"
```

---

### Task 4: Pure US Eastern time helpers

Digest day-of-week and week boundaries must be Eastern. `Time.zone` is ActiveSupport and unavailable in `lib/`, so this implements the US federal DST rule directly: daylight time runs from the second Sunday in March at 02:00 local standard (07:00 UTC) to the first Sunday in November at 02:00 local daylight (06:00 UTC).

**Files:**
- Create: `lib/redhawks_schedule/eastern.rb`
- Test: `spec/lib/eastern_spec.rb`

**Interfaces:**
- Consumes: nothing
- Produces: `RedhawksSchedule::Eastern` with module functions
  - `.dst?(utc)` → Boolean
  - `.local(utc)` → Time carrying Eastern wall-clock values (its own zone label is meaningless; use it only for reading `.year`, `.month`, `.day`, `.hour`, `.wday`, `.strftime`)
  - `.day_name(utc)` → String, e.g. `"Monday"`
  - `.iso_week(utc)` → String, e.g. `"2026-W36"`
  - `.start_of_day(utc)` → Time (UTC) at Eastern midnight of that Eastern date

- [ ] **Step 1: Write the failing test**

Create `spec/lib/eastern_spec.rb`:

```ruby
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
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/lib/eastern_spec.rb`
Expected: FAIL — `cannot load such file -- .../lib/redhawks_schedule/eastern`

- [ ] **Step 3: Write minimal implementation**

Create `lib/redhawks_schedule/eastern.rb`:

```ruby
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/lib/eastern_spec.rb`
Expected: PASS (12 examples)

- [ ] **Step 5: Commit**

```bash
git add lib/redhawks_schedule/eastern.rb spec/lib/eastern_spec.rb
git commit -m "Add pure US Eastern time helpers"
```

---

### Task 5: Compose topic titles and bodies

Pure formatting: an event (or a week of them) becomes a topic title and a markdown body. Handles the three stream states — embeddable iframe, TV badge with outbound link, nothing at all.

**Files:**
- Create: `lib/redhawks_schedule/gameday_composer.rb`
- Test: `spec/lib/gameday_composer_spec.rb`

**Interfaces:**
- Consumes: `RedhawksSchedule::Eastern` (Task 4); event Hashes shaped by Tasks 1–3
- Produces: `RedhawksSchedule::GamedayComposer` with module functions
  - `.thread_title(event)` → String
  - `.thread_body(event)` → String
  - `.digest_title(sport, now)` → String
  - `.digest_body(sport, events)` → String

- [ ] **Step 1: Write the failing test**

Create `spec/lib/gameday_composer_spec.rb`:

```ruby
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
    it "leads with the matchup, Eastern kickoff and location" do
      body = described_class.thread_body(event)
      expect(body).to include("**Football vs Ohio**")
      expect(body).to include("Tuesday, November 10 · 7:00 PM ET")
      expect(body).to include("Oxford, Ohio")
    end

    it "says Time TBA when the feed announced no time" do
      body = described_class.thread_body(event(time_known: false))
      expect(body).to include("Time TBA")
      expect(body).to_not include("PM ET")
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
      expect(body).to include("[Watch the stream](https://youtube.com/watch?v=abc)")
      expect(body).to_not include("<iframe")
    end

    it "shows a TV badge with no embed for a network broadcast" do
      body = described_class.thread_body(event(broadcast: { tv: "ESPN2/ESPNU" }))
      expect(body).to include("**TV:** ESPN2/ESPNU")
      expect(body).to_not include("<iframe")
    end

    it "lists radio, audio, live stats and tickets when present" do
      body = described_class.thread_body(
        event(
          broadcast: {
            radio: "Miami Radio Network",
            audio: "https://miamiredhawks.com/listen",
            livestats: "https://miamiredhawks.com/sidearmstats/football/summary",
            tickets: "https://redhawktix.evenue.net/events/FBSE",
          },
        ),
      )
      expect(body).to include("**Radio:** Miami Radio Network")
      expect(body).to include("[Listen live](https://miamiredhawks.com/listen)")
      expect(body).to include("[Live stats](https://miamiredhawks.com/sidearmstats/football/summary)")
      expect(body).to include("[Tickets](https://redhawktix.evenue.net/events/FBSE)")
    end

    it "omits the whole broadcast section when the feed carries nothing" do
      body = described_class.thread_body(event)
      expect(body).to_not include("**TV:**")
      expect(body).to_not include("<iframe")
      expect(body).to_not include("[Tickets]")
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
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/lib/gameday_composer_spec.rb`
Expected: FAIL — `cannot load such file -- .../lib/redhawks_schedule/gameday_composer`

- [ ] **Step 3: Write minimal implementation**

Create `lib/redhawks_schedule/gameday_composer.rb`:

```ruby
# frozen_string_literal: true

require "time"
require_relative "eastern"

module RedhawksSchedule
  # Turns events into topic titles and markdown bodies. Pure formatting — it
  # decides how a post reads, never whether it should exist. That split means a
  # copy change cannot break scheduling.
  module GamedayComposer
    IFRAME = '<iframe src="%s" width="100%%" height="420" frameborder="0" allowfullscreen></iframe>'

    module_function

    def thread_title(event)
      "#{matchup(event)} — #{Eastern.local(event[:start_utc]).strftime('%b %-d')}"
    end

    def thread_body(event)
      lines = ["**#{matchup(event)}**", when_line(event)]
      lines << event[:location] if event[:location]

      broadcast = event[:broadcast] || {}
      stream = stream_block(broadcast)
      lines += ["", stream] if stream

      details = detail_lines(broadcast)
      lines += [""] + details unless details.empty?

      links = link_line(broadcast)
      lines += ["", links] if links

      lines << ""
      lines << "[Game page](#{event[:url]})" if event[:url]

      lines.join("\n").strip
    end

    def digest_title(sport, now)
      "#{sport} — week of #{Eastern.local(now).strftime('%B %-d')}"
    end

    def digest_body(sport, events)
      lines = ["#{sport} games this week:", ""]

      events.each do |event|
        line = "- #{when_line(event)} — #{side(event)} #{event[:opponent]}"
        line += " (#{event[:location]})" if event[:location]

        stats = (event[:broadcast] || {})[:livestats]
        line += " · [Live stats](#{stats})" if stats

        lines << line
      end

      lines.join("\n")
    end

    def matchup(event)
      "#{event[:sport]} #{side(event)} #{event[:opponent]}"
    end

    def side(event)
      event[:home_away] == "away" ? "at" : "vs"
    end

    def when_line(event)
      local = Eastern.local(event[:start_utc])
      date = local.strftime("%A, %B %-d")
      return "#{date} · Time TBA" unless event[:time_known]

      "#{date} · #{local.strftime('%-I:%M %p')} ET"
    end

    # Three states: framable player, plain link, nothing.
    def stream_block(broadcast)
      return format(IFRAME, broadcast[:video_embed]) if broadcast[:video_embed]
      return "[Watch the stream](#{broadcast[:video]})" if broadcast[:video]

      nil
    end

    def detail_lines(broadcast)
      lines = []
      lines << "**TV:** #{broadcast[:tv]}" if broadcast[:tv]
      lines << "**Radio:** #{broadcast[:radio]}" if broadcast[:radio]
      lines
    end

    def link_line(broadcast)
      links = []
      links << "[Listen live](#{broadcast[:audio]})" if broadcast[:audio]
      links << "[Live stats](#{broadcast[:livestats]})" if broadcast[:livestats]
      links << "[Tickets](#{broadcast[:tickets]})" if broadcast[:tickets]
      return nil if links.empty?

      links.join(" · ")
    end
  end
end
```

Note `100%%` inside `IFRAME`: `format` needs the percent escaped.

- [ ] **Step 4: Run test to verify it passes**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/lib/gameday_composer_spec.rb`
Expected: PASS (12 examples)

- [ ] **Step 5: Commit**

```bash
git add lib/redhawks_schedule/gameday_composer.rb spec/lib/gameday_composer_spec.rb
git commit -m "Compose gameday titles and bodies from events"
```

---

### Task 6: Plan per-game threads

The planner decides what to post. Pure: it takes events, config, the ledger of what already exists and the current time, and returns actions. It never writes anything.

**Files:**
- Create: `lib/redhawks_schedule/gameday_planner.rb`
- Test: `spec/lib/gameday_planner_spec.rb`

**Interfaces:**
- Consumes: `RedhawksSchedule::Eastern` (Task 4); event Hashes from Tasks 1–3
- Produces: `RedhawksSchedule::GamedayPlanner.plan(events:, config:, ledger:, now:, limit: 5)` → Hash with:
  - `:actions` → Array of Hashes. Thread actions are `{ kind: :thread, key: String, category_id: Integer, event: Hash }`. Digest actions arrive in Task 7.
  - `:unmatched` → Array of configured sport names that match no event
  - `:deferred` → Integer, how many eligible actions the limit held back
  - Config rows accept String or Symbol keys; the planner normalises them.

- [ ] **Step 1: Write the failing test**

Create `spec/lib/gameday_planner_spec.rb`:

```ruby
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/lib/gameday_planner_spec.rb`
Expected: FAIL — `cannot load such file -- .../lib/redhawks_schedule/gameday_planner`

- [ ] **Step 3: Write minimal implementation**

Create `lib/redhawks_schedule/gameday_planner.rb`:

```ruby
# frozen_string_literal: true

require "time"
require_relative "eastern"

module RedhawksSchedule
  # Decides what to post. Pure: no Rails, no clock, no I/O — `now` is always
  # passed in. The job that executes a plan cannot be tested on the dev Mac, so
  # every scheduling rule worth getting right lives here instead.
  module GamedayPlanner
    DAY = 24 * 60 * 60
    DEFAULT_LIMIT = 5

    module_function

    def plan(events:, config:, ledger:, now:, limit: DEFAULT_LIMIT)
      rows = config.map { |row| normalize(row) }
      seen_sports = {}
      events.each { |e| seen_sports[e[:sport]] = true }

      eligible = []
      rows.each do |row|
        next if row[:mode] == "off" || row[:category_id].nil?

        sport_events = events.select { |e| e[:sport] == row[:sport] }
        eligible += thread_actions(sport_events, row, ledger, now) if row[:mode] == "thread"
      end

      eligible = eligible.sort_by { |a| a[:sort_at] }

      {
        actions: eligible.take(limit).map { |a| a.reject { |k, _| k == :sort_at } },
        deferred: [eligible.length - limit, 0].max,
        unmatched: rows.map { |r| r[:sport] }.reject { |s| seen_sports[s] },
      }
    end

    def thread_actions(sport_events, row, ledger, now)
      days_before = row[:days_before] || 0

      sport_events.each_with_object([]) do |event, actions|
        next if event[:id].nil?

        key = "gameday:game:#{event[:id]}"
        next if ledger.key?(key)
        # The window opens at Eastern MIDNIGHT of the day `days_before` ahead,
        # not at the kickoff minute. Otherwise days_before: 0 would mean "post
        # at kickoff", which is useless, rather than "post that morning".
        next if now < Eastern.start_of_day(event[:start_utc] - days_before * DAY)

        actions << {
          kind: :thread,
          key: key,
          category_id: row[:category_id],
          event: event,
          sort_at: event[:start_utc],
        }
      end
    end

    # Site settings hand back string keys; specs are easier to read with
    # symbols. Accept both rather than making the untestable job convert.
    def normalize(row)
      get = lambda { |name| row[name] || row[name.to_s] }
      categories = get.call(:category)

      {
        sport: get.call(:sport),
        mode: get.call(:mode).to_s,
        category_id: categories.is_a?(Array) ? categories.first : categories,
        days_before: get.call(:days_before),
        digest_day: get.call(:digest_day),
      }
    end
  end
end
```

`a.reject { |k, _| k == :sort_at }` rather than `Hash#except`, which does not exist in Ruby 2.6.

- [ ] **Step 4: Run test to verify it passes**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/lib/gameday_planner_spec.rb`
Expected: PASS (13 examples)

- [ ] **Step 5: Commit**

```bash
git add lib/redhawks_schedule/gameday_planner.rb spec/lib/gameday_planner_spec.rb
git commit -m "Plan per-game gameday threads"
```

---

### Task 7: Plan weekly digests

Sports in `digest` mode get one topic per week listing that week's games, posted on a configured Eastern day. An empty week posts nothing.

**Files:**
- Modify: `lib/redhawks_schedule/gameday_planner.rb`
- Test: `spec/lib/gameday_planner_spec.rb`

**Interfaces:**
- Consumes: `GamedayPlanner.plan` from Task 6; `Eastern.day_name`, `Eastern.iso_week`, `Eastern.start_of_day` from Task 4
- Produces: digest actions in `:actions` — `{ kind: :digest, key: String, category_id: Integer, sport: String, events: Array }`, where `key` is `"gameday:digest:<Sport>:<ISO week>"`

- [ ] **Step 1: Write the failing test**

Add to `spec/lib/gameday_planner_spec.rb`:

```ruby
  describe "digest mode" do
    # 2026-08-31 12:00 UTC is Monday, 8:00 AM Eastern.
    MONDAY = Time.utc(2026, 8, 31, 12)

    let(:config) do
      [{ sport: "Field Hockey", mode: "digest", category: [9], digest_day: "Monday" }]
    end

    let(:this_week) do
      [
        event(id: "40001", sport: "Field Hockey", start_utc: Time.utc(2026, 9, 4, 17)),
        event(id: "40002", sport: "Field Hockey", start_utc: Time.utc(2026, 9, 6, 19)),
      ]
    end

    it "plans one digest holding the week's games" do
      result = plan(this_week, config, {}, MONDAY)
      action = result[:actions].first

      expect(result[:actions].length).to eq(1)
      expect(action[:kind]).to eq(:digest)
      expect(action[:sport]).to eq("Field Hockey")
      expect(action[:category_id]).to eq(9)
      expect(action[:events].map { |e| e[:id] }).to eq(%w[40001 40002])
    end

    it "keys the digest by Eastern ISO week" do
      action = plan(this_week, config, {}, MONDAY)[:actions].first
      expect(action[:key]).to eq("gameday:digest:Field Hockey:2026-W36")
    end

    it "posts nothing on any other day of the week" do
      tuesday = MONDAY + DAY_SECONDS
      expect(plan(this_week, config, {}, tuesday)[:actions]).to be_empty
    end

    it "posts nothing when the week holds no games" do
      later = [event(id: "40003", sport: "Field Hockey", start_utc: Time.utc(2026, 10, 1, 17))]
      expect(plan(later, config, {}, MONDAY)[:actions]).to be_empty
    end

    it "skips a week already in the ledger" do
      ledger = { "gameday:digest:Field Hockey:2026-W36" => 55 }
      expect(plan(this_week, config, ledger, MONDAY)[:actions]).to be_empty
    end

    it "excludes games beyond seven days" do
      mixed = this_week + [event(id: "40009", sport: "Field Hockey", start_utc: Time.utc(2026, 9, 30, 17))]
      action = plan(mixed, config, {}, MONDAY)[:actions].first
      expect(action[:events].map { |e| e[:id] }).to eq(%w[40001 40002])
    end

    it "never applies the burst cap to digests" do
      wide = (1..8).map do |n|
        event(id: "410#{n}", sport: "Field Hockey", start_utc: Time.utc(2026, 9, 1, 17))
      end
      result = plan(wide, config, {}, MONDAY, 1)
      expect(result[:actions].length).to eq(1)
      expect(result[:actions].first[:events].length).to eq(8)
    end
  end
```

Add near the top of the file, beside `NOW`:

```ruby
  DAY_SECONDS = 24 * 60 * 60
```

- [ ] **Step 2: Run test to verify it fails**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/lib/gameday_planner_spec.rb -e "digest mode"`
Expected: FAIL — `expected: 1, got: 0`; no digest actions are produced.

- [ ] **Step 3: Write minimal implementation**

In `lib/redhawks_schedule/gameday_planner.rb`, add a constant beside `DAY`:

```ruby
    WEEK = 7 * DAY
```

Replace the loop body inside `plan` so digests are collected separately — the burst cap governs per-game threads, which is where an unbounded first run would flood a category, not the one-per-sport-per-week digest:

```ruby
      eligible = []
      digests = []

      rows.each do |row|
        next if row[:mode] == "off" || row[:category_id].nil?

        sport_events = events.select { |e| e[:sport] == row[:sport] }

        case row[:mode]
        when "thread"
          eligible += thread_actions(sport_events, row, ledger, now)
        when "digest"
          action = digest_action(sport_events, row, ledger, now)
          digests << action if action
        end
      end

      eligible = eligible.sort_by { |a| a[:sort_at] }

      {
        actions: digests + eligible.take(limit).map { |a| a.reject { |k, _| k == :sort_at } },
        deferred: [eligible.length - limit, 0].max,
        unmatched: rows.map { |r| r[:sport] }.reject { |s| seen_sports[s] },
      }
```

Add the method:

```ruby
    def digest_action(sport_events, row, ledger, now)
      return nil unless Eastern.day_name(now) == row[:digest_day].to_s

      key = "gameday:digest:#{row[:sport]}:#{Eastern.iso_week(now)}"
      return nil if ledger.key?(key)

      window_start = Eastern.start_of_day(now)
      window_end = window_start + WEEK
      in_week = sport_events.select do |e|
        e[:start_utc] >= window_start && e[:start_utc] < window_end
      end

      # An empty week is silence, not an empty digest.
      return nil if in_week.empty?

      {
        kind: :digest,
        key: key,
        category_id: row[:category_id],
        sport: row[:sport],
        events: in_week,
      }
    end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/`
Expected: PASS — every spec file, confirming Task 6's thread planning still holds.

- [ ] **Step 5: Commit**

```bash
git add lib/redhawks_schedule/gameday_planner.rb spec/lib/gameday_planner_spec.rb
git commit -m "Plan weekly per-sport digests"
```

---

### Task 8: Site settings and iframe allowlisting

Per-sport configuration as an admin-editable table, and the one core setting that decides whether the embed survives Discourse's sanitizer.

**Files:**
- Modify: `config/settings.yml`
- Modify: `plugin.rb`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `SiteSetting.redhawks_gameday_enabled` → Boolean, default `false`
  - `SiteSetting.redhawks_gameday_sports` → Array of Hashes with String keys `sport`, `mode`, `category`, `days_before`, `digest_day`
  - `SiteSetting.redhawks_gameday_poster_username` → String, default `"swoop_bot"`
  - `RedhawksSchedule::EMBED_PREFIX` → the `allowed_iframes` entry

- [ ] **Step 1: Write the settings**

Replace `config/settings.yml` with:

```yaml
plugins:
  redhawks_schedule_enabled:
    default: true
    client: true
  redhawks_schedule_feed_url:
    default: "https://miamiredhawks.com/calendar.ashx/calendar.rss"
  redhawks_gameday_enabled:
    default: false
  redhawks_gameday_poster_username:
    default: "swoop_bot"
  redhawks_gameday_sports:
    type: objects
    default: []
    schema:
      name: sport
      properties:
        sport:
          type: string
          required: true
        mode:
          type: enum
          required: true
          default: "off"
          choices:
            - "thread"
            - "digest"
            - "off"
        category:
          type: categories
          required: true
          validations:
            max: 1
        days_before:
          type: integer
          validations:
            min: 0
            max: 14
        digest_day:
          type: enum
          default: "Monday"
          choices:
            - "Monday"
            - "Tuesday"
            - "Wednesday"
            - "Thursday"
            - "Friday"
            - "Saturday"
            - "Sunday"
```

`redhawks_gameday_enabled` defaults to `false` so the rebuild that ships this does not immediately post to a live forum.

- [ ] **Step 2: Wire up plugin.rb**

Replace `plugin.rb` with:

```ruby
# frozen_string_literal: true

# name: discourse-redhawks-schedule
# about: Fetches the Miami University Athletics RSS calendar, serves upcoming events as JSON, and opens gameday topics.
# version: 0.2.0
# authors: MiamiHawkTalk
# url: https://github.com/dustin-riley/discourse-redhawks-schedule

enabled_site_setting :redhawks_schedule_enabled

module ::RedhawksSchedule
  PLUGIN_NAME = "discourse-redhawks-schedule"
  STORE_KEY = "events"
  ALL_EVENTS_KEY = "all_events"
  LEDGER_KEY = "gameday_ledger"
  BOT_ID_KEY = "gameday_bot_user_id"

  # Discourse strips iframes unless the src prefix is allowlisted. Prefix
  # matching, so the query string is deliberately left open.
  EMBED_PREFIX = "https://miamiredhawks.com/showcase/embed.aspx?"
end

require_relative "lib/redhawks_schedule/parser"
require_relative "lib/redhawks_schedule/eastern"
require_relative "lib/redhawks_schedule/gameday_composer"
require_relative "lib/redhawks_schedule/gameday_planner"

after_initialize do
  require_relative "app/services/redhawks_schedule/gameday_bot"
  require_relative "app/jobs/scheduled/fetch_redhawks_schedule"
  require_relative "app/jobs/scheduled/post_redhawks_gameday"
  require_relative "app/controllers/redhawks_schedule_controller"

  Discourse::Application.routes.append do
    get "/redhawks-schedule" => "redhawks_schedule#index", :format => :json
  end

  # Allowlist the player once, rather than relying on a remembered manual step.
  # Guarded, so this writes on first boot after deploy and never again.
  begin
    allowed = SiteSetting.allowed_iframes.to_s.split("|")
    unless allowed.include?(::RedhawksSchedule::EMBED_PREFIX)
      SiteSetting.allowed_iframes = (allowed + [::RedhawksSchedule::EMBED_PREFIX]).join("|")
    end
  rescue StandardError => e
    Rails.logger.warn("[redhawks-schedule] could not allowlist the player iframe: #{e.class}: #{e.message}")
  end
end
```

The `rescue` matters: a failure here must not take the site down on boot.

- [ ] **Step 3: Verify the plugin still loads its pure code**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/`
Expected: PASS — this does not exercise `plugin.rb`, but confirms nothing in `lib/` broke. Tasks 9 and 10 create the two files `plugin.rb` now requires; until then the plugin will not boot, which is why this task does not deploy.

- [ ] **Step 4: Commit**

```bash
git add config/settings.yml plugin.rb
git commit -m "Add gameday site settings and allowlist the player iframe"
```

---

### Task 9: Resolve or create Swoop Bot

The poster is a dedicated account the plugin creates on demand, identified thereafter by a stored user id so renaming it in the admin UI cannot spawn a duplicate.

**Files:**
- Create: `app/services/redhawks_schedule/gameday_bot.rb`

**Interfaces:**
- Consumes: `RedhawksSchedule::BOT_ID_KEY`, `PLUGIN_NAME` (Task 8)
- Produces: `RedhawksSchedule::GamedayBot.resolve` → a `User`, or `nil` when the stored id no longer resolves

- [ ] **Step 1: Write the implementation**

This file needs Rails (`User`, `PluginStore`, `SiteSetting`) and cannot be tested on the dev Mac. Task 10's job spec covers its behaviour on the server.

Create `app/services/redhawks_schedule/gameday_bot.rb`:

```ruby
# frozen_string_literal: true

module ::RedhawksSchedule
  # The account gameday topics are posted as.
  #
  # Identity is the STORED USER ID, not the username. Resolving by username
  # each run would create a second account the first time anyone renames the
  # bot in the admin UI, orphaning every existing thread's author. With the id
  # stored, Swoop Bot can be renamed, re-avatared and given a bio freely.
  #
  # Core's own bots were both rejected: `system` (-1) has an unguarded
  # User.seed fixture, so seed-fu resets its username on every db:migrate, and
  # it attributes all staff and automation notices; `discobot` (-2) routes any
  # reply to its own posts into the new-user tutorial, which would answer fans
  # in every game thread.
  class GamedayBot
    DISPLAY_NAME = "Swoop Bot"
    EMAIL = "swoop-bot@miamihawktalk.fans"

    def self.resolve
      stored_id = PluginStore.get(::RedhawksSchedule::PLUGIN_NAME, ::RedhawksSchedule::BOT_ID_KEY)

      if stored_id
        user = User.find_by(id: stored_id)
        if user.nil?
          # Deliberately not recreated: a vanished bot account is a thing to
          # look at, not to paper over with a fresh one.
          Rails.logger.warn(
            "[redhawks-schedule] gameday bot user ##{stored_id} no longer exists; posting nothing",
          )
        end
        return user
      end

      create_bot
    end

    def self.create_bot
      username = SiteSetting.redhawks_gameday_poster_username
      username = "swoop_bot" if username.blank?

      user = User.find_by_username(username) || build_user(username)
      PluginStore.set(::RedhawksSchedule::PLUGIN_NAME, ::RedhawksSchedule::BOT_ID_KEY, user.id)
      user
    rescue StandardError => e
      Rails.logger.warn("[redhawks-schedule] could not create the gameday bot: #{e.class}: #{e.message}")
      nil
    end

    def self.build_user(username)
      user =
        User.create!(
          username: UserNameSuggester.suggest(username),
          name: DISPLAY_NAME,
          email: EMAIL,
          password: SecureRandom.hex(32),
          active: true,
          approved: true,
          trust_level: TrustLevel[4],
        )

      user.email_tokens.update_all(confirmed: true)
      user.user_option&.update!(
        email_messages_level: UserOption.email_level_types[:never],
        email_level: UserOption.email_level_types[:never],
      )
      user
    end
  end
end
```

`email_level: never` matters — without it the bot mails itself about every reply in every gameday thread.

- [ ] **Step 2: Check syntax**

Run: `ruby -c app/services/redhawks_schedule/gameday_bot.rb`
Expected: `Syntax OK`

- [ ] **Step 3: Commit**

```bash
git add app/services/redhawks_schedule/gameday_bot.rb
git commit -m "Resolve or create Swoop Bot, identified by stored user id"
```

---

### Task 10: The scheduled job

A thin executor: load stored events, deserialize, call the planner, compose, post, record. Everything interesting was decided in Tasks 5–7.

**Files:**
- Create: `app/jobs/scheduled/post_redhawks_gameday.rb`
- Test: `spec/jobs/post_redhawks_gameday_spec.rb`

**Interfaces:**
- Consumes: `GamedayPlanner.plan` (Tasks 6–7), `GamedayComposer` (Task 5), `GamedayBot.resolve` (Task 9), `ALL_EVENTS_KEY` and `LEDGER_KEY` (Task 8)
- Produces: `Jobs::PostRedhawksGameday`, running every 30 minutes

- [ ] **Step 1: Write the implementation**

Create `app/jobs/scheduled/post_redhawks_gameday.rb`:

```ruby
# frozen_string_literal: true

module ::Jobs
  class PostRedhawksGameday < ::Jobs::Scheduled
    every 30.minutes

    def execute(_args)
      return unless SiteSetting.redhawks_schedule_enabled
      return unless SiteSetting.redhawks_gameday_enabled

      config = SiteSetting.redhawks_gameday_sports
      return if config.blank?

      events = stored_events
      return if events.empty?

      ledger = PluginStore.get(::RedhawksSchedule::PLUGIN_NAME, ::RedhawksSchedule::LEDGER_KEY) || {}

      plan =
        ::RedhawksSchedule::GamedayPlanner.plan(
          events: events,
          config: config,
          ledger: ledger,
          now: Time.now.utc,
        )

      plan[:unmatched].each do |sport|
        Rails.logger.warn("[redhawks-schedule] configured sport matches no event: #{sport.inspect}")
      end

      if plan[:deferred] > 0
        Rails.logger.info("[redhawks-schedule] deferred #{plan[:deferred]} gameday topics to a later run")
      end

      return if plan[:actions].empty?

      bot = ::RedhawksSchedule::GamedayBot.resolve
      return if bot.nil?

      plan[:actions].each { |action| post(action, bot, ledger) }
    rescue StandardError => e
      Rails.logger.warn("[redhawks-schedule] gameday run failed: #{e.class}: #{e.message}")
    end

    private

    def post(action, bot, ledger)
      if action[:kind] == :thread
        title = ::RedhawksSchedule::GamedayComposer.thread_title(action[:event])
        raw = ::RedhawksSchedule::GamedayComposer.thread_body(action[:event])
      else
        title = ::RedhawksSchedule::GamedayComposer.digest_title(action[:sport], Time.now.utc)
        raw = ::RedhawksSchedule::GamedayComposer.digest_body(action[:sport], action[:events])
      end

      post =
        PostCreator.create!(
          bot,
          title: title,
          raw: raw,
          category: action[:category_id],
          # Swoop Bot is an ordinary user, so it is subject to new-user rate
          # limits and post validations that do not apply to core's bots.
          skip_validations: true,
        )

      # Record before the next action, so a mid-run failure cannot duplicate
      # everything already posted.
      ledger[action[:key]] = post.topic_id
      PluginStore.set(::RedhawksSchedule::PLUGIN_NAME, ::RedhawksSchedule::LEDGER_KEY, ledger)
    rescue StandardError => e
      Rails.logger.warn("[redhawks-schedule] could not post #{action[:key]}: #{e.class}: #{e.message}")
    end

    def stored_events
      stored = PluginStore.get(::RedhawksSchedule::PLUGIN_NAME, ::RedhawksSchedule::ALL_EVENTS_KEY)
      return [] if stored.nil?

      (stored["events"] || []).map { |row| deserialize(row) }
    end

    # PluginStore round-trips through JSON, so everything comes back with
    # string keys and times as strings. The planner and composer expect symbol
    # keys and real Times.
    def deserialize(row)
      event = {}
      row.each { |key, value| event[key.to_sym] = value }

      event[:start_utc] = Time.iso8601(event[:start_utc]) if event[:start_utc].is_a?(String)
      event[:end_utc] = Time.iso8601(event[:end_utc]) if event[:end_utc].is_a?(String)

      broadcast = {}
      (event[:broadcast] || {}).each { |key, value| broadcast[key.to_sym] = value }
      event[:broadcast] = broadcast

      event
    end
  end
end
```

- [ ] **Step 2: Check syntax**

Run: `ruby -c app/jobs/scheduled/post_redhawks_gameday.rb`
Expected: `Syntax OK`

- [ ] **Step 3: Write the job spec**

This spec needs Rails and runs **only inside the container**, per the repo's constraints. Create `spec/jobs/post_redhawks_gameday_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Jobs::PostRedhawksGameday do
  fab!(:category) { Fabricate(:category) }

  let(:events) do
    [
      {
        "id" => "20845",
        "sport" => "Football",
        "opponent" => "Ohio",
        "home_away" => "home",
        "start_utc" => 2.days.from_now.utc.iso8601,
        "end_utc" => 2.days.from_now.utc.iso8601,
        "time_known" => true,
        "location" => "Oxford, Ohio",
        "broadcast" => {},
      },
    ]
  end

  before do
    SiteSetting.redhawks_schedule_enabled = true
    SiteSetting.redhawks_gameday_enabled = true
    PluginStore.set(
      RedhawksSchedule::PLUGIN_NAME,
      RedhawksSchedule::ALL_EVENTS_KEY,
      { "generated_at" => Time.now.utc.iso8601, "events" => events },
    )
    SiteSetting.redhawks_gameday_sports = [
      { "sport" => "Football", "mode" => "thread", "category" => [category.id], "days_before" => 5 },
    ]
  end

  it "creates a topic in the configured category" do
    expect { described_class.new.execute({}) }.to change { Topic.count }.by(1)
    expect(Topic.last.category_id).to eq(category.id)
    expect(Topic.last.title).to include("Football vs Ohio")
  end

  it "posts nothing on a second run" do
    described_class.new.execute({})
    expect { described_class.new.execute({}) }.to_not change { Topic.count }
  end

  it "posts nothing when disabled" do
    SiteSetting.redhawks_gameday_enabled = false
    expect { described_class.new.execute({}) }.to_not change { Topic.count }
  end

  it "creates the bot exactly once across two runs" do
    described_class.new.execute({})
    bot_id = PluginStore.get(RedhawksSchedule::PLUGIN_NAME, RedhawksSchedule::BOT_ID_KEY)
    expect(bot_id).to be_present

    PluginStore.set(RedhawksSchedule::PLUGIN_NAME, RedhawksSchedule::LEDGER_KEY, {})
    expect { described_class.new.execute({}) }.to_not change { User.count }
  end

  it "keeps posting as the same account after a rename" do
    described_class.new.execute({})
    bot = Topic.last.user
    bot.update!(username: "renamed_bot")

    PluginStore.set(RedhawksSchedule::PLUGIN_NAME, RedhawksSchedule::LEDGER_KEY, {})
    described_class.new.execute({})

    expect(Topic.last.user_id).to eq(bot.id)
  end
end
```

- [ ] **Step 4: Commit**

```bash
git add app/jobs/scheduled/post_redhawks_gameday.rb spec/jobs/post_redhawks_gameday_spec.rb
git commit -m "Post gameday topics from the plan"
```

---

### Task 11: Update CLAUDE.md

The repo's own guidance says this plugin serves "one feature". It now serves two, and the next session needs to know where the boundary actually is.

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: nothing
- Produces: nothing

- [ ] **Step 1: Rewrite the "What this is" section**

Replace it with:

```markdown
## What this is

A **Discourse plugin** with two features, both fed by the Miami Athletics RSS
calendar it fetches every 30 minutes:

- `/redhawks-schedule.json` — upcoming events, rendered by
  `../miamihawktalk-schedule/`.
- **Gameday topics** — a topic per game, or one weekly digest per sport,
  opened automatically and posted as Swoop Bot.

The schedule exists because `miamiredhawks.com` sends no CORS headers, so a
browser cannot fetch that feed directly.
```

- [ ] **Step 2: Extend the Architecture section**

Add after the existing bullets:

```markdown
- **`lib/redhawks_schedule/eastern.rb`**, **`gameday_composer.rb`**,
  **`gameday_planner.rb`** — pure, like the parser, and for the same reason.
  The planner decides *what* to post; the composer decides *how it reads*; the
  job only executes. Scheduling rules that lived in the job would be
  untestable until they were posting to a live forum.
- **`app/services/redhawks_schedule/gameday_bot.rb`** — resolves Swoop Bot by a
  **stored user id**, never by username. Renaming the bot in the admin UI must
  not spawn a duplicate or orphan existing threads.
- **`app/jobs/scheduled/post_redhawks_gameday.rb`** — every 30 minutes, gated
  on `redhawks_gameday_enabled`, which defaults to **false**.

Two PluginStore keys back gameday: `gameday_ledger` (what has been posted) and
`gameday_bot_user_id`. Clearing the ledger causes every eligible topic to be
posted again.
```

- [ ] **Step 3: Add a section on the feed's broadcast fields**

Add after "The feed's dominant quirk":

```markdown
## What the feed carries about broadcasts

`<description>` holds labelled lines delimited by a **literal backslash-n** —
two characters, not a newline. Labels seen: `Streaming Video`, `TV`, `Radio`,
`Streaming Audio`, `Tickets`. `<s:links>` holds only `<s:livestats>`.

**`TV:` is a bare network name with no URL**, and ESPN cannot be embedded by
any route — subscription and MVPD auth, DRM'd per-session manifests, no embed
API. Football, basketball and baseball therefore get a TV badge and an
outbound link, permanently. That is a ceiling, not a gap to close.

Exactly one event in the feed has ever carried a `Streaming Video` link, so the
`showcase?Live=NNN` → `showcase/embed.aspx?Live=NNN&type=Live` transform
generalises from a single sample. A non-match falls back to a plain link and
logs; do not widen the pattern on a guess.
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "Document the gameday half of the plugin"
```

---

### Task 12: Deploy and verify

One rebuild, at the end, with the feature switched off. This is the only step with downtime.

**Files:** none

- [ ] **Step 1: Run the whole pure suite one more time**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/`
Expected: PASS. `spec/jobs/` will not run here — it needs Rails.

- [ ] **Step 2: Push**

```bash
git push origin main
```

- [ ] **Step 3: Rebuild**

Use the `discourse-server-ops` skill. On the server:

```bash
cd /var/discourse && ./launcher rebuild app
```

Several minutes of downtime. If the site does not come back, remove this plugin's clone line from `containers/app.yml` and rebuild again to restore service, then debug.

- [ ] **Step 4: Verify the sidebar still works**

```bash
curl -s https://miamihawktalk.fans/redhawks-schedule.json | head -c 300
```

Expected: JSON with `generated_at` and `events`. This confirms Task 3 did not disturb the existing consumer.

- [ ] **Step 5: Confirm the iframe allowlist took**

```bash
cd /var/discourse && ./launcher enter app
cd /var/www/discourse
sudo -E -u discourse bundle exec rails runner 'puts SiteSetting.allowed_iframes'
```

Expected: the value ends with `|https://miamiredhawks.com/showcase/embed.aspx?`

- [ ] **Step 6: Run the Rails job spec**

Inside the container:

```bash
sudo -E -u discourse LOAD_PLUGINS=1 bundle exec rspec plugins/discourse-redhawks-schedule/spec/jobs/post_redhawks_gameday_spec.rb
```

Expected: PASS (5 examples)

- [ ] **Step 7: Configure one sport, then enable**

In the admin UI, under Settings → Plugins, add a single row to
`redhawks_gameday_sports` — Football, mode `thread`, a category, `days_before` 3
— then set `redhawks_gameday_enabled` to true. Starting with one sport keeps a
misconfiguration from posting across several categories at once.

- [ ] **Step 8: Trigger a run and inspect**

```bash
sudo -E -u discourse bundle exec rails runner 'Jobs::PostRedhawksGameday.new.execute({})'
sudo -E -u discourse bundle exec rails runner 'puts PluginStore.get("discourse-redhawks-schedule", "gameday_ledger").inspect'
```

Expected: the ledger holds `gameday:game:<id>` → topic id for any football game inside the window. Open the topic and confirm the header, the TV badge and the links read correctly.

---

## Notes for the implementer

**The one thing most likely to be wrong in production** is the `type: objects`
site setting rendering. It is confirmed present in
`SiteSettings::TypeSupervisor.types` (`objects: 28`), but this plugin has never
used it. If the admin form fails to render after the rebuild, check the Discourse
version's expected `schema` shape before changing anything else — the planner
already accepts both String and Symbol keys, so the data side is tolerant.

**Do not widen the embed pattern** if a second sport turns up with a differently
shaped `Streaming Video` value. Add a second explicit pattern with its own test.
The fallback to a plain link is the safety net and should stay load-bearing.

**Clearing `gameday_ledger` reposts everything eligible.** The burst cap holds it
to 5 per run, but that is a throttle, not a guard. If a mistake needs undoing,
delete the topics *and* prune their keys from the ledger.
