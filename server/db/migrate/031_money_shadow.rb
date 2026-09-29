# frozen_string_literal: true

# Money authority M1b (shadow): per account, s - the balance M2 would keep: the prizes it
# would pay, the server's own deals, the spends - and c - the client's balance as the
# server last knew it. A fresh money frame v above s logs what no source explains and was
# not already above s: max(0, v - s) - max(0, c - s). The excess is derived each time,
# never kept; s is never floored (a purchase it cannot cover is logged). A boot with the
# money authority off empties the table, so a stretch without measurement never counts.
Sequel.migration do
  change do
    create_table(:money_shadow) do
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      Bignum   :s,          null: false
      Bignum   :c,          null: false
      DateTime :updated_at, null: false

      primary_key [:account_id]
    end
  end
end
