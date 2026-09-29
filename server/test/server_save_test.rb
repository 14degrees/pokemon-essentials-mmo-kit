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

# Save-store integration: a save round-trips through Postgres (login returns it as
# an opaque body on the next session), and a hostile save body is stored verbatim
# WITHOUT the server ever Marshal.load'ing it (the _load gadget never fires).
class ServerSaveTest < Minitest::Test
  W = PEMK::Wire

  # If the server ever deserialized a save body, this gadget's _load would flip
  # the global. It must stay false.
  class Boom
    def self._load(_s)
      $pemk_srv_boom = true
      allocate
    end

    def _dump(_l)
      "x"
    end
  end

  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete rescue nil   # no cascade from accounts (deliberate)
    @db[:enforcement_events].delete rescue nil
    @db[:accounts].delete
    @server = PEMK::Server.new(logger: ->(_m) {})
    @server.start
    @port = @server.port
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  def open_conn
    TCPSocket.new("127.0.0.1", @port)
  end

  def send_env(sock, env, body = nil)
    sock.write(W.encode_split(env, body))
  end

  def recv(sock, timeout = 5)
    Timeout.timeout(timeout) do
      hdr = sock.read(4)
      return nil if hdr.nil?

      W.decode_envelope(sock.read(hdr.unpack1("N")), false)
    end
  end

  def register(sock, user, pw)
    send_env(sock, { type: :register, email: "#{user}@t.co", password: pw })
    recv(sock)
  end

  def login(sock, user, pw)
    send_env(sock, { type: :login, email: "#{user}@t.co", password: pw })
    recv(sock)
  end

  def wait_until(timeout = 3)
    deadline = Time.now + timeout
    loop do
      value = yield
      return value if value
      raise "timeout waiting" if Time.now > deadline

      sleep 0.05
    end
  end

  def test_save_persists_and_reloads_as_body
    c = open_conn
    assert_equal :register_ok, register(c, "Nate", "hoennrules1")[:env][:type]
    lo = login(c, "Nate", "hoennrules1")
    assert_equal :login_ok, lo[:env][:type]
    assert_nil lo[:body], "a brand-new account has no save"
    account_id = lo[:env][:account_id]

    blob = Marshal.dump({ party: [1, 2, 3], money: 5000, name: "Réd" })
    send_env(c, { type: :save, trainer_id: 42 }, blob)
    wait_until { @db[:characters].where(account_id: account_id).get(:save_blob) }
    c.close

    c2 = open_conn
    lo2 = login(c2, "Nate", "hoennrules1")
    assert_equal :login_ok, lo2[:env][:type]
    assert_equal blob, lo2[:body], "login returns the stored save as an opaque body"
    c2.close
  end

  def test_hostile_save_body_stored_but_never_deserialized
    c = open_conn
    register(c, "Cynthia", "garchomp11")
    account_id = login(c, "Cynthia", "garchomp11")[:env][:account_id]

    $pemk_srv_boom = false
    evil = Marshal.dump(Boom.new)
    send_env(c, { type: :save }, evil)
    stored = wait_until { @db[:characters].where(account_id: account_id).get(:save_blob) }

    assert_equal false, $pemk_srv_boom, "server must not Marshal.load a save body"
    assert_equal evil, stored.to_s, "hostile bytes stored verbatim"
    c.close
  end

  # Durability: a client that asks is told whether each save was written, so it sends
  # one again instead of trusting a save that never landed.
  def login_with(sock, user, pw, caps)
    send_env(sock, { type: :login, email: "#{user}@t.co", password: pw, caps: caps })
    recv(sock)
  end

  # The first frame of +type+, or nil when none comes within +timeout+. (IO.select, not
  # a Timeout inside recv's: a nested Timeout can fire after its block has ended.)
  def next_of(sock, type, timeout = 3)
    deadline = Time.now + timeout
    loop do
      left = deadline - Time.now
      return nil if left <= 0 || !IO.select([sock], nil, nil, left)

      hdr = sock.read(4)
      return nil unless hdr

      env = W.decode_envelope(sock.read(hdr.unpack1("N")), false)[:env]
      return env if env[:type] == type
    end
  end

  def test_a_written_save_is_answered
    c = open_conn
    register(c, "Ash", "pikachu111")
    lo = login_with(c, "Ash", "pikachu111", %w[save_ack])
    assert_equal true, lo[:env][:save_ack], "the login says saves are answered"
    send_env(c, { type: :save, seq: 7 }, Marshal.dump({ money: 1 }))
    ok = next_of(c, :save_ok)
    refute_nil ok
    assert_equal 7, ok[:seq]
    refute_nil @db[:characters].where(account_id: lo[:env][:account_id]).get(:save_blob), "answered once written"
    c.close
  end

  def test_an_older_client_is_not_answered
    c = open_conn
    register(c, "Misty", "starmie111")
    login_with(c, "Misty", "starmie111", [])
    send_env(c, { type: :save, seq: 1 }, Marshal.dump({ money: 1 }))
    assert_nil next_of(c, :save_ok, 1.5)
    c.close
  end

  def test_a_save_the_database_refuses_is_answered_as_not_written
    c = open_conn
    register(c, "Brock", "onix111111")
    id = login_with(c, "Brock", "onix111111", %w[save_ack])[:env][:account_id]
    chars = @server.instance_variable_get(:@characters)
    chars.define_singleton_method(:store) { |*, **| raise Sequel::DatabaseError, "disk full" }
    sealed = []
    deliveries = @server.instance_variable_get(:@trade_deliveries)   # on by default
    refute_nil deliveries
    deliveries.define_singleton_method(:seal) { |aid| sealed << aid }
    send_env(c, { type: :save, seq: 3 }, Marshal.dump({ money: 1 }))
    err = next_of(c, :save_err)
    refute_nil err
    assert_equal [3, "store_failed"], [err[:seq], err[:reason]]
    assert_nil @db[:characters].where(account_id: id).get(:save_blob)
    assert_empty sealed, "nothing that counts on the save runs"
    c.close
  end

  def test_a_save_too_large_names_its_seq
    c = open_conn
    register(c, "Gary", "eevee11111")
    login_with(c, "Gary", "eevee11111", %w[save_ack])
    send_env(c, { type: :save, seq: 9 }, "x" * (PEMK::Server::SAVE_MAX_BYTES + 1))
    err = next_of(c, :save_err)
    assert_equal [9, "too_large"], [err[:seq], err[:reason]]
    c.close
  end
end
