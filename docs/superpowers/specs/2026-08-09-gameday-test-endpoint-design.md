# Gameday test endpoint — design

An admin-only endpoint that posts one gameday topic on demand, for the next
upcoming event among the sports configured for threads. It exists so the
composer's real rendered output — embeds, broadcast badges, TBA handling — can
be seen on the live forum before `redhawks_gameday_enabled` is turned on.

Stacked on the `gameday-threads` branch; it depends on the planner, composer
and bot introduced there.

## Why an endpoint

A rake task or a one-off Sidekiq job would each be about a third of the code
and add no permanent surface. The endpoint was chosen anyway, deliberately: it
is triggerable without an interactive shell on the container, and it returns
the created topic's URL to the caller rather than to a log.

The cost is accepted, not overlooked. This plugin's only other route is an
anonymous read; this adds an authenticated write.

## Trigger and gating

```
POST /redhawks-gameday-test.json
```

Admin only.

Gating is asymmetric on purpose:

- **`redhawks_schedule_enabled`** applies. `plugin.rb` declares
  `enabled_site_setting :redhawks_schedule_enabled`, so the route 404s when the
  plugin is off. With the plugin off there is no stored feed to post from.
- **`redhawks_gameday_enabled` is ignored.** Testing the output *before*
  enabling gameday is the entire purpose. An endpoint that required the switch
  already thrown would have nothing to offer.

## Selection

The stored payload does most of the work already. `FetchRedhawksSchedule`
stores `parser.events`, and `Parser#events` returns rows that are already
`upcoming`-filtered and sorted by `[start_utc, sport]`. So "the next event" is
the first matching row of the stored list — there is no need to re-derive the
`DATE_ONLY_GRACE` cutoff that keeps a TBA event alive through its day, and no
need to invent a tie-break for two games starting the same minute.

The one consequence to know: the store refreshes every 30 minutes, so a game
that started within the last half hour can still be at the front. For a tool
whose output a human reads immediately, that is acceptable.

New pure function, in `lib/redhawks_schedule/gameday_planner.rb`:

```ruby
GamedayPlanner.next_test_action(events:, config:, ledger:)
```

It maps `config` rows through the existing `normalize`, keeps those with
`mode == "thread"` and a non-nil category, and returns the first event that:

- belongs to one of those sports,
- has a non-nil `id`, and
- has no `gameday:game:<id>` key in the ledger.

It returns `nil` when nothing qualifies. It takes no `now`, because the stored
list is already time-filtered.

`nil` carries no reason with it, and it does not need to. The controller checks
the two coarse cases — no `thread`-mode sport configured, no stored events —
before calling, so a `nil` return means exactly one thing: every candidate is
already in the ledger. Keeping the function's return a plain event or `nil`
avoids a result object that exists only to name errors.

It belongs in the planner rather than the controller for one concrete reason:
`normalize` already lives there, and site-setting row parsing should not exist
in two places. It is pure, so it is spec'd on the dev Mac like the rest of
`lib/`.

**Ledger: read, never written.** Reading it means the endpoint answers the
question actually being asked — "what will the next thread look like" — rather
than re-posting a game production already covered. Not writing it means a test
run never suppresses a real one.

## Posting

Identical to the path `PostRedhawksGameday#post` already takes:

- `GamedayBot.resolve` for the poster,
- `GamedayComposer.thread_title` and `thread_body` for the content,
- `PostCreator.create!` with `skip_validations: true`, into the sport's
  configured category.

The topic lands in the **real** category, not a staging one, so what is seen is
what production would produce.

## Responses

Success is `200`:

```json
{
  "topic_id": 123,
  "topic_url": "https://miamihawktalk.fans/t/.../123",
  "title": "…",
  "sport": "Football",
  "start_utc": "2026-08-29T18:00:00Z",
  "time_known": true,
  "category_id": 42
}
```

Failure is `422` with a `reason` string, for:

- no sport configured in `thread` mode with a category,
- no stored events,
- every candidate event already in the ledger,
- Swoop Bot unresolvable.

This inverts the convention used elsewhere in the plugin, where failures are
logged and swallowed so an upstream outage stays invisible to users. That
convention is right for a background job serving a public sidebar and wrong
here: a human is reading this response and needs to know why nothing was
posted.

## Testing

- `GamedayPlanner.next_test_action` extends `spec/lib/gameday_planner_spec.rb`
  and runs on the dev Mac with the other pure specs.
- A request spec requires `rails_helper` and therefore joins `spec/jobs/` as
  container-only, run with `LOAD_PLUGINS=1`.

## To verify before implementing

The correct admin-only controller base class for this Discourse version —
`::Admin::AdminController` versus an explicit `ensure_admin` on a plain
`::ApplicationController` — has not been checked against the container source.
Confirm it there and record the finding in `NOTES-api-verification.md`, the way
the sidebar outlet correction was recorded.

## Accepted tradeoff

Because the endpoint never writes the ledger, enabling gameday later causes the
real job to post the same game a second time. The duplicate is deleted by hand.
This was chosen over the alternatives — writing the ledger (the test silently
*becomes* the live thread, with no second chance at a bad title) and posting to
a staging category (no collision, but no longer a test of the real thing).
