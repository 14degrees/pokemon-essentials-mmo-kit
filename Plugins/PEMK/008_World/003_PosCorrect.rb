#===============================================================================
# PEMK :: PosCorrect  (client side — M4 Layer B snap-back)
#-------------------------------------------------------------------------------
# Applies a server-authoritative position correction (:pos_correct) when the
# server's position audit (enforcement mode :on) rejects a move: the player is
# snapped back to the last-good tile the server holds. Same-map -> moveto (instant,
# recentred, no fade); cross-map -> a Transfer. The apply is DEFERRED to a safe
# overworld frame (never mid-battle / menu / transfer), mirroring the NetStatus /
# Checkpoint gate.
#
# A swimmer sent back stays one: dismounted on water it could neither step off (water
# is a wall on foot) nor surf again (Surf and Dive start from the tile it stands on),
# and a diver could never come up.
#
# Enforcement is OPT-IN server-side (PEMK_POS_ENFORCE=on); in the default :off /
# :shadow modes the server never sends :pos_correct, so this stays dormant.
#===============================================================================
module PEMK
  module PosCorrect
    @pending    = nil   # [map, x, y] awaiting a safe frame
    @swim_after = nil   # [map, :surf | :dive] once a cross-map snap-back has landed

    module_function

    # From Dispatch on an inbound :pos_correct. Store; apply on the next safe frame.
    # A newer correction supersedes an unapplied older one (converge on the latest).
    def request(map, x, y)
      return unless map.is_a?(Integer) && x.is_a?(Integer) && y.is_a?(Integer)

      @pending = [map, x, y]
    end

    def reset
      @pending    = nil
      @swim_after = nil
    end

    def tick
      swim_again if @swim_after
      return unless @pending
      return unless safe?

      map, x, y = @pending
      @pending = nil
      apply(map, x, y)
    rescue => e
      PEMK.log("poscorrect: tick error #{e.class}: #{e.message}")
    end

    # Only reposition in the overworld with nothing else in flight.
    def safe?
      $scene.is_a?(Scene_Map) && $game_temp && $game_map && $game_player &&
        !$game_temp.in_battle && !$game_temp.in_menu &&
        !$game_temp.player_transferring && !$game_temp.transition_processing
    rescue
      false
    end

    def apply(map, x, y)
      swim = swim_for(map, x, y)
      if $game_map.map_id == map
        (pbCancelVehicles(map, swim.nil?) rescue nil)   # off the bike where it cannot ride
        swim_as(swim)
        $game_player.moveto(x, y)     # same map: instant + recentred (Game_Player#moveto)
      else
        $game_temp.player_new_map_id    = map
        $game_temp.player_new_x         = x
        $game_temp.player_new_y         = y
        $game_temp.player_new_direction = $game_player.direction   # keep facing
        $game_temp.player_transferring  = true                     # Scene_Map completes it
        @swim_after = swim && [map, swim]   # ... on foot: a swimmer swims again once there
      end
      PEMK.log("poscorrect: snapped to #{map}(#{x},#{y})#{swim ? " (#{swim})" : ''}")
    rescue => e
      PEMK.log("poscorrect: apply error #{e.class}: #{e.message}")
    end

    # How the player moves on the tile it is sent back to: diving on a map below (one
    # some map's DiveMap names), surfing if it swims now and the tile is water, else on
    # foot.
    def swim_for(map, x, y)
      return :dive if underwater?(map)
      return nil unless $PokemonGlobal && ($PokemonGlobal.surfing || $PokemonGlobal.diving)

      tag = ($map_factory.getTerrainTag(map, x, y) rescue nil)
      tag && tag.can_surf ? :surf : nil
    end

    def underwater?(map)
      found = false
      GameData::MapMetadata.each { |md| found ||= md.dive_map_id == map }
      found
    rescue
      false
    end

    def swim_as(swim)
      return unless swim

      $PokemonGlobal.surfing = (swim == :surf)
      $PokemonGlobal.diving  = (swim == :dive)
      (pbUpdateVehicle rescue nil)
    end

    # Scene_Map#transfer_player dismounts: once the snap-back has landed, swim again.
    def swim_again
      return unless safe?

      map, swim = @swim_after
      @swim_after = nil
      swim_as(swim) if $game_map.map_id == map
    end
  end
end

EventHandlers.add(:on_frame_update, :pemk_pos_correct,
  proc { PEMK::PosCorrect.tick })
