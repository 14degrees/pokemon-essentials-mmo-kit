require "minitest/autorun"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk"
require "pemk/chain/relayer"
require "pemk/chain/reconciler"
require_relative "support/fake_chain"

# The audit: after the relayer catches up, the chain agrees with the registry, and
# every way it could stop agreeing is a named finding. In-flight rows are lag, not drift.
class ChainReconcilerTest < Minitest::Test
  MON_CAPS = { uid_req_max: 64, party_max: 6, level_max: 100, trade_max: 1 }.freeze

  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    %i[asset_events asset_tokens battle_records monster_transfers encounter_rolls monsters enforcement_events accounts].each { |t| @db[t].delete rescue nil }
    @a = @db[:accounts].insert(email: "a@t.co", password_hash: "x", status: "active", created_at: Time.now)
    @b = @db[:accounts].insert(email: "b@t.co", password_hash: "x", status: "active", created_at: Time.now)
    @log    = []
    @events = PEMK::AssetEvents.new(@db, mode: :on, species: %w[MEWTWO])
    @mon    = PEMK::Monsters.new(@db, MON_CAPS, assets: @events)
    @trades = PEMK::Trades.new(@db, assets: @events)
    @chain  = FakeChain.new
    @relay  = PEMK::Chain::Relayer.new(@events, adapter: @chain, mode: :on)
    @audit  = PEMK::Chain::Reconciler.new(@db, @chain, logger: ->(m) { @log << m })
  end

  def teardown
    %i[asset_events asset_tokens].each { |t| @db[t].delete rescue nil }
    @db&.disconnect
  end

  def mint(account, species, nonce)
    st, grants = @mon.mint_batch(account, [{ tmp: nonce, species: species, level: 5, pid: nonce, egg: false }])
    assert_equal :ack, st
    grants.first[:uid]
  end

  def whats(report) = report[:drift].map { |d| d[:what] }

  def test_a_relayed_registry_agrees_with_the_chain
    ua = mint(@a, "MEWTWO", 1)
    ub = mint(@b, "EEVEE", 2)
    @trades.execute_trade("t1", a: @a, b: @b, a_gives: [ua], b_gives: [ub])
    @db[:monsters].where(id: ua).update(status: "quarantined")   # as the verdict sweep does, with its receipt
    @events.freeze(ua, @b, reason: "walk_mismatch")
    @relay.pass
    r = @audit.run
    assert r[:ok], r[:drift].inspect
    assert_equal({ tokens: 1, checked: 1, in_flight: 0 }, r.slice(:tokens, :checked, :in_flight))
    assert_match(/audit ok - 1 token/, @log.last)
  end

  def test_in_flight_events_are_lag_not_drift
    mint(@a, "MEWTWO", 1)   # queued, not relayed
    r = @audit.run
    assert r[:ok]
    assert_equal({ tokens: 1, checked: 0, in_flight: 1 }, r.slice(:tokens, :checked, :in_flight))
  end

  def test_an_owner_moved_on_chain_alone_is_drift
    ua = mint(@a, "MEWTWO", 1)
    @relay.pass
    @chain.tokens[ua][:account] = @b       # somebody used the key
    r = @audit.run
    assert_equal ["owner"], whats(r)
    assert_equal({ registry: @a, chain: @b }, r[:drift][0].slice(:registry, :chain))
    assert_match(/DRIFT/, @log.join)
  end

  def test_a_freeze_the_chain_lost_is_drift
    ua = mint(@a, "MEWTWO", 1)
    @relay.pass
    @db[:monsters].where(id: ua).update(status: "quarantined")   # the registry's state, its receipt already relayed and then undone on chain
    @events.freeze(ua, @a, reason: "x")
    @relay.pass
    @chain.tokens[ua][:frozen] = false
    r = @audit.run
    assert_equal ["frozen"], whats(r)
  end

  def test_a_confirmed_mint_the_chain_does_not_hold_is_drift
    ua = mint(@a, "MEWTWO", 1)
    @relay.pass
    @chain.tokens.delete(ua)               # a reorg, a wrong contract, a wiped dev node
    r = @audit.run
    assert_equal ["not minted on chain", "supply"], whats(r)
    assert_match(/mint confirmed 0x/, r[:drift][0][:registry])
  end

  def test_a_registry_move_without_a_receipt_is_drift
    ua = mint(@a, "MEWTWO", 1)
    ub = mint(@b, "EEVEE", 2)
    @trades.execute_trade("t1", a: @a, b: @b, a_gives: [ua], b_gives: [ub])
    @relay.pass
    @db[:asset_events].where(kind: "transfer").delete   # the swap's receipt gone
    @chain.tokens[ua][:account] = @a                    # and the chain never learned of the move
    r = @audit.run
    assert_equal ["owner", "transfer without a receipt"], whats(r)
    assert_match(/trade t1/, r[:drift][1][:registry])
  end

  def test_tokens_on_chain_the_registry_never_issued_are_drift
    mint(@a, "MEWTWO", 1)
    @relay.pass
    @chain.mint(999, account: 5, kind: 0, species: "MEW", shiny: true, origin: "client")   # the key, used elsewhere
    r = @audit.run
    assert_equal ["supply"], whats(r)
    assert_equal({ registry: 1, chain: 2 }, r[:drift][0].slice(:registry, :chain))
  end
end
