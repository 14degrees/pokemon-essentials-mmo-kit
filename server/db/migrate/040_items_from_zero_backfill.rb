# frozen_string_literal: true

# Item authority: an account that had never played when accounts.items_from_zero came -
# no save, no inventory record - has no history to trust either, so its first full
# snapshot is judged from nothing too. A fact fixed now: sending a save later changes
# nothing (a live check of it could be satisfied by the client). Older accounts that
# played keep their first snapshot as the baseline.
Sequel.migration do
  up do
    self[:accounts].where(items_from_zero: false)
                   .exclude(id: self[:characters].select(:account_id))
                   .exclude(id: self[:inventory_snapshots].select(:account_id))
                   .update(items_from_zero: true)
  end

  down do
    # Nothing to undo: the flag only has a first snapshot judged.
  end
end
