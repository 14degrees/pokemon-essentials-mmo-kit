# frozen_string_literal: true

# Two players battle through the pause menu. The challenger hosts, the other
# replays; each picks for its own side, and the choices cross through the server.
# Both windows must see the same end, one win and one loss with no timeout, and the
# battle is fought on copies: neither real party loses a hit point. Each team is
# checked on its way (PEMK_PEER_CHECK on): honest teams pass the server and the client.
Autotest.scenario "two players battle each other", flags: { PEMK_PEER_CHECK: "on" }, budget: 420 do |s|
  a = s.player(:a)
  b = s.player(:b)
  s.together(-> { a.new_game("Alice") }, -> { b.new_game("Bob") })

  a.add_pokemon!("PIKACHU", 30)
  b.add_pokemon!("MAGIKARP", 5)
  b.add_pokemon!("WEEDLE", 5)        # Bob sends it in when Magikarp faints
  [a, b].each do |p|
    p.fast!                         # no animations, and no "change Pokémon?" between faints
    p.battle!("mode", "auto")
  end

  a.warp!(7, 38, 30)
  b.warp!(7, 40, 30)
  s.wait_for("each window draws the other", seconds: 30) do
    a.remote_names.include?("Bob") && b.remote_names.include?("Alice")
  end
  party = ->(p) { Array(p.state["party"]).map { |m| [m["species"], m["level"], m["hp"]] } }
  before = [party.call(a), party.call(b)]

  a.pause_menu("Battle Player")
  a.converse("Bob")                               # "Challenge which player?"
  b.answer_when_asked("Yes", "Yes")               # "Alice wants to battle! Accept?"
  s.together(-> { a.wait_until!("battle within 30", timeout: 40) },
             -> { b.wait_until!("battle within 30", timeout: 40) })
  s.together(-> { a.wait_until!("no_battle within 180", timeout: 190) },
             -> { b.wait_until!("no_battle within 180", timeout: 190) })
  s.together(-> { a.wait_until!("idle within 30", timeout: 40) },
             -> { b.wait_until!("idle within 30", timeout: 40) })

  logged = ->(p, text) { p.log_tail(400).any? { |l| l.include?(text) } }
  s.check("Alice hosts and Bob replays") do
    logged.call(a, "battle: PvP start as HOST") && logged.call(b, "battle: PvP start as CLIENT")
  end
  s.check("Alice wins and Bob loses, on both screens") do
    logged.call(a, "battle: ended (outcome=1)") && logged.call(b, "battle: ended (outcome=2)")
  end
  s.check("each side played the other's choices") do
    [a, b].all? { |p| logged.call(p, "battle: applied remote choice") }
  end
  s.check("Bob's replacement reached Alice's screen") do
    logged.call(b, "battle: sent switch") && logged.call(a, "battle: applied remote switch")
  end
  s.check("nothing timed out, starved or raised") do
    [a, b].none? do |p|
      logged.call(p, "timeout/disconnect") || logged.call(p, "starved") || logged.call(p, "run_battle error")
    end
  end
  s.check("both real parties are untouched") { [party.call(a), party.call(b)] == before }
  s.check("neither team was refused, by the server or a client") do
    s.server.grep(/REFUSE/).empty? && [a, b].none? { |p| logged.call(p, "peer:") }
  end
end
