# frozen_string_literal: true

module Autotest
  # A PEMK server in this process, on the test port and the pemk_autotest database,
  # booted with one scenario's flags. Bound to 0.0.0.0 so the Windows game reaches
  # it through WSL's localhost forwarding, like the dev server.
  class TestServer
    attr_reader :port, :lines

    def initialize(port:, flags:, log_path:)
      @port     = port
      @flags    = flags
      @log_path = log_path
      @lines    = []
      @mutex    = Mutex.new
    end

    def start
      @file = File.open(@log_path, "a")
      boot
      self
    end

    def stop
      @server&.stop
      @file&.close
    end

    # A deploy, as the connected windows see it: the server stops, and a new one
    # comes up on the same port, database and flags.
    def restart
      @server&.stop
      log("autotest: the server restarts")
      boot
      self
    end

    def grep(pattern)
      @mutex.synchronize { @lines.grep(pattern) }
    end

    private

    def boot
      env = ENV.to_h.merge("PEMK_BIND" => "0.0.0.0", "PEMK_PORT" => @port.to_s)
      @flags.each { |k, v| env[k.to_s] = v.to_s }
      @server = PEMK::Server.new(config: PEMK::Config.new(env: env), logger: method(:log))
      @server.start
    end

    def log(message)
      line = "#{Time.now.strftime('%H:%M:%S.%L')} #{message}"
      @mutex.synchronize do
        @lines << line
        @file.puts(line)
        @file.flush
      end
    end
  end
end
