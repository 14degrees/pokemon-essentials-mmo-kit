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
  # becomes a debt that a credit arriving within GRACE seconds pays. A debt still open
  # then is an unexplained increase. Rows: qty > 0 is a credit, qty < 0 a debt.
  class ItemLedger
    CREDIT_TTL   = 30 * 60   # a credit no snapshot took by then was never applied (a crash, a full bag)
    GRACE        = 120       # how long an increase waits for its source
    SETTLE_BATCH = 500

    def initialize(db)
      @db = db
    end

    # +qty+ of +item+ came from +source+. It pays the item's open debts first, oldest
    # first; the rest waits as a credit. -> the part kept as a credit.
    def credit(account_id, item, qty, source:, ref: nil, now: Time.now)
      return 0 unless item && qty.is_a?(Integer) && qty.positive?

      left = qty - take(debts(account_id, item), qty)
      if left.positive?
        @db[:item_credits].insert(account_id: account_id, item: item.to_s, qty: left, source: source.to_s,
                                  ref: ref&.to_s, created_at: now, expires_at: now + CREDIT_TTL)
      end
      left
    end

    # One snapshot the record adopted: +prev+ and +cur+ are {"ITEM" => count} over the
    # same stores. Each increase beyond +allow+ takes credits; the rest becomes a debt.
    # -> { "ITEM" => count left owing }
    def judge(account_id, prev, cur, allow: {}, now: Time.now)
      owing = {}
      cur.each do |item, n|
        up = n.to_i - prev[item].to_i - allow[item].to_i
        next unless up.positive?

        missing = up - take(credits(account_id, item, now), up)
        next unless missing.positive?

        @db[:item_credits].insert(account_id: account_id, item: item.to_s, qty: -missing, source: "seen",
                                  created_at: now, expires_at: now + GRACE)
        owing[item] = missing
      end
      owing
    end

    # The debts past their grace, after a last look for a credit that came late. They are
    # removed. -> [{ account_id:, item:, qty:, since: }], the unexplained increases.
    # Credits past their time go too.
    def settle(now: Time.now)
      @db[:item_credits].where(Sequel[:qty] > 0).where(Sequel[:expires_at] <= now).delete
      due = @db[:item_credits].where(Sequel[:qty] < 0).where(Sequel[:expires_at] <= now)
                              .order(:id).limit(SETTLE_BATCH).select_map(:id)
      due.filter_map do |id|
        @db.transaction do
          d = @db[:item_credits].where(id: id).for_update.first
          next nil unless d && d[:qty].negative?   # paid in the meantime

          owed = -d[:qty] - take(credits(d[:account_id], d[:item], now), -d[:qty])
          @db[:item_credits].where(id: id).delete
          { account_id: d[:account_id], item: d[:item], qty: owed, since: d[:created_at] } if owed.positive?
        end
      end
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

    def debts(account_id, item)
      @db[:item_credits].where(account_id: account_id, item: item.to_s).where(Sequel[:qty] < 0)
                        .order(:id).for_update.all
    end

    # Takes up to +want+ units from +rows+ (credits or debts), oldest first. -> taken.
    def take(rows, want)
      left = want
      rows.each do |r|
        break if left.zero?

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
