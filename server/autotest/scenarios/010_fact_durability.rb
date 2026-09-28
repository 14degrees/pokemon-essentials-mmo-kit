# frozen_string_literal: true

# A progression fact the game earned but never saved must not come back. The switch
# reaches the server with the flags snapshot on a map change, the game dies before
# the checkpoint that would have saved it, and the next session loads a blob without
# it. Neither that session's save nor any later login may restore it - and with
# enforcement on, the server must judge the new session against what was SAVED, not
# repair the switch back from the state the crash lost.
Autotest.scenario "a fact lost in a crash is never restored",
                  flags: { PEMK_FLAG_STATE: "on", PEMK_FLAG_ENFORCE: "on" } do |s|
  fact   = "sw:visited_berth_island"   # switch 51, fact tier in the manifest
  a      = s.player(:a)
  a.new_game("Crash")
  id     = s.account_id(a)
  facts  = -> { s.db[:progression_facts].where(account_id: id, fact_key: fact) }

  a.save!                     # a known save; the next checkpoint now waits 20 s
  a.set_switch!(51, "on")
  a.warp!(7, 38, 29)          # a map change sends the flags snapshot at once
  s.wait_for("the server banks the switch as pending", seconds: 10) { facts.call.first }
  a.hard_kill                 # before the checkpoint could save it
  s.check("the fact was pending, not durable") { facts.call.get(:durable_at).nil? }

  a.relaunch
  s.check("the next session does not have it") { a.get_switch!(51)["value"] == false }
  saved_at = -> { s.db[:characters].where(account_id: id).get(:updated_at) }
  before = saved_at.call
  a.save!                     # this session's blob lacks the switch
  s.wait_for("the save reaches the server", seconds: 10) { saved_at.call != before }
  s.check("the lost fact never became durable") { facts.call.exclude(durable_at: nil).count.zero? }

  a.relaunch
  s.check("nor does it come back at the next login") { a.get_switch!(51)["value"] == false }
  s.check("the server never repaired it back") { s.server.grep(/flags: account #{id} REPAIR/).empty? }
end
