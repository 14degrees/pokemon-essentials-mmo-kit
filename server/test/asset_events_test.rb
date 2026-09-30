require "minitest/autorun"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk"

# Chain C1 - the asset outbox: which Pokemon the policy tokenizes, and that every mint,
# swap and quarantine of one leaves its receipt in the SAME transaction as the registry
# write (a rolled-back swap leaves none).
class AssetEventsTest < Minitest::Test
  MON_CAPS = { uid_req_max: 64, party_max: 6, level_max: 100, trade_max: 1 }.freeze

  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    %i[asset_events asset_tokens battle_records monster_transfers encounter_rolls monsters enforcement_events accounts].each do |t|
      @db[t].delete rescue nil
    end
    @a = @db[:accounts].insert(email: "a@t.co", password_hash: "x", status: "active", created_at: Time.now)
    @b = @db[:accounts].insert(email: "b@t.co", password_hash: "x", status: "active", created_at: Time.now)
    @log    = []
    @assets = PEMK::AssetEvents.new(@db, mode: :on, species: %w[mewtwo], shiny: true, logger: ->(m) { @log << m })
    @rolls  = PEMK::EncounterRolls.new(@db)
    @mon    = PEMK::Monsters.new(@db, MON_CAPS, rolls: @rolls, assets: @assets)
    @trades = PEMK::Trades.new(@db, assets: @assets)
  end

  def teardown
    %i[asset_events asset_tokens].each { |t| @db[t].delete rescue nil }   # leave nothing for the other suites' account cleanup
    @db&.disconnect
  end

  # A server-minted encounter, caught (the D3 verdict), the roll the uid mint claims.
  def roll(account, species, pid, shiny:, caught: true)
    id = @rolls.record(account, { "species" => species, "level" => 5, "pid" => pid, "iv" => [31] * 6, "shiny" => shiny }, 1, "Land")
    @rolls.mark_caught(account, species, 5, pid) if caught
    id
  end

  def mint(account, species, nonce:, pid: nonce)
    st, grants = @mon.mint_batch(account, [{ tmp: nonce, species: species, level: 5, pid: pid, egg: false }])
    assert_equal :ack, st
    grants.first[:uid]
  end

  def events(uid = nil)
    ds = @db[:asset_events].order(:id)
    ds = ds.where(asset_id: uid) if uid
    ds.all
  end

  # --- the policy ---

  def test_a_server_caught_shiny_is_tokenized_with_its_mint_receipt
    roll(@a, "PIKACHU", 77, shiny: true)
    uid = mint(@a, "PIKACHU", nonce: 1, pid: 77)
    t = @assets.token(uid)
    refute_nil t
    assert_equal({ reason: "shiny", origin: "wild_caught", shiny: true, token_id: uid }, t.slice(:reason, :origin, :shiny, :token_id))
    ev = events(uid)
    assert_equal ["mint"], ev.map { |e| e[:kind] }
    assert_equal [nil, @a, "pending"], [ev[0][:from_account_id], ev[0][:to_account_id], ev[0][:status]]
    assert_equal({ "species" => "PIKACHU", "origin" => "wild_caught", "shiny" => true, "reason" => "shiny" }, ev[0][:payload].to_h)
    assert_match(/tokenized \(shiny, wild_caught\)/, @log.join("\n"))
  end

  def test_a_shiny_the_client_claims_is_not
    uid = mint(@a, "PIKACHU", nonce: 1)          # no roll: origin client, nothing proves shiny
    assert_nil @assets.token(uid)
    assert_empty events
  end

  def test_a_server_minted_shiny_that_fled_is_not
    roll(@a, "PIKACHU", 77, shiny: true, caught: false)   # origin wild, no catch verdict
    uid = mint(@a, "PIKACHU", nonce: 1, pid: 77)
    assert_equal "wild", @db[:monsters].where(id: uid).get(:origin)
    assert_nil @assets.token(uid)
  end

  def test_a_listed_species_is_tokenized_from_any_origin_and_says_so
    uid = mint(@a, "MEWTWO", nonce: 1)
    t = @assets.token(uid)
    assert_equal({ reason: "species", origin: "client", shiny: false }, t.slice(:reason, :origin, :shiny))
    assert_equal "client", events(uid)[0][:payload]["origin"]
  end

  def test_shiny_policy_can_be_turned_off
    assets = PEMK::AssetEvents.new(@db, mode: :on, species: [], shiny: false)
    mon = PEMK::Monsters.new(@db, MON_CAPS, rolls: @rolls, assets: assets)
    roll(@a, "PIKACHU", 77, shiny: true)
    st, grants = mon.mint_batch(@a, [{ tmp: 1, species: "PIKACHU", level: 5, pid: 77, egg: false }])
    assert_equal :ack, st
    assert_nil assets.token(grants.first[:uid])
  end

  def test_a_replayed_mint_writes_one_token_and_one_receipt
    roll(@a, "PIKACHU", 77, shiny: true)
    uid  = mint(@a, "PIKACHU", nonce: 1, pid: 77)
    uid2 = mint(@a, "PIKACHU", nonce: 1, pid: 77)   # the same nonce: a lost grant, re-sent
    assert_equal uid, uid2
    assert_equal 1, @db[:asset_tokens].count
    assert_equal 1, events.size
  end

  def test_without_the_outbox_nothing_is_written
    mon = PEMK::Monsters.new(@db, MON_CAPS, rolls: @rolls)   # PEMK_CHAIN=off: no collaborator
    roll(@a, "PIKACHU", 77, shiny: true)
    mon.mint_batch(@a, [{ tmp: 1, species: "PIKACHU", level: 5, pid: 77, egg: false }])
    assert_equal 0, @db[:asset_tokens].count
    assert_equal 0, @db[:asset_events].count
  end

  # --- the swap ---

  def test_a_committed_trade_queues_a_transfer_for_the_tokenized_side_only
    roll(@a, "PIKACHU", 77, shiny: true)
    ua = mint(@a, "PIKACHU", nonce: 1, pid: 77)
    ub = mint(@b, "EEVEE", nonce: 2)
    st, = @trades.execute_trade("t1", a: @a, b: @b, a_gives: [ua], b_gives: [ub])
    assert_equal :ok, st
    xfer = events.select { |e| e[:kind] == "transfer" }
    assert_equal 1, xfer.size
    assert_equal({ asset_id: ua, from_account_id: @a, to_account_id: @b, ref: "t1" },
                 xfer[0].slice(:asset_id, :from_account_id, :to_account_id, :ref))
  end

  def test_an_aborted_trade_queues_nothing
    roll(@a, "PIKACHU", 77, shiny: true)
    ua = mint(@a, "PIKACHU", nonce: 1, pid: 77)
    ub = mint(@b, "EEVEE", nonce: 2)
    st, = @trades.execute_trade("t2", a: @a, b: @b, a_gives: [ub], b_gives: [ua])   # neither owns what it gives
    assert_equal :abort, st
    assert_equal ["mint"], events.map { |e| e[:kind] }
  end

  def test_a_replayed_trade_queues_no_second_transfer
    roll(@a, "PIKACHU", 77, shiny: true)
    ua = mint(@a, "PIKACHU", nonce: 1, pid: 77)
    ub = mint(@b, "EEVEE", nonce: 2)
    @trades.execute_trade("t3", a: @a, b: @b, a_gives: [ua], b_gives: [ub])
    st, = @trades.execute_trade("t3", a: @a, b: @b, a_gives: [ua], b_gives: [ub])
    assert_equal :ok_replay, st
    assert_equal 1, events.count { |e| e[:kind] == "transfer" }
  end

  # --- quarantine ---

  def test_freeze_and_unfreeze_follow_a_tokenized_uid_only
    roll(@a, "PIKACHU", 77, shiny: true)
    ua = mint(@a, "PIKACHU", nonce: 1, pid: 77)
    ub = mint(@a, "EEVEE", nonce: 2)
    assert @assets.freeze(ua, @a, reason: "walk_mismatch")
    refute @assets.freeze(ub, @a, reason: "walk_mismatch")
    assert @assets.unfreeze(ua, @a, reason: "operator pardon")
    assert_equal %w[mint freeze unfreeze], events(ua).map { |e| e[:kind] }
    assert_equal %w[walk_mismatch operator\ pardon], events(ua).last(2).map { |e| e[:ref] }
  end

  # --- backfill ---

  def test_backfill_takes_earlier_pokemon_by_the_same_policy
    plain = PEMK::Monsters.new(@db, MON_CAPS, rolls: @rolls)   # minted before the chain was on
    roll(@a, "PIKACHU", 77, shiny: true)
    roll(@a, "RATTATA", 78, shiny: false)
    plain.mint_batch(@a, [{ tmp: 1, species: "PIKACHU", level: 5, pid: 77, egg: false },
                          { tmp: 2, species: "RATTATA", level: 5, pid: 78, egg: false },
                          { tmp: 3, species: "MEWTWO", level: 70, pid: 79, egg: false }])
    assert_equal 0, @db[:asset_tokens].count
    assert_equal 2, @assets.backfill
    assert_equal %w[MEWTWO PIKACHU], @db[:asset_tokens].select_order_map(:species)
    assert_equal 0, @assets.backfill   # a second run finds nothing new
  end

  # --- the relayer's stamps ---

  def test_stamps_move_a_row_through_its_states
    uid = mint(@a, "MEWTWO", nonce: 1)
    id  = events(uid)[0][:id]
    assert_equal 1, @assets.pending.size
    @assets.mark_failed(id, "boom")
    row = @db[:asset_events][id: id]
    assert_equal ["failed", 1, "boom"], [row[:status], row[:attempts], row[:last_error]]
    assert_equal 1, @assets.pending.size                      # a failed row is retried in its place
    @assets.mark_confirmed(id, "0xabc")
    row = @db[:asset_events][id: id]
    assert_equal ["confirmed", "0xabc", 2, nil], [row[:status], row[:tx_hash], row[:attempts], row[:last_error]]
    assert_equal "0xabc", @assets.token(uid)[:mint_tx]        # a confirmed mint stamps its token
    assert_empty @assets.pending
    assert_equal({ "confirmed" => 1 }, @assets.counts)
  end
end
