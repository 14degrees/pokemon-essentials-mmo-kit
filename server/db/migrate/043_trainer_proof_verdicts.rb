# frozen_string_literal: true

# Trainer proof P3 (docs/TRAINER-PROOF-DESIGN.md): a prize claim names the seed of the
# battle it was won in, and gets a verdict once that battle's record is replayed -
# proven (the replay agrees: a win, the same prize), refuted, or unprovable. The replay
# keeps what its engine paid and why it disagreed.
Sequel.migration do
  change do
    alter_table(:money_claims) do
      add_foreign_key :trainer_battle_id, :trainer_battles, type: :Bignum, null: true, on_delete: :set_null
      add_column :proof, String, size: 16, null: true          # proven | refuted | unprovable
      add_column :proof_record_id, :Bignum, null: true         # the record it was judged on
      add_column :proof_at, DateTime, null: true
      add_index :trainer_battle_id
    end

    alter_table(:battle_records) do
      add_column :replay_prize, Integer, null: true            # what the replay's engine paid (trainer)
      add_column :replay_detail, String, text: true, null: true # why it disagreed, when it did
      add_column :team_check, String, size: 16, null: true     # ok | refuted | unprovable: the player's side
    end
  end
end
