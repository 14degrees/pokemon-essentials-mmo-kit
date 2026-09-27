# frozen_string_literal: true

# A modified client puts message codes in the names it sends. In the victim's
# "X wants to trade! Accept?" box, "\ch[51,...]" would set its variable 51 and
# "\se[...]" play a sound; a name drawn over a player on the map would carry them
# too, with a sprite path out of Graphics/Characters. What arrives must be plain
# text, and variable 51 must not move whatever the answer.
Autotest.scenario "names from a modified client run no message codes" do |s|
  a = s.player(:a)
  home = a.new_game("Victim")
  a.set_var!(51, 7)
  rogue = s.rogue(:r)

  map = home.dig("map", "id")
  rogue.send_env({ type: :pos, map: map, x: 3, y: 3, dir: 2, speed: 3,
                   char: "../../Titles/title", name: "\\se[GUI sel buzzer]Mallory" })
  seen = s.wait_for("the victim draws the rogue", seconds: 15) do
    Array(a.state["remotes"]).find { |r| r["id"] == rogue.account_id }
  end
  s.check("the name over the rogue is plain text") { seen["name"] == "se[GUI sel buzze" }

  rogue.send_env({ type: :trade_invite, to: s.account_id(a), trade_id: "#{rogue.account_id}:1:1",
                   name: "\\ch[51,2,Yes,No]Eve" })
  a.answer_when_asked("Yes", "No")
  lines = Array(a.state["log"]).map { |e| e["text"].to_s }
  s.check("the invite shows the name as plain text") do
    lines.any? { |t| t.include?("ch[51,2,Yes,No]E wants to trade! Accept?") }
  end
  s.check("variable 51 did not move") { a.get_var!(51)["value"] == 7 }
  s.check("the rogue is told no") { rogue.wait_for(:trade_decline)[:env][:name] == "Victim" }
  s.check("the victim's window still answers") { a.state["ok"] == true }
end
