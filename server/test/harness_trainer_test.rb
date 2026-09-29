require "minitest/autorun"
require "json"
require "rbconfig"

# docs/TRAINER-PROOF-DESIGN.md, P1: the harness rebuilds a trainer from the game's data
# and re-runs its AI against a real battle record (Brock, 12 rounds, the player lost: two
# Full Restores, Onix sent in). As recorded it replays to the same end and the same
# money; a record that changes the AI's choices, the foe team, the bag or the trainer
# does not. The engine runs in a SUBPROCESS, as for the wild replays.
class HarnessTrainerTest < Minitest::Test
  SERVER_ROOT = File.expand_path("..", __dir__)
  RUNNER      = File.join(SERVER_ROOT, "test", "support", "harness_trainer_runner.rb")
  FIXTURE     = File.join(SERVER_ROOT, "test", "fixtures", "battle_records", "trainer_brock_loss.bin")

  def test_the_trainer_s_ai_is_re_run
    game_root = ENV["PEMK_GAME_ROOT"] || File.expand_path("..", SERVER_ROOT)
    unless File.exist?(File.join(game_root, "Data", "trainers.dat"))
      skip "game Data/*.dat not compiled (launch the game once) - harness replay skipped"
    end

    out = IO.popen([RbConfig.ruby, "-W0", RUNNER, FIXTURE], err: %i[child out], &:read)
    assert $?.success?, "harness runner failed:\n#{out}"
    got = JSON.parse(out.lines.last).to_h { |v| [v["tamper"], v] }

    assert_equal "match", got["as recorded"]["verdict"], got["as recorded"]["detail"]
    assert_equal(-160, got["as recorded"]["prize"], "the money the game took for the loss")
    {
      "ai choice"       => /round 2: the trainer's AI chose \["UseItem", "FULLRESTORE"/,
      "ai switch"       => /the trainer's AI sent in party 1, the record says 0/,
      "foe level"       => /foe 0 level: the game's data has 12, the record 5/,
      "foe moves"       => /foe 1 moves: the game's data has/,
      "bag"             => /the trainers' bag: the game's data has \[\["FULLRESTORE", "FULLRESTORE"\]\]/,
      "trainer"         => /no trainer \["LEADER_Brock", "Brock", 7\] in the game's data/,
      "no trainer name" => /a trainer the game's data cannot rebuild/
    }.each do |tamper, why|
      assert_equal "mismatch", got[tamper]["verdict"], "#{tamper}: #{got[tamper]['detail']}"
      assert_match why, got[tamper]["detail"].to_s, tamper
    end
  end
end
