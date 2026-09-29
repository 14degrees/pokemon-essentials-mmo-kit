require "minitest/autorun"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk"

# Money authority M1b: the shadow balance. S is what M2 would keep, C the client's balance
# as the server last knew it; a frame logs max(0, v - S) - max(0, C - S). The excess is
# derived each time, so money conjured again after a spend - or back up to an old peak -
# is logged again, and money carried from frame to frame is logged once.
class MoneyShadowTest < Minitest::Test
  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    @db[:money_shadow].delete
    @db[:accounts].where(email: "shadow@t.co").delete
    @aid = @db[:accounts].insert(username: "shadow_test", email: "shadow@t.co", password_hash: "x")
    @m = PEMK::MoneyShadow.new(@db, start_money: 3000, cap: 999_999)
  end

  def teardown
    @db[:accounts].where(email: "shadow@t.co").delete
    @db&.disconnect
  end

  def sc
    @db[:money_shadow].where(account_id: @aid).get(%i[s c])
  end

  def test_a_new_account_starts_at_the_start_money
    assert_equal 0, @m.frame(@aid, 3000, before: nil), "the login seed of a new account"
    assert_equal [3000, 3000], sc
  end

  def test_an_existing_balance_is_the_baseline
    assert_equal 0, @m.frame(@aid, 5000, before: 5000)
    assert_equal 700, @m.frame(@aid, 5700, before: 5000), "700 no claim explains"
  end

  def test_a_claim_explains_its_prize
    @m.claim(@aid, 176, before: 1000)
    assert_equal 0, @m.frame(@aid, 1176, before: 1000)
    assert_equal [1176, 1176], sc
  end

  def test_a_carried_excess_is_logged_once_and_a_new_one_again
    @m.frame(@aid, 1000, before: 1000)
    assert_equal 500, @m.frame(@aid, 1500, before: 1000)
    assert_equal 0, @m.frame(@aid, 1500, before: 1500), "carried, not new"
    assert_equal 0, @m.frame(@aid, 1200, before: 1500), "a spend from the excess"
    assert_equal 300, @m.frame(@aid, 1500, before: 1200), "back up to the old peak"
    assert_equal 0, @m.frame(@aid, 900, before: 1500), "a spend below S"
    assert_equal [900, 900], sc
    assert_equal 400, @m.frame(@aid, 1300, before: 900), "conjured again after the spend"
  end

  def test_a_deal_moves_both_and_names_what_s_cannot_cover
    @m.frame(@aid, 1000, before: 1000)
    @m.frame(@aid, 1500, before: 1000)                          # 500 unexplained
    assert_equal 300, @m.deal(@aid, -1300, before: 1500), "300 of the 1300 came from nowhere"
    assert_equal [-300, 200], sc
    assert_equal 0, @m.frame(@aid, 200, before: 200), "the client's echo of the deal"
    assert_equal 0, @m.deal(@aid, 450, before: 200), "a sale"
    assert_equal [150, 650], sc
  end

  def test_a_login_adopts_the_ledger_and_a_void_takes_its_prize_back
    @m.claim(@aid, 176, before: 1000)
    @m.void(@aid, 176, before: 1000)
    @m.login(@aid, 1000)
    assert_equal [1000, 1000], sc
    assert_equal 176, @m.frame(@aid, 1176, before: 1000), "the voided prize explains nothing"
  end

  # M1d: a sale of items the server never judged moves the client's balance, not S; its
  # echo is not unexplained, but spending it beyond S is.
  def test_a_sale_of_items_never_judged
    @m.frame(@aid, 1000, before: 1000)
    assert_equal 0, @m.deal(@aid, 500, before: 1000, credit: false)
    assert_equal [1000, 1500], sc
    assert_equal 0, @m.frame(@aid, 1500, before: 1500), "the client's echo of the sale"
    assert_equal 400, @m.deal(@aid, -1400, before: 1500), "400 of it spent beyond what S holds"
  end

  def test_s_is_capped
    @m.frame(@aid, 999_900, before: 999_900)
    @m.claim(@aid, 500, before: 999_900)
    assert_equal 999_999, sc[0]
  end
end
