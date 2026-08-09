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
      expect { post "/admin/plugins/discourse-redhawks-schedule/gameday-test.json" }.to change { Topic.count }.by(1)

      expect(response.status).to eq(200)
      expect(Topic.last.category_id).to eq(category.id)
      expect(Topic.last.title).to include("Football vs Ohio")
    end

    it "returns the created topic so it can be opened" do
      post "/admin/plugins/discourse-redhawks-schedule/gameday-test.json"
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
      expect { post "/admin/plugins/discourse-redhawks-schedule/gameday-test.json" }.to change { Topic.count }.by(1)
    end

    it "never writes the ledger, so the real job still posts this game" do
      post "/admin/plugins/discourse-redhawks-schedule/gameday-test.json"

      ledger = PluginStore.get(RedhawksSchedule::PLUGIN_NAME, RedhawksSchedule::LEDGER_KEY)
      expect(ledger.to_h).to be_empty
    end

    it "skips a game the real job already posted" do
      PluginStore.set(
        RedhawksSchedule::PLUGIN_NAME,
        RedhawksSchedule::LEDGER_KEY,
        { "gameday:game:20845" => 991 },
      )

      expect { post "/admin/plugins/discourse-redhawks-schedule/gameday-test.json" }.to_not change { Topic.count }
      expect(response.status).to eq(422)
      expect(response.parsed_body["reason"]).to include("already been posted")
    end

    it "explains an empty configuration rather than reporting nothing to post" do
      SiteSetting.redhawks_gameday_sports = []

      post "/admin/plugins/discourse-redhawks-schedule/gameday-test.json"
      expect(response.status).to eq(422)
      expect(response.parsed_body["reason"]).to include("configured")
    end

    it "explains a configuration holding no thread-mode sport" do
      SiteSetting.redhawks_gameday_sports = [
        { "sport" => "Football", "mode" => "digest", "category" => [category.id], "digest_day" => "Monday" },
      ]

      post "/admin/plugins/discourse-redhawks-schedule/gameday-test.json"
      expect(response.status).to eq(422)
      expect(response.parsed_body["reason"]).to include("configured")
    end

    it "explains an empty store rather than raising" do
      PluginStore.remove(RedhawksSchedule::PLUGIN_NAME, RedhawksSchedule::ALL_EVENTS_KEY)

      post "/admin/plugins/discourse-redhawks-schedule/gameday-test.json"
      expect(response.status).to eq(422)
      expect(response.parsed_body["reason"]).to include("no stored events")
    end

    it "explains an unresolvable bot rather than raising" do
      allow(RedhawksSchedule::GamedayBot).to receive(:resolve).and_return(nil)

      expect { post "/admin/plugins/discourse-redhawks-schedule/gameday-test.json" }.to_not change { Topic.count }
      expect(response.status).to eq(422)
      expect(response.parsed_body["reason"]).to include("bot")
    end

    it "is unreachable when the plugin is disabled" do
      SiteSetting.redhawks_schedule_enabled = false

      post "/admin/plugins/discourse-redhawks-schedule/gameday-test.json"
      expect(response.status).to eq(404)
    end
  end

  it "refuses an ordinary user" do
    sign_in(user)

    expect { post "/admin/plugins/discourse-redhawks-schedule/gameday-test.json" }.to_not change { Topic.count }
    expect(response.status).to eq(403)
  end

  it "refuses anonymous callers" do
    expect { post "/admin/plugins/discourse-redhawks-schedule/gameday-test.json" }.to_not change { Topic.count }
    expect(response.status).to eq(403)
  end
end
