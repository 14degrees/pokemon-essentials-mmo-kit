# frozen_string_literal: true

# Step 6 of sovereign variables: with PEMK_GIFT_ENFORCE on, an event asks the server
# before it gives an item. Brock's TM80 is a one-shot gift (his page turns once it
# pays): the first win pays it, the bag snapshot that follows settles it, and Brock
# re-armed as a save edit would must not pay a second one - the player is told they
# already received it, and the event moves on as if it had paid.
Autotest.scenario "a one-shot gift is paid once", flags: { PEMK_GIFT_ENFORCE: "on" }, budget: 480 do |s|
  a = s.player(:a)
  a.new_game("Giftee")
  id = s.account_id(a)
  a.fast!
  a.add_pokemon!("WARTORTLE", 40)          # beats Brock's rock types
  a.warp!(10, 6, 6)                        # in front of Brock, out of the Camper's sight
  a.wait_until!("idle within 10", timeout: 20)
  tms   = -> { a.get_item!("TM80")["quantity"] }
  grant = -> { s.db[:gift_grants].where(account_id: id, map: 10, event: 3).first }

  beat_brock = lambda do
    a.talk_to!(3, timeout: 60)
    a.converse
    s.check("Brock's battle started") { a.in_battle?(10) }
    a.fight_battle
    a.converse
  end

  beat_brock.call
  s.check("the TM reached the bag") { tms.call == 1 }
  s.check("the server granted it as a one-shot") { grant.call && grant.call[:state] != "void" }
  a.save!
  s.wait_for("the bag snapshot settles the grant", seconds: 20) { grant.call[:state] == "sealed" }

  a.set_selfswitch!(10, 3, "A", "off")     # Brock re-armed, as a save edit would
  a.wait_until!("idle within 5", timeout: 15)
  beat_brock.call
  s.check("no second TM") { tms.call == 1 }
  s.check("the player is told they already received it") do
    Array(a.state["log"]).any? { |e| e["text"].to_s.include?("You already received the TM80") }
  end
  s.check("the event moved on as if it had paid") { a.get_selfswitch!(10, 3, "A")["value"] }
  s.check("the server refused the second payout") do
    !s.server.grep(/gift: account #{id} DENY — map 10 event 3 TM80 already paid/).empty?
  end

  a.relaunch
  s.check("after a relaunch, still one TM") { tms.call == 1 }
end
