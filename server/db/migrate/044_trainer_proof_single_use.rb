# frozen_string_literal: true

# Trainer proof P3, after its review: one win proves one prize. A seed row holds one won
# battle (every lost attempt may name it; a second win on it is a copy), and one claim
# (a second claim naming the same battle is another prize for it).
Sequel.migration do
  change do
    alter_table(:battle_records) do
      add_index :trainer_battle_id, unique: true, where: Sequel.lit("outcome = 1 AND trainer_battle_id IS NOT NULL"),
                                    name: :battle_records_one_win_per_seed
    end
    alter_table(:money_claims) do
      add_index :trainer_battle_id, unique: true, where: Sequel.lit("trainer_battle_id IS NOT NULL"),
                                    name: :money_claims_one_claim_per_seed
    end
  end
end
