# Proving a trainer battle before its prize is paid

Design, 2026-09-29 (revised after its adversarial review). Money authority
(docs/MONEY-AUTHORITY-DESIGN.md) pays a trainer's prize on the client's claim, judged by
placement, cadence and daily caps: a claim proves no fight. This design lets the server
prove that the battle was fought and won, against the trainer's real team and AI, with
randomness the client did not choose - before the prize counts.

## 1. What the engine gives us (research, 2026-09-29)

- The foe team is deterministic. `GameData::Trainer#to_trainer` draws with Kernel#rand
  (personalID, IVs) but overwrites each drawn value from the PBS data or a fixed default
  (gender, ability index 0, nature, IVs, EVs, shiny, moves, held item). Only the FORM of a
  few species survives: random at creation (Unown, Pumpkaboo, Minior, Sinistea, Alcremie,
  Urshifu) or taken from map, clock or player (Burmy, Lycanroc, the Scatterbug line).
- In battle the rolls go through `Battle#pbRandom` and `Battle::AI#pbAIRandom`, both tapped
  by the D7 recorder; one Kernel#rand is left in AI scoring (Shell Side Arm's tie).
- The prize has no randomness: max level of each foe team x base money, x2 Amulet Coin /
  Luck Incense on the player's side, x2 Happy Hour; added in `pbEndOfBattle` on a win.
- Nothing names a trainer to the server when the battle starts; the claim goes out inside
  `pbEndOfBattle`, before any record exists.
- The D7 recorder captures both sides' choices, forced switches and the outcome; the
  harness replays wild battles by re-registering both sides' recorded choices - it has
  never re-run the AI, and raises on any AI draw.

## 2. The model

1. **One seed per placement.** When a trainer loads, the client asks
   (`:trainer_battle_req {trainers, map, event, page}`); it waits for the answer at
   `pbStartBattle`, behind the transition. The server checks the placement against the
   export and the player's position, and hands out THE seed of (account, placement, page):
   made on the account's mailbox under a unique index, the same answer however often it is
   asked, replaced only after a proven win or a server-side expiry - never after a loss the
   client reports. The answer also sets what the client would otherwise choose: weather and
   terrain, the rules, the forms the export leaves random.
2. **A battle the client cannot steer.** Every draw of both streams comes from the seed
   (D7 `on`). The record carries what a replay needs: the trainers and their bag, the
   player's items used, every "Will you switch?" answer and forgotten move, the switch
   style.
3. **The record goes first.** It leaves at `pbEndOfBattle` entry, before the claim, and is
   kept with the claim until the server has it.
4. **The replay decides, in seconds.** The ingest walks the seed (D7) and binds the record
   to its seed row (one record per row, one claim per record). The replay daemon, woken at
   once (Postgres NOTIFY), rebuilds the FOE team with the engine's own `to_trainer` from the
   game's data, checks the PLAYER team against the server's own knowledge (owned uids,
   first-sight locks, the last team report, legality, EXP at most the high-water), replays
   the player's choices and RE-RUNS the trainer's AI on the seed's AI stream: the foe's
   choices must be the AI's, the outcome a win, the recomputed prize the claimed amount,
   the claim's trainers the row's.
5. **Pay on the verdict.** A proven claim is paid - within the client's 60-second hold. A
   refuted or unreplayable one is held unpaid, never voided (engines can drift; D8 never
   condemns on a replay alone), and replayed again after a harness fix.

## 3. Steps

- **P1 - can the AI be re-run? (no protocol change, shadow only).** The recorder records
  single battles against one trainer in shadow; the harness loads the trainers' data,
  builds the foe team with `to_trainer`, replays the player's choices and re-runs the AI on
  the recorded AI draws, and compares the foe's choices. Parity over real battles (the
  autotest fights the demo's trainers) is the go/no-go for everything below.
- **P2 - the seed.** Request and answer, the seed rows (migration), the recorder arming in
  `on`, the record additions, the record before the claim.
- **P3 - the verdict.** Claim-record-seed binding, the player-side checks, the NOTIFY-woken
  daemon, `proven` / `refuted` / `not_replayable`; shadow logs what `on` would hold.
- **P4 - enforcement,** first for repeatable single-trainer placements and rematches (the
  open-ended farm the daily cap only bounds), then one-shot trainers, then doubles and
  partners.

### P1 results (2026-09-29): go

- The recorder records single battles against one trainer in shadow: the trainers, their
  bag, the battle's settings, every yes/no the player answered and each move forgotten,
  and the map (a level-up's happiness reads it).
- The harness rebuilds the trainer with the engine's own `to_trainer` from the game's
  data, refuses a record whose foe team or bag differs, registers the player's recorded
  choices, re-runs the trainer's AI on the recorded AI draws, and compares its choices,
  its Mega Evolution and its replacements; the prize is recomputed.
- Autotest 083 fights Camper Liam and Brock (AI skill 100, two Full Restores): 8 battles
  over four runs, 3 to 12 rounds, won and lost, replayed to the same end and the same
  money. A unit test replays a frozen Brock record and altered copies (an AI choice, a
  replacement, the foe team, the bag, the trainer): each is refused, with its reason.
- Found on the way: a level-up in any replayed battle crashed the harness (no
  `$game_map`); it now has one, set to the recorded map, and the corpus's caught
  battles that failed on it replay to a match.

### P2 (2026-09-29): the seed

- Under `PEMK_BATTLE_ENFORCE_RNG=on` the login says trainer battles are seeded
  (`trainer_seed`). A trainer loaded for a battle asks its placement's seed at once
  (`:trainer_battle_req {nonce, trainers: [[type, name, version, map, event]]}`); the
  battle's start waits for the answer, at most two seconds, behind the transition.
- The server answers only a placement the export knows, on the map the player stands on,
  and one trainer at a time (single battles first): `:trainer_battle_seed {nonce, seed}`,
  else `:trainer_battle_deny {nonce, reason}` and the battle is recorded unseeded.
- The seed is THE open seed of (account, placement) - migration 042, `trainer_battles`,
  one open row per placement under a unique index: asked again, the same answer; a new one
  only once a win on it is proven (P3) or after a day. Every attempt's record names it.
- The record leaves at `pbEndOfBattle` entry, before the prize claim; the ingest binds it
  to its seed row (`battle_records.trainer_battle_id`) and walks it.
- Autotest 084: Liam, then Brock twice under `on` - three seeded battles, the two against
  Brock on the same seed (and, the same choices, the same battle), each walked and
  replayed from the seed, the AI's draws included, to a match.

## 4. What stays open

- Lookahead: a client knows its seed before it plays, so it can simulate the battle ahead
  (D7 accepted this for wild battles). Revealing each round's draws only after the
  player's choices close it, at one round trip per turn.
- A bot that fights for real is not a cheat this can see; caps and cadence still bound it.
- Placements the export cannot rebuild (a trainer built by a script, edited in
  `:on_trainer_load`) are marked unprovable.

## 5. Decisions for Sam

- **Unproven claims under `on`** (no answer to the seed request, an unprovable
  placement): held and paid from a small daily allowance (proposed), paid under the caps
  as today, or refused. Old clients are refused at login, as M3 does.
- **Lookahead:** accept it for trainers as for wild battles (proposed, first), or reveal
  per round later.
