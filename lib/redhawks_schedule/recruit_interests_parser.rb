# frozen_string_literal: true

require "nokogiri"

module RedhawksSchedule
  # Parses the /recruitment/<slug>/recruitinterests/ page.
  #
  # Deliberately separate from RecruitParser: this page shares no markup with
  # the player page. There is no `college-comp__*` class anywhere on it — a
  # school row is a `div.first_blk` (team name and status) beside a
  # `div.secondary_blk` (visit, offer, roster). Folding both shapes into one
  # parser would mean every selector needing a comment about which page it
  # applies to.
  #
  # Emits the same row shape RecruitParser#offers does, so the component
  # consumes one contract regardless of which page a list came from.
  module RecruitInterestsParser
    module_function

    def parse(html)
      return nil unless html.is_a?(String) && !html.empty?

      document = Nokogiri::HTML(html)
      rows =
        document
          .css("li")
          .select { |li| li.at_css("div.first_blk") }
          .map { |li| row_from(li) }
          .compact

      rows.empty? ? nil : rows
    rescue StandardError
      nil
    end

    # Each school's <li> also wraps the college's depth chart, whose entries
    # are themselves <li> elements holding player links. Those have no
    # first_blk, which is what the select above filters on — without it,
    # "D. Finn" would be parsed as a school.
    def row_from(li)
      block = li.at_css("div.first_blk")
      team = team_name(block)
      return nil if team.nil?

      { "team" => team, "status" => status(block), "offered" => offered?(li) }
    end

    def team_name(block)
      link = block.at_css("a")
      return nil if link.nil?

      text = link.text.to_s.strip
      text.empty? ? nil : text
    end

    # "Status: Committed" on this page; title="committed" on the player page.
    # Both must reduce to "committed" or the two sources disagree about the
    # single fact the card's entire visual state depends on.
    #
    # The wrapping span is always class="status", but its contents differ: a
    # committed row nests a "Status: Committed" span plus a separate <a> for
    # the "(2/1/2026)" commit date, while an uncommitted row nests a single
    # span.none reading "None". node.text flattens both to one string.
    def status(block)
      node = block.at_css("span.status")
      return nil if node.nil?

      text = node.text.to_s.strip.sub(/\AStatus:\s*/i, "")
      # Drop a trailing "(2/1/2026)" commit date that lands in the same
      # flattened string, since it comes from a sibling <a> inside the span.
      text = text.sub(/\s*\([^)]*\)\s*\z/, "").strip.downcase
      return nil if text.empty? || text == "none"

      text
    end

    def offered?(li)
      node = li.at_css("div.secondary_blk span.offer")
      return false if node.nil?

      # Must strip before stripping the "Offer:" prefix: the offer span's
      # own text node starts with a leading space before the nested
      # span.heading that holds the literal word "Offer:", so /\AOffer:/
      # cannot match until that space is gone.
      node.text.to_s.strip.sub(/\AOffer:\s*/i, "").strip.casecmp("yes").zero?
    end
  end
end
