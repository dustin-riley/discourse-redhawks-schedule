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
      return if recruit.nil?

      PluginStore.set(
        ::RedhawksSchedule::PLUGIN_NAME,
        ::RedhawksSchedule.recruit_store_key(slug),
        { "fetched_at" => Time.now.utc.iso8601, "recruit" => recruit },
      )
    rescue StandardError => e
      Rails.logger.warn("[redhawks-recruit] refresh failed for #{slug}: #{e.class}: #{e.message}")
    end

    private

    def fetch(url)
      FinalDestination::HTTP.get(URI(url))
    rescue StandardError => e
      Rails.logger.warn("[redhawks-recruit] fetch failed: #{e.class}: #{e.message}")
      nil
    end
  end
end
