# Gameday Test Endpoint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an admin-only `POST /redhawks-gameday-test.json` that opens one gameday topic for the next unposted event among sports configured in `thread` mode, so the composer's real output can be seen on the live forum before `redhawks_gameday_enabled` is turned on.

**Architecture:** Selection is a new pure function on `GamedayPlanner`, which reads the already-`upcoming`-filtered, already-sorted stored event list and returns the first event whose sport is configured for threads and whose ledger key is absent. A thin admin controller calls it, posts through the same `GamedayBot` + `GamedayComposer` + `PostCreator` path the scheduled job uses, and renders the created topic's URL. The ledger is read and never written.

**Tech Stack:** Ruby, Discourse plugin API, RSpec, `PluginStore` for persistence.

## Global Constraints

- **Branch:** all work lands on `gameday-test-endpoint`, stacked off `gameday-threads`. Do not branch from or merge to `main`.
- **Ruby 2.6 compatibility.** The dev Mac runs system Ruby 2.6.10; the container runs 3.x. Do not use `filter_map`, `Hash#except`, endless method definitions, or rightward assignment — they pass in production and fail here.
- **`lib/` stays pure.** No Rails, no HTTP, no persistence in `lib/redhawks_schedule/*`. That is what makes those files testable without a Discourse checkout.
- **No ActiveSupport in pure specs.** `be_in` and `in?` are unavailable under `spec/lib/`. Use plain matchers or `satisfy {}`.
- **Local test command:** `~/.gem/ruby/2.6.0/bin/rspec spec/lib` — `rspec` is not on `PATH`. Never run plain `rspec spec/`; `spec/jobs/` requires `rails_helper` and aborts the whole run with a `LoadError`.
- **Container test command:** `sudo -E -u discourse LOAD_PLUGINS=1 bundle exec rspec plugins/discourse-redhawks-schedule/spec/jobs/<file>`
- **The ledger is never written by this feature.** Reading it is required; writing it is a defect.
- **`redhawks_gameday_enabled` must not gate the endpoint.** `redhawks_schedule_enabled` does, via the existing `enabled_site_setting` declaration.

---

### Task 1: Selection in the planner

Adds the two pure functions the controller needs. `thread_sports` exists so the controller can tell "no sport is configured" from "everything is already posted" without parsing site-setting rows itself — `normalize` must not have a second implementation.

`next_test_action` returns an **action hash in the same shape `plan` returns** (`:kind`, `:key`, `:category_id`, `:event`) rather than a bare event, so the controller's posting code mirrors `PostRedhawksGameday#post` exactly.

**Files:**
- Modify: `lib/redhawks_schedule/gameday_planner.rb`
- Test: `spec/lib/gameday_planner_spec.rb`

**Interfaces:**
- Consumes: `RedhawksSchedule::GamedayPlanner.normalize(row)` (existing, returns `{sport:, mode:, category_id:, days_before:, digest_day:}`)
- Produces:
  - `GamedayPlanner.thread_sports(config)` → `Hash` of `sport String => category_id Integer`, containing only rows with `mode == "thread"` and a non-nil category. Empty hash when none.
  - `GamedayPlanner.next_test_action(events:, config:, ledger:)` → `{kind: :thread, key: String, category_id: Integer, event: Hash}` or `nil`.

- [ ] **Step 1: Write the failing tests**

Append inside the top-level `RSpec.describe RedhawksSchedule::GamedayPlanner do` block in `spec/lib/gameday_planner_spec.rb`, after the existing `describe "digest mode"` block:

```ruby
  describe ".thread_sports" do
    it "maps thread-mode sports to their category" do
      config = [{ sport: "Football", mode: "thread", category: [7], days_before: 5 }]
      expect(described_class.thread_sports(config)).to eq({ "Football" => 7 })
    end

    it "excludes digest and off rows" do
      config = [
        { sport: "Field Hockey", mode: "digest", category: [9], digest_day: "Monday" },
        { sport: "Soccer", mode: "off", category: [11] },
      ]
      expect(described_class.thread_sports(config)).to eq({})
    end

    it "excludes a thread row with no category" do
      config = [{ sport: "Football", mode: "thread", category: nil, days_before: 5 }]
      expect(described_class.thread_sports(config)).to eq({})
    end

    it "accepts string keys, as the site setting supplies them" do
      config = [{ "sport" => "Football", "mode" => "thread", "category" => [7] }]
      expect(described_class.thread_sports(config)).to eq({ "Football" => 7 })
    end
  end

  describe ".next_test_action" do
    let(:config) do
      [{ sport: "Football", mode: "thread", category: [7], days_before: 5 }]
    end

    def next_test(events, cfg = config, ledger = {})
      described_class.next_test_action(events: events, config: cfg, ledger: ledger)
    end

    it "returns a thread action for the next configured event" do
      action = next_test([event])

      expect(action[:kind]).to eq(:thread)
      expect(action[:key]).to eq("gameday:game:20845")
      expect(action[:category_id]).to eq(7)
      expect(action[:event][:opponent]).to eq("Ohio")
    end

    # The stored list is already upcoming-filtered and sorted by
    # [start_utc, sport] at fetch time, so "next" is "first match".
    it "takes the first match in stored order without re-sorting" do
      later = event(id: "30002", start_utc: Time.utc(2026, 9, 12, 17))
      sooner = event(id: "30001", start_utc: Time.utc(2026, 9, 5, 17))

      expect(next_test([later, sooner])[:event][:id]).to eq("30002")
    end

    it "ignores the days_before window entirely" do
      far = event(start_utc: Time.utc(2026, 12, 25, 17))
      expect(next_test([far])[:event][:id]).to eq("20845")
    end

    it "skips a game already in the ledger and takes the one after" do
      ledger = { "gameday:game:20845" => 991 }
      second = event(id: "20846", opponent: "Toledo")

      expect(next_test([event, second], config, ledger)[:event][:id]).to eq("20846")
    end

    it "returns nil when every candidate is in the ledger" do
      ledger = { "gameday:game:20845" => 991 }
      expect(next_test([event], config, ledger)).to be_nil
    end

    it "returns nil when no sport is configured for threads" do
      digest_only = [{ sport: "Football", mode: "digest", category: [9], digest_day: "Monday" }]
      expect(next_test([event], digest_only)).to be_nil
    end

    it "ignores events for unconfigured sports" do
      expect(next_test([event(sport: "Men's Golf")])).to be_nil
    end

    it "skips an event carrying no id, since it cannot be keyed" do
      expect(next_test([event(id: nil), event(id: "20846")])[:event][:id]).to eq("20846")
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/lib/gameday_planner_spec.rb`
Expected: FAIL with `NoMethodError: undefined method 'thread_sports'` (and the same for `next_test_action`).

- [ ] **Step 3: Write the implementation**

In `lib/redhawks_schedule/gameday_planner.rb`, add both functions after `digest_action` and before `normalize`:

```ruby
    # The sports the test endpoint is allowed to post for, mapped to where.
    # Extracted so the controller can distinguish "nothing configured" from
    # "nothing left to post" without re-implementing `normalize`.
    def thread_sports(config)
      config.each_with_object({}) do |row, map|
        normalized = normalize(row)
        next unless normalized[:mode] == "thread"
        next if normalized[:category_id].nil?

        map[normalized[:sport]] = normalized[:category_id]
      end
    end

    # The one topic the test endpoint would post right now. Deliberately
    # ignores `days_before` -- waiting for the window is what the endpoint
    # exists to avoid. Takes no `now`: the stored list arrives already
    # upcoming-filtered and sorted by [start_utc, sport], so the first match
    # is the next event.
    def next_test_action(events:, config:, ledger:)
      categories = thread_sports(config)
      return nil if categories.empty?

      event =
        events.find do |e|
          next false if e[:id].nil?
          next false unless categories.key?(e[:sport])

          !ledger.key?("gameday:game:#{e[:id]}")
        end
      return nil if event.nil?

      {
        kind: :thread,
        key: "gameday:game:#{event[:id]}",
        category_id: categories[event[:sport]],
        event: event,
      }
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/lib`
Expected: PASS — 90 existing examples plus 12 new, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/redhawks_schedule/gameday_planner.rb spec/lib/gameday_planner_spec.rb
git commit -m "Select the next unposted thread event for the test endpoint"
```

---

### Task 2: Share the stored-event deserializer

The controller needs the exact JSON round-trip handling `PostRedhawksGameday#deserialize` already does — string keys back to symbols, ISO strings back to `Time`. Two copies of that would drift silently and produce a controller that works on `broadcast` and breaks on `start_utc`. Extract it before writing the second caller.

It goes in `lib/` as a pure function taking the already-read payload, so the `lib/`-is-pure rule holds and it gets a Mac-runnable spec. Each caller keeps its own one-line `PluginStore.get`.

**Files:**
- Create: `lib/redhawks_schedule/stored_events.rb`
- Modify: `plugin.rb:23-26` (require block), `app/jobs/scheduled/post_redhawks_gameday.rb:75-97`
- Test: `spec/lib/stored_events_spec.rb`

**Interfaces:**
- Produces: `RedhawksSchedule::StoredEvents.deserialize(payload)` → `Array` of event hashes with symbol keys, `:start_utc`/`:end_utc` as `Time`, and `:broadcast` a symbol-keyed hash. Returns `[]` for `nil`, a payload with no `"events"`, or an empty list.

- [ ] **Step 1: Write the failing test**

Create `spec/lib/stored_events_spec.rb`:

```ruby
# frozen_string_literal: true

require "time"
require_relative "../../lib/redhawks_schedule/stored_events"

RSpec.describe RedhawksSchedule::StoredEvents do
  let(:payload) do
    {
      "generated_at" => "2026-09-01T12:00:00Z",
      "events" => [
        {
          "id" => "20845",
          "sport" => "Football",
          "opponent" => "Ohio",
          "start_utc" => "2026-09-05T17:00:00Z",
          "end_utc" => "2026-09-05T20:00:00Z",
          "time_known" => true,
          "broadcast" => { "tv" => "ESPN" },
        },
      ],
    }
  end

  it "returns symbol-keyed events" do
    event = described_class.deserialize(payload).first
    expect(event[:sport]).to eq("Football")
    expect(event[:id]).to eq("20845")
  end

  it "revives the times as Time objects" do
    event = described_class.deserialize(payload).first
    expect(event[:start_utc]).to eq(Time.utc(2026, 9, 5, 17))
    expect(event[:end_utc]).to eq(Time.utc(2026, 9, 5, 20))
  end

  it "symbol-keys the nested broadcast hash" do
    expect(described_class.deserialize(payload).first[:broadcast]).to eq({ tv: "ESPN" })
  end

  it "supplies an empty broadcast when the feed carried none" do
    payload["events"].first.delete("broadcast")
    expect(described_class.deserialize(payload).first[:broadcast]).to eq({})
  end

  it "returns an empty list for a nil payload" do
    expect(described_class.deserialize(nil)).to eq([])
  end

  it "returns an empty list for a payload carrying no events key" do
    expect(described_class.deserialize({ "generated_at" => "2026-09-01T12:00:00Z" })).to eq([])
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/lib/stored_events_spec.rb`
Expected: FAIL with `LoadError` — cannot load `../../lib/redhawks_schedule/stored_events`.

- [ ] **Step 3: Write the implementation**

Create `lib/redhawks_schedule/stored_events.rb`:

```ruby
# frozen_string_literal: true

require "time"

module RedhawksSchedule
  # PluginStore round-trips through JSON, so stored events come back with
  # string keys and times as strings, while the planner and composer expect
  # symbol keys and real Times. Pure, and shared: a second copy of this in
  # the controller would drift from the job's copy one field at a time.
  module StoredEvents
    module_function

    def deserialize(payload)
      return [] if payload.nil?

      (payload["events"] || payload[:events] || []).map { |row| revive(row) }
    end

    def revive(row)
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

- [ ] **Step 4: Run the test to verify it passes**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/lib/stored_events_spec.rb`
Expected: PASS — 6 examples, 0 failures.

- [ ] **Step 5: Require the new file from plugin.rb**

In `plugin.rb`, add to the existing top-level require block (currently lines 23-26), after the `parser` require:

```ruby
require_relative "lib/redhawks_schedule/stored_events"
```

- [ ] **Step 6: Delete the job's private copy**

In `app/jobs/scheduled/post_redhawks_gameday.rb`, replace both `stored_events` and `deserialize` (the whole block from `def stored_events` to the `end` closing `deserialize`, currently lines 75-97) with:

```ruby
    def stored_events
      ::RedhawksSchedule::StoredEvents.deserialize(
        PluginStore.get(::RedhawksSchedule::PLUGIN_NAME, ::RedhawksSchedule::ALL_EVENTS_KEY),
      )
    end
```

- [ ] **Step 7: Check the job still parses**

Run: `ruby -c app/jobs/scheduled/post_redhawks_gameday.rb`
Expected: `Syntax OK`

The job's behavioural spec is container-only and runs in Task 5. Nothing else on this branch reads those two methods — confirm with:

Run: `grep -rn "deserialize\|stored_events" app/ lib/`
Expected: only the new `StoredEvents` definition and the job's one-line call.

- [ ] **Step 8: Run the full local suite**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/lib`
Expected: PASS, 0 failures.

- [ ] **Step 9: Commit**

```bash
git add lib/redhawks_schedule/stored_events.rb spec/lib/stored_events_spec.rb plugin.rb app/jobs/scheduled/post_redhawks_gameday.rb
git commit -m "Extract the stored-event deserializer so two callers share it"
```

---

### Task 3: Verify the admin controller base class

The spec flags this as unverified, and the repo's convention is to check Discourse API facts against source and write down the finding rather than trust memory — `NOTES-api-verification.md` exists because a plugin outlet was assumed wrong once.

This task requires the live container. Use the `discourse-server-ops` skill for the SSH session.

**Files:**
- Modify: `NOTES-api-verification.md`

**Interfaces:**
- Produces: the confirmed base class and any required `requires_plugin` call, consumed by Task 4's controller.

- [ ] **Step 1: Read the admin controller source in the container**

```bash
cd /var/discourse && ./launcher enter app
cd /var/www/discourse
sed -n '1,60p' app/controllers/admin/admin_controller.rb
```

Expected: a class definition showing which filters enforce admin-only access (look for `requires_login`, `ensure_admin`, and whether `check_xhr` is skipped).

- [ ] **Step 2: Check whether plugin controllers must declare their plugin**

```bash
grep -rn "def requires_plugin" lib/ app/controllers/application_controller.rb
grep -rln "requires_plugin" plugins/*/app/controllers/ | head -5
```

Expected: either a `requires_plugin` class method exists and plugin controllers call it, or no such method exists in this version. Record which.

- [ ] **Step 3: Confirm a non-namespaced route reaches an AdminController subclass**

```bash
grep -rn "AdminController" plugins/*/plugin.rb plugins/*/app/controllers/*.rb | head -10
```

Expected: examples of how other plugins route to admin controllers — specifically whether their routes sit under `/admin/plugins/...` or at the top level. If every example is namespaced, Task 4's route must be namespaced too.

- [ ] **Step 4: Record the findings**

Append a new section to `NOTES-api-verification.md`, matching the existing style — state what was read, quote the relevant source, and say what the plugin will therefore do:

```markdown
## 5. Admin-only controllers — verified <DATE>

Read `app/controllers/admin/admin_controller.rb` in the container.

<quote the class definition and its filters>

**Decision:** `RedhawksGamedayTestController` subclasses `<confirmed base class>`
and <does / does not> call `requires_plugin`. The route <is / is not> namespaced
under `/admin/plugins/`, because <what step 3 showed>.
```

Replace every `<...>` with what the commands actually returned. If the findings contradict the design spec's assumption of a top-level `POST /redhawks-gameday-test.json`, say so explicitly here and carry the corrected path into Task 4 — the route in Task 4 is provisional on this task's result.

- [ ] **Step 5: Commit**

```bash
git add NOTES-api-verification.md
git commit -m "Verify the admin controller base class against container source"
```

---

### Task 4: The endpoint

**Files:**
- Create: `app/controllers/redhawks_gameday_test_controller.rb`
- Modify: `plugin.rb:28-37` (`after_initialize` block — the require list and the route block)
- Test: `spec/requests/redhawks_gameday_test_spec.rb`

**Interfaces:**
- Consumes: `GamedayPlanner.thread_sports(config)`, `GamedayPlanner.next_test_action(events:, config:, ledger:)` (Task 1); `StoredEvents.deserialize(payload)` (Task 2); the base class confirmed in Task 3. Also existing: `GamedayBot.resolve`, `GamedayComposer.thread_title(event)`, `GamedayComposer.thread_body(event)`.
- Produces: `POST /redhawks-gameday-test.json` → 200 with `topic_id`, `topic_url`, `title`, `sport`, `start_utc`, `time_known`, `category_id`; or 422 with `reason`.

**Note on TDD order here:** this task's spec requires `rails_helper` and therefore cannot be run on the dev Mac at all — not to fail, not to pass. Write it first anyway, as the statement of intended behaviour, then verify it in the container in Task 5. Do not skip it on the grounds that it cannot be run locally.

- [ ] **Step 1: Write the request spec**

Create `spec/requests/redhawks_gameday_test_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "gameday test endpoint" do
  fab!(:admin)
  fab!(:user)
  fab!(:category) { Fabricate(:category) }

  let(:events) do
    [
      {
        "id" => "20845",
        "sport" => "Football",
        "opponent" => "Ohio",
        "home_away" => "home",
        "start_utc" => 30.days.from_now.utc.iso8601,
        "end_utc" => 30.days.from_now.utc.iso8601,
        "time_known" => true,
        "location" => "Oxford, Ohio",
        "broadcast" => {},
      },
    ]
  end

  before do
    SiteSetting.redhawks_schedule_enabled = true
    SiteSetting.redhawks_gameday_enabled = false
    PluginStore.set(
      RedhawksSchedule::PLUGIN_NAME,
      RedhawksSchedule::ALL_EVENTS_KEY,
      { "generated_at" => Time.now.utc.iso8601, "events" => events },
    )
    SiteSetting.redhawks_gameday_sports = [
      { "sport" => "Football", "mode" => "thread", "category" => [category.id], "days_before" => 5 },
    ]
  end

  context "as an admin" do
    before { sign_in(admin) }

    it "posts one topic into the configured category" do
      expect { post "/redhawks-gameday-test.json" }.to change { Topic.count }.by(1)

      expect(response.status).to eq(200)
      expect(Topic.last.category_id).to eq(category.id)
      expect(Topic.last.title).to include("Football vs Ohio")
    end

    it "returns the created topic so it can be opened" do
      post "/redhawks-gameday-test.json"
      body = response.parsed_body

      expect(body["topic_id"]).to eq(Topic.last.id)
      expect(body["topic_url"]).to include("/t/")
      expect(body["sport"]).to eq("Football")
      expect(body["time_known"]).to eq(true)
      expect(body["category_id"]).to eq(category.id)
    end

    # The whole point: usable before the switch is thrown.
    it "works while gameday posting is disabled" do
      SiteSetting.redhawks_gameday_enabled = false
      expect { post "/redhawks-gameday-test.json" }.to change { Topic.count }.by(1)
    end

    it "never writes the ledger, so the real job still posts this game" do
      post "/redhawks-gameday-test.json"

      ledger = PluginStore.get(RedhawksSchedule::PLUGIN_NAME, RedhawksSchedule::LEDGER_KEY)
      expect(ledger.to_h).to be_empty
    end

    it "skips a game the real job already posted" do
      PluginStore.set(
        RedhawksSchedule::PLUGIN_NAME,
        RedhawksSchedule::LEDGER_KEY,
        { "gameday:game:20845" => 991 },
      )

      expect { post "/redhawks-gameday-test.json" }.to_not change { Topic.count }
      expect(response.status).to eq(422)
      expect(response.parsed_body["reason"]).to include("already been posted")
    end

    it "explains an empty configuration rather than reporting nothing to post" do
      SiteSetting.redhawks_gameday_sports = []

      post "/redhawks-gameday-test.json"
      expect(response.status).to eq(422)
      expect(response.parsed_body["reason"]).to include("configured")
    end

    it "explains a configuration holding no thread-mode sport" do
      SiteSetting.redhawks_gameday_sports = [
        { "sport" => "Football", "mode" => "digest", "category" => [category.id], "digest_day" => "Monday" },
      ]

      post "/redhawks-gameday-test.json"
      expect(response.status).to eq(422)
      expect(response.parsed_body["reason"]).to include("configured")
    end

    it "explains an empty store rather than raising" do
      PluginStore.remove(RedhawksSchedule::PLUGIN_NAME, RedhawksSchedule::ALL_EVENTS_KEY)

      post "/redhawks-gameday-test.json"
      expect(response.status).to eq(422)
      expect(response.parsed_body["reason"]).to include("no stored events")
    end

    it "explains an unresolvable bot rather than raising" do
      allow(RedhawksSchedule::GamedayBot).to receive(:resolve).and_return(nil)

      expect { post "/redhawks-gameday-test.json" }.to_not change { Topic.count }
      expect(response.status).to eq(422)
      expect(response.parsed_body["reason"]).to include("bot")
    end

    it "is unreachable when the plugin is disabled" do
      SiteSetting.redhawks_schedule_enabled = false

      post "/redhawks-gameday-test.json"
      expect(response.status).to eq(404)
    end
  end

  it "refuses an ordinary user" do
    sign_in(user)

    expect { post "/redhawks-gameday-test.json" }.to_not change { Topic.count }
    expect(response.status).to eq(403)
  end

  it "refuses anonymous callers" do
    expect { post "/redhawks-gameday-test.json" }.to_not change { Topic.count }
    expect(response.status).to eq(403)
  end
end
```

- [ ] **Step 2: Write the controller**

Create `app/controllers/redhawks_gameday_test_controller.rb`. Substitute the base class and any `requires_plugin` line confirmed in Task 3 — the `::Admin::AdminController` below is the assumption, not the verified answer:

```ruby
# frozen_string_literal: true

# Posts one gameday topic on demand, for the next event that production has
# not posted yet. Exists so the composer's rendered output can be seen on the
# real forum before `redhawks_gameday_enabled` is turned on -- which is why
# this deliberately does NOT check that setting.
#
# Unlike the scheduled job, failures surface as 422s instead of being logged
# and swallowed. The job serves a public sidebar, where an upstream outage
# should stay invisible; here a human is waiting on the response and needs to
# know why nothing was posted.
class RedhawksGamedayTestController < ::Admin::AdminController
  def create
    config = SiteSetting.redhawks_gameday_sports
    if config.blank? || ::RedhawksSchedule::GamedayPlanner.thread_sports(config).empty?
      return refuse("no sport is configured for gameday threads")
    end

    events =
      ::RedhawksSchedule::StoredEvents.deserialize(
        PluginStore.get(::RedhawksSchedule::PLUGIN_NAME, ::RedhawksSchedule::ALL_EVENTS_KEY),
      )
    return refuse("no stored events; the schedule feed has not been fetched yet") if events.empty?

    ledger = PluginStore.get(::RedhawksSchedule::PLUGIN_NAME, ::RedhawksSchedule::LEDGER_KEY) || {}

    action =
      ::RedhawksSchedule::GamedayPlanner.next_test_action(
        events: events,
        config: config,
        ledger: ledger,
      )
    return refuse("every upcoming event has already been posted") if action.nil?

    bot = ::RedhawksSchedule::GamedayBot.resolve
    return refuse("the gameday bot could not be resolved; see the logs") if bot.nil?

    event = action[:event]

    post =
      PostCreator.create!(
        bot,
        title: ::RedhawksSchedule::GamedayComposer.thread_title(event),
        raw: ::RedhawksSchedule::GamedayComposer.thread_body(event),
        category: action[:category_id],
        # Swoop Bot is an ordinary user, subject to new-user rate limits and
        # post validations that core's bots are exempt from.
        skip_validations: true,
      )

    # The ledger is READ above and never written. Writing it would silently
    # turn this test into the real gameday thread, with no second chance at a
    # bad title.
    render json: {
             topic_id: post.topic_id,
             topic_url: "#{Discourse.base_url}#{post.topic.relative_url}",
             title: post.topic.title,
             sport: event[:sport],
             start_utc: event[:start_utc].iso8601,
             time_known: event[:time_known],
             category_id: action[:category_id],
           }
  rescue StandardError => e
    Rails.logger.warn("[redhawks-schedule] gameday test failed: #{e.class}: #{e.message}")
    refuse("#{e.class}: #{e.message}")
  end

  private

  def refuse(reason)
    render json: { reason: reason }, status: 422
  end
end
```

- [ ] **Step 3: Require and route it**

In `plugin.rb`, inside `after_initialize`, add the require after the existing controller require:

```ruby
  require_relative "app/controllers/redhawks_gameday_test_controller"
```

and add the route inside the existing `Discourse::Application.routes.append do` block, below the `get` line:

```ruby
    post "/redhawks-gameday-test" => "redhawks_gameday_test#create", :format => :json
```

If Task 3 found that admin routes must be namespaced, use the namespaced path it recorded instead, and update the paths in the Step 1 spec to match.

- [ ] **Step 4: Check both files parse**

Run: `ruby -c app/controllers/redhawks_gameday_test_controller.rb && ruby -c plugin.rb`
Expected: `Syntax OK` twice.

- [ ] **Step 5: Confirm the local suite is still green**

Run: `~/.gem/ruby/2.6.0/bin/rspec spec/lib`
Expected: PASS, 0 failures. (This proves nothing about the controller — it confirms Tasks 1 and 2 were not disturbed.)

- [ ] **Step 6: Commit**

```bash
git add app/controllers/redhawks_gameday_test_controller.rb plugin.rb spec/requests/redhawks_gameday_test_spec.rb
git commit -m "Add an admin endpoint that posts the next gameday thread on demand"
```

---

### Task 5: Deploy, verify in the container, document

Nothing before this point has actually been run against Rails. This task is where the request spec first executes.

Use the `discourse-server-ops` skill for the SSH session. Deploying this plugin requires a container rebuild with real downtime, so expect several minutes with the site down.

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Push the branch**

```bash
git push -u origin gameday-test-endpoint
```

- [ ] **Step 2: Point the container at this branch and rebuild**

In `/var/discourse/containers/app.yml`, the plugin's clone line needs this branch rather than `main` for the duration of testing. Add `--branch gameday-test-endpoint` to its `git clone` line, then:

```bash
cd /var/discourse && ./launcher rebuild app
```

Expected: the site returns. If it does not, remove this plugin's clone line from `containers/app.yml` and rebuild again — that restores service immediately. Debug afterwards, not during.

- [ ] **Step 3: Run the new request spec**

```bash
cd /var/discourse && ./launcher enter app
cd /var/www/discourse
sudo -E -u discourse LOAD_PLUGINS=1 bundle exec rspec plugins/discourse-redhawks-schedule/spec/requests/redhawks_gameday_test_spec.rb
```

Expected: 12 examples, 0 failures. Fix whatever fails — in particular the base class, route path, and the 403-vs-404 expectations for unauthorised callers, which depend on Discourse's admin filter behaviour and are the most likely to need adjusting to what it actually does.

- [ ] **Step 4: Run the job spec, to prove Task 2's extraction did not break it**

```bash
sudo -E -u discourse LOAD_PLUGINS=1 bundle exec rspec plugins/discourse-redhawks-schedule/spec/jobs/post_redhawks_gameday_spec.rb
```

Expected: 6 examples, 0 failures.

- [ ] **Step 5: Smoke-test against the live site**

From a machine logged in as an admin, with `redhawks_gameday_enabled` still false and at least one sport configured in `thread` mode:

```bash
curl -X POST https://miamihawktalk.fans/redhawks-gameday-test.json \
  -H "Api-Key: $DISCOURSE_API_KEY" -H "Api-Username: <your admin username>"
```

Expected: 200 with a `topic_url`. Open it and check the things this endpoint exists to check — the title, the broadcast badges, the embedded player if the event carries one, and the TBA wording if the event has no announced time.

- [ ] **Step 6: Confirm the ledger is untouched**

```bash
sudo -E -u discourse bundle exec rails runner 'puts PluginStore.get("discourse-redhawks-schedule", "gameday_ledger").inspect'
```

Expected: `nil` or `{}`. Anything containing the game just posted is a defect in Task 4 — the endpoint must never write the ledger.

- [ ] **Step 7: Delete the test topic**

Delete it through the admin UI. It is in a real category by design, and nothing cleans it up automatically.

- [ ] **Step 8: Document the endpoint**

In `CLAUDE.md`, add to the "Architecture" list, after the `post_redhawks_gameday.rb` bullet:

```markdown
- **`app/controllers/redhawks_gameday_test_controller.rb`** — admin-only
  `POST /redhawks-gameday-test.json`. Posts one gameday topic for the next
  event production has not covered yet, into its real category, so the
  composer's output can be seen before `redhawks_gameday_enabled` is turned
  on. It **reads the ledger and never writes it** — so enabling gameday later
  posts that same game again, and the test topic is deleted by hand.
```

Also update the "Tests" section, which currently says there are four pure spec files and a fifth Rails-dependent one: there are now five pure files (`stored_events_spec.rb` joins them) and two container-only ones (`spec/requests/redhawks_gameday_test_spec.rb` joins `spec/jobs/`). Correct the example counts to what Steps 3 and 4 actually printed.

- [ ] **Step 9: Commit and push**

```bash
git add CLAUDE.md
git commit -m "Document the gameday test endpoint"
git push
```

- [ ] **Step 10: Restore the container's branch**

Once the branch merges, revert `containers/app.yml` to cloning the default branch and rebuild. Leaving the container pinned to a feature branch is how a plugin quietly stops receiving changes.

---

## Notes for the reviewer

- **Task 3 gates Task 4.** The controller's base class and route path are provisional until the container says otherwise. A Task 4 that ignores a contradicting Task 3 finding should be rejected.
- **Nothing is genuinely verified until Task 5.** Tasks 1 and 2 have real green tests; Tasks 3 and 4 produce code that has never executed. Do not treat a clean `ruby -c` as passing tests.
- **The one invariant worth re-reading the diff for:** no `PluginStore.set` call anywhere near `LEDGER_KEY` in the new controller.
