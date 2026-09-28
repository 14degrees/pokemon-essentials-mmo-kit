require "minitest/autorun"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk"

# A traded Pokemon's body is held from the swap until a save after the receiver's
# report lands; anything still held is owed again, only for a uid the receiver owns.
class TradeDeliveriesTest < Minitest::Test
  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    %i[trade_deliveries monster_transfers monsters enforcement_events].each { |t| @db[t].delete rescue nil }
    @db[:accounts].delete
    @a = account("td-a@x.co")
    @b = account("td-b@x.co")
    @uid = mint(@a, 1)
    @td = PEMK::TradeDeliveries.new(@db)
  end

  def teardown
    @db&.disconnect
  end

  def account(email)
    @db[:accounts].insert(email: email, password_hash: "x", status: "active", created_at: Time.now)
  end

  def mint(owner, nonce)
    @db[:monsters].insert(owner_account_id: owner, issuer_account_id: owner, client_nonce: nonce,
                          species: "PIKACHU", level_at_issue: 5, personal_id: 1, egg_at_issue: false,
                          status: "active", flagged: false)
  end

  def deliver(uid = @uid, trade = "t1", body = "\x04\b[\x00".b)
    @td.store([{ account_id: @a, uid: uid, trade_id: trade, body: body }])
  end

  def test_a_stored_delivery_is_owed_with_its_bytes
    deliver
    owed = @td.pending(@a)
    assert_equal 1, owed.size
    assert_equal @uid, owed[0][:uid]
    assert_equal "t1", owed[0][:trade_id]
    assert_equal "\x04\b[\x00".b, owed[0][:body].b
    assert_empty @td.pending(@b)
  end

  def test_the_report_then_a_save_drop_it
    deliver
    @td.ack(@a, "t1")
    assert_empty @td.pending(@a), "reported: nothing to send again this session"
    assert_equal 1, @td.seal(@a)
    @td.unack(@a)
    assert_empty @td.pending(@a), "sealed: gone for good"
  end

  # The client reported it, then died before a save landed: the login loads a save
  # without it, so it is owed again.
  def test_a_fresh_login_owes_what_no_save_sealed
    deliver
    @td.ack(@a, "t1")
    @td.unack(@a)
    assert_equal [@uid], @td.pending(@a).map { |r| r[:uid] }
  end

  def test_a_save_before_the_report_seals_nothing
    deliver
    assert_equal 0, @td.seal(@a)
    assert_equal 1, @td.pending(@a).size
  end

  # Traded on (or evicted): the registry says it is someone else's now.
  def test_a_uid_the_receiver_no_longer_owns_is_dropped
    deliver
    @db[:monsters].where(id: @uid).update(owner_account_id: @b)
    assert_empty @td.pending(@a)
    assert_equal 0, @db[:trade_deliveries].count
  end

  def test_a_later_trade_of_the_same_uid_replaces_the_row
    deliver
    @td.ack(@a, "t1")
    deliver(@uid, "t2", "\x04\b[\x06i\x06".b)
    owed = @td.pending(@a)
    assert_equal ["t2"], owed.map { |r| r[:trade_id] }
    assert_equal "\x04\b[\x06i\x06".b, owed[0][:body].b
  end
end
