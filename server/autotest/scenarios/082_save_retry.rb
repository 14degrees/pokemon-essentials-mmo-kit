# frozen_string_literal: true

# A save the server could not write (a database error) used to count as saved: the game
# never sent it again, and a crash took the player back to the save before. The server
# now says whether each save was written, and the game sends one it could not write
# again until it lands.
Autotest.scenario "a save the server could not write is sent again", budget: 300 do |s|
  a = s.player(:a)
  a.new_game("Keeper")
  id = s.account_id(a)
  a.wait_until!("idle within 10", timeout: 20)
  written = -> { s.server.grep(/server: saved account #{id} /).size }
  a.set_var!(51, 7)                        # lives only in the save (story state is not shadowed here)
  s.server.fail_saves(id, 1)               # the next write fails, as on a database error
  before = written.call
  a.save!
  s.wait_for("the server could not write it", seconds: 20) { s.server.grep(/save of account #{id} FAILED/).any? }
  s.wait_for("the game sends it again and it lands", seconds: 60) { written.call > before }
  s.check("the game knew it was not written") { a.log_tail(200).any? { |l| l.include?("sync: save not written") } }
  a.relaunch                               # a crash: no save on the way out
  s.check("the value is in the save the server kept") { a.get_var!(51)["value"] == 7 }
end
