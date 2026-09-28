# frozen_string_literal: true

# Step 5 of sovereign variables: in-session enforcement (PEMK_FLAG_ENFORCE).
#
# The server's mirror of the owned switches, variables and self-switches is built
# from the writes the game's own events make (the delta stream). With enforcement
# on, a snapshot that disagrees with it means the state changed some other way (a
# memory or save edit): the server keeps its mirror and repairs the client.
#
# The mirror must be judged against DURABLE state at login, like the progression
# facts (020): a value the client set after its last save and lost in a crash must
# not come back without what went with it. So the server keeps the mirror exactly
# as it stood at the flags seq each saved blob carries (durable_mirror / its seq),
# and the characters row keeps the seq of the blob it stores. At login the mirror
# rebases onto the durable one only when the two seqs match; otherwise the first
# snapshot of the session re-establishes it, which can never repair wrongly.
#
# All columns nullable: absent means "unknown", the pre-022 behaviour.
Sequel.migration do
  change do
    alter_table(:flag_snapshots) do
      add_column :durable_mirror, :jsonb, null: true
      add_column :durable_seq, Integer, null: true
    end

    alter_table(:characters) do
      add_column :flags_seq, Integer, null: true   # the flags seq the stored blob was saved at
    end
  end
end
