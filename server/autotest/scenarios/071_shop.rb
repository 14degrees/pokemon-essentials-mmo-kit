# frozen_string_literal: true

# Item authority E3: with PEMK_SHOP_ENFORCE on, a Mart purchase is made by the server.
# The Poke Ball clerk in the Cedolan department store sells one at the price the world
# and battle exports give; the server takes the money from its ledger, and the game
# shows the balance the server settled on. The money is the new game's own: the
# starting money reaches the ledger at login (it used to stay in the save, and a gated
# Mart refused the first purchase).
Autotest.scenario "a Mart purchase is made by the server", flags: { PEMK_SHOP_ENFORCE: "on" }, budget: 300 do |s|
  a = s.player(:a)
  a.new_game("Buyer")
  id = s.account_id(a)
  a.fast!
  start = a.state.dig("trainer", "money")
  ledger = -> { s.db[:economy_balances].where(account_id: id, field: "money").get(:balance) }
  s.check("the new game has starting money") { start.to_i >= 200 }
  s.wait_for("the server has the starting money", seconds: 15) { ledger.call == start }
  a.warp!(15, 3, 8)                        # across the counter from the Poke Ball clerk
  a.wait_until!("idle within 10", timeout: 20)

  a.face!("LEFT")
  a.interact!
  a.wait_until!("menu within 10", timeout: 15)
  a.choose!("I'm here to buy")
  a.wait_until!("menu within 10", timeout: 15)
  a.choose!("0")                           # the first in stock: Poke Balls
  a.press!("USE")                          # how many? one
  a.wait_until!("menu within 10", timeout: 15)
  a.choose!("Yes")                         # "It'll be $200. All right?" - the server buys
  a.wait(1)
  a.press!("USE")                          # "Here you are! Thank you!" (the shop's own box)
  a.wait_until!("menu within 10", timeout: 15)
  a.press!("BACK")                         # out of the stock list
  a.converse("No, thanks")

  s.check("the Poke Ball reached the bag") { a.get_item!("POKEBALL")["quantity"] == 1 }
  s.check("the server took $200 from its ledger") { ledger.call == start - 200 }
  s.check("the game shows the server's balance") { a.state.dig("trainer", "money") == start - 200 }
  s.check("the ledger says why") do
    s.db[:economy_ledger].where(account_id: id, reason: "shop:buy:POKEBALLx1").count == 1
  end
  s.check("nothing was refused") { s.server.grep(/shop: account #{id} (WOULD-)?DENY/).empty? }
end
