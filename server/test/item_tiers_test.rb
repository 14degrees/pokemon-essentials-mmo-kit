require "minitest/autorun"
require "json"
require "tempfile"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk"

# Item authority E2b: an item is judged (tracked) only when every way the game can
# produce it leaves a credit under the gates that are on; anything else is local.
class ItemTiersTest < Minitest::Test
  def self.json_file(doc)
    f = Tempfile.new(["pemk", ".json"])
    f.write(JSON.generate(doc))
    f.flush
    f
  end

  def self.item(berry: false, ball: false, price: 100, bp: 0)
    { "is_berry" => berry, "is_ball" => ball, "price" => price, "bp_price" => bp }
  end

  ITEMS = { "POTION" => item, "POKEBALL" => item(ball: true), "PREMIERBALL" => item(ball: true, price: 0),
            "TM80" => item(price: 0), "MASTERBALL" => item(price: 0), "PPUP" => item, "PROTEIN" => item(bp: 1),
            "FRESHWATER" => item, "ORANBERRY" => item(berry: true), "HELIXFOSSIL" => item(price: 0),
            "LEFTOVERS" => item, "XATTACK" => item, "HONEY" => item, "NUGGET" => item, "COINCASE" => item(price: 0) }.freeze

  def self.battle_doc(wild: true, rules: true)
    sp = { "species" => "SNORLAX", "form" => 0 }
    sp["wild_items"] = %w[LEFTOVERS] if wild
    doc = { "schema_version" => 1, "items" => ITEMS, "species" => { "SNORLAX" => sp } }
    if rules
      doc["item_rules"] = { "pickup_items" => %w[NUGGET], "honey_gather" => %w[HONEY], "mining_items" => %w[HELIXFOSSIL] }
    end
    doc
  end

  def self.world_doc(sources: true)
    doc = { "schema_version" => 3, "maps" => {
      "5" => { "name" => "Route", "width" => 30, "height" => 30, "objects" => [
        { "kind" => "item", "item" => "POTION", "quantity" => 1, "x" => 1, "y" => 1, "event_id" => 1 }
      ] },
      "10" => { "name" => "Gym", "width" => 30, "height" => 30, "objects" => [
        { "kind" => "gift", "item" => "TM80", "items" => ["TM80"], "once" => true, "dynamic" => false, "x" => 1, "y" => 1, "event_id" => 3 },
        { "kind" => "gift", "item" => "MASTERBALL", "items" => ["MASTERBALL"], "once" => true, "dynamic" => true, "x" => 2, "y" => 1, "event_id" => 4 },
        { "kind" => "gift", "item" => "COINCASE", "items" => ["COINCASE"], "once" => false, "dynamic" => false, "x" => 3, "y" => 1, "event_id" => 5 }
      ] },
      "13" => { "name" => "Game Corner", "width" => 30, "height" => 30, "objects" => [
        { "kind" => "prize", "item" => "PPUP", "items" => %w[PPUP MASTERBALL], "once" => false, "dynamic" => true, "x" => 1, "y" => 1, "event_id" => 17 }
      ] },
      "15" => { "name" => "Mart", "width" => 30, "height" => 30, "objects" => [
        { "kind" => "mart", "items" => %w[POTION POKEBALL XATTACK], "prices" => {}, "dynamic" => false, "x" => 1, "y" => 1, "event_id" => 5 }
      ] },
      "54" => { "name" => "Frontier", "width" => 30, "height" => 30, "objects" => [
        { "kind" => "bp_shop", "items" => %w[PROTEIN], "prices" => {}, "dynamic" => false, "x" => 1, "y" => 1, "event_id" => 5 }
      ] }
    } }
    if sources
      doc["item_sources"] = { "events" => [
        { "map" => 19, "event" => 2, "calls" => ["$bag.add"], "items" => ["FRESHWATER"], "unbounded" => false },
        { "common_event" => 3, "calls" => ["computed"], "items" => [], "unbounded" => true }
      ], "berry_plants" => true, "mining" => true }
    end
    doc
  end

  WORLD  = json_file(world_doc)
  BATTLE = json_file(battle_doc)
  OLD_WORLD  = json_file(world_doc(sources: false))
  OLD_BATTLE = json_file(battle_doc(wild: false, rules: false))

  def tiers(gifts: true, claims: true, shops: true, extra: [], world: WORLD, battle: BATTLE, repeatable: nil)
    w = PEMK::WorldData.new(world.path)
    b = PEMK::BattleData.new(battle.path)
    args = { world: w, battle: b, gifts: gifts, claims: claims, shops: shops, extra: extra }
    args[:repeatable] = repeatable if repeatable
    PEMK::ItemTiers.new(**args)
  end

  def test_every_gate_on
    t = tiers
    assert_equal %w[FRESHWATER HELIXFOSSIL HONEY LEFTOVERS MASTERBALL NUGGET ORANBERRY PPUP], t.local.to_a.sort
    %w[POTION POKEBALL PREMIERBALL TM80 PROTEIN XATTACK COINCASE].each { |i| refute t.local?(i), i }
    assert t.complete?
    assert_equal ["common event 3 (computed)"], t.unbounded
    assert_match(/\A8 local \(/, t.summary)
  end

  def test_the_shop_gate_off_makes_what_shops_sell_local
    t = tiers(shops: false)
    %w[POTION POKEBALL XATTACK PROTEIN PREMIERBALL].each { |i| assert t.local?(i), i }
  end

  def test_with_no_gift_gate_and_no_claims_every_literal_gift_is_local
    t = tiers(gifts: false, claims: false)
    assert t.local?("TM80")
    assert t.local?("COINCASE")
  end

  # The gift gate credits a one-shot once; any other gift needs the claims ledger.
  def test_the_gift_gate_alone_credits_only_one_shots
    t = tiers(claims: false)
    refute t.local?("TM80")
    assert t.local?("COINCASE")
    assert tiers(claims: false, repeatable: ->(map, ev) { map == 10 && ev == 3 }).local?("TM80"),
           "a one-shot the manifest says pays again by design"
  end

  def test_the_claims_ledger_alone_credits_literal_gifts
    t = tiers(gifts: false)
    refute t.local?("TM80")
    refute t.local?("COINCASE")
  end

  def test_the_operator_adds_items
    assert tiers(extra: %w[XATTACK]).local?("XATTACK")
  end

  # Exports from before E1b: what they cannot say stays judged, and the server says so.
  def test_older_exports_are_incomplete
    t = tiers(world: OLD_WORLD, battle: OLD_BATTLE)
    refute t.complete?
    refute t.local?("FRESHWATER")
    refute t.local?("ORANBERRY")
    assert t.local?("MASTERBALL"), "the world objects still say what they can"
  end
end
