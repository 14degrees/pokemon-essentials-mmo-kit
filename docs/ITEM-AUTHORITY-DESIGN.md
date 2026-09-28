# Item authority: the server owns the bag

Status: design, 2026-09-28, revised after an adversarial review the same day. Approved in
principle by the project owner ("le serveur maître du sac"). Built in shippable steps, each
off by default unless it only fixes a loss or a dupe.

## 1. Where we start

The bag is client-authored. Every change to `$bag` marks the `:inv` channel, and the client
sends the whole bag as an absolute snapshot `{item => qty}`. The server stores the last one
(`inventory_snapshots`), checks only its shape (caps), and restores it at login over the bag
the save file carries. It never rejects, never corrects, keeps no history.

Everything else that holds items lives only in the save blob:

| Store | Where | Server sees it |
|---|---|---|
| Bag | `$bag` (8 pockets) | yes, restored at login |
| PC item storage | `$PokemonGlobal.pcItemStorage` | no |
| Mailbox | `$PokemonGlobal.mailbox` (up to 10 `Mail`) | no |
| Held items | `Pokemon#item` in the party, the boxes, the Day Care, a fused partner | party only, and only with team checks on |

Two things follow.

- **A dupe and a loss window.** The bag and the blob are persisted on separate channels. A
  PC withdrawal or taking a held item reaches the server with the next bag flush (half a
  second), while the PC or the Pokemon that gave the item only changes with the next blob.
  Kill the game in between: the login restores the bag (with the item) and loads the PC or
  the Pokemon from the older blob (with the item too). The reverse moves lose items.
- **No source is judged.** Pickups and one-shot gifts are gated, but the bag the client
  reports afterwards is adopted whatever it holds.

Increases of the whole possession come from (engine survey, `Data/Scripts`):

- **Server-gated already:** item balls and hidden items (`pbItemBall`, `PEMK_PICKUP_ENFORCE`),
  NPC gifts (`pbReceiveItem`, `PEMK_GIFT_ENFORCE`).
- **Shops:** the Poke Mart (plus free Premier Balls), the Battle Point shop, the Game Corner
  prize desk (`pbBuyPrize`, coins taken by the event), vending machines (an event's
  `$bag.add` after a Change Gold).
- **The field:** berry picking (yield from the client clock), the mining game, Mystery Gift,
  the PC item storage's start items (created lazily).
- **Battle:** held items gained on the player's side (Pickup, Honey Gather, Thief/Covet and
  Magician/Pickpocket against wild Pokemon, Ball Fetch, Harvest, Recycle, Sticky Barb), the
  held item of a caught wild Pokemon, unused battle items given back.
- **Other players:** a traded Pokemon's held item and mail.
- **Event exchanges:** fossils, Apricorns, Heart Scales (the event removes one item and
  gives another item or a Pokemon).
- **Debug**, which must never be explained.

Decreases (uses, battle consumption, evolution items, TRs - every TM in this PBS is a TR -,
sales, tosses, releases, items handed to NPCs) are the client's business: a decrease never
gives anything, so the server accepts every one.

## 2. The model

The server keeps, per account:

- **the possession**: the last accepted totals per item, over all stores (bag, PC, mailbox,
  held items). Moving an item between stores does not change its total;
- **the credits**: increases the server authorized and has not yet seen, each with its item,
  quantity, source and expiry.

On each snapshot, per item: `delta = reported total - possession`. A decrease is accepted. An
increase takes credits for that item, oldest first; what no credit covers is **unexplained**.

- `shadow` logs `UNEXPLAINED +n ITEM` and files a D5 report; the record adopts the snapshot.
- `on` records only the explained part, and sends the client its corrected possession
  (`:inv_correct`), applied on a free overworld frame like `:flag_repair`.

Items are sorted at build time into **tiers**, from the project's own data:

- **tracked**: every way this game can produce the item is a credit source. Judged.
- **local**: some source cannot be seen or bounded (a computed `pbReceiveItem`, the mining
  table, Mystery Gift, battle held items until they are modelled...). Recorded, never judged.

Anything the export does not understand makes an item local: a degradation, never a false
accusation. The tiers ship in the world export, like the flag manifest.

## 3. Credit sources

| Source | Credit | Strength |
|---|---|---|
| Pickup grant | the export's item and quantity | server-decided |
| Gift grant, literal event | the export's item, the request's quantity (bounded by the export) | server-decided |
| Gift grant, computed or unknown event | none: the client chose the item | the item stays local |
| Mart purchase (gated) | the item bought, plus the bonus Premier Balls the engine gives | server transaction |
| Battle Point shop (gated) | the item, against its BP price | server transaction |
| Trade | the traded Pokemon's held item and mail, moved between the two records in the swap | conservation between accounts |
| PC start items | `Metadata.start_item_storage`, once per account | server-known |
| Vending machine | the event's literal item, through a request bound to the event (later) | local until then |
| Berry picking, mining, battle held items, Mystery Gift, prize desk | none in the first release | local |

A credit lives until its source settles (see section 4); what a fresh login loads is the
record, which never held an unsettled credit's item.

## 4. What the review changed

An adversarial review of the first draft found that E0 as first written would have added
dupes, and that several honest paths had no credit. The rules below come from it.

- **Items in transit.** The engine moves an item in two steps with a message in between:
  taking a held item adds it to the bag, shows a message, then clears the Pokemon; the box
  screen's "Take" and the mailbox's "Move to Bag" do the same. `Sync.tick` runs inside
  messages, so a snapshot there counts the item twice, and so does the save written when the
  window closes. These methods run under an `Inventory.atomic` hold: no `:inv` snapshot and
  no closing save while it is held (nor while the box screen holds a Pokemon in its hand).
- **Every store marks the channel.** `Pokemon#item=`, `PCItemStorage#add/remove/clear` and
  the mail helpers mark `:inv`, and a save always sends the full snapshot (hash-gated), so a
  berry eaten in battle or an item lost on release reaches the record.
- **Restore by totals, not by placement.** Uids arrive after the blob is written, evictions
  and redeliveries run after the inventory reconcile, and a Pokemon can be in the record but
  not in the blob. The login therefore restores the bag and the PC from the record, then
  brings each item's total across every store to the record's total: an excess comes off
  held items first (the record's uids only say which Pokemon to prefer), then the bag; a
  deficit is added to the bag. Items of a Pokemon that is gone are never moved to the bag.
- **The record is authoritative only when it is whole.** An older client sends the bag alone;
  the other stores then carry an older seq. They are used only when their seq equals the
  bag's, otherwise the blob's stores are kept and become the new baseline.
- **Trades carry their held item.** Done ahead of E0 as a fix: the commit waits for the offered
  Pokemon to be unchanged (still in the party or a box, same item), and a change after the
  commit is settled when the result comes. With E0, `:trade_lock` and `:trade_commit` also carry
  the item, and the swap moves it between the two records, aborting on a mismatch.
- **One container list.** Party, boxes, the Day Care, a fusion's partner, the Bug Contest's
  set-aside party and the Frontier's saved party (rentals excluded) are enumerated in one
  place, for the snapshot, the restore, the uid sweep and uid lookups. Done ahead of E0 for the
  Day Care and fusions.
- **Credits live until they are settled**, not on a timer: a pickup or gift credit with its
  grant (sealed, voided), a purchase with its transaction; a short grace period applies before
  an increase is called unexplained. A fresh login drops unsettled credits, but the `resume`
  flag that decides "fresh" is the client's, so credits must never depend on it alone.
- **Tiers follow the gates that are on.** The export ships each item's sources; the server
  derives the tiers at boot from the gates enabled (a Mart item is tracked only once shops are
  server transactions; an item ball only with the pickup gate, and an offline pickup becomes
  owed, like a gift).
- **No client-chosen credit.** A gift grant for a computed or unknown event never credits a
  tracked item. Vending needs an explicit request bound to its event, not money that dropped
  (the economy channel coalesces to the latest balance, so any spend would fund it).
- **Level credit from totals.** The reward audit counts Rare and EXP Candies in the bag only,
  so depositing them reads as using them and buys level credit. It moves to totals across all
  stores with E0.

A second adversarial review, of the ledger and of a first draft of E4, found holes that
were open already; they were closed before going on:

- **A sale could be replayed.** The server paid for items its record still held, and a
  client that kept them and sent no new bag could sell them again and again. A sale now
  takes them out of the record in the same transaction as the money.
- **A gift could be paid at every login.** A client that never reported a gift applied
  kept its grant unsealed, and a fresh login voided it. A bag snapshot that shows the item
  now seals the grant, and a grant is voided at most once.
- **A holder could be invented.** The record named a Pokemon as holding an item the held
  counts did not include, which a trade then confirmed. Such stores are refused.
- **The judgment could be made to fail.** An item id too long for the ledger rolled back
  every debt of the snapshot. Ids are checked, and a failed judgment is logged loudly.
- **Bag-only snapshots were judged**, and a PC withdrawal during one read as an increase.
  Only full snapshots are judged, against the last full one's totals, which the server's
  own moves lower.
- **A dropped link bypassed the gates**: a shop or an item ball under a gate fell back to
  the engine's own when the link was down. They now refuse, or leave the ball.
- **Twins**: the engine turns some items into one another (`$bag.replace_item`); they count
  as one item.
- **Races**: the trade swap takes both records' locks first, in account order, and the
  snapshot takes its record's lock before the ledger's rows.

## 5. Steps

Each step ships alone, with unit tests and an autotest scenario.

- **E0 - one record for every item store**, under the rules above. On by default (a dupe
  fix); `PEMK_ITEM_RECORD=bag` keeps the bag-only record. **Done 2026-09-28**, with its
  prerequisites (the trade item binding, the transit holds, the Day Care and fusion lookups).
  A save written before a Pokemon's uid arrived knows it by its mint nonce, so the login
  record names each holder by uid and nonce. Autotest 070 crashes after a PC withdrawal, a
  give and a take: one item each time, where the bag-only record duplicated or lost it.
- **E1 - the item catalogue and the tiers in the exports.** Buy, sell and BP prices, key and
  consumable flags, mart stocks per event (the union of their badge branches), vending events,
  item-ball quantities, and each item's tier. **Prices, flags, shop stocks (with the prices an
  event sets) and item-ball quantities done 2026-09-28**, then the engine's item rules (the
  PC's start items, the Premier Ball bonus); vending and the tiers come with E2b.
- **E2 - the ledger in shadow** (`PEMK_ITEM_AUTHORITY=shadow`). Possession, credits from the
  sources above that are already server-known, `UNEXPLAINED` logs and the `item_unexplained`
  D5 kind. Every autotest scenario runs with it and must log nothing. **E2a done
  2026-09-28**: credits from granted or reported pickups (the export's quantity), literal
  gifts (a one-shot once, a request sent again is the same payout; a computed call never),
  Mart purchases with their Premier Balls, and the PC's start items once per account. A
  traded Pokemon's item counts only as the sender's record knew it, bound to that
  Pokemon's arrival when it has a delivery (once per delivery, re-armed by a fresh login),
  otherwise a credit. An increase no credit covers is a debt for two minutes (a pickup is
  reported after its message closes, when the bag already went out), then `UNEXPLAINED`:
  one line per account and item and one review count per account each sweep. Autotest 072
  buys and picks up honestly and adds an X Attack from nowhere. **E2b done the same day**:
  the world export lists the item sources no request names (computed gifts and item balls,
  `$bag.add`, `pbBuyPrize`, common events, berry plants, the mining game) and the battle
  export the species' wild items and the Pickup, Honey Gather and mining tables; the
  server derives the tiers at boot from them and the gates that are on, judges tracked
  items only, and names in a warning any source whose items it cannot tell
  (`PEMK_ITEM_LOCAL` for the honest ones).
- **E3 - shops as server transactions** (`PEMK_SHOP_ENFORCE`). The client asks to buy or sell;
  the server checks the stock, the price and the balance, moves the money and the credit in
  one transaction, and answers. A sale needs the item in the possession, so a made-up item can
  no longer turn into money. **Marts done 2026-09-28**, then the Battle Point exchange (in
  BP, advertised as its own gate): the server's own ledger rows take negative seqs, so the
  client's next money or BP frame is never taken for a replay. Autotest 071 buys a Poke
  Ball in the Cedolan department store, 073 a Protein for 1 BP in the Battle Frontier Mart.
  Event prices (2026-09-28): the world export follows each clerk's event the way the
  interpreter runs it and lists every price its Mart calls may use, so a price set on one
  branch (the Lerucean stall's Saturday sale) and the catalogue's both pass, a Key Item the
  event always prices never passes at its catalogue $0, and a sale is paid the clerk's own
  buy-back price (setPrice's rule). Autotest 075 buys the stall's Silph Scope and sells it
  a Great Ball.
- **E4 - enforcement** (`PEMK_ITEM_AUTHORITY=on`). Unexplained increases of tracked items are
  not recorded and are corrected on the client. Detailed in section 7. **Done 2026-09-28**
  (migration 028 for the vanished holders); autotest 074 buys a Poke Ball and adds an X
  Attack from nowhere, which the game gives back on its own within the grace plus a sweep.
- **Later:** battle allowances (a won wild battle credits its foe's possible held items, a
  Pickup Pokemon its table), berry plants, the prize desk, and fixes for the engine's own dupes
  (a held item swapped for mail then cancelled - done with E0; Trick or Bestow on a wild
  Pokemon that is then caught - done with E2).

## 6. Limits we accept

- The server bounds what enters the possession; it cannot say an item was used legitimately.
  Uses are the client's, as the EXP and level checks already assume.
- An item added and spent between two snapshots never shows in one. Its effects are judged
  where they land: levels by the reward audit, money by the ledger, and sales by E3.
- Local items stay client-authored until their source is modelled. The tier table says which,
  so an operator knows exactly what is judged.


## 7. Enforcement (E4)

E2 records what it cannot explain; E4 takes it back. A first draft was reviewed
adversarially before any code; the rules below are the result.

**Preconditions.** `PEMK_ITEM_AUTHORITY=on` is honoured only with the pickup, gift and shop
gates `on`, trade redelivery on, the full record (`PEMK_ITEM_RECORD=full`) and complete
exports; otherwise the server says why at boot and runs `shadow`. A gate that is off, or a
source reported after the fact, would turn honest items into corrections.

**The recognized possession.** The record keeps adopting whole snapshots (its layout stays
the client's); the ledger judges full snapshots against its judged totals. An open debt is
an increase no credit covered. The recognized possession of an item is its judged total
minus its open debts, and whatever relies on the possession uses it: a sale needs the
recognized units (and lowers the judged total, never a debt), a trade confirms a held item
only when the sender's record names it and recognizes it (else the swap is refused).

**The verdict.** A debt unpaid after its grace becomes *owed*: logged `UNEXPLAINED`, counted
for review, and kept until its units leave. A late credit pays a pending debt, never an owed
one. A key item is never owed: its verdict goes to review only. Owed debts of an item that
is local since the last boot are dropped, never corrected.

**Corrections.** After each judged snapshot, and when a debt becomes owed, a client able to
(capability `inv_correct`) is sent `:inv_correct { id, seq, items }`: the owed units, bound
to the snapshot seq the server judged last. The client applies it only on a free overworld
frame (no message, menu, battle, trade, box screen, Bug Contest or Frontier challenge),
only while its last sent seq is that seq and nothing changed since, taking the units from
the bag, then the PC, the mailbox and held items; its next `:inv` names the correction it
applied. Anything else drops it, and the next judged snapshot brings a fresh one: a
correction can neither apply twice nor lower a count the server recognizes. A login
restores the record as always; the first judged snapshot after it brings the correction.

**Decreases.** A decrease of an item settles its open debts first, owed then pending (a
pending one spent before its verdict is still logged `UNEXPLAINED`). Except a Pokemon that
drops out of the snapshot while the registry still gives it to the account (a save that
lost a traded Pokemon, or a client hiding one): its item is noted as vanished; the drop
settles no debt, and the same Pokemon coming back with the same item is not an increase.
A released Pokemon simply never comes back.

**Credits** from a gift live seven days (an owed gift may be applied long after its grant);
the others thirty minutes. A fresh login drops them all, as in E2.
