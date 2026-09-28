require "minitest/autorun"
require "rbconfig"

# A trade's escrow is the offered Pokemon as it was when it was locked. Taking its held
# item off afterwards used to leave the item in both games: the partner got it with the
# escrow, the sender kept it in the bag. The commit now waits for an unchanged Pokemon,
# and a change after the commit is settled when the result comes. Pokemon are also
# found and removed wherever they are owned: the Day Care and fusions included.
class TradeItemPluginTest < Minitest::Test
  PEMK_DIR = File.expand_path("../../Plugins/PEMK", __dir__)

  RUNNER = <<~'RUBY'
    $sent = []; $log = []
    def _INTL(s, *a); a.each_with_index.reduce(s) { |t, (v, i)| t.sub("{#{i + 1}}", v.to_s) }; end
    def pbMessage(*); end
    def pbStorePokemon(p); end
    def pbAddToPartySilent(*); end
    def pbGenerateEgg(*); end
    module MenuHandlers; def self.add(*); end; end
    module EventHandlers; def self.add(*); end; end
    module Settings; MAX_PARTY_SIZE = 6; end
    class Pokemon
      attr_accessor :fused, :species, :form, :name
      def initialize(species, uid, item = nil)
        @species = species; @pemk_uid = uid; @item = item; @form = 0; @name = species.to_s
      end
      def item_id; @item; end
      def item=(v); @item = v; end
      def isSpecies?(s); @species == s; end
      def setForm(f); @form = f; yield if block_given?; end
      def level; 5; end
      def egg?; false; end
    end
    class Slot
      attr_reader :pokemon
      def initialize(p); @pokemon = p; end
      def reset; @pokemon = nil; end
    end
    DayCare = Struct.new(:slots)
    Storage = Struct.new(:boxes)
    Global  = Struct.new(:day_care, :pcItemStorage)
    Player  = Struct.new(:party, :name)
    class Bag
      attr_reader :items
      def initialize(h); @items = h; end
      def has?(i); (@items[i] || 0) > 0; end
      def add(i, q = 1); @items[i] = (@items[i] || 0) + q; true; end
      def remove(i, q = 1); return false unless has?(i); @items[i] -= q; @items.delete(i) if @items[i] <= 0; true; end
      def replace_item(a, b); @items[b] = @items.delete(a); true; end
    end
    module PEMK
      def self.log(m); $log << m; end
      def self.self_id; 1; end
      def self.send_message(m, _b = nil); $sent << m; end
      module Sync; def self.mark_mon; end; end
      module Checkpoint; def self.request(_r); end; end
    end
    load File.join(ARGV[0], "004_Persist", "006_Monsters.rb")
    load File.join(ARGV[0], "007_Trade", "001_Trade.rb")
    M = PEMK::Monsters
    T = PEMK::Trade

    pika   = Pokemon.new(:PIKACHU, 1, :LEFTOVERS)
    boxed  = Pokemon.new(:EEVEE, 2)
    parked = Pokemon.new(:DITTO, 3)
    kyurem = Pokemon.new(:KYUREM, 4)
    zekrom = Pokemon.new(:ZEKROM, 5)
    kyurem.fused = zekrom
    kyurem.form = 2
    $player = Player.new([pika, kyurem], "Red")
    $PokemonStorage = Storage.new([[nil, boxed]])
    $PokemonGlobal = Global.new(DayCare.new([Slot.new(parked), Slot.new(nil)]), nil)
    $bag = Bag.new({ DNASPLICERSUSED: 1 })
    out = {}

    seen = []
    M.each_owned { |p| seen << p.pemk_uid }
    out[:owned] = seen.sort
    out[:where] = [1, 2, 3, 5, 9].map { |u| M.locate(u)[0] }

    # the escrow of Pikachu (holding Leftovers) is locked
    T.instance_variable_set(:@session, { :trade_id => "t", :partner => 2, :partner_name => "Bob",
                                         :my_uid => 1, :my_pkmn => pika, :my_item => :LEFTOVERS,
                                         :my_locked => true, :their_obj => Pokemon.new(:EEVEE, 9),
                                         :their_uid => 9, :phase => :locked_waiting })
    pika.item = nil
    $bag.add(:LEFTOVERS)                      # taken off it while the partner decides
    T.maybe_commit
    out[:cancelled] = [$sent.map { |m| m[:type] }, T.instance_variable_get(:@session).nil?]

    # the same change after the commit: settled when the swap is reported
    $sent.clear
    pika.item = :LEFTOVERS
    $bag.remove(:LEFTOVERS)
    T.instance_variable_set(:@session, { :trade_id => "t2", :partner => 2, :partner_name => "Bob",
                                         :my_uid => 1, :my_pkmn => pika, :my_item => :LEFTOVERS,
                                         :my_locked => true, :their_obj => Pokemon.new(:EEVEE, 9),
                                         :their_uid => 9, :phase => :committing })
    pika.item = :ORANBERRY
    $bag.add(:LEFTOVERS)
    $bag.remove(:ORANBERRY) rescue nil
    T.on_result({ :trade_id => "t2", :ok => true, :recv => [9], :gave => [1] })
    out[:settled] = [$bag.items[:LEFTOVERS], $bag.items[:ORANBERRY], $player.party.map(&:pemk_uid)]

    # a parked and a fused Pokemon are removed where they are
    out[:day_care] = [M.remove_by_uid(3), $PokemonGlobal.day_care.slots[0].pokemon]
    out[:fusion] = [M.remove_by_uid(5), kyurem.fused, kyurem.form, $bag.items.key?(:DNASPLICERS)]

    # a partner's escrow must hold what its lock says (the item the server checks)
    module PEMK; module PeerPokemon; def self.load(body, _what); body; end; end; end
    lock = lambda do |tid, said, held|
      $sent.clear
      T.instance_variable_set(:@session, { :trade_id => tid, :partner => 2, :partner_name => "Bob", :my_uid => 1,
                                           :my_locked => false, :their_uid => 9, :their_species => :EEVEE,
                                           :phase => :confirming })
      T.on_message({ :type => :trade_lock, :from => 2, :to => 1, :trade_id => tid, :uid => 9, :item => said,
                     :_body => Pokemon.new(:EEVEE, 9, held) })
      s = T.instance_variable_get(:@session)
      [$sent.map { |m| m[:type] }, s && s[:their_obj] && s[:their_obj].item_id]
    end
    out[:unsaid] = lock.call("t3", nil, :MASTERBALL)
    out[:said]   = lock.call("t4", :MASTERBALL, :MASTERBALL)
    print out.inspect
  RUBY

  def test_the_offered_pokemon_is_frozen_and_found_everywhere
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, PEMK_DIR], err: %i[child out], &:read)
    assert $?.success?, "trade item runner crashed:\n#{out}"
    o = eval(out) # rubocop:disable Security/Eval -- our own runner's inspect output
    assert_equal [1, 2, 3, 4, 5], o[:owned], "party, box, Day Care and a fused partner"
    assert_equal %i[party box day_care fused] + [nil], o[:where]
    assert_equal [[:trade_cancel], true], o[:cancelled], "a changed offer is never committed"
    assert_equal [nil, 1, [4, 9]], o[:settled], "Oran Berry back, the Leftovers gone with the escrow"
    assert_equal [true, nil], o[:day_care]
    assert_equal [true, nil, 0, true], o[:fusion]
    assert_equal [[:trade_cancel], nil], o[:unsaid], "a held item the lock did not declare cancels the trade"
    assert_equal [[], :MASTERBALL], o[:said]
  end
end
