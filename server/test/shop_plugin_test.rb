require "minitest/autorun"
require "rbconfig"

# Item authority E3, client half: with the shop gate on, a Mart purchase or sale is
# asked first and applied only on a grant, with the money the server settled on; a
# refusal changes nothing. With the gate off, the engine's own screen runs. The
# Battle Point exchange works the same way with BP, under its own gate.
class ShopPluginTest < Minitest::Test
  PEMK_DIR = File.expand_path("../../Plugins/PEMK", __dir__)

  RUNNER = <<~'RUBY'
    $sent = []; $msgs = []; $script = []; $vanilla = 0
    def _INTL(s, *a); a.each_with_index.reduce(s) { |t, (v, i)| t.sub("{#{i + 1}}", v.to_s) }; end
    def pbSEPlay(*); end
    class Integer; def to_s_formatted; to_s; end; end
    module Settings; BAG_MAX_PER_SLOT = 999; MORE_BONUS_PREMIER_BALLS = true; end
    module Input; def self.update; end; end
    module Graphics
      def self.update
        r = $script.shift
        PEMK::Shop.on_reply(r.call) if r
      end
    end
    ItemData = Struct.new(:id, :important, :ball) do
      def is_important?; important; end
      def is_poke_ball?; ball; end
      def portion_name; id.to_s; end
      def portion_name_plural; "#{id}s"; end
    end
    module GameData
      module Item
        def self.get(i); ItemData.new(i, i == :BICYCLE, i == :POKEBALL); end
        def self.exists?(_i); true; end
      end
    end
    Stats = Struct.new(:money_spent_at_marts, :mart_items_bought, :premier_balls_earned, :money_earned_at_marts,
                       :battle_points_spent)
    $stats = Stats.new(0, 0, 0, 0, 0)
    Player = Struct.new(:money, :battle_points)
    $player = Player.new(1000, 50)
    class Bag
      attr_reader :items
      def initialize(h = {}); @items = h; end
      def add(i, q = 1); @items[i] = (@items[i] || 0) + q; true; end
      def remove(i, q = 1); @items[i] -= q; @items.delete(i) if @items[i] <= 0; true; end
      def has?(i); (@items[i] || 0) > 0; end
      def can_add?(_i, _q = 1); true; end
    end
    class Adapter
      def getName(i); i.to_s; end
      def getNamePlural(i); "#{i}s"; end
      def getPrice(i, sell = false); sell ? 150 : 300; end
      def getMoney; $player.money; end
      def setMoney(v); $player.money = v; end
      def addItem(i); $bag.add(i); end
      def removeItem(i); $bag.remove(i); end
      def canSell?(_i); true; end
      def getQuantity(i); $bag.items[i] || 0; end
      def getInventory; $bag; end
    end
    class Scene
      def initialize(picks, qty); @picks = picks; @qty = qty; end
      def pbStartBuyScene(*); end
      def pbEndBuyScene; end
      def pbStartSellScene(*); end
      def pbEndSellScene; end
      def pbChooseBuyItem; @picks.shift; end
      def pbChooseItem; @picks.shift; end
      def pbStartScene(*); end
      def pbEndScene; end
      def pbChooseSellItem; @picks.shift; end
      def pbChooseNumber(*); @qty; end
      def pbConfirm(_m); true; end
      def pbDisplayPaused(m); $msgs << m; end
      def pbShowMoney; end
      def pbHideMoney; end
      def pbRefresh; end
    end
    class PokemonMartScreen
      def initialize(scene, stock); @scene = scene; @stock = stock; @adapter = Adapter.new; end
      def pbConfirm(m); @scene.pbConfirm(m); end
      def pbDisplayPaused(m, &_b); @scene.pbDisplayPaused(m); end
      def pbBuyScreen; $vanilla += 1; end
      def pbSellScreen; $vanilla += 1; end
    end
class BPAdapter
  def getName(i); i.to_s; end
  def getNamePlural(i); "#{i}s"; end
  def getPrice(_i); 16; end
  def getBP; $player.battle_points; end
  def setBP(v); $player.battle_points = v; end
  def addItem(i); $bag.add(i); end
end
class BattlePointShopScreen
  def initialize(scene, stock); @scene = scene; @stock = stock; @adapter = BPAdapter.new; end
  def pbConfirm(m); @scene.pbConfirm(m); end
  def pbDisplayPaused(m, &_b); @scene.pbDisplayPaused(m); end
  def pbBuyScreen; $vanilla += 1; end
end
    module PEMK
      def self.enabled?; true; end
      def self.self_id; 7; end
      def self.client; Struct.new(:c) { def connected?; true; end }.new(1); end
      def self.log(_m); end
      def self.send_message(m); $sent << m; end
      module Config; SHOP_TIMEOUT = 0.3; end
      module Sync; def self.flush_primitives; $sent << { :type => :flush }; end; end
      module GiftClaim; def self.context; [15, 5]; end; end
    end
    load File.join(ARGV[0], "008_World", "006_Shop.rb")
    S = PEMK::Shop
    last_req = -> { $sent.reverse.find { |m| m[:type] == :shop_req } }
    out = {}

    PokemonMartScreen.new(Scene.new([:POTION], 3), []).pbBuyScreen
    out[:off] = [$vanilla, $sent.size]

    S.adopt_gate(true)
    $bag = Bag.new
    $script = [-> { { :type => :shop_grant, :seq => last_req.call[:seq], :balance => 100 } }]
    PokemonMartScreen.new(Scene.new([:POTION], 3), []).pbBuyScreen
    r = last_req.call
    out[:buy] = [$bag.items.dup, $player.money, [r[:op], r[:item], r[:quantity], r[:unit_price], r[:map], r[:event]],
                 $sent.map { |m| m[:type] }]

    $sent.clear; $msgs.clear
    $player.money = 1000                 # enough by the client's count; the server says no
    $script = [-> { { :type => :shop_deny, :seq => last_req.call[:seq], :reason => "money" } }]
    PokemonMartScreen.new(Scene.new([:POTION], 1), []).pbBuyScreen
    out[:denied] = [$bag.items.dup, $player.money, $msgs.dup]

    $script = []
    PokemonMartScreen.new(Scene.new([:POTION], 1), []).pbBuyScreen
    out[:silence] = [$bag.items.dup, $player.money]

    $script = [-> { { :type => :shop_grant, :seq => last_req.call[:seq] } }]   # shadow: no balance
    PokemonMartScreen.new(Scene.new([:POTION], 2), []).pbSellScreen
    out[:sell] = [$bag.items.dup, $player.money, last_req.call[:op]]

# the Battle Point exchange has its own gate: the Mart's alone leaves it vanilla
$sent.clear; $msgs.clear; $vanilla = 0
BattlePointShopScreen.new(Scene.new([:PROTEIN], 2), []).pbBuyScreen
out[:bp_off] = [$vanilla, $sent.size]
S.adopt_bp_gate(true)
$bag = Bag.new
$script = [-> { { :type => :shop_grant, :seq => last_req.call[:seq], :balance => 18 } }]
BattlePointShopScreen.new(Scene.new([:PROTEIN], 2), []).pbBuyScreen
r = last_req.call
out[:bp_buy] = [$bag.items.dup, $player.battle_points, [r[:op], r[:item], r[:quantity], r[:unit_price], r[:bp]]]
$msgs.clear
$script = [-> { { :type => :shop_deny, :seq => last_req.call[:seq], :reason => "bp" } }]
BattlePointShopScreen.new(Scene.new([:PROTEIN], 1), []).pbBuyScreen
out[:bp_denied] = [$bag.items.dup, $player.battle_points, $msgs.dup]
    print out.inspect
  RUBY

  def test_mart_deals_are_asked_first
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, PEMK_DIR], err: %i[child out], &:read)
    assert $?.success?, "shop runner crashed:\n#{out}"
    o = eval(out) # rubocop:disable Security/Eval -- our own runner's inspect output
    assert_equal [1, 0], o[:off], "the gate off: the engine's screen, nothing asked"
    assert_equal({ :POTION => 3 }, o[:buy][0])
    assert_equal 100, o[:buy][1], "the balance the server settled on"
    assert_equal [:buy, "POTION", 3, 300, 15, 5], o[:buy][2]
    assert_equal %i[flush shop_req], o[:buy][3], "the money channel goes out before the ask"
    assert_equal [{ :POTION => 3 }, 1000, ["You don't have enough money."]], o[:denied]
    assert_equal [{ :POTION => 3 }, 1000], o[:silence], "nothing bought unasked"
    assert_equal [{ :POTION => 1 }, 1300, :sell], o[:sell], "shadow: the vanilla money change"
assert_equal [1, 0], o[:bp_off], "a server that only gates the Mart: the engine's exchange"
assert_equal [{ :PROTEIN => 2 }, 18, [:buy, "PROTEIN", 2, 16, true]], o[:bp_buy], "the BP the server settled on"
assert_equal [{ :PROTEIN => 2 }, 18, ["I'm sorry, you don't have enough BP."]], o[:bp_denied]
  end
end
