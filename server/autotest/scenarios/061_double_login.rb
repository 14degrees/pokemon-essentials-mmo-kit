# frozen_string_literal: true

# The same account logged in from a second window. The newest login must win for
# good: the first window is told why it went offline and stops trying, instead of
# the two taking the account back from each other, each pushing its own save over
# the other's.
Autotest.scenario "a second login ends the first session for good", budget: 300 do |s|
  a = s.player(:a)
  a.new_game("Twice")
  id = s.account_id(a)
  a.save!
  b = s.player(:b, as: :a)                  # the same account, another window
  b.wait_in_game(90)
  sleep 40                                  # time for a few reconnect rounds, if any
  authed = s.server.grep(/authed \S+ as account #{id}$/).size
  File.write(File.join(s.dir, "logins.txt"), s.server.grep(/account #{id}\b/).join("\n"))
  s.check("the account was taken over once, not back and forth (#{authed} logins)") { authed <= 2 }
  s.check("the first window was told why") do
    Array(a.state["log"]).any? { |e| e["text"].to_s =~ /another (window|device)|logged in elsewhere/i }
  end
  s.check("the second window is still online") { b.state.dig("online", "connected") == true }
end
