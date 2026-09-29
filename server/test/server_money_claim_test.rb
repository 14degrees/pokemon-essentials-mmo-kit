require "minitest/autorun"
require "socket"
require "timeout"
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

# Money authority M1a over the wire: a trainer battle's prize is claimed where the engine
# pays it, and judged against the exports - each trainer placed on the claim's map, where
# the player is; each battle paid once (the branches of one event are one battle); a
# rematch in order and on its cadence; the amount within the bound its trainers and facts
# allow. In shadow every verdict is recorded and logged, and no money moves.
class ServerMoneyClaimTest < Minitest::Test
  W = PEMK::Wire

  WORLD = Tempfile.new(["pemk_world", ".json"])
  WORLD.write(JSON.generate(
    "schema_version" => 3,
    "maps" => {
      "31" => { "name" => "Route", "width" => 20, "height" => 20, "objects" => [], "trainers" => [
        { "event_id" => 5, "x" => 1, "y" => 1, "type" => "CAMPER", "name" => "Jeff", "version" => 0, "rematch" => true },
        { "event_id" => 5, "x" => 1, "y" => 1, "type" => "CAMPER", "name" => "Jeff", "version" => 1, "rematch" => true },
        { "event_id" => 7, "x" => 2, "y" => 2, "type" => "LASS", "name" => "Anna", "version" => 0 },
        { "event_id" => 15, "x" => 3, "y" => 3, "type" => "RIVAL1", "name" => "Blue", "version" => 0 },
        { "event_id" => 15, "x" => 3, "y" => 3, "type" => "RIVAL1", "name" => "Blue", "version" => 1 },
        { "event_id" => 9, "x" => 4, "y" => 4, "type" => "LASS", "name" => "Copy", "version" => 0 }
      ] },
      "32" => { "name" => "Town", "width" => 20, "height" => 20, "objects" => [
        { "kind" => "mart", "items" => %w[POTION], "prices" => {}, "price_options" => {}, "sell_options" => {},
          "dynamic" => false, "x" => 9, "y" => 9, "event_id" => 20 }
      ] }
    }
  ))
  WORLD.flush

  BATTLE = Tempfile.new(["pemk_battle", ".json"])
  src = JSON.parse(File.read(File.expand_path("../data/battle_data.json", __dir__)))
  src["trainer_types"] = { "CAMPER" => { "base_money" => 16 }, "LASS" => { "base_money" => 20 },
                           "RIVAL1" => { "base_money" => 60 } }
  src["trainers"] = [
    { "type" => "CAMPER", "name" => "Jeff", "version" => 0, "party" => [["SPEAROW", 16, nil, %w[PECK]]] },
    { "type" => "CAMPER", "name" => "Jeff", "version" => 1, "party" => [["SPEAROW", 30, nil, %w[PECK]]] },
    { "type" => "LASS", "name" => "Anna", "version" => 0, "party" => [["RATTATA", 20, nil, %w[TACKLE]]] },
    { "type" => "RIVAL1", "name" => "Blue", "version" => 0, "party" => [["PIDGEY", 10, nil, %w[TACKLE]]] },
    { "type" => "RIVAL1", "name" => "Blue", "version" => 1, "party" => [["PIDGEY", 12, nil, %w[TACKLE]]] },
    { "type" => "LASS", "name" => "Copy", "version" => 0, "party" => [["CLEFAIRY", 10, nil, %w[METRONOME]]] }
  ]
  BATTLE.write(JSON.generate(src))
  BATTLE.flush

  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    %i[money_claims money_payouts money_shadow encounter_rolls economy_ledger economy_balances inventory_snapshots party_snapshots monster_transfers monsters
       enforcement_events].each { |t| @db[t].delete rescue nil }
    @db[:accounts].delete
    @logs = Queue.new
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  def start_server(mode = "shadow", extra = {})
    env = ENV.to_h.merge("PEMK_WORLD" => WORLD.path, "PEMK_BATTLE_DATA" => BATTLE.path, "PEMK_MONEY_AUTHORITY" => mode)
                  .merge(extra)
    @server = PEMK::Server.new(config: PEMK::Config.new(env: env), logger: ->(m) { @logs << m })
    @server.start
    @port = @server.port
  end

  def logs
    out = []
    out << @logs.pop until @logs.empty?
    out
  end

  def send_env(s, e)
    s.write(W.encode_split(e))
  end

  def recv_type(s, *types)
    Timeout.timeout(5) do
      loop do
        h = s.read(4)
        return nil if h.nil?

        env = W.decode_envelope(s.read(h.unpack1("N")), false)[:env]
        return env if types.include?(env[:type])
      end
    end
  end

  def login(email = "claim@t.co", map: 31)
    s = TCPSocket.new("127.0.0.1", @port)
    send_env(s, { type: :register, email: email, password: "password1" })
    recv_type(s, :register_ok, :register_err)
    send_env(s, { type: :login, email: email, password: "password1" })
    lo = recv_type(s, :login_ok)
    send_env(s, { type: :pos, map: map, x: 5, y: 5, dir: 2 }) if map
    [s, lo]
  end

  def claim(s, nonce, trainers, amount, map: 31, **facts)
    send_env(s, { type: :money_claim, nonce: nonce, trainers: trainers, amount: amount, map: map }.merge(facts))
    recv_type(s, :money_claim_ack)
  end

  ANNA = ["LASS", "Anna", 0, 31, 7].freeze
  def jeff(v) = ["CAMPER", "Jeff", v, 31, 5]
  def blue(v) = ["RIVAL1", "Blue", v, 31, 15]

  def test_a_prize_is_judged_against_its_trainer
    start_server
    s, lo = login
    r = claim(s, 11, [ANNA], 400)
    assert_equal ["paid", 400], r.values_at(:verdict, :accepted), "20 x 20"
    row = @db[:money_claims].where(account_id: lo[:account_id], nonce: 11).first
    assert_equal ["paid", "shadow", 400], row.values_at(:verdict, :mode, :accepted)
    assert_nil @db[:economy_balances].where(account_id: lo[:account_id], field: "money").get(:balance), "shadow moves nothing"
    assert(logs.any? { |l| l.include?("prize 400 for LASS Anna v0") })
  end

  def test_a_battle_is_paid_once
    start_server
    s, = login
    claim(s, 1, [ANNA], 400)
    assert_equal ["repeat", 0], claim(s, 2, [ANNA], 400).values_at(:verdict, :accepted)
    assert_equal "paid", claim(s, 3, [blue(0)], 600)[:verdict]
    assert_equal "repeat", claim(s, 4, [blue(1)], 720)[:verdict], "another branch of the same event"
  end

  def test_a_claim_away_from_its_trainer
    start_server
    s, = login(map: 32)
    assert_equal "away", claim(s, 1, [ANNA], 400)[:verdict]
    s2, = login("claim2@t.co")
    assert_equal "unknown", claim(s2, 2, [["LASS", "Anna", 0, 31, 9]], 400)[:verdict], "not this event's trainer"
    assert_equal "unknown", claim(s2, 3, [["LASS", "Nobody", 0, 31, 7]], 400)[:verdict]
  end

  def test_a_claim_over_its_bound_is_suspect
    start_server
    s, lo = login
    assert_equal ["suspect", 400], claim(s, 1, [ANNA], 800, amulet: true).values_at(:verdict, :accepted),
                 "no Amulet Coin on the party"
    assert_equal 1, @db[:money_payouts].where(account_id: lo[:account_id], key: "trainer:LASS:Anna:0").count,
                 "the battle is paid for all the same"
  end

  def test_rematches_in_order_and_on_their_cadence
    start_server
    s, lo = login
    assert_equal "order", claim(s, 1, [jeff(1)], 480)[:verdict], "the first rematch before the battle itself"
    assert_equal "paid", claim(s, 2, [jeff(0)], 256)[:verdict]
    assert_equal "paid", claim(s, 3, [jeff(1)], 480)[:verdict]
    assert_equal "cadence", claim(s, 4, [jeff(1)], 480)[:verdict]
    @db[:money_payouts].where(account_id: lo[:account_id]).update(paid_at: Time.now - 21 * 60)
    assert_equal "paid", claim(s, 5, [jeff(1)], 480)[:verdict], "twenty minutes later"
  end

  def test_a_nonce_gets_its_first_verdict_and_a_claim_waits_for_a_position
    start_server
    s, = login(map: nil)
    assert_equal "wait", claim(s, 1, [ANNA], 400)[:verdict], "no position on this connection yet"
    send_env(s, { type: :pos, map: 31, x: 5, y: 5, dir: 2 })
    assert_equal "paid", claim(s, 1, [ANNA], 400)[:verdict], "judged once it has one"
    assert_equal ["paid", 400], claim(s, 1, [ANNA], 400).values_at(:verdict, :accepted), "asked again"
  end

  def test_an_unsealed_claim_is_voided_at_login
    start_server
    s, lo = login
    claim(s, 1, [ANNA], 400)
    s.close
    s, = login   # the save it loads may lack the battle
    assert_equal "paid", claim(s, 2, [ANNA], 400)[:verdict], "fought again"
    send_env(s, { type: :econ, field: :money, value: 3400, seq: 1 })
    recv_type(s, :econ_ack, :econ_rej)
    s.close
    s, = login
    assert_equal "repeat", claim(s, 3, [ANNA], 400)[:verdict], "sealed by the money frame"
    assert_equal 1, @db[:money_claims].where(account_id: lo[:account_id]).exclude(voided_at: nil).count
    assert_equal ["void", 0], claim(s, 1, [ANNA], 400).values_at(:verdict, :accepted), "the voided one, asked again"
  end

  def money(s, value, seq)
    send_env(s, { type: :econ, field: :money, value: value, seq: seq })
    recv_type(s, :econ_ack, :econ_rej)
  end

  # M1b: the shadow balance explains a claimed prize, and names money nothing explains.
  def test_the_shadow_balance
    start_server
    s, lo = login
    money(s, 3000, 1)                      # a new account's starting money, seeded at login
    claim(s, 1, [ANNA], 400)
    money(s, 3400, 2)                      # the prize
    money(s, 4000, 3)                      # 600 from nowhere
    money(s, 4000, 4)                      # carried, not new
    sleep 0.3
    lines = logs.grep(/money: account #{lo[:account_id]} UNEXPLAINED/)
    assert_equal ["UNEXPLAINED +600"], lines.map { |l| l[/UNEXPLAINED \+\d+/] }
    assert_equal [3400, 4000], @db[:money_shadow].where(account_id: lo[:account_id]).get(%i[s c])
  end

  def sell(s, item, qty, unit, seq)
    send_env(s, { type: :shop_req, op: :sell, item: item, quantity: qty, unit_price: unit, map: 32, event: 20, seq: seq })
    recv_type(s, :shop_grant, :shop_deny)
  end

  # M1d: a sale of items the server never judged moves the client's balance and not the
  # shadow balance; one of a local tier is labelled so in the ledger.
  def test_a_sale_of_items_never_judged
    start_server("shadow", "PEMK_SHOP_ENFORCE" => "on")
    s, lo = login
    money(s, 1000, 1)
    send_env(s, { type: :inv, bag: { POTION: 2, NUGGET: 1 }, seq: 1 })
    recv_type(s, :inv_ack)
    @server.instance_variable_set(:@judged_local, Set["NUGGET"])   # what item authority's tiers would say
    battle = @server.instance_variable_get(:@battle)
    nugget = battle.item("NUGGET")["sell_price"]
    potion = battle.item("POTION")["sell_price"]
    assert_equal :shop_grant, sell(s, "NUGGET", 1, nugget, 1)[:type]
    assert_equal :shop_grant, sell(s, "POTION", 1, potion, 2)[:type]
    reasons = @db[:economy_ledger].where(account_id: lo[:account_id]).select_map(:reason)
    assert_includes reasons, "shop:sell:local:NUGGETx1"
    assert_includes reasons, "shop:sell:POTIONx1"
    assert_equal [1000 + potion, 1000 + potion + nugget], @db[:money_shadow].where(account_id: lo[:account_id]).get(%i[s c]),
                 "the Potion counts, the Nugget does not"
    assert(logs.any? { |l| l.include?("UNOWNED-SOURCE +#{nugget} (sold NUGGET") })
  end

  # A trainer fought again after its prize was paid: the claim is a repeat, and the money
  # that follows is logged as one, not as money from nowhere.
  def test_a_prize_paid_again_is_a_repeat
    start_server
    s, lo = login
    money(s, 3000, 1)
    claim(s, 1, [ANNA], 400)
    money(s, 3400, 2)
    assert_equal "repeat", claim(s, 2, [ANNA], 5000)[:verdict], "stating more than the battle pays"
    money(s, 8400, 3)
    sleep 0.3
    lines = logs.grep(/money: account #{lo[:account_id]} (UNEXPLAINED|REPEAT)/).map { |l| l[/(UNEXPLAINED|REPEAT) \+\d+/] }
    assert_equal ["REPEAT +400", "UNEXPLAINED +4600"], lines, "a repeat of what the battle pays, no more"
  end

  # --- M1c: Pay Day -------------------------------------------------------------

  def team(s, *mons)
    send_env(s, { type: :team_check, team: mons.map { |sp, lv, mv| { "species" => sp, "level" => lv, "moves" => mv } }, seq: 1 })
    recv_type(s, :team_ack)
  end

  # A foe the server minted +age+ seconds ago (a battle takes time: one use per second).
  def mint(account_id, pid, species: "RATTATA", level: 5, age: 120)
    @db[:encounter_rolls].insert(account_id: account_id, species: species, level: level, pid: pid,
                                 iv: Sequel.pg_jsonb([0, 0, 0, 0, 0, 0]), shiny: false, map: 31, enctype: "Land",
                                 created_at: Time.now - age)
  end

  def payday(s, nonce, amount, **proof)
    send_env(s, { type: :money_claim, kind: :payday, nonce: nonce, amount: amount, map: 31 }.merge(proof))
    recv_type(s, :money_claim_ack)
  end

  # A wild battle's Pay Day needs the foe the server minted for it, once.
  def test_pay_day_in_a_wild_battle_needs_its_mint
    start_server("shadow", "PEMK_BATTLE_ENFORCE_ENCOUNTERS" => "on")
    s, lo = login
    team(s, ["MEOWTH", 12, %w[SCRATCH PAYDAY]])
    mint(lo[:account_id], 777)
    assert_equal ["paid", 60], payday(s, 1, 60, foes: [777]).values_at(:verdict, :accepted), "5 x 12, used once"
    refute_nil @db[:encounter_rolls].where(pid: 777).get(:payday_at)
    assert_equal "unproven", payday(s, 2, 60, foes: [777])[:verdict], "the same mint again"
    assert_equal "unproven", payday(s, 3, 60, foes: [888])[:verdict], "a foe never minted"
  end

  def test_pay_day_is_bounded_by_the_party
    start_server("shadow", "PEMK_BATTLE_ENFORCE_ENCOUNTERS" => "on")
    s, lo = login
    team(s, ["MEOWTH", 12, %w[SCRATCH PAYDAY]])
    mint(lo[:account_id], 1)
    assert_equal ["suspect", 600], payday(s, 1, 5000, foes: [1]).values_at(:verdict, :accepted),
                 "5 x 12 x ten uses at most for one foe"
    team(s, ["PIKACHU", 30, %w[THUNDERSHOCK]])
    mint(lo[:account_id], 2)
    assert_equal ["suspect", 0], payday(s, 2, 60, foes: [2]).values_at(:verdict, :accepted), "no one knows Pay Day"
  end

  # A mint is handed out on request: its claim pays at most one use per second since.
  def test_pay_day_is_bounded_by_the_battles_time
    start_server("shadow", "PEMK_BATTLE_ENFORCE_ENCOUNTERS" => "on")
    s, lo = login
    team(s, ["MEOWTH", 12, %w[PAYDAY]])
    mint(lo[:account_id], 5, age: 3)
    assert_equal ["suspect", 180], payday(s, 1, 600, foes: [5]).values_at(:verdict, :accepted), "5 x 12 x three uses"
  end

  # Until battle records prove each use, the day's Pay Day is capped.
  def test_pay_day_is_capped_per_day
    start_server("shadow", "PEMK_BATTLE_ENFORCE_ENCOUNTERS" => "on", "PEMK_MONEY_PAYDAY_DAILY" => "100")
    s, lo = login
    team(s, ["MEOWTH", 12, %w[PAYDAY]])
    mint(lo[:account_id], 7)
    mint(lo[:account_id], 8)
    assert_equal ["paid", 60], payday(s, 1, 60, foes: [7]).values_at(:verdict, :accepted)
    assert_equal ["capped", 40], payday(s, 2, 60, foes: [8]).values_at(:verdict, :accepted)
  end

  def test_pay_day_without_mints_is_only_bounded
    start_server
    s, = login
    team(s, ["MEOWTH", 12, %w[PAYDAY]])
    assert_equal "paid", payday(s, 1, 60, foes: [4242])[:verdict]
    assert(logs.any? { |l| l.include?("pay day 60 (bound 600) (unminted)") })
  end

  def test_pay_day_in_a_trainer_battle_follows_its_prize
    start_server
    s, = login
    team(s, ["MEOWTH", 12, %w[PAYDAY]])
    claim(s, 50, [ANNA], 400)
    assert_equal "paid", payday(s, 1, 60, trainer_claim: 50)[:verdict]
    assert_equal ["spent", 0], payday(s, 4, 60, trainer_claim: 50).values_at(:verdict, :accepted),
                 "a battle scatters its coins once"
    assert_equal "unproven", payday(s, 2, 60, trainer_claim: 51)[:verdict], "no such prize claim"
    s2, = login("claim2@t.co", map: 32)
    team(s2, ["MEOWTH", 12, %w[PAYDAY]])
    claim(s2, 60, [ANNA], 400)
    assert_equal "unproven", payday(s2, 3, 60, trainer_claim: 60)[:verdict], "its prize was refused"
  end

  def test_the_login_says_how_claims_are_judged
    start_server
    _, lo = login
    assert_equal "shadow", lo[:money_claims]
  end

  def test_happy_hour_needs_the_move
    start_server
    s, = login
    assert_equal ["suspect", 400], claim(s, 1, [ANNA], 800, happy_hour: true).values_at(:verdict, :accepted)
    send_env(s, { type: :team_check, team: [{ "species" => "CLEFAIRY", "level" => 10, "moves" => %w[METRONOME] }], seq: 1 })
    recv_type(s, :team_ack)
    assert_equal ["paid", 400], claim(s, 2, [["LASS", "Copy", 0, 31, 9]], 400, happy_hour: true).values_at(:verdict, :accepted),
                 "10 x 20 x 2 with Metronome in the party"
  end

  def test_bad_claims
    start_server
    s, = login
    assert_equal "bad", claim(s, 1, [ANNA, ANNA], 400)[:verdict], "the same trainer twice"
    assert_equal "bad", claim(s, 2, [ANNA, blue(0), jeff(0), ["LASS", "Copy", 0, 31, 9]], 1)[:verdict], "four trainers"
    assert_equal "bad", claim(s, 3, [ANNA], -5)[:verdict]
    assert_equal "bad", claim(s, nil, [ANNA], 400)[:verdict]
    assert_equal 0, @db[:money_claims].count
  end

  def test_off_judges_nothing
    start_server("off")
    s, = login
    send_env(s, { type: :money_claim, nonce: 1, trainers: [ANNA], amount: 400, map: 31 })
    assert_raises(Timeout::Error) { recv_type(s, :money_claim_ack) }
    assert_equal 0, @db[:money_claims].count
  end
end
