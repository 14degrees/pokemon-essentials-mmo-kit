require "minitest/autorun"
require "rbconfig"

# E3: a gated deal whose answer misses its wait is in doubt. The server may already
# have moved the money and the items; the client used to drop the late answer, and a
# sale then left the items in the bag and out of the server's record. The client now
# keeps the deal (in the save), asks how it ended by its nonce, holds its money and bag
# frames and any other deal meanwhile, and applies a late grant on a free frame.
class ShopDoubtPluginTest < Minitest::Test
  PEMK_DIR = File.expand_path("../../Plugins/PEMK", __dir__)

  RUNNER = <<~'RUBY'
    $sent = []; $msgs = []; $script = []; $now = 0.0
    def _INTL(s, *a); a.each_with_index.reduce(s) { |t, (v, i)| t.sub("{#{i + 1}}", v.to_s) }; end
    def pbSEPlay(*); end
    def pbMessage(m); $msgs << m; PEMK::Shop.tick; end   # a message runs frames of its own
    def pbMapInterpreterRunning?; false; end
    class Integer; def to_s_formatted; to_s; end; end
    module Settings; BAG_MAX_PER_SLOT = 999; MORE_BONUS_PREMIER_BALLS = true; end
    module Input; def self.update; end; end
    module Graphics
      def self.update
        $now += 0.05
        r = $script.shift
        PEMK::Shop.on_reply(r.call) if r
      end
    end
    ItemData = Struct.new(:id) do
      def is_important?; false; end
      def is_poke_ball?; false; end
      def name; id.to_s.capitalize; end
    end
    module GameData
      module Item
        def self.get(i); ItemData.new(i); end
        def self.exists?(_i); true; end
      end
    end
    Stats = Struct.new(:money_spent_at_marts, :mart_items_bought, :premier_balls_earned, :money_earned_at_marts)
    $stats = Stats.new(0, 0, 0, 0)
    Player = Struct.new(:money, :battle_points)
    $player = Player.new(1000, 50)
    class Bag
      attr_reader :items
      def initialize(h = {}); @items = h; end
      def add(i, q = 1); @items[i] = (@items[i] || 0) + q; true; end
      def remove(i, q = 1); return false if (@items[i] || 0) < q; @items[i] -= q; @items.delete(i) if @items[i] <= 0; true; end
      def quantity(i); @items[i] || 0; end
      def has?(i); (@items[i] || 0) > 0; end
      def can_add?(_i, _q = 1); true; end
    end
    class PokemonGlobalMetadata; attr_accessor :pcItemStorage, :mailbox; end
    class Scene_Map; end
    $scene = Scene_Map.new
    $game_temp = Struct.new(:in_battle, :in_menu, :message_window_showing).new(false, false, false)
    class Adapter
      def getName(i); i.to_s; end
      def getNamePlural(i); "#{i}s"; end
      def getPrice(_i, sell = false); sell ? 150 : 300; end
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
      def pbBuyScreen; end
      def pbSellScreen; end
    end
    module PEMK
      def self.enabled?; true; end
      def self.self_id; 7; end
      def self.client; Struct.new(:c) { def connected?; $up != false; end }.new(1); end
      def self.log(_m); end
      def self.send_message(m); $sent << m; end
      module Config; SHOP_TIMEOUT = 0.3; end
      module Sync; def self.flush_primitives; $sent << { :type => :flush }; end; end
      module GiftClaim; def self.context; [15, 5]; end; end
      module Inventory; def self.atomic?; false; end; def self.away_from_own_party?; false; end; end
      module Trade; def self.busy?; false; end; end
    end
    load File.join(ARGV[0], "004_Persist", "013_ItemCorrect.rb")
    load File.join(ARGV[0], "008_World", "006_Shop.rb")
    S = PEMK::Shop
    def S.mono; $now; end
    $PokemonGlobal = PokemonGlobalMetadata.new
    $bag = Bag.new
    reqs = -> { $sent.select { |m| m[:type] == :shop_req } }
    out = {}

    S.adopt_gate(true)
    S.adopt_recheck(true)
    # a purchase whose answer misses the wait: in doubt, asked about at once
    PokemonMartScreen.new(Scene.new([:POTION], 3), []).pbBuyScreen
    deal, again = reqs.call.last(2)
    out[:doubt] = [$bag.items.dup, $player.money, $PokemonGlobal.pemk_deals_doubt.map { |d| d[1..] },
                   again[:recheck] == true && again[:nonce] == deal[:nonce] && deal[:nonce].is_a?(Integer), S.holding?]
    # no other deal meanwhile, and nothing sent for it
    n = reqs.call.size
    PokemonMartScreen.new(Scene.new([:POTION], 1), []).pbBuyScreen
    out[:held] = [reqs.call.size - n, $msgs.last]
    # the answer comes late: applied on a free frame, once
    S.on_reply({ :type => :shop_grant, :seq => deal[:seq], :nonce => deal[:nonce], :delta => -900, :bonus => 1 })
    S.on_reply({ :type => :shop_grant, :seq => again[:seq], :nonce => deal[:nonce], :delta => -900, :bonus => 1 })
    $msgs.clear
    3.times { S.tick }
    out[:late] = [$bag.items.dup, $player.money, $msgs.dup, S.holding?]

    # a sale in doubt that never reached the server: void, nothing changes
    PokemonMartScreen.new(Scene.new([:POTION], 1), []).pbSellScreen
    sale = reqs.call.last
    S.on_reply({ :type => :shop_deny, :seq => sale[:seq], :nonce => sale[:nonce], :reason => "void" })
    $msgs.clear
    S.tick
    out[:void] = [$bag.items.dup, $player.money, $msgs.dup, S.holding?]

    # a reconnect asks again at once; after that, every ten seconds
    PokemonMartScreen.new(Scene.new([:POTION], 1), []).pbSellScreen
    n = reqs.call.size
    S.reset; S.adopt_gate(true); S.adopt_recheck(true)
    S.tick
    $now += 5; S.tick
    $now += 6; S.tick
    out[:resend] = reqs.call.size - n
    # a fresh login restored money and bag from the server: nothing left in doubt
    S.settled_by_login
    out[:login] = [$PokemonGlobal.pemk_deals_doubt, S.holding?]
    # a server that records no deals: nothing in doubt, the late answer dropped as before
    S.adopt_recheck(false)
    $player.money = 1000
    PokemonMartScreen.new(Scene.new([:POTION], 1), []).pbBuyScreen
    out[:old] = [$PokemonGlobal.pemk_deals_doubt, reqs.call.last.key?(:nonce)]
    print out.inspect
  RUBY

  def test_a_deal_in_doubt_is_asked_again_and_applied_late
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, PEMK_DIR], err: %i[child out], &:read)
    assert $?.success?, "shop runner crashed:\n#{out}"
    o = eval(out) # rubocop:disable Security/Eval -- our own runner's inspect output
    assert_equal [{}, 1000, [[:buy, "POTION", 3, false]], true, true], o[:doubt]
    assert_equal [0, "I'm still waiting to hear back about your last order. Please try again in a moment."], o[:held]
    assert_equal [{ POTION: 3, PREMIERBALL: 1 }, 100, ["The shop confirmed your purchase: Potion x3."], false], o[:late]
    assert_equal [{ POTION: 3, PREMIERBALL: 1 }, 100, [], false], o[:void]
    assert_equal 2, o[:resend], "once at the reconnect, once ten seconds later"
    assert_equal [[], false], o[:login]
    assert_equal [[], false], o[:old]
  end
end

# While a deal is in doubt the sync layer sends no money or bag frame: the server's
# ledger and record keep the deal until its answer comes. Other channels go on.
class ShopDoubtSyncPluginTest < Minitest::Test
  SYNC = File.expand_path("../../Plugins/PEMK/006_Sync/001_Sync.rb", __dir__)

  RUNNER = <<~'RUBY'
    $sent = []; $doubt = true
    module Graphics; @f = 0; def self.frame_count; @f; end; def self.step(n); @f += n; end; end
    class FakeClient
      def connected?; true; end
      def send_message(m, _body = nil); $sent << m[:type]; end
    end
    module PEMK
      def self.client; @client ||= FakeClient.new; end
      def self.log(_m); end
      module Shop; def self.holding?; $doubt; end; end
      module Monsters
        def self.pending_batch(_max = 64); [[], false]; end
        def self.projection; [{ uid: 1, species: :SQUIRTLE, level: 8 }]; end
      end
      module Flags; def self.active?; false; end; end
      module Trade; def self.busy?; false; end; end
      module TeamReport; def self.build; nil; end; end
      module Checkpoint; def self.request(_r); end; end
      module Inventory; def self.full_bag; { "POTION" => 1 }; end; def self.stores; nil; end; end
    end
    $game_temp = Struct.new(:in_battle).new(false)
    load ARGV[0]

    PEMK::Sync.mark_econ(:money, 700)
    PEMK::Sync.mark_inv
    PEMK::Sync.mark_mon
    Graphics.step(400)
    PEMK::Sync.tick                 # the per-frame flush waits
    during_tick = $sent.dup
    PEMK::Sync.flush_primitives     # a direct flush (a save) still sends the rest
    during_flush = $sent.dup
    $sent.clear
    $doubt = false
    Graphics.step(400)
    PEMK::Sync.tick
    print [during_tick, during_flush, $sent].inspect
  RUBY

  def test_no_money_or_bag_frame_leaves_while_a_deal_is_in_doubt
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, SYNC], err: %i[child out], &:read)
    assert $?.success?, "sync runner crashed:\n#{out}"
    assert_equal "[[], [:mon_party], [:econ, :inv]]", out.strip
  end
end
