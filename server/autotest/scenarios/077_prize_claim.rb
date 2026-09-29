# frozen_string_literal: true

# Money authority M1a: a trainer battle's prize is claimed where the engine pays it, and
# judged in shadow against the exports. Camper Liam is placed in the Cedolan Gym, the
# player stands there, the battle was never paid for, and the amount is his strongest
# Pokemon's level times his type's base money: the claim is judged paid, for exactly what
# the engine paid, and the money frame that follows seals it. Nothing moves on the
# server's say in shadow.
Autotest.scenario "a trainer's prize is claimed and judged", flags: { PEMK_MONEY_AUTHORITY: "shadow" },
                                                            budget: 360 do |s|
  a = s.player(:a)
  a.new_game("Claimer")
  id = s.account_id(a)
  a.fast!
  a.add_pokemon!("WARTORTLE", 30)
  a.warp!(10, 6, 14)                       # the Cedolan Gym's entrance
  a.wait_until!("idle within 10", timeout: 20)
  before = a.state.dig("trainer", "money")

  a.talk_to(4, timeout: 60)                # Camper Liam, unless he spots the player first
  a.converse
  s.check("Liam's battle started") { a.in_battle?(10) }
  a.fight_battle
  a.converse
  prize = a.state.dig("trainer", "money") - before
  claim = -> { s.db[:money_claims].where(account_id: id).first }
  s.wait_for("the claim reaches the server", seconds: 20) { claim.call }

  s.check("the engine paid a prize") { prize.positive? }
  s.check("the claim names Liam where he stands") { claim.call[:trainers].to_a == [["CAMPER", "Liam", 0, 10, 4]] }
  s.check("it is judged paid, for what the engine paid") do
    claim.call.values_at(:verdict, :accepted, :amount) == ["paid", prize, prize]
  end
  s.check("nothing refused or suspect") { s.server.grep(/money: account #{id} (WOULD-REFUSE|SUSPECT)/).empty? }
  s.check("the money frame sealed it") { s.wait_for("the seal", seconds: 20) { claim.call[:sealed_at] } }
  s.check("the shadow balance explains every coin, the starting money too") do
    s.server.grep(/money: account #{id} (UNEXPLAINED|BOUGHT-UNEXPLAINED)/).empty?
  end
end
