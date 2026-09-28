# frozen_string_literal: true

# Item authority, after an adversarial review of the ledger.
#
# inventory_snapshots.judged: the totals ({item => n}, every store) of the last snapshot
# the item ledger judged. Only a snapshot that carries every store is judged, always
# against this, so a stretch of bag-only snapshots (the Bug Contest, a collection too big
# to send) neither reads a store move as an increase nor lets an increase slip in. The
# server's own moves (a sale, a Pokemon traded away) lower it too.
#
# gift_grants.voids: how many times a fresh login voided this payout. A crash may cost
# a payout once; the second time it stays paid, so a client that never reports a gift
# applied cannot have it paid again at every login.
Sequel.migration do
  change do
    alter_table(:inventory_snapshots) do
      add_column :judged, :jsonb, null: true
    end
    alter_table(:gift_grants) do
      add_column :voids, Integer, null: false, default: 0
    end
  end
end
