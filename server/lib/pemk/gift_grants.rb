# frozen_string_literal: true

module PEMK
  # Step 6 of sovereign variables: the payout gate (PEMK_GIFT_ENFORCE).
  #
  # GiftClaims records after the fact who got what. This is the gate in front of it: a
  # one-shot NPC gift is paid only when the server grants it, and once per account, so
  # an event re-armed by an edit (its self-switch cleared) cannot pay a second time.
  #
  # The bag is the client's, restored at login from the server's :inv record, so a
  # payout is on the record exactly when a bag snapshot holding it has landed. Each
  # grant walks:
  #
  #   granted  the server said yes to request +nonce+, sent on connection +conn+
  #   applied  the client reports the item in its bag (:gift_applied)
  #   sealed   a bag snapshot landed after that: every later request is refused
  #   void     a fresh login found it unsealed; the bag that login loads cannot hold
  #            it, so the next request is a first one again
  #
  # The client holds its bag flushes from the request until its :gift_applied is out,
  # and TCP keeps the order, so no snapshot seals a payout it does not hold. A grant
  # still "granted" when its connection is gone is sealed by the first snapshot of a
  # later one: a reconnecting client re-sends every gift it still waits for before it
  # flushes its bag, so one it did not re-send was applied (its report lost with the
  # socket).
  class GiftGrants
    DENY_FLAG = 3   # refusals of one paid gift before the account goes to review

    def initialize(db, logger: nil)
      @db  = db
      @log = logger || ->(_m) {}
    end

    # -> [:grant, nil, 0] | [:grant, "again", 0] (the same request, its reply lost) |
    # [:deny, "already_claimed", times refused]. Serialized per account on the mailbox.
    def request(account_id, map, event, item, quantity, nonce, conn:, now: Time.now)
      key = { account_id: account_id, map: map, event: event }
      row = @db[:gift_grants].where(key).first
      fresh = { item: item, quantity: quantity, nonce: nonce, state: "granted", conn: conn,
                granted_at: now, updated_at: now }

      if row.nil?
        if legacy_paid?(account_id, map, event)
          # Paid while the gate was off: the detection ledger saw it.
          @db[:gift_grants].insert(key.merge(fresh).merge(nonce: nil, state: "sealed", conn: nil, denied: 1))
          return [:deny, "already_claimed", 1]
        end
        @db[:gift_grants].insert(key.merge(fresh))
        return [:grant, nil, 0]
      end

      if row[:state] == "void"
        @db[:gift_grants].where(key).update(fresh)
        return [:grant, nil, 0]
      end

      if row[:state] == "granted" && row[:nonce] == nonce
        # The same request again: its reply was lost with a socket. It rides this one now.
        @db[:gift_grants].where(key).update(conn: conn, updated_at: now)
        return [:grant, "again", 0]
      end

      denied = row[:denied] + 1
      @db[:gift_grants].where(key).update(denied: denied, updated_at: now)
      [:deny, "already_claimed", denied]
    end

    # Would a request for this event be a new payout (never granted, or voided)? One
    # asked again, or already paid, is not.
    def first_time?(account_id, map, event)
      row = @db[:gift_grants].where(account_id: account_id, map: map, event: event).first
      row.nil? || row[:state] == "void"
    end

    # :gift_applied - the client holds the payout of request +nonce+. -> true when it
    # moved a grant (a stale or unknown nonce changes nothing).
    def applied(account_id, map, event, nonce, now: Time.now)
      @db[:gift_grants].where(account_id: account_id, map: map, event: event, nonce: nonce, state: "granted")
                       .update(state: "applied", updated_at: now).positive?
    end

    # A bag snapshot landed on connection +conn+: every payout it holds is on the
    # record. -> rows sealed.
    def seal(account_id, conn, now: Time.now)
      return 0 unless conn.is_a?(Integer)   # nil would read "any connection" and seal all

      earlier =Sequel.&({ state: "granted" }, Sequel.~(conn: conn))
      @db[:gift_grants].where(account_id: account_id)
                       .where(Sequel.|({ state: "applied" }, earlier))
                       .update(state: "sealed", updated_at: now)
    end

    # A bag snapshot the record adopted grew by +increases+ ({ "ITEM" => n }): a payout of
    # that size has reached the record, whatever the client reported - a client that never
    # sends :gift_applied can no longer keep its payout unsealed. -> rows sealed.
    def seal_arrived(account_id, increases, now: Time.now)
      return 0 if increases.empty?

      rows = @db[:gift_grants].where(account_id: account_id, state: %w[granted applied], item: increases.keys).all
      arrived = rows.select { |r| increases[r[:item]].to_i >= r[:quantity].to_i }
      arrived.each do |r|
        @db[:gift_grants].where(account_id: account_id, map: r[:map], event: r[:event]).update(state: "sealed", updated_at: now)
      end
      arrived.size
    end

    # A fresh login loads the stored bag, which holds no unsealed payout: voided, so the
    # event pays again - once. A payout voided before stays paid: a crash may cost it once,
    # but a client cannot have it paid again at every login. -> rows voided.
    def void_unsealed(account_id, now: Time.now)
      open = @db[:gift_grants].where(account_id: account_id, state: %w[granted applied])
      kept = open.where { voids >= 1 }.update(state: "sealed", updated_at: now)
      n = open.where(voids: 0).update(state: "void", voids: Sequel[:voids] + 1, updated_at: now)
      @log.call("gift: account #{account_id} — #{n} unsealed grant(s) void at login") if n.positive?
      if kept.positive?
        @log.call("gift: account #{account_id} — #{kept} unsealed grant(s) voided before: kept as paid")
      end
      n
    end

    private

    def legacy_paid?(account_id, map, event)
      @db[:gift_claims].where(account_id: account_id, map: map, event: event).count.positive?
    end
  end
end
