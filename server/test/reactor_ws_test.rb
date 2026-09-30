require "minitest/autorun"
require "socket"
require "timeout"

lib   = File.expand_path("../lib", __dir__)
proto = File.expand_path("../../protocol", __dir__)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk_wire"
require "pemk/reactor"
require_relative "support/ws_client"

# The reactor's WebSocket door: the RFC 6455 handshake, a message in each direction
# (one message = one PEMK payload, no length prefix), the three payload-length
# encodings, fragments, control frames, the refusals, and the TCP door still open
# beside it.
class ReactorWsTest < Minitest::Test
  W = PEMK::Wire

  def setup
    @received = Queue.new
    @closed   = Queue.new
    @reactor  = PEMK::Reactor.new(host: "127.0.0.1", port: 0, ws_port: 0, on_frame: method(:handle),
                                  on_close: ->(c) { @closed << c })
    @reactor.start
    @thread = Thread.new { @reactor.run }
    @thread.abort_on_exception = true
  end

  def teardown
    @reactor.stop
    @thread&.join(3)
  end

  # Echoes a :ping as a :pong; answers :big with a body of the asked size.
  def handle(conn, payload)
    dec = W.decode_envelope(payload, false)
    @received << [conn, dec]
    return unless dec

    case dec[:env][:type]
    when :ping then @reactor.send_frame(conn, W.encode_split({ type: :pong, t: dec[:env][:t] }))
    when :big  then @reactor.send_frame(conn, W.encode_split({ type: :blob }, "z" * dec[:env][:n]))
    end
  end

  def ws
    c = WsClient.new("127.0.0.1", @reactor.ws_port)
    assert c.accept_ok, "handshake refused: #{c.status}"
    c
  end

  def payload(env, body = nil)
    f = W.encode_split(env, body)
    f.byteslice(4, f.bytesize - 4)   # the message is the payload alone
  end

  def test_handshake_accept_value_is_the_rfc_s
    c = WsClient.new("127.0.0.1", @reactor.ws_port, key: "dGhlIHNhbXBsZSBub25jZQ==")   # RFC 6455 4.2.2's example
    assert_equal "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", c.headers["sec-websocket-accept"]
    assert c.accept_ok
    c.close
  end

  def test_a_message_each_way_without_a_length_prefix
    c = ws
    c.send_message(payload({ type: :ping, t: 7 }))
    _, got = Timeout.timeout(3) { @received.pop }
    assert_equal({ type: :ping, t: 7 }, got[:env])
    op, msg = c.read_message
    assert_equal 0x2, op
    assert_equal({ type: :pong, t: 7 }, W.decode_envelope(msg, false)[:env])
    c.close
  end

  def test_a_text_frame_is_a_message_too
    c = ws
    c.send_message(payload({ type: :ping, t: 1 }), opcode: 0x1)
    _, got = Timeout.timeout(3) { @received.pop }
    assert_equal :ping, got[:env][:type]
    c.close
  end

  def test_every_length_encoding_and_a_body_each_way
    c = ws
    [100, 300, 70_000].each do |n|   # 7-bit, 16-bit and 64-bit lengths
      c.send_message(payload({ type: :echo, n: n }, "y" * n))
      _, got = Timeout.timeout(5) { @received.pop }
      assert_equal n, got[:env][:n]
      assert_equal "y" * n, got[:body]
      c.send_message(payload({ type: :big, n: n }))
      Timeout.timeout(5) { @received.pop }
      _, msg = c.read_message
      dec = W.decode_envelope(msg, false)
      assert_equal :blob, dec[:env][:type]
      assert_equal n, dec[:body].bytesize
    end
    c.close
  end

  def test_two_messages_in_one_write_and_a_fragmented_one
    c = ws
    c.sock.write(c.frame(0x2, payload({ type: :ping, t: 1 })) + c.frame(0x2, payload({ type: :ping, t: 2 })))
    ts = 2.times.map { Timeout.timeout(3) { @received.pop }[1][:env][:t] }
    assert_equal [1, 2], ts
    2.times { c.read_message }
    p = payload({ type: :ping, t: 3 }, "abcdef")
    c.sock.write(c.frame(0x2, p.byteslice(0, 5), fin: false) + c.frame(0x0, p.byteslice(5, p.bytesize - 5), fin: true))
    _, got = Timeout.timeout(3) { @received.pop }
    assert_equal [3, "abcdef"], [got[:env][:t], got[:body]]
    c.close
  end

  def test_ping_is_answered_with_pong_and_close_is_echoed
    c = ws
    c.send_ping("hi")
    assert_equal [0xA, "hi"], c.read_message
    c.send_close(1000)
    op, body = c.read_message
    assert_equal [0x8, 1000], [op, body.unpack1("n")]
    Timeout.timeout(3) { @closed.pop }
    assert_equal 0, @reactor.conn_count
    c.close
  end

  def test_an_unmasked_client_frame_closes_the_connection
    c = ws
    c.send_message(payload({ type: :ping, t: 1 }), masked: false)
    Timeout.timeout(3) { @closed.pop }
    assert_equal 0, @reactor.conn_count
    assert @received.empty?
    c.close
  end

  def test_a_plain_http_request_is_refused
    s = TCPSocket.new("127.0.0.1", @reactor.ws_port)
    s.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
    reply = Timeout.timeout(3) { s.read }
    assert reply.start_with?("HTTP/1.1 400"), reply
    Timeout.timeout(3) { @closed.pop }
    s.close
  end

  def test_a_legacy_marshal_payload_is_still_rejected_and_the_tcp_door_still_works
    c = ws
    c.send_message(W.encode({ type: :ping }).byteslice(4..))   # whole-Marshal: the host path refuses it
    _, dec = Timeout.timeout(3) { @received.pop }
    assert_nil dec
    c.close
    t = TCPSocket.new("127.0.0.1", @reactor.port)
    t.write(W.encode_split({ type: :ping, t: 9 }))
    _, got = Timeout.timeout(3) { @received.pop }
    assert_equal 9, got[:env][:t]
    len = t.read(4).unpack1("N")
    assert_equal 9, W.decode_envelope(t.read(len), false)[:env][:t]
    t.close
  end
end
