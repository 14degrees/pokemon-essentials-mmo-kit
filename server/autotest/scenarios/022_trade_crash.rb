# frozen_string_literal: true

# A trade's Pokemon reaches the receiver's disk only with its next save. Bob's saves
# are held back (as if his game died before the save landed), the trade completes,
# and his game is killed: the save the relaunch loads still has Eevee and lacks
# Pikachu. The server kept Alice's escrow, so the relaunched game gets Pikachu back,
# under Alice's uid, and Eevee (now Alice's) is gone - one of each, nowhere twice.
Autotest.scenario "a Pokemon traded just before a crash is not lost", budget: 480 do |s|
  a = s.player(:a)
  b = s.player(:b)
  s.together(-> { a.new_game("Alice") }, -> { b.new_game("Bob") })
  id_a = s.account_id(a)
  id_b = s.account_id(b)

  a.add_pokemon!("PIKACHU", 10)
  a.add_pokemon!("RATTATA", 5)
  b.add_pokemon!("EEVEE", 10)
  b.add_pokemon!("PIDGEY", 5)
  uid_of = ->(player, species) { Array(player.state["party"]).find { |p| p["species"] == species }&.dig("uid") }
  pikachu, eevee = s.wait_for("the server gives the new Pokemon their uids", seconds: 30) do
    ids = [uid_of.call(a, "PIKACHU"), uid_of.call(b, "EEVEE")]
    ids if ids.all?
  end
  b.save!                                  # Bob's save holds Eevee and Pidgey
  b.hold_saves!("on")                      # from here on, none of his saves lands

  a.warp!(7, 38, 30)
  b.warp!(7, 40, 30)
  s.wait_for("each window draws the other", seconds: 30) do
    a.remote_names.include?("Bob") && b.remote_names.include?("Alice")
  end

  a.pause_menu("Trade Player")
  a.converse("Bob")
  b.answer_when_asked("Yes", "Yes", "Eevee")
  a.answer_when_asked("Pikachu", "Pikachu", "Yes")
  b.answer_when_asked("Yes", "Yes")
  said = ->(player, text) { Array(player.state["log"]).any? { |e| e["text"].to_s.include?(text) } }
  s.wait_for("Bob is told the trade is complete", seconds: 30) { said.call(b, "The trade with Alice is complete!") }
  s.check("Bob holds Pikachu before the crash") { uid_of.call(b, "PIKACHU") == pikachu }
  s.wait_for("Bob's report reaches the server", seconds: 15) do
    s.db[:trade_deliveries].where(account_id: id_b, uid: pikachu, acked: true).count == 1
  end

  b.hard_kill                              # before any save of his landed
  b.launch
  # Not wait_in_game: the game says where Pikachu came from, and waits on that message.
  s.wait_for("Bob's game is back online", seconds: 60) do
    st = b.state
    st["map"] && st.dig("online", "logged_in")
  end
  s.wait_for("the relaunched game gets Pikachu back", seconds: 30) { uid_of.call(b, "PIKACHU") == pikachu }
  b.converse                               # "Pikachu arrived from a trade that was cut short."
  s.check("Bob is told where it came from") { said.call(b, "arrived from a trade that was cut short") }
  s.check("Eevee, now Alice's, left Bob's party") { !b.party_species.include?("EEVEE") }
  s.check("the registry agrees") do
    s.db[:monsters].where(id: pikachu).get(:owner_account_id) == id_b &&
      s.db[:monsters].where(id: eevee).get(:owner_account_id) == id_a
  end
  s.wait_for("the save that holds it settles the delivery", seconds: 30) do
    s.db[:trade_deliveries].where(account_id: id_b).count.zero?
  end

  owed_lines = -> { s.server.grep(/trade: account #{id_b} owed/).size }
  sent_before = owed_lines.call
  b.relaunch
  s.check("after another relaunch Bob has one Pikachu") do
    b.party_species.count("PIKACHU") == 1 && uid_of.call(b, "PIKACHU") == pikachu
  end
  s.check("and nothing is sent again") do
    sleep 2
    owed_lines.call == sent_before
  end
end
