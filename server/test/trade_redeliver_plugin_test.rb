require "minitest/autorun"
require "rbconfig"

# A traded Pokemon the save never got comes back from the server: the client asks once
# its save is loaded, adds one whose uid is missing (and reports it, before the
# checkpoint that saves it), only reports one it already holds, ignores one that does
# not match, and drops what the account traded away while the link was down.
class TradeRedeliverPluginTest < Minitest::Test
  TRADE = File.expand_path("../../Plugins/PEMK/007_Trade/002_Redeliver.rb", __dir__)

  RUNNER = <<~'RUBY'
    $sent = []; $msgs = []; $added = []; $evicted = []; $saves = []; $held = [6]
    def _INTL(s, *a); a.each_with_index.reduce(s) { |t, (v, i)| t.sub("{#{i + 1}}", v.to_s) }; end
    def pbMessage(s); $msgs << s; end
    def pbMapInterpreterRunning?; false; end
    module EventHandlers; def self.add(*); end; end
    class Scene_Map; end
    class Pokemon
      attr_accessor :pemk_uid, :name
      def initialize(uid, name); @pemk_uid = uid; @name = name; end
    end
    Temp = Struct.new(:in_battle, :in_menu, :message_window_showing)
    module PEMK
      def self.self_id; 7; end
      def self.log(_m); end
      def self.send_message(m); $sent << m; end
      module PeerPokemon; def self.load(b, _w); Marshal.load(b); end; end
      module Monsters
        def self.find_by_uid(u); $held.include?(u) ? :there : nil; end
        def self.materialize(p); $added << p.pemk_uid; $held << p.pemk_uid; true; end
        def self.evict(l); $evicted.concat(l); end
      end
      module Sync; def self.mark_mon; end; end
      module Checkpoint; def self.request(r); $saves << [r, $sent.last && $sent.last[:type]]; end; end
      module Trade; @busy = false; def self.busy?; @busy; end; def self.busy=(v); @busy = v; end; end
    end
    load ARGV[0]
    R = PEMK::TradeRedeliver
    $player = true
    $scene = Scene_Map.new
    $game_temp = Temp.new(false, false, false)
    out = {}

    R.ask_owed
    R.applied("t0")
    out[:off] = $sent.dup

    R.adopt(true)
    R.ask_owed
    out[:asked] = $sent.map { |m| m[:type] }
    $sent.clear

    R.on_redeliver({ :uid => 5, :trade_id => "t1", :_body => Marshal.dump([Pokemon.new(5, "Eevee")]) })
    R.on_redeliver({ :uid => 6, :trade_id => "t2", :_body => Marshal.dump([Pokemon.new(6, "Pidgey")]) })
    R.on_redeliver({ :uid => 8, :trade_id => "t3", :_body => Marshal.dump([Pokemon.new(7, "Mew")]) })
    PEMK::Trade.busy = true
    R.tick
    out[:busy] = [$added.dup, $sent.size]
    PEMK::Trade.busy = false
    R.tick
    R.tick
    R.tick
    out[:added] = $added.dup
    out[:reports] = $sent.map { |m| [m[:type], m[:trade_id]] }
    out[:saves] = $saves.dup
    out[:msgs] = $msgs.dup

    R.note_evict([9, 10])
    R.tick
    out[:evicted] = $evicted.dup
    R.reset
    R.ask_owed
    out[:after_reset] = $sent.size
    print out.inspect
  RUBY

  def test_redelivery
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, TRADE], err: %i[child out], &:read)
    assert $?.success?, "redeliver runner crashed:\n#{out}"
    o = eval(out) # rubocop:disable Security/Eval -- our own runner's inspect output
    assert_equal [], o[:off], "nothing is asked of a server that keeps nothing"
    assert_equal [:trade_owed], o[:asked]
    assert_equal [[], 0], o[:busy], "never during a trade"
    assert_equal [5], o[:added], "the missing one is added; the held one and the mismatch are not"
    assert_equal [[:trade_applied, "t1"], [:trade_applied, "t2"]], o[:reports]
    assert_equal [[:trade, :trade_applied]], o[:saves], "the report goes out before the save is asked for"
    assert_equal ["Eevee arrived from a trade that was cut short."], o[:msgs]
    assert_equal [9, 10], o[:evicted]
    assert_equal 2, o[:after_reset], "after a reset nothing is asked until the server says so again"
  end
end
