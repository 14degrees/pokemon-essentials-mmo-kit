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
    "trainer_marks" => true,
    "partners" => { "list" => [["POKEMONTRAINER", "May", 0]], "computed" => false },
    "maps" => {
      "31" => { "name" => "Route", "width" => 20, "height" => 20, "objects" => [], "trainers" => [
        { "event_id" => 5, "x" => 1, "y" => 1, "type" => "CAMPER", "name" => "Jeff", "version" => 0, "rematch" => true },
        { "event_id" => 5, "x" => 1, "y" => 1, "type" => "CAMPER", "name" => "Jeff", "version" => 1, "rematch" => true },
        { "event_id" => 7, "x" => 2, "y" => 2, "type" => "LASS", "name" => "Anna", "version" => 0 },
        { "event_id" => 15, "x" => 3, "y" => 3, "type" => "RIVAL1", "name" => "Blue", "version" => 0 },
        { "event_id" => 15, "x" => 3, "y" => 3, "type" => "RIVAL1", "name" => "Blue", "version" => 1 },
        { "event_id" => 9, "x" => 4, "y" => 4, "type" => "LASS", "name" => "Copy", "version" => 0 },
        { "event_id" => 3, "x" => 5, "y" => 5, "type" => "CHAMPION", "name" => "Blue", "version" => 0, "repeatable" => true },
        { "event_id" => 20, "x" => 6, "y" => 6, "type" => "YOUNGSTER", "name" => "Ben", "version" => 0 },
        { "event_id" => 20, "x" => 6, "y" => 6, "type" => "YOUNGSTER", "name" => "Ben", "version" => 1, "page" => 1 },
        { "event_id" => 21, "x" => 7, "y" => 7, "type" => "YOUNGSTER", "name" => "Joey", "version" => 0, "no_money" => true }
      ] },
      "32" => { "name" => "Town", "width" => 20, "height" => 20, "objects" => [
        { "kind" => "mart", "items" => %w[POTION], "prices" => {}, "price_options" => {}, "sell_options" => {},
          "dynamic" => false, "x" => 9, "y" => 9, "event_id" => 20 },
        { "kind" => "bp_shop", "items" => %w[PROTEIN], "prices" => {}, "price_options" => {}, "dynamic" => false,
          "x" => 11, "y" => 9, "event_id" => 22 }
      ] }
    }
  ))
  WORLD.flush

  BATTLE = Tempfile.new(["pemk_battle", ".json"])
  src = JSON.parse(File.read(File.expand_path("../data/battle_data.json", __dir__)))
  src["trainer_types"] = { "CAMPER" => { "base_money" => 16 }, "LASS" => { "base_money" => 20 },
                           "RIVAL1" => { "base_money" => 60 }, "CHAMPION" => { "base_money" => 100 },
                           "YOUNGSTER" => { "base_money" => 16 } }
  src["trainers"] = [
    { "type" => "CAMPER", "name" => "Jeff", "version" => 0, "party" => [["SPEAROW", 16, nil, %w[PECK]]] },
    { "type" => "CAMPER", "name" => "Jeff", "version" => 1, "party" => [["SPEAROW", 30, nil, %w[PECK]]] },
    { "type" => "LASS", "name" => "Anna", "version" => 0, "party" => [["RATTATA", 20, nil, %w[TACKLE]]] },
    { "type" => "RIVAL1", "name" => "Blue", "version" => 0, "party" => [["PIDGEY", 10, nil, %w[TACKLE]]] },
    { "type" => "RIVAL1", "name" => "Blue", "version" => 1, "party" => [["PIDGEY", 12, nil, %w[TACKLE]]] },
    { "type" => "LASS", "name" => "Copy", "version" => 0, "party" => [["CLEFAIRY", 10, nil, %w[METRONOME]]] },
    { "type" => "CHAMPION", "name" => "Blue", "version" => 0, "party" => [["PIDGEOT", 50, nil, %w[TACKLE]]] },
    { "type" => "YOUNGSTER", "name" => "Ben", "version" => 0, "party" => [["RATTATA", 10, nil, %w[TACKLE]]] },
    { "type" => "YOUNGSTER", "name" => "Ben", "version" => 1, "party" => [["RATTATA", 20, nil, %w[TACKLE]]] },
    { "type" => "YOUNGSTER", "name" => "Joey", "version" => 0, "party" => [["RATTATA", 20, nil, %w[TACKLE]]] },
    { "type" => "POKEMONTRAINER", "name" => "May", "version" => 0, "party" => [["TORCHIC", 10, "AMULETCOIN", %w[EMBER]]] },
    { "type" => "RICHBOY", "name" => "Rich", "version" => 0, "party" => [["MEOWTH", 10, "AMULETCOIN", %w[SCRATCH]]] }
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

  # A battle the game lets be fought again (its win marks nothing a later page waits for):
  # the boot names it, and a re-fight's refusal says so.
  def test_a_battle_fought_again_by_design
    start_server
    assert(logs.any? { |l| l.include?("fought again") && l.include?("CHAMPION Blue v0 (map 31 event 3)") })
    s, lo = login
    champion = ["CHAMPION", "Blue", 0, 31, 3]
    assert_equal "paid", claim(s, 1, [champion], 5000)[:verdict], "50 x 100"
    assert_equal "cadence", claim(s, 2, [champion], 5000)[:verdict], "once per 20 minutes (Sam, 2026-09-29)"
    assert(logs.any? { |l| l.include?("WOULD-REFUSE") && l.include?("a battle the game lets be fought again") })
    assert_equal 5000, @db[:money_shadow].where(account_id: lo[:account_id]).get(:repeat), "its prize is no conjure"
    @db[:money_payouts].where(account_id: lo[:account_id]).update(paid_at: Time.now - (21 * 60))
    assert_equal "paid", claim(s, 3, [champion], 5000)[:verdict], "twenty minutes later"
    assert_nil @db[:money_payouts].where(account_id: lo[:account_id], key: "trainer:CHAMPION:Blue:0").first,
               "its event is its clock"
  end

  # The battle rules say it pays nothing: the engine claims nothing, so a claim is forged.
  def test_a_battle_that_pays_nothing
    start_server
    s, = login
    assert_equal ["no_money", 0], claim(s, 1, [["YOUNGSTER", "Joey", 0, 31, 21]], 320).values_at(:verdict, :accepted)
    assert(logs.any? { |l| l.include?("WOULD-REFUSE prize 320 for YOUNGSTER Joey v0 (no_money)") })
  end

  # An Amulet Coin on the partner trainer's party counts for a partner the game registers.
  def test_the_partner_is_one_the_game_registers
    start_server
    s, = login
    assert_equal ["suspect", 400], claim(s, 1, [ANNA], 800, amulet: true, partner: %w[RICHBOY Rich])
      .values_at(:verdict, :accepted), "never registered as a partner"
    assert_equal ["paid", 1200], claim(s, 2, [blue(0)], 1200, amulet: true, partner: %w[POKEMONTRAINER May])
      .values_at(:verdict, :accepted), "10 x 60, doubled: May holds one"
  end

  # A later page's battle (the first win moved the event on) is another battle.
  def test_a_later_pages_battle_is_another
    start_server
    s, = login
    ben = ->(v) { ["YOUNGSTER", "Ben", v, 31, 20] }
    assert_equal "paid", claim(s, 1, [ben.(0)], 160)[:verdict]
    assert_equal "paid", claim(s, 2, [ben.(1)], 320)[:verdict], "the event's second page"
    assert_equal "repeat", claim(s, 3, [ben.(1)], 320)[:verdict]
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

  # A save after a claim holds its battle, with or without a money frame between them.
  def test_a_save_seals_the_claims_before_it
    start_server
    s, lo = login
    claim(s, 1, [ANNA], 400)
    s.write(W.encode_split({ type: :save }, "\x04\b0".b))
    send_env(s, { type: :inv, bag: {}, seq: 1 })
    recv_type(s, :inv_ack)   # the save's job ran before this one
    s.close
    s, = login
    assert_equal "repeat", claim(s, 2, [ANNA], 400)[:verdict], "sealed by the save"
    assert_equal 0, @db[:money_claims].where(account_id: lo[:account_id]).exclude(voided_at: nil).count
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

  # A claim is judged with what its connection reported: nothing is recorded before.
  def test_a_claim_waits_for_what_it_is_judged_with
    start_server
    s, lo = login(map: nil)
    assert_equal "wait", claim(s, 1, [ANNA], 400)[:verdict], "no position yet"
    assert_equal "wait", payday(s, 2, 60, trainer_claim: 1)[:verdict], "no team yet"
    team(s, ["MEOWTH", 12, %w[PAYDAY]])
    assert_equal "wait", payday(s, 2, 60, trainer_claim: 1)[:verdict], "its prize still waits"
    assert_equal 0, @db[:money_claims].where(account_id: lo[:account_id]).count
    send_env(s, { type: :pos, map: 31, x: 5, y: 5, dir: 2 })
    assert_equal "paid", claim(s, 1, [ANNA], 400)[:verdict]
    assert_equal "paid", payday(s, 2, 60, trainer_claim: 1)[:verdict], "judged after its prize"
    s2, = login("claim2@t.co")
    assert_equal "wait", claim(s2, 3, [ANNA], 800, happy_hour: true)[:verdict], "Happy Hour: no team yet"
    assert_equal "paid", claim(s2, 4, [blue(0)], 600)[:verdict], "a prize alone needs no team"
    # a prize claim refused as malformed never holds its Pay Day
    team(s2, ["MEOWTH", 12, %w[PAYDAY]])
    assert_equal "bad", claim(s2, 5, [ANNA], -1)[:verdict]
    assert_equal "unproven", payday(s2, 6, 60, trainer_claim: 5)[:verdict]
  end

  # A prize claim dropped over its frame budget goes out again: the Pay Day that gets
  # through after it waits for it.
  def test_a_pay_day_waits_for_a_prize_over_its_budget
    start_server
    s, = login
    team(s, ["MEOWTH", 12, %w[PAYDAY]])
    10.times { |i| send_env(s, { type: :money_claim, nonce: 100 + i, trainers: [ANNA], amount: 400, map: 31 }) }
    send_env(s, { type: :money_claim, nonce: 1, trainers: [blue(0)], amount: 600, map: 31 })   # over budget
    10.times { recv_type(s, :money_claim_ack) }
    sleep 0.8   # the budget grows back by one
    assert_equal "wait", payday(s, 2, 60, trainer_claim: 1)[:verdict], "its prize is coming"
    sleep 1.2   # room for both
    assert_equal "paid", claim(s, 1, [blue(0)], 600)[:verdict]
    assert_equal "paid", payday(s, 2, 60, trainer_claim: 1)[:verdict]
    # a malformed one dropped the same way, then refused, holds nothing
    s2, = login("claim2@t.co")
    team(s2, ["MEOWTH", 12, %w[PAYDAY]])
    10.times { |i| send_env(s2, { type: :money_claim, nonce: 200 + i, trainers: [ANNA], amount: 400, map: 31 }) }
    send_env(s2, { type: :money_claim, nonce: 3, trainers: [ANNA], amount: -1, map: 31 })   # over budget
    10.times { recv_type(s2, :money_claim_ack) }
    sleep 1.2
    assert_equal "bad", claim(s2, 3, [ANNA], -1)[:verdict]
    assert_equal "unproven", payday(s2, 4, 60, trainer_claim: 3)[:verdict]
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

  # A local tier the server itself sold: reselling those units is money it owns (the demo's
  # Potions are a local tier); any more than it sold is not.
  def test_a_resale_of_what_the_server_sold
    start_server("shadow", "PEMK_SHOP_ENFORCE" => "on")
    s, lo = login
    money(s, 1000, 1)
    send_env(s, { type: :inv, bag: { POTION: 2 }, seq: 1 })
    recv_type(s, :inv_ack)
    @server.instance_variable_set(:@judged_local, Set["POTION"])
    potion = @server.instance_variable_get(:@battle).item("POTION")
    send_env(s, { type: :shop_req, op: :buy, item: "POTION", quantity: 2, unit_price: potion["price"], map: 32,
                  event: 20, seq: 1 })
    assert_equal :shop_grant, recv_type(s, :shop_grant, :shop_deny)[:type]
    sold = potion["sell_price"]
    assert_equal :shop_grant, sell(s, "POTION", 1, sold, 2)[:type]
    assert_equal :shop_grant, sell(s, "POTION", 3, sold, 3)[:type]
    reasons = @db[:economy_ledger].where(account_id: lo[:account_id]).order(:id).select_map(:reason)
    assert_equal ["shop:sell:POTIONx1", "shop:sell:local:POTIONx3"], reasons.grep(/sell/)
    s_now, c_now = @db[:money_shadow].where(account_id: lo[:account_id]).get(%i[s c])
    assert_equal 1000 - 2 * potion["price"] + 2 * sold, s_now, "the two it sold count"
    assert_equal s_now + 2 * sold, c_now, "two more than it sold do not"
    assert(logs.any? { |l| l.include?("UNOWNED-SOURCE +#{2 * sold} (sold POTION") })
  end

  # Battle points are the client's word until BP authority: what they buy is not money the
  # server received, and its resale is not owned.
  def test_a_resale_of_what_battle_points_bought
    start_server("shadow", "PEMK_SHOP_ENFORCE" => "on")
    s, lo = login
    money(s, 1000, 1)
    send_env(s, { type: :econ, field: :battle_points, value: 50, seq: 1 })
    recv_type(s, :econ_ack, :econ_rej)
    send_env(s, { type: :inv, bag: {}, seq: 1 })
    recv_type(s, :inv_ack)
    @server.instance_variable_set(:@judged_local, Set["PROTEIN"])
    protein = @server.instance_variable_get(:@battle).item("PROTEIN")
    send_env(s, { type: :shop_req, op: :buy, item: "PROTEIN", quantity: 1, unit_price: protein["bp_price"], bp: true,
                  map: 32, event: 22, seq: 1 })
    assert_equal :shop_grant, recv_type(s, :shop_grant, :shop_deny)[:type]
    count = ->(column) { @db[:inventory_snapshots].where(account_id: lo[:account_id]).get(column).to_h }
    assert_equal({}, count.(:bought))
    assert_equal({ "PROTEIN" => 1 }, count.(:bp_bought))
    # never sold for money (Sam, 2026-09-29): refused once enforced, logged until then
    @server.instance_variable_set(:@money_enforce, true)
    assert_equal "bp_bought", sell(s, "PROTEIN", 1, protein["sell_price"], 2)[:reason]
    assert_equal 1, @db[:inventory_snapshots].where(account_id: lo[:account_id]).get(:bag).to_h["PROTEIN"], "kept"
    @server.instance_variable_set(:@money_enforce, false)
    assert_equal :shop_grant, sell(s, "PROTEIN", 1, protein["sell_price"], 3)[:type]
    lines = logs
    assert(lines.any? { |l| l.include?("WOULD-REFUSE sale of PROTEIN x1 (bp_bought: 1 bought with battle points)") })
    assert(lines.any? { |l| l.include?("UNOWNED-SOURCE +#{protein['sell_price']} (sold PROTEIN") })
    assert_equal({}, count.(:bp_bought), "sold")
  end

  # The units battle points bought are the possession's last: a sale of the others is free.
  def test_the_units_battle_points_bought_go_last
    start_server("shadow", "PEMK_SHOP_ENFORCE" => "on")
    s, lo = login
    send_env(s, { type: :econ, field: :battle_points, value: 50, seq: 1 })
    recv_type(s, :econ_ack, :econ_rej)
    send_env(s, { type: :inv, bag: { PROTEIN: 2 }, seq: 1 })   # two found
    recv_type(s, :inv_ack)
    @server.instance_variable_set(:@judged_local, Set.new)
    @server.instance_variable_set(:@money_enforce, true)
    protein = @server.instance_variable_get(:@battle).item("PROTEIN")
    send_env(s, { type: :shop_req, op: :buy, item: "PROTEIN", quantity: 1, unit_price: protein["bp_price"], bp: true,
                  map: 32, event: 22, seq: 1 })
    assert_equal :shop_grant, recv_type(s, :shop_grant, :shop_deny)[:type]
    assert_equal :shop_grant, sell(s, "PROTEIN", 2, protein["sell_price"], 2)[:type], "the two found"
    assert_equal "bp_bought", sell(s, "PROTEIN", 1, protein["sell_price"], 3)[:reason], "the one BP bought"
    assert_equal 1, @db[:inventory_snapshots].where(account_id: lo[:account_id]).get(:bag).to_h["PROTEIN"]
  end

  # Local units the server never sold: at most PEMK_MONEY_LOCAL_DAILY a day (Sam, 2026-09-29).
  def test_the_days_local_sales_are_bounded
    start_server("shadow", "PEMK_SHOP_ENFORCE" => "on", "PEMK_MONEY_LOCAL_DAILY" => "250")
    s, lo = login
    send_env(s, { type: :inv, bag: { POTION: 5 }, seq: 1 })
    recv_type(s, :inv_ack)
    @server.instance_variable_set(:@judged_local, Set["POTION"])
    sold = @server.instance_variable_get(:@battle).item("POTION")["sell_price"]   # 100
    assert_equal :shop_grant, sell(s, "POTION", 2, sold, 1)[:type]
    assert_equal 2 * sold, @db[:money_daily].where(account_id: lo[:account_id]).get(:local_sold)
    @server.instance_variable_set(:@money_enforce, true)
    assert_equal "local_daily", sell(s, "POTION", 1, sold, 2)[:reason], "the day's allowance is spent"
    @server.instance_variable_set(:@money_enforce, false)
    assert_equal :shop_grant, sell(s, "POTION", 1, sold, 3)[:type]
    assert(logs.any? { |l| l.include?("WOULD-REFUSE sale of POTION x1 (local_daily: $#{sold} of local units, $#{2 * sold} sold today of $250)") })
    assert_equal 2, @db[:inventory_snapshots].where(account_id: lo[:account_id]).get(:bag).to_h["POTION"]
  end

  # Units used where a bag-only snapshot shows it are gone from the count: conjured back,
  # they are not the ones the server sold. The stores last known still hold theirs.
  def test_a_bag_only_snapshot_lowers_the_units_sold
    start_server("shadow", "PEMK_SHOP_ENFORCE" => "on")
    s, lo = login
    money(s, 1000, 1)
    send_env(s, { type: :inv, bag: {}, seq: 1 })
    recv_type(s, :inv_ack)
    @server.instance_variable_set(:@judged_local, Set["POTION"])
    potion = @server.instance_variable_get(:@battle).item("POTION")
    send_env(s, { type: :shop_req, op: :buy, item: "POTION", quantity: 3, unit_price: potion["price"], map: 32,
                  event: 20, seq: 1 })
    assert_equal :shop_grant, recv_type(s, :shop_grant, :shop_deny)[:type]
    bought = -> { @db[:inventory_snapshots].where(account_id: lo[:account_id]).get(:bought).to_h }
    stores = { pc: { POTION: 1 }, mail: {}, held: {}, holders: {} }
    send_env(s, { type: :inv, bag: { POTION: 1 }, stores: stores, seq: 2 })   # one used, one in the PC
    recv_type(s, :inv_ack)
    assert_equal({ "POTION" => 2 }, bought.call)
    send_env(s, { type: :inv, bag: {}, seq: 3 })   # the bag's used too - the PC's stays
    recv_type(s, :inv_ack)
    assert_equal({ "POTION" => 1 }, bought.call)
    send_env(s, { type: :inv, bag: { POTION: 2 }, seq: 4 })   # two appear
    recv_type(s, :inv_ack)
    assert_equal({ "POTION" => 1 }, bought.call, "what appears is never a unit it sold")
    sold = potion["sell_price"]
    assert_equal :shop_grant, sell(s, "POTION", 2, sold, 2)[:type]
    assert(logs.any? { |l| l.include?("UNOWNED-SOURCE +#{sold} (sold POTION") }, "one of the two was its own")
  end

  def test_the_login_says_how_claims_are_judged
    start_server
    _, lo = login
    assert_equal "shadow", lo[:money_claims]
  end

  def test_happy_hour_needs_the_move
    start_server
    s, = login
    team(s, ["PIKACHU", 10, %w[THUNDERSHOCK]])
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
