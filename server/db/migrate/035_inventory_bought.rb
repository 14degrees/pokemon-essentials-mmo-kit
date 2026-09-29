# frozen_string_literal: true

# Money authority: inventory_snapshots.bought { item => n } - units of each item the
# server itself sold this account (gated Mart purchases). Reselling them is money the
# server owns even when the item is a local tier the record never judges (the demo's
# Potions and Great Balls are). Each snapshot lowers it to what the possession may still
# hold, and a sale spends it first, so a conjured unit can never pass for a bought one.
Sequel.migration do
  change do
    alter_table(:inventory_snapshots) do
      add_column :bought, :jsonb, null: true
    end
  end
end
