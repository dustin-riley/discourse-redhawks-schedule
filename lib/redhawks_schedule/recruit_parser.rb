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
        "rating" => rating,
        "stars" => stars,
        "ranks" => ranks,
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

    # A page can carry two `.rankings-section` blocks — the plain "247Sports"
    # rating and the separate "247Sports Composite®" rating — and nothing but
    # `h3.title` text tells them apart; both share every other class. We want
    # the plain one: the composite's rank-block is a decimal ("0.8600") that
    # reads as no rating at all, and its ranks-list holds composite position
    # numbers, not the plain rank/state numbers the sidebar shows elsewhere.
    # Falling back to the first section keeps single-section pages (enrolled
    # players) working without a title to match.
    def rankings_section
      document.css(".rankings-section").find { |s| text_at_node(s, "h3.title") == "247Sports" } ||
        document.at_css(".rankings-section")
    end

    def text_at_node(node, selector)
      child = node.at_css(selector)
      child ? child.text.strip : nil
    end

    def rating
      section = rankings_section
      return nil if section.nil?

      raw = text_at_node(section, ".rank-block").to_s
      raw =~ /\A\d+\z/ ? raw.to_i : nil
    end

    # Filled stars are `.icon-starsolid.yellow`; empty ones are `.lightgrey`
    # and must not be counted. This is the least stable selector in the file —
    # a rating with no stars is a class-name change, not a missing rating.
    def stars
      section = rankings_section
      return nil if section.nil?

      block = section.at_css(".stars-block")
      return nil if block.nil?

      count = block.css("span.icon-starsolid.yellow").length
      count.zero? ? nil : count
    end

    def ranks
      section = rankings_section
      return [] if section.nil?

      section
        .css("ul.ranks-list li")
        .map do |li|
          label = li.at_css("b")
          value = li.at_css("strong")
          next nil if label.nil? || value.nil?

          label_text = label.text.strip
          value_text = value.text.strip
          next nil if label_text.empty? || value_text !~ /\A\d+\z/

          { "label" => label_text, "value" => value_text.to_i }
        end
        .compact
    end
  end
end
