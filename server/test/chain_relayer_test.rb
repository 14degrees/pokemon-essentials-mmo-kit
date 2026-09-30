require "minitest/autorun"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk"
require "pemk/chain/relayer"
require_relative "support/fake_chain"

# Chain C1 - the relayer: drains the outbox in order, idempotent against the chain's
# state, stops on a failure and retries it after a backoff. The chain is a double here;
# chain_evm_test.rb runs the same relayer against a real node.
class ChainRelayerTest < Minitest::Test
  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    %i[asset_events asset_tokens battle_records monster_transfers encounter_rolls monsters enforcement_events accounts].each { |t| @db[t].delete rescue nil }
    @a = @db[:accounts].insert(email: "a@t.co", password_hash: "x", status: "active", created_at: Time.now)
    @b = @db[:accounts].insert(email: "b@t.co", password_hash: "x", status: "active", created_at: Time.now)
    @log    = []
    @events = PEMK::AssetEvents.new(@db, mode: :on, species: %w[MEWTWO])
    @chain  = FakeChain.new
    @relay  = PEMK::Chain::Relayer.new(@events, adapter: @chain, mode: :on, logger: ->(m) { @log << m })
  end

  def teardown
    %i[asset_events asset_tokens].each { |t| @db[t].delete rescue nil }   # leave nothing for the other suites' account cleanup
    @db&.disconnect
  end

  def mon(owner, species, nonce)
    uid = @db[:monsters].insert(owner_account_id: owner, issuer_account_id: owner, client_nonce: nonce,
                                species: species, level_at_issue: 5, personal_id: nonce, egg_at_issue: false, origin: "client")
    @assets_reason = @events.tokenize(uid, owner, species: species, origin: "client", shiny: false)
    uid
  end

  def statuses
    @db[:asset_events].order(:id).select_map(:status)
  end

  def test_a_pass_mints_moves_and_freezes_in_order
    uid = mon(@a, "MEWTWO", 1)
    @events.transfer(uid, from: @a, to: @b, ref: "t1")
    @events.freeze(uid, @b, reason: "walk_mismatch")
    t = @relay.pass
    assert_equal({ confirmed: 3, shadow: 0, failed: 0, waiting: 0 }, t)
    assert_equal [[:mint, uid], [:move, uid], [:freeze, uid]], @chain.calls
    assert_equal({ account: @b, frozen: true, species: "MEWTWO" }, @chain.tokens[uid].slice(:account, :frozen, :species))
    assert_equal %w[confirmed confirmed confirmed], statuses
    assert_equal "0xmint#{uid}1", @events.token(uid)[:mint_tx]
  end

  def test_the_chain_state_makes_a_replay_a_no_op
    uid = mon(@a, "MEWTWO", 1)
    @chain.mint(uid, account: @a, kind: 0, species: "MEWTWO", shiny: false, origin: "client")   # already there (a crash after the tx)
    @chain.calls.clear
    @relay.pass
    assert_empty @chain.calls
    assert_equal ["confirmed"], statuses
    assert_equal "(already on chain)", @db[:asset_events].first[:tx_hash]
  end

  def test_a_failure_stops_the_pass_and_is_retried_after_its_backoff
    u1 = mon(@a, "MEWTWO", 1)
    u2 = mon(@a, "MEWTWO", 2)
    @chain.fail_next!("node down")
    t0 = Time.now
    assert_equal({ confirmed: 0, shadow: 0, failed: 1, waiting: 0 }, @relay.pass(now: t0))
    assert_equal %w[failed pending], statuses
    assert_match(/node down/, @db[:asset_events].order(:id).first[:last_error])
    assert_equal({ confirmed: 0, shadow: 0, failed: 0, waiting: 1 }, @relay.pass(now: t0 + 1))   # too soon: nothing moves
    assert_equal %w[failed pending], statuses
    assert_equal({ confirmed: 2, shadow: 0, failed: 0, waiting: 0 }, @relay.pass(now: t0 + 11))  # after 10 s: both, in order
    assert_equal [[:mint, u1], [:mint, u2]], @chain.calls
    assert_equal 2, @db[:asset_events].order(:id).first[:attempts]
  end

  def test_a_transfer_ahead_of_its_mint_is_out_of_order_not_applied
    uid = mon(@a, "MEWTWO", 1)
    @events.transfer(uid, from: @a, to: @b, ref: "t1")
    @db[:asset_events].where(kind: "mint").delete   # the mint row lost: nothing may move
    t = @relay.pass
    assert_equal 1, t[:failed]
    assert_match(/OutOfOrder/, @db[:asset_events].first[:last_error])
    assert_empty @chain.calls
  end

  def test_shadow_stamps_without_a_chain
    relay = PEMK::Chain::Relayer.new(@events, mode: :shadow, logger: ->(m) { @log << m })
    mon(@a, "MEWTWO", 1)
    assert_equal({ confirmed: 0, shadow: 1, failed: 0, waiting: 0 }, relay.pass)
    assert_equal ["shadow"], statuses
    assert_empty @chain.calls
    assert_match(/mint token .* \(shadow\)/, @log.join)
  end

  def test_on_without_an_adapter_is_refused
    assert_raises(ArgumentError) { PEMK::Chain::Relayer.new(@events, mode: :on) }
  end
end
