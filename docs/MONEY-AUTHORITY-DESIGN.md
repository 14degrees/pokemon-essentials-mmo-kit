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
