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
    # Pay Day: a wild battle's names its foes; a trainer battle's, the prize claim
    Mon = Struct.new(:personalID)
    class WildBattle < Battle
      def trainerBattle?; false; end
      def pbParty(_side); [Mon.new(4242)]; end
    end
    $sent.clear
    WildBattle.new([], [], { 1 => false, 2 => true, 3 => 60 }).pbGainMoney
    w = claims.call.last
    out[:wild] = [w[:kind], w[:foes], w[:amount], w[:trainers]]
    $sent.clear
    Battle.new([first], [20], { 1 => false, 2 => false, 3 => 50 }).pbGainMoney
    prize, pay = claims.call.last(2)
    out[:trainer_payday] = [pay[:kind], pay[:trainer_claim] == prize[:nonce], pay[:amount]]
    $sent.clear
    WildBattle.new([], [], { 1 => false, 2 => false, 3 => 0 }).pbGainMoney
    out[:no_coins] = claims.call.length
    # before a battle, the facts a claim is judged by go out
    module PEMK
      module Inventory; def self.mark; $sent << :inv; end; end
      module Sync; def self.mark_mon; $sent << :mon; end; def self.flush_primitives; $sent << :flush; end; end
    end
    $sent.clear
    P.before_battle
    out[:facts] = $sent.dup
    # off: nothing is claimed
    P.adopt_mode("off"); $sent.clear
    b.pbGainMoney
    P.before_battle
    out[:off] = claims.call.length + ($sent - [:engine_paid]).length
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
    assert_equal [:payday, [4242], 120, nil], o[:wild], "the coins scattered, doubled by Happy Hour"
    assert_equal [:payday, true, 50], o[:trainer_payday]
    assert_equal 0, o[:no_coins]
    assert_equal %i[pos inv mon flush], o[:facts], "position, bag, party, then the flush"
    assert_equal 0, o[:off]
  end

  # M3, client half: the server pays the prizes itself. The money the engine adds waits
  # for its verdict (the money frames hold, at most HOLD_MAX), then becomes what the
  # server paid; a refused frame already took it back; a fresh login's balance is the
  # server's word. Triple Triad cards are not sold while enforcement runs.
  M3_RUNNER = <<~'RUBY'
    $sent = []; $now = 0.0; $event = 7; $said = []; $ack = nil
    module PBEffects; AmuletCoin = 1; HappyHour = 2; PayDay = 3; end
    module Settings; MAX_MONEY = 999_999; end
    class Player; attr_accessor :money; end
    $player = Player.new; $player.money = 1000
    class NPCTrainer
      attr_reader :trainer_type, :name, :version, :base_money
      def initialize(type, name, version, money); @trainer_type = type; @name = name; @version = version; @base_money = money; end
    end
    module GameData
      class Trainer
        def initialize(type, name, version); @trainer_type = type; @real_name = name; @version = version; end
        def to_trainer; NPCTrainer.new(@trainer_type, @real_name, @version, 20); end
      end
    end
    Field = Struct.new(:effects)
    class Battle
      attr_reader :opponent, :field
      attr_accessor :internalBattle, :moneyGain
      def initialize(opp, levels); @opponent = opp; @levels = levels; @field = Field.new({ 1 => false, 2 => false, 3 => 0 }); @internalBattle = true; @moneyGain = true; end
      def trainerBattle?; true; end
      def pbMaxLevelInTeam(_side, i); @levels[i]; end
      def pbGainMoney   # the engine: the prize, up to the cap
        $player.money = [$player.money + @levels.each_with_index.sum { |l, i| l * @opponent[i].base_money }, 999_999].min
      end
    end
    class PokemonGlobalMetadata; attr_accessor :partner; end
    Map = Struct.new(:map_id)
    $game_map = Map.new(31)
    def pbMapInterpreterRunning?; true; end
    Self = Struct.new(:id)
    def pbMapInterpreter; Struct.new(:x) { def get_self; Self.new($event); end }.new(1); end
    def pbSellTriads; $sent << :cards_sold; end
    def pbMessage(text); $said << text; end
    def _INTL(text, *_args); text; end
    module Graphics; def self.update; $now += 1.0; PEMK::PrizeClaim.on_ack($ack) if $ack && $now >= 3.0; end; end
    module Input; def self.update; end; end
    module PEMK
      def self.enabled?; true; end
      def self.self_id; 7; end
      def self.client; Struct.new(:c) { def connected?; true; end }.new(1); end
      def self.log(_m); end
      def self.send_message(m); $sent << m; end
      module Presence; def self.emit_now(_t); end; end
    end
    load File.join(ARGV[0], "009_BattleData", "007_PrizeClaim.rb")
    P = PEMK::PrizeClaim
    def P.mono; $now; end
    $PokemonGlobal = PokemonGlobalMetadata.new
    anna = -> { GameData::Trainer.new(:LASS, "Anna", 0).to_trainer }
    fight = -> { Battle.new([anna.call], [20]).pbGainMoney; $sent.select { |m| m.is_a?(Hash) }.last[:nonce] }
    ack = ->(n, verdict, paid) { { :type => :money_claim_ack, :nonce => n, :verdict => verdict, :accepted => paid } }
    out = {}

    P.adopt_mode("on")
    n = fight.call                                    # 20 x 20 = 400
    out[:held] = [$player.money, P.holding?]
    P.on_ack(ack.(n, "paid", 400))
    out[:paid] = [$player.money, P.holding?]
    n = fight.call
    P.on_ack(ack.(n, "suspect", 150))                 # the server paid 150 of it
    out[:suspect] = $player.money
    n = fight.call
    P.on_ack(ack.(n, "repeat", 0))
    out[:repeat] = $player.money
    # past HOLD_MAX the frame goes; the server refused it, and the game went back to its
    # balance (1550) without the prize - the late verdict brings what it paid
    n = fight.call
    $now += 61
    out[:released] = P.holding?
    P.frame_refused
    $player.money = 1550
    P.on_ack(ack.(n, "paid", 400))
    out[:late] = $player.money
    # near the cap the engine adds what fits, and so does the server
    $player.money = 999_700
    n = fight.call
    P.on_ack(ack.(n, "paid", 299))
    out[:cap] = $player.money
    # a fresh login adopts the ledger's balance: nothing left to correct
    $player.money = 2000
    fight.call
    P.adopted
    out[:adopted] = [P.holding?, $player.money]
    # a Mart waits for the verdicts - bounded
    n = fight.call
    $ack = ack.(n, "paid", 400); $now = 100.0; start = $now
    out[:settled] = [P.settle(8.0), $now - start <= 8.0]
    $ack = nil
    fight.call
    out[:unsettled] = P.settle(3.0)
    P.adopted
    # Triple Triad: closed while enforced, open otherwise
    pbSellTriads
    P.adopt_mode("shadow")
    pbSellTriads
    out[:triad] = [$said.length, $sent.count(:cards_sold)]
    # shadow: the engine's money stands, nothing is held
    $player.money = 1000
    n = fight.call
    P.on_ack(ack.(n, "suspect", 150))
    out[:shadow] = [$player.money, P.holding?]
    print out.inspect
  RUBY

  def test_enforced_the_money_becomes_what_the_server_paid
    out = IO.popen([RbConfig.ruby, "-W0", "-e", M3_RUNNER, PEMK_DIR], err: %i[child out], &:read)
    assert $?.success?, "M3 runner crashed:\n#{out}"
    o = eval(out) # rubocop:disable Security/Eval -- our own runner's inspect output
    assert_equal [1400, true], o[:held], "the engine added it; the money frames wait"
    assert_equal [1400, false], o[:paid]
    assert_equal 1550, o[:suspect], "400 added, 150 paid"
    assert_equal 1550, o[:repeat], "nothing paid"
    assert_equal false, o[:released], "past HOLD_MAX the frames go"
    assert_equal 1950, o[:late], "the refused frame dropped it: what the server paid comes back"
    assert_equal 999_999, o[:cap], "the engine and the server both stop at the cap"
    assert_equal [false, 2400], o[:adopted]
    assert_equal [true, true], o[:settled], "a Mart waits for the verdict"
    assert_equal false, o[:unsettled], "and gives up after its bound"
    assert_equal [1, 1], o[:triad], "closed while enforced (a message), open in shadow"
    assert_equal [1400, false], o[:shadow], "shadow never touches the game's money"
  end
end
