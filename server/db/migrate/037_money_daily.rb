# frozen_string_literal: true

# Money authority: per account and day (UTC), the money of sales no source the server
# owns explains - local-tier units it never sold itself. PEMK_MONEY_LOCAL_DAILY bounds it
# (Sam, 2026-09-29: $10,000).
Sequel.migration do
  change do
    create_table(:money_daily) do
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      Date    :day,        null: false
      Bignum  :local_sold, null: false, default: 0

      primary_key %i[account_id day]
    end
  end
end
