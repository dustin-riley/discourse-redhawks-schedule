# frozen_string_literal: true

require "time"
require_relative "eastern"

module RedhawksSchedule
  # Decides what to post. Pure: no Rails, no clock, no I/O — `now` is always
  # passed in. The job that executes a plan cannot be tested on the dev Mac, so
  # every scheduling rule worth getting right lives here instead.
  module GamedayPlanner
    DAY = 24 * 60 * 60
    DEFAULT_LIMIT = 5

    module_function

    def plan(events:, config:, ledger:, now:, limit: DEFAULT_LIMIT)
      rows = config.map { |row| normalize(row) }
      seen_sports = {}
      events.each { |e| seen_sports[e[:sport]] = true }

      eligible = []
      rows.each do |row|
        next if row[:mode] == "off" || row[:category_id].nil?

        sport_events = events.select { |e| e[:sport] == row[:sport] }
        eligible += thread_actions(sport_events, row, ledger, now) if row[:mode] == "thread"
      end

      eligible = eligible.sort_by { |a| a[:sort_at] }

      {
        actions: eligible.take(limit).map { |a| a.reject { |k, _| k == :sort_at } },
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
