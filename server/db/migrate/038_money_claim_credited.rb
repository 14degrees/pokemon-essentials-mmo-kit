# frozen_string_literal: true

# Money authority M3: money_claims.credited - what the server itself paid into the ledger
# for the claim (enforcement on). A fresh login that voids the claim takes back exactly
# that; a claim judged in shadow credited nothing (its money came with the client's frame).
Sequel.migration do
  change do
    alter_table(:money_claims) do
      add_column :credited, Integer, null: false, default: 0
    end
  end
end
