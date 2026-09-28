# frozen_string_literal: true

# Every protection on at once, and a player who only plays: the starter from the
# Pokemon Lab, the Great Ball on Route 1, a wild battle in its grass (that ball
# first, then the starter's moves), a save and a relaunch. No debug shortcut: each
# step is one a real player takes. The server rolls the battle, so it may be lost:
# a blackout home is honest play too. Nothing may be suspected, corrected, refused,
# flagged or quarantined, and the relaunch must give everything back.
MAX_SECURITY = {
  PEMK_POS_ENFORCE: "on", PEMK_PICKUP_ENFORCE: "on", PEMK_FLAG_STATE: "on", PEMK_FLAG_ENFORCE: "on",
  PEMK_BATTLE_ENFORCE_TEAMS: "on", PEMK_BATTLE_ENFORCE_ENCOUNTERS: "on",
  PEMK_BATTLE_ENFORCE_CATCHES: "on", PEMK_BATTLE_ENFORCE_REWARDS: "on",
  PEMK_BATTLE_ENFORCE_EXP: "on", PEMK_BATTLE_ENFORCE_RNG: "on",
  PEMK_BATTLE_ENFORCE_RESIM: "on", PEMK_ANOMALY_DETECTION: "on", PEMK_GIFT_ENFORCE: "on"
}.freeze

# What the server writes about an account it suspects, corrects or refuses.
ALARMS = Regexp.union(/SUSPECT/, /DRIFT/, /mode_mismatch/, /over budget/, /over the hourly/,
                      /CONDEMNED/, /noclip/, /illegal_warp/, /posenforce/, /interact (?!match)/,
                      /suspicious team/, /illegal team/, /bag divergence/, /quarantin/, /REPAIR/,
                      /gift: account \d+ (?:WOULD-)?DENY/)

Autotest.scenario "an honest player trips nothing with every protection on",
                  flags: MAX_SECURITY, budget: 600 do |s|
  a = s.player(:a)
  a.new_game("Honest")
  id = s.account_id(a)
  a.fast!

  a.enter!(3)                              # down the bedroom stairs
  a.wait_until!("idle within 10", timeout: 20)
  a.enter!(1)                              # out of the house
  a.wait_until!("map 2 within 10", timeout: 20)
  a.wait_until!("idle within 5", timeout: 15)
  a.enter!(2, timeout: 60)                 # the Pokemon Lab: Oak's welcome
  a.wait_until!("map 4 within 10", timeout: 20)
  a.converse
  a.talk_to!(6)                            # Squirtle: Route 1's Pidgey hit it for 1x
  a.converse("Yes")                        # fast: no nickname prompt
  a.enter!(7, timeout: 60)
  a.wait_until!("map 2 within 10", timeout: 20)
  a.wait_until!("idle within 5", timeout: 15)
  a.walk_to!(14, 0, timeout: 60)
  a.cross("UP", 5)                         # Route 1
  a.talk_to!(11, timeout: 60)              # the Great Ball
  a.converse
  s.check("the starter and the Great Ball are in hand") do
    a.party_species == ["SQUIRTLE"] && a.get_item!("GREATBALL")["quantity"] == 1
  end

  # One wild battle: the Great Ball first, then Squirtle's strongest move. Route 1's
  # wild Pokemon are level 11-14, so losing and waking up at home is likely, and fine.
  a.find_wild_battle
  a.catch_with("GREATBALL")
  a.converse                               # what follows (a blackout's walk home too)
  story = [a.party_species.size == 2 ? "caught it" : "did not catch it",
           a.state.dig("map", "id") == 5 ? "still on Route 1" : "blacked out, home"]
  File.write(File.join(s.dir, "story.txt"), story.join("\n"))

  party = -> { Array(a.state["party"]).map { |m| [m["species"], m["level"], m["uid"]] } }
  before = s.wait_for("every Pokemon has its uid", seconds: 30) { (p = party.call).all?(&:last) && p }
  a.save!
  a.relaunch
  s.check("the relaunch gives the party back as it was") do
    party.call == before
  end

  alarms = s.server.grep(/account #{id}\b/).grep(ALARMS)
  File.write(File.join(s.dir, "alarms.txt"), alarms.join("\n"))
  s.check("the server suspected, corrected and refused nothing") { alarms.empty? }
  s.check("no anomaly counter moved") { s.db[:player_flags].where(account_id: id).count.zero? }
  s.check("no Pokemon is held back") do
    s.db[:monsters].where(owner_account_id: id).exclude(status: "active").count.zero?
  end
  s.check("the client was never snapped back") { a.log_tail(600).none? { |l| l.include?("poscorrect: snapped") } }
end
