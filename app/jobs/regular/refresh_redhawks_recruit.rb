# frozen_string_literal: true

module ::Jobs
  # Fetches one recruit page and stores the parsed result.
  #
  # Enqueued by the controller when a cached entry has gone stale. Failures are
  # logged and swallowed: the controller has already served the stale copy, so
  # a failed refresh costs freshness, never an error in someone's post.
  class RefreshRedhawksRecruit < ::Jobs::Base
    def execute(args)
      return unless SiteSetting.redhawks_recruit_enabled

      slug = args[:slug] || args["slug"]
      url = ::RedhawksSchedule::RecruitSource.url_for(slug)
      return if url.nil?

      body = fetch(url)
      return if body.blank?

      recruit = ::RedhawksSchedule::RecruitParser.parse(body)

      if recruit.nil?
        renew_tombstone(slug)
        return
      end

      # Only after the tombstone decision is already made, so a failed
      # interests fetch can never influence it: by here the player page has
      # parsed, which is the only thing a tombstone is allowed to be about.
      recruit = ::RedhawksSchedule::RecruitAssembler.merge(recruit, fetch_interests(body))

      PluginStore.set(
        ::RedhawksSchedule::PLUGIN_NAME,
        ::RedhawksSchedule.recruit_store_key(slug),
        { "fetched_at" => Time.now.utc.iso8601, "recruit" => recruit },
      )
    rescue StandardError => e
      Rails.logger.warn("[redhawks-recruit] refresh failed for #{slug}: #{e.class}: #{e.message}")
    end

    private

    def fetch(url, label = "fetch")
      FinalDestination::HTTP.get(URI(url))
    rescue StandardError => e
      Rails.logger.warn("[redhawks-recruit] #{label} failed: #{e.class}: #{e.message}")
      nil
    end

    # Returns nil on every failure path, and swallows everything itself so
    # that nothing here can reach execute's rescue. A missing or unreachable
    # interests page is a partial success — the caller still has the offers the
    # player page carried — so it must never renew a tombstone or otherwise
    # cost the reader the card. Note `fetch` above already logs and returns nil
    # on a transport failure; this rescue is for the parse and URI paths.
    def fetch_interests(player_html)
      url = ::RedhawksSchedule::RecruitSource.interests_url_from(player_html)
      return nil if url.nil?

      body = fetch(url, "interests fetch")
      return nil if body.blank?

      ::RedhawksSchedule::RecruitInterestsParser.parse(body)
    rescue StandardError => e
      Rails.logger.warn("[redhawks-recruit] interests fetch failed: #{e.class}: #{e.message}")
      nil
    end

    # A refresh that fails to parse only ever replaces a tombstone (or an
    # absent entry) with a fresh tombstone, resetting the negative-cache
    # clock. It must never overwrite a *good* cached entry: a transient 247
    # hiccup on a stale-but-real recruit must cost freshness, not the card
    # itself.
    def renew_tombstone(slug)
      key = ::RedhawksSchedule.recruit_store_key(slug)
      current = PluginStore.get(::RedhawksSchedule::PLUGIN_NAME, key)
      return unless current.nil? || (current.is_a?(Hash) && current["tombstone"] == true)

      PluginStore.set(
        ::RedhawksSchedule::PLUGIN_NAME,
        key,
        { "fetched_at" => Time.now.utc.iso8601, "tombstone" => true },
      )
    end
  end
end
