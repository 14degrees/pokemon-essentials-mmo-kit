# frozen_string_literal: true

# Item authority E4 (PEMK_ITEM_AUTHORITY=on, every gate on): an item no source explained
# is taken back. A Poke Ball bought in Cedolan stays; an X Attack added the way a memory
# edit would is owed once its grace is over (10 s here), and the game gives it back on
# its own - the server's correction, applied on a free frame - leaving nothing owed.
Autotest.scenario "an item from nowhere is taken back, a purchase stays",
                  flags: { PEMK_ITEM_AUTHORITY: "on", PEMK_PICKUP_ENFORCE: "on", PEMK_GIFT_ENFORCE: "on",
                           PEMK_SHOP_ENFORCE: "on", PEMK_ITEM_GRACE_SEC: "10" },
                  budget: 360 do |s|
  a = s.player(:a)
  a.new_game("Warden")
  id = s.account_id(a)
  a.fast!
  s.check("the server enforces") { s.server.grep(/item enforcement ON/).any? }

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

  a.ap!("add_item XATTACK 1")              # the raw verb: no credit from the harness
  s.check("the X Attack is taken back") do
    s.wait_for("the correction lands", seconds: 90) { a.get_item!("XATTACK")["quantity"].zero? }
  end
  s.check("the server saw it applied, and owes nothing") do
    s.wait_for("the ledger settles", seconds: 20) do
      s.server.grep(/account #{id} applied correction/).any? && s.unexplained_items(a).empty?
    end
  end
  s.check("the Poke Ball stays") { a.get_item!("POKEBALL")["quantity"] == 1 }
  s.check("the verdict was logged") { s.server.grep(/account #{id} UNEXPLAINED \+1 XATTACK.*taken back/).any? }
end
