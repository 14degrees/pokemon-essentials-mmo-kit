require "minitest/autorun"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk"

# Audit item 4 (second half): the NPC-gift / event-item claim ledger. Layer C gates
# only item balls; every other acquisition runs through pbReceiveItem, which was
# hooked nowhere — so a self-switch rewind re-farmed every gift with no trace.
# DETECTION only: repeatable/daily gift NPCs exist, so a repeat is evidence for a
# human, never an automatic consequence.
class GiftClaimsTest < Minitest::Test
  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    @db[:gift_claims].delete rescue nil
    @db[:flag_snapshots].delete rescue nil
    @db[:enforcement_events].delete rescue nil
    @db[:battle_records].delete rescue nil
    @db[:encounter_rolls].delete rescue nil
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete rescue nil
    @db[:accounts].delete
    @a = @db[:accounts].insert(email: "gc-a@x.co", password_hash: "x", status: "active", created_at: Time.now)
    @logs = []
    @gc = PEMK::GiftClaims.new(@db, logger: ->(m) { @logs << m })
  end

  def teardown
    @db&.disconnect
  end

  def test_first_claim_is_recorded
    assert_equal :first, @gc.claim(@a, 5, 12, "POTION", 1)
    row = @db[:gift_claims].first
    assert_equal 5, row[:map]
    assert_equal 12, row[:event]
    assert_equal "POTION", row[:item]
    assert_equal 1, row[:claims]
  end

  # The re-farm signature: the SAME one-shot event paying out over and over.
  def test_repeats_accumulate_and_become_suspect
    verdicts = (1..PEMK::GiftClaims::REPEAT_MIN).map { @gc.claim(@a, 5, 12, "TM01", 1) }
    assert_equal :first, verdicts.first
    assert_equal :suspect, verdicts.last
    assert_equal PEMK::GiftClaims::REPEAT_MIN, @db[:gift_claims].first[:claims]
    assert(@logs.any? { |l| l.include?("SUSPECT re-farm") }, @logs.inspect)
  end

  # A daily event (a lottery, a daily NPC) claimed every day for weeks is just play.
  def test_a_repeatable_event_claimed_once_a_day_is_never_suspect
    t = Time.now
    verdicts = (0...20).map { |day| @gc.claim(@a, 13, 17, "ULTRABALL", 1, repeatable: true, now: t + day * 90_000) }
    refute_includes verdicts, :suspect
    assert_empty @logs.grep(/SUSPECT/)
  end

  # ... but re-armed and milked inside one day, it is the re-farm signature again.
  def test_a_repeatable_event_milked_in_a_day_is_suspect
    t = Time.now
    verdicts = (0...PEMK::GiftClaims::REPEAT_MIN).map do |i|
      @gc.claim(@a, 13, 17, "ULTRABALL", 1, repeatable: true, now: t + i * 60)
    end
    assert_equal :suspect, verdicts.last
    assert(@logs.any? { |l| l.include?("in a day") }, @logs.inspect)
  end

  def test_distinct_events_and_items_are_separate_one_shots
    @gc.claim(@a, 5, 12, "POTION", 1)
    @gc.claim(@a, 5, 13, "POTION", 1)   # different event
    @gc.claim(@a, 6, 12, "POTION", 1)   # different map
    @gc.claim(@a, 5, 12, "ETHER", 1)    # different item
    assert_equal 4, @db[:gift_claims].count
    assert_equal [1, 1, 1, 1], @db[:gift_claims].select_map(:claims)
  end

  def test_hostile_shapes_are_rejected
    assert_equal :bad, @gc.claim(@a, "5", 12, "POTION", 1)
    assert_equal :bad, @gc.claim(@a, 5, 12, "", 1)
    assert_equal :bad, @gc.claim(@a, 5, 12, "X" * 65, 1)
    assert_equal :bad, @gc.claim(@a, 5, 12, "POTION", 0)
    assert_equal :bad, @gc.claim(@a, 5, 12, "POTION", -3)
    assert_equal 0, @db[:gift_claims].count
  end
end
