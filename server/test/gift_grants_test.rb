require "minitest/autorun"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk"

# Step 6: the payout gate's ledger. A one-shot gift is granted once per account; the
# grant becomes final (sealed) only when a bag snapshot that holds it lands, and a
# fresh login voids one that never did, so a crash can neither dupe nor lose it.
class GiftGrantsTest < Minitest::Test
  C1 = 111
  C2 = 222

  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    @db[:gift_grants].delete rescue nil
    @db[:gift_claims].delete rescue nil
    @db[:flag_snapshots].delete rescue nil
    @db[:enforcement_events].delete rescue nil
    @db[:battle_records].delete rescue nil
    @db[:encounter_rolls].delete rescue nil
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete rescue nil
    @db[:accounts].delete
    @a = @db[:accounts].insert(email: "gg-a@x.co", password_hash: "x", status: "active", created_at: Time.now)
    @b = @db[:accounts].insert(email: "gg-b@x.co", password_hash: "x", status: "active", created_at: Time.now)
    @logs = []
    @gg = PEMK::GiftGrants.new(@db, logger: ->(m) { @logs << m })
  end

  def teardown
    @db&.disconnect
  end

  def ask(nonce, conn: C1, account: @a, event: 3)
    @gg.request(account, 10, event, "TM80", 1, nonce, conn: conn)
  end

  def state(account: @a, event: 3)
    @db[:gift_grants].where(account_id: account, map: 10, event: event).get(:state)
  end

  def test_the_first_request_is_granted
    assert_equal [:grant, nil, 0], ask(7)
    assert_equal "granted", state
  end

  # The re-farm: the event was re-armed and asks again with a new request.
  def test_another_request_for_a_paid_gift_is_refused
    ask(7)
    @gg.applied(@a, 10, 3, 7)
    @gg.seal(@a, C1)
    verdict, reason, denied = ask(8)
    assert_equal :deny, verdict
    assert_equal "already_claimed", reason
    assert_equal 1, denied
    assert_equal 2, ask(9)[2]
  end

  # Even before it is sealed: a second request in the same session is a re-armed event.
  def test_a_second_request_while_the_first_is_unsettled_is_refused
    ask(7)
    assert_equal :deny, ask(8)[0]
  end

  # The reply was lost with its socket: the same request comes again and is granted
  # again, on the new connection.
  def test_the_same_request_again_is_granted_again
    ask(7)
    assert_equal :grant, ask(7, conn: C2)[0]
    assert_equal C2, @db[:gift_grants].first[:conn]
  end

  # Once the client holds it, its request is spent.
  def test_the_same_request_after_it_was_applied_is_refused
    ask(7)
    assert @gg.applied(@a, 10, 3, 7)
    assert_equal :deny, ask(7)[0]
  end

  def test_applied_needs_the_granted_request
    ask(7)
    refute @gg.applied(@a, 10, 3, 99)
    assert_equal "granted", state
  end

  def test_a_snapshot_seals_what_the_client_applied
    ask(7)
    @gg.applied(@a, 10, 3, 7)
    assert_equal 1, @gg.seal(@a, C1)
    assert_equal "sealed", state
  end

  # A snapshot on the grant's own connection may predate the item reaching the bag:
  # only the client's :gift_applied says it is there.
  def test_a_snapshot_on_the_same_connection_does_not_seal_an_unapplied_grant
    ask(7)
    assert_equal 0, @gg.seal(@a, C1)
    assert_equal "granted", state
  end

  # The :gift_applied died with the socket. A reconnecting client re-sends what it
  # still waits for before its bag, so a grant it did not re-send was applied.
  def test_the_first_snapshot_of_a_later_connection_seals_a_grant_left_behind
    ask(7)
    assert_equal 1, @gg.seal(@a, C2)
    assert_equal "sealed", state
  end

  def test_a_re_sent_request_moves_to_the_new_connection_and_stays_open
    ask(7)
    ask(7, conn: C2)
    assert_equal 0, @gg.seal(@a, C2)
    assert_equal "granted", state
  end

  # Crash before the bag reached the server: the stored bag the login loads does not
  # hold the gift, so the re-armed event pays once more - the first payout is gone.
  def test_a_fresh_login_voids_an_unsealed_grant_and_the_gift_is_paid_again
    ask(7)
    @gg.applied(@a, 10, 3, 7)
    assert_equal 1, @gg.void_unsealed(@a)
    assert_equal "void", state
    assert_equal :grant, ask(8)[0]
    assert_equal "granted", state
  end

  def test_a_fresh_login_keeps_a_sealed_grant
    ask(7)
    @gg.applied(@a, 10, 3, 7)
    @gg.seal(@a, C1)
    assert_equal 0, @gg.void_unsealed(@a)
    assert_equal :deny, ask(8)[0]
  end

  # Paid while the gate was off: the detection ledger remembers it.
  def test_a_gift_the_detection_ledger_saw_paid_is_refused
    @db[:gift_claims].insert(account_id: @a, map: 10, event: 3, item: "TM80", quantity: 1, claims: 1,
                             first_at: Time.now, last_at: Time.now)
    assert_equal :deny, ask(7)[0]
    assert_equal "sealed", state
  end

  def test_accounts_and_events_are_separate
    ask(7)
    assert_equal :grant, ask(8, account: @b)[0]
    assert_equal :grant, ask(9, event: 4)[0]
  end

  def test_seal_and_void_touch_one_account
    ask(7)
    ask(8, account: @b)
    @gg.void_unsealed(@a)
    assert_equal "granted", state(account: @b)
    @gg.seal(@b, C2)
    assert_equal "void", state
  end

  def test_a_seal_without_a_connection_id_changes_nothing
    ask(7)
    assert_equal 0, @gg.seal(@a, nil)
    assert_equal "granted", state
  end
end
