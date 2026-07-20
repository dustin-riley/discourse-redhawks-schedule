# frozen_string_literal: true

require "nokogiri"
require "uri"

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

    INTERESTS_HOSTS = ["247sports.com", "www.247sports.com"].freeze
    INTERESTS_PATH = %r{\A/recruitment/([a-z0-9-]+-\d+)/recruitinterests/?\z}i.freeze

    # The player page carries a link to the recruit's full interests page, and
    # the recruitment id in it cannot be derived from the player slug — so the
    # href has to be scraped. Scraping a URL out of a page we do not control
    # and then fetching it is exactly the SSRF hole `url_for` exists to
    # prevent, so the result is validated here and rebuilt from the matched
    # slug rather than passed through. A string match alone is not enough:
    # `evil-247sports.com` and `247sports.com.attacker.net` satisfy almost any
    # substring test you would write. Only the parsed host is trustworthy.
    # `player_slug` is optional only so the security-boundary specs can exercise
    # host and scheme handling in isolation; every production caller passes it,
    # and should. Without it this returns the *first* recruitinterests anchor on
    # the page, and 247 is free to render a "similar recruits" module whose link
    # precedes the subject's own — which would attribute another teenager's
    # scholarship offers to this one, silently and in a card that reads as fact.
    # With it, the recruitment slug's name portion must match the player slug's,
    # and anything else is skipped. Returning nil (a card with the player page's
    # partial offers) is always better than guessing.
    def self.interests_url_from(html, player_slug = nil)
      return nil unless html.is_a?(String) && !html.empty?

      expected = nil
      unless player_slug.nil?
        # A caller that hands us a slug we cannot vet gets nil rather than the
        # unfiltered first-anchor behaviour it was trying to avoid.
        return nil unless valid_slug?(player_slug)

        expected = slug_name(player_slug)
      end

      document = Nokogiri::HTML(html)
      document.css("a[href]").each do |anchor|
        url = parse_interests_href(anchor["href"], expected)
        return url unless url.nil?
      end
      nil
    rescue StandardError
      nil
    end

    # "kaden-estep-46165474" -> "kaden-estep". The trailing id differs between
    # the player slug and the recruitment slug for the same person (they are
    # different 247 id spaces), so only the name portion can be compared.
    def self.slug_name(slug)
      slug.to_s.downcase.sub(/-\d+\z/, "")
    end
    private_class_method :slug_name

    def self.parse_interests_href(href, expected_name = nil)
      uri = URI.parse(href.to_s)
      return nil unless uri.scheme == "https"
      return nil unless INTERESTS_HOSTS.include?(uri.host.to_s.downcase)

      match = INTERESTS_PATH.match(uri.path.to_s)
      return nil if match.nil?

      found = match[1].downcase
      return nil if !expected_name.nil? && slug_name(found) != expected_name

      "https://247sports.com/recruitment/#{found}/recruitinterests/"
    rescue URI::Error
      nil
    end
    private_class_method :parse_interests_href
  end
end
