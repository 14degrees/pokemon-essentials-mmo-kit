# frozen_string_literal: true

module PEMK
  # Audit item 4 (second half): the NPC-gift / event-item claim ledger. Layer C gates
  # only pbItemBall; every other acquisition path (gifts, TMs, HMs, key items, story
  # rewards) runs through pbReceiveItem, which was hooked nowhere — so with
  # client-owned self-switches, every one-shot reward was re-farmable with no trace.
  #
  # DETECTION only, and deliberately so: the bag is blob-authoritative, and some games
  # legitimately have repeatable or daily gift NPCs. A repeat is EVIDENCE for a human
  # (through the D5 queue), never an automatic consequence. The value is that a re-farm
  # now leaves a record naming exactly which event and item were milked.
  class GiftClaims
    REPEAT_MIN   = 5        # claims of the SAME (map, event, item) before it is reportable
    DAILY_WINDOW = 86_400   # a repeatable event is judged per day, not over its lifetime

    def initialize(db, logger: nil)
      @db  = db
      @log = logger || ->(_m) {}
    end

    # -> :first | :repeat | :suspect | :bad. +repeatable+: the world export says the
    # event pays out again by design (a daily NPC's cooldown, a lottery's prize table).
    # Its row then counts the current day only, and REPEAT_MIN claims in one day are
    # the suspect case: claiming it every day for weeks is just playing.
    def claim(account_id, map, event, item, quantity, repeatable: false, now: Time.now)
      return :bad unless map.is_a?(Integer) && event.is_a?(Integer) &&
                         item.is_a?(String) && !item.empty? && item.length <= 64 &&
                         quantity.is_a?(Integer) && quantity.between?(1, 999_999)

      row = @db[:gift_claims].where(account_id: account_id, map: map, event: event, item: item).first
      if row.nil?
        @db[:gift_claims].insert(account_id: account_id, map: map, event: event, item: item,
                                 quantity: quantity, claims: 1, first_at: now, last_at: now)
        return :first
      end

      if repeatable && now - row[:first_at] > DAILY_WINDOW
        @db[:gift_claims].where(id: row[:id]).update(claims: 1, quantity: quantity, first_at: now, last_at: now)
        return :repeat
      end

      claims = row[:claims] + 1
      @db[:gift_claims].where(id: row[:id]).update(claims: claims, quantity: quantity, last_at: now)
      return :repeat if claims < REPEAT_MIN

      @log.call("gift: account #{account_id} SUSPECT re-farm — map #{map} event #{event} " \
                "granted #{item} #{claims} times" \
                "#{repeatable ? ' in a day (a daily event re-armed?)' : ' (one-shot event re-armed?)'}")
      :suspect
    rescue Sequel::UniqueConstraintViolation
      :repeat   # raced with itself; the row exists, nothing to judge
    rescue StandardError => e
      @log.call("gift: claim failed #{e.class}: #{e.message}")
      :bad
    end
  end
end
