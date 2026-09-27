# frozen_string_literal: true

# The floor every other scenario stands on: a window boots against the test server,
# the login creates a fresh account, and the intro plays through to the player's
# house.
Autotest.scenario "a new account logs in and plays the intro" do |s|
  a = s.player(:a)
  home = a.new_game("Ash")

  s.check("logged in to the test server") { home.dig("online", "logged_in") == true }
  s.check("the account exists on the server") { !s.account_id(a).nil? }
  s.check("the intro ends idle in the player's house") { home.dig("map", "name").to_s.include?("house") }
  s.check("the trainer carries the typed name") { home.dig("trainer", "name") == "Ash" }
end
