# frozen_string_literal: true

# Chain C1 - the asset outbox. The server stays the owner of record for every Pokemon
# (monsters, monster_transfers); the chain is a receipt of what the server proved. These
# two tables are the only seam between them, so the game never waits on a node:
#
#   asset_tokens  - the Pokemon the policy tokenized (a server-proven shiny, a listed
#                   species), one row per uid, the token id = the uid. Written in the
#                   mint's own transaction; a replayed mint conflicts and writes nothing.
#   asset_events  - append-only, id-ordered: what the chain must reflect (mint, transfer,
#                   freeze), each written in the transaction that changed the registry,
#                   so a committed swap always has its receipt queued and a rolled-back
#                   one never does. The relayer (bin/pemk_chain.rb) drains it in order
#                   and stamps each row sent -> confirmed (tx hash), or failed (kept, with
#                   its error, retried); shadow rows are stamped without a chain.
#
# The account FKs cascade (an account is never deleted in production; the test suite
# clears accounts, and the chain keeps its own copy of every receipt anyway).
Sequel.migration do
  change do
    create_table(:asset_tokens) do
      String      :asset_kind,        null: false, default: "monster"   # monster | card (later)
      Bignum      :asset_id,          null: false                       # monsters.id for a monster
      Bignum      :token_id,          null: false                       # on the contract; = asset_id for monsters
      String      :reason,            null: false                       # shiny | species - why the policy took it
      String      :species,           null: false
      String      :origin,            null: true                        # wild_caught | wild | client | nil (pre-provenance)
      TrueClass   :shiny,             null: false, default: false
      foreign_key :issuer_account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      String      :mint_tx,           null: true                        # stamped by the relayer once minted
      DateTime    :created_at,        null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime    :minted_at,         null: true

      primary_key %i[asset_kind asset_id]
      index :token_id, unique: true
    end

    create_table(:asset_events) do
      primary_key :id, type: :Bignum
      String      :kind,            null: false                     # mint | transfer | freeze | unfreeze
      String      :asset_kind,      null: false, default: "monster"
      Bignum      :asset_id,        null: false
      Bignum      :token_id,        null: false
      foreign_key :from_account_id, :accounts, type: :Bignum, null: true, on_delete: :cascade
      foreign_key :to_account_id,   :accounts, type: :Bignum, null: true, on_delete: :cascade
      String      :ref,             null: true                      # trade_id, quarantine reason...
      column      :payload,         :jsonb, null: false, default: Sequel.lit("'{}'::jsonb")
      String      :status,          null: false, default: "pending" # pending | sent | confirmed | failed | shadow
      Integer     :attempts,        null: false, default: 0
      String      :tx_hash,         null: true
      String      :last_error,      null: true
      DateTime    :created_at,      null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime    :sent_at,         null: true
      DateTime    :confirmed_at,    null: true

      index %i[status id]
      index %i[asset_kind asset_id]
    end
  end
end
