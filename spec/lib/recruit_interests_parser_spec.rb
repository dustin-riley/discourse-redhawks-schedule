# frozen_string_literal: true

require_relative "../../lib/redhawks_schedule/recruit_interests_parser"

RSpec.describe RedhawksSchedule::RecruitInterestsParser do
  def fixture(name)
    File.read(File.expand_path("../fixtures/#{name}.html", __dir__))
  end

  let(:rows) { described_class.parse(fixture("recruit_interests")) }

  it "extracts every school on the page" do
    teams = rows.map { |r| r["team"] }
    expect(teams).to include("Miami (OH)", "Kent State", "Toledo", "Gardner-Webb")
  end

  it "does not mistake depth-chart players for schools" do
    teams = rows.map { |r| r["team"] }
    expect(teams).not_to include("D. Finn", "T. Gotkowski")
    expect(rows.length).to eq(4)
  end

  # The interests page writes "Status: Committed" where the player page
  # writes title="committed". Both must land on the same lowercase token,
  # because committed_to and the card's red state key off that exact value.
  it "normalizes the committed status to the player page's token" do
    miami = rows.find { |r| r["team"] == "Miami (OH)" }
    expect(miami["status"]).to eq("committed")
    expect(miami["offered"]).to eq(true)
  end

  # "None" is an absence, not a status word — passing it through would render
  # a chip reading "None" next to a school that has, in fact, offered.
  it "normalizes a plain school's status to nil, not the string \"None\"" do
    kent = rows.find { |r| r["team"] == "Kent State" }
    expect(kent["status"]).to be_nil
    expect(kent["offered"]).to eq(true)
  end

  it "reads the offer flag as a boolean" do
    # `be_in` needs ActiveSupport's Object#in?, unavailable in this plain
    # Ruby gem environment — assert membership directly instead.
    expect(rows.map { |r| r["offered"] }.uniq).to all(satisfy { |v| [true, false].include?(v) })
  end

  # All four rows in the fixture read "Offer: Yes", so the spec above never
  # exercises the false branch of offered? — a parser that always returned
  # true would pass it. These use small inline HTML, mirroring the real
  # markup's leading space before the nested "Offer:" heading span (the
  # flattened text is " Offer:  Yes  ", not a clean "Offer: Yes"), to prove
  # both the nil-node short circuit and the "yes" comparison actually gate
  # the result.
  it "reads an explicit \"Offer: No\" as false" do
    html = <<~HTML
      <li><div class="left"><div class="first_blk"><a>Case Western</a></div>
      <div class="secondary_blk"><span class="offer"> <span class="heading">Offer:</span>  No  </span></div></div></li>
    HTML
    row = described_class.parse(html).first
    expect(row["offered"]).to eq(false)
  end

  it "reads a row with no offer span at all as false" do
    html = <<~HTML
      <li><div class="left"><div class="first_blk"><a>Case Western</a></div>
      <div class="secondary_blk"><span class="roster"> <span class="heading">Roster Outlook:</span> None </span></div></div></li>
    HTML
    row = described_class.parse(html).first
    expect(row["offered"]).to eq(false)
  end

  it "reads an explicit \"Offer: Yes\" as true" do
    html = <<~HTML
      <li><div class="left"><div class="first_blk"><a>Case Western</a></div>
      <div class="secondary_blk"><span class="offer"> <span class="heading">Offer:</span>  Yes  </span></div></div></li>
    HTML
    row = described_class.parse(html).first
    expect(row["offered"]).to eq(true)
  end

  it "returns nil when the page has no school rows" do
    expect(described_class.parse("<html><body></body></html>")).to be_nil
  end

  it "returns nil for empty or non-string input" do
    expect(described_class.parse("")).to be_nil
    expect(described_class.parse(nil)).to be_nil
  end

  it "skips a row whose team name is missing" do
    html = <<~HTML
      <li><div class="left"><div class="first_blk"><a></a></div>
      <div class="secondary_blk"><span class="offer">Offer: Yes</span></div></div></li>
    HTML
    expect(described_class.parse(html)).to be_nil
  end
end
