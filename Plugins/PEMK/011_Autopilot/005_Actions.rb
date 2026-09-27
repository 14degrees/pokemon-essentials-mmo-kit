#===============================================================================
# PEMK :: Autopilot::Actions  (verbs that act on what the agent sees)
#-------------------------------------------------------------------------------
#   wait_until COND[|COND...] [ARG] [within SECONDS]
#       idle, battle, no_battle, decision, message, no_message, menu, no_menu,
#       menu_with TEXT, map ID, scene NAME. Answers with the condition that matched.
#       "decision|no_battle" is the usual way to wait out a battle turn.
#   choose LABEL|INDEX
#       picks an entry of the newest open menu by its text (or index) and confirms
#       it, through the menu's own cursor and the USE key.
#   dismiss [MAX]
#       taps USE until no message is left (chained lines included), and stops early
#       when a choice list opens so the agent can pick.
#   advance on|off
#       windows that only wait for a key (level-up stats...) close on their own;
#       always on while a battle is played by the agent or the auto policy.
#   fast on|off
#       instant text, no battle animations, no nickname or switch prompts - for the
#       test window's own options; "off" puts the previous ones back.
#===============================================================================
module PEMK
  module Autopilot
    module Actions
      FAST_OPTIONS = { textspeed: 3, battlescene: 1, battlestyle: 1, givenicknames: 1, sendtoboxes: 1 }.freeze
      # In seconds, because the message box runs on the clock: it ignores USE while it
      # slides in, and a chained line opens a moment after the previous one closes.
      TAP_GAP = 0.12   # between two taps
      QUIET   = 0.25   # no message for this long = the chain of lines is over

      @saved_options = nil
      @advance       = false

      module_function

      def advance?
        @advance || BattleControl.mode != :keys
      end

      # --- conditions ---------------------------------------------------------

      def idle?
        gt = $game_temp
        return false unless $scene.is_a?(Scene_Map) && gt && $game_player

        !(gt.in_menu || gt.in_battle || gt.message_window_showing || gt.player_transferring ||
          $game_player.moving? || (pbMapInterpreterRunning? rescue false) || !Observe.menus.empty?)
      end

      def condition(name, arg)
        case name
        when "idle"       then idle?
        when "battle"     then BattleControl.attached?
        when "no_battle"  then !BattleControl.attached?
        when "decision"   then !BattleControl.awaiting.nil?
        when "message"    then !Observe.current_message.nil?
        when "no_message" then Observe.current_message.nil?
        when "menu"       then !Observe.menus.empty?
        when "no_menu"    then Observe.menus.empty?
        when "menu_with"  then menu_with?(arg)
        when "map"        then $game_map && $game_map.map_id == arg.to_i
        when "scene"      then $scene && $scene.class.name == arg.to_s
        end
      end

      def menu_with?(text)
        want = text.to_s.downcase
        Observe.menus.any? { |m| Array(m["commands"]).any? { |c| c.to_s.downcase.start_with?(want) } }
      end

      TAKES_ARG = %w[map scene menu_with].freeze
      KNOWN     = %w[idle battle no_battle decision message no_message menu no_menu menu_with map scene].freeze

      def cmd_wait_until(id, rest)
        words  = rest.split
        limit  = JOB_SECONDS
        if (i = words.index("within"))
          limit = words[i + 1].to_f.clamp(0.1, 3600.0)
          words.slice!(i, 2)
        end
        conds = words[0].to_s.split("|")
        arg   = words[1..].join(" ")
        unknown = conds.reject { |c| KNOWN.include?(c) }
        unless !conds.empty? && unknown.empty?
          return Autopilot.respond(id, "ok" => false, "error" => "unknown condition #{unknown.first.inspect}; " \
                                                                  "one of #{KNOWN.join(', ')}")
        end

        start = Autopilot.frame
        Autopilot.start_job(id, limit) do
          hit = conds.find { |c| condition(c, TAKES_ARG.include?(c) ? arg : nil) }
          next false unless hit

          Autopilot.respond(id, "ok" => true, "matched" => hit, "waited" => Autopilot.frame - start)
        end
      end

      # --- menus ----------------------------------------------------------------

      def cmd_choose(id, rest)
        wanted = rest.strip
        window = Observe.active_windows.last
        return Autopilot.respond(id, "ok" => false, "error" => "no menu is open") unless window

        labels = window.respond_to?(:commands) ? Array(window.commands).map { |c| Observe.clean(c) } : []
        index  = if wanted.match?(/\A\d+\z/) then wanted.to_i
                 else labels.index { |l| l.casecmp?(wanted) } ||
                      labels.index { |l| l.downcase.start_with?(wanted.downcase) }
                 end
        unless index && index < [labels.length, 1].max
          return Autopilot.respond(id, "ok" => false, "error" => "no entry #{wanted.inspect}", "commands" => labels)
        end

        window.index = index
        use = VInput.key("USE")
        VInput.hold(use, 2)
        settled = nil
        Autopilot.start_job(id) do
          next false if VInput.down?(use)

          settled ||= Autopilot.frame
          next false if Autopilot.frame == settled

          Autopilot.respond(id, "ok" => true, "chose" => labels[index] || index)
        end
      end

      # --- messages -------------------------------------------------------------

      def cmd_dismiss(id, rest)
        max       = rest.to_i.positive? ? rest.to_i : 20
        use       = VInput.key("USE")
        presses   = 0
        last_tap  = nil
        quiet_at  = nil
        Autopilot.start_job(id) do
          next false if VInput.down?(use)

          unless Observe.menus.empty?
            next Autopilot.respond(id, "ok" => true, "presses" => presses, "stopped" => "menu",
                                       "message" => Observe.current_message, "menus" => Observe.menus)
          end
          if Observe.current_message.nil?
            quiet_at ||= Autopilot.now
            next false if Autopilot.now - quiet_at < QUIET

            next Autopilot.respond(id, "ok" => true, "presses" => presses)
          end
          quiet_at = nil
          next false if last_tap && Autopilot.now - last_tap < TAP_GAP
          if presses >= max
            next Autopilot.respond(id, "ok" => false, "error" => "message still open after #{max} presses",
                                       "message" => Observe.current_message)
          end
          VInput.hold(use, 2)
          presses += 1
          last_tap = Autopilot.now
          false
        end
      end

      def cmd_advance(id, rest)
        @advance = rest.strip != "off"
        Autopilot.respond(id, "ok" => true, "advance" => @advance)
      end

      # --- speed ----------------------------------------------------------------

      def cmd_fast(id, rest)
        sys = $PokemonSystem
        return Autopilot.respond(id, "ok" => false, "error" => "no game loaded yet") unless sys

        if rest.strip == "off"
          (@saved_options || {}).each { |k, v| sys.send("#{k}=", v) }
          @saved_options = nil
        else
          @saved_options ||= FAST_OPTIONS.keys.to_h { |k| [k, sys.send(k)] }
          FAST_OPTIONS.each { |k, v| sys.send("#{k}=", v) }
        end
        (MessageConfig.pbSetTextSpeed(MessageConfig.pbSettingToTextSpeed(sys.textspeed)) rescue nil)
        Autopilot.respond(id, "ok" => true, "fast" => !@saved_options.nil?)
      end

      Autopilot.verb("wait_until") { |id, rest| cmd_wait_until(id, rest) }
      Autopilot.verb("choose")     { |id, rest| cmd_choose(id, rest) }
      Autopilot.verb("dismiss")    { |id, rest| cmd_dismiss(id, rest) }
      Autopilot.verb("advance")    { |id, rest| cmd_advance(id, rest) }
      Autopilot.verb("fast")       { |id, rest| cmd_fast(id, rest) }
    end
  end
end

if PEMK::Autopilot.active?
  # Windows that only wait for USE (level-up stats in battle, rare candies...). Their
  # text goes to the log either way; with nobody at the keys they close at once.
  if defined?(pbTopRightWindow) && !defined?(pemk_ap_orig_pbTopRightWindow)
    alias pemk_ap_orig_pbTopRightWindow pbTopRightWindow
    def pbTopRightWindow(text, scene = nil)
      PEMK::Autopilot::Observe.note(text, "window")
      PEMK::Autopilot::VInput.tap(PEMK::Autopilot::VInput.key("USE")) if PEMK::Autopilot::Actions.advance?
      pemk_ap_orig_pbTopRightWindow(text, scene)
    end
  end
end
