# frozen_string_literal: true

module PEMK
  # Server-authoritative trading — the atomic ownership swap (M3.2). This is the
  # single security invariant of the whole feature: a trade moves owner_account_id
  # for every uid in ONE @db.transaction or none of them move. Everything else
  # (handshake, escrow, UI) is UX layered on top and cannot violate this.
  #
  # Threats defeated here, regardless of what a fully-modified client does:
  #  - DUPE: all uids are FOR UPDATE-locked in ascending id order (a deadlock-free
  #    total order), each CAS requires owner==seller, and the summed rowcount must
  #    equal the expected count or the WHOLE trade rolls back. Two concurrent trades
  #    over a shared uid serialize on the lock; the loser re-evaluates its CAS
  #    against the new owner, matches 0 rows, and aborts.
  #  - THEFT: the CAS `owner_account_id == seller` clause matches 0 rows for any uid
  #    the seller does not currently own -> abort.
  #  - FLAGGED/CLONED laundering: `flagged == false` in the CAS gates them out.
  #  - REPLAY: the pre-swap trade_id check + UNIQUE(trade_id, uid) make a re-sent
  #    swap an idempotent no-op.
  # NOT secured here (M4): the traded Pokémon OBJECT's stat/acquisition legality.
  class Trades
    HOLD_TTL_SEC = 3600   # D8: fail-open window for a provisional catch's trade hold

    def initialize(db, resim: :off, assets: nil)
      @db    = db
      @resim = resim   # D8: :on adds the provisional trade hold (walk-gated release)
      @assets = assets # C1: the chain's outbox (nil = off) - a tokenized uid's move gets its receipt
    end

    # -> [:ok, {a_recv:, b_recv:}] | [:ok_replay, {a_recv:, b_recv:}] | [:abort, reason]
    def execute_trade(trade_id, a:, b:, a_gives:, b_gives:, now: Time.now)
      result = nil
      @db.transaction do
        if @db[:monster_transfers].where(trade_id: trade_id).count.positive?
          result = [:ok_replay, replay_view(trade_id, a, b)]     # idempotent re-ack; NO re-swap
          next
        end

        all_uids = (a_gives + b_gives).uniq.sort
        @db[:monsters].where(id: all_uids).order(:id).for_update.select(:id).all  # LOCK ascending -> deadlock-free

        # D8: a seeded catch is provisional until its battle record's seed WALK clears
        # (usually seconds) — held from trades so a to-be-condemned mon can't be
        # laundered onto a partner inside the verdict window. Quarantined mons are
        # already blocked by the CAS (status='active'); this covers the pre-verdict
        # window, TTL fail-open so a dead harness never bricks trading.
        if @resim == :on && held_provisional?(all_uids, now)
          result = [:abort, :unverified]
          raise Sequel::Rollback
        end

        moved = 0
        rows  = []
        a_gives.each { |u| moved += cas(u, a, b, now); rows << xfer(trade_id, u, a, b, now) }
        b_gives.each { |u| moved += cas(u, b, a, now); rows << xfer(trade_id, u, b, a, now) }

        if moved != (a_gives.size + b_gives.size)
          result = [:abort, :ownership]
          raise Sequel::Rollback                                  # WHOLE trade rolls back — nothing moved
        end

        @db[:monster_transfers].multi_insert(rows)                # UNIQUE(trade_id, uid) dedup
        if @assets                                                # C1: receipts, same commit or none
          a_gives.each { |u| @assets.transfer(u, from: a, to: b, ref: trade_id, now: now) }
          b_gives.each { |u| @assets.transfer(u, from: b, to: a, ref: trade_id, now: now) }
        end
        yield if block_given?                                     # the caller's rows, in the same commit
        result = [:ok, { a_recv: b_gives, b_recv: a_gives }]
      end
      result
    end

    private

    # The theft gate AND the singularity gate. -> rowcount 0 | 1.
    def cas(uid, seller, buyer, now)
      @db[:monsters]
        .where(id: uid, owner_account_id: seller, status: "active", flagged: false)
        .update(owner_account_id: buyer, updated_at: now)
    end

    def xfer(trade_id, uid, from, to, now)
      { uid: uid, from_account_id: from, to_account_id: to, trade_id: trade_id, created_at: now }
    end

    # Any provisional uid whose seed walk hasn't cleared? (trade_max=1 -> <=2 uids).
    # Released as soon as the bound record ingests a non-refuting walk; held while
    # the record is still pending (or refuted), until the fail-open TTL.
    def held_provisional?(uids, now)
      prov = @db[:monsters].where(id: uids, verify_state: "provisional").select_map(:id)
      prov.any? do |uid|
        roll = @db[:encounter_rolls].where(claimed_monster_uid: uid).order(Sequel.desc(:id)).first
        status = roll && @db[:battle_records].where(encounter_roll_id: roll[:id]).order(Sequel.desc(:id)).get(:replay_status)
        if status == "walk_mismatch"
          true                                                   # condemned — hold hard (pre-quarantine window)
        elsif status.nil? || status == "pending"
          # not walk-cleared -> hold, but FAIL-OPEN: a missing roll or a NULL caught_at
          # (no record will ever arrive) must RELEASE, never hold forever. Held only
          # while a real caught_at is still inside the TTL.
          !!(roll && roll[:caught_at] && (now - roll[:caught_at]) < HOLD_TTL_SEC)
        else
          false                                                  # walk ran, didn't refute -> released
        end
      end
    end

    def replay_view(trade_id, a, b)
      rows = @db[:monster_transfers].where(trade_id: trade_id).all
      { a_recv: rows.select { |r| r[:to_account_id] == a }.map { |r| r[:uid] },
        b_recv: rows.select { |r| r[:to_account_id] == b }.map { |r| r[:uid] } }
    end
  end
end
