require "minitest/autorun"
require "rbconfig"

# Money authority M1a, client half: a trainer battle's prize is claimed where the engine
# pays it (Battle#pbGainMoney), naming each trainer by the data it was built from and the
# event that started its battle - a rival's substituted name and a trainer that spotted
# the player first keep theirs - with the amount the engine is about to add and the
# multiplier facts. The claim is sent after a fresh position, waits in the save until the
# server answers it, and goes out again on a new connection.
class PrizeClaimPluginTest < Minitest::Test
  PEMK_DIR = File.expand_path("../../Plugins/PEMK", __dir__)

  RUNNER = <<~'RUBY'
    $sent = []; $now = 0.0; $event = 7
    module PBEffects; AmuletCoin = 1; HappyHour = 2; PayDay = 3; end
    class NPCTrainer
      attr_reader :trainer_type, :name, :version, :base_money
      def initialize(type, name, version, money); @trainer_type = type; @name = name; @version = version; @base_money = money; end
    end
    module GameData
      class Trainer
        def initialize(type, name, version); @trainer_type = type; @real_name = name; @version = version; end
        def to_trainer
          shown = @trainer_type == :RIVAL1 ? "Sam" : @real_name   # Settings::RIVAL_NAMES
          NPCTrainer.new(@trainer_type, shown, @version, 20)
        end
      end
    end
    Field = Struct.new(:effects)
    class Battle
      attr_reader :opponent, :field
      attr_accessor :internalBattle, :moneyGain
      def initialize(opp, levels, effects); @opponent = opp; @levels = levels; @field = Field.new(effects); @internalBattle = true; @moneyGain = true; end
      def trainerBattle?; true; end
      def pbMaxLevelInTeam(_side, i); @levels[i]; end
      def pbGainMoney; $sent << :engine_paid; end
    end
    class PokemonGlobalMetadata; attr_accessor :partner; end
    Map = Struct.new(:map_id)
    $game_map = Map.new(31)
    def pbMapInterpreterRunning?; true; end
    Self = Struct.new(:id)
    def pbMapInterpreter; Struct.new(:x) { def get_self; Self.new($event); end }.new(1); end
    module PEMK
      def self.enabled?; true; end
      def self.self_id; 7; end
      def self.client; Struct.new(:c) { def connected?; $up != false; end }.new(1); end
      def self.log(_m); end
      def self.send_message(m); $sent << m; end
      module Presence; def self.emit_now(_t); $sent << :pos; end; end
    end
    load File.join(ARGV[0], "009_BattleData", "007_PrizeClaim.rb")
    P = PEMK::PrizeClaim
    def P.mono; $now; end
    $PokemonGlobal = PokemonGlobalMetadata.new
    claims = -> { $sent.select { |m| m.is_a?(Hash) && m[:type] == :money_claim } }
    out = {}

    P.adopt_mode("shadow")
    # a trainer that spotted the player first, on event 3, then the rival on event 7
    $event = 3; first = GameData::Trainer.new(:LASS, "Anna", 0).to_trainer
    $event = 7; rival = GameData::Trainer.new(:RIVAL1, "Blue", 1).to_trainer
    b = Battle.new([rival, first], [12, 20], { 1 => true, 2 => false, 3 => 0 })
    b.pbGainMoney
    c = claims.call.last
    out[:claim] = [$sent.first, c[:trainers], c[:amount], c[:amulet], c[:happy_hour], c[:map], $sent.last]
    out[:kept] = $PokemonGlobal.pemk_prize_claims.length
    # a battle that pays no money claims nothing
    $sent.clear
    b2 = Battle.new([first], [20], { 1 => false, 2 => false, 3 => 0 }); b2.moneyGain = false
    b2.pbGainMoney
    out[:no_money] = claims.call.length
    # the answer drops it; "wait" keeps it for another try
    P.on_ack({ :type => :money_claim_ack, :nonce => c[:nonce], :verdict => "wait" })
    out[:wait] = $PokemonGlobal.pemk_prize_claims.length
    $sent.clear
    P.reset; P.adopt_mode("shadow")      # a new connection
    P.tick
    out[:resent] = [claims.call.map { |m| m[:nonce] } == [c[:nonce]], $sent.first]
    # a reconnect's reseed sends them at once, before its money frame
    $sent.clear
    P.reset; P.adopt_mode("shadow")
    P.flush
    out[:flushed] = [claims.call.map { |m| m[:nonce] } == [c[:nonce]], $sent.first]
    P.on_ack({ :type => :money_claim_ack, :nonce => c[:nonce], :verdict => "paid" })
    out[:answered] = $PokemonGlobal.pemk_prize_claims.length
    # off: nothing is claimed
    P.adopt_mode("off"); $sent.clear
    b.pbGainMoney
    out[:off] = claims.call.length
    print out.inspect
  RUBY

  def test_a_prize_is_claimed_where_the_engine_pays_it
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, PEMK_DIR], err: %i[child out], &:read)
    assert $?.success?, "claim runner crashed:\n#{out}"
    o = eval(out) # rubocop:disable Security/Eval -- our own runner's inspect output
    trainers, amount, amulet, happy, map = o[:claim][1, 5]
    assert_equal :pos, o[:claim][0], "a fresh position first"
    assert_equal [["RIVAL1", "Blue", 1, 31, 7], ["LASS", "Anna", 0, 31, 3]], trainers,
                 "the data's names and each trainer's own event"
    assert_equal [(12 * 20 + 20 * 20) * 2, true, false, 31], [amount, amulet, happy, map], "Amulet Coin doubles it"
    assert_equal :engine_paid, o[:claim][6], "then the engine pays"
    assert_equal 1, o[:kept], "kept in the save until answered"
    assert_equal 0, o[:no_money]
    assert_equal 1, o[:wait]
    assert_equal [true, :pos], o[:resent], "again on a new connection, after a position"
    assert_equal [true, :pos], o[:flushed], "at once for a reconnect's reseed"
    assert_equal 0, o[:answered]
    assert_equal 0, o[:off]
  end
end
