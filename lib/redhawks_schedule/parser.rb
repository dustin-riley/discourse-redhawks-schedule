# frozen_string_literal: true

require "nokogiri"
require "time"

module RedhawksSchedule
  # Parses the SIDEARM Sports RSS calendar into a list of upcoming events.
  #
  # Deliberately free of Rails, HTTP and persistence so it can be unit tested
  # without a Discourse environment.
  class Parser
    NAMESPACES = {
      "ev" => "http://purl.org/rss/1.0/modules/event/",
      "s" => "http://sidearmsports.com/schemas/cal_rss/1.0/",
    }.freeze

    # "8/16 7:00 PM Miami University ..." and also "8/29 Miami University ..."
    # since 59% of items carry no time at all.
    TITLE_PREFIX = %r{\A\s*\d{1,2}/\d{1,2}(?:\s+\d{1,2}:\d{2}\s*[AP]M)?\s+}i
    TEAM_PREFIX = /\AMiami University\s+/i
    SEPARATOR = /\s+(vs|at)\s+/i

    # A date-only event has no time of day, and the feed publishes Eastern
    # calendar dates. Midnight UTC on such a date is 8pm Eastern the PREVIOUS
    # day, so a plain 24-hour window drops the game at 8pm Eastern on the day
    # it is actually played. 30 hours covers the full Eastern day in both EDT
    # and EST, lingering at most ~2 hours past midnight Eastern — much better
    # than hiding a game that has not been played yet.
    DATE_ONLY_GRACE = 30 * 60 * 60
    COLLAPSE_WINDOW = 48 * 60 * 60

    # The description repeats the title, then appends labelled lines delimited
    # by a LITERAL backslash-n — two characters, not a newline.
    DESCRIPTION_DELIMITER = "\\n"
    BROADCAST_LABELS = {
      "streaming video" => :video,
      "tv" => :tv,
      "radio" => :radio,
      "streaming audio" => :audio,
      "tickets" => :tickets,
    }.freeze

    # Only ONE event in the whole feed has ever carried a Streaming Video link,
    # so this pattern generalises from a single sample. A non-match must fall
    # back to a plain link — a wrong iframe is worse than a working link.
    SHOWCASE_LIVE_ID = /\/showcase\?Live=(\d+)/i
    EMBED_TEMPLATE = "https://miamiredhawks.com/showcase/embed.aspx?Live=%s&type=Live"

    def self.parse(xml, now: Time.now.utc)
      new(xml, now: now).parse
    end

    def initialize(xml, now: Time.now.utc)
      @xml = xml.to_s
      @now = now.utc
    end

    # Uncollapsed: one row per calendar item. Gameday threads want each day of
    # a series; the sidebar wants them merged, which is what #parse does.
    def events
      # `.map.compact` rather than `filter_map`: the dev Mac runs system Ruby
      # 2.6, where filter_map does not exist.
      rows = document.xpath("//channel/item").map { |item| build_event(item) }.compact
      upcoming(rows).sort_by { |e| [e[:start_utc], e[:sport]] }
    end

    def parse
      collapse(events)
    end

    private

    def document
      @document ||= Nokogiri::XML(@xml)
    end

    def build_event(item)
      start_raw = text(item, "ev:startdate")
      start_utc = parse_time(start_raw)
      return nil if start_utc.nil?

      sport, home_away, title_opponent = split_title(text(item, "title"))
      return nil if sport.empty?

      {
        id: presence(text(item, "s:gameid")),
        sport: sport,
        opponent: presence(text(item, "s:opponent")) || title_opponent,
        home_away: home_away,
        start_utc: start_utc,
        end_utc: parse_time(text(item, "ev:enddate")) || start_utc,
        time_known: start_raw.include?("T"),
        location: presence(text(item, "ev:location")),
        opponent_logo: presence(text(item, "s:opponentlogo")),
        promo: presence(text(item, "s:gamepromoname")),
        url: presence(text(item, "link")),
        broadcast: broadcast(item),
      }
    end

    def split_title(title)
      rest = title.to_s.strip.sub(TITLE_PREFIX, "").sub(TEAM_PREFIX, "")
      match = SEPARATOR.match(rest)
      return [rest.strip, "home", ""] if match.nil?

      [match.pre_match.strip, match[1].casecmp?("at") ? "away" : "home", match.post_match.strip]
    end

    def upcoming(events)
      events.reject do |event|
        cutoff = event[:time_known] ? event[:start_utc] : event[:start_utc] + DATE_ONLY_GRACE
        cutoff < @now
      end
    end

    # Merges each event into the most recent still-open group for the same
    # matchup. Comparing only against the previous row is wrong: another
    # sport's event routinely sorts between two days of the same tournament,
    # which silently breaks the run. Against the real feed that mistake leaves
    # 13 tournaments and series uncollapsed.
    def collapse(events)
      rows = []
      index = {}

      events.each do |event|
        key = [event[:sport], event[:opponent]]
        at = index[key]

        if at && (event[:start_utc] - rows[at][:end_utc]) <= COLLAPSE_WINDOW
          rows[at][:end_utc] = [rows[at][:end_utc], event[:end_utc]].max
          rows[at][:days] += 1
        else
          rows << event.merge(days: 1)
          index[key] = rows.length - 1
        end
      end

      rows
    end

    def parse_time(raw)
      value = raw.to_s.strip
      return nil if value.empty?
      return nil if value.match?(/\A(TBA|TBD)\z/i)

      value = value.sub(/\.\d+/, "")
      value = "#{value}T00:00:00" unless value.include?("T")
      value = "#{value}Z" unless value.end_with?("Z")
      Time.iso8601(value).utc
    rescue ArgumentError
      nil
    end

    def broadcast(item)
      found = {}

      # The first segment is the title repeated, never a labelled field.
      text(item, "description").split(DESCRIPTION_DELIMITER)[1..-1].to_a.each do |line|
        label, value = line.split(":", 2)
        next if value.nil?

        key = BROADCAST_LABELS[label.strip.downcase]
        next if key.nil?

        value = value.strip
        found[key] = value unless value.empty?
      end

      livestats = presence(text(item, "s:links/s:livestats"))
      found[:livestats] = livestats if livestats

      video = found[:video]
      if video
        match = SHOWCASE_LIVE_ID.match(video)
        found[:video_embed] = format(EMBED_TEMPLATE, match[1]) if match
      end

      found
    end

    def text(node, path)
      found = node.at_xpath(path, NAMESPACES)
      found ? found.text.strip : ""
    end

    def presence(value)
      value.nil? || value.empty? ? nil : value
    end
  end
end
