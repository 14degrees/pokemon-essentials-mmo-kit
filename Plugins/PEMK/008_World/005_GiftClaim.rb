#===============================================================================
# PEMK :: GiftClaim  (client side — NPC gifts: event items through pbReceiveItem)
#-------------------------------------------------------------------------------
# Layer C gates item BALLS (pbItemBall). Every other acquisition — NPC gifts, TMs,
# key items, story rewards — funnels through pbReceiveItem, and client-owned
# self-switches made all of it re-farmable: clear the switch, talk again.
#
# REPORT (the server's gift gate off): after the item was given, a fire-and-forget
# :gift_claim names which event gave what, so a re-farm leaves a record. Dormant
# unless the flag shadow (PEMK_FLAG_STATE) is on, silent offline.
#
# GATE (step 6: PEMK_GIFT_ENFORCE, advertised as gift_gate at login): an event asks
# the server first (:gift_req) and waits a bounded time, pumping the overworld frame.
#   grant    the vanilla gift runs, then :gift_applied says the item is in the bag
#   deny "already_claimed"
#            "You already received the X." and TRUE: that payout happened before (an
#            event re-armed by an edit, or a save that lost the event's self-switch),
#            so the event moves on as if it paid now
#   deny     any other reason: FALSE, the event's own "no room" branch
#   silence  the gift is OWED and the event moves on (TRUE); the item is added as
#            soon as the server grants it. Never given unasked, so cutting the link
#            cannot skip the gate; never dropped, so a bad link cannot cost an honest
#            player a one-shot item.
#
# Owed gifts live in $PokemonGlobal and ride the save blob: a save that holds the
# event's self-switch also holds the gift it still owes. The server settles a grant
# with the first bag snapshot after the client's :gift_applied (server GiftGrants),
# so the client (1) holds its bag flushes from a request until that report is out and
# (2) re-sends every owed gift on a new connection before its first bag flush. TCP
# keeps both orders.
#===============================================================================
class PokemonGlobalMetadata
  attr_accessor :pemk_gifts_owed   # [[map, event, item, quantity, nonce], ...]
end

module PEMK
  module GiftClaim
    RESEND_AFTER = 10.0   # seconds before an unanswered owed gift is asked again
    INBOX_MAX    = 32

    @gate    = false   # the server gates gifts (adopted at login)
    @gen     = 0       # bumped per authenticated connection
    @inbox   = {}      # nonce => reply, delete-on-read
    @sent    = {}      # nonce => [gen, monotonic time] of its last request
    @holding = 0       # gifts between their request and their :gift_applied (a parallel
                       # event can give one while another waits)
    @running = []      # interpreters inside execute_script, innermost last
    @rng     = nil

    module_function

    def running
      @running
    end

    # Sync.reset on (re)connect: a fresh socket carries no stale reply, and the gate
    # waits for the server to advertise it again.
    def reset
      @gate  = false
      @inbox = {}
      @sent  = {}
    end

    # From the login/auth snapshot. A new connection re-sends the owed gifts here,
    # before anything can flush the bag. (A fresh login's save loads later; the server
    # voided its unsettled grants, so the order does not matter there.)
    def adopt_gate(v)
      @gate = (v == true)
      @gen += 1
      before_bag_flush
    end

    def gate?
      @gate == true && PEMK.enabled? && !PEMK.self_id.nil?
    rescue StandardError
      false
    end

    def online?
      return false unless PEMK.enabled? && PEMK.self_id

      c = PEMK.client
      !!(c && c.connected?)
    rescue StandardError
      false
    end

    # Sync keeps the bag back while this is true.
    def holding?
      @holding > 0
    end

    # The event running this gift -> [map_id, event_id] | nil. The innermost
    # interpreter evaluating a script (a parallel event runs its own), else the map's.
    # Interpreter exposes no accessor for these (verified), so read the ivars.
    def context
      interp = @running.last || pbMapInterpreter
      return nil unless interp

      id  = interp.instance_variable_get(:@event_id)
      map = interp.instance_variable_get(:@map_id)
      map = ($game_map && $game_map.map_id) unless map.is_a?(Integer) && map.positive?
      return nil unless id.is_a?(Integer) && id.positive? && map.is_a?(Integer)

      [map, id]
    rescue StandardError
      nil
    end

    # --- the gate ------------------------------------------------------------------

    # The gated pbReceiveItem. +give+ is the vanilla one (its messages, the bag add and
    # its true/false). -> what the event sees.
    def receive(item, quantity, &give)
      ctx = context
      id  = item_id(item)
      # Nothing to key the gift on, or nothing the bag could take: vanilla behaviour (a
      # full bag keeps its own message and false, and nothing is spent). The server
      # judges the quantity itself.
      return give.call unless ctx && id && quantity.is_a?(Integer) && quantity >= 1 &&
                              can_hold?(id, quantity)

      entry   = [ctx[0], ctx[1], id.to_s, quantity, nonce]
      verdict = :owed
      @holding += 1
      begin
        reply = online? && request(entry) ? wait_for(entry[4]) : nil
        case reply && reply[:type]
        when :gift_grant
          # Not under any rescue: the vanilla gift runs at most once.
          if give.call
            applied(entry)
            return true
          end
          # Granted, but the bag refused it after all: owed like an unanswered one.
        when :gift_deny
          verdict = reply[:reason].to_s == "already_claimed" ? :claimed : :refused
        end
        if verdict == :owed
          owe(entry)
          before_bag_flush   # a reconnect during the wait: ahead of the bag the hold kept back
        end
      ensure
        @holding -= 1
      end
      tell(verdict, id)
    end

    # Dispatch routes :gift_grant / :gift_deny here, keyed by the request's nonce.
    def on_reply(msg)
      n = msg && msg[:seq]
      return unless n.is_a?(Integer)

      @inbox.delete(@inbox.keys.first) while @inbox.size >= INBOX_MAX
      @inbox[n] = msg
    end

    # Every owed gift reaches this connection before its first bag snapshot: the
    # server seals a grant sent on an earlier connection with that snapshot, reading
    # the client's silence as "applied".
    def before_bag_flush
      return unless @gate && online?

      owed.each { |e| request(e) unless (@sent[e[4]] || [])[0] == @gen }
    end

    # Each overworld frame: ask again what has waited too long, and add a granted owed
    # gift once nothing else is on screen.
    def tick
      return if !@gate || holding?

      list = owed
      return if list.empty? || !online?

      before_bag_flush
      now = mono
      list.each { |e| request(e) if now - (@sent[e[4]] || [0, 0.0])[1] >= RESEND_AFTER }
      return unless free_frame?

      list.dup.each do |e|
        reply = @inbox.delete(e[4])
        next unless reply

        settle(e, reply)
        break   # one gift at a time: its messages run their own loop
      end
    rescue StandardError => e
      PEMK.log("gift: tick error #{e.class}: #{e.message}")
    end

    def settle(entry, reply)
      id = entry[2].to_sym
      if reply[:type] == :gift_grant
        return unless can_hold?(id, entry[3])   # still no room: granted again later

        @holding += 1
        begin
          applied(entry) if pemk_orig_pbReceiveItem(id, entry[3])
        ensure
          @holding -= 1
        end
      else
        drop(entry)
        PEMK.log("gift: owed #{entry[2]} dropped (#{reply[:reason]})")
      end
    end

    def request(entry)
      map, event, item, qty, n = entry
      # The server judges a gift by where it last saw the player. After a transfer the
      # position only goes out on the next idle frame, so a gift paid on arrival would
      # find the server a map behind: where the player stands is sent first.
      (PEMK::Presence.emit(:pos) rescue nil)
      PEMK.send_message(:type => :gift_req, :map => map, :event => event, :item => item,
                        :quantity => qty, :nonce => n, :seq => n)
      @sent[n] = [@gen, mono]
      true
    rescue StandardError => e
      PEMK.log("gift: request error #{e.class}: #{e.message}")
      false
    end

    def applied(entry)
      PEMK.send_message(:type => :gift_applied, :map => entry[0], :event => entry[1], :nonce => entry[4])
      drop(entry)
    rescue StandardError => e
      PEMK.log("gift: applied error #{e.class}: #{e.message}")
    end

    # Block until the answer to +n+ arrives, the bound passes or the link drops,
    # pumping the overworld (Graphics.update is the network pump). -> reply | nil.
    def wait_for(n)
      deadline = mono + Config::GIFT_GRANT_TIMEOUT
      loop do
        r = @inbox.delete(n)
        return r if r
        return nil if mono >= deadline || !online?

        Graphics.update
        Input.update
        (pbUpdateSceneMap rescue nil)
      end
    rescue StandardError => e
      PEMK.log("gift: wait error #{e.class}: #{e.message}")
      nil
    end

    def tell(verdict, id)
      name = (GameData::Item.get(id).name rescue id.to_s)
      case verdict
      when :claimed
        pbMessage(_INTL("You already received the {1}.", name))
        true
      when :refused
        pbMessage(_INTL("The server did not confirm this gift."))
        false
      else
        pbMessage(_INTL("The {1} will be added to your Bag once the server confirms it.", name))
        true
      end
    end

    # --- owed gifts (in the save) ----------------------------------------------------

    def owed
      g = $PokemonGlobal
      return [] unless g && g.respond_to?(:pemk_gifts_owed)

      list = g.pemk_gifts_owed
      list = g.pemk_gifts_owed = [] unless list.is_a?(Array)
      list.select! { |e| owed_entry?(e) }
      list
    end

    def owed_entry?(e)
      e.is_a?(Array) && e.length == 5 && e[0].is_a?(Integer) && e[1].is_a?(Integer) &&
        e[2].is_a?(String) && e[3].is_a?(Integer) && e[4].is_a?(Integer)
    end

    def owe(entry)
      list = owed
      list << entry unless list.any? { |e| e[4] == entry[4] }
    end

    def drop(entry)
      owed.reject! { |e| e[4] == entry[4] }
      @sent.delete(entry[4])
    end

    # --- helpers ---------------------------------------------------------------------

    def item_id(item)
      d = GameData::Item.try_get(item)
      d ? d.id : nil
    rescue StandardError
      nil
    end

    def can_hold?(id, quantity)
      return true unless $bag && $bag.respond_to?(:can_add?)

      $bag.can_add?(id, quantity)
    rescue StandardError
      true
    end

    def free_frame?
      $scene.is_a?(Scene_Map) && $game_temp && !$game_temp.in_battle &&
        !$game_temp.message_window_showing && !$game_temp.player_transferring &&
        !(pbMapInterpreterRunning? rescue true)
    rescue StandardError
      false
    end

    def nonce
      (@rng ||= Random.new).rand(1...(1 << 62))
    end

    def mono
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rescue StandardError
      0.0
    end

    # --- report (the gate off) -------------------------------------------------------

    def report(item, quantity)
      return unless (PEMK::Flags.active? rescue false)
      return unless PEMK.enabled? && PEMK.self_id

      ctx = context
      return unless ctx   # no event context -> not a one-shot we can key

      PEMK.send_message(:type => :gift_claim, :map => ctx[0], :event => ctx[1],
                        :item => item.to_s, :quantity => quantity)
    rescue StandardError => e
      PEMK.log("gift: report error #{e.class}: #{e.message}")
    end
  end
end

# The event behind a gift: a parallel event evaluates its scripts on its own
# interpreter, not the map's, so each script evaluation names itself.
if defined?(Interpreter) && Interpreter.method_defined?(:execute_script) &&
   !Interpreter.method_defined?(:pemk_gift_execute_script)
  class Interpreter
    alias_method :pemk_gift_execute_script, :execute_script
    def execute_script(script)
      PEMK::GiftClaim.running.push(self)
      begin
        pemk_gift_execute_script(script)
      ensure
        PEMK::GiftClaim.running.pop
      end
    end
  end
end

# The ONE acquisition seam outside item balls. Guarded so it aliases at most once and
# loads cleanly in a headless harness (pbReceiveItem undefined there).
if defined?(pbReceiveItem) && !defined?(pemk_orig_pbReceiveItem)
  alias pemk_orig_pbReceiveItem pbReceiveItem
  def pbReceiveItem(item, quantity = 1)
    if (PEMK::GiftClaim.gate? rescue false)
      return PEMK::GiftClaim.receive(item, quantity) { pemk_orig_pbReceiveItem(item, quantity) }
    end

    ret = pemk_orig_pbReceiveItem(item, quantity)
    (PEMK::GiftClaim.report(item, quantity) rescue nil) if ret
    ret
  end
end

EventHandlers.add(:on_frame_update, :pemk_gift_owed, proc { PEMK::GiftClaim.tick }) if defined?(EventHandlers)
