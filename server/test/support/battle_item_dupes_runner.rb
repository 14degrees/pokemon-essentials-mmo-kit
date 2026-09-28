# frozen_string_literal: true

# Subprocess body for battle_item_dupes_plugin_test.rb: boot the headless engine (the
# real battle code from Data/Scripts), load the PEMK fix, and play Trick and Bestow
# onto a foe. Prints one JSON line LAST: the items the player owns after each battle.

server_root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(server_root, "lib"))
$LOAD_PATH.unshift(File.expand_path("../protocol", server_root))

require "json"
require_relative "../../harness/harness"

game_root = ENV["PEMK_GAME_ROOT"] || File.expand_path("..", server_root)
PEMK::Harness.boot!(game_root: game_root)

module PEMK
  module Config
    ENGINE_DUPE_FIXES = ENV["PEMK_DUPE_FIX"] != "off"
  end

  def self.log(_msg); end
end
load File.join(game_root, "Plugins", "PEMK", "005_Battle", "010_ItemDupes.rb")

# The player's Pokemon (holding +held+) uses +move_id+ on a foe holding +foe_item+.
# A wild foe is then caught: it joins the party with what it holds, as the engine's
# storage step records it. The battle ends with the engine's own restore of each party
# member's item. -> { item => count } over the player's Pokemon.
def play(move_id, held:, foe_item: nil, wild: true)
  trainer = Player.new("T", GameData::TrainerType.keys.first)
  $player = trainer
  mine = Pokemon.new(:ABRA, 30, trainer)
  mine.item = held
  foe = Pokemon.new(:RATTATA, 5, wild ? nil : trainer)
  foe.item = foe_item
  opponent = wild ? nil : [NPCTrainer.new("F", GameData::TrainerType.keys.first)]
  battle = Battle.new(Battle::DebugSceneNoVisuals.new(false), [mine], [foe], [trainer], opponent)
  battle.pbCreateBattler(0, mine, 0)
  battle.pbCreateBattler(1, foe, 0)
  move = Battle::Move.from_pokemon_move(battle, Pokemon::Move.new(move_id))
  move.pbEffectAgainstTarget(battle.battlers[0], battle.battlers[1])
  party = [mine]
  if wild
    party << foe
    battle.initialItems[0][1] = foe.item_id
  end
  party.each_with_index { |pk, i| pk.item = battle.initialItems[0][i] }
  party.filter_map(&:item_id).tally.transform_keys(&:to_s)
end

out = {
  "trick_wild"      => play(:TRICK, held: :LEFTOVERS),
  "trick_wild_swap" => play(:TRICK, held: :LEFTOVERS, foe_item: :ORANBERRY),
  "bestow_wild"     => play(:BESTOW, held: :LEFTOVERS),
  "trick_trainer"   => play(:TRICK, held: :LEFTOVERS, foe_item: :ORANBERRY, wild: false)
}
puts JSON.generate(out)
