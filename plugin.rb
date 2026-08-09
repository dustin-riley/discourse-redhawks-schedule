# frozen_string_literal: true

# name: discourse-redhawks-schedule
# about: Fetches the Miami University Athletics RSS calendar, serves upcoming events as JSON, and opens gameday topics.
# version: 0.2.0
# authors: MiamiHawkTalk
# url: https://github.com/dustin-riley/discourse-redhawks-schedule

enabled_site_setting :redhawks_schedule_enabled

module ::RedhawksSchedule
  PLUGIN_NAME = "discourse-redhawks-schedule"
  STORE_KEY = "events"
  ALL_EVENTS_KEY = "all_events"
  LEDGER_KEY = "gameday_ledger"
  BOT_ID_KEY = "gameday_bot_user_id"

  # Discourse strips iframes unless the src prefix is allowlisted. Prefix
  # matching, so the query string is deliberately left open.
  EMBED_PREFIX = "https://miamiredhawks.com/showcase/embed.aspx?"
end

require_relative "lib/redhawks_schedule/parser"
require_relative "lib/redhawks_schedule/eastern"
require_relative "lib/redhawks_schedule/gameday_composer"
require_relative "lib/redhawks_schedule/gameday_planner"

after_initialize do
  require_relative "app/services/redhawks_schedule/gameday_bot"
  require_relative "app/jobs/scheduled/fetch_redhawks_schedule"
  require_relative "app/jobs/scheduled/post_redhawks_gameday"
  require_relative "app/controllers/redhawks_schedule_controller"

  Discourse::Application.routes.append do
    get "/redhawks-schedule" => "redhawks_schedule#index", :format => :json
  end

  # Allowlist the player once, rather than relying on a remembered manual step.
  # Guarded, so this writes on first boot after deploy and never again.
  begin
    allowed = SiteSetting.allowed_iframes.to_s.split("|")
    unless allowed.include?(::RedhawksSchedule::EMBED_PREFIX)
      SiteSetting.allowed_iframes = (allowed + [::RedhawksSchedule::EMBED_PREFIX]).join("|")
    end
  rescue StandardError => e
    Rails.logger.warn("[redhawks-schedule] could not allowlist the player iframe: #{e.class}: #{e.message}")
  end
end
