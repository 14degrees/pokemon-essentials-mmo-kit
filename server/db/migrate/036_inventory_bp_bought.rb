# frozen_string_literal: true

# Money authority: inventory_snapshots.bp_bought { item => n } - units of each item the
# account bought with battle points at the gated exchange. Battle points are the client's
# word until BP authority, so those units never sell for money (Sam, 2026-09-29): a Mart
# sale may not reach into them. Each snapshot lowers the count to what the possession
# may still hold, as for the units bought with money.
Sequel.migration do
  change do
    alter_table(:inventory_snapshots) do
      add_column :bp_bought, :jsonb, null: true
    end
  end
end
