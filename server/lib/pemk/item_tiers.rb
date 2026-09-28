# frozen_string_literal: true

require "set"

module PEMK
  # Item authority E2b: which items the server can judge.
  #
  # An item is TRACKED when every way this game can produce it leaves a credit under the
  # gates that are on: an item ball (granted, or reported with the pickup gate off), a
  # literal gift (the gift gate or the claims ledger), a Mart or Battle Point purchase
  # (the shop gate), a trade, the PC's start items. It is LOCAL when some source cannot
  # be seen or bounded: a berry plant, a wild Pokemon's held item, the Pickup ability,
  # Honey Gather, the mining game, a gift or a prize whose item is computed, an item an
  # event adds straight to the bag, a common event, a shop whose gate is off. An increase
  # of a local item is recorded, never judged: whatever the exports cannot account for
  # makes an item local - a degradation, never a false accusation.
  #
  # Built at boot from the exports and the gates that are on. An event that adds an item
  # the export cannot name (a computed call with no item written anywhere in it) is
  # unbounded: its items are judged, and named at boot so the operator can list them in
  # PEMK_ITEM_LOCAL.
  class ItemTiers
    attr_reader :unbounded

    # gifts: the gift gate is on; claims: the claims ledger runs (PEMK_FLAG_STATE);
    # shops: the shop gate is on; repeatable: (map, event) -> does it pay again by design.
    def initialize(world:, battle:, gifts:, claims:, shops:, repeatable: ->(_m, _e) { false }, extra: [])
      @why = Hash.new { |h, k| h[k] = Set.new }
      @unbounded = []
      @complete = !world.item_sources.nil? && !battle.wild_items.nil?
      engine(battle)
      sources(world, battle) if world.item_sources
      objects(world, battle, gifts: gifts, claims: claims, shops: shops, repeatable: repeatable)
      mark(extra, "PEMK_ITEM_LOCAL")
      @local = @why.keys.to_set.freeze
    end

    def local
      @local
    end

    def local?(item)
      @local.include?(item.to_s)
    end

    # Did the exports say enough to sort every source? (An export from before the item
    # sources leaves computed and unhooked ones unknown: their items are judged.)
    def complete?
      @complete
    end

    # -> "93 local (berry plants 67, wild held items 40, ...)"
    def summary
      counts = Hash.new(0)
      @why.each_value { |reasons| reasons.each { |r| counts[r] += 1 } }
      detail = counts.sort_by { |r, n| [-n, r] }.map { |r, n| "#{r} #{n}" }.join(", ")
      "#{@local.size} local#{detail.empty? ? '' : " (#{detail})"}"
    end

    private

    def mark(items, reason)
      Array(items).each { |i| @why[i.to_s] << reason if i }
    end

    # The engine's own tables.
    def engine(battle)
      rules = battle.item_rules
      mark(battle.wild_items, "wild held items")
      mark(rules["pickup_items"], "Pickup")
      mark(rules["honey_gather"], "Honey Gather")
    end

    def sources(world, battle)
      src = world.item_sources
      if src["berry_plants"]
        mark(battle.item_ids.select { |i| battle.item(i)["is_berry"] }, "berry plants")
      end
      mark(battle.item_rules["mining_items"], "mining") if src["mining"]
      Array(src["events"]).each do |e|
        where = e["common_event"] ? "common event #{e['common_event']}" : "map #{e['map']} event #{e['event']}"
        mark(e["items"], e["common_event"] ? "common events" : "events adding items themselves")
        @unbounded << "#{where} (#{Array(e['calls']).join(', ')})" if e["unbounded"]
      end
    end

    # What the world objects give, and whether the gate that credits them is on.
    def objects(world, battle, gifts:, claims:, shops:, repeatable:)
      (world.objects_of("gift") + world.objects_of("prize")).each do |map, o|
        items = o["items"] || [o["item"]]
        if o["dynamic"] != false
          mark(items, "computed gifts and prizes")
        elsif !claims && (!gifts || o["once"] != true || repeatable.call(map, o["event_id"]))
          # A one-shot is credited by the gift gate or the claims ledger; any other gift
          # only by the claims ledger, which bounds its repeats.
          mark(items, "gifts with no gate to credit them")
        end
      end
      return if shops

      %w[mart bp_shop].each do |kind|
        price = kind == "mart" ? "price" : "bp_price"
        world.objects_of(kind).each do |_map, o|
          sold = o["dynamic"] ? battle.item_ids.select { |i| battle.item(i)[price].to_i.positive? } : Array(o["items"])
          mark(sold, "shops with the gate off")
          # A Mart adds Premier Balls to a large ball purchase.
          if kind == "mart" && sold.any? { |i| battle.item(i)&.fetch("is_ball", false) }
            mark(["PREMIERBALL"], "shops with the gate off")
          end
        end
      end
    end
  end
end
