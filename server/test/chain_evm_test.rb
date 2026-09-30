require "minitest/autorun"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk"
require "pemk/chain/relayer"

# Chain C1 against a REAL node: the outbox the registry wrote, relayed onto a freshly
# deployed PemkAssets by the same Relayer the daemon runs. Needs a local EVM node and
# the `eth` gem; skipped otherwise:
#   npx hardhat node            # or anvil
#   PEMK_CHAIN_RPC=http://127.0.0.1:8545 PEMK_CHAIN_KEY=<a funded key> rake test
class ChainEvmTest < Minitest::Test
  MON_CAPS = { uid_req_max: 64, party_max: 6, level_max: 100, trade_max: 1 }.freeze

  def setup
    skip "no node: set PEMK_CHAIN_RPC and PEMK_CHAIN_KEY" unless ENV["PEMK_CHAIN_RPC"] && ENV["PEMK_CHAIN_KEY"]
    begin
      require "pemk/chain/evm"
    rescue LoadError
      skip "the eth gem is not installed"
    end
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    %i[asset_events asset_tokens monster_transfers encounter_rolls monsters accounts].each { |t| @db[t].delete rescue nil }
    @a = @db[:accounts].insert(email: "a@t.co", password_hash: "x", status: "active", created_at: Time.now)
    @b = @db[:accounts].insert(email: "b@t.co", password_hash: "x", status: "active", created_at: Time.now)
    @events = PEMK::AssetEvents.new(@db, mode: :on, species: %w[MEWTWO])
    @rolls  = PEMK::EncounterRolls.new(@db)
    @mon    = PEMK::Monsters.new(@db, MON_CAPS, rolls: @rolls, assets: @events)
    @trades = PEMK::Trades.new(@db, assets: @events)
    address = PEMK::Chain::Evm.deploy(rpc: ENV["PEMK_CHAIN_RPC"], key: ENV["PEMK_CHAIN_KEY"])
    @chain  = PEMK::Chain::Evm.new(rpc: ENV["PEMK_CHAIN_RPC"], key: ENV["PEMK_CHAIN_KEY"], address: address)
    @log    = []
    @relay  = PEMK::Chain::Relayer.new(@events, adapter: @chain, mode: :on, logger: ->(m) { @log << m })
  end

  def teardown
    %i[asset_events asset_tokens].each { |t| @db[t].delete rescue nil }   # leave nothing for the other suites' account cleanup
    @db&.disconnect
  end

  def mint(account, species, nonce:, pid: nonce, shiny: false)
    if shiny
      @rolls.record(account, { "species" => species, "level" => 5, "pid" => pid, "iv" => [31] * 6, "shiny" => true }, 1, "Land")
      @rolls.mark_caught(account, species, 5, pid)
    end
    st, grants = @mon.mint_batch(account, [{ tmp: nonce, species: species, level: 5, pid: pid, egg: false }])
    assert_equal :ack, st
    grants.first[:uid]
  end

  def test_the_registry_s_receipts_land_on_the_contract_in_order
    ua = mint(@a, "PIKACHU", nonce: 1, pid: 77, shiny: true)
    ub = mint(@b, "EEVEE", nonce: 2)
    st, = @trades.execute_trade("t1", a: @a, b: @b, a_gives: [ua], b_gives: [ub])
    assert_equal :ok, st
    @events.freeze(ua, @b, reason: "walk_mismatch")

    t = @relay.pass
    assert_equal({ confirmed: 3, shadow: 0, failed: 0, waiting: 0 }, t, @log.join("\n"))
    assert @chain.minted?(ua)
    refute @chain.minted?(ub)                                   # a plain Eevee never reaches the chain
    assert_equal @b, @chain.account_of(ua)
    assert @chain.frozen?(ua)
    asset = @chain.asset_of(ua)
    assert_equal({ account: @b, kind: 0, shiny: true, frozen: true, species: "PIKACHU", origin: "wild_caught" }, asset)
    assert_equal @chain.operator.downcase, @chain.owner_of(ua).to_s.downcase   # held by the vault
    rows = @db[:asset_events].order(:id).all
    assert_equal %w[confirmed confirmed confirmed], rows.map { |r| r[:status] }
    assert rows.all? { |r| r[:tx_hash].start_with?("0x") }
    assert_equal rows[0][:tx_hash], @events.token(ua)[:mint_tx]

    # A second pass finds nothing; a re-queued mint is a no-op against the chain.
    assert_equal({ confirmed: 0, shadow: 0, failed: 0, waiting: 0 }, @relay.pass)
  end

  def test_the_contract_s_supply_cap_holds_against_the_relayer
    @chain.set_cap("MEWTWO", 1)
    u1 = mint(@a, "MEWTWO", nonce: 1)
    u2 = mint(@a, "MEWTWO", nonce: 2)
    t = @relay.pass
    assert_equal({ confirmed: 1, shadow: 0, failed: 1, waiting: 0 }, t)
    assert @chain.minted?(u1)
    refute @chain.minted?(u2)
    assert_equal [1, 1], @chain.supply_of("MEWTWO")
    failed = @db[:asset_events].where(status: "failed").first
    assert_equal u2, failed[:asset_id]
    assert_match(/reverted/, failed[:last_error])
  end
end
