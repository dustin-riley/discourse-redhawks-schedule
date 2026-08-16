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
      broadcast = event[:broadcast] || {}

      segments = [
        headline(event),
        when_where(event),
        watch_line(broadcast),
        stream_block(broadcast),
        thread_links(event, broadcast),
      ]

      segments.compact.reject(&:empty?).join("\n\n")
    end

    def headline(event)
      line = "#{sport_emoji(event[:sport])} **#{matchup(event)}**"
      line += " · #{event[:promo]}" if event[:promo]
      line
    end

    def when_where(event)
      lines = ["📅 #{when_line(event)}"]
      lines << "📍 #{event[:location]}" if event[:location]
      lines.join("\n")
    end

    def watch_line(broadcast)
      parts = []
      parts << "📺 #{broadcast[:tv]}" if broadcast[:tv]
      parts << "📻 #{broadcast[:radio]}" if broadcast[:radio]
      return nil if parts.empty?

      parts.join(" · ")
    end

    def thread_links(event, broadcast)
      links = []
      links << "🎟️ [Tickets](#{broadcast[:tickets]})" if broadcast[:tickets]
      links << "📊 [Live stats](#{broadcast[:livestats]})" if broadcast[:livestats]
      links << "🔊 [Listen live](#{broadcast[:audio]})" if broadcast[:audio]
      links << "🔗 [Game page](#{event[:url]})" if event[:url]
      return nil if links.empty?

      links.join(" · ")
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
      "#{Eastern.local(event[:start_utc]).strftime('%A, %B %-d')}#{time_suffix(event)}"
    end

    def time_suffix(event)
      return " · Time TBA" unless event[:time_known]

      " · #{Eastern.local(event[:start_utc]).strftime('%-I:%M %p')} ET"
    end

    def stream_block(broadcast)
      return format(IFRAME, broadcast[:video_embed]) if broadcast[:video_embed]
      return "▶️ [Watch the stream](#{broadcast[:video]})" if broadcast[:video]

      nil
    end

  end
end
