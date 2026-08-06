# Gameday Threads — Design

**Date:** 2026-08-05
**Status:** Approved, ready for planning

## Goal

Automatically open a discussion topic for each game, or a weekly digest per
sport, from the athletics RSS calendar this plugin already fetches. Where the
game has an embeddable stream, embed it.

## Why this lives here

A gameday thread is a pure function of the parsed schedule. Splitting it into
its own plugin would either couple two plugins through an undocumented
PluginStore key or duplicate `Parser` — the trickiest code in the workspace,
holding the date-only Eastern handling and the collapse logic. Duplicating it
guarantees the two eventually disagree about what is on the schedule.

This does broaden the plugin past "one feature". The boundary that matters —
`lib/redhawks_schedule/parser.rb` stays free of Rails, HTTP and persistence —
is untouched: the gameday planner is a second pure consumer of the same parsed
events. `CLAUDE.md` needs rewording, not defending.

## What the feed actually supports

Verified against a live fetch on 2026-08-02 (167 items).

Miami self-produces streams for the sports no network wanted, and those embed
freely. Football, basketball and baseball go to ESPN precisely because they are
the valuable ones. **Embeddability runs inversely to how much anyone cares
about the game**, and no design choice changes that.

- `<s:links><s:livestats>` — 13 events. Football and Field Hockey **home** games
  plus one Track & Field meet. URLs are sport-generic
  (`/sidearmstats/football/summary` is identical across all six football dates),
  so they are a "stats are live now" pointer, not a per-game link.
- `<description>` — labelled lines delimited by a **literal backslash-n**, not a
  newline. Labels across the whole feed: `Streaming Video` ×1, `TV` ×7,
  `Radio` ×13, `Streaming Audio` ×13, `Tickets` ×6.
- `TV:` is a bare network name (`ESPN+`, `CW Network`, `ESPN2/ESPNU/CBS Sports`)
  with **no URL**. There is nothing to embed and nothing to link precisely.

### ESPN cannot be embedded, by any route

Not a headers problem to work around. Three independent blockers, each fatal on
its own: ESPN+ requires a paid subscription login and ESPN/ESPN2/ESPNU require
MVPD authentication, so every viewer would have to authenticate *inside the
iframe*; playback uses DRM-protected, per-session tokenised manifests, so
pointing our own player at it is out; and there is no third-party embed API for
ESPN live game video. Their edge returns `x-amzn-waf-action: challenge` with a
zero-byte body, so even the response headers are unreadable.

Football, men's and women's basketball, and baseball therefore get a TV badge
and an outbound link, permanently. This is a ceiling, not a gap to close later.

### The one embeddable stream

`showcase?Live=630` → `/watch/?Live=630`, whose Knockout-bound player frames:

    https://miamiredhawks.com/showcase/embed.aspx?Live=630&type=Live

That URL returns 200 with **no `X-Frame-Options` and no CSP `frame-ancestors`**
— built to be framed. Inside is a plain JW Player on an unauthenticated HLS
source (`cdn.jwplayer.com/live/broadcast/ImGAT1SZ.m3u8`), with a countdown to
15 minutes pre-kickoff and a poll that swaps in the player when the manifest
goes live. No login, no paywall, no membership check.

Reframing a Learfield/SIDEARM stream routes around their ads and analytics on a
rightsholder's feed. Accepted deliberately, with the fallback below limiting
blast radius.

## Components

Four pieces in this repo, one container rebuild.

| Piece | Kind | Responsibility |
|---|---|---|
| `lib/redhawks_schedule/parser.rb` | extended | `#events` (uncollapsed) and `broadcast` extraction |
| `lib/redhawks_schedule/gameday_planner.rb` | **new, pure** | decides *what* to post |
| `app/jobs/scheduled/post_redhawks_gameday.rb` | new | executes the plan |
| `config/settings.yml` | extended | per-sport configuration |

`GamedayPlanner` is pure Ruby: `(events, config, now) → [actions]`, no Rails, no
clock, no I/O. The local Mac cannot run Rails-dependent specs, so scheduling
logic inside the job would be untestable until it was on the server posting to a
live forum. The job stays a thin executor — call planner, loop, `PostCreator`.

## Parser changes

`#parse` returns exactly what it returns today. `#events` exposes the
uncollapsed list underneath it:

```ruby
def events; upcoming(raw_events).sort_by { |e| [e[:start_utc], e[:sport]] }; end
def parse;  collapse(events);                                                end
```

The sidebar wants tournaments collapsed into one row; gameday wants each game.
No behaviour change for the existing consumer.

Each event gains a `broadcast` hash, from the `\n`-delimited description labels
plus `<s:livestats>`:

```ruby
broadcast: { video:, tv:, radio:, audio:, tickets:, livestats: }
```

### Embed URL derivation

The feed gives `admin.miamiredhawks.com/showcase?Live=630`; the framable player
is `miamiredhawks.com/showcase/embed.aspx?Live=630&type=Live`. Extract
`Live=(\d+)`, rebuild against the canonical host.

**This generalises from exactly one sample.** If the pattern does not match,
emit a plain link and never guess — a wrong iframe is worse than a working link.
Log non-matching `Streaming Video` values so a second format is noticed rather
than silently degraded.

## Settings

```yaml
redhawks_gameday_enabled:
  default: false
redhawks_gameday_sports:
  type: objects
  default: []
  schema:
    name: sport
    properties:
      sport:       { type: string, required: true }
      mode:        { type: enum, choices: ["thread", "digest", "off"], required: true }
      category:    { type: categories, required: true, validations: { max: 1 } }
      days_before: { type: integer, validations: { min: 0, max: 14 } }
      digest_day:  { type: enum, choices: ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"] }
redhawks_gameday_poster_username:
  default: "redhawks_bot"
```

`type: objects` is confirmed available to plugin site settings —
`SiteSettings::TypeSupervisor.types` includes `objects: 28` with `schema` as a
validator opt. (The meta topic claiming theme-settings-only is stale.)
`categories` is an array type with no singular form, hence `max: 1`. Admin gets
a real form with a category chooser per row, so sports can be retuned mid-season
without a rebuild — which matters when a code change costs downtime.

`days_before` applies only to `thread` mode; `digest_day` only to `digest`. Each
field means one thing. A digest is a calendar posting, not a countdown posting,
so it does not reuse `days_before`.

`sport` must match the feed string exactly — `Women's Volleyball`,
`Track & Field, Cross Country`, curly apostrophes included. The planner returns
unmatched configured names and the job logs them; otherwise a typo is a
permanent silent no-op.

Current feed distribution, for choosing defaults — note basketball and baseball
are **not in the feed yet** and will appear as their seasons approach:

| Sport | Events | With any link |
|---|---|---|
| Hockey | 40 | 0 |
| Men's Golf | 33 | 0 |
| Women's Volleyball | 32 | 0 |
| Women's Soccer | 23 | 1 |
| Field Hockey | 20 | 6 |
| Football | 13 | 13 |
| Track & Field, Cross Country | 6 | 1 |

## The bot account

Posts come from a dedicated account, not `system`. Core reserves negative user
ids (`-1` system, `-2` discobot) and a third-party plugin claiming one risks
collision, so the bot is seeded idempotently as an ordinary user named by
`redhawks_gameday_poster_username`: active, approved, trust level 4.

Being a positive-id user it is not `bot?`, so it is subject to new-user rate
limits and post validations. Create posts with `skip_validations: true`. If the
account is missing or the setting names a nonexistent user, **log and post
nothing** — never silently fall back to `system`, because retrofitting authorship
after threads exist is the problem this choice avoids.

## Job behaviour

`Jobs::PostRedhawksGameday`, every 30 minutes, after the existing fetch. It
reads stored PluginStore data and never touches the network, so an upstream
outage leaves it working from the last good fetch.

Idempotency is a PluginStore ledger:

```
"gameday:game:20927"                    => topic_id
"gameday:digest:Field Hockey:2026-W36"  => topic_id
```

- **thread** — for each upcoming event in a `thread` sport, if
  `now >= start_utc - days_before` and no ledger entry exists, create and record.
- **digest** — if today (Eastern) is `digest_day`, collect that sport's events
  in the next 7 days. **No games → post nothing.** Ledger keyed by ISO week, so
  a re-run within the day is a no-op.

All day-of-week and week-boundary maths is `America/New_York`, never UTC. 59% of
events are date-only Eastern calendar dates; doing this in UTC would post
digests on the wrong day roughly a fifth of the time.

**First-run burst cap.** With an empty ledger and `days_before: 14`, the first
run would open every qualifying thread at once. Cap creations at 5 per run, let
the rest bleed out over following runs, and log what was deferred.

`redhawks_gameday_enabled` defaults to **false** so deploying the rebuild does
not immediately post to a live forum. Configure sports first, then enable.

## Post body — three stream states

Built server-side as markdown. Header is matchup, kickoff (or "Time TBA" for
date-only events), and location, followed by whichever blocks apply:

1. **Embeddable** — `<iframe src="…/showcase/embed.aspx?Live=630&type=Live">`.
   SIDEARM's page handles its own pre-game countdown and manifest polling, so a
   thread opened days early degrades gracefully with no work on our side.
2. **Linkable** — no embeddable URL but a `TV:` value: a network badge and an
   outbound "Watch on ESPN+" button. Football, basketball, baseball — permanent.
3. **Absent** — omit the block entirely. Roughly 160 of 167 events today.

Then radio, streaming audio, live stats and tickets links where present.

Discourse sanitises iframes out of posts unless the src prefix is in the core
`allowed_iframes` list setting, which does prefix matching. The plugin appends
`https://miamiredhawks.com/showcase/embed.aspx?` to it idempotently on
initialisation rather than relying on a remembered manual admin step.

## Failure modes

| Condition | Behaviour |
|---|---|
| Upstream feed outage | Job reads stored data; keeps working from last good fetch |
| Game time moves after thread exists | Log; do **not** rewrite the post — silent edits to a thread people are reading are worse than a stale header |
| Game cancelled | Vanishes from feed; thread stays as-is |
| Configured sport matches nothing | Logged as unmatched; never fatal |
| `Streaming Video` in an unrecognised format | Plain link instead of iframe; logged |
| Bot account missing | Log, post nothing |

## Testing

Planner and parser specs are pure — they run on the local Mac under Ruby 2.6
with no ActiveSupport, per this repo's constraints:

- description parsing, including the literal `\n` delimiter
- embed-URL derivation, and its fallback on an unrecognised format
- `#events` uncollapsed vs `#parse` collapsed
- thread selection at the `days_before` boundary
- digest selection on the configured day; empty week posts nothing
- ledger idempotency for both kinds
- Eastern week boundaries and date-only events
- burst cap defers rather than drops

The job gets one thin Rails spec proving it calls `PostCreator` with what the
planner returned, and stops when disabled or when the bot is missing.

## Out of scope

- Editing or closing threads after creation
- Scores, records or live score updates — the RSS calendar carries no scores
  (`BACKLOG.md` tracks this separately)
- A gameday banner on the site chrome — that is the separate `[theme]` Game-day
  mode backlog item
- Any attempt to embed ESPN
