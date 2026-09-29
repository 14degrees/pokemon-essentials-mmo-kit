# frozen_string_literal: true

require "open3"

# The trainer proof's first step (docs/TRAINER-PROOF-DESIGN.md, P1). A trainer battle
# is recorded (battle RNG in shadow); the replay rebuilds the trainer from the game's
# data and RE-RUNS its AI against what the player did: every round the AI must choose
# what the game's AI chose, and the battle must end the same, with the same prize.
# Camper Liam, then Brock (a leader's AI, the most skilled, with Full Restores).
Autotest.scenario "the replay re-runs a trainer's AI to the same battle",
                  flags: { PEMK_BATTLE_ENFORCE_RNG: "shadow" }, budget: 480 do |s|
  a = s.player(:a)
  a.new_game("Challenger")
  id = s.account_id(a)
  a.fast!
  a.add_pokemon!("WARTORTLE", 20)          # strong enough to win, weak enough for the AI to have to choose
  a.warp!(10, 6, 14)                       # the Cedolan Gym's entrance
  a.wait_until!("idle within 10", timeout: 20)
  records = -> { s.db[:battle_records].where(account_id: id).order(:id).all }
  money = -> { a.state.dig("trainer", "money").to_i }
  paid = []                                # what the game paid (or took) for each battle

  before = money.call
  a.talk_to(4, timeout: 60)                # Camper Liam, unless he spots the player first
  a.converse
  s.check("Liam's battle started") { a.in_battle?(10) }
  a.fight_battle
  a.converse
  paid << money.call - before
  s.wait_for("Liam's battle is recorded", seconds: 30) { records.call.size >= 1 }

  a.heal!
  before = money.call
  a.talk_to(3, timeout: 60)                # Brock (won or lost: either is a battle to replay)
  a.converse
  s.check("Brock's battle started") { a.in_battle?(10) }
  a.fight_battle
  a.converse
  paid << money.call - before
  s.wait_for("Brock's battle is recorded", seconds: 30) { records.call.size >= 2 }

  # Each record on its own (the corpus holds every other scenario's records too).
  lines = records.call.map do |r|
    out, = Open3.capture2e({ "DATABASE_URL" => ENV.fetch("DATABASE_URL"), "REPLAY_ID" => r[:id].to_s },
                           "bundle", "exec", "ruby", "bin/pemk_replay.rb", chdir: Autotest::SERVER_DIR)
    out.lines.grep(/^  #/).join
  end
  File.write(File.join(s.dir, "replay.txt"), lines.join)
  s.check("both battles replay to a match, the trainer's AI re-run") do
    records.call.map { |r| r[:replay_status] } == %w[match match]
  end
  File.write(File.join(s.dir, "paid.txt"), paid.inspect)
  s.check("the replay pays (or takes) what the game did") do
    lines.map { |l| l[/\(prize (-?\d+)\)/, 1]&.to_i } == paid
  end
end
