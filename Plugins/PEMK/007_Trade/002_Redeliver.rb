#===============================================================================
# PEMK :: TradeRedeliver  (client side — a traded Pokemon the save never got)
#-------------------------------------------------------------------------------
# The trade's swap is the server's, but the Pokemon itself arrives from the partner's
# client and reaches this player's disk only with the next save. A crash before that
# save, or a result lost with the connection, used to lose it: the server kept no copy.
#
# Now the server holds the escrow until a save that follows this client's
# :trade_applied lands. After a login (once the save is loaded) and after a reconnect,
# the client asks what it is still owed (:trade_owed); each answer is the Pokemon as
# its sender locked it (:trade_redeliver), checked like any peer's (PeerPokemon). One
# whose uid is already in the party or a box is only acknowledged, so a repeat never
# duplicates anything; a missing one is added on the next free overworld frame, and
# the trade's checkpoint saves it.
#
# A reconnect also drops the Pokemon this account traded away (the login's eviction
# list): after a lost result the player would otherwise keep both until the next login.
#===============================================================================
module PEMK
  module TradeRedeliver
    @enabled = false   # the server keeps traded Pokemon (advertised at login)
    @queue   = {}      # uid => [trade_id, Pokemon]
    @evict   = nil     # uids traded away, dropped on the next free frame

    module_function

    def reset
      @enabled = false
      @queue   = {}
      @evict   = nil
    end

    def adopt(v)
      @enabled = (v == true)
    end

    def enabled?
      @enabled == true
    end

    # Once the save is loaded, or after a reconnect: what does the server still owe us?
    def ask_owed
      return unless @enabled && PEMK.self_id

      PEMK.send_message(:type => :trade_owed)
    rescue StandardError => e
      PEMK.log("trade: owed request error #{e.class}: #{e.message}")
    end

    # The traded Pokemon is in the party or a box: the next save that lands holds it.
    def applied(trade_id)
      return unless @enabled && trade_id

      PEMK.send_message(:type => :trade_applied, :trade_id => trade_id.to_s)
    rescue StandardError => e
      PEMK.log("trade: applied report error #{e.class}: #{e.message}")
    end

    def note_evict(list)
      @evict = list if list.is_a?(Array) && !list.empty?
    end

    # Dispatch routes :trade_redeliver here (inside the pump: no UI).
    def on_redeliver(msg)
      uid = msg[:uid]
      return unless uid.is_a?(Integer) && msg[:trade_id].is_a?(String)

      obj = PEMK::PeerPokemon.load(msg[:_body], "traded Pokemon sent again")
      obj = obj[0] if obj.is_a?(Array)
      unless obj.is_a?(Pokemon) && obj.pemk_uid == uid
        PEMK.log("trade: the Pokemon sent again for uid #{uid} does not match -> ignored")
        return
      end
      @queue[uid] = [msg[:trade_id], obj]
    end

    # Each overworld frame: evictions first, then one owed Pokemon.
    def tick
      return unless (@evict || !@queue.empty?) && free_frame?

      if @evict
        list = @evict
        @evict = nil
        PEMK::Monsters.evict(list)
        (PEMK::Sync.mark_mon rescue nil)
      end
      uid, (trade_id, pkmn) = @queue.first
      return unless uid

      @queue.delete(uid)
      if PEMK::Monsters.find_by_uid(uid)
        applied(trade_id)   # the save already had it
        return
      end
      return unless PEMK::Monsters.materialize(pkmn)

      applied(trade_id)
      (PEMK::Sync.mark_mon rescue nil)
      (PEMK::Checkpoint.request(:trade) rescue nil)
      PEMK.log("trade: uid #{uid} from trade #{trade_id} added again")
      pbMessage(_INTL("{1} arrived from a trade that was cut short.", pkmn.name))
    rescue StandardError => e
      PEMK.log("trade: redelivery error #{e.class}: #{e.message}")
    end

    def free_frame?
      $player && $scene.is_a?(Scene_Map) && $game_temp && !$game_temp.in_battle &&
        !$game_temp.in_menu && !$game_temp.message_window_showing &&
        !(pbMapInterpreterRunning? rescue true) && !(PEMK::Trade.busy? rescue false)
    rescue StandardError
      false
    end
  end
end

EventHandlers.add(:on_frame_update, :pemk_trade_redeliver, proc { PEMK::TradeRedeliver.tick }) if defined?(EventHandlers)
