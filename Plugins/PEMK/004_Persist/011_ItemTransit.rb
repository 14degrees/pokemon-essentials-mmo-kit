#===============================================================================
# PEMK :: ItemTransit  (client side — an item never counted in two places)
#-------------------------------------------------------------------------------
# The engine moves some items in two steps with a message in between: taking a held
# item adds it to the bag, says "Received the X", and only then clears the Pokemon;
# the box screen's "Take" and the mailbox's "Move to Bag" do the same. The sync tick
# runs inside that message, and so does the save written when the window closes, so
# either could record the item twice - in the bag and still on the Pokemon - and a
# relaunch would hand both back.
#
# Those moves now run under Inventory.atomic: no bag snapshot leaves while it is held
# (Sync keeps it back), and the closing save is not re-serialized from it (the last
# good save is pushed instead). The box screen counts as a move too, since it can hold
# a Pokemon in its "hand", out of every box.
#
# The engine also duplicates on its own: swapping a held item for Mail, then cancelling
# the letter, puts the old item in the bag while the Pokemon keeps holding it. That is
# undone here.
#===============================================================================
module PEMK
  module Inventory
    @atomic = 0

    # Run +blk+ as one move of items between stores. Nests.
    def self.atomic
      @atomic += 1
      yield
    ensure
      @atomic -= 1
    end

    def self.atomic?
      @atomic.positive? || ($game_temp && $game_temp.in_storage ? true : false)
    rescue StandardError
      false
    end
  end
end

if defined?(pbTakeItemFromPokemon) && !defined?(pemk_orig_pbTakeItemFromPokemon)
  alias pemk_orig_pbTakeItemFromPokemon pbTakeItemFromPokemon
  def pbTakeItemFromPokemon(pkmn, scene)
    PEMK::Inventory.atomic { pemk_orig_pbTakeItemFromPokemon(pkmn, scene) }
  end
end

if defined?(pbGiveItemToPokemon) && !defined?(pemk_orig_pbGiveItemToPokemon)
  alias pemk_orig_pbGiveItemToPokemon pbGiveItemToPokemon
  def pbGiveItemToPokemon(item, pkmn, scene, pkmnid = 0)
    held   = (pkmn.item_id rescue nil)
    before = held && $bag ? $bag.quantity(held) : 0
    ret = PEMK::Inventory.atomic { pemk_orig_pbGiveItemToPokemon(item, pkmn, scene, pkmnid) }
    # The engine's cancelled Mail swap: the old item went to the bag and stayed held.
    if !ret && held && (pkmn.item_id rescue nil) == held && $bag && $bag.quantity(held) > before
      $bag.remove(held, $bag.quantity(held) - before)
      PEMK.log("inv: a cancelled Mail swap left #{held} held and in the bag -> taken back")
    end
    ret
  end
end

if defined?(pbPCMailbox) && !defined?(pemk_orig_pbPCMailbox)
  alias pemk_orig_pbPCMailbox pbPCMailbox
  def pbPCMailbox
    PEMK::Inventory.atomic { pemk_orig_pbPCMailbox }
  end
end

if defined?(PokemonStorageScreen) && PokemonStorageScreen.method_defined?(:pbItem) &&
   !PokemonStorageScreen.method_defined?(:pemk_orig_pbItem)
  class PokemonStorageScreen
    alias_method :pemk_orig_pbItem, :pbItem
    def pbItem(selected, heldpoke)
      PEMK::Inventory.atomic { pemk_orig_pbItem(selected, heldpoke) }
    end
  end
end
