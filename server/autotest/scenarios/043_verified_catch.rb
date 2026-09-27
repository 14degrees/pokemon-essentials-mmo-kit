# frozen_string_literal: true

# The whole battle-verification chain on an honest catch. With the battle RNG
# seeded by the server (D7) and re-sim enforcement on (D8): the catch is born
# provisional, its battle record passes the server's seed walk as it arrives, the
# replay worker re-simulates it on the real engine to a match, and the server's
# verdict sweep promotes the Pokemon to verified. Nothing is quarantined.
Autotest.scenario "an honest catch is verified, never quarantined",
                  flags: { PEMK_BATTLE_ENFORCE_ENCOUNTERS: "on", PEMK_BATTLE_ENFORCE_CATCHES: "on",
                           PEMK_BATTLE_ENFORCE_RNG: "on", PEMK_BATTLE_ENFORCE_RESIM: "on" },
                  budget: 480 do |s|
  a = s.player(:a)
  a.new_game("Honest")
  id = s.account_id(a)
  a.fast!
  a.add_pokemon!("MAGIKARP", 10)           # leads: Splash does nothing, so the foe
  a.add_pokemon!("PIKACHU", 20)            # gets turns (damage and AI draws to replay)
  a.add_item!("POKEBALL", 30)
  a.warp!(5, 18, 20)                       # Route 1
  a.wait_until!("idle within 10", timeout: 20)

  a.find_wild_battle
  a.catch_with("POKEBALL", warm_up: 2)
  a.wait_until!("idle within 30", timeout: 40)
  uid = s.wait_for("the catch gets a uid", seconds: 30) { Array(a.state["party"])[2]&.dig("uid") }
  s.check("the catch is born provisional") { s.db[:monsters].where(id: uid).get(:verify_state) == "provisional" }

  record = s.wait_for("the battle record reaches the server", seconds: 30) do
    s.db[:battle_records].where(account_id: id).order(:id).last
  end
  s.check("the server's seed walk accepts it") { record[:replay_status] == "walk_ok" && record[:outcome] == 4 }
  s.check("the battle took more than the throw") { record[:rounds].to_i >= 3 }

  out, status = Open3.capture2e({ "DATABASE_URL" => ENV.fetch("DATABASE_URL"), "REPLAY_ID" => record[:id].to_s },
                                "bundle", "exec", "ruby", "bin/pemk_replay.rb", chdir: Autotest::SERVER_DIR)
  File.write(File.join(s.dir, "replay.log"), out)
  s.check("the replay worker re-simulates it to a match") do
    status.success? && s.db[:battle_records].where(id: record[:id]).get(:replay_status) == "match"
  end
  s.check("the verdict sweep verifies the catch") do
    s.wait_for("verified", seconds: 90) { s.db[:monsters].where(id: uid).get(:verify_state) == "verified" }
  end
  s.check("nothing is quarantined") do
    s.db[:monsters].where(owner_account_id: id).exclude(status: "active").count.zero? &&
      s.db[:enforcement_events].where(account_id: id, kind: %w[quarantine would_quarantine]).count.zero?
  end
end
