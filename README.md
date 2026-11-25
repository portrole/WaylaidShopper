# Waylaid Shopper

A WoW Forever add-on (client 1.60.1, Interface 16001) that finds the **cheapest way to fill Waylaid Crates** from
**Auctionator's scan prices**, builds **one shopping list**, and walks it at the Auction House with a **Buy Next** button.

Author: Demnock. License: GPL-3.0 (see LICENSE and NOTICE).

## What it knows
WoW Forever has 30 Waylaid Crates in four tiers: Apprentice (level 10), Journeyman (level 10), Expert (level 20) and
Artisan (level 35), across seven types: Herbs, Ore, Ingots, Textiles, Fabrics, Curiosities and Parts. Each crate
lists several bundles, and **any one bundle fills it**. The filled crate becomes a Sealed crate that you turn in for
Merchant's Favor: Alliance to Marcy Baker at Three Corners (Redridge), Horde to Dokimi west of the Crossroads (Barrens).
White crates pay 5 / 10 / 15 Favor (Apprentice / Journeyman / Expert) and green crates pay double. Artisan values are
an estimate (20 / 40) until confirmed.

## Use
1. Scan the AH with Auctionator (a full scan, or search the materials).
2. `/wl` opens the window. Optional: set **Max per Favor** (e.g. `50s`) so crates that cost more per Merchant's Favor
   are flagged red and left out, and a **Budget**. On the **Crates** tab every crate shows its cheapest fill and cost. Hover a crate for all of
   its bundles and prices. Left-click selects one more, right-click one less, Shift-click clears.
   Crates are sorted by cost per Favor (best value first). Use **Cheapest** (N crates), **Best value** (the N best fills; the same crate can be
   repeated up to **Max each**), **Fill budget** (best-value fills until the budget is used) or **Held** (the crates in your bags).
3. **Build list**: each selected crate takes its cheapest bundle after what you already have, and the materials are
   added up.
   With **Buy crates** on (default), every empty crate you need and this character does not hold is added at the top as
   "Waylaid Crate (Tier Type)" (crates on alts are not counted; the chat line tells you to mail them), and its price counts
   toward the crate's cost and cost per Favor. Crates you hold none of that have no AH price are not auto-picked.
4. **Shopping List** tab: quantity left, scan price, total, and a **max unit price** per item (scan price + 25% by
   default; type e.g. `1g20s` + Enter to set your own). Set a **Budget** for the run (e.g. `50g`).
5. At the Auction House click **Search: <item>**:
   - It searches the next item (waiting for the AH if it is busy; results are re-used for 30 s), and the status line
     says exactly what the next click buys. Clicking while it waits never sends another query.
   - Materials (commodities): the next click asks for a price quote, then **Confirm** buys. If the quote is above your
     cap or budget, it is cancelled and the reason is shown.
   - Single listings: the next click buys that one listing at its buyout.
   - It never buys above the max unit price or a price that would push a crate over your per-Favor limit, never more than the list still needs, and never past the budget.
     Your own auctions are skipped.
   You can also use **Auctionator list** (it writes a shopping list named "Waylaid Shopper") or **Copy text**.
6. **Bags check** (button or `/wl check`) before you leave town: for every planned fill, it checks for an empty crate and
   one complete bundle in your **bags**. It lists Ready/Missing per crate with the exact amounts and says what to
   withdraw from the bank. It also runs by itself when you close the AH, bank or mailbox and when you leave a city or
   inn, and shows a raid-warning alert if anything is missing (`/wl alert off` to stop that). AH purchases arrive by mail.

## Commands
| Command | What it does |
| --- | --- |
| `/wl` or `/waylaid` | open / close |
| `/wl cheapest <N>` | select the N cheapest crates (current filters) |
| `/wl best <N>` | select the N best-value crates (lowest cost per Favor) |
| `/wl fill` | best-value fills until the budget is used (same crate more than once allowed) |
| `/wl fill [money]` | set the budget (optional, e.g. `10g`) and select best-value fills until it is used; says why if nothing fits |
| `/wl buycrates on\|off` | add the empty crates you need (and do not hold) to the list, priced into cost per Favor (default on) |
| `/wl check` | Bags check: are the empty crates and bundles for every planned fill in your bags? Tells you what to withdraw from the bank |
| `/wl alert on\|off` | run the Bags check by itself on closing the AH / bank / mailbox and on leaving a city or inn, alert if missing (default on) |
| `/wl maxrepeat <N>` | max fills of the same crate for Best value / Fill budget (default 5; Held crates = what you hold) |
| `/wl maxper <money\|off>` | max cost per Merchant's Favor, e.g. `/wl maxper 50s` |
| `/wl hideover on\|off` | hide crates over that limit (else shown in red) |
| `/wl owned` | select the crates you hold |
| `/wl select <crate> [n]`, `/wl clear` | select by name, clear |
| `/wl build` | build the shopping list |
| `/wl budget <money\|off>` | budget for the run, e.g. `/wl budget 50g` |
| `/wl cap <item> <money\|auto>` | max unit price, e.g. `/wl cap Copper Bar 1g20s` |
| `/wl cappct <n>` | default cap: scan price + n% (default 25) |
| `/wl buy`, `/wl skip`, `/wl reset` | Buy Next, skip the current item, reset spent / bought |
| `/wl export`, `/wl text` | Auctionator shopping list, copyable text |
| `/wl useowned on\|off`, `/wl alts on\|off` | subtract what you have; count alts (AltStash) |

Money: `1g20s5c`, `50g`, `120s`, `75c`, or a plain number of gold (`0.5` = 50s).

## Notes
- Boxes save when you press Enter or click elsewhere, and the buttons use what you typed. Red text = not understood (try `10g`, `10g 50s`, `75s`); Escape restores the saved value.
- Prices come only from Auctionator's public API (`Auctionator.API.v1`). `*` = price older than 3 days. The window
  refreshes when Auctionator finishes a scan.
- Every purchase needs your click (WoW requires a hardware event); nothing is bought automatically.
- If a single listing's stack is bigger than what you still need, it is not bought ("never more than needed").
- Optional: Auctionator (prices, export), AltStash (counts your alts' materials and crates).

## Data
`CrateData.lua` is generated by `tools/gen_cratedata.py` from ForeverDiff's Waylaid Crates page, which ForeverDiff reads
from the game client. A saved copy of the page is in `tools/`. Material IDs were checked against QuestieDB 1.1.6
(Forever). To regenerate:
```
python3 tools/parse_foreverdiff.py tools/source_foreverdiff_2026-11-25.html > tools/crates.json
python3 tools/gen_cratedata.py tools/crates.json
```
