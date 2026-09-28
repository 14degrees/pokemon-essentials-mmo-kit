# frozen_string_literal: true

module PEMK
  # Item authority E2: every increase of an item the player possesses must be explained by
  # a source the server knows.
  #
  # The possession is the bag, the PC storage, the mailbox and the held items together
  # (E0 keeps them in one record), so moving an item between them changes nothing here.
  # A decrease - an item used, sold, tossed, handed to an NPC - is the client's business
  # and always accepted. An increase takes the account's credits for that item, oldest
  # first. A credit is what a source left: a pickup the server granted, a gift it paid, a
  # purchase it made, the item a traded Pokemon brought.
  #
  # A source can also be heard after the increase it explains (a pickup reported once its
  # message closed, while the bag went out during the message), so what no credit covers
  # becomes a debt that a credit arriving within its grace pays. A debt still open then is
  # an unexplained increase. Rows: qty > 0 is a credit, qty < 0 a debt.
  #
  # Enforcement (E4): a debt past its grace is not dropped but kept OWED - the client is
  # asked to take its units back - until they leave the possession: a decrease settles
  # the item's open debts first, owed then pending. A late credit pays a pending debt,
  # never an owed one (its correction may already be applied).
  class ItemLedger
    CREDIT_TTL      = 30 * 60           # a credit no snapshot took by then was never applied (a crash, a full bag)
    GIFT_CREDIT_TTL = 7 * 24 * 3600     # an owed gift may be applied long after its grant
    GRACE           = 120               # how long an increase waits for its source
    SETTLE_BATCH    = 500
    OWED_UNTIL      = Time.utc(9999, 1, 1)   # an owed debt waits for its units, not for a clock

    PENDING = "seen"   # a debt within its grace
    OWED    = "owed"   # a debt whose verdict fell: its units are to be taken back

    attr_reader :grace

    def initialize(db, grace: GRACE)
      @db    = db
      @grace = grace
    end

    # +qty+ of +item+ came from +source+. It pays the item's pending debts first, oldest
    # first; the rest waits as a credit. -> the part kept as a credit.
    def credit(account_id, item, qty, source:, ref: nil, now: Time.now)
      return 0 unless item && qty.is_a?(Integer) && qty.positive?

      left = qty - take(debts(account_id, item, PENDING), qty)
      if left.positive?
        ttl = source.to_s == "gift" ? GIFT_CREDIT_TTL : CREDIT_TTL
        @db[:item_credits].insert(account_id: account_id, item: item.to_s, qty: left, source: source.to_s,
                                  ref: ref&.to_s, created_at: now, expires_at: now + ttl)
      end
      left
    end

    # One snapshot the record adopted: +prev+ and +cur+ are {"ITEM" => count} over the
    # same stores. Each increase beyond +allow+ takes credits; the rest becomes a debt,
    # except for a +local+ item (E2b: one this game can produce unseen), which is
    # recorded and never judged. -> { "ITEM" => count left owing }
    def judge(account_id, prev, cur, allow: {}, local: nil, now: Time.now)
      owing = {}
      cur.each do |item, n|
        up = n.to_i - prev[item].to_i - allow[item].to_i
        next unless up.positive?

        missing = up - take(credits(account_id, item, now), up)
        next unless missing.positive? && !local&.include?(item)

        @db[:item_credits].insert(account_id: account_id, item: item.to_s, qty: -missing, source: PENDING,
                                  created_at: now, expires_at: now + @grace)
        owing[item] = missing
      end
      owing
    end

    # E4: units that left the possession ({ "ITEM" => n }) settle the item's open debts,
    # owed first (a correction applied), then pending.
    # -> [{ "ITEM" => pending debts settled } (increases spent before their verdict),
    #     { "ITEM" => debts settled in all }]
    def settle_decreases(account_id, down)
      spent = {}
      settled = {}
      down.each do |item, n|
        next unless n.is_a?(Integer) && n.positive?

        k = take(debts(account_id, item, OWED), n)
        k2 = take(debts(account_id, item, PENDING), n - k)
        spent[item] = k2 if k2.positive?
        settled[item] = k + k2 if (k + k2).positive?
      end
      [spent, settled]
    end

    # The debts past their grace, after a last look for a credit that came late.
    # +keep+ (E4): (account_id, item) -> true keeps the rest OWED instead of dropping it.
    # -> [{ account_id:, item:, qty:, since:, owed: }], the unexplained increases. Credits
    # past their time go too.
    def settle(now: Time.now, keep: nil)
      @db[:item_credits].where(Sequel[:qty] > 0).where(Sequel[:expires_at] <= now).delete
      due = @db[:item_credits].where(source: PENDING).where(Sequel[:qty] < 0).where(Sequel[:expires_at] <= now)
                              .order(:id).limit(SETTLE_BATCH).select_map(:id)
      due.filter_map do |id|
        @db.transaction do
          d = @db[:item_credits].where(id: id).for_update.first
          next nil unless d && d[:qty].negative? && d[:source] == PENDING   # paid in the meantime

          rest = -d[:qty] - take(credits(d[:account_id], d[:item], now), -d[:qty])
          owed = rest.positive? && keep ? keep.call(d[:account_id], d[:item]) : false
          if owed
            @db[:item_credits].where(id: id).update(qty: -rest, source: OWED, expires_at: OWED_UNTIL)
          else
            @db[:item_credits].where(id: id).delete
          end
          { account_id: d[:account_id], item: d[:item], qty: rest, since: d[:created_at], owed: owed } if rest.positive?
        end
      end
    end

    # { "ITEM" => n } of the account's open debts (pending and owed), or of +kind+ alone.
    def open_debts(account_id, kind = nil)
      ds = @db[:item_credits].where(account_id: account_id).where(Sequel[:qty] < 0)
      ds = ds.where(source: kind) if kind
      ds.group(:item).select_map([:item, Sequel.function(:sum, :qty).as(:total)]).to_h { |i, t| [i, -t.to_i] }
    end

    def owed(account_id)
      open_debts(account_id, OWED)
    end

    # Owed debts that are no longer to be corrected (an item local since, a key item).
    def drop_owed(account_id, items)
      return 0 if items.empty?

      @db[:item_credits].where(account_id: account_id, source: OWED, item: items.map(&:to_s)).delete
    end

    # A fresh login loads the record, which holds no item a waiting credit was for: the
    # credits go. Debts stay - what was seen was seen.
    def drop_credits(account_id)
      @db[:item_credits].where(account_id: account_id).where(Sequel[:qty] > 0).delete
    end

    private

    def credits(account_id, item, now)
      @db[:item_credits].where(account_id: account_id, item: item.to_s).where(Sequel[:qty] > 0)
                        .where(Sequel[:expires_at] > now).order(:id).for_update.all
    end

    def debts(account_id, item, kind = nil)
      ds = @db[:item_credits].where(account_id: account_id, item: item.to_s).where(Sequel[:qty] < 0)
      ds = ds.where(source: kind) if kind
      ds.order(:id).for_update.all
    end

    # Takes up to +want+ units from +rows+ (credits or debts), oldest first. -> taken.
    def take(rows, want)
      left = want
      rows.each do |r|
        break if left <= 0

        have = r[:qty].abs
        n = [have, left].min
        left -= n
        if n == have
          @db[:item_credits].where(id: r[:id]).delete
        else
          @db[:item_credits].where(id: r[:id]).update(qty: r[:qty].positive? ? have - n : n - have)
        end
      end
      want - left
    end
  end
end
