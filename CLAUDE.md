# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **Discourse plugin** with two features, both fed by the Miami Athletics RSS
calendar it fetches every 30 minutes:

- `/redhawks-schedule.json` — upcoming events, rendered by
  `../miamihawktalk-schedule/`.
- **Gameday topics** — a topic per game, or one weekly digest per sport,
  opened automatically and posted as Swoop Bot.

The schedule exists because `miamiredhawks.com` sends no CORS headers, so a
browser cannot fetch that feed directly.

## Deploying costs downtime

Unlike the theme-side repos, changes here require a container rebuild:

```bash
cd /var/discourse && ./launcher rebuild app
```

That is several minutes with the site down, so batch changes rather than
deploying one at a time. If the site fails to come back, remove this plugin's
clone line from `containers/app.yml` and rebuild again — that restores service
immediately. Debug afterwards, not during.

## Running anything against the live app

`rails runner` **must run as the `discourse` user.** Postgres uses peer
authentication and rejects root with "Peer authentication failed for user
discourse".

```bash
cd /var/discourse && ./launcher enter app
cd /var/www/discourse
sudo -E -u discourse bundle exec rails runner 'puts PluginStore.get("discourse-redhawks-schedule", "events")["events"].length'
```

## Tests

```bash
~/.gem/ruby/2.6.0/bin/rspec spec/lib
```

`rspec` is installed user-scoped and is **not** on `PATH`. That runs the four
pure spec files under `spec/lib/` (`parser_spec.rb`, `eastern_spec.rb`,
`gameday_composer_spec.rb`, `gameday_planner_spec.rb`) — 90 examples, 0
failures. There is a fifth spec file, `spec/jobs/post_redhawks_gameday_spec.rb`,
which is Rails-dependent and does not run here — see below.

**Do not run plain `rspec spec/` on this machine — it fails to load, not just
to pass.** `spec/jobs/post_redhawks_gameday_spec.rb` requires `rails_helper`,
which exists only inside the Discourse container. RSpec loads every spec file
before running any of them, so that one missing require aborts the whole run
with a `LoadError` and "0 examples, 0 failures, 1 error occurred outside of
examples" — it looks like the suite is broken when really it's just pointed
at the wrong scope. Run `spec/jobs/` inside the container instead:

```bash
sudo -E -u discourse LOAD_PLUGINS=1 bundle exec rspec plugins/discourse-redhawks-schedule/spec/jobs/post_redhawks_gameday_spec.rb
```

**ActiveSupport is not loaded in the pure specs.** Matchers that depend on it
(`be_in`, `in?`) fail. Use plain matchers or `satisfy {}`. The controller and
jobs do run inside Rails and may use `blank?`; their specs cannot.

**Local Ruby is 2.6.10; the container runs 3.x.** Syntax newer than 2.6 —
`filter_map`, `Hash#except`, endless method definitions, rightward assignment —
works in production and fails only on this machine. Stay 2.6-compatible.

## Architecture

- **`lib/redhawks_schedule/parser.rb`** — pure Ruby, with **no Rails, HTTP or
  persistence**. That is deliberate: it puts all the interesting logic somewhere
  unit testable without a Discourse checkout. Keep it that way.
- **`app/jobs/scheduled/fetch_redhawks_schedule.rb`** — Sidekiq, every 30
  minutes. Failures are logged and swallowed, and a response not containing
  `<rss` is discarded rather than stored — so an upstream outage leaves the last
  good data in place and stays invisible to users.
- **`app/controllers/redhawks_schedule_controller.rb`** — serves the stored
  payload. `requires_login false` is load-bearing: the sidebar renders for
  anonymous visitors too.
- Storage is **`PluginStore`**, not a table. The payload is a few KB and needs no
  querying, so a migration would be overhead with no benefit.
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

## The feed's dominant quirk

**59% of events carry no announced time.** The feed expresses this as a
date-only `<ev:startdate>` (`2026-08-29`) rather than the string "TBA", and
those are **Eastern calendar dates** that must never be timezone-converted.
Hockey and football are the most affected sports. `time_known` in the payload is
what marks them.

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

## Docs

- `NOTES-api-verification.md` — Discourse API facts verified against source
  (outlet names, helper signatures), with where each came from.
- `docs/superpowers/` — the schedule design spec and implementation plan.
- Planned work lives in `../BACKLOG.md`, not here.
