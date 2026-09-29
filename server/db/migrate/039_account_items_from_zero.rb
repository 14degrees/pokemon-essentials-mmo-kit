# frozen_string_literal: true

# Item authority: accounts.items_from_zero - the account was registered while item
# authority ran, so the server saw its inventory from nothing: its first full snapshot is
# judged against an empty one, never taken as a trusted baseline (a new account declaring
# 999 Proteins would otherwise own them, and sell them for money). Older accounts keep
# their first snapshot as the baseline.
Sequel.migration do
  change do
    alter_table(:accounts) do
      add_column :items_from_zero, TrueClass, null: false, default: false
    end
  end
end
