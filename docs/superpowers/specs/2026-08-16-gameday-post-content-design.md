# Gameday post content — design

Refines what a gameday post *says*. The planner decides which topics exist and
the job posts them; both are done. This changes only `GamedayComposer` — the
titles and markdown bodies for the per-game **thread** and the weekly
**digest** — so a copy change still cannot affect scheduling.

Today the body reads like a scoreboard: a bold matchup, a date line, a
location, then bold-labelled `TV:` / `Radio:` rows and a bare link list. It is
correct and dull. The goal is a scannable **info board** — the definitive
one-stop game post — that reads well whether the feed gave us everything or
almost nothing.

## The data we actually have

Pulled the live feed (226 events) to check fill rates rather than trust the
schema. The lesson was about *timing*, not the numbers:

- Broadcast fields — TV, radio, streaming audio, livestats, tickets — are
  **sparse when a game is far out and fill in a week or two before kickoff**,
  which is exactly when a gameday thread posts. So at post time these are
  usually present for the marquee sports threads are configured for. The body
  must **present richly by default and degrade gracefully**, not assume the
  sparse far-out snapshot is normal.
- **Times are usually known at post time.** `Time TBA` is the exception later,
  even though 59% of the far-out feed lacks a time.
- `s:gamepromoname` is a real promo for thread sports (`Homecoming`,
  `Family Weekend`, `Exhibition`). Its golf-venue noise (`Talis Park`,
  `Calusa Pines`) does not matter — **golf is not a thread sport.**
- **TV is a bare network name with no URL**, and ESPN can never be embedded.
  This is unchanged: TV renders as a text badge, and the only thing ever
  embedded is a framable SIDEARM `showcase/embed.aspx` link (one or two events
  in the whole feed). ESPN gets a badge, never a player.

## Thread body

Inline/compact. A sport emoji leads; every line below the headline renders only
when it has content, so the same template covers the rich and sparse cases
without empty labels.

**Rich game — what a football thread looks like at post time:**

```
🏈 **Football vs Ohio** · Homecoming

📅 Tuesday, November 10 · 7:00 PM ET
📍 Yager Stadium, Oxford OH

📺 ESPN2/ESPNU · 📻 Miami Radio Network

<framable showcase embed, when present>

🎟️ [Tickets] · 📊 [Live stats] · 🔊 [Listen live] · 🔗 [Game page]
```

**Sparse game — same template, degraded:**

```
⚽ **Women's Soccer vs Purdue Fort Wayne** · Exhibition

📅 Saturday, August 8 · 7:00 PM ET
📍 Bobby Kramig Field, Oxford OH

🔗 [Game page]
```

Line by line:

- **Headline** — `<emoji> **<matchup>**`, always rendered. When
  `event[:promo]` is present, append ` · <promo>` verbatim. No dedup or
  exhibition special-casing: if the opponent name already carries `(Exhibition)`
  and the promo is also `Exhibition`, both show. Not worth the complexity.
- **`📅` when line** — the existing `when_line`, which already handles
  `Time TBA`. Emoji prefix only.
- **`📍` location** — rendered only when `event[:location]` is present.
- **`📺 … · 📻 …` watch/listen line** — TV and radio badges, joined by ` · `,
  emitted only if at least one is present. Bare text, no links (the feed gives
  no URLs for these).
- **Stream embed** — the current three-state logic is unchanged:
  framable `video_embed` → iframe; plain `video` → `▶️ [Watch the stream]`;
  neither → nothing.
- **Links line** — collects whichever of `🎟️ [Tickets]`, `📊 [Live stats]`,
  `🔊 [Listen live]` (the `audio` field), `🔗 [Game page]` (the `url`) exist,
  joined by ` · `. Rendered only when non-empty. `Game page` is almost always
  present, so this line almost always appears.

Blank lines separate the headline, the when/where block, the watch line, the
embed, and the links line. Adjacent groups that both collapse to nothing must
not leave a double blank — the composer joins present segments rather than
emitting fixed blank lines.

## Digest body

Same voice, applied to the weekly per-sport digest.

```
🏈 **Football — week of November 8**

- 📅 Sat, Nov 8 · 3:30 PM ET — vs Ohio · 📊 [Live stats]
- 📅 Tue, Nov 11 · Time TBA — at Cincinnati
```

- Header gains the sport emoji and bolding; `digest_title` (the topic title) is
  unchanged.
- Each row keeps its inline `when_line — <side> <opponent>` shape, prefixed with
  `📅`, and appends ` · 📊 [Live stats]` when the event carries livestats. A
  shorter date form (`%a, %b %-d`) than the thread's full weekday keeps rows
  tight; this stays inside the composer.

## Sport → emoji

A small lookup in the composer, keyed on `event[:sport]` exactly as the feed
spells it:

| Sport | Emoji | | Sport | Emoji |
|---|---|---|---|---|
| Football | 🏈 | | Baseball | ⚾ |
| Ice Hockey / Hockey | 🏒 | | Softball | 🥎 |
| Men's/Women's Basketball | 🏀 | | Field Hockey | 🏑 |
| Men's/Women's Soccer | ⚽ | | Tennis | 🎾 |
| Volleyball | 🏐 | | Cross Country / Track | 🏃 |

Unmapped sports fall back to `🗓️` so the headline still renders cleanly. The
exact feed spellings are confirmed against the live titles during
implementation; the map matches on the sport string the parser already
produces.

## Titles

`thread_title` and `digest_title` are unchanged. The promo stays in the body;
titles keep their clean `matchup — date` / `sport — week of date` form.

## Non-goals

- No images. `opponent_logo` is 100% present but hotlinks an external CDN, and
  the site is trademark-careful; text and emoji carry the visual weight.
- No discussion prompts. This is an info board, not a discussion starter.
- No new feed fields, HTTP, or persistence. `GamedayComposer` stays pure.
- Stripping the `(Exhibition)` opponent suffix is a separate sidebar backlog
  item, out of scope here.

## Testing

All changes land in `lib/redhawks_schedule/gameday_composer.rb`, which is pure
and spec'd on the dev Mac. `spec/lib/gameday_composer_spec.rb` is rewritten to
assert the new output: emoji headline, conditional promo, the collapsing
watch/links lines, unchanged embed states, the sparse-degradation case, and the
digest emoji header. Stay Ruby 2.6-compatible and avoid ActiveSupport matchers,
per the repo's constraints. No container-only specs are needed — nothing here
touches Rails.
