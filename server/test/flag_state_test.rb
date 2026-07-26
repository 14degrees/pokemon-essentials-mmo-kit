require "minitest/autorun"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk"

# Audit item 4: the switches/variables/self-switches DETECTION shadow. The server
# records the absolute snapshot and flags a self-switch REWIND (one-shot events
# re-armed = the NPC-gift/TM/key-item re-farm). It never rejects, and it must not
# flag the things that legitimately move backwards (temp switches, countdowns).
class FlagStateTest < Minitest::Test
  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    @db[:flag_snapshots].delete rescue nil
    @db[:progression_facts].delete rescue nil
    # dependents first: monsters/rolls hold FKs to accounts (no cascade — audit rows
    # deliberately survive account deletion), so a bare accounts.delete would fail.
    @db[:enforcement_events].delete rescue nil
    @db[:battle_records].delete rescue nil
    @db[:encounter_rolls].delete rescue nil
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete rescue nil
    @db[:accounts].delete
    @a = @db[:accounts].insert(email: "fl-a@x.co", password_hash: "x", status: "active", created_at: Time.now)
    @logs = []
    # the trust gate judges only POLICY-OWNED ids; 77 is deliberately absent (local)
    @fs = PEMK::FlagState.new(@db, policy: { switches: [1, 2, 3, 4, 9], variables: [4, 7, 10] },
                              facts: { 4 => "sw:defeated_gym_1", 9 => "sw:visited_island" },
                              logger: ->(m) { @logs << m })
  end

  def teardown
    @db&.disconnect
  end

  def snap(switches: [], variables: {}, self_switches: [])
    { switches: switches, variables: variables, self_switches: self_switches }
  end

  def test_records_an_absolute_snapshot
    status, flags = @fs.apply_flags(@a, snap(switches: [3, 1], variables: { "10" => 5 },
                                             self_switches: ["5:2:A"]), 1)
    assert_equal :ack, status
    assert_empty flags
    row = @fs.snapshot(@a)
    assert_equal [1, 3], row[:switches].to_a          # normalized: unique + sorted
    assert_equal({ "10" => 5 }, row[:variables].to_h)
    assert_equal ["5:2:A"], row[:self_switches].to_a
    assert_equal 1, row[:last_seq]
  end

  def test_stale_snapshot_is_a_dup_and_never_overwrites
    @fs.apply_flags(@a, snap(switches: [1, 2, 3]), 5)
    status, = @fs.apply_flags(@a, snap(switches: []), 4)   # replayed older
    assert_equal :dup, status
    assert_equal [1, 2, 3], @fs.snapshot(@a)[:switches].to_a
  end

  # THE signal: a batch of one-shot markers going OFF is a save rollback.
  def test_self_switch_rewind_is_flagged
    @fs.apply_flags(@a, snap(self_switches: ["1:1:A", "1:2:A", "2:7:A", "3:1:A"]), 1)
    status, flags = @fs.apply_flags(@a, snap(self_switches: ["1:1:A"]), 2)   # 3 cleared
    assert_equal :ack, status
    assert_includes flags, "rewind"
    assert @fs.snapshot(@a)[:flagged]
    assert(@logs.any? { |l| l.include?("SUSPECT rewind") }, @logs.inspect)
  end

  def test_a_single_cleared_self_switch_is_tolerated
    @fs.apply_flags(@a, snap(self_switches: ["1:1:A", "1:2:A"]), 1)
    _, flags = @fs.apply_flags(@a, snap(self_switches: ["1:1:A"]), 2)   # 1 cleared
    assert_empty flags, "one deliberate reset must not open a report"
  end

  # Switches turning off and counters decreasing happen constantly in honest play
  # (temp flags, countdowns, event resets) — recorded, never judged.
  def test_switch_off_and_variable_decrease_are_recorded_not_flagged
    @fs.apply_flags(@a, snap(switches: [1, 2, 3], variables: { "4" => 100 }), 1)
    _, flags = @fs.apply_flags(@a, snap(switches: [1], variables: { "4" => 2 }), 2)
    assert_empty flags
    refute @fs.snapshot(@a)[:flagged]
    assert(@logs.any? { |l| l.include?("regression") }, @logs.inspect)
  end

  # A snapshot over the cap is stored but marked, and — the subtle half — the NEXT
  # snapshot can't be judged against it either: entries the truncated one had to drop
  # would read as cleared and fake a rewind. It just re-establishes a clean baseline.
  def test_a_truncated_snapshot_is_never_judged_in_either_direction
    big = (1..(PEMK::FlagState::MAX_ENTRIES + 1)).map { |i| "1:#{i}:A" }
    _, flags = @fs.apply_flags(@a, snap(self_switches: big), 1)
    assert_equal ["truncated"], flags
    assert @fs.snapshot(@a)[:truncated]

    _, flags = @fs.apply_flags(@a, snap(self_switches: []), 2)   # would look like a huge rewind
    assert_equal ["truncated"], flags                            # not judged against a bad baseline
    refute @fs.snapshot(@a)[:truncated], "the fresh full snapshot becomes a clean baseline"

    # ...and from that clean baseline, detection works again
    @fs.apply_flags(@a, snap(self_switches: ["1:1:A", "1:2:A", "1:3:A"]), 3)
    _, flags = @fs.apply_flags(@a, snap(self_switches: []), 4)
    assert_includes flags, "rewind"
  end

  def test_hostile_shapes_are_rejected
    assert_equal :rej, @fs.apply_flags(@a, snap(switches: [99_999]), 1).first        # out of range
    assert_equal :rej, @fs.apply_flags(@a, snap(switches: ["x"]), 1).first           # wrong type
    assert_equal :rej, @fs.apply_flags(@a, snap(variables: { "abc" => 1 }), 1).first # bad key
    assert_equal :rej, @fs.apply_flags(@a, "nope", 1).first                          # not a hash
    assert_equal 0, @db[:flag_snapshots].count
  end

  # THE RECONNECT BUG: Sync.reset zeroes every channel seq on a new socket, and the
  # server treats seq <= last_seq as a dup — so without the server advertising its
  # high-water (flags_seq) and the client adopting it, the channel goes permanently
  # silent after the first reconnect. This test pins the server half of that contract.
  def test_snapshot_exposes_last_seq_so_a_reconnect_can_resume
    @fs.apply_flags(@a, snap(switches: [1]), 7)
    assert_equal 7, @fs.snapshot(@a)[:last_seq]

    # a reconnect restarting at 1 WOULD be dropped as stale...
    assert_equal :dup, @fs.apply_flags(@a, snap(switches: [1, 2]), 1).first
    # ...which is exactly why the client must resume above the advertised high-water
    assert_equal :ack, @fs.apply_flags(@a, snap(switches: [1, 2]), 8).first
    assert_equal [1, 2], @fs.snapshot(@a)[:switches].to_a
  end

  def test_non_integer_variables_are_dropped_not_rejected
    status, = @fs.apply_flags(@a, snap(variables: { "3" => "quest", "4" => 7 }), 1)
    assert_equal :ack, status
    assert_equal({ "4" => 7 }, @fs.snapshot(@a)[:variables].to_h)
  end
  # === step 3: THE TRUST GATE =================================================
  # The client sends every intercepted write as a delta; the server folds them into
  # a mirror and, when the next ABSOLUTE snapshot lands, checks the two agree. That
  # agreement is the proof the interception is complete — the precondition for ever
  # giving the server authority. Divergence is reported, never enforced.

  def delta(switches: {}, variables: {}, self_switches: {}, overflow: false)
    { switches: switches, variables: variables, self_switches: self_switches, overflow: overflow }
  end

  def test_a_complete_delta_stream_reconstructs_the_snapshot
    @fs.apply_flags(@a, snap(switches: [1], self_switches: ["5:2:A"]), 1)   # baseline
    # the player plays: two switches on, a self-switch set, a counter moved
    @fs.apply_delta(@a, delta(switches: { "4" => true, "9" => true },
                              self_switches: { "5:3:A" => true },
                              variables: { "7" => 12 }))
    # the client's own absolute snapshot agrees with what the deltas said
    _, = @fs.apply_flags(@a, snap(switches: [1, 4, 9], self_switches: ["5:2:A", "5:3:A"],
                                  variables: { "7" => 12 }), 2)
    row = @fs.snapshot(@a)
    assert_nil row[:drift], "a complete stream must show no drift"
    refute(@logs.any? { |l| l.include?("DELTA DRIFT") }, @logs.inspect)
  end

  # THE failure this gate exists to catch: a write the interception MISSED.
  def test_a_missed_write_shows_up_as_drift
    @fs.apply_flags(@a, snap(switches: [1]), 1)
    @fs.apply_delta(@a, delta(switches: { "4" => true }))
    # ...but the truth also contains switch 9, which no delta ever reported
    @fs.apply_flags(@a, snap(switches: [1, 4, 9]), 2)
    refute_nil @fs.snapshot(@a)[:drift]
    assert(@logs.any? { |l| l.include?("DELTA DRIFT") }, @logs.inspect)
  end

  def test_a_variable_the_deltas_got_wrong_is_named_in_the_drift
    @fs.apply_flags(@a, snap(variables: { "7" => 1 }), 1)
    @fs.apply_delta(@a, delta(variables: { "7" => 5 }))
    @fs.apply_flags(@a, snap(variables: { "7" => 9 }), 2)   # truth says 9, mirror said 5
    assert_match(/var 7 mirror=5 snapshot=9/, @fs.snapshot(@a)[:drift])
  end

  # An overflowed delta means WE know the mirror is incomplete — comparing then would
  # report our own gap as the client's divergence.
  def test_an_overflowed_delta_suspends_the_comparison
    @fs.apply_flags(@a, snap(switches: [1]), 1)
    @fs.apply_delta(@a, delta(overflow: true))
    refute @fs.snapshot(@a)[:mirror_valid]
    @fs.apply_flags(@a, snap(switches: [1, 2, 3, 4]), 2)   # would look like 3 missed writes
    assert_nil @fs.snapshot(@a)[:drift], "an invalid mirror must not accuse the client"
    assert @fs.snapshot(@a)[:mirror_valid], "...and the snapshot re-establishes it"
  end

  # An id the policy calls LOCAL never appears in the delta stream, and must not be
  # mistaken for a missed write.
  def test_ids_the_mirror_never_heard_of_are_not_counted_as_missing
    @fs.apply_flags(@a, snap(switches: [1]), 1)
    @fs.apply_delta(@a, delta(switches: { "4" => true }))
    # switch 77 is local: it is in the truth but was never deltaed, and never known
    @fs.apply_flags(@a, snap(switches: [1, 4, 77]), 2)
    assert_nil @fs.snapshot(@a)[:drift]
  end

  def test_a_delta_before_any_snapshot_is_ignored
    assert_equal :bad, @fs.apply_delta(@a, delta(switches: { "4" => true })).first
  end

  # The mirror must mean "the state the server OWNS", not "everything it has seen".
  # The snapshot is deliberately unfiltered (rewind detection needs the whole
  # picture), so without filtering the seed the mirror silently re-acquires local ids
  # the delta stream never sends — harmless for the comparison, but it makes the
  # mirror lie about its own scope right before it becomes the basis of authority.
  def test_the_mirror_only_holds_policy_owned_state
    @fs.apply_flags(@a, snap(switches: [1, 77], variables: { "7" => 3, "99" => 5 },
                             self_switches: ["5:2:A"]), 1)
    m = @fs.snapshot(@a)[:mirror].to_h
    assert_equal true, m["sw/1"]                 # owned
    assert_nil m["sw/77"], "a local switch must not enter the mirror"
    assert_equal 3, m["var/7"]                   # owned
    assert_nil m["var/99"], "a local variable must not enter the mirror"
    assert_equal true, m["ss/5:2:A"]             # self-switches are wholly owned
  end

  # === step 4: the grant-only progression ledger ==============================

  def test_facts_are_granted_from_a_snapshot_and_survive_a_rollback
    @fs.apply_flags(@a, snap(switches: [4, 9], self_switches: ["5:2:A"]), 1)
    @fs.commit_facts(@a)
    f = @fs.facts_for(@a)
    assert_equal [4, 9], f[:switches]
    assert_equal ["5:2:A"], f[:self_switches]

    # the client rolls its save back: the snapshot no longer carries any of it
    @fs.apply_flags(@a, snap(switches: [], self_switches: []), 2)
    f = @fs.facts_for(@a)
    assert_equal [4, 9], f[:switches], "a fact is grant-only - a rollback cannot take it back"
    assert_equal ["5:2:A"], f[:self_switches]
  end

  def test_only_fact_tier_switches_become_facts
    @fs.apply_flags(@a, snap(switches: [1, 2, 3, 4]), 1)   # 1,2,3 are mirror-tier
    @fs.commit_facts(@a)
    assert_equal [4], @fs.facts_for(@a)[:switches]
  end

  def test_granting_is_idempotent
    3.times { |i| @fs.apply_flags(@a, snap(switches: [4], self_switches: ["5:2:A"]), i + 1) }
    assert_equal 2, @db[:progression_facts].where(account_id: @a).count
  end

  # Keys are name-derived so a compiler renumber does not lose progression: the fact
  # stored under "sw:defeated_gym_1" resolves to whatever id now carries that name.
  def test_a_renumbered_switch_still_resolves_to_its_fact
    @fs.apply_flags(@a, snap(switches: [4]), 1)
    @fs.commit_facts(@a)
    renumbered = PEMK::FlagState.new(@db, policy: { switches: [88] },
                                     facts: { 88 => "sw:defeated_gym_1" })
    assert_equal [88], renumbered.facts_for(@a)[:switches]
  end

  def test_a_fact_whose_name_vanished_is_dropped_not_guessed
    @fs.apply_flags(@a, snap(switches: [4]), 1)
    gone = PEMK::FlagState.new(@db, policy: { switches: [] }, facts: {})
    assert_empty gone.facts_for(@a)[:switches]
  end

  def test_an_operator_revoked_fact_is_not_sent
    @fs.apply_flags(@a, snap(switches: [4]), 1)
    @fs.commit_facts(@a)
    @db[:progression_facts].where(account_id: @a).update(revoked_at: Time.now)
    assert_empty @fs.facts_for(@a)[:switches]
  end

  # The restore writes into the client with delta recording suppressed, so the mirror
  # must be told what we sent - otherwise the next snapshot reports our own restore as
  # missed writes. The trust gate caught this in a live session.
  def test_materializing_facts_folds_them_into_the_mirror
    @fs.apply_flags(@a, snap(switches: [4], self_switches: ["5:2:A"]), 1)
    @fs.commit_facts(@a)
    # the player reloads an older save that lost the self-switch
    @fs.apply_flags(@a, snap(switches: [4], self_switches: []), 2)

    f = @fs.materialize_facts(@a)
    assert_includes f[:self_switches], "5:2:A"
    assert_equal true, @fs.snapshot(@a)[:mirror].to_h["ss/5:2:A"], "the mirror must know what we restored"

    # the client applies it and reports the restored state: no drift
    @fs.apply_flags(@a, snap(switches: [4], self_switches: ["5:2:A"]), 3)
    assert_nil @fs.snapshot(@a)[:drift]
  end

  def test_materialize_is_a_no_op_without_facts
    @fs.apply_flags(@a, snap(switches: [1]), 1)   # mirror-tier, never a fact
    f = @fs.materialize_facts(@a)
    assert_empty f[:switches]
    assert_empty f[:self_switches]
  end

  # === fact durability is bound to the client's save commit ===================
  # Granting on the snapshot alone restored a switch onto a save that never got what
  # the event granted beside it - the gym flag came back, the badge did not.

  def test_a_fact_is_pending_until_the_client_saves
    @fs.apply_flags(@a, snap(switches: [4], self_switches: ["5:2:A"]), 1)
    assert_equal 2, @db[:progression_facts].where(account_id: @a).count, "granted..."
    assert_empty @fs.facts_for(@a)[:switches], "...but not handed back before a save"
    assert_empty @fs.facts_for(@a)[:self_switches]

    @fs.commit_facts(@a, 1)
    assert_equal [4], @fs.facts_for(@a)[:switches]
    assert_equal ["5:2:A"], @fs.facts_for(@a)[:self_switches]
  end

  def test_the_watermark_holds_back_facts_the_blob_predates
    @fs.apply_flags(@a, snap(switches: [4]), 1)
    @fs.apply_flags(@a, snap(switches: [4, 9]), 2)

    @fs.commit_facts(@a, 1)   # the blob was serialized at flags seq 1
    assert_equal [4], @fs.facts_for(@a)[:switches], "switch 9 is not in that save yet"

    @fs.commit_facts(@a, 2)
    assert_equal [4, 9], @fs.facts_for(@a)[:switches]
  end

  # A pre-020 client sends no watermark. Withholding its facts forever is worse than
  # the window this bounds, so a missing seq promotes everything pending.
  def test_a_client_without_a_watermark_promotes_everything
    @fs.apply_flags(@a, snap(switches: [4, 9]), 1)
    @fs.commit_facts(@a, nil)
    assert_equal [4, 9], @fs.facts_for(@a)[:switches]
  end

  def test_committing_twice_does_not_move_the_durability_stamp
    @fs.apply_flags(@a, snap(switches: [4]), 1)
    @fs.commit_facts(@a, 1)
    first = @db[:progression_facts].where(account_id: @a).get(:durable_at)
    assert_equal 0, @fs.commit_facts(@a, 1), "already durable - nothing left to promote"
    assert_equal first, @db[:progression_facts].where(account_id: @a).get(:durable_at)
  end

  # The restore only ever writes state the client provably had on disk, so a pending
  # fact must not reach the mirror either.
  def test_materialize_ignores_pending_facts
    @fs.apply_flags(@a, snap(switches: [4], self_switches: ["5:2:A"]), 1)
    @fs.apply_flags(@a, snap(switches: [], self_switches: []), 2)   # rolled back, never saved

    f = @fs.materialize_facts(@a)
    assert_empty f[:switches]
    assert_empty f[:self_switches]
    assert_nil @fs.snapshot(@a)[:mirror].to_h["ss/5:2:A"], "nothing was restored, so nothing to fold"
  end

end
