# frozen_string_literal: true

# Item authority E4: inventory_snapshots.vanished { uid => item }. A Pokemon that dropped
# out of the snapshots while the registry still gives it to the account (a save that
# lost a traded Pokemon, a client hiding one), with the item it held: its drop settles no
# debt, and the same Pokemon coming back with the same item is not an increase. A
# released Pokemon never comes back and stays listed, harmlessly.
Sequel.migration do
  change do
    alter_table(:inventory_snapshots) do
      add_column :vanished, :jsonb, null: true
    end
  end
end
