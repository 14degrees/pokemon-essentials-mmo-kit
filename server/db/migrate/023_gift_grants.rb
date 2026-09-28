# frozen_string_literal: true

# Step 6 of sovereign variables: the payout gate (PEMK_GIFT_ENFORCE).
#
# A one-shot NPC gift (the world export marks it: one payout, after which the event
# turns to another page) is paid only once the server grants it, and once per
# account. One row per (account, event) walks granted -> applied -> sealed, or is
# voided when a fresh login loads a bag that cannot hold it (see GiftGrants).
#
# nonce: the client's id for the request, so a request whose reply was lost can be
# sent again and granted again, while any other request for the same payout - an
# event re-armed to pay twice - is refused. conn: the connection the grant went out
# on (random per connection), which tells a reconnect's first bag snapshot which
# grants it settles.
Sequel.migration do
  change do
    create_table(:gift_grants) do
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      Integer  :map,      null: false
      Integer  :event,    null: false
      String   :item,     null: false
      Integer  :quantity, null: false
      Bignum   :nonce                            # null: paid before the gate existed
      String   :state,    null: false            # granted | applied | sealed | void
      Bignum   :conn
      Integer  :denied,   null: false, default: 0
      DateTime :granted_at, null: false
      DateTime :updated_at, null: false

      primary_key %i[account_id map event]
    end
  end
end
