-- WaylaidShopper: Core (saved data, owned counts, crate ranking, shopping list, caps / budget, slash commands).
-- Read-only except the AH "Buy Next" walk in Buyer.lua, which only acts on your clicks.
local ADDON, WS = ...
WS = WS or {}
_G.WaylaidShopper = WS
WS.version = "0.2.5"
WS.CALLER = "WaylaidShopper"
WS.LIST_NAME = "Waylaid Shopper"

local function Print(msg) DEFAULT_CHAT_FRAME:AddMessage("|cff33ccffWaylaid Shopper:|r " .. tostring(msg)) end
WS.Print = Print

local DEFAULT_SETTINGS = {
    capPct = 25,          -- default per-item cap = scanned price + 25%
    staleDays = 3,
    useOwned = true,      -- subtract materials you already have
    useAlts = true,       -- also count your alts' items (AltStash, when installed)
    myLevel = false,      -- only crates your level can fill
    ownedCrates = false,  -- only crates you are holding
    tier = "all",
    category = "all",
    sort = "favor",       -- "favor" (cost per Merchant's Favor, default) or "cost"
    maxPer = 0,           -- max cost per Merchant's Favor in copper (0 = no limit)
    maxRepeat = 5,        -- Best value / Fill budget: max fills of the same crate (when "Held crates" is off)
    buyCrates = true,     -- add the empty Waylaid Crates you do not hold to the list (and count their price)
    hideOver = false,     -- hide crates over the per-Favor limit (otherwise they are shown in red)
}

local function CopyDefaults(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then dst[k] = type(dst[k]) == "table" and dst[k] or {}; CopyDefaults(dst[k], v)
        elseif dst[k] == nil then dst[k] = v end
    end
end

function WS.InitDB()
    WaylaidShopperDB = type(WaylaidShopperDB) == "table" and WaylaidShopperDB or {}
    local db = WaylaidShopperDB
    db.settings = type(db.settings) == "table" and db.settings or {}
    CopyDefaults(db.settings, DEFAULT_SETTINGS)
    db.sel = type(db.sel) == "table" and db.sel or {}       -- crateID -> count selected
    db.caps = type(db.caps) == "table" and db.caps or {}    -- itemID -> copper (user-set max unit price)
    db.budget = tonumber(db.budget) or 0                     -- copper, 0 = no budget
    db.avail = type(db.avail) == "table" and db.avail or {}  -- itemID -> { t = time(), qty, rows = {{unit, qty}}, full } AH listings seen
    db.run = type(db.run) == "table" and db.run or {}
    db.run.spent = tonumber(db.run.spent) or 0
    db.run.bought = type(db.run.bought) == "table" and db.run.bought or {}
    db.run.skip = type(db.run.skip) == "table" and db.run.skip or {}
    db.run.log = type(db.run.log) == "table" and db.run.log or {}
    if (tonumber(db.settings.schema) or 1) < 2 then
        db.settings.sort = "favor"      -- 0.2.0: best value (cost per Favor) is the default order
        db.settings.schema = 2
    end
    if (tonumber(db.settings.schema) or 1) < 3 then
        db.settings.buyCrates = true    -- 0.2.4: missing empty crates go on the list (also for saved settings from before 0.2.3)
        db.settings.schema = 3
    end
    if db.settings.buyCrates == nil then db.settings.buyCrates = true end
    WS.db = db
    WS.byId = {}
    WS.matName = {}
    for _, c in ipairs(WS.Crates or {}) do
        WS.byId[c.id] = c
        for _, b in ipairs(c.bundles) do WS.matName[b.item] = b.name end
    end
end

------------------------------------------------------------------------
-- counts
------------------------------------------------------------------------
local function ItemCount(id)
    local f = (C_Item and C_Item.GetItemCount) or GetItemCount
    if type(f) ~= "function" then return 0 end
    local ok, n = pcall(f, id, true)          -- true = include bank (cached)
    return (ok and tonumber(n)) or 0
end
WS.ItemCount = ItemCount

-- what you have: this character's bags + bank, or (useAlts) AltStash's total over all characters when that is higher
function WS.Owned(id)
    local n = ItemCount(id)
    if WS.db.settings.useAlts then
        local A = _G.AltStash and _G.AltStash.API
        if type(A) == "table" and type(A.GetTotalCount) == "function" then
            local ok, t = pcall(A.GetTotalCount, id, "always")
            if ok and type(t) == "number" and t > n then n = t end
        end
    end
    return n
end

function WS.ItemName(id)
    local n
    if C_Item and type(C_Item.GetItemNameByID) == "function" then local ok, r = pcall(C_Item.GetItemNameByID, id); if ok then n = r end end
    if not n and type(GetItemInfo) == "function" then local ok, r = pcall(GetItemInfo, id); if ok then n = r end end
    return n or WS.matName[id] or (WS.byId[id] and WS.byId[id].name) or ("item " .. tostring(id))
end

local function PlayerLevel()
    local ok, l = pcall(UnitLevel, "player")
    return (ok and tonumber(l)) or 60
end

------------------------------------------------------------------------
-- pricing a crate
------------------------------------------------------------------------
------------------------------------------------------------------------
-- AH availability (how many are listed). Auctionator stores prices only, so the add-on records what its own searches
-- saw (Buy Next and Scan crates), with the time. Fresh for AVAIL_FRESH, used (marked old) up to AVAIL_MAX.
------------------------------------------------------------------------
WS.AVAIL_FRESH = 1800
WS.AVAIL_MAX = 6 * 3600
local function WallNow() return (time and time()) or 0 end
-- rec, age (seconds), stale  (nil when nothing recorded or older than AVAIL_MAX)
function WS.Avail(id)
    local r = WS.db and WS.db.avail and WS.db.avail[id]
    if type(r) ~= "table" or not r.t then return nil end
    local age = math.max(0, WallNow() - r.t)
    if age > WS.AVAIL_MAX then return nil end
    return r, age, age > WS.AVAIL_FRESH
end
function WS.RecordAvail(id, rows, full)
    if not (WS.db and WS.db.avail) then return end
    local keep, qty = {}, 0
    for i, r in ipairs(rows or {}) do
        qty = qty + (r.qty or 0)
        if i <= 40 then keep[#keep + 1] = { unit = r.unit, qty = r.qty } end
    end
    WS.db.avail[id] = { t = WallNow(), qty = qty, rows = keep, full = (full ~= false) and #(rows or {}) <= 40 }
end
function WS.AgeText(sec)
    sec = math.floor(sec or 0)
    if sec < 90 then return "just now" end
    if sec < 5400 then return math.floor(sec / 60 + 0.5) .. " min ago" end
    return string.format("%.1f h ago", sec / 3600)
end

-- cost of buying qty more units of an item when `already` units are already planned:
-- walks the AH listings (cheapest first) seen by the Buyer or Scan crates, so the 2nd, 3rd... unit pays the next,
-- dearer listing; otherwise Auctionator's single scan price, flat.
-- Returns cost, "ah" | "scan", beyondDepth. When the listings are complete (not cut off) and fewer than needed are
-- left, returns nil, "ah", true, "soldout" (that many cannot be bought right now).
function WS.DepthCost(id, already, qty, unit)
    local rows = WS.Buyer and WS.Buyer.Depth and WS.Buyer.Depth(id)
    local full = false
    local rec = WS.Avail(id)
    if rec then
        if not rows then rows = rec.rows end
        full = rec.full and true or false
    end
    if not rows or #rows == 0 then
        if rec and full then return nil, "ah", true, "soldout" end     -- searched: none listed
        if not unit then return nil end
        return unit * qty, "scan", false
    end
    local skip, need, cost, last = already or 0, qty, 0, nil
    for _, r in ipairs(rows) do
        local avail = r.qty
        if skip > 0 then local s = math.min(skip, avail); skip = skip - s; avail = avail - s end
        if avail > 0 and need > 0 then
            local take = math.min(avail, need)
            cost = cost + take * r.unit
            need = need - take
        end
        last = r.unit
        if need <= 0 then break end
    end
    local beyond = need > 0
    if beyond and full then return nil, "ah", true, "soldout" end
    if beyond then cost = cost + need * math.max(last or 0, unit or 0) end   -- more than is listed: assume the dearest seen
    return cost, "ah", beyond
end

-- how many of an item can be bought right now per the recorded listings (nil = unknown)
function WS.AvailQty(id)
    local rows = WS.Buyer and WS.Buyer.Depth and WS.Buyer.Depth(id)
    local rec, age, stale = WS.Avail(id)
    if rows then local n = 0; for _, r in ipairs(rows) do n = n + r.qty end; return n, 0, false end
    if rec then return rec.qty, age, stale end
    return nil
end

-- cost of one bundle given a pool of owned items (pool may be nil = ignore owned) and, optionally, the units of each
-- item already planned (bought) so rising AH prices are counted.
-- returns { item, count, buy, use, unit, cost, missing, stale, src }
function WS.BundleCost(b, pool, bought)
    local have = (pool and pool[b.item]) or 0
    local use = math.min(have, b.count)
    local buy = b.count - use
    local unit, age, stale = WS.Prices.Get(b.item)
    local r = { item = b.item, name = b.name, count = b.count, use = use, buy = buy, unit = unit, age = age, stale = stale }
    if buy == 0 then r.cost = 0
    elseif bought then
        local c, src, beyond, why = WS.DepthCost(b.item, bought[b.item] or 0, buy, unit)
        if c then r.cost, r.src, r.beyond = c, src, beyond else r.missing = true; r.soldOut = (why == "soldout") end
    elseif unit then r.cost = unit * buy; r.src = "scan"
    else r.missing = true end
    return r
end

-- cheapest bundle for a crate. nil + "noprice" when no bundle can be priced.
function WS.BestBundle(crate, pool, bought)
    local best, nMissing = nil, 0
    for _, b in ipairs(crate.bundles) do
        local r = WS.BundleCost(b, pool, bought)
        if r.missing then nMissing = nMissing + 1
        elseif not best or r.cost < best.cost or (r.cost == best.cost and r.buy < best.buy) then best = r end
    end
    if best then best.nMissing = nMissing end
    return best
end

local function Pool()
    if not WS.db.settings.useOwned then return nil end
    local pool, cache = {}, {}
    setmetatable(pool, { __index = function(t, id) local n = WS.Owned(id) + ((WS._carry and not WS.byId[id] and WS._carry[id]) or 0); rawset(t, id, n); return n end })
    return pool
end

-- empty crates you hold (always counted, whatever "Use my mats" says)
-- empty crates you can turn in: THIS character's bags + bank only. Crates on alts are not counted (they would have
-- to be mailed first); the list says how many your alts hold.
function WS.HeldCrates(id) return ItemCount(id) end
function WS.AltCrates(id)
    local A = _G.AltStash and _G.AltStash.API
    if type(A) ~= "table" or type(A.GetTotalCount) ~= "function" then return 0 end
    local ok, n = pcall(A.GetTotalCount, id, "always")
    if not ok or type(n) ~= "number" then return 0 end
    return math.max(0, n - ItemCount(id))
end
function WS.CrateLabel(c)
    if not c then return "Waylaid Crate" end
    return string.format("Waylaid Crate (%s %s)", c.tier or "?", c.category or "?")
end
local function CratePool()
    return setmetatable({}, { __index = function(t, id) local n = WS.HeldCrates(id) + ((WS._carry and WS._carry[id]) or 0); rawset(t, id, n); return n end })
end
WS._CratePool = CratePool

-- one more fill of a crate: its cheapest bundle, plus the empty crate itself when you hold none left and
-- "Buy missing crates" is on. Returns nil when no bundle has a price, else
-- { b = bundle, crateBuy = 0|1, crateCost, crateNoPrice, cost = bundle + crate, live }
function WS.FillCost(crate, pool, cpool, bought)
    local b = WS.BestBundle(crate, pool, bought)
    if not b then return nil end
    local f = { b = b, crateBuy = 0, crateCost = 0, cost = b.cost, live = b.src == "ah" }
    if WS.db.settings.buyCrates and cpool and (cpool[crate.id] or 0) <= 0 then
        f.crateBuy = 1
        local unit = WS.Prices.Get(crate.id)
        local c, src, _, why = WS.DepthCost(crate.id, (bought and bought[crate.id]) or 0, 1, unit)
        if c then f.crateCost = c; f.cost = b.cost + c; if src == "ah" then f.live = true end
        elseif why == "soldout" then f.crateSoldOut = true
        else f.crateNoPrice = true end
    end
    return f
end

-- use up what a fill takes: owned materials, a held crate, and the planned purchases (for rising AH prices)
local function Consume(f, crate, pool, cpool, bought)
    local b = f.b
    if pool and b.use > 0 then pool[b.item] = pool[b.item] - b.use end
    if bought then bought[b.item] = (bought[b.item] or 0) + b.buy end
    if f.crateBuy == 1 then
        if bought then bought[crate.id] = (bought[crate.id] or 0) + 1 end
    elseif cpool and (cpool[crate.id] or 0) > 0 then
        cpool[crate.id] = cpool[crate.id] - 1
    end
end

function WS.PassesFilter(c)
    local s = WS.db.settings
    if s.tier ~= "all" and c.tier ~= s.tier then return false end
    if s.category ~= "all" and c.category ~= s.category then return false end
    if s.myLevel and PlayerLevel() < c.level then return false end
    if s.ownedCrates and WS.Owned(c.id) <= 0 then return false end
    return true
end

-- per-Favor limit (copper per Merchant's Favor); nil = off
function WS.MaxPer()
    local m = tonumber(WS.db.settings.maxPer) or 0
    return m > 0 and m or nil
end
function WS.OverLimit(perFavor)
    local m = WS.MaxPer()
    return (m and perFavor and perFavor > m) and true or false
end

-- ranked list of { crate, best, favor, perFavor, over, held, sel }
function WS.Rank(ignoreFilter)
    local out = {}
    local pool, cpool = Pool(), CratePool()
    for _, c in ipairs(WS.Crates or {}) do
        if ignoreFilter or WS.PassesFilter(c) then
            local f = WS.FillCost(c, pool, cpool, nil)
            local best = f and f.b
            local e = { crate = c, best = best, fill = f, favor = c.favor, held = WS.Owned(c.id), sel = WS.db.sel[c.id] or 0 }
            if f then
                e.cost = f.cost
                e.crateCost, e.crateBuy = f.crateCost, f.crateBuy
                e.crateSoldOut = f.crateSoldOut
                -- you hold none (left) and the empty crate has no AH price, or none is listed on the AH
                e.unavailable = (f.crateNoPrice or f.crateSoldOut) and true or false
                e.perFavor = f.cost / math.max(1, c.favor)
                e.over = WS.OverLimit(e.perFavor)
            end
            if ignoreFilter or not (e.over and WS.db.settings.hideOver) then out[#out + 1] = e end
        end
    end
    local byFavor = WS.db.settings.sort == "favor"
    table.sort(out, function(a, b)
        if (a.best ~= nil) ~= (b.best ~= nil) then return a.best ~= nil end
        if not a.best then return a.crate.name < b.crate.name end
        if a.unavailable ~= b.unavailable then return not a.unavailable end
        local ka, kb = a.cost, b.cost
        if byFavor then ka, kb = a.perFavor, b.perFavor end
        if ka ~= kb then return ka < kb end
        return a.crate.name < b.crate.name
    end)
    return out
end

------------------------------------------------------------------------
-- selection
------------------------------------------------------------------------
function WS.SetSel(id, n)
    n = math.max(0, math.min(99, math.floor(tonumber(n) or 0)))
    WS.db.sel[id] = n > 0 and n or nil
end
function WS.ClearSel() WS.db.sel = {} end
function WS.NumSelected()
    local n = 0
    for _, v in pairs(WS.db.sel) do n = n + v end
    return n
end

-- select the N cheapest crates that pass the filters (one of each; held count when "owned crates" is on)
function WS.SelectCheapest(n)
    n = math.floor(tonumber(n) or 0)
    if n <= 0 then return 0 end
    WS.db.lastPick = { mode = "cheapest", n = n }
    WS.ClearSel()
    local k = 0
    for _, e in ipairs(WS.Rank()) do
        if k >= n then break end
        if e.best and not e.over and not e.unavailable then
            local cnt = WS.db.settings.ownedCrates and math.max(1, e.held) or 1
            WS.SetSel(e.crate.id, cnt); k = k + 1
        end
    end
    return k
end

-- like SelectCheapest but always ordered by cost per Favor (whatever the sort setting is)
local function ByValue(ignoreFilter)
    local saved = WS.db.settings.sort
    WS.db.settings.sort = "favor"
    local r = WS.Rank(ignoreFilter)
    WS.db.settings.sort = saved
    return r
end

-- Greedy best value WITH repeats: each step adds the single fill (any crate, again if allowed) with the lowest
-- marginal cost per Favor. The marginal cost counts materials you have that earlier fills already used, AH listings
-- earlier fills already bought (rising prices, when the Buyer has live listings), and lets the bundle switch (e.g. Copper
-- Ore -> Tin Ore once the cheap copper is gone). Repeats per crate: what you hold with "Held crates", else maxRepeat.
-- Stops at maxFills / when the budget would be passed / when nothing is within the per-Favor limit.
-- returns counts {crateID = n}, fills, cost, favor, usedLiveDepth
function WS.Greedy(maxFills, budget)
    local s = WS.db.settings
    local pool, cpool, bought = Pool(), CratePool(), {}
    local cands, counts = {}, {}
    local maxRep = math.max(1, math.floor(tonumber(s.maxRepeat) or 5))
    for _, c in ipairs(WS.Crates or {}) do
        if WS.PassesFilter(c) then
            local cap = s.ownedCrates and WS.Owned(c.id) or maxRep
            if cap > 0 then cands[#cands + 1] = { crate = c, cap = cap } end
        end
    end
    local k, spent, favor, live = 0, 0, 0, false
    while (not maxFills or k < maxFills) and k < 999 do
        local pick, pb, pper
        for _, e in ipairs(cands) do
            if (counts[e.crate.id] or 0) < e.cap then
                local f = WS.FillCost(e.crate, pool, cpool, bought)
                if f and not f.crateNoPrice and not f.crateSoldOut then     -- an empty crate you would have to buy but has no price / none listed: not picked
                    local per = f.cost / math.max(1, e.crate.favor)
                    if not WS.OverLimit(per) and (not budget or spent + f.cost <= budget) then
                        if not pick or per < pper or (per == pper and f.cost < pb.cost) then pick, pb, pper = e, f, per end
                    end
                end
            end
        end
        if not pick then break end
        Consume(pb, pick.crate, pool, cpool, bought)
        counts[pick.crate.id] = (counts[pick.crate.id] or 0) + 1
        k, spent, favor = k + 1, spent + pb.cost, favor + pick.crate.favor
        if pb.live then live = true end
    end
    return counts, k, spent, favor, live
end

local function ApplyCounts(counts)
    WS.ClearSel()
    for id, n in pairs(counts) do WS.SetSel(id, n) end
end

-- the N best-value fills (repeats allowed). returns fills, cost, favor, live
function WS.SelectBestValue(n)
    n = math.floor(tonumber(n) or 0)
    if n <= 0 then return 0 end
    local counts, k, cost, favor, live = WS.Greedy(n, nil)
    if k == 0 then return 0, 0, 0, false, WS.WhyNothing(nil) end
    WS.db.lastPick = { mode = "best", n = n }
    ApplyCounts(counts)
    return k, cost, favor, live
end

-- best-value fills until the budget left would be passed (repeats allowed).
-- returns fills, cost, favor, live. 0 fills or no budget: nil + reason, and the selection is left as it was.
function WS.SelectFillBudget()
    local left = WS.BudgetLeft()
    if not left then return nil, "set a budget first: type it in the Budget box (e.g. 10g) or /wl fill 10g." end
    local counts, k, cost, favor, live = WS.Greedy(nil, left)
    if k == 0 then return nil, WS.WhyNothing(left) end
    WS.db.lastPick = { mode = "fill" }
    ApplyCounts(counts)
    return k, cost, favor, live
end

-- why Greedy picked nothing: a sentence naming the crates left out and why. budget = copper left or nil.
function WS.WhyNothing(budget)
    local P, s = WS.Prices, WS.db.settings
    local nAll, nFilt, noMat, noCrate, over, fits, sold = 0, 0, 0, 0, 0, 0, 0
    local cheapest, cheapName
    local pool, cpool = Pool(), CratePool()
    local anyPrice = false
    for _, c in ipairs(WS.Crates or {}) do
        nAll = nAll + 1
        for _, b in ipairs(c.bundles) do if P.Get(b.item) then anyPrice = true end end
        if not WS.PassesFilter(c) then nFilt = nFilt + 1
        else
            local f = WS.FillCost(c, pool, cpool, {})
            if not f then noMat = noMat + 1
            elseif f.crateSoldOut then sold = sold + 1
            elseif f.crateNoPrice then noCrate = noCrate + 1
            elseif WS.OverLimit(f.cost / math.max(1, c.favor)) then over = over + 1
            else
                fits = fits + 1
                if not cheapest or f.cost < cheapest then cheapest, cheapName = f.cost, c.name end
            end
        end
    end
    if not anyPrice then return "nothing selected: no Auctionator prices for crate materials. Run an Auctionator scan at the AH first." end
    local parts = {}
    if budget and cheapest and cheapest > budget then
        local spent = WS.db.run.spent or 0
        parts[#parts + 1] = string.format("nothing fits %s%s: the cheapest fill (%s) costs %s", P.Format(budget),
            spent > 0 and string.format(" (budget %s minus %s already spent this run; Reset run to start over)", P.Format(WS.db.budget or 0), P.Format(spent)) or "",
            tostring(cheapName):gsub("^Waylaid Crate: ", ""), P.Format(cheapest))
    elseif budget and budget <= 0 then
        parts[#parts + 1] = string.format("no budget left: %s already spent this run (Reset run, or raise the budget)", P.Format(WS.db.run.spent or 0))
    else
        parts[#parts + 1] = "nothing selected"
    end
    if nFilt > 0 then
        local why = {}
        if s.tier ~= "all" then why[#why + 1] = "Tier " .. s.tier end
        if s.category ~= "all" then why[#why + 1] = "Type " .. s.category end
        if s.myLevel then why[#why + 1] = "My level" end
        if s.ownedCrates then why[#why + 1] = "Held crates (only crates you hold)" end
        parts[#parts + 1] = string.format("%d of %d crates hidden by filters (%s)", nFilt, nAll, table.concat(why, ", "))
    end
    if noCrate > 0 then parts[#parts + 1] = string.format("%d crate(s) need an empty crate you do not hold and Auctionator has no price for it (scan / search the crates, or untick Buy crates if you get them elsewhere)", noCrate) end
    if sold > 0 then parts[#parts + 1] = string.format("%d crate(s) need an empty crate you do not hold and none is listed on the AH (Scan crates again later)", sold) end
    if noMat > 0 then parts[#parts + 1] = string.format("%d crate(s) have no material prices (run an Auctionator scan)", noMat) end
    if over > 0 then parts[#parts + 1] = string.format("%d crate(s) cost more than your Max per Favor %s", over, P.Format(WS.MaxPer() or 0)) end
    if fits == 0 and nFilt == 0 and noCrate == 0 and noMat == 0 and over == 0 and sold == 0 then parts[#parts + 1] = "no crates to choose from" end
    return table.concat(parts, "; ") .. "."
end

function WS.SelectionText(k, cost, favor, live)
    local P = WS.Prices
    local nCr = 0
    for _ in pairs(WS.db.sel) do nCr = nCr + 1 end
    return string.format("selected %d fill(s) of %d crate type(s): about %s for %d Favor (%s per Favor). %s", k, nCr, P.Format(cost or 0), favor or 0,
        (favor or 0) > 0 and P.Format(math.floor(cost / favor + 0.5)) or "?",
        live and "Prices follow the AH listings you searched (dearer listings for repeat fills)."
             or "Prices are Auctionator's scan price, flat; search the items at the AH (Search) to price repeat fills from the real listings.")
end

-- select every crate you hold, count = how many you hold
function WS.SelectOwned()
    WS.ClearSel()
    local k = 0
    for _, c in ipairs(WS.Crates or {}) do
        local h = WS.Owned(c.id)
        if h > 0 then WS.SetSel(c.id, h); k = k + h end
    end
    return k
end

function WS.FindCrate(q)
    q = tostring(q or ""):lower()
    if q == "" then return nil end
    local id = tonumber(q)
    if id and WS.byId[id] then return WS.byId[id] end
    for _, c in ipairs(WS.Crates) do if c.name:lower() == q or c.name:lower() == ("waylaid crate: " .. q) then return c end end
    for _, c in ipairs(WS.Crates) do if c.name:lower():find(q, 1, true) then return c end end
end

------------------------------------------------------------------------
-- shopping list
------------------------------------------------------------------------
-- Build from the selection: each selected crate (cheapest first) takes its cheapest bundle, using up owned materials
-- as it goes, so two crates never count the same owned stack twice. Starts a fresh buying run.
-- opts.carry = { itemID = n } already bought this run but maybe still in the mailbox (Replan): counted as yours.
-- opts.keepSpent = keep this run's spent gold (Replan).
function WS.BuildList(opts)
    opts = opts or {}
    local pool, cpool, bought = Pool(), CratePool(), {}
    local carry = opts.carry or {}
    if not pool and next(carry) then pool = setmetatable({}, { __index = function() return 0 end }) end
    for id, n in pairs(carry) do
        if n > 0 then
            if WS.byId[id] then cpool[id] = (cpool[id] or 0) + n
            elseif pool then pool[id] = (pool[id] or 0) + n end
        end
    end
    local soldOut, soldOrder = {}, {}
    local items, picks, noPrice, overLimit, crateNoPrice = {}, {}, {}, {}, {}
    local order, crateOrder = {}, {}
    local crateHeld, crateBuyN = 0, 0
    local function Add(id, n, name, isCrate)
        local it = items[id]
        if not it then
            it = { id = id, need = 0, name = name, isCrate = isCrate or nil, label = isCrate and WS.CrateLabel(WS.byId[id]) or nil }
            items[id] = it
            if isCrate then crateOrder[#crateOrder + 1] = id else order[#order + 1] = id end
        end
        it.need = it.need + n
    end
    -- the empty crate for one fill: a held one (this character) is used up, else one goes on the list (priced or not)
    local function AddCrate(c)
        if not WS.db.settings.buyCrates then return end
        if (cpool[c.id] or 0) > 0 then cpool[c.id] = cpool[c.id] - 1; crateHeld = crateHeld + 1 return end
        Add(c.id, 1, c.name, true)
        crateBuyN = crateBuyN + 1
        if not WS.Prices.Get(c.id) and not (WS.Buyer and WS.Buyer.Depth and WS.Buyer.Depth(c.id)) then
            local dup = false
            for _, n in ipairs(crateNoPrice) do if n == c.name then dup = true end end
            if not dup then crateNoPrice[#crateNoPrice + 1] = c.name end
        end
    end
    for _, e in ipairs(WS.Rank(true)) do
        local cnt = WS.db.sel[e.crate.id] or 0
        for i = 1, cnt do
            local f = WS.FillCost(e.crate, pool, cpool, bought)
            if not f then
                -- no material price: still list the empty crate you need, the materials cannot be priced
                noPrice[#noPrice + 1] = e.crate.name
                AddCrate(e.crate)
            elseif f.crateSoldOut then
                -- no more of this empty crate on the AH (per the last search / Scan crates): that fill is left out
                if not soldOut[e.crate.id] then soldOut[e.crate.id] = 0; soldOrder[#soldOrder + 1] = e.crate.id end
                soldOut[e.crate.id] = soldOut[e.crate.id] + 1
            elseif WS.OverLimit(f.cost / math.max(1, e.crate.favor)) then
                overLimit[#overLimit + 1] = e.crate.name
            else
                local best = f.b
                if pool and best.use > 0 then pool[best.item] = pool[best.item] - best.use end
                bought[best.item] = (bought[best.item] or 0) + best.buy
                if f.crateBuy == 1 then bought[e.crate.id] = (bought[e.crate.id] or 0) + 1 end
                AddCrate(e.crate)
                picks[#picks + 1] = { crate = e.crate.id, item = best.item, count = best.count, buy = best.buy, use = best.use, favor = e.crate.favor,
                    cost = f.cost, matCost = best.cost, crateBuy = f.crateBuy, crateCost = f.crateCost }
                if best.buy > 0 then Add(best.item, best.buy, best.name) end
            end
        end
    end
    -- empty crates first (no point buying materials for a crate you cannot get), then the materials
    for i = #crateOrder, 1, -1 do table.insert(order, 1, crateOrder[i]) end
    local alts = 0
    for _, id in ipairs(crateOrder) do alts = alts + math.min(WS.AltCrates(id), items[id].need) end
    local base = {}
    for id in pairs(items) do base[id] = ItemCount(id) end           -- what you had when the list was built (for Replan)
    local soldList = {}
    for _, id in ipairs(soldOrder) do
        local a = WS.AvailQty(id)
        soldList[#soldList + 1] = { id = id, n = soldOut[id], listed = a or 0 }
    end
    WS.db.list = { items = items, order = order, picks = picks, noPrice = noPrice, overLimit = overLimit, crateNoPrice = crateNoPrice,
        crateHeld = crateHeld, crateBuy = crateBuyN, crateOnAlts = alts, soldOut = soldList, base = base, built = time and time() or 0 }
    local spent, log = WS.db.run.spent, WS.db.run.log
    WS.ResetRun(true)
    if opts.keepSpent then WS.db.run.spent, WS.db.run.log = spent or 0, log or {} end
    return WS.db.list
end

-- what this run bought that is not in your bags/bank yet (AH purchases wait in the mailbox)
function WS.InMail()
    local L, run = WS.db.list, WS.db.run
    local carry = {}
    if not L then return carry end
    for id, n in pairs(run.bought or {}) do
        local arrived = math.max(0, ItemCount(id) - ((L.base and L.base[id]) or 0))
        local m = math.max(0, n - arrived)
        if m > 0 then carry[id] = m end
    end
    return carry
end

-- rebuild the list with today's AH availability: the crates that sold out drop out and, when the selection came from
-- Best value / Fill budget / Cheapest, that pick runs again so the freed money goes to the next best fills. What you
-- already bought this run (bags or mail) counts as yours; spent gold is kept against the budget.
function WS.Replan()
    local carry = WS.InMail()
    local lp = WS.db.lastPick
    local msg
    -- the purchases so far are yours: plan the rest only
    local function WithCarry(fn)
        WS._carry = carry
        local ok, a, b, c, d, e = pcall(fn)
        WS._carry = nil
        if not ok then error(a) end
        return a, b, c, d, e
    end
    local L = WS.db.list
    if lp and lp.mode == "fill" then
        local k, why = WithCarry(function() return WS.SelectFillBudget() end)
        msg = k and string.format("replanned Fill budget: %d fill(s).", k) or ("replan: " .. tostring(why))
    elseif lp and lp.mode == "best" then
        local k = WithCarry(function() return WS.SelectBestValue(lp.n) end)
        msg = string.format("replanned Best value: %d fill(s).", k or 0)
    elseif lp and lp.mode == "cheapest" then
        local k = WithCarry(function() return WS.SelectCheapest(lp.n) end)
        msg = string.format("replanned Cheapest: %d crate(s).", k or 0)
    else
        -- hand-picked selection: trim the crates that cannot be bought
        if L and L.soldOut then
            for _, s in ipairs(L.soldOut) do WS.SetSel(s.id, (WS.db.sel[s.id] or 0) - s.n) end
        end
        msg = "replanned: crates that are not listed were taken out of the selection."
    end
    local NL = WS.BuildList({ carry = carry, keepSpent = true })
    if WS.Buyer and WS.Buyer.ClearShort then WS.Buyer.ClearShort() end
    return NL, msg
end

function WS.ReportSoldOut(L)
    for _, s in ipairs((L and L.soldOut) or {}) do
        Print(string.format("|cffffd100%s: only %d listed on the AH; %d fill(s) left out.|r", WS.CrateLabel(WS.byId[s.id]), s.listed or 0, s.n))
    end
end
-- crates on the list whose AH quantity is unknown or old
function WS.CrateAvailNotes(L)
    local unknown, old = {}, {}
    for _, id in ipairs((L and L.order) or {}) do
        local it = L.items[id]
        if it and it.isCrate then
            local q, age, stale = WS.AvailQty(id)
            local nm = (WS.byId[id] and (WS.byId[id].tier .. " " .. WS.byId[id].category)) or tostring(id)
            if not q then unknown[#unknown + 1] = nm elseif stale then old[#old + 1] = nm .. " (" .. WS.AgeText(age) .. ")" end
        end
    end
    return unknown, old
end
function WS.ReportAvailAge(L)
    local unknown, old = WS.CrateAvailNotes(L)
    if #unknown > 0 then Print("AH quantity unknown for: " .. table.concat(unknown, ", ") .. ". Click Scan crates at the AH (/wl scancrates) to see how many are listed.") end
    if #old > 0 then Print("AH quantity is old for: " .. table.concat(old, ", ") .. ". Scan crates again before buying.") end
end

function WS.ResetRun(quiet)
    WS.db.run = { spent = 0, bought = {}, skip = {}, log = {} }
    if WS.Buyer and WS.Buyer.Reset then WS.Buyer.Reset() end
    if not quiet then Print("buying run reset (spent and bought counts cleared).") end
end

function WS.Remaining(id)
    local it = WS.db.list and WS.db.list.items[id]
    if not it then return 0 end
    return math.max(0, it.need - (WS.db.run.bought[id] or 0))
end

-- default cap = scanned price + capPct%; a user cap always wins. nil = no cap known (Buy Next refuses).
function WS.Cap(id)
    local u = WS.db.caps[id]
    if u then return u, true end
    local p = WS.Prices.Get(id)
    if p then return math.floor(p * (1 + (tonumber(WS.db.settings.capPct) or 25) / 100) + 0.5), false end
    return nil
end

-- highest unit price for an item that keeps every crate it fills within the per-Favor limit (nil = no limit),
-- plus the crate that sets it
function WS.PerFavorCap(id)
    local m = WS.MaxPer()
    local L = WS.db.list
    if not (m and L) then return nil end
    local best, crate
    for _, p in ipairs(L.picks or {}) do
        local favor = p.favor or (WS.byId[p.crate] and WS.byId[p.crate].favor) or 1
        local u
        if p.item == id and (p.buy or 0) > 0 then
            -- materials: what is left of the crate's Favor allowance after the empty crate's planned price
            u = math.floor(math.max(0, m * favor - (p.crateCost or 0)) / p.buy)
        elseif p.crate == id and p.crateBuy == 1 then
            -- the empty crate itself: what is left after the planned materials
            u = math.floor(math.max(0, m * favor - (p.matCost or 0)))
        end
        if u and (not best or u < best) then best, crate = u, p.crate end
    end
    return best, crate
end

-- the cap Buy Next uses: min(item cap, per-Favor cap). returns cap, why ("item" / "favor"), crateID
function WS.EffectiveCap(id)
    local c = WS.Cap(id)
    local f, crate = WS.PerFavorCap(id)
    if f and (not c or f < c) then return f, "favor", crate end
    return c, "item"
end

function WS.SetCap(id, copper)
    if copper == nil then WS.db.caps[id] = nil else WS.db.caps[id] = math.max(1, math.floor(copper)) end
end

function WS.BudgetLeft()
    local b = WS.db.budget or 0
    if b <= 0 then return nil end
    return math.max(0, b - (WS.db.run.spent or 0))
end

-- rows for the list window / text: { id, name, need, bought, left, unit, stale, total, cap, userCap }
function WS.ListRows()
    local rows, total, missing = {}, 0, 0
    local L = WS.db.list
    if not L then return rows, 0, 0 end
    for _, id in ipairs(L.order) do
        local it = L.items[id]
        local left = WS.Remaining(id)
        local unit, age, stale = WS.Prices.Get(id)
        local cap, userCap = WS.Cap(id)
        local r = { id = id, name = it.name or WS.ItemName(id), need = it.need, bought = WS.db.run.bought[id] or 0, left = left,
            unit = unit, age = age, stale = stale, cap = cap, userCap = userCap, skip = WS.db.run.skip[id], isCrate = it.isCrate,
            label = it.label or (it.isCrate and WS.CrateLabel(WS.byId[id])) or nil }
        if unit then r.total = unit * left; total = total + r.total elseif left > 0 then missing = missing + 1 end
        rows[#rows + 1] = r
    end
    return rows, total, missing
end

-- total Favor of the list's crates, estimated cost (current scan prices, what is still to buy + already spent)
function WS.ListSummary()
    local L = WS.db.list
    local favor, est = 0, 0
    if not L then return 0, 0, nil end
    for _, p in ipairs(L.picks or {}) do favor = favor + (p.favor or (WS.byId[p.crate] and WS.byId[p.crate].favor) or 0) end
    local _, left = WS.ListRows()
    est = left + (WS.db.run.spent or 0)
    return favor, est, favor > 0 and (est / favor) or nil
end

function WS.ListText()
    local rows, total, missing = WS.ListRows()
    local P = WS.Prices
    local t = { "Waylaid Shopper list (" .. date("%Y-%m-%d %H:%M") .. ")" }
    for _, r in ipairs(rows) do
        if r.left > 0 then
            t[#t + 1] = string.format("%dx %s%s - %s ea = %s%s", r.left, r.label or r.name, r.isCrate and " (empty crate)" or "", r.unit and P.Format(r.unit) or "no price",
                r.total and P.Format(r.total) or "?", r.stale and " (old price)" or "")
        end
    end
    t[#t + 1] = "Total: " .. P.Format(total) .. (missing > 0 and (" + " .. missing .. " item(s) without a price") or "")
    local fav, est, avg = WS.ListSummary()
    if fav > 0 then t[#t + 1] = string.format("Merchant's Favor: %d  (about %s per Favor)", fav, avg and P.Format(math.floor(avg + 0.5)) or "?") end
    if WS.db.list and #WS.db.list.picks > 0 then
        t[#t + 1] = ""
        t[#t + 1] = "Crates:"
        for _, p in ipairs(WS.db.list.picks) do
            local c = WS.byId[p.crate]
            t[#t + 1] = string.format("  %s <- %dx %s%s", c and c.name:gsub("^Waylaid Crate: ", "") or p.crate, p.count, WS.ItemName(p.item),
                (p.use > 0 and string.format(" (%d from your bags)", p.use) or "") .. (p.crateBuy == 1 and " + buy the empty crate" or ""))
        end
    end
    return table.concat(t, "\n")
end

function WS.Export()
    local rows = WS.ListRows()
    local terms = {}
    for _, r in ipairs(rows) do if r.left > 0 then terms[#terms + 1] = { name = r.name, count = r.left } end end
    local ok, why = WS.Prices.ExportShoppingList(WS.LIST_NAME, terms)
    if ok then Print("Auctionator shopping list \"" .. WS.LIST_NAME .. "\" written (" .. #terms .. " items).")
    else Print("could not export: " .. tostring(why) .. " Use /wl text to copy the list instead.") end
    return ok
end

------------------------------------------------------------------------
-- slash commands
------------------------------------------------------------------------
local function ItemFromArg(s)
    s = tostring(s or "")
    local id = tonumber(s:match("item:(%d+)")) or tonumber(s)
    if id then return id end
    local q = s:lower()
    if WS.db.list then
        for _, i in ipairs(WS.db.list.order) do if WS.ItemName(i):lower() == q then return i end end
        for _, i in ipairs(WS.db.list.order) do if WS.ItemName(i):lower():find(q, 1, true) then return i end end
    end
    for i, n in pairs(WS.matName) do if n:lower() == q then return i end end
    for i, n in pairs(WS.matName) do if n:lower():find(q, 1, true) then return i end end
end

local HELP = {
    "/wl - open / close the window",
    "/wl cheapest <N> - select the N cheapest crates   /wl best <N> - the N best value (cost per Favor)   /wl owned - the crates you hold",
    "/wl scancrates [all] - at the AH: search every relevant empty crate and record how many are listed (caps crate buying)   /wl replan - rebuild the list with what is listed",
    "/wl check - Bags check: is everything to fill your planned crates in your BAGS?",
    "/wl buycrates on|off - add the empty Waylaid Crates you do not hold to the list and count their price (default on)",
    "/wl maxrepeat <N> - Best value / Fill budget may fill the same crate up to N times (default 5; Held crates = what you hold)",
    "/wl fill [money] - best-value crates until the budget is used (e.g. /wl fill 10g sets the budget too)   /wl maxper <money|off> - max cost per Merchant's Favor, e.g. /wl maxper 50s",
    "/wl hideover on|off - hide crates over the per-Favor limit (else shown in red)",
    "/wl select <crate> [n]   /wl clear   /wl build - build the shopping list from the selection",
    "/wl budget <money|off> - spending goal for the run, e.g. /wl budget 50g",
    "/wl cap <item> <money|auto> - max unit price, e.g. /wl cap Copper Bar 1g20s   /wl cappct <n> - default cap % over scan",
    "/wl buy - same as the Buy Next button (at the AH)   /wl skip   /wl reset - clear spent / bought",
    "/wl export - write an Auctionator shopping list   /wl text - copyable list",
    "/wl useowned on|off   /wl alts on|off   /wl list   /wl crates",
    "Money: 1g20s5c, 50g, 120s or a plain number of gold (0.5 = 50s).",
}

local function OnOff(v, cur)
    v = tostring(v or ""):lower()
    if v == "on" or v == "1" or v == "true" then return true end
    if v == "off" or v == "0" or v == "false" then return false end
    return not cur
end

function WS.Slash(msg)
    msg = tostring(msg or "")
    local cmd, rest = msg:match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    local P = WS.Prices
    if cmd == "" then if WS.Toggle then WS.Toggle() end
    elseif cmd == "help" or cmd == "?" then for _, l in ipairs(HELP) do Print(l) end
    elseif cmd == "crates" then if WS.Show then WS.Show("crates") end
    elseif cmd == "list" then if WS.Show then WS.Show("list") end
    elseif cmd == "cheapest" then
        local n = WS.SelectCheapest(tonumber(rest) or 5)
        Print("selected the " .. n .. " cheapest crate(s). /wl build to make the list.")
        if WS.Show then WS.Show("crates") end
    elseif cmd == "best" or cmd == "bestvalue" then
        local k, cost, favor, live, why = WS.SelectBestValue(tonumber(rest) or 5)
        if k == 0 and why then Print("|cffff8040" .. why .. "|r"); WS.selNote = why
        else Print(WS.SelectionText(k, cost, favor, live) .. " /wl build to make the list."); WS.selNote = nil end
        if WS.Show then WS.Show("crates") end
    elseif cmd == "fill" then
        if rest ~= "" then
            local c = P.Parse(rest)
            if not c or c <= 0 then Print("could not read \"" .. rest .. "\" as money (try 10g or 10g 50s).") return end
            WS.db.budget = c
        end
        local k, cost, favor, live = WS.SelectFillBudget()
        if not k then Print("|cffff8040" .. cost .. "|r"); WS.selNote = cost
        else Print(WS.SelectionText(k, cost, favor, live)); WS.selNote = nil end
        if WS.Show then WS.Show("crates") end
    elseif cmd == "scancrates" or cmd == "scan" then
        if WS.Buyer then WS.Buyer.ScanCrates(rest:lower() == "all") end
    elseif cmd == "replan" then
        if not WS.db.list then Print("no shopping list to replan (Build list first).")
        else
            local L, msg = WS.Replan()
            Print(msg .. string.format(" New list: %d item(s) for %d crate(s); spent so far kept (%s).", #L.order, #L.picks, P.Format(WS.db.run.spent or 0)))
            WS.ReportSoldOut(L)
            if WS.Show then WS.Show("list") end
        end
    elseif cmd == "check" then if WS.Check then WS.Check.Run(true) end
    elseif cmd == "alert" then
        Print("the Bags check no longer runs by itself; click Bags check or type /wl check.")
    elseif cmd == "buycrates" then
        WS.db.settings.buyCrates = OnOff(rest, WS.db.settings.buyCrates)
        Print("buy missing crates: " .. (WS.db.settings.buyCrates and "on (empty crates you do not hold are added to the list and priced in)" or "off (assumes you have the crates)"))
        if WS.RefreshUI then WS.RefreshUI() end
    elseif cmd == "maxrepeat" then
        local n = tonumber(rest)
        if not n or n < 1 or n > 99 then Print("usage: /wl maxrepeat <1-99> (now " .. tostring(WS.db.settings.maxRepeat) .. ")")
        else WS.db.settings.maxRepeat = math.floor(n); Print("Best value / Fill budget: up to " .. math.floor(n) .. " fills of the same crate (with Held crates off).") end
        if WS.RefreshUI then WS.RefreshUI() end
    elseif cmd == "maxper" then
        local v = rest:lower()
        if v == "" then local m = WS.MaxPer(); Print(m and ("max cost per Favor: " .. P.Format(m)) or "no per-Favor limit.")
        elseif v == "off" or v == "0" or v == "none" then WS.db.settings.maxPer = 0; Print("per-Favor limit off.")
        else
            local c = P.Parse(rest)
            if not c or c <= 0 then Print("could not read \"" .. rest .. "\" as money (try 50s).") else WS.db.settings.maxPer = c; Print("max cost per Merchant's Favor: " .. P.Format(c) .. ".") end
        end
        if WS.RefreshUI then WS.RefreshUI() end
    elseif cmd == "hideover" then WS.db.settings.hideOver = OnOff(rest, WS.db.settings.hideOver); Print("hide crates over the per-Favor limit: " .. (WS.db.settings.hideOver and "on" or "off")); if WS.RefreshUI then WS.RefreshUI() end
    elseif cmd == "owned" then
        Print("selected " .. WS.SelectOwned() .. " crate(s) you hold.")
        if WS.Show then WS.Show("crates") end
    elseif cmd == "select" then
        local q, n = rest:match("^(.-)%s+(%d+)$")
        if not q then q, n = rest, nil end
        local c = WS.FindCrate(q)
        if not c then Print("no crate matches \"" .. rest .. "\".") else
            WS.SetSel(c.id, tonumber(n) or ((WS.db.sel[c.id] or 0) + 1))
            Print(c.name .. ": " .. (WS.db.sel[c.id] or 0) .. " selected.")
        end
        if WS.RefreshUI then WS.RefreshUI() end
    elseif cmd == "clear" then WS.ClearSel(); Print("selection cleared."); if WS.RefreshUI then WS.RefreshUI() end
    elseif cmd == "build" then
        local L = WS.BuildList()
        Print(string.format("shopping list: %d item(s) for %d crate(s).", #L.order, #L.picks))
        if not WS.db.settings.buyCrates then Print("Buy crates is off: empty crates are not on the list (/wl buycrates on).")
        else
            Print(string.format("empty crates: %d to buy (top of the list), %d held on this character.%s", L.crateBuy or 0, L.crateHeld or 0,
                (L.crateOnAlts or 0) > 0 and string.format(" Your alts hold %d of the ones to buy: mail them over instead.", L.crateOnAlts) or ""))
        end
        if #L.noPrice > 0 then Print("no price for any bundle of: " .. table.concat(L.noPrice, ", ") .. " (scan the AH with Auctionator).") end
        if #L.overLimit > 0 then Print("left out (over your per-Favor limit): " .. table.concat(L.overLimit, ", ") .. ".") end
        WS.ReportSoldOut(L)
        WS.ReportAvailAge(L)
        if #L.crateNoPrice > 0 then Print("no AH price for these empty crates (Buy Next needs a cap: /wl cap <crate> 1g): " .. table.concat(L.crateNoPrice, ", ") .. ".") end
        if WS.Show then WS.Show("list") end
    elseif cmd == "budget" then
        local v = rest:lower()
        if v == "off" or v == "none" or v == "0" then WS.db.budget = 0; Print("budget off.")
        elseif v == "" then
            local b = WS.db.budget or 0
            Print(b > 0 and ("budget " .. P.Format(b) .. ", spent " .. P.Format(WS.db.run.spent) .. ", left " .. P.Format(WS.BudgetLeft())) or "no budget set.")
        else
            local c = P.Parse(rest)
            if not c or c <= 0 then Print("could not read \"" .. rest .. "\" as money (try 50g or 12g50s).") else WS.db.budget = c; Print("budget " .. P.Format(c) .. " for this run.") end
        end
        if WS.RefreshUI then WS.RefreshUI() end
    elseif cmd == "cap" then
        local a, v = rest:match("^(.-)%s+(%S+)$")
        local id = a and ItemFromArg(a)
        if not id then Print("usage: /wl cap <item> <money|auto>") else
            if v:lower() == "auto" or v:lower() == "off" then WS.SetCap(id, nil); Print(WS.ItemName(id) .. ": cap back to scan + " .. WS.db.settings.capPct .. "%.")
            else
                local c = P.Parse(v)
                if not c or c <= 0 then Print("could not read \"" .. v .. "\" as money.") else WS.SetCap(id, c); Print(WS.ItemName(id) .. ": max " .. P.Format(c) .. " each.") end
            end
        end
        if WS.RefreshUI then WS.RefreshUI() end
    elseif cmd == "cappct" then
        local n = tonumber(rest)
        if not n or n < 0 or n > 1000 then Print("usage: /wl cappct <0-1000>") else WS.db.settings.capPct = n; Print("default cap: scan price + " .. n .. "%.") end
        if WS.RefreshUI then WS.RefreshUI() end
    elseif cmd == "useowned" then WS.db.settings.useOwned = OnOff(rest, WS.db.settings.useOwned); Print("use materials you have: " .. (WS.db.settings.useOwned and "on" or "off")); if WS.RefreshUI then WS.RefreshUI() end
    elseif cmd == "alts" then WS.db.settings.useAlts = OnOff(rest, WS.db.settings.useAlts); Print("count alts (AltStash): " .. (WS.db.settings.useAlts and "on" or "off")); if WS.RefreshUI then WS.RefreshUI() end
    elseif cmd == "export" then WS.Export()
    elseif cmd == "text" then if WS.ShowText then WS.ShowText(WS.ListText()) else Print(WS.ListText()) end
    elseif cmd == "buy" then if WS.Buyer then WS.Buyer.Click() end
    elseif cmd == "skip" then if WS.Buyer then WS.Buyer.Skip() end
    elseif cmd == "reset" then WS.ResetRun()
    else Print("unknown command. /wl help") end
end

------------------------------------------------------------------------
-- events
------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
pcall(ev.RegisterEvent, ev, "BAG_UPDATE_DELAYED")
ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        WS.InitDB()
    elseif event == "ADDON_LOADED" and arg1 == "Auctionator" then
        WS.Prices.Hook()
    elseif event == "PLAYER_LOGIN" then
        if not WS.db then WS.InitDB() end
        WS.Prices.Hook()
        if WS.InitUI then local ok, err = pcall(WS.InitUI); if not ok then Print("UI error: " .. tostring(err)) end end
    elseif event == "BAG_UPDATE_DELAYED" then
        if WS.RefreshUI then WS.RefreshUI() end
    end
end)

SLASH_WAYLAIDSHOPPER1 = "/wl"
SLASH_WAYLAIDSHOPPER2 = "/waylaid"
SlashCmdList["WAYLAIDSHOPPER"] = function(msg) WS.Slash(msg) end
