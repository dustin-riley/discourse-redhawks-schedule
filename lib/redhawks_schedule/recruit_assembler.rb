# frozen_string_literal: true

module RedhawksSchedule
  # Merges the player page's recruit hash with the full school list from the
  # interests page, and derives the two fields the card needs but neither
  # parser can compute alone.
  #
  # Its own file, rather than logic in the controller, because the controller's
  # inline fetch and the background refresh job both build this payload. Two
  # copies would eventually disagree, and the disagreement would only show up
  # as cards that differ depending on whether they were cache-warmed.
  #
  # Pure Ruby, like the parsers: no Rails, no HTTP, no persistence. The callers
  # own the fetching and the failure handling; this only decides what the
  # merged hash looks like given whatever they managed to get.
  module RecruitAssembler
    COMMITTED = "committed"

    module_function

    # `interest_rows` being nil is the ordinary partial-success case, not an
    # error: the second fetch failed and the caller still holds the handful of
    # offers the player page carried. Returns a new hash — the callers go on to
    # persist what they pass in, so mutating it would change what gets stored.
    def merge(recruit, interest_rows)
      return recruit unless recruit.is_a?(Hash)

      merged = recruit.dup
      rows = interest_rows.is_a?(Array) && !interest_rows.empty? ? interest_rows : nil

      unless rows.nil?
        merged["offers"] = rows
        # Only ever set from the full list. Counting the player page's five
        # rows would report "4 offers" for a player with sixteen — a wrong
        # number is worse than no number, since the card renders it as fact.
        # Zero from a real list is a genuine answer and is set; the key is left
        # absent entirely when the list never arrived.
        merged["offer_count"] = rows.count { |r| r.is_a?(Hash) && r["offered"] == true }
      end

      merged["committed_to"] = committed_team(merged["offers"])
      merged
    end

    def committed_team(offers)
      return nil unless offers.is_a?(Array)

      row = offers.find { |o| o.is_a?(Hash) && committed_status?(o["status"]) }
      row && row["team"]
    end

    # `to_s.downcase` on a status straight off a scraped page can raise
    # ArgumentError when the string is tagged UTF-8 but carries invalid
    # bytes. merge must never raise (see the module comment above): a raise
    # here reaches fetch_inline's outer rescue, which sets the global fetch
    # failure cooldown and stops recruit cards for every visitor, not just
    # this one row. Same reasoning and same two checks as
    # RecruitSource.valid_slug?: an ASCII-incompatible encoding tag and a
    # malformed byte sequence within an otherwise ASCII-compatible encoding
    # are two different ways downcase can blow up, so both are guarded here.
    def committed_status?(status)
      status = status.to_s
      return false unless status.encoding.ascii_compatible?
      return false unless status.valid_encoding?

      status.downcase == COMMITTED
    end
  end
end
