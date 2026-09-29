# frozen_string_literal: true

# Money authority M1c: money_claims.payday_at - the Pay Day claim a trainer battle's prize
# claim has backed. A trainer battle scatters its coins once: a second Pay Day claim naming
# the same prize credits nothing (a review found one prize could back any number).
Sequel.migration do
  change do
    alter_table(:money_claims) do
      add_column :payday_at, DateTime, null: true
    end
  end
end
