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

# Item authority E3 over the wire: a Mart purchase needs a clerk the world export knows,
# an item it stocks at the price it charges, and the money on the ledger; the server
# takes the money itself and answers with the balance. A sale needs the item in the
# bag record. shadow grants everything and only logs.
class ServerShopTest < Minitest::Test
  W = PEMK::Wire

  WORLD = Tempfile.new(["pemk_world", ".json"])
  WORLD.write(JSON.generate(
    "schema_version" => 3,
    "maps" => { "15" => { "name" => "Mart", "width" => 20, "height" => 10, "objects" => [
      { "kind" => "mart", "items" => %w[POTION POKEBALL], "prices" => { "POKEBALL" => 150 },
        "price_options" => { "POKEBALL" => [150] }, "sell_options" => { "POKEBALL" => [150] },
        "dynamic" => false, "x" => 2, "y" => 2, "event_id" => 5 },
      { "kind" => "mart", "items" => [], "prices" => {}, "price_options" => {}, "sell_options" => {},
        "dynamic" => true, "x" => 4, "y" => 2, "event_id" => 6 },
      { "kind" => "bp_shop", "items" => %w[PROTEIN], "prices" => {}, "price_options" => {}, "dynamic" => false,
        "x" => 6, "y" => 2, "event_id" => 7 },
      # a sale on some days; a key item always at the clerk's own price
      { "kind" => "mart", "items" => %w[POTION SILPHSCOPE], "prices" => { "POTION" => 250, "SILPHSCOPE" => 5000 },
        "price_options" => { "POTION" => [nil, 250], "SILPHSCOPE" => [5000] },
        "sell_options" => { "POTION" => [nil, 250], "SILPHSCOPE" => [5000] },
        "dynamic" => false, "x" => 8, "y" => 2, "event_id" => 8 },
      # an export from before the price options
      { "kind" => "mart", "items" => %w[POKEBALL], "prices" => { "POKEBALL" => 150 }, "dynamic" => false,
        "x" => 10, "y" => 2, "event_id" => 9 },
      # a clerk that buys nothing back
      { "kind" => "mart", "items" => %w[POTION], "prices" => {}, "price_options" => {}, "sell_options" => {},
        "sells" => false, "dynamic" => false, "x" => 12, "y" => 2, "event_id" => 10 }
    ] } }
  ))
  WORLD.flush

  BATTLE = Tempfile.new(["pemk_battle", ".json"])
  def self.item(price, sell, important: false, bp: 1)
    { "pocket" => 2, "is_ball" => false, "is_berry" => false, "is_machine" => false, "can_hold" => !important,
      "move" => nil, "price" => price, "sell_price" => sell, "bp_price" => bp, "important" => important,
      "consumable" => true }
  end
  # The real export, with the prices this test relies on (an older export has none).
  src = JSON.parse(File.read(File.expand_path("../data/battle_data.json", __dir__)))
  src["items"].merge!("POTION" => item(300, 150), "POKEBALL" => item(200, 100), "MASTERBALL" => item(0, 0),
                      "BICYCLE" => item(0, 0, important: true), "PROTEIN" => item(10_000, 5_000, bp: 16),
                      "SILPHSCOPE" => item(0, 0, important: true))
  BATTLE.write(JSON.generate(src))
  BATTLE.flush

  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    %i[economy_ledger economy_balances inventory_snapshots monster_transfers monsters enforcement_events].each do |t|
      @db[t].delete rescue nil
    end
    @db[:accounts].delete
    @logs = Queue.new
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  def start_server(mode = "on")
    env = ENV.to_h.merge("PEMK_WORLD" => WORLD.path, "PEMK_BATTLE_DATA" => BATTLE.path, "PEMK_SHOP_ENFORCE" => mode)
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

  def player(money: 1000, bag: {})
    s = TCPSocket.new("127.0.0.1", @port)
    send_env(s, { type: :register, email: "shop@t.co", password: "password1" })
    recv_type(s, :register_ok, :register_err)
    send_env(s, { type: :login, email: "shop@t.co", password: "password1" })
    lo = recv_type(s, :login_ok)
    send_env(s, { type: :econ, field: :money, value: money, seq: 1 })
    recv_type(s, :econ_ack, :econ_rej)
    send_env(s, { type: :inv, bag: bag, seq: 1 })
    recv_type(s, :inv_ack)
    [s, lo]
  end

  def ask(s, op, item, qty, unit, event: 5, seq: 1)
    send_env(s, { type: :shop_req, op: op, item: item, quantity: qty, unit_price: unit, map: 15, event: event, seq: seq })
    recv_type(s, :shop_grant, :shop_deny)
  end

  def bp_player(points: 50)
    s, lo = player
    send_env(s, { type: :econ, field: :battle_points, value: points, seq: 1 })
    recv_type(s, :econ_ack, :econ_rej)
    [s, lo]
  end

  def bp_ask(s, item, qty, unit, event: 7, seq: 1)
    send_env(s, { type: :shop_req, op: :buy, item: item, quantity: qty, unit_price: unit, bp: true, map: 15,
                  event: event, seq: seq })
    recv_type(s, :shop_grant, :shop_deny)
  end

  def bp(lo)
    @db[:economy_balances].where(account_id: lo[:account_id], field: "battle_points").get(:balance)
  end

  def money(lo)
    @db[:economy_balances].where(account_id: lo[:account_id], field: "money").get(:balance)
  end

  def test_a_purchase_is_made_by_the_server
    start_server
    s, lo = player
    assert_equal true, lo[:shop_gate]
    r = ask(s, :buy, "POTION", 3, 300)
    assert_equal :shop_grant, r[:type]
    assert_equal 100, r[:balance]
    assert_equal 100, money(lo)
    assert_equal :shop_deny, ask(s, :buy, "POTION", 1, 300, seq: 2)[:type], "no money left"
  end

  def test_the_clerk_the_stock_and_the_price_are_checked
    start_server
    s, = player
    assert_equal "price", ask(s, :buy, "POKEBALL", 1, 200)[:reason], "this clerk sets its own price"
    assert_equal :shop_grant, ask(s, :buy, "POKEBALL", 1, 150, seq: 2)[:type]
    assert_equal "not_sold", ask(s, :buy, "MASTERBALL", 1, 0, seq: 3)[:reason]
    assert_equal "not_sold", ask(s, :buy, "MASTERBALL", 1, 0, event: 6, seq: 4)[:reason], "never free from a computed stock"
    assert_equal "not_a_shop", ask(s, :buy, "POTION", 1, 300, event: 42, seq: 5)[:reason]
  end

  def test_a_sale_needs_the_item_in_the_bag_record
    start_server
    s, lo = player(bag: { POTION: 2 })
    r = ask(s, :sell, "POTION", 2, 150)
    assert_equal [:shop_grant, 1300], [r[:type], r[:balance]]
    assert_equal "not_held", ask(s, :sell, "POTION", 3, 150, seq: 2)[:reason]
    assert_equal "not_sellable", ask(s, :sell, "BICYCLE", 1, 0, seq: 3)[:reason]
    assert_equal 1300, money(lo)
  end

  # An event's setPrice(item, buy) makes its clerk buy that item back at +buy+ too (the
  # engine's rule): a sale there is paid that, elsewhere the catalogue's sell price.
  def test_a_clerk_that_sets_a_price_buys_back_at_it
    start_server
    s, lo = player(bag: { POKEBALL: 3 })
    assert_equal "price", ask(s, :sell, "POKEBALL", 1, 100)[:reason], "not the catalogue's, at this clerk"
    assert_equal [:shop_grant, 1150], ask(s, :sell, "POKEBALL", 1, 150, seq: 2).values_at(:type, :balance)
    assert_equal :shop_grant, ask(s, :sell, "POKEBALL", 1, 100, event: 6, seq: 3)[:type], "another clerk: the catalogue's"
    assert_equal 1250, money(lo)
  end

  # A price set on one branch only (a sale day): the clerk charges it on some visits and
  # the catalogue's on others, and the server takes either - but never a price no visit
  # can see, like a key item at its catalogue $0.
  def test_a_price_set_on_some_visits_only
    start_server
    s, lo = player(money: 6000, bag: { POTION: 2 })
    assert_equal :shop_grant, ask(s, :buy, "POTION", 1, 250, event: 8)[:type], "the sale"
    assert_equal :shop_grant, ask(s, :buy, "POTION", 1, 300, event: 8, seq: 2)[:type], "another day"
    assert_equal "price", ask(s, :buy, "POTION", 1, 150, event: 8, seq: 3)[:reason]
    assert_equal "price", ask(s, :buy, "SILPHSCOPE", 1, 0, event: 8, seq: 4)[:reason], "never at the catalogue's"
    assert_equal :shop_grant, ask(s, :buy, "SILPHSCOPE", 1, 5000, event: 8, seq: 5)[:type]
    assert_equal 450, money(lo)
    assert_equal :shop_grant, ask(s, :sell, "POTION", 1, 250, event: 8, seq: 6)[:type]
    assert_equal :shop_grant, ask(s, :sell, "POTION", 1, 150, event: 8, seq: 7)[:type]
    assert_equal 850, money(lo)
  end

  # An export from before the options: the one price the event sets, and the
  # catalogue's sell price.
  def test_an_older_export_keeps_its_rules
    start_server
    s, lo = player(bag: { POKEBALL: 1 })
    assert_equal "price", ask(s, :buy, "POKEBALL", 1, 200, event: 9)[:reason]
    assert_equal :shop_grant, ask(s, :buy, "POKEBALL", 1, 150, event: 9, seq: 2)[:type]
    assert_equal :shop_grant, ask(s, :sell, "POKEBALL", 1, 100, event: 9, seq: 3)[:type]
    assert_equal 950, money(lo)
  end

  # pbPokemonMart(stock, speech, true) offers no "I'm here to sell".
  def test_a_clerk_that_buys_nothing_back
    start_server
    s, lo = player(bag: { POTION: 1 })
    assert_equal "not_sellable", ask(s, :sell, "POTION", 1, 150, event: 10)[:reason]
    assert_equal :shop_grant, ask(s, :buy, "POTION", 1, 300, event: 10, seq: 2)[:type]
    assert_equal 700, money(lo)
  end

  # A client that sells and keeps the items (no new snapshot) cannot sell the same
  # record twice: the sale took them out of it with the money in.
  def test_the_same_items_cannot_be_sold_twice
    start_server
    s, lo = player(bag: { POTION: 2 })
    assert_equal :shop_grant, ask(s, :sell, "POTION", 2, 150)[:type]
    assert_equal "not_held", ask(s, :sell, "POTION", 2, 150, seq: 2)[:reason]
    assert_equal 1300, money(lo)
    assert_nil @db[:inventory_snapshots].where(account_id: lo[:account_id]).get(:bag).to_h["POTION"]
  end

  # A sale refused for another reason (a wrong price) leaves the record as it was.
  def test_a_refused_sale_keeps_the_items
    start_server
    s, lo = player(bag: { POTION: 2 })
    assert_equal "price", ask(s, :sell, "POTION", 2, 999)[:reason]
    assert_equal 2, @db[:inventory_snapshots].where(account_id: lo[:account_id]).get(:bag).to_h["POTION"]
  end

  # Money the ledger cannot take (past its cap) moves nothing, the items neither.
  def test_a_sale_the_ledger_refuses_keeps_the_items
    start_server
    s, lo = player(money: 999_900, bag: { POTION: 2 })
    assert_equal "money", ask(s, :sell, "POTION", 2, 150)[:reason]
    assert_equal 2, @db[:inventory_snapshots].where(account_id: lo[:account_id]).get(:bag).to_h["POTION"]
    assert_equal 999_900, money(lo)
  end

  def test_shadow_grants_and_moves_no_money
    start_server("shadow")
    s, lo = player
    r = ask(s, :buy, "MASTERBALL", 1, 0)
    assert_equal :shop_grant, r[:type]
    assert_nil r[:balance]
    assert_equal 1000, money(lo)
    assert(logs.any? { |l| l.include?("WOULD-DENY buy MASTERBALL") })
  end

  # The client keeps its own seqs: the server's own ledger rows never take one.
  def test_the_clients_next_money_frame_is_not_mistaken_for_a_replay
    start_server
    s, lo = player
    ask(s, :buy, "POTION", 1, 300)
    send_env(s, { type: :econ, field: :money, value: 700, seq: 2 })
    assert_equal :econ_ack, recv_type(s, :econ_ack, :econ_rej)[:type]
    assert_equal [-1, 1, 2], @db[:economy_ledger].where(account_id: lo[:account_id]).order(:seq).select_map(:seq)
    assert_equal 2, @db[:economy_balances].where(account_id: lo[:account_id], field: "money").get(:last_seq)
  end

  # The Battle Point exchange: the same, in BP.
  def test_a_bp_exchange_is_made_by_the_server
    start_server
    s, lo = bp_player
    assert_equal true, lo[:bp_shop_gate]
    r = bp_ask(s, "PROTEIN", 2, 16)
    assert_equal [:shop_grant, 18], [r[:type], r[:balance]]
    assert_equal [18, 1000], [bp(lo), money(lo)], "BP moved, no money"
    assert_equal 1, @db[:economy_ledger].where(account_id: lo[:account_id], reason: "bpshop:buy:PROTEINx2").count
    assert_equal "bp", bp_ask(s, "PROTEIN", 2, 16, seq: 2)[:reason], "18 BP buy one, not two"
  end

  def test_the_exchange_clerk_and_price_are_checked
    start_server
    s, = bp_player
    assert_equal "not_a_shop", bp_ask(s, "POTION", 1, 300, event: 5)[:reason], "a Mart is not the exchange"
    assert_equal "not_sold", bp_ask(s, "POTION", 1, 1, seq: 2)[:reason]
    assert_equal "price", bp_ask(s, "PROTEIN", 1, 1, seq: 3)[:reason]
    send_env(s, { type: :shop_req, op: :sell, item: "PROTEIN", quantity: 1, unit_price: 8, bp: true, map: 15,
                  event: 7, seq: 4 })
    assert_equal "bad", recv_type(s, :shop_grant, :shop_deny)[:reason], "the exchange buys nothing back"
  end
end
