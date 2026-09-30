# frozen_string_literal: true

module PEMK
  module Chain
    # Chain C1 - drains the asset outbox (AssetEvents) onto a contract, in id order, one
    # event at a time. Runs in its own process (bin/pemk_chain.rb), never in the game
    # server. Idempotent by reading the chain first: a mint of a token that exists, a
    # move to the account that holds it, a freeze already in place are confirmed without
    # a transaction - so a crash between the transaction and the stamp is harmless, and
    # a restarted relayer never double-writes.
    #
    # Order is the receipt's meaning (a transfer names a token its mint created), so a
    # failure STOPS the pass: the row is stamped failed with its error, retried after a
    # backoff that grows with its attempts, and nothing behind it moves until it does.
    # The operator sees it in `status` and `show`. Shadow stamps every row without a
    # chain, so the queue empties and the log shows what `on` would have sent.
    #
    # The adapter (Evm, or a test double) speaks the contract:
    #   minted?(id) account_of(id) frozen?(id)
    #   mint(id, account:, kind:, species:, shiny:, origin:) -> tx hash (mined, succeeded)
    #   move(id, to_account:, ref:) -> tx hash
    #   set_frozen(id, frozen, reason:) -> tx hash
    class Relayer
      KIND_MONSTER = 0
      KIND_CARD    = 1
      BACKOFF_MAX  = 300   # seconds between retries of one failed row, at most

      class OutOfOrder < StandardError; end

      def initialize(events, adapter: nil, mode: :shadow, logger: nil)
        @events  = events
        @adapter = adapter
        @mode    = mode
        @log     = logger || ->(_m) {}
        raise ArgumentError, "chain on needs an adapter" if @mode == :on && @adapter.nil?
      end

      # One pass. -> {confirmed:, shadow:, failed:, waiting:}
      def pass(limit: 100, now: Time.now)
        tally = { confirmed: 0, shadow: 0, failed: 0, waiting: 0 }
        @events.pending(limit: limit).each do |ev|
          if @mode == :shadow
            @events.mark_shadow(ev[:id], now: now)
            @log.call("chain: ##{ev[:id]} #{describe(ev)} (shadow)")
            tally[:shadow] += 1
            next
          end
          if ev[:status] == "failed" && ev[:sent_at] && (now - ev[:sent_at]) < backoff(ev[:attempts])
            tally[:waiting] += 1
            break   # its turn has not come; nothing behind it moves
          end
          begin
            tx = apply(ev)
            @events.mark_confirmed(ev[:id], tx, now: now)
            @log.call("chain: ##{ev[:id]} #{describe(ev)} -> #{tx}")
            tally[:confirmed] += 1
          rescue StandardError => e
            @events.mark_failed(ev[:id], "#{e.class}: #{e.message}", now: now)
            @log.call("chain: ##{ev[:id]} #{describe(ev)} FAILED #{e.class}: #{e.message} (attempt #{ev[:attempts] + 1})")
            tally[:failed] += 1
            break
          end
        end
        tally
      end

      # The daemon: a pass, then wait for the server's NOTIFY (or the interval).
      def run(interval: 15, db:)
        loop do
          t = pass
          @log.call("chain: pass - #{t[:confirmed]} confirmed / #{t[:shadow]} shadow / #{t[:failed]} failed") if t.values.sum.positive?
          begin
            db.listen(AssetEvents::CHANNEL, timeout: interval)
          rescue StandardError
            sleep interval
          end
        end
      end

      private

      # -> the tx hash, or a marker when the chain already showed the event's state.
      def apply(ev)
        id = ev[:token_id]
        case ev[:kind]
        when "mint"
          return "(already on chain)" if @adapter.minted?(id)

          p = ev[:payload].to_h
          @adapter.mint(id, account: ev[:to_account_id], kind: kind_code(ev[:asset_kind]),
                            species: p["species"].to_s, shiny: p["shiny"] == true, origin: p["origin"].to_s)
        when "transfer"
          raise OutOfOrder, "token #{id} not minted" unless @adapter.minted?(id)
          return "(already on chain)" if @adapter.account_of(id) == ev[:to_account_id]

          @adapter.move(id, to_account: ev[:to_account_id], ref: ev[:ref].to_s)
        when "freeze", "unfreeze"
          raise OutOfOrder, "token #{id} not minted" unless @adapter.minted?(id)

          want = ev[:kind] == "freeze"
          return "(already on chain)" if @adapter.frozen?(id) == want

          @adapter.set_frozen(id, want, reason: ev[:ref].to_s)
        else
          raise ArgumentError, "unknown event kind #{ev[:kind]}"
        end
      end

      def kind_code(asset_kind)
        asset_kind == "card" ? KIND_CARD : KIND_MONSTER
      end

      def backoff(attempts)
        [5 * (2**[attempts, 8].min), BACKOFF_MAX].min
      end

      def describe(ev)
        case ev[:kind]
        when "mint"     then "mint token #{ev[:token_id]} (#{ev[:payload].to_h['species']}) for account #{ev[:to_account_id]}"
        when "transfer" then "move token #{ev[:token_id]} #{ev[:from_account_id]}->#{ev[:to_account_id]} (#{ev[:ref]})"
        else                 "#{ev[:kind]} token #{ev[:token_id]} (#{ev[:ref]})"
        end
      end
    end
  end
end
