require "minitest/autorun"
require "rbconfig"

# The server answers each :econ frame with the balance it kept. The client used to apply
# every answer as the new balance, whatever frame it answered: a late answer to an older
# frame undid a newer change, and a change made while the answer was on its way was lost
# once the next change marked a value without it. Only the answer to a field's latest
# frame counts now, and it lands as a delta on a change still waiting to go out.
class EconReplyPluginTest < Minitest::Test
  SYNC     = File.expand_path("../../Plugins/PEMK/006_Sync/001_Sync.rb", __dir__)
  DISPATCH = File.expand_path("../../Plugins/PEMK/003_Game/004_Dispatch.rb", __dir__)

  RUNNER = <<~'RUBY'
    $sent = []
    module Graphics; @f = 0; def self.frame_count; @f; end; end
    class FakeClient
      def connected?; true; end
      def send_message(m, _body = nil); $sent << m; end
    end
    module PEMK
      def self.client; @client ||= FakeClient.new; end
      def self.log(_m); end
      module Monsters; def self.pending_batch(_max = 64); [[], false]; end; def self.projection; nil; end; end
      module Flags; def self.active?; false; end; end
      module Trade; def self.busy?; false; end; end
      module TeamReport; def self.build; nil; end; end
      module Checkpoint; def self.request(_r); end; end
      module Inventory; def self.full_bag; nil; end; def self.stores; nil; end; end
    end
    $game_temp = Struct.new(:in_battle).new(false)
    class Player
      attr_accessor :money
      def pokemmo_apply_economy(field, value); @money = value if field == :money; end
      def pokemmo_apply_badges_mask(mask); $mask = mask; end
    end
    $player = Player.new
    load ARGV[0]
    load ARGV[1]

    change = ->(v) { $player.money = v; PEMK::Sync.mark_econ(:money, v) }
    flush  = lambda do |field = :money|
      $sent.clear
      PEMK::Sync.flush_primitives
      $sent.find { |m| m[:type] == :econ && m[:field] == field }
    end
    answer = ->(type, frame, value) { PEMK::Dispatch.handle({ type: type, field: frame[:field], value: value, seq: frame[:seq] }) }

    out = {}
    # an older frame's answer lands after a newer frame's
    change.(1100); f1 = flush.()
    change.(1200); f2 = flush.()
    answer.(:econ_ack, f2, 1200)
    answer.(:econ_ack, f1, 1100)
    out[:stale] = $player.money
    # the latest frame's answer, with a newer change waiting to go out
    change.(1300); f3 = flush.()
    change.(1350)
    answer.(:econ_ack, f3, 1300)
    out[:waiting] = [$player.money, flush.()[:value]]
    # a correction to the latest frame, with a newer change waiting: a delta on it
    change.(2000); f5 = flush.()
    change.(2100)
    answer.(:econ_rej, f5, 1350)
    out[:corrected] = [$player.money, flush.()[:value]]
    # nothing waiting: the answer is the balance, as before
    change.(1500); f7 = flush.()
    answer.(:econ_rej, f7, 1450)
    out[:plain] = $player.money
    # badges: a bitmask waits for the newer frame's own answer
    PEMK::Sync.mark_econ(:badges, 1); b1 = flush.(:badges)
    PEMK::Sync.mark_econ(:badges, 3)
    answer.(:econ_ack, b1, 1)
    out[:badges] = [$mask, flush.(:badges)[:value]]
    print out.inspect
  RUBY

  def test_only_the_latest_answer_counts_and_a_waiting_change_survives
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, SYNC, DISPATCH], err: %i[child out], &:read)
    assert $?.success?, "econ runner crashed:\n#{out}"
    o = eval(out) # rubocop:disable Security/Eval -- our own runner's inspect output
    assert_equal 1200, o[:stale], "an older frame's answer does not undo the newer one"
    assert_equal [1350, 1350], o[:waiting], "the waiting change stays, and goes out"
    assert_equal [1450, 1450], o[:corrected], "the server's correction, plus the change made since"
    assert_equal 1450, o[:plain]
    assert_equal [nil, 3], o[:badges]
  end

  # M3: the money waits for the verdicts of this session's prizes; the other fields go.
  # A money frame the server refused as unexplained tells the prize claims.
  HOLD_RUNNER = <<~'RUBY'
    $sent = []; $refused = 0
    module Graphics; @f = 0; def self.frame_count; @f; end; end
    class FakeClient
      def connected?; true; end
      def send_message(m, _body = nil); $sent << m; end
    end
    module PEMK
      def self.client; @client ||= FakeClient.new; end
      def self.log(_m); end
      module Monsters; def self.pending_batch(_max = 64); [[], false]; end; def self.projection; nil; end; end
      module Flags; def self.active?; false; end; end
      module Trade; def self.busy?; false; end; end
      module TeamReport; def self.build; nil; end; end
      module Checkpoint; def self.request(_r); end; end
      module Inventory; def self.full_bag; nil; end; def self.stores; nil; end; end
      module PrizeClaim
        @held = false
        def self.holding?; @held; end
        def self.hold(v); @held = v; end
        def self.frame_refused; $refused += 1; end
      end
    end
    $game_temp = Struct.new(:in_battle).new(false)
    class Player
      attr_accessor :money
      def pokemmo_apply_economy(field, value); @money = value if field == :money; end
    end
    $player = Player.new
    load ARGV[0]
    load ARGV[1]
    fields = -> { $sent.select { |m| m[:type] == :econ }.map { |m| [m[:field], m[:value]] } }
    out = {}
    PEMK::PrizeClaim.hold(true)
    $player.money = 1400
    PEMK::Sync.mark_econ(:money, 1400)
    PEMK::Sync.mark_econ(:coins, 50)
    PEMK::Sync.flush_primitives
    out[:held] = [fields.call, PEMK::Sync.dirty?]
    $sent.clear
    PEMK::PrizeClaim.hold(false)
    PEMK::Sync.flush_primitives
    out[:released] = fields.call
    frame = $sent.find { |m| m[:type] == :econ }
    PEMK::Dispatch.handle({ type: :econ_rej, field: :money, value: 1000, seq: frame[:seq], reason: "unexplained" })
    PEMK::Dispatch.handle({ type: :econ_rej, field: :money, value: 1000, seq: frame[:seq], reason: "cap" })
    out[:refused] = [$refused, $player.money]
    print out.inspect
  RUBY

  def test_the_money_waits_for_the_prize_verdicts
    out = IO.popen([RbConfig.ruby, "-W0", "-e", HOLD_RUNNER, SYNC, DISPATCH], err: %i[child out], &:read)
    assert $?.success?, "hold runner crashed:\n#{out}"
    o = eval(out) # rubocop:disable Security/Eval -- our own runner's inspect output
    assert_equal [[[:coins, 50]], true], o[:held], "the coins go; the money waits, still to send"
    assert_equal [[:money, 1400]], o[:released]
    assert_equal [1, 1000], o[:refused], "an unexplained refusal tells the claims; the game takes the balance"
  end
end
