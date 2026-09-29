# frozen_string_literal: true

# Item authority E3: Mart transactions made by the server at a clerk whose event sets its
# own prices. The Lerucean Town stall always sells its Silph Scope (a Key Item, $0 in the
# catalogue) at $5,000, and on Saturdays sells its Poke Balls cheaper - and so, by the
# engine's rule, buys them back at the sale price too. The server takes and pays what the
# stall's event can charge on that visit, never the catalogue's $0.
Autotest.scenario "a clerk that sets its prices is paid them", flags: { PEMK_SHOP_ENFORCE: "on" }, budget: 300 do |s|
  a = s.player(:a)
  a.new_game("Seller")
  id = s.account_id(a)
  a.fast!
  a.add_item!("GREATBALL", 1)
  ledger = -> { s.db[:economy_balances].where(account_id: id, field: "money").get(:balance) }
  held   = -> { (s.db[:inventory_snapshots].where(account_id: id).get(:bag) || {}).to_h["GREATBALL"].to_i }
  s.wait_for("the server has the Great Ball", seconds: 20) { held.call == 1 }
  a.money!(6000)                           # more than a new game starts with
  s.wait_for("the server has the money", seconds: 15) { ledger.call == 6000 }
  sell = Time.now.saturday? ? 450 : 300    # pbIsWeekday(0, 6): the stall's sale day

  a.warp!(23, 12, 23)                      # below the stall
  a.wait_until!("idle within 10", timeout: 20)
  a.talk_to!(7, timeout: 60)               # the stall's clerk at (12,21)
  a.wait_until!("menu within 10", timeout: 15)
  a.choose!("I'm here to buy")
  a.wait_until!("menu within 10", timeout: 15)
  a.choose!("0")                           # the first in stock: the Silph Scope
  a.wait_until!("menu within 10", timeout: 15)
  a.choose!("Yes")                         # "It'll be $5,000. All right?" - the server buys
  a.wait(1)
  a.press!("USE")                          # "Here you are! Thank you!"
  a.wait_until!("menu within 10", timeout: 15)
  a.press!("BACK")                         # out of the stock list
  a.wait_until!("menu within 10", timeout: 15)
  a.choose!("I'm here to sell")            # "Is there anything else I can do for you?"
  a.pick!("GREATBALL")                     # from the bag
  a.wait_until!("menu within 10", timeout: 15)
  a.choose!("Yes")                         # "I can pay $300. Would that be OK?" - the server buys
  a.wait(1)
  a.press!("USE")                          # "You turned over the Great Ball and got $300."
  a.pick!("cancel")                        # out of the bag
  a.wait_until!("menu within 10", timeout: 15)
  a.converse("No, thanks")

  s.check("the Silph Scope reached the bag") { a.get_item!("SILPHSCOPE")["quantity"] == 1 }
  s.check("the Great Ball was sold") { a.get_item!("GREATBALL")["quantity"].zero? }
  s.check("the server took the stall's $5,000 and paid the day's $#{sell}") { ledger.call == 1000 + sell }
  s.check("the ledger says why") do
    # With item authority on, the demo's Great Ball is a local tier (an event adds it by
    # itself): its sale is labelled so.
    [%w[shop:buy:SILPHSCOPEx1], %w[shop:sell:GREATBALLx1 shop:sell:local:GREATBALLx1]].all? do |why|
      s.db[:economy_ledger].where(account_id: id, reason: why).count == 1
    end
  end
  s.check("the ball left the server's record") { s.wait_for("the record", seconds: 10) { held.call.zero? } }
  s.check("nothing was refused") { s.server.grep(/shop: account #{id} (WOULD-)?DENY/).empty? }
end
