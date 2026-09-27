#===============================================================================
# PEMK :: Autopilot::World  (moving around and setting a scene up)
#-------------------------------------------------------------------------------
#   walk_to X Y       walks there with the arrow keys, one tile at a time, on a path
#                     found with the engine's own passability (tiles, events, ledges
#                     as the player sees them); re-plans when an NPC steps in the way
#                     and stops as soon as a battle, message, menu, event or map
#                     transfer interrupts it, saying which
#   face DIR          down / left / right / up
#   interact          taps USE at whatever is in front
#   talk_to EVENT     walks next to the event (or across a counter from it), faces it
#                     and taps USE; answers with the message that opened, if any
#   events            the current map's events: id, name, position, trigger
#   warp MAP X Y      the debug menu's warp
# Debug setters, for arranging a test quickly. They go through the engine's normal
# setters, so the PEMK sync and interception see them like any other change:
#   set_switch ID on|off   set_var ID VALUE   set_selfswitch MAP EVENT LETTER on|off
#   add_item ITEM [QTY]    add_pokemon SPECIES LEVEL    heal    money AMOUNT
# Readers: get_switch ID, get_var ID, get_selfswitch MAP EVENT LETTER. And save.
#===============================================================================
module PEMK
  module Autopilot
    module World
      STEP = { 2 => [0, 1], 4 => [-1, 0], 6 => [1, 0], 8 => [0, -1] }.freeze
      KEY  = { 2 => "DOWN", 4 => "LEFT", 6 => "RIGHT", 8 => "UP" }.freeze
      TURN = { 2 => :turn_down, 4 => :turn_left, 6 => :turn_right, 8 => :turn_up }.freeze
      DIR_NAMES = { "down" => 2, "left" => 4, "right" => 6, "up" => 8 }.freeze
      MAX_NODES = 6000

      module_function

      def on_map?
        $scene.is_a?(Scene_Map) && $game_map && $game_player
      end

      # Breadth-first over the map with Game_Player#passable?. -> [dir, ...] or nil.
      def path_to(tx, ty)
        start = [$game_player.x, $game_player.y]
        return [] if start == [tx, ty]

        prev  = { start => nil }
        queue = [start]
        until queue.empty?
          x, y = queue.shift
          STEP.each do |d, (dx, dy)|
            nxt = [x + dx, y + dy]
            next if prev.key?(nxt) || !$game_map.valid?(*nxt)
            next unless $game_player.passable?(x, y, d)

            prev[nxt] = [x, y, d]
            return unwind(prev, nxt) if nxt == [tx, ty]
            return nil if prev.size > MAX_NODES

            queue << nxt
          end
        end
        nil
      end

      def unwind(prev, tile)
        dirs = []
        while (p = prev[tile])
          dirs.unshift(p[2])
          tile = [p[0], p[1]]
        end
        dirs
      end

      # What stops a walk: the game started doing something else.
      def interruption
        return "battle"   if $game_temp.in_battle
        return "transfer" if $game_temp.player_transferring
        return "message"  if Observe.current_message
        return "menu"     unless Observe.menus.empty?
        return "screen"   unless Observe.screens.empty?
        return "text"     if TextEntry.awaiting
        return "item"     if ItemChoice.awaiting
        return "event"    if (pbMapInterpreterRunning? rescue false)

        nil
      end

      def at
        [$game_player.x, $game_player.y]
      end

      # One tile per held arrow: the key goes down, comes up as soon as the step has
      # started (the position changes at the start of a step), and the next one waits
      # for the step to finish.
      class Walker
        STEP_TIMEOUT = 0.8   # seconds an arrow may be held without a step starting
        MAX_REPLANS  = 3

        attr_reader :status, :detail, :steps

        def initialize(tx, ty)
          @target  = [tx, ty]
          @path    = nil
          @key     = nil
          @steps   = 0
          @replans = 0
          @status  = :walking
        end

        # One frame. -> true once finished: :arrived, :interrupted, :blocked, :no_path
        # An interruption wins over everything, even mid-step: the agent is told as
        # soon as the game starts doing something else.
        def step
          if (why = World.interruption)
            return finish(:interrupted, why)
          end
          return holding if @key
          return false if $game_player.moving?
          return finish(:arrived, nil) if World.at == @target

          @path = World.path_to(*@target) if @path.nil? || @path.empty?
          return finish(:no_path, "no path from #{World.at.join(',')}") if @path.nil?

          d = @path.shift
          return replan("the next tile closed") unless $game_player.passable?(*World.at, d)

          @key    = VInput.key(KEY[d])
          @origin = World.at
          @since  = Autopilot.now
          VInput.hold(@key, nil)
          false
        end

        def holding
          if World.at != @origin
            VInput.release(@key)
            @key = nil
            @steps += 1
          elsif Autopilot.now - @since > STEP_TIMEOUT
            VInput.release(@key)
            @key = nil
            return replan("blocked at #{World.at.join(',')}")
          end
          false
        end

        def replan(why)
          @path = nil
          @replans += 1
          return false if @replans <= MAX_REPLANS

          finish(:blocked, why)
        end

        def finish(status, detail)
          VInput.release(@key) if @key
          @key    = nil
          @status = status
          @detail = detail
          true
        end
      end

      def walk_budget(tx, ty)
        x, y = at
        [0.6 * ((tx - x).abs + (ty - y).abs) + 5, 120].min
      end

      def walk_result(walker)
        { "ok" => walker.status == :arrived, "status" => walker.status.to_s,
          "detail" => walker.detail, "steps" => walker.steps, "at" => at }
      end

      def cmd_walk_to(id, rest)
        tx, ty = rest.split.map { |v| Integer(v, exception: false) }
        return Autopilot.respond(id, "ok" => false, "error" => "walk_to X Y") unless tx && ty
        return Autopilot.respond(id, "ok" => false, "error" => "not on a map") unless on_map?

        # A door or an NPC stands on its tile: nobody walks onto it, you bump into it.
        blocker = $game_map.events.values.find { |e| e.x == tx && e.y == ty && !e.through }
        if blocker && at != [tx, ty]
          return Autopilot.respond(id, "ok" => false, "status" => "no_path",
                                       "detail" => "event #{blocker.id} (#{blocker.name}) stands there: " \
                                                   "use talk_to/enter #{blocker.id}")
        end

        walker = Walker.new(tx, ty)
        Autopilot.start_job(id, walk_budget(tx, ty)) do
          next false unless walker.step

          Autopilot.respond(id, walk_result(walker))
        end
      end

      def cmd_face(id, rest)
        d = DIR_NAMES[rest.strip.downcase] || rest.to_i
        return Autopilot.respond(id, "ok" => false, "error" => "face down|left|right|up") unless TURN[d]

        $game_player.send(TURN[d])
        Autopilot.respond(id, "ok" => true, "dir" => d)
      end

      # Taps USE and reports what it opened (a message, an event) within a second.
      def interact_job(id, extra = {})
        VInput.tap(VInput.key("USE"))
        since = Autopilot.now
        Autopilot.start_job(id) do
          started = Observe.current_message || !Observe.menus.empty? || $game_temp.in_battle
          next false unless started || Autopilot.now - since > 1.0

          Autopilot.respond(id, { "ok" => true, "message" => Observe.current_message,
                                  "menus" => Observe.menus, "battle" => $game_temp.in_battle ? true : false }.merge(extra))
        end
      end

      def cmd_interact(id)
        return Autopilot.respond(id, "ok" => false, "error" => "not on a map") unless on_map?

        interact_job(id)
      end

      # Where to stand to talk to an event: next to it, or else two tiles away across a
      # counter (the nurse, shop clerks). -> [[x, y, facing, path], ...] best first:
      # any reachable adjacent tile beats a counter spot, then the shorter walk wins.
      def talk_spots(ev)
        spots = []
        STEP.each do |d, (dx, dy)|
          facing = { 2 => 8, 8 => 2, 4 => 6, 6 => 4 }[d]
          spots << [ev.x + dx, ev.y + dy, facing, 0]
          spots << [ev.x + (2 * dx), ev.y + (2 * dy), facing, 1]
        end
        spots.select { |x, y, _, _| $game_map.valid?(x, y) }
             .map { |x, y, f, tier| [x, y, f, (at == [x, y] ? [] : path_to(x, y)), tier] }
             .reject { |s| s[3].nil? }
             .sort_by { |s| [s[4], s[3].length] }
      end

      # Events that start when walked into (doors, warp tiles) rather than on USE.
      def touch_trigger?(ev)
        [1, 2].include?(ev.trigger)
      end

      # Holds the arrow into a touch event until it starts - and lets go at once, so the
      # player does not keep walking on the far side of a door.
      def bump_job(id, dir, extra = {})
        key = VInput.key(KEY[dir])
        VInput.hold(key, nil)
        since = Autopilot.now
        Autopilot.start_job(id) do
          why = interruption
          next false unless why || Autopilot.now - since > 1.0

          VInput.release(key)
          Autopilot.respond(id, { "ok" => !why.nil?, "started" => why, "message" => Observe.current_message }.merge(extra))
        end
      end

      # talk_to / enter EVENT: walk next to it, then USE (NPCs, signs) or bump (doors).
      def cmd_talk_to(id, rest)
        return Autopilot.respond(id, "ok" => false, "error" => "not on a map") unless on_map?

        ev = $game_map.events[rest.to_i]
        return Autopilot.respond(id, "ok" => false, "error" => "no event #{rest.strip} on this map") unless ev

        spot = talk_spots(ev).first
        return Autopilot.respond(id, "ok" => false, "error" => "no reachable spot next to event #{ev.id}") unless spot

        walker = Walker.new(spot[0], spot[1])
        Autopilot.start_job(id, walk_budget(spot[0], spot[1])) do
          next false unless walker.step
          next Autopilot.respond(id, walk_result(walker).merge("event" => ev.id)) unless walker.status == :arrived

          $game_player.send(TURN[spot[2]])
          if touch_trigger?(ev)
            bump_job(id, spot[2], "event" => ev.id)   # replaces this job
          else
            interact_job(id, "event" => ev.id)
          end
          false
        end
      end

      def cmd_events(id)
        return Autopilot.respond(id, "ok" => false, "error" => "not on a map") unless on_map?

        list = $game_map.events.values.sort_by(&:id).map do |e|
          { "id" => e.id, "name" => e.name.to_s, "x" => e.x, "y" => e.y,
            "trigger" => (e.trigger rescue nil), "visible" => !e.character_name.to_s.empty? }
        end
        Autopilot.respond(id, "ok" => true, "map" => $game_map.map_id, "events" => list)
      end

      # event_pages EVENT - an event's pages as the editor stores them: the conditions
      # that pick the live page and the command list (code, indent, parameters), so
      # the agent can read what an NPC waits for instead of guessing.
      def cmd_event_pages(id, rest)
        return Autopilot.respond(id, "ok" => false, "error" => "not on a map") unless on_map?

        ev = $game_map.events[rest.to_i]
        return Autopilot.respond(id, "ok" => false, "error" => "no event #{rest.strip} on this map") unless ev

        rpg = ev.instance_variable_get(:@event)
        pages = rpg.pages.each_with_index.map do |page, i|
          c = page.condition
          { "page" => i + 1, "trigger" => page.trigger,
            "condition" => { "switch1" => (c.switch1_valid ? c.switch1_id : nil),
                             "switch2" => (c.switch2_valid ? c.switch2_id : nil),
                             "variable" => (c.variable_valid ? [c.variable_id, c.variable_value] : nil),
                             "self_switch" => (c.self_switch_valid ? c.self_switch_ch : nil) },
            "commands" => page.list.map { |cmd| [cmd.code, cmd.indent, plain(cmd.parameters)] } }
        end
        Autopilot.respond(id, "ok" => true, "event" => ev.id, "name" => ev.name.to_s, "pages" => pages)
      end

      # Parameters flattened to JSON-safe values (RPG objects become their class name).
      def plain(value)
        case value
        when Array then value.map { |v| plain(v) }
        when String, Integer, Float, true, false, nil then value
        when Symbol then value.to_s
        else value.class.name
        end
      end

      def cmd_warp(id, rest)
        map, x, y = rest.split.map { |v| Integer(v, exception: false) }
        return Autopilot.respond(id, "ok" => false, "error" => "warp MAP X Y") unless map && x && y
        return Autopilot.respond(id, "ok" => false, "error" => "not on a map") unless on_map?

        $game_temp.player_new_map_id    = map
        $game_temp.player_new_x         = x
        $game_temp.player_new_y         = y
        $game_temp.player_new_direction = 2
        $scene.transfer_player
        Autopilot.respond(id, "ok" => true, "map" => $game_map.map_id, "at" => at)
      end

      # --- debug setters --------------------------------------------------------

      def on?(word)
        %w[on true 1 yes].include?(word.to_s.downcase)
      end

      def refresh_map
        $game_map.need_refresh = true if $game_map
      end

      def cmd_setter(id, name, rest)
        a = rest.split
        result =
          case name
          when "set_switch"
            $game_switches[a[0].to_i] = on?(a[1])
            refresh_map
            { "switch" => a[0].to_i, "value" => $game_switches[a[0].to_i] }
          when "set_var"
            $game_variables[a[0].to_i] = a[1].to_i
            refresh_map
            { "variable" => a[0].to_i, "value" => $game_variables[a[0].to_i] }
          when "set_selfswitch"
            key = [a[0].to_i, a[1].to_i, a[2].to_s.upcase]
            $game_self_switches[key] = on?(a[3])
            refresh_map
            { "self_switch" => key.join(":"), "value" => $game_self_switches[key] }
          when "add_item"
            item = a[0].to_s.upcase.to_sym
            { "item" => item.to_s, "added" => $bag.add(item, [a[1].to_i, 1].max) ? true : false }
          when "add_pokemon"
            ok = pbAddPokemonSilent(a[0].to_s.upcase.to_sym, [a[1].to_i, 1].max)
            { "species" => a[0].to_s.upcase, "added" => ok ? true : false }
          when "heal"
            $player.heal_party
            { "healed" => true }
          when "money"
            $player.money = a[0].to_i
            { "money" => $player.money }
          when "get_switch"
            { "switch" => a[0].to_i, "value" => $game_switches[a[0].to_i] ? true : false }
          when "get_var"
            { "variable" => a[0].to_i, "value" => $game_variables[a[0].to_i] }
          when "get_selfswitch"
            key = [a[0].to_i, a[1].to_i, a[2].to_s.upcase]
            { "self_switch" => key.join(":"), "value" => $game_self_switches[key] ? true : false }
          end
        Autopilot.respond(id, { "ok" => true }.merge(result))
      end

      Autopilot.verb("walk_to")  { |id, rest| cmd_walk_to(id, rest) }
      Autopilot.verb("face")     { |id, rest| cmd_face(id, rest) }
      Autopilot.verb("interact") { |id, _| cmd_interact(id) }
      Autopilot.verb("talk_to")  { |id, rest| cmd_talk_to(id, rest) }
      Autopilot.verb("enter")    { |id, rest| cmd_talk_to(id, rest) }
      Autopilot.verb("events")   { |id, _| cmd_events(id) }
      Autopilot.verb("event_pages") { |id, rest| cmd_event_pages(id, rest) }
      Autopilot.verb("warp")     { |id, rest| cmd_warp(id, rest) }
      %w[set_switch set_var set_selfswitch add_item add_pokemon heal money
         get_switch get_var get_selfswitch].each do |name|
        Autopilot.verb(name) do |id, rest|
          next Autopilot.respond(id, "ok" => false, "error" => "no game loaded yet") unless $player

          cmd_setter(id, name, rest)
        end
      end

      # save - a manual save (the pause menu's), so a test can put a known state on
      # disk and on the server. Only from an idle overworld, like a player's save.
      def cmd_save(id)
        return Autopilot.respond(id, "ok" => false, "error" => "not idle") unless Actions.idle?

        ok = Game.save
        Autopilot.respond(id, "ok" => ok ? true : false)
      end

      Autopilot.verb("save") { |id, _| cmd_save(id) }
    end
  end
end
