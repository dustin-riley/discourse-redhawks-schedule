# frozen_string_literal: true

require_relative "../../lib/redhawks_schedule/recruit_assembler"

RSpec.describe RedhawksSchedule::RecruitAssembler do
  let(:player_offers) do
    [
      { "team" => "Miami (OH)", "status" => "committed", "offered" => true },
      { "team" => "Toledo", "status" => nil, "offered" => true },
    ]
  end

  let(:recruit) { { "name" => "Kaden Estep", "offers" => player_offers } }

  let(:interest_rows) do
    [
      { "team" => "Miami (OH)", "status" => "committed", "offered" => true },
      { "team" => "Kent State", "status" => nil, "offered" => true },
      { "team" => "Toledo", "status" => nil, "offered" => true },
      { "team" => "Maryland", "status" => nil, "offered" => false },
    ]
  end

  it "replaces the truncated player-page list with the full one" do
    merged = described_class.merge(recruit, interest_rows)
    expect(merged["offers"].length).to eq(4)
    expect(merged["offers"].map { |o| o["team"] }).to include("Maryland")
  end

  it "counts only schools that actually offered" do
    merged = described_class.merge(recruit, interest_rows)
    expect(merged["offer_count"]).to eq(3)
  end

  it "hoists the committed school to the top level" do
    merged = described_class.merge(recruit, interest_rows)
    expect(merged["committed_to"]).to eq("Miami (OH)")
  end

  it "matches the interests page's capitalised status" do
    rows = interest_rows.map { |r| r["status"].nil? ? r : r.merge("status" => "Committed") }
    expect(described_class.merge(recruit, rows)["committed_to"]).to eq("Miami (OH)")
  end

  it "reports no commitment when nobody is committed" do
    rows = interest_rows.map { |r| r.merge("status" => nil) }
    expect(described_class.merge(recruit, rows)["committed_to"]).to be_nil
  end

  # Zero is a real answer here: the full list arrived and nobody had offered.
  # That is different from the absent case below, which sets nothing at all.
  it "reports a count of zero when the full list has no offers" do
    rows = interest_rows.map { |r| r.merge("offered" => false) }
    merged = described_class.merge(recruit, rows)
    expect(merged["offer_count"]).to eq(0)
    expect(merged.key?("offer_count")).to be(true)
  end

  # A failed second fetch is a partial success, not a failure: the reader
  # keeps the card built from the five rows the player page already gave us.
  it "falls back to the player-page offers when interests are absent" do
    merged = described_class.merge(recruit, nil)
    expect(merged["offers"].length).to eq(2)
  end

  # Omitted, not zero: "0 offers" is a claim, and we do not have the data to
  # make it when the full list never arrived.
  it "omits offer_count when interests are absent" do
    merged = described_class.merge(recruit, nil)
    expect(merged["offer_count"]).to be_nil
    expect(merged.key?("offer_count")).to be(false)
  end

  it "treats an empty interests list as absent rather than as zero offers" do
    merged = described_class.merge(recruit, [])
    expect(merged["offers"].length).to eq(2)
    expect(merged.key?("offer_count")).to be(false)
  end

  it "treats a non-array interests value as absent" do
    merged = described_class.merge(recruit, "nope")
    expect(merged["offers"].length).to eq(2)
    expect(merged.key?("offer_count")).to be(false)
  end

  it "still finds a commitment in the player-page offers on fallback" do
    expect(described_class.merge(recruit, nil)["committed_to"]).to eq("Miami (OH)")
  end

  it "handles a recruit with no offers section at all" do
    merged = described_class.merge({ "name" => "X", "offers" => nil }, nil)
    expect(merged["offers"]).to be_nil
    expect(merged["offer_count"]).to be_nil
    expect(merged["committed_to"]).to be_nil
  end

  # A nil offers list plus a good interests page is the ordinary "the player
  # page's offers block was missing but the interests page loaded" case: the
  # full list should still land.
  it "fills in offers for a recruit whose offers were nil" do
    merged = described_class.merge({ "name" => "X", "offers" => nil }, interest_rows)
    expect(merged["offers"].length).to eq(4)
    expect(merged["offer_count"]).to eq(3)
    expect(merged["committed_to"]).to eq("Miami (OH)")
  end

  it "survives junk rows inside the interests list" do
    rows = [nil, "junk", { "team" => "Ohio", "status" => nil, "offered" => true }]
    merged = described_class.merge(recruit, rows)
    expect(merged["offer_count"]).to eq(1)
    expect(merged["committed_to"]).to be_nil
  end

  # `status.to_s.downcase` raises ArgumentError for a String tagged UTF-8
  # that carries invalid bytes. merge is called outside the rescue that
  # protects the interests-page fetch, so a raise here would reach
  # fetch_inline's outer rescue and trip the global fetch failure cooldown,
  # taking recruit cards down site-wide rather than just this one row.
  it "does not raise when a status carries invalid UTF-8 bytes, and reports no commitment" do
    bad_status = "\xFF".dup.force_encoding("UTF-8")
    rows = [{ "team" => "Miami (OH)", "status" => bad_status, "offered" => true }]
    expect { described_class.merge(recruit, rows) }.not_to raise_error
    expect(described_class.merge(recruit, rows)["committed_to"]).to be_nil
  end

  it "returns nil for a nil recruit" do
    expect(described_class.merge(nil, interest_rows)).to be_nil
  end

  it "returns a non-hash recruit untouched" do
    expect(described_class.merge("nope", interest_rows)).to eq("nope")
  end

  # The job and the controller both hand it a hash they go on to store, so a
  # mutating merge would silently change what gets persisted.
  it "does not mutate the recruit it was given" do
    original = { "name" => "Kaden Estep", "offers" => player_offers }
    described_class.merge(original, interest_rows)
    expect(original.keys).to eq(%w[name offers])
    expect(original["offers"].length).to eq(2)
  end

  it "does not mutate the interest rows it was given" do
    rows = interest_rows.map { |r| r.dup }
    before = Marshal.dump(rows)
    described_class.merge(recruit, rows)
    expect(Marshal.dump(rows)).to eq(before)
  end
end
