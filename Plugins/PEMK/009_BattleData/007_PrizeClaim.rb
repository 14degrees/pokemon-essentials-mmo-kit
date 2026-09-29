#===============================================================================
# PEMK :: PrizeClaim  (client side — money authority M1a: trainer prizes claimed)
#-------------------------------------------------------------------------------
# A trainer battle's prize is claimed where the engine pays it (Battle#pbGainMoney),
# just before the engine adds it. The claim names each trainer by the data it was built
# from and the event that started its battle - both tagged when GameData::Trainer builds
# it (#to_trainer), so a rival's substituted name, and a trainer that spotted the player
# first and waited for a second one, keep theirs - with the amount the engine is about
# to pay and its multiplier facts (Amulet Coin, Happy Hour). The coins Pay Day scattered
# are claimed apart (M1c): a wild battle's name its foes, a trainer battle's its prize
# claim.
#
# The server judges it against the exports and records its verdict (money_claims at
# login; shadow only logs). A fresh position goes first, since the claim is judged by
# where the server last saw the player. The claim waits in the save until the server
# answers it, and goes out again on a new connection; the econ flush is held during
# battles, so it always reaches the server before the frame that shows its money.
#===============================================================================
class PokemonGlobalMetadata
  attr_accessor :pemk_prize_claims   # [[nonce, trainers, amount, amulet, happy_hour, map, partner], ...]
end

class NPCTrainer
  attr_accessor :pemk_key     # [type, name, version] of the trainer data it was built from
  attr_accessor :pemk_event   # [map, event] of the event whose battle built it
end

module PEMK
  module PrizeClaim
    RESEND_AFTER = 10.0   # seconds before an unanswered claim goes out again
    HOLD_MAX     = 60.0   # M3: seconds a money frame waits at most for this session's verdicts

    @mode  = :off
    @asked = {}   # nonce => when this connection last sent it (monotonic)
    @local = {}   # M3: nonce => [money the engine added here, when, released, dropped]
    @late  = {}   # M3: nonces still waiting in the save when a fresh login adopted the balance
    @rng   = nil

    module_function

    # Sync.reset on (re)connect: every claim goes out again on the new socket, and the
    # mode waits for the server to say it again. The money the engine added is still in
    # the game: it keeps waiting for its verdicts.
    def reset
      @mode  = :off
      @asked = {}
    end

    def adopt_mode(v)
      s = v.to_s
      @mode = %w[shadow on].include?(s) ? s.to_sym : :off
    end

    def active?
      @mode != :off
    end

    # M3: the server pays the prizes itself and refuses money it cannot explain.
    def enforced?
      @mode == :on
    end

    # GameData::Trainer#to_trainer: the data the trainer was built from, and the event
    # running its battle.
    def tag(trainer, type, name, version)
      trainer.pemk_key = [type.to_s, name.to_s, version.to_i]
      event = (pbMapInterpreterRunning? ? pbMapInterpreter.get_self : nil)
      trainer.pemk_event = [$game_map.map_id, event.id] if event && $game_map
    rescue StandardError
      nil
    end

    # Battle#pbGainMoney, before the engine pays: what it is about to add, and for whom -
    # a trainer battle's prize, and the coins Pay Day scattered (M1c).
    def claim(battle)
      return unless active? && battle.internalBattle && battle.moneyGain

      amulet = battle.field.effects[PBEffects::AmuletCoin] ? true : false
      happy  = battle.field.effects[PBEffects::HappyHour] ? true : false
      @room  = nil   # M3: what the engine can still add this battle (read at the first claim)
      prize  = battle.trainerBattle? ? claim_prize(battle, amulet, happy) : nil
      claim_payday(battle, amulet, happy, prize)
    rescue StandardError => e
      PEMK.log("prize: claim error #{e.class}: #{e.message}")
    end

    # M3: the engine adds +amount+ right after its claim (up to the money cap) - money the
    # server has not paid yet, held back from the money frames until the verdict.
    def paid_here(nonce, amount)
      return unless enforced? && $player

      @room ||= (Settings::MAX_MONEY rescue 999_999) - $player.money
      added = [[amount, @room].min, 0].max
      @room -= added
      @local[nonce] = [added, mono, false, false]
    end

    # M3: a money frame waits while a prize the engine added this session has no verdict -
    # at most HOLD_MAX, after which it goes and carries that money (released).
    def holding?
      return false unless enforced? && !@local.empty?

      now = mono
      held = false
      @local.each_value do |e|
        if now - e[1] < HOLD_MAX
          held = true
        else
          e[2] = true
        end
      end
      held
    end

    # M3: waits up to +bound+ seconds for this session's verdicts - a Mart judges the money
    # the server holds. -> true once nothing is held.
    def settle(bound)
      deadline = mono + bound
      while holding?
        return false if mono >= deadline || !online?

        Graphics.update
        Input.update
      end
      true
    end

    # M3: the money the engine added becomes what the server paid. Held back, it is
    # corrected here; released (past HOLD_MAX), the frame that carries it brings the
    # server's balance on its own - unless that frame was refused before this verdict,
    # which took it all out. A claim left over from before a fresh login, judged only now
    # (+first+), was never in the balance the login brought.
    def correct(nonce, accepted, first = false)
      e = @local.delete(nonce)
      late = @late.delete(nonce)
      return unless enforced? && $player

      paid = accepted.is_a?(Integer) ? accepted : 0
      delta = if e && e[3] then paid
              elsif e && e[2] then 0
              elsif e then paid - e[0]
              elsif late && first == true then paid
              else 0
              end
      return if delta.zero?

      $player.money = [$player.money + delta, 0].max
      PEMK.log("prize: claim #{nonce} paid #{paid}: money #{delta.positive? ? '+' : ''}#{delta}")
    end

    # M3: the server refused a money frame - the game is back at its balance, and the
    # released claims' money went with it.
    def frame_refused
      @local.each_value { |e| e[3] = true if e[2] }
    end

    # A fresh login adopted the ledger's balance: the prizes added here are in it or not,
    # as the server says. The claims still waiting in the save are paid into it only once
    # judged - those judged from now on are added then.
    def adopted
      @local.clear
      @late = claims.to_h { |e| [e[0], true] }
    end

    # -> the prize claim's nonce, or nil when its trainers were not built from data.
    def claim_prize(battle, amulet, happy)
      opp = Array(battle.opponent)
      return nil if opp.empty? || opp.any? { |t| !t.respond_to?(:pemk_key) || t.pemk_key.nil? || t.pemk_event.nil? }

      amount = 0
      opp.each_with_index { |t, i| amount += battle.pbMaxLevelInTeam(1, i) * t.base_money }
      amount *= 2 if amulet
      amount *= 2 if happy
      partner = ($PokemonGlobal.partner rescue nil)
      # Trainer proof P3: the seed the battle ran on names it - the replay of its record
      # is the claim's verdict.
      seed = (battle.pemk_rng_session&.seed rescue nil)
      entry = [new_nonce, opp.map { |t| t.pemk_key + t.pemk_event }, amount, amulet, happy, $game_map.map_id,
               partner ? [partner[0].to_s, partner[1].to_s] : nil, seed.is_a?(Integer) ? seed : nil]
      claims << entry
      paid_here(entry[0], amount)
      send_claim(entry)
      entry[0]
    end

    # Pay Day's coins, doubled like the prize. A wild battle names its foes (the server
    # minted them); a trainer battle, its prize claim.
    def claim_payday(battle, amulet, happy, prize)
      coins = battle.field.effects[PBEffects::PayDay].to_i
      return unless coins.positive?

      coins *= 2 if amulet
      coins *= 2 if happy
      if battle.trainerBattle?
        return unless prize

        proof = { "trainer_claim" => prize }
      else
        proof = { "foes" => Array(battle.pbParty(1)).map { |pk| pk.personalID }.first(2) }
      end
      entry = [new_nonce, :payday, coins, amulet, happy, $game_map.map_id, proof]
      claims << entry
      paid_here(entry[0], coins)
      send_claim(entry)
    end

    def send_claim(entry)
      return unless online?

      (PEMK::Presence.emit_now(:pos) rescue nil)   # judged by where the server last saw the player
      nonce, what, amount, amulet, happy, map, extra, seed = entry
      msg = { :type => :money_claim, :nonce => nonce, :amount => amount, :amulet => amulet,
              :happy_hour => happy, :map => map }
      if what == :payday
        msg[:kind] = :payday
        msg[:foes] = extra["foes"] if extra["foes"]
        msg[:trainer_claim] = extra["trainer_claim"] if extra["trainer_claim"]
      else
        msg[:trainers] = what
        msg[:partner] = extra if extra
        msg[:seed] = seed if seed.is_a?(Integer)   # the battle's seed (older saves' claims have none)
      end
      PEMK.send_message(msg)
      @asked[nonce] = mono
    end

    # Dispatch routes :money_claim_ack here. "wait": the server had no position for this
    # connection yet - asked again on a later tick.
    def on_ack(msg)
      n = msg && msg[:nonce]
      return unless n.is_a?(Integer)
      return if msg[:verdict].to_s == "wait"

      claims.reject! { |e| e[0] == n }
      @asked.delete(n)
      PEMK.log("prize: claim #{n} judged #{msg[:verdict]} (#{msg[:accepted]})")
      correct(n, msg[:accepted], msg[:first])
    end

    # :on_start_battle, before the battle sets in_battle (which holds every flush): the
    # facts a claim is judged by reach the server now - where the player stands, the bag
    # and the Pokemon holding items (an Amulet Coin given just before), the party and its
    # moves (Happy Hour, Pay Day). Unchanged channels send nothing.
    def before_battle
      return unless active? && online?

      (PEMK::Presence.emit_now(:pos) rescue nil)
      (PEMK::Inventory.mark rescue nil)
      (PEMK::Sync.mark_mon rescue nil)
      (PEMK::Sync.flush_primitives rescue nil)
    end

    # A new connection's reseed: every claim still unanswered goes out now, before the
    # money frame that shows it.
    def flush
      return unless active? && online?

      claims.each { |e| send_claim(e) }
    rescue StandardError => e
      PEMK.log("prize: flush error #{e.class}: #{e.message}")
    end

    # Per frame: a claim this connection has not sent, or sent long ago, goes out.
    def tick
      return unless active?

      list = claims
      return if list.empty? || !online?

      now = mono
      list.each { |e| send_claim(e) if now - (@asked[e[0]] || -1.0e18) >= RESEND_AFTER }
    rescue StandardError => e
      PEMK.log("prize: tick error #{e.class}: #{e.message}")
    end

    def claims
      g = $PokemonGlobal
      return [] unless g && g.respond_to?(:pemk_prize_claims)

      list = g.pemk_prize_claims
      list = g.pemk_prize_claims = [] unless list.is_a?(Array)
      list.select! { |e| e.is_a?(Array) && e.length == 7 && e[0].is_a?(Integer) && (e[1].is_a?(Array) || e[1] == :payday) }
      list
    end

    def online?
      return false unless PEMK.enabled? && PEMK.self_id

      c = PEMK.client
      !!(c && c.connected?)
    rescue StandardError
      false
    end

    def new_nonce
      (@rng ||= Random.new).rand(1...(1 << 62))
    end

    def mono
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rescue StandardError
      0.0
    end
  end
end

if defined?(GameData::Trainer) && !GameData::Trainer.method_defined?(:pemk_orig_to_trainer)
  module GameData
    class Trainer
      alias_method :pemk_orig_to_trainer, :to_trainer

      def to_trainer
        trainer = pemk_orig_to_trainer
        PEMK::PrizeClaim.tag(trainer, @trainer_type, @real_name, @version)
        trainer
      end
    end
  end
end

if defined?(Battle) && !Battle.method_defined?(:pemk_orig_pbGainMoney)
  class Battle
    alias_method :pemk_orig_pbGainMoney, :pbGainMoney

    def pbGainMoney
      PEMK::PrizeClaim.claim(self)
      pemk_orig_pbGainMoney
    end
  end
end

if defined?(EventHandlers)
  EventHandlers.add(:on_frame_update, :pemk_prize_claims, proc { PEMK::PrizeClaim.tick })
  EventHandlers.add(:on_start_battle, :pemk_battle_facts, proc { PEMK::PrizeClaim.before_battle })
end

# M3: Triple Triad cards live on the client alone - their sale is closed while the server
# enforces money (Sam, 2026-09-29), until it is a server transaction. Buying them is a
# spend, and stays open.
if respond_to?(:pbSellTriads, true) && !respond_to?(:pemk_orig_pbSellTriads, true)
  alias pemk_orig_pbSellTriads pbSellTriads

  def pbSellTriads
    if (PEMK::PrizeClaim.enforced? rescue false)
      pbMessage(_INTL("I'm sorry, I'm not buying cards on this server."))
      return
    end
    pemk_orig_pbSellTriads
  end
end
