# Athletics Schedule Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show upcoming Miami University Athletics events in the miamihawktalk.fans sidebar, sourced from the athletics department's RSS calendar.

**Architecture:** A Discourse plugin fetches and parses the RSS server-side every 30 minutes (eliminating CORS entirely) and serves the result at `/redhawks-schedule.json`. A separate theme component renders an "Upcoming Games" sidebar section from that endpoint. The split exists because plugins need a multi-minute `./launcher rebuild app` to update while theme components need only a git pull — so the stable backend is the plugin and everything iterated on is the component.

**Tech Stack:** Ruby, Nokogiri, RSpec, Discourse plugin API, Ember/Glimmer (`.gjs`), SCSS.

**Spec:** `docs/superpowers/specs/2026-07-18-athletics-schedule-design.md`

## Global Constraints

- Target Discourse version: **2026.7.0-latest**, self-hosted.
- Two new repositories, both siblings of this one:
  - `/Users/dustin/Development/MiamiHawkTalk/discourse-redhawks-schedule`
  - `/Users/dustin/Development/MiamiHawkTalk/miamihawktalk-schedule`
- Feed URL: `https://miamiredhawks.com/calendar.ashx/calendar.rss`
- JSON field names are **snake_case** (`start_utc`, `home_away`, `time_known`, `opponent_logo`), matching Discourse convention. The spec's prose uses camelCase illustratively; snake_case is authoritative.
- **59% of feed events have no announced time.** Date-only events must render as `Aug 30, TBA` and must **never** be timezone-converted — converting a presumed midnight displays `2026-08-29` as Aug 28 for every US viewer.
- Multi-day collapsing requires a **48-hour window** between consecutive events. Without it, separate same-opponent series months apart merge into one nonsensical row.
- The component renders **nothing at all** — no error text, no empty container — when data is missing, malformed, or contains zero upcoming events.
- The theme component must not redefine colors. It inherits `$tertiary`, `$primary`, `$primary-medium`, `$primary-low` from the parent theme.
- Never claim a visual change works without seeing it rendered on the live site in both color schemes (per this project's CLAUDE.md).

---

### Task 1: Verify Discourse 2026.7.0 API surface

This version postdates the assistant's knowledge cutoff. Every API name used in later tasks is an assumption until confirmed here. **Do not skip and do not guess** — a wrong outlet name produces a component that silently renders nothing, which is indistinguishable from the designed empty state and therefore very expensive to debug later.

**Files:**
- Create: `/Users/dustin/Development/MiamiHawkTalk/discourse-redhawks-schedule/NOTES-api-verification.md`

- [ ] **Step 1: Find the sidebar plugin outlets available on this version**

On the Discourse host:

```bash
cd /var/discourse && ./launcher enter app
grep -rn "PluginOutlet" /var/www/discourse/app/assets/javascripts/discourse/app/components/sidebar/ | grep -o '@name="[^"]*"' | sort -u
```

Expected: a list including something like `below-sidebar-sections`. Record the **exact** names returned.

- [ ] **Step 2: Confirm the api-initializer import path**

```bash
ls /var/www/discourse/app/assets/javascripts/discourse/app/lib/ | grep -E "^(api|plugin-api)\.js"
grep -n "export function apiInitializer" /var/www/discourse/app/assets/javascripts/discourse/app/lib/*.js
```

Expected: identifies whether the import is `discourse/lib/api` or `discourse/lib/plugin-api`, and whether `apiInitializer` takes a version-string first argument.

- [ ] **Step 3: Confirm the server-side HTTP helper**

```bash
grep -rn "class HTTP" /var/www/discourse/lib/final_destination/
grep -rn "def self.get" /var/www/discourse/lib/final_destination/http.rb
```

Expected: confirms `FinalDestination::HTTP` exists and that `.get(URI(...))` returns a body string.

- [ ] **Step 4: Confirm the controller filter names**

```bash
grep -n "before_action" /var/www/discourse/app/controllers/application_controller.rb | head -30
```

Expected: confirms `check_xhr`, `preload_json`, and `redirect_to_login_if_required` still exist under those names.

- [ ] **Step 5: Record findings**

Write `NOTES-api-verification.md` with a line per finding, in this exact shape:

```markdown
# API verification — Discourse 2026.7.0-latest
Verified: 2026-07-18

- Sidebar outlet name: `<exact name>`
- apiInitializer import: `<exact path>`; version arg required: yes/no
- FinalDestination::HTTP.get returns body string: yes/no
- ApplicationController filters present: check_xhr / preload_json / redirect_to_login_if_required
```

- [ ] **Step 6: Reconcile with this plan**

If any finding contradicts what later tasks assume, **stop and report to the user before writing code.** If no suitable rich sidebar outlet exists at all, that invalidates the approved row design and requires the user's decision on the text-only fallback — it is not an implementer's call.

---

### Task 2: Plugin skeleton that boots

**Files:**
- Create: `/Users/dustin/Development/MiamiHawkTalk/discourse-redhawks-schedule/plugin.rb`
- Create: `/Users/dustin/Development/MiamiHawkTalk/discourse-redhawks-schedule/config/settings.yml`
- Create: `/Users/dustin/Development/MiamiHawkTalk/discourse-redhawks-schedule/config/locales/server.en.yml`
- Create: `/Users/dustin/Development/MiamiHawkTalk/discourse-redhawks-schedule/.gitignore`

**Interfaces:**
- Produces: `RedhawksSchedule::PLUGIN_NAME` (String), `RedhawksSchedule::STORE_KEY` (String), site settings `redhawks_schedule_enabled` and `redhawks_schedule_feed_url`.

- [ ] **Step 1: Create the repo**

```bash
mkdir -p /Users/dustin/Development/MiamiHawkTalk/discourse-redhawks-schedule/{config/locales,lib/redhawks_schedule,app/jobs/scheduled,app/controllers,spec/lib,spec/fixtures}
cd /Users/dustin/Development/MiamiHawkTalk/discourse-redhawks-schedule && git init
```

- [ ] **Step 2: Write `plugin.rb`**

```ruby
# frozen_string_literal: true

# name: discourse-redhawks-schedule
# about: Fetches the Miami University Athletics RSS calendar and serves upcoming events as JSON.
# version: 0.1.0
# authors: MiamiHawkTalk
# url: https://github.com/dustin-riley/discourse-redhawks-schedule

enabled_site_setting :redhawks_schedule_enabled

module ::RedhawksSchedule
  PLUGIN_NAME = "discourse-redhawks-schedule"
  STORE_KEY = "events"
end

require_relative "lib/redhawks_schedule/parser"

after_initialize do
  require_relative "app/jobs/scheduled/fetch_redhawks_schedule"
  require_relative "app/controllers/redhawks_schedule_controller"

  Discourse::Application.routes.append do
    get "/redhawks-schedule" => "redhawks_schedule#index", :format => :json
  end
end
```

- [ ] **Step 3: Write `config/settings.yml`**

```yaml
plugins:
  redhawks_schedule_enabled:
    default: true
    client: true
  redhawks_schedule_feed_url:
    default: "https://miamiredhawks.com/calendar.ashx/calendar.rss"
```

- [ ] **Step 4: Write `config/locales/server.en.yml`**

```yaml
en:
  site_settings:
    redhawks_schedule_enabled: "Fetch the Miami Athletics calendar and serve it at /redhawks-schedule.json."
    redhawks_schedule_feed_url: "URL of the athletics RSS calendar feed."
```

- [ ] **Step 5: Write `.gitignore`**

```
*.gem
.DS_Store
```

- [ ] **Step 6: Commit**

The referenced job, controller, and parser files do not exist yet, so the plugin will not boot until Task 7. That is expected — this commit is the scaffold only.

```bash
cd /Users/dustin/Development/MiamiHawkTalk/discourse-redhawks-schedule
git add -A && git commit -m "feat: plugin scaffold and site settings"
```

---

### Task 3: Parser — field extraction and title parsing

The parser is a plain Ruby class with no Rails, HTTP, or persistence dependencies. That is deliberate: it holds all the interesting logic and can therefore be tested on your Mac without a Discourse checkout.

**Files:**
- Create: `/Users/dustin/Development/MiamiHawkTalk/discourse-redhawks-schedule/lib/redhawks_schedule/parser.rb`
- Create: `/Users/dustin/Development/MiamiHawkTalk/discourse-redhawks-schedule/spec/lib/parser_spec.rb`
- Create: `/Users/dustin/Development/MiamiHawkTalk/discourse-redhawks-schedule/spec/fixtures/calendar.rss`

**Interfaces:**
- Produces: `RedhawksSchedule::Parser.parse(xml, now:) -> Array<Hash>` where each hash has keys `:id, :sport, :opponent, :home_away, :start_utc (Time), :end_utc (Time), :time_known (bool), :location, :opponent_logo, :promo, :url, :days (Integer)`.

- [ ] **Step 1: Install test dependencies and add the fixture**

Already done on this machine — verified 2026-07-18. `nokogiri` 1.13.8 was
present; `rspec` 3.13.6 was installed user-scoped because macOS system Ruby's
gem directory is not writable:

```bash
gem install --user-install rspec          # already run
cp /Users/dustin/Downloads/calendar.rss /Users/dustin/Development/MiamiHawkTalk/discourse-redhawks-schedule/spec/fixtures/calendar.rss
```

**The `rspec` binary is not on `PATH`.** Every test command in this plan must
be run as:

```bash
~/.gem/ruby/2.6.0/bin/rspec spec/lib/parser_spec.rb
```

The target Ruby is **2.6.10** (system Ruby, no rbenv/rvm/asdf present). Avoid
`filter_map` (2.7+), `Hash#except` (3.0+), endless method definitions (3.0+),
and rightward assignment. The parser in Step 3 is already written to this
constraint.

The fixture is the 2026-07-18 snapshot: 141 items, 83 date-only and 58 timed, 5 sports (Hockey 40, Men's Golf 33, Women's Volleyball 32, Women's Soccer 23, Football 13). Basketball is absent because those schedules were not published yet — which is exactly why the sport-label map in Task 10 needs a fallback.

- [ ] **Step 2: Write the failing test**

`spec/lib/parser_spec.rb`:

```ruby
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
```

- [ ] **Step 2b: Run the test to verify it fails**

```bash
cd /Users/dustin/Development/MiamiHawkTalk/discourse-redhawks-schedule && ~/.gem/ruby/2.6.0/bin/rspec spec/lib/parser_spec.rb
```

Expected: FAIL — `cannot load such file -- .../lib/redhawks_schedule/parser`

- [ ] **Step 3: Write the parser**

`lib/redhawks_schedule/parser.rb`:

```ruby
# frozen_string_literal: true

require "nokogiri"
require "time"

module RedhawksSchedule
  # Parses the SIDEARM Sports RSS calendar into a list of upcoming events.
  #
  # Deliberately free of Rails, HTTP and persistence so it can be unit tested
  # without a Discourse environment.
  class Parser
    NAMESPACES = {
      "ev" => "http://purl.org/rss/1.0/modules/event/",
      "s" => "http://sidearmsports.com/schemas/cal_rss/1.0/",
    }.freeze

    # "8/16 7:00 PM Miami University ..." and also "8/29 Miami University ..."
    # since 59% of items carry no time at all.
    TITLE_PREFIX = %r{\A\s*\d{1,2}/\d{1,2}(?:\s+\d{1,2}:\d{2}\s*[AP]M)?\s+}i
    TEAM_PREFIX = /\AMiami University\s+/i
    SEPARATOR = /\s+(vs|at)\s+/i

    # A date-only event has no time of day, and the feed publishes Eastern
    # calendar dates. Midnight UTC on such a date is 8pm Eastern the PREVIOUS
    # day, so a plain 24-hour window drops the game at 8pm Eastern on the day
    # it is actually played. 30 hours covers the full Eastern day in both EDT
    # and EST, lingering at most ~2 hours past midnight Eastern — much better
    # than hiding a game that has not been played yet.
    DATE_ONLY_GRACE = 30 * 60 * 60
    COLLAPSE_WINDOW = 48 * 60 * 60

    def self.parse(xml, now: Time.now.utc)
      new(xml, now: now).parse
    end

    def initialize(xml, now: Time.now.utc)
      @xml = xml.to_s
      @now = now.utc
    end

    def parse
      # `.map.compact` rather than `filter_map`: the dev Mac runs system Ruby
      # 2.6, where filter_map does not exist. Discourse's container runs 3.x,
      # so this would otherwise fail only locally.
      events = document.xpath("//channel/item").map { |item| build_event(item) }.compact
      collapse(upcoming(events).sort_by { |e| [e[:start_utc], e[:sport]] })
    end

    private

    def document
      @document ||= Nokogiri::XML(@xml)
    end

    def build_event(item)
      start_raw = text(item, "ev:startdate")
      start_utc = parse_time(start_raw)
      return nil if start_utc.nil?

      sport, home_away, title_opponent = split_title(text(item, "title"))
      return nil if sport.empty?

      {
        id: presence(text(item, "s:gameid")),
        sport: sport,
        opponent: presence(text(item, "s:opponent")) || title_opponent,
        home_away: home_away,
        start_utc: start_utc,
        end_utc: parse_time(text(item, "ev:enddate")) || start_utc,
        time_known: start_raw.include?("T"),
        location: presence(text(item, "ev:location")),
        opponent_logo: presence(text(item, "s:opponentlogo")),
        promo: presence(text(item, "s:gamepromoname")),
        url: presence(text(item, "link")),
      }
    end

    def split_title(title)
      rest = title.to_s.strip.sub(TITLE_PREFIX, "").sub(TEAM_PREFIX, "")
      match = SEPARATOR.match(rest)
      return [rest.strip, "home", ""] if match.nil?

      [match.pre_match.strip, match[1].casecmp?("at") ? "away" : "home", match.post_match.strip]
    end

    def upcoming(events)
      events.reject do |event|
        cutoff = event[:time_known] ? event[:start_utc] : event[:start_utc] + DATE_ONLY_GRACE
        cutoff < @now
      end
    end

    # Merges each event into the most recent still-open group for the same
    # matchup. Comparing only against the previous row is wrong: another
    # sport's event routinely sorts between two days of the same tournament,
    # which silently breaks the run. Against the real feed that mistake leaves
    # 13 tournaments and series uncollapsed.
    def collapse(events)
      rows = []
      index = {}

      events.each do |event|
        key = [event[:sport], event[:opponent]]
        at = index[key]

        if at && (event[:start_utc] - rows[at][:end_utc]) <= COLLAPSE_WINDOW
          rows[at][:end_utc] = [rows[at][:end_utc], event[:end_utc]].max
          rows[at][:days] += 1
        else
          rows << event.merge(days: 1)
          index[key] = rows.length - 1
        end
      end

      rows
    end

    def parse_time(raw)
      value = raw.to_s.strip
      return nil if value.empty?
      return nil if value.match?(/\A(TBA|TBD)\z/i)

      value = value.sub(/\.\d+/, "")
      value = "#{value}T00:00:00" unless value.include?("T")
      value = "#{value}Z" unless value.end_with?("Z")
      Time.iso8601(value).utc
    rescue ArgumentError
      nil
    end

    def text(node, path)
      found = node.at_xpath(path, NAMESPACES)
      found ? found.text.strip : ""
    end

    def presence(value)
      value.nil? || value.empty? ? nil : value
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Users/dustin/Development/MiamiHawkTalk/discourse-redhawks-schedule && ~/.gem/ruby/2.6.0/bin/rspec spec/lib/parser_spec.rb
```

Expected: PASS, all examples green.

- [ ] **Step 5: Commit**

```bash
git add lib spec && git commit -m "feat: parse SIDEARM calendar items into events"
```

---

### Task 4: Parser — past filtering, sorting and multi-day collapsing

**Files:**
- Modify: `/Users/dustin/Development/MiamiHawkTalk/discourse-redhawks-schedule/spec/lib/parser_spec.rb`

The implementation for this behaviour already landed in Task 3 (`upcoming` and `collapse`). This task locks it down with tests that would otherwise be missing — particularly the 48-hour window, which is the single most breakable rule in the parser.

- [ ] **Step 1: Write the failing tests**

Append to `spec/lib/parser_spec.rb`, inside the top-level `describe`:

```ruby
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
```

- [ ] **Step 2: Run the tests**

```bash
cd /Users/dustin/Development/MiamiHawkTalk/discourse-redhawks-schedule && ~/.gem/ruby/2.6.0/bin/rspec spec/lib/parser_spec.rb
```

Expected: PASS. These numbers (101 rows, 36 collapsed groups, 141 total days) were computed by simulating this exact algorithm against the real snapshot, so a failure means the collapsing logic drifted, not that the expectations are wrong.

- [ ] **Step 3: Commit**

```bash
git add spec && git commit -m "test: cover filtering, ordering and 48-hour multi-day collapsing"
```

---

### Task 5: Parser — malformed input tolerance

The feed is a third-party dependency that can change without notice. A parse failure must degrade to fewer events, never to an exception that kills the scheduled job.

**Files:**
- Modify: `/Users/dustin/Development/MiamiHawkTalk/discourse-redhawks-schedule/spec/lib/parser_spec.rb`
- Modify: `/Users/dustin/Development/MiamiHawkTalk/discourse-redhawks-schedule/lib/redhawks_schedule/parser.rb` (only if a test fails)

- [ ] **Step 1: Write the failing tests**

Append inside the top-level `describe`:

```ruby
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
```

- [ ] **Step 2: Run the tests**

```bash
cd /Users/dustin/Development/MiamiHawkTalk/discourse-redhawks-schedule && ~/.gem/ruby/2.6.0/bin/rspec spec/lib/parser_spec.rb
```

Expected: PASS without implementation changes — `filter_map`, the `parse_time` rescue, and Nokogiri's lenient XML mode already cover these. If any example fails, fix `parser.rb` minimally and rerun; do not weaken the test.

- [ ] **Step 3: Commit**

```bash
git add spec lib && git commit -m "test: parser degrades gracefully on malformed feed input"
```

---

### Task 6: Scheduled fetch job

**Files:**
- Create: `/Users/dustin/Development/MiamiHawkTalk/discourse-redhawks-schedule/app/jobs/scheduled/fetch_redhawks_schedule.rb`

**Interfaces:**
- Consumes: `RedhawksSchedule::Parser.parse`, `RedhawksSchedule::PLUGIN_NAME`, `RedhawksSchedule::STORE_KEY`.
- Produces: a `PluginStore` entry shaped `{ "generated_at" => ISO8601 String, "events" => [ { "start_utc" => ISO8601 String, ... } ] }`.

- [ ] **Step 1: Write the job**

```ruby
# frozen_string_literal: true

module ::Jobs
  class FetchRedhawksSchedule < ::Jobs::Scheduled
    every 30.minutes

    def execute(_args)
      return unless SiteSetting.redhawks_schedule_enabled

      url = SiteSetting.redhawks_schedule_feed_url
      return if url.blank?

      body = fetch(url)
      # Guard against error pages and truncated responses. Writing a parsed
      # HTML error page over good data would blank the sidebar; leaving the
      # previous value in place makes an upstream outage invisible to users.
      return if body.blank? || !body.include?("<rss")

      events = ::RedhawksSchedule::Parser.parse(body)

      PluginStore.set(
        ::RedhawksSchedule::PLUGIN_NAME,
        ::RedhawksSchedule::STORE_KEY,
        { "generated_at" => Time.now.utc.iso8601, "events" => events.map { |e| serialize(e) } },
      )
    rescue StandardError => e
      Rails.logger.warn("[redhawks-schedule] update failed: #{e.class}: #{e.message}")
    end

    private

    def fetch(url)
      FinalDestination::HTTP.get(URI(url))
    rescue StandardError => e
      Rails.logger.warn("[redhawks-schedule] fetch failed: #{e.class}: #{e.message}")
      nil
    end

    def serialize(event)
      event.merge(
        start_utc: event[:start_utc].iso8601,
        end_utc: event[:end_utc].iso8601,
      )
    end
  end
end
```

Substitute the HTTP call verified in Task 1 Step 3 if it differs.

- [ ] **Step 2: Commit**

```bash
git add app && git commit -m "feat: fetch and store the calendar every 30 minutes"
```

Verification happens in Task 8, once the plugin can boot.

---

### Task 7: JSON endpoint

**Files:**
- Create: `/Users/dustin/Development/MiamiHawkTalk/discourse-redhawks-schedule/app/controllers/redhawks_schedule_controller.rb`

**Interfaces:**
- Produces: `GET /redhawks-schedule.json` returning `{ generated_at, events: [...] }`, readable by anonymous visitors.

- [ ] **Step 1: Write the controller**

```ruby
# frozen_string_literal: true

class RedhawksScheduleController < ::ApplicationController
  requires_login false
  skip_before_action :check_xhr, :preload_json, :redirect_to_login_if_required, raise: false

  def index
    # A database hiccup must degrade to an absent sidebar, not a 500. This is
    # the only remaining path that could render a broken section rather than
    # no section at all.
    payload =
      begin
        PluginStore.get(::RedhawksSchedule::PLUGIN_NAME, ::RedhawksSchedule::STORE_KEY)
      rescue StandardError => e
        Rails.logger.warn("[redhawks-schedule] store read failed: #{e.class}: #{e.message}")
        nil
      end
    payload ||= { "generated_at" => nil, "events" => [] }

    response.headers["Cache-Control"] = "public, max-age=900"
    render json: payload
  end
end
```

Adjust the `skip_before_action` list to match the filters confirmed in Task 1 Step 4. `raise: false` keeps this working if one of them is absent.

- [ ] **Step 2: Commit**

```bash
git add app && git commit -m "feat: serve stored schedule at /redhawks-schedule.json"
```

---

### Task 8: Install the plugin and verify the backend end to end

This is the first point at which the plugin actually runs. It requires a rebuild, so everything backend-side is verified here in one pass.

**Files:** none — this task is deployment and verification.

- [ ] **Step 1: Push the plugin repo**

```bash
cd /Users/dustin/Development/MiamiHawkTalk/discourse-redhawks-schedule
gh repo create dustin-riley/discourse-redhawks-schedule --private --source=. --push
```

- [ ] **Step 2: Add it to the container config**

On the Discourse host, edit `/var/discourse/containers/app.yml` and add the clone line under the existing `hooks.after_code.exec.cmd` git-clone block:

```yaml
          - git clone --depth 1 https://github.com/dustin-riley/discourse-redhawks-schedule.git
```

- [ ] **Step 3: Rebuild**

```bash
cd /var/discourse && ./launcher rebuild app
```

Expected: build completes and the site comes back up. **If the site fails to boot, `./launcher rebuild app` after removing the clone line restores service** — do that first, then debug.

- [ ] **Step 4: Confirm the plugin loaded**

Visit `/admin/plugins`. Expected: `discourse-redhawks-schedule` listed and enabled, with both settings visible.

- [ ] **Step 5: Run the job by hand rather than waiting 30 minutes**

```bash
cd /var/discourse && ./launcher enter app
# MUST run as the discourse user — Postgres uses peer authentication and
# rejects root with "Peer authentication failed for user discourse".
cd /var/www/discourse && sudo -E -u discourse bundle exec rails runner \
  'Jobs::FetchRedhawksSchedule.new.execute({}); \
   d = PluginStore.get("discourse-redhawks-schedule", "events"); \
   puts "generated_at=#{d["generated_at"]}"; \
   puts "events=#{d["events"].length}"; \
   puts d["events"].first(3).map { |e| [e["sport"], e["home_away"], e["opponent"], e["start_utc"], e["time_known"]].inspect }'
```

Expected: `events=` a number in the low hundreds, and three plausible rows. Events already in the past are excluded, so the count will be at or below 101 and will shrink as the season progresses.

- [ ] **Step 6: Verify the endpoint, including anonymously**

```bash
curl -s https://miamihawktalk.fans/redhawks-schedule.json | head -c 400
curl -s -H "Cookie:" https://miamihawktalk.fans/redhawks-schedule.json | python3 -m json.tool | head -20
```

Expected: JSON with `generated_at` and an `events` array in both cases. The second must work — anonymous visitors need the sidebar too.

- [ ] **Step 7: Verify the stale-on-error path**

Point the feed setting at a URL that 404s (Admin → Settings → search "redhawks"), rerun the job from Step 5, and re-check the endpoint.

Expected: the endpoint still returns the previous good data. Then restore the correct feed URL.

- [ ] **Step 8: Record the result**

Append the observed event count and a sample row to `NOTES-api-verification.md`, then commit.

```bash
cd /Users/dustin/Development/MiamiHawkTalk/discourse-redhawks-schedule
git add NOTES-api-verification.md && git commit -m "docs: record backend verification results"
```

---

### Task 9: Theme component scaffold

**Files:**
- Create: `/Users/dustin/Development/MiamiHawkTalk/miamihawktalk-schedule/about.json`
- Create: `/Users/dustin/Development/MiamiHawkTalk/miamihawktalk-schedule/settings.yml`
- Create: `/Users/dustin/Development/MiamiHawkTalk/miamihawktalk-schedule/locales/en.yml`
- Create: `/Users/dustin/Development/MiamiHawkTalk/miamihawktalk-schedule/.gitignore`

**Interfaces:**
- Produces: theme settings `games_shown` (int) and `enabled_on_mobile` (bool); locale keys under `js.redhawks_schedule`.

- [ ] **Step 1: Create the repo**

```bash
mkdir -p /Users/dustin/Development/MiamiHawkTalk/miamihawktalk-schedule/{javascripts/discourse/{api-initializers,components,lib},common,locales}
cd /Users/dustin/Development/MiamiHawkTalk/miamihawktalk-schedule && git init
```

- [ ] **Step 2: Write `about.json`**

```json
{
  "name": "MiamiHawkTalk Schedule",
  "about_url": "https://miamihawktalk.fans",
  "license_url": "https://github.com/dustin-riley/miamihawktalk-schedule/blob/main/LICENSE",
  "authors": "MiamiHawkTalk",
  "component": true
}
```

- [ ] **Step 3: Write `settings.yml`**

```yaml
games_shown:
  type: integer
  default: 5
  min: 1
  max: 10

enabled_on_mobile:
  type: bool
  default: true
```

- [ ] **Step 4: Write `locales/en.yml`**

```yaml
en:
  theme_metadata:
    description: "Shows upcoming Miami University Athletics events in the sidebar."
  title: "Upcoming Games"
  full_schedule: "See full schedule"
  tba: "TBA"
  home_prefix: "vs"
  away_prefix: "at"
```

**Theme components namespace translations differently from plugins.** Keys go
directly under `en:` with no `js:` level, and Discourse stores them as
`theme_translation.<theme_id>.<key>`. They resolve only through the
`themePrefix` helper — a bare `i18n("title")` renders the literal
`[en.title]` placeholder. Verified against Discourse's own Horizon theme and
`docs/developer-guides/docs/05-themes-components/14-localizable-strings.md`.

- [ ] **Step 5: Write `.gitignore`**

```
.DS_Store
```

- [ ] **Step 6: Verify and commit**

```bash
cd /Users/dustin/Development/MiamiHawkTalk/miamihawktalk-schedule
python3 -m json.tool about.json > /dev/null && echo "about.json OK"
ruby -ryaml -e "YAML.load_file('locales/en.yml'); puts 'locales OK'"
git add -A && git commit -m "feat: theme component scaffold"
```

---

### Task 10: Data access and formatting libraries

Kept separate from the component so the fiddly bits — caching, date formatting, the TBA branch — are small focused modules rather than buried in a template.

**Files:**
- Create: `/Users/dustin/Development/MiamiHawkTalk/miamihawktalk-schedule/javascripts/discourse/lib/schedule-data.js`
- Create: `/Users/dustin/Development/MiamiHawkTalk/miamihawktalk-schedule/javascripts/discourse/lib/format-event.js`

**Interfaces:**
- Produces: `fetchSchedule() -> Promise<Array>`, `sportLabel(sport) -> String`, `formatWhen(event) -> String`, `prefixFor(event) -> String`.

- [ ] **Step 1: Write `schedule-data.js`**

```js
const CACHE_KEY = "mht-schedule-v1";
const TTL_MS = 30 * 60 * 1000;
const ENDPOINT = "/redhawks-schedule.json";

// localStorage throws in Safari private browsing and when quota is exhausted.
// A cache miss is always survivable, so every access is defensive.
function readCache() {
  try {
    const raw = window.localStorage.getItem(CACHE_KEY);
    if (!raw) {
      return null;
    }
    const { at, events } = JSON.parse(raw);
    if (!at || Date.now() - at > TTL_MS || !Array.isArray(events)) {
      return null;
    }
    return events;
  } catch {
    return null;
  }
}

function writeCache(events) {
  try {
    window.localStorage.setItem(CACHE_KEY, JSON.stringify({ at: Date.now(), events }));
  } catch {
    // Not being able to cache is not worth surfacing.
  }
}

// MUST match DATE_ONLY_GRACE in the server-side parser. A date-only event's
// start is midnight UTC on an Eastern calendar date, which is only 4-5 hours
// before Eastern midnight of that same date — so a flat 24 hours here hides
// an untimed game at 8pm Eastern on the day it is played, six hours before
// the server stops serving it.
const DATE_ONLY_GRACE_MS = 30 * 60 * 60 * 1000;

// The stored feed can outlive individual events, so filter again on read.
export function upcomingOnly(events, now = Date.now()) {
  return events.filter((event) => {
    // The payload is third-party data reaching us through a cache; a null or
    // non-object element must yield a shorter list, never a thrown exception
    // that collapses the whole sidebar.
    if (!event || typeof event !== "object") {
      return false;
    }
    const start = Date.parse(event.start_utc);
    if (isNaN(start)) {
      return false;
    }
    const end = Date.parse(event.end_utc) || start;
    const cutoff = event.time_known ? start : end + DATE_ONLY_GRACE_MS;
    return cutoff >= now;
  });
}

export async function fetchSchedule() {
  const cached = readCache();
  if (cached) {
    return upcomingOnly(cached);
  }

  const response = await fetch(ENDPOINT, { headers: { Accept: "application/json" } });
  if (!response.ok) {
    throw new Error(`schedule request failed: ${response.status}`);
  }

  const payload = await response.json();
  const events = Array.isArray(payload?.events) ? payload.events : [];
  writeCache(events);
  return upcomingOnly(events);
}
```

- [ ] **Step 2: Write `format-event.js`**

```js
import { i18n } from "discourse-i18n";
import { themePrefix } from "virtual:theme";

// Sidebar rows are roughly 200px wide, so long sport names must be shortened
// or they wrap. This map is not exhaustive on purpose: the July feed contains
// no basketball at all because those schedules are published later, so unknown
// sports must degrade to a readable uppercase label rather than break.
const SPORT_LABELS = {
  Football: "FOOTBALL",
  Hockey: "HOCKEY",
  "Men's Basketball": "M BASKETBALL",
  "Women's Basketball": "W BASKETBALL",
  "Men's Soccer": "M SOCCER",
  "Women's Soccer": "W SOCCER",
  "Men's Golf": "M GOLF",
  "Women's Golf": "W GOLF",
  "Women's Volleyball": "VOLLEYBALL",
  Baseball: "BASEBALL",
  Softball: "SOFTBALL",
};

export function sportLabel(sport) {
  return SPORT_LABELS[sport] ?? (sport ?? "").toUpperCase();
}

export function prefixFor(event) {
  return event.home_away === "away"
    ? i18n(themePrefix("away_prefix"))
    : i18n(themePrefix("home_prefix"));
}

// Formats the calendar date carried in an ISO string WITHOUT converting it.
// Used for events with no announced time: converting a presumed midnight
// would render 2026-08-29 as "Aug 28" for every viewer in the US.
function calendarDate(iso) {
  const [year, month, day] = iso.slice(0, 10).split("-").map(Number);
  return new Date(Date.UTC(year, month - 1, day)).toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
    timeZone: "UTC",
  });
}

function localDate(date) {
  return date.toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

function localTime(date) {
  return date
    .toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })
    .replace(/\s?([AP])M/i, (_, meridiem) => meridiem.toLowerCase());
}

export function formatWhen(event) {
  const multiDay = (event.days ?? 1) > 1;

  if (!event.time_known) {
    const start = calendarDate(event.start_utc);
    if (multiDay) {
      return `${start}–${calendarDate(event.end_utc)}`;
    }
    return `${start}, ${i18n(themePrefix("tba"))}`;
  }

  const start = new Date(event.start_utc);
  if (multiDay) {
    return `${localDate(start)}–${localDate(new Date(event.end_utc))}`;
  }
  return `${localDate(start)}, ${localTime(start)}`;
}
```

- [ ] **Step 3: Commit**

```bash
cd /Users/dustin/Development/MiamiHawkTalk/miamihawktalk-schedule
git add javascripts && git commit -m "feat: schedule fetching, caching and row formatting"
```

---

### Task 11: Sidebar component and styling

**Files:**
- Create: `/Users/dustin/Development/MiamiHawkTalk/miamihawktalk-schedule/javascripts/discourse/components/upcoming-games.gjs`
- Create: `/Users/dustin/Development/MiamiHawkTalk/miamihawktalk-schedule/javascripts/discourse/api-initializers/schedule.js`
- Create: `/Users/dustin/Development/MiamiHawkTalk/miamihawktalk-schedule/common/common.scss`

**Interfaces:**
- Consumes: `fetchSchedule`, `upcomingOnly` from `../lib/schedule-data`; `sportLabel`, `prefixFor`, `formatWhen` from `../lib/format-event`; the outlet name recorded in Task 1.

- [ ] **Step 1: Write the component**

`javascripts/discourse/components/upcoming-games.gjs`:

```gjs
import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { i18n } from "discourse-i18n";
import { themePrefix } from "virtual:theme";
import { fetchSchedule } from "../lib/schedule-data";
import { formatWhen, prefixFor, sportLabel } from "../lib/format-event";

export default class UpcomingGames extends Component {
  @tracked events = [];

  constructor() {
    super(...arguments);
    this.load();
  }

  async load() {
    try {
      const events = await fetchSchedule();
      this.events = events.slice(0, settings.games_shown);
    } catch {
      // Silence is the designed failure mode: an error box parked in the
      // sidebar for the length of an outage is worse than showing nothing.
      this.events = [];
    }
  }

  get hasEvents() {
    return this.events.length > 0;
  }

  row = (event) => ({
    ...event,
    prefix: prefixFor(event),
    sportLabel: sportLabel(event.sport),
    when: formatWhen(event),
  });

  hideLogo(domEvent) {
    domEvent.target.style.display = "none";
  }

  <template>
    {{#if this.hasEvents}}
      <div class="mht-schedule">
        <h3 class="mht-schedule__title">{{i18n (themePrefix "title")}}</h3>

        <ul class="mht-schedule__list">
          {{#each this.events as |event|}}
            {{#let (this.row event) as |row|}}
              <li class="mht-schedule__item">
                <a
                  class="mht-schedule__link"
                  href={{row.url}}
                  target="_blank"
                  rel="noopener noreferrer"
                >
                  {{#if row.opponent_logo}}
                    <img
                      class="mht-schedule__logo"
                      src={{row.opponent_logo}}
                      alt=""
                      loading="lazy"
                      {{on "error" this.hideLogo}}
                    />
                  {{/if}}

                  <span class="mht-schedule__detail">
                    <span class="mht-schedule__matchup">
                      <span class="mht-schedule__prefix">{{row.prefix}}</span>
                      {{row.opponent}}
                    </span>
                    <span class="mht-schedule__meta">
                      {{row.sportLabel}}
                      &middot;
                      {{row.when}}
                    </span>
                  </span>
                </a>
              </li>
            {{/let}}
          {{/each}}
        </ul>

        <a
          class="mht-schedule__all"
          href="https://miamiredhawks.com/calendar.aspx"
          target="_blank"
          rel="noopener noreferrer"
        >
          {{i18n (themePrefix "full_schedule")}}
        </a>
      </div>
    {{/if}}
  </template>
}
```

Add `import { on } from "@ember/modifier";` at the top if this Ember version does not auto-import the `on` modifier — Task 1's findings and the browser console will tell you.

- [ ] **Step 2: Write the api-initializer**

`javascripts/discourse/api-initializers/schedule.js`:

```js
import { apiInitializer } from "discourse/lib/api";
import UpcomingGames from "../components/upcoming-games";

export default apiInitializer((api) => {
  if (!settings.enabled_on_mobile && api.container.lookup("service:site").mobileView) {
    return;
  }

  // Verified against Discourse source 2026-07-19: this outlet lives in
  // frontend/discourse/app/components/sidebar.gjs, inside <nav id="d-sidebar">,
  // below the nav sections and above the switch-panel buttons and footer.
  // `below-sidebar-sections` (this plan's original guess) does not exist.
  api.renderInOutlet("after-sidebar-sections", UpcomingGames);
});
```

- [ ] **Step 3: Write the styles**

`common/common.scss`. Colors come from the parent theme; do not hardcode hex values.

```scss
.mht-schedule {
  padding: 0.5em 1em 1em;

  &__title {
    font-size: $font-down-1;
    font-weight: 700;
    letter-spacing: 0.05em;
    text-transform: uppercase;
    color: var(--primary-medium);
    margin-bottom: 0.5em;
  }

  &__list {
    list-style: none;
    margin: 0;
    padding: 0;
  }

  &__item + &__item {
    margin-top: 0.6em;
  }

  &__link {
    display: flex;
    align-items: center;
    gap: 0.5em;
    color: var(--primary);

    &:hover {
      background: var(--primary-low);
      color: var(--primary);
    }
  }

  &__logo {
    width: 24px;
    height: 24px;
    object-fit: contain;
    flex: 0 0 auto;
  }

  &__detail {
    display: flex;
    flex-direction: column;
    min-width: 0;
  }

  &__matchup {
    font-size: $font-down-1;
    font-weight: 600;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  &__prefix {
    color: var(--tertiary);
    font-weight: 700;
  }

  &__meta {
    font-size: $font-down-2;
    color: var(--primary-medium);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  &__all {
    display: inline-block;
    margin-top: 0.75em;
    font-size: $font-down-2;
    color: var(--tertiary);
  }
}
```

- [ ] **Step 4: Commit and push**

```bash
cd /Users/dustin/Development/MiamiHawkTalk/miamihawktalk-schedule
git add -A && git commit -m "feat: upcoming games sidebar section"
gh repo create dustin-riley/miamihawktalk-schedule --private --source=. --push
```

---

### Task 12: Live verification

No offline tool can confirm a Discourse selector or outlet actually matches the live DOM, so this task is mandatory before calling the work done.

**Files:** none.

- [ ] **Step 1: Install the component**

Discourse Admin → Customize → Themes → Components → Install → From a git repository → the `miamihawktalk-schedule` URL. Then add it as a component of the MiamiHawkTalk theme.

- [ ] **Step 2: Confirm it renders at all**

Load the site and hard-refresh (Cmd+Shift+R). Expected: an "Upcoming Games" section in the sidebar with `settings.games_shown` rows.

If nothing renders, check the browser console first, then confirm the outlet name against Task 1's notes — a wrong outlet name fails silently and looks identical to the designed empty state.

- [ ] **Step 3: Check a TBA row and a timed row together**

Expected: at least one row reading like `HOCKEY · Oct 10, TBA` and one like `W SOCCER · Aug 16, 7:00p`.

**Verify the TBA date against `https://miamiredhawks.com/calendar.aspx` directly.** An off-by-one date here is the specific bug the no-conversion rule exists to prevent, and it is invisible unless compared to the source.

- [ ] **Step 4: Check both color schemes**

Switch between MiamiHawkTalk Light and MiamiHawkTalk Dark. Expected: the `vs`/`at` prefix and the footer link pick up the scheme's red; text stays legible; hover uses the theme's `--primary-low`.

- [ ] **Step 5: Check mobile**

Load on a phone or a narrow viewport. Expected: rows do not wrap or overflow; long opponent names ellipsize. Then set `enabled_on_mobile` to false and confirm the section disappears on mobile only. Restore it.

- [ ] **Step 6: Check logged out**

Open a private window. Expected: the section renders for anonymous visitors.

- [ ] **Step 7: Check the empty state**

Admin → Settings → set `redhawks_schedule_feed_url` to a URL returning no items, run the job (Task 8 Step 5), clear `localStorage` (`localStorage.removeItem("mht-schedule-v1")`), and reload.

Expected: **no section, no error text, no empty box.** Then restore the real feed URL and rerun the job.

- [ ] **Step 8: Check the broken-logo fallback**

In devtools, break one row's `img` src. Expected: the image disappears and the text reflows without a broken-image icon or layout shift.

- [ ] **Step 9: Record completion**

Report to the user which checks passed, with what was actually observed. Per this project's CLAUDE.md, do not claim the feature works on the basis of tests alone — only the running site confirms rendering.

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| Sidebar placement | 11, 12 |
| All sports, chronological | 3, 4 |
| Plugin fetch + Sidekiq every 30 min | 6, 8 |
| Nokogiri namespace parsing | 3 |
| PluginStore, stale-on-error | 6, 8 (Step 7) |
| `/redhawks-schedule.json`, anonymous | 7, 8 (Step 6), 12 (Step 6) |
| Site settings | 2 |
| Sport / opponent / home-away parsing | 3 |
| `time_known` and TBA rendering | 3, 10, 12 (Step 3) |
| Fractional seconds | 3 |
| 48-hour multi-day collapsing | 3, 4 |
| Local timezone for timed events only | 10 |
| Logo with error fallback | 11, 12 (Step 8) |
| Shortened sport labels with fallback | 10 |
| `games_shown`, `enabled_on_mobile` | 9, 11 |
| Silent empty/error state | 11, 12 (Step 7) |
| Inherits theme colors | 11 |
| Parser unit tests | 3, 4, 5 |
| Live verification, both schemes | 12 |

**Type consistency:** the parser emits symbol keys with `Time` values; the job serializes `start_utc`/`end_utc` to ISO strings; `PluginStore` round-trips them as string keys; the JS reads `event.start_utc`, `event.end_utc`, `event.time_known`, `event.home_away`, `event.opponent_logo`, `event.days`, `event.url`, `event.opponent`, `event.sport`. These match across Tasks 3, 6, 10 and 11.

**Known open item:** the sidebar outlet name and the `apiInitializer` import path are unverified against Discourse 2026.7.0 and are resolved in Task 1. Task 1 Step 6 requires stopping and consulting the user if no suitable rich outlet exists, since the fallback changes an approved design.
