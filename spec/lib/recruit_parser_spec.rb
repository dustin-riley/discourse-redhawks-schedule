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
end
