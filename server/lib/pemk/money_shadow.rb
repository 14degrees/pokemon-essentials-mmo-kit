# frozen_string_literal: true

module PEMK
  # Money authority M1b (shadow): what M2 and M3 would keep and refuse, measured.
  #
  # Per account, S - the balance M2 would keep: the prizes it would pay, the server's
  # own deals, the spends - and C - the client's balance as the server last knew it. A
  # fresh money frame of value v logs what no source explains and was not already above
  # S: max(0, v - S) - max(0, C - S); then S = min(S, v) and C = v. The excess is derived
  # each time, never kept, so a conjure after a spend, or back up to an old peak, is
  # logged again. S is never floored: a purchase S cannot cover is logged as such.
  #
  # A row is seeded at the account's first claim, deal or frame with the measurement on,
  # from the ledger balance before that event applies - the start money when the ledger
  # has no row yet (a new account's login seed is its starting money, not a gain).
  # Every call runs on the account's mailbox, or inside its deal's transaction.
  class MoneyShadow
    def initialize(db, start_money:, cap:)
      @db = db
      @start_money = start_money.is_a?(Integer) ? start_money : 0
      @cap = cap
    end

    # -> [s, c], the row seeded from +before+ (the ledger balance before the event, nil
    # when the ledger has no row) if the account has none yet.
    def row(account_id, before)
      r = @db[:money_shadow].where(account_id: account_id).first
      return [r[:s], r[:c]] if r

      base = before.nil? ? @start_money : before
      @db[:money_shadow].insert(account_id: account_id, s: base, c: base, updated_at: Time.now)
      [base, base]
    end

    # A claim judged payable: M2 would pay +amount+.
    def claim(account_id, amount, before:)
      s, = row(account_id, before)
      set(account_id, s: [s + amount, @cap].min)
    end

    # A claim a fresh login voided: its battle may be fought again, and its prize never
    # reached the ledger.
    def void(account_id, amount, before:)
      s, = row(account_id, before)
      set(account_id, s: s - amount)
    end

    # A deal the server made (Ledger#adjust, acked) moves both - but S only for a source
    # the server owns (+credit+ false: a sale of items it never judged). -> what S could not
    # cover of a purchase (0 when it could).
    def deal(account_id, delta, before:, credit: true)
      s, c = row(account_id, before)
      s2 = credit ? s + delta : s
      set(account_id, s: s2, c: c + delta)
      return 0 if delta >= 0 || s2 >= 0

      [-s2, -delta].min
    end

    # A claim refused as already paid: the next frame shows its prize again. That part of
    # the frame's excess is a repeat - a crash may have undone the save's record of the
    # win - logged apart from money no source explains.
    def repeat(account_id, amount, before:)
      row(account_id, before)
      @db[:money_shadow].where(account_id: account_id)
                        .update(repeat: Sequel[:repeat] + amount, updated_at: Time.now)
    end

    # A fresh, acked frame of value +v+ from the account's current connection.
    # -> [the money it shows that no source explains, newly; the part a repeat explains].
    # The next frame consumes the pending repeat, whether or not it showed.
    def frame(account_id, v, before:)
      s, c = row(account_id, before)
      pending = @db[:money_shadow].where(account_id: account_id).get(:repeat).to_i
      d = [[v - s, 0].max - [c - s, 0].max, 0].max
      r = [d, pending].min
      set(account_id, s: [s, v].min, c: v, repeat: 0)
      [d - r, r]
    end

    # A fresh login adopts the ledger balance through a setter that sends no frame.
    def login(account_id, balance)
      @db[:money_shadow].where(account_id: account_id).update(c: balance, updated_at: Time.now)
    end

    def self.clear(db)
      db[:money_shadow].delete
    end

    private

    def set(account_id, **fields)
      @db[:money_shadow].where(account_id: account_id).update(fields.merge(updated_at: Time.now))
    end
  end
end
