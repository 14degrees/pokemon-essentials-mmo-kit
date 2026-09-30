# frozen_string_literal: true

require "socket"
require "thread"
require "digest/sha1"
require "base64"

module PEMK
  # Single-threaded, non-blocking TCP reactor on stdlib IO.select — no async gem,
  # no nio4r. Owns the listen socket + every client socket, slices length-prefixed
  # frames into per-connection buffers, and drains a bounded per-connection
  # outbound buffer (backpressure: a slow client is dropped, never blocks the loop).
  #
  # Off-thread work (DB, bcrypt) runs on a worker pool; a worker hands a reply back
  # by calling #post(&block), which wakes the reactor through a self-pipe and runs
  # the block ON THE REACTOR THREAD — so all connection state and socket writes stay
  # single-threaded and lock-free.
  #
  # A second listener (ws_port, off unless set) speaks WebSocket (RFC 6455) for a
  # browser client: the same reactor, the same handlers, the same envelopes. One
  # binary (or text) message is one PEMK payload - the split envelope + body WITHOUT
  # the 4-byte length prefix, which the socket framing carries instead. Handshake,
  # masking, fragments, ping/pong and close are handled here, on stdlib alone; TLS
  # (wss://, which a browser on an https page requires) is a reverse proxy's job, as
  # for the TCP port.
  class Reactor
    OUTBUF_CAP = 4 << 20
    MAX_CONNS        = 2000   # far above the 500-CCU target; bounds fd/memory exhaustion
    IDLE_SWEEP_SEC   = 15.0   # how often the idle/pre-auth sweep runs
    PREAUTH_DEADLINE = 30.0   # seconds a socket may sit unauthenticated
    IDLE_TIMEOUT     = 300.0  # seconds an authed socket may go silent (client heartbeats ~0.5-30s)
    READ_CHUNK = 64 * 1024
    LEN_BYTES  = 4
    MAX_FRAME  = PEMK::Wire::MAX_MESSAGE_BYTES
    WS_GUID          = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    WS_HANDSHAKE_MAX = 8 * 1024   # an HTTP upgrade request larger than this is not one
    WS_OP_CONT, WS_OP_TEXT, WS_OP_BINARY, WS_OP_CLOSE, WS_OP_PING, WS_OP_PONG = 0x0, 0x1, 0x2, 0x8, 0x9, 0xA

    class Conn
      attr_reader :io, :addr, :transport
      attr_accessor :inbuf, :outbuf, :closing, :data, :ws_open, :ws_fragments

      def initialize(io, addr, transport: :tcp)
        @io        = io
        @addr      = addr
        @transport = transport   # :tcp (length-prefixed frames) | :ws (WebSocket messages)
        @inbuf     = +"".b
        @outbuf    = +"".b
        @closing   = false
        @data      = {}
        @ws_open   = false       # :ws only - the upgrade handshake is done
        @ws_fragments = nil      # :ws only - a fragmented message being assembled
      end

      def ws?
        @transport == :ws
      end

      def want_write?
        !@outbuf.empty?
      end
    end

    attr_reader :port, :ws_port

    def initialize(host:, port:, on_frame:, on_close: nil, on_tick: nil, logger: nil, ws_port: nil)
      @host     = host
      @port     = port
      @ws_port  = ws_port   # nil = no WebSocket listener
      @on_frame = on_frame
      @on_close = on_close
      @on_tick  = on_tick   # reactor-thread hook fired each loop (~<=0.5s) — coarse periodic work
      @log      = logger || ->(_m) {}
      @conns    = {}
      @running  = false
      @posts    = Queue.new
      @wake_r, @wake_w = IO.pipe
    end

    def start
      @server  = TCPServer.new(@host, @port)
      @port    = @server.addr[1]
      if @ws_port
        @ws_server = TCPServer.new(@host, @ws_port)
        @ws_port   = @ws_server.addr[1]
      end
      @running = true
      @log.call("reactor: listening on #{@host}:#{@port}#{@ws_port ? " (websocket on #{@ws_port})" : ''}")
    end

    def stop
      @running = false
      wake!   # break the IO.select so the loop notices @running == false
    end

    def running?
      @running
    end

    def conn_count
      @conns.size
    end

    # Reactor-thread only: is this connection still registered (not closed)?
    def alive?(conn)
      !conn.nil? && @conns.key?(conn.io)
    end

    def run
      start unless @server
      run_loop
    end

    def run_loop
      while @running
        begin
          tick
        rescue StandardError => e
          @log.call("reactor: tick error #{e.class}: #{e.message}")
        end
      end
    ensure
      shutdown
    end

    def tick(timeout = 0.5)
      reads  = [@server, @wake_r, *@conns.keys]
      reads << @ws_server if @ws_server
      writes = @conns.values.select(&:want_write?).map(&:io)
      readable, writable, = IO.select(reads, (writes.empty? ? nil : writes), nil, timeout)
      readable&.each do |io|
        if    io.equal?(@server)    then accept_conns(@server, :tcp)
        elsif io.equal?(@ws_server) then accept_conns(@ws_server, :ws)
        elsif io.equal?(@wake_r)    then drain_wake
        else  read_conn(@conns[io])
        end
      end
      writable&.each { |io| write_conn(@conns[io]) }
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if now - (@last_idle_sweep || 0.0) >= IDLE_SWEEP_SEC
        @last_idle_sweep = now
        sweep_idle(now)
      end
      @on_tick&.call   # reactor-thread; keep it O(1)/coarse (it runs up to ~2x/s)
    end

    # Thread-safe: schedule a block to run on the reactor thread and wake it.
    def post(&block)
      @posts << block
      wake!
    end

    # Reactor-thread only. Queue a frame to a live connection, try to flush now.
    def send_frame(conn, frame)
      return if conn.nil? || conn.closing || !@conns.key?(conn.io)

      if conn.ws?
        return unless conn.ws_open   # nothing is sent before the upgrade completes

        # The socket framing carries the length: a message is the payload alone.
        conn.outbuf << ws_frame(WS_OP_BINARY, frame.byteslice(LEN_BYTES, frame.bytesize - LEN_BYTES) || "".b)
      else
        conn.outbuf << frame
      end
      if conn.outbuf.bytesize > OUTBUF_CAP
        @log.call("reactor: outbuf overflow #{conn.addr} -> drop")
        close_conn(conn)
      else
        write_conn(conn)
      end
    end

    # Reactor-thread only. Close +conn+ as soon as what is queued for it is written.
    def finish(conn)
      return if conn.nil? || !@conns.key?(conn.io)

      conn.closing = true
      conn.outbuf.empty? ? close_conn(conn) : write_conn(conn)
    end

    def shutdown
      (@server.close rescue nil) if @server
      (@ws_server.close rescue nil) if @ws_server
      @conns.values.each { |c| close_conn(c) }
      @conns.clear
      (@wake_r.close rescue nil)
      (@wake_w.close rescue nil)
    end

    private

    def wake!
      # 1-byte pipe writes are atomic (PIPE_BUF), so no lock is needed — and this
      # MUST stay lock-free because it runs from the SIGTERM/SIGINT trap, where
      # Mutex#synchronize raises ThreadError. write_nonblock never blocks the trap.
      @wake_w.write_nonblock("x", exception: false)
    rescue IOError, SystemCallError
      nil
    end

    def drain_wake
      loop do
        d = @wake_r.read_nonblock(4096, exception: false)
        break if d == :wait_readable || d.nil?
      end
      loop do
        block = (@posts.pop(true) rescue nil)
        break unless block

        block.call
      end
    end

    def accept_conns(server, transport)
      loop do
        io = server.accept_nonblock(exception: false)
        break if io == :wait_readable || io.nil?

        addr = (io.peeraddr[3] rescue "?")
        # Hard ceiling: without it, an attacker opens sockets until the process runs
        # out of file descriptors or memory, and every accepted socket costs buffers
        # before it ever authenticates (audit). Well above the 500-CCU target.
        if @conns.size >= MAX_CONNS
          @log.call("reactor: connection cap #{MAX_CONNS} reached -> refusing #{addr}")
          (io.close rescue nil)
          next
        end
        conn = Conn.new(io, addr, transport: transport)
        conn.data[:opened_at] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @conns[io] = conn
        @log.call("reactor: + #{addr}#{transport == :ws ? ' ws' : ''} (#{@conns.size})")
      end
    end

    # Close sockets that connected but never authenticated (slowloris / scanner), and
    # authenticated ones that have gone silent far past any client heartbeat. Runs on
    # the reactor thread from the existing tick — O(conns), no DB.
    def sweep_idle(now)
      @conns.values.each do |conn|
        # A socket marked closing with nothing left to write closed only on its next
        # read or write: a silent one (a replaced session) stayed open for good.
        if conn.closing
          close_conn(conn) if conn.outbuf.empty?
          next
        end

        opened = conn.data[:opened_at] || now
        if conn.data[:account_id].nil?
          conn.closing = true if (now - opened) > PREAUTH_DEADLINE
        elsif (now - (conn.data[:last_seen] || opened)) > IDLE_TIMEOUT
          conn.closing = true
        end
        close_conn(conn) if conn.closing && conn.outbuf.empty?
      end
    end

    def read_conn(conn)
      return unless conn

      eof = false
      loop do
        data = conn.io.read_nonblock(READ_CHUNK, exception: false)
        if data.nil?          # EOF — but frames may still sit in inbuf
          eof = true
          break
        end
        break if data == :wait_readable

        conn.inbuf << data
        return close_conn(conn) if conn.inbuf.bytesize > MAX_FRAME + LEN_BYTES + 16
      end
      # Process buffered frames BEFORE honoring the EOF: a client that writes its
      # last frames and immediately closes (the graceful-quit flush) must not have
      # them silently discarded — that read+close race dropped real data.
      conn.ws? ? ws_process(conn) : slice_frames(conn)
      close_conn(conn) if eof && @conns.key?(conn.io)   # slice may have closed it already
    rescue IOError, SystemCallError
      close_conn(conn)
    end

    def slice_frames(conn)
      buf = conn.inbuf
      loop do
        break if buf.bytesize < LEN_BYTES

        len = buf.byteslice(0, LEN_BYTES).unpack1("N")
        return close_conn(conn) if len > MAX_FRAME

        total = LEN_BYTES + len
        break if buf.bytesize < total

        payload = buf.byteslice(LEN_BYTES, len)
        conn.inbuf = buf = (buf.byteslice(total, buf.bytesize - total) || +"".b)
        @on_frame.call(conn, payload)
        if conn.closing
          close_conn(conn) if conn.outbuf.empty?   # else write_conn closes after flush
          return
        end
      end
    end

    # --- WebSocket (RFC 6455), server side --------------------------------------

    def ws_process(conn)
      unless conn.ws_open
        return unless ws_handshake(conn)
      end
      ws_slice_messages(conn)
    end

    # The HTTP upgrade. -> true once the connection is open (the reply is queued);
    # false while the request is incomplete or after a refusal closed the socket.
    def ws_handshake(conn)
      buf = conn.inbuf
      head_end = buf.index("\r\n\r\n")
      if head_end.nil?
        return false if buf.bytesize <= WS_HANDSHAKE_MAX

        @log.call("reactor: ws #{conn.addr} handshake too large -> drop")
        close_conn(conn)
        return false
      end

      head = buf.byteslice(0, head_end)
      conn.inbuf = buf.byteslice(head_end + 4, buf.bytesize - head_end - 4) || +"".b
      lines = head.split("\r\n")
      request = lines.shift.to_s
      headers = {}
      lines.each do |l|
        k, v = l.split(":", 2)
        headers[k.to_s.strip.downcase] = v.to_s.strip if v
      end
      key = headers["sec-websocket-key"]
      key_ok = begin
        key && Base64.strict_decode64(key).bytesize == 16
      rescue ArgumentError
        false
      end
      unless request.start_with?("GET ") && headers["upgrade"].to_s.downcase == "websocket" &&
             headers["connection"].to_s.downcase.split(",").map(&:strip).include?("upgrade") && key_ok
        @log.call("reactor: ws #{conn.addr} bad upgrade request -> refuse")
        conn.outbuf << "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
        conn.closing = true
        write_conn(conn)
        return false
      end

      accept = Base64.strict_encode64(Digest::SHA1.digest(key + WS_GUID))
      conn.outbuf << "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                     "Sec-WebSocket-Accept: #{accept}\r\n\r\n"
      conn.ws_open = true
      write_conn(conn)
      @conns.key?(conn.io)
    end

    # Frames -> messages -> on_frame. A client frame must be masked; the whole
    # message is capped like a TCP frame; control frames are answered here.
    def ws_slice_messages(conn)
      loop do
        buf = conn.inbuf
        break if buf.bytesize < 2

        b0, b1 = buf.getbyte(0), buf.getbyte(1)
        fin    = (b0 & 0x80) != 0
        opcode = b0 & 0x0F
        masked = (b1 & 0x80) != 0
        len    = b1 & 0x7F
        pos    = 2
        if len == 126
          break if buf.bytesize < 4

          len = buf.byteslice(2, 2).unpack1("n")
          pos = 4
        elsif len == 127
          break if buf.bytesize < 10

          len = buf.byteslice(2, 8).unpack1("Q>")
          pos = 10
        end
        return close_conn(conn) if len > MAX_FRAME || (b0 & 0x70) != 0   # oversized, or RSV bits set
        return close_conn(conn) unless masked                             # a client MUST mask (5.1)

        total = pos + 4 + len
        break if buf.bytesize < total

        mask    = buf.byteslice(pos, 4)
        payload = ws_unmask(buf.byteslice(pos + 4, len), mask)
        conn.inbuf = (buf.byteslice(total, buf.bytesize - total) || +"".b)

        case opcode
        when WS_OP_BINARY, WS_OP_TEXT, WS_OP_CONT
          if opcode == WS_OP_CONT
            return close_conn(conn) unless conn.ws_fragments   # a continuation of nothing

            conn.ws_fragments << payload
          else
            return close_conn(conn) if conn.ws_fragments        # a new message inside a fragmented one

            conn.ws_fragments = payload
          end
          return close_conn(conn) if conn.ws_fragments.bytesize > MAX_FRAME

          next unless fin

          message = conn.ws_fragments
          conn.ws_fragments = nil
          @on_frame.call(conn, message)
          if conn.closing
            close_conn(conn) if conn.outbuf.empty?
            return
          end
        when WS_OP_PING
          conn.outbuf << ws_frame(WS_OP_PONG, payload)
          write_conn(conn)
        when WS_OP_PONG
          nil
        when WS_OP_CLOSE
          conn.outbuf << ws_frame(WS_OP_CLOSE, payload.byteslice(0, 2) || "".b)
          conn.closing = true
          write_conn(conn)
          return
        else
          return close_conn(conn)
        end
      end
    end

    # XOR by 32-bit words (a save blob is hundreds of KB; byte by byte is too slow).
    def ws_unmask(data, mask)
      return data if data.empty?

      key   = mask.unpack1("N")
      words = data.bytesize / 4
      out   = data.byteslice(0, words * 4).unpack("N*").map! { |w| w ^ key }.pack("N*")
      tail  = data.bytesize - words * 4
      if tail.positive?
        mb = mask.bytes
        out << (data.byteslice(words * 4, tail).bytes.each_with_index.map { |b, i| b ^ mb[i] }.pack("C*"))
      end
      out.force_encoding(Encoding::BINARY)
    end

    # A server frame: never masked (5.1).
    def ws_frame(opcode, payload)
      len = payload.bytesize
      head = [0x80 | opcode].pack("C")
      head << if len < 126 then [len].pack("C")
              elsif len < 65_536 then [126, len].pack("Cn")
              else [127, len].pack("CQ>")
              end
      head.force_encoding(Encoding::BINARY) << payload
    end

    def write_conn(conn)
      return unless conn && !conn.outbuf.empty?

      loop do
        n = conn.io.write_nonblock(conn.outbuf, exception: false)
        break if n == :wait_writable

        conn.outbuf = (conn.outbuf.byteslice(n, conn.outbuf.bytesize - n) || +"".b)
        break if conn.outbuf.empty?
      end
      close_conn(conn) if conn.closing && conn.outbuf.empty?
    rescue IOError, SystemCallError
      close_conn(conn)
    end

    def close_conn(conn)
      return unless conn && @conns.key?(conn.io)

      @conns.delete(conn.io)
      (conn.io.close rescue nil)
      @on_close&.call(conn)
      @log.call("reactor: - #{conn.addr} (#{@conns.size})")
    end
  end
end
