# frozen_string_literal: true

# A deploy restarts the server under a playing client. The client must find the
# server again on its own, tell the player both ways, and keep saving: what was
# gained before the restart and what was gained after it both survive a relaunch.
Autotest.scenario "a server restart mid-session loses nothing", budget: 300 do |s|
  a = s.player(:a)
  a.new_game("Restart")
  id = s.account_id(a)
  a.add_item!("POTION", 3)
  saved = -> { s.db[:characters].where(account_id: id).get(:updated_at) }
  before = saved.call
  a.save!
  s.wait_for("the save reaches the server") { saved.call != before }

  s.server.restart
  s.wait_for("the window finds the server again", seconds: 90) do
    a.log_tail(80).any? { |l| l.include?("net: reconnected + re-authenticated") }
  end
  a.converse                               # the two notices, lost then restored
  told = Array(a.state["log"]).map { |e| e["text"].to_s }
  s.check("the player was told it was lost") { told.any? { |t| t.include?("Connection to the server was lost") } }
  s.check("and that it was restored") { told.any? { |t| t.include?("Connection restored") } }

  a.add_item!("ETHER", 2)
  before = saved.call
  a.save!
  s.wait_for("the save after the restart reaches the server") { saved.call != before }
  a.relaunch
  s.check("what came before the restart is still there") { a.get_item!("POTION")["quantity"] == 3 }
  s.check("and what came after it") { a.get_item!("ETHER")["quantity"] == 2 }
end
