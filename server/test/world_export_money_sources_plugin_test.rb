require "minitest/autorun"
require "rbconfig"

# Money authority M0: the world export names every way an event can raise the player's
# money, coins or battle points without a request the server answers: Change Gold (code
# 125) increases with their literal amounts - a variable amount is computed - scripts
# that add to a balance, and the calls that pay by themselves (Triple Triad card sales,
# the Game Corner). A spend is not a source.
class WorldExportMoneySourcesPluginTest < Minitest::Test
  EXPORT = File.expand_path("../../Plugins/PEMK/008_World/002_Export.rb", __dir__)

  RUNNER = <<~'RUBY'
    module PEMK; def self.log(_m); end; end
    load ARGV[0]

    Cmd  = Struct.new(:code, :parameters, :indent)
    Cond = Struct.new(:switch1_valid, :switch1_id, :switch2_valid, :switch2_id, :variable_valid,
                      :variable_id, :variable_value, :self_switch_valid, :self_switch_ch)
    Page = Struct.new(:condition, :list)
    Ev   = Struct.new(:id, :x, :y, :pages)
    Common = Struct.new(:id, :list)
    none = Cond.new(false, 1, false, 1, false, 1, 0, false, "A")
    fin  = Cmd.new(0, [], 0)
    ev   = ->(id, *cmds) { Ev.new(id, 3, 4, [Page.new(none, cmds + [fin])]) }
    gold = ->(op, type, operand) { Cmd.new(125, [op, type, operand], 0) }
    s    = ->(t) { Cmd.new(355, [t], 0) }

    COMMONS = [nil, Common.new(1, [s.("$player.coins += 50"), fin]), Common.new(2, [s.("pbMessage(\"hi\")"), fin])]
    def load_data(path)
      raise "no #{path}" unless path.include?("CommonEvents")

      COMMONS
    end

    events = [
      [5, ev.(1, gold.(0, 0, 500), gold.(0, 0, 200), gold.(1, 0, 100))],   # two literal gains and a spend
      [5, ev.(2, gold.(0, 1, 12))],                                        # a gain read from variable 12
      [5, ev.(3, gold.(1, 0, 300))],                                       # a spend only: no source
      [6, ev.(4, s.("$player.money += 1000"))],
      [6, ev.(5, s.("pbSellTriads"))],
      [6, ev.(6, s.("$player.battle_points += $game_variables[3]"))],
      [6, ev.(7, s.("$player.money -= 50"))]                               # a spend in a script
    ]
    print PEMK::WorldExport.money_sources(events).inspect
  RUBY

  def test_every_money_source_an_event_holds
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, EXPORT], err: %i[child out], &:read)
    assert $?.success?, "export runner crashed:\n#{out}"
    o = eval(out) # rubocop:disable Security/Eval -- our own runner's inspect output
    list = o[:events]
    by = ->(k, v) { list.find { |e| e[k] == v } }
    assert_equal({ :map => 5, :event => 1, :calls => ["change_gold"], :fields => ["money"], :amounts => [500, 200],
                   :computed => false }, by.(:event, 1))
    assert_equal [["change_gold"], true], by.(:event, 2).values_at(:calls, :computed)
    assert_nil by.(:event, 3), "a spend is not a source"
    assert_equal [["script"], ["money"], [1000], false], by.(:event, 4).values_at(:calls, :fields, :amounts, :computed)
    assert_equal [["pbSellTriads"], ["money"], true], by.(:event, 5).values_at(:calls, :fields, :computed)
    assert_equal [["script"], ["battle_points"], true], by.(:event, 6).values_at(:calls, :fields, :computed)
    assert_nil by.(:event, 7)
    assert_equal [["script"], ["coins"], [50], false], by.(:common_event, 1).values_at(:calls, :fields, :amounts, :computed)
    assert_nil by.(:common_event, 2)
    assert_equal 6, list.size, "three of the nine hold no source"
  end
end
