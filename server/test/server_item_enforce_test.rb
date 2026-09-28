require "minitest/autorun"
require "socket"
require "timeout"
require "json"
require "tempfile"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)

ENV["PEMK_BIND"] = "127.0.0.1"
ENV["PEMK_PORT"] = "0"
require "pemk"

# Item authority E4 over the wire (PEMK_ITEM_AUTHORITY=on, every gate on): an increase of
# a judged item no source explained is owed once its grace is over, and taken back - the
# client is sent the owed units bound to the snapshot seq the server judged, again after
# each judged snapshot until a decrease settles them. Nothing relies on owed units: a
# sale or a trade of them is refused. A key item is never corrected.
class ServerItemEnforceTest < Minitest::Test
  W = PEMK::Wire
  GATES = { "PEMK_ITEM_AUTHORITY" => "on", "PEMK_PICKUP_ENFORCE" => "on", "PEMK_GIFT_ENFORCE" => "on",
            "PEMK_SHOP_ENFORCE" => "on" }.freeze

  WORLD = Tempfile.new(["pemk_world", ".json"])
  WORLD.write(JSON.generate(
    "schema_version" => 3,
    "maps" => {
      "5" => { "name" => "Route", "width" => 40, "height" => 30, "objects" => [
        { "kind" => "item", "item" => "RARECANDY", "quantity" => 1, "x" => 12, "y" => 8, "event_id" => 1 }
      ] },
      "15" => { "name" => "Mart", "width" => 10, "height" => 10, "objects" => [
        { "kind" => "mart", "items" => %w[POKEBALL], "prices" => {}, "dynamic" => false, "x" => 2, "y" => 2, "event_id" => 5 }
      ] }
    },
    "item_sources" => { "events" => [], "berry_plants" => false, "mining" => false }
  ))
  WORLD.flush

  BATTLE = Tempfile.new(["pemk_battle", ".json"])
  src = JSON.parse(File.read(File.expand_path("../data/battle_data.json", __dir__)))
  src["item_rules"] = { "start_item_storage" => [], "more_bonus_premier_balls" => true, "pickup_items" => [] }
  src["species"].each_value { |s| s["wild_items"] = [] }   # known, and none: every item here is judged
  BATTLE.write(JSON.generate(src))
  BATTLE.flush

  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    %i[item_credits pickups gift_grants gift_claims trade_deliveries economy_ledger economy_balances
       inventory_snapshots monster_transfers monsters enforcement_events player_flags].each { |t| @db[t].delete rescue nil }
    @db[:accounts].delete
    @logs = Queue.new
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  def start_server(env = GATES)
    base = { "PEMK_WORLD" => WORLD.path, "PEMK_BATTLE_DATA" => BATTLE.path }
    @server = PEMK::Server.new(config: PEMK::Config.new(env: ENV.to_h.merge(base).merge(env)), logger: ->(m) { @logs << m })
    @server.start
    @server.instance_variable_set(:@item_sweeping, true)   # the tests sweep themselves
    @port = @server.port
  end

  def logs
    out = []
    out << @logs.pop until @logs.empty?
    out
  end

  def send_env(s, e, body = nil)
    s.write(W.encode_split(e, body))
  end

  def recv_type(s, *types, timeout: 5)
    Timeout.timeout(timeout) do
      loop do
        h = s.read(4)
        return nil if h.nil?

        env = W.decode_envelope(s.read(h.unpack1("N")), false)[:env]
        return env if types.include?(env[:type])
      end
    end
  end

  # -> the next frame of +types+, or nil if none comes within +seconds+.
  def maybe(s, *types, seconds: 1)
    recv_type(s, *types, timeout: seconds)
  rescue Timeout::Error
    nil
  end

  def login(email, register: true, caps: %w[inv_correct trade_redeliver])
    s = TCPSocket.new("127.0.0.1", @port)
    if register
      send_env(s, { type: :register, email: email, password: "password1" })
      recv_type(s, :register_ok, :register_err)
    end
    send_env(s, { type: :login, email: email, password: "password1", caps: caps })
    [s, recv_type(s, :login_ok)]
  end

  def st(pc: {}, mail: {}, holders: {})
    { pc: pc, mail: mail, held: holders.values.compact.tally, holders: holders }
  end

  def inv(s, seq, bag, stores = st, extra = {})
    send_env(s, { type: :inv, bag: bag, seq: seq, stores: stores }.merge(extra))
    recv_type(s, :inv_ack)
  end

  def debts(account_id)
    @db[:item_credits].where(account_id: account_id).where(Sequel[:qty] < 0).order(:item).select_map(%i[item qty source])
  end

  def verdict!
    @db[:item_credits].where(Sequel[:qty] < 0).update(expires_at: Time.now - 1)
    @server.send(:settle_items)
  end

  def test_on_needs_every_gate
    start_server("PEMK_ITEM_AUTHORITY" => "on")
    assert(logs.any? { |l| l.include?("WARNING item authority 'on' needs PEMK_PICKUP_ENFORCE=on") })
    s, lo = login("e0@t.co")
    inv(s, 1, {})
    inv(s, 2, { RARECANDY: 1 })
    verdict!
    assert_empty debts(lo[:account_id]), "shadow: the verdict drops the debt"
  end

  def test_an_item_from_nowhere_is_taken_back
    start_server
    assert(logs.any? { |l| l.include?("item enforcement ON") })
    s, lo = login("e1@t.co")
    id = lo[:account_id]
    inv(s, 1, {})
    inv(s, 2, { RARECANDY: 2 })
    assert_nil maybe(s, :inv_correct, seconds: 0.5), "within its grace: nothing yet"
    verdict!
    fix = recv_type(s, :inv_correct)
    assert_equal [2, { RARECANDY: 2 }], [fix[:seq], fix[:items]], "bound to the last judged snapshot"
    assert_equal [["RARECANDY", -2, "owed"]], debts(id)
    assert(logs.any? { |l| l.include?("account #{id} UNEXPLAINED +2 RARECANDY") && l.include?("taken back") })

    inv(s, 3, { RARECANDY: 2, POKEBALL: 0 }.reject { |_, n| n.zero? })   # not applied yet
    fix2 = recv_type(s, :inv_correct)
    assert_equal 3, fix2[:seq], "each judged snapshot brings it again, for its own seq"
    assert fix2[:id] > fix[:id]

    inv(s, 4, {}, st, corrected: fix2[:id])                               # applied: both gone
    assert_empty debts(id)
    assert_nil maybe(s, :inv_correct, seconds: 0.5)
    assert(logs.any? { |l| l.include?("applied correction ##{fix2[:id]}") })
  end

  # A client that never applies a correction it was sent is reported, once.
  def test_a_correction_left_unapplied_is_reported
    start_server(GATES.merge("PEMK_ANOMALY_DETECTION" => "on"))
    s, lo = login("e1b@t.co")
    id = lo[:account_id]
    inv(s, 1, {})
    inv(s, 2, { RARECANDY: 1 })
    verdict!
    recv_type(s, :inv_correct)
    Timeout.timeout(5) { sleep 0.05 until @db[:item_credits].where(account_id: id).get(:ref).to_s.start_with?("sent:") }
    @db[:item_credits].where(account_id: id).update(ref: "sent:#{Time.now.to_i - 31 * 60}")
    2.times { @server.send(:settle_items) }
    Timeout.timeout(5) { sleep 0.05 until @db[:player_flags].where(account_id: id, kind: "item_correction_ignored").get(:count) }
    assert_equal 1, logs.grep(/account #{id} has not applied the correction for RARECANDY/).size
    assert_equal 1, @db[:player_flags].where(account_id: id, kind: "item_correction_ignored").get(:count)
  end

  # A report heard after the verdict (a gate that should have come first) pays nothing:
  # the correction may already be applied.
  def test_a_late_credit_never_pays_an_owed_debt
    start_server
    s, lo = login("e2@t.co")
    inv(s, 1, {})
    inv(s, 2, { RARECANDY: 1 })
    verdict!
    recv_type(s, :inv_correct)
    send_env(s, { type: :pos, map: 5, x: 12, y: 7 })
    send_env(s, { type: :interact_claim, kind: :item, item: :RARECANDY, map: 5, x: 12, y: 8, px: 12, py: 7 })
    credited = -> { @db[:item_credits].where(account_id: lo[:account_id]).where(Sequel[:qty] > 0).count == 1 }
    Timeout.timeout(5) { sleep 0.05 until credited.call || debts(lo[:account_id]).empty? }
    assert_equal [["RARECANDY", -1, "owed"]], debts(lo[:account_id])
    assert credited.call, "it waits as a credit instead"
  end

  def test_a_key_item_goes_to_review_only
    start_server
    s, lo = login("e3@t.co")
    inv(s, 1, {})
    inv(s, 2, { BICYCLE: 1 })
    verdict!
    assert_nil maybe(s, :inv_correct, seconds: 0.5)
    assert_empty debts(lo[:account_id])
    assert(logs.any? { |l| l.include?("UNEXPLAINED +1 BICYCLE") && !l.include?("taken back") })
  end

  # Used before its verdict: gone, and unexplained all the same.
  def test_an_item_spent_before_its_verdict_is_still_reported
    start_server
    s, lo = login("e4@t.co")
    inv(s, 1, {})
    inv(s, 2, { RARECANDY: 2 })
    inv(s, 3, { RARECANDY: 1 })
    assert_equal [["RARECANDY", -1, "seen"]], debts(lo[:account_id])
    assert(logs.any? { |l| l.include?("UNEXPLAINED +1 RARECANDY (spent before its verdict)") })
  end

  def test_owed_units_cannot_be_sold
    start_server
    s, lo = login("e5@t.co")
    send_env(s, { type: :econ, field: :money, value: 1000, seq: 1 })
    recv_type(s, :econ_ack, :econ_rej)
    inv(s, 1, {})
    inv(s, 2, { XATTACK: 1 })
    verdict!
    recv_type(s, :inv_correct)
    price = JSON.parse(File.read(BATTLE.path))["items"]["XATTACK"]["sell_price"]
    send_env(s, { type: :shop_req, op: :sell, item: "XATTACK", quantity: 1, unit_price: price, map: 15, event: 5, seq: 1 })
    assert_equal "not_held", recv_type(s, :shop_grant, :shop_deny)[:reason]
    assert_equal 1000, @db[:economy_balances].where(account_id: lo[:account_id], field: "money").get(:balance)
  end

  # A bag-only snapshot (a battle, the Bug Contest) is recorded, never judged: what it
  # shows cannot be sold before a judged snapshot recognizes it.
  def test_a_bag_the_ledger_never_judged_sells_nothing
    start_server
    s, lo = login("e5b@t.co")
    send_env(s, { type: :econ, field: :money, value: 1000, seq: 1 })
    recv_type(s, :econ_ack, :econ_rej)
    inv(s, 1, {})
    send_env(s, { type: :inv, bag: { XATTACK: 1 }, seq: 2 })   # the bag alone
    recv_type(s, :inv_ack)
    price = JSON.parse(File.read(BATTLE.path))["items"]["XATTACK"]["sell_price"]
    send_env(s, { type: :shop_req, op: :sell, item: "XATTACK", quantity: 1, unit_price: price, map: 15, event: 5, seq: 1 })
    assert_equal "not_held", recv_type(s, :shop_grant, :shop_deny)[:reason]
    assert_equal 1000, @db[:economy_balances].where(account_id: lo[:account_id], field: "money").get(:balance)
  end

  # A Pokemon the registry gives the account drops out: its item's debt stays open, and its
  # return with that item is no increase.
  def test_a_vanished_pokemon_settles_nothing
    start_server
    s, lo = login("e6@t.co")
    id = lo[:account_id]
    uid = @db[:monsters].insert(owner_account_id: id, issuer_account_id: id, client_nonce: 1, species: "PIKACHU",
                                level_at_issue: 5, personal_id: 1, egg_at_issue: false, status: "active", flagged: false)
    inv(s, 1, {}, st(holders: { uid => :LEFTOVERS }))
    inv(s, 2, { LEFTOVERS: 1 }, st(holders: { uid => :LEFTOVERS }))   # one more, from nowhere
    inv(s, 3, { LEFTOVERS: 1 }, st(holders: {}))                       # the holder hides
    assert_equal [["LEFTOVERS", -1, "seen"]], debts(id), "its drop settles nothing"
    inv(s, 4, { LEFTOVERS: 1 }, st(holders: { uid => :LEFTOVERS }))    # and comes back
    assert_equal [["LEFTOVERS", -1, "seen"]], debts(id), "nor is its return an increase"
  end

  # A ball leaves the bag before its throw is judged, and its snapshot may land first:
  # the throw is judged against the possession as it was before.
  def test_a_ball_is_judged_as_it_was_before_the_throw
    start_server
    ok = ->(id) { @server.send(:ball_ok?, id, "POKEBALL") }
    s, lo = login("e7@t.co")
    inv(s, 1, { POKEBALL: 2 })
    assert ok.(lo[:account_id]), "two recognized balls"
    inv(s, 2, { POKEBALL: 1 })
    inv(s, 3, {})
    assert ok.(lo[:account_id]), "both thrown, their snapshots first: they were recognized"

    c, lc = login("e8@t.co")
    inv(c, 1, {})
    inv(c, 2, { POKEBALL: 1 })
    refute ok.(lc[:account_id]), "a ball from nowhere, still in the bag"
    inv(c, 3, {})
    refute ok.(lc[:account_id]), "... and thrown: its snapshot settled its debt, it was never recognized"

    n, ln = login("e9@t.co")
    inv(n, 1, {})
    refute ok.(ln[:account_id]), "a ball no snapshot ever showed"
  end

  def trade(a, la, b, lb, ua, ub, a_says:)
    send_env(a, { type: :trade_invite, to: lb[:account_id], trade_id: "t" })
    recv_type(b, :trade_invite)
    send_env(b, { type: :trade_accept, to: la[:account_id], trade_id: "t" })
    recv_type(a, :trade_accept)
    send_env(a, { type: :trade_lock, to: lb[:account_id], trade_id: "t", uid: ua, item: a_says }, Marshal.dump([1]))
    recv_type(b, :trade_lock)
    send_env(b, { type: :trade_lock, to: la[:account_id], trade_id: "t", uid: ub, item: nil }, Marshal.dump([2]))
    recv_type(a, :trade_lock)
    send_env(a, { type: :trade_commit, trade_id: "t", partner: lb[:account_id], give: [ua], recv: [ub] })
    send_env(b, { type: :trade_commit, trade_id: "t", partner: la[:account_id], give: [ub], recv: [ua] })
    recv_type(a, :trade_result)
  end

  def test_a_held_item_the_server_does_not_recognize_cannot_be_traded
    start_server
    a, la = login("ta@t.co")
    b, lb = login("tb@t.co")
    mint = ->(owner, n) do
      @db[:monsters].insert(owner_account_id: owner, issuer_account_id: owner, client_nonce: n, species: "PIKACHU",
                            level_at_issue: 5, personal_id: n, egg_at_issue: false, status: "active", flagged: false)
    end
    ua = mint.(la[:account_id], 1)
    ub = mint.(lb[:account_id], 2)
    inv(a, 1, {}, st(holders: { ua => nil }))
    inv(a, 2, {}, st(holders: { ua => :LEFTOVERS }))   # a Leftovers from nowhere, on the Pokemon to trade
    inv(b, 1, {}, st(holders: { ub => nil }))
    r = trade(a, la, b, lb, ua, ub, a_says: :LEFTOVERS)
    assert_equal [false, "item"], [r[:ok], r[:reason]]
    assert_equal la[:account_id], @db[:monsters].where(id: ua).get(:owner_account_id), "nothing moved"
  end
end
