# frozen_string_literal: true

require "nokogiri"

module RedhawksSchedule
  # Parses a 247Sports player page into a flat hash.
  #
  # Deliberately free of Rails, HTTP and persistence so it can be unit tested
  # against saved fixtures without a Discourse environment — the same rule the
  # RSS Parser follows.
  #
  # Every field is independently optional. This is a scraper against a third
  # party's markup: one missing selector must cost one field, never the whole
  # card. Only the name is required, because a card with no name is not a card.
  class RecruitParser
    def self.parse(html)
      new(html).parse
    end

    def initialize(html)
      @html = html.to_s
    end

    def parse
      name = extract_name
      return nil if name.nil?

      metrics = labeled_list("ul.metrics-list")
      details = labeled_list("ul.details")

      {
        "name" => name,
        "photo" => meta("og:image"),
        "position" => metrics["Pos"],
        "height" => metrics["Height"],
        "weight" => metrics["Weight"],
        "high_school" => details["High School"],
        "city" => details["City"],
        "class_year" => details["Class"],
      }
    end

    private

    def document
      @document ||= Nokogiri::HTML(@html)
    end

    def extract_name
      presence(text_at("h1.name")) || presence(meta_name_fallback)
    end

    # og:title is "Kaden Estep, Cincinnati Elder , Quarterback" — the name is
    # everything before the first comma.
    def meta_name_fallback
      meta("og:title").to_s.split(",").first
    end

    def meta(property)
      node = document.at_css(%(meta[property="#{property}"]))
      node ? node["content"].to_s.strip : nil
    end

    def text_at(selector)
      node = document.at_css(selector)
      node ? node.text.strip : nil
    end

    def presence(value)
      return nil if value.nil?
      stripped = value.strip
      stripped.empty? ? nil : stripped
    end

    # Builds { "Label" => "Value" } from <li><span>Label</span><span>Value</span></li>.
    # Keyed by label because the row set differs between page types.
    def labeled_list(selector)
      document.css("#{selector} li").each_with_object({}) do |li, out|
        spans = li.css("span")
        next if spans.length < 2

        label = spans[0].text.strip
        value = spans[1].text.strip
        out[label] = value unless label.empty? || value.empty?
      end
    end
  end
end
