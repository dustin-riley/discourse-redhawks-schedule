# frozen_string_literal: true

module ::Jobs
  class FetchRedhawksSchedule < ::Jobs::Scheduled
    every 30.minutes

    def execute(_args)
      return unless SiteSetting.redhawks_schedule_enabled

      url = SiteSetting.redhawks_schedule_feed_url
      return if url.blank?

      body = fetch(url)
      # Guard against error pages and truncated responses. Writing a parsed
      # HTML error page over good data would blank the sidebar; leaving the
      # previous value in place makes an upstream outage invisible to users.
      return if body.blank? || !body.include?("<rss")

      parser = ::RedhawksSchedule::Parser.new(body)
      generated_at = Time.now.utc.iso8601

      PluginStore.set(
        ::RedhawksSchedule::PLUGIN_NAME,
        ::RedhawksSchedule::STORE_KEY,
        { "generated_at" => generated_at, "events" => parser.parse.map { |e| serialize(e) } },
      )

      # Gameday threads need each day of a series, and read stored data rather
      # than re-fetching, so the uncollapsed list is stored alongside.
      PluginStore.set(
        ::RedhawksSchedule::PLUGIN_NAME,
        ::RedhawksSchedule::ALL_EVENTS_KEY,
        { "generated_at" => generated_at, "events" => parser.events.map { |e| serialize(e) } },
      )
    rescue StandardError => e
      Rails.logger.warn("[redhawks-schedule] update failed: #{e.class}: #{e.message}")
    end

    private

    def fetch(url)
      FinalDestination::HTTP.get(URI(url))
    rescue StandardError => e
      Rails.logger.warn("[redhawks-schedule] fetch failed: #{e.class}: #{e.message}")
      nil
    end

    def serialize(event)
      event.merge(
        start_utc: event[:start_utc].iso8601,
        end_utc: event[:end_utc].iso8601,
      )
    end
  end
end
