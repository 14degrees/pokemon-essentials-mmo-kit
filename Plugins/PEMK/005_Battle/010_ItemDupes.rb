#===============================================================================
# PEMK :: BattleItemDupes  (client side — an engine dupe the item authority found)
#-------------------------------------------------------------------------------
# Trick and Switcheroo swap held items with the target, and Bestow gives the user's
# away; the engine's own notes say both stand after a wild battle. It made them stand
# only when the user held nothing when the battle began: otherwise the end of the
# battle handed the user back the item it had moved onto the wild Pokemon, and
# catching that Pokemon kept a second one. Against a wild Pokemon, what the user holds
# after the move is now what it keeps. PEMK::Config::ENGINE_DUPE_FIXES = false puts the
# engine's behaviour back.
#===============================================================================
module PEMK
  module BattleItemDupes
    module_function

    # +user+ just moved its held item onto +target+.
    def settle(user, target)
      return unless PEMK::Config::ENGINE_DUPE_FIXES
      return unless target.wild? && !user.wild?

      user.setInitialItem(user.item)
    rescue StandardError => e
      (PEMK.log("battle: item settle error #{e.class}: #{e.message}") rescue nil)
    end
  end
end

if defined?(Battle::Move::UserTargetSwapItems) && defined?(Battle::Move::TargetTakesUserItem)
  [Battle::Move::UserTargetSwapItems, Battle::Move::TargetTakesUserItem].each do |klass|
    next if klass.method_defined?(:pemk_dupe_orig_effect)

    klass.class_eval do
      alias_method :pemk_dupe_orig_effect, :pbEffectAgainstTarget
      def pbEffectAgainstTarget(user, target)
        pemk_dupe_orig_effect(user, target)
        PEMK::BattleItemDupes.settle(user, target)
      end
    end
  end
end
