# The chain: a receipt of what the server proved

Design and C1 (2026-09-30). A private game among friends wants its rare Pokemon to
be tokens: tradeable, provably scarce, with a history anyone can read. The server
already owns every Pokemon (`monsters`, its UIDs, `monster_transfers`) and every trade
(one atomic swap or nothing). The chain does not replace that. It mirrors the part of
it that gains from being outside the server's control, and nothing else.

## 1. What goes on chain, and what does not

On chain:

- **Ownership of scarce Pokemon.** One token per Pokemon the policy takes (below); the
  token id IS the server's uid. Not every Rattata: a token for a common Pokemon costs a
  transaction and proves nothing the registry does not.
- **The supply caps.** The contract refuses to mint a species past its cap, whoever
  asks - the operator included. This is the one thing the chain does that Postgres
  cannot: the scarcity is credible even against the person running the server.
- **Provenance.** The mint names the account, the species, whether it is shiny and what
  the server knew of its origin (`wild_caught`, `wild`, `client`); every move names the
  trade; a quarantine freezes the token and a pardon thaws it. All of it is events a
  buyer can read.

Not on chain: game state (party, boxes, position, flags, saves, battle records); in-game
money (the ledger is already append-only and audited); any mutable trait of a Pokemon
(level, moves, EVs, nickname); and above all **anything the server has not proved**. A
shiny minted on the client's word would be a lie with a receipt.

## 2. The model: the server writes, the chain reflects

The server stays the owner of record. The chain is a **receipt** of what it did, written
by one key, the operator's, through one contract that refuses every other sender.
Players hold no wallets in C1: every token sits in the vault (the operator's address) and
is attributed to a PEMK account number. Nothing in the game ever reads the chain.

Why this and not player wallets: two owners of record is a second system. If a token
could move on chain outside the game, the server would have to watch the chain and
evict a Pokemon whose token left, escrow across the two, and resolve every race between
them. That is a real later layer (section 6), to be chosen deliberately, not drifted
into.

## 3. The piping (C1, built)

```
registry write ──same transaction──▶ asset_tokens / asset_events ──NOTIFY──▶ relayer ──▶ PemkAssets
(mint, swap, quarantine)              (the outbox, Postgres)                  (bin/pemk_chain.rb)   (the contract)
```

- **The policy** (`PEMK::AssetEvents#reason_for`) takes a Pokemon when it is a shiny the
  server minted itself AND saw caught (origin `wild_caught`, its encounter roll shiny;
  `PEMK_CHAIN_SHINY`, on by default), or when its species is listed
  (`PEMK_CHAIN_SPECIES=MEWTWO,MEW,...` - the legendaries), from any origin. A listed
  species from a client-made Pokemon (a starter, a gift, a save edit) still gets a
  token, and the token says `client`: visible, not hidden.
- **The outbox.** `asset_tokens` (one row per tokenized uid) and `asset_events`
  (append-only: `mint`, `transfer`, `freeze`, `unfreeze`) are written in the SAME
  transaction as the registry change: inside `Monsters#mint_one` after the insert,
  inside `Trades#execute_trade` after every CAS matched, inside the D8 verdict sweep's
  quarantine, in the pardon console. A committed swap always has its receipt queued; a
  rolled-back one never does. The write ends with `NOTIFY pemk_assets`, which Postgres
  delivers at commit and drops on rollback.
- **The relayer** (`bin/pemk_chain.rb loop`) is a separate process. It `LISTEN`s, drains
  the queue in id order one event at a time, and stamps each row `confirmed` with its
  transaction hash. It reads the chain before each write, so a mint of a token that
  exists, a move to the account that holds it, or a freeze already in place is confirmed
  without a transaction: a crash between a transaction and its stamp is harmless, and a
  restarted relayer never double-writes. A failure stamps the row `failed` with its error
  and STOPS the pass - order is the receipt's meaning - and the row is retried after a
  backoff that grows with its attempts (5 s, 10 s, ... 5 min). `status` shows it,
  `retry <id>` clears the wait.
- **The contract** (`server/chain/PemkAssets.sol`, its ABI in `PemkAssets.json`) keeps
  per token: the account, the kind (monster now, card later), species, shiny, origin,
  frozen. Writes: `mint`, `move`, `setFrozen`, `setCap`, operator only. Reads: an ERC-721
  subset (`name`, `symbol`, `ownerOf`, `balanceOf`, the `Transfer` event) so explorers and
  wallets list the tokens, plus `accountOf`, `assetOf`, `frozen`, `supplyOf`. A cap can
  never be set below what is minted.
- **The modes.** `PEMK_CHAIN=off` (default) writes nothing. `shadow` writes the same
  rows as `on` and the relayer stamps them `shadow` without a chain: the log shows what
  `on` would have sent. `on` relays. The game never waits on the chain in any mode.

What is NOT verified by the chain, because it is not verified by the server either:
the matrix in `ARCHITECTURE-SECURITY.md` still holds. A token is exactly as honest as
the row behind it. For `shiny` that is a server-minted encounter under
`PEMK_BATTLE_ENFORCE_ENCOUNTERS=on` and a server-rolled catch under
`PEMK_BATTLE_ENFORCE_CATCHES=on`; without them no shiny is ever tokenized, because no
roll exists to prove it. For a listed species the origin on the token is the honesty.

## 4. Running it

```bash
# a local node for development (Hardhat or Anvil), in another window
npx hardhat node                                   # http://127.0.0.1:8545, funded keys printed

# once: compile (needs node + solc; the committed PemkAssets.json is current) and deploy
cd server && bash chain/build.sh
PEMK_CHAIN_RPC=http://127.0.0.1:8545 PEMK_CHAIN_KEY=<operator key> bundle exec ruby bin/pemk_chain.rb deploy
#   -> set PEMK_CHAIN_CONTRACT=0x...

# the server (rows are written from now on) and the relayer, each with the env above
PEMK_CHAIN=on PEMK_CHAIN_SPECIES=MEWTWO,MEW bundle exec ruby bin/pemk_server.rb
PEMK_CHAIN=on ... bundle exec ruby bin/pemk_chain.rb loop

# Pokemon minted before the chain was on
bundle exec ruby bin/pemk_chain.rb backfill
# a species' cap, on the contract
bundle exec ruby bin/pemk_chain.rb cap MEWTWO 3
# what happened
bundle exec ruby bin/pemk_chain.rb status
bundle exec ruby bin/pemk_chain.rb show <uid>
```

`PEMK_CHAIN_KEY` is the operator's private key: a secret, never committed, and on a real
chain a funded account. The relayer needs the `eth` gem (`bundle install --with chain`,
which builds against libsecp256k1: `apt install libsecp256k1-dev` first). The game
server never loads it.

Docker: `docker compose --profile chain up` adds the relayer as a service next to the
server, reading the same `.env`.

## 5. Tests

- `test/asset_events_test.rb` - the policy, the receipts in the mint's and the swap's
  transaction (and none for an aborted or replayed swap), freeze and unfreeze, backfill,
  the relayer's stamps.
- `test/chain_relayer_test.rb` - the relayer against an in-memory contract: order,
  idempotence against chain state, a failure stopping the pass and its backoff, an
  out-of-order transfer refused, shadow.
- `test/chain_evm_test.rb` - the same relayer against a real node and a freshly
  deployed contract; a cap holding against the relayer. Skipped unless `PEMK_CHAIN_RPC`
  and `PEMK_CHAIN_KEY` are set.

## 6. What comes next

- **Supply caps in the server** (C2): the server refusing to mint a capped species in
  the encounter path, so the game agrees with the contract instead of learning at relay
  time. Legendaries in Essentials are static map events, not wild encounters: that path
  (`interact_claim`, gifts) is only partly server-owned today and comes first.
- **The marketplace** (C3): listings priced in the ledger's money, a buy that debits,
  credits, swaps and writes its receipt in one transaction. Needs the PC boxes projected
  to the server, or a listed Pokemon could be hidden in one.
- **Cards** (C4): a second registry with the same shape (owner, issuer, status, flagged;
  set, number, grade, cert id), minted by the operator's console, `kind = 1` on the same
  contract.
- **Player wallets** (C5, the deliberate choice): `account_wallets` linked by a signed
  nonce, tokens moved to the player's address, and then the inbound watcher and escrow
  that make the chain an owner of record.
