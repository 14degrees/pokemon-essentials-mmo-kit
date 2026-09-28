require "minitest/autorun"
require "socket"
require "timeout"
require "sequel"
require "json"
require "tempfile"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)

ENV["PEMK_BIND"] = "127.0.0.1"
ENV["PEMK_PORT"] = "0"
require "pemk"

# The flags channel over the wire: a :flags snapshot grants progression facts, a
# :save promotes the ones its watermark covers, and a login in `on` mode hands back
# only the durable ones. FlagState is unit-tested on its own; this pins the wiring
# between it, the save handler and the login payload.
class ServerFlagsTest < Minitest::Test
  W = PEMK::Wire

  WORLD = Tempfile.new(["pemk_world", ".json"])
  WORLD.write(JSON.generate(
    "schema_version" => 3,
    "maps" => {},
    "flags" => {
      "manifest_version" => 1,
      "switches" => { "4" => { "writes" => 1, "reads" => 1, "key" => "sw:defeated_gym_1", "tier" => "fact" } },
      "variables" => {},
      "self_switches" => { "policy" => "fact", "repeatable" => ["13:17"], "latched" => ["11:2:A"] },
      "unjudgeable" => []
    }
  ))
  WORLD.flush

  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete rescue nil   # no cascade from accounts (deliberate)
    @db[:enforcement_events].delete rescue nil
    @db[:accounts].delete
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  def start_server(mode = "on", enforce: "off")
    env = ENV.to_h.merge("PEMK_WORLD" => WORLD.path, "PEMK_FLAG_STATE" => mode, "PEMK_FLAG_ENFORCE" => enforce)
    @server = PEMK::Server.new(config: PEMK::Config.new(env: env), logger: ->(_m) {})
    @server.start
    @port = @server.port
  end

  def open_conn; TCPSocket.new("127.0.0.1", @port); end
  def send_env(sock, env, body = nil); sock.write(W.encode_split(env, body)); end

  def recv(sock, timeout = 5)
    Timeout.timeout(timeout) do
      hdr = sock.read(4)
      return nil if hdr.nil?

      W.decode_envelope(sock.read(hdr.unpack1("N")), false)[:env]
    end
  end

  def register(email)
    c = open_conn
    send_env(c, { type: :register, email: email, password: "password1" })
    recv(c)
    c.close
  end

  # A fresh session: a login on a new socket retires the previous one, as a relaunch
  # of the game does.
  def session(email)
    c = open_conn
    send_env(c, { type: :login, email: email, password: "password1" })
    lo = recv(c)
    assert_equal :login_ok, lo[:type]
    [c, lo]
  end

  def snapshot(c, seq, switches: [], self_switches: [], event_times: {})
    send_env(c, { type: :flags, seq: seq, switches: switches, variables: {},
                  self_switches: self_switches, event_times: event_times })
    ack = recv(c)
    assert_equal :flags_ack, ack[:type]
    assert_equal seq, ack[:seq]
  end

  # :save has no reply. A ping answered after it proves the save reached the account
  # mailbox, and the next login's state read queues behind it there.
  def save(c, flags_seq)
    env = { type: :save, trainer_id: 1 }
    env[:flags_seq] = flags_seq unless flags_seq.nil?
    send_env(c, env, Marshal.dump({ blob: flags_seq }))
    send_env(c, { type: :ping, t: 1 })
    assert_equal :pong, recv(c)[:type]
  end

  # A client that says it can apply a repair (step 5).
  def repairing_session(email)
    c = open_conn
    send_env(c, { type: :login, email: email, password: "password1", caps: ["flag_repair"] })
    lo = recv(c)
    assert_equal :login_ok, lo[:type]
    [c, lo]
  end

  # Step 5: a self-switch cleared some other way than the game's own writes (no delta
  # said so) comes back through a :flag_repair, to a client that can apply one.
  def test_an_edit_the_game_did_not_make_is_repaired
    start_server("on", enforce: "on")
    register("fl9@t.co")
    c, lo = repairing_session("fl9@t.co")
    assert_equal "on", lo[:flag_enforce]
    snapshot(c, 1, self_switches: ["5:3:A"])
    send_env(c, { type: :flags, seq: 2, switches: [], variables: {}, self_switches: [], event_times: {} })
    assert_equal :flags_ack, recv(c)[:type]
    rep = recv(c)
    assert_equal :flag_repair, rep[:type]
    assert_equal 2, rep[:seq]
    assert_equal({ "5:3:A" => true }, rep[:self_switches])
    c.close
  end

  # An older client cannot apply one: it is never sent a repair.
  def test_an_older_client_is_not_sent_a_repair
    start_server("on", enforce: "on")
    register("fl10@t.co")
    c, = session("fl10@t.co")
    snapshot(c, 1, self_switches: ["5:3:A"])
    snapshot(c, 2, self_switches: [])
    send_env(c, { type: :ping, t: 2 })
    assert_equal :pong, recv(c)[:type]   # nothing came between the ack and the pong
    c.close
  end

  def test_a_save_promotes_only_the_facts_its_watermark_covers
    start_server
    register("fl1@t.co")
    c, = session("fl1@t.co")
    snapshot(c, 1, switches: [4], event_times: { "13:17" => 1_000 })
    snapshot(c, 2, switches: [4], self_switches: ["5:2:A", "11:2:A"])
    save(c, 1)
    c.close

    c, lo = session("fl1@t.co")
    assert_equal 2, lo[:flags_seq], "the client resumes above the server's high-water"
    f = lo[:flag_facts]
    assert_equal [4], f[:switches]
    assert_empty f[:self_switches], "5:2:A arrived after the blob was serialized"
    assert_equal({ "13:17" => 1_000 }, f[:event_times])
    save(c, 2)
    c.close

    _, lo = session("fl1@t.co")
    assert_equal ["5:2:A"], lo[:flag_facts][:self_switches], "the latched 11:2:A is never banked"
  end

  # The case the watermark alone got wrong: the fact is granted, the game dies before
  # the next save, and the next session's blob never had it. Its first save must not
  # make the lost fact durable, or the login after restores a switch without its payout.
  def test_a_fact_lost_in_a_crash_is_never_restored
    start_server
    register("fl2@t.co")
    c, = session("fl2@t.co")
    snapshot(c, 1, switches: [4])
    c.close   # crash: no save

    c, lo = session("fl2@t.co")
    assert_empty lo[:flag_facts][:switches]
    snapshot(c, 2, switches: [])   # the blob it loaded never had the switch
    save(c, 2)
    c.close

    _, lo = session("fl2@t.co")
    assert_empty lo[:flag_facts][:switches]
  end

  # A client from before the watermark sends none: it keeps the old promote-on-save.
  def test_a_save_without_a_watermark_promotes_what_the_client_holds
    start_server
    register("fl3@t.co")
    c, = session("fl3@t.co")
    snapshot(c, 1, switches: [4])
    save(c, nil)
    c.close

    _, lo = session("fl3@t.co")
    assert_equal [4], lo[:flag_facts][:switches]
  end

  def test_shadow_records_facts_but_never_hands_them_back
    start_server("shadow")
    register("fl4@t.co")
    c, lo = session("fl4@t.co")
    assert_equal "shadow", lo[:flag_state]
    snapshot(c, 1, switches: [4])
    save(c, 1)
    c.close

    _, lo = session("fl4@t.co")
    assert_nil lo[:flag_facts]
    assert_equal 1, @db[:progression_facts].exclude(durable_at: nil).count
  end

  # Off is the default and must stay inert: no ack, no rows, nothing in the login.
  def test_off_leaves_the_channel_inert
    start_server("off")
    register("fl5@t.co")
    c, lo = session("fl5@t.co")
    assert_equal "off", lo[:flag_state]
    assert_nil lo[:flag_facts]
    send_env(c, { type: :flags, seq: 1, switches: [4], variables: {}, self_switches: [] })
    send_env(c, { type: :ping, t: 1 })
    assert_equal :pong, recv(c)[:type], "no :flags_ack when the layer is off"
    assert_equal 0, @db[:progression_facts].count
    c.close
  end
end
