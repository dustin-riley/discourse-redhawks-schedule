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
