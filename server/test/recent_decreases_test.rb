require "minitest/autorun"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk"

# E4: what left an account's possession in the last minute, and how much of it the
# ledger had not recognized.
class RecentDecreasesTest < Minitest::Test
  def test_a_minute_of_decreases_per_account_and_item
    r = PEMK::RecentDecreases.new(window: 60)
    r.note(1, { "POKEBALL" => 1 }, {}, now: 100)
    r.note(1, { "POKEBALL" => 2, "POTION" => 1 }, { "POKEBALL" => 1 }, now: 130)
    r.note(2, { "POKEBALL" => 5 }, {}, now: 130)
    assert_equal [3, 1], r.recent(1, "POKEBALL", now: 150)
    assert_equal [2, 1], r.recent(1, "POKEBALL", now: 170), "the first one is over a minute old"
    assert_equal [0, 0], r.recent(1, "MASTERBALL", now: 150)
    assert_equal [5, 0], r.recent(2, "POKEBALL", now: 150)
  end
end
