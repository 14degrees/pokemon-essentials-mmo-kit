# frozen_string_literal: true

# The Pokemon Institute's fossil NPCs turn their self-switch A on and back off: the
# reviver holds A while it keeps a fossil, across map changes and saves. Banking that
# latch as a progression fact replayed the collection at every login (and crashed
# the client on the combiner). A latch must never reach the ledger, and after a
# relaunch both NPCs must behave as before, with no second Pokemon from a replay.
Autotest.scenario "the fossil NPCs' latch is never banked",
                  flags: { PEMK_FLAG_STATE: "on", PEMK_FLAG_ENFORCE: "on" } do |s|
  institute = [11, 7, 9]   # map, then the tile inside the door
  a = s.player(:a)
  a.new_game("Fossil")
  id = s.account_id(a)
  a.add_item!("HELIXFOSSIL")
  a.add_item!("FOSSILIZEDBIRD")
  a.add_item!("FOSSILIZEDDRAKE")

  a.warp!(*institute)
  a.wait_until!("idle within 10", timeout: 20)
  a.talk_to!(2)
  a.converse("Yes", "HELIXFOSSIL")
  s.check("the reviver keeps the fossil (its A is on)") { a.get_selfswitch!(11, 2, "A")["value"] }

  # Out through the door: the exit event is what finishes the revival (it clears the
  # "come back later" switch; a warp would skip it). The map change sends the flags
  # snapshot with A on, and the save would make it durable if it were banked.
  a.enter!(1)
  a.wait_until!("map 7 within 10", timeout: 20)
  a.wait_until!("idle within 10", timeout: 20)
  a.save!
  s.wait_for("the snapshot with the latch on reaches the server") do
    Array(s.db[:flag_snapshots].where(account_id: id).get(:self_switches)).include?("11:2:A")
  end
  s.check("the latch never reaches the ledger") do
    s.db[:progression_facts].where(account_id: id, fact_key: "ss:11:2:A").count.zero?
  end

  a.warp!(*institute)
  a.wait_until!("idle within 10", timeout: 20)
  a.talk_to!(2)
  a.converse("No")                                   # the nickname
  a.talk_to!(4)
  a.converse("Yes", "Fossilized Bird", "Fossilized Drake", "Yes, please", "No")
  species = a.party_species
  s.check("Omanyte and Dracozolt joined the party") { species.count("OMANYTE") == 1 && species.count("DRACOZOLT") == 1 }
  a.save!

  a.relaunch
  s.check("after a relaunch the reviver's A is off") { !a.get_selfswitch!(11, 2, "A")["value"] }
  a.warp!(*institute)
  a.wait_until!("idle within 10", timeout: 20)
  a.talk_to!(2)
  a.converse("No")                                   # "Do you have a fossil for me?"
  a.talk_to!(4)
  a.converse
  lines = Array(a.state["log"]).map { |e| e["text"] }
  s.check("no NPC replays a collection") { lines.none? { |t| t.include?("finished reviving") || t.include?("obtained") } }
  species = a.party_species
  s.check("still one Omanyte and one Dracozolt") { species.count("OMANYTE") == 1 && species.count("DRACOZOLT") == 1 }
  s.check("the game's own latch toggles were never repaired") do
    s.server.grep(/flags: account #{s.account_id(a)} REPAIR/).empty?
  end
end
