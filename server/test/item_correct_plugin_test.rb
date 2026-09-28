require "minitest/autorun"
require "rbconfig"

# Item authority E4, client half: the items the server could not account for are taken
# back - only while the snapshot the correction was judged against is still the game's
# last word (its seq, nothing changed since), only on a free overworld frame, the bag
# first, then the PC storage, the mailbox and held items - and the next snapshot names
# the correction applied. One that no longer fits is dropped.
class ItemCorrectPluginTest < Minitest::Test
  PERSIST = File.expand_path("../../Plugins/PEMK/004_Persist", __dir__)

  RUNNER = <<~'RUBY'
    $log = []; $marks = 0; $seq = 7; $dirty = false; $busy = false
    module EventHandlers; def self.add(*); end; end
    class Scene_Map; end
    def pbMapInterpreterRunning?; false; end
    class Store
      def initialize(h); @h = h; end
      def quantity(i); @h[i] || 0; end
      def remove(i, q); return false if quantity(i) < q; @h[i] -= q; @h.delete(i) if @h[i].zero?; true; end
      def to_h; @h.dup; end
    end
    Mail = Struct.new(:item)
    Mon  = Struct.new(:item_id, :mail) do
      def item=(v); self.item_id = v; end
    end
    Global = Struct.new(:pcItemStorage, :mailbox)
    Temp   = Struct.new(:in_battle, :in_menu, :message_window_showing)
    module PEMK
      def self.log(m); $log << m; end
      module Sync
        def self.inv_seq; $seq; end
        def self.inv_dirty?; $dirty; end
      end
      module Trade; def self.busy?; $busy; end; end
      module Inventory
        def self.atomic?; false; end
        def self.away_from_own_party?; false; end
        def self.mark; $marks += 1; $dirty = true; end
      end
      module Monsters
        def self.each_owned(&blk); $mons.each(&blk); end
      end
    end
    load File.join(ARGV[0], "013_ItemCorrect.rb")
    C = PEMK::ItemCorrect

    $player = Object.new
    $scene = Scene_Map.new
    $game_temp = Temp.new(false, false, false)
    $bag = Store.new({ XATTACK: 1, POTION: 5 })
    $PokemonGlobal = Global.new(Store.new({ XATTACK: 1 }), [Mail.new(:GRASSMAIL), Mail.new(:AIRMAIL)])
    $mons = [Mon.new(:XATTACK), Mon.new(:GRASSMAIL, :letter), Mon.new(:XATTACK), Mon.new(nil)]
    out = {}

    # malformed entries are left out; an older correction never replaces a newer one
    C.receive({ :id => 2, :seq => 7, :items => { :XATTACK => 3, :GRASSMAIL => 2, "BAD" => 1, :POTION => -2 } })
    C.receive({ :id => 1, :seq => 6, :items => { :POTION => 5 } })
    out[:pending] = C.pending

    $busy = true
    C.tick
    out[:busy] = [$bag.to_h, C.pending && C.pending[:id]]
    $busy = false

    C.tick
    out[:bag] = $bag.to_h
    out[:pc] = $PokemonGlobal.pcItemStorage.to_h
    out[:mailbox] = $PokemonGlobal.mailbox.map(&:item)
    out[:mons] = $mons.map { |m| [m.item_id, m.mail] }
    out[:took] = $log.grep(/took back/)
    out[:applied] = [C.take_applied, C.take_applied, $marks]

    # a correction for another snapshot, or a possession changed since: dropped
    $log.clear; $dirty = false; $seq = 8
    C.receive({ :id => 3, :seq => 7, :items => { :POTION => 1 } })
    C.tick
    C.receive({ :id => 4, :seq => 8, :items => { :POTION => 1 } })
    $dirty = true
    C.tick
    out[:dropped] = [$bag.to_h[:POTION], $log.grep(/dropped/).size, C.pending]

    C.receive({ :id => 5, :seq => 8, :items => { :POTION => 1 } })
    C.reset
    out[:reset] = C.pending
    print out.inspect
  RUBY

  def run_correct
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, PERSIST], err: %i[child out], &:read)
    assert $?.success?, "correction runner crashed:\n#{out}"
    eval(out) # rubocop:disable Security/Eval -- our own runner's inspect output
  end

  def test_a_correction_applies_to_its_own_snapshot_only
    o = run_correct
    assert_equal({ id: 2, seq: 7, items: { XATTACK: 3, GRASSMAIL: 2 } }, o[:pending])
    assert_equal [{ XATTACK: 1, POTION: 5 }, 2], o[:busy], "never during a trade"
    assert_equal({ POTION: 5 }, o[:bag], "the bag first")
    assert_equal({}, o[:pc], "then the PC")
    assert_equal [:AIRMAIL], o[:mailbox], "then the mailbox"
    assert_equal [[nil, nil], [nil, nil], [:XATTACK, nil], [nil, nil]], o[:mons],
                 "then held items, a letter with its mail; the third X Attack was not asked for"
    assert_equal ["inv: the server took back 3 XATTACK it could not account for",
                  "inv: the server took back 2 GRASSMAIL it could not account for"], o[:took]
    assert_equal [2, nil, 1], o[:applied], "named once, in the next snapshot"
    assert_equal [5, 2, nil], o[:dropped], "another snapshot's, or a changed possession: nothing taken"
    assert_nil o[:reset]
  end
end
