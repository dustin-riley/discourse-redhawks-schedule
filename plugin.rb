# frozen_string_literal: true

# name: discourse-redhawks-schedule
# about: Fetches the Miami University Athletics RSS calendar and serves upcoming events as JSON.
# version: 0.1.0
# authors: MiamiHawkTalk
# url: https://github.com/dustin-riley/discourse-redhawks-schedule

enabled_site_setting :redhawks_schedule_enabled

module ::RedhawksSchedule
  PLUGIN_NAME = "discourse-redhawks-schedule"
  STORE_KEY = "events"
  ALL_EVENTS_KEY = "all_events"
end

require_relative "lib/redhawks_schedule/parser"

after_initialize do
  require_relative "app/jobs/scheduled/fetch_redhawks_schedule"
  require_relative "app/controllers/redhawks_schedule_controller"

  Discourse::Application.routes.append do
    get "/redhawks-schedule" => "redhawks_schedule#index", :format => :json
  end
end
