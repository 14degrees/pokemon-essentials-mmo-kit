require "minitest/autorun"
require "sequel"
require "json"

lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "pemk/proof_checks"
require "pemk/trainer_proofs"

# Trainer proof P3 (docs/TRAINER-PROOF-DESIGN.md). The player's team in a trainer record
# must be the server's own Pokemon (ProofChecks); a prize claim naming its battle's seed
# gets the replay's verdict (TrainerProofs): proven, refuted or unprovable - and a proven
# win spends the placement's seed.
class TrainerProofsTest < Minitest::Test
  STATS = %w[HP ATTACK DEFENSE SPECIAL_ATTACK SPECIAL_DEFENSE SPEED].freeze
  LIAM  = ["CAMPER", "Liam", 0, 10, 4].freeze

  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))   # plain, as the replay tool's: jsonb as text
    @db[:battle_records].delete
    @db[:trainer_battles].delete
    @db[:money_claims].delete
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete
    @db[:enforcement_events].delete rescue nil
    @db[:accounts].delete
    @me    = account("me@t.co")
    @other = account("other@t.co")
    @proofs = PEMK::TrainerProofs.new(@db)
    @now = Time.now
  end

  def teardown
    @db&.disconnect
  end

  def account(email)
    @db[:accounts].insert(email: email, password_hash: "x", status: "active", created_at: Time.now)
  end

  def mon(owner, ivs: nil, exp: nil, status: "active", shiny: false)
    uid = @db[:monsters].insert(owner_account_id: owner, issuer_account_id: owner, client_nonce: rand(1 << 40),
                                species: "WARTORTLE", level_at_issue: 20, personal_id: 1, status: status)
    if ivs
      @db[:monster_blocks].insert(uid: uid, species: "WARTORTLE", level: 20, ivs: ivs.to_json, evs: "{}",
                                  moves: "[]", shiny: shiny, gender: 0)
    end
    @db[:monster_stats].insert(uid: uid, exp: exp, level: 20) if exp
    uid
  end

  def frame(uid, iv: 10, exp: 5000, shiny: false, gender: 0)
    { uid: uid, iv: STATS.to_h { |s| [s, iv] }, exp: exp, shiny: shiny, gender: gender }
  end

  def team(*frames) = { init: { player: frames } }

  def test_the_player_team_must_be_the_server_s
    ivs = STATS.to_h { |s| [s, 10] }
    ok  = mon(@me, ivs: ivs, exp: 6000)
    assert_equal [:ok, nil], PEMK::ProofChecks.player_team(@db, @me, team(frame(ok)))
    assert_equal :ok, PEMK::ProofChecks.player_team(@db, @me, team(frame(ok, iv: 31)))[0], "Hyper Training"
    {
      frame(mon(@other))                    => /not this account's/,
      frame(mon(@me, status: "quarantined")) => /quarantined, not active/,
      frame(ok, iv: 25)                     => /IV HP 25, locked at 10/,
      frame(ok, shiny: true)                => /shiny changed/,
      frame(ok, gender: 1)                  => /gender changed/,
      frame(ok, exp: 7000)                  => /EXP 7000, more than the 6000 the server has seen/
    }.each do |f, why|
      verdict, reason = PEMK::ProofChecks.player_team(@db, @me, team(frame(ok), f))
      assert_equal :refuted, verdict, reason
      assert_match why, reason
    end
    verdict, reason = PEMK::ProofChecks.player_team(@db, @me, team(frame(ok), { uid: nil, exp: 1 }))
    assert_equal [:unprovable, "player 1: a Pokemon the server has not registered yet"], [verdict, reason]
  end

  # --- claims and verdicts -----------------------------------------------------------

  def seed_row(account, trainer = LIAM, seed: rand(1 << 50) + 1)
    @db[:trainer_battles].insert(account_id: account, map_id: trainer[3], event_id: trainer[4], tr_type: trainer[0],
                                 tr_name: trainer[1], tr_version: trainer[2], seed: seed, issued_at: @now)
    [@db[:trainer_battles].where(seed: seed).get(:id), seed]
  end

  def claim(account, nonce, amount: 176, trainers: [LIAM], at: @now)
    @db[:money_claims].insert(account_id: account, nonce: nonce, kind: "trainer", verdict: "paid", mode: "shadow",
                              amount: amount, accepted: amount, map: 10, trainers: trainers.to_json, created_at: at)
  end

  def record(row, status:, outcome: 1, prize: 176, team: "ok", detail: nil)
    @db[:battle_records].insert(account_id: @me, mode: "on", record: Sequel.blob("x"), outcome: outcome,
                                replay_status: status, trainer_battle_id: row, replay_prize: prize,
                                team_check: team, replay_detail: detail, created_at: @now)
  end

  def verdict(nonce) = @db[:money_claims].where(account_id: @me, nonce: nonce).get(:proof)

  def test_a_claim_is_linked_only_to_its_own_battle
    row, seed = seed_row(@me)
    claim(@me, 1)
    assert_nil @proofs.link_claim(@me, 1, seed, [["CAMPER", "Liam", 0, 10, 3]]), "another event"
    assert_nil @proofs.link_claim(@me, 1, seed + 1, [LIAM]), "another seed"
    assert_nil @proofs.link_claim(@other, 1, seed, [LIAM]), "another account"
    assert_equal row, @proofs.link_claim(@me, 1, seed, [LIAM])
    assert_equal row, @db[:money_claims].where(nonce: 1).get(:trainer_battle_id)
  end

  def linked(nonce, row, seed, **kw)
    claim(@me, nonce, **kw)
    @proofs.link_claim(@me, nonce, seed, kw[:trainers] || [LIAM])
  end

  def test_a_proven_win_spends_the_seed
    row, seed = seed_row(@me)
    linked(1, row, seed)
    record(row, status: "walk_ok")
    assert_empty @proofs.sweep(now: @now), "not replayed yet: no verdict"
    @db[:battle_records].where(trainer_battle_id: row).update(replay_status: "match")
    assert_equal [[@me, 1, :proven, nil]], @proofs.sweep(now: @now)
    assert_equal "proven", verdict(1)
    assert_equal "proven", @db[:trainer_battles].where(id: row).get(:state)
  end

  def test_what_refutes_or_leaves_a_claim_unprovable
    cases = {
      { status: "walk_mismatch" }                      => [:refuted, /draws are not its seed's/],
      { status: "mismatch", detail: "round 2: AI" }     => [:refuted, /the replay disagrees: round 2: AI/],
      { status: "match", team: "refuted", detail: "x" } => [:refuted, /the player's team/],
      { status: "match", prize: 999 }                  => [:refuted, /claimed 176, the replay paid 999/],
      { status: "match", team: "unprovable" }          => [:unprovable, /the player's team/],
      { status: "error" }                              => [:unprovable, /could not be replayed/],
      { status: "match", prize: nil }                  => [:unprovable, /paid no prize/]
    }
    cases.each_with_index do |(rec, (want, why)), i|
      trainer = ["CAMPER", "Liam", 0, 10, 100 + i]          # one open seed per placement: one each
      row, seed = seed_row(@me, trainer)
      linked(i + 1, row, seed, trainers: [trainer])
      record(row, **rec)
      _, _, got, reason = @proofs.sweep(now: @now).find { |_, n, _, _| n == i + 1 }
      assert_equal want, got, rec.inspect
      assert_match why, reason
      assert_equal "open", @db[:trainer_battles].where(id: row).get(:state), "only a proven win spends the seed"
    end
  end

  def test_a_claim_waits_for_its_record_then_is_unprovable
    row, seed = seed_row(@me)
    linked(1, row, seed, at: @now - 60)
    record(row, status: "match", outcome: 2)             # a lost battle proves no prize
    assert_empty @proofs.sweep(now: @now)
    assert_equal [[@me, 1, :unprovable, "no record of a won battle on its seed"]], @proofs.sweep(now: @now + 700)
  end

  def test_one_record_proves_one_claim
    row, seed = seed_row(@me)
    linked(1, row, seed)
    linked(2, row, seed)
    record(row, status: "match")
    judged = @proofs.sweep(now: @now)
    assert_equal [[@me, 1, :proven, nil]], judged, "the second claim finds no record left"
    assert_nil verdict(2)
    assert_equal [[@me, 2, :unprovable, "no record of a won battle on its seed"]], @proofs.sweep(now: @now + 700)
  end
end
