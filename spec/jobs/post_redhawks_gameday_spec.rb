# frozen_string_literal: true

require "rails_helper"

RSpec.describe Jobs::PostRedhawksGameday do
  fab!(:category) { Fabricate(:category) }

  let(:events) do
    [
      {
        "id" => "20845",
        "sport" => "Football",
        "opponent" => "Ohio",
        "home_away" => "home",
        "start_utc" => 2.days.from_now.utc.iso8601,
        "end_utc" => 2.days.from_now.utc.iso8601,
        "time_known" => true,
        "location" => "Oxford, Ohio",
        "broadcast" => {},
      },
    ]
  end

  before do
    SiteSetting.redhawks_schedule_enabled = true
    SiteSetting.redhawks_gameday_enabled = true
    PluginStore.set(
      RedhawksSchedule::PLUGIN_NAME,
      RedhawksSchedule::ALL_EVENTS_KEY,
      { "generated_at" => Time.now.utc.iso8601, "events" => events },
    )
    SiteSetting.redhawks_gameday_sports = [
      { "sport" => "Football", "mode" => "thread", "category" => [category.id], "days_before" => 5 },
    ]
  end

  it "creates a topic in the configured category" do
    expect { described_class.new.execute({}) }.to change { Topic.count }.by(1)
    expect(Topic.last.category_id).to eq(category.id)
    expect(Topic.last.title).to include("Football vs Ohio")
  end

  it "posts nothing on a second run" do
    described_class.new.execute({})
    expect { described_class.new.execute({}) }.to_not change { Topic.count }
  end

  it "posts nothing when disabled" do
    SiteSetting.redhawks_gameday_enabled = false
    expect { described_class.new.execute({}) }.to_not change { Topic.count }
  end

  it "creates the bot exactly once across two runs" do
    described_class.new.execute({})
    bot_id = PluginStore.get(RedhawksSchedule::PLUGIN_NAME, RedhawksSchedule::BOT_ID_KEY)
    expect(bot_id).to be_present

    PluginStore.set(RedhawksSchedule::PLUGIN_NAME, RedhawksSchedule::LEDGER_KEY, {})
    expect { described_class.new.execute({}) }.to_not change { User.count }
  end

  it "keeps posting as the same account after a rename" do
    described_class.new.execute({})
    bot = Topic.last.user
    bot.update!(username: "renamed_bot")

    PluginStore.set(RedhawksSchedule::PLUGIN_NAME, RedhawksSchedule::LEDGER_KEY, {})
    described_class.new.execute({})

    expect(Topic.last.user_id).to eq(bot.id)
  end

  it "suppresses the bot's own email notifications" do
    described_class.new.execute({})
    bot_id = PluginStore.get(RedhawksSchedule::PLUGIN_NAME, RedhawksSchedule::BOT_ID_KEY)
    bot = User.find(bot_id)

    expect(bot.user_option.email_level).to eq(UserOption.email_level_types[:never])
    expect(bot.user_option.email_messages_level).to eq(UserOption.email_level_types[:never])
  end
end
