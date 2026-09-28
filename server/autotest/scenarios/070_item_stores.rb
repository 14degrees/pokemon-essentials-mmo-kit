# frozen_string_literal: true

# Item authority E0: the PC storage and the items Pokemon hold come back at login from
# the server's record, like the bag, instead of from the save, which is written on
# another channel. Each move below is followed by a crash before any save lands: after
# the relaunch the item is in one place - not two (a PC withdrawal, a taken item used to
# be duplicated) and not none (a given item used to be lost).
Autotest.scenario "an item moved just before a crash is in exactly one place", budget: 420 do |s|
  a = s.player(:a)
  a.new_game("Keeper")
  id = s.account_id(a)
  a.add_item!("ORANBERRY", 1)
  a.pc_deposit!("ORANBERRY", 1)
  a.add_pokemon!("PIKACHU", 10)
  a.add_item!("LEFTOVERS", 1)
  a.save!                                  # the save: an Oran Berry in the PC, Leftovers in the bag
  record = -> { s.db[:inventory_snapshots].where(account_id: id).first }
  count  = ->(col, item) { (record.call[col] || {})[item].to_i }
  relaunch_after_crash = lambda do
    a.hard_kill
    a.launch
    a.wait_in_game
  end

  a.hold_saves!("on")                      # from here, no save of this game lands
  a.pc_withdraw!("ORANBERRY", 1)
  a.give_held!(0, "LEFTOVERS")
  s.wait_for("the server records both moves", seconds: 20) do
    count.(:bag, "ORANBERRY") == 1 && count.(:pc, "ORANBERRY").zero? && count.(:held, "LEFTOVERS") == 1
  end
  relaunch_after_crash.call
  s.check("the withdrawn Oran Berry is in the bag, not also in the PC") do
    a.get_item!("ORANBERRY")["quantity"] == 1 && a.get_pc!("ORANBERRY")["quantity"].zero?
  end
  s.check("the given Leftovers is held by Pikachu, not lost") do
    a.get_held!(0)["held"] == "LEFTOVERS" && a.get_item!("LEFTOVERS")["quantity"].zero?
  end

  a.hold_saves!("on")
  a.take_held!(0)
  s.wait_for("the server records the take", seconds: 20) do
    count.(:bag, "LEFTOVERS") == 1 && count.(:held, "LEFTOVERS").zero?
  end
  relaunch_after_crash.call
  s.check("the taken Leftovers is in the bag, not still held") do
    a.get_item!("LEFTOVERS")["quantity"] == 1 && a.get_held!(0)["held"].nil?
  end
end
