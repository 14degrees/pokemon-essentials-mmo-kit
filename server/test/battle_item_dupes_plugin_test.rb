require "minitest/autorun"
require "json"
require "rbconfig"

# An engine dupe: Trick or Bestow moved the user's held item onto a wild Pokemon, the
# end of the battle gave the user its item back, and catching the wild Pokemon kept a
# second one. Played on the real battle code (the headless harness, in a subprocess).
class BattleItemDupesPluginTest < Minitest::Test
  SERVER_ROOT = File.expand_path("..", __dir__)
  RUNNER      = File.join(SERVER_ROOT, "test", "support", "battle_item_dupes_runner.rb")

  def play(fix)
    game_root = ENV["PEMK_GAME_ROOT"] || File.expand_path("..", SERVER_ROOT)
    unless File.exist?(File.join(game_root, "Data", "types.dat"))
      skip "game Data/*.dat not compiled (launch the game once) - engine test skipped"
    end

    out = IO.popen({ "PEMK_DUPE_FIX" => fix }, [RbConfig.ruby, "-W0", RUNNER], err: %i[child out], &:read)
    assert $?.success?, "runner failed:\n#{out}"
    JSON.parse(out.lines.last)
  end

  def test_an_item_moved_onto_a_wild_pokemon_is_not_given_back
    r = play("on")
    assert_equal({ "LEFTOVERS" => 1 }, r["trick_wild"])
    assert_equal({ "LEFTOVERS" => 1, "ORANBERRY" => 1 }, r["trick_wild_swap"], "the swap stands")
    assert_equal({ "LEFTOVERS" => 1 }, r["bestow_wild"])
  end

  def test_a_trainer_battle_still_gives_the_item_back
    assert_equal({ "LEFTOVERS" => 1 }, play("on")["trick_trainer"])
  end

  # The kill switch: the engine as it was, and the dupe this fixes.
  def test_the_engine_duplicated_the_item
    r = play("off")
    assert_equal({ "LEFTOVERS" => 2 }, r["trick_wild"])
    assert_equal({ "LEFTOVERS" => 2 }, r["bestow_wild"])
  end
end
