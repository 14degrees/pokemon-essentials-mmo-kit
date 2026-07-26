# frozen_string_literal: true

# Bind a fact's durability to the client's save commit.
#
# Step 4 banked a fact the moment a snapshot reported the switch ON. The snapshot
# flushes every few seconds; the save blob lands on its own (slower) cadence. In
# the window between them the server holds a fact the client has not written to
# disk - and if the player crashes or quits there, the next login restores the
# switch onto a save that never got the thing the event granted alongside it. A
# gym flag comes back without its badge and the leader is no longer rebattleable:
# progress that cannot be finished.
#
# So a fact is now PENDING when granted and DURABLE once a save blob arrives that
# provably contains it. granted_seq is the :flags channel seq the fact rode in on;
# the save frame carries the client's current flags seq, and everything at or below
# it is in the blob (Checkpoint#commit flushes the sync channels before serializing).
# Only durable facts are handed back at login.
#
# Existing rows are backfilled durable: they have already been materialized into
# live saves, and retroactively withholding them would look like losing progress.
Sequel.migration do
  change do
    alter_table(:progression_facts) do
      add_column :granted_seq, Integer, null: false, default: 0
      add_column :durable_at, DateTime, null: true
    end
    run "UPDATE progression_facts SET durable_at = first_at WHERE durable_at IS NULL"
  end
end
