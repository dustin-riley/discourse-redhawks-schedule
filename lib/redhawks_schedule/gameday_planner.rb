# frozen_string_literal: true

require "time"
require_relative "eastern"

module RedhawksSchedule
  # Decides what to post. Pure: no Rails, no clock, no I/O — `now` is always
  # passed in. The job that executes a plan cannot be tested on the dev Mac, so
  # every scheduling rule worth getting right lives here instead.
  module GamedayPlanner
    DAY = 24 * 60 * 60
    WEEK = 7 * DAY
    DEFAULT_LIMIT = 5

    module_function

    def plan(events:, config:, ledger:, now:, limit: DEFAULT_LIMIT)
      rows = config.map { |row| normalize(row) }
      seen_sports = {}
      events.each { |e| seen_sports[e[:sport]] = true }

      eligible = []
      digests = []

      rows.each do |row|
        next if row[:mode] == "off" || row[:category_id].nil?

        sport_events = events.select { |e| e[:sport] == row[:sport] }

        case row[:mode]
        when "thread"
          eligible += thread_actions(sport_events, row, ledger, now)
        when "digest"
          action = digest_action(sport_events, row, ledger, now)
          digests << action if action
        end
      end

      eligible = eligible.sort_by { |a| a[:sort_at] }

      {
        actions: digests + eligible.take(limit).map { |a| a.reject { |k, _| k == :sort_at } },
        deferred: [eligible.length - limit, 0].max,
        unmatched: rows.map { |r| r[:sport] }.reject { |s| seen_sports[s] },
      }
    end

    def thread_actions(sport_events, row, ledger, now)
      days_before = row[:days_before] || 0

      sport_events.each_with_object([]) do |event, actions|
        next if event[:id].nil?

        key = "gameday:game:#{event[:id]}"
        next if ledger.key?(key)
        # The window opens at Eastern MIDNIGHT of the day `days_before` ahead,
        # not at the kickoff minute. Otherwise days_before: 0 would mean "post
        # at kickoff", which is useless, rather than "post that morning".
        next if now < Eastern.start_of_day(event[:start_utc] - days_before * DAY)

        actions << {
          kind: :thread,
          key: key,
          category_id: row[:category_id],
          event: event,
          sort_at: event[:start_utc],
        }
      end
    end

    def digest_action(sport_events, row, ledger, now)
      return nil unless Eastern.day_name(now) == row[:digest_day].to_s

      key = "gameday:digest:#{row[:sport]}:#{Eastern.iso_week(now)}"
      return nil if ledger.key?(key)

      window_start = Eastern.start_of_day(now)
      window_end = window_start + WEEK
      in_week = sport_events.select do |e|
        e[:start_utc] >= window_start && e[:start_utc] < window_end
      end

      # An empty week is silence, not an empty digest.
      return nil if in_week.empty?

      {
        kind: :digest,
        key: key,
        category_id: row[:category_id],
        sport: row[:sport],
        events: in_week,
      }
    end

    # The sports the test endpoint is allowed to post for, mapped to where.
    # Extracted so the controller can distinguish "nothing configured" from
    # "nothing left to post" without re-implementing `normalize`.
    def thread_sports(config)
      config.each_with_object({}) do |row, map|
        normalized = normalize(row)
        next unless normalized[:mode] == "thread"
        next if normalized[:category_id].nil?

        map[normalized[:sport]] = normalized[:category_id]
      end
    end

    # The one topic the test endpoint would post right now. Deliberately
    # ignores `days_before` -- waiting for the window is what the endpoint
    # exists to avoid. Takes no `now`: the stored list arrives already
    # upcoming-filtered and sorted by [start_utc, sport], so the first match
    # is the next event.
    def next_test_action(events:, config:, ledger:)
      categories = thread_sports(config)
      return nil if categories.empty?

      event =
        events.find do |e|
          next false if e[:id].nil?
          next false unless categories.key?(e[:sport])

          !ledger.key?("gameday:game:#{e[:id]}")
        end
      return nil if event.nil?

      {
        kind: :thread,
        key: "gameday:game:#{event[:id]}",
        category_id: categories[event[:sport]],
        event: event,
      }
    end

    # Site settings hand back string keys; specs are easier to read with
    # symbols. Accept both rather than making the untestable job convert.
    def normalize(row)
      get = lambda { |name| row[name] || row[name.to_s] }
      categories = get.call(:category)

      {
        sport: get.call(:sport),
        mode: get.call(:mode).to_s,
        category_id: categories.is_a?(Array) ? categories.first : categories,
        days_before: get.call(:days_before),
        digest_day: get.call(:digest_day),
      }
    end
  end
end
