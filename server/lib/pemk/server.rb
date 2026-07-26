# frozen_string_literal: true

require "time"
require "set"

module PEMK
  # Milestone 1 server: reactor + worker pool + a connection AUTH-GATE. A socket is
  # unauthenticated (only :ping/:register/:login/:auth accepted, everything else
  # dropped) until it presents valid credentials or a session token — this retires
  # the old client-claimed account_id and closes the impersonation hole. Blocking
  # work (Postgres, bcrypt) runs on the pool; replies come back via reactor.post so
  # connection state and socket writes stay single-threaded.
  #
  # Per-player mailbox routing, zone presence and the save store are the next
  # increments; authenticated gameplay frames are logged here for now.
  class Server
    AUTH_TYPES     = %i[ping register login auth].freeze
    # Authenticated point-to-point frames the server relays to the :to account
    # (challenge handshake + the whole battle stream), the role the old in-process
    # relay played — now with server-trusted :from and no cross-client leakage.
    ADDRESSED      = %i[challenge challenge_accept challenge_decline battle_team
                        battle_start battle_choice battle_round battle_switch battle_end
                        trade_invite trade_accept trade_decline trade_offer trade_lock trade_cancel].freeze
    TRADE_TTL      = 15          # seconds a half-committed (lone) trade rendezvous lingers before timeout
    WORKERS        = 8
    LOGIN_MAX      = 10          # login/register attempts ...
    LOGIN_WINDOW   = 60          # ... per this many seconds, per IP

    def self.log(msg)
      $stdout.puts("#{Time.now.utc.iso8601} #{msg}")
      $stdout.flush
    end

    def initialize(config: Config.new, logger: nil)
      @config   = config
      @log      = logger || self.class.method(:log)
      @db       = DB.connect(@config.database_url, max_connections: WORKERS + 2)
      @accounts   = Accounts.new(@db)
      @sessions   = Sessions.new(@db)
      @characters = Characters.new(@db)
      # Badges become monotonic once the sovereignty layer is on: they are progression,
      # and a reloaded save pushing 0 must not erase them.
      @ledger     = Ledger.new(@db, @config.economy_caps, monotonic: @config.flag_state == :on)
      @inventory  = Inventory.new(@db, @config.inventory_caps, logger: @log)
      @encounter_rolls = EncounterRolls.new(@db)   # M4 D3.2: persisted mints -> mon provenance
      # Provenance labeling only makes sense when the server actually mints encounters:
      # off/shadow would label every honest catch "client" (and invert the signal). With
      # rolls disabled, origin stays NULL = its documented "unknown" meaning.
      @monsters   = Monsters.new(@db, @config.monster_caps, logger: @log,
                                 rolls: (@config.battle_enforce_encounters == :on ? @encounter_rolls : nil),
                                 resim: @config.battle_enforce_resim)   # D8: birth states
      @trades     = Trades.new(@db, resim: @config.battle_enforce_resim)   # D8: provisional trade hold
      # M4 Layer A: read-only world model + detection-only interaction audit. Both are
      # in-memory and DB-free; a missing export just makes the audit a no-op.
      @world      = WorldData.new(@config.world_path, logger: @log)
      @battle     = BattleData.new(@config.battle_data_path, logger: @log)   # M4 Layer D read model
      @team_audit = TeamAudit.new(@battle, mode: @config.battle_enforce_teams,
                                  party_max: @config.monster_caps[:party_max], logger: @log)   # M4 Layer D D1
      # Audit item 5: the per-mon stat block (first-sight identity lock). Rides the
      # existing D1 team flag rather than adding a 12th knob.
      @monster_blocks = MonsterBlocks.new(@db, logger: @log) if @config.battle_enforce_teams != :off
      @encounter_mint = EncounterMint.new(@world, logger: @log)   # M4 Layer D D2 wild-encounter roller
      @catch_calc = CatchCalc.new(@battle)                        # M4 Layer D D3 capture adjudication
      # M4 Layer D D4 wild-battle reward bounds (detection). Only active when the operator
      # opts in; needs encounter context (foe mints) for meaningful windows.
      @reward_audit = if @config.battle_enforce_rewards != :off
                        RewardAudit.new(RewardCalc.new(@battle), @battle, logger: @log)
                      end
      # M4 Layer D D5: cross-battle anomaly detection -> review queue (never enforces).
      @anomaly = AnomalyDetector.new(@db, @world, logger: @log) if @config.anomaly_detection
      @last_anomaly_sweep = nil
      @anomaly_sweeping   = false
      # M4 Layer D D6: per-mon EXP high-water + rollback detection (part 1) + the :on
      # up-only restore (part 2). battle_data supplies per-species EXP sanity caps.
      @monster_stats = MonsterStats.new(@db, battle: @battle) if @config.battle_enforce_exp != :off
      # M4 Layer D D8: the re-sim verdict sweep (live-server writer of monster state).
      @resim = ResimVerdicts.new(@db, mode: @config.battle_enforce_resim,
                                 min_strikes: @config.resim_min_strikes, logger: @log) if @config.battle_enforce_resim != :off
      @last_resim_sweep = nil
      @resim_sweeping   = false
      # M4 Layer D D7 part 1: the battle-record corpus ingest (shadow + on).
      if @config.battle_enforce_rng != :off
        @battle_records = BattleRecords.new(@db, mode: @config.battle_enforce_rng, logger: @log)
      end
      # Audit item 4: switches/variables/self-switches detection shadow.
      if @config.flag_state != :off
        @flag_state = FlagState.new(@db, policy: manifest_policy, facts: manifest_fact_keys,
                                    repeatable: manifest_repeatable, logger: @log)
      end
      @gift_claims = GiftClaims.new(@db, logger: @log) if @config.flag_state != :off
      @audit      = Audit.new(@world, logger: @log)
      @pos_audit  = PositionAudit.new(@world, logger: @log, mode: @config.position_enforcement)   # M4 Layer B
      @pickups    = Pickups.new(@db)   # M4 Layer C one-shot ledger
      @pool     = WorkerPool.new(size: WORKERS, logger: @log)
      @limiter  = RateLimiter.new(max: LOGIN_MAX, per: LOGIN_WINDOW)
      @zones    = Hash.new { |h, k| h[k] = Set.new }   # map_id => Set(conn); reactor-thread only
      @online   = {}                                    # account_id => conn; reactor-thread only
      @pending_trades = {}                              # trade_id => rendezvous; reactor-thread only
      @peer_sessions  = {}                              # account_id => partner id (mutual); reactor-thread only
      @conn_buckets   = {}                              # conn => [tokens, last_refill]; reactor-thread only
      @reactor  = Reactor.new(
        host: @config.bind, port: @config.port,
        on_frame: method(:on_frame), on_close: method(:on_close),
        on_tick: method(:on_tick), logger: @log
      )
      @mailbox  = PlayerMailbox.new(pool: @pool, post: @reactor.method(:post), logger: @log)
    end

    def port
      @reactor.port
    end

    def start
      @db.test_connection
      @log.call("server: db ok (#{@db.opts[:database]}), workers=#{WORKERS}")
      @log.call("server: economy caps #{@config.economy_caps}, badges<#{@config.badges_max}")
      @log.call("server: inventory caps #{@config.inventory_caps} (detection-only, flag-not-reject)")
      @log.call("server: monster caps #{@config.monster_caps} (uid registry, flag-not-reject)")
      @log.call("server: world data #{@world.summary} (M4 Layer A, audit-only)")
      @log.call("server: battle data #{@battle.summary} (M4 Layer D)")
      @log.call("server: team legality enforcement = #{@config.battle_enforce_teams} (M4 Layer D D1, detection-only)")
      @log.call("server: encounter enforcement = #{@config.battle_enforce_encounters} (M4 Layer D D2)")
      @log.call("server: catch enforcement = #{@config.battle_enforce_catches} (M4 Layer D D3)")
      @log.call("server: reward enforcement = #{@config.battle_enforce_rewards} (M4 Layer D D4, detection-only)")
      @log.call("server: anomaly detection = #{@config.anomaly_detection ? 'on' : 'off'} (M4 Layer D D5, review-queue only)")
      @log.call("server: exp authority = #{@config.battle_enforce_exp} (M4 Layer D D6; on = up-only restore to high-water)")
      @log.call("server: battle rng = #{@config.battle_enforce_rng} (M4 Layer D D7 part 1 — instrumentation, never rejects)")
      @log.call("server: resim enforcement = #{@config.battle_enforce_resim} (M4 Layer D D8 — walk-tier quarantine, strikes=#{@config.resim_min_strikes})")
      if @config.battle_enforce_resim != :off && @config.battle_enforce_rng != :on
        @log.call("server: WARNING resim enforcement is #{@config.battle_enforce_resim} but battle rng is #{@config.battle_enforce_rng} — no seeds/records means nothing can ever be verified or condemned")
      end
      if @config.battle_enforce_rewards != :off && @config.battle_enforce_encounters != :on
        @log.call("server: WARNING reward detection is on but encounter enforcement is #{@config.battle_enforce_encounters} — no foe context, so battle windows can't open")
      end
      if @config.battle_enforce_rng != :off && @config.battle_enforce_encounters != :on
        @log.call("server: WARNING battle rng is #{@config.battle_enforce_rng} but encounter enforcement is #{@config.battle_enforce_encounters} — seeds ride the mint, so no battle can be seeded")
      end
      begin
        pruned = @encounter_rolls.prune
        @log.call("server: pruned #{pruned} stale encounter roll(s) (>#{EncounterRolls::RETENTION_DAYS}d, never fought)") if pruned.positive?
      rescue StandardError => e
        @log.call("server: encounter-roll prune failed #{e.class}: #{e.message}")
      end
      # D7 part 3: corpus retention — matched records are spent; evidence is kept.
      if @battle_records
        begin
          pruned = @battle_records.prune(days: @config.corpus_retention_days)
          @log.call("server: pruned #{pruned} matched battle record(s) (>#{@config.corpus_retention_days}d)") if pruned.positive?
        rescue StandardError => e
          @log.call("server: battle-record prune failed #{e.class}: #{e.message}")
        end
      end
      if @config.battle_enforce_catches == :on && @config.battle_enforce_encounters != :on
        @log.call("server: WARNING catch enforcement is on but encounter enforcement is #{@config.battle_enforce_encounters} — catches need a server encounter mint, so they will all fail-open to local")
      end
      @log.call("server: flag state = #{@config.flag_state} " \
                "(switches/variables#{@config.flag_state == :on ? '; facts materialized at login, grant-only' : ' — detection only'})")
      @log.call("server: position enforcement = #{@config.position_enforcement} (M4 Layer B)")
      @log.call("server: pickup enforcement = #{@config.pickup_enforce ? 'on' : 'off'} (M4 Layer C server-mint)")
      @log.call("server: WARNING pickup reset ALLOWED (PEMK_ALLOW_PICKUP_RESET=on) — DEV ONLY, disable in production") if @config.pickup_reset_allowed
      @pool.start
      @reactor.start
      @thread = Thread.new { @reactor.run_loop }
      @thread.abort_on_exception = true
    end

    def stop
      @reactor.stop
      @thread&.join(5)
      @pool.shutdown
      @log.call("server: stopped")
    end

    def run
      install_signal_handlers
      start
      @thread.join           # block until SIGTERM stops the reactor
      @pool.shutdown
      @log.call("server: stopped")
    end

    private

    def on_frame(conn, payload)
      # An EVICTED socket (a relogin took over this account) must never mutate account
      # state again — it used to be honored for one more frame (audit).
      return if conn.closing

      conn.data[:last_seen] = Process.clock_gettime(Process::CLOCK_MONOTONIC)   # idle sweep
      dec = Wire.decode_envelope(payload, false) # host path rejects legacy whole-Marshal
      unless dec
        @log.call("server: bad/legacy frame from #{conn.addr} -> drop")
        conn.closing = true
        return
      end

      env    = dec[:env]
      type   = env[:type]
      authed = conn.data[:account_id]

      unless authed || AUTH_TYPES.include?(type)
        @log.call("server: pre-auth #{type.inspect} from #{conn.addr} -> drop")
        conn.closing = true
        return
      end

      # Per-connection budget for AUTHENTICATED frames. Nothing rate-limited anything
      # after login before this (audit): one socket could spam DB-touching frames until
      # the mailbox/pool queues ate the host. Honest clients send these at human,
      # debounced cadence, so the budgets are generous.
      if authed && !frame_budget_ok?(conn, type)
        @log.call("server: account #{authed} over budget on #{type.inspect} -> drop")
        return
      end

      dispatch_frame(conn, env, type, authed, dec[:body])
    rescue StandardError => e
      # A raise used to unwind to the reactor's blanket rescue, aborting the whole tick
      # (and the rest of this socket's already-parsed frames) with an unattributable log.
      @log.call("server: handler error on #{type.inspect} account #{authed.inspect}: #{e.class}: #{e.message}")
    end

    # Token bucket per connection. Tight for the DB-touching types, generous for
    # presence. Unlisted authed types get the default bucket.
    FRAME_BUDGETS = {
      # save: the Checkpoint fires urgent (<=1s) bursts after high-value events, so the
      # burst must absorb several back-to-back pushes; sustained 1/s is still ~100x an
      # honest client and bounds a flood to the blob cap per second.
      save: [10, 1.0], econ: [10, 4], inv: [10, 4], uid_req: [10, 4], mon_party: [10, 4],
      flags: [10, 1.0], flag_delta: [20, 4], gift_claim: [20, 4],
      encounter_req: [10, 2], catch_req: [20, 6], battle_record: [6, 1], trade_commit: [6, 2],
      team_check: [10, 2], pickup_req: [20, 6], interact_claim: [30, 10],
      pos: [40, 20], dir: [40, 20], step: [40, 20], spawn: [10, 2]
    }.freeze
    FRAME_BUDGET_DEFAULT = [30, 10].freeze

    def frame_budget_ok?(conn, type)
      burst, rate = FRAME_BUDGETS.fetch(type, FRAME_BUDGET_DEFAULT)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      b = (conn.data[:budgets] ||= {})
      tokens, last = b[type] || [burst.to_f, now]
      tokens = [tokens + ((now - last) * rate), burst.to_f].min
      return (b[type] = [tokens, now]) && false if tokens < 1.0

      b[type] = [tokens - 1.0, now]
      true
    end

    def dispatch_frame(conn, env, type, authed, body)
      case type
      when :ping     then reply(conn, type: :pong, t: env[:t])
      when :register then handle_register(conn, env)
      when :login    then handle_login(conn, env)
      when :auth     then handle_auth(conn, env)
      when :save     then handle_save(conn, env, body, authed, conn.data[:last_pos])
      when :econ     then handle_econ(conn, env, authed)
      when :inv      then handle_inv(conn, env, authed)
      when :uid_req  then handle_uid_req(conn, env, authed)
      when :mon_party then handle_mon_party(conn, env, authed)
      when :interact_claim then handle_interact_claim(conn, env, authed)
      when :pickup_req then handle_pickup_req(conn, env, authed)
      when :pickups_reset then handle_pickups_reset(conn, env, authed)
      when :team_check then handle_team_check(conn, env, authed)
      when :encounter_report then handle_encounter_report(conn, env, authed)
      when :encounter_req then handle_encounter_req(conn, env, authed)
      when :catch_req then handle_catch_req(conn, env, authed)
      when :catch_report then handle_catch_report(conn, env, authed)
      when :battle_end_report then handle_battle_end(conn, env, authed)
      when :battle_record then handle_battle_record(env, body, authed)
      when :flags then handle_flags(conn, env, authed)
      when :flag_delta then handle_flag_delta(env, authed)
      when :gift_claim then handle_gift_claim(env, authed)
      when :trade_commit then handle_trade_commit(conn, env, authed)
      when :pos, :dir, :step, :spawn then handle_presence(conn, env, authed)
      when *ADDRESSED then handle_addressed(conn, env, body, authed)
      else
        # Other authenticated gameplay frames (economy, battle) — per-player mailbox
        # routing + handlers land in later milestones.
        @log.call("server: authed #{type.inspect} from account #{authed}")
      end
    end

    def handle_register(conn, env)
      return reply(conn, type: :register_err, reason: "rate_limited") unless @limiter.allow?(conn.addr)

      email = env[:email].to_s
      pw    = env[:password].to_s
      uname = env[:username]   # optional display handle
      @pool.submit do
        result =
          begin
            id = @accounts.create(email: email, password: pw, username: uname)
            id ? { type: :register_ok, account_id: id } : { type: :register_err, reason: "taken" }
          rescue ArgumentError => e
            { type: :register_err, reason: e.message }
          end
        @reactor.post { reply(conn, **result) }
      end
    end

    def handle_login(conn, env)
      return reply(conn, type: :login_err, reason: "rate_limited") unless @limiter.allow?(conn.addr)

      email = env[:email].to_s
      pw    = env[:password].to_s
      addr  = conn.addr
      @pool.submit do
        acct, err = @accounts.authenticate(email, pw)
        if acct
          token = @sessions.issue(acct[:id], remote_addr: addr)
          # The state READ must serialize behind any in-flight :save/:econ/:inv for
          # this account (a login racing a pending save would hand back a stale
          # blob and the client's next push would fossilize the rollback). Mailbox
          # bookkeeping is reactor-thread-only, so route the submit through post.
          @reactor.post do
            @mailbox.submit(acct[:id]) do
              blob = @characters.load_blob(acct[:id])   # opaque; never loaded here
              rec  = reconcile_block(acct[:id])
              pos  = (@characters.load_position(acct[:id]) rescue nil)   # M4-B: seed last_pos (never brick login)
              @reactor.post do
                if @reactor.alive?(conn)   # never bind a dead conn into @online
                  bind(conn, acct[:id])
                  conn.data[:last_pos] = pos if pos
                  reply_body(conn, { type: :login_ok, account_id: acct[:id], token: token }.merge(rec), blob)
                end
              end
            end
          end
        else
          @reactor.post { reply(conn, type: :login_err, reason: err.to_s) }
        end
      end
    end

    def handle_auth(conn, env)
      token = env[:token].to_s
      @pool.submit do
        account_id = @sessions.resolve(token)
        if account_id
          # Same serialization as handle_login: read behind the account's mailbox.
          @reactor.post do
            @mailbox.submit(account_id) do
              blob = @characters.load_blob(account_id)
              rec  = reconcile_block(account_id)
              pos  = (@characters.load_position(account_id) rescue nil)   # M4-B: seed last_pos (never brick login)
              @reactor.post do
                if @reactor.alive?(conn)   # never bind a dead conn into @online
                  bind(conn, account_id)
                  conn.data[:last_pos] = pos if pos
                  reply_body(conn, { type: :auth_ok, account_id: account_id }.merge(rec), blob)
                end
              end
            end
          end
        else
          @reactor.post { reply(conn, type: :auth_err, reason: "invalid_token") }
        end
      end
    end

    # Persist the opaque save body (never Marshal.load'd server-side). On the
    # per-account MAILBOX (not the raw pool): two rapid pushes for one account
    # must commit in arrival order (raw-pool scheduling could commit the OLDER
    # blob last, silently rolling the account back), and the login/auth state
    # read serializes behind any in-flight save.
    # A real Essentials save measures ~100 KB; full PC boxes leave plenty of room under
    # this. MUST stay below the reactor's OUTBUF_CAP (4 MiB) or a stored blob could
    # never be delivered back at login, permanently bricking that account (audit).
    SAVE_MAX_BYTES = 2 * 1024 * 1024

    def handle_save(conn, env, body, account_id, last_pos)
      unless body.is_a?(String) && !body.empty?
        @log.call("server: empty :save from account #{account_id} -> ignore")
        return
      end

      if body.bytesize > SAVE_MAX_BYTES
        # Tell the client rather than dropping silently: a save that never lands is
        # invisible permanent progress loss.
        @log.call("server: account #{account_id} save too large (#{body.bytesize}B > #{SAVE_MAX_BYTES}) -> reject")
        return reply(conn, type: :save_err, reason: "too_large", max: SAVE_MAX_BYTES)
      end

      tid = env[:trainer_id]
      sv  = env[:save_version]
      wv  = env[:wire_version]
      # Persist the SERVER-tracked position (captured on the reactor thread when the
      # frame arrived, not client-claimed) alongside the blob, so the next login seeds
      # the position audit. nil (no presence yet) leaves the stored position untouched.
      fseq = env[:flags_seq]
      @mailbox.submit(account_id) do
        @characters.store(account_id, blob: body, trainer_id: tid, save_version: sv, wire_version: wv, position: last_pos)
        # The blob is the client's durability boundary: progression facts granted up
        # to the flags seq it carries are now on the player's disk, so promote them
        # out of pending. Anything granted after it waits for the next save, or a
        # crash here would restore a switch onto a save that lacks its payout.
        @flag_state&.commit_facts(account_id, fseq)
        @log.call("server: saved account #{account_id} (#{body.bytesize}B)")
      end
    end

    # Server-authoritative economy. Serialized per account on the mailbox: apply the
    # absolute value through the ledger (cap-checked, gap-safe idempotent), then
    # ACK the canonical balance or REJECT (the client rolls back to it).
    def handle_econ(conn, env, account_id)
      field = env[:field]
      value = env[:value]
      seq   = env[:seq]
      @mailbox.submit(account_id) do
        # D4: attribute a fresh MONEY change to a recent wild battle's budget window
        # (reason "battle:<n>"/"battle_suspect:<n>"), else "unattributed". Only on a
        # genuinely new frame (never a replay), only for :money, only when reward
        # detection is enabled — otherwise the reason stays the M2 default.
        reason = "unattributed"
        if @reward_audit && field.to_s == "money" && value.is_a?(Integer) && !@ledger.recorded?(account_id, field, seq)
          delta = value - @ledger.current(account_id, field)
          reason, suspect = @reward_audit.note_money(account_id, delta)
          if suspect
            @log.call("reward: account #{account_id} SUSPECT money delta #{delta} exceeds battle window (#{reason})")
            flag_anomaly(account_id, :reward_money)
          end
        end
        status = @ledger.apply_econ(account_id, field, value, seq, reason: reason)
        @reactor.post do
          case status.first
          when :ack, :dup then reply(conn, type: :econ_ack, field: field, value: status[1], seq: seq)
          when :rej       then reply(conn, type: :econ_rej, field: field, value: status[1], seq: seq, reason: status[2].to_s)
          end
        end
      end
    end

    # Server-side BAG record (DETECTION-ONLY): the client pushes the whole bag as an
    # absolute {item_id => qty} snapshot. Serialized per account on the SAME mailbox
    # as :econ/:save (no read-modify-write race). We record + structurally flag, then
    # ALWAYS ack (never reject/roll back) — the bag stays blob-authoritative in M2.3.
    def handle_inv(conn, env, account_id)
      bag = env[:bag]
      seq = env[:seq]
      @mailbox.submit(account_id) do
        status = @inventory.apply_inv(account_id, bag, seq)
        @reactor.post { reply(conn, type: :inv_ack, seq: seq, flagged: status[1].any?) }
      end
    end

    # Server-issued monster UIDs (M3.1): mint one uid per swept instance, matched by
    # the client's persisted nonce. Idempotent by the monsters_mint_dedup unique
    # index — a replayed request re-receives the SAME uids. On the mailbox like all
    # per-account mutations.
    def handle_uid_req(conn, env, account_id)
      mons = env[:mons]
      seq  = env[:seq]
      @mailbox.submit(account_id) do
        status = @monsters.mint_batch(account_id, mons)
        if status.first == :ack
          @reactor.post { reply(conn, type: :uid_grant, grants: status[1], seq: seq) }
        else
          @log.call("server: bad :uid_req from account #{account_id} -> ignored")
        end
      end
    end

    # Party projection (detection-only shadow): record + cross-check against the
    # registry, FLAG never reject, always ack.
    def handle_mon_party(conn, env, account_id)
      mons = env[:mons]
      seq  = env[:seq]
      # D4: diff per-uid levels vs the last projection on this connection; a level JUMP
      # needing more exp than a recent battle window holds is logged (detection-only —
      # Rare Candies level mons outside battle, so it never rejects). Inline pre-check.
      reward_check_levels(conn, account_id, mons) if @reward_audit
      @mailbox.submit(account_id) do
        status = @monsters.apply_party(account_id, mons, seq)
        corr = observe_exp(account_id, mons)   # D6: EXP high-water + rollback; :on -> up-only restore plan
        ack = { type: :mon_ack, seq: seq, flagged: status[1].any? }
        # D6 part 2: the plan rides the existing ack (absent in off/shadow). :level is
        # server-internal — strip it from the wire.
        ack[:exp_correct] = corr.map { |c| { uid: c[:uid], exp: c[:exp] } } if corr
        @reactor.post do
          if corr
            # Exempt the restore's own level jump from the D4 reward audit (the next
            # projection reports the restored level with NO battle window open — without
            # this the server would SUSPECT-flag its own correction). Reactor-thread
            # write, consumed one-shot by reward_check_levels (also reactor-thread).
            allowed = (conn.data[:exp_restored] ||= {})
            corr.each { |c| allowed[c[:uid]] = c[:level] if c[:level].is_a?(Integer) }
          end
          reply(conn, **ack)   # reply takes keywords (Ruby 3: no implicit hash splat)
        end
      end
    end

    # D6 (in the mailbox): track each owned mon's EXP high-water and flag a rollback
    # (reported EXP below it = old save / edit); feeds the D5 review queue.
    # -> part 2: in :on, returns the UP-ONLY restore plan [{uid:, exp: high_water}] for the
    # ack (nil when clean); re-emitted every below-frame (client's up-only guard makes a
    # re-send a no-op; the applied restore re-projects AT the high-water and the plan goes
    # empty). In :shadow the plan is LOGGED once per rollback episode (gated on the same
    # observe() latch — corrections() alone has no latch and would spam every frame).
    def observe_exp(account_id, mons)
      return nil unless @monster_stats && mons.is_a?(Array)

      entries = mons.map { |m| { uid: m[:uid], exp: m[:exp], level: m[:level], species: m[:species] } if m.is_a?(Hash) }.compact
      rollbacks = @monster_stats.observe(account_id, entries)
      unless rollbacks.empty?
        brief = rollbacks.map { |r| "uid#{r[:uid]} #{r[:from]}->#{r[:to]}" }.join(", ")
        @log.call("exp: account #{account_id} SUSPECT rollback #{brief} (reported EXP below high-water)")
        flag_anomaly(account_id, :exp_rollback)
      end
      case @config.battle_enforce_exp
      when :on
        corr = @monster_stats.corrections(account_id, entries)
        corr.empty? ? nil : corr
      when :shadow
        unless rollbacks.empty?
          plan = @monster_stats.corrections(account_id, entries)
          unless plan.empty?
            brief = plan.map { |c| "uid#{c[:uid]}->#{c[:exp]}" }.join(", ")
            @log.call("exp: account #{account_id} would restore #{brief} (shadow)")
          end
        end
        nil
      end
    rescue StandardError => e
      @log.call("exp: observe failed #{e.class}: #{e.message}")
      nil
    end

    # M4 Layer D D4: the client reports a wild battle's end (outcome + the foes it
    # fought); the server opens/extends a per-account reward budget window, but ONLY for
    # foes it can prove it minted (matched by pid in this connection's encounter stash) —
    # a fabricated :battle_end with no real foe grants no budget. Inline, no reply.
    def handle_battle_end(conn, env, account_id)
      return unless @reward_audit

      outcome = env[:outcome]
      claimed = env[:foes]
      return unless outcome.is_a?(Integer) && claimed.is_a?(Array)

      stash = conn.data[:enc_mints] || []
      foes  = []
      claimed.first(2).each do |f|
        next unless f.is_a?(Hash)

        pid = f[:pid]
        m = stash.find { |x| x["pid"] == pid }   # provable: an identity THIS conn was minted
        foes << { species: m["species"], level: m["level"] } if m
      end
      return if foes.empty?

      w = @reward_audit.record_battle(account_id, foes, outcome)
      @log.call("reward: account #{account_id} battle##{w[:id]} outcome=#{outcome} " \
                "foes=#{foes.map { |f| "#{f[:species]}@#{f[:level]}" }.join(',')} " \
                "budget exp=#{w[:exp]} gain=#{w[:gain]} loss=#{w[:loss]}")
    end

    # Level-jump exp bound (D4). Diffs the new projection vs the last one stashed on the
    # connection; feeds real jumps to the reward window. Runs on the reactor thread.
    def reward_check_levels(conn, account_id, mons)
      return unless mons.is_a?(Array)

      prev = conn.data[:party_levels] || {}
      restored = conn.data[:exp_restored]   # D6 part 2: uids whose next jump is the server's own restore
      cur  = {}
      changes = []
      mons.each do |m|
        next unless m.is_a?(Hash)

        uid = m[:uid]; sp = m[:species]; lvl = m[:level]
        next unless lvl.is_a?(Integer)

        cur[uid] = [sp, lvl] if uid
        old = uid && prev[uid]
        next unless old && old[0] == sp && lvl > old[1]

        # One-shot exemption: the D6 restore raises this uid's level with no battle
        # window — that jump is server-authored, not a reward claim. Exempt it only up
        # to the level the high-water recorded; anything beyond is judged normally.
        if restored && restored.key?(uid)
          allowed = restored.delete(uid)
          next if lvl <= allowed
        end
        changes << [sp, old[1], lvl]
      end
      conn.data[:party_levels] = cur

      return if changes.empty?

      suspect, detail = @reward_audit.check_levels(account_id, changes)
      if suspect
        @log.call("reward: account #{account_id} SUSPECT level jump — #{detail}")
        flag_anomaly(account_id, :reward_level)
      end
    end

    # Detection-only interaction audit (M4 Layer A). Runs INLINE on the reactor
    # thread like handle_presence — no mailbox, no DB, and crucially NO reply: it is
    # pure telemetry. Compares the client's interaction claim against the read-only
    # world model and logs a mismatch; it enforces nothing (enforcement is a later
    # layer). Identity is the server-trusted account_id, never a client :id.
    def handle_interact_claim(conn, env, account_id)
      # Layer C: judge the pickup against the player's SERVER-tracked tile (Layer B),
      # not the client-claimed px/py — so a remote pickup is caught. Inline + cheap.
      verdict = @audit.check_interaction(account_id, env, conn.data[:last_pos])

      # Layer C one-shot: a VALID item-ball pickup is recorded per account; a repeat
      # claim for the same tile is a dupe. The DB write goes on the per-account mailbox
      # so it never blocks the reactor. (Gifts have no fixed tile — skip them.)
      return unless verdict == :match && env[:kind] == :item

      map = env[:map]; x = env[:x]; y = env[:y]
      return unless map.is_a?(Integer) && x.is_a?(Integer) && y.is_a?(Integer)

      item = env[:item]
      @mailbox.submit(account_id) do
        if @pickups.record(account_id, map, x, y) == :dup
          @log.call("audit: account #{account_id} already_taken item=#{item.to_s[0, 32]} at (#{map},#{x},#{y})")
        end
      end
    end

    # Server-minted pickup (M4 Layer C): the client asks permission BEFORE adding an
    # item ball; we validate and reply :pickup_grant / :pickup_deny. Existence + item
    # + distance are judged INLINE against the world model and the player's SERVER-
    # tracked tile (never client px/py); the one-shot is then done ATOMICALLY on the
    # per-account mailbox (record -> :new grants, :dup denies), so two rapid requests
    # for one tile can never both grant. Fail-OPEN when no world is exported (an
    # operator misconfig must not brick every pickup); fail-CLOSED on any real reject.
    def handle_pickup_req(conn, env, account_id)
      seq = env[:seq]
      map = env[:map]; x = env[:x]; y = env[:y]

      verdict = @audit.check_interaction(account_id, env, conn.data[:last_pos])

      if verdict == :unchecked
        @log.call("pickup: account #{account_id} GRANT (world unexported — fail-open) seq=#{seq.inspect}")
        return reply(conn, type: :pickup_grant, seq: seq, item: env[:item], map: map, x: x, y: y)
      end
      unless verdict == :match
        return reply(conn, type: :pickup_deny, seq: seq, reason: verdict.to_s)
      end

      obj  = @world.object_at(map, x, y)
      item = (obj && obj["item"]) || env[:item]   # server-authoritative item id
      @mailbox.submit(account_id) do
        status = @pickups.record(account_id, map, x, y)
        @reactor.post do
          next unless @reactor.alive?(conn)

          if status == :new
            reply(conn, type: :pickup_grant, seq: seq, item: item, map: map, x: x, y: y)
          else
            reply(conn, type: :pickup_deny, seq: seq, reason: "already_taken")
          end
        end
      end
    end

    # DEV/QA-ONLY pickup reset (M4 Layer C polish). Forgets this account's taken tiles
    # so its item balls can be re-tested. Fail-CLOSED: honored ONLY when the server was
    # booted with PEMK_ALLOW_PICKUP_RESET=on. In production that flag is off, so this
    # always denies — a client could otherwise wipe its pickups and re-farm every item
    # ball infinitely. The client's F9 tool only offers the reset when reconcile_block
    # advertised it, but we re-check the server flag here (never trust the client).
    def handle_pickups_reset(conn, env, account_id)
      seq = env[:seq]
      unless @config.pickup_reset_allowed
        @log.call("pickup-reset: account #{account_id} DENIED (PEMK_ALLOW_PICKUP_RESET off)")
        return reply(conn, type: :pickups_reset_deny, seq: seq, reason: "not_allowed")
      end

      @mailbox.submit(account_id) do
        n = @pickups.clear(account_id)
        @reactor.post do
          next unless @reactor.alive?(conn)

          @log.call("pickup-reset: account #{account_id} cleared #{n} tile(s) (DEV)")
          reply(conn, type: :pickups_reset_ok, seq: seq, cleared: n)
        end
      end
    end

    # M4 Layer D D1: team/set legality audit. The client reports its FULL-STAT team as
    # primitives in the envelope (never a Marshal blob); the audit validates every mon
    # against the exported battle data and logs illegal teams (detection-only — there is
    # no battle-entry gate to block yet). Always acks so the client can correlate; the
    # legality result rides the ack for future client-side UX.
    def handle_team_check(conn, env, account_id)
      verdict = @team_audit.check(account_id, env[:team])
      observe_blocks(account_id, env[:team])
      reply(conn, type: :team_ack, seq: env[:seq], legal: (verdict[:legal] != false))
    end

    # Audit item 5: lock each owned mon's identity traits on first sight and flag a
    # later report that violates them (a counterfeit carrying a valid uid). On the
    # account mailbox — DB work, and it must serialize with the mint that creates the
    # registry row it keys on.
    def observe_blocks(account_id, team)
      return unless @monster_blocks && team.is_a?(Array)

      entries = team.map do |m|
        next unless m.is_a?(Hash)

        { uid: m["uid"] || m[:uid], species: m["species"] || m[:species],
          level: m["level"] || m[:level], ivs: m["ivs"] || m[:ivs], evs: m["evs"] || m[:evs],
          moves: m["moves"] || m[:moves], ability: m["ability"] || m[:ability],
          nature: m["nature"] || m[:nature], item: m["item"] || m[:item],
          shiny: m["shiny"].nil? ? m[:shiny] : m["shiny"],
          gender: m["gender"] || m[:gender] }
      end.compact
      return if entries.empty?

      @mailbox.submit(account_id) do
        diverged = @monster_blocks.observe(account_id, entries)
        flag_anomaly(account_id, :mon_counterfeit) unless diverged.empty?
      end
    end

    # M4 Layer D D2 (shadow): the client reports the wild encounter it rolled LOCALLY;
    # the server audits it against the Layer A encounter tables (a species absent from the
    # table = a fabricated encounter) and logs what it WOULD mint, so the roller can be
    # validated against real play before the mint is enforced (on). Fire-and-forget — no
    # reply, no gameplay effect. Cross-checks the reported map against the player's
    # server-tracked position (Layer B).
    def handle_encounter_report(conn, env, account_id)
      map     = env[:map]
      enctype = env[:enctype].to_s[0, 24]
      species = env[:species].to_s[0, 32]
      level   = env[:level]
      return unless map.is_a?(Integer) && !enctype.empty? && !species.empty?

      legal     = @encounter_mint.legal?(map, enctype, species)   # nil (no table) | true | false
      pos       = conn.data[:last_pos]
      wrong_map = pos.is_a?(Array) && pos[0] != map
      would     = @encounter_mint.roll(map, enctype)

      tag = if legal == false then "SUSPECT species-not-in-table"
            elsif wrong_map    then "SUSPECT wrong-map(on #{pos[0]})"
            else "ok"
            end
      wm = would ? "#{would['species']}@#{would['level']}#{would['shiny'] ? '/shiny' : ''}" : "-"
      @log.call("encounter: account #{account_id} #{tag} map #{map} #{enctype} " \
                "client=#{species}@#{level} server_would=#{wm}")
      flag_anomaly(account_id, :encounter_species)   if legal == false
      flag_anomaly(account_id, :encounter_wrong_map) if legal != false && wrong_map
    end

    # M4 Layer D D2 (on): server-authoritative wild-encounter MINT. The client requests an
    # encounter for (map, enctype); the server rolls the slot (species+level) from the Layer
    # A tables and mints the identity {personalID, iv[6], shiny} with SecureRandom, and the
    # client builds the wild Pokémon from it — so the server owns what appears, its level,
    # shininess and IVs (client = observer). Pure CPU (no DB), so it replies inline.
    # Fail-OPEN: a wrong-map claim or a map with no table denies, and the client falls back
    # to a local roll — wild encounters must never just stop happening.
    def handle_encounter_req(conn, env, account_id)
      seq = env[:seq]
      # Only an `on` server mints (an honest client only asks when `on` was advertised;
      # a modified one asking anyway must not get real mints recorded as provenance).
      unless @config.battle_enforce_encounters == :on
        return reply(conn, type: :encounter_deny, seq: seq, reason: "not_enforcing")
      end

      map     = env[:map]
      enctype = env[:enctype].to_s
      return reply(conn, type: :encounter_deny, seq: seq, reason: "bad_req") unless map.is_a?(Integer) && !enctype.empty?

      pos = conn.data[:last_pos]
      # No server-trusted position yet (a fresh char before its first :pos) -> can't vouch for
      # the claimed map, so deny and let the client roll LOCALLY against its real map. Otherwise
      # a client could mint from any map's table before ever sending a position.
      return reply(conn, type: :encounter_deny, seq: seq, reason: "no_pos") unless pos.is_a?(Array)

      if pos[0] != map
        @log.call("encounter: account #{account_id} req wrong-map claim #{map} (on #{pos[0]}) -> deny")
        flag_anomaly(account_id, :encounter_wrong_map)
        return reply(conn, type: :encounter_deny, seq: seq, reason: "wrong_map")
      end

      mint = @encounter_mint.roll(map, enctype)
      return reply(conn, type: :encounter_deny, seq: seq, reason: "no_table") unless mint   # unexported -> local

      # Stash the mint on the connection (last 2 — a double wild battle mints two) so a
      # following :catch_req can be adjudicated against WHAT THE SERVER MINTED — its
      # species/level/IVs — not client claims. Same per-conn pattern as :last_pos.
      stash = (conn.data[:enc_mints] ||= [])
      stash << mint
      stash.shift while stash.length > 2

      # D7 part 1: a 63-bit PCG32 battle seed is born WITH the mint when the rng seam is
      # active (63-bit: Postgres bigint is signed). In `on` the client draws the battle's
      # RNG from it; in `shadow` it is only the record<->roll correlation token. Old
      # clients ignore the extra grant key.
      seed = (SecureRandom.random_number(1 << 63) if @config.battle_enforce_rng != :off)

      # D3.2: persist the mint (durable claim-check for the caught mon's UID provenance).
      # Background on the per-account mailbox — the grant reply stays inline, and mailbox
      # FIFO guarantees this insert lands before any later catch/uid frame's DB work.
      @mailbox.submit(account_id) do
        begin
          @encounter_rolls.record(account_id, mint, map, enctype, seed: seed)
        rescue StandardError => e
          @log.call("encounter: roll persist failed #{e.class}: #{e.message}")
        end
      end

      @log.call("encounter: account #{account_id} MINT map #{map} #{enctype} -> " \
                "#{mint['species']}@#{mint['level']}#{mint['shiny'] ? ' /SHINY' : ''}")
      grant = { type: :encounter_grant, seq: seq,
                species: mint["species"], level: mint["level"],
                pid: mint["pid"], iv: mint["iv"], shiny: mint["shiny"] }
      grant[:battle_seed] = seed if seed
      reply(conn, **grant)
    end

    # Audit item 4: the switches/variables/self-switches DETECTION shadow. An absolute
    # snapshot on the account mailbox (the :inv pattern). Detection-only: a self-switch
    # REWIND (one-shot events re-armed = the NPC-gift/TM/key-item re-farm) is logged and
    # feeds the D5 review queue; nothing is ever rejected or corrected.
    def handle_flags(conn, env, account_id)
      return unless @flag_state

      seq = env[:seq]
      payload = { switches: env[:switches], variables: env[:variables], self_switches: env[:self_switches] }
      # A dropped job (queue full) must NOT leave the client believing its snapshot
      # landed — it would advance its seq and the server would then reject every
      # later one as stale. Nack so the client can resend.
      queued = @mailbox.submit(account_id) do
        status, flags = @flag_state.apply_flags(account_id, payload, seq)
        flag_anomaly(account_id, :flag_rewind) if flags&.include?("rewind")
        @reactor.post { reply(conn, type: :flags_ack, seq: seq, flagged: status == :ack && flags.any?) }
      end
      reply(conn, type: :flags_ack, seq: seq, busy: true) unless queued
    end

    # Step 3: an intercepted-write DELTA. Fire-and-forget; the server folds it into
    # the mirror it compares against the next absolute snapshot (the trust gate).
    def handle_flag_delta(env, account_id)
      return unless @flag_state

      payload = { switches: env[:switches], variables: env[:variables],
                  self_switches: env[:self_switches], overflow: env[:overflow] }
      @mailbox.submit(account_id) { @flag_state.apply_delta(account_id, payload) }
    end

    # Audit item 4 (second half): an NPC gift / event-granted item. Fire-and-forget
    # DETECTION — the ledger records which one-shot event granted what, so a re-farm
    # (self-switch rewind -> the same event pays out again) leaves a trace naming it.
    def handle_gift_claim(env, account_id)
      return unless @gift_claims

      map = env[:map]; event = env[:event]; item = env[:item].to_s; qty = env[:quantity]
      @mailbox.submit(account_id) do
        verdict = @gift_claims.claim(account_id, map, event, item, qty)
        flag_anomaly(account_id, :gift_refarm) if verdict == :suspect
      end
    end

    # M4 Layer D D7 part 1: a finished wild battle's capture record (fire-and-forget,
    # no reply — instrumentation, never adjudicates). The opaque body is stored
    # verbatim for part 2's headless replay; ingest runs on the account mailbox so the
    # seed's roll row (recorded there) is guaranteed visible.
    def handle_battle_record(env, body, account_id)
      return unless @battle_records

      @mailbox.submit(account_id) do
        begin
          result = @battle_records.ingest(account_id, env, body)
          # the seed walk refuted the claimed draws -> D5 review-queue counter
          flag_anomaly(account_id, :rng_desync) if result == :desync
        rescue StandardError => e
          @log.call("battlerec: ingest job failed #{e.class}: #{e.message}")
        end
      end
    end

    # M4 Layer D D3 (on): server-adjudicated Poké Ball capture. The client asks for a
    # verdict on a ball throw; the server finds the STASHED D2 encounter mint (so species/
    # level/IVs are what IT minted, never client claims), computes the engine capture
    # formula with clamped client inputs (HP bounded by the server-computed max, ball rate
    # capped at the ball's legitimate best, status whitelisted) and rolls the shakes with
    # SecureRandom — a cheat can no longer force an unrolled catch. A successful catch
    # CONSUMES the stashed mint (one catch per encounter). Fail-OPEN: no mint / not
    # enforcing / unknown species -> deny -> the client rolls locally.
    def handle_catch_req(conn, env, account_id)
      seq = env[:seq]
      unless @config.battle_enforce_catches == :on
        return reply(conn, type: :catch_deny, seq: seq, reason: "not_enforcing")
      end

      species = env[:species].to_s[0, 32]
      level   = env[:level]
      mints   = conn.data[:enc_mints]
      mint    = mints.is_a?(Array) &&
                mints.find { |m| m["species"] == species && m["level"] == level }
      unless mint
        @log.call("catch: account #{account_id} req #{species}@#{level.inspect} has NO stashed mint -> local")
        return reply(conn, type: :catch_deny, seq: seq, reason: "no_encounter")
      end

      # A miss doesn't consume the mint (vanilla re-throws are legit), so count the
      # attempts: a client hammering :catch_req to brute-force the roll shows up here.
      mint["attempts"] = (mint["attempts"] || 0) + 1
      if mint["attempts"] == 21
        @log.call("catch: account #{account_id} SUSPECT catch-spam #{species}@#{level} (21+ attempts on one mint)")
        flag_anomaly(account_id, :catch_spam)
      end

      hp_iv   = mint["iv"].is_a?(Array) ? mint["iv"][0] : nil
      verdict = @catch_calc.adjudicate(species, mint["level"], hp_iv,
                                       env[:ball].to_s, env[:hp_current], env[:status].to_s,
                                       claimed_rate: env[:claimed_rate],
                                       dex_owned: env[:dex_owned], charm: env[:charm] == true)
      return reply(conn, type: :catch_deny, seq: seq, reason: "unknown_species") unless verdict

      if verdict[:caught]
        mints.delete_at(mints.index(mint))   # one successful catch per mint
        # D3.2: stamp the persisted roll as caught (mailbox FIFO -> after its record).
        pid = mint["pid"]
        lvl = mint["level"]
        @mailbox.submit(account_id) do
          begin
            unless @encounter_rolls.mark_caught(account_id, species, lvl, pid)
              # Always anomalous in the caught branch: the roll's record must have failed.
              @log.call("catch: account #{account_id} caught-stamp found NO roll for #{species}@#{lvl} (record failed earlier?)")
            end
          rescue StandardError => e
            @log.call("catch: roll caught-stamp failed #{e.class}: #{e.message}")
          end
        end
      end
      @log.call("catch: account #{account_id} VERDICT #{species}@#{mint['level']} " \
                "ball=#{env[:ball].to_s[0, 24]} shakes=#{verdict[:shakes]}#{verdict[:critical] ? ' CRIT' : ''} " \
                "#{verdict[:caught] ? 'CAUGHT' : 'broke free'} " \
                "(hp=#{env[:hp_current].inspect}/#{verdict[:total_hp]} status=#{env[:status].to_s[0, 16]})")
      reply(conn, type: :catch_verdict, seq: seq,
            shakes: verdict[:shakes], critical: verdict[:critical])
    end

    # M4 Layer D D3 (shadow): the client reports the shakes its LOCAL calc produced; the
    # server rolls its own verdict from the same (clamped) inputs and logs both, so the
    # ported formula can be validated against real play before `on`. Fire-and-forget.
    def handle_catch_report(conn, env, account_id)
      species = env[:species].to_s[0, 32]
      return if species.empty?

      mints = conn.data[:enc_mints]
      mint  = mints.is_a?(Array) && mints.find { |m| m["species"] == species }
      hp_iv = mint && mint["iv"].is_a?(Array) ? mint["iv"][0] : nil
      would = @catch_calc.adjudicate(species, env[:level], hp_iv,
                                     env[:ball].to_s, env[:hp_current], env[:status].to_s,
                                     claimed_rate: env[:claimed_rate],
                                     dex_owned: env[:dex_owned], charm: env[:charm] == true)
      wm = would ? "#{would[:shakes]}#{would[:critical] ? ' CRIT' : ''}#{would[:caught] ? ' CAUGHT' : ''}" : "-"
      @log.call("catch: account #{account_id} report #{species}@#{env[:level].inspect} " \
                "ball=#{env[:ball].to_s[0, 24]} client_shakes=#{env[:shakes].inspect} server_would=#{wm}")
    end

    # Server-authoritative trade COMMIT (M3.2). The only authoritative trade frame
    # (invite/accept/offer/lock/cancel are pure peer relay via ADDRESSED). Each side
    # commits ONLY after it holds the partner's uid-validated object; the server
    # rendezvous fires the atomic swap when BOTH matching commits arrive.
    def handle_trade_commit(conn, env, account_id)
      trade_id = env[:trade_id]
      partner  = env[:partner]
      give     = env[:give]
      recv     = env[:recv]
      max      = @config.monster_caps[:trade_max]
      unless trade_id.is_a?(String) && partner.is_a?(Integer) && partner != account_id &&
             uid_list?(give, max) && uid_list?(recv, max)
        @log.call("server: bad :trade_commit from account #{account_id} -> drop")
        return
      end
      give = give.sort
      recv = recv.sort

      pending = @pending_trades[trade_id]
      if pending.nil?
        @pending_trades[trade_id] = { account: account_id, partner: partner,
                                      give: give, recv: recv, conn: conn, at: Time.now }
        return
      end

      @pending_trades.delete(trade_id)
      # Cross-check the two commits name each other and mirror give/recv exactly. A
      # third party guessing a trade_id fails here (its partner id won't match).
      unless pending[:account] == partner && pending[:partner] == account_id &&
             pending[:give] == recv && pending[:recv] == give
        reply(conn, type: :trade_result, trade_id: trade_id, ok: false, reason: "terms")
        reply(pending[:conn], type: :trade_result, trade_id: trade_id, ok: false, reason: "terms")
        return
      end

      a = pending[:account]; a_conn = pending[:conn]; a_gives = pending[:give]
      b = account_id;        b_conn = conn;           b_gives = give
      @pool.submit do
        # A raise here used to leave BOTH traders in :committing forever (no client
        # timeout, and Trade.busy? then suppresses everything else) — audit. The
        # transaction has already rolled back, so replying failure is always safe.
        st = begin
          @trades.execute_trade(trade_id, a: a, b: b, a_gives: a_gives, b_gives: b_gives)
        rescue StandardError => e
          @log.call("server: trade #{trade_id} #{a}<->#{b} raised #{e.class}: #{e.message}")
          [:err, "error"]
        end
        @reactor.post do
          if st.first == :ok || st.first == :ok_replay
            reply(a_conn, type: :trade_result, trade_id: trade_id, ok: true, recv: b_gives, gave: a_gives) if @reactor.alive?(a_conn)
            reply(b_conn, type: :trade_result, trade_id: trade_id, ok: true, recv: a_gives, gave: b_gives) if @reactor.alive?(b_conn)
            @log.call("server: trade #{trade_id} #{a}<->#{b} swapped #{a_gives}/#{b_gives}")
          else
            reason = st[1].to_s
            reply(a_conn, type: :trade_result, trade_id: trade_id, ok: false, reason: reason) if @reactor.alive?(a_conn)
            reply(b_conn, type: :trade_result, trade_id: trade_id, ok: false, reason: reason) if @reactor.alive?(b_conn)
          end
        end
      end
    end

    def uid_list?(a, max)
      a.is_a?(Array) && a.size.between?(1, max) && a.all? { |u| u.is_a?(Integer) && u.positive? }
    end

    # Reactor-thread periodic: time out a lone (half-committed) rendezvous whose
    # partner never committed and never disconnected. A lone commit never mutated
    # the registry, so this only frees the entry + tells the waiter.
    # Reactor-thread periodic hook (fires up to ~2x/s). Keep it O(1): the trade sweep is
    # in-memory; the anomaly sweep is DB-heavy so it's dispatched to a worker, gated to run
    # at most every ANOMALY_SWEEP_SEC and never overlapping itself.
    ANOMALY_SWEEP_SEC = 60
    RESIM_SWEEP_SEC   = 60

    def on_tick
      sweep_trades
      maybe_anomaly_sweep
      maybe_resim_sweep
    end

    # D8: same non-overlapping worker-dispatch shape as the anomaly sweep. Consumes
    # harness-stamped verdicts into monster state. Logs a loud WARNING if replayable
    # records pile up while verdict_at never advances (the harness isn't running).
    def maybe_resim_sweep
      return unless @resim

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if @resim_sweeping
      return if @last_resim_sweep && (now - @last_resim_sweep) < RESIM_SWEEP_SEC

      @last_resim_sweep = now
      @resim_sweeping   = true
      @pool.submit do
        begin
          @resim.sweep
          warn_if_harness_stalled
        ensure
          @reactor.post { @resim_sweeping = false }
        end
      end
    end

    def warn_if_harness_stalled
      stale = @db[:battle_records].where(replay_status: %w[pending walk_ok walk_skipped])
                                  .where { created_at < Time.now - 86_400 }.count
      @log.call("resim: WARNING #{stale} replayable record(s) >24h old with no verdict — is bin/pemk_replay.rb running?") if stale.positive?
    rescue StandardError => e
      @log.call("resim: harness-liveness check failed #{e.class}: #{e.message}")
    end

    def maybe_anomaly_sweep
      return unless @anomaly

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if @anomaly_sweeping
      return if @last_anomaly_sweep && (now - @last_anomaly_sweep) < ANOMALY_SWEEP_SEC

      @last_anomaly_sweep = now
      @anomaly_sweeping   = true
      @pool.submit do
        begin
          @anomaly.sweep
        ensure
          @reactor.post { @anomaly_sweeping = false }   # clear on the reactor thread
        end
      end
    end

    # Fire-and-forget: bump an account's SUSPECT counter off the reactor thread (atomic
    # upsert). No-op unless anomaly detection is enabled.
    def flag_anomaly(account_id, kind)
      @pool.submit { @anomaly.record_flag(account_id, kind) } if @anomaly
    end

    def sweep_trades
      return if @pending_trades.empty?

      now = Time.now
      @pending_trades.reject! do |tid, p|
        next false if (now - p[:at]) < TRADE_TTL

        reply(p[:conn], type: :trade_result, trade_id: tid, ok: false, reason: "timeout") if @reactor.alive?(p[:conn])
        true
      end
    end

    # Canonical primitives the client reconciles onto its save at load (login_ok /
    # auth_ok), plus the per-channel seq the client adopts as its next-seq authority.
    # inv carries the whole bag (server-persistent, like economy): nil when unseeded
    # so the client keeps its blob bag and seeds the record on the first flush.
    # mon_seq is the :mon_party high-water; mon_evict is the M3.2 positive list of
    # uids this account traded away and no longer owns (the client evicts them).
    def reconcile_block(account_id)
      snap = @ledger.snapshot(account_id)
      inv  = @inventory.snapshot(account_id)
      { econ: snap[:balances], econ_seq: snap[:last_seq],
        inv: inv[:bag], inv_seq: inv[:last_seq],
        mon_seq: @monsters.mon_seq(account_id),
        mon_evict: @monsters.evictions(account_id),
        pickup_enforce: @config.pickup_enforce,     # M4 Layer C: client gates pickups only when on
        pickup_reset_allowed: @config.pickup_reset_allowed,    # dev-only F9 reset offered only when on
        battle_enforce_teams: @config.battle_enforce_teams.to_s,   # M4 Layer D D1 team-legality mode
        battle_enforce_encounters: @config.battle_enforce_encounters.to_s,   # M4 Layer D D2 encounter mode
        battle_enforce_catches: @config.battle_enforce_catches.to_s,         # M4 Layer D D3 catch mode
        battle_enforce_rewards: @config.battle_enforce_rewards.to_s,         # M4 Layer D D4 reward mode
        battle_enforce_exp: @config.battle_enforce_exp.to_s,                 # M4 Layer D D6 EXP mode
        battle_enforce_rng: @config.battle_enforce_rng.to_s,                 # M4 Layer D D7 rng/capture mode
        battle_enforce_resim: @config.battle_enforce_resim.to_s,             # M4 Layer D D8 enforcement mode
        flag_state: @config.flag_state.to_s,                                 # audit item 4: flags shadow
        flags_seq: (@flag_state ? (@flag_state.snapshot(account_id)&.fetch(:last_seq, 0) || 0) : 0),
        flag_policy: flag_policy,
        flag_facts: (@config.flag_state == :on && @flag_state ? @flag_state.materialize_facts(account_id) : nil) }
    end

    # The owned-id sets FlagState judges over, from the same manifest the client is
    # handed — so the trust gate measures exactly the ids we claim, and nothing else.
    def manifest_policy
      m = @world.flag_manifest
      return nil unless m.is_a?(Hash)

      out = {}
      %w[switches variables].each do |kind|
        sec = m[kind]
        next unless sec.is_a?(Hash)

        out[kind.to_sym] = sec.select { |_, e| e.is_a?(Hash) && e["tier"] && e["tier"] != "local" }.keys
      end
      out
    end

    # id -> stable name key for FACT-tier switches, so the ledger survives a renumber.
    def manifest_fact_keys
      m = @world.flag_manifest
      return {} unless m.is_a?(Hash) && m["switches"].is_a?(Hash)

      out = {}
      m["switches"].each do |id, e|
        out[id.to_i] = e["key"] if e.is_a?(Hash) && e["tier"] == "fact" && e["key"]
      end
      out
    end

    # "map:event" of the events the manifest found to be on a cooldown. Their
    # self-switch is cleared on purpose when the timer elapses, so it must never be
    # banked as a monotonic fact.
    def manifest_repeatable
      m = @world.flag_manifest
      sec = m.is_a?(Hash) ? m["self_switches"] : nil
      sec.is_a?(Hash) ? Array(sec["repeatable"]) : []
    end

    # The build-time tier table, pushed so BOTH sides provably agree on the policy.
    # Only NON-LOCAL ids travel — absent means local, which is the pre-sovereignty
    # behaviour, so the payload stays tiny (32 entries on the reference project).
    def flag_policy
      return nil unless @flag_state && @world.flag_manifest

      out = {}
      %w[switches variables].each do |kind|
        sec = @world.flag_manifest[kind]
        next unless sec.is_a?(Hash)

        picked = {}
        sec.each { |id, e| picked[id] = e["tier"] if e.is_a?(Hash) && e["tier"] && e["tier"] != "local" }
        out[kind] = picked unless picked.empty?
      end
      out.empty? ? nil : out
    end

    # Zone-scoped presence: track each player's current map and fan a position
    # update out ONLY to same-map connections (the 500-CCU lever). Runs inline on
    # the reactor thread — cheap, in-memory, no DB. Identity is the server-trusted
    # account_id, not the client-provided :id (anti-spoof).
    def handle_presence(conn, env, account_id)
      map = env[:map]
      return unless map.is_a?(Integer)

      # M4 Layer B: audit FIRST. In :on mode an enforceable violation stashes the
      # last-good tile in conn.data[:correct_to] — send a :pos_correct and REJECT the
      # frame: no zone change and no fan-out of the rejected position, so peers keep
      # seeing the offender at its last accepted tile and it never joins the illegal
      # map's zone. In :off/:shadow correct_to is never set, so the frame flows on.
      @pos_audit.check(account_id, env, conn.data)
      if (tgt = conn.data.delete(:correct_to))
        reply(conn, type: :pos_correct, map: tgt[0], x: tgt[1], y: tgt[2])
        return
      end

      old = conn.data[:map_id]
      if old && old != map
        @zones[old].delete(conn)
        broadcast_zone(old, conn, Wire.encode_split({ type: :leave, id: account_id }))
        @zones.delete(old) if @zones[old].empty?   # reap AFTER the broadcast (audit: unbounded growth)
      end
      @zones[map].add(conn)
      conn.data[:map_id] = map

      # ALLOWLIST the fan-out frame instead of echoing the client's envelope: env.merge
      # would relay every extra key the client attached (up to the 64 KiB envelope cap)
      # to every peer on the map — a broadcast amplifier, and an injection surface.
      broadcast_zone(map, conn, Wire.encode_split(presence_frame(env, account_id, map)))
    end

    # The only fields a presence frame may carry to peers.
    def presence_frame(env, account_id, map)
      out = { type: env[:type], id: account_id, map: map }
      %i[x y dir mode].each { |k| out[k] = env[k] if env[k].is_a?(Integer) || env[k].is_a?(Symbol) }
      out
    end

    def broadcast_zone(map, sender, frame)
      @zones[map].each { |c| @reactor.send_frame(c, frame) unless c.equal?(sender) }
    end

    # Relay an addressed frame to ONLY the :to account's connection, re-stamping
    # :from with the server-trusted sender id and preserving the opaque body
    # (e.g. a battle team). Unknown/offline or self-addressed -> dropped.
    #
    # AUTHORIZATION (audit): the relay used to forward ANY of the 15 addressed types,
    # with an unbounded body, to ANY online account. That was three weapons at once —
    # a >OUTBUF_CAP body disconnected the victim, an unsolicited :battle_team made the
    # victim Marshal.load attacker bytes, and a third party could inject into a live
    # battle. Now: HANDSHAKE frames (invite/accept/decline) may reach a stranger — that
    # is what an invite IS — but every PAYLOAD frame requires a live peer session that
    # only a mutual accept creates, and every body is capped.
    RELAY_BODY_MAX = 256 * 1024   # a Marshal'd battle team is a few KB

    def handle_addressed(sender, env, body, from_account)
      target = @online[env[:to]]
      if target.nil? || target.equal?(sender)
        @log.call("server: no route for #{env[:type].inspect} -> #{env[:to].inspect}")
        return
      end

      if body && body.bytesize > RELAY_BODY_MAX
        @log.call("server: account #{from_account} oversized #{env[:type].inspect} body " \
                  "(#{body.bytesize}B > #{RELAY_BODY_MAX}) -> drop")
        return
      end

      unless relay_allowed?(env[:type], from_account, env[:to])
        @log.call("server: account #{from_account} #{env[:type].inspect} -> #{env[:to].inspect} " \
                  "without a peer session -> drop")
        return
      end

      note_peer_session(env[:type], from_account, env[:to])
      @reactor.send_frame(target, Wire.encode_split(env.merge(from: from_account), body))
    end

    # Frames a stranger may legitimately send: the handshake itself, plus the
    # TEARDOWN. trade_cancel is deliberately here — the inviter's :awaiting_accept
    # watchdog fires BEFORE any accept opened a session, and dropping that cancel
    # would leave the invitee waiting on its own 30s timeout instead of being told
    # at once. It is a pure control frame (no body is ever read from it) and the
    # client already ignores one that doesn't match its own live trade (`mine?`),
    # so admitting it from a stranger grants nothing.
    HANDSHAKE = %i[challenge challenge_accept challenge_decline
                   trade_invite trade_accept trade_decline trade_cancel].freeze

    def relay_allowed?(type, from_account, to_account)
      return true if HANDSHAKE.include?(type)

      @peer_sessions[from_account] == to_account && @peer_sessions[to_account] == from_account
    end

    # A mutual accept opens the session; a decline/cancel/end closes it. Reactor-thread
    # only (like @online/@zones), so a plain Hash is correct.
    def note_peer_session(type, from_account, to_account)
      case type
      when :challenge_accept, :trade_accept
        @peer_sessions[from_account] = to_account
        @peer_sessions[to_account]   = from_account
      when :challenge_decline, :trade_decline, :trade_cancel, :battle_end
        clear_peer_session(from_account)
        clear_peer_session(to_account)
      end
    end

    def clear_peer_session(account_id)
      partner = @peer_sessions.delete(account_id)
      @peer_sessions.delete(partner) if partner && @peer_sessions[partner] == account_id
    end

    def bind(conn, account_id)
      # A reconnect on a new socket takes over routing for the account.
      previous = @online[account_id]
      previous.closing = true if previous && !previous.equal?(conn)
      conn.data[:account_id] = account_id
      @online[account_id] = conn
      @log.call("server: authed #{conn.addr} as account #{account_id}")
    end

    def reply(conn, **env)
      @reactor.send_frame(conn, Wire.encode_split(env))
    end

    def reply_body(conn, env, body)
      @reactor.send_frame(conn, Wire.encode_split(env, body))
    end

    def on_close(conn)
      aid = conn.data[:account_id]
      @online.delete(aid) if aid && @online[aid].equal?(conn)
      if aid
        cancel_pending_trades(aid, conn)
        clear_peer_session(aid)   # a dropped account's peer session dies with it
      end

      map = conn.data[:map_id]
      return unless map

      @zones[map].delete(conn)
      broadcast_zone(map, conn, Wire.encode_split({ type: :leave, id: aid })) if aid
      @zones.delete(map) if @zones[map].empty?   # reap AFTER the broadcast
    end

    # A dropped account cancels any rendezvous it was part of. If a LONE committer
    # (the still-connected party) was waiting on this account, tell it "partner_left"
    # — a single commit never mutated the registry, so nothing was traded.
    def cancel_pending_trades(aid, closing_conn)
      @pending_trades.reject! do |tid, p|
        next false unless p[:account] == aid || p[:partner] == aid

        waiter = p[:conn]
        if !waiter.equal?(closing_conn) && @reactor.alive?(waiter)
          reply(waiter, type: :trade_result, trade_id: tid, ok: false, reason: "partner_left")
        end
        true
      end
    end

    def install_signal_handlers
      %w[INT TERM].each { |sig| Signal.trap(sig) { @reactor.stop } }
    end
  end
end
