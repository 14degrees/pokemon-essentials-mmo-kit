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
require_relative "support/ws_client"

# The whole server behind the WebSocket door: an account registers, logs in and
# reconnects with its token over WebSocket messages, with the same envelopes the TCP
# door speaks. PEMK_WS_PORT unset leaves no listener.
class ServerWsTest < Minitest::Test
  W = PEMK::Wire

  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
    %i[asset_events asset_tokens monster_transfers monsters enforcement_events accounts].each { |t| @db[t].delete rescue nil }
    @server = PEMK::Server.new(config: PEMK::Config.new(env: ENV.to_h.merge("PEMK_WS_PORT" => "0")), logger: ->(_m) {})
    @server.start
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  def message(env, body = nil)
    f = W.encode_split(env, body)
    f.byteslice(4, f.bytesize - 4)
  end

  def recv(c)
    _, msg = c.read_message
    W.decode_envelope(msg, false)[:env]
  end

  def test_register_login_and_token_reconnect_over_websocket
    c = WsClient.new("127.0.0.1", @server.ws_port)
    assert c.accept_ok
    c.send_message(message({ type: :register, email: "web@t.co", password: "charizard1" }))
    reg = recv(c)
    assert_equal :register_ok, reg[:type]
    c.send_message(message({ type: :login, email: "web@t.co", password: "charizard1" }))
    lo = recv(c)
    assert_equal :login_ok, lo[:type]
    assert_equal reg[:account_id], lo[:account_id]
    c.close

    c2 = WsClient.new("127.0.0.1", @server.ws_port)
    c2.send_message(message({ type: :auth, token: lo[:token] }))
    a = recv(c2)
    assert_equal :auth_ok, a[:type]
    assert_equal reg[:account_id], a[:account_id]
    # The TCP door still answers beside it.
    t = TCPSocket.new("127.0.0.1", @server.port)
    t.write(W.encode_split({ type: :ping, t: 1 }))
    len = Timeout.timeout(3) { t.read(4) }.unpack1("N")
    assert_equal :pong, W.decode_envelope(t.read(len), false)[:env][:type]
    t.close
    c2.close
  end

  def test_no_listener_unless_configured
    off = PEMK::Server.new(config: PEMK::Config.new(env: ENV.to_h.tap { |e| e.delete("PEMK_WS_PORT") }), logger: ->(_m) {})
    off.start
    assert_nil off.ws_port
  ensure
    off&.stop
  end
end
