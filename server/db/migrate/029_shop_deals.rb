# frozen_string_literal: true

# E3: the gated Mart deals a client names by a nonce that went through, recorded in the
# deal's own transaction. A request whose nonce is recorded gets the recorded outcome and
# never runs twice. A client that gave up waiting asks again by the nonce; a nonce with
# no deal (never received, or refused: nothing moved) is then recorded as void, so a
# copy of the request still on its way is refused. The sweep drops rows older than a
# week.
Sequel.migration do
  change do
    create_table(:shop_deals) do
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      Bignum   :nonce,      null: false
      String   :outcome,    null: false   # grant | void
      String   :op                        # buy | sell
      String   :item
      Integer  :quantity
      String   :field                     # money | battle_points
      Integer  :delta                     # what the deal moved the balance by
      Integer  :bonus                     # the Premier Balls a purchase added
      DateTime :created_at, null: false

      primary_key %i[account_id nonce]
      index :created_at
    end
  end
end
