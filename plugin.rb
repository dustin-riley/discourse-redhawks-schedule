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
  RECRUIT_TTL = 86_400

  def self.recruit_store_key(slug)
    "recruit:#{slug}"
  end
end

require_relative "lib/redhawks_schedule/parser"
require_relative "lib/redhawks_schedule/recruit_source"
require_relative "lib/redhawks_schedule/recruit_parser"

after_initialize do
  require_relative "app/jobs/scheduled/fetch_redhawks_schedule"
  require_relative "app/controllers/redhawks_schedule_controller"
  require_relative "app/jobs/regular/refresh_redhawks_recruit"
  require_relative "app/controllers/redhawks_recruit_controller"

  Discourse::Application.routes.append do
    get "/redhawks-schedule" => "redhawks_schedule#index", :format => :json
    get "/redhawks-recruit" => "redhawks_recruit#show", :format => :json
  end
end
