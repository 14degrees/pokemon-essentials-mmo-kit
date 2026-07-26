# frozen_string_literal: true

# Cooldown timestamps for repeatable events ($PokemonGlobal.eventvars).
#
# pbSetEventTime stamps the current time under [map_id, event_id] and sets the
# event's self-switch A. The event's own expiry check clears A once the delay has
# passed. That pair is the engine's berry plant / daily respawn mechanism.
#
# 020 deliberately stopped banking those self-switches as monotonic facts - doing
# so froze the event as permanently done. But leaving the pair entirely to the
# client means a rollback resets the timer and the respawn can be farmed early.
# The timestamp is the honest monotonic half: each harvest moves it forward and
# nothing in normal play moves it back, so the server keeps the maximum.
#
# At login the client gets the stored times and applies one only where its own is
# missing or older, restoring self-switch A alongside it. Strictly-greater is what
# keeps this safe: an event that legitimately expired reports the same timestamp
# with A off, matches, and is left alone rather than being re-locked.
#
# Keyed "map:event" to match the manifest's repeatable list; only events on that
# list are stored, so an eventvars entry a fan script parked there never travels.
Sequel.migration do
  change do
    create_table(:event_cooldowns) do
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      String   :event_key, null: false           # "13:17"
      Bignum   :at,        null: false           # unix seconds, monotonic per key
      DateTime :updated_at, null: false, default: Sequel::CURRENT_TIMESTAMP

      primary_key %i[account_id event_key]
    end
  end
end
