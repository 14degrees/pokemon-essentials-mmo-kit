# frozen_string_literal: true

# The lobby: the one website. A friend opens it, signs in (or creates an account - the
# game's own accounts, the same table the server authenticates against), and the lobby
# gives them a game: it takes a free SLOT (a streaming container, stream/README.md),
# starts it with their login pre-filled so the game signs in by itself, waits until it
# answers, logs the browser into the slot's stream, and sends it there. When they
# leave, the slot is stopped and goes back to the pool. Nobody is handed a URL or a
# password; the only address is this one.
#
#   cd server && DATABASE_URL=... bundle exec ruby ../stream/lobby/lobby.rb
#
# Env: LOBBY_BIND (127.0.0.1:8090), LOBBY_SECRET (cookie signing; random per boot if
# unset, so a restart signs everyone out), LOBBY_SECURE (1 = https cookies; set when
# behind the Caddyfile's domain), STREAM_DIR (the stream/ folder with slots.json and
# docker-compose.yml), LOBBY_IDLE_MIN (minutes a game may sit with nobody watching
# before its slot is freed; 10).
#
# Slots come from stream/slots.json (gen.sh): name, web port. Each slot's neko is
# reached on 127.0.0.1:<web port>/<slot>/ (the same path Caddy routes), so the lobby
# and the games share one origin and one cookie jar.

require "webrick"
require "json"
require "openssl"
require "securerandom"
require "net/http"
require "uri"
require "erb"
require "fileutils"

server_root = ENV["PEMK_SERVER_ROOT"] || File.expand_path("../../server", __dir__)
$LOAD_PATH.unshift File.join(server_root, "lib") unless $LOAD_PATH.include?(File.join(server_root, "lib"))
require "pemk/db"
require "pemk/password"
require "pemk/accounts"
require "pemk/bans"

module PEMK
  module Lobby
    # One streaming container and who has it.
    Slot = Struct.new(:name, :web_port, :account_id, :email, :password, :api_token,
                      :assigned_at, :ready_at, :connected_at, :disconnected_since, keyword_init: true) do
      def free? = account_id.nil?
      def path  = "/#{name}/"
    end

    # Talks to Docker Compose and to a slot's neko. Everything the tests fake.
    class ComposeDriver
      def initialize(stream_dir:, logger:)
        @dir = stream_dir
        @log = logger
      end

      # Start (or restart) the slot's container with this session's env.
      def start(slot)
        env = File.join(@dir, "slots", "#{slot.name}.env")
        FileUtils.mkdir_p(File.dirname(env))
        File.open(env, "w", 0o600) do |f|
          f.puts "PEMK_EMAIL=#{slot.email}"
          f.puts "PEMK_PASSWORD=#{slot.password}"
          f.puts "NEKO_MEMBER_MULTIUSER_USER_PASSWORD=#{slot.api_token}"
          f.puts "NEKO_SESSION_API_TOKEN=#{slot.api_token}"
        end
        compose("up", "-d", "--force-recreate", "--no-deps", slot.name)
      end

      # Stop it and forget the session's env (the next start writes a new one).
      def stop(slot)
        compose("stop", slot.name)
        env = File.join(@dir, "slots", "#{slot.name}.env")
        File.write(env, "") if File.exist?(env)
      end

      # neko answers its API with the session's token: the stream is up.
      def ready?(slot)
        sessions(slot).is_a?(Array)
      end

      # Is anyone connected to the stream right now?
      def connected?(slot)
        list = sessions(slot)
        list.is_a?(Array) && list.any? { |s| s.dig("state", "is_connected") == true }
      end

      private

      def sessions(slot)
        uri = URI("http://127.0.0.1:#{slot.web_port}#{slot.path}api/sessions")
        req = Net::HTTP::Get.new(uri)
        req["Authorization"] = "Bearer #{slot.api_token}"
        res = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 3) { |h| h.request(req) }
        res.code == "200" ? JSON.parse(res.body) : nil
      rescue StandardError
        nil
      end

      def compose(*args)
        out = IO.popen(["docker", "compose", *args], chdir: @dir, err: [:child, :out], &:read)
        raise "docker compose #{args.join(' ')} failed: #{out.to_s[-400..] || out}" unless $?.success?

        out
      end
    end

    # The pool. One thread-safe object: assign, release, poll readiness, reap the idle.
    class Slots
      GRACE_SEC = 180   # a freshly started game gets this long before "nobody watching" counts

      attr_reader :slots

      def initialize(slots, driver:, logger:, idle_sec: 600, clock: -> { Time.now })
        @slots  = slots
        @driver = driver
        @log    = logger
        @idle   = idle_sec
        @clock  = clock
        @lock   = Mutex.new
      end

      def for_account(account_id)
        @lock.synchronize { @slots.find { |s| s.account_id == account_id } }
      end

      # -> the account's slot (its own if it has one, else a free one started for it),
      # or nil when every slot is taken.
      def assign(account_id:, email:, password:)
        slot = nil
        @lock.synchronize do
          slot = @slots.find { |s| s.account_id == account_id }
          return slot if slot

          slot = @slots.find(&:free?)
          return nil unless slot

          slot.account_id = account_id
          slot.email      = email
          slot.password   = password
          slot.api_token  = SecureRandom.hex(16)
          slot.assigned_at = @clock.call
          slot.ready_at = slot.connected_at = slot.disconnected_since = nil
        end
        begin
          @driver.start(slot)
          @log.call("lobby: #{slot.name} -> account #{account_id} (#{email})")
        rescue StandardError => e
          @log.call("lobby: #{slot.name} failed to start: #{e.message}")
          release(slot)
          raise
        end
        slot
      end

      def release(slot)
        @lock.synchronize do
          return if slot.free?

          @log.call("lobby: #{slot.name} released from account #{slot.account_id}")
          slot.account_id = slot.email = slot.password = slot.api_token = nil
          slot.assigned_at = slot.ready_at = slot.connected_at = slot.disconnected_since = nil
        end
        begin
          @driver.stop(slot)
        rescue StandardError => e
          @log.call("lobby: #{slot.name} failed to stop: #{e.message}")
        end
      end

      # -> :none | :starting | :ready. Remembers the first ready sight.
      def state(slot)
        return :none if slot.nil? || slot.free?
        return :ready if slot.ready_at

        if @driver.ready?(slot)
          slot.ready_at = @clock.call
          :ready
        else
          :starting
        end
      end

      # Free the slots nobody is watching: after the grace since the start, a stream
      # with no connected session for idle_sec goes back to the pool (the game's own
      # save is on the server; nothing is lost). -> released slots
      def reap
        now = @clock.call
        gone = []
        @slots.each do |slot|
          next if slot.free? || slot.assigned_at.nil? || (now - slot.assigned_at) < GRACE_SEC

          if @driver.connected?(slot)
            slot.connected_at = now
            slot.disconnected_since = nil
          else
            slot.disconnected_since ||= now
            gone << slot if (now - slot.disconnected_since) >= @idle
          end
        end
        gone.each { |s| release(s) }
        gone
      end

      def counts
        @lock.synchronize { { total: @slots.size, free: @slots.count(&:free?) } }
      end
    end

    # The HTTP side. Cookie `lobby` = "<account id>.<hmac>", HttpOnly, SameSite=Lax.
    class App
      COOKIE = "lobby"

      attr_reader :port

      def initialize(db:, slots:, secret: SecureRandom.hex(32), secure: false, bind: "127.0.0.1", port: 8090, logger: ->(_m) {})
        @db       = db
        @accounts = PEMK::Accounts.new(db)
        @bans     = PEMK::Bans.new(db)
        @slots    = slots
        @secret   = secret
        @secure   = secure
        @log      = logger
        @server   = WEBrick::HTTPServer.new(BindAddress: bind, Port: port, Logger: WEBrick::Log.new(File::NULL),
                                            AccessLog: [])
        @port     = @server.config[:Port]
        route
      end

      def start
        @thread = Thread.new { @server.start }
        @reaper = Thread.new do
          loop do
            sleep 30
            begin
              @slots.reap
            rescue StandardError => e
              @log.call("lobby: reap failed #{e.class}: #{e.message}")
            end
          end
        end
        self
      end

      def stop
        @reaper&.kill
        @server.shutdown
        @thread&.join(5)
      end

      def join = @thread&.join

      private

      def route
        @server.mount_proc("/")       { |req, res| req.request_method == "GET" && req.path == "/" ? page_login(req, res) : not_found(res) }
        @server.mount_proc("/login")  { |req, res| req.request_method == "POST" ? post_login(req, res) : not_found(res) }
        @server.mount_proc("/wait")   { |req, res| page_wait(req, res) }
        @server.mount_proc("/status") { |req, res| json_status(req, res) }
        @server.mount_proc("/logout") { |req, res| req.request_method == "POST" ? post_logout(req, res) : not_found(res) }
        @server.mount_proc("/healthz") { |_req, res| res.body = "ok"; res["Content-Type"] = "text/plain" }
      end

      # --- handlers ---

      def page_login(req, res, error: nil, email: "")
        html(res, LOGIN_HTML, { error: error, email: email, counts: @slots.counts })
      end

      def post_login(req, res)
        email    = req.query["email"].to_s.strip
        password = req.query["password"].to_s
        create   = req.query["create"].to_s == "1"
        acct, why = nil, nil
        if create
          begin
            id = @accounts.create(email: email, password: password)
            why = :taken unless id
            acct = @db[:accounts][id: id] if id
          rescue ArgumentError => e
            why = e.message.to_sym
          end
        else
          acct, why = @accounts.authenticate(email, password)
        end
        return page_login(req, res, error: ERRORS.fetch(why, "That did not work."), email: email) unless acct

        if (ban = @bans.active(acct[:id]))
          return page_login(req, res, error: "This account is banned#{ban[:reason].to_s.empty? ? '' : ": #{ban[:reason]}"}.", email: email)
        end

        slot = @slots.assign(account_id: acct[:id], email: acct[:email], password: password)
        unless slot
          c = @slots.counts
          return page_login(req, res, error: "Every seat is taken right now (#{c[:total]} seats). Try again in a few minutes.", email: email)
        end

        set_cookie(res, acct[:id])
        html(res, WAIT_HTML, { slot: slot.name })
      rescue StandardError => e
        @log.call("lobby: login failed #{e.class}: #{e.message}")
        page_login(req, res, error: "Your game could not be started. Try again.", email: email)
      end

      # Reloading the wait page: still theirs -> wait; no seat -> the front page.
      def page_wait(req, res)
        account_id = current_account(req)
        slot = account_id && @slots.for_account(account_id)
        slot ? html(res, WAIT_HTML, { slot: slot.name }) : page_login(req, res)
      end

      def json_status(req, res)
        account_id = current_account(req)
        slot = account_id && @slots.for_account(account_id)
        state = @slots.state(slot)
        out = { state: state.to_s }
        if slot && state == :ready
          out[:path] = slot.path
          out[:user] = "neko"
          out[:password] = slot.api_token
        end
        res["Content-Type"] = "application/json"
        res["Cache-Control"] = "no-store"
        res.body = JSON.generate(out)
      end

      def post_logout(req, res)
        account_id = current_account(req)
        slot = account_id && @slots.for_account(account_id)
        @slots.release(slot) if slot
        res["Set-Cookie"] = "#{COOKIE}=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"
        page_login(req, res)
      end

      # --- helpers ---

      ERRORS = {
        not_found: "No account with that email. Tick \"create my account\" to make one.",
        bad_password: "Wrong password.",
        locked: "Too many wrong passwords. Try again in a few minutes.",
        taken: "That email already has an account. Sign in instead.",
        invalid_email: "That is not an email address.",
        weak_password: "Passwords need at least 8 characters.",
        invalid_username: "That name is not allowed."
      }.freeze

      def sign(account_id)
        OpenSSL::HMAC.hexdigest("SHA256", @secret, account_id.to_s)
      end

      def set_cookie(res, account_id)
        c = WEBrick::Cookie.new(COOKIE, "#{account_id}.#{sign(account_id)}")
        c.path = "/"
        c.max_age = 12 * 3600
        c.secure = @secure
        # WEBrick's Cookie has no SameSite/HttpOnly fields: the header is written by hand.
        res["Set-Cookie"] = "#{c}; HttpOnly; SameSite=Lax"
      end

      def current_account(req)
        raw = req.cookies.find { |c| c.name == COOKIE }&.value.to_s
        id, sig = raw.split(".", 2)
        return nil unless id && sig && id.match?(/\A\d+\z/)
        return nil unless OpenSSL.fixed_length_secure_compare(sig, sign(id)) rescue false

        id.to_i
      end

      def html(res, template, vars)
        res["Content-Type"] = "text/html; charset=utf-8"
        res["Cache-Control"] = "no-store"
        res.body = ERB.new(template).result_with_hash(vars.merge(h: ->(s) { ERB::Util.html_escape(s.to_s) }))
      end

      def not_found(res)
        res.status = 404
        res["Content-Type"] = "text/plain"
        res.body = "not found"
      end

      STYLE = <<~CSS
        body{margin:0;min-height:100vh;display:grid;place-items:center;background:#0f1218;color:#e8e8ee;font:16px/1.4 system-ui,sans-serif}
        main{width:min(92vw,380px);background:#171b24;border:1px solid #2a3040;border-radius:12px;padding:28px}
        h1{margin:0 0 4px;font-size:22px} p{margin:8px 0;color:#aab} label{display:block;margin:14px 0 4px;font-size:14px;color:#aab}
        input[type=email],input[type=password]{width:100%;box-sizing:border-box;padding:10px;border-radius:8px;border:1px solid #2a3040;background:#0f1218;color:#fff;font-size:16px}
        button{margin-top:18px;width:100%;padding:12px;border:0;border-radius:8px;background:#e8433f;color:#fff;font-size:16px;font-weight:600;cursor:pointer}
        .err{background:#3a1d1d;border:1px solid #6b2b2b;color:#ffb3b3;padding:10px;border-radius:8px;margin-top:12px}
        .chk{display:flex;gap:8px;align-items:center;margin-top:14px;font-size:14px;color:#aab} .chk input{width:auto}
        .bar{height:6px;background:#2a3040;border-radius:3px;overflow:hidden;margin:18px 0} .bar i{display:block;height:100%;width:30%;background:#e8433f;animation:s 1.2s infinite linear} @keyframes s{from{transform:translateX(-100%)}to{transform:translateX(330%)}}
        small{color:#778}
      CSS

      LOGIN_HTML = <<~HTML
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Play</title><style>#{STYLE}</style></head>
        <body><main>
          <h1>Play</h1>
          <p>Sign in with your game account. <small><%= counts[:free] %> of <%= counts[:total] %> seats free.</small></p>
          <form method="post" action="/login">
            <label>Email</label><input type="email" name="email" required autocomplete="username" value="<%= h.(email) %>">
            <label>Password</label><input type="password" name="password" required minlength="8" autocomplete="current-password">
            <label class="chk"><input type="checkbox" name="create" value="1"> create my account</label>
            <% if error %><div class="err"><%= h.(error) %></div><% end %>
            <button type="submit">Play</button>
          </form>
        </main></body></html>
      HTML

      WAIT_HTML = <<~HTML
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Starting your game</title><style>#{STYLE}</style></head>
        <body><main>
          <h1>Starting your game</h1>
          <p id="msg">Your seat is <%= h.(slot) %>. The game is booting, this takes about half a minute.</p>
          <div class="bar"><i></i></div>
          <form method="post" action="/logout"><button type="submit" style="background:#2a3040">Cancel</button></form>
          <script>
            async function poll() {
              try {
                const r = await fetch('/status', {cache: 'no-store', credentials: 'same-origin'});
                const s = await r.json();
                if (s.state === 'none') { location.href = '/'; return; }
                if (s.state === 'ready') {
                  document.getElementById('msg').textContent = 'Ready. Joining...';
                  const login = await fetch(s.path + 'api/login', {method: 'POST', credentials: 'same-origin',
                    headers: {'Content-Type': 'application/json'}, body: JSON.stringify({username: s.user, password: s.password})});
                  if (login.ok || login.status === 422) { location.href = s.path; return; }
                  document.getElementById('msg').textContent = 'The stream refused the login (' + login.status + '). Retrying...';
                }
              } catch (e) {}
              setTimeout(poll, 2000);
            }
            poll();
          </script>
        </main></body></html>
      HTML
    end

    # -> the App, from the env and stream/slots.json. Nothing runs until #start.
    def self.build(env: ENV, logger: ->(m) { puts "#{Time.now.strftime('%H:%M:%S')} #{m}" })
      stream_dir = env["STREAM_DIR"] || File.expand_path("..", __dir__)
      slots_file = File.join(stream_dir, "slots.json")
      raise "no #{slots_file}: run stream/gen.sh first" unless File.exist?(slots_file)

      slots = JSON.parse(File.read(slots_file)).map { |s| Slot.new(name: s["name"], web_port: s["web_port"]) }
      bind, port = env.fetch("LOBBY_BIND", "127.0.0.1:8090").split(":", 2)
      db = PEMK::DB.connect(env.fetch("DATABASE_URL"), max_connections: 4)
      pool = Slots.new(slots, driver: ComposeDriver.new(stream_dir: stream_dir, logger: logger), logger: logger,
                       idle_sec: (env["LOBBY_IDLE_MIN"] || "10").to_i * 60)
      App.new(db: db, slots: pool, secret: env["LOBBY_SECRET"] || SecureRandom.hex(32),
              secure: env["LOBBY_SECURE"].to_s == "1", bind: bind, port: port.to_i, logger: logger)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  app = PEMK::Lobby.build
  puts "lobby: #{app.port} - #{app.instance_variable_get(:@slots).counts[:total]} seats (Ctrl-C to stop)"
  trap("INT")  { app.stop; exit 0 }
  trap("TERM") { app.stop; exit 0 }
  app.start.join
end
