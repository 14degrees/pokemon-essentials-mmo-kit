# frozen_string_literal: true

module PEMK
  # M4 Layer D D3 part 2: the durable record of server-minted wild encounters. Every D2
  # `on` mint is persisted here (record), the D3 catch verdict stamps caught_at
  # (mark_caught), and the caught mon's M3 UID mint claims the roll (claim) — which is
  # what lets Monsters label each minted identity's PROVENANCE: the pid the client
  # reports either matches a roll the server actually issued, or it doesn't.
  #
  # All three writes run under the per-account PlayerMailbox (FIFO), and the natural
  # gameplay order — encounter -> catch -> next sync flush's uid_req — means the roll is
  # recorded and caught-stamped before the mint tries to claim it. Claimed/caught rolls
  # are kept as audit; stale never-fought rolls are pruned at boot (retention window).
  #
  # HONEST label semantics (do not oversell):
  #   wild_caught — the identity was server-issued AND its capture passed the server
  #                 catch verdict. The strongest label (but D3.1's ball claim is still
  #                 unvalidated, and IVs/EVs/moves are not bound by the uid mint).
  #   wild        — the identity was server-issued but NO catch verdict exists: either
  #                 catches enforcement was off, or a cheat fabricated a mon from a
  #                 FLED encounter's grant. "Server-issued", not "legitimately obtained".
  #   client      — no matching roll. Legitimate for starters/gifts/eggs/events, which
  #                 is why it can never reject; suspicious only in volume for species
  #                 that exist in wild tables.
  class EncounterRolls
    RETENTION_DAYS = 7   # never-fought, never-claimed rolls older than this are pruned
    def initialize(db)
      @db = db
    end

    # Boot-time retention: drop stale rolls that were never caught and never claimed
    # (fled/abandoned encounters — the overwhelming majority). Caught or claimed rows
    # are audit and are kept — and so is any roll a D7 battle record references
    # (pruning it would SET NULL the record's binding and re-open the seed's
    # single-use constraint). -> rows deleted.
    def prune(now: Time.now, days: RETENTION_DAYS)
      cutoff = now - (days * 86_400)
      ds = @db[:encounter_rolls]
           .where(caught_at: nil, claimed_at: nil)
           .where { created_at < cutoff }
      if @db.table_exists?(:battle_records)
        ds = ds.exclude(id: @db[:battle_records].exclude(encounter_roll_id: nil).select(:encounter_roll_id))
      end
      ds.delete
    end

    # Persist a D2 mint (String-keyed hash from EncounterMint#roll). -> row id.
    def record(account_id, mint, map, enctype, seed: nil, now: Time.now)
      @db[:encounter_rolls].insert(
        account_id: account_id,
        species:    mint["species"].to_s,
        level:      mint["level"],
        pid:        mint["pid"],
        iv:         Sequel.pg_jsonb(Array(mint["iv"])),
        shiny:      mint["shiny"] == true,
        map:        map,
        enctype:    enctype.to_s,
        battle_seed: seed,   # D7: the 63-bit PCG32 seed born with this mint (nil = rng off)
        created_at: now
      )
    end

    # Stamp the roll as caught (D3 verdict). Matches the newest uncaught roll with this
    # identity — idempotent-ish: a re-stamp of an already-caught roll is a no-op.
    def mark_caught(account_id, species, level, pid, now: Time.now)
      id = @db[:encounter_rolls]
           .where(account_id: account_id, species: species.to_s, level: level, pid: pid, caught_at: nil)
           .order(Sequel.desc(:id)).limit(1).get(:id)
      return false unless id

      @db[:encounter_rolls].where(id: id).update(caught_at: now)
      true
    end

    # Claim the roll backing a UID mint of (species, pid): caught-stamped rolls first,
    # then oldest. -> :wild_caught | :wild (claimed; caught-stamped or not) | nil (no
    # matching roll -> the identity was not server-issued). Runs inside mint_batch's
    # transaction, so a crashed mint never leaves a half-claimed roll.
    #
    # Level is deliberately NOT part of the claim key: the client sweep reports the
    # level at FLUSH time, and a mon that leveled between a delayed first flush and a
    # retry would otherwise mislabel "client" AND strand a claimable wild_caught roll.
    # species+pid is already 2^-32-selective per account.
    def claim(account_id, species, pid, now: Time.now)
      # FOR UPDATE: serialize against a concurrent D8 condemn on the SAME roll (both
      # lock the row) so a catch can never claim-then-birth-active in the gap where a
      # sweep is poisoning its roll. Runs inside mint_batch's transaction.
      row = @db[:encounter_rolls]
            .where(account_id: account_id, species: species.to_s, pid: pid, claimed_at: nil)
            .order(Sequel.lit("caught_at IS NULL"), :id).limit(1).for_update.first
      return nil unless row

      @db[:encounter_rolls].where(id: row[:id]).update(claimed_at: now)
      # D8 needs the roll's enforcement context at birth: the seed (a record is
      # owed -> provisional) and a possible walk-refutation (condemned -> the mon
      # is born quarantined). The uid is stamped right after the mint inserts
      # (stamp_claim) — same mint_batch transaction, so the link is crash-atomic.
      { label: row[:caught_at] ? :wild_caught : :wild,
        id: row[:id], battle_seed: row[:battle_seed], condemned_at: row[:condemned_at],
        shiny: row[:shiny] == true }   # C1: a server-minted shiny is the one the chain may take
    end

    # The roll->mon link (the ONLY direction stored; mon->roll derives by join).
    def stamp_claim(roll_id, uid)
      @db[:encounter_rolls].where(id: roll_id).update(claimed_monster_uid: uid)
    end
  end
end
