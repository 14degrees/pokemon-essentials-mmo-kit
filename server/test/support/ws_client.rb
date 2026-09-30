# frozen_string_literal: true

require "socket"
require "timeout"
require "digest/sha1"
require "base64"
require "securerandom"

# A minimal WebSocket CLIENT (RFC 6455) for the tests: the handshake, masked frames
# out, unmasked frames in, control frames. Just enough to be a browser's stand-in.
class WsClient
  GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  attr_reader :sock, :accept_ok, :status, :headers

  def initialize(host, port, path: "/", headers: {}, key: nil)
    @sock = TCPSocket.new(host, port)
    key ||= Base64.strict_encode64(SecureRandom.random_bytes(16))
    req = ["GET #{path} HTTP/1.1", "Host: #{host}:#{port}", "Upgrade: websocket", "Connection: Upgrade",
           "Sec-WebSocket-Key: #{key}", "Sec-WebSocket-Version: 13"]
    headers.each { |k, v| req << "#{k}: #{v}" }
    @sock.write(req.join("\r\n") + "\r\n\r\n")
    @status, @headers = read_http_head
    expected = Base64.strict_encode64(Digest::SHA1.digest(key + GUID))
    @accept_ok = @status.include?(" 101 ") && @headers["sec-websocket-accept"] == expected
  end

  def send_message(payload, opcode: 0x2, fin: true, masked: true)
    @sock.write(frame(opcode, payload, fin: fin, masked: masked))
  end

  def send_ping(payload = "")  = @sock.write(frame(0x9, payload))
  def send_close(code = 1000)  = @sock.write(frame(0x8, [code].pack("n")))
  def close                    = (@sock.close rescue nil)

  # -> [opcode, payload] of the next server frame (fragments reassembled for data).
  def read_message(timeout = 5)
    Timeout.timeout(timeout) do
      buffer = nil
      loop do
        b0, b1 = @sock.read(2).unpack("CC")
        fin, opcode, masked, len = (b0 & 0x80) != 0, b0 & 0x0F, (b1 & 0x80) != 0, b1 & 0x7F
        raise "server frame was masked" if masked

        len = @sock.read(2).unpack1("n") if len == 126
        len = @sock.read(8).unpack1("Q>") if len == 127
        payload = len.zero? ? "".b : @sock.read(len)
        return [opcode, payload] if opcode >= 0x8

        buffer = buffer ? buffer + payload : payload
        return [opcode, buffer] if fin
      end
    end
  end

  def frame(opcode, payload, fin: true, masked: true)
    payload = payload.b
    len = payload.bytesize
    head = [(fin ? 0x80 : 0) | opcode].pack("C")
    mbit = masked ? 0x80 : 0
    head << if len < 126 then [mbit | len].pack("C")
            elsif len < 65_536 then [mbit | 126, len].pack("Cn")
            else [mbit | 127, len].pack("CQ>")
            end
    return head.b + payload unless masked

    mask = SecureRandom.random_bytes(4)
    mb = mask.bytes
    head.b + mask + payload.bytes.each_with_index.map { |b, i| b ^ mb[i % 4] }.pack("C*")
  end

  private

  def read_http_head
    head = +""
    Timeout.timeout(5) { head << @sock.read(1) until head.end_with?("\r\n\r\n") }
    lines = head.split("\r\n")
    status = lines.shift
    headers = lines.each_with_object({}) { |l, h| k, v = l.split(":", 2); h[k.strip.downcase] = v.to_s.strip if v }
    [status, headers]
  end
end
