require "minitest/autorun"
require "rbconfig"

# Item authority E1: the world export says what a clerk sells (every literal stock list
# of its Mart or Battle Point shop call, merged across badge branches) and how many an
# item ball gives. E3: every price a clerk's Mart calls may use, followed through the
# event the way the interpreter runs it - nil standing for the catalogue's.
class WorldExportShopPluginTest < Minitest::Test
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
    fin  = ->(ind = 0) { Cmd.new(0, [], ind) }
    # an event of one page; the editor ends every list with a blank command
    ev   = ->(*cmds) { Ev.new(8, 3, 4, [Page.new(none, cmds + [fin.()])]) }
    c    = ->(code, params, ind = 0) { Cmd.new(code, params, ind) }
    s    = ->(t, ind = 0) { Cmd.new(355, [t], ind) }
    s655 = ->(t, ind = 0) { Cmd.new(655, [t], ind) }
    br   = ->(t, ind = 0) { Cmd.new(111, [12, t], ind) }
    els  = ->(ind = 0) { Cmd.new(411, [], ind) }
    bend = ->(ind = 0) { Cmd.new(412, [], ind) }
    classify = ->(e) { PEMK::WorldExport.classify_event(e) }

    COMMONS = []
    COMMONS[5] = Common.new(5, [Cmd.new(355, ["setPrice(:POTION, 100)"], 0), Cmd.new(0, [], 0)])
    def load_data(path)
      raise "no #{path}" unless path.include?("CommonEvents")

      COMMONS
    end

    out = {}
    # badge branches: each hands the Mart a longer list; the second sets a price first
    out[:mart] = classify.(ev.(br.("$player.badge_count >= 3"), s.("pbPokemonMart([", 1),
                               s655.("  :POKEBALL, :GREATBALL,", 1), s655.("  :POTION", 1), s655.("])", 1),
                               c.(115, [], 1), fin.(1), bend.(),
                               br.("$player.badge_count >= 1"), s.("setPrice(:POTION, 250)", 1),
                               s.("pbPokemonMart([:POKEBALL, :POTION])", 1), fin.(1), bend.()))
    # the engine's rules: a buy price alone sells at it too; a sell price is doubled;
    # -1 (and a buy price of 0) leaves a price as it is
    out[:rules] = classify.(ev.(s.("setPrice(:GREATBALL, 450)"), s655.("setPrice(:POKEBALL, 150, 40)"),
                                s655.("setSellPrice(:POTION, 0)"), s655.("setPrice(:ANTIDOTE, -1, 60)"),
                                s655.("setPrice(:REPEL, 0, 100)"),
                                s655.("pbPokemonMart([:GREATBALL, :POKEBALL, :POTION, :ANTIDOTE, :REPEL])")))
    # the Lerucean stall: a Saturday sale on one branch, a key item's price on every visit,
    # two Mart calls (the first ends the event)
    out[:sale] = classify.(ev.(br.("pbIsWeekday(0, 6)"), s.("setPrice(:GREATBALL, 450)", 1), fin.(1), bend.(),
                               s.("setPrice(:SILPHSCOPE, 5000)"),
                               c.(111, [0, 12, 0]), s.("pbPokemonMart([:SILPHSCOPE, :GREATBALL, :LEMONADE])", 1),
                               c.(115, [], 1), fin.(1), bend.(),
                               s.("pbPokemonMart([:SILPHSCOPE, :GREATBALL])")))
    # if / else, each setting its own price: never the catalogue's
    out[:else] = classify.(ev.(br.("cond"), s.("setPrice(:POTION, 100)", 1), fin.(1), els.(),
                               s.("setPrice(:POTION, 200)", 1), fin.(1), bend.(),
                               s.("pbPokemonMart([:POTION])")))
    # a choice's price does not reach the next choice's Mart
    out[:choices] = classify.(ev.(c.(102, [%w[Cheap Dear], 0]), c.(402, [0, "Cheap"]),
                                  s.("setPrice(:POTION, 100)", 1), fin.(1), c.(402, [1, "Dear"]),
                                  s.("pbPokemonMart([:POTION])", 1), fin.(1), c.(404, [])))
    # a Mart in a loop: its second visit has forgotten the price
    out[:loop] = classify.(ev.(s.("setPrice(:POTION, 100)"), c.(112, []), s.("pbPokemonMart([:POTION])", 1),
                               fin.(1), c.(413, [])))
    # a jump back to a label: the price set after the Mart reaches it the next time
    out[:label] = classify.(ev.(c.(118, ["top"]), s.("pbPokemonMart([:POTION])"), c.(108, ["-"]),
                                s.("setPrice(:POTION, 100)"), c.(119, ["top"])))
    # Ruby control flow in the script: the price may or may not be set
    out[:ruby] = classify.(ev.(s.("setPrice(:POTION, 100) if pbIsWeekday(0, 6)"), s655.("pbPokemonMart([:POTION])")))
    # a price set by a common event the clerk calls
    out[:common] = classify.(ev.(c.(117, [5]), s.("pbPokemonMart([:POTION])")))
    # a Mart that buys nothing back, and a price the export cannot read
    out[:nosell] = classify.(ev.(s.("setPrice(:POTION, 100)"), s655.("pbPokemonMart([:POTION], _INTL(\"Hi, there!\"), true)")))
    out[:unread] = classify.(ev.(s.("setPrice(:POTION, $game_variables[5])"), s655.("pbPokemonMart([:POTION])")))
    out[:bp] = classify.(ev.(s.("setPrice(:PROTEIN, 8)"), s655.("pbBattlePointShop([:PROTEIN, :IRON])")))
    out[:computed] = classify.(ev.(s.("pbPokemonMart(stock_for_today)")))
    out[:ball] = classify.(ev.(s.("pbItemBall(:RARECANDY, 2)")))
    out[:one] = classify.(ev.(br.("pbItemBall(:POTION)")))
    print out.inspect
  RUBY

  def export
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, EXPORT], err: %i[child out], &:read)
    assert $?.success?, "export runner crashed:\n#{out}"
    eval(out) # rubocop:disable Security/Eval -- our own runner's inspect output
  end

  def test_shops_and_item_balls
    o = export
    assert_equal "mart", o[:mart][:kind]
    assert_equal %w[POKEBALL GREATBALL POTION], o[:mart][:items]
    assert_equal false, o[:mart][:dynamic]
    assert_equal ["bp_shop", %w[PROTEIN IRON]], [o[:bp][:kind], o[:bp][:items]]
    assert_equal [[], true], [o[:computed][:items], o[:computed][:dynamic]]
    assert_equal ["item", "RARECANDY", 2], [o[:ball][:kind], o[:ball][:item], o[:ball][:quantity]]
    assert_equal ["POTION", 1], [o[:one][:item], o[:one][:quantity]]
  end

  def test_the_prices_a_clerks_mart_calls_may_use
    o = export
    assert_equal({ "POTION" => [nil, 250] }, o[:mart][:price_options], "one branch sets it, the other does not")
    assert_equal({ "POTION" => [nil, 250] }, o[:mart][:sell_options])
    assert_equal({ "POTION" => 250 }, o[:mart][:prices], "what an older server reads")

    assert_equal({ "GREATBALL" => [450], "POKEBALL" => [150] }, o[:rules][:price_options])
    assert_equal({ "ANTIDOTE" => [120], "GREATBALL" => [450], "POKEBALL" => [80], "POTION" => [0], "REPEL" => [200] },
                 o[:rules][:sell_options])
    assert_equal({ "GREATBALL" => 450, "POKEBALL" => 150 }, o[:rules][:prices])

    assert_equal({ "GREATBALL" => [nil, 450], "SILPHSCOPE" => [5000] }, o[:sale][:price_options],
                 "the sale on some days; the key item never at the catalogue's")
    assert_equal({ "POTION" => [100, 200] }, o[:else][:price_options])
    assert_equal({}, o[:choices][:price_options], "the Mart is on the other choice")
    assert_equal({ "POTION" => [nil, 100] }, o[:loop][:price_options])
    assert_equal({ "POTION" => [nil, 100] }, o[:label][:price_options])
    assert_equal({ "POTION" => [nil, 100] }, o[:ruby][:price_options])
    assert_equal({ "POTION" => [100] }, o[:common][:price_options])
    assert_equal({ "PROTEIN" => [8] }, o[:bp][:price_options])
    assert_nil o[:bp][:sell_options], "the exchange buys nothing back"
  end

  def test_a_clerk_that_buys_nothing_back_or_computes_a_price
    o = export
    assert_equal false, o[:nosell][:sells]
    assert_nil o[:rules][:sells], "only said when false"
    assert_equal ["setPrice(:POTION, $game_variables[5])"], o[:unread][:unread]
    assert_equal({}, o[:unread][:price_options], "not a price the server can check")
    assert_nil o[:rules][:unread]
  end
end
