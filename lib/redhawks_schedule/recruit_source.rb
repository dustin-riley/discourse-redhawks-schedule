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
      return false unless slug.is_a?(String)

      # A malformed byte sequence (e.g. a stray \xFF in a UTF-8 string) would
      # raise ArgumentError out of the regexp match below. Reject it here
      # instead, since this boundary must return false for any input, never
      # raise.
      return false unless slug.valid_encoding?

      # A validly-encoded string in an encoding incompatible with SLUG (e.g.
      # UTF-16LE) would raise Encoding::CompatibilityError out of the regexp
      # match below. Reject it here for the same reason.
      return false unless Encoding.compatible?(SLUG, slug)

      SLUG.match?(slug)
    end

    def self.url_for(slug)
      return nil unless valid_slug?(slug)

      "#{BASE}/#{slug}/"
    end
  end
end
