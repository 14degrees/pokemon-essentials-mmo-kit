# frozen_string_literal: true

# Money authority M1a: the prizes clients claim, and what the server made of them.
#
# money_claims: one row per claim a client named by a nonce, with its verdict (paid,
# suspect, away, unknown, repeat, cadence, order), the mode that judged it, the amount
# claimed and the amount the server would pay. A claim asked again gets its first
# verdict. sealed_at: the first fresh money frame after it (the prize reached the ledger);
# voided_at: a fresh login found it unsealed (the save may not have kept the battle), so
# the battle may be fought and claimed again.
#
# money_payouts: what each account has been paid for, one row per key -
# "trainer:TYPE:NAME:VERSION" and, for a battle that cannot be fought again,
# "event:MAP:EVENT" (the branches of one event are one battle). A rematch repeats: its
# paid_at is its contact's clock.
Sequel.migration do
  change do
    create_table(:money_claims) do
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      Bignum   :nonce,      null: false
      String   :kind,       null: false   # trainer
      String   :verdict,    null: false
      String   :mode,       null: false   # shadow | on
      Integer  :amount,     null: false
      Integer  :accepted,   null: false
      Integer  :map
      column   :trainers,   :jsonb        # [[type, name, version, map, event], ...]
      DateTime :sealed_at
      DateTime :voided_at
      DateTime :created_at, null: false

      primary_key %i[account_id nonce]
      index %i[account_id created_at]
    end

    create_table(:money_payouts) do
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      String    :key,       null: false
      Bignum    :nonce,     null: false   # the claim that paid it
      TrueClass :rematch,   null: false, default: false
      DateTime  :paid_at,   null: false

      primary_key %i[account_id key]
    end
  end
end
