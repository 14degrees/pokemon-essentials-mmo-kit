# frozen_string_literal: true

# With the server minting wild encounters and rolling catches
# (PEMK_BATTLE_ENFORCE_ENCOUNTERS and _CATCHES on), an honest catch in the tall
# grass of Route 1 goes through: the server mints the wild Pokemon, rolls the
# ball's shakes, and the catch joins the party under a uid whose origin says it
# was caught in the wild. A relaunch keeps it.
Autotest.scenario "a wild Pokemon is caught under server authority",
                  flags: { PEMK_BATTLE_ENFORCE_ENCOUNTERS: "on", PEMK_BATTLE_ENFORCE_CATCHES: "on" },
                  budget: 360 do |s|
  a = s.player(:a)
  a.new_game("Catcher")
  id = s.account_id(a)
  a.fast!                                  # no animations, no nickname prompt
  a.add_pokemon!("PIKACHU", 20)
  a.add_item!("POKEBALL", 30)
  a.warp!(5, 18, 20)                       # Route 1
  a.wait_until!("idle within 10", timeout: 20)

  a.find_wild_battle
  foe = Array(a.state.dig("battle", "battlers")).find { |b| b["side"] == "foe" }
  raise Autotest::Failure, "no wild Pokemon in the battle" unless foe

  a.catch_with("POKEBALL")
  a.wait_until!("idle within 30", timeout: 40)
  wild = foe["species"]

  s.check("the server minted the wild #{wild}") do
    !s.server.grep(/encounter: account #{id} MINT map 5 \S+ -> #{wild}@#{foe['level']}/).empty?
  end
  s.check("and rolled the ball that caught it") do
    !s.server.grep(/catch: account #{id} VERDICT #{wild}@\d+ .* CAUGHT/).empty?
  end
  s.check("the catch joined the party") { a.party_species == ["PIKACHU", wild] }
  uid = s.wait_for("the catch gets a uid", seconds: 30) { Array(a.state["party"])[1]&.dig("uid") }
  s.check("its uid says it was caught in the wild") { s.db[:monsters].where(id: uid).get(:origin) == "wild_caught" }
  s.check("the minted roll is marked caught and claimed") do
    s.db[:encounter_rolls].where(account_id: id).exclude(caught_at: nil).exclude(claimed_at: nil).count == 1
  end

  a.relaunch
  s.check("a relaunch keeps it") { a.party_species == ["PIKACHU", wild] }
end
