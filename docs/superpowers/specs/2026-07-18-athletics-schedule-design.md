# Upcoming Games — Design

**Date:** 2026-07-18
**Status:** Approved, ready for planning

## Goal

Show Miami University Athletics' upcoming events in the miamihawktalk.fans
sidebar, sourced from the athletics department's public RSS calendar.

## Source data

`https://miamiredhawks.com/calendar.ashx/calendar.rss` — a SIDEARM Sports feed.
A snapshot taken 2026-07-18 (`~144KB`) held 141 `<item>` elements covering the
full athletic year across every sport.

Each item is well structured:

```xml
<item>
  <title>8/16 7:00 PM Miami University Women's Soccer at Xavier</title>
  <link>https://miamiredhawks.com/calendar.aspx?game_id=20926&amp;sport_id=16</link>
  <ev:location>Cincinnati, Ohio</ev:location>
  <ev:startdate>2026-08-16T23:00:00.0000000Z</ev:startdate>
  <s:localstartdate>2026-08-16T19:00:00.0000000</s:localstartdate>
  <s:opponentlogo>https://miamiredhawks.com/images/logos/Xavier_.png</s:opponentlogo>
  <s:opponent>Xavier</s:opponent>
  <s:gameid>20926</s:gameid>
</item>
```

Observed characteristics of the snapshot, which the parser must not assume hold
forever:

- **59% of events have no announced time.** The feed expresses this by omitting
  the time from the timestamp rather than by writing `TBA`:

  ```
  timed:     <ev:startdate>2026-08-16T23:00:00.0000000Z</ev:startdate>
  time unset: <ev:startdate>2026-08-29</ev:startdate>
  ```

  83 of 141 items are date-only: Hockey 40, Men's Golf 33, Football 6, Women's
  Soccer 3, Women's Volleyball 1. The signal is unambiguous — a date-only
  timestamp always coincides with no time in the `<title>`, and a timed
  timestamp always coincides with one. These are real events whose times are set
  closer to the season.
- Fractional seconds are not always zero: `2026-08-28T00:00:00.0000001Z` occurs.
  Parse by stripping the fraction, not by matching `.0000000`.
- 66 of 141 titles use ` at ` (away); the rest use ` vs `.
- Multi-day events appear as repeated items sharing a title: `Men's Golf vs MAC
  Championship- Talis Park` appears 3 times, `Hockey vs NCHC First Round
  (Best-of-3)` 3 times.
- `s:opponent` is cleaner than the title remainder — for the volleyball
  exhibition the title yields `Xavier- Exhibition` while `s:opponent` is
  `Xavier`, with `Exhibition` carried separately in `s:gamepromoname`.

## Decisions

| Question | Decision |
|---|---|
| Placement | Sidebar block |
| Sports included | All of them, chronological |
| Data delivery | Discourse plugin, server-side fetch |
| Packaging | Plugin for data, theme component for UI |
| Row design | Opponent logo + vs/at + opponent, sport and date beneath |
| Multi-day events | Collapsed into one row with a date range |
| Timezone | Visitor's local timezone, for timed events only |
| Events with no announced time | Render the date plus `TBA`; never timezone-convert |

### Why a plugin rather than a browser fetch

A theme component runs in the visitor's browser, and `miamiredhawks.com` does
not send CORS headers, so a direct `fetch()` is blocked. A Cloudflare Worker
proxy was considered and rejected once self-hosting was confirmed: a plugin
fetches server-side, which removes the CORS problem, the third-party service,
and the account to maintain.

### Why the plugin/component split

Plugins require `./launcher rebuild app` to update and can fail a site's boot;
theme components update with a git pull and a browser refresh and cannot. So the
backend — small, stable, essentially never changing after it works — is the
plugin, and everything that will be iterated on (layout, CSS, copy, settings)
stays in a theme component.

## Architecture

```
miamiredhawks.com/calendar.ashx/calendar.rss
        |  Sidekiq, every 30 minutes, server-side
[1] discourse-redhawks-schedule  (plugin)
        |  PluginStore -> GET /redhawks-schedule.json  (same origin)
[2] miamihawktalk-schedule  (theme component)
        |
[3] "Upcoming Games" sidebar section
```

## Component 1 — `discourse-redhawks-schedule` (plugin)

```
plugin.rb
config/settings.yml
app/jobs/scheduled/fetch_redhawks_schedule.rb
app/controllers/redhawks_schedule_controller.rb
lib/redhawks_schedule/parser.rb
spec/lib/parser_spec.rb
spec/fixtures/calendar.rss
```

### Parser (`lib/redhawks_schedule/parser.rb`)

A plain Ruby class: XML string in, array of event hashes out. No Rails, no HTTP,
no persistence — this is the unit that carries all the interesting logic and all
the tests.

Uses Nokogiri (already bundled with Discourse) with namespace-aware selectors
rather than string matching.

Per item:

- **sport** — strip the leading `M/D H:MM AM/PM ` and the `Miami University `
  prefix from the title, then take everything before ` vs ` or ` at `.
- **opponent** — `s:opponent`, falling back to the title remainder after the
  ` vs ` / ` at ` separator.
- **homeAway** — `at` in the title means away, `vs` means home. Neutral-site
  games are published as `vs` and are not distinguishable from true home games;
  they are treated as home.
- **startUtc / endUtc** — `ev:startdate` / `ev:enddate`, ISO 8601 UTC. Strip
  fractional seconds before parsing.
- **timeKnown** — false when `ev:startdate` is date-only (no `T`), true
  otherwise. Consumers must branch on this rather than inferring from the time
  value, since a date-only event has no meaningful time-of-day at all.
- **location** — `ev:location`.
- **opponentLogo** — `s:opponentlogo`.
- **url** — `link`.
- **id** — `s:gameid`.

Then, in order:

1. Drop events whose `startUtc` is in the past.
2. Sort ascending by `startUtc`.
3. Collapse same-sport, same-opponent events into one entry whose `startUtc`
   is the first item's and whose `endUtc` is the last item's — **but only when
   the next event begins within 48 hours of the running group's end.** The
   window is required: without it, the November and February home series
   against the same hockey opponent would merge into one nonsensical
   five-month row.

   Each event must be matched against the most recent open group **for its own
   sport and opponent**, not merely against the previous row in the sorted
   list. Events from other sports routinely fall between two days of the same
   tournament, and a previous-row-only comparison silently leaves 13
   tournaments and series uncollapsed.

   Verified by simulating the algorithm against the 2026-07-18 snapshot: 141
   items reduce to 101 rows across 36 collapsed groups, with every original
   item still accounted for, no two rows for the same matchup inside the
   window, and the three-day golf tournaments and `NCHC First Round
   (Best-of-3)` merged while separate series stay distinct.

Timestamps that arrive as literal `TBA`/`TBD` strings do not occur in the
current snapshot but must not raise; they are treated the same as date-only.

### Job (`app/jobs/scheduled/fetch_redhawks_schedule.rb`)

`Jobs::Scheduled`, `every 30.minutes`. Fetches via `FinalDestination::HTTP`,
passes the body to the parser, and writes the result plus a `fetched_at` stamp
to `PluginStore`.

**A failed fetch or a parse error leaves the previous value in place.** This is
the entire stale-if-error strategy: an outage at miamiredhawks.com is invisible
to forum users until the data ages out naturally. Failures are logged, not
raised.

`PluginStore` is used deliberately in place of a custom table — the payload is a
few KB and needs no querying, so a migration would be overhead with no benefit.

### Controller

`GET /redhawks-schedule.json` returns `{ generated_at, events: [...] }`.

- `requires_login false` — anonymous visitors must get the sidebar too.
- `skip_before_action :check_xhr`.
- `Cache-Control: public, max-age=900`.
- Returns an empty `events` array, not an error, when the store is empty.

### Site settings

- `redhawks_schedule_enabled` — bool, default true
- `redhawks_schedule_feed_url` — string, default the calendar.ashx URL above

## Component 2 — `miamihawktalk-schedule` (theme component)

```
about.json          # component: true
settings.yml
javascripts/discourse/api-initializers/schedule.js
javascripts/discourse/components/upcoming-games.gjs
common/common.scss
locales/en.yml
```

Kept separate from the main `miamihawktalk-theme` repo so it can be disabled or
updated independently, and so the theme stays SCSS-only. It inherits the theme's
color variables (`$tertiary`, `$primary`, `$primary-medium`, `$primary-low`)
automatically and must not redefine the palette.

### Rendering

A Glimmer component rendered into a sidebar plugin outlet.

Target Discourse version: **2026.7.0-latest** (self-hosted).

**Resolved 2026-07-19** against Discourse source. The concern was real:
`addSidebarSection` is organised around link rows — one line of text per link
plus a prefix and suffix — and cannot produce the two-line, logo-bearing layout
below.

It does not block the design, because `after-sidebar-sections` is an ordinary
plugin outlet in `frontend/discourse/app/components/sidebar.gjs` and accepts an
arbitrary Glimmer component through `api.renderInOutlet`. It sits inside
`<nav id="d-sidebar">`, below the navigation sections and above the
switch-panel buttons and footer. The approved row design stands; no fallback to
a text-only layout is needed.

Note the outlet is **not** `below-sidebar-sections`, which this document
originally guessed at and which does not exist anywhere in Discourse. Full
findings, including the frontend tree's move to `frontend/discourse/app/`, are
in `NOTES-api-verification.md` in the plugin repo.

### Row

```
[logo]  vs Xavier
        W SOCCER - Aug 16, 7:00p
```

- Logo 24px from `opponentLogo`; on error the `img` is hidden and text reflows.
  Some of these URLs will eventually 404.
- `vs` / `at` in `$tertiary`; opponent name in `$primary`.
- Sport label uppercase, small, `$primary-medium`, shortened via a lookup map
  (`Women's Soccer` -> `W SOCCER`, `Men's Basketball` -> `M BASKETBALL`) so rows
  do not wrap at sidebar width (~200px).
- Times rendered in the visitor's local timezone with `Intl.DateTimeFormat`, no
  timezone label, since it is the reader's own clock.
- **Events with `timeKnown: false` render as `Aug 30, TBA`** and are formatted
  from the feed's calendar date directly, with no timezone conversion. Applying
  conversion to a presumed midnight would display `2026-08-29` as Aug 28 for
  every viewer in the US. This path covers the majority of hockey and football
  rows for most of the year, so it is a primary case, not an edge case.
- Collapsed multi-day events show a range: `Apr 27-29`.
- The whole row links to the event's `calendar.aspx` page, new tab.
- Footer link **See full schedule ->** to `https://miamiredhawks.com/calendar.aspx`.

### Data fetch

`GET /redhawks-schedule.json` on page load, cached in `localStorage` with a
30-minute TTL so navigation does not re-request.

### Settings

- `games_shown` — int, default 5, range 1-10
- `enabled_on_mobile` — bool, default true

### Empty and error states

If the request fails, returns malformed data, or returns zero upcoming events,
**the section renders nothing at all** — no error text, no empty container. Zero
events is the normal state every June; a persistent "Error loading games" box in
the sidebar for six weeks would be worse than absence.

## Verification

Per this project's rule that only the running site confirms rendering:

**Offline, before deploy:**

- `bundle exec rspec` against the parser, using the 2026-07-18 snapshot as a
  fixture. Covers: sport extraction across all title shapes, vs/at home/away,
  date-only vs timed detection (83/58 split in the fixture), fractional-second
  timestamps, multi-day collapsing within the 48-hour window (the 3-item golf
  and hockey cases, merging across an interleaved other-sport event, and the
  non-merging of separate same-opponent series), past-event filtering, and
  malformed input not raising.
- `python3 -m json.tool about.json`, `ruby -ryaml -e "YAML.load_file(...)"` on
  locales, per the existing repo checks.

**On the live site:**

- Sidebar renders in both MiamiHawkTalk Light and Dark.
- Desktop and mobile.
- Logged out, to confirm the anonymous path works.
- A row with a deliberately broken logo URL to confirm the fallback.
- Both a timed row and a `TBA` row visible together, confirming the TBA date
  matches the athletics site's published date exactly.
- Empty state, by pointing the feed setting at a stub that yields no events.

## Out of scope

- A dedicated `/games` route or full schedule page.
- Per-user sport filtering.
- Scores, results, or standings — this is upcoming events only.
- Game-thread creation or any link between events and topics.
