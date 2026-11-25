# Changelog

## v0.2.5

_2026-11-25_

- The add-on now knows how many empty crates are on the AH. Auctionator keeps one price per item, not the quantity.
  - New **Scan crates** button (Crates tab, at the AH) or `/wl scancrates`. It searches each relevant empty crate one at
    a time, waiting for the AH throttle: the crates on your list, the selected ones and every crate that passes the
    filters (Shift-click or `/wl scancrates all` for all 30). It saves how many are listed and their prices, with the
    time. Buy Next searches record the same.
  - Best value, Fill budget, Cheapest and Build list never plan more crates of a type than you hold plus what is listed.
    Each extra crate is priced from the real listings (2nd cheapest, 3rd...), and the fills that do not fit go to the
    next best value. A crate with none listed (and none held) shows "none on AH" and is not picked.
  - Materials: a complete listing snapshot from a Buy Next search also caps that material, so the bundle can switch.
  - New **AH** column on the Crates tab, plus AH counts on the list's crate rows and in the tooltip (cheapest price and
    age). "?" means not scanned; grey means older than 30 minutes. Old data is still used but flagged, in chat and in the
    list warnings. Data older than 6 hours is ignored, so the add-on works as before ("qty unknown").
  - Build list says which crates had fewer listed than selected ("only 1 listed; 4 fill(s) left out").
- When Buy Next finds fewer than the list needs (or none), it saves the new count and says "only 1 listed (need 5):
  Replan?". The new **Replan** button (or `/wl replan`) rebuilds the list with what can be bought.
  - If the list came from Best value, Fill budget or Cheapest, that pick runs again with the cap, so the money goes to the
    next best fills.
  - What you already bought this run counts as yours, even while it is still in the mailbox, and the gold spent stays
    on the budget.
- Bought listings are taken off the saved counts right away.
- The Bags check now runs only when you click Bags check or type `/wl check`. It no longer runs by itself when you close
  the AH, bank or mailbox or leave a rested area, and there is no on-screen alert or sound. `/wl alert` is gone (typing it
  just says so).

## v0.2.4

_2026-11-25_
- Fix: typing a Budget and clicking Fill budget (without pressing Enter) cleared the box and selected nothing. The
  boxes only saved on Enter, so Fill budget saw no budget, and the window refresh then wrote the saved (empty) value back
  into the box. Now every box (Budget on both tabs, Max per Favor, Max each, N, the max unit prices) saves when it loses
  focus, and Cheapest, Best value, Fill budget, Build list and Buy read what is typed first. A refresh never overwrites a
  box you are editing.
- Text that cannot be read as money stays in the box in red, with a chat message; the saved value is kept and the button
  does nothing until you fix it or press Escape. Money now also reads "10 g", "10.5g", "10 gold 5 silver", "1,250g", "10,5g".
- When Fill budget or Best value finds nothing, the selection is kept and chat plus the window say why: "nothing fits 10g:
  the cheapest fill costs 12g", budget already spent this run, crates hidden by filters (and which), empty crates you do not
  hold with no AH price, no material prices (run a scan), or over Max per Favor. `/wl fill 10g` sets the budget and fills.
- Fix: Build list could leave out empty crates you need. Every selected fill now adds its empty crate (selected minus the
  crates this character holds) at the top as "Waylaid Crate (Tier Type)", also when the crate or its materials have no
  AH price (listed with a warning).
  - Crates on alts no longer count as held (you cannot turn them in from there); the chat line says how many your alts
    hold so you can mail them instead.
  - Saved settings from before 0.2.3 get Buy crates turned on (one-time update).
  - Build list prints how many empty crates are to buy and how many are held.

## v0.2.3

_2026-11-25_
- Empty crates you need to buy now go on the shopping list. "Buy crates" check on the Crates tab or `/wl buycrates on|off`, on by default.
  - Crates you hold (bags + bank, plus alts with AltStash) are used first. For each fill beyond those, one empty Waylaid
    Crate (not a Sealed one) is added at its Auctionator price, with the usual cap and budget.
  - The crate price is part of a fill's cost and cost per Favor, for Cheapest, Best value, Fill budget, the per-Favor
    limit and the per-item caps. The Cost column marks it "+c".
  - A crate you hold none of and that has no AH price shows "no crate" and is not auto-picked. If you select it by hand,
    it is listed with a warning; set a cap so Buy Next can buy it.
  - Buy Next buys the crates first (as a listing or a commodity). Auctionator export and Copy text include them.
- New Bags check (button on the Shopping List, `/wl check`). It checks that your BAGS hold an empty crate and one full
  bundle for every planned fill (the list, or the selection without a list). The bank and alts do not count.
  - It shows Ready/Missing per crate with the exact items and amounts, plus a summary. Items in the bank say
    "in bank: withdraw N"; items on alts are flagged too.
  - It shares bag contents out over the fills and switches to another bundle of the crate when the bags hold that one.
  - It runs by itself when you close the AH, bank or mailbox and when you leave a rested area (city / inn). If something
    is missing it posts a raid-warning style alert, with a sound. `/wl alert on|off`, on by default.

## v0.2.2

_2026-11-25_
- Best value and Fill budget can now fill the same crate more than once. They add one fill at a time, always the one
  with the lowest marginal cost per Merchant's Favor, so a cheap crate is repeated while it stays the best deal.
  - Repeats per crate: up to "Max each" (box on the Crates tab or `/wl maxrepeat N`, default 5), or as many as you hold
    when "Held crates" is ticked (bags + bank, alts too with AltStash).
  - Each extra fill is priced after the ones before it: materials you have are used up once, the bundle can switch
    (e.g. Tin Ore -> Copper Ore when the cheap tin is gone), and, for items you searched at the AH in the last 10 minutes,
    the next and dearer listings are used. Without a search the scan price is flat (the chat line says which).
  - The per-Favor limit and the budget are respected for every fill.
- Build list prices repeat fills the same way.
- Crate rows show the count as xN.

## v0.2.1

_2026-11-25_
- Fix: money values with silver (e.g. "Per favor", costs, totals) showed broken color codes such as "cffc7c7..." as
  text. The coloring of g/s/c ran one pattern after another, and the copper pass matched the "7c" inside the silver color
  code and split it. Money text is now built from its parts. Edit boxes (Max per Favor, Budget, caps) stay plain "50s".

## v0.2.0

_2026-11-25_
- Cost-to-reward limit: "Max per Favor" (box on the Crates tab, or `/wl maxper 50s`, saved). Crates whose cheapest fill
  costs more per Merchant's Favor are shown in red (or hidden with "Hide over" / `/wl hideover on`) and are left out of
  Cheapest, Best value, Fill budget and Build list (the list says which were left out).
- Default order is now cost per Favor (best value first).
- New: "Best value" (N crates with the lowest cost per Favor, `/wl best N`) and "Fill budget" (best value first until
  the budget is used, `/wl fill`). Budget box on the Crates tab too.
- Shopping list shows total Merchant's Favor, estimated total and average cost per Favor; the Crates tab shows the
  selection's cost, Favor and cost per Favor.
- Buy Next respects the per-Favor limit with live AH prices: the max unit price for an item is the lower of its cap and
  what keeps its crate within the limit. If today's price pushes the crate over, the item is skipped with the reason.
- AH searches no longer stall or time out:
  - searches wait for the AH throttle (queued and sent as soon as the AH is ready, AUCTION_HOUSE_THROTTLED_SYSTEM_READY
    or IsThrottledMessageSystemReady; CanSendAuctionQuery as a fallback);
  - search results are re-used for 30 s, so after a purchase the next click buys/plans without a new query;
  - results are also polled every 0.25 s in case an AH event is missed;
  - every wait has a timeout that ends in a "click again" message instead of a stuck button; clicking while waiting
    never sends another query;
  - an item with nothing listed is passed over for a minute instead of being searched again and again;
  - the button now reads "Search: <item>" when it will search, and "Get quote" / "Confirm" / "Buy" when it will buy.

## v0.1.0

_2026-11-25_
- First release.
- All 30 WoW Forever Waylaid Crates (Apprentice, Journeyman, Expert, Artisan) with every fill bundle.
- Ranks crates by the cheapest bundle at Auctionator's last scan, or by cost per Merchant's Favor; filters for tier, type,
  your level and crates you hold; subtracts materials you already have (bags + bank, and alts through AltStash).
- Shopping list: select crates (click, "cheapest N" or "select held"), Build list adds up the materials, using each owned
  stack only once.
- Auctionator export (shopping list "Waylaid Shopper") and copyable text.
- Buy Next at the Auction House: one click per step (search, quote, confirm), per-item max unit price (scan + 25% by
  default, editable), a gold budget for the run, skip, live spent / left.
