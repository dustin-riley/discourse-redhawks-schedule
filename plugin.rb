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

  # A parse failure (nonexistent player, or a page 247 has changed shape on) is
  # cached too, as a tombstone, so the 48KB fetch that produced "nothing here"
  # isn't repeated on every anonymous request for the slug. Shorter than
  # RECRUIT_TTL so a page that goes live shortly after we first checked isn't
  # hidden for a full day.
  RECRUIT_NEGATIVE_TTL = 3_600

  # How long a "someone already enqueued a refresh for this slug" flag lives in
  # Redis. Only needs to outlast one 247 fetch, so concurrent readers of a
  # stale card collapse into a single job instead of one each.
  RECRUIT_REFRESH_LOCK_TTL = 60

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
