# frozen_string_literal: true

module PEMK
  # M4 Layer D D4: wild-battle reward WINDOWS. When the client reports a wild battle's
  # end (:battle_end — outcome + the foes it fought), a per-account budget window opens:
  # how much EXP the party could have legitimately gained (RewardCalc envelope) and how
  # much money could have moved (Pay Day gain / blackout loss). Subsequent money deltas
  # and level jumps are checked against — and consume — the window:
  #
  #   money  in-window & within budget  -> ledger reason "battle:<n>" (attribution)
  #          in-window but OVER budget  -> "battle_suspect:<n>" + a SUSPECT log
  #          no window                  -> "unattributed" (shops/trades are normal)
  #   levels jump needs more exp than the window holds -> SUSPECT log (detection-only,
  #          it NEVER rejects). Level items used outside battles (Rare Candy, the Exp.
  #          Candies) are credited from the bag snapshots first, so using them is not
  #          suspect; where the items came from is the inventory audit's question.
  #
  # ATTRIBUTION vs SUSPICION: money attribution (`battle:<n>` / `unattributed`) is written
  # to the append-only ledger, so it must stay CLEAN — a suspicious over-budget delta is
  # still attributed to its battle window and the *suspicion* is a returned flag the caller
  # LOGS (never a ledger label). A money DECREASE is a spend/loss, never a reward cheat, so
  # it is never suspect.
  #
  # THREADING: called from BOTH the reactor thread (record_battle, check_levels) and worker
  # threads (note_money, via the PlayerMailbox), so all @windows access is under @mutex.
  class RewardAudit
    WINDOW_TTL  = 90         # seconds a battle's budget stays consumable
    MAX_WINDOWS = 4_096      # stale-entry sweep threshold (accounts, not per-account)

    # Items that level a Pokemon up when used on it: levels per use, or EXP per use.
    LEVEL_ITEMS = { RARECANDY: 1 }.freeze
    EXP_ITEMS   = { EXPCANDYXS: 100, EXPCANDYS: 800, EXPCANDYM: 3_000,
                    EXPCANDYL: 10_000, EXPCANDYXL: 30_000 }.freeze
    # The level-up can reach the server a checkpoint after the bag does (the party is
    # projected on save, the bag on change), so a used item stays credited a while.
    ITEM_CREDIT_TTL   = 1_800
    CREDIT_MAX_LEVELS = 600          # a full party from 1 to 100
    CREDIT_MAX_EXP    = 10_000_000

    def initialize(reward_calc, battle_data, logger: nil)
      @calc    = reward_calc
      @bd      = battle_data
      @log     = logger || ->(_m) {}
      @windows = {}   # account_id => { id:, exp:, gain:, loss:, at: }
      @counter = 0
      @mutex   = Mutex.new
    end

    # A wild battle ended. Accumulate its budgets into the account's window (several
    # quick battles inside one TTL stack). foes: [{species:, level:}...] (<=2, already
    # validated by the handler). -> the window (for logging).
    def record_battle(account_id, foes, outcome, now: Time.now)
      @mutex.synchronize do
        w = window(account_id, now)
        if [1, 4].include?(outcome)   # won / caught: exp + Pay Day gains possible
          foes.each do |f|
            per_foe = @calc.max_exp_per_foe(f[:species], f[:level])
            w[:exp] += per_foe if per_foe
          end
          w[:gain] += @calc.wild_money_gain_max
        elsif [2, 5].include?(outcome)   # lost / draw: blackout money loss possible
          w[:loss] += @calc.wild_money_loss_max
        end
        w[:at] = now
        w.dup   # a copy for logging; never let the caller mutate the live window
      end
    end

    # A money delta arrived. -> [ledger_reason, suspect_bool]. The reason is always a CLEAN
    # attribution (`battle:<n>` / `unattributed`) safe to persist; suspect is a log-only
    # flag. Consumes budget. A negative delta (spend/blackout) is never suspect.
    def note_money(account_id, delta, now: Time.now)
      @mutex.synchronize do
        w = live_window(account_id, now)
        return ["unattributed", false] unless w && delta.is_a?(Integer) && delta != 0

        if delta.positive?
          if delta <= w[:gain]
            w[:gain] -= delta
            ["battle:#{w[:id]}", false]
          else
            w[:gain] = 0
            ["battle:#{w[:id]}", true]   # over the battle's yield -> attributed + SUSPECT (logged, not persisted)
          end
        elsif -delta <= w[:loss]
          w[:loss] += delta              # delta negative -> shrinks the loss budget
          ["battle:#{w[:id]}", false]
        else
          ["unattributed", false]        # a spend larger than the blackout cap: a normal purchase
        end
      end
    end

    # A connection's level-item credit, fed by note_items and spent by check_levels.
    # Lives with the connection (the caller keeps it), so it needs no sweeping.
    def self.new_credit
      { counts: nil, levels: 0, exp: 0, at: nil }
    end

    # A bag snapshot arrived (absolute: item => quantity). Level items that went down
    # since the last one were used, on a Pokemon most likely: each credits the next
    # level jumps, a Rare Candy one level, an Exp. Candy its EXP. The first snapshot
    # only sets the baseline.
    def note_items(credit, bag, now: Time.now)
      return unless credit && bag.is_a?(Hash)

      counts = (LEVEL_ITEMS.keys + EXP_ITEMS.keys).to_h do |item|
        qty = bag.key?(item) ? bag[item] : bag[item.to_s]
        [item, qty.is_a?(Integer) ? qty : 0]
      end
      prev = credit[:counts]
      credit[:counts] = counts
      return unless prev

      levels = 0
      exp    = 0
      counts.each do |item, qty|
        used = prev.fetch(item, 0) - qty
        next unless used.positive?

        levels += used * LEVEL_ITEMS.fetch(item, 0)
        exp    += used * EXP_ITEMS.fetch(item, 0)
      end
      return if levels.zero? && exp.zero?

      expire_credit(credit, now)
      credit[:levels] = [credit[:levels] + levels, CREDIT_MAX_LEVELS].min
      credit[:exp]    = [credit[:exp] + exp, CREDIT_MAX_EXP].min
      credit[:at]     = now
    end

    # Party level jumps arrived (from the party projection). changes = [[species, old,
    # new], ...]. Levels the connection's used Rare Candies account for are free; the
    # rest needs the conservative min-exp of each jump, taken from the battle window and
    # then from used Exp. Candies. Anything beyond is suspect (detection-only).
    # -> [suspect_bool, detail_str].
    def check_levels(account_id, changes, credit: nil, now: Time.now)
      expire_credit(credit, now) if credit
      need    = 0
      parts   = []
      unknown = false
      changes.each do |species, old_l, new_l|
        if credit && credit[:levels].positive?
          free = [credit[:levels], new_l - old_l].min
          credit[:levels] -= free
          old_l += free
          next if old_l >= new_l
        end
        sp   = @bd.species(species.to_s)
        rate = sp && sp["growth_rate"]
        min  = rate && @calc.min_exp_for_jump(rate, old_l, new_l)
        if min.nil?
          unknown = true   # no curve/species -> that jump is unjudgeable, skip it
          next
        end
        need += min
        parts << "#{species} #{old_l}->#{new_l}(min #{min})"
      end
      return [false, nil] if need.zero?

      @mutex.synchronize do
        w      = live_window(account_id, now)
        budget = w ? w[:exp] : 0
        items  = credit ? credit[:exp] : 0
        if need <= budget + items
          from_window = [need, budget].min
          w[:exp] -= from_window if w
          credit[:exp] -= need - from_window if credit
          [false, nil]
        else
          detail = "#{parts.join(', ')} needs >=#{need} exp vs window #{budget}" \
                   "#{items.positive? ? " + items #{items}" : ''}" \
                   "#{unknown ? ' (+unjudgeable jumps skipped)' : ''}"
          [true, detail]
        end
      end
    end

    def expire_credit(credit, now)
      return unless credit[:at] && now - credit[:at] > ITEM_CREDIT_TTL

      credit[:levels] = 0
      credit[:exp]    = 0
      credit[:at]     = nil
    end

    private
    # NOTE: window/live_window/sweep assume @mutex is already held (all public callers wrap).

    def window(account_id, now)
      sweep(now) if @windows.size > MAX_WINDOWS
      w = live_window(account_id, now)
      return w if w

      @counter += 1
      @windows[account_id] = { id: @counter, exp: 0, gain: 0, loss: 0, at: now }
    end

    def live_window(account_id, now)
      w = @windows[account_id]
      return nil unless w

      if now - w[:at] > WINDOW_TTL
        @windows.delete(account_id)
        nil
      else
        w
      end
    end

    def sweep(now)
      @windows.delete_if { |_k, w| now - w[:at] > WINDOW_TTL }
    end
  end
end
