# frozen_string_literal: true

# Item authority E2: the increases the server can explain, and the ones it cannot yet.
#
# A source the server decides or checks - a pickup it granted, a gift it paid, a purchase
# it made, the item a traded Pokemon brought - leaves a credit (qty > 0): that many of
# that item may appear in the account's possession. An increase no credit covers leaves a
# debt (qty < 0) that a source heard shortly after can still pay; one left open past
# expires_at is an unexplained increase. Credits expire unused, and go at a fresh login.
#
# pc_started: the PC item storage has been seen once, so its start items were given.
# explained: a delivered Pokemon arrived holding its item, which that delivery explained;
# a fresh login re-arms it (the save it loads lacks the Pokemon, which comes again).
Sequel.migration do
  change do
    create_table(:item_credits) do
      primary_key :id, type: :Bignum
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      String   :item,       null: false
      Integer  :qty,        null: false          # > 0 a credit, < 0 a debt; what is left of it
      String   :source,     null: false          # pickup | gift | shop | trade | pc_start | seen ...
      String   :ref                              # where from: "map:x:y", "map:event", a trade id
      DateTime :created_at, null: false
      DateTime :expires_at, null: false

      index %i[account_id item]
      index :expires_at
    end

    alter_table(:inventory_snapshots) do
      add_column :pc_started, TrueClass, null: false, default: false
    end
    alter_table(:trade_deliveries) do
      add_column :explained, TrueClass, null: false, default: false
    end
  end
end
