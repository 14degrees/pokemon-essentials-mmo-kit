require "minitest/autorun"
require "json"
require "tempfile"

lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "pemk/battle_data"

# M4 Layer D read model: the server loads the build-time battle_data.json (species/
# moves/items/types/natures/caps) exactly like WorldData loads world.json — absent is a
# no-op, present-but-invalid is a boot error. No DB.
class BattleDataTest < Minitest::Test
  FIX = {
    "schema_version" => 1,
    "caps"    => { "max_level" => 100, "iv_stat_limit" => 31, "ev_limit" => 510, "ev_stat_limit" => 252, "no_vitamin_ev_cap" => true },
    "natures" => { "ADAMANT" => [["ATTACK", 10], ["SPECIAL_ATTACK", -10]], "HARDY" => [] },
    "growth_rates" => { "Parabolic" => { "max_exp" => 1_059_860 } },
    "types"   => { "FIRE" => { "GRASS" => 4, "WATER" => 1 }, "GRASS" => { "GRASS" => 2 } },
    "abilities" => %w[OVERGROW CHLOROPHYLL],
    "items"   => {
      "POTION" => { "pocket" => 1, "is_ball" => false, "is_berry" => false, "is_machine" => false, "can_hold" => true, "move" => nil },
      "TM01"   => { "pocket" => 4, "is_ball" => false, "is_berry" => false, "is_machine" => true, "can_hold" => false, "move" => "MEGAPUNCH" }
    },
    "moves"   => {
      "TACKLE" => { "type" => "NORMAL", "category" => 0, "power" => 40, "accuracy" => 100, "pp" => 35,
                    "priority" => 0, "target" => "NearOther", "function_code" => "None", "flags" => ["Contact"], "effect_chance" => 0 }
    },
    "species" => {
      "BULBASAUR" => {
        "species" => "BULBASAUR", "form" => 0, "types" => %w[GRASS POISON],
        "base_stats" => { "HP" => 45, "ATTACK" => 49, "DEFENSE" => 49, "SPECIAL_ATTACK" => 65, "SPECIAL_DEFENSE" => 65, "SPEED" => 45 },
        "evs" => { "SPECIAL_ATTACK" => 1 }, "base_exp" => 64, "growth_rate" => "Parabolic", "catch_rate" => 45,
        "abilities" => ["OVERGROW"], "hidden_abilities" => ["CHLOROPHYLL"],
        "level_up_moves" => [[1, "TACKLE"], [1, "GROWL"], [3, "VINEWHIP"]],
        "tutor_moves" => ["TOXIC"], "egg_moves" => ["CURSE"], "prev_species" => nil, "minimum_level" => 1
      },
      "IVYSAUR" => {
        "species" => "IVYSAUR", "form" => 0, "types" => %w[GRASS POISON],
        "base_stats" => { "HP" => 60, "ATTACK" => 62, "DEFENSE" => 63, "SPECIAL_ATTACK" => 80, "SPECIAL_DEFENSE" => 80, "SPEED" => 60 },
        "evs" => { "SPECIAL_ATTACK" => 1, "SPECIAL_DEFENSE" => 1 }, "base_exp" => 142, "growth_rate" => "Parabolic", "catch_rate" => 45,
        "abilities" => ["OVERGROW"], "hidden_abilities" => ["CHLOROPHYLL"],
        "level_up_moves" => [[1, "TACKLE"], [3, "VINEWHIP"]],
        "tutor_moves" => [], "egg_moves" => [], "prev_species" => "BULBASAUR", "minimum_level" => 16
      }
    }
  }.freeze

  def write_json(obj)
    f = Tempfile.new(["pemk_bd", ".json"])
    f.write(obj.is_a?(String) ? obj : JSON.generate(obj))
    f.flush
    @tmp << f
    f.path
  end

  def setup
    @tmp = []
    @bd  = PEMK::BattleData.new(write_json(FIX))
  end

  def teardown
    @tmp.each { |f| f.close! rescue nil }
  end

  def test_loads_species_stats_and_prevolution
    assert @bd.loaded?
    refute @bd.empty?
    assert @bd.species_known?("BULBASAUR")
    assert_equal 45, @bd.species("BULBASAUR")["base_stats"]["HP"]
    assert_nil @bd.species("BULBASAUR")["prev_species"]
    assert_equal "BULBASAUR", @bd.species("IVYSAUR")["prev_species"]
    assert_equal 16, @bd.species("IVYSAUR")["minimum_level"]
    assert_nil @bd.species("MISSINGNO")
  end

  def test_moves_abilities_natures
    assert @bd.move_known?("TACKLE")
    assert_equal 40, @bd.move("TACKLE")["power"]
    refute @bd.move_known?("HYPERBEAM")
    assert @bd.ability_known?("OVERGROW")
    refute @bd.ability_known?("WONDERGUARD")
    assert_equal [["ATTACK", 10], ["SPECIAL_ATTACK", -10]], @bd.nature("ADAMANT")
    assert_equal [], @bd.nature("HARDY")             # neutral
    refute @bd.nature_known?("NOTANATURE")
  end

  def test_item_holdability
    assert_equal true,  @bd.holdable?("POTION")
    assert_equal false, @bd.holdable?("TM01")        # machine, not holdable
    assert_equal false, @bd.holdable?("UNKNOWN")     # unknown item -> not vouched holdable
    assert_equal "MEGAPUNCH", @bd.item("TM01")["move"]
  end

  def test_type_effectiveness_and_default
    assert_equal 4, @bd.type_effectiveness("FIRE", "GRASS")
    assert_equal 1, @bd.type_effectiveness("FIRE", "WATER")
    assert_equal 2, @bd.type_effectiveness("GRASS", "GRASS")
    assert_equal 2, @bd.type_effectiveness("NORMAL", "GHOST")   # unknown pairing -> NORMAL, never fabricate
  end

  def test_caps_and_growth
    assert_equal 100, @bd.max_level
    assert_equal 510, @bd.caps["ev_limit"]
    assert_equal true, @bd.caps["no_vitamin_ev_cap"]
    assert_equal 1_059_860, @bd.growth_rate_max_exp("Parabolic")
    assert_nil @bd.growth_rate_max_exp("Erratic")
  end

  # D4: a trainer battle's EXP is bounded by the party the export gives the trainer.
  def test_trainer_parties
    bd = PEMK::BattleData.new(write_json(FIX.merge(
      "trainers" => [{ "type" => "CAMPER", "name" => "Liam", "version" => 0,
                       "party" => [["DIGLETT", 10], ["BONSLY", 11], ["BAD", "x"]] }]
    )))
    assert_equal [["DIGLETT", 10], ["BONSLY", 11]], bd.trainer_party("CAMPER", "Liam", 0)
    assert_equal [["DIGLETT", 10], ["BONSLY", 11]], bd.trainer_party(:CAMPER, "Liam", 0)
    assert_nil bd.trainer_party("CAMPER", "Liam", 1)
    assert_nil @bd.trainer_party("CAMPER", "Liam", 0)   # a pre-D4 export has none
  end

  # Money authority M0: a trainer's prize is its strongest Pokemon's level x its type's
  # base money (Battle#pbGainMoney); the moves say whether a foe could double it.
  def test_trainer_prizes_and_start_money
    bd = PEMK::BattleData.new(write_json(FIX.merge(
      "trainer_types" => { "CAMPER" => { "base_money" => 16 }, "ODD" => { "base_money" => -1 } },
      "money_rules" => { "start_money" => 3000 },
      "trainers" => [
        { "type" => "CAMPER", "name" => "Liam", "version" => 0,
          "party" => [["DIGLETT", 10, nil, %w[SCRATCH]], ["MEOWTH", 11, "AMULETCOIN", %w[PAYDAY HAPPYHOUR]]] },
        { "type" => "CAMPER", "name" => "Old", "version" => 0, "party" => [["DIGLETT", 12]] },
        { "type" => "ODD", "name" => "Odd", "version" => 0, "party" => [["DIGLETT", 5]] }
      ]
    )))
    assert_equal 176, bd.trainer_prize("CAMPER", "Liam", 0), "11 x 16"
    assert_equal 192, bd.trainer_prize(:CAMPER, "Old", 0)
    assert_nil bd.trainer_prize("ODD", "Odd", 0), "a base money the engine cannot have"
    assert_nil bd.trainer_prize("CAMPER", "Nobody", 0)
    assert_equal [["DIGLETT", 10, nil, %w[SCRATCH]], ["MEOWTH", 11, "AMULETCOIN", %w[PAYDAY HAPPYHOUR]]],
                 bd.trainer_party("CAMPER", "Liam", 0), "the held items and moves ride along"
    assert_equal true, bd.trainer_knows_any?("CAMPER", "Liam", 0, %w[HAPPYHOUR METRONOME])
    assert_equal false, bd.trainer_knows_any?("CAMPER", "Liam", 0, %w[METRONOME])
    assert_nil bd.trainer_knows_any?("CAMPER", "Old", 0, %w[HAPPYHOUR]), "no moves listed"
    assert_equal 3000, bd.start_money
    assert_nil @bd.start_money, "an export from before M0"
    assert_nil @bd.trainer_base_money("CAMPER")
  end

  def test_absent_export_is_a_no_op
    path = File.join(Dir.tmpdir, "pemk_absent_battle_data_#{Process.pid}.json")
    File.delete(path) if File.exist?(path)
    bd = PEMK::BattleData.new(path)
    refute bd.loaded?
    assert bd.empty?
    assert bd.summary.start_with?("absent")
    assert_nil bd.species("BULBASAUR")               # accessors are safe on an empty model
  end

  def test_wrong_schema_version_is_a_boot_error
    e = assert_raises(RuntimeError) { PEMK::BattleData.new(write_json(FIX.merge("schema_version" => 99))) }
    assert_includes e.message, "schema_version"
  end

  def test_species_not_an_object_is_a_boot_error
    e = assert_raises(RuntimeError) { PEMK::BattleData.new(write_json(FIX.merge("species" => []))) }
    assert_includes e.message, "'species' is not an object"
  end

  def test_unparseable_json_is_a_boot_error
    e = assert_raises(RuntimeError) { PEMK::BattleData.new(write_json("{ not valid json")) }
    assert_includes e.message, "not valid JSON"
  end
end
