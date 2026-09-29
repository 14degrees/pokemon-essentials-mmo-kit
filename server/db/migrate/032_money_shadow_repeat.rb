# frozen_string_literal: true

# Money authority M1b: money_shadow.repeat - the prize of a claim just refused as already
# paid. The next money frame shows it: that part of its excess is a repeat (a crash may
# have undone the save's record of the win; a save edit re-arming the trainer is the flag
# audit's to see), logged apart from money no source explains. The next frame consumes it.
Sequel.migration do
  change do
    alter_table(:money_shadow) do
      add_column :repeat, :Bignum, null: false, default: 0
    end
  end
end
