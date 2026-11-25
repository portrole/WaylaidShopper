-- WaylaidShopper: "Buy Next" walk through the shopping list at the Auction House.
-- WoW: Forever 1.60.1 has the modern C_AuctionHouse API (same as Classic Era 1.15.x). Purchases need a hardware event
-- (a click or a typed command), so this NEVER buys on its own: every purchase is one of your clicks.
--   Search:  one click searches the next item (C_AuctionHouse.SendSearchQuery). Searches go through the AH's throttle:
--            when the AH is busy the search is queued and sent by itself as soon as the AH is ready (no purchase is
--            ever made without a click). Results are re-used for CACHE_TTL seconds, so after a purchase the next click
--            plans from the results already on screen instead of searching again.
--   Buy:     the button then shows exactly what the next click buys.
--     commodity (stackable materials): click = StartCommoditiesPurchase (server quote), then Confirm click =
--              ConfirmCommoditiesPurchase, only if the quote is within the caps, the per-Favor limit and the budget.
--     item listing: click = PlaceBid on ONE listing at its buyout (stack not bigger than still needed).
-- Never above the item's cap or the per-Favor limit, never more than the list still needs, never past the budget.
-- No step can stall: every wait has a timeout, results are also polled (in case an event is missed), and a timeout
-- leaves a "click again" message instead of a stuck button.
local ADDON, WS = ...
local B = {}
WS.Buyer = B

B.SEARCH_TIMEOUT = 10           -- seconds to wait for search results
B.QUOTE_TIMEOUT = 10            -- seconds to wait for a commodity quote / purchase answer
B.QUEUE_TIMEOUT = 20            -- seconds a queued search waits for the AH throttle
B.CACHE_TTL = 30                -- seconds search results are re-used without a new query
B.NONE_TTL = 60                 -- seconds an item with no listings is passed over
B.POLL = 0.25                   -- seconds between result polls while waiting
B.DEPTH_TTL = 600               -- seconds a listing snapshot is used to price repeat fills (Best value / Build list)
local SORT_PRICE = (Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price) or 0

B.state = "idle"                -- idle | queued | searching | ready | quoting | confirm | buying
B.status = "Open the Auction House, then click Search."
local cur = nil                 -- { id, key, isCommodity, qty, planTotal, cap, capWhy, auctionID, buyout, quoteTotal }
local waitStart = 0
local ahOpen = false
local searched = {}             -- itemID -> time of the last search whose results arrived
local none = {}                 -- itemID -> time the AH had no usable listing
local boughtAuctions = {}       -- auctionIDs bought this AH visit (item listings), never offered again
local depth = {}                -- itemID -> { t = time, rows = { {unit=, qty=}, ... } } listings seen, cheapest first
B._searched, B._none = searched, none

local function Now() return (GetTime and GetTime()) or (time and time()) or 0 end
local function AH() return type(C_AuctionHouse) == "table" and C_AuctionHouse or nil end
local function F(name) local A = AH(); return A and type(A[name]) == "function" and A[name] or nil end
local function Money(c) return WS.Prices.Money(c) end
local function Name(id) return WS.ItemName(id) end
local function Refresh() if WS.RefreshUI then pcall(WS.RefreshUI) end end
local function CrateName(id) local c = id and WS.byId[id]; return c and (c.name:gsub("^Waylaid Crate: ", "")) or "a crate" end

local function Set(state, status)
    B.state = state
    if status then B.status = status end
    if state == "queued" or state == "searching" or state == "quoting" or state == "buying" then waitStart = Now() end
    Refresh()
end

local function CancelQuote() local c = F("CancelCommoditiesPurchase"); if c then pcall(c) end end

function B.Reset()
    if B.state == "quoting" or B.state == "confirm" then CancelQuote() end
    cur = nil
    Set("idle", ahOpen and "Click Search to look up the next item." or "Open the Auction House, then click Search.")
end

function B.IsAHOpen() return ahOpen end
function B.ClearShort() B.short = nil end
function B.ClearDepth() for k in pairs(depth) do depth[k] = nil end end
function B.Current() return cur end

-- AH throttle: true when a query may be sent now
function B.ThrottleReady()
    local ready = F("IsThrottledMessageSystemReady")
    if ready then local ok, r = pcall(ready); if ok and r == false then return false end; return true end
    if type(CanSendAuctionQuery) == "function" then local ok, r = pcall(CanSendAuctionQuery); if ok then return r and true or false end end
    return true
end

-- next list item that still needs buying, was not skipped, and was not just found empty
local function NextItem()
    local L = WS.db.list
    if not L then return nil end
    local t = Now()
    local firstNone
    for _, id in ipairs(L.order) do
        if WS.Remaining(id) > 0 and not WS.db.run.skip[id] then
            if not (none[id] and t - none[id] < B.NONE_TTL) then return id end
            firstNone = firstNone or id
        end
    end
    return nil, firstNone
end
B.NextItem = NextItem

-- take bought units off the recorded listings (cheapest first) so planning sees what is left
local function TakeListed(id, qty)
    local function take(rows)
        local left = qty
        for i = 1, #rows do
            if left <= 0 then break end
            local s = math.min(rows[i].qty, left)
            rows[i].qty = rows[i].qty - s; left = left - s
        end
        for i = #rows, 1, -1 do if rows[i].qty <= 0 then table.remove(rows, i) end end
    end
    if depth[id] then take(depth[id].rows) end
    local rec = WS.db.avail and WS.db.avail[id]
    if rec and rec.rows then take(rec.rows); rec.qty = math.max(0, (rec.qty or 0) - qty) end
end
B.TakeListed = TakeListed

local function Record(id, qty, total)
    TakeListed(id, qty)
    local run = WS.db.run
    run.bought[id] = (run.bought[id] or 0) + qty
    run.spent = (run.spent or 0) + total
    run.log[#run.log + 1] = { id = id, qty = qty, total = total, t = time and time() or 0 }
    WS.Print(string.format("bought %dx %s for %s. Spent this run: %s.", qty, Name(id), WS.Prices.Format(total), WS.Prices.Format(run.spent)))
end

local function CapReason(id, cap, why, crate, price)
    if why == "favor" then
        return string.format("at %s each %s would cost more than your %s per Favor limit (max %s each)", Money(price), CrateName(crate), Money(WS.MaxPer()), Money(cap))
    end
    return string.format("cheapest is %s each, above your cap of %s", Money(price), Money(cap))
end

------------------------------------------------------------------------
-- results -> plan (what the next click buys)
------------------------------------------------------------------------
local function NumCommodity(id) local f = F("GetNumCommoditySearchResults"); if not f then return 0 end local ok, n = pcall(f, id); return (ok and tonumber(n)) or 0 end
local function NumItem(key) local f = F("GetNumItemSearchResults"); if not f then return 0 end local ok, n = pcall(f, key); return (ok and tonumber(n)) or 0 end

local function NoneListed(id, why)
    none[id] = Now()
    depth[id] = nil
    WS.RecordAvail(id, {}, true)
    local need = WS.Remaining(id)
    if need > 0 then B.short = { id = id, listed = 0, need = need }; why = why .. " Replan to rebuild the list without it." end
    cur = nil
    local nxt = NextItem()
    Set("idle", "|cffffd100" .. why .. "|r" .. (nxt and (" Click Search for " .. Name(nxt) .. ".") or " Nothing else to buy right now."))
end

local function PlanCommodity()
    local id = cur.id
    local get = F("GetCommoditySearchResultInfo")
    if not get then return Set("idle", "|cffff4040No commodity results API.|r") end
    local n = NumCommodity(id)
    local need = WS.Remaining(id)
    local cap, why, crate = WS.EffectiveCap(id)
    local budget = WS.BudgetLeft()
    local qty, total, firstPrice, stopReason = 0, 0, nil, nil
    for i = 1, n do
        local ok, r = pcall(get, id, i)
        if ok and type(r) == "table" and tonumber(r.unitPrice) then
            local unit = tonumber(r.unitPrice)
            local avail = (tonumber(r.quantity) or 0) - (tonumber(r.numOwnerItems) or 0)   -- your own auctions cannot be bought
            if avail > 0 then
                firstPrice = firstPrice or unit
                if unit > cap then stopReason = stopReason or CapReason(id, cap, why, crate, unit); break end
                local take = math.min(avail, need - qty)
                if budget then
                    local afford = math.floor((budget - total) / unit)
                    if afford < take then take = math.max(0, afford); stopReason = stopReason or "budget limit" end
                end
                qty = qty + take
                total = total + take * unit
                if qty >= need or (budget and stopReason) then break end
            end
        end
    end
    if not firstPrice then return NoneListed(id, "No " .. Name(id) .. " for sale right now (passed over for a minute).") end
    if qty <= 0 then
        local reason = stopReason or "nothing affordable"
        if firstPrice > cap then reason = CapReason(id, cap, why, crate, firstPrice) end
        if budget and firstPrice <= cap and budget < firstPrice then reason = "budget left " .. Money(budget) .. " is less than one unit (" .. Money(firstPrice) .. ")" end
        cur = nil
        if why == "favor" and firstPrice > cap then WS.db.run.skip[id] = true end   -- the crate is not worth it at today's price
        return Set("idle", "|cffff4040Not buying " .. Name(id) .. ": " .. reason .. ".|r" .. (WS.db.run.skip[id] and " Skipped; click Search for the next item." or " Skip it, raise the cap (/wl cap) or the budget."))
    end
    cur.qty, cur.planTotal, cur.cap, cur.capWhy = qty, total, cap, why
    cur.isCommodity = true
    local note = (qty < need) and string.format(" |cffaaaaaa(%d of %d: %s)|r", qty, need, stopReason or "not enough listed") or ""
    Set("ready", string.format("Next click: price quote for %dx %s, about %s (%s each avg, max %s%s).%s", qty, Name(id), Money(total),
        Money(math.floor(total / qty + 0.5)), Money(cap), why == "favor" and " by Favor limit" or "", note))
end

local function PlanItem()
    local id, key = cur.id, cur.key
    local get = F("GetItemSearchResultInfo")
    if not get then return Set("idle", "|cffff4040No item results API.|r") end
    local n = NumItem(key)
    local need = WS.Remaining(id)
    local cap, why, crate = WS.EffectiveCap(id)
    local budget = WS.BudgetLeft()
    local best, seen, cheapestUnit, tooBig = nil, 0, nil, 0
    for i = 1, n do
        local ok, r = pcall(get, key, i)
        if ok and type(r) == "table" and tonumber(r.buyoutAmount) and tonumber(r.buyoutAmount) > 0 and not r.containsOwnerItem
            and not boughtAuctions[r.auctionID] then
            seen = seen + 1
            local q = math.max(1, tonumber(r.quantity) or 1)
            local buy = tonumber(r.buyoutAmount)
            local unit = buy / q
            cheapestUnit = (cheapestUnit and math.min(cheapestUnit, unit)) or unit
            if q > need then tooBig = tooBig + 1
            elseif unit <= cap and (not budget or buy <= budget) then
                if not best or unit < best.unit or (unit == best.unit and q > best.q) then best = { auctionID = r.auctionID, q = q, buy = buy, unit = unit } end
            end
        end
    end
    if seen == 0 then return NoneListed(id, "No " .. Name(id) .. " with a buyout right now (passed over for a minute).") end
    if not best then
        local reason
        if cheapestUnit and cheapestUnit > cap then reason = CapReason(id, cap, why, crate, math.floor(cheapestUnit))
        elseif tooBig > 0 then reason = "every listing within your cap is a bigger stack than the " .. need .. " you still need"
        else reason = "no listing fits the budget left (" .. Money(budget or 0) .. ")" end
        cur = nil
        if why == "favor" and cheapestUnit and cheapestUnit > cap then WS.db.run.skip[id] = true end
        return Set("idle", "|cffff4040Not buying " .. Name(id) .. ": " .. reason .. ".|r" .. (WS.db.run.skip[id] and " Skipped; click Search for the next item." or ""))
    end
    cur.isCommodity = false
    cur.auctionID, cur.qty, cur.buyout, cur.planTotal, cur.cap, cur.capWhy = best.auctionID, best.q, best.buy, best.buy, cap, why
    Set("ready", string.format("Next click BUYS %dx %s for %s (%s each, max %s%s).", best.q, Name(id), Money(best.buy), Money(math.floor(best.unit + 0.5)),
        Money(cap), why == "favor" and " by Favor limit" or ""))
end

-- snapshot of the listings (cheapest first, your own auctions left out) for pricing repeat fills; also saved as the
-- item's AH availability (WS.RecordAvail). Returns the total quantity listed.
local function Snapshot(kind, id, key)
    id, key = id or cur.id, key or cur.key
    local rows, full = {}, true
    if kind == "commodity" then
        local get = F("GetCommoditySearchResultInfo")
        if not get then return end
        for i = 1, NumCommodity(id) do
            local ok, r = pcall(get, id, i)
            if ok and type(r) == "table" and tonumber(r.unitPrice) then
                local q = (tonumber(r.quantity) or 0) - (tonumber(r.numOwnerItems) or 0)
                if q > 0 then rows[#rows + 1] = { unit = tonumber(r.unitPrice), qty = q } end
            end
        end
        local has = F("HasFullCommoditySearchResults")
        if has then local ok, r = pcall(has, id); if ok and r == false then full = false end end
    else
        local get = F("GetItemSearchResultInfo")
        if not get then return end
        for i = 1, NumItem(key) do
            local ok, r = pcall(get, key, i)
            if ok and type(r) == "table" and tonumber(r.buyoutAmount) and tonumber(r.buyoutAmount) > 0 and not r.containsOwnerItem
                and not boughtAuctions[r.auctionID] then
                local q = math.max(1, tonumber(r.quantity) or 1)
                rows[#rows + 1] = { unit = tonumber(r.buyoutAmount) / q, qty = q }
            end
        end
        local has = F("HasFullItemSearchResults")
        if has then local ok, r = pcall(has, key); if ok and r == false then full = false end end
    end
    table.sort(rows, function(a, b) return a.unit < b.unit end)
    depth[id] = { t = Now(), rows = rows }
    WS.RecordAvail(id, rows, full)
    local n = 0
    for _, r in ipairs(rows) do n = n + r.qty end
    return n
end
B.Snapshot = Snapshot

-- listings seen for an item in the last DEPTH_TTL seconds (nil when none / too old)
function B.Depth(id)
    local d = depth[id]
    if not d or Now() - d.t > B.DEPTH_TTL or #d.rows == 0 then return nil end
    return d.rows
end

-- results for cur arrived (event or poll)
local function OnResults(kind)
    if not cur or B.state ~= "searching" then return end
    searched[cur.id] = Now()
    local ok, listed = pcall(Snapshot, kind)
    local id, need = cur.id, WS.Remaining(cur.id)
    if ok and listed and listed < need then
        B.short = { id = id, listed = listed, need = need }
        WS.Print(string.format("|cffffd100only %d %s listed on the AH (the list needs %d).|r Click Replan to rebuild the list with what can be bought.", listed, Name(id), need))
    elseif B.short and B.short.id == id then B.short = nil end
    if kind == "commodity" then PlanCommodity() else PlanItem() end
    if B.short and B.short.id == id and B.status and not B.status:find("Replan", 1, true) then
        B.status = B.status .. string.format(" |cffffd100Only %d listed (need %d): Replan?|r", B.short.listed, B.short.need)
        Refresh()
    end
end

-- results already on hand for this item (fresh enough to plan without a new query)?
local function CachedKind(id, key)
    local t = searched[id]
    if not t or Now() - t > B.CACHE_TTL then return nil end
    if NumCommodity(id) > 0 then return "commodity" end
    if NumItem(key) > 0 then return "item" end
    return nil
end

------------------------------------------------------------------------
-- search (queued behind the AH throttle)
------------------------------------------------------------------------
local function SendSearch()
    local send = F("SendSearchQuery")
    local ok, err = pcall(send, cur.key, { { sortOrder = SORT_PRICE, reverseSort = false } }, true)
    if not ok then cur = nil; return Set("idle", "|cffff4040Search failed: " .. tostring(err) .. ". Click Search to retry.|r") end
    Set("searching", "Searching " .. Name(cur.id) .. "...")
end

local function Search()
    if not ahOpen then return Set("idle", "Open the Auction House first.") end
    local send, mk = F("SendSearchQuery"), F("MakeItemKey")
    if not (send and mk) then return Set("idle", "|cffff4040This client has no C_AuctionHouse search API. Use the Auctionator list instead (/wl export).|r") end
    local id, waiting = NextItem()
    if not id then
        if waiting then return Set("idle", "|cffffd100Nothing listed right now for what is left (" .. Name(waiting) .. "...). Try again in a minute or /wl reset.|r") end
        return Set("idle", "|cff40ff40Shopping list done (or the rest is skipped).|r")
    end
    local cap = WS.EffectiveCap(id)
    if not cap then
        return Set("idle", string.format("|cffff4040%s has no scanned price, so no cap. Set one: /wl cap %s 1g (or Skip).|r", Name(id), Name(id)))
    end
    local left = WS.BudgetLeft()
    if left and left <= 0 then return Set("idle", "|cffff4040Budget reached (" .. Money(WS.db.budget) .. "). Raise it or /wl budget off.|r") end
    local okK, key = pcall(mk, id)
    if not okK or type(key) ~= "table" then return Set("idle", "|cffff4040Could not make an item key for " .. Name(id) .. ".|r") end
    cur = { id = id, key = key }
    local info = F("GetItemKeyInfo")
    if info then local ok, ki = pcall(info, key); if ok and type(ki) == "table" then cur.isCommodity = ki.isCommodity end end
    -- fresh results already on hand: plan from them, no new query
    local kind = CachedKind(id, key)
    if kind then
        B.state = "searching"
        return OnResults(kind)
    end
    if not B.ThrottleReady() then
        return Set("queued", "AH busy: " .. Name(id) .. " will be searched as soon as the AH is ready...")
    end
    SendSearch()
end

------------------------------------------------------------------------
-- buy steps
------------------------------------------------------------------------
local function StartPurchase()
    local cap = WS.EffectiveCap(cur.id)
    if cur.isCommodity then
        local start = F("StartCommoditiesPurchase")
        if not start then return Set("idle", "|cffff4040No StartCommoditiesPurchase API.|r") end
        if not cap or cur.planTotal > cur.qty * cap then cur = nil; return Set("idle", "|cffff4040Your limits changed: click Search to re-plan.|r") end
        local ok, err = pcall(start, cur.id, cur.qty)
        if not ok then cur = nil; return Set("idle", "|cffff4040Could not start the purchase: " .. tostring(err) .. "|r") end
        Set("quoting", "Waiting for the server's price quote...")
    else
        local bid = F("PlaceBid")
        if not bid then return Set("idle", "|cffff4040No PlaceBid API.|r") end
        -- re-check limits right before committing
        if not cap or cur.buyout > cur.qty * cap + 0.5 then cur = nil; return Set("idle", "|cffff4040This listing is now above your cap / per-Favor limit. Click Search to re-plan.|r") end
        local left = WS.BudgetLeft()
        if left and cur.buyout > left then cur = nil; return Set("idle", "|cffff4040Over budget now. Click Search to re-plan.|r") end
        if cur.qty > WS.Remaining(cur.id) then cur = nil; return Set("idle", "|cffff4040You no longer need that many. Click Search to re-plan.|r") end
        local ok, err = pcall(bid, cur.auctionID, cur.buyout)
        if not ok then cur = nil; return Set("idle", "|cffff4040Buy failed: " .. tostring(err) .. "|r") end
        Set("buying", "Buying " .. cur.qty .. "x " .. Name(cur.id) .. "...")
    end
end

local function Confirm()
    local conf = F("ConfirmCommoditiesPurchase")
    if not conf then return Set("idle", "|cffff4040No ConfirmCommoditiesPurchase API.|r") end
    local qr = F("GetQuoteDurationRemaining")
    if qr then
        local ok, s = pcall(qr)
        if ok and tonumber(s) and tonumber(s) <= 0 then
            CancelQuote(); cur = nil
            return Set("idle", "Quote expired. Click Search to re-plan (uses the results on screen, no new query).")
        end
    end
    local ok, err = pcall(conf, cur.id, cur.qty)
    if not ok then cur = nil; return Set("idle", "|cffff4040Confirm failed: " .. tostring(err) .. "|r") end
    Set("buying", "Buying " .. cur.qty .. "x " .. Name(cur.id) .. "...")
end

local function Waited() return math.floor(Now() - waitStart) end

-- the Buy Next button / "/wl buy"
function B.Click()
    if B.scan then B.status = string.format("Scanning crates %d/%d... (Buy Next waits for the scan)", B.scan.i, #B.scan.queue); Refresh() return end
    if not WS.db.list then return Set("idle", "Build a shopping list first (Crates tab -> Build list).") end
    if B.state == "idle" then Search()
    elseif B.state == "ready" and cur then StartPurchase()
    elseif B.state == "confirm" and cur then Confirm()
    elseif B.state == "queued" or B.state == "searching" or B.state == "quoting" or B.state == "buying" then
        B.Tick(true)                 -- a click checks for results / timeouts right away
        if B.state == "queued" or B.state == "searching" or B.state == "quoting" or B.state == "buying" then
            B.status = "Still waiting for the AH (" .. Waited() .. "s)... nothing is bought until it answers."
            Refresh()
        end
    else B.Reset() end
end

function B.Skip()
    local id = (cur and cur.id) or NextItem()
    if B.state == "quoting" or B.state == "confirm" then CancelQuote() end
    cur = nil
    if id then WS.db.run.skip[id] = true; Set("idle", "Skipped " .. Name(id) .. " for this run (/wl reset brings it back).")
    else Set("idle", "Nothing to skip.") end
end

-- label for the button
function B.ButtonText()
    if B.scan then return string.format("Scanning %d/%d", B.scan.i, #B.scan.queue) end
    if B.state == "ready" and cur then
        if cur.isCommodity then return "Get quote: " .. cur.qty .. "x" end
        return "Buy " .. cur.qty .. "x " .. WS.Prices.Format(cur.buyout)
    elseif B.state == "confirm" and cur then return "Confirm " .. WS.Prices.Format(cur.quoteTotal or 0)
    elseif B.state == "queued" then return "AH busy..."
    elseif B.state == "searching" then return "Searching..."
    elseif B.state == "quoting" then return "Quoting..."
    elseif B.state == "buying" then return "Buying..."
    end
    local id = WS.db and WS.db.list and NextItem()
    if id then
        local nm = Name(id)
        if #nm > 14 then nm = nm:sub(1, 13) .. "." end
        return "Search: " .. nm
    end
    return "Search"
end

------------------------------------------------------------------------
-- ticker: throttle queue, result polling, timeouts (runs only while waiting)
------------------------------------------------------------------------
local acc = 0
function B.Tick(force)
    local s = B.state
    if s == "queued" then
        if not ahOpen or not cur then return B.Reset() end
        if B.ThrottleReady() then return SendSearch() end
        if Now() - waitStart > B.QUEUE_TIMEOUT then
            cur = nil
            return Set("idle", "|cffffd100The AH stayed busy for " .. B.QUEUE_TIMEOUT .. "s (another addon may be scanning). Click Search again in a few seconds.|r")
        end
    elseif s == "searching" then
        if not cur then return B.Reset() end
        -- poll: results can arrive without our event reaching us
        if Now() - waitStart >= 0.3 or force then
            local hasC, hasI = F("HasFullCommoditySearchResults"), F("HasFullItemSearchResults")
            if NumCommodity(cur.id) > 0 then
                local full = true; if hasC then local ok, r = pcall(hasC, cur.id); full = (not ok) or r ~= false end
                if full or Now() - waitStart > 2 then return OnResults("commodity") end
            elseif NumItem(cur.key) > 0 then
                local full = true; if hasI then local ok, r = pcall(hasI, cur.key); full = (not ok) or r ~= false end
                if full or Now() - waitStart > 2 then return OnResults("item") end
            end
        end
        if Now() - waitStart > B.SEARCH_TIMEOUT then
            local id = cur.id
            cur = nil
            -- the AH answers an empty search with no rows: treat a full answer with no rows as "none listed"
            local hasC = F("HasFullCommoditySearchResults")
            local full = false
            if hasC then local ok, r = pcall(hasC, id); full = ok and r == true end
            if full then return NoneListed(id, "No " .. Name(id) .. " for sale right now (passed over for a minute).") end
            return Set("idle", "|cffffd100The AH did not answer in " .. B.SEARCH_TIMEOUT .. "s (busy or throttled). Click Search to try again.|r")
        end
    elseif s == "quoting" or s == "buying" then
        if Now() - waitStart > B.QUOTE_TIMEOUT then
            if s == "quoting" then CancelQuote() end
            local id = cur and cur.id
            cur = nil
            if id then searched[id] = nil end   -- results may be stale now
            return Set("idle", "|cffffd100No answer from the AH in " .. B.QUOTE_TIMEOUT .. "s. Check your mailbox/bags; click Search to re-plan.|r")
        end
    end
end

------------------------------------------------------------------------
-- Scan crates: one search per empty crate (behind the AH throttle) to record how many are listed and at what prices.
-- Auctionator keeps one price per item, not the quantity, so this is what caps crate purchases to what is for sale.
------------------------------------------------------------------------
B.SCAN_EMPTY = 2.5             -- seconds after which a complete answer with no rows means "none listed"
local function ScanIDs(all)
    local ids, seen = {}, {}
    local function add(id) if id and not seen[id] then seen[id] = true; ids[#ids + 1] = id end end
    local L = WS.db.list
    if L then for _, id in ipairs(L.order) do if L.items[id] and L.items[id].isCrate then add(id) end end end
    for _, c in ipairs(WS.Crates or {}) do if (WS.db.sel[c.id] or 0) > 0 then add(c.id) end end
    for _, c in ipairs(WS.Crates or {}) do if all or WS.PassesFilter(c) then add(c.id) end end
    return ids
end
B.ScanIDs = ScanIDs

local function ScanFinish(msg)
    local s = B.scan
    B.scan = nil
    if s then
        local listed, zero, unknown = 0, 0, 0
        for _, id in ipairs(s.queue) do
            local r = WS.Avail(id)
            if s.done[id] == "ok" and r then if (r.qty or 0) > 0 then listed = listed + 1 else zero = zero + 1 end else unknown = unknown + 1 end
        end
        WS.Print(msg or string.format("Scan crates done: %d crate type(s) listed, %d none listed%s.", listed, zero,
            unknown > 0 and (", " .. unknown .. " no answer (scan again)") or ""))
    end
    Refresh()
end

local function ScanSend()
    local s = B.scan
    local send = F("SendSearchQuery")
    local ok = send and pcall(send, s.key, { { sortOrder = SORT_PRICE, reverseSort = false } }, true)
    if not ok then s.done[s.id] = "fail"; s.state = "next"; return end
    s.state, s.sent = "sent", Now()
end

local function ScanNext()
    local s = B.scan
    if not s then return end
    s.i = s.i + 1
    local id = s.queue[s.i]
    if not id then return ScanFinish() end
    local mk = F("MakeItemKey")
    local ok, key = pcall(mk, id)
    if not ok or type(key) ~= "table" then s.done[id] = "fail"; return ScanNext() end
    s.id, s.key = id, key
    B.status = string.format("Scanning crates %d/%d: %s...", s.i, #s.queue, CrateName(id))
    if B.ThrottleReady() then ScanSend() else s.state, s.sent = "queued", Now() end
    Refresh()
end

local function ScanGot(kind)
    local s = B.scan
    if not s or s.state ~= "sent" then return end
    pcall(Snapshot, kind, s.id, s.key)
    searched[s.id] = Now()
    s.done[s.id] = "ok"
    ScanNext()
end

-- ids: list of crate item IDs (default: the list's crates, the selection and every crate passing the filters)
function B.ScanCrates(all)
    if not ahOpen then WS.Print("Scan crates: open the Auction House first."); return false end
    if B.scan then WS.Print("Scan crates is already running."); return false end
    if not (F("SendSearchQuery") and F("MakeItemKey")) then WS.Print("Scan crates: this client has no C_AuctionHouse search API."); return false end
    if B.state ~= "idle" and B.state ~= "ready" then WS.Print("Scan crates: finish the current purchase first."); return false end
    local ids = ScanIDs(all)
    if #ids == 0 then WS.Print("Scan crates: no crates to scan."); return false end
    if B.state == "ready" then cur = nil; B.state = "idle" end
    B.scan = { queue = ids, i = 0, done = {} }
    WS.Print(string.format("Scan crates: searching %d empty crate type(s), one at a time...", #ids))
    ScanNext()
    return true
end

function B.ScanTick()
    local s = B.scan
    if not s then return end
    if not ahOpen then return ScanFinish("Scan crates stopped: the AH was closed.") end
    if s.state == "next" then return ScanNext() end
    if s.state == "queued" then
        if B.ThrottleReady() then return ScanSend() end
        if Now() - s.sent > B.QUEUE_TIMEOUT then return ScanFinish("Scan crates stopped: the AH stayed busy. Try again in a few seconds.") end
        return
    end
    if s.state == "sent" then
        local wait = Now() - s.sent
        if wait >= 0.3 then
            local hasC, hasI = F("HasFullCommoditySearchResults"), F("HasFullItemSearchResults")
            if NumCommodity(s.id) > 0 then
                local full = true; if hasC then local ok, r = pcall(hasC, s.id); full = (not ok) or r ~= false end
                if full or wait > 2 then return ScanGot("commodity") end
            elseif NumItem(s.key) > 0 then
                local full = true; if hasI then local ok, r = pcall(hasI, s.key); full = (not ok) or r ~= false end
                if full or wait > 2 then return ScanGot("item") end
            elseif wait > B.SCAN_EMPTY then
                local full = false
                if hasI then local ok, r = pcall(hasI, s.key); full = full or (ok and r == true) end
                if hasC then local ok, r = pcall(hasC, s.id); full = full or (ok and r == true) end
                if full then
                    WS.RecordAvail(s.id, {}, true); depth[s.id] = nil
                    s.done[s.id] = "ok"
                    return ScanNext()
                end
            end
        end
        if wait > B.SEARCH_TIMEOUT then s.done[s.id] = "noanswer"; return ScanNext() end
    end
end

------------------------------------------------------------------------
-- events
------------------------------------------------------------------------
local ev = CreateFrame("Frame")
local EVENTS = { "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "COMMODITY_SEARCH_RESULTS_UPDATED", "COMMODITY_SEARCH_RESULTS_ADDED",
    "ITEM_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_ADDED", "AUCTION_HOUSE_THROTTLED_SYSTEM_READY",
    "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE", "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED",
    "AUCTION_HOUSE_PURCHASE_COMPLETED", "AUCTION_HOUSE_SHOW_ERROR" }
for _, e in ipairs(EVENTS) do pcall(ev.RegisterEvent, ev, e) end
B._events = ev
ev:SetScript("OnUpdate", function(_, elapsed)
    if (B.state == "idle" or B.state == "ready" or B.state == "confirm") and not B.scan then acc = 0; return end
    acc = acc + (tonumber(elapsed) or 0)
    if acc >= B.POLL then acc = 0; if B.scan then B.ScanTick() else B.Tick() end end
end)

local function KeyID(k) return type(k) == "table" and tonumber(k.itemID) or nil end

function B.OnEvent(event, a1, a2)
    if event == "AUCTION_HOUSE_SHOW" then
        ahOpen = true; searched = {}; none = {}; boughtAuctions = {}; B._searched, B._none = searched, none
        B.Reset()
        if WS.OnAHShow then pcall(WS.OnAHShow) end
        return
    elseif event == "AUCTION_HOUSE_CLOSED" then
        ahOpen = false
        if B.scan then ScanFinish("Scan crates stopped: the AH was closed (what was scanned is kept).") end
        B.Reset(); return
    elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
        if B.scan then if B.scan.state == "queued" then ScanSend() end return end
        if B.state == "queued" and cur then SendSearch() end
        return
    end
    if B.scan then
        local s = B.scan
        if s.state == "sent" then
            if (event == "COMMODITY_SEARCH_RESULTS_UPDATED") and tonumber(a1) == s.id then
                local hasC = F("HasFullCommoditySearchResults"); local full = true
                if hasC then local ok, r = pcall(hasC, s.id); full = (not ok) or r ~= false end
                if full then ScanGot("commodity") end
            elseif event == "ITEM_SEARCH_RESULTS_UPDATED" and KeyID(a1) == s.id then
                local hasI = F("HasFullItemSearchResults"); local full = true
                if hasI then local ok, r = pcall(hasI, s.key); full = (not ok) or r ~= false end
                if full then ScanGot("item") end
            end
        end
        return
    end
    if not cur then return end
    if event == "COMMODITY_SEARCH_RESULTS_UPDATED" or event == "COMMODITY_SEARCH_RESULTS_ADDED" then
        if B.state == "searching" and tonumber(a1) == cur.id then OnResults("commodity") end
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" or event == "ITEM_SEARCH_RESULTS_ADDED" then
        if B.state == "searching" and (KeyID(a1) == cur.id or a1 == nil) then OnResults("item") end
    elseif event == "COMMODITY_PRICE_UPDATED" then
        if B.state ~= "quoting" then return end
        local unit, total = tonumber(a1), tonumber(a2)
        local cap, why, crate = WS.EffectiveCap(cur.id)
        local left = WS.BudgetLeft()
        local reason
        if not total or not unit then reason = "the server sent no price"
        elseif not cap or total > cur.qty * cap then
            reason = string.format("quote %s (%s each) is above your max of %s each%s", Money(total), Money(unit), Money(cap or 0),
                why == "favor" and (" (" .. CrateName(crate) .. " would go over your per-Favor limit)") or "")
        elseif left and total > left then reason = string.format("quote %s is more than the budget left (%s)", Money(total), Money(left)) end
        if reason then
            CancelQuote()
            searched[cur.id] = nil
            cur = nil
            return Set("idle", "|cffff4040Cancelled: " .. reason .. ".|r Prices moved; click Search to look again.")
        end
        cur.quoteTotal = total
        Set("confirm", string.format("|cff40ff40Quote:|r %dx %s for %s (%s each). Next click CONFIRMS this purchase.", cur.qty, Name(cur.id), Money(total), Money(unit)))
    elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
        if B.state == "quoting" then searched[cur.id] = nil; cur = nil; Set("idle", "|cffffd100Price no longer available (sold out). Click Search to look again.|r") end
    elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
        if B.state == "buying" and cur.isCommodity then
            Record(cur.id, cur.qty, cur.quoteTotal or cur.planTotal or 0)
            local id = cur.id; cur = nil
            Set("idle", WS.Remaining(id) > 0 and ("Bought. " .. WS.Remaining(id) .. " more " .. Name(id) .. " needed: click to continue.") or "Bought. Click Search for the next item.")
        end
    elseif event == "COMMODITY_PURCHASE_FAILED" then
        if B.state == "buying" or B.state == "quoting" then searched[cur.id] = nil; cur = nil; Set("idle", "|cffff4040Purchase failed (someone else bought it, or not enough gold). Click Search to look again.|r") end
    elseif event == "AUCTION_HOUSE_PURCHASE_COMPLETED" then
        if B.state == "buying" and not cur.isCommodity and (a1 == nil or tonumber(a1) == tonumber(cur.auctionID)) then
            boughtAuctions[cur.auctionID] = true
            Record(cur.id, cur.qty, cur.buyout)
            cur = nil
            Set("idle", "Bought. Click to continue (uses the results on screen).")
        end
    elseif event == "AUCTION_HOUSE_SHOW_ERROR" then
        if B.state == "buying" or B.state == "quoting" then
            if cur.auctionID then boughtAuctions[cur.auctionID] = true end
            searched[cur.id] = nil
            cur = nil
            Set("idle", "|cffff4040The AH refused the purchase (error " .. tostring(a1) .. "). Click Search to look again.|r")
        end
    end
end
ev:SetScript("OnEvent", function(_, event, ...) B.OnEvent(event, ...) end)
