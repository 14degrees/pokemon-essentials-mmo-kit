# frozen_string_literal: true

# With PEMK_PICKUP_ENFORCE=on an item ball is granted by the server before the game
# adds it, once per account and tile. An honest pickup goes through: the Great Ball
# on Route 1 reaches the bag and the server records its tile, and a relaunch keeps
# both. Putting the ball back (its self switch cleared, as a save edit would) must
# not give a second one.
Autotest.scenario "an item ball is granted once", flags: { PEMK_PICKUP_ENFORCE: "on" } do |s|
  a = s.player(:a)
  a.new_game("Finder")
  id = s.account_id(a)

  a.enter!(3)                              # down the bedroom stairs
  a.wait_until!("idle within 10", timeout: 20)
  a.enter!(1)                              # out of the house
  a.wait_until!("map 2 within 10", timeout: 20)
  a.wait_until!("idle within 5", timeout: 15)
  a.walk_to!(14, 0, timeout: 60)
  a.cross("UP", 5)                         # Route 1 (no Pokemon yet: no wild battle)
  a.talk_to!(11, timeout: 60)              # the Great Ball at (26,14)
  a.converse
  great_balls = -> { a.get_item!("GREATBALL")["quantity"] }

  s.check("the Great Ball reached the bag") { great_balls.call == 1 }
  s.check("the server granted it against the world, and kept the tile") do
    s.server.grep(/pickup: account #{id} GRANT \(world unexported/).empty? &&
      s.db[:pickups].where(account_id: id, map: 5, x: 26, y: 14).count == 1
  end

  a.save!
  a.relaunch
  s.check("after a relaunch the ball is still taken") { a.get_selfswitch!(5, 11, "A")["value"] }
  s.check("and the bag still has one") { great_balls.call == 1 }

  a.set_selfswitch!(5, 11, "A", "off")     # the ball is back, as after a save edit
  a.wait_until!("idle within 5", timeout: 15)
  a.talk_to!(11, timeout: 60)
  a.converse
  s.check("a second pickup of the same ball is refused") { great_balls.call == 1 }
  s.check("the player is told it is empty") do
    Array(a.state["log"]).any? { |e| e["text"].to_s.include?("seems to be empty") }
  end
end
