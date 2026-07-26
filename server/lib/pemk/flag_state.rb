# frozen_string_literal: true

require "set"

module PEMK
  # Audit item 4: the server's DETECTION shadow of RPG-Maker switches, variables and
  # self-switches — the state the north star says the server must own and which, until
  # now, it could not even observe.
  #
  # The client pushes the WHOLE non-default set as an absolute snapshot (the `:inv`
  # pattern: reconnect-safe, self-healing, last_seq high-water dedup). We RECORD it and
  # flag a REWIND, but never reject: the save blob stays authoritative until the
  # world-vs-player ID partition is decided (a game-design call, not an engineering one).
  #
  # WHAT COUNTS AS A REWIND — calibrated to avoid punishing honest play:
  #   * self-switches that were ON and are now OFF => THE signal. A self-switch is the
  #     engine's "this one-shot event has happened" marker; vanilla event scripts set
  #     them and effectively never clear them, so a batch of them going OFF is a save
  #     rollback, and it is exactly what re-farms NPC gifts / TMs / key items.
  #   * switches going OFF and variables DECREASING are RECORDED but NOT flagged:
  #     both legitimately happen all the time (temp flags, countdowns, counters reset
  #     by events), so judging them would flood the queue with honest players.
  # A single self-switch clearing is tolerated (some games do reset one deliberately);
  # REWIND_MIN of them in one step is the reportable event.
  class FlagState
    REWIND_MIN   = 3       # self-switches cleared in one snapshot before it is reportable
    MAX_ENTRIES  = 4_000   # per section; beyond it the snapshot is recorded but NOT judged

    # policy: { switches: Set/Array of non-local ids, variables: ... }. The comparison
    # is only meaningful over ids the POLICY claims — a LOCAL id is legitimately absent
    # from the delta stream, and judging it would report our own scope as a divergence.
    def initialize(db, policy: nil, facts: nil, repeatable: nil, latched: nil, logger: nil)
      @db  = db
      @log = logger || ->(_m) {}
      @owned_switches = to_id_set(policy && (policy[:switches] || policy["switches"]))
      @owned_vars     = to_id_set(policy && (policy[:variables] || policy["variables"]))
      # "map:event" of events the manifest found to be on a cooldown (berry plants,
      # daily respawns - anything whose text reaches for expired?/pbSetEventTime).
      # Their self-switch is deliberately cleared when the timer elapses, so banking
      # it as a monotonic fact would restore it ON forever and the event would never
      # re-arm. The manifest has always exported this list; the ledger now reads it.
      @repeatable = Array(repeatable).map(&:to_s).to_set
      # "map:event:letter" the project writes BOTH ON and OFF - a latch, not a one-shot
      # marker. The Pokemon Institute fossil NPCs are the case that proved it: page 1
      # sets A when you hand a fossil over, page 2 clears it when you collect. Banking
      # that replays the collection page at every login (and one of the two crashes the
      # client on it). Letter-precise, unlike @repeatable: excluding a latch letter must
      # not unprotect a genuine one-shot letter on the same event.
      @latched = Array(latched).map(&:to_s).to_set
      # id <-> stable key for fact-tier switches. Keys are name-derived because the
      # compiler renumbers ids, so the stored fact survives a renumber and resolves
      # back to whatever id currently carries that name.
      @fact_key_by_id = {}
      @fact_id_by_key = {}
      (facts || {}).each do |id, key|
        @fact_key_by_id[id.to_i] = key.to_s
        @fact_id_by_key[key.to_s] = id.to_i
      end
    end

    # --- step 4: the grant-only progression ledger -----------------------------

    # Union the facts implied by an absolute snapshot into the ledger. Grant-only:
    # a rollback cannot take one back, which is what makes rewind detection moot.
    #
    # A fresh fact is PENDING. It becomes durable only once a save blob arrives that
    # contains it (commit_facts) - restoring a switch onto a save that never got what
    # the event granted beside it leaves unfinishable progress: the gym flag comes
    # back, the badge does not, and the leader will not rebattle.
    # -> number of NEW facts granted.
    def grant_facts(account_id, switches, selfsw, seq: 0, now: Time.now)
      keys = []
      switches.each { |id| (k = @fact_key_by_id[id]) && keys << k }
      selfsw.each   { |k| keys << "ss:#{k}" if bankable?(k) }
      return 0 if keys.empty?

      granted = 0
      keys.uniq.each do |k|
        n = @db[:progression_facts]
            .insert_conflict   # DO NOTHING: the set-union is the whole semantics
            .insert(account_id: account_id, fact_key: k, first_at: now,
                    granted_seq: seq.is_a?(Integer) ? seq : 0)
        granted += 1 if n
      end
      granted
    rescue StandardError => e
      @log.call("flags: grant_facts failed #{e.class}: #{e.message}")
      0
    end

    # --- repeatable events: the cooldown half -----------------------------------
    #
    # A repeatable event's self-switch is deliberately NOT a fact (it must be able to
    # clear), which leaves the rollback free to reset the timer and farm the respawn
    # early. The timestamp is the honest monotonic half - each harvest moves it
    # forward - so the server keeps the maximum and hands it back at login.
    #
    # times: { "13:17" => 1_753_000_000 }. Only events the manifest calls repeatable
    # are kept, so an eventvars entry a fan script parked there never travels.
    def note_cooldowns(account_id, times, now: Time.now)
      return 0 unless times.is_a?(Hash) && !@repeatable.empty?

      kept = 0
      seen = 0
      times.each do |key, at|
        break if (seen += 1) > MAX_ENTRIES   # hostile input must not drive an unbounded scan

        k = key.to_s
        next unless at.is_a?(Integer) && at.positive? && @repeatable.include?(k)

        @db[:event_cooldowns]
          .insert_conflict(target: %i[account_id event_key],
                           update: { at: Sequel.function(:GREATEST, Sequel[:excluded][:at],
                                                         Sequel[:event_cooldowns][:at]),
                                     updated_at: now })
          .insert(account_id: account_id, event_key: k, at: at, updated_at: now)
        kept += 1
      end
      kept
    rescue StandardError => e
      @log.call("flags: note_cooldowns failed #{e.class}: #{e.message}")
      0
    end

    # -> { "13:17" => at }. The CLIENT decides whether to apply one: it holds the live
    # eventvars and only raises a value that is missing or older, so an event that
    # legitimately expired is never re-locked.
    def cooldowns_for(account_id)
      out = {}
      @db[:event_cooldowns].where(account_id: account_id).select(:event_key, :at).each do |r|
        # The SAME filter the write side uses. It was written the other way round, so an
        # export that dropped an event from the repeatable list kept handing its stale
        # row back forever - the read and the write have to agree on what is ours.
        out[r[:event_key]] = r[:at] if @repeatable.include?(r[:event_key])
      end
      out
    rescue StandardError => e
      @log.call("flags: cooldowns_for failed #{e.class}: #{e.message}")
      {}
    end

    # The client wrote a save blob. Everything the :flags channel had sent by then is
    # inside it (Checkpoint#commit flushes the sync channels before serializing), so
    # promote those facts from pending to durable.
    #
    # A client that sends no watermark promotes everything pending: it is the pre-020
    # behaviour, and withholding facts from an older client forever is worse than the
    # narrow window this bounds. -> number promoted.
    def commit_facts(account_id, upto_seq = nil, now: Time.now)
      # The watermark is a client claim like any other: clamp it to the highest seq we
      # actually recorded, so an inflated one cannot promote a fact from a snapshot the
      # server never saw. Under-claiming stays allowed - it only defers a promotion.
      if upto_seq.is_a?(Integer)
        high = @db[:flag_snapshots].where(account_id: account_id).get(:last_seq) || 0
        upto_seq = high if upto_seq > high
      end
      ds = @db[:progression_facts].where(account_id: account_id, durable_at: nil)
      ds = ds.where { granted_seq <= upto_seq } if upto_seq.is_a?(Integer)
      ds.update(durable_at: now)
    rescue StandardError => e
      @log.call("flags: commit_facts failed #{e.class}: #{e.message}")
      0
    end

    # Login materialization: hand the client its facts AND fold them into the mirror.
    #
    # The client applies them with delta recording suppressed - it must not echo back
    # what we just sent - so without this fold the mirror would not know that state
    # exists, and the next snapshot would report our own restore as missed writes.
    # (The trust gate caught exactly that.) We know precisely what we sent, so the
    # mirror stays a live measurement instead of being invalidated.
    def materialize_facts(account_id, now: Time.now)
      f = facts_for(account_id)
      # Cooldowns ride the same login payload but are NOT folded into the mirror: the
      # client decides whether each one applies (it holds the live eventvars), so the
      # server cannot know what it wrote. eventvars is outside the mirror anyway.
      f[:event_times] = cooldowns_for(account_id)
      return f if f[:switches].empty? && f[:self_switches].empty?

      row = @db[:flag_snapshots].where(account_id: account_id).first
      return f unless row && row[:mirror].respond_to?(:to_h)

      mirror = row[:mirror].to_h
      f[:switches].each     { |id| mirror["sw/#{id}"] = true if owned_switch?(id) }
      f[:self_switches].each { |k| mirror["ss/#{k}"] = true }
      @db[:flag_snapshots].where(account_id: account_id)
                          .update(mirror: Sequel.pg_jsonb(mirror), updated_at: now)
      f
    rescue StandardError => e
      @log.call("flags: materialize failed #{e.class}: #{e.message}")
      facts_for(account_id)
    end

    # What the client must be holding at login. -> { switches: [id,...],
    # self_switches: ["m:e:A",...] }. A fact whose name no longer maps to an id
    # (the dev deleted or renamed the switch) is simply dropped, never guessed.
    def facts_for(account_id)
      rows = @db[:progression_facts]
             .where(account_id: account_id, revoked_at: nil)
             .exclude(durable_at: nil)   # pending = the client never saved it; do not invent it
             .select_map(:fact_key)
      sw = []
      ss = []
      rows.each do |k|
        if k.start_with?("ss:")
          key = k[3..]
          # Filtered on READ as well as on grant, so a re-export that newly marks an
          # event repeatable takes effect at once - no operator surgery on rows banked
          # under the old policy.
          ss << key if bankable?(key)
        elsif (id = @fact_id_by_key[k])
          sw << id
        end
      end
      { switches: sw.sort, self_switches: ss.sort }
    rescue StandardError => e
      @log.call("flags: facts_for failed #{e.class}: #{e.message}")
      { switches: [], self_switches: [] }
    end

    # Is this self-switch a monotonic one-shot marker, i.e. the server's to bank?
    # key is "map:event:letter".
    def bankable?(key)
      !repeatable?(key) && !@latched.include?(key.to_s)
    end

    # The manifest lists a repeatable EVENT as "map:event" - pbSetEventTime drives every
    # letter of it - so this match deliberately ignores the letter.
    def repeatable?(key)
      return false if @repeatable.empty?

      parts = key.to_s.split(":")
      parts.length >= 2 && @repeatable.include?("#{parts[0]}:#{parts[1]}")
    end

    def to_id_set(list)
      return nil unless list   # nil = no policy = compare nothing (inert)

      list.map(&:to_i).to_set
    end

    # payload: { switches: [id,...], variables: {id=>int}, self_switches: ["m:e:A",...] }
    # -> [:ack, flags] | [:dup, []] | [:rej, ["bad_shape"]]
    def apply_flags(account_id, payload, seq, now: Time.now)
      return [:rej, ["bad_shape"]] unless payload.is_a?(Hash) && seq.is_a?(Integer)

      switches = int_list(payload[:switches])
      selfsw   = str_list(payload[:self_switches])
      vars     = var_map(payload[:variables])
      return [:rej, ["bad_shape"]] if switches.nil? || selfsw.nil? || vars.nil?

      truncated = switches.length > MAX_ENTRIES || selfsw.length > MAX_ENTRIES ||
                  vars.size > MAX_ENTRIES

      result = nil
      @db.transaction do
        row = @db[:flag_snapshots].where(account_id: account_id).first
        if row && seq <= row[:last_seq]
          result = [:dup, []]   # replayed/stale absolute snapshot -> re-ack, no write
        else
          flags = truncated ? ["truncated"] : detect_rewind(account_id, row, switches, selfsw, vars)
          # THE TRUST GATE measurement: does the delta-built mirror agree with the
          # absolute truth? Reported, never enforced — a disagreement is evidence
          # about OUR interception, not about the player.
          drift = compare_mirror(account_id, row, switches, selfsw, vars)
          unless drift.empty?
            @log.call("flags: account #{account_id} DELTA DRIFT — #{drift.join('; ')}")
          end
          grant_facts(account_id, switches, selfsw, seq: seq, now: now)
          note_cooldowns(account_id, payload[:event_times], now: now)
          store(account_id, switches, vars, selfsw, seq, truncated, flags, now, drift)
          result = [:ack, flags]
        end
      end
      result
    rescue StandardError => e
      @log.call("flags: apply failed #{e.class}: #{e.message}")
      [:rej, ["error"]]
    end

    def snapshot(account_id)
      @db[:flag_snapshots].where(account_id: account_id).first
    end

    # --- step 3: the delta stream + THE TRUST GATE -----------------------------
    #
    # The client sends every intercepted write as a delta. We apply it to our own
    # copy of the state; when the next ABSOLUTE snapshot arrives we compare the two.
    # If they agree across real play, the interception is complete and the server may
    # eventually own this state. If they disagree, the stream is lossy and NOTHING
    # further may be built on it — which is the entire point of shipping this in
    # shadow first. Divergence is reported, never enforced.
    #
    # -> [:ok, drift] | [:bad, []] — drift is a human-readable list of disagreements.
    def apply_delta(account_id, payload, now: Time.now)
      return [:bad, []] unless payload.is_a?(Hash)

      sw   = bool_map(payload[:switches])
      selfsw = bool_map(payload[:self_switches])
      vars = payload[:variables].is_a?(Hash) ? payload[:variables] : {}
      return [:bad, []] if sw.nil? || selfsw.nil?

      @db.transaction do
        row = @db[:flag_snapshots].where(account_id: account_id).first
        return [:bad, []] unless row

        # Apply onto the mirror we keep beside the snapshot. An overflowed delta
        # invalidates the mirror (we know it is incomplete), so we stop comparing
        # until the next absolute snapshot re-establishes it.
        mirror = row[:mirror].respond_to?(:to_h) ? row[:mirror].to_h : seed_mirror(row)
        if payload[:overflow] == true
          @db[:flag_snapshots].where(account_id: account_id)
                              .update(mirror_valid: false, updated_at: now)
          return [:ok, []]
        end

        sw.each     { |id, on| apply_set(mirror, "sw", id, on) }
        selfsw.each { |k, on|  apply_set(mirror, "ss", k, on) }
        vars.each   { |id, v|  mirror["var/#{id}"] = v if v.is_a?(Integer) }

        @db[:flag_snapshots].where(account_id: account_id)
                            .update(mirror: Sequel.pg_jsonb(mirror), updated_at: now)
      end
      [:ok, []]
    rescue StandardError => e
      @log.call("flags: delta failed #{e.class}: #{e.message}")
      [:bad, []]
    end

    # Called when an absolute snapshot lands: does the delta-built mirror agree?
    # This IS the trust gate's measurement.
    def compare_mirror(account_id, row, switches, selfsw, vars)
      # NOTE: Sequel hands jsonb back as a DelegateClass(Hash), NOT a Hash subclass —
      # an `is_a?(Hash)` guard here silently disabled the whole gate. Use to_h, as the
      # rest of this file already does for :variables / :switches.
      return [] unless row && row[:mirror_valid] && row[:mirror].respond_to?(:to_h)

      return [] unless @owned_switches   # no policy -> nothing is ours -> nothing to judge

      mirror = row[:mirror].to_h
      drift  = []

      # SWITCHES — compared over the policy-owned ids ONLY. A local id is absent from
      # the delta stream by design; an OWNED id present in the truth but missing from
      # the mirror is exactly the missed write this gate exists to catch.
      want = switches.select { |i| @owned_switches.include?(i) }.map { |i| "sw/#{i}" }
      have = mirror.keys.select { |k| k.start_with?("sw/") && mirror[k] &&
                                      @owned_switches.include?(k.split("/", 2)[1].to_i) }
      missing = want - have
      extra   = have - want
      unless missing.empty? && extra.empty?
        drift << "switches missed=#{missing.first(3).join(',')} stale=#{extra.first(3).join(',')}"
      end

      # SELF-SWITCHES — the whole namespace is owned (they are one-shot markers).
      want_ss = selfsw.map { |k| "ss/#{k}" }
      have_ss = mirror.keys.select { |k| k.start_with?("ss/") && mirror[k] }
      ss_missing = want_ss - have_ss
      ss_extra   = have_ss - want_ss
      unless ss_missing.empty? && ss_extra.empty?
        drift << "self_switches missed=#{ss_missing.first(3).join(',')} stale=#{ss_extra.first(3).join(',')}"
      end

      vars.each do |id, v|
        next unless @owned_vars&.include?(id.to_i)

        m = mirror["var/#{id}"]
        next if m == v

        drift << "var #{id} mirror=#{m.inspect} snapshot=#{v}"
      end
      drift.first(8)
    end

    def apply_set(mirror, prefix, key, on)
      k = "#{prefix}/#{key}"
      mirror[k] = on ? true : false
    end

    # An absolute snapshot IS the truth, so it always re-establishes the mirror — but
    # only over the ids the POLICY claims. The snapshot itself is deliberately
    # unfiltered (rewind detection wants the whole picture), so without this the
    # mirror would silently re-acquire local ids the delta stream never sends, and
    # "the mirror" would stop meaning "the state the server owns" — which is exactly
    # what it has to mean once it becomes the basis of authority in step 4.
    def mirror_from(switches, vars, selfsw)
      m = {}
      switches.each { |i| m["sw/#{i}"] = true if owned_switch?(i) }
      selfsw.each   { |k| m["ss/#{k}"] = true }          # the whole namespace is owned
      vars.each     { |id, v| m["var/#{id}"] = v if owned_var?(id) }
      m
    end

    def owned_switch?(id)
      @owned_switches.nil? || @owned_switches.include?(id.to_i)
    end

    def owned_var?(id)
      @owned_vars.nil? || @owned_vars.include?(id.to_i)
    end

    def seed_mirror(row)
      m = {}
      Array(row[:switches].to_a).each { |i| m["sw/#{i}"] = true }
      Array(row[:self_switches].to_a).each { |k| m["ss/#{k}"] = true }
      row[:variables].to_h.each { |id, v| m["var/#{id}"] = v }
      m
    end

    def bool_map(h)
      return {} if h.nil?
      return nil unless h.is_a?(Hash)

      out = {}
      h.each { |k, v| out[k.to_s] = (v == true) }
      out
    end

    private

    # -> flags (["rewind"] when the self-switch drop is reportable). Switch/variable
    # regressions are logged for the operator but never flagged (see the header).
    def detect_rewind(account_id, row, switches, selfsw, vars)
      return [] unless row
      # A comparison against a TRUNCATED baseline is meaningless: entries the previous
      # snapshot had to drop would read as cleared. Record, don't judge, until a full
      # snapshot re-establishes the baseline.
      return ["truncated"] if row[:truncated]

      prev_self = Array(row[:self_switches].to_a)
      cleared   = prev_self - selfsw
      prev_sw   = Array(row[:switches].to_a)
      sw_off    = prev_sw - switches
      prev_vars = row[:variables].to_h
      dropped   = prev_vars.count { |k, v| v.is_a?(Integer) && vars[k.to_s].is_a?(Integer) && vars[k.to_s] < v }

      if sw_off.any? || dropped.positive?
        @log.call("flags: account #{account_id} regression — #{sw_off.length} switch(es) off, " \
                  "#{dropped} variable(s) decreased (recorded, not judged)")
      end
      return [] if cleared.length < REWIND_MIN

      @log.call("flags: account #{account_id} SUSPECT rewind — #{cleared.length} self-switches cleared " \
                "(#{cleared.first(5).join(', ')}#{cleared.length > 5 ? ', …' : ''}) — one-shot events re-armed")
      ["rewind"]
    end

    def store(account_id, switches, vars, selfsw, seq, truncated, flags, now, drift = [])
      @db[:flag_snapshots]
        .insert_conflict(target: :account_id,
                         update: { switches: Sequel.pg_jsonb(switches), variables: Sequel.pg_jsonb(vars),
                                   self_switches: Sequel.pg_jsonb(selfsw), last_seq: seq,
                                   truncated: truncated, flagged: flags.any?,
                                   flags: Sequel.pg_jsonb(flags), updated_at: now,
                                   mirror: Sequel.pg_jsonb(mirror_from(switches, vars, selfsw)),
                                   mirror_valid: true,
                                   drift_at: (drift.empty? ? nil : now),
                                   drift: (drift.empty? ? nil : drift.join('; ')[0, 500]) })
        .insert(account_id: account_id, switches: Sequel.pg_jsonb(switches),
                variables: Sequel.pg_jsonb(vars), self_switches: Sequel.pg_jsonb(selfsw),
                last_seq: seq, truncated: truncated, flagged: flags.any?,
                flags: Sequel.pg_jsonb(flags), updated_at: now,
                mirror: Sequel.pg_jsonb(mirror_from(switches, vars, selfsw)), mirror_valid: true,
                drift_at: (drift.empty? ? nil : now), drift: (drift.empty? ? nil : drift.join('; ')[0, 500]))
    end

    # --- shape guards (hostile input) -----------------------------------------

    def int_list(v)
      return [] if v.nil?
      return nil unless v.is_a?(Array) && v.all? { |i| i.is_a?(Integer) && i.between?(0, 5000) }

      v.uniq.sort
    end

    def str_list(v)
      return [] if v.nil?
      return nil unless v.is_a?(Array) && v.all? { |s| s.is_a?(String) && s.length <= 32 }

      v.uniq.sort
    end

    def var_map(v)
      return {} if v.nil?
      return nil unless v.is_a?(Hash)

      out = {}
      v.each do |k, val|
        id = k.to_s
        return nil unless id.match?(/\A\d{1,4}\z/) && id.to_i.between?(0, 5000)
        next unless val.is_a?(Integer)   # non-Integer values are not judged, just dropped

        out[id] = val
      end
      out
    end
  end
end
