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

# A traded Pokemon reaches the receiver's disk only with its next save. The server keeps
# the escrow the partner locked until a save that follows the receiver's
# :trade_applied lands, and sends it again (:trade_redeliver) to a client that asks
# (:trade_owed) before then: after a crash, or a result lost with the connection.
class ServerTradeDeliveryTest < Minitest::Test
  W = PEMK::Wire
  CAPS = %w[flag_repair trade_redeliver].freeze

  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
    %i[trade_deliveries monster_transfers monsters enforcement_events].each { |t| @db[t].delete rescue nil }
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

  # -> [env, body] of the next frame of one of +types+.
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

  def login(email, caps: CAPS, register: true)
    s = TCPSocket.new("127.0.0.1", @port)
    if register
      send_env(s, { type: :register, email: email, password: "password1" })
      recv_type(s, :register_ok, :register_err)
    end
    send_env(s, { type: :login, email: email, password: "password1", caps: caps })
    env, = recv_type(s, :login_ok)
    [s, env]
  end

  def resume(token, caps: CAPS)
    s = TCPSocket.new("127.0.0.1", @port)
    send_env(s, { type: :auth, token: token, caps: caps, resume: true })
    env, = recv_type(s, :auth_ok)
    [s, env]
  end

  def mint(owner, nonce)
    @db[:monsters].insert(owner_account_id: owner, issuer_account_id: owner, client_nonce: nonce,
                          species: "PIKACHU", level_at_issue: 5, personal_id: 1, egg_at_issue: false,
                          status: "active", flagged: false)
  end

  # A full trade: each side locks its escrow, then both commit. -> the two escrows.
  def trade(a, la, b, lb, tid = "t-1")
    ua = mint(la[:account_id], 11)
    ub = mint(lb[:account_id], 22)
    send_env(a, { type: :trade_invite, to: lb[:account_id], trade_id: tid })
    recv_type(b, :trade_invite)
    send_env(b, { type: :trade_accept, to: la[:account_id], trade_id: tid })
    recv_type(a, :trade_accept)
    esc_a = Marshal.dump([["alice's", ua]])
    esc_b = Marshal.dump([["bob's", ub]])
    send_env(a, { type: :trade_lock, to: lb[:account_id], trade_id: tid, uid: ua }, esc_a)
    recv_type(b, :trade_lock)
    send_env(b, { type: :trade_lock, to: la[:account_id], trade_id: tid, uid: ub }, esc_b)
    recv_type(a, :trade_lock)
    send_env(a, { type: :trade_commit, trade_id: tid, partner: lb[:account_id], give: [ua], recv: [ub] })
    send_env(b, { type: :trade_commit, trade_id: tid, partner: la[:account_id], give: [ub], recv: [ua] })
    ra, = recv_type(a, :trade_result)
    rb, = recv_type(b, :trade_result)
    assert ra[:ok] && rb[:ok], [ra, rb].inspect
    { ua: ua, ub: ub, esc_a: esc_a, esc_b: esc_b }
  end

  def owed(s)
    send_env(s, { type: :trade_owed })
    out = []
    begin
      Timeout.timeout(1) { loop { out << recv_type(s, :trade_redeliver) } }
    rescue Timeout::Error
      nil
    end
    out.compact
  end

  def save(s, seq)
    send_env(s, { type: :save, seq: seq }, "\x04\b0".b)
    sleep 0.3   # no reply: let the mailbox store it
  end

  def test_the_escrow_is_owed_until_a_save_after_the_report
    start_server
    a, la = login("da@t.co")
    b, lb = login("db@t.co")
    t = trade(a, la, b, lb)
    assert_equal true, la[:trade_redelivery]
    assert_equal 2, @db[:trade_deliveries].count

    # Bob reports it in his party, and a save lands: his is sealed.
    send_env(b, { type: :trade_applied, trade_id: "t-1" })
    save(b, 1)
    assert_equal [la[:account_id]], @db[:trade_deliveries].select_map(:account_id)

    # Alice died before saving: after her next login, she is owed Bob's escrow.
    a.close
    a2, = login("da@t.co", register: false)
    got = owed(a2)
    assert_equal 1, got.size
    env, body = got.first
    assert_equal t[:ub], env[:uid]
    assert_equal "t-1", env[:trade_id]
    assert_equal t[:esc_b], body
    assert_empty owed(b), "Bob's is on his disk"
  end

  # The report came, the save did not: a fresh login loads a save without it.
  def test_a_report_without_a_save_is_owed_again_after_a_fresh_login
    start_server
    a, la = login("ea@t.co")
    b, lb = login("eb@t.co")
    trade(a, la, b, lb)
    send_env(a, { type: :trade_applied, trade_id: "t-1" })
    sleep 0.2
    assert_empty owed(a), "reported: this session holds it"
    a.close
    a2, = login("ea@t.co", register: false)
    assert_equal 1, owed(a2).size
  end

  # The result was lost with the socket: the resumed session asks and gets it.
  def test_a_resumed_session_is_owed_what_it_never_reported
    start_server
    a, la = login("fa@t.co")
    b, lb = login("fb@t.co")
    trade(a, la, b, lb)
    a.close
    a2, = resume(la[:token])
    assert_equal 1, owed(a2).size
  end

  def test_a_client_that_cannot_take_one_is_never_owed
    start_server
    a, la = login("ga@t.co", caps: %w[flag_repair])
    b, lb = login("gb@t.co")
    trade(a, la, b, lb)
    assert_equal [lb[:account_id]], @db[:trade_deliveries].select_map(:account_id), "only Bob can take one"
    assert_empty owed(a)
  end

  def test_the_operator_can_turn_it_off
    start_server("PEMK_TRADE_REDELIVERY" => "off")
    a, la = login("ha@t.co")
    b, lb = login("hb@t.co")
    trade(a, la, b, lb)
    assert_equal false, la[:trade_redelivery]
    assert_equal 0, @db[:trade_deliveries].count
  end
end
