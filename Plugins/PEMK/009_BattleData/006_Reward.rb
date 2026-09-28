#===============================================================================
# PEMK :: Reward  (client side — M4 Layer D D4, battle reward reporting)
#-------------------------------------------------------------------------------
# When a battle ends, the client reports its outcome and what it fought, so the
# server can open a per-account reward BUDGET window (how much EXP/money that battle
# could legitimately have produced). Subsequent money deltas (the :econ channel) and
# party level jumps (the :mon_party projection) are then checked against that window
# server-side — detection-only, nothing is ever rejected.
#
# Wild foes are captured as they're generated (PEMK::Encounter's pbGenerateWildPokemon
# alias calls note_foe), so we have each foe's personalID — which, for a server-minted
# (D2 `on`) encounter, IS the id the server issued, letting it match the battle to the
# mints it stashed. Trainers are captured as they load (:on_trainer_load): the server
# takes their parties from the battle data export, and only for a trainer whose battle
# starts on the player's map. Fire-and-forget; no reply. Modes off/shadow/on adopted at
# login (shadow and on both just detect in D4; a hard gate is future work).
#===============================================================================
module PEMK
  module Reward
    @mode     = :off
    @foes     = []   # personalIDs of the current battle's wild foes
    @trainers = []   # [type, name, version] of the current battle's trainers

    module_function

    def reset
      @mode     = :off
      @foes     = []
      @trainers = []
    end

    def adopt_mode(v)
      s = v.to_s
      @mode = %w[off shadow on].include?(s) ? s.to_sym : :off
    end

    def mode; @mode; end

    def active?
      return false if @mode == :off
      return false unless PEMK.enabled? && PEMK.self_id

      c = PEMK.client
      !!(c && c.connected?)
    rescue StandardError
      false
    end

    # Called from the wild-generation seam for each foe as it's built.
    def note_foe(pkmn)
      return unless active?
      return if @foes.length >= 2   # engine never fields more than a double wild battle

      pid = (pkmn.personalID rescue nil)
      @foes << pid if pid.is_a?(Integer)
    rescue StandardError
      nil
    end

    def clear_foes
      @foes = []
    end

    # A trainer battle loads each opponent (:on_trainer_load); the server knows their
    # parties from the battle data export, so the name is all it needs.
    def note_trainer(trainer)
      return unless active?
      return if @trainers.length >= 2   # a double battle has two trainers at most

      @trainers << [trainer.trainer_type, trainer.name.to_s, trainer.version.to_i]
    rescue StandardError
      nil
    end

    def clear_trainers
      @trainers = []
    end

    # Report the just-ended battle (outcome 0-5, the wild foes' pids, the trainers).
    # Drains both lists.
    def on_end(outcome)
      foes     = @foes
      trainers = @trainers
      @foes     = []
      @trainers = []
      return unless active? && (foes.any? || trainers.any?) && outcome.is_a?(Integer)

      msg = { :type => :battle_end_report, :outcome => outcome, :foes => foes.map { |p| { :pid => p } } }
      msg[:trainers] = trainers if trainers.any?
      PEMK.send_message(msg)
    rescue StandardError => e
      PEMK.log("reward: report error #{e.class}: #{e.message}")
    end
  end
end

# Wild battle end -> report. :on_end_battle fires for wild battles (PvP uses its own
# checkpoint path and never reaches here). on_end DRAINS the foe list, so foes noted at
# generation (before :on_start_battle) survive to here — do NOT clear on :on_start_battle
# (it fires AFTER generation and would wipe them before the report).
if defined?(EventHandlers)
  EventHandlers.add(:on_end_battle, :pemk_reward_battle_end,
                    proc { |outcome, _can_lose| (PEMK::Reward.on_end(outcome) rescue nil) })
  # A trainer battle fires :on_start_battle BEFORE it loads its trainers (the reverse of
  # a wild battle), so the trainer list is cleared there and filled as each one loads.
  EventHandlers.add(:on_start_battle, :pemk_reward_trainers_reset,
                    proc { (PEMK::Reward.clear_trainers rescue nil) })
  EventHandlers.add(:on_trainer_load, :pemk_reward_trainer,
                    proc { |trainer| (PEMK::Reward.note_trainer(trainer) rescue nil) })
end
