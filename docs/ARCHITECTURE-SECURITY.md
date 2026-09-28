# PEMK — Security model & anti-cheat roadmap

This document answers one blunt question: **which player actions does the server
actually verify, and which does it take on faith?** It then lays out the plan
(Milestone 4) to move gameplay itself under server authority.

Guiding principle, borrowed from every serious multiplayer engine:
**never trust the client.** The client renders and predicts; the server decides.
Today PEMK meets that bar for *data* (money, items, Pokémon) but not yet for
*gameplay* (where you are, what you touch, how a battle resolves).

---

## TL;DR — is "pick up the item" secured?

**No.** Picking up an overworld item is computed entirely on the client. There is
**no distance check, no "does this item exist / is it still there" check** on the
server. The client runs the map event, adds the item locally, and then syncs its
**bag** to the server as a snapshot. The server checks the *bag*'s shape and caps
and flags what breaks them (it records the bag either way) — but it never validated the **act** of
picking it up: it doesn't know the item's tile, doesn't know your position, and
can't tell a legitimate pickup from a fabricated one.

So the bag *contents* are server-recorded, but the *event that changed them*
is trusted. That distinction is the whole point of this document, and closing it
is Milestone 4.

---

## What the server verifies today (the honest matrix)

| Capability | Computed by | Server-verified? | If a cheat client lies… |
|---|---|---|---|
| **Login / identity** | server | ✅ yes | can't — bcrypt + opaque session token, no client-claimed id |
| **Money / coins / BP / soot** | client → **server ledger** | ⚠️ capped + audited, not authored | the VALUE is client-pushed; the ledger caps it, makes it append-only and idempotent, and M4-D4 bounds battle gains — but an in-cap lie is persisted |
| **Badges** | client → **server ledger** | ⚠️ capped, not authored | the client computes the bitmask and pushes it on the `:econ` channel; the server enforces the cap, not the earning |
| **Bag, PC item storage, held items** | client → **server record** | ⚠️ recorded and restored together (item authority E0); every increase judged against server-known sources (E2, `PEMK_ITEM_AUTHORITY=shadow`), not refused yet | a crash can no longer duplicate an item moved between them; an item from nowhere is logged `UNEXPLAINED` and reported, but still kept (see [`ITEM-AUTHORITY-DESIGN.md`](ITEM-AUTHORITY-DESIGN.md)) |
| **Pokémon identity & ownership** | server (UIDs) | ✅ yes | can't dupe — UID registry + ownership |
| **Trades** | server | ✅ yes | can't dupe/steal — atomic CAS swap, rollback; a Pokémon the receiver never saved (a crash, a lost result) is sent again |
| **Where a Pokémon came from (pickup, gift, catch)** | **client** | ❌ no | can fabricate acquiring one (within UID rules) |
| **Overworld movement / position** | client → **server-audited** | ✅ enforceable (M4-B) | no-clip / illegal-warp snapped back to last-good tile (opt-in flag; audit-only by default) |
| **Item pickup (distance, existence)** | client → **server-granted** | ✅ enforceable (M4-C) | remote / duplicate pickups denied — distance gate + one-shot + server grant (opt-in flag) |
| **Interacting with NPCs / objects** | client → **server-audited** | ⚠️ partial (M4-C, `PEMK_GIFT_ENFORCE`) | item balls are distance-gated + one-shot; a one-shot NPC **gift** is paid once per account (`PEMK_GIFT_ENFORCE=on`), other gifts are recorded; the event's own conditions (a battle won, a switch on) still run on the client |
| **Story progression (switches, variables, self-switches)** | client → **server-shadowed** | ⚠️ partial (`PEMK_FLAG_STATE`, `PEMK_FLAG_ENFORCE`) | a rollback of saved one-shot progression is detected (`shadow`) and undone at login (`on`); a tracked value edited in session is repaired (`PEMK_FLAG_ENFORCE=on`); writes through the game's own setters are trusted |
| **Wild encounters / which Pokémon appears** | **server** | ✅ enforceable (M4-D2, `PEMK_BATTLE_ENFORCE_ENCOUNTERS=on`) | the server mints species/level/PID/IVs/shiny; the client builds what it is given |
| **Catching** | **server** | ✅ enforceable (M4-D3, `PEMK_BATTLE_ENFORCE_CATCHES=on`) | the server runs the capture formula and rolls the shakes with SecureRandom, clamping every client input |
| **Battle rewards (vs NPC)** | client → **server-bounded** | ✅ detection (M4-D4, `PEMK_BATTLE_ENFORCE_REWARDS`) | EXP/money beyond the closed-form envelope is flagged to the review queue |
| **Battle RNG + outcome (vs NPC)** | **server-seeded, re-simulated** | ✅ enforceable (M4-D7/D8, `PEMK_BATTLE_ENFORCE_RNG` + `PEMK_BATTLE_ENFORCE_RESIM`) | rolls derive from a server seed and are refuted value-by-value at ingest; the battle is re-simulated headless, and a refuted catch is quarantined |
| **Per-mon EXP** | client → **server high-water** | ✅ detection + up-only restore (M4-D6) | a rollback is detected and the mon is restored UP to the server's high-water; EXP is never lowered |
| **Team / set legality** | client → **server-audited** | ✅ detection (M4-D1) | illegal moves/abilities/natures/EVs are flagged (the team block itself is still client-reported — see limits) |
| **PvP battle** | both clients (relayed) | ⚠️ deterministic, not authoritative | a modified client can desync/cheat its own side — D9 (ranked) is the remaining milestone |
| **Spawn / respawn position** | **server** | ✅ enforceable (M4-B) | server seeds spawn from the persisted last-good position |
| **Map transfers / warps** | client → **server-audited** | ✅ enforceable (M4-B) | illegal (non-endpoint) warps snapped back (opt-in flag) |

Read the ✅ rows as: *a hacked client cannot gain here* — **but note the flag**: every
Layer B/C/D protection is **opt-in and OFF by default**. A server running the stock
config is a trusted-players model no matter what this matrix says. See
`docs/GETTING-STARTED.md` for the ramp (each flag goes `off → shadow → on`).

> ⚠️ **Sections below this matrix are older than the matrix.** They were written before
> M4 Layer D shipped and still describe encounters/catches/battles as unprotected. The
> matrix above is the current truth; the narrative below is kept for the threat-model
> reasoning, not for its status claims.

### What the server still does NOT own (audit, 2026-07-25)

The honest counterweight to the ✅ column — these are the real remaining gaps:

| Surface | Status | Consequence |
|---|---|---|
| `$game_variables` / `$game_switches` / `$game_self_switches` | **server-shadowed** (`PEMK_FLAG_STATE`), **held** (`PEMK_FLAG_ENFORCE`) | saved one-shot progression is restored at login in `on`, and a tracked value edited in session is repaired; a one-shot NPC gift is paid once per account with `PEMK_GIFT_ENFORCE` |
| Per-mon stat block (IVs/EVs/moves/ability/nature) | **server first-sight lock** (detection, with `PEMK_BATTLE_ENFORCE_TEAMS`) | IVs, shiny and gender are locked the first time the server sees a mon, and a divergence is flagged (D5 `mon_counterfeit`); moves, EVs, ability and nature change in normal play, so they are recorded but not judged |
| PC boxes, Pokédex, roamers, daycare | **client-only** | not projected at all — "park it in a box" evades the party shadow (their held items are recorded, E0) |
| Party composition | **server-shadowed** | detection-only; the save blob remains authoritative |
| Money / badges | **server-persisted, client-authored** | capped and audited, not earned server-side |
| Overworld position | **enforceable, but** | the no-clip verdict is suppressed whenever the CLIENT declares `:surf`/`:dive` |

### Story state: switches, variables, self-switches (`PEMK_FLAG_STATE`)

Off by default. The server learns the story state from the client and, in `on`,
gives back the progression it has seen saved.

- **`shadow`** — the client sends its switches, variables and self-switches as an
  absolute snapshot, plus each write to an id the manifest tracks. The server
  stores both and logs any disagreement between them (`DELTA DRIFT`). A batch of
  one-shot self-switches going OFF is logged as a rollback (`SUSPECT rewind`), and
  every NPC gift (`pbReceiveItem`) is recorded so a re-farmed event shows up
  (`SUSPECT re-farm`). With `PEMK_ANOMALY_DETECTION=on` both feed the D5 review
  queue. Nothing is restored.
- **`on`** — everything above, plus a login payload: the progression facts this
  account has saved (fact-tier switches and one-shot self-switches) and the
  cooldown timestamps of repeatable events. The client adds them to the loaded save
  and never removes anything. Badges are also merged instead of overwritten.

Which ids count as progression is worked out at build time from the project's own
events, in the manifest inside `world.json`. A named switch the events turn ON and
never OFF is a fact. A self-switch the events clear somewhere is a latch and is never banked.
An event that uses a cooldown helper (`pbSetEventTime`, `expired?`...) is
repeatable: only its timestamp is kept, and only moved forward. There is nothing
to declare in RPG Maker.

A fact is banked only once a save that contains it reaches the server, so a crash
between an event and the next save never restores a switch without its payout.
Banked progression belongs to the account, like pickups and badges: a fresh
playthrough is a new account.

#### Enforcement in session (`PEMK_FLAG_ENFORCE`)

Off by default, and only meaningful with `PEMK_FLAG_STATE` on. The server keeps its
own copy of every switch, variable and self-switch the manifest tracks, built from
the writes the game's own code makes. A snapshot that disagrees with it means an id
changed some other way (a memory or save edit, since those skip the game's setters).

- **`shadow`** — logs `WOULD-REPAIR` with the ids and the values the server holds.
- **`on`** — the server keeps its values and sends them back (`:flag_repair`); the
  client applies them on the next free overworld frame. An id the game wrote again
  since the snapshot is left alone (the next snapshot is judged instead), a
  variable holding an object is never overwritten, and a repeatable event's
  self-switch stays under its cooldown. A fact switch set by an edit is repaired off
  and never banked. `REPAIR` is logged.

Like the facts, this is judged against saved state: the server remembers its copy as
it stood at each saved blob, and a new session is compared with the one the loaded
blob was saved at. When that cannot be matched exactly, the session's first snapshot
is trusted (`login state unverified` in the log) rather than risk repairing
progress a crash lost. Only a client that announces it can apply a repair gets one;
an older client is logged as `WOULD-REPAIR`.

Limit: a modified client that writes through the game's own setters looks like the
game to this layer. The rewards, pickups and battle layers bound what those writes
can earn.

**After updating the kit**, do one debug launch before restarting the server: the
automatic export reruns when your maps and data change, and also when the kit's
exporters do, so the server gets the current format (an older manifest lacks the
latch list, and `on` would restore self-switches the game clears on purpose). F9 →
*PEMK: Export World* does the same by hand. Migrations run on their own when the
server starts.

#### The payout gate (`PEMK_GIFT_ENFORCE`)

Off by default, and independent of the settings above. An event that gives an item
(`pbReceiveItem`) asks the server first; the export tells it which events are
one-shot gifts: a single payout, on a page that turns on a switch, self-switch or
variable a later page waits for (Brock's TM in the demo). Found from your events,
nothing to declare.

- **`shadow`** — the client asks, the server grants everything and logs
  `WOULD-DENY` where `on` would refuse.
- **`on`** — a one-shot gift is paid once per account. Asked again (the event
  re-armed by an edit, or a save that lost its self-switch), the server refuses:
  the player reads *You already received the TM80.* and the event moves on as if
  it had paid. An item the event's script never gives (an edited map) is refused
  too (`not_this_gift`). Every other gift (a daily NPC, the lottery, one whose item
  is computed) is granted and recorded as before.

Nothing is lost on a bad link. When the server does not answer in time (3 s), the
gift is *owed*: the event moves on, the owed gift is kept in the save, and the item
is added as soon as the server grants it. It is never given without a grant, so
cutting the connection does not skip the gate.

A grant becomes final once the bag that holds it reaches the server (the bag is
restored from the server at login). The client reports the item in its bag, holds
its bag updates back until that report is out, and re-sends what it is owed before
anything else on a new connection. A crash before the bag got through voids the
grant at the next login, so the event, re-armed by the older save, pays it again.
`DENY` is logged. With `PEMK_ANOMALY_DETECTION` on, the third refusal of one gift,
or any item an event never gives, goes to the D5 review queue.

Not covered yet: the gate bounds how many times a one-shot gift pays, not whether
its event's conditions were met (a battle won, a switch on): those still run on the
client. Variable values stay client-authored outside the tracked ids. A
gift a map event gives through a common event it calls is not known to the export,
so it is granted and recorded; one given outside any map event (a common event
running on its own, or Ruby code) is not gated at all.

### The precise list of currently **unsecured** interactions

Everything the game does in the overworld and in battle is client-side:

1. **Movement** — position, facing, speed, collision. The server relays your
   coordinates to same-map players but never checks they're reachable.
2. **Item pickup** — no distance check, no check that the item exists or is
   unclaimed. Only the resulting bag is clamped.
3. **Hidden items / Poké-finder / foraging** — same as pickup.
4. **NPC & object interaction** — talking, receiving gifts, cut/rock-smash/etc.,
   triggering switches — all client-run; the server isn't consulted.
5. **Wild encounters** — encounter roll, species, level, shininess, IVs.
6. **Catching** — capture success and the resulting Pokémon's data (the UID makes
   it non-duplicable, but not *un-fabricable*).
7. **NPC/trainer battles** — outcome, rewards, EXP, item drops.
8. **PvP battles** — deterministic and relayed, but each side simulates locally;
   authority is "challenger's RNG," not the server. A modified client can cheat.
9. **Spawn point & respawn** — where you appear on login or after a faint.
10. **Map warps / transfers** — which map you move to and where you land.

None of these is a bug — it's the current milestone. The client runs the *entire*
Essentials engine, so anything the engine computes is, by definition, trusted
until the server grows an independent copy of the rules.

---

## Why it's like this

The client is a full, self-contained Pokémon Essentials game. It already knows
every map, event, encounter table and battle formula. Making the *data* (money,
items, Pokémon) server-authoritative was tractable: those are small, discrete
facts the server can hold and clamp. Making *gameplay* authoritative means the
server needs its **own** model of the world — maps, object positions, spawn tiles,
encounter tables — and its own battle engine, so it can independently recompute
what the client claims. That's a much bigger surface, which is why it's its own
milestone.

The good news: you don't have to server-simulate *everything* to kill the common
cheats. A cheap distance/existence check stops fabricated pickups; a movement
sanity check stops teleporting; server-owned spawn tiles stop spawn-anywhere. Full
battle re-simulation is only needed for the last mile (ranked PvP integrity).

---

## Milestone 4 — the anti-cheat ladder

Four layers, cheapest-and-highest-value first. Each is shippable on its own and
each makes the next easier (they share the "server has its own world data" spine).

### Layer A — Server-side world data (the foundation) — *shipped*

**Shipped so far:** the server now loads a **read-only world model** from a
build-time JSON export (`server/data/world.json`, produced in-engine by the
"PEMK: Export World" debug action — the server never reads `.rxdata` maps, so it
never `Marshal.load`s an engine object). On top of it, the client sends an
**audit-only interaction claim** on every item-ball pickup ("I picked up item X
at (map,x,y)"), and the server **logs** any claim that disagrees with the model.
It enforces nothing yet — this is the telemetry that will seed the enforcement
checks with real data and a false-positive signal before anything blocks.
Remaining in Layer A: warp/spawn tiles, encounter tables, and widening claims
beyond item balls.

The server can't verify a position or a pickup until it knows the map. So first,
give the server a **read-only model of the world**, extracted from the same
Essentials data the client ships:

- **Interactive objects** — every map's item balls, hidden items, and interactable
  events, keyed by a stable **object id + (map, x, y)**.
- **Spawn / warp tiles** — legal spawn points, respawn (healing) points, and warp
  endpoints per map.
- **Collision / passability** — enough to know which tiles are walkable.
- **Encounter tables** — species/level/rate per map & method (for Layer D later).

*Deliverable:* an offline exporter that reads the game's map data into a compact
server-side table, plus an **audit mode** where the server logs (doesn't block)
mismatches between what clients claim and what the world data says. Audit-first is
the safe way to seed the data and find bad assumptions before enforcing.

### Layer B — Position authority — *shipped (opt-in enforcement)*

**Shipped:** the server runs a **position audit** on the presence stream it
already receives (no new client message) — every per-step frame is checked
against the world model and a violation is classified:

- **no-clip** — a step onto a fully-blocked tile (passability grid),
- **teleport** — a same-map jump of more than one tile (Chebyshev distance),
- **illegal-warp** — a cross-map move that matches no known warp endpoint, edge
  connection, or spawn/heal/home tile.

Enforcement is **live but gated** behind `PEMK_POS_ENFORCE` (off / shadow / on).
In `on`, no-clip and illegal-warp are **snapped back** to the last-good tile
(`:pos_correct` → client `PosCorrect`, moveto same-map / transfer cross-map),
and the violating frame is *not* fanned out to peers; teleport stays log-only
(too many legit sources — Fly/Dig/ledges). Default is audit-only so real players
surface false-positive classes (surf, bridges, ledges) before anything is
blocked. **Spawn/respawn is server-owned:** the last-good position is persisted
(migration 007) and re-seeded at login, so a client can't spawn anywhere.

The end state for Layer B:

- Reject or snap-back positions that aren't reachable (through walls, off-map).
- Cap movement speed / step rate (no teleporting, no super-speed).
- Own **spawn and respawn** points — the server places you on login and after a
  faint, from Layer A's legal tiles.
- Own **warps** — a map transfer is validated against Layer A's warp endpoints.

*Result:* teleport, no-clip, and spawn-anywhere die. This is also the prerequisite
for the interaction check.

### Layer C — Interaction authority (the "pick up the item" fix) — *shipped (opt-in enforcement, item pickups)*

The server validates an *action* against *position*. **Shipped** for overworld
item balls:

- **Distance gate** — a pickup is only accepted if the claimed object is **within
  one tile** (Chebyshev) of the player's server-known position (Layer B). Otherwise
  `:too_far`. (One tile is the classic engine rule.)
- **Existence & one-shot** — the object must exist at that (map, x, y) per Layer A,
  and item balls are **consumed server-side** via an atomic `UNIQUE(account_id,
  map, x, y)` row (migration 008), so the same item can't be picked up twice
  (`already_taken`).
- **Server grant** — with `PEMK_PICKUP_ENFORCE=on`, the client's guarded
  `pbItemBall` **asks first** (`:pickup_req`) and adds the item only on
  `:pickup_grant`; a `:pickup_deny` leaves the ball. Off by default; offline /
  solo / pre-login / bag-full fall back to the local pickup.
- **Permanent per account** — pickups are one-shot *for all time*, like the money
  ledger and badges: a client "new game" on the same account does **not** re-enable
  taken balls (your money doesn't refund either), while a genuinely fresh start is a
  **new account** whose pickup rows are empty (FK cascade on account delete). So
  enforcement is safe to default on — real players never hit a stale-dup wall. The
  only wipe path is a **dev/QA F9 tool** (`PEMK: Reset my pickups`), honored **only**
  when the server was booted with `PEMK_ALLOW_PICKUP_RESET=on` (off in production);
  a client-obeyed reset is deliberately *not* offered — it would be an infinite
  item re-farm.

**Honest scope:** this makes pickups server-*authorized*, not yet
minted-into-inventory. The bag is still blob-authoritative (M2.3), so a fully
hacked client that edits its own bag blob is *detected* on the next snapshot, not
*prevented* here; and because the one-shot is consumed at grant time, a lost grant
forfeits that one item (favours anti-dupe over anti-loss). True exactly-once mint,
plus gift/event rewards and NPC-talk gating, are deferred to the
server-authoritative-bag milestone.

*Result:* fabricated pickups, remote grabs, and duplicate item balls all fail
(opt-in). Gift/event/NPC-spam gating remains future work.

### Layer D — Battle authority — *scoped; see [`LAYER-D-BATTLE-DESIGN.md`](LAYER-D-BATTLE-DESIGN.md)*

The last and largest layer: the server independently determines what a battle
produced. It is **staged** so the cheap, high-value kills land first with **no
battle engine**, and the expensive re-simulation lands last, parity-gated.

- **Tier 1 (no engine)** — server-authored outcomes: **D1** team/set legality
  *(shipped, detection-only)* — over an exported `battle_data.json`, like Layer A's
  `world.json`; **D2**
  server-minted wild encounters (species/level/shininess/IVs server-rolled, not
  client-claimed), **D3** server-adjudicated catches minting the encounter's own
  identity, **D4** closed-form PvE reward bounds (EXP/money/drops), **D5**
  cross-battle statistical anomaly detection.
- **Tier 2** — **D6** per-mon EXP/level authority (migrating stats off the opaque
  party blob).
- **Tier 3 (deferred, parity-gated)** — the engine: **D7** a cross-engine seeded
  PRNG + a **headless re-run of Essentials' own battle code on the MRI server**
  (reused, never reimplemented — the mechanics core has zero Graphics refs and a
  `Battle::DebugSceneNoVisuals` null scene already exists), validated offline
  against a parity corpus; **D8** per-turn checkpoint re-sim; **D9**
  **server-authoritative ranked PvP** + ladder, replacing today's
  "challenger-authoritative" relay.

Enforcement ramps on four independent facets (`PEMK_BATTLE_ENFORCE_{teams,
encounters,catches,rewards,pvp}`, `off/shadow/on`), advertised via
`reconcile_block` — same audit-first pattern as B and C.

*Result:* illegal teams, forced shinies, fake catches, fabricated rewards, and PvP
cheating all fail. **Ranked end-state ratified: reuse the Essentials engine
headless.** Honest limit: until D8 the server bounds and clamps but doesn't
re-derive battle context; the version-coupling tax of the reused engine is
permanent.

---

## Roadmap at a glance

| Layer | Kills | Needs | Effort |
|---|---|---|---|
| **A. World data** *(shipped)* | (foundation) | in-engine map exporter + audit logging | medium |
| **B. Position** *(shipped, opt-in)* | teleport, no-clip, spawn/warp-anywhere | Layer A + movement checks | medium |
| **C. Interaction** *(shipped, opt-in — item pickups)* | fake/remote/duplicate pickups | Layers A–B + distance gate + server grant | medium |
| **D. Battle** *(scoped — staged D1–D9)* | illegal teams, forced encounters/shinies, fake catches/rewards, PvP cheats | Tier 1 (D1–D5) closed-form, no engine → Tier 2 EXP authority → Tier 3 (D7–D9) headless engine reuse + ranked | large |

Recommended order is A → B → C → D, and within it **audit before enforce**: ship
each check in log-only mode first so real players surface false positives before
anything gets blocked.

---

## Transport security (orthogonal, but don't forget it)

All of the above assumes the bytes on the wire are the client's. They're sent over
**plain TCP**. Two consequences:

- **Keep it to a trusted network.** LAN or **Tailscale** (which is encrypted). A
  public server on bare TCP is exposed.
- **A public deployment needs TLS** at a reverse proxy — not just for privacy: the
  client `Marshal.load`s its own save and a peer's battle team, so a MITM that can
  rewrite those bytes is a client-side remote-code-execution risk. TLS closes that.

### A Pokemon another player built (`PEMK_PEER_CHECK`)

A trade's escrow and a PvP team travel from one client to another as Marshal, and
the receiver loads them. Loading attacker-made Marshal can build any class the game
has loaded, and even a real `Pokemon` can carry anything in its instance variables.
Off by default.

- **`shadow`** — the server reads every relayed body without loading it
  (`MarshalScan`: it walks the bytes, checks their lengths and nesting, and names the
  classes they refer to) and logs `WOULD-REFUSE` for one that names a class outside
  the allow list. Clients run the same checks and log them.
- **`on`** — such a body is dropped by the server (`REFUSED`, and a D5 `peer_body`
  report), and refused again by the receiving client before anything is built. The
  client then checks the shape of every Pokemon it loaded (species, moves, stats,
  owner, mail... of the types the game relies on) and refuses one that does not fit:
  the trade is cancelled, the battle does not start.

The allow list is the party's own classes: `Pokemon`, `Pokemon::Move`,
`Pokemon::Owner`, `Mail`. A game whose plugins keep their own objects in a Pokemon
adds those classes to `PEMK_PEER_CLASSES` (server, comma-separated) and
`PEMK::Config::PEER_CLASSES` (client). Whatever the setting, the texts another player
wrote (nickname, original trainer, mail) reach this game without message codes.

### Mart purchases and sales (`PEMK_SHOP_ENFORCE`)

Off by default. A Mart used to be the client's alone: it added what it bought, took the
money off itself, and a sale turned any item in the bag - made up or not - into money.

- **`shadow`** — each purchase and sale is asked first. The server checks the clerk (a
  Mart the world export knows), the item (in that clerk's stock, never free from a computed
  one), the price (the catalogue's, or the one the event sets), and for a sale the item in
  its bag record, and logs `WOULD-DENY`; the client still moves the money.
- **`on`** — the server refuses what fails (`DENY`) and moves the money itself, in its
  ledger (`shop:buy:ITEMxN`); the client adopts the balance it answers with. Nothing is
  bought or sold without an answer.

A purchase the server made or approved also explains its items (and the Premier Balls the
engine adds) to the item ledger below. The Battle Point shop is not gated yet.

### Where an item came from (`PEMK_ITEM_AUTHORITY`)

Off by default. The possession is every place an item can be - the bag, the PC storage,
the mailbox, the items Pokemon hold - recorded together (E0), so moving an item between
them is never an increase. A decrease (an item used, sold, tossed, handed to an NPC) is
always accepted. An increase must take a **credit** that a source the server knows left:

- a pickup it granted (`PEMK_PICKUP_ENFORCE`), or one reported with the gate off - the
  quantity from the world export;
- a gift from an event the export reads literally: a one-shot one once, when the gate
  pays it; another while the claims ledger sees no re-farm. A computed call names its own
  item, so it explains nothing;
- a Mart purchase the server made or approved, with its Premier Balls;
- a traded Pokemon's held item, as the sender's record knew it: bound to that Pokemon's
  arrival (once per delivery) when it can be delivered again, otherwise a credit;
- the PC storage's start items, once per account.

What no credit covers is owed for two minutes (a pickup is reported after its message
closes, when the bag has already gone out); a source heard in that time pays it. Then it
is logged `UNEXPLAINED +n ITEM` and counted for the review queue (D5 `item_unexplained`).
A fresh login drops the credits still waiting: the record it loads never held their items.

- **`shadow`** — judges and reports; the record adopts every snapshot.
- **`on`** — enforcement (step E4) is not built yet: `on` runs as `shadow`.

Sources the server does not model yet leave their items unexplained: berries, battle
held items (Pickup, Thief, a caught Pokemon's item), the prize desk, vending machines,
Mystery Gift, and anything added with the gates off. Read `UNEXPLAINED` lines with that
list in mind until the tiers (E2b) sort those items out.

### A traded Pokemon is not lost (`PEMK_TRADE_REDELIVERY`)

On by default (`off` turns it off). The swap is the server's, but the Pokemon itself
comes from the partner's client and reaches the receiver's disk only with its next
save: a crash in that second, or a result lost with the connection, used to lose it.
The server now keeps the escrow the partner locked until a save that follows the
receiver's report lands. After a login (once the save is loaded) and after a
reconnect, the client asks what it is still owed; a Pokemon missing from its party
and boxes is added back, with a message, and one it already holds is only
acknowledged, so nothing is ever held twice. A reconnect also drops the Pokemon the
account traded away. Only clients that say they can take one are sent one; each
escrow is checked like any peer's Pokemon (above).

Transport hardening is independent of the A–D gameplay ladder; both are needed for
a real public deployment.
