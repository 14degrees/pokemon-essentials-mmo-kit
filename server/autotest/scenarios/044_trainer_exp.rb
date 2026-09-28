# frozen_string_literal: true

# With battle rewards bounded (PEMK_BATTLE_ENFORCE_REWARDS on), the EXP a trainer
# battle gives must be accounted for like a wild battle's: a level-up after beating
# Camper Liam in the Cedolan Gym is honest, never a SUSPECT level jump.
Autotest.scenario "a trainer battle's EXP is not a suspect level jump",
                  flags: { PEMK_BATTLE_ENFORCE_ENCOUNTERS: "on", PEMK_BATTLE_ENFORCE_REWARDS: "on" },
                  budget: 360 do |s|
  a = s.player(:a)
  a.new_game("Trainer")
  id = s.account_id(a)
  a.fast!
  a.add_pokemon!("MAGIKARP", 2)            # takes part, then steps aside: it levels up
  a.add_pokemon!("WARTORTLE", 30)          # wins the battle
  a.warp!(10, 6, 14)                       # the Cedolan Gym's entrance
  a.wait_until!("idle within 10", timeout: 20)

  a.talk_to(4, timeout: 60)                # Camper Liam, unless he spots the player first
  a.converse
  s.check("Liam's battle started") { a.in_battle?(10) }
  a.fight_battle(swap_to: 1)
  a.converse
  s.check("the lead levelled up from it") { Array(a.state["party"])[0]["level"] > 2 }
  s.wait_for("the party reaches the server", seconds: 30) do
    s.db[:monsters].where(owner_account_id: id).count == 2
  end
  a.save!                                  # the projection with the new levels goes out
  s.check("the server finds no suspect level jump") do
    sleep 2
    s.server.grep(/reward: account #{id} SUSPECT/).empty?
  end
end
