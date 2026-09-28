require "minitest/autorun"
require "rbconfig"

# Item authority E1b: the world export names the ways events produce an item that no
# request names - an item added straight to the bag, a computed gift or item ball, a Game
# Corner prize, a common event's gift - with the item ids written in them, and whether
# the game has berry plants or the mining game.
class WorldExportItemSourcesPluginTest < Minitest::Test
  EXPORT = File.expand_path("../../Plugins/PEMK/008_World/002_Export.rb", __dir__)

  RUNNER = <<~'RUBY'
    module PEMK; def self.log(_m); end; end
    module GameData
      module Item
        IDS = %i[FRESHWATER SODAPOP POKEBALL REDAPRICORN LEVELBALL TM80 SMOKEBALL].freeze
        def self.exists?(i); IDS.include?(i); end
      end
    end
    def load_data(_path); $commons; end
    load ARGV[0]

    Cmd  = Struct.new(:code, :parameters)
    Cond = Struct.new(:switch1_valid, :switch1_id, :switch2_valid, :switch2_id, :variable_valid,
                      :variable_id, :variable_value, :self_switch_valid, :self_switch_ch)
    Page = Struct.new(:condition, :list)
    Ev   = Struct.new(:id, :x, :y, :pages)
    Common = Struct.new(:id, :list)
    none = Cond.new(false, 1, false, 1, false, 1, 0, false, "A")
    ev = ->(id, *cmds) { Ev.new(id, 3, 4, [Page.new(none, cmds)]) }
    s355 = ->(t) { Cmd.new(355, [t]) }
    br   = ->(t) { Cmd.new(111, [12, t]) }
    W = PEMK::WorldExport

    $commons = [nil, Common.new(3, [s355.("pbReceiveItem(:TM80)")]), Common.new(4, [s355.("pbWait(8)")])]
    events = [
      [19, ev.(2, br.("$player.money >= 200"), s355.("$bag.add([:FRESHWATER, :SODAPOP].sample)"))],
      [6,  ev.(2, br.("$bag.has?(:REDAPRICORN)"), s355.("pbSet(1, :LEVELBALL)"), s355.("pbReceiveItem(pbGet(1))"))],
      [13, ev.(28, s355.("pbBuyPrize(:SMOKEBALL)"))],
      [7,  ev.(5, s355.("pbReceiveItem(pbGet(9))"))],
      [5,  ev.(1, br.("pbItemBall(:POKEBALL)"))],
      [5,  ev.(2, s355.("pbReceiveItem(:POKEBALL)"))],
      [5,  ev.(3, s355.("pbBerryPlant"))]
    ]
    print W.item_sources(events).inspect
  RUBY

  def test_the_sources_no_request_names
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, EXPORT], err: %i[child out], &:read)
    assert $?.success?, "export runner crashed:\n#{out}"
    o = eval(out) # rubocop:disable Security/Eval -- our own runner's inspect output
    by = o[:events].to_h { |e| [e[:common_event] ? "c#{e[:common_event]}" : "#{e[:map]}:#{e[:event]}", e] }
    assert_equal [["$bag.add"], %w[FRESHWATER SODAPOP], false], by["19:2"].values_at(:calls, :items, :unbounded)
    assert_equal [["computed"], %w[REDAPRICORN LEVELBALL], false], by["6:2"].values_at(:calls, :items, :unbounded)
    assert_equal [["pbBuyPrize"], %w[SMOKEBALL]], by["13:28"].values_at(:calls, :items)
    assert_equal [["computed"], [], true], by["7:5"].values_at(:calls, :items, :unbounded), "nothing names its item"
    assert_equal [["pbReceiveItem"], %w[TM80]], by["c3"].values_at(:calls, :items), "a common event's literal gift"
    refute by.key?("5:1"), "a literal item ball: its own object"
    refute by.key?("5:2"), "a literal gift: its own object"
    refute by.key?("c4")
    assert_equal [true, false], [o[:berry_plants], o[:mining]]
  end
end
