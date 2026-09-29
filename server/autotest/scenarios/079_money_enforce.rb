# frozen_string_literal: true

# Money authority M3 (PEMK_MONEY_AUTHORITY=on, every gate on): money rises only through
# the server's own transactions. A new account starts from the exported start money; Camper
# Liam's prize is paid by the server itself, and the game holds exactly that; money a
# memory edit adds is refused, and the game comes back to the server's balance on its own.
Autotest.scenario "the server pays a prize and refuses money from nowhere",
                  flags: { PEMK_MONEY_AUTHORITY: "on", PEMK_ITEM_AUTHORITY: "on", PEMK_PICKUP_ENFORCE: "on",
                           PEMK_GIFT_ENFORCE: "on", PEMK_SHOP_ENFORCE: "on", PEMK_BATTLE_ENFORCE_ENCOUNTERS: "on" },
                  budget: 420 do |s|
  a = s.player(:a)
  a.new_game("Payee")
  id = s.account_id(a)
  a.fast!
  s.check("the server enforces money") { s.server.grep(/money authority = on \(the server pays/).any? }
  ledger = -> { s.db[:economy_balances].where(account_id: id, field: "money").get(:balance) }
  money  = -> { a.state.dig("trainer", "money") }
  s.wait_for("the ledger has the start money", seconds: 15) { ledger.call }
  s.check("the start money is the server's, and the game holds it") { money.call == ledger.call }

  a.add_pokemon!("WARTORTLE", 30)
  a.warp!(10, 6, 14)                       # the Cedolan Gym's entrance
  a.wait_until!("idle within 10", timeout: 20)
  before = ledger.call
  a.talk_to(4, timeout: 60)                # Camper Liam, unless he spots the player first
  a.converse
  s.check("Liam's battle started") { a.in_battle?(10) }
  a.fight_battle
  a.converse
  claim = -> { s.db[:money_claims].where(account_id: id).first }
  s.wait_for("the claim is judged", seconds: 20) { claim.call }
  s.check("the server paid the prize itself") do
    s.wait_for("the payment", seconds: 10) { ledger.call == before + claim.call[:accepted] } &&
      claim.call[:credited] == claim.call[:accepted] && claim.call[:accepted].positive?
  end
  s.check("the game holds what the server paid") { s.wait_for("the game", seconds: 20) { money.call == ledger.call } }

  paid = ledger.call
  a.ap!("money #{paid + 5000}")            # a memory edit: no claim, no deal
  s.check("the server refused it") do
    s.wait_for("the refusal", seconds: 20) { s.server.grep(/money: account #{id} REFUSED a frame of #{paid + 5000}/).any? }
  end
  s.check("the game came back to the server's balance") { s.wait_for("the game", seconds: 20) { money.call == paid } }
  s.check("the ledger never moved") { ledger.call == paid }
end
