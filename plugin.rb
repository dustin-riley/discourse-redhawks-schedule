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

  # A fetch failure (throttle, block, timeout, empty body) says nothing about
  # whether a player exists, so it must never be recorded as a tombstone — but
  # it does mean 247 is currently unhappy with *us*, not with one slug. That's
  # why this cooldown is global rather than per-slug: the attack this defends
  # against is a slug walk, and a per-slug flag would let the walk simply move
  # to the next slug on every failure, which is no defense at all. Short
  # relative to RECRUIT_NEGATIVE_TTL so a transient outage doesn't hide real
  # recruits for long.
  RECRUIT_FETCH_FAILURE_COOLDOWN_TTL = 300

  # Bounds new outbound fetches (cache misses) per requesting IP. A cache hit
  # is never limited — this only guards the inline-fetch path, so a popular
  # post serving many reads of an already-fetched card is unaffected.
  #
  # A slug walk of well-formed-but-fake slugs is pure cache misses — every
  # request is a distinct slug, so nothing here is ever cached, and every hit
  # both costs a 247 round trip and writes a permanent tombstone row. A real
  # reader can only produce a burst of cache misses by opening a thread that
  # onebox-embeds several never-before-seen recruit links at once —
  # realistically a full signing-class post, which NCAA initial-counter rules
  # cap at around 25 recruits — all rendered within a few seconds of the page
  # loading. 40 requests per 60 seconds gives that worst case real headroom
  # (60% above a 25-recruit class) while still making a walk of any size slow
  # enough to not be worth running: sustaining it for, say, 1,000 slugs takes
  # 25 minutes at this ceiling.
  #
  # This counts *inbound* requests to this endpoint, not outbound fetches to
  # 247. Those are the same number only for a bogus slug, which parses to nil
  # and stops after the player-page fetch. A cache miss on a real recruit also
  # fetches the interests page, so the per-IP outbound ceiling this limiter
  # implies is effectively double this number for genuine recruits.
  RECRUIT_FETCH_RATE_LIMIT_MAX = 40
  RECRUIT_FETCH_RATE_LIMIT_SECS = 60

  def self.recruit_store_key(slug)
    "recruit:#{slug}"
  end
end

require_relative "lib/redhawks_schedule/parser"
require_relative "lib/redhawks_schedule/recruit_source"
require_relative "lib/redhawks_schedule/recruit_parser"
require_relative "lib/redhawks_schedule/recruit_interests_parser"
require_relative "lib/redhawks_schedule/recruit_assembler"

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
