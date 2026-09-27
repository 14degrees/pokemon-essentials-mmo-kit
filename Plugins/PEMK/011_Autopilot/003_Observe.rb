#===============================================================================
# PEMK :: Autopilot::Observe  (what the agent sees)
#-------------------------------------------------------------------------------
# A JSON-ready snapshot read straight from the game objects: scene, map, player,
# the message on screen, open command menus (choices and the highlighted index),
# the party, and whether the MMO layer is online. The agent reasons over this;
# screenshots are for evidence and for what the snapshot does not cover.
#
# The message and the menus are captured where the engine creates them
# (pbMessageDisplay, Window_DrawableCommand), which every message box and every
# command list in Essentials goes through.
#===============================================================================
module PEMK
  module Autopilot
    module Observe
      MAX_WINDOWS = 16
      MAX_LOG     = 40

      @messages = []   # texts on screen, innermost last (a choice can open over a message)
      @windows  = []   # command windows, newest last; disposed ones are pruned
      @log      = []   # recent messages, overworld and battle, oldest first

      module_function

      def push_message(text)
        t = clean(text)
        @messages.push(t)
        note(t, "message")
      end

      # Every message that went by, so a line that closed on its own is not lost.
      def note(text, source)
        t = clean(text)
        return if t.empty?

        @log.push({ "frame" => PEMK::Autopilot.frame, "source" => source, "text" => t })
        @log.shift while @log.size > MAX_LOG
      end

      def log
        @log
      end

      def pop_message
        @messages.pop
      end

      def track_window(window)
        @windows.reject! { |w| gone?(w) }
        @windows.push(window)
        @windows.shift while @windows.size > MAX_WINDOWS
      end

      def snapshot
        s = { "frame" => PEMK::Autopilot.frame, "scene" => ($scene ? $scene.class.name : nil),
              "instance" => PEMK.instance, "online" => online, "flags" => temp_flags,
              "message" => @messages.last, "menus" => menus, "held" => VInput.held_names }
        s["map"]     = map_info if $game_map
        s["player"]  = player_info if $game_player
        s["trainer"] = trainer_info if $player
        s["party"]   = party_info if $player
        s["battle"]  = BattleControl.snapshot if defined?(BattleControl) && BattleControl.attached?
        s["log"]     = @log.last(12)
        s
      end

      def online
        c = PEMK.client
        { "logged_in"  => (PEMK::Auth.logged_in? rescue false),
          "account_id" => (PEMK::Auth.account_id rescue nil),
          "connected"  => (c ? (c.connected? rescue false) : false) }
      end

      def temp_flags
        gt = $game_temp
        return {} unless gt

        { "in_menu"      => gt.in_menu ? true : false,
          "in_battle"    => gt.in_battle ? true : false,
          "message"      => gt.message_window_showing ? true : false,
          "transferring" => gt.player_transferring ? true : false,
          "event"        => ($game_map ? (pbMapInterpreterRunning? rescue false) : false) }
      end

      def current_message
        @messages.last
      end

      # Visible, active command lists, newest last: what a key press would act on.
      def active_windows
        @windows.reject! { |w| gone?(w) }
        @windows.select { |w| w.visible && w.active }
      rescue StandardError
        []
      end

      def menus
        active_windows.map do |w|
          cmds = w.respond_to?(:commands) ? Array(w.commands).map { |c| clean(c) } : nil
          { "class" => w.class.name, "commands" => cmds, "index" => w.index }
        end
      rescue StandardError
        []
      end

      def map_info
        { "id" => $game_map.map_id, "name" => clean($game_map.name) }
      rescue StandardError
        { "id" => ($game_map.map_id rescue nil) }
      end

      def player_info
        { "x" => $game_player.x, "y" => $game_player.y, "dir" => $game_player.direction,
          "moving" => $game_player.moving? ? true : false }
      end

      def trainer_info
        { "name" => $player.name, "money" => $player.money,
          "badges" => ($player.badge_count rescue nil) }
      end

      def party_info
        $player.party.map do |p|
          { "species" => p.species.to_s, "level" => p.level, "hp" => p.hp,
            "total_hp" => p.totalhp, "fainted" => p.fainted? ? true : false }
        end
      rescue StandardError
        []
      end

      def gone?(window)
        window.disposed?
      rescue StandardError
        true
      end

      # Message text without the engine's formatting codes (\c[1], \se[...], <b>...).
      def clean(text)
        t = text.to_s.dup
        t.gsub!(/\\pn/i) { $player ? $player.name.to_s : "" }
        t.gsub!(/\\n/i, " ")
        t.gsub!(/\\[a-z]+\[[^\]]*\]/i, "")
        t.gsub!(/\\[a-z.|^!]+/i, "")
        t.gsub!(/<[^>]*>/, "")
        t.gsub!(/[\x00-\x1f]/, " ")
        t.squeeze(" ").strip
      end
    end
  end
end

if PEMK::Autopilot.active?
  # Every message box goes through here; nested ones (a choice list over its prompt)
  # stack, and the ensure keeps the stack honest when a box is closed by a raise.
  if defined?(pbMessageDisplay) && !defined?(pemk_ap_orig_pbMessageDisplay)
    alias pemk_ap_orig_pbMessageDisplay pbMessageDisplay
    def pbMessageDisplay(msgwindow, message, letterbyletter = true, commandProc = nil, &block)
      PEMK::Autopilot::Observe.push_message(message)
      begin
        pemk_ap_orig_pbMessageDisplay(msgwindow, message, letterbyletter, commandProc, &block)
      ensure
        PEMK::Autopilot::Observe.pop_message
      end
    end
  end

  # Every command list (pause menu, choices, debug menu...) is a Window_DrawableCommand.
  class Window_DrawableCommand
    unless method_defined?(:pemk_ap_orig_initialize) || private_method_defined?(:pemk_ap_orig_initialize)
      alias_method :pemk_ap_orig_initialize, :initialize
      def initialize(*args, &block)
        pemk_ap_orig_initialize(*args, &block)
        PEMK::Autopilot::Observe.track_window(self)
      end
    end
  end
end
