#===============================================================================
# PEMK :: PrizeClaim  (client side — money authority M1a: trainer prizes claimed)
#-------------------------------------------------------------------------------
# A trainer battle's prize is claimed where the engine pays it (Battle#pbGainMoney),
# just before the engine adds it. The claim names each trainer by the data it was built
# from and the event that started its battle - both tagged when GameData::Trainer builds
# it (#to_trainer), so a rival's substituted name, and a trainer that spotted the player
# first and waited for a second one, keep theirs - with the amount the engine is about
# to pay and its multiplier facts (Amulet Coin, Happy Hour).
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

    @mode  = :off
    @asked = {}   # nonce => when this connection last sent it (monotonic)
    @rng   = nil

    module_function

    # Sync.reset on (re)connect: every claim goes out again on the new socket, and the
    # mode waits for the server to say it again.
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

    # GameData::Trainer#to_trainer: the data the trainer was built from, and the event
    # running its battle.
    def tag(trainer, type, name, version)
      trainer.pemk_key = [type.to_s, name.to_s, version.to_i]
      event = (pbMapInterpreterRunning? ? pbMapInterpreter.get_self : nil)
      trainer.pemk_event = [$game_map.map_id, event.id] if event && $game_map
    rescue StandardError
      nil
    end

    # Battle#pbGainMoney, before the engine pays: what it is about to add, and for whom.
    def claim(battle)
      return unless active? && battle.trainerBattle? && battle.internalBattle && battle.moneyGain

      opp = Array(battle.opponent)
      return if opp.empty? || opp.any? { |t| !t.respond_to?(:pemk_key) || t.pemk_key.nil? || t.pemk_event.nil? }

      amount = 0
      opp.each_with_index { |t, i| amount += battle.pbMaxLevelInTeam(1, i) * t.base_money }
      amulet = battle.field.effects[PBEffects::AmuletCoin] ? true : false
      happy  = battle.field.effects[PBEffects::HappyHour] ? true : false
      amount *= 2 if amulet
      amount *= 2 if happy
      partner = ($PokemonGlobal.partner rescue nil)
      entry = [new_nonce, opp.map { |t| t.pemk_key + t.pemk_event }, amount, amulet, happy, $game_map.map_id,
               partner ? [partner[0].to_s, partner[1].to_s] : nil]
      claims << entry
      send_claim(entry)
    rescue StandardError => e
      PEMK.log("prize: claim error #{e.class}: #{e.message}")
    end

    def send_claim(entry)
      return unless online?

      (PEMK::Presence.emit_now(:pos) rescue nil)   # judged by where the server last saw the player
      nonce, trainers, amount, amulet, happy, map, partner = entry
      msg = { :type => :money_claim, :nonce => nonce, :trainers => trainers, :amount => amount,
              :amulet => amulet, :happy_hour => happy, :map => map }
      msg[:partner] = partner if partner
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
      list.select! { |e| e.is_a?(Array) && e.length == 7 && e[0].is_a?(Integer) && e[1].is_a?(Array) }
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

EventHandlers.add(:on_frame_update, :pemk_prize_claims, proc { PEMK::PrizeClaim.tick }) if defined?(EventHandlers)
