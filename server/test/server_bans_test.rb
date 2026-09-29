require "minitest/autorun"
require "socket"
require "timeout"
require "sequel"

root  = File.expand_path("..", __dir__)               # server/
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)

ENV["PEMK_BIND"] = "127.0.0.1"
ENV["PEMK_PORT"] = "0"
require "pemk"

# Moderation: an operator bans an account (bin/pemk_admin.rb). The server refuses it at
# login and at a resume, telling it until when and why, and lets go of a banned account
# that is playing. A lifted or ended ban is no ban; nothing of it is erased.
class ServerBansTest < Minitest::Test
  W = PEMK::Wire

  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete rescue nil   # no cascade from accounts (deliberate)
    @db[:enforcement_events].delete rescue nil
    @db[:accounts].delete
    @bans = PEMK::Bans.new(@db)
    @server = PEMK::Server.new(logger: ->(_m) {})
    @server.start
    @port = @server.port
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  def send_env(sock, env)
    sock.write(W.encode_split(env))
  end

  def recv_env(sock, timeout = 5)
    Timeout.timeout(timeout) do
      hdr = sock.read(4)
      return nil if hdr.nil?

      W.decode_envelope(sock.read(hdr.unpack1("N")), false)[:env]
    end
  end

  # The first frame of +type+ (others are skipped), or nil when the socket closes first.
  def recv_type(sock, type, timeout = 5)
    Timeout.timeout(timeout) do
      loop do
        env = recv_env(sock, timeout)
        return nil if env.nil?
        return env if env[:type] == type
      end
    end
  end

  def register(email)
    c = TCPSocket.new("127.0.0.1", @port)
    send_env(c, { type: :register, email: email, password: "charizard1" })
    id = recv_env(c)[:account_id]
    c.close
    id
  end

  def login(email, password = "charizard1")
    c = TCPSocket.new("127.0.0.1", @port)
    send_env(c, { type: :login, email: email, password: password })
    [c, recv_env(c)]
  end

  def test_what_is_in_force
    id = register("mod@t.co")
    now = Time.now
    assert_nil @bans.active(id)
    @bans.ban(id, reason: "old", by: "op", ends_at: now - 60, now: now - 3600)   # over
    assert_nil @bans.active(id, now: now)
    b = @bans.ban(id, reason: "botting", by: "op", ends_at: now + 3600, now: now)
    assert_equal b, @bans.active(id, now: now)[:id]
    assert_equal [id], @bans.banned_among([id, id + 1], now: now)
    assert_equal 1, @bans.lift(id, by: "op", now: now)
    assert_nil @bans.active(id, now: now)
    assert_equal 2, @bans.history(id).size, "a lifted ban stays on record"
  end

  def test_a_banned_account_cannot_log_in
    id = register("ban@t.co")
    ends = Time.at(Time.now.to_i + 86_400)
    @bans.ban(id, reason: "item duplication", by: "op", ends_at: ends)
    c, reply = login("ban@t.co")
    assert_equal :login_err, reply[:type]
    assert_equal "banned", reply[:reason]
    assert_equal ends.to_i, reply[:until]
    assert_equal "item duplication", reply[:note]
    c.close
    # the password is checked first: a stranger learns nothing of the ban
    c, reply = login("ban@t.co", "wrongpass1")
    assert_equal "bad_password", reply[:reason]
    c.close
  end

  def test_a_lifted_ban_lets_the_account_back_in
    id = register("back@t.co")
    @bans.ban(id, reason: "", by: "op")
    @bans.lift(id, by: "op")
    c, reply = login("back@t.co")
    assert_equal :login_ok, reply[:type]
    c.close
  end

  def test_a_session_cannot_resume_once_banned
    id = register("resume@t.co")
    c, reply = login("resume@t.co")
    token = reply[:token]
    c.close
    @bans.ban(id, reason: "", by: "op")   # straight in the table: the token was not revoked
    c2 = TCPSocket.new("127.0.0.1", @port)
    send_env(c2, { type: :auth, token: token, resume: true })
    a = recv_env(c2)
    assert_equal :auth_err, a[:type]
    assert_equal "banned", a[:reason]
    assert_nil a[:until], "until lifted"
    c2.close
  end

  def test_a_playing_account_is_let_go
    id = register("live@t.co")
    other = register("other@t.co")
    c, reply = login("live@t.co")
    assert_equal :login_ok, reply[:type]
    o, = login("other@t.co")
    @bans.ban(id, reason: "speed hack", by: "op")
    @server.instance_variable_set(:@last_ban_sweep, nil)   # the next tick sweeps
    told = recv_type(c, :banned, PEMK::Server::BAN_SWEEP_SEC + 5)
    refute_nil told, "the banned window is told why"
    assert_equal "speed hack", told[:note]
    assert_nil Timeout.timeout(5) { c.read(1) }, "and its connection closes"
    send_env(o, { type: :ping })
    refute_nil recv_type(o, :pong), "the others play on"
    assert_nil @bans.active(other)
  ensure
    c&.close
    o&.close
  end
end
