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
end
