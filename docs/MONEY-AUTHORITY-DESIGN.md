# Money authority: the server owns the purse

Status: design, 2026-09-28, revised 2026-09-29 after an adversarial review. Approved in
principle by the project owner ("feu vert"), after item authority (E0-E4) left money as the
way around it: a client that sets its money to the cap buys at a gated Mart, and what the
server sells it is explained. Built in steps, each off by default, with the same method as
the items: survey, design, adversarial review, then steps that ship alone with unit tests
and an autotest scenario.

The review changed the model. The first draft let the client keep pushing its absolute
balance and judged each increase against credits the server had computed. A credit taken
from a merged delta lingers, a spend hides an equal gain, and a battle report could be
replayed to mint credits. The revision makes every accepted gain a server transaction,
the way E3 already makes Mart deals: the client asks, the server checks and pays.

## 1. Where we start

The economy ledger (`ledger.rb`) keeps one balance per account and field (money, coins,
battle points, soot). The client pushes the **absolute** value after every change. The
server caps it, dedups it by seq, records the delta with a reason, and either acks it or
rejects it; on a reject the client rolls back to the server's balance. Any value within the
cap is accepted: "capped and audited, not authored".

What the server already makes itself, with `Ledger#adjust` (negative seqs, so the client's
own seqs never collide):
- Mart purchases and sales, and Battle Point exchanges (E3, with the shop gate on).
- The prices a clerk's event sets are exported per Mart call, with the engine's rules
  (2026-09-29).

What it bounds without authoring: D4 opens a window after a battle it can prove (a wild foe
it minted, a trainer the exports place on the player's map). It labels the money deltas
inside that window `battle:<n>` and flags only what exceeds a flat envelope.

A new game's starting money now reaches the ledger at login (2026-09-29). Before that, the
ledger had no row and read $0: a gated Mart refused the first purchase, and a first sale
overwrote the rest.

Increases, from a survey of the engine and the demo's events:

| Source | Where the amount is decided | Server-knowable |
|---|---|---|
| Trainer prize money | max party level x the trainer type's base money, summed over the trainers; x2 with Amulet Coin or Luck Incense held by a battler on the player's side, x2 with Happy Hour | the parties and placements, once exported; the multipliers as validated facts |
| Pay Day | 5 x the user's level per use, paid on a win or a capture, doubled like the prize | only as a bound (duration, battlers, PP) |
| Mart sale | unit price x quantity, the clerk's price when its event sets one | made by the server with the shop gate on |
| Triple Triad card sale | a quarter of the card's price x quantity | the price yes, the collection no |
| Event "Change Gold" (code 125) | a constant or a variable | not exported yet; the demo's seven are all spends |
| Scripts (`$player.money +=`) | any Ruby | not exported yet; none in the demo |
| Starting money | metadata, set without the setter | seeded at login |
| Debug | anything | must never be explained |

Coins come from buying them (an event: money down, then a script adds coins), the slot
machine and Voltorb Flip (random, client-side). Battle points come from the Battle
Frontier's award events (client-side win counters). Soot comes from walking in soot grass.

## 2. What makes money harder than items

- **One number, merged.** A flush carries the latest absolute balance. A prize, a sale and
  a Day Care fee in the same half second arrive as one delta, and a spend can hide an equal
  unexplained gain. Where the server makes the transaction itself (E3) the problem goes
  away: the ledger moves, and the client's next frame echoes it.
- **No placement.** Money has no stores to move between, which helps. It has no tiers
  either: a source the server cannot bound makes the whole field unjudgeable, not one item.
- **Battle state stays on the client.** Who took part, what they held, Pay Day uses.
- **Currencies convert.** Money buys coins (an event), coins buy prizes (local items),
  items sell for money (E3), battle points buy items (E3). A currency the server does not
  own turns into the others through the server's own transactions.

## 3. The model

- The **balance** is the server's: the ledger, as today.
- Every gain the server accepts is a **server transaction**. The client **claims** it,
  with a nonce: a trainer prize at a battle's end, a Pay Day total, an event's payment.
  The server checks the claim, applies it with `adjust` on the account's mailbox, and
  answers with the balance, which the client adopts. Mart and BP deals already work this
  way (E3).
- A client frame above the ledger is **unexplained**. It is logged and counted for
  review; in `on` it is refused, and the client adopts the balance. A frame below the
  ledger is a spend, the client's business as for items: buying, a Day Care fee, a lost
  battle.
- No credit exists to linger. A frame's delta is never matched against earlier gains, so
  a prize merged with a spend leaves nothing over for a later conjured gain.
- A spend in the same frame can still hide an equal conjured gain: +300 conjured and
  -300 spent give a delta of 0. That is harmless only while what was bought is not
  protected. Every spend that buys something the server protects is itself a server
  transaction: coins, a Pokemon from a seller, a vending machine's items once they are
  tracked.

## 4. Proving each payout once

A claim is only as good as the proof that the payout happened, and happened once.

- **Trainer prize.** Paid once per account, map, event, trainer and version, with the
  gift gate's semantics: sealed when the money lands, voided at most once on a fresh
  login (the save may not have kept it). Phone rematches are paid once per version. The
  last version repeats, so it is paid on a server cadence of at least 20 minutes per
  contact (the engine's own delay is 20 to 40 minutes).
  - The trainers come from `generate_foes`' result: all of them, including a waiting one.
    `:on_trainer_load` misses a trainer that spotted the player first, and three trainers
    exceed the current cap of two.
  - The client sends its position at `:on_start_battle` and names the map in the claim;
    the map just left counts, as for gifts.
  - The amount is the trainer version's exported party (max level x base money) times the
    multipliers the claim states as facts, each checked: an Amulet Coin or Luck Incense
    holder the item record recognizes and the party (or the exported partner) contains;
    Happy Hour only if a party member, the partner or a foe knows it or a move that can
    call it (Metronome, Assist, Copycat, Mimic, Mirror Move, Me First, Transform, Sketch).
  - A battle whose event says no money (per-event battle rules) pays nothing.
- **Pay Day.** A wild battle's claim consumes the encounter mint it names; a mint pays
  once. With the RNG seam on, the claim carries the battle's D7 seed or record. The total
  is bounded by the battle's duration (mint to claim) x the player's battlers x 5 x their
  level after the battle x the multiplier, and by the move's PP.
- **Event money.** A gate like the gift gate: the event asks, and the server grants what
  the export reads literally, once for a one-shot event.
- **Starting money.** Once per account, equal to the exported start money. The login seed
  that ships now is taken as is; under M3 the server grants it itself.

## 5. Closing every path into server-made money

M3 cannot start while any currency or item the server does not own can be turned into
money by a server transaction.

- **Local items sold at a gated Mart.** A local item never becomes a debt, so 200 Nuggets
  added in memory sell for about $1,000,000 through `Ledger#adjust` today. M1 labels such
  sales (`shop:sell:local:ITEM`) and counts them. Before M3, each source is either modelled
  (Pickup credited at a won battle's end, bounded by its table and the Pickup Pokemon in
  the party; server-rolled mining; a server-drawn lottery), or local-sale income is capped
  per account and day, with a clerk message when the cap refuses.
- **Battle points.** The client can set 9,999 BP, buy 999 Proteins at the gated exchange
  (which credits them as items) and sell them at a Mart for $5,000 each. This is a live
  hole in E4 today. BP authority is a precondition of M3: the Frontier's awards bounded
  server-side per challenge and streak, on a cadence. Until then, units bought with BP are
  not sellable: `take_sold` cannot draw from a per-item BP-bought count.
- **Triple Triad.** The demo sells, buys and duels cards on map 13, and the collection
  lives only on the client. Card sales become server-made (`:triad_sell`, checked against a
  server card record that server-made purchases credit, duel winnings bounded per duel),
  or the operator removes them.
- **No declared escape.** The first draft let the operator declare an unbounded source.
  The server sees one merged delta and cannot tell a declared sale from a conjured gain, so
  declaring a source meant accepting every gain. The boot refuses `on` and names each
  unbounded source instead: Triple Triad, Change Gold with a variable amount, computed
  money scripts, `:on_trainer_load` handlers that change the foes.

## 6. Protocol safety

These are live today and are fixed first.

- **A stale reply overwrote newer money** (fixed 2026-09-29). `:econ_ack` and `:econ_rej`
  were applied as absolute values whatever frame they answered. With a gain pending when an
  older frame's reply landed, a spend in between marked a value that no longer had the
  gain. A reply now applies only when it answers its field's latest frame, and as a delta
  (local += server value - value sent) while a newer change is pending.
- **A late shop reply** (fixed 2026-09-29; void rows capped per account, and a refused deal
  needs no row). When a gated deal's reply misses its five seconds, the clerk
  says it cannot reach the server, but the server may already have moved the money and
  the items. The next `ask` dropped the late grant. A sale then left the items in the bag
  and out of the server's record, and E4 took them back. The review proposed that each
  frame name the last deal the client applied, and the server reverse the rest. A single
  seq cannot say that deal 7 timed out when deal 8 went through, though, and a client that
  crashes after applying a deal never names it. Instead:
  - Each deal carries a nonce, and the server records its outcome in the same
    transaction as the deal. A request whose nonce is recorded gets the recorded
    outcome and never runs twice.
  - The client keeps each deal it gave up on (in the save, as owed gifts are) and asks
    for its outcome again by the nonce, at once and after a reconnect. A nonce the server
    never received is recorded as void, so a copy of the request still on its way is
    refused.
  - While a deal is in doubt, no econ or inv frame leaves and no other deal starts. The
    ledger and the record therefore still hold the deal when its outcome comes back.
    A late grant is applied on a safe frame, as `:inv_correct` is: the items in or out
    of the bag, and the money by the delta the server applied. Changes made locally in
    the meantime are kept, and go out after it.
  - A purchase also adds its items to the server's bag record, as a sale takes them out.
    A login after a crash then restores both sides of the deal from the server. A fresh
    login clears the deals in doubt, since the restore already settled them.
- **Claims across a disconnect.** The link can drop mid-battle, and the client does not
  reconnect during a battle. Each claim is queued in the save with its nonce and sent
  before the reseed. A re-sent claim is accepted by its nonce, without judging it by place
  again, as gifts are. Credits and claims live in the database, written through the
  account mailbox, never the worker pool.
- **Judge at once.** Every claim reaches the server before the frame that shows its money,
  on the same connection and mailbox, so there is no grace period in which unexplained
  money could be spent at a gated Mart.
- **Quitting mid-battle.** `on_terminate` flushes the econ channel even inside a battle,
  so the prize frame goes out without its claim. Inside a battle the flush skips econ.

## 7. Steps

- **M0 - exports.**
  - Done 2026-09-29:
    - the prices a clerk's Mart calls can see;
    - each trainer type's base money;
    - each trainer version's party with levels, held items and moves (the PBS moves, else
      the engine's last four by level), for the foes and the partner;
    - the phone rematch versions (every version from the start one, placed where
      `Phone.battle` is called);
    - the start money.
  - Per event: the battle rules (no money, can lose).
  - Per event and common event: the money sources no request names (Change Gold with its
    sign and a constant or variable amount, money scripts, the minigame calls, the
    Frontier's BP awards) and whether each pays once.
  - Whether a plugin registers an `:on_trainer_load` handler (named as unbounded).
- **M0.5 - protocol safety.** Done 2026-09-29:
  - the starting money seed;
  - seq-bound replies applied as deltas;
  - a deal given up on asked about again by its nonce, and a late grant applied.
- **M1 - claims in shadow** (`PEMK_MONEY_AUTHORITY=shadow`).
  - The client sends trainer and Pay Day claims with nonces. The server checks them, logs
    what it would pay against what the frames show, and logs `UNEXPLAINED` for a frame
    above the ledger that no claim accounts for.
  - A D5 kind. Local-item sales are labelled.
  - The autotests get a server-side test grant in place of `a.money!`, which must log as a
    debug source. Every scenario runs in shadow and must log nothing unexpected.
- **M2 - the server pays.** Claims are applied by the server; event money goes through its
  gate.
- **M3 - enforcement** (`PEMK_MONEY_AUTHORITY=on`): a frame above the ledger is refused.
  - The boot checks its preconditions and names what blocks them, as E4 does: D4 and D2
    at least in shadow (D2 on for the wild proof), `PEMK_POS_ENFORCE=on`, D1 for move data,
    the placement and rematch exports, the shop gate on, item authority with the
    local-sale bound, BP authority (or BP-bought units unsellable), and no unbounded
    source.
  - Cutover: existing balances become the baseline, and large unattributed histories go
    to D5. Accounts with a save but no money row were seeded at login.
- **Later:** coins (the Game Corner) and Triple Triad as server transactions.

## 8. What the review answered

- **Multipliers.** With one-shot trainer prizes, an upper bound on the multipliers is
  acceptable: the total exposure is three times the sum of the game's prizes. Wild Pay Day
  takes the duration and PP bound now, and the D7/D8 battle records later.
- **Existing accounts.** The baseline, plus a D5 audit of unattributed history.
- **The reconnect path.** Claims go out before the reseed, and the reseed's absolute value
  is judged like any frame.
- **Offline play.** An offline session is local and never reaches the account.
- **Alt accounts.** Per-account caps do not stop a farm of alts: money buys tracked items,
  which trade across as held items. D5 review is the answer there.


## 9. M1 in detail (revised 2026-09-29 after its own review)

M1 measures, in shadow, exactly what M2 and M3 would pay and refuse. Nothing a player
sees changes. A second adversarial review of the first draft found that it would have
explained money nobody earned (Pay Day stacked on D4's envelope, one battle paid for each
of its branches, rematches claimed at their top version, a carried excess hiding later
conjures) and logged honest money as unexplained (Pay Day in a trainer battle, a claim
judged against a stale position after a reconnect, new accounts). M1 is therefore split,
and each part ships on its own.

### M1a - trainer prize claims

Built 2026-09-29 (`money_claims`, `money_payouts`; autotest 077). Still to come from this
list: the partner's version, the battle rules (a no-money event), the flush of the facts
at `:on_start_battle`, and marking the trainers beaten before M1 as paid.

- **The claim.** An alias of `Battle#pbGainMoney` computes, before the original runs, what
  the engine is about to add: `internalBattle && moneyGain` must hold, then the sum of
  `pbMaxLevelInTeam(1, i) * t.base_money` over the opponents, and the Amulet Coin and Happy
  Hour field effects. Each opponent carries the key of the trainer data it was built from,
  tagged in `GameData::Trainer#to_trainer`: `[type, real_name, version]`, so a rival's
  substituted name and a trainer rebuilt after spotting the player keep their key. The
  claim also names each trainer's `(map, event_id)`, the partner's `(type, name)`, and the
  client's econ seq.
- **The place.** No capability opts out of it. Before each claim, and at
  `:on_start_battle`, the client sends a position frame that bypasses Presence's
  deduplication, whose memory `Sync.reset` clears on a new connection. On a new connection
  the server judges a claim only after that connection's first position. The claim may
  also name the map the account's previous connection ended on, which the server keeps per
  account when a connection closes. With `PEMK_POS_ENFORCE` off, the place is the client's
  own word, and the verdict says so.
- **Once.** A trainer pays once per account and `(type, name, version)`, and a non-rematch
  event once per account and `(map, event_id)`: the rival's three branches on one event
  are one battle. A claim names at most three distinct trainers. A battle whose event sets
  no money pays nothing once the battle rules are exported.
- **Rematches.** A placement the export marks as a rematch may repeat. A version above the
  start one pays only once the version below it was paid. A version already paid repeats
  at most once per 20 minutes, on one clock per `(type, name, start version)` kept in
  `money_claims`. The export places only the versions `Phone.add` registered.
- **The bound.** The sum of `trainer_prize` over the trainers, doubled per multiplier:
  - Amulet Coin: a unit the item record recognizes (judged, no open debt), held by a
    Pokemon in `party_snapshots` or in the partner's exported party;
  - Happy Hour: the player's side knows HAPPYHOUR or METRONOME, or has a copying move
    (MIMIC, COPYCAT, MIRRORMOVE, SKETCH, TRANSFORM) or the IMPOSTER ability facing a
    battler that knows either. A foe's own Happy Hour does nothing (the engine sets the
    effect only for the player's side).
  The facts are flushed at `:on_start_battle`, before `in_battle` is set: position, bag,
  party and team report. The accepted amount is `min(amount, bound)`; the rest is logged
  `SUSPECT`.
- **Seal and void**, as gifts: the first fresh money frame after a claim seals it. A fresh
  login voids the unsealed claims once, since the save may not have kept the battle; a
  void takes its amount back from S and marks its nonce. An excess that follows a claim
  refused as already paid is logged `REPEAT`, outside D5.
- **Nonces** are keyed by `(account_id, nonce)`; the verdict is stored with the mode it
  was judged in. A shadow verdict never becomes an M2 payment for the same nonce.
- **Validation.** An integer amount from 0 to the cap, at most three trainers, strings of
  at most 32 characters, and a `money_claim` frame budget.

### M1b - the shadow balance

Built 2026-09-29 (`money_shadow`), with two simplifications: a boot with the setting off
empties the table (no epoch), and the claim's econ seq is not checked against the seed yet.
A reconnect's reseed sends the unanswered claims first, each after a position. The money
that follows a claim refused as already paid is logged `REPEAT` (money_shadow.repeat, which
the next frame consumes); a full autotest run with the measurement on logs only the
harness's `a.money!` and the gift scenario's deliberate re-fight of Brock.

- Two numbers per account: S, the balance M2 would keep, and C, the client's balance as
  the server last knew it (`money_shadow`). Only fresh, acked frames of the account's
  current connection count: replays, rejected frames and frames of a replaced session
  still in the mailbox do not.
- **Seeding.** S and C are created at the account's first claim, adjust or fresh frame with
  M1 on, from the ledger balance before that event applies; an account with no ledger row
  starts from the exported start money. A boot in shadow after a boot with M1 off drops
  every row, so a stretch without measurement never counts. A claim whose econ seq is older
  than the seed is answered `stale` and credits nothing. At seeding, the placed trainers
  whose self-switch A the flag mirror holds are marked paid; without the mirror, the first
  claim of each already beaten trainer is an exposure the logs name.
- **Claims.** An accepted claim of amount a: `S = min(S + a, cap)`.
- **Server transactions**, inside `Ledger#adjust`'s transaction and only when acked: `S +=
  d` and `C += d`. A purchase S cannot cover is logged `BOUGHT-UNEXPLAINED`, and S is never
  floored.
- **Frames.** A fresh frame of value v logs `max(0, v - S) - max(0, C - S)` when positive,
  as `money: account N UNEXPLAINED +d` (a D5 kind, `money_unexplained`); then `S = min(S,
  v)` and `C = v`. The excess is derived each time, never remembered: a conjure after a
  spend, or back up to an old peak, is logged again.
- **Login.** A fresh login adopts the ledger balance L through the trusted setter, which
  sends no frame: C becomes L. S is never reset at login, or a logout would launder money.
- **Reseed.** The reseed frame after a reconnect is judged only after the re-sent claims
  and after a position frame.

### M1c - Pay Day

Built 2026-09-29 (`encounter_rolls.payday_at`; autotest 078), with two changes to the
plan: the claim leaves with the prize's, from `pbGainMoney` (the mint was made at the
battle's start, so D4's report is not needed), and a mint stays good for 30 minutes rather
than 90 seconds, which a long battle outlasts. Without D2's mints a wild battle's Pay Day is
only bounded, and says so ("unminted"). The party's levels and moves come from the team
report the client always sends.

- One claim per battle, sent at `:on_end_battle` after the D4 report. `in_battle` is still
  true there, so it reaches the server before the frame with the money. A wild battle's
  claim names all its foes; a trainer battle's names the trainer claim's nonce.
- Each named foe's encounter mint must belong to the account, be younger than 90 seconds,
  and have no `payday_at` yet (a new column, apart from the catch and uid markers).
- The bound: 5 x the highest level among the party Pokemon that know PAYDAY, METRONOME, or
  a copying move while a foe knows PAYDAY, x min(their summed maximum PP, K per foe), x 4.
  K is a small constant tuned from M1's logs. D4's envelope is not used.

### M1d - money from sources the server does not own

S credits only sales of units the item record judged. A sale of a local-tier item, or of
an item bought with battle points, goes to a counter per account and day, logged
`UNOWNED-SOURCE +n` and labelled in the ledger (`shop:sell:local:ITEM`).

Built 2026-09-29 for the local tiers: the sale is labelled, logged `UNOWNED-SOURCE`, and
moves C without S; without item authority every sale is unowned. Still to come: the items
bought with battle points (they need a per-item count in the record) and the daily counter.

### Preconditions

At boot, the server names what M1 cannot measure, and labels the claims instead of logging
`UNEXPLAINED` while any holds: the shop gate off (sales are not server transactions), D2
not on (no mints for Pay Day), D1 off (no moves for Happy Hour), no trainer placement or
money sources export. The harness grant that replaces `a.money!` in the autotests exists
only behind a server flag.

### Also found by the review, live today

- Presence remembered the last position it sent across a reconnect, so a new connection's
  first position waited for the player to move; the gift gate could judge a request
  against the position stored with the last save. Fixed 2026-09-29: `Sync.reset` clears
  that memory.
- A client that does not advertise `gift_pos` is never judged by place at the gift gate.
  That keeps older clients working with the gate on; once the operators' clients all send
  their position first, the gate can judge every client.
- A partner trainer's version is lost: `partner[2]` holds the trainer's random ID and is
  read back as a version.
