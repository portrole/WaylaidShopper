-- WaylaidShopper: Bags check - is everything needed to fill the planned crates in your BAGS (not the bank, not alts)?
-- Plan = the shopping list's crates (or, without a list, the selection). Counts only bags 0-4. Bag contents are shared
-- out over the fills: each fill needs one empty crate and one complete bundle; the planned bundle is used when the bags
-- cover it, otherwise any other bundle of that crate the bags fully cover (it switches). Read-only.
-- Runs only when you ask: the Bags check button or /wl check.
local ADDON, WS = ...
local K = {}
WS.Check = K


local function BagCount(id)
    local f = (C_Item and C_Item.GetItemCount) or GetItemCount
    if type(f) ~= "function" then return 0 end
    local ok, n = pcall(f, id, false)             -- false = bags only
    return (ok and tonumber(n)) or 0
end
K.BagCount = BagCount

local function BankCount(id)
    local f = (C_Item and C_Item.GetItemCount) or GetItemCount
    if type(f) ~= "function" then return 0 end
    local ok, n = pcall(f, id, true)              -- bags + bank (cached)
    return math.max(0, ((ok and tonumber(n)) or 0) - BagCount(id))
end

local function AltCount(id)
    local A = _G.AltStash and _G.AltStash.API
    if type(A) ~= "table" or type(A.GetTotalCount) ~= "function" then return 0 end
    local ok, t = pcall(A.GetTotalCount, id, "always")
    if not ok or type(t) ~= "number" then return 0 end
    return math.max(0, t - BagCount(id) - BankCount(id))      -- AltStash's total includes this character
end

-- fills to check: { {crate = crateData, item = plannedBundleItem or nil}, ... }
function K.Plan()
    local fills = {}
    local L = WS.db and WS.db.list
    if L and L.picks and #L.picks > 0 then
        for _, p in ipairs(L.picks) do
            local c = WS.byId[p.crate]
            if c then fills[#fills + 1] = { crate = c, item = p.item } end
        end
        return fills, "list"
    end
    for _, c in ipairs(WS.Crates or {}) do
        for _ = 1, (WS.db and WS.db.sel[c.id]) or 0 do fills[#fills + 1] = { crate = c } end
    end
    return fills, "selection"
end

-- returns result = { fills, ready, perCrate = { [crateID] = {crate, total, ready, missing = {itemID = n}} }, order,
--                    missing = {itemID = n}, source }
function K.Evaluate()
    local fills, source = K.Plan()
    local bag = setmetatable({}, { __index = function(t, id) local n = BagCount(id); rawset(t, id, n); return n end })
    -- fills with fewer bag-covered options first, so a flexible crate does not take what a fixed one needs
    local function Options(f)
        local n = 0
        for _, b in ipairs(f.crate.bundles) do if bag[b.item] >= b.count then n = n + 1 end end
        return n
    end
    for i, f in ipairs(fills) do f.idx = i; f.opts = Options(f) end
    local sorted = {}
    for i, f in ipairs(fills) do sorted[i] = f end
    table.sort(sorted, function(a, b) if a.opts ~= b.opts then return a.opts < b.opts end return a.idx < b.idx end)
    local res = { fills = #fills, ready = 0, perCrate = {}, order = {}, missing = {}, source = source }
    local function Miss(pc, id, n)
        if n <= 0 then return end
        pc.missing[id] = (pc.missing[id] or 0) + n
        res.missing[id] = (res.missing[id] or 0) + n
    end
    for _, f in ipairs(sorted) do
        local c = f.crate
        local pc = res.perCrate[c.id]
        if not pc then pc = { crate = c, total = 0, ready = 0, missing = {} }; res.perCrate[c.id] = pc end
        pc.total = pc.total + 1
        local hasCrate = bag[c.id] > 0
        -- bundle: planned one if the bags cover it, else any covered one (cheapest by scan price), else none
        local chosen
        if f.item then
            for _, b in ipairs(c.bundles) do if b.item == f.item and bag[b.item] >= b.count then chosen = b end end
        end
        if not chosen then
            local bestP
            for _, b in ipairs(c.bundles) do
                if bag[b.item] >= b.count then
                    local p = (WS.Prices.Get(b.item) or 0) * b.count
                    if not chosen or p < bestP then chosen, bestP = b, p end
                end
            end
        end
        if hasCrate then bag[c.id] = bag[c.id] - 1 else Miss(pc, c.id, 1) end
        if chosen then
            bag[chosen.item] = bag[chosen.item] - chosen.count
            f.used = chosen
        else
            -- report the planned bundle's shortfall, or the bundle the bags are closest to
            local target
            if f.item then for _, b in ipairs(c.bundles) do if b.item == f.item then target = b end end end
            if not target then
                local bestShort
                for _, b in ipairs(c.bundles) do
                    local short = b.count - math.max(0, bag[b.item])
                    if not target or short < bestShort then target, bestShort = b, short end
                end
            end
            if target then Miss(pc, target.item, target.count - math.max(0, bag[target.item])) end
        end
        if hasCrate and chosen then pc.ready = pc.ready + 1; res.ready = res.ready + 1 end
    end
    for _, c in ipairs(WS.Crates or {}) do if res.perCrate[c.id] then res.order[#res.order + 1] = c.id end end
    return res
end

local function Where(id, n)
    local bank, alts = BankCount(id), AltCount(id)
    local t = {}
    if bank > 0 then t[#t + 1] = string.format("in bank: withdraw %d", math.min(n, bank)) end
    if alts > 0 then t[#t + 1] = string.format("%d on alts", alts) end
    return #t > 0 and (" (" .. table.concat(t, ", ") .. ")") or ""
end

local function Short(name) return (tostring(name):gsub("^Waylaid Crate: ", "")) end

-- lines for chat / the text window; summary line first
function K.Lines(res)
    local lines = {}
    if res.fills == 0 then
        lines[1] = "Bags check: nothing planned (select crates or build a list first)."
        return lines, true
    end
    local ok = res.ready == res.fills
    local miss = {}
    for id, n in pairs(res.missing) do miss[#miss + 1] = { id = id, n = n } end
    table.sort(miss, function(a, b) return WS.ItemName(a.id) < WS.ItemName(b.id) end)
    if ok then
        lines[1] = string.format("|cff40ff40Bags check: all %d crate fill(s) ready - everything is in your bags.|r", res.fills)
    else
        local parts = {}
        for _, m in ipairs(miss) do parts[#parts + 1] = string.format("%dx %s%s", m.n, WS.ItemName(m.id), Where(m.id, m.n)) end
        lines[1] = string.format("|cffff4040Bags check: %d of %d crate fill(s) ready. Missing from bags:|r %s", res.ready, res.fills, table.concat(parts, ", "))
    end
    for _, id in ipairs(res.order) do
        local pc = res.perCrate[id]
        local status
        if pc.ready == pc.total then status = "|cff40ff40Ready|r"
        else
            local m = {}
            for mid, n in pairs(pc.missing) do m[#m + 1] = string.format("%dx %s", n, Short(WS.ItemName(mid))) end
            table.sort(m)
            status = "|cffff4040Missing|r " .. table.concat(m, ", ")
        end
        lines[#lines + 1] = string.format("  %s x%d: %d/%d ready - %s", Short(pc.crate.name), pc.total, pc.ready, pc.total, status)
    end
    if not ok then lines[#lines + 1] = "  (AH purchases arrive in your mailbox: collect the mail first.)" end
    return lines, ok
end

-- prints the summary and one line per crate
function K.Run()
    if not WS.db then return end
    local res = K.Evaluate()
    K.last = res
    for _, l in ipairs((K.Lines(res))) do WS.Print(l) end
    return res
end
