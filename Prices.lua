-- WaylaidShopper: prices from Auctionator's scan data, money formatting / parsing.
-- Uses ONLY Auctionator's public API (Auctionator.API.v1.*): every call is feature-detected and pcall-wrapped, and
-- Auctionator is optional (## OptionalDeps). Never reads Auctionator's saved variables. All money values are copper.
local ADDON, WS = ...
local P = {}
WS.Prices = P

P.STALE_DAYS = 3

local function IsSecret(v) return issecretvalue and issecretvalue(v) or false end
local function Num(v) if type(v) == "number" and not IsSecret(v) and v == v then return v end end
P.Num = Num

function P.API()
    local A = type(Auctionator) == "table" and Auctionator.API
    local v1 = type(A) == "table" and A.v1
    if type(v1) == "table" and type(v1.GetAuctionPriceByItemID) == "function" then return v1 end
    return nil
end

local memo = {}
function P.ResetMemo() memo = {} end

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a = pcall(fn, WS.CALLER, ...)
    if ok then return a end
end

-- unit price (copper), age in days (nil = unknown), stale flag
function P.Get(id)
    if type(id) ~= "number" then return nil end
    local m = memo[id]
    if m then return m[1], m[2], m[3] end
    local v1 = P.API()
    local price, age
    if v1 then
        price = Num(Call(v1.GetAuctionPriceByItemID, id))
        if price and price <= 0 then price = nil end
        age = Num(Call(v1.GetAuctionAgeByItemID, id))
    end
    local stale = false
    if price then
        local days = (WS.db and WS.db.settings and tonumber(WS.db.settings.staleDays)) or P.STALE_DAYS
        stale = (age == nil and v1 and type(v1.GetAuctionAgeByItemID) == "function") or (age ~= nil and age > days)
        stale = stale and true or false
    end
    memo[id] = { price, age, stale }
    return price, age, stale
end

function P.AgeText(age)
    if age == nil then return "unknown" end
    if age == 0 then return "today" end
    return age .. " day" .. (age == 1 and "" or "s") .. " ago"
end

-- "1g 20s 5c" (compact, no textures so it also works in copy text)
function P.Format(c)
    c = tonumber(c)
    if not c then return "?" end
    local neg = c < 0
    c = math.floor(math.abs(c) + 0.5)
    local g, s, cp = math.floor(c / 10000), math.floor((c % 10000) / 100), c % 100
    local t = {}
    if g > 0 then t[#t + 1] = g .. "g" end
    if s > 0 then t[#t + 1] = s .. "s" end
    if cp > 0 or #t == 0 then t[#t + 1] = cp .. "c" end
    return (neg and "-" or "") .. table.concat(t, " ")
end

-- colored version for the UI
function P.Money(c)
    c = tonumber(c)
    if not c then return "|cff666666?|r" end
    -- Built from the parts. (0.2.0 colored the letters with chained gsubs; the "c" pass also matched the "7c" inside the
    -- silver color code |cffc7c7cf and broke it, so values with silver showed raw text like "cffc7...".)
    local neg = c < 0
    c = math.floor(math.abs(c) + 0.5)
    local g, s, cp = math.floor(c / 10000), math.floor((c % 10000) / 100), c % 100
    local t = {}
    if g > 0 then t[#t + 1] = g .. "|cffffd700g|r" end
    if s > 0 then t[#t + 1] = s .. "|cffc7c7cfs|r" end
    if cp > 0 or #t == 0 then t[#t + 1] = cp .. "|cffeda55fc|r" end
    return (neg and "-" or "") .. table.concat(t, " ")
end

-- parse money typed by a person. Returns copper, or nil on garbage (never guesses).
-- Accepts "1g20s5c", "1g 20s", "10 g", "10g 50s", "50g", "120s", "75c", "10.5g", "1.5" (plain number = gold),
-- "1,250g" (comma = thousands), "10,5g" (comma = decimal), "10 gold 5 silver", "10G".
function P.Parse(str)
    if type(str) ~= "string" then return nil end
    local s = str:lower()
    s = s:gsub("gold", "g"):gsub("silver", "s"):gsub("copper", "c")
    s = s:gsub("%s+", "")
    s = s:gsub("(%d),(%d%d%d)%f[^%d]", "%1%2")       -- thousands separators: 1,250 -> 1250 (repeat for 1,000,000)
    s = s:gsub("(%d),(%d%d%d)%f[^%d]", "%1%2")
    s = s:gsub("(%d),(%d)", "%1.%2")                    -- any other comma between digits: decimal
    if s == "" then return nil end
    if s:find("^%d*%.?%d+$") or s:find("^%d+%.$") then
        local plain = tonumber(s)
        if not plain then return nil end
        return math.floor(plain * 10000 + 0.5)
    end
    local total, any = 0, false
    for num, unit in s:gmatch("(%d*%.?%d+)([gsc])") do
        local n = tonumber(num)
        if not n then return nil end
        any = true
        if unit == "g" then total = total + n * 10000 elseif unit == "s" then total = total + n * 100 else total = total + n end
    end
    local rest = s:gsub("%d*%.?%d+[gsc]", "")
    if not any or rest ~= "" then return nil end
    return math.floor(total + 0.5)
end

-- refresh when Auctionator finishes a scan (public API, if this Auctionator has it)
function P.Hook()
    if P._hooked then return end
    local v1 = P.API()
    if v1 and type(v1.RegisterForDBUpdate) == "function" then
        P._hooked = pcall(v1.RegisterForDBUpdate, WS.CALLER, function()
            P.ResetMemo()
            WS.pricesUpdatedAt = time and time() or nil
            if WS.RefreshUI then pcall(WS.RefreshUI) end
        end)
    end
end

-- Write an Auctionator shopping list (only when the user clicks / types the command).
-- terms = { {name=, count=}, ... }. Returns true, or false + reason.
function P.ExportShoppingList(listName, terms)
    local v1 = P.API()
    if not v1 then return false, "Auctionator is not loaded." end
    if type(v1.CreateShoppingList) ~= "function" then return false, "this Auctionator has no CreateShoppingList API." end
    if #terms == 0 then return false, "the shopping list is empty." end
    local searches = {}
    for _, t in ipairs(terms) do
        local name = tostring(t.name or ""):gsub('[";]', "")
        local s
        if type(v1.ConvertToSearchString) == "function" then
            local ok, r = pcall(v1.ConvertToSearchString, WS.CALLER, { searchString = name, isExact = true, quantity = t.count })
            if ok and type(r) == "string" then s = r end
        end
        searches[#searches + 1] = s or ('"' .. name .. '"')
    end
    local ok, err = pcall(v1.CreateShoppingList, WS.CALLER, listName, searches)
    if not ok then return false, "Auctionator error: " .. tostring(err) end
    return true
end
