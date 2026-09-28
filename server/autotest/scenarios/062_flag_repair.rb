# frozen_string_literal: true

# Step 5 of sovereign variables: with PEMK_FLAG_ENFORCE on, the server keeps the
# owned switches and variables as the game's own writes left them. A value changed
# some other way (a memory edit: the game's setter never runs) comes back to the
# server's at the next save; a value the game itself sets is kept; and the edit does
# not come back after a relaunch, with nothing honest repaired on the way.
Autotest.scenario "an edited variable comes back to the server's value",
                  flags: { PEMK_FLAG_STATE: "on", PEMK_FLAG_ENFORCE: "on" } do |s|
  a = s.player(:a)
  a.new_game("Sovereign")
  id  = s.account_id(a)
  var = 7        # the demo's starter_choice: a mirror variable
  sw  = 31       # the wild-shiny switch: a mirror switch
  a.save!

  a.set_var!(var, 5)                       # through the game's own setter
  a.save!
  s.check("a value the game sets is kept") { a.get_var!(var)["value"] == 5 }

  a.set_raw_var!(var, 99)                  # a memory edit: no setter runs
  a.set_raw_switch!(sw, "on")
  a.save!                                  # the save's snapshot shows the edit
  s.wait_for("the server repairs the client", seconds: 20) { a.get_var!(var)["value"] == 5 }
  s.check("the edited variable is back to the game's value") { a.get_var!(var)["value"] == 5 }
  s.check("and the edited switch is off again") { a.get_switch!(sw)["value"] == false }
  s.check("the server logged the repair") { !s.server.grep(/flags: account #{id} REPAIR .*var #{var}=5/).empty? }
  s.check("the client applied it") { a.log_tail(200).any? { |l| l.include?("flags: repaired") } }

  a.save!
  a.relaunch
  s.check("after a relaunch the edit is still gone") do
    a.get_var!(var)["value"] == 5 && a.get_switch!(sw)["value"] == false
  end
  s.check("nothing honest was repaired, before or after") do
    s.server.grep(/flags: account #{id} REPAIR/).size == 1
  end
end
