require "minitest/autorun"
require "rbconfig"

# Trainer proof P2 on the client: a trainer loaded for a battle asks its placement's seed
# (only under `on`, when the server says it seeds trainers, for a trainer the game's data
# built from an event); the battle's start waits for the answer, at most two seconds,
# and runs unseeded when it is a refusal or does not come.
class TrainerSeedPluginTest < Minitest::Test
  RNG = File.expand_path("../../Plugins/PEMK/010_BattleRng/001_BattleRng.rb", __dir__)

  RUNNER = <<~'RUBY'
    $sent = []; $now = 100.0; $pumps = 0
    module EventHandlers; def self.add(*); end; end
    module Graphics; def self.update; $pumps += 1; $now += 0.25; end; end
    module Input; def self.update; end; end
    class Battle; def pbStartBattle; end; def pbRandom(x); 0; end; def pbCommandPhase; end
      def pbSwitchInBetween(*); end; def pbRun(*); end; def pbEndOfBattle; end; def pbDisplayConfirm(_m); end; end
    class Battle::AI; def pbAIRandom(x); 0; end; end
    class FakeClient; def connected?; true; end; end
    module PEMK
      def self.enabled?; true; end
      def self.self_id; 1; end
      def self.client; FakeClient.new; end
      def self.log(_m); end
      def self.send_message(m, _b = nil); $sent << m; true; end
    end
    load ARGV[0]
    PEMK::BattleRng.define_singleton_method(:mono) { $now }
    Trainer = Struct.new(:pemk_key, :pemk_event)
    rng = PEMK::BattleRng
    liam = Trainer.new(["CAMPER", "Liam", 0], [10, 4])
    out = {}

    rng.adopt_mode("shadow"); rng.adopt_trainer_seed(true)
    rng.ask_trainer_seed(liam)
    out[:shadow] = $sent.size                                  # shadow: nothing asked
    rng.adopt_mode("on"); rng.adopt_trainer_seed(false)
    rng.ask_trainer_seed(liam)
    out[:not_offered] = $sent.size                             # the server does not seed trainers
    rng.adopt_trainer_seed(true)
    rng.ask_trainer_seed(Trainer.new(["CAMPER", "Liam", 0], nil))
    out[:no_event] = $sent.size                                # not from an event: nothing to name

    rng.ask_trainer_seed(liam)
    out[:asked] = $sent.last
    rng.on_trainer_seed({ type: :trainer_battle_seed, nonce: $sent.last[:nonce], seed: 42 })
    rng.on_trainer_seed({ type: :trainer_battle_seed, nonce: 999, seed: 7 })   # nobody asked
    out[:seeded] = [rng.trainer_seed(liam), $pumps]

    brock = Trainer.new(["LEADER_Brock", "Brock", 0], [10, 3])
    rng.ask_trainer_seed(brock)
    rng.on_trainer_seed({ type: :trainer_battle_deny, nonce: $sent.last[:nonce], reason: "not_here" })
    out[:denied] = rng.trainer_seed(brock)

    ariel = Trainer.new(["SWIMMER2_F", "Ariel", 0], [69, 5])
    rng.ask_trainer_seed(ariel)
    t0 = $now
    out[:late] = [rng.trainer_seed(ariel), ($now - t0).round(2)]   # no answer: two seconds, then none
    print out.inspect
  RUBY

  def test_a_trainer_battle_asks_and_waits_for_its_seed
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, RNG], err: %i[child out], &:read)
    assert $?.success?, "runner crashed:\n#{out}"
    got = eval(out) # rubocop:disable Security/Eval - our own runner's inspect
    assert_equal 0, got[:shadow]
    assert_equal 0, got[:not_offered]
    assert_equal 0, got[:no_event]
    assert_equal :trainer_battle_req, got[:asked][:type]
    assert_equal [["CAMPER", "Liam", 0, 10, 4]], got[:asked][:trainers]
    assert_equal [42, 0], got[:seeded], "answered already: no wait"
    assert_nil got[:denied]
    assert_equal [nil, 2.0], got[:late]
  end
end
