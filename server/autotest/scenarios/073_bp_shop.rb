# frozen_string_literal: true

# Item authority E3, the Battle Point exchange: with PEMK_SHOP_ENFORCE on, a BP purchase
# is made by the server. The first clerk of the Battle Frontier Mart trades a Protein
# for 1 BP; the server takes the BP from its ledger, and the game shows the balance the
# server settled on.
Autotest.scenario "a Battle Point exchange is made by the server", flags: { PEMK_SHOP_ENFORCE: "on" }, budget: 300 do |s|
  a = s.player(:a)
  a.new_game("Trader")
  id = s.account_id(a)
  a.fast!
  a.bp!(5)
  ledger = -> { s.db[:economy_balances].where(account_id: id, field: "battle_points").get(:balance) }
  s.wait_for("the server has the BP", seconds: 15) { ledger.call == 5 }

  a.warp!(54, 4, 6)                        # the Battle Frontier Mart, this side of the counter
  a.wait_until!("idle within 10", timeout: 20)
  a.talk_to!(5, timeout: 60)               # the clerk at (8,6), across the counter
  a.wait_until!("message within 10", timeout: 15)
  a.dismiss!                               # "Welcome to the Exchange Service Corner!" and its sequel
  a.wait_until!("menu within 20", timeout: 30)   # the stock list
  a.choose!("0")                           # the first in stock: Protein
  a.press!("USE")                          # how many? one
  a.wait_until!("menu within 10", timeout: 15)
  a.choose!("Yes")                         # "So you want 1 Protein? It'll be 1 BP." - the server trades
  a.wait(1)
  a.press!("USE")                          # "Here you are! Thank you!"
  a.wait_until!("menu within 10", timeout: 15)
  a.press!("BACK")                         # out of the stock list
  a.wait_until!("message within 10", timeout: 15)   # "Thank you for visiting." once the list has closed
  a.converse

  s.check("the Protein reached the bag") { a.get_item!("PROTEIN")["quantity"] == 1 }
  s.check("the server took 1 BP from its ledger") { ledger.call == 4 }
  s.check("the game shows the server's BP") { a.state.dig("trainer", "battle_points") == 4 }
  s.check("the ledger says why") do
    s.db[:economy_ledger].where(account_id: id, reason: "bpshop:buy:PROTEINx1").count == 1
  end
  s.check("nothing was refused") { s.server.grep(/bpshop: account #{id} (WOULD-)?DENY/).empty? }
end
