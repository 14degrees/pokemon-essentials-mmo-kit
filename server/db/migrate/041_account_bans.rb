# frozen_string_literal: true

# Moderation: an operator suspends an account (bin/pemk_admin.rb). A ban is a row, never
# an edit of the account: its reason, who set it and until when stay on record, and a
# lifted ban stays too. An account is banned while one of its rows is not lifted and
# has no end, or an end still ahead.
Sequel.migration do
  change do
    create_table(:account_bans) do
      primary_key :id, type: :Bignum
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      String   :reason,     text: true
      String   :banned_by,  size: 64
      DateTime :created_at, null: false
      DateTime :ends_at                        # nil: until lifted
      DateTime :lifted_at
      String   :lifted_by,  size: 64

      index %i[account_id]
    end
  end
end
