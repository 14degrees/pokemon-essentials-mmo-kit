# frozen_string_literal: true

module PEMK
  module Chain
    # Chain C1 - the audit that makes the receipt model honest. The relayer only ever
    # writes forward; nothing else checks that the chain still SAYS what the registry
    # says. This does: for every token whose queue has drained, the chain's owner
    # account and frozen flag must equal the registry's, its mint must exist; every
    # registry transfer of a tokenized Pokemon must have its receipt; and the contract
    # must hold no more tokens than the registry issued (the operator key used
    # elsewhere would show here). A token with events still in flight is not judged -
    # the queue has not caught up, which is lag, not drift.
    #
    # Read-only, on both sides. Run by `pemk_chain.rb audit` and by the daemon's loop
    # (PEMK_CHAIN_AUDIT_SEC). A drift is an alarm for the operator, never repaired on
    # its own: the registry is the owner of record, and a chain that disagrees with it
    # means a key, a node or a relayer did something the design forbids.
    class Reconciler
      KIND = AssetEvents::KIND

      def initialize(db, adapter, logger: nil)
        @db      = db
        @adapter = adapter
        @log     = logger || ->(_m) {}
      end

      # -> { tokens:, checked:, in_flight:, drift: [{token_id:, what:, registry:, chain:}], ok: }
      def run
        drift     = []
        in_flight = 0
        tokens    = @db[:asset_tokens].where(asset_kind: KIND).order(:token_id).all
        open      = @db[:asset_events].where(asset_kind: KIND, status: %w[pending failed sent])
                                      .group_and_count(:asset_id).to_hash(:asset_id, :count)
        mons      = @db[:monsters].where(id: tokens.map { |t| t[:asset_id] }).to_hash(:id)

        tokens.each do |t|
          if open[t[:asset_id]].to_i.positive?
            in_flight += 1
            next
          end
          id  = t[:token_id]
          mon = mons[t[:asset_id]]
          unless mon
            drift << { token_id: id, what: "token without a registry row", registry: nil, chain: nil }
            next
          end
          unless @adapter.minted?(id)
            drift << { token_id: id, what: "not minted on chain", registry: t[:mint_tx] ? "mint confirmed #{t[:mint_tx]}" : "mint never confirmed", chain: "no token" }
            next
          end
          account = @adapter.account_of(id)
          drift << { token_id: id, what: "owner", registry: mon[:owner_account_id], chain: account } if account != mon[:owner_account_id]
          frozen = @adapter.frozen?(id)
          want   = mon[:status] == "quarantined"
          drift << { token_id: id, what: "frozen", registry: want, chain: frozen } if frozen != want
        end

        # Every registry move of a tokenized Pokemon has its receipt (any status: the
        # in-flight ones are lag, a MISSING one is a swap that wrote no event).
        tokenized = @db[:asset_tokens].where(asset_kind: KIND).select(:asset_id)
        receipts  = @db[:asset_events].where(asset_kind: KIND, kind: "transfer").select(:asset_id, :ref)
        @db[:monster_transfers].where(uid: tokenized)
                               .exclude(Sequel.lit("(uid, trade_id) IN ?", receipts))
                               .order(:id).each do |x|
          drift << { token_id: x[:uid], what: "transfer without a receipt", registry: "trade #{x[:trade_id]} #{x[:from_account_id]}->#{x[:to_account_id]}", chain: nil }
        end

        # The contract holds exactly the tokens the registry confirmed minting.
        confirmed = @db[:asset_tokens].where(asset_kind: KIND).exclude(mint_tx: nil).count
        supply    = @adapter.total_supply
        if supply != confirmed
          drift << { token_id: nil, what: "supply", registry: confirmed, chain: supply }
        end

        report = { tokens: tokens.size, checked: tokens.size - in_flight, in_flight: in_flight, drift: drift, ok: drift.empty? }
        log(report)
        report
      end

      private

      def log(r)
        if r[:ok]
          @log.call("chain: audit ok - #{r[:checked]} token(s) agree with the chain#{r[:in_flight].positive? ? ", #{r[:in_flight]} in flight" : ''}")
        else
          @log.call("chain: audit DRIFT - #{r[:drift].size} finding(s) over #{r[:checked]} token(s)")
          r[:drift].each do |d|
            @log.call("chain:   #{d[:token_id] ? "token #{d[:token_id]}" : 'contract'}: #{d[:what]} - registry #{d[:registry].inspect}, chain #{d[:chain].inspect}")
          end
        end
      end
    end
  end
end
