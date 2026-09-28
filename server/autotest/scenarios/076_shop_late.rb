# frozen_string_literal: true

# E3: a purchase answered after the clerk stopped waiting. The server holds the account's
# requests longer than the clerk waits: the clerk says it cannot reach the server, and
# the purchase is in doubt. The client asks how it ended and, once out of the Mart,
# applies it - the Poke Ball in the bag, paid once, the same on both sides. It used to
# drop the late answer: paid on the server, missing in the game.
Autotest.scenario "a purchase answered late is applied once", flags: { PEMK_SHOP_ENFORCE: "on" }, budget: 300 do |s|
  a = s.player(:a)
  a.new_game("Patient")
  id = s.account_id(a)
  a.fast!
  start = a.state.dig("trainer", "money")
  ledger = -> { s.db[:economy_balances].where(account_id: id, field: "money").get(:balance) }
  s.wait_for("the server has the starting money", seconds: 15) { ledger.call == start }
  a.warp!(15, 3, 8)                        # across the counter from the Poke Ball clerk
  a.wait_until!("idle within 10", timeout: 20)

  a.face!("LEFT")
  a.interact!
  a.wait_until!("menu within 10", timeout: 15)
  a.choose!("I'm here to buy")
  a.wait_until!("menu within 10", timeout: 15)
  a.choose!("0")                           # Poke Balls
  a.press!("USE")                          # how many? one
  a.wait_until!("menu within 10", timeout: 15)
  s.server.hold_account(id, 8)             # the answer comes after the clerk's five seconds
  a.choose!("Yes")                         # "It'll be $200. All right?"
  a.wait("7s")                             # the clerk waits five seconds
  a.press!("USE")                          # "The shop can't reach the server right now."
  a.wait_until!("menu within 10", timeout: 15)
  a.press!("BACK")                         # out of the stock list
  a.converse("No, thanks")                 # ... and the late purchase, once out of the Mart

  s.check("the Poke Ball reached the bag, once") { a.get_item!("POKEBALL")["quantity"] == 1 }
  s.check("the server took $200, once") { s.wait_for("the ledger", seconds: 15) { ledger.call == start - 200 } }
  s.check("the game shows the same balance") do
    s.wait_for("the balance", seconds: 10) { a.state.dig("trainer", "money") == start - 200 }
  end
  s.check("the ledger says why, once") do
    s.db[:economy_ledger].where(account_id: id, reason: "shop:buy:POKEBALLx1").count == 1
  end
  s.check("the server's record has the ball") do
    s.wait_for("the record", seconds: 10) do
      (s.db[:inventory_snapshots].where(account_id: id).get(:bag) || {}).to_h["POKEBALL"].to_i == 1
    end
  end
  s.check("the client applied it late") { a.log_tail(400).any? { |l| l.include?("went through late") } }
  s.check("nothing was refused") { s.server.grep(/shop: account #{id} (WOULD-)?DENY/).empty? }
end
