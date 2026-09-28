#===============================================================================
# PEMK :: ItemCorrect  (client side — item authority E4: what the server takes back)
#-------------------------------------------------------------------------------
# With the server's item authority on, an increase of an item it judges that no source
# explained is taken back once it has waited its grace for one: the server sends
# :inv_correct { id, seq, items => { item => n } }, bound to the bag snapshot it judged
# last. It is applied only while that snapshot is still this game's last word - its seq
# is the last one sent and nothing changed since - and only on a free overworld frame:
# never inside a message, a menu, a battle, a trade, an event, an item move or the box
# screen, nor during the Bug Contest or a Frontier challenge. The units come off the bag
# first, then the PC storage, the mailbox and the items Pokemon hold; the next bag
# snapshot names the correction it applied. A correction that no longer fits is dropped:
# the server sends a fresh one after each snapshot it judges, so none applies twice.
# Nothing is said to the player; the log keeps a line.
#===============================================================================
module PEMK
  module ItemCorrect
    @pending = nil   # the latest correction: { :id, :seq, :items }
    @applied = nil   # the id of the one applied, for the next :inv

    module_function

    def reset
      @pending = nil
      @applied = nil
    end

    def pending
      @pending && @pending.dup
    end

    # Dispatch routes :inv_correct here (inside the network pump: no UI). A newer one
    # replaces the one waiting.
    def receive(msg)
      return unless msg.is_a?(Hash) && msg[:id].is_a?(Integer) && msg[:seq].is_a?(Integer) && msg[:items].is_a?(Hash)
      return if @pending && @pending[:id] > msg[:id]

      items = {}
      msg[:items].each do |item, n|
        items[item] = n if item.is_a?(Symbol) && n.is_a?(Integer) && n.positive? && n <= 999_999
      end
      @pending = items.empty? ? nil : { :id => msg[:id], :seq => msg[:seq], :items => items }
    end

    # -> the id of the correction applied since the last :inv, once.
    def take_applied
      id = @applied
      @applied = nil
      id
    end

    def tick
      return unless @pending && free_frame?

      fix = @pending
      @pending = nil
      unless PEMK::Sync.inv_seq == fix[:seq] && !PEMK::Sync.inv_dirty?
        PEMK.log("inv: correction ##{fix[:id]} is for snapshot #{fix[:seq]}, not this possession - dropped")
        return
      end
      fix[:items].each do |item, n|
        took = take(item, n)
        PEMK.log("inv: the server took back #{took} #{item} it could not account for" \
                 "#{took < n ? " (#{n - took} already gone)" : ''}")
      end
      @applied = fix[:id]
      PEMK::Inventory.mark
    rescue StandardError => e
      PEMK.log("inv: correction error #{e.class}: #{e.message}")
    end

    # Removes up to +n+ of +item+: the bag, the PC storage, the mailbox, then held items.
    # -> how many came off.
    def take(item, n)
      left = n
      [$bag, ($PokemonGlobal && $PokemonGlobal.pcItemStorage)].each do |store|
        next unless store && left.positive?

        k = [store.quantity(item), left].min
        left -= k if k.positive? && store.remove(item, k)
      end
      box = $PokemonGlobal && $PokemonGlobal.mailbox
      while left.positive? && box && (i = box.index { |m| m.respond_to?(:item) && m.item == item })
        box.delete_at(i)
        left -= 1
      end
      if left.positive?
        PEMK::Monsters.each_owned do |p|
          break if left.zero?
          next unless (p.item_id rescue nil) == item

          p.item = nil
          (p.mail = nil) rescue nil
          left -= 1
        end
      end
      n - left
    end

    def free_frame?
      $player && $scene.is_a?(Scene_Map) && $game_temp && !$game_temp.in_battle &&
        !$game_temp.in_menu && !$game_temp.message_window_showing &&
        !(pbMapInterpreterRunning? rescue true) && !(PEMK::Inventory.atomic? rescue true) &&
        !(PEMK::Trade.busy? rescue false) && !(PEMK::Inventory.away_from_own_party? rescue true)
    rescue StandardError
      false
    end
  end
end

EventHandlers.add(:on_frame_update, :pemk_item_correct, proc { PEMK::ItemCorrect.tick }) if defined?(EventHandlers)
