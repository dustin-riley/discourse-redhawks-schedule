# frozen_string_literal: true

module RedhawksSchedule
  # The security boundary for recruit fetching.
  #
  # The endpoint takes a slug and never a URL. An endpoint that fetched a
  # caller-supplied URL would be a server-side request forgery hole: on this
  # droplet, `?url=http://169.254.169.254/metadata/v1.json` reads the
  # DigitalOcean instance metadata. Every URL this plugin fetches for a recruit
  # is built here, from a slug that matched SLUG.
  module RecruitSource
    SLUG = /\A[a-z0-9-]+-\d+\z/.freeze
    BASE = "https://247sports.com/player"

    def self.valid_slug?(slug)
      !slug.nil? && slug.is_a?(String) && !(SLUG =~ slug).nil?
    end

    def self.url_for(slug)
      return nil unless valid_slug?(slug)

      "#{BASE}/#{slug}/"
    end
  end
end
