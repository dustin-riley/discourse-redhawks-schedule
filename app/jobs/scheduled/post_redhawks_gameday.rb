# frozen_string_literal: true

module ::Jobs
  class PostRedhawksGameday < ::Jobs::Scheduled
    every 30.minutes

    def execute(_args)
      return unless SiteSetting.redhawks_schedule_enabled
      return unless SiteSetting.redhawks_gameday_enabled

      config = SiteSetting.redhawks_gameday_sports
      return if config.blank?

      events = stored_events
      return if events.empty?

      ledger = PluginStore.get(::RedhawksSchedule::PLUGIN_NAME, ::RedhawksSchedule::LEDGER_KEY) || {}

      plan =
        ::RedhawksSchedule::GamedayPlanner.plan(
          events: events,
          config: config,
          ledger: ledger,
          now: Time.now.utc,
        )

      plan[:unmatched].each do |sport|
        Rails.logger.warn("[redhawks-schedule] configured sport matches no event: #{sport.inspect}")
      end

      if plan[:deferred] > 0
        Rails.logger.info("[redhawks-schedule] deferred #{plan[:deferred]} gameday topics to a later run")
      end

      return if plan[:actions].empty?

      bot = ::RedhawksSchedule::GamedayBot.resolve
      return if bot.nil?

      plan[:actions].each { |action| post(action, bot, ledger) }
    rescue StandardError => e
      Rails.logger.warn("[redhawks-schedule] gameday run failed: #{e.class}: #{e.message}")
    end

    private

    def post(action, bot, ledger)
      if action[:kind] == :thread
        title = ::RedhawksSchedule::GamedayComposer.thread_title(action[:event])
        raw = ::RedhawksSchedule::GamedayComposer.thread_body(action[:event])
      else
        title = ::RedhawksSchedule::GamedayComposer.digest_title(action[:sport], Time.now.utc)
        raw = ::RedhawksSchedule::GamedayComposer.digest_body(action[:sport], action[:events])
      end

      post =
        PostCreator.create!(
          bot,
          title: title,
          raw: raw,
          category: action[:category_id],
          # Swoop Bot is an ordinary user, so it is subject to new-user rate
          # limits and post validations that do not apply to core's bots.
          skip_validations: true,
        )

      # Record before the next action, so a mid-run failure cannot duplicate
      # everything already posted.
      ledger[action[:key]] = post.topic_id
      PluginStore.set(::RedhawksSchedule::PLUGIN_NAME, ::RedhawksSchedule::LEDGER_KEY, ledger)
    rescue StandardError => e
      Rails.logger.warn("[redhawks-schedule] could not post #{action[:key]}: #{e.class}: #{e.message}")
    end

    def stored_events
      ::RedhawksSchedule::StoredEvents.deserialize(
        PluginStore.get(::RedhawksSchedule::PLUGIN_NAME, ::RedhawksSchedule::ALL_EVENTS_KEY),
      )
    end
  end
end
