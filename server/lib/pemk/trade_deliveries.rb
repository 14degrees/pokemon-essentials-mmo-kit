# frozen_string_literal: true

module PEMK
  # A traded Pokemon is safe only once a save that holds it lands. The swap is the
  # registry's (Trades), but the Pokemon itself travels client to client, so a receiver
  # that died before that save - or never got the trade's result - lost it for good.
  #
  # This keeps the body the partner locked, from the swap until then:
  #   stored   in the swap's own transaction
  #   acked    when the client reports it in its party or a box (:trade_applied)
  #   dropped  by the first save after that report (TCP keeps the order, so that save
  #            holds it)
  # Whatever is still held when the receiver authenticates is sent again
  # (:trade_redeliver). The client adds the Pokemon only when its uid is not already
  # there, so a repeat is harmless. A fresh login un-acks what no save sealed: the save
  # it loads cannot hold it.
  class TradeDeliveries
    def initialize(db, logger: nil)
      @db  = db
      @log = logger || ->(_m) {}
    end

    # rows: [{ account_id:, uid:, trade_id:, body: }]. Called inside the trade's
    # transaction, so the swap and its deliveries commit together.
    def store(rows, now: Time.now)
      rows.each do |r|
        fields = { trade_id: r[:trade_id], body: Sequel.blob(r[:body]), acked: false, created_at: now }
        @db[:trade_deliveries]
          .insert_conflict(target: %i[account_id uid], update: fields)
          .insert(fields.merge(account_id: r[:account_id], uid: r[:uid]))
      end
    end

    def ack(account_id, trade_id)
      @db[:trade_deliveries].where(account_id: account_id, trade_id: trade_id).update(acked: true)
    end

    # A save landed: what the client reported before it is on disk. -> rows dropped.
    def seal(account_id)
      @db[:trade_deliveries].where(account_id: account_id, acked: true).delete
    end

    # A fresh login loads a save that holds no unsealed delivery.
    def unack(account_id)
      @db[:trade_deliveries].where(account_id: account_id, acked: true).update(acked: false)
    end

    # -> [{ uid:, trade_id:, body: }] still owed to +account_id+. A uid it no longer
    # owns (traded on again, or evicted) is dropped instead.
    def pending(account_id)
      rows  = @db[:trade_deliveries].where(account_id: account_id, acked: false).all
      owned = @db[:monsters].where(id: rows.map { |r| r[:uid] }, owner_account_id: account_id).select_map(:id)
      gone  = rows.map { |r| r[:uid] } - owned
      @db[:trade_deliveries].where(account_id: account_id, uid: gone).delete unless gone.empty?
      rows.select { |r| owned.include?(r[:uid]) }
          .map { |r| { uid: r[:uid], trade_id: r[:trade_id], body: r[:body].to_s } }
    end
  end
end
