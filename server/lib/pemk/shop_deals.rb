# frozen_string_literal: true

module PEMK
  # E3: the gated Mart deals a client named by a nonce that went through. A deal runs
  # once: asked again - its answer lost with a socket, or later than the client would
  # wait - it is answered from here. A refused deal moved nothing and needs no row: asked
  # about, it is void like one that never arrived.
  class ShopDeals
    KEEP_SEC = 7 * 24 * 3600   # a week: far past any reconnect
    NONCE    = (1...(1 << 62)).freeze
    VOID_MAX = 50              # void rows kept per account: an honest client makes one per lost request

    def initialize(db)
      @db = db
    end

    # -> the nonce a request names, or nil
    def self.nonce(value)
      value.is_a?(Integer) && NONCE.cover?(value) ? value : nil
    end

    # -> the recorded deal (a Hash), or nil
    def find(account_id, nonce)
      @db[:shop_deals].where(account_id: account_id, nonce: nonce).first
    end

    # A deal that went through, in its own transaction; or a void.
    def record(account_id, nonce, outcome, op: nil, item: nil, quantity: nil, field: nil, delta: nil, bonus: nil,
               now: Time.now)
      @db[:shop_deals].insert_conflict.insert(
        account_id: account_id, nonce: nonce, outcome: outcome, op: op&.to_s, item: item, quantity: quantity,
        field: field&.to_s, delta: delta, bonus: bonus, created_at: now
      )
    end

    # A nonce asked about that no deal went through under: nothing moved, and nothing will
    # - the request, should it still arrive, finds it void. Past VOID_MAX rows the answer
    # stands unrecorded: a client asking about nonces it never sent only gets told no.
    # -> the recorded deal (the deal's own, when it got there first)
    def void(account_id, nonce, now: Time.now)
      if @db[:shop_deals].where(account_id: account_id, outcome: "void").count < VOID_MAX
        record(account_id, nonce, "void", now: now)
      end
      find(account_id, nonce) || { outcome: "void" }
    end

    def prune(now: Time.now)
      @db[:shop_deals].where { created_at < now - KEEP_SEC }.delete
    end
  end
end
