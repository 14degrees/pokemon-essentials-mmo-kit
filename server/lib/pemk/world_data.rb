# frozen_string_literal: true

require "json"

module PEMK
  # Read-only server model of the game world (Milestone 4). Loaded ONCE at boot from
  # a build-time JSON export (server/data/world.json) produced IN-ENGINE by the
  # client's "PEMK: Export World" debug action. The server NEVER reads the RMXP
  # .rxdata maps directly — that would need the engine's RPG/Table/Tone classes and a
  # Marshal.load of attacker-influenceable files, the exact RCE surface M4 forbids. It
  # only ever consumes plain JSON.
  #
  # Schema v2 carries the full static world the layered anti-cheat needs:
  #   per-map: objects[] (item balls — Layer A/C), passability grid (Layer B no-clip),
  #            warps[] (Layer B/C transfer legality), heal (Layer B respawn whitelist),
  #            encounters (Layer D);
  #   top-level: connections[] (edge map-stitching), home + start (respawn/genesis).
  # Every section is OPTIONAL (absent -> that check no-ops), mirroring the empty?/
  # map_known? tolerance, so partial exports never brick anything.
  #
  # Passability is a per-map array of H hex-nibble row strings (W chars each), where
  # the nibble is the ground tile's RMXP passage bits and 0x0f ('f') == fully blocked.
  # walkable? flags ONLY an explicit 'f' (never a missing grid), so the position audit
  # is conservative by construction.
  #
  # Boot policy (unchanged, asymmetric): ABSENT export -> tolerated (empty model + one
  # warning); PRESENT-but-INVALID (unparseable / wrong schema_version / wrong shape)
  # -> BOOT ERROR, so a stale/corrupt world never boots silently.
  class WorldData
    SCHEMA_VERSION  = 3
    # v2 exports stay valid: v3 only ADDS the optional :flags manifest, so an operator
    # who has not re-exported since the sovereign-variables work keeps a working server
    # (they simply have no manifest, which means all-local — today's behaviour).
    ACCEPTED_VERSIONS = [2, 3].freeze
    BLOCKED = "f"   # a passability nibble of 0x0f == fully blocked

    def initialize(path, expected_version: ACCEPTED_VERSIONS, logger: nil)
      @log          = logger || ->(_m) {}
      @by_tile      = {}    # [map,x,y] => frozen object hash
      @maps         = {}    # map_id => { name:, width:, height:, count: }
      @passable     = {}    # map_id => frozen Array of frozen row strings
      @ledges       = {}    # map_id => frozen Hash { [x,y] => true }
      @warps_by_map = {}    # map_id => frozen Array of frozen warp hashes
      @heal         = {}    # map_id => [map,x,y]
      @connections  = []    # frozen Array of raw 6-int conn arrays
      @home         = nil   # [map,x,y,dir]
      @start        = nil   # [map,x,y]
      @encounters   = {}    # map_id => raw encounters hash
      @trainers_by_map = {} # map_id => frozen Array of [type, name, version]
      @gifts        = {}    # [map,event_id] => frozen gift/prize object (step 6 payout gate)
      @shops        = {}    # [map,event_id] => frozen mart / bp_shop object (item authority)
      @loaded       = false
      load!(path, expected_version)
    end

    def loaded?; @loaded; end
    def empty?;  @maps.empty?; end
    def map_known?(map_id); @maps.key?(map_id); end

    # --- objects (Layer A/C) ---------------------------------------------------
    # -> frozen object hash { "kind"=>, "item"=>, "event_id"=>, "x"=>, "y"=> } | nil
    def object_at(map_id, x, y)
      @by_tile[[map_id, x, y]]
    end

    # --- passability (Layer B no-clip) -----------------------------------------
    # true = walkable, false = fully blocked ('f'), nil = unjudgeable (no grid for
    # this map, OR the coord is outside the grid). Out-of-bounds is NOT a wall: at a
    # map-connection seam the player's local x/y legitimately goes negative / past
    # the edge while stepping onto a stitched neighbour, so it must never read as a
    # no-clip. The audit only ever flags an explicit `false`.
    def walkable?(map_id, x, y)
      grid = @passable[map_id]
      return nil unless grid
      return nil if y < 0 || y >= grid.length

      row = grid[y]
      return nil if x < 0 || x >= row.length

      row[x] != BLOCKED
    end

    # A one-way ledge tile (hop-over). Lets the position audit accept a 2-tile ledge
    # jump instead of flagging it as a teleport.
    def ledge?(map_id, x, y)
      s = @ledges[map_id]
      s ? s.key?([x, y]) : false
    end

    # --- warps (Layer B/C transfer legality) -----------------------------------
    # Does a warp on +from_map+ land on (+to_map+, x, y), or within +reach+ tiles of
    # it? Used to decide a cross-map move is a legal known teleport.
    def warp_dest?(from_map, to_map, x, y, reach: 0)
      list = @warps_by_map[from_map]
      return false unless list

      list.any? do |w|
        w["dest_map"] == to_map && (w["dest_x"] - x).abs <= reach && (w["dest_y"] - y).abs <= reach
      end
    end

    # Is (x, y) the tile of a warp event on +map+ (a door, stairs)? The player steps
    # onto it to trigger the warp, even where the tile under the event is a wall.
    def warp_src?(map_id, x, y)
      (@warps_by_map[map_id] || []).any? { |w| w["src_x"] == x && w["src_y"] == y }
    end

    def warps_on(map_id)
      @warps_by_map[map_id] || []
    end

    # --- spawns / connections / encounters -------------------------------------
    def heal(map_id); @heal[map_id]; end          # [map,x,y] | nil
    def home;  @home;  end                         # [map,x,y,dir] | nil
    def start; @start; end                         # [map,x,y] | nil
    def connections; @connections; end             # raw [m1,x1,y1,m2,x2,y2] arrays
    def encounters(map_id); @encounters[map_id]; end

    # The set of every species (String) that appears in ANY map's wild encounter table,
    # across all versions/types. Used by D5 to tell a fabricated wild-table mon (a
    # "client"-origin Pidgey) from a legitimate gift. Computed once, frozen.
    # The build-time switch/variable classification (v3 exports). nil = no manifest,
    # which the whole design reads as "everything is local" — the pre-sovereignty
    # behaviour, never an error. Nothing consumes this yet (step 2 ships the data).
    def flag_manifest
      @flag_manifest
    end

    # Item authority E1b: { "events" => [{ "map", "event" | "common_event", "calls",
    # "items", "unbounded" }], "berry_plants" => bool, "mining" => bool } | nil.
    def item_sources
      @item_sources
    end

    # Every object of +kind+ ("item", "gift", "prize", "mart", "bp_shop") on every map.
    # -> [[map_id, object], ...]
    def objects_of(kind)
      @by_tile.filter_map { |(map, _x, _y), o| [map, o] if o["kind"] == kind }
    end

    def flag_tier(kind, id)
      m = @flag_manifest
      return "local" unless m

      section = m[kind.to_s]
      entry = section.is_a?(Hash) ? section[id.to_s] : nil
      entry.is_a?(Hash) ? (entry["tier"] || "local") : "local"
    end

    def wild_species
      @wild_species ||= begin
        set = {}
        @encounters.each_value do |versions|
          next unless versions.is_a?(Hash)

          versions.each_value do |types|
            next unless types.is_a?(Hash)

            types.each_value do |t|
              slots = t.is_a?(Hash) ? t["slots"] : nil
              next unless slots.is_a?(Array)

              slots.each { |s| set[s[1].to_s] = true if s.is_a?(Array) && s[1] }
            end
          end
        end
        set.keys.freeze
      end
    end

    # A tile the player can legally be teleported TO without a warp event: the
    # new-game start, the global home (whiteout fallback), or any map's heal
    # destination (Pokémon Center / Fly-heal return), or within +reach+ tiles of one.
    # Layer B transfer whitelist.
    def spawn_tile?(map, x, y, reach: 0)
      near = ->(d) { d && d[0] == map && (d[1] - x).abs <= reach && (d[2] - y).abs <= reach }
      near.call(@start) || near.call(@home) || @heal.each_value.any? { |d| near.call(d) }
    end

    # Is event +event_id+ on +map_id+ a prize table (several rewards, one picked: the
    # Game Corner lottery)? It pays out again and again by design.
    def prize_event?(map_id, event_id)
      o = @gifts[[map_id, event_id]]
      !o.nil? && o["kind"] == "prize"
    end

    # The export's record of an event that gives items (pbReceiveItem): kind "gift"
    # (one literal item) or "prize" (several). Newer exports add "once" (a single
    # payout, after which the event turns to another page), "dynamic" (a call whose
    # item is computed, so the literal list is not the whole story) and "quantities"
    # (item => largest literal quantity). -> frozen Hash | nil.
    def gift_object(map_id, event_id)
      @gifts[[map_id, event_id]]
    end

    # The export's record of a shop clerk: kind "mart" or "bp_shop", the items any of its
    # stock lists names, the prices the event sets, and "dynamic" when a list is computed.
    # -> frozen Hash | nil.
    def shop_object(map_id, event_id)
      @shops[[map_id, event_id]]
    end

    # --- trainers (Layer D D4 rewards) --------------------------------------------
    # Does this export say where trainer battles start? A pre-D4 export does not.
    def trainers_known?
      !@trainers_by_map.empty?
    end

    # Does a battle against this trainer start on +map_id+?
    def trainer_on_map?(map_id, type, name, version)
      (@trainers_by_map[map_id] || []).include?([type.to_s, name.to_s, version.to_i])
    end

    # Coarse: are these two maps joined by ANY edge connection? Used to accept an
    # edge-cross transfer without (yet) modelling the exact seam geometry.
    def connected?(map_a, map_b)
      @connections.any? do |c|
        (c[0] == map_a && c[3] == map_b) || (c[0] == map_b && c[3] == map_a)
      end
    end

    def summary
      return "absent (audit no-op — run the in-game exporter)" unless @loaded

      "#{@maps.size} maps, #{@by_tile.size} objects, #{@passable.size} passgrids, " \
        "#{@ledges.values.sum(&:size)} ledges, #{@warps_by_map.values.sum(&:size)} warps, " \
        "#{@connections.size} connections (schema v#{SCHEMA_VERSION})"
    end

    private

    def load!(path, expected_version)
      unless File.file?(path)
        @log.call("world: #{path} absent — Layer A/B audit runs in no-op mode until the in-game exporter is run")
        return
      end

      doc =
        begin
          JSON.parse(File.read(path))
        rescue JSON::ParserError => e
          raise "world data #{path} is not valid JSON: #{e.message}"
        end

      accepted = expected_version.is_a?(Array) ? expected_version : [expected_version]
      unless doc.is_a?(Hash) && accepted.include?(doc["schema_version"])
        got = doc.is_a?(Hash) ? doc["schema_version"].inspect : "missing"
        raise "world data #{path} schema_version #{got} not in #{accepted.inspect} " \
              "(regenerate via the in-game 'PEMK: Export World' action)"
      end

      maps = doc["maps"]
      raise "world data #{path} 'maps' is not an object" unless maps.is_a?(Hash)

      maps.each { |map_key, m| load_map(path, map_key, m) }
      # The flag manifest (v3+). Absent = no classification = everything local, which
      # is exactly the pre-sovereignty behaviour. Frozen; nothing reads it yet (step 2
      # ships the data, step 3 consumes it).
      @flag_manifest = doc["flags"].is_a?(Hash) ? deep_freeze(doc["flags"]) : nil
      # Item authority E1b: the events that produce items no request names. Absent =
      # an export from before it: the server cannot tell those items apart.
      @item_sources = doc["item_sources"].is_a?(Hash) ? deep_freeze(doc["item_sources"]) : nil
      @connections = freeze_connections(doc["connections"])
      @home  = coord_array(doc["home"], 4) || coord_array(doc["home"], 3)
      @start = coord_array(doc["start"], 3)

      freeze_all
      @loaded = true
      @log.call("world: loaded #{summary} from #{path}")
    end

    def load_map(path, map_key, m)
      map_id = begin; Integer(map_key); rescue ArgumentError, TypeError; nil; end
      return unless map_id && m.is_a?(Hash)

      width  = m["width"]
      height = m["height"]

      load_objects(map_id, m["objects"])
      load_passability(path, map_id, m["passability"], width, height)
      load_ledges(map_id, m["ledges"])
      load_warps(map_id, m["warps"])
      h = coord_array(m["heal"], 3)
      @heal[map_id] = h if h
      @encounters[map_id] = m["encounters"] if m["encounters"].is_a?(Hash)
      load_trainers(map_id, m["trainers"])

      @maps[map_id] = { name: m["name"], width: width, height: height,
                        count: (m["objects"].is_a?(Array) ? m["objects"].size : 0) }.freeze
    end

    def load_objects(map_id, objects)
      return unless objects.is_a?(Array)

      objects.each do |obj|
        next unless obj.is_a?(Hash)

        x = obj["x"]; y = obj["y"]
        next unless x.is_a?(Integer) && y.is_a?(Integer)

        key = [map_id, x, y]
        if @by_tile.key?(key)
          @log.call("world: duplicate object on tile (#{map_id},#{x},#{y}) — keeping first")
          next
        end
        @by_tile[key] = obj.freeze
        ev = obj["event_id"]
        @gifts[[map_id, ev]] = obj if %w[gift prize].include?(obj["kind"]) && ev.is_a?(Integer)
        next unless %w[mart bp_shop].include?(obj["kind"]) && ev.is_a?(Integer)

        @shops[[map_id, ev]] = obj
        if obj["prices_unread"]
          @log.call("world: the clerk on map #{map_id} (event #{ev}) computes a price the export cannot read " \
                    "- the server holds it to the catalogue's and its literal prices")
        end
      end
    end

    def load_passability(path, map_id, grid, width, height)
      return if grid.nil?

      unless grid.is_a?(Array) && width.is_a?(Integer) && height.is_a?(Integer) &&
             grid.length == height &&
             grid.all? { |r| r.is_a?(String) && r.length == width && r.match?(/\A[0-9a-f]*\z/) }
        raise "world data #{path} map #{map_id} passability is malformed " \
              "(need #{height} hex-nibble strings of #{width} chars; regenerate the export)"
      end

      @passable[map_id] = grid.map(&:freeze).freeze
    end

    def load_ledges(map_id, ledges)
      return unless ledges.is_a?(Array)

      set = {}
      ledges.each do |t|
        next unless t.is_a?(Array) && t.length == 2 && t[0].is_a?(Integer) && t[1].is_a?(Integer)

        set[[t[0], t[1]]] = true
      end
      @ledges[map_id] = set.freeze unless set.empty?
    end

    # [{event_id, x, y, type, name, version}, ...] -> the trainers whose battles start here.
    def load_trainers(map_id, list)
      return unless list.is_a?(Array)

      ids = list.filter_map do |t|
        next unless t.is_a?(Hash) && t["type"] && t["name"]

        [t["type"].to_s, t["name"].to_s, t["version"].to_i].freeze
      end
      @trainers_by_map[map_id] = ids.uniq.freeze unless ids.empty?
    end

    def load_warps(map_id, warps)
      return unless warps.is_a?(Array)

      valid = warps.select do |w|
        w.is_a?(Hash) && w["dest_map"].is_a?(Integer) &&
          w["dest_x"].is_a?(Integer) && w["dest_y"].is_a?(Integer)
      end
      @warps_by_map[map_id] = valid.map(&:freeze).freeze unless valid.empty?
    end

    # A JSON array of exactly +len+ integers, else nil (tolerant).
    def coord_array(v, len)
      return nil unless v.is_a?(Array) && v.length == len && v.all? { |n| n.is_a?(Integer) }

      v
    end

    # Recursively freeze a parsed JSON subtree (the manifest is read-only at runtime).
    def deep_freeze(obj)
      case obj
      when Hash  then obj.each_value { |v| deep_freeze(v) }.freeze
      when Array then obj.each { |v| deep_freeze(v) }.freeze
      else obj.freeze
      end
    end

    def freeze_connections(conns)
      return [].freeze unless conns.is_a?(Array)

      # Records are [map1, edge1, off1, map2, edge2, off2]; edge1/edge2 may be letter
      # Strings. Only [0]/[3] (the map ids) are read by connected?, so require just
      # those to be Integers — matching the exporter's load_connections filter.
      conns.select { |c| c.is_a?(Array) && c.length >= 6 && c[0].is_a?(Integer) && c[3].is_a?(Integer) }
           .map { |c| c[0, 6].freeze }.freeze
    end

    def freeze_all
      @by_tile.freeze
      @maps.freeze
      @passable.freeze
      @ledges.freeze
      @warps_by_map.freeze
      @heal.freeze
      @encounters.freeze
      @trainers_by_map.freeze
      @gifts.freeze
      @shops.freeze
    end
  end
end
