# frozen_string_literal: true

# Item authority, step E0: one record for every place that holds items.
#
# The bag record (004) is restored at login, but the PC item storage, the mailbox and
# the items Pokemon hold lived only in the save blob, written on another channel: a
# PC withdrawal or a taken held item reached the server with the next bag flush while
# its source changed only with the next blob, and a crash in between duplicated it.
#
# The same snapshot now carries every store, recorded in one row with the bag:
#   stores_seq  the bag seq of the last snapshot that carried them all; an older client
#               sends the bag alone, and the stores are used only while this equals
#               last_seq
#   pc          { item => qty }, NULL while the game has never created its PC storage
#   mailbox     { item => count } (the letters' texts stay in the save)
#   held        { item => count } over every Pokemon the player owns
#   holders     { uid => item }, which Pokemon held what: a hint for the login restore
#
# All nullable: a row from before this step has none of them, which reads as "not
# known yet", and the first full snapshot sets them.
Sequel.migration do
  change do
    alter_table(:inventory_snapshots) do
      add_column :stores_seq, Integer, null: true
      add_column :pc,         :jsonb,  null: true
      add_column :mailbox,    :jsonb,  null: true
      add_column :held,       :jsonb,  null: true
      add_column :holders,    :jsonb,  null: true
    end
    alter_table(:trade_deliveries) do
      add_column :item, String, null: true   # the held item the escrow carried, as its lock said
    end
  end
end
