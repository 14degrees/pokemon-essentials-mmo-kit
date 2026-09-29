# frozen_string_literal: true

# Money authority M1c: encounter_rolls.payday_at - the Pay Day claim of the battle this
# server-minted foe was fought in. A wild battle's Pay Day is claimed once per mint, apart
# from the catch (caught_at) and the uid mint (claimed_at) the same roll can also back.
Sequel.migration do
  change do
    alter_table(:encounter_rolls) do
      add_column :payday_at, DateTime, null: true
    end
  end
end
