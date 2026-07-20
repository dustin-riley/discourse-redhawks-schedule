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

      # A validly-encoded string in an encoding incompatible with SLUG (e.g.
      # UTF-16LE) would raise Encoding::CompatibilityError out of the regexp
      # match below. Encoding.compatible?(SLUG, slug) looks tempting for this,
      # but it special-cases zero-length strings as compatible with anything
      # since there are no bytes to reconcile — so an empty UTF-16LE string
      # sails past it and still blows up at the match, one line down. Check
      # the encoding *tag* instead of asking about the content: an
      # ASCII-incompatible encoding can never match SLUG regardless of what
      # (if anything) the string holds.
      return false unless slug.encoding.ascii_compatible?

      # A malformed byte sequence (e.g. a stray \xFF in a UTF-8 string) would
      # raise ArgumentError out of the regexp match below. Reject it here
      # instead, since this boundary must return false for any input, never
      # raise. This is still needed even with the ascii_compatible? guard
      # above: it catches a different failure (bad bytes within an otherwise
      # fine encoding), not the encoding tag itself.
      return false unless slug.valid_encoding?

      SLUG.match?(slug)
    end

    def self.url_for(slug)
      return nil unless valid_slug?(slug)

      "#{BASE}/#{slug}/"
    end
  end
end
