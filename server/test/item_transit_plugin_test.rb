require "minitest/autorun"
require "rbconfig"

# Taking a held item adds it to the bag, shows a message, then clears the Pokemon. A
# bag snapshot sent during that message counted the item twice. It now waits for the
# move to finish, and the closing save does not re-serialize one in progress. The
# engine's own dupe - a Mail swap cancelled - is undone.
class ItemTransitPluginTest < Minitest::Test
  PEMK_DIR = File.expand_path("../../Plugins/PEMK", __dir__)

  RUNNER = <<~'RUBY'
    $sent = []; $during = nil; $log = []
    module Graphics; @f = 0; def self.frame_count; @f; end; def self.step(n); @f += n; end; end
    class FakeClient
      def connected?; true; end
      def send_message(m, _body = nil); $sent << [m[:type], m[:bag] && m[:bag].dup]; end
    end
    class PokemonBag
      def initialize; @items = {}; end
      def items; @items; end
      def quantity(i); @items[i] || 0; end
      def add(i, q = 1); @items[i] = quantity(i) + q; true; end
      def remove(i, q = 1); return false if quantity(i) < q; @items[i] -= q; @items.delete(i) if @items[i].zero?; true; end
      def replace_item(a, b); true; end
      def clear; @items.clear; end
      def pockets; [nil, @items.map { |k, v| [k, v] }]; end
    end
    class Mon
      attr_accessor :item_id
      def initialize(i); @item_id = i; end
      def item=(v); @item_id = v; end
    end
    # the message: long enough for the sync tick to want to flush
    class Scene; def say; Graphics.step(400); PEMK::Sync.tick; $during = $sent.size; end; end
    # the engine, as it behaves
    def pbTakeItemFromPokemon(pkmn, scene)
      $bag.add(pkmn.item_id)
      scene.say                                  # "Received the X from Y." - frames run here
      pkmn.item = nil
      true
    end
    def pbGiveItemToPokemon(item, pkmn, _scene, _id = 0)   # swap to Mail, letter cancelled
      $bag.remove(item)
      $bag.add(pkmn.item_id)
      $bag.add(item)
      false
    end
    module PEMK
      def self.client; @client ||= FakeClient.new; end
      def self.log(m); $log << m; end
      module Flags; def self.active?; false; end; end
      module Trade; def self.busy?; false; end; end
      module Monsters; def self.pending_batch(_m = 64); [[], false]; end; def self.projection; nil; end; end
      module TeamReport; def self.build; nil; end; end
      module Checkpoint; def self.request(_r); end; end
    end
    Temp = Struct.new(:in_battle, :in_storage)
    $game_temp = Temp.new(false, false)
    load File.join(ARGV[0], "006_Sync", "001_Sync.rb")
    load File.join(ARGV[0], "004_Persist", "005_Inventory.rb")
    load File.join(ARGV[0], "004_Persist", "011_ItemTransit.rb")

    $bag = PokemonBag.new
    pika = Mon.new(:LEFTOVERS)
    Graphics.step(400)
    PEMK::Sync.reset
    out = {}

    pbTakeItemFromPokemon(pika, Scene.new)
    during = $during
    Graphics.step(400)
    PEMK::Sync.tick
    out[:take] = [during, $sent.map(&:first), $sent.last && $sent.last[1], pika.item_id]

    $game_temp.in_storage = true
    out[:storage] = PEMK::Inventory.atomic?
    $game_temp.in_storage = false

    $bag = PokemonBag.new
    $bag.add(:GRASSMAIL)
    eevee = Mon.new(:ORANBERRY)
    ret = pbGiveItemToPokemon(:GRASSMAIL, eevee, nil)
    out[:mail_cancel] = [ret, eevee.item_id, $bag.items]
    print out.inspect
  RUBY

  def test_an_item_in_transit_is_counted_once
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, PEMK_DIR], err: %i[child out], &:read)
    assert $?.success?, "item transit runner crashed:\n#{out}"
    o = eval(out) # rubocop:disable Security/Eval -- our own runner's inspect output
    assert_equal [0, [:inv], { LEFTOVERS: 1 }, nil], o[:take], "nothing during the message, then the settled bag"
    assert_equal true, o[:storage], "the box screen counts as a move"
    assert_equal [false, :ORANBERRY, { GRASSMAIL: 1 }], o[:mail_cancel], "the Oran Berry is only held"
  end
end
