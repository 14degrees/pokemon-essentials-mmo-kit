#===============================================================================
# PEMK :: FlagManifest  (build-time classification of switches / variables)
#-------------------------------------------------------------------------------
# Step 2 of the sovereign-variables architecture. The RM developer's OWN event
# commands are the declaration: this walks everything they authored and derives,
# per switch/variable, whether the server may own it — with no annotation, no
# naming ritual and no step they could forget.
#
# WHAT IT WALKS (four of these are surfaces the world exporter never touched):
#   * every map event page's command list — codes 121/122/123 (the writes),
#     111 (Conditional Branch reads), 355/655 (script text)
#   * page.condition — switch1/switch2/variable/self-switch: what decides which
#     NPC page is live, and therefore what gates content
#   * move routes (page.move_route + code 209) — codes 27/28 write switches and
#     are invisible to command-list analysis
#   * $data_common_events — a large blind spot in a real game
#   * $data_system switch/variable NAMES, and Settings::*_SWITCH constants
#
# THE TIERS (first match wins; the default is always LOCAL, i.e. exactly today's
# behaviour — an unclassified id degrades, it never breaks):
#   local   — never leaves the client. Unnamed ids land here UNCONDITIONALLY: the
#             compiler's MapData#registerSwitch rewrites Data/System.rxdata, so any
#             id-derived fallback key is actively unstable. So do `s:`-prefixed
#             names (the engine EVALS them as Ruby — there is no stored value) and
#             duplicate names (ambiguous key).
#   fact    — written true and never cleared anywhere: a monotonic progression
#             marker. The server can own these grant-only, which is what removes
#             rewind detection entirely.
#   mirror  — everything else the events actually write, keyed by name.
# CONFIG candidates (ids equal to a Settings::*_SWITCH constant) are emitted as
# `config_candidate` on a MIRROR entry, never auto-promoted: Essentials itself
# writes some of them and static map analysis cannot see those writes.
#
# KEYS ARE NAME-DERIVED, NOT ID-DERIVED — ids are renumbered by the compiler.
#===============================================================================
module PEMK
  module FlagManifest
    MANIFEST_VERSION = 1

    module_function

    # -> the :flags section for world.json, or nil if there is nothing to say.
    def build
      sys = (load_data("Data/System.rxdata") rescue nil)
      return nil unless sys

      ev = Evidence.new
      collect_common_events(ev)
      collect_maps(ev)

      sw  = classify(ev.switch_writes, ev.switch_reads, names_of(sys, :switches), "sw", ev)
      var = classify(ev.var_writes, ev.var_reads, names_of(sys, :variables), "var", ev)
      return nil if sw.empty? && var.empty?

      section = {
        :manifest_version => MANIFEST_VERSION,
        :switches         => sw,
        :variables        => var,
        # Self-switches need no per-id table: they are per-(map,event,letter) markers,
        # so the namespace is FACT-tier with two exclusions.
        #   repeatable — "map:event" whose text reaches for a cooldown helper. Inferred
        #     from event TEXT, and it covers every letter of the event because
        #     pbSetEventTime drives them together.
        #   latched — "map:event:letter" this project ever writes OFF. Inferred from
        #     what the events DO, and it is the same rule the switch tiering above has
        #     always used: a flag that gets cleared is not monotonic, so it is not a
        #     fact. Only the self-switch namespace had been exempted from it.
        # The cost is asymmetric, which is why both err towards excluding: excluding a
        # genuine one-shot only forfeits anti-rollback protection (the pre-sovereignty
        # behaviour), while banking a latch replays a completed event at every login -
        # and one of the two cases found here crashes the client when it does.
        :self_switches    => { :policy => "fact", :repeatable => ev.repeatable_events.sort,
                               :latched => ev.cleared_self_switches },
        :unjudgeable      => ev.unjudgeable.sort
      }
      section[:manifest_hash] = hash_of(section)
      section
    end

    # --- evidence -------------------------------------------------------------

    class Evidence
      attr_reader :switch_writes, :switch_reads, :var_writes, :var_reads,
                  :cleared_switches, :unjudgeable, :repeatable_events

      def initialize
        @switch_writes = Hash.new(0)   # id => write count
        @switch_reads  = Hash.new(0)
        @var_writes    = Hash.new(0)
        @var_reads     = Hash.new(0)
        @cleared_switches = {}         # id => true (ever written OFF)
        @unjudgeable   = []            # human-readable notes
        @repeatable_events = []        # "map:event" whose text implies a cooldown
        @cleared_self = {}             # "map:event:A" => true (ever written OFF)
      end

      # THE SAME RULE the switch tiering already uses (see wrote_switch above): a flag
      # this project ever writes OFF is not monotonic, so it is not a fact. Only the
      # self-switch namespace had been exempted from it, on the assumption that a
      # self-switch is always a one-shot "this happened" marker. It is not: the two
      # Pokemon Institute fossil NPCs drive A in both directions (page 1 sets it when
      # you hand a fossil over, page 2 clears it when you collect the result), and
      # banking that replays the collection page at every login.
      #
      # Deliberately keyed on the CLEAR alone, not on seeing both directions. Where the
      # ON comes from does not matter - a pbSetSelfSwitch in a script is invisible here -
      # while the clear is the disqualifying evidence on its own.
      def wrote_self_switch(origin, letter, on)
        return if letter.to_s.empty? || on
        # A common event does not know which map event it runs for, so its key could
        # never match a client's "map:event:letter". Note the blind spot instead of
        # exporting an unmatchable entry.
        unless origin.to_s =~ /\A\d+:\d+\z/
          return note("self-switch cleared inside #{origin} — cannot be attributed to an event")
        end

        @cleared_self["#{origin}:#{letter}"] = true
      end

      # "map:event:letter" of every self-switch this project clears. Letter-precise:
      # excluding a latch letter must not unprotect a genuine one-shot letter on the
      # same event.
      def cleared_self_switches
        @cleared_self.keys.sort
      end

      def wrote_switch(id, on)
        return unless id.is_a?(Integer) && id.positive?

        @switch_writes[id] += 1
        @cleared_switches[id] = true unless on
      end

      def wrote_var(id)
        @var_writes[id] += 1 if id.is_a?(Integer) && id.positive?
      end

      def read_switch(id); @switch_reads[id] += 1 if id.is_a?(Integer) && id.positive?; end
      def read_var(id);    @var_reads[id]    += 1 if id.is_a?(Integer) && id.positive?; end
      def note(msg);       @unjudgeable << msg unless @unjudgeable.include?(msg); end
      def repeatable(key); @repeatable_events << key unless @repeatable_events.include?(key); end
    end

    COOLDOWN = /expired\?|expiredDays\?|cooledDown\?|pbSetEventTime/.freeze

    def collect_common_events(ev)
      list = (load_data("Data/CommonEvents.rxdata") rescue nil)
      return unless list.is_a?(Array)

      list.each do |ce|
        next unless ce && ce.respond_to?(:list)

        ev.read_switch(ce.switch_id) if ce.respond_to?(:switch_id) && ce.trigger.to_i == 2
        walk_commands(ce.list, ev, "common:#{ce.respond_to?(:id) ? ce.id : '?'}")
      end
    end

    def collect_maps(ev)
      mapinfos = (load_data("Data/MapInfos.rxdata") rescue nil)
      return unless mapinfos

      mapinfos.keys.sort.each do |map_id|
        map = (load_data(sprintf("Data/Map%03d.rxdata", map_id)) rescue nil)
        next unless map && map.respond_to?(:events) && map.events

        map.events.each_value do |event|
          next unless event && event.pages

          event.pages.each do |page|
            next unless page

            collect_page_condition(page, ev)
            walk_move_route(page.move_route, ev) if page.respond_to?(:move_route)
            walk_commands(page.list, ev, "#{map_id}:#{event.id}")
          end
        end
      end
    end

    # The page condition decides which NPC page is live — i.e. what gates content.
    def collect_page_condition(page, ev)
      c = (page.condition rescue nil)
      return unless c

      ev.read_switch(c.switch1_id) if c.respond_to?(:switch1_valid) && c.switch1_valid
      ev.read_switch(c.switch2_id) if c.respond_to?(:switch2_valid) && c.switch2_valid
      ev.read_var(c.variable_id)   if c.respond_to?(:variable_valid) && c.variable_valid
    end

    # Move-route codes 27 (switch ON) and 28 (switch OFF) are invisible to command
    # analysis, and they DO write switches.
    def walk_move_route(route, ev)
      return unless route && route.respond_to?(:list) && route.list

      route.list.each do |c|
        next unless c.respond_to?(:code) && c.parameters

        ev.wrote_switch(c.parameters[0], true)  if c.code == 27
        ev.wrote_switch(c.parameters[0], false) if c.code == 28
      end
    end

    def walk_commands(list, ev, origin)
      return unless list.is_a?(Array)

      list.each do |cmd|
        next unless cmd.respond_to?(:code)

        p = (cmd.respond_to?(:parameters) ? cmd.parameters : nil)
        next unless p

        case cmd.code
        when 121   # Control Switches: range p[0]..p[1], p[2] == 0 means ON
          range_each(p[0], p[1]) { |id| ev.wrote_switch(id, p[2].to_i.zero?) }
        when 122   # Control Variables: range p[0]..p[1]
          range_each(p[0], p[1]) { |id| ev.wrote_var(id) }
          ev.note("var operand kind #{p[3]} at #{origin} is not statically derivable") if p[3].to_i > 1
        when 123   # Control Self Switch: p[0] = letter, p[1] == 0 means ON
          ev.wrote_self_switch(origin, p[0].to_s, p[1].to_i.zero?)
        when 111   # Conditional Branch
          case p[0].to_i
          when 0 then ev.read_switch(p[1])
          when 1 then ev.read_var(p[1])
          when 12 then ev.note("script branch at #{origin} is an eval — unjudgeable")
          end
        when 209   # Set Move Route
          walk_move_route(p[1], ev)
        when 355, 655
          txt = p[0].to_s
          ev.repeatable(origin) if txt =~ COOLDOWN
          scan_script(txt, ev, origin)
        end
      end
    end

    # Literal accesses in Script commands. A non-literal index (a computed id) is
    # explicitly NOT resolvable — it is noted so the id can be forced LOCAL.
    def scan_script(txt, ev, origin)
      txt.scan(/\$game_switches\[\s*(\d+)\s*\]\s*=/) { |m| ev.wrote_switch(m[0].to_i, true) }
      txt.scan(/\$game_variables\[\s*(\d+)\s*\]\s*=/) { |m| ev.wrote_var(m[0].to_i) }
      txt.scan(/pbSet\(\s*(\d+)\s*,/) { |m| ev.wrote_var(m[0].to_i) }
      # A self-switch cleared from Ruby counts too: the clear is what disqualifies it,
      # and the event id is explicit in this form.
      txt.scan(/pbSetSelfSwitch\(\s*(\d+)\s*,\s*["']([A-D])["']\s*,\s*(?:false|nil)/) do |m|
        ev.wrote_self_switch("#{origin.split(':').first}:#{m[0]}", m[1], false)
      end
      if txt =~ /\$game_(?:switches|variables)\[\s*[^\d\s\]]/
        ev.note("computed switch/variable index at #{origin} — those ids stay local")
      end
    end

    def range_each(a, b)
      lo = a.to_i
      hi = (b || a).to_i
      return if lo <= 0 || hi < lo || (hi - lo) > 5000

      (lo..hi).each { |id| yield id }
    end

    # --- classification -------------------------------------------------------

    def names_of(sys, which)
      arr = (sys.send(which) rescue nil)
      arr.is_a?(Array) ? arr : []
    end

    def classify(writes, reads, names, prefix, ev)
      dupes = duplicate_names(names)
      config = config_ids(prefix)
      out = {}
      (writes.keys | reads.keys).sort.each do |id|
        name = names[id].to_s.strip
        entry = { :writes => writes[id], :reads => reads[id] }

        if name.empty?
          # UNCONDITIONAL: the compiler rewrites Data/System.rxdata, so an id-derived
          # key is actively unstable. No report-only escape hatch.
          entry[:tier] = "local"
          entry[:why]  = "unnamed"
        elsif name =~ /\Atemp[\s_\-]/i
          # Scratch: Essentials' own convention for a value that lives inside one menu
          # or one animation. The real project data makes the case — "Temp Pokemon
          # Choice" takes 90 writes and "PokeCenter Healing Ball Count" 36, all of it
          # transient with no exploit value. Replicating that is pure wire noise.
          entry[:tier] = "local"
          entry[:why]  = "temp scratch (engine convention)"
        elsif name.start_with?("s:")
          entry[:tier] = "local"
          entry[:why]  = "s-prefixed name is evaluated as Ruby by the engine"
        elsif dupes.include?(name.downcase)
          entry[:tier] = "local"
          entry[:why]  = "duplicate name — no unique key"
        else
          entry[:key] = "#{prefix}:#{slug(name)}"
          if prefix == "sw" && writes[id].positive? && !ev.cleared_switches[id]
            entry[:tier] = "fact"      # only ever written ON -> monotonic marker
          else
            entry[:tier] = "mirror"
          end
          entry[:config_candidate] = true if config.include?(id)
        end
        out[id.to_s] = entry
      end
      out
    end

    def duplicate_names(names)
      seen = Hash.new(0)
      names.each { |n| s = n.to_s.strip.downcase; seen[s] += 1 unless s.empty? }
      seen.select { |_, c| c > 1 }.keys
    end

    # Ids the game's own Settings point at — candidates only (Essentials writes some
    # of them from code the map walk cannot see).
    def config_ids(prefix)
      want = prefix == "sw" ? /_SWITCH$/ : /_VARIABLE$/
      out = []
      (Settings.constants rescue []).each do |c|
        next unless c.to_s =~ want

        v = (Settings.const_get(c) rescue nil)
        out << v if v.is_a?(Integer) && v.positive?
      end
      out
    rescue StandardError
      []
    end

    def slug(name)
      name.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")[0, 48]
    end

    # A cheap stable digest so the client can advertise WHICH manifest it holds and
    # the server can refuse to reason about a stale one (FNV-1a over the sorted body).
    def hash_of(section)
      h = 0xcbf29ce484222325
      m = (1 << 64) - 1
      digest_source(section).each_byte { |b| h = ((h ^ b) * 0x100000001b3) & m }
      format("%016x", h)
    end

    def digest_source(section)
      parts = []
      %i[switches variables].each do |k|
        section[k].keys.sort_by(&:to_i).each do |id|
          e = section[k][id]
          parts << "#{k}/#{id}/#{e[:tier]}/#{e[:key]}"
        end
      end
      parts << "self/#{section[:self_switches][:repeatable].join(',')}"
      parts << "latched/#{section[:self_switches][:latched].join(',')}"
      parts.join("|")
    end
  end
end
