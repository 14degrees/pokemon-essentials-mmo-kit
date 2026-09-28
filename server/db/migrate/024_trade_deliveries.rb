# frozen_string_literal: true

# A traded Pokemon reaches the receiver's disk only with its next save. The swap is the
# registry's (monster_transfers), but the Pokemon itself travels from client to client
# as the Marshal body its sender locked, which the server relayed and kept nowhere: a
# receiver that crashed before that save, or never got the trade's result, lost it.
#
# One row per (receiver, uid) holds that body until a save after the receiver's
# :trade_applied lands (then the row goes). Anything still held is sent again when the
# receiver authenticates; its client adds the Pokemon only when that uid is missing.
Sequel.migration do
  change do
    create_table(:trade_deliveries) do
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      Bignum    :uid,        null: false
      String    :trade_id,   null: false
      File      :body,       null: false       # the Pokemon as its sender locked it (Marshal)
      TrueClass :acked,      null: false, default: false
      DateTime  :created_at, null: false

      primary_key %i[account_id uid]
    end
  end
end
