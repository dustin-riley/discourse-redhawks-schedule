# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **Discourse plugin** serving two unrelated features, each fetched server-side
and rendered by its own theme component:

| Endpoint | Source | Component |
|---|---|---|
| `/redhawks-schedule.json` | Miami Athletics RSS calendar, refreshed every 30 min | `../miamihawktalk-schedule/` |
| `/redhawks-recruit.json` | 247Sports player pages, fetched per slug on demand | `../miamihawktalk-recruits/` |

The schedule exists because `miamiredhawks.com` sends no CORS headers, so a
browser cannot fetch that feed directly. The two halves share only this repo and
the PluginStore.

**Working on the recruit half — the parsers, `RecruitSource`, `RecruitAssembler`,
the recruit controller or job, or the payload shape — use the `recruit-pipeline`
skill.** It is a public unauthenticated endpoint that scrapes a third party, and
the invariants are not guessable from the code alone.

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
~/.gem/ruby/2.6.0/bin/rspec spec/
```

`rspec` is installed user-scoped and is **not** on `PATH`. Run the whole
directory — there are five spec files, and naming one runs a fraction of them.

**ActiveSupport is not loaded here.** Matchers that depend on it (`be_in`,
`in?`) fail. Use plain matchers or `satisfy {}`. The controller and jobs do run
inside Rails and may use `blank?`; their specs cannot.

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

## The feed's dominant quirk

**59% of events carry no announced time.** The feed expresses this as a
date-only `<ev:startdate>` (`2026-08-29`) rather than the string "TBA", and
those are **Eastern calendar dates** that must never be timezone-converted.
Hockey and football are the most affected sports. `time_known` in the payload is
what marks them.

## Docs

- `NOTES-api-verification.md` — Discourse API facts verified against source
  (outlet names, helper signatures), with where each came from.
- `docs/superpowers/` — the schedule design spec and implementation plan.
- Planned work lives in `../BACKLOG.md`, not here.
