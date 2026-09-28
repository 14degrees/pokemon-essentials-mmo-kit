require "minitest/autorun"
require "json"
require "tempfile"

lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "pemk/battle_data"
require "pemk/reward_calc"
require "pemk/reward_audit"

# M4 Layer D D4: the per-account reward window (battle -> exp/money budgets, consumed by
# level jumps + money deltas). Pure (no DB); a fixed `now` drives TTL deterministically.
class RewardAuditTest < Minitest::Test
  FIX = {
    "schema_version" => 1, "caps" => { "max_level" => 100 }, "natures" => {}, "types" => {},
    "abilities" => [], "items" => {}, "moves" => {},
    "growth_rates" => { "Toy" => { "max_exp" => 100_000, "curve" => (1..100).map { |n| n * 100 } } },
    "species" => {
      "HOOTHOOT" => { "species" => "HOOTHOOT", "form" => 0, "base_stats" => { "HP" => 60 },
                      "base_exp" => 64, "growth_rate" => "Toy" }
    }
  }.freeze

  def setup
    @tmp = Tempfile.new(["pemk_ra", ".json"]); @tmp.write(JSON.generate(FIX)); @tmp.flush
    @bd  = PEMK::BattleData.new(@tmp.path)
    @ra  = PEMK::RewardAudit.new(PEMK::RewardCalc.new(@bd), @bd)
    @t   = Time.now
  end

  def teardown
    @tmp.close! rescue nil
  end

  def foe(level = 10); { species: "HOOTHOOT", level: level }; end

  # --- money attribution --------------------------------------------------------------
  def test_money_gain_within_budget_is_attributed
    @ra.record_battle(1, [foe], 1, now: @t)              # win -> gain budget = 100_000
    reason, suspect = @ra.note_money(1, 500, now: @t)
    assert_equal "battle:1", reason
    refute suspect
  end

  def test_money_gain_over_budget_is_suspect_but_reason_stays_clean
    @ra.record_battle(1, [foe], 1, now: @t)
    reason, suspect = @ra.note_money(1, 999_999, now: @t)
    assert_equal "battle:1", reason   # ledger stays clean-attributed, never "battle_suspect"
    assert suspect                    # the suspicion is a flag the caller LOGS
  end

  # A spend AFTER a win (win opens gain budget, loss=0) must NOT be flagged suspect and
  # must not pollute the ledger — it's a normal "won a little, bought a Potion".
  def test_spend_after_a_win_is_not_suspect
    @ra.record_battle(1, [foe], 1, now: @t)
    reason, suspect = @ra.note_money(1, -300, now: @t)
    assert_equal "unattributed", reason
    refute suspect
  end

  def test_money_without_a_window_is_unattributed
    reason, suspect = @ra.note_money(1, 5_000, now: @t)  # a shop purchase, no battle
    assert_equal "unattributed", reason
    refute suspect
  end

  def test_loss_within_blackout_cap_is_attributed
    @ra.record_battle(1, [foe], 2, now: @t)              # lost -> loss budget = 12_000
    reason, suspect = @ra.note_money(1, -8_000, now: @t)
    assert_equal "battle:1", reason
    refute suspect
  end

  def test_loss_over_cap_is_not_suspect_just_unattributed
    @ra.record_battle(1, [foe], 2, now: @t)              # loss budget = 12_000
    reason, suspect = @ra.note_money(1, -50_000, now: @t) # a big purchase, bigger than blackout cap
    assert_equal "unattributed", reason                  # a decrease is never a reward cheat
    refute suspect
  end

  def test_gain_budget_is_consumed
    @ra.record_battle(1, [foe], 1, now: @t)
    100.times { assert_equal "battle:1", @ra.note_money(1, 1_000, now: @t)[0] }  # 100k exactly
    reason, suspect = @ra.note_money(1, 1, now: @t)                              # now empty
    assert_equal "battle:1", reason   # still attributed to the window
    assert suspect                    # ... but over budget -> flagged
  end

  def test_windows_stack_within_ttl
    @ra.record_battle(1, [foe], 1, now: @t)
    w = @ra.record_battle(1, [foe], 1, now: @t + 5)      # same window, budgets add
    assert_equal 1, w[:id]
    assert_equal 200_000, w[:gain]
  end

  def test_window_expires_after_ttl
    @ra.record_battle(1, [foe], 1, now: @t)
    reason, = @ra.note_money(1, 100, now: @t + 91)        # TTL 90s passed
    assert_equal "unattributed", reason
  end

  # --- level-jump exp check -----------------------------------------------------------
  def test_level_jump_within_exp_budget_ok
    @ra.record_battle(1, [foe(10)], 1, now: @t)           # exp budget = 1197*6 = 7182
    # curve is n*100: level 5->6 needs curve(6)-curve(5+1)... wait, old=5 -> ceil=curve(6)=600,
    # new=6 -> target=600 -> min = 600-600+1 = 1. Small jump, well within budget.
    suspect, = @ra.check_levels(1, [["HOOTHOOT", 5, 6]], now: @t)
    refute suspect
  end

  def test_impossible_level_jump_is_suspect
    @ra.record_battle(1, [foe(10)], 1, now: @t)           # budget 7182
    # 1 -> 90: target curve(90)=9000, ceil curve(2)=200 -> min 8801 > 7182 -> suspect
    suspect, detail = @ra.check_levels(1, [["HOOTHOOT", 1, 90]], now: @t)
    assert suspect
    assert_includes detail, "needs >="
  end

  def test_level_jump_without_a_window_is_suspect_if_any_exp_needed
    # no battle recorded -> budget 0; any real jump exceeds it
    suspect, = @ra.check_levels(1, [["HOOTHOOT", 1, 5]], now: @t)
    assert suspect
  end

  def test_no_jump_is_never_suspect
    suspect, detail = @ra.check_levels(1, [["HOOTHOOT", 10, 10]], now: @t)
    refute suspect
    assert_nil detail
  end

  # A battle lost to a trainer's second Pokemon still paid EXP for knocking out the first.
  def test_a_lost_battle_still_bounds_the_exp_it_paid
    @ra.record_battle(1, [foe(10)], 2, now: @t)   # lost
    refute @ra.check_levels(1, [["HOOTHOOT", 5, 6]], now: @t).first
  end

  # --- level items used outside battles ----------------------------------------------
  # Curve n*100: min exp for old -> new is curve(new) - curve(old + 1) + 1.
  def bag(candies, xs = 0); { RARECANDY: candies, EXPCANDYXS: xs }; end

  def used(credit, before, after)
    @ra.note_items(credit, before, now: @t)
    @ra.note_items(credit, after, now: @t)
  end

  def test_a_used_rare_candy_pays_for_its_level
    credit = PEMK::RewardAudit.new_credit
    used(credit, bag(3), bag(2))
    suspect, = @ra.check_levels(1, [["HOOTHOOT", 5, 6]], credit: credit, now: @t)
    refute suspect
    assert_equal 0, credit[:levels]
  end

  def test_a_candy_pays_for_one_level_only
    credit = PEMK::RewardAudit.new_credit
    used(credit, bag(3), bag(2))
    suspect, = @ra.check_levels(1, [["HOOTHOOT", 5, 20]], credit: credit, now: @t)
    assert suspect   # 6 -> 20 still needs EXP no window holds
  end

  def test_candies_that_appear_pay_for_nothing
    credit = PEMK::RewardAudit.new_credit
    used(credit, bag(0), bag(5))   # picked up or bought, not used
    suspect, = @ra.check_levels(1, [["HOOTHOOT", 5, 6]], credit: credit, now: @t)
    assert suspect
  end

  def test_exp_candies_pay_in_exp
    credit = PEMK::RewardAudit.new_credit
    used(credit, bag(0, 2), bag(0, 0))                                                 # 200 EXP
    refute @ra.check_levels(1, [["HOOTHOOT", 5, 7]], credit: credit, now: @t).first   # needs 101
    assert @ra.check_levels(1, [["HOOTHOOT", 7, 9]], credit: credit, now: @t).first   # 99 left, needs 101
  end

  def test_a_used_item_stays_credited_for_half_an_hour
    credit = PEMK::RewardAudit.new_credit
    used(credit, bag(1), bag(0))
    assert @ra.check_levels(1, [["HOOTHOOT", 5, 6]], credit: credit, now: @t + 1_801).first
  end

  def test_the_first_bag_is_only_a_baseline
    credit = PEMK::RewardAudit.new_credit
    @ra.note_items(credit, bag(0), now: @t)   # the session's first snapshot
    assert_equal 0, credit[:levels]
  end

  def test_unjudgeable_jump_is_skipped_not_suspect
    # unknown species -> that jump is skipped; with no other need, not suspect
    suspect, = @ra.check_levels(1, [["MISSINGNO", 1, 50]], now: @t)
    refute suspect
  end
end
