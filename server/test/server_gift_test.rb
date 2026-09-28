require "minitest/autorun"
require "socket"
require "timeout"
require "sequel"
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

# Step 6 over the wire: the client asks (:gift_req) before an event gives an item. A
# one-shot gift the export knows is granted once per account; the grant is final once
# a bag snapshot lands after the client's :gift_applied, and a fresh login voids one
# that never got there - so neither a re-armed event nor a crash changes the count.
class ServerGiftTest < Minitest::Test
  W = PEMK::Wire

  FIXTURE = Tempfile.new(["pemk_world", ".json"])
  FIXTURE.write(JSON.generate(
    "schema_version" => 3,
    "maps" => { "10" => { "name" => "Gym", "width" => 20, "height" => 20, "objects" => [
      # Brock: one payout, then his page turns.
      { "kind" => "gift", "item" => "TM80", "items" => ["TM80"], "x" => 6, "y" => 5, "event_id" => 3,
        "once" => true, "dynamic" => false, "quantities" => { "TM80" => 1 } },
      # A giver with no marker: gives whenever asked (the Coin Case NPC).
      { "kind" => "gift", "item" => "POTION", "items" => ["POTION"], "x" => 2, "y" => 2, "event_id" => 5,
        "once" => false, "dynamic" => false, "quantities" => { "POTION" => 2 } },
      # A prize table with a computed call (the lottery's stored prize).
      { "kind" => "prize", "item" => "MASTERBALL", "items" => %w[MASTERBALL ULTRABALL], "x" => 9, "y" => 2,
        "event_id" => 6, "once" => false, "dynamic" => true },
      # An export from before step 6: no once / dynamic.
      { "kind" => "gift", "item" => "BICYCLE", "items" => ["BICYCLE"], "x" => 4, "y" => 4, "event_id" => 7 }
    ] } }
  ))
  FIXTURE.flush

  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
    %i[gift_grants gift_claims flag_snapshots inventory_snapshots enforcement_events
       monster_transfers monsters].each { |t| @db[t].delete rescue nil }
    @db[:accounts].delete
    @logs = Queue.new
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  def start_server(gift: "on")
    env = ENV.to_h.merge("PEMK_WORLD" => FIXTURE.path, "PEMK_GIFT_ENFORCE" => gift,
                         "PEMK_FLAG_STATE" => "shadow")
    @server = PEMK::Server.new(config: PEMK::Config.new(env: env), logger: ->(m) { @logs << m })
    @server.start
    @port = @server.port
  end

  def logs
    out = []
    out << @logs.pop until @logs.empty?
    out
  end

  def open_conn; TCPSocket.new("127.0.0.1", @port); end
  def send_env(sock, env); sock.write(W.encode_split(env)); end

  def recv(sock, timeout = 5)
    Timeout.timeout(timeout) do
      hdr = sock.read(4)
      return nil if hdr.nil?

      W.decode_envelope(sock.read(hdr.unpack1("N")), false)[:env]
    end
  end

  # The next frame of one of +types+ (the server interleaves presence and acks).
  def recv_type(sock, *types)
    loop do
      r = recv(sock)
      return r if r.nil? || types.include?(r[:type])
    end
  end

  def register(email)
    c = open_conn
    send_env(c, { type: :register, email: email, password: "password1" }); recv(c)
    c.close
  end

  def login(email)
    c = open_conn
    send_env(c, { type: :login, email: email, password: "password1" })
    [c, recv_type(c, :login_ok)]
  end

  def resume(token)
    c = open_conn
    send_env(c, { type: :auth, token: token, resume: true })
    [c, recv_type(c, :auth_ok)]
  end

  def ask(c, nonce, event: 3, item: "TM80", quantity: 1, seq: nonce)
    send_env(c, { type: :gift_req, map: 10, event: event, item: item, quantity: quantity, nonce: nonce, seq: seq })
    recv_type(c, :gift_grant, :gift_deny)
  end

  # The client's bag flush after it applied the gift; returns once the server stored it.
  def bag(c, seq, items = { "TM80" => 1 })
    send_env(c, { type: :inv, bag: items, seq: seq })
    recv_type(c, :inv_ack)
  end

  def applied(c, nonce, event: 3)
    send_env(c, { type: :gift_applied, map: 10, event: event, nonce: nonce })
  end

  def grant_state
    @db[:gift_grants].where(map: 10, event: 3).get(:state)
  end

  def test_the_gate_is_advertised_only_when_on
    start_server(gift: "off")
    register("g0@t.co")
    _, lo = login("g0@t.co")
    assert_equal false, lo[:gift_gate]
    @server.stop
    start_server(gift: "shadow")
    _, lo = login("g0@t.co")
    assert_equal true, lo[:gift_gate]
  end

  def test_a_one_shot_gift_is_granted_once
    start_server
    register("g1@t.co")
    c, = login("g1@t.co")
    r = ask(c, 11, seq: 1)
    assert_equal :gift_grant, r[:type]
    assert_equal 1, r[:seq]

    r = ask(c, 12, seq: 2)
    assert_equal :gift_deny, r[:type]
    assert_equal 2, r[:seq]
    assert_equal "already_claimed", r[:reason]
    assert(logs.any? { |l| l.include?("DENY") && l.include?("already paid") })
  end

  def test_shadow_grants_what_on_would_refuse
    start_server(gift: "shadow")
    register("g2@t.co")
    c, = login("g2@t.co")
    assert_equal :gift_grant, ask(c, 11)[:type]
    assert_equal :gift_grant, ask(c, 12)[:type]
    assert(logs.any? { |l| l.include?("WOULD-DENY") })
  end

  # An item this event never gives: an edited map, or a stale export.
  def test_an_item_the_event_never_gives_is_refused
    start_server
    register("g3@t.co")
    c, = login("g3@t.co")
    assert_equal "not_this_gift", ask(c, 11, item: "MASTERBALL")[:reason]
    assert_equal "not_this_gift", ask(c, 12, event: 5, item: "POTION", quantity: 5)[:reason]
    assert_equal :gift_grant, ask(c, 13, event: 5, item: "POTION", quantity: 2)[:type]
  end

  # A computed call can give anything, and an old export does not say: both granted.
  def test_a_computed_or_unknown_gift_is_granted
    start_server
    register("g4@t.co")
    c, = login("g4@t.co")
    assert_equal :gift_grant, ask(c, 11, event: 6, item: "PPUP")[:type]
    assert_equal :gift_grant, ask(c, 12, event: 7, item: "BICYCLE")[:type]
    assert_equal :gift_grant, ask(c, 13, event: 7, item: "BICYCLE")[:type]
    assert_equal :gift_grant, ask(c, 14, event: 42, item: "RARECANDY")[:type]
    assert_nil grant_state
  end

  # A giver that gives whenever asked is granted every time, and the detection ledger
  # still counts it.
  def test_a_repeatable_gift_is_granted_and_recorded
    start_server
    register("g5@t.co")
    c, = login("g5@t.co")
    3.times { |i| assert_equal :gift_grant, ask(c, 20 + i, event: 5, item: "POTION")[:type] }
    Timeout.timeout(5) { sleep 0.05 until @db[:gift_claims].where(event: 5).get(:claims) == 3 }
  end

  def test_a_malformed_request_is_refused
    start_server
    register("g6@t.co")
    c, = login("g6@t.co")
    send_env(c, { type: :gift_req, map: 10, event: 3, item: "tm80; drop", quantity: 1, nonce: 1, seq: 9 })
    r = recv_type(c, :gift_grant, :gift_deny)
    assert_equal "bad", r[:reason]
    assert_equal "bad", ask(c, 0)[:reason]
  end

  # Applied, then a bag snapshot: final. A fresh login and a re-armed event get nothing.
  def test_a_sealed_gift_survives_a_fresh_login
    start_server
    register("g7@t.co")
    c, = login("g7@t.co")
    ask(c, 11)
    applied(c, 11)
    bag(c, 1)
    assert_equal "sealed", grant_state
    c.close

    c2, = login("g7@t.co")
    assert_equal "already_claimed", ask(c2, 12)[:reason]
  end

  # The client died before its bag reached the server: the login's bag lacks the gift,
  # so the event that re-armed with the stored save pays it again.
  def test_a_gift_lost_in_a_crash_is_paid_again
    start_server
    register("g8@t.co")
    c, = login("g8@t.co")
    ask(c, 11)
    applied(c, 11)
    c.close

    c2, = login("g8@t.co")
    assert_equal :gift_grant, ask(c2, 12)[:type]
  end

  # The grant was lost with the socket: the resumed session asks again with the same
  # request, before its bag, and is granted again; its bag does not settle it early.
  def test_a_resumed_session_re_sends_and_is_granted_again
    start_server
    register("g9@t.co")
    c, lo = login("g9@t.co")
    ask(c, 11)
    c.close

    c2, = resume(lo[:token])
    assert_equal :gift_grant, ask(c2, 11)[:type]
    bag(c2, 1, {})
    assert_equal "granted", grant_state
    applied(c2, 11)
    bag(c2, 2)
    assert_equal "sealed", grant_state
  end

  # The :gift_applied was lost with the socket, the item is in the bag: the resumed
  # session's first bag snapshot settles the grant, so a re-armed event is refused.
  def test_a_grant_left_behind_is_settled_by_the_next_session
    start_server
    register("g10@t.co")
    c, lo = login("g10@t.co")
    ask(c, 11)
    c.close

    c2, = resume(lo[:token])
    bag(c2, 1)
    assert_equal "sealed", grant_state
    assert_equal "already_claimed", ask(c2, 12)[:reason]
  end

  # A resume keeps the client's live state, so it voids nothing.
  def test_a_resume_voids_nothing
    start_server
    register("g11@t.co")
    c, lo = login("g11@t.co")
    ask(c, 11)
    applied(c, 11)
    c.close

    resume(lo[:token])
    assert_equal "applied", grant_state
    c2, = login("g11@t.co")
    assert_equal "void", grant_state
    c2.close
  end
end
