# frozen_string_literal: true

module PEMK
  # M4 Layer D D8: the VERDICT SWEEP — consumes stamped battle_records verdicts and
  # turns them into monster state, on the LIVE server's worker pool (the harness
  # NEVER touches monsters; single-writer). Design: "provisional-until-verified,
  # walk-tier bite".
  #
  #   VERIFY   — a `match` record bound to a provisional mon promotes it to
  #              verify_state='verified' (releases the trade hold; the D9
  #              ranked-eligibility asset). `on` only.
  #   CONDEMN  — a `walk_mismatch` record (ingest-time seed refutation — the ONLY
  #              tier that can condemn; harness `mismatch` is version-drift-prone
  #              and only WITHHOLDS 'verified') poisons its roll and quarantines
  #              the caught mon, GATED by: MIN_STRIKES distinct refuted battles per
  #              account (drift-tolerant), and an FP-STORM breaker (suppress if a
  #              whole engine_fp cohort is failing — likely our bug / a mass event,
  #              not one cheater). `on` acts; `shadow` audits would_quarantine only.
  #
  # Idempotent: enforcement_action + enforced_at stamp each processed record; every
  # decision (including suppressions) writes an enforcement_events audit row.
  # NEVER touches EXP/money/the flagged bit; quarantine rides monsters.status only
  # (the M3.2 trade CAS already requires status='active').
  class ResimVerdicts
    STORM_ACCOUNTS = 3          # distinct accounts adverse in one cohort/window -> suppress
    STORM_WINDOW_SEC = 86_400

    def initialize(db, mode:, min_strikes: 2, logger: nil, assets: nil)
      @db      = db
      @mode    = mode          # :shadow | :on  (constructed only when != :off)
      @strikes = min_strikes
      @log     = logger || ->(_m) {}
      @assets  = assets        # C1: a quarantined token is frozen on chain (nil = off)
    end

    # One sweep. -> {verified:, quarantined:, would:, suppressed:} counts.
    def sweep(now: Time.now)
      counts = { verified: 0, quarantined: 0, would: 0, suppressed: 0 }
      verify_pass(counts, now)
      condemn_pass(counts, now)
      total = counts.values.sum
      @log.call("resim: sweep — #{counts.map { |k, v| "#{v} #{k}" }.join(', ')}") if total.positive?
      counts
    rescue StandardError => e
      @log.call("resim: sweep failed #{e.class}: #{e.message}")
      counts
    end

    private

    # A record is still ACTIONABLE if it was never processed (NULL) — and, in `on`,
    # ALSO if it was only SHADOW-observed (would_*). So flipping shadow->on
    # re-adjudicates the observation-period records instead of the shadow verdict
    # permanently burning the on-mode idempotency slot (review-caught). Terminal
    # `on` actions (quarantined/verified/suppressed_breaker/pardoned) are excluded.
    def actionable
      @mode == :on ? Sequel.|({ enforcement_action: nil }, { enforcement_action: %w[would_quarantine would_verify] })
                   : { enforcement_action: nil }
    end

    # --- VERIFY: match -> verified ----------------------------------------------
    def verify_pass(counts, now)
      @db[:battle_records].where(replay_status: "match").where(actionable)
                          .exclude(encounter_roll_id: nil).each do |rec|
        uid = roll_uid(rec[:encounter_roll_id])
        if @mode == :on
          next if uid.nil?   # the catch hasn't minted yet -> leave actionable, retry next sweep

          changed = @db[:monsters].where(id: uid, verify_state: "provisional").update(verify_state: "verified")
          if changed.positive?
            audit(rec[:account_id], "verify", uid, rec[:id], "match -> verified", now)
            counts[:verified] += 1
          end
          stamp(rec[:id], "verified", now)   # terminal: mon exists (promoted, or already handled)
        else
          audit(rec[:account_id], "would_verify", uid, rec[:id], "match (shadow)", now)
          stamp(rec[:id], "would_verify", now)
          counts[:verified] += 1
        end
      end
    end

    # --- CONDEMN: walk_mismatch -> quarantine, per account ----------------------
    def condemn_pass(counts, now)
      accounts = @db[:battle_records]
                 .where(replay_status: "walk_mismatch").where(actionable)
                 .distinct.select_map(:account_id)

      accounts.each do |account_id|
        pending = @db[:battle_records]
                  .where(account_id: account_id, replay_status: "walk_mismatch").where(actionable)
                  .order(:id).all
        next if pending.empty?

        if storm_suppressed?(pending, now)
          # DO NOT stamp — leave the records actionable so a transient storm doesn't
          # permanently forgive them; re-adjudicated once the cohort recovers. Audit
          # once per record so a persistent storm doesn't spam the trail.
          pending.each do |rec|
            audit_once(account_id, "suppression", rec, "fp-storm cohort (>= #{STORM_ACCOUNTS} accts)", now)
            counts[:suppressed] += 1
          end
          next
        end

        # Strikes = the account's refuted battles, EXCLUDING ones an operator pardoned
        # (else a pardoned honest player stays armed for instant re-quarantine). Counted
        # as total - pardoned so NULL enforcement_action rows (the un-actioned strikes)
        # are NOT dropped by a NULL-unsafe `!= 'pardoned'`.
        base    = @db[:battle_records].where(account_id: account_id, replay_status: "walk_mismatch")
        strikes = base.count - base.where(enforcement_action: "pardoned").count
        next if strikes < @strikes   # under threshold: leave actionable, revisit as strikes grow

        pending.each { |rec| condemn(account_id, rec, counts, now) }
      end
    end

    def condemn(account_id, rec, counts, now)
      roll_id = rec[:encounter_roll_id]
      if @mode == :on
        # poison + quarantine + audit + stamp in ONE transaction: a crash mid-condemn
        # rolls the record back to actionable, so re-run is exactly-once. LOCK the roll
        # FOR UPDATE and read its uid link INSIDE the txn so a concurrent mint claim
        # (which also locks the row) can't slip a catch through as active — it either
        # commits first (we see its uid -> quarantine the mon) or waits and then births
        # the mon quarantined off our condemned_at.
        @db.transaction do
          @db[:encounter_rolls].where(id: roll_id).for_update.first if roll_id
          uid = roll_uid(roll_id)
          @db[:encounter_rolls].where(id: roll_id).update(condemned_at: now) if roll_id   # poison unclaimed catch
          if uid
            n = @db[:monsters].where(id: uid, status: "active").update(
              status: "quarantined", quarantined_at: now,
              quarantine_reason: "walk_mismatch", quarantine_record_id: rec[:id]
            )
            @assets.freeze(uid, account_id, reason: "walk_mismatch", now: now) if @assets && n.positive?   # C1
          end
          audit(account_id, "quarantine", uid, rec[:id], "walk_mismatch, strikes>=#{@strikes}", now)
          stamp(rec[:id], "quarantined", now)
        end
        counts[:quarantined] += 1
      else
        audit(account_id, "would_quarantine", roll_uid(roll_id), rec[:id], "walk_mismatch, strikes>=#{@strikes} (shadow)", now)
        stamp(rec[:id], "would_quarantine", now)
        counts[:would] += 1
      end
    end

    # An FP storm: >= STORM_ACCOUNTS distinct accounts adverse in the SAME engine_fp
    # cohort within the window. Walk-tier is cryptographic (drift can't cause it), so
    # a cohort-wide failure is more likely OUR bug or a mass event than one cheater —
    # suppress and let a human look. Records with no engine_fp never storm-suppress.
    def storm_suppressed?(pending, now)
      fps = pending.map { |r| r[:engine_fp] }.compact.uniq
      fps.any? do |fp|
        @db[:battle_records]
          .where(engine_fp: fp, replay_status: %w[walk_mismatch mismatch])
          .where { created_at > now - STORM_WINDOW_SEC }
          .distinct.select_map(:account_id).length >= STORM_ACCOUNTS
      end
    end

    def roll_uid(roll_id)
      roll_id && @db[:encounter_rolls].where(id: roll_id).get(:claimed_monster_uid)
    end

    def stamp(record_id, action, now)
      @db[:battle_records].where(id: record_id).update(enforcement_action: action, enforced_at: now)
    end

    def audit(account_id, kind, uid, record_id, detail, now)
      @db[:enforcement_events].insert(
        account_id: account_id, kind: kind, monster_uid: uid,
        record_id: record_id, detail: detail, created_at: now
      )
    end

    # Audit at most once per (record, kind) — for the re-adjudicated suppression path.
    def audit_once(account_id, kind, rec, detail, now)
      return if @db[:enforcement_events].where(record_id: rec[:id], kind: kind).count.positive?

      audit(account_id, kind, roll_uid(rec[:encounter_roll_id]), rec[:id], detail, now)
    end
  end
end
