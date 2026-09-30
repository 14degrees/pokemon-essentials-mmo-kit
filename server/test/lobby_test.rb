require "minitest/autorun"
require "net/http"
require "uri"
require "json"
require "sequel"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk"
require File.expand_path("../../stream/lobby/lobby.rb", __dir__)

# The one website: sign in with a game account (or make one), get a seat started with
# that login, be sent into it once it answers, lose the seat when idle. The containers
# and their neko are a fake here; the lobby's own logic is real, over real HTTP.
class LobbyTest < Minitest::Test
  class FakeDriver
    attr_reader :started, :stopped, :ready, :connected
    def initialize
      @started = []
      @stopped = []
      @ready = {}       # slot name => bool
      @connected = {}   # slot name => bool
      @fail_start = false
    end
    def fail_start!    = @fail_start = true
    def start(slot)
      raise "docker is down" if @fail_start
      @started << [slot.name, slot.email, slot.password, slot.api_token]
    end
    def stop(slot)     = @stopped << slot.name
    def ready?(slot)   = @ready[slot.name] == true
    def connected?(slot) = @connected[slot.name] == true
  end

  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    %i[account_bans asset_events asset_tokens monster_transfers monsters enforcement_events accounts].each { |t| @db[t].delete rescue nil }
    @accounts = PEMK::Accounts.new(@db)
    @red = @accounts.create(email: "red@t.co", password: "charizard1")
    @driver = FakeDriver.new
    @now = Time.now
    @slots = PEMK::Lobby::Slots.new([PEMK::Lobby::Slot.new(name: "slot1", web_port: 8081),
                                     PEMK::Lobby::Slot.new(name: "slot2", web_port: 8082)],
                                    driver: @driver, logger: ->(_m) {}, idle_sec: 600, clock: -> { @now })
    @app = PEMK::Lobby::App.new(db: @db, slots: @slots, secret: "s3cret", port: 0, logger: ->(_m) {})
    @app.start
    @base = URI("http://127.0.0.1:#{@app.port}")
  end

  def teardown
    @app&.stop
    @db&.disconnect
  end

  # --- HTTP helpers (no redirects followed; cookies carried by hand) ---

  def get(path, cookie: nil)
    req = Net::HTTP::Get.new(path)
    req["Cookie"] = cookie if cookie
    Net::HTTP.start(@base.host, @base.port) { |h| h.request(req) }
  end

  def post(path, form, cookie: nil)
    req = Net::HTTP::Post.new(path)
    req.set_form_data(form)
    req["Cookie"] = cookie if cookie
    Net::HTTP.start(@base.host, @base.port) { |h| h.request(req) }
  end

  def login(email, password, create: false)
    form = { "email" => email, "password" => password }
    form["create"] = "1" if create
    res = post("/login", form)
    [res, res["Set-Cookie"].to_s[/lobby=[^;]*/]]
  end

  # --- signing in ---

  def test_the_front_page_shows_the_seats
    res = get("/")
    assert_equal "200", res.code
    assert_includes res.body, "2 of 2 seats free"
  end

  def test_a_wrong_password_stays_on_the_page_and_starts_nothing
    res, cookie = login("red@t.co", "wrong-wrong")
    assert_equal "200", res.code
    assert_includes res.body, "Wrong password"
    assert_nil cookie
    assert_empty @driver.started
  end

  def test_a_good_login_takes_a_seat_started_with_that_login_and_goes_to_wait
    res, cookie = login("red@t.co", "charizard1")
    assert_equal "200", res.code
    assert_includes res.body, "Starting your game"
    assert_match(/\Alobby=#{@red}\.[0-9a-f]{64}\z/, cookie)
    assert_includes res["Set-Cookie"], "HttpOnly"
    assert_equal 1, @driver.started.size
    name, email, password, token = @driver.started[0]
    assert_equal ["slot1", "red@t.co", "charizard1"], [name, email, password]
    assert_equal 32, token.length
    assert_equal({ total: 2, free: 1 }, @slots.counts)
  end

  def test_creating_an_account_signs_it_in
    res, cookie = login("blue@t.co", "blastoise1", create: true)
    assert_includes res.body, "Starting your game"
    refute_nil cookie
    acct = @db[:accounts][email: "blue@t.co"]
    refute_nil acct
    assert PEMK::Password.verify("blastoise1", acct[:password_hash])
    assert_equal "blue@t.co", @driver.started[0][1]
  end

  def test_creating_over_an_existing_email_or_a_weak_password_is_refused
    res, = login("red@t.co", "charizard1", create: true)
    assert_includes res.body, "already has an account"
    res, = login("green@t.co", "short", create: true)
    assert_includes res.body, "at least 8 characters"
    assert_empty @driver.started
  end

  def test_a_banned_account_is_refused
    PEMK::Bans.new(@db).ban(@red, reason: "griefing", by: "sam")
    res, cookie = login("red@t.co", "charizard1")
    assert_includes res.body, "banned: griefing"
    assert_nil cookie
    assert_empty @driver.started
  end

  def test_a_failed_container_start_frees_the_seat_and_says_so
    @driver.fail_start!
    res, = login("red@t.co", "charizard1")
    assert_includes res.body, "could not be started"
    assert_equal({ total: 2, free: 2 }, @slots.counts)
    assert_equal ["slot1"], @driver.stopped   # released after the failed start
  end

  # --- seats ---

  def test_signing_in_twice_keeps_the_same_seat
    _, cookie = login("red@t.co", "charizard1")
    _, cookie2 = login("red@t.co", "charizard1")
    assert_equal cookie, cookie2
    assert_equal 1, @driver.started.size
    assert_equal({ total: 2, free: 1 }, @slots.counts)
  end

  def test_when_every_seat_is_taken_the_next_player_waits
    login("red@t.co", "charizard1")
    login("blue@t.co", "blastoise1", create: true)
    res, cookie = login("green@t.co", "venusaur1", create: true)
    assert_includes res.body, "Every seat is taken"
    assert_nil cookie
    assert_equal 2, @driver.started.size
  end

  # --- the wait page and the join ---

  def test_status_says_starting_then_ready_with_the_seat_s_login
    _, cookie = login("red@t.co", "charizard1")
    res = get("/wait", cookie: cookie)
    assert_equal "200", res.code
    assert_includes res.body, "Your seat is slot1"
    assert_includes res.body, "api/login"          # the page joins the stream itself
    st = JSON.parse(get("/status", cookie: cookie).body)
    assert_equal({ "state" => "starting" }, st)
    @driver.ready["slot1"] = true
    st = JSON.parse(get("/status", cookie: cookie).body)
    assert_equal "ready", st["state"]
    assert_equal "/slot1/", st["path"]
    assert_equal "neko", st["user"]
    assert_equal @driver.started[0][3], st["password"]   # the seat's own session password
  end

  def test_without_a_cookie_or_a_seat_the_wait_page_is_the_front_page
    assert_includes get("/wait").body, "Sign in with your game account"
    assert_includes get("/wait", cookie: "lobby=#{@red}.deadbeef").body, "Sign in"   # a forged cookie
    assert_equal({ "state" => "none" }, JSON.parse(get("/status").body))
    assert_equal({ "state" => "none" }, JSON.parse(get("/status", cookie: "lobby=#{@red}.deadbeef").body))
  end

  def test_logout_frees_the_seat_and_stops_the_container
    _, cookie = login("red@t.co", "charizard1")
    res = post("/logout", {}, cookie: cookie)
    assert_includes res.body, "Sign in"
    assert_includes res["Set-Cookie"], "Max-Age=0"
    assert_equal ["slot1"], @driver.stopped
    assert_equal({ total: 2, free: 2 }, @slots.counts)
  end

  # --- reaping ---

  def test_a_seat_nobody_watches_is_freed_after_the_grace_and_the_idle_time
    login("red@t.co", "charizard1")
    assert_empty @slots.reap                          # just started: grace
    @now += 200
    assert_empty @slots.reap                          # first sighting of nobody: the idle clock starts
    @now += 599
    assert_empty @slots.reap
    @now += 2
    assert_equal ["slot1"], @slots.reap.map(&:name)   # idle_sec without a viewer
    assert_equal ["slot1"], @driver.stopped
    assert_equal({ total: 2, free: 2 }, @slots.counts)
  end

  def test_a_watched_seat_is_kept_and_its_idle_clock_resets
    login("red@t.co", "charizard1")
    @now += 200
    @slots.reap                                       # nobody yet
    @now += 300
    @driver.connected["slot1"] = true
    @slots.reap                                       # they came back
    @driver.connected["slot1"] = false
    @now += 500
    assert_empty @slots.reap                          # first sighting of nobody since: the clock restarts here
    @now += 599
    assert_empty @slots.reap
    @now += 2
    assert_equal ["slot1"], @slots.reap.map(&:name)
  end
end
