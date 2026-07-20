---
name: recruit-pipeline
description: Use when editing, reviewing, or debugging anything under the recruit half of this plugin — RecruitSource, the two parsers, RecruitAssembler, the recruit controller or refresh job, or the /redhawks-recruit.json payload shape. Also use when a recruit card renders the wrong thing and you need to know whether the plugin or the theme component is at fault.
---

# Recruit pipeline

The plugin serves two unrelated features. This covers the recruit half:
`/redhawks-recruit.json`, a public unauthenticated endpoint that scrapes
247Sports and caches the result. The schedule half (RSS calendar, Sidekiq job)
shares nothing with it but the repo and the PluginStore.

The theme component that renders this data is `../miamihawktalk-recruits/`.

## Shape of the pipeline

```
slug ──► RecruitSource.url_for ──────► player page HTML
                                            │
                    RecruitParser.parse ◄───┤  identity, ratings, ranks,
                                            │  and a TRUNCATED ~5-school list
                                            │
         RecruitSource.interests_url_from ◄──┘
                       │
                       ▼
              interests page HTML ──► RecruitInterestsParser.parse
                                            │  the COMPLETE school list
                                            ▼
                              RecruitAssembler.merge
                                            │
                                            ▼
                          payload + offer_count + committed_to
```

Both fetch paths — the controller's `fetch_inline` and
`Jobs::RefreshRedhawksRecruit` — run this same sequence. Any change to payload
assembly goes in `RecruitAssembler` so the two cannot drift; a card that differs
depending on whether it was cache-warmed is the symptom of putting it elsewhere.

## Build every fetched URL in RecruitSource

`RecruitSource` is the plugin's SSRF boundary. The endpoint accepts a slug and
never a URL, because this droplet answers
`http://169.254.169.254/metadata/v1.json` with its instance metadata.

The interests URL is the one URL not built from a slug — it is scraped from a
page 247 controls. Keep the existing discipline when touching
`interests_url_from`:

- Validate the **parsed** host against the allowlist. A string match passes
  `evil-247sports.com` and `247sports.com.attacker.net`.
- **Rebuild the URL from the regex capture.** Never return the scraped href.
  The capture's charset is `[a-z0-9-]`, which contains no `/`, `.`, `:`, `@`,
  `?` or `#` — that is what makes the output structurally incapable of naming
  another host, and what discards any port, userinfo, query or fragment.
- Require the recruitment slug to correspond to the player slug. Without it the
  first matching anchor wins, and a "similar recruits" module would attribute
  another player's offers to this one.
- Return `nil` for anything unexpected. This runs on a public endpoint, so a
  raise is a 500.

## Three protections, three different triggers

| Mechanism | Scope | Means |
|---|---|---|
| Tombstone | per slug | 247 answered, and this player does not exist |
| Fetch-failure cooldown | **global**, 5 min | 247 refused *us* — throttle, block, timeout, empty body |
| Rate limiter | per IP | bounds *new* outbound fetches; cache hits are unlimited |

The cooldown is the defence against slug-walking: one flag turns every slug away
at the door. That is also why it must not be tripped casually — setting it stops
recruit cards site-wide for five minutes.

**An interests-page failure trips none of them.** It is a partial success: the
player page parsed, so the caller still holds the ~5 offers it carried, and the
card degrades rather than disappearing. `fetch_interests` therefore rescues
everything itself in both callers, and the job makes its tombstone decision
*before* calling it.

If you add a third fetch, give it the same treatment.

## Absent, zero, and empty are three different facts

The card renders claims about named teenagers, so the payload must not blur
them. Preserve these:

| Field | `nil` means | Distinct from |
|---|---|---|
| `stars` | no rating block | never `0` — the parser maps zero filled stars to `nil` |
| `offers` | the page has no offers section (enrolled players) | `[]` |
| `offer_count` | key **absent** — the list is the truncated fallback | `0`, a real count |
| `committed_to` | not committed | — |

`offer_count`'s presence is the only signal that `offers` is complete, and the
component relies on it for exactly that. Set it only where the interests rows
were actually assigned.

Guard with `Number.isFinite`-equivalents, never truthiness. Parser methods
return `nil` on bad input rather than raising.

## The two 247 pages share no markup

Do not reuse selectors across them.

| | Player page | Interests page |
|---|---|---|
| Row | `li` with `.college-comp__interest-level` | `li` with `div.first_blk` |
| Team | `a.college-comp__team-name-link` (the `img` has no `title`) | `div.first_blk a`, `img` does carry `title` |
| Offered | `.college-comp__offer-check` present | `div.secondary_blk span.offer` text is `Yes` |
| Commitment | `title="committed"` | text `Status: Committed (2/1/2026)` |

Two consequences worth stating outright:

- **Both commitment forms must normalise to the lowercase token `committed`.**
  `committed_to` and the card's entire red state key off that exact string, and
  a mismatch fails silently.
- **Strip before matching, don't anchor first.** Both pages pad their text
  nodes: the offer span flattens to `" Offer:  Yes  "`, so `/\AOffer:/` against
  the raw text never matches and every school reads as not offered.

247 writes `title="none"` for a plain offer. That is an absence, not a status —
normalise it to `nil` or the card shows a chip reading "None" beside a school
that did offer.

Each school's `li` also wraps a depth chart of `li` elements holding player
names. Filtering rows on `div.first_blk` is what excludes them.

## rankings_section falls back; composite_section must not

The player page carries two `.rankings-section` blocks, `247Sports` and
`247Sports Composite®`, holding `86` and `0.8600` respectively — the same
recruit on two scales.

- `rankings_section` **falls back** to the first section when no title matches.
  That fallback is what keeps single-section pages (enrolled players) working.
- `composite_section` has **no fallback**, so a single-section page yields `nil`
  for the composite rather than reporting the 247 numbers as composite ones. Do
  not add one.
- Match the composite on the `"247Sports Composite"` **prefix**, stopping before
  the `®`, so the entity decoding never matters.
- `rating` guards on `/\A\d+\z/` and `composite_rating` on `/\A\d*\.\d+\z/`, so
  neither can read the other's block.

Ranks come from the 247 section only. Stars come from **both** — each rating
renders its own row in the card.

## Tests

```bash
~/.gem/ruby/2.6.0/bin/rspec spec/
```

`rspec` is user-scoped and not on `PATH`. Run the whole directory: the recruit
half spans `recruit_parser_spec.rb`, `recruit_interests_parser_spec.rb`,
`recruit_source_spec.rb` and `recruit_assembler_spec.rb`.

**Local Ruby is 2.6.10, the container runs 3.x.** `filter_map`, `Hash#except`,
endless method definitions and rightward assignment work in production and fail
here.

**ActiveSupport is not loaded in specs.** `be_in`, `in?` and friends fail —
use plain matchers or `satisfy {}`. The controller and job *do* run inside
Rails and may use `blank?`.

`RedhawksRecruitController` and `RefreshRedhawksRecruit` have no automated
coverage; they need Rails globals this setup cannot load. Changes there are
verified by reading, so trace the failure paths deliberately.

Fixtures are real saved pages: `recruit_hs.html` (Kaden Estep, committed to
Miami, both rankings sections), `recruit_enrolled.html` (William Pressley,
single section, no offers section) and `recruit_interests.html` (Estep's
interests page).

## Deploying, and the cache

Changes here need `./launcher rebuild app` — minutes of downtime. Batch them.
See the `discourse-server-ops` skill for the rebuild and for **clearing cached
payloads, which any change to the payload shape requires**: entries carry no
schema version and are served until `RECRUIT_TTL` (24h) expires, so new code
alone will not make a new field appear.
