# frozen_string_literal: true

# Posts one gameday topic on demand, for the next event that production has
# not posted yet. Exists so the composer's rendered output can be seen on the
# real forum before `redhawks_gameday_enabled` is turned on -- which is why
# this deliberately does NOT check that setting.
#
# Unlike the scheduled job, failures surface as 422s instead of being logged
# and swallowed. The job serves a public sidebar, where an upstream outage
# should stay invisible; here a human is waiting on the response and needs to
# know why nothing was posted.
class RedhawksGamedayTestController < ::Admin::AdminController
  requires_plugin ::RedhawksSchedule::PLUGIN_NAME

  def create
    config = SiteSetting.redhawks_gameday_sports
    if config.blank? || ::RedhawksSchedule::GamedayPlanner.thread_sports(config).empty?
      return refuse("no sport is configured for gameday threads")
    end

    events =
      ::RedhawksSchedule::StoredEvents.deserialize(
        PluginStore.get(::RedhawksSchedule::PLUGIN_NAME, ::RedhawksSchedule::ALL_EVENTS_KEY),
      )
    return refuse("no stored events; the schedule feed has not been fetched yet") if events.empty?

    ledger = PluginStore.get(::RedhawksSchedule::PLUGIN_NAME, ::RedhawksSchedule::LEDGER_KEY) || {}

    action =
      ::RedhawksSchedule::GamedayPlanner.next_test_action(
        events: events,
        config: config,
        ledger: ledger,
      )
    return refuse("every upcoming event has already been posted") if action.nil?

    bot = ::RedhawksSchedule::GamedayBot.resolve
    return refuse("the gameday bot could not be resolved; see the logs") if bot.nil?

    event = action[:event]

    post =
      PostCreator.create!(
        bot,
        title: ::RedhawksSchedule::GamedayComposer.thread_title(event),
        raw: ::RedhawksSchedule::GamedayComposer.thread_body(event),
        category: action[:category_id],
        # Swoop Bot is an ordinary user, subject to new-user rate limits and
        # post validations that core's bots are exempt from.
        skip_validations: true,
      )

    # The ledger is READ above and never written. Writing it would silently
    # turn this test into the real gameday thread, with no second chance at a
    # bad title.
    render json: {
             topic_id: post.topic_id,
             topic_url: "#{Discourse.base_url}#{post.topic.relative_url}",
             title: post.topic.title,
             sport: event[:sport],
             start_utc: event[:start_utc].iso8601,
             time_known: event[:time_known],
             category_id: action[:category_id],
           }
  rescue StandardError => e
    Rails.logger.warn("[redhawks-schedule] gameday test failed: #{e.class}: #{e.message}")
    refuse("#{e.class}: #{e.message}")
  end

  private

  def refuse(reason)
    render json: { reason: reason }, status: 422
  end
end
