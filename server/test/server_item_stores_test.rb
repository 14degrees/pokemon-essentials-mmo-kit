require "minitest/autorun"
require "socket"
require "timeout"
require "sequel"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)

ENV["PEMK_BIND"] = "127.0.0.1"
ENV["PEMK_PORT"] = "0"
require "pemk"

# Item authority E0 over the wire: the :inv snapshot's stores come back in login_ok
# while the record is whole, and a trade whose escrow says its Pokemon holds something
# else than the sender's record is refused; a traded Pokemon takes its held item out
# of the sender's record.
class ServerItemStoresTest < Minitest::Test
  W = PEMK::Wire

  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))   # jsonb columns read as Hashes
    %i[trade_deliveries monster_transfers monsters enforcement_events inventory_snapshots].each { |t| @db[t].delete rescue nil }
    @db[:accounts].delete
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  def start_server(env = {})
    @server = PEMK::Server.new(config: PEMK::Config.new(env: ENV.to_h.merge(env)), logger: ->(_m) {})
    @server.start
    @port = @server.port
  end

  def send_env(s, e, body = nil)
    s.write(W.encode_split(e, body))
  end

  def recv_type(s, *types)
    Timeout.timeout(5) do
      loop do
        h = s.read(4)
        return nil if h.nil?

        dec = W.decode_envelope(s.read(h.unpack1("N")), false)
        return [dec[:env], dec[:body]] if types.include?(dec[:env][:type])
      end
    end
  end

  def login(email, register: true)
    s = TCPSocket.new("127.0.0.1", @port)
    if register
      send_env(s, { type: :register, email: email, password: "password1" })
      recv_type(s, :register_ok, :register_err)
    end
    send_env(s, { type: :login, email: email, password: "password1", caps: %w[flag_repair trade_redeliver] })
    env, = recv_type(s, :login_ok)
    [s, env]
  end

  def inv(s, seq, bag, stores = nil)
    msg = { type: :inv, bag: bag, seq: seq }
    msg[:stores] = stores if stores
    send_env(s, msg)
    recv_type(s, :inv_ack)
  end

  def stores(holders)
    held = holders.values.compact.tally
    { pc: { POTION: 1 }, mail: {}, held: held, holders: holders }
  end

  def mint(owner, nonce)
    @db[:monsters].insert(owner_account_id: owner, issuer_account_id: owner, client_nonce: nonce,
                          species: "PIKACHU", level_at_issue: 5, personal_id: 1, egg_at_issue: false,
                          status: "active", flagged: false)
  end

  def test_the_stores_come_back_while_the_record_is_whole
    start_server
    a, = login("sa@t.co")
    inv(a, 1, { ORANBERRY: 1 }, stores({ 5 => :LEFTOVERS }))
    a.close
    a, lo = login("sa@t.co", register: false)
    assert_equal({ POTION: 1 }, lo[:inv_stores][:pc])
    assert_equal({ LEFTOVERS: 1 }, lo[:inv_stores][:held])
    assert_equal({ 5 => :LEFTOVERS }, lo[:inv_stores][:holders])

    inv(a, lo[:inv_seq] + 1, { ORANBERRY: 2 })   # an older client: the bag alone
    a.close
    _, lo = login("sa@t.co", register: false)
    assert_nil lo[:inv_stores]
  end

  def test_the_bag_only_record_sends_no_stores
    start_server("PEMK_ITEM_RECORD" => "bag")
    a, = login("sb@t.co")
    inv(a, 1, {}, stores({}))
    a.close
    _, lo = login("sb@t.co", register: false)
    assert_nil lo[:inv_stores]
  end

  # A full trade between A (gives uid ua) and B (gives ub); +a_says+ is what A's lock
  # says its Pokemon holds.
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
    recv_type(a, :trade_result).first
  end

  def test_an_escrow_that_disagrees_with_the_record_is_refused
    start_server
    a, la = login("ta@t.co")
    b, lb = login("tb@t.co")
    ua = mint(la[:account_id], 1)
    ub = mint(lb[:account_id], 2)
    inv(a, 1, {}, stores({ ua => :LEFTOVERS }))     # A's record: its Pokemon holds Leftovers
    r = trade(a, la, b, lb, ua, ub, a_says: nil)    # ... but the escrow says it holds nothing
    assert_equal false, r[:ok]
    assert_equal "item", r[:reason]
    assert_equal la[:account_id], @db[:monsters].where(id: ua).get(:owner_account_id), "nothing moved"
  end

  def test_a_traded_pokemon_takes_its_item_out_of_the_senders_record
    start_server
    a, la = login("ua@t.co")
    b, lb = login("ub@t.co")
    ua = mint(la[:account_id], 1)
    ub = mint(lb[:account_id], 2)
    inv(a, 1, {}, stores({ ua => :LEFTOVERS, 99 => nil }))
    r = trade(a, la, b, lb, ua, ub, a_says: :LEFTOVERS)
    assert_equal true, r[:ok], r.inspect
    row = @db[:inventory_snapshots].where(account_id: la[:account_id]).first
    assert_equal({}, row[:held].to_h)
    assert_equal({ "99" => nil }, row[:holders].to_h)
  end
end
