# frozen_string_literal: true

# Item authority E2 (PEMK_ITEM_AUTHORITY=shadow): every item the player gains must be
# explained by a source the server knows. The Great Ball on Route 1 (granted by the
# pickup gate) and a Poke Ball from the Cedolan Mart (bought by the server) leave nothing
# owed. A Master Ball added the way a memory edit would - no source at all - is owed.
Autotest.scenario "an item from nowhere is owed, a pickup and a purchase are not",
                  flags: { PEMK_ITEM_AUTHORITY: "shadow", PEMK_PICKUP_ENFORCE: "on", PEMK_SHOP_ENFORCE: "on" },
                  budget: 420 do |s|
  a = s.player(:a)
  a.new_game("Ledger")
  id = s.account_id(a)
  a.fast!

  a.enter!(3)                              # down the bedroom stairs
  a.wait_until!("idle within 10", timeout: 20)
  a.enter!(1)                              # out of the house
  a.wait_until!("map 2 within 10", timeout: 20)
  a.wait_until!("idle within 5", timeout: 15)
  a.walk_to!(14, 0, timeout: 60)
  a.cross("UP", 5)                         # Route 1
  a.talk_to!(11, timeout: 60)              # the Great Ball at (26,14)
  a.converse
  s.check("the Great Ball reached the bag") { a.get_item!("GREATBALL")["quantity"] == 1 }

  a.money!(5000)
  a.warp!(15, 3, 8)                        # across the counter from the Poke Ball clerk
  a.wait_until!("idle within 10", timeout: 20)
  s.wait_for("the server has the money", seconds: 15) do
    s.db[:economy_balances].where(account_id: id, field: "money").get(:balance) == 5000
  end
  a.face!("LEFT")
  a.interact!
  a.wait_until!("menu within 10", timeout: 15)
  a.choose!("I'm here to buy")
  a.wait_until!("menu within 10", timeout: 15)
  a.choose!("0")                           # Poke Balls
  a.press!("USE")                          # one
  a.wait_until!("menu within 10", timeout: 15)
  a.choose!("Yes")
  a.wait(1)
  a.press!("USE")                          # "Here you are! Thank you!"
  a.wait_until!("menu within 10", timeout: 15)
  a.press!("BACK")
  a.converse("No, thanks")
  s.check("the Poke Ball reached the bag") { a.get_item!("POKEBALL")["quantity"] == 1 }

  bag = -> { (s.db[:inventory_snapshots].where(account_id: id).get(:bag) || {}).to_h }
  s.wait_for("the server has seen both", seconds: 20) { bag.call["GREATBALL"] == 1 && bag.call["POKEBALL"] == 1 }
  s.check("nothing is owed for them", s.unexplained_items(a).inspect) do
    s.unexplained_items(a).none? { |item, _| %w[GREATBALL POKEBALL].include?(item) }
  end
  s.check("nothing else is owed either", s.unexplained_items(a).inspect) { s.unexplained_items(a).empty? }

  a.ap!("add_item MASTERBALL 1")           # the raw verb: no credit from the harness
  s.check("a Master Ball from nowhere is owed") do
    s.wait_for("the ledger owes it", seconds: 20) { s.unexplained_items(a) == [["MASTERBALL", 1]] }
  end
end
