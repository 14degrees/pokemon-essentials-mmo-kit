#===============================================================================
# PEMK :: ItemStores  (client side — item authority E0: one record for every store)
#-------------------------------------------------------------------------------
# The bag was mirrored to the server and restored from it at login, while the PC item
# storage, the mailbox and the items Pokemon hold came back from the save blob, written
# on another channel. A PC withdrawal or a taken held item reached the server with the
# next bag flush but changed its source only with the next blob: a crash in between
# handed the item back twice, and the reverse moves lost it.
#
# The bag snapshot now counts every store (:stores in the :inv frame) and the server
# keeps them in the same row. A login takes them from that record, not the blob:
#   - the PC storage exactly;
#   - held items and the mailbox by totals. An excess comes off Pokemon, first those the
#     record does not name as holding that item, then off the mailbox; a deficit goes
#     back on a Pokemon the record names as holding it (if it holds nothing now), the
#     rest to the bag. A Pokemon the record names and the save lacks (lost in a crash,
#     or a trade's Pokemon that comes back later) is left out with its item.
# During a Bug Contest or a Frontier challenge the party is not the player's own, so
# only the bag goes out; the record then reads "bag only" and the next login keeps the
# save's stores, as before this step. The same during a battle: held items change there
# only for its length (Knock Off, a Trick against a trainer, all given back at its end),
# so the server judges the first full snapshot after it against the one before it.
#===============================================================================
module PEMK
  module Inventory
    STORES_MAX_BYTES = 40_000   # the whole :inv envelope must stay under the 64 KiB wire cap

    @carry_pc       = {}    # PC items the restore could not put back (unknown ids): still counted
    @pending_stores = nil

    # -> { pc: {item => n} | nil, mail: {item => n}, held: {item => n}, holders: {uid => item} },
    # or nil when this is not the player's own possession, or too big to send.
    def self.stores
      return nil if away_from_own_party?

      g = $PokemonGlobal
      pc = nil
      if g && g.pcItemStorage
        pc = {}
        g.pcItemStorage.items.each { |slot| count(pc, slot[0], slot[1]) if slot.is_a?(Array) }
        @carry_pc.each { |id, n| count(pc, id, n) }
      end
      mail = {}
      Array(g && g.mailbox).each { |m| count(mail, m.item, 1) if m.respond_to?(:item) }
      held = {}
      holders = {}
      PEMK::Monsters.each_owned do |p|
        item = (p.item_id rescue nil)
        count(held, item, 1) if item
        holders[p.pemk_uid] = item if p.pemk_uid   # nil too: "holds nothing" is known
      end
      out = { :pc => pc, :mail => mail, :held => held, :holders => holders }
      return nil if bytes(out) > STORES_MAX_BYTES

      out
    rescue StandardError => e
      PEMK.log("inv: stores error #{e.class}: #{e.message}")
      nil
    end

    def self.count(h, item, n)
      return unless item.is_a?(Symbol) && n.is_a?(Integer) && n > 0

      h[item] = (h[item] || 0) + n
    end

    def self.bytes(out)
      maps = [out[:pc] || {}, out[:mail], out[:held]]
      maps.sum { |m| m.sum { |k, _| k.to_s.bytesize + 14 } } + out[:holders].size * 24
    end

    def self.away_from_own_party?
      (pbInBugContest? rescue false) || ($PokemonGlobal&.challenge&.pbInChallenge? rescue false) ||
        ($game_temp && $game_temp.in_battle) ? true : false
    end

    # --- the login restore ---------------------------------------------------------

    def self.note_stores(rec)
      @pending_stores = rec.is_a?(Hash) ? rec : nil
    end

    # After the save is loaded and the traded-away Pokemon evicted.
    def self.restore_stores
      rec = @pending_stores
      @pending_stores = nil
      return unless rec && $PokemonGlobal

      @applying = true
      begin
        restore_pc(rec[:pc]) if rec[:pc].is_a?(Hash)
        settle_held(rec)
      ensure
        @applying = false
      end
      PEMK::Sync.mark_inv   # the settled possession goes back to the server
    rescue StandardError => e
      PEMK.log("inv: store restore error #{e.class}: #{e.message}")
    end

    def self.restore_pc(pc)
      st = PCItemStorage.allocate          # .new would add the start items again
      st.instance_variable_set(:@items, [])
      @carry_pc = {}
      pc.each do |id, n|
        next unless n.is_a?(Integer) && n > 0

        if (GameData::Item.exists?(id) rescue false)
          ItemStorageHelper.add(st.items, PCItemStorage::MAX_SIZE, PCItemStorage::MAX_PER_SLOT, id, n)
        else
          @carry_pc[id] = n
          PEMK.log("inv: PC item #{id.inspect} x#{n} is unknown to this game - kept in the server record")
        end
      end
      $PokemonGlobal.pcItemStorage = st
    end

    # Held items and the mailbox to the record's totals (see the header).
    def self.settle_held(rec)
      holders = rec[:holders].is_a?(Hash) ? rec[:holders] : {}
      # A save written before a Pokemon's uid arrived knows it by its mint nonce only.
      by_nonce = rec[:nonces].is_a?(Hash) ? rec[:nonces].invert : {}
      uid_of = ->(p) { p.pemk_uid || by_nonce[(p.pemk_nonce rescue nil)] }
      target = Hash.new(0)
      [rec[:held], rec[:mail]].each { |m| m.each { |i, n| target[i] += n.to_i } if m.is_a?(Hash) }
      # A Pokemon the record names but the save lacks (lost in a crash, or owed by a trade
      # and coming back with it) takes its item along: never into the bag.
      owned = {}
      PEMK::Monsters.each_owned { |p| (u = uid_of.(p)) && owned[u] = true }
      holders.each { |uid, item| target[item] -= 1 if item && !owned[uid] }
      have = Hash.new { |h, k| h[k] = [] }
      PEMK::Monsters.each_owned { |p| (i = (p.item_id rescue nil)) && have[i] << [:held, p] }
      Array($PokemonGlobal.mailbox).each { |m| have[m.item] << [:mail, m] if m.respond_to?(:item) }
      (have.keys | target.keys).each do |item|
        places = have[item]
        want = [target[item], 0].max
        if places.size > want
          strip = places.sort_by { |kind, obj| kind == :mail ? 2 : (holders[uid_of.(obj)] == item ? 1 : 0) }
          strip.first(places.size - want).each do |kind, obj|
            if kind == :held
              obj.item = nil
            else
              $PokemonGlobal.mailbox.delete(obj)
            end
          end
          PEMK.log("inv: #{places.size - want} #{item} the save held beyond the record came off")
        elsif places.size < want
          # Back on a Pokemon the record names as holding it, if it holds nothing now;
          # the rest to the bag.
          missing = want - places.size
          PEMK::Monsters.each_owned do |p|
            break if missing.zero?
            next unless holders[uid_of.(p)] == item && (p.item_id rescue nil).nil?

            p.item = item
            missing -= 1
          end
          $bag.add(item, missing) if missing.positive?
          PEMK.log("inv: #{want - places.size} #{item} the save lacked came back (#{missing} to the bag)")
        end
      end
    end
  end
end

# --- every store marks the channel -----------------------------------------------
class PCItemStorage
  unless method_defined?(:pemk_orig_add)
    alias_method :pemk_orig_add,    :add
    alias_method :pemk_orig_remove, :remove
    alias_method :pemk_orig_clear,  :clear

    def add(item, qty = 1)
      ret = pemk_orig_add(item, qty)
      PEMK::Inventory.mark unless PEMK::Inventory.applying   # a partial add changed it too
      ret
    end

    def remove(item, qty = 1)
      ret = pemk_orig_remove(item, qty)
      PEMK::Inventory.mark unless PEMK::Inventory.applying
      ret
    end

    def clear
      ret = pemk_orig_clear
      PEMK::Inventory.mark unless PEMK::Inventory.applying
      ret
    end
  end
end

class Pokemon
  unless method_defined?(:pemk_orig_item_set)
    alias_method :pemk_orig_item_set, :item=
    def item=(value)
      before = @item
      pemk_orig_item_set(value)
      PEMK::Inventory.mark if @item != before && !PEMK::Inventory.applying
    end
  end
end

if defined?(pbMoveToMailbox) && !defined?(pemk_orig_pbMoveToMailbox)
  alias pemk_orig_pbMoveToMailbox pbMoveToMailbox
  def pbMoveToMailbox(pokemon)
    ret = pemk_orig_pbMoveToMailbox(pokemon)
    PEMK::Inventory.mark if ret
    ret
  end
end
