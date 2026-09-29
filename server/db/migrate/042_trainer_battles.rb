# frozen_string_literal: true

# Trainer proof P2 (docs/TRAINER-PROOF-DESIGN.md): the seed of a trainer battle. One per
# account and placement (map, event, trainer) while it is open: asked again, the same
# answer, so a client cannot shop for a seed it likes. It changes only once a battle on
# it is proven won, or after it expires - never on a loss (each attempt's record names
# the same seed; only a proven win will count).
Sequel.migration do
  change do
    create_table(:trainer_battles) do
      primary_key :id, type: :Bignum
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      Integer  :map_id,     null: false
      Integer  :event_id,   null: false
      String   :tr_type,    null: false, size: 64
      String   :tr_name,    null: false, size: 64
      Integer  :tr_version, null: false
      Bignum   :seed,       null: false
      String   :state,      null: false, default: "open", size: 16   # open | proven | expired
      DateTime :issued_at,  null: false
      Bignum   :record_id                                         # the record proven won on it
      DateTime :closed_at

      index %i[account_id map_id event_id tr_type tr_name tr_version], unique: true,
            where: Sequel.lit("state = 'open'"), name: :trainer_battles_one_open
      index %i[account_id seed], unique: true
    end

    alter_table(:battle_records) do
      add_foreign_key :trainer_battle_id, :trainer_battles, type: :Bignum, null: true, on_delete: :set_null
      add_index :trainer_battle_id
    end
  end
end
