# frozen_string_literal: true

# M4 Layer D D8 — the operator's quarantine console. Reversibility is D8's spine:
# every consequence is one UPDATE, and this is where a human undoes a false
# positive. NEVER destroys anything.
#
# Usage (WSL, from server/):
#   DATABASE_URL=... bundle exec ruby bin/pemk_quarantine.rb list [account_id]
#   DATABASE_URL=... bundle exec ruby bin/pemk_quarantine.rb show <uid>
#   DATABASE_URL=... bundle exec ruby bin/pemk_quarantine.rb pardon <uid> [reason...]
#   DATABASE_URL=... bundle exec ruby bin/pemk_quarantine.rb reports        # open review queue

require "sequel"
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "pemk/asset_events"

db  = Sequel.connect(ENV.fetch("DATABASE_URL"))
cmd = ARGV.shift

def audit(db, account_id, kind, uid, detail)
  db[:enforcement_events].insert(account_id: account_id, kind: kind, monster_uid: uid,
                                 detail: detail, created_at: Time.now)
end

case cmd
when "list"
  ds = db[:monsters].where(status: "quarantined")
  ds = ds.where(owner_account_id: ARGV[0].to_i) if ARGV[0]
  rows = ds.order(:quarantined_at).all
  puts "#{rows.length} quarantined mon(s):"
  rows.each do |m|
    puts format("  uid %-8d acct %-6d %-14s reason=%-14s at %s (evidence record #%s)",
                m[:id], m[:owner_account_id], m[:species], m[:quarantine_reason],
                m[:quarantined_at], m[:quarantine_record_id] || "-")
  end

when "show"
  uid = ARGV.shift.to_i
  m = db[:monsters].where(id: uid).first
  abort "no such mon uid #{uid}" unless m
  puts "uid #{uid}: #{m[:species]} acct=#{m[:owner_account_id]} status=#{m[:status]} verify=#{m[:verify_state]}"
  puts "  reason=#{m[:quarantine_reason]} at=#{m[:quarantined_at]} evidence=record##{m[:quarantine_record_id]}"
  roll = db[:encounter_rolls].where(claimed_monster_uid: uid).first
  if roll
    puts "  roll ##{roll[:id]} seed=#{roll[:battle_seed]} condemned_at=#{roll[:condemned_at] || '-'}"
    rec = db[:battle_records].where(encounter_roll_id: roll[:id]).order(Sequel.desc(:id)).first
    puts "  record ##{rec[:id]} replay_status=#{rec[:replay_status]} enforcement=#{rec[:enforcement_action]}" if rec
  end
  puts "  audit trail:"
  db[:enforcement_events].where(monster_uid: uid).order(:created_at).each do |e|
    puts "    #{e[:created_at]} #{e[:kind]} — #{e[:detail]}"
  end

when "pardon"
  uid    = ARGV.shift.to_i
  reason = ARGV.join(" ")
  reason = "operator pardon" if reason.empty?
  m = db[:monsters].where(id: uid).first
  abort "no such mon uid #{uid}" unless m
  unless m[:status] == "quarantined"
    abort "uid #{uid} is not quarantined (status=#{m[:status]})"
  end
  db.transaction do
    # verify_state -> verified: the operator vouches for it, so it leaves the
    # provisional trade-hold set (a bare status flip would leave it un-tradeable).
    db[:monsters].where(id: uid).update(status: "active", verify_state: "verified",
                                        quarantine_reason: nil, quarantined_at: nil,
                                        quarantine_record_id: nil, updated_at: Time.now)
    # un-poison the roll so a re-mint / re-verify won't re-quarantine it, and mark its
    # evidence record 'pardoned' so it stops counting toward the account's strikes
    # (otherwise the next honest walk-fail re-quarantines instantly — pardon treadmill).
    roll = db[:encounter_rolls].where(claimed_monster_uid: uid)
    roll_ids = roll.select_map(:id)
    roll.update(condemned_at: nil)
    db[:battle_records].where(encounter_roll_id: roll_ids, replay_status: "walk_mismatch")
                       .update(enforcement_action: "pardoned", enforced_at: Time.now) unless roll_ids.empty?
    audit(db, m[:owner_account_id], "pardon", uid, reason)
    # C1: a frozen token thaws with its pardon (a no-op for a Pokemon without one).
    PEMK::AssetEvents.new(db).unfreeze(uid, m[:owner_account_id], reason: reason) if db.table_exists?(:asset_tokens)
  end
  puts "pardoned uid #{uid} (#{m[:species]}, acct #{m[:owner_account_id]}) — now active + verified. reason: #{reason}"

when "unflag"
  # REPAIR for the pre-audit cross-account grief: any account could set flagged=true on
  # ANY monster by projecting its uid, and Trades#cas gates on flagged=false — so a
  # stranger's Pokémon became permanently untradeable with no recovery path. The write
  # is gone (monsters.rb records the sighting against the projector now), but rows
  # flagged before the fix still need clearing. `unflag all` repairs the whole registry.
  target = ARGV.shift.to_s
  ds = target == "all" ? db[:monsters].where(flagged: true) : db[:monsters].where(id: target.to_i, flagged: true)
  rows = ds.select_map(%i[id owner_account_id])
  if rows.empty?
    puts target == "all" ? "no flagged mons" : "uid #{target} is not flagged"
  else
    ds.update(flagged: false, updated_at: Time.now)
    rows.each { |(uid, acct)| audit(db, acct, "unflag", uid, "operator cleared foreign-uid sighting flag") }
    puts "unflagged #{rows.length} mon(s) — tradeable again"
  end

when "reports"
  rows = db[:anomaly_reports].where(reviewed_at: nil).order(Sequel.desc(:updated_at)).limit(100).all
  puts "#{rows.length} open review report(s):"
  rows.each do |r|
    puts format("  acct %-6d %-22s score=%-4d %s", r[:account_id], r[:kind], r[:score], r[:detail])
  end

else
  puts <<~USAGE
    PEMK quarantine console (D8). Commands:
      list [account_id]        quarantined mons (optionally one account)
      show <uid>               full evidence + audit trail for a mon
      pardon <uid> [reason]    un-quarantine (one UPDATE; reversal is the design's spine)
      unflag <uid>|all         clear the legacy foreign-uid flag that blocked trading
      reports                  open D5/D8 review queue
  USAGE
  exit 1
end
