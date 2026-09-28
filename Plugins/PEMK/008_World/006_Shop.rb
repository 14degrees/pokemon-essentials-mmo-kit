#===============================================================================
# PEMK :: Shop  (client side — item authority E3: purchases and sales the server makes)
#-------------------------------------------------------------------------------
# A Mart is the game's main source of items, and until now the client decided alone:
# it added what it bought and took the money off itself, and a sale turned any item in
# the bag - made up or not - into money.
#
# With the server's shop gate on (PEMK_SHOP_ENFORCE, advertised as shop_gate at login),
# each purchase and each sale is asked first (:shop_req) and waits a bounded time. The
# server checks the clerk's stock and the price against the world export, the money
# against its ledger and, for a sale, the item against its record of the bag; it then
# moves the money itself and answers with the new balance, which the client adopts.
#   grant   the vanilla purchase or sale goes on; the money is the server's
#   deny    nothing changes, with a word from the clerk
#   silence the same as a deny: nothing is bought or sold unasked
# The economy channel is flushed before asking, so the server judges the money the
# client has, and no other money change leaves while the answer is awaited. The
# Battle Point exchange works the same way with BP (bp_shop_gate at login).
#
# A deal whose answer misses the wait is in doubt when the server records deals
# (shop_recheck at login): the server may already have moved the money and the items.
# The deal stays in the save, and the client asks how it ended by its nonce, at once and
# after a reconnect. Meanwhile no money or bag frame leaves and no other deal starts, so
# the ledger and the record still hold the deal when its answer comes; a late grant is
# then applied on a free frame. A fresh login restores the money and the bag from the
# server, which settles every doubt.
#
# The three screens below are the engine's own (v21.1), with the ask inserted right
# before the purchase or the sale is applied; with the gate off, the engine's run.
#===============================================================================
class PokemonGlobalMetadata
  attr_accessor :pemk_deals_doubt   # [[nonce, op, item, quantity, bp], ...] deals whose outcome is unknown
end

module PEMK
  module Shop
    RECHECK_AFTER = 10.0   # seconds before a deal in doubt is asked about again
    RECHECK_MAX   = 12     # asked this often with no answer: the doubt is dropped (logged)

    @gate    = false
    @bp_gate = false
    @recheck = false        # the server records deals: one given up on can be asked about
    @seq     = 0
    @inbox   = {}
    @late    = {}           # nonce => the answer to a deal in doubt, applied on a free frame
    @asked   = {}           # nonce => when this connection last asked about it (monotonic)
    @tries   = Hash.new(0)  # nonce => how often it was asked about
    @rng     = nil

    module_function

    def reset
      @gate    = false
      @bp_gate = false
      @recheck = false
      @inbox   = {}
      @asked   = {}
    end

    def adopt_gate(v)
      @gate = (v == true)
    end

    def adopt_recheck(v)
      @recheck = (v == true)
    end

    # The Battle Point exchange has its own word: a server from before it knew only the
    # Mart, and would take a BP purchase for a Mart one and refuse it.
    def adopt_bp_gate(v)
      @bp_gate = (v == true)
    end

    # Once the server said it makes the deals, a shop never deals without it: with the
    # link down the ask gets no answer and the clerk refuses, instead of the engine's
    # shop running unasked (a dropped link would otherwise buy items no one credited).
    def gate?
      @gate == true
    end

    def bp_gate?
      @bp_gate == true
    end

    def online?
      return false unless PEMK.enabled? && PEMK.self_id

      c = PEMK.client
      !!(c && c.connected?)
    rescue StandardError
      false
    end

    # Dispatch routes :shop_grant / :shop_deny here. The answer to a deal in doubt (its
    # own, late, or a recheck's) waits for a free frame; the others go to the ask waiting.
    def on_reply(msg)
      n = msg && msg[:nonce]
      if n.is_a?(Integer) && doubts.any? { |d| d[0] == n }
        @late[n] ||= msg
        return
      end
      s = msg && msg[:seq]
      @inbox[s] = msg if s.is_a?(Integer)
    end

    # -> reply Hash (:shop_grant / :shop_deny) | nil (no answer). +op+ :buy | :sell.
    def ask(op, item, qty, unit_price, bp: false)
      return { :type => :shop_deny, :reason => "doubt" } if holding?

      ctx = (PEMK::GiftClaim.context rescue nil)
      (PEMK::Sync.flush_primitives rescue nil)   # the money the server judges is ours
      @inbox.clear
      @seq += 1
      nonce = @recheck ? new_nonce : nil
      msg = { :type => :shop_req, :op => op, :item => item.to_s, :quantity => qty, :unit_price => unit_price,
              :bp => bp, :map => ctx && ctx[0], :event => ctx && ctx[1], :seq => @seq }
      msg[:nonce] = nonce if nonce
      PEMK.send_message(msg)
      reply = wait_for(@seq)
      doubt([nonce, op, item.to_s, qty, bp]) if reply.nil? && nonce
      reply
    rescue StandardError => e
      PEMK.log("shop: ask error #{e.class}: #{e.message}")
      nil
    end

    def wait_for(seq)
      deadline = mono + Config::SHOP_TIMEOUT
      loop do
        r = @inbox.delete(seq)
        return r if r
        return nil if mono >= deadline || !online?

        Graphics.update
        Input.update
      end
    end

    # The money after the deal: the balance the server settled on when it made the deal
    # (gate on), else the vanilla change (shadow: the server only judged).
    def settle_money(reply, adapter, delta)
      value = reply[:balance]
      if value.is_a?(Integer)
        $player.money = value
      else
        adapter.setMoney(adapter.getMoney + delta)
      end
    end

    # The BP after the exchange, the same way.
    def settle_bp(reply, adapter, delta)
      value = reply[:balance]
      if value.is_a?(Integer)
        $player.battle_points = value
      else
        adapter.setBP(adapter.getBP + delta)
      end
    end

    def refusal(reply)
      case reply ? reply[:reason].to_s : ""   # no answer at all: the link
      when "money"    then _INTL("You don't have enough money.")
      when "bp"       then _INTL("I'm sorry, you don't have enough BP.")
      when "not_sold" then _INTL("Sorry, that isn't something I sell.")
      when "not_held" then _INTL("You don't seem to have that.")
      when "doubt"    then _INTL("I'm still waiting to hear back about your last order. Please try again in a moment.")
      when ""         then _INTL("The shop can't reach the server right now. Please try again.")
      else _INTL("Sorry, I can't do that right now.")
      end
    end

    # --- deals in doubt ----------------------------------------------------------------

    def doubts
      g = $PokemonGlobal
      return [] unless g && g.respond_to?(:pemk_deals_doubt)

      list = g.pemk_deals_doubt
      list = g.pemk_deals_doubt = [] unless list.is_a?(Array)
      list.select! { |d| doubt_entry?(d) }
      list
    end

    def doubt_entry?(d)
      d.is_a?(Array) && d.length == 5 && d[0].is_a?(Integer) && %i[buy sell].include?(d[1]) &&
        d[2].is_a?(String) && d[3].is_a?(Integer) && [true, false].include?(d[4])
    end

    # While a deal is in doubt no money or bag frame leaves (Sync) and no other deal
    # starts: the server's ledger and record still hold the deal when its answer comes.
    def holding?
      @recheck && !doubts.empty?
    end

    def doubt(entry)
      doubts << entry
      PEMK.log("shop: deal #{entry[0]} (#{entry[1]} #{entry[2]} x#{entry[3]}) in doubt: asking the server")
      recheck(entry[0])
    end

    def recheck(nonce)
      @seq += 1
      PEMK.send_message(:type => :shop_req, :recheck => true, :nonce => nonce, :seq => @seq)
      @asked[nonce] = mono
      @tries[nonce] += 1
    end

    # A fresh login restored the money and the bag from the server, which holds every
    # deal it made: nothing is left in doubt.
    def settled_by_login
      doubts.clear
      @late  = {}
      @asked = {}
      @tries = Hash.new(0)
    end

    # Per frame: asks again about each deal in doubt, and applies an answer on a free frame.
    def tick
      list = doubts
      return if list.empty? || !@recheck

      now = mono
      list.dup.each do |d|
        next if @late.key?(d[0])

        if @tries[d[0]] >= RECHECK_MAX
          forget(d)
          PEMK.log("shop: deal #{d[0]} dropped: #{RECHECK_MAX} asks went unanswered")
        elsif online? && now - (@asked[d[0]] || -1.0e18) >= RECHECK_AFTER
          recheck(d[0])
        end
      end
      return unless free_frame?

      d = list.find { |e| @late.key?(e[0]) }
      settle(d, @late[d[0]]) if d
    rescue StandardError => e
      PEMK.log("shop: tick error #{e.class}: #{e.message}")
    end

    def settle(d, reply)
      forget(d)   # before any message: its own frames must not settle it again
      nonce, op, item, qty, bp = d
      unless reply[:type] == :shop_grant
        PEMK.log("shop: deal #{nonce} (#{op} #{item} x#{qty}) never went through (#{reply[:reason]})")
        return
      end
      PEMK.log("shop: deal #{nonce} (#{op} #{item} x#{qty}) went through late")
      apply_late(op, item.to_sym, qty, bp, reply[:delta].to_i, reply[:bonus].to_i)
    end

    def forget(d)
      doubts.reject! { |e| e[0] == d[0] }
      @late.delete(d[0])
      @asked.delete(d[0])
      @tries.delete(d[0])
    end

    # A deal the server made after the client stopped waiting: its items into or out of
    # the bag, its money, and a word - as the clerk would have, a moment late.
    def apply_late(op, item, qty, bp, delta, bonus)
      if op == :buy
        store(item, qty)
        store(:PREMIERBALL, bonus) if bonus.positive?
      else
        PEMK::ItemCorrect.take(item, qty)
      end
      if bp
        $player.battle_points += delta
      else
        $player.money += delta
      end
      (PEMK::Inventory.mark rescue nil)
      name = (GameData::Item.get(item).name rescue item.to_s)
      if op == :buy
        pbMessage(_INTL("The shop confirmed your purchase: {1} x{2}.", name, qty))
      else
        pbMessage(_INTL("The shop confirmed your sale: {1} x{2}.", name, qty))
      end
    end

    # Into the bag, or the PC's item storage when the bag has no room left.
    def store(item, qty)
      return if $bag.add(item, qty)

      pc = $PokemonGlobal && $PokemonGlobal.pcItemStorage
      return if pc && pc.add(item, qty)

      PEMK.log("shop: no room for #{qty} #{item} bought late")
    end

    def free_frame?
      $player && $scene.is_a?(Scene_Map) && $game_temp && !$game_temp.in_battle &&
        !$game_temp.in_menu && !$game_temp.message_window_showing &&
        !(pbMapInterpreterRunning? rescue true) && !(PEMK::Inventory.atomic? rescue true) &&
        !(PEMK::Trade.busy? rescue false)
    rescue StandardError
      false
    end

    def new_nonce
      (@rng ||= Random.new).rand(1...(1 << 62))
    end

    def mono
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rescue StandardError
      0.0
    end
  end
end

if defined?(PokemonMartScreen) && !PokemonMartScreen.method_defined?(:pemk_orig_pbBuyScreen)
  class PokemonMartScreen
    alias_method :pemk_orig_pbBuyScreen, :pbBuyScreen
    alias_method :pemk_orig_pbSellScreen, :pbSellScreen

    def pbBuyScreen
      return pemk_orig_pbBuyScreen unless PEMK::Shop.gate?

      @scene.pbStartBuyScene(@stock, @adapter)
      item = nil
      loop do
        item = @scene.pbChooseBuyItem
        break if !item
        quantity       = 0
        itemname       = @adapter.getName(item)
        itemnameplural = @adapter.getNamePlural(item)
        price = @adapter.getPrice(item)
        unit  = price
        if @adapter.getMoney < price
          pbDisplayPaused(_INTL("You don't have enough money."))
          next
        end
        if GameData::Item.get(item).is_important?
          next if !pbConfirm(_INTL("So you want the {1}?\nIt'll be ${2}. All right?",
                                   itemname, price.to_s_formatted))
          quantity = 1
        else
          maxafford = (price <= 0) ? Settings::BAG_MAX_PER_SLOT : @adapter.getMoney / price
          maxafford = Settings::BAG_MAX_PER_SLOT if maxafford > Settings::BAG_MAX_PER_SLOT
          quantity = @scene.pbChooseNumber(
            _INTL("So how many {1}?", itemnameplural), item, maxafford
          )
          next if quantity == 0
          price *= quantity
          if quantity > 1
            next if !pbConfirm(_INTL("So you want {1} {2}?\nThey'll be ${3}. All right?",
                                     quantity, itemnameplural, price.to_s_formatted))
          elsif quantity > 0
            next if !pbConfirm(_INTL("So you want {1} {2}?\nIt'll be ${3}. All right?",
                                     quantity, itemname, price.to_s_formatted))
          end
        end
        if @adapter.getMoney < price
          pbDisplayPaused(_INTL("You don't have enough money."))
          next
        end
        # Item authority E3: the server makes the purchase.
        if !$bag.can_add?(item, quantity)
          pbDisplayPaused(_INTL("You have no room in your Bag."))
          next
        end
        reply = PEMK::Shop.ask(:buy, item, quantity, unit)
        unless reply && reply[:type] == :shop_grant
          pbDisplayPaused(PEMK::Shop.refusal(reply))
          next
        end
        added = 0
        quantity.times do
          break if !@adapter.addItem(item)
          added += 1
        end
        $stats.money_spent_at_marts += price
        $stats.mart_items_bought += quantity
        PEMK::Shop.settle_money(reply, @adapter, -price)
        @stock.delete_if { |itm| GameData::Item.get(itm).is_important? && $bag.has?(itm) }
        pbDisplayPaused(_INTL("Here you are! Thank you!")) { pbSEPlay("Mart buy item") }
        if quantity >= 10 && GameData::Item.exists?(:PREMIERBALL)
          if Settings::MORE_BONUS_PREMIER_BALLS && GameData::Item.get(item).is_poke_ball?
            premier_balls_added = 0
            (quantity / 10).times do
              break if !@adapter.addItem(:PREMIERBALL)
              premier_balls_added += 1
            end
            ball_name = GameData::Item.get(:PREMIERBALL).portion_name
            ball_name = GameData::Item.get(:PREMIERBALL).portion_name_plural if premier_balls_added > 1
            $stats.premier_balls_earned += premier_balls_added
            pbDisplayPaused(_INTL("And have {1} {2} on the house!", premier_balls_added, ball_name))
          elsif !Settings::MORE_BONUS_PREMIER_BALLS && GameData::Item.get(item) == :POKEBALL
            if @adapter.addItem(:PREMIERBALL)
              ball_name = GameData::Item.get(:PREMIERBALL).name
              $stats.premier_balls_earned += 1
              pbDisplayPaused(_INTL("And have 1 {1} on the house!", ball_name))
            end
          end
        end
      end
      @scene.pbEndBuyScene
    end

    def pbSellScreen
      return pemk_orig_pbSellScreen unless PEMK::Shop.gate?

      item = @scene.pbStartSellScene(@adapter.getInventory, @adapter)
      loop do
        item = @scene.pbChooseSellItem
        break if !item
        itemname       = @adapter.getName(item)
        itemnameplural = @adapter.getNamePlural(item)
        if !@adapter.canSell?(item)
          pbDisplayPaused(_INTL("Oh, no. I can't buy {1}.", itemnameplural))
          next
        end
        price = @adapter.getPrice(item, true)
        unit  = price
        qty = @adapter.getQuantity(item)
        next if qty == 0
        @scene.pbShowMoney
        if qty > 1
          qty = @scene.pbChooseNumber(
            _INTL("How many {1} would you like to sell?", itemnameplural), item, qty
          )
        end
        if qty == 0
          @scene.pbHideMoney
          next
        end
        price *= qty
        if pbConfirm(_INTL("I can pay ${1}.\nWould that be OK?", price.to_s_formatted))
          # Item authority E3: the server makes the sale.
          reply = PEMK::Shop.ask(:sell, item, qty, unit)
          if reply && reply[:type] == :shop_grant
            old_money = @adapter.getMoney
            qty.times { @adapter.removeItem(item) }
            PEMK::Shop.settle_money(reply, @adapter, price)
            $stats.money_earned_at_marts += @adapter.getMoney - old_money
            sold_item_name = (qty > 1) ? itemnameplural : itemname
            pbDisplayPaused(_INTL("You turned over the {1} and got ${2}.",
                                  sold_item_name, price.to_s_formatted)) { pbSEPlay("Mart buy item") }
            @scene.pbRefresh
          else
            pbDisplayPaused(PEMK::Shop.refusal(reply))
          end
        end
        @scene.pbHideMoney
      end
      @scene.pbEndSellScene
    end
  end
end

if defined?(BattlePointShopScreen) && !BattlePointShopScreen.method_defined?(:pemk_orig_pbBuyScreen)
  class BattlePointShopScreen
    alias_method :pemk_orig_pbBuyScreen, :pbBuyScreen

    def pbBuyScreen
      return pemk_orig_pbBuyScreen unless PEMK::Shop.bp_gate?

      @scene.pbStartScene(@stock, @adapter)
      item = nil
      loop do
        item = @scene.pbChooseItem
        break if !item
        quantity       = 0
        itemname       = @adapter.getName(item)
        itemnameplural = @adapter.getNamePlural(item)
        price = @adapter.getPrice(item)
        unit  = price
        if @adapter.getBP < price
          pbDisplayPaused(_INTL("You don't have enough BP."))
          next
        end
        if GameData::Item.get(item).is_important?
          next if !pbConfirm(_INTL("You would like the {1}?\nThat will be {2} BP.",
                                   itemname, price.to_s_formatted))
          quantity = 1
        else
          maxafford = (price <= 0) ? Settings::BAG_MAX_PER_SLOT : @adapter.getBP / price
          maxafford = Settings::BAG_MAX_PER_SLOT if maxafford > Settings::BAG_MAX_PER_SLOT
          quantity = @scene.pbChooseNumber(
            _INTL("How many {1} would you like?", itemnameplural), item, maxafford
          )
          next if quantity == 0
          price *= quantity
          if quantity > 1
            next if !pbConfirm(_INTL("You would like {1} {2}?\nThey'll be {3} BP.",
                                     quantity, itemnameplural, price.to_s_formatted))
          elsif quantity > 0
            next if !pbConfirm(_INTL("So you want {1} {2}?\nIt'll be {3} BP.",
                                     quantity, itemname, price.to_s_formatted))
          end
        end
        if @adapter.getBP < price
          pbDisplayPaused(_INTL("I'm sorry, you don't have enough BP."))
          next
        end
        # Item authority E3: the server makes the exchange.
        if !$bag.can_add?(item, quantity)
          pbDisplayPaused(_INTL("You have no room in your Bag."))
          next
        end
        reply = PEMK::Shop.ask(:buy, item, quantity, unit, bp: true)
        unless reply && reply[:type] == :shop_grant
          pbDisplayPaused(PEMK::Shop.refusal(reply))
          next
        end
        quantity.times { break if !@adapter.addItem(item) }
        $stats.battle_points_spent += price
        $stats.mart_items_bought += quantity
        PEMK::Shop.settle_bp(reply, @adapter, -price)
        @stock.delete_if { |itm| GameData::Item.get(itm).is_important? && $bag.has?(itm) }
        pbDisplayPaused(_INTL("Here you are! Thank you!")) { pbSEPlay("Mart buy item") }
      end
      @scene.pbEndScene
    end
  end
end

EventHandlers.add(:on_frame_update, :pemk_shop_doubt, proc { PEMK::Shop.tick }) if defined?(EventHandlers)
