require "minitest/autorun"
require "rbconfig"

# Item authority E0, client half: the snapshot counts every store, and a login takes the
# PC exactly and the held items by totals from the server's record - an excess off
# Pokemon the record does not name first, a deficit to the bag, and a Pokemon a trade
# still owes left out.
class ItemStoresPluginTest < Minitest::Test
  PEMK_DIR = File.expand_path("../../Plugins/PEMK", __dir__)

  RUNNER = <<~'RUBY'
    $marks = 0; $log = []
    def pbInBugContest?; false; end
    module GameData
      module Item; def self.exists?(i); %i[POTION LEFTOVERS ORANBERRY GRASSMAIL].include?(i); end; end
    end
    module ItemStorageHelper
      def self.add(items, _max, _per, item, qty); items << [item, qty]; true; end
    end
    class PCItemStorage
      MAX_SIZE = 999; MAX_PER_SLOT = 999
      attr_reader :items
      def initialize; @items = [[:POTION, 1]]; end   # the start item
      def add(i, q = 1); @items << [i, q]; true; end
      def remove(i, q = 1); true; end
      def clear; @items.clear; end
    end
    class Pokemon
      attr_accessor :pemk_uid, :pemk_nonce
      def initialize(uid, item, nonce = nil); @pemk_uid = uid; @item = item; @pemk_nonce = nonce; end
      def item_id; @item; end
      def item=(v); @item = v; end
    end
    MailObj = Struct.new(:item)
    Global = Struct.new(:pcItemStorage, :mailbox, :challenge)
    class Bag
      attr_reader :items
      def initialize; @items = {}; end
      def add(i, q = 1); @items[i] = (@items[i] || 0) + q; true; end
    end
    module PEMK
      def self.log(m); $log << m; end
      module Sync; def self.mark_inv; $marks += 1; end; end
      module Inventory
        @applying = false
        def self.applying; @applying; end
        def self.mark; $marks += 1; end
      end
      module Monsters
        def self.each_owned(&b); $owned.each(&b); end
        def self.find_by_uid(u); $owned.find { |p| p.pemk_uid == u }; end
      end
    end
    load File.join(ARGV[0], "004_Persist", "012_ItemStores.rb")
    I = PEMK::Inventory
    out = {}

    pika = Pokemon.new(1, :LEFTOVERS); eevee = Pokemon.new(2, nil); egg = Pokemon.new(nil, :ORANBERRY)
    $owned = [pika, eevee, egg]
    $PokemonGlobal = Global.new(PCItemStorage.new, [MailObj.new(:GRASSMAIL)], nil)
    out[:stores] = I.stores
    Temp = Struct.new(:in_battle)
    $game_temp = Temp.new(true)
    out[:in_battle] = I.stores          # held items change only for a battle's length: the bag alone
    $game_temp = Temp.new(false)

    $marks = 0
    pika.item = :LEFTOVERS            # unchanged: no mark
    pika.item = nil
    $PokemonGlobal.pcItemStorage.add(:POTION)
    out[:marks] = $marks

    # a login: the save still has on Pokemon 3 what the record says was taken off, and
    # lacks Pokemon 5 and 6 (one lost in a crash, one a trade will bring back)
    ditto = Pokemon.new(3, :LEFTOVERS)
    snorlax = Pokemon.new(4, :LEFTOVERS)
    $owned = [ditto, snorlax]
    $bag = Bag.new
    $PokemonGlobal = Global.new(nil, [], nil)
    I.note_stores({ pc: { POTION: 2, MYSTERY: 1 }, mail: {}, held: { LEFTOVERS: 1, ORANBERRY: 2 },
                    holders: { 3 => nil, 4 => :LEFTOVERS, 5 => :ORANBERRY, 6 => :ORANBERRY } })
    I.restore_stores
    out[:pc] = $PokemonGlobal.pcItemStorage.items
    out[:held] = [ditto.item_id, snorlax.item_id]
    out[:bag] = $bag.items.dup
    out[:after] = I.stores[:pc]

    # another login: the save is older than a give - the record says both hold Leftovers,
    # and it was written before Zapdos got its uid (it knows its mint nonce only)
    mew = Pokemon.new(7, :LEFTOVERS)
    zapdos = Pokemon.new(nil, nil, 555)
    $owned = [mew, zapdos]
    $bag = Bag.new
    I.note_stores({ pc: {}, mail: {}, held: { LEFTOVERS: 2 }, holders: { 7 => :LEFTOVERS, 8 => :LEFTOVERS },
                    nonces: { 8 => 555 } })
    I.restore_stores
    out[:deficit] = [mew.item_id, zapdos.item_id, $bag.items]
    print out.inspect
  RUBY

  def test_every_store_counted_and_restored_by_totals
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, PEMK_DIR], err: %i[child out], &:read)
    assert $?.success?, "item stores runner crashed:\n#{out}"
    o = eval(out) # rubocop:disable Security/Eval -- our own runner's inspect output
    assert_equal({ :pc => { :POTION => 1 }, :mail => { :GRASSMAIL => 1 },
                   :held => { :LEFTOVERS => 1, :ORANBERRY => 1 }, :holders => { 1 => :LEFTOVERS, 2 => nil } },
                 o[:stores], "a Pokemon still without a uid is counted, not named")
    assert_nil o[:in_battle], "during a battle only the bag goes out"
    assert_equal 2, o[:marks], "a real held-item change and a PC change mark the channel"
    assert_equal [[:POTION, 2]], o[:pc], "exactly the record: no start item, the unknown one carried"
    assert_equal [nil, :LEFTOVERS], o[:held], "the Leftovers the record says was taken comes off"
    assert_equal({}, o[:bag], "the missing Pokemon's Oran Berries are not handed over on their own")
    assert_equal({ :POTION => 2, :MYSTERY => 1 }, o[:after], "the carried item stays in the record")
    assert_equal [:LEFTOVERS, :LEFTOVERS, {}], o[:deficit], "back on the Pokemon the record names"
  end
end
