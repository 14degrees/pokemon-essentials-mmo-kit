#===============================================================================
# PEMK :: Flags::Delta  (client — the write interception + delta buffer)
#-------------------------------------------------------------------------------
# Step 3 of sovereign variables, and THE TRUST GATE of the whole design: before
# the server may own this state, the delta stream must provably reconstruct the
# absolute snapshot across real play. This ships the interception in SHADOW —
# the server applies our deltas to its own copy and compares it against the
# absolute snapshot the existing :flags channel already sends. A mismatch means
# the stream is lossy and nothing further may be built on it.
#
# THE SEAM: reopen the three wrappers' `[]=`. Never `[]` (reads must stay free —
# a parallel event evaluates conditions constantly), and NEVER a subclass: the
# save's `ensure_class :Game_Switches` plus Marshal means the persisted object
# must remain a literal Game_Switches or the save is unloadable without us.
#
# THE ORDER IS NON-NEGOTIABLE: the vanilla store happens FIRST and
# UNCONDITIONALLY. The interpreter has no rollback and @index has already moved,
# so an exception from our code before the store would corrupt quest state.
#
# THE POLICY comes from the SERVER at login (the tier table derived at build time
# from the developer's own events). Anything absent is LOCAL — the pre-sovereignty
# behaviour — so an unclassified id costs nothing and a missing policy makes the
# whole layer inert.
#===============================================================================
module PEMK
  module Flags
    module Delta
      MAX_ENTRIES = 2000   # a delta bigger than this is pathological -> fall back to snapshot-only

      @switches      = {}  # id  => bool
      @variables     = {}  # id  => value
      @self_switches = {}  # key => bool
      @overflow      = false
      @origin        = nil # [map_id, event_id] of the running event, for attribution
      @suppressed    = false
      @written_at    = {}  # "sw/4" => the flags seq current when the game last wrote it

      module_function

      def reset
        @switches = {}
        @variables = {}
        @self_switches = {}
        @overflow = false
        @origin = nil
      end

      def empty?
        @switches.empty? && @variables.empty? && @self_switches.empty?
      end

      def overflow?; @overflow; end

      # --- the ambient intent frame -----------------------------------------
      # The running event is the natural attribution unit. It also retires the
      # fragile `pbMapInterpreter.instance_variable_get(:@event_id)` reach-in that
      # GiftClaim documents as a hack.
      def with_origin(map_id, event_id)
        prev = @origin
        @origin = [map_id, event_id]
        yield
      ensure
        @origin = prev
      end

      def origin; @origin; end

      # Applying server-sent state must not be recorded as a client write: echoing it
      # straight back is noise the trust gate would then have to explain away.
      def suppress
        prev = @suppressed
        @suppressed = true
        yield
      ensure
        @suppressed = prev
      end

      def suppressed?; @suppressed == true; end

      # Did the game write +key+ after the snapshot +seq+ was sent? A repair judged on
      # that snapshot must then leave it alone: the next snapshot shows the new value.
      def written_since?(key, seq)
        at = @written_at[key]
        !at.nil? && at >= seq
      end

      def stamp(key)
        @written_at.clear if @written_at.size > 5_000
        @written_at[key] = (PEMK::Sync.flags_seq rescue 0)
      end

      # --- recording ---------------------------------------------------------

      def record_switch(id, value)
        return if @suppressed
        return unless PEMK::Flags.owned?(:switches, id)

        stamp("sw/#{id}")
        note(@switches, id, value ? true : false)
      end

      def record_variable(id, value)
        return if @suppressed
        return unless PEMK::Flags.owned?(:variables, id)

        stamp("var/#{id}")
        # Only primitives cross the wire. A variable legitimately holds a Pokémon or
        # an Array in Essentials; those are recorded as untracked rather than shipped.
        return note(@variables, id, nil) unless value.is_a?(Integer)

        note(@variables, id, value)
      end

      def record_self_switch(key, value)
        return if @suppressed
        return unless key.is_a?(Array) && key.length >= 3

        k = "#{key[0]}:#{key[1]}:#{key[2]}"
        stamp("ss/#{k}")
        note(@self_switches, k, value ? true : false)
      end

      def note(bucket, key, value)
        # Coalescing by key is what makes an event's 90 scratch writes one entry.
        if bucket.size >= MAX_ENTRIES && !bucket.key?(key)
          @overflow = true
          return
        end
        bucket[key] = value
      end

      # --- draining ----------------------------------------------------------
      # -> the payload for one :flag_delta frame, or nil when there is nothing to
      # send. Clears the buffer: the caller owns delivery from here.
      def drain
        return nil if empty? && !@overflow

        payload = { :switches => @switches.dup, :variables => @variables.dup,
                    :self_switches => @self_switches.dup, :overflow => @overflow }
        reset
        payload
      end
    end
  end
end

#===============================================================================
# The interception. Reopen (never subclass), alias once, vanilla store FIRST.
#===============================================================================
class Game_Switches
  unless method_defined?(:pemk_orig_set)
    alias pemk_orig_set []=
    def []=(switch_id, value)
      pemk_orig_set(switch_id, value)   # vanilla FIRST, always — no rollback exists
      (PEMK::Flags::Delta.record_switch(switch_id, value) rescue nil)
    end
  end
end

class Game_Variables
  unless method_defined?(:pemk_orig_set)
    alias pemk_orig_set []=
    def []=(variable_id, value)
      pemk_orig_set(variable_id, value)
      (PEMK::Flags::Delta.record_variable(variable_id, value) rescue nil)
    end
  end
end

class Game_SelfSwitches
  unless method_defined?(:pemk_orig_set)
    alias pemk_orig_set []=
    def []=(key, value)
      pemk_orig_set(key, value)
      (PEMK::Flags::Delta.record_self_switch(key, value) rescue nil)
    end
  end
end

#===============================================================================
# The ambient intent frame: which event is writing. Aliased on the three write
# commands (the interpreter knows its own event) — cheap, and it gives the server
# attribution without the GiftClaim ivar reach-in.
#===============================================================================
class Interpreter
  unless method_defined?(:pemk_orig_command_121)
    %w[121 122 123].each do |code|
      alias_method(:"pemk_orig_command_#{code}", :"command_#{code}")
      define_method(:"command_#{code}") do
        map = ($game_map && $game_map.map_id) rescue nil
        ev  = instance_variable_get(:@event_id)
        if map && ev.is_a?(Integer) && ev.positive?
          PEMK::Flags::Delta.with_origin(map, ev) { send(:"pemk_orig_command_#{code}") }
        else
          send(:"pemk_orig_command_#{code}")
        end
      end
    end
  end
end
