# frozen_string_literal: true

class RedhawksRecruitController < ::ApplicationController
  # Load-bearing, as on the schedule controller: anonymous visitors are most of
  # a public fan forum's readers and must get cards.
  requires_login false
  skip_before_action :check_xhr, :preload_json, :redirect_to_login_if_required, raise: false

  # Sentinel distinguishing "the store read blew up" from "the store read
  # succeeded and found nothing" — the two look identical as a bare nil, but
  # only the latter should fall into fetch_inline. Confusing them turns a
  # database outage into an outbound-fetch storm.
  READ_FAILED = :read_failed

  # Distinct from the store's "tombstone" concept: a tombstone says 247 was
  # reached and said the player doesn't exist. This key says the opposite —
  # we never got a clean answer at all, whether from a throttle, a block, a
  # timeout, or an empty body — so it must not poison anything player-specific
  # and must expire fast. Global rather than per-slug: the failure mode this
  # guards against is 247 refusing *us*, not one player, and that's exactly
  # what a slug walk provokes. A per-slug flag would let the walk simply keep
  # moving to the next slug on every failure — no defense at all — whereas one
  # flag makes every slug in the walk turn away at the door as soon as 247
  # starts erroring.
  FETCH_FAILURE_COOLDOWN_KEY = "redhawks_recruit_fetch_failure_cooldown"

  def show
    slug = params[:slug].to_s
    return render_missing unless ::RedhawksSchedule::RecruitSource.valid_slug?(slug)

    # The kill switch has to cover the network-facing half too, not just the
    # background job — otherwise turning it off stops refreshes but leaves the
    # endpoint happily fetching and serving.
    return render_missing unless SiteSetting.redhawks_recruit_enabled

    entry = read_store(slug)
    return render_missing if entry == READ_FAILED

    if entry.nil?
      # Only entries we don't already have are gated — a cached hit above,
      # fresh or stale, is served regardless of the cooldown below.
      return render_missing if fetch_failure_cooldown_active?

      entry = fetch_inline(slug)
      return render_missing if entry.nil?
    elsif stale?(entry)
      # Serve the current copy now and refresh behind the reader. Nobody waits
      # on 247. For a real entry that's the stale card; for a tombstone that's
      # nothing, so this request still 404s below, but the next one may not.
      enqueue_refresh(slug)
    end

    # A tombstone is a server-side "we already checked, there's nothing" —
    # it must never reach a response body, only ever the 404 status.
    return render_missing if tombstone?(entry)

    response.headers["Cache-Control"] = "public, max-age=900"
    render json: entry
  end

  private

  def read_store(slug)
    PluginStore.get(::RedhawksSchedule::PLUGIN_NAME, ::RedhawksSchedule.recruit_store_key(slug))
  rescue StandardError => e
    Rails.logger.warn("[redhawks-recruit] store read failed: #{e.class}: #{e.message}")
    READ_FAILED
  end

  def tombstone?(entry)
    entry.is_a?(Hash) && entry["tombstone"] == true
  end

  def stale?(entry)
    # A malformed entry (wrong type entirely, or a fetched_at that isn't a
    # string) is treated as stale rather than raising: Time.iso8601 raises
    # TypeError (not ArgumentError) on a non-string, and this is a
    # silent-failure boundary, not a place to 500.
    return true unless entry.is_a?(Hash)

    fetched_at = entry["fetched_at"]
    return true unless fetched_at.is_a?(String)

    ttl = tombstone?(entry) ? ::RedhawksSchedule::RECRUIT_NEGATIVE_TTL : ::RedhawksSchedule::RECRUIT_TTL
    Time.now.utc - Time.iso8601(fetched_at) >= ttl
  rescue ArgumentError, TypeError
    true
  end

  # Nothing cached: the reader would otherwise get no card at all, so pay the
  # fetch once. Every later view is served from the store — including a
  # negative result, so a slug that doesn't exist costs one fetch, not one per
  # request forever.
  #
  # Only this path is rate-limited, never a cache hit: a popular post
  # legitimately serves many reads of the same already-fetched card, and
  # those must stay unlimited. What must be bounded is *new* outbound fetches
  # from one IP — a slug walk of well-formed-but-fake slugs never repeats a
  # slug, so it is pure cache misses, one inline fetch and one tombstone row
  # per request, with no reaper. A real reader can only ever cause a burst of
  # cache misses by opening a thread that onebox-embeds many recruit links
  # that have never been fetched before — realistically a couple dozen at
  # once for a full recruiting-class post — so the limit is set well above
  # that and far below what a slug walk needs to be worth running.
  def fetch_inline(slug)
    begin
      inline_fetch_rate_limiter(request.remote_ip).performed!
    rescue RateLimiter::LimitExceeded
      # Our own throttle, not a 247 failure — must not trip the
      # fetch-failure cooldown above, which is reserved for 247 itself
      # misbehaving.
      return nil
    end

    url = ::RedhawksSchedule::RecruitSource.url_for(slug)
    # Not a fetch failure — this is url_for rejecting the slug before any
    # network call was attempted, so it must not trip the cooldown.
    return nil if url.nil?

    body = FinalDestination::HTTP.get(URI(url))
    if body.blank?
      set_fetch_failure_cooldown
      return nil
    end

    recruit = ::RedhawksSchedule::RecruitParser.parse(body)
    # Guarded on a real recruit so a slug walk costs exactly one outbound
    # request per request, as before: a bogus slug parses to nil and never
    # reaches the second fetch.
    recruit = ::RedhawksSchedule::RecruitAssembler.merge(recruit, fetch_interests(body, slug)) unless recruit.nil?

    entry =
      if recruit.nil?
        { "fetched_at" => Time.now.utc.iso8601, "tombstone" => true }
      else
        { "fetched_at" => Time.now.utc.iso8601, "recruit" => recruit }
      end

    # A store write failure must not throw away a fetch that already
    # succeeded — the caller still has a good `entry` in hand even if it
    # couldn't be persisted for the next reader.
    write_store(slug, entry)
    entry
  rescue StandardError => e
    Rails.logger.warn("[redhawks-recruit] inline fetch failed for #{slug}: #{e.class}: #{e.message}")
    set_fetch_failure_cooldown
    nil
  end

  # Returns nil on every failure path, and swallows everything itself so that
  # nothing here can reach fetch_inline's rescue.
  #
  # Deliberately does NOT call set_fetch_failure_cooldown on failure. That
  # cooldown exists for 247 refusing us outright, and turns every slug in a
  # walk away at the door. A missing secondary page is not that signal — it is
  # one page we could not get for one player, and tripping the global cooldown
  # over it would stop cards site-wide for five minutes. Equally it must not
  # tombstone: the player demonstrably exists, we just read one page fewer, and
  # the caller still holds the offers the player page carried.
  def fetch_interests(player_html, slug)
    url = ::RedhawksSchedule::RecruitSource.interests_url_from(player_html, slug)
    return nil if url.nil?

    body = FinalDestination::HTTP.get(URI(url))
    return nil if body.blank?

    ::RedhawksSchedule::RecruitInterestsParser.parse(body)
  rescue StandardError => e
    Rails.logger.warn("[redhawks-recruit] interests fetch failed: #{e.class}: #{e.message}")
    nil
  end

  def inline_fetch_rate_limiter(remote_ip)
    RateLimiter.new(
      nil,
      "redhawks_recruit_fetch:#{remote_ip}",
      ::RedhawksSchedule::RECRUIT_FETCH_RATE_LIMIT_MAX,
      ::RedhawksSchedule::RECRUIT_FETCH_RATE_LIMIT_SECS,
    )
  end

  def fetch_failure_cooldown_active?
    Discourse.redis.get(FETCH_FAILURE_COOLDOWN_KEY).present?
  rescue StandardError => e
    Rails.logger.warn("[redhawks-recruit] cooldown read failed: #{e.class}: #{e.message}")
    # Same fail-closed direction as enqueue_refresh's lock, but the other way
    # round: an unreachable Redis means we can't tell if we're in cooldown, so
    # assume the worst and skip the fetch rather than risk adding to whatever
    # is already going wrong for 247.
    true
  end

  def set_fetch_failure_cooldown
    Discourse.redis.set(
      FETCH_FAILURE_COOLDOWN_KEY,
      "1",
      ex: ::RedhawksSchedule::RECRUIT_FETCH_FAILURE_COOLDOWN_TTL,
    )
  rescue StandardError => e
    Rails.logger.warn("[redhawks-recruit] cooldown write failed: #{e.class}: #{e.message}")
  end

  def write_store(slug, entry)
    PluginStore.set(::RedhawksSchedule::PLUGIN_NAME, ::RedhawksSchedule.recruit_store_key(slug), entry)
  rescue StandardError => e
    Rails.logger.warn("[redhawks-recruit] store write failed for #{slug}: #{e.class}: #{e.message}")
  end

  # A short Redis flag collapses N concurrent readers of one stale card into a
  # single enqueued job instead of N identical ones all fetching the same URL.
  # If Redis itself is unreachable, skip the refresh rather than risk raising
  # out of a request that would otherwise have served fine.
  def enqueue_refresh(slug)
    key = "redhawks_recruit_refresh_lock:#{slug}"
    return unless Discourse.redis.set(key, "1", ex: ::RedhawksSchedule::RECRUIT_REFRESH_LOCK_TTL, nx: true)

    ::Jobs.enqueue(:refresh_redhawks_recruit, slug: slug)
  rescue StandardError => e
    Rails.logger.warn("[redhawks-recruit] refresh enqueue failed for #{slug}: #{e.class}: #{e.message}")
  end

  # 404 with an empty body. The component treats any non-200 as "leave the
  # existing onebox alone", so this is the silent-failure path.
  def render_missing
    render json: {}, status: :not_found
  end
end
