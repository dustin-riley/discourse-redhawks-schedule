# frozen_string_literal: true

require_relative "../../lib/redhawks_schedule/recruit_parser"

RSpec.describe RedhawksSchedule::RecruitParser do
  def fixture(name)
    File.read(File.expand_path("../fixtures/#{name}.html", __dir__))
  end

  let(:hs) { described_class.parse(fixture("recruit_hs")) }
  let(:enrolled) { described_class.parse(fixture("recruit_enrolled")) }

  it "extracts the recruit's name" do
    expect(hs["name"]).to eq("Kaden Estep")
  end

  it "extracts the enrolled player's name" do
    expect(enrolled["name"]).to eq("William Pressley")
  end

  it "extracts the photo URL" do
    expect(hs["photo"]).to start_with("https://s3media.247sports.com/")
  end

  it "returns nil when the document has no name" do
    expect(described_class.parse("<html><body></body></html>")).to be_nil
  end

  it "returns nil for empty input" do
    expect(described_class.parse("")).to be_nil
  end

  it "extracts position from the metrics list" do
    expect(hs["position"]).to eq("QB")
  end

  it "extracts height and weight from the metrics list" do
    expect(hs["height"]).to eq("6-1.5")
    expect(hs["weight"]).to eq("170")
  end

  it "extracts high school and city from the details list" do
    expect(hs["high_school"]).to eq("Cincinnati Elder")
    expect(hs["city"]).to eq("Cincinnati, OH")
  end

  it "extracts class year for a high school recruit" do
    expect(hs["class_year"]).to eq("2027")
  end

  # The enrolled player's details list has an "Exp" row where a recruit has
  # "Class". Reading by index would return the eligibility range here.
  it "returns no class year for an enrolled player" do
    expect(enrolled["class_year"]).to be_nil
  end

  it "still reads the enrolled player's metrics" do
    expect(enrolled["position"]).to eq("WR")
    expect(enrolled["height"]).to eq("6-1")
  end

  it "extracts the composite rating as an integer" do
    expect(hs["rating"]).to eq(86)
    expect(enrolled["rating"]).to eq(87)
  end

  it "counts filled stars only" do
    expect(hs["stars"]).to eq(3)
    expect(enrolled["stars"]).to eq(3)
  end

  it "extracts position and state ranks with their labels" do
    expect(hs["ranks"]).to eq(
      [{ "label" => "QB", "value" => 67 }, { "label" => "OH", "value" => 52 }],
    )
  end

  it "extracts ranks for the enrolled player" do
    expect(enrolled["ranks"]).to eq(
      [{ "label" => "WR", "value" => 157 }, { "label" => "TN", "value" => 35 }],
    )
  end

  # In every current fixture the plain "247Sports" section happens to come
  # before "247Sports Composite®" in document order, so a parser that just
  # grabbed the first `.rankings-section` would pass every test above for the
  # wrong reason. This fixture reverses that order — composite first, plain
  # second — to prove the selection is driven by the h3.title text, not by
  # position. Under a first-section-wins reading, "rating" would come from
  # the composite's decimal rank-block ("0.8600") and silently return nil
  # (its regex only matches whole numbers), and "ranks" would return the
  # composite's numbers (70/50) instead of the plain ones (67/52).
  it "selects the plain 247Sports section by title even when it is not first in document order" do
    reversed_order_html = <<~HTML
      <html><body>
        <h1 class="name">Reversed Order</h1>
        <section class="rankings-section">
          <h3 class="title">247Sports Composite&reg;</h3>
          <div class="rank-block">0.8600</div>
          <ul class="ranks-list">
            <li><b>QB</b><strong>70</strong></li>
            <li><b>OH</b><strong>50</strong></li>
          </ul>
        </section>
        <section class="rankings-section">
          <h3 class="title">247Sports</h3>
          <div class="stars-block">
            <span class="icon-starsolid yellow"></span>
            <span class="icon-starsolid yellow"></span>
            <span class="icon-starsolid yellow"></span>
            <span class="icon-starsolid lightgrey"></span>
            <span class="icon-starsolid lightgrey"></span>
          </div>
          <div class="rank-block">86</div>
          <ul class="ranks-list">
            <li><b>QB</b><strong>67</strong></li>
            <li><b>OH</b><strong>52</strong></li>
          </ul>
        </section>
      </body></html>
    HTML

    parsed = described_class.parse(reversed_order_html)

    expect(parsed["rating"]).to eq(86)
    expect(parsed["stars"]).to eq(3)
    expect(parsed["ranks"]).to eq(
      [{ "label" => "QB", "value" => 67 }, { "label" => "OH", "value" => 52 }],
    )
  end

  # An absent rating and a zero rating mean different things; the card omits
  # the whole cluster rather than rendering "0" or "NR".
  it "returns nil rating and stars when the section is absent" do
    parsed = described_class.parse("<html><body><h1 class='name'>No Rank</h1></body></html>")
    expect(parsed["rating"]).to be_nil
    expect(parsed["stars"]).to be_nil
    expect(parsed["ranks"]).to eq([])
  end

  it "extracts every offer with team and status" do
    teams = hs["offers"].map { |o| o["team"] }
    expect(teams).to include("Miami (OH)", "Kent State", "Toledo", "Gardner-Webb")
  end

  it "marks the committed school" do
    miami = hs["offers"].find { |o| o["team"] == "Miami (OH)" }
    expect(miami["status"]).to eq("committed")
    expect(miami["offered"]).to eq(true)
  end

  # 247 marks a plain offer's interest-level with title="none" — an absence,
  # not a status word — so the parser normalizes it to nil rather than
  # passing through the string "none", which would otherwise render as a
  # status chip reading "None" next to a school that has, in fact, offered.
  it "normalizes a plain offer's status to nil, not the string \"none\"" do
    toledo = hs["offers"].find { |o| o["team"] == "Toledo" }
    expect(toledo["offered"]).to eq(true)
    expect(toledo["status"]).to be_nil
  end

  # nil, not [] — the card omits the panel entirely rather than rendering an
  # empty bordered box.
  it "returns nil offers when the page has no offers section" do
    expect(enrolled["offers"]).to be_nil
  end
end
