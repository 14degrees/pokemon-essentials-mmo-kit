# frozen_string_literal: true

require "rbconfig"

# Moderation: the operator bans a player who is playing (bin/pemk_admin.rb). The window
# is told until when and why and goes offline for good; the next launch is refused at
# login; once the ban is lifted the account plays again.
Autotest.scenario "a banned player is let go and kept out", budget: 360 do |s|
  a = s.player(:a)
  a.new_game("Mallory")
  id = s.account_id(a)
  admin = lambda do |*args|
    out = IO.popen([RbConfig.ruby, "bin/pemk_admin.rb", *args.map(&:to_s)], chdir: Autotest::SERVER_DIR,
                   err: %i[child out], &:read)
    raise Autotest::Failure, "pemk_admin #{args.first}: #{out}" unless $?.success?

    out
  end

  s.check("the operator bans the account for a day") do
    admin.("ban", id, "--days", 1, "duplicating", "items").include?("banned account #{id}")
  end
  s.wait_for("the window is let go", seconds: 30) { a.log_tail(100).any? { |l| l.include?("net: the account is banned") } }
  a.converse                               # the notice
  told = Array(a.state["log"]).map { |e| e["text"].to_s }
  s.check("the player reads until when and why") do
    told.any? { |t| t.start_with?("This account is suspended until") && t.include?("Reason: duplicating items") }
  end
  s.wait_for("the window goes offline", seconds: 10) { a.state.dig("online", "connected") != true }
  sleep 7                                  # past a reconnect's first try (5 s)
  s.check("and stays offline") { a.log_tail(100).none? { |l| l.include?("net: reconnect attempt") } }

  a.hard_kill
  a.launch
  s.wait_for("the next launch is refused", seconds: 60) do
    a.log_tail(200).any? { |l| l.include?("config login failed (banned)") }
  end
  s.check("the operator lifts the ban") { admin.("unban", id).include?("lifted 1 ban(s)") }
  a.relaunch
  s.check("the account plays again") { a.state.dig("online", "logged_in") == true }
end
