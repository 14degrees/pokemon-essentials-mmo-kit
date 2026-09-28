require "minitest/autorun"
require "rbconfig"

# Item authority E1: the world export says what a clerk sells (every literal stock list
# of its Mart or Battle Point shop call, merged across badge branches, plus the prices
# the event sets) and how many an item ball gives.
class WorldExportShopPluginTest < Minitest::Test
  EXPORT = File.expand_path("../../Plugins/PEMK/008_World/002_Export.rb", __dir__)

  RUNNER = <<~'RUBY'
    module PEMK; def self.log(_m); end; end
    load ARGV[0]

    Cmd  = Struct.new(:code, :parameters)
    Cond = Struct.new(:switch1_valid, :switch1_id, :switch2_valid, :switch2_id, :variable_valid,
                      :variable_id, :variable_value, :self_switch_valid, :self_switch_ch)
    Page = Struct.new(:condition, :list)
    Ev   = Struct.new(:id, :x, :y, :pages)
    none = Cond.new(false, 1, false, 1, false, 1, 0, false, "A")
    ev = ->(*cmds) { Ev.new(8, 3, 4, [Page.new(none, cmds)]) }
    s355 = ->(t) { Cmd.new(355, [t]) }
    s655 = ->(t) { Cmd.new(655, [t]) }
    br   = ->(t) { Cmd.new(111, [12, t]) }
    classify = ->(e) { PEMK::WorldExport.classify_event(e) }

    out = {}
    out[:mart] = classify.(ev.(br.("$player.badge_count >= 3"), s355.("pbPokemonMart(["),
                               s655.("  :POKEBALL, :GREATBALL,"), s655.("  :POTION"), s655.("])"),
                               br.("$player.badge_count >= 1"), s355.("pbPokemonMart([:POKEBALL, :POTION])"),
                               s355.("setPrice(:POTION, 250)")))
    out[:bp] = classify.(ev.(s355.("pbBattlePointShop([:PROTEIN, :IRON])")))
    out[:computed] = classify.(ev.(s355.("pbPokemonMart(stock_for_today)")))
    out[:ball] = classify.(ev.(s355.("pbItemBall(:RARECANDY, 2)")))
    out[:one] = classify.(ev.(br.("pbItemBall(:POTION)")))
    print out.inspect
  RUBY

  def test_shops_and_item_balls
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, EXPORT], err: %i[child out], &:read)
    assert $?.success?, "export runner crashed:\n#{out}"
    o = eval(out) # rubocop:disable Security/Eval -- our own runner's inspect output
    assert_equal "mart", o[:mart][:kind]
    assert_equal %w[POKEBALL GREATBALL POTION], o[:mart][:items]
    assert_equal({ "POTION" => 250 }, o[:mart][:prices])
    assert_equal false, o[:mart][:dynamic]
    assert_equal ["bp_shop", %w[PROTEIN IRON]], [o[:bp][:kind], o[:bp][:items]]
    assert_equal [[], true], [o[:computed][:items], o[:computed][:dynamic]]
    assert_equal ["item", "RARECANDY", 2], [o[:ball][:kind], o[:ball][:item], o[:ball][:quantity]]
    assert_equal ["POTION", 1], [o[:one][:item], o[:one][:quantity]]
  end
end
