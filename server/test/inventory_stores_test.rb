require "minitest/autorun"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk"

# Item authority E0: the bag's record also keeps the PC storage, the mailbox and the
# held items the same snapshot counted, and hands them back at login only while the
# last snapshot carried them all.
class InventoryStoresTest < Minitest::Test
  CAPS = { per_item: 99_999, distinct: 2_000, total: 10_000_000 }.freeze

  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    %i[trade_deliveries monster_transfers monsters enforcement_events inventory_snapshots].each { |t| @db[t].delete rescue nil }
    @db[:accounts].delete
    @a = @db[:accounts].insert(email: "is-a@x.co", password_hash: "x", status: "active", created_at: Time.now)
    @inv = PEMK::Inventory.new(@db, CAPS)
  end

  def teardown
    @db&.disconnect
  end

  def stores(pc: { POTION: 3 }, mail: { GRASSMAIL: 1 }, held: { LEFTOVERS: 1 }, holders: { 7 => :LEFTOVERS, 8 => nil })
    { pc: pc, mail: mail, held: held, holders: holders }
  end

  def test_the_stores_ride_the_bag_and_come_back_at_login
    assert_equal :ack, @inv.apply_inv(@a, { ORANBERRY: 2 }, 1, stores: stores)[0]
    snap = @inv.snapshot(@a)
    assert_equal({ ORANBERRY: 2 }, snap[:bag])
    assert_equal({ POTION: 3 }, snap[:stores][:pc])
    assert_equal({ GRASSMAIL: 1 }, snap[:stores][:mail])
    assert_equal({ LEFTOVERS: 1 }, snap[:stores][:held])
    assert_equal({ 7 => :LEFTOVERS }, snap[:stores][:holders], "the restore needs only those holding something")
  end

  # A save written before a Pokemon's uid arrived knows it by its mint nonce.
  def test_the_holders_come_with_their_mint_nonces
    uid = @db[:monsters].insert(owner_account_id: @a, issuer_account_id: @a, client_nonce: 555, species: "PIKACHU",
                                level_at_issue: 5, personal_id: 1, egg_at_issue: false, status: "active", flagged: false)
    @inv.apply_inv(@a, {}, 1, stores: stores(holders: { uid => :LEFTOVERS }))
    assert_equal({ uid => 555 }, @inv.snapshot(@a)[:stores][:nonces])
  end

  # An older client sent the bag alone afterwards: the stores are stale, the save's win.
  def test_a_bag_only_snapshot_makes_the_stores_stale
    @inv.apply_inv(@a, { ORANBERRY: 2 }, 1, stores: stores)
    @inv.apply_inv(@a, { ORANBERRY: 1 }, 2)
    assert_nil @inv.snapshot(@a)[:stores]
    @inv.apply_inv(@a, { ORANBERRY: 1 }, 3, stores: stores(pc: nil))
    snap = @inv.snapshot(@a)
    assert_nil snap[:stores][:pc], "a game that never created its PC storage"
    refute_nil snap[:stores][:held]
  end

  def test_malformed_stores_are_flagged_and_not_kept
    flags = @inv.apply_inv(@a, { ORANBERRY: 2 }, 1, stores: stores(holders: { "7" => :LEFTOVERS }))[1]
    assert_includes flags, "bad_stores"
    assert_nil @inv.snapshot(@a)[:stores]
    assert_equal({ ORANBERRY: 2 }, @inv.snapshot(@a)[:bag], "the bag itself is still recorded")
  end

  def test_what_a_pokemon_holds_by_the_record
    @inv.apply_inv(@a, {}, 1, stores: stores)
    assert_equal :LEFTOVERS, @inv.holder_item(@a, 7)
    assert_nil @inv.holder_item(@a, 8)
    assert_equal :unknown, @inv.holder_item(@a, 9)
    @inv.apply_inv(@a, {}, 2)
    assert_equal :unknown, @inv.holder_item(@a, 7), "not whole any more"
  end

  def test_a_traded_pokemon_takes_its_item_out_of_the_record
    @inv.apply_inv(@a, {}, 1, stores: stores(held: { LEFTOVERS: 2 }, holders: { 7 => :LEFTOVERS, 5 => :LEFTOVERS, 8 => nil }))
    @inv.drop_holder(@a, 7)
    @inv.drop_holder(@a, 8)
    snap = @inv.snapshot(@a)[:stores]
    assert_equal({ LEFTOVERS: 1 }, snap[:held])
    assert_equal({ 5 => :LEFTOVERS }, snap[:holders])
  end

  def test_totals_add_every_store
    t = PEMK::Inventory.totals({ RARECANDY: 1 }, { pc: { RARECANDY: 4 }, mail: {}, held: { RARECANDY: 1 } })
    assert_equal 6, t[:RARECANDY]
    assert_equal 1, PEMK::Inventory.totals({ RARECANDY: 1 }, nil)[:RARECANDY]
  end
end
