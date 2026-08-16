# frozen_string_literal: true

require "time"
require_relative "eastern"

module RedhawksSchedule
  # Turns events into topic titles and markdown bodies. Pure formatting — it
  # decides how a post reads, never whether it should exist. That split means a
  # copy change cannot break scheduling.
  module GamedayComposer
    IFRAME = '<iframe src="%s" width="100%%" height="420" frameborder="0" allowfullscreen></iframe>'
    SPORT_EMOJI = {
      "Football" => "🏈",
      "Hockey" => "🏒",
      "Ice Hockey" => "🏒",
      "Men's Basketball" => "🏀",
      "Women's Basketball" => "🏀",
      "Men's Soccer" => "⚽",
      "Women's Soccer" => "⚽",
      "Volleyball" => "🏐",
      "Women's Volleyball" => "🏐",
      "Baseball" => "⚾",
      "Softball" => "🥎",
      "Field Hockey" => "🏑",
      "Men's Tennis" => "🎾",
      "Women's Tennis" => "🎾",
      "Men's Golf" => "⛳",
      "Women's Golf" => "⛳",
      "Men's Cross Country" => "🏃",
      "Women's Cross Country" => "🏃",
      "Track & Field, Cross Country" => "🏃",
      "Track & Field" => "🏃",
    }.freeze
    DEFAULT_EMOJI = "🗓️"

    module_function

    def thread_title(event)
      "#{matchup(event)} — #{Eastern.local(event[:start_utc]).strftime('%b %-d')}"
    end

    def thread_body(event)
      lines = ["**#{matchup(event)}**", when_line(event)]
      lines << event[:location] if event[:location]

      broadcast = event[:broadcast] || {}
      stream = stream_block(broadcast)
      lines += ["", stream] if stream

      details = detail_lines(broadcast)
      lines += [""] + details unless details.empty?

      links = link_line(broadcast)
      lines += ["", links] if links

      lines << ""
      lines << "[Game page](#{event[:url]})" if event[:url]

      lines.join("\n").strip
    end

    def digest_title(sport, now)
      "#{sport} — week of #{Eastern.local(now).strftime('%B %-d')}"
    end

    def digest_body(sport, events)
      lines = ["#{sport} games this week:", ""]

      events.each do |event|
        line = "- #{when_line(event)} — #{side(event)} #{event[:opponent]}"
        line += " (#{event[:location]})" if event[:location]

        stats = (event[:broadcast] || {})[:livestats]
        line += " · [Live stats](#{stats})" if stats

        lines << line
      end

      lines.join("\n")
    end

    def matchup(event)
      "#{event[:sport]} #{side(event)} #{event[:opponent]}"
    end

    def sport_emoji(sport)
      SPORT_EMOJI.fetch(sport, DEFAULT_EMOJI)
    end

    def side(event)
      event[:home_away] == "away" ? "at" : "vs"
    end

    def when_line(event)
      local = Eastern.local(event[:start_utc])
      date = local.strftime("%A, %B %-d")
      return "#{date} · Time TBA" unless event[:time_known]

      "#{date} · #{local.strftime('%-I:%M %p')} ET"
    end

    # Three states: framable player, plain link, nothing.
    def stream_block(broadcast)
      return format(IFRAME, broadcast[:video_embed]) if broadcast[:video_embed]
      return "[Watch the stream](#{broadcast[:video]})" if broadcast[:video]

      nil
    end

    def detail_lines(broadcast)
      lines = []
      lines << "**TV:** #{broadcast[:tv]}" if broadcast[:tv]
      lines << "**Radio:** #{broadcast[:radio]}" if broadcast[:radio]
      lines
    end

    def link_line(broadcast)
      links = []
      links << "[Listen live](#{broadcast[:audio]})" if broadcast[:audio]
      links << "[Live stats](#{broadcast[:livestats]})" if broadcast[:livestats]
      links << "[Tickets](#{broadcast[:tickets]})" if broadcast[:tickets]
      return nil if links.empty?

      links.join(" · ")
    end
  end
end
