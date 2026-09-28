#===============================================================================
# PEMK :: Flags  (client side — the switches/variables/self-switches projection)
#-------------------------------------------------------------------------------
# The north-star gap the audit named: RPG-Maker switches, variables and self-
# switches — quest progression, story flags and every one-shot event marker —
# had NO server representation at all. They lived only inside the opaque save
# blob, so the server could not even SEE that a player rewound their story; and
# rewinding a self-switch re-arms every NPC gift, TM, HM and key-item event.
#
# This projects the NON-DEFAULT set (a switch is false and a variable 0 by
# default), so a real save is a few hundred ids rather than 10,000 slots. It is
# a DETECTION shadow — the server records it and flags a rewind, it does not
# correct anything. Making the server authoritative here needs the world-vs-
# player ID partition, which is a game-design decision.
#
# Reads the ivars directly (the engine classes are plain @data wrappers) so no
# engine file is touched and no accessor is added to core.
#===============================================================================
module PEMK
  module Flags
    MAX_ENTRIES = 4000   # mirrors the server cap; beyond it the snapshot isn't judged

    @mode = :off
    # The tier table, pushed by the server at login (it owns the build-time manifest,
    # so both sides provably agree). Only NON-LOCAL ids travel — everything absent is
    # local, which is the pre-sovereignty behaviour, so a missing policy makes the
    # whole layer inert rather than wrong.
    @tiers = { :switches => {}, :variables => {} }

    module_function

    def reset
      @mode = :off
      @tiers = { :switches => {}, :variables => {} }
      @repair = nil   # a repair from a dead session must not land in the next one
      (PEMK::Flags::Delta.reset rescue nil)
    end

    # policy: { "switches" => {"4"=>"fact", ...}, "variables" => {"7"=>"mirror"} }
    def adopt_policy(policy)
      t = { :switches => {}, :variables => {} }
      if policy.is_a?(Hash)
        %w[switches variables].each do |kind|
          sec = policy[kind]
          next unless sec.is_a?(Hash)

          sec.each { |id, tier| t[kind.to_sym][id.to_i] = tier.to_s if id.to_i.positive? }
        end
      end
      @tiers = t
      PEMK.log("flags: adopted policy (#{t[:switches].size} switches, #{t[:variables].size} variables)")
    end

    # Is this id the server's business? Absent => local => never recorded, never sent.
    def owned?(kind, id)
      return false unless active? && id.is_a?(Integer)

      !@tiers[kind].nil? && !@tiers[kind][id].nil?
    end

    def tier(kind, id)
      (@tiers[kind] || {})[id] || "local"
    end

    def adopt_mode(v)
      s = v.to_s
      @mode = %w[off shadow on].include?(s) ? s.to_sym : :off
    end

    def mode; @mode; end
    def active?; @mode != :off; end

    # -> { :switches => [id,...], :variables => {id_string => int}, :self_switches => ["m:e:A",...] }
    # nil when the game state isn't loaded yet (never send a half-built snapshot).
    def projection
      return nil unless $game_switches && $game_variables && $game_self_switches

      { :switches      => on_switches,
        :variables     => set_variables,
        :self_switches => on_self_switches,
        :event_times   => event_times }
    rescue => e
      PEMK.log("flags: projection error: #{e.class}: #{e.message}")
      nil
    end

    # $PokemonGlobal.eventvars: per-event state keyed [map_id, event_id]. pbSetEventTime
    # parks a unix timestamp there and sets the event's self-switch A - the berry plant /
    # daily respawn pair. Only the Integer entries are projected; setVariable can park
    # anything at all in here, and the server keeps only the events its manifest already
    # classified as repeatable.
    def event_times
      vars = ($PokemonGlobal && $PokemonGlobal.eventvars) rescue nil
      return {} unless vars.is_a?(Hash)

      out = {}
      vars.each do |k, v|
        next unless v.is_a?(Integer) && k.is_a?(Array) && k.length >= 2

        out["#{k[0]}:#{k[1]}"] = v
        break if out.size >= MAX_ENTRIES
      end
      out
    end

    def on_switches
      data = $game_switches.instance_variable_get(:@data) || []
      out  = []
      data.each_with_index do |v, i|
        next unless v
        out << i
        break if out.length >= MAX_ENTRIES
      end
      out
    end

    # Only Integer values are projected: they are the ones the server can compare,
    # and they cover quest counters. Non-Integer variables (strings, arrays a fan
    # script parked there) are deliberately skipped rather than shipped blindly.
    def set_variables
      data = $game_variables.instance_variable_get(:@data) || []
      out  = {}
      data.each_with_index do |v, i|
        next unless v.is_a?(Integer) && v != 0
        out[i.to_s] = v
        break if out.size >= MAX_ENTRIES
      end
      out
    end

    # Keys are [map_id, event_id, "A"] -> flattened to "map:event:A" (compact,
    # primitive-codec friendly, and stable to sort/diff server-side).
    def on_self_switches
      data = $game_self_switches.instance_variable_get(:@data) || {}
      out  = []
      data.each do |k, v|
        next unless v == true && k.is_a?(Array) && k.length >= 3
        out << "#{k[0]}:#{k[1]}:#{k[2]}"
        break if out.length >= MAX_ENTRIES
      end
      out
    end

    # --- step 5: in-session repair --------------------------------------------
    # The server's mirror of the owned state is built from the game's own writes; a
    # snapshot that disagreed with it changed some id another way (a memory or save
    # edit). The repair puts the server's values back at a safe frame, skipping any
    # id the game wrote again since that snapshot (the next one shows it).
    def note_repair(msg)
      @repair = msg if msg.is_a?(Hash) && msg[:seq].is_a?(Integer)
    end

    def tick_repair
      r = @repair
      return unless r && repair_safe?

      @repair = nil
      applied = apply_repair(r)
      return if applied.zero?

      $game_map.need_refresh = true if $game_map   # event pages must re-evaluate
      (PEMK::Sync.mark_flags rescue nil)           # a fresh snapshot confirms it
      PEMK.log("flags: repaired #{applied} value(s) to the server's (snapshot #{r[:seq]})")
    rescue => e
      PEMK.log("flags: repair error #{e.class}: #{e.message}")
    end

    def repair_safe?
      $scene.is_a?(Scene_Map) && $game_temp && $game_switches && $game_variables && $game_self_switches &&
        !$game_temp.in_battle && !$game_temp.message_window_showing &&
        !$game_temp.player_transferring && !(pbMapInterpreterRunning? rescue true)
    rescue
      false
    end

    # -> how many values changed. Suppressed: this is the server's state coming
    # back, and its mirror already holds it.
    def apply_repair(r)
      seq = r[:seq]
      d   = PEMK::Flags::Delta
      applied = 0
      d.suppress do
        (r[:switches] || {}).each do |id, on|
          id = id.to_i
          next if id <= 0 || d.written_since?("sw/#{id}", seq)

          $game_switches[id] = on ? true : false
          applied += 1
        end
        (r[:variables] || {}).each do |id, val|
          id = id.to_i
          next if id <= 0 || !val.is_a?(Integer) || d.written_since?("var/#{id}", seq)

          cur = $game_variables[id]
          next unless cur.nil? || cur.is_a?(Integer)   # never overwrite what the game parked there

          $game_variables[id] = val
          applied += 1
        end
        (r[:self_switches] || {}).each do |k, on|
          parts = k.to_s.split(":")
          next unless parts.length == 3 && !d.written_since?("ss/#{k}", seq)

          $game_self_switches[[parts[0].to_i, parts[1].to_i, parts[2]]] = on ? true : false
          applied += 1
        end
      end
      applied
    end

    # :flags_ack is telemetry — log a server flag, never write anything back.
    def on_ack(msg)
      PEMK.log("flags: server flagged a state rewind (seq #{msg[:seq]})") if msg && msg[:flagged]
    end

    # --- step 4: login authority (facts only) ---------------------------------
    # The server's progression facts are UNIONED into the loaded save. A union can
    # only ever ADD, so this restores progress a rollback or a lost save dropped and
    # can never destroy any - including a session played offline, whose own facts
    # simply travel up on the next snapshot. Mirrored VALUES are deliberately not
    # applied here: overwriting a counter needs to know which side is newer, which
    # is what step 5's fencing provides.
    def note_facts(facts)
      @pending_facts = facts if facts.is_a?(Hash)
    end

    # Called after the save has loaded (PersistHooks), like reconcile_monsters.
    def reconcile
      f = @pending_facts
      @pending_facts = nil
      return unless f && active? && $game_switches && $game_self_switches

      applied = 0
      # Suppress delta recording: we are applying what the server just told us, and
      # echoing it straight back would be noise the trust gate then has to explain.
      PEMK::Flags::Delta.suppress do
        Array(f[:switches]).each do |id|
          next unless id.is_a?(Integer) && !$game_switches[id]

          $game_switches[id] = true
          applied += 1
        end
        Array(f[:self_switches]).each do |k|
          parts = k.to_s.split(":")
          next unless parts.length == 3

          key = [parts[0].to_i, parts[1].to_i, parts[2]]
          next if $game_self_switches[key]

          $game_self_switches[key] = true
          applied += 1
        end
      end
      applied += restore_cooldowns(f[:event_times])
      return if applied.zero?

      $game_map.need_refresh = true if $game_map   # event pages must re-evaluate
      PEMK.log("flags: restored #{applied} progression fact(s) from the server")
    rescue => e
      PEMK.log("flags: reconcile error #{e.class}: #{e.message}")
    end

    # Repeatable events (berry plants, daily respawns): put back the harvest timestamp
    # AND the self-switch A that pbSetEventTime sets with it. The two only ever move
    # together, so restoring one without the other would either leave a plantable spot
    # on a future timer or lock a spot with no timer at all.
    #
    # STRICTLY GREATER is the whole safety argument. An event that legitimately expired
    # keeps its timestamp and clears A on its own; it reports the same value we hold,
    # does not match "greater", and is left alone. Only a client that is genuinely
    # BEHIND - a rollback, a lost save - gets written to, and never downward.
    def restore_cooldowns(times)
      return 0 unless times.is_a?(Hash) && $PokemonGlobal && $game_self_switches

      applied = 0
      armed   = []
      PEMK::Flags::Delta.suppress do
        $PokemonGlobal.eventvars = {} unless $PokemonGlobal.eventvars.is_a?(Hash)
        times.each do |key, at|
          next unless at.is_a?(Integer) && at.positive?

          parts = key.to_s.split(":")
          next unless parts.length == 2

          k = [parts[0].to_i, parts[1].to_i]
          # Only ever raise a MISSING or LOWER Integer. setVariable parks arbitrary
          # objects in this same namespace (berry plants keep a growth record here), so
          # "not an Integer" must mean leave it alone, not treat it as absent and
          # clobber it. The manifest filter makes that unreachable today; this makes it
          # a local invariant instead of one that depends on the export.
          cur = $PokemonGlobal.eventvars[k]
          next unless cur.nil? || (cur.is_a?(Integer) && cur < at)

          $PokemonGlobal.eventvars[k] = at
          armed << [k[0], k[1], "A"]
          applied += 1
        end
      end
      # Recorded, not suppressed: which cooldowns applied is the client's call, so the
      # server learns the self-switches from the delta stream like any game write.
      armed.each { |key| $game_self_switches[key] = true }
      applied
    rescue => e
      PEMK.log("flags: cooldown restore error #{e.class}: #{e.message}")
      0
    end
  end
end

# Step 5: a pending repair lands on the first safe overworld frame.
if defined?(EventHandlers)
  EventHandlers.add(:on_frame_update, :pemk_flag_repair,
    proc { PEMK::Flags.tick_repair })
end
