require "minitest/autorun"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk"

# Item authority E2: an increase of the possession takes the credits its sources left,
# oldest first; what none covers is a debt a late source can still pay, and one left
# open past its grace is unexplained.
class ItemLedgerTest < Minitest::Test
  T0 = Time.utc(2026, 9, 28, 12, 0, 0)

  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    %i[item_credits trade_deliveries monster_transfers monsters enforcement_events inventory_snapshots].each do |t|
      @db[t].delete rescue nil
    end
    @db[:accounts].delete
    @a = @db[:accounts].insert(email: "il-a@x.co", password_hash: "x", status: "active", created_at: T0)
    @b = @db[:accounts].insert(email: "il-b@x.co", password_hash: "x", status: "active", created_at: T0)
    @l = PEMK::ItemLedger.new(@db)
  end

  def teardown
    @db&.disconnect
  end

  def rows(account = @a)
    @db[:item_credits].where(account_id: account).order(:id).select_map(%i[item qty source])
  end

  def test_a_credit_explains_an_increase
    @l.credit(@a, "POTION", 2, source: :pickup, ref: "5:12:8", now: T0)
    assert_empty @l.judge(@a, { "POTION" => 1 }, { "POTION" => 3 }, now: T0 + 1)
    assert_empty rows
  end

  def test_what_no_credit_covers_is_owed
    @l.credit(@a, "POTION", 1, source: :pickup, now: T0)
    assert_equal({ "POTION" => 2 }, @l.judge(@a, {}, { "POTION" => 3 }, now: T0 + 1))
    assert_equal [["POTION", -2, "seen"]], rows
  end

  def test_a_decrease_and_a_move_ask_nothing
    assert_empty @l.judge(@a, { "POTION" => 3, "ANTIDOTE" => 1 }, { "POTION" => 1 }, now: T0)
    assert_empty rows
  end

  def test_credits_go_oldest_first_and_partly
    @l.credit(@a, "POKEBALL", 5, source: :shop, now: T0)
    @l.credit(@a, "POKEBALL", 5, source: :pickup, now: T0 + 1)
    @l.judge(@a, {}, { "POKEBALL" => 7 }, now: T0 + 2)
    assert_equal [["POKEBALL", 3, "pickup"]], rows
  end

  def test_credits_are_per_item_and_per_account
    @l.credit(@b, "POTION", 1, source: :pickup, now: T0)
    @l.credit(@a, "ANTIDOTE", 1, source: :pickup, now: T0)
    assert_equal({ "POTION" => 1 }, @l.judge(@a, {}, { "POTION" => 1 }, now: T0 + 1))
  end

  # The bag went out while the pickup's message was showing; its report came after.
  def test_a_late_source_pays_the_debt
    @l.judge(@a, {}, { "POTION" => 1 }, now: T0)
    assert_equal 0, @l.credit(@a, "POTION", 1, source: :pickup, now: T0 + 5)
    assert_empty rows
    assert_empty @l.settle(now: T0 + PEMK::ItemLedger::GRACE + 1)
  end

  def test_a_debt_past_its_grace_is_unexplained
    @l.judge(@a, {}, { "MASTERBALL" => 1 }, now: T0)
    assert_empty @l.settle(now: T0 + 10), "still within its grace"
    out = @l.settle(now: T0 + PEMK::ItemLedger::GRACE + 1)
    assert_equal [[@a, "MASTERBALL", 1]], out.map { |u| [u[:account_id], u[:item], u[:qty]] }
    assert_empty rows, "settled once"
    assert_empty @l.settle(now: T0 + PEMK::ItemLedger::GRACE + 60)
  end

  # A credit that raced the judgment is still looked for before the verdict.
  def test_the_verdict_takes_a_credit_that_came_late
    @l.judge(@a, {}, { "POTION" => 2 }, now: T0)
    @db[:item_credits].insert(account_id: @a, item: "POTION", qty: 1, source: "pickup", created_at: T0 + 1,
                              expires_at: T0 + 3600)
    out = @l.settle(now: T0 + PEMK::ItemLedger::GRACE + 1)
    assert_equal [1], out.map { |u| u[:qty] }
    assert_empty rows
  end

  def test_an_unused_credit_expires
    @l.credit(@a, "POTION", 1, source: :pickup, now: T0)
    @l.settle(now: T0 + PEMK::ItemLedger::CREDIT_TTL + 1)
    assert_empty rows
    assert_equal({ "POTION" => 1 }, @l.judge(@a, {}, { "POTION" => 1 }, now: T0 + PEMK::ItemLedger::CREDIT_TTL + 2))
  end

  def test_an_expired_credit_explains_nothing_even_before_the_sweep
    @l.credit(@a, "POTION", 1, source: :pickup, now: T0)
    assert_equal({ "POTION" => 1 }, @l.judge(@a, {}, { "POTION" => 1 }, now: T0 + PEMK::ItemLedger::CREDIT_TTL + 1))
  end

  def test_an_allowance_covers_its_part
    assert_empty @l.judge(@a, {}, { "POTION" => 1 }, allow: { "POTION" => 1 }, now: T0)
    assert_equal({ "POTION" => 1 }, @l.judge(@a, { "POTION" => 1 }, { "POTION" => 3 }, allow: { "POTION" => 1 }, now: T0))
  end

  # A fresh login loads the record, which holds no waiting credit's item.
  def test_a_fresh_login_drops_the_credits_and_keeps_the_debts
    @l.credit(@a, "POTION", 1, source: :pickup, now: T0)
    @l.judge(@a, {}, { "MASTERBALL" => 1 }, now: T0)
    @l.drop_credits(@a)
    assert_equal [["MASTERBALL", -1, "seen"]], rows
  end

  def test_nothing_is_credited_for_nothing
    assert_equal 0, @l.credit(@a, "POTION", 0, source: :shop, now: T0)
    assert_equal 0, @l.credit(@a, nil, 1, source: :shop, now: T0)
    assert_empty rows
  end
end
