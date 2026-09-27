# frozen_string_literal: true

# Two players on one map trade a Pokemon each through the pause menu. The server
# swaps the owners in one transaction: each window must end up with the other's
# Pokemon under the same server uid, the registry must agree, and a relaunch (from
# the save the trade forces) must keep it that way.
Autotest.scenario "two players trade a Pokemon", budget: 420 do |s|
  a = s.player(:a)
  b = s.player(:b)
  s.together(-> { a.new_game("Alice") }, -> { b.new_game("Bob") })
  id_a = s.account_id(a)
  id_b = s.account_id(b)

  # Two each: the last able Pokemon cannot be traded.
  a.add_pokemon!("PIKACHU", 10)
  a.add_pokemon!("RATTATA", 5)
  b.add_pokemon!("EEVEE", 10)
  b.add_pokemon!("PIDGEY", 5)
  uid_of = ->(player, species) { Array(player.state["party"]).find { |p| p["species"] == species }&.dig("uid") }
  pikachu, eevee = s.wait_for("the server gives the new Pokemon their uids", seconds: 30) do
    ids = [uid_of.call(a, "PIKACHU"), uid_of.call(b, "EEVEE")]
    ids if ids.all?
  end

  a.warp!(7, 38, 30)
  b.warp!(7, 40, 30)
  s.wait_for("each window draws the other", seconds: 30) do
    a.remote_names.include?("Bob") && b.remote_names.include?("Alice")
  end

  a.pause_menu("Trade Player")
  a.converse("Bob")                                   # "Trade with which player?"
  b.answer_when_asked("Yes", "Yes", "Eevee")          # accept, offer Eevee
  a.answer_when_asked("Pikachu", "Pikachu", "Yes")    # offer Pikachu, confirm
  b.answer_when_asked("Yes", "Yes")                   # confirm

  # The last line may already have been read by the confirm's conversation, so the
  # log says whether it came.
  said = ->(player, text) { Array(player.state["log"]).any? { |e| e["text"].to_s.include?(text) } }
  s.check("both windows are told the trade is complete") do
    [[a, "Bob"], [b, "Alice"]].all? do |p, partner|
      s.wait_for("#{p.name} is told the trade is complete", seconds: 30) do
        said.call(p, "The trade with #{partner} is complete!")
      end
    end
  end
  [a, b].each(&:converse)
  s.check("Alice now has Eevee, under Bob's uid") { uid_of.call(a, "EEVEE") == eevee && !a.party_species.include?("PIKACHU") }
  s.check("Bob now has Pikachu, under Alice's uid") { uid_of.call(b, "PIKACHU") == pikachu && !b.party_species.include?("EEVEE") }
  s.check("the registry swapped the owners") do
    s.db[:monsters].where(id: pikachu).get(:owner_account_id) == id_b &&
      s.db[:monsters].where(id: eevee).get(:owner_account_id) == id_a
  end
  s.check("the transfer log holds one row each way") do
    rows = s.db[:monster_transfers].where(uid: [pikachu, eevee]).select_map(%i[uid from_account_id to_account_id])
    rows.sort == [[pikachu, id_a, id_b], [eevee, id_b, id_a]].sort
  end

  a.relaunch
  b.relaunch
  s.check("after a relaunch Alice still has Eevee and not Pikachu") do
    uid_of.call(a, "EEVEE") == eevee && !a.party_species.include?("PIKACHU")
  end
  s.check("after a relaunch Bob still has Pikachu and not Eevee") do
    uid_of.call(b, "PIKACHU") == pikachu && !b.party_species.include?("EEVEE")
  end
end
