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

# Item authority E2 over the wire (PEMK_ITEM_AUTHORITY=shadow): every increase of the
# possession - bag, PC, mailbox and held items together - takes a credit a source the
# server knows left. A pickup it granted, a Mart purchase (and its Premier Balls), a
# one-shot gift it paid, a traded Pokemon's item, the PC's start items: explained. An
# item from nowhere is owed, then reported UNEXPLAINED.
class ServerItemLedgerTest < Minitest::Test
  W = PEMK::Wire

  WORLD = Tempfile.new(["pemk_world", ".json"])
  WORLD.write(JSON.generate(
    "schema_version" => 3,
    "maps" => {
      "5" => { "name" => "Route", "width" => 40, "height" => 30, "objects" => [
        { "kind" => "item", "item" => "POTION", "quantity" => 2, "x" => 12, "y" => 8, "event_id" => 1 }
      ] },
      "10" => { "name" => "Gym", "width" => 20, "height" => 20, "objects" => [
        { "kind" => "gift", "item" => "TM80", "items" => ["TM80"], "x" => 6, "y" => 5, "event_id" => 3,
          "once" => true, "dynamic" => false, "quantities" => { "TM80" => 1 } },
        { "kind" => "gift", "item" => "MASTERBALL", "items" => ["MASTERBALL"], "x" => 8, "y" => 5, "event_id" => 4,
          "once" => true, "dynamic" => true }
      ] },
      "15" => { "name" => "Mart", "width" => 10, "height" => 10, "objects" => [
        { "kind" => "mart", "items" => %w[POKEBALL], "prices" => {}, "dynamic" => false,
          "x" => 2, "y" => 2, "event_id" => 5 },
        { "kind" => "bp_shop", "items" => %w[PROTEIN], "prices" => {}, "dynamic" => false,
          "x" => 6, "y" => 2, "event_id" => 7 }
      ] }
    }
  ))
  WORLD.flush

  BATTLE = Tempfile.new(["pemk_battle", ".json"])
  def self.item(price, ball: false, bp: 1)
    { "pocket" => 3, "is_ball" => ball, "is_berry" => false, "is_machine" => false, "can_hold" => true,
      "move" => nil, "price" => price, "sell_price" => price / 2, "bp_price" => bp, "important" => false,
      "consumable" => true }
  end
  src = JSON.parse(File.read(File.expand_path("../data/battle_data.json", __dir__)))
  src["items"].merge!("POTION" => item(300), "POKEBALL" => item(200, ball: true), "PREMIERBALL" => item(0, ball: true),
                      "PROTEIN" => item(10_000, bp: 16))
  # The engine's tables, fixed here (the real export's wild items and Pickup table would
  # make half these items local): NUGGET alone comes from the Pickup ability.
  src["item_rules"] = { "start_item_storage" => ["POTION"], "more_bonus_premier_balls" => true,
                        "pickup_items" => ["NUGGET"] }
  src["species"].each_value { |s| s.delete("wild_items") }
  BATTLE.write(JSON.generate(src))
  BATTLE.flush

  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    %i[item_credits pickups gift_grants gift_claims flag_snapshots trade_deliveries economy_ledger economy_balances
       inventory_snapshots monster_transfers monsters enforcement_events player_flags].each { |t| @db[t].delete rescue nil }
    @db[:accounts].delete
    @logs = Queue.new
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  def start_server(env = {})
    base = { "PEMK_WORLD" => WORLD.path, "PEMK_BATTLE_DATA" => BATTLE.path, "PEMK_ITEM_AUTHORITY" => "shadow" }
    @server = PEMK::Server.new(config: PEMK::Config.new(env: ENV.to_h.merge(base).merge(env)), logger: ->(m) { @logs << m })
    @server.start
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

  def recv_type(s, *types)
    Timeout.timeout(5) do
      loop do
        h = s.read(4)
        return nil if h.nil?

        env = W.decode_envelope(s.read(h.unpack1("N")), false)[:env]
        return env if types.include?(env[:type])
      end
    end
  end

  # +older+: an account from before item authority ran, with a save - its first snapshot
  # the baseline (these tests' own premise); false - one the server saw born, judged from
  # nothing.
  def login(email, register: true, caps: %w[trade_redeliver], older: true)
    s = TCPSocket.new("127.0.0.1", @port)
    if register
      send_env(s, { type: :register, email: email, password: "password1" })
      recv_type(s, :register_ok, :register_err)
      older_account(email) if older
    end
    send_env(s, { type: :login, email: email, password: "password1", caps: caps })
    [s, recv_type(s, :login_ok)]
  end

  def older_account(email)
    id = @db[:accounts].where(email: email).get(:id)
    @db[:accounts].where(id: id).update(items_from_zero: false)
    PEMK::Characters.new(@db).store(id, blob: "\x04\b0".b) if @db[:characters].where(account_id: id).empty?
  end

  def st(pc: {}, mail: {}, held: nil, holders: {})
    { pc: pc, mail: mail, held: held || holders.values.compact.tally, holders: holders }
  end

  # One snapshot, landed (and judged) once the ack is back.
  def inv(s, seq, bag, stores = st)
    msg = { type: :inv, bag: bag, seq: seq }
    msg[:stores] = stores if stores
    send_env(s, msg)
    recv_type(s, :inv_ack)
  end

  # The server's own sweep (every few seconds) stays out of a test that sweeps itself.
  def hold_periodic_sweep
    @server.instance_variable_set(:@item_sweeping, true)
  end

  def owing(account_id)
    @db[:item_credits].where(account_id: account_id).where(Sequel[:qty] < 0).select_map(%i[item qty])
  end

  def credits(account_id)
    @db[:item_credits].where(account_id: account_id).where(Sequel[:qty] > 0).select_map(%i[item qty source])
  end

  def mint(owner, nonce)
    @db[:monsters].insert(owner_account_id: owner, issuer_account_id: owner, client_nonce: nonce,
                          species: "PIKACHU", level_at_issue: 5, personal_id: 1, egg_at_issue: false,
                          status: "active", flagged: false)
  end

  def test_off_by_default_the_ledger_keeps_nothing
    start_server("PEMK_ITEM_AUTHORITY" => "off")
    s, lo = login("il0@t.co")
    inv(s, 1, {})
    inv(s, 2, { MASTERBALL: 5 })
    assert_equal 0, @db[:item_credits].where(account_id: lo[:account_id]).count
  end

  def test_an_item_from_nowhere_is_owed_then_unexplained
    start_server("PEMK_ANOMALY_DETECTION" => "on")
    assert(logs.any? { |l| l.include?("item authority = shadow") })
    s, lo = login("il1@t.co")
    id = lo[:account_id]
    inv(s, 1, {}, st)                  # the first snapshot is the baseline
    inv(s, 2, { RARECANDY: 1 })
    assert_equal [["RARECANDY", -1]], owing(id)

    # Its grace runs out: the next sweep reports it.
    hold_periodic_sweep
    @db[:item_credits].where(account_id: id).update(expires_at: Time.now - 1)
    @server.send(:settle_items)
    Timeout.timeout(5) { sleep 0.05 until @db[:player_flags].where(account_id: id, kind: "item_unexplained").count == 1 }
    assert(logs.any? { |l| l.include?("account #{id} UNEXPLAINED +1 RARECANDY") })
    assert_empty owing(id)
  end

  # A source the server does not model yet, used many times, is one finding a sweep.
  def test_many_increases_make_one_line_per_item_and_one_count_per_sweep
    start_server("PEMK_ANOMALY_DETECTION" => "on")
    s, lo = login("il1b@t.co")
    id = lo[:account_id]
    inv(s, 1, {}, st)
    (2..4).each { |n| inv(s, n, { ORANBERRY: n - 1, PECHABERRY: 1 }) }
    assert_equal 4, @db[:item_credits].where(account_id: id).count, "three berries seen in three snapshots, and a Pecha"
    hold_periodic_sweep
    @db[:item_credits].where(account_id: id).update(expires_at: Time.now - 1)
    @server.send(:settle_items)
    Timeout.timeout(5) { sleep 0.05 until @db[:player_flags].where(account_id: id, kind: "item_unexplained").get(:count) }
    lines = logs.grep(/account #{id} UNEXPLAINED/)
    assert_equal 2, lines.size, lines.inspect
    assert(lines.any? { |l| l.include?("+3 ORANBERRY") })
    assert_equal 1, @db[:player_flags].where(account_id: id, kind: "item_unexplained").get(:count)
  end

  # A Nugget can come from the Pickup ability, which no request names: recorded, not judged.
  def test_a_local_item_owes_nothing
    start_server
    assert(logs.any? { |l| l.include?("item tiers: ") && l.include?("Pickup 1") })
    s, lo = login("il2b@t.co")
    inv(s, 1, {}, st)
    inv(s, 2, { NUGGET: 1, RARECANDY: 1, MASTERBALL: 1 })
    assert_equal [["RARECANDY", -1]], owing(lo[:account_id]), "the Master Ball: a computed gift"
  end

  def test_the_first_snapshot_is_the_baseline
    start_server
    s, lo = login("il2@t.co")
    inv(s, 1, { POTION: 5 }, st(pc: { ANTIDOTE: 2 }))
    assert_empty owing(lo[:account_id])
  end

  # ... unless the server saw the account born: then it starts from nothing, and a first
  # snapshot declaring items owes them (the PC's start items excepted).
  def test_a_new_account_starts_from_nothing
    start_server
    s, lo = login("il2n@t.co", older: false)
    assert_equal true, @db[:accounts].where(id: lo[:account_id]).get(:items_from_zero)
    inv(s, 1, { POTION: 5 }, st(pc: { ANTIDOTE: 2 }))
    assert_equal [["ANTIDOTE", -2], ["POTION", -4]], owing(lo[:account_id]).sort, "the PC's start Potion excepted"
  end

  def test_a_granted_pickup_explains_its_quantity
    start_server("PEMK_PICKUP_ENFORCE" => "on")
    s, lo = login("il3@t.co")
    inv(s, 1, {})
    send_env(s, { type: :pos, map: 5, x: 12, y: 7 })
    send_env(s, { type: :pickup_req, kind: :item, item: :POTION, map: 5, x: 12, y: 8, seq: 1 })
    assert_equal :pickup_grant, recv_type(s, :pickup_grant, :pickup_deny)[:type]
    inv(s, 2, { POTION: 2 })
    assert_empty owing(lo[:account_id])
    assert_empty credits(lo[:account_id])
  end

  # The gate off: the pickup is reported once its message closed, after the bag went out.
  def test_a_reported_pickup_pays_what_its_snapshot_owed
    start_server
    s, lo = login("il4@t.co")
    inv(s, 1, {})
    inv(s, 2, { POTION: 2 })
    assert_equal [["POTION", -2]], owing(lo[:account_id])
    send_env(s, { type: :pos, map: 5, x: 12, y: 7 })
    send_env(s, { type: :interact_claim, kind: :item, item: :POTION, map: 5, x: 12, y: 8, px: 12, py: 7 })
    Timeout.timeout(5) { sleep 0.05 until owing(lo[:account_id]).empty? }
    assert_empty credits(lo[:account_id])
  end

  def test_a_purchase_explains_the_item_and_its_premier_balls
    start_server("PEMK_SHOP_ENFORCE" => "on")
    s, lo = login("il5@t.co")
    send_env(s, { type: :econ, field: :money, value: 5000, seq: 1 })
    recv_type(s, :econ_ack, :econ_rej)
    inv(s, 1, {})
    send_env(s, { type: :shop_req, op: :buy, item: "POKEBALL", quantity: 10, unit_price: 200, map: 15, event: 5, seq: 1 })
    assert_equal :shop_grant, recv_type(s, :shop_grant, :shop_deny)[:type]
    inv(s, 2, { POKEBALL: 10, PREMIERBALL: 1 })
    assert_empty owing(lo[:account_id])
    assert_empty credits(lo[:account_id])
    # The purchase joined the record: no credit is left over to explain ten more.
    inv(s, 3, { POKEBALL: 20, PREMIERBALL: 1 })
    assert_equal [["POKEBALL", -10]], owing(lo[:account_id])
  end

  # A new account buys before its first full snapshot: judged from nothing, the purchase
  # is explained by a credit - the record had no judged totals to join.
  def test_a_new_accounts_first_purchase_is_explained
    start_server("PEMK_SHOP_ENFORCE" => "on")
    s, lo = login("il5n@t.co", older: false)
    send_env(s, { type: :econ, field: :money, value: 5000, seq: 1 })
    recv_type(s, :econ_ack, :econ_rej)
    inv(s, 1, {}, nil)   # bag-only: nothing judged yet
    send_env(s, { type: :shop_req, op: :buy, item: "POKEBALL", quantity: 10, unit_price: 200, map: 15, event: 5, seq: 1 })
    assert_equal :shop_grant, recv_type(s, :shop_grant, :shop_deny)[:type]
    inv(s, 2, { POKEBALL: 10, PREMIERBALL: 1 })
    assert_empty owing(lo[:account_id])
  end

  # An older account that never saved has no history to trust: judged from nothing too.
  def test_an_account_that_never_saved_starts_from_nothing
    start_server
    s, lo = login("il5s@t.co", older: false)
    @db[:accounts].where(id: lo[:account_id]).update(items_from_zero: false)   # registered before it ran
    inv(s, 1, { NUGGET: 1, RARECANDY: 3 })
    assert_equal [["RARECANDY", -3]], owing(lo[:account_id]), "the Nugget is a local tier"
  end

  def test_a_bp_exchange_explains_its_item
    start_server("PEMK_SHOP_ENFORCE" => "on")
    s, lo = login("il5b@t.co")
    send_env(s, { type: :econ, field: :battle_points, value: 50, seq: 1 })
    recv_type(s, :econ_ack, :econ_rej)
    inv(s, 1, {})
    send_env(s, { type: :shop_req, op: :buy, item: "PROTEIN", quantity: 2, unit_price: 16, bp: true, map: 15, event: 7,
                  seq: 1 })
    assert_equal :shop_grant, recv_type(s, :shop_grant, :shop_deny)[:type]
    inv(s, 2, { PROTEIN: 2 })
    assert_empty owing(lo[:account_id])
    assert_empty credits(lo[:account_id])
  end

  def test_a_refused_purchase_explains_nothing
    start_server("PEMK_SHOP_ENFORCE" => "shadow")
    s, lo = login("il6@t.co")
    inv(s, 1, {})
    send_env(s, { type: :shop_req, op: :buy, item: "POKEBALL", quantity: 1, unit_price: 1, map: 15, event: 5, seq: 1 })
    assert_equal :shop_grant, recv_type(s, :shop_grant, :shop_deny)[:type], "shadow lets it through"
    inv(s, 2, { POKEBALL: 1 })
    assert_equal [["POKEBALL", -1]], owing(lo[:account_id])
  end

  def test_moving_an_item_between_stores_is_not_an_increase
    start_server
    s, lo = login("il7@t.co")
    inv(s, 1, {}, st(pc: { POTION: 3 }))
    inv(s, 2, { POTION: 3 }, st(pc: {}))                               # withdrawn
    inv(s, 3, { POTION: 2 }, st(pc: {}, holders: { 7 => :POTION }))     # given to a Pokemon
    inv(s, 4, { POTION: 1 }, st(pc: {}, mail: {}, holders: { 7 => :POTION }))   # one used
    assert_empty owing(lo[:account_id])
  end

  # The Bug Contest, a collection too big to send, an older client: the bag alone is
  # recorded, never judged; the next full snapshot is judged against the last full one.
  def test_a_stretch_without_stores_neither_hides_nor_invents
    start_server
    s, lo = login("il8@t.co")
    inv(s, 1, {}, st(pc: { POTION: 3 }))
    inv(s, 2, { POTION: 1 }, nil)                            # withdrew one, as the bag alone says
    inv(s, 3, { POTION: 3 }, st(pc: {}))                     # ... and the rest: a move, not an increase
    assert_empty owing(lo[:account_id])
    inv(s, 4, { POTION: 9 }, nil)                            # six from nowhere, during a stretch
    inv(s, 5, { POTION: 9 }, st(pc: {}))
    assert_equal [["POTION", -6]], owing(lo[:account_id])
  end

  # Something that is not an item id never reaches the ledger, and never costs it the rest.
  def test_a_key_that_is_no_item_is_left_out
    start_server
    s, lo = login("il8b@t.co")
    inv(s, 1, {}, st)
    r = inv(s, 2, { RARECANDY: 1, :bogus_key => 5, :"#{'A' * 100}" => 1 })
    assert_equal true, r[:flagged]
    assert_equal [["RARECANDY", -1]], owing(lo[:account_id])
  end

  # The engine turns the DNA Splicers into their used form when they fuse two Pokemon.
  def test_an_item_and_its_twin_count_as_one
    start_server
    s, lo = login("il8c@t.co")
    inv(s, 1, { DNASPLICERS: 1 }, st)
    inv(s, 2, { DNASPLICERSUSED: 1 }, st)
    inv(s, 3, { DNASPLICERS: 1 }, st)
    assert_empty owing(lo[:account_id])
  end

  def test_the_pc_start_items_are_explained_once
    start_server
    s, lo = login("il9@t.co")
    inv(s, 1, {}, st(pc: nil))
    inv(s, 2, {}, st(pc: { POTION: 1 }))     # the storage appeared, with its Potion
    assert_empty owing(lo[:account_id])
    inv(s, 3, {}, st(pc: nil))
    inv(s, 4, {}, st(pc: { POTION: 1 }))     # never twice
    assert_equal [["POTION", -1]], owing(lo[:account_id])
  end

  def test_a_fresh_login_drops_the_waiting_credits
    start_server("PEMK_PICKUP_ENFORCE" => "on")
    s, lo = login("il10@t.co")
    inv(s, 1, {})
    send_env(s, { type: :pos, map: 5, x: 12, y: 7 })
    send_env(s, { type: :pickup_req, kind: :item, item: :POTION, map: 5, x: 12, y: 8, seq: 1 })
    recv_type(s, :pickup_grant, :pickup_deny)
    assert_equal [["POTION", 2, "pickup"]], credits(lo[:account_id])
    s.close
    login("il10@t.co", register: false)
    assert_empty credits(lo[:account_id]), "the record it loads never held that Potion"
  end

  def test_a_one_shot_gift_is_explained_once
    start_server("PEMK_GIFT_ENFORCE" => "on")
    s, lo = login("il11@t.co")
    inv(s, 1, {})
    2.times do   # the same request again: its reply was lost
      send_env(s, { type: :gift_req, map: 10, event: 3, item: "TM80", quantity: 1, nonce: 7, seq: 1 })
      assert_equal :gift_grant, recv_type(s, :gift_grant, :gift_deny)[:type]
    end
    assert_equal [["TM80", 1, "gift"]], credits(lo[:account_id])
    inv(s, 2, { TM80: 1 })
    assert_empty owing(lo[:account_id])
  end

  # A computed call names its item itself: the client chose it, so it explains nothing.
  def test_a_computed_gift_explains_nothing
    start_server("PEMK_GIFT_ENFORCE" => "on")
    s, lo = login("il12@t.co")
    inv(s, 1, {})
    send_env(s, { type: :gift_req, map: 10, event: 4, item: "MASTERBALL", quantity: 1, nonce: 8, seq: 1 })
    assert_equal :gift_grant, recv_type(s, :gift_grant, :gift_deny)[:type]
    assert_empty credits(lo[:account_id])
  end

  # --- trades ---------------------------------------------------------------------

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

  def traders(b_caps: %w[trade_redeliver], a_holders: nil)
    a, la = login("ta#{b_caps.size}@t.co")
    b, lb = login("tb#{b_caps.size}@t.co", caps: b_caps)
    ua = mint(la[:account_id], 1)
    ub = mint(lb[:account_id], 2)
    inv(a, 1, {}, st(holders: a_holders || { ua => :LEFTOVERS }))
    inv(b, 1, {}, st(holders: { ub => nil }))
    [a, la, b, lb, ua, ub]
  end

  # The delivered Pokemon explains its own item when it arrives - once.
  def test_a_traded_pokemon_brings_its_item
    start_server
    a, la, b, lb, ua, ub = traders
    assert_equal true, trade(a, la, b, lb, ua, ub, a_says: :LEFTOVERS)[:ok]
    assert_equal "LEFTOVERS", @db[:trade_deliveries].where(account_id: lb[:account_id], uid: ua).get(:item)
    assert_equal({}, @db[:inventory_snapshots].where(account_id: la[:account_id]).get(:judged).to_h,
                 "the Leftovers left A's judged totals with the Pokemon")
    inv(b, 2, {}, st(holders: { ua => :LEFTOVERS }))
    assert_empty owing(lb[:account_id])
    assert_empty credits(lb[:account_id]), "bound to that Pokemon, not a credit anyone could use"
    assert_equal true, @db[:trade_deliveries].where(account_id: lb[:account_id], uid: ua).get(:explained), "once"
    # It drops out of the snapshot (a save that lost it) while the registry gives it to B,
    # and comes back with the same item: neither a decrease that settles nor an increase.
    inv(b, 3, {}, st(holders: {}))
    assert_equal({ ua.to_s => "LEFTOVERS" }, @db[:inventory_snapshots].where(account_id: lb[:account_id]).get(:vanished).to_h)
    inv(b, 4, {}, st(holders: { ua => :LEFTOVERS }))
    assert_empty owing(lb[:account_id])
    assert_equal({}, @db[:inventory_snapshots].where(account_id: lb[:account_id]).get(:vanished).to_h)
  end

  # A client that cannot be redelivered to gets the item as a credit instead.
  def test_without_a_delivery_the_item_is_a_credit
    start_server
    a, la, b, lb, ua, ub = traders(b_caps: [])
    assert_equal true, trade(a, la, b, lb, ua, ub, a_says: :LEFTOVERS)[:ok]
    assert_equal [["LEFTOVERS", 1, "trade"]], credits(lb[:account_id])
    inv(b, 2, {}, st(holders: { ua => :LEFTOVERS }))
    assert_empty owing(lb[:account_id])
  end

  # The sender's record never saw that Pokemon: its word alone explains nothing.
  def test_an_item_the_senders_record_never_knew_is_not_explained
    start_server
    a, la, b, lb, ua, ub = traders(a_holders: {})
    assert_equal true, trade(a, la, b, lb, ua, ub, a_says: :RARECANDY)[:ok]
    assert_nil @db[:trade_deliveries].where(account_id: lb[:account_id], uid: ua).get(:item)
    inv(b, 2, {}, st(holders: { ua => :RARECANDY }))
    assert_equal [["RARECANDY", -1]], owing(lb[:account_id])
  end
end
