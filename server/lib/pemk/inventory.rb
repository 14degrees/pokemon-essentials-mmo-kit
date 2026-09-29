# frozen_string_literal: true

module PEMK
  # Server-side BAG record, DETECTION-ONLY. The client pushes the WHOLE bag as an
  # absolute {item_id => qty} snapshot (reconnect-safe + self-healing, exactly like
  # Ledger#apply_econ takes the absolute post-clamp value). We RECORD it and
  # structurally FLAG anomalies, but NEVER reject/roll back: without a GameData::Item
  # registry and server-side gameplay (M3) we cannot validate item ACQUISITION. A
  # modified client can send a fully plausible within-cap bag of real-id items and
  # pass every check — same caveat as the economy ledger. The bag stays
  # blob-authoritative in M2.3; this row is a detection shadow + the trading
  # foundation.
  #
  # Idempotent by nature (an absolute snapshot) -> a simple last_seq high-water dedup,
  # NOT economy_ledger's gap-safe per-(account,field,seq) scheme (row-existence would
  # wrongly accept a replayed OLDER whole-bag). Runs under the per-account
  # PlayerMailbox — :inv/:econ/:save AND the login/auth state read all ride the
  # same box, so an account's mutations and reads are strictly serialized.
  class Inventory
    DIVERGENCE_MIN = 8         # only log a blob-vs-record divergence this material (coarse tamper signal)
    SHIP_MAX_BYTES = 60_000    # never ship a login bag so large it pushes login_ok past the 64 KiB wire cap
    STORE_MAX      = 4096      # entries per store map (the wire's own per-container cap)
    ITEM_ID        = /\A[A-Z0-9_]{1,64}\z/   # what an item id can be; anything else is not an item

    def initialize(db, caps, logger: nil)
      @db   = db
      @caps = caps                 # { per_item:, distinct:, total: }
      @log  = logger || ->(_m) {}
    end

    # -> [:ack, flags] | [:dup, []] | [:rej, ["bad_shape"]]
    # +stores+ (item authority E0): the other places the same snapshot counted,
    # { pc:, mail:, held:, holders: }. Recorded in the bag's row with the bag's seq, or
    # not at all (flagged bad_stores).
    def apply_inv(account_id, bag, seq, stores: nil, now: Time.now)
      return [:rej, ["bad_shape"]] unless bag.is_a?(Hash) && seq.is_a?(Integer)

      result = nil
      @db.transaction do
        row = @db[:inventory_snapshots].where(account_id: account_id).first
        if row && seq <= row[:last_seq]
          result = [:dup, []]                       # replayed/stale absolute snapshot -> re-ack, no write
        else
          flags = validate(bag)
          log_divergence(account_id, row, bag) if row
          stored   = bag.each_with_object({}) { |(k, v), h| h[k.to_s] = v }  # jsonb keys are strings
          distinct = bag.size
          total    = bag.values.sum { |v| v.is_a?(Integer) ? v : 0 }
          fields = { bag: Sequel.pg_jsonb(stored), last_seq: seq, distinct_items: distinct, total_qty: total,
                     updated_at: now }
          unless stores.nil?
            clean = clean_stores(stores)
            if clean
              fields.merge!(stores_seq: seq, pc: clean[:pc] && Sequel.pg_jsonb(clean[:pc]),
                            mailbox: Sequel.pg_jsonb(clean[:mail]), held: Sequel.pg_jsonb(clean[:held]),
                            holders: Sequel.pg_jsonb(clean[:holders]))
            else
              flags << "bad_stores"
            end
          end
          fields.merge!(flagged: !flags.empty?, flags: Sequel.pg_jsonb(flags))
          @db[:inventory_snapshots]
            .insert_conflict(target: :account_id, update: fields)  # adopt EVEN WHEN flagged, or the record drifts
            .insert(fields.merge(account_id: account_id))
          result = [:ack, flags]
        end
      end
      result
    end

    # login_ok / auth_ok: the client adopts inv_seq AND restores the bag from the
    # server record (server-persistent, like the economy — no save needed). bag is
    # nil when the account has NO record yet (unseeded): the client then keeps its
    # blob bag and the first flush seeds the record. A present bag (even {}) is
    # authoritative and overwrites the client bag on load.
    def snapshot(account_id)
      row = @db[:inventory_snapshots].where(account_id: account_id).first
      return { bag: nil, last_seq: 0 } unless row

      bag = (row[:bag] || {}).to_h
      # A tampered/oversized bag must NEVER brick login: if shipping it could push
      # login_ok past the wire envelope cap, ship nil instead (the client keeps its
      # blob bag and re-seeds the record). Legit bags are far under this.
      est = bag.sum { |k, _| k.to_s.bytesize + 14 }
      return { bag: nil, last_seq: row[:last_seq] } if est > SHIP_MAX_BYTES

      { bag: bag.transform_keys(&:to_sym), last_seq: row[:last_seq], stores: stores_for(row, est) }
    end

    # The other stores, as the login restores them: only while the last snapshot carried
    # them all (an older client sends the bag alone, and its stores would be stale), and
    # only if they still fit the login reply.
    def stores_for(row, bag_bytes)
      return nil unless row[:stores_seq] && row[:stores_seq] == row[:last_seq]

      # Only the Pokemon that hold something matter to the restore. A save written before
      # a Pokemon's uid arrived knows it by its mint nonce alone, so each comes with it.
      holders = (row[:holders] || {}).to_h.each_with_object({}) { |(u, i), h| h[u.to_i] = i.to_sym if i }
      nonces  = @db[:monsters].where(id: holders.keys, issuer_account_id: row[:account_id])
                              .select_map(%i[id client_nonce]).to_h
      out = { pc: row[:pc] && symbols(row[:pc]), mail: symbols(row[:mailbox] || {}), held: symbols(row[:held] || {}),
              holders: holders, nonces: nonces }
      est = bag_bytes + [out[:pc] || {}, out[:mail], out[:held]].sum { |m| m.sum { |k, _| k.to_s.bytesize + 14 } } +
            (holders.size + nonces.size) * 24
      est > SHIP_MAX_BYTES ? nil : out
    end

    # Every store's count of each item: what the reward audit reads Rare Candies from, so
    # a deposit does not look like a use. Bag only for a client that sends no stores.
    def self.totals(bag, stores)
      out = Hash.new(0)
      [bag, *(stores.is_a?(Hash) ? [stores[:pc], stores[:mail], stores[:held]] : [])].each do |m|
        m.each { |k, v| out[k] += v if v.is_a?(Integer) } if m.is_a?(Hash)
      end
      out
    end

    # Does the record's bag hold +qty+ of +item+? (A sale is only paid for items the
    # server has seen.) An account with no record holds nothing.
    def holds?(account_id, item, qty)
      bag = @db[:inventory_snapshots].where(account_id: account_id).get(:bag)
      bag.to_h[item.to_s].to_i >= qty
    end

    # A sale the server makes: +qty+ of +item+ leave the record's bag (and the ledger's
    # judged totals) in the same transaction as the money, so a client that keeps them
    # cannot sell the same record twice. -> false when the bag record lacks them.
    # +owed+ (E4, nil when not enforcing): the item's open debts, units the server does not
    # recognize - a sale then needs recognized ones, judged totals minus debts: a bag the
    # ledger never judged (bag-only snapshots) sells nothing it has not seen.
    def take_sold(account_id, item, qty, owed: nil, now: Time.now)
      row = @db[:inventory_snapshots].where(account_id: account_id).for_update.first
      bag = (row && row[:bag]).to_h
      return false unless bag[item.to_s].to_i >= qty
      return false if owed && (row[:judged].nil? || row[:judged].to_h[item.to_s].to_i - owed < qty)

      bag[item.to_s] -= qty
      bag.delete(item.to_s) if bag[item.to_s] <= 0
      fields = { bag: Sequel.pg_jsonb(bag), updated_at: now }
      fields[:judged] = Sequel.pg_jsonb(lower(row[:judged], item, qty)) if row[:judged]
      @db[:inventory_snapshots].where(account_id: account_id).update(fields)
      true
    end

    # A purchase the server makes: its items join the record's bag (and the judged totals,
    # under +canon+'s names) in the same transaction as the money, as a sale's leave it.
    # A client that lost the answer and logs in again gets both sides of the deal back
    # from the server. +items+ { item => qty }. -> false when there is no record yet (the
    # first snapshot brings them).
    # +paid+: bought with money, so a resale draws on money the server received (M1d).
    # Battle points are the client's word until BP authority: what they buy is not counted.
    def add_bought(account_id, items, canon: ->(i) { i }, paid: true, now: Time.now)
      row = @db[:inventory_snapshots].where(account_id: account_id).for_update.first
      return false unless row && row[:bag]

      bag    = row[:bag].to_h
      judged = row[:judged] && row[:judged].to_h
      bought = row[:bought].to_h
      items.each do |item, qty|
        next unless qty.to_i.positive?

        bag[item.to_s] = bag[item.to_s].to_i + qty
        judged[canon.call(item.to_s)] = judged[canon.call(item.to_s)].to_i + qty if judged
        bought[canon.call(item.to_s)] = bought[canon.call(item.to_s)].to_i + qty if paid
      end
      fields = { bag: Sequel.pg_jsonb(bag), bought: Sequel.pg_jsonb(bought), updated_at: now }
      fields[:judged] = Sequel.pg_jsonb(judged) if judged
      @db[:inventory_snapshots].where(account_id: account_id).update(fields)
      true
    end

    # A sale spends the units the server sold first. -> how many of +qty+ it had sold.
    def take_bought(account_id, item, qty, now: Time.now)
      row = @db[:inventory_snapshots].where(account_id: account_id).for_update.first
      bought = (row && row[:bought]).to_h
      have = bought[item.to_s].to_i
      return 0 unless have.positive?

      used = [have, qty].min
      bought[item.to_s] = have - used
      bought.delete(item.to_s) unless bought[item.to_s].positive?
      @db[:inventory_snapshots].where(account_id: account_id).update(bought: Sequel.pg_jsonb(bought), updated_at: now)
      used
    end

    # A judged snapshot: no more bought units than the possession holds (+totals+, by
    # canonical id) - one used or tossed is gone, whichever unit it was.
    def clamp_bought(account_id, totals)
      row = @db[:inventory_snapshots].where(account_id: account_id).first
      bought = (row && row[:bought]).to_h
      return if bought.empty?

      clamped = bought.to_h { |item, n| [item, [n.to_i, totals[item].to_i].min] }.select { |_, n| n.positive? }
      return if clamped == bought

      @db[:inventory_snapshots].where(account_id: account_id).update(bought: Sequel.pg_jsonb(clamped))
    end

    # -> the item the record says +uid+ holds (nil: nothing), or :unknown when the record
    # never saw that Pokemon or is not whole. The snapshot lists every owned uid.
    def holder_item(account_id, uid)
      row = @db[:inventory_snapshots].where(account_id: account_id).first
      return :unknown unless row && row[:stores_seq] && row[:stores_seq] == row[:last_seq]

      holders = (row[:holders] || {}).to_h
      return :unknown unless holders.key?(uid.to_s)

      holders[uid.to_s]&.to_sym
    end

    # A Pokemon left this account in a trade: its held item leaves the record with it,
    # so a crash before the next snapshot cannot hand the item back at the next login.
    # The row is locked: a snapshot of this account landing meanwhile (its own mailbox,
    # while the swap runs on the pool) waits instead of being overwritten or overwriting.
    def drop_holder(account_id, uid, now: Time.now)
      row = @db[:inventory_snapshots].where(account_id: account_id).for_update.first
      return unless row && row[:holders]

      holders = row[:holders].to_h
      return unless holders.key?(uid.to_s)

      item = holders.delete(uid.to_s)
      unless item
        @db[:inventory_snapshots].where(account_id: account_id).update(holders: Sequel.pg_jsonb(holders), updated_at: now)
        return
      end

      held = (row[:held] || {}).to_h
      held[item] = held[item].to_i - 1
      held.delete(item) if held[item] <= 0
      fields = { holders: Sequel.pg_jsonb(holders), held: Sequel.pg_jsonb(held), updated_at: now }
      fields[:judged] = Sequel.pg_jsonb(lower(row[:judged], item, 1)) if row[:judged]   # it left with the Pokemon
      @db[:inventory_snapshots].where(account_id: account_id).update(fields)
    end

    # Headless STRUCTURAL checks -> array of reason strings. FLAG, never reject.
    # (No GameData::Item on a headless server, so item-id existence is out of reach.)
    def validate(bag)
      flags = []
      flags << "bad_key"        unless bag.keys.all? { |k| k.is_a?(Symbol) && k.to_s.match?(ITEM_ID) }
      flags << "bad_qty"        unless bag.values.all? { |v| v.is_a?(Integer) && v >= 0 }
      flags << "over_item_cap"  if bag.values.any? { |v| v.is_a?(Integer) && v > @caps[:per_item] }
      flags << "too_many_items" if bag.size > @caps[:distinct]
      total = bag.values.sum { |v| v.is_a?(Integer) ? v : 0 }
      flags << "over_total"     if total > @caps[:total]
      flags
    end

    private

    # -> { pc: {"ITEM"=>n} | nil, mail:, held:, holders: {"uid"=>"ITEM"} } ready for jsonb, or nil.
    # A holder names an item the held counts must include: more Pokemon holding an item
    # than held of it would let a trade confirm an item the possession never counted.
    def clean_stores(s)
      return nil unless s.is_a?(Hash)
      return nil unless (s[:pc].nil? || counts?(s[:pc])) && counts?(s[:mail]) && counts?(s[:held])

      holders = s[:holders]
      return nil unless holders.is_a?(Hash) && holders.size <= STORE_MAX &&
                        holders.all? { |u, i| u.is_a?(Integer) && u.positive? && (i.nil? || item_id?(i)) }
      return nil if holders.values.compact.tally.any? { |i, n| n > s[:held][i].to_i }

      { pc: s[:pc] && strings(s[:pc]), mail: strings(s[:mail]), held: strings(s[:held]),
        holders: holders.each_with_object({}) { |(u, i), h| h[u.to_s] = i&.to_s } }
    end

    def counts?(h)
      h.is_a?(Hash) && h.size <= STORE_MAX &&
        h.all? { |k, v| item_id?(k) && v.is_a?(Integer) && v.positive? && v <= @caps[:per_item] }
    end

    def item_id?(k)
      k.is_a?(Symbol) && k.to_s.match?(ITEM_ID)
    end

    # +judged+ ({"ITEM" => n}) with +qty+ of +item+ gone.
    def lower(judged, item, qty)
      out = judged.to_h.dup
      out[item.to_s] = out[item.to_s].to_i - qty
      out.delete(item.to_s) if out[item.to_s] <= 0
      out
    end

    def strings(h)
      h.each_with_object({}) { |(k, v), o| o[k.to_s] = v }
    end

    def symbols(h)
      h.to_h.each_with_object({}) { |(k, v), o| o[k.to_sym] = v }
    end

    # Coarse blob-vs-record divergence signal (a save-file edit that bypassed the
    # observers shows up as a large first-post-login diff). Small diffs are EXPECTED
    # in normal play (the opaque blob pushes throttled while :inv debounces), so only
    # material divergence is logged, and NEVER as a cheat verdict.
    def log_divergence(account_id, row, bag)
      prev = row[:bag] || {}
      cur  = bag.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
      appeared    = (cur.keys - prev.keys).size
      disappeared = (prev.keys - cur.keys).size
      changed     = (cur.keys & prev.keys).count { |k| cur[k] != prev[k] }
      material    = appeared + disappeared + changed
      return if material < DIVERGENCE_MIN

      @log.call("inv: account #{account_id} bag divergence +#{appeared}/-#{disappeared}/~#{changed} (blob-vs-record signal)")
    rescue StandardError
      nil
    end
  end
end
