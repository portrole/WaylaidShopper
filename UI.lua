-- WaylaidShopper: window (Crates ranking / Shopping List + AH Buy Next panel), minimal style like AltStash.
local ADDON, WS = ...

local BACKDROP_TMPL = BackdropTemplateMixin and "BackdropTemplate" or nil
local WHITE = "Interface\\ChatFrame\\ChatFrameBackground"
local BORDER = "Interface\\Tooltips\\UI-Tooltip-Border"
local ICON = "Interface\\Icons\\INV_Crate_02"
local W, H = 660, 520
local PAD = 12
local TITLE_H = 30
local ROW_H = 20
local LIST_TOP = -130
local LIST_W = W - 2 * PAD - 12 - 26

local win, ui = nil, { rows = {}, view = "crates" }
WS._ui = ui

local function SetBackdropSafe(f, bg, edge, edgeSize, inset, bgc, bc)
    if not f.SetBackdrop then return end
    f:SetBackdrop({ bgFile = bg, edgeFile = edge, tile = false, tileSize = 0, edgeSize = edgeSize or 12,
        insets = { left = inset or 3, right = inset or 3, top = inset or 3, bottom = inset or 3 } })
    if bgc then f:SetBackdropColor(bgc[1], bgc[2], bgc[3], bgc[4]) end
    if bc then f:SetBackdropBorderColor(bc[1], bc[2], bc[3], bc[4]) end
end

local function Btn(parent, text, w, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w or 90, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function Check(parent, label, get, set)
    local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    c:SetSize(22, 22)
    local t = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    t:SetPoint("LEFT", c, "RIGHT", 1, 0)
    t:SetText(label)
    c:SetScript("OnClick", function(self) set(self:GetChecked() and true or false); WS.RefreshUI() end)
    c.sync = function() c:SetChecked(get() and true or false) end
    return c, t
end

local function Tip(f, title, lines)
    f:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(title, 1, 0.82, 0)
        for _, l in ipairs(lines) do GameTooltip:AddLine(l, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
end

local function Cycle(list, cur)
    for i, v in ipairs(list) do if v == cur then return list[i % #list + 1] end end
    return list[1]
end

local QCOLOR = { [1] = "|cffffffff", [2] = "|cff1eff00" }
local function ShortCrate(n) return (n:gsub("^Waylaid Crate: ", "")) end

------------------------------------------------------------------------
-- rows (pooled): columns are font strings; list rows also get a cap edit box
------------------------------------------------------------------------
-- Input boxes keep what you type until it is committed: on Enter, when the box loses focus, and before any button that
-- uses the value (Fill budget, Best value, Build list, Buy...). Text that cannot be read stays in the box in red with a
-- chat message; it never wipes the box or the saved value. Refreshes do not overwrite a box you are editing.
WS.inputBoxes = WS.inputBoxes or {}
local function Bad(eb, bad)
    eb.bad = bad and true or nil
    if eb.SetTextColor then if bad then eb:SetTextColor(1, 0.25, 0.25) else eb:SetTextColor(1, 1, 1) end end
end
-- commit(text) -> true, or false + message
local function InputBox(eb, commit, validate)
    eb.commit, eb.validate = commit, validate
    WS.inputBoxes[#WS.inputBoxes + 1] = eb
    eb:SetScript("OnTextChanged", function(self, userInput)
        if not userInput then return end
        self.dirty = true
        Bad(self, self.validate and not self.validate(self:GetText() or ""))
    end)
    local function Commit(self, quiet)
        if not self.dirty then return true end
        local ok, msg = self.commit(self:GetText() or "")
        if ok then self.dirty = nil; Bad(self, false); return true end
        Bad(self, true)
        if not quiet then WS.Print("|cffff4040" .. (msg or "could not read that") .. "|r") end
        return false, msg
    end
    eb.Commit = Commit
    eb:SetScript("OnEnterPressed", function(self)
        self.dirty = true                        -- Enter always commits what is in the box
        local ok = Commit(self)
        self:ClearFocus()
        if ok then WS.RefreshUI() end
    end)
    eb:SetScript("OnEditFocusLost", function(self)
        if self.dirty and Commit(self) then WS.RefreshUI() end
    end)
    eb:SetScript("OnEscapePressed", function(self)
        self.dirty = nil; Bad(self, false); self:ClearFocus(); WS.RefreshUI()
    end)
    return eb
end
-- set a box from the saved value unless you are editing it or it holds unread text
local function SetBox(eb, text)
    if eb:HasFocus() or eb.dirty or eb.bad then return end
    eb:SetText(text)
end
-- commit every edited box; false + message if one cannot be read (the action should not run then)
function WS.CommitInputs()
    local okAll, first = true, nil
    for _, eb in ipairs(WS.inputBoxes) do
        if eb.dirty then
            local ok, msg = eb:Commit()
            if not ok then okAll = false; first = first or msg end
        end
    end
    return okAll, first
end
local function Guarded(fn)
    return function(...)
        if not WS.CommitInputs() then WS.Print("|cffff4040fix the red box first (or press Escape in it).|r") return end
        return fn(...)
    end
end
local function MoneyOk(t) t = t or ""; return t == "" or t:lower() == "off" or (WS.Prices.Parse(t) or -1) >= 0 end
local function ReadMoney(t, what)
    t = t or ""
    if t == "" or t:lower() == "off" or t:lower() == "none" then return 0 end
    local c = WS.Prices.Parse(t)
    if not c then return nil, string.format("%s: could not read \"%s\" as money (try 10g, 10g 50s or 75s).", what, t) end
    return c
end
WS._ReadMoney = ReadMoney

local CRATE_COLS = { { "sel", 34, "RIGHT" }, { "name", 190 }, { "lvl", 28, "RIGHT" }, { "fill", 126 }, { "cost", 82, "RIGHT" }, { "favor", 34, "RIGHT" }, { "per", 62, "RIGHT" }, { "ah", 40, "RIGHT" } }
local LIST_COLS = { { "name", 190 }, { "need", 40, "RIGHT" }, { "left", 40, "RIGHT" }, { "unit", 86, "RIGHT" }, { "total", 86, "RIGHT" }, { "cap", 140 } }

local function GetRow(i)
    local r = ui.rows[i]
    if r then return r end
    r = CreateFrame("Button", nil, ui.holder)
    r:SetSize(LIST_W, ROW_H)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    if r.RegisterForClicks then r:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
    local hl = r:CreateTexture(nil, "BACKGROUND")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.03 or 0)
    r.bg = hl
    r.fs = {}
    for k = 1, 8 do
        local fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetHeight(ROW_H)
        fs:SetWordWrap(false)
        r.fs[k] = fs
    end
    local eb = CreateFrame("EditBox", nil, r, "InputBoxTemplate")
    eb:SetSize(70, 16)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(16)
    InputBox(eb, function(txt)
        local id = eb.forId or r.itemID
        if not id then return true end
        if txt == "" or txt:lower() == "auto" then WS.SetCap(id, nil) return true end
        local c = WS.Prices.Parse(txt)
        if c and c > 0 then WS.SetCap(id, c) return true end
        return false, "max price: could not read \"" .. txt .. "\" as money (try 1g20s, or auto)."
    end, function(txt) return txt == "" or txt:lower() == "auto" or (WS.Prices.Parse(txt) or 0) > 0 end)
    r.cap = eb
    r.capNote = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    r:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    ui.rows[i] = r
    return r
end

local function Layout(r, cols)
    local x = 4
    for k = 1, 8 do
        local fs, c = r.fs[k], cols[k]
        fs:ClearAllPoints()
        if c then
            fs:SetPoint("LEFT", r, "LEFT", x, 0)
            fs:SetWidth(c[2] - 4)
            fs:SetJustifyH(c[3] or "LEFT")
            fs:Show()
            r.capX = x
            x = x + c[2]
        else fs:Hide() end
    end
end

local function HeaderLayout(cols, labels)
    local x = PAD + 6 + 4
    for k = 1, 8 do
        local fs = ui.hdr[k]
        local c = cols[k]
        fs:ClearAllPoints()
        if c then
            fs:SetPoint("TOPLEFT", win, "TOPLEFT", x, LIST_TOP + 16)
            fs:SetWidth(c[2] - 4)
            fs:SetJustifyH(c[3] or "LEFT")
            fs:SetText(labels[k])
            fs:Show()
            x = x + c[2]
        else fs:Hide() end
    end
end

local function CrateTooltip(self)
    local e = self.entry
    if not (e and GameTooltip) then return end
    local P = WS.Prices
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(e.crate.name, 1, 0.82, 0)
    GameTooltip:AddLine(string.format("Level %d - %s - %s - %d Merchant's Favor%s", e.crate.level, e.crate.category, e.crate.profession,
        e.crate.favor, e.crate.favorEstimated and " (estimate)" or ""), 0.8, 0.8, 0.8, true)
    GameTooltip:AddLine("Fill with ONE of:", 1, 1, 1)
    local pool = WS.db.settings.useOwned and setmetatable({}, { __index = function(t, id) local n = WS.Owned(id); rawset(t, id, n); return n end }) or nil
    for _, b in ipairs(e.crate.bundles) do
        local c = WS.BundleCost(b, pool)
        local right
        if c.missing then right = "|cff666666no price|r"
        else right = P.Money(c.cost) .. (c.stale and " |cff888888*|r" or "") end
        local left = string.format("%dx %s", b.count, b.name) .. (c.use > 0 and string.format(" |cff88ff88(have %d)|r", c.use) or "")
        if e.best and e.best.item == b.item then left = "|cff40ff40> |r" .. left end
        GameTooltip:AddDoubleLine(left, right, 1, 1, 1, 1, 1, 1)
    end
    if e.held > 0 then GameTooltip:AddLine("You hold " .. e.held .. " of this crate.", 0.5, 1, 0.5) end
    do
        local q, age, stale = WS.AvailQty(e.crate.id)
        if q then
            local rec = WS.Avail(e.crate.id)
            local cheapest = rec and rec.rows and rec.rows[1] and rec.rows[1].unit
            GameTooltip:AddLine(string.format("AH: %d empty crate(s) listed%s, %s%s", q, cheapest and (", cheapest " .. P.Money(math.floor(cheapest + 0.5))) or "",
                WS.AgeText(age), stale and " (old: Scan crates again)" or ""), stale and 0.7 or 0.5, stale and 0.7 or 1, stale and 0.5 or 0.5, true)
        else
            GameTooltip:AddLine("AH: quantity unknown (Scan crates at the Auction House).", 0.6, 0.6, 0.6, true)
        end
    end
    if e.fill and e.fill.crateBuy == 1 then
        if e.crateSoldOut then GameTooltip:AddLine("You hold none and none (or no more) are listed on the AH: not picked automatically.", 1, 0.5, 0.25, true)
        elseif e.unavailable then GameTooltip:AddLine("You hold none and the empty crate has no AH price: not picked automatically.", 1, 0.5, 0.25, true)
        else GameTooltip:AddDoubleLine("+ empty crate (AH)", P.Money(e.crateCost), 1, 1, 1, 1, 1, 1) end
    end
    GameTooltip:AddLine("Left-click: select one more. Right-click: one less. Shift-click: clear.", 0.6, 0.6, 0.6, true)
    GameTooltip:AddLine("* = price older than " .. (WS.db.settings.staleDays or 3) .. " days.", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

-- "AH" column: empty crates listed (from Buy Next searches / Scan crates); ? = not searched yet, grey = old
local function AHText(id)
    local q, age, stale = WS.AvailQty(id)
    if not q then return "|cff666666?|r" end
    if q == 0 then return stale and "|cff996666" .. "0|r" or "|cffff40400|r" end
    return (stale and "|cff999999" or "|cffffffff") .. q .. "|r"
end
WS._AHText = AHText

local function RefreshCrates()
    local P = WS.Prices
    ui.empty:Hide()
    HeaderLayout(CRATE_COLS, { "Sel", "Crate", "Lv", "Cheapest fill", "Cost", "Favor", "Per favor", "AH" })
    local list = WS.Rank()
    for i, e in ipairs(list) do
        local r = GetRow(i)
        Layout(r, CRATE_COLS)
        r.cap:Hide(); r.capNote:Hide()
        r.entry = e
        r.itemID = nil
        local c = e.crate
        r.fs[1]:SetText(e.sel > 0 and ("|cffffff00x" .. e.sel .. "|r") or "|cff555555-|r")
        r.fs[2]:SetText((e.over and "|cff996666" or QCOLOR[c.quality] or "") .. ShortCrate(c.name) .. "|r" .. (e.held > 0 and (" |cff88ff88(" .. e.held .. ")|r") or ""))
        r.fs[3]:SetText(tostring(c.level))
        if e.best then
            r.fs[4]:SetText(string.format("%dx %s", e.best.count, e.best.name) .. (e.best.use > 0 and " |cff88ff88*|r" or ""))
            if e.crateSoldOut then r.fs[5]:SetText("|cffff8040none on AH|r")
            elseif e.unavailable then r.fs[5]:SetText("|cffff8040no crate|r")
            else r.fs[5]:SetText(P.Money(e.cost) .. (e.best.stale and "|cff888888*|r" or "") .. ((e.crateBuy == 1) and "|cffaaaaaa+c|r" or "")) end
            r.fs[7]:SetText(e.over and ("|cffff4040" .. P.Format(math.floor(e.perFavor + 0.5)) .. "|r") or P.Money(math.floor(e.perFavor + 0.5)))
        else
            r.fs[4]:SetText("|cff666666no prices - scan the AH|r")
            r.fs[5]:SetText("|cff666666?|r")
            r.fs[7]:SetText("")
        end
        r.fs[6]:SetText(tostring(c.favor) .. (c.favorEstimated and "|cff888888~|r" or ""))
        r.fs[8]:SetText(AHText(c.id))
        r:SetScript("OnClick", function(_, button)
            local cur = WS.db.sel[c.id] or 0
            if IsShiftKeyDown and IsShiftKeyDown() then WS.SetSel(c.id, 0)
            elseif button == "RightButton" then WS.SetSel(c.id, cur - 1)
            else WS.SetSel(c.id, cur + 1) end
            WS.RefreshUI()
        end)
        r:SetScript("OnEnter", CrateTooltip)
        r:Show()
    end
    for i = #list + 1, #ui.rows do ui.rows[i]:Hide() end
    ui.holder:SetHeight(math.max(10, #list * ROW_H))
    local s = WS.db.settings
    ui.tierBtn:SetText("Tier: " .. (s.tier == "all" and "All" or s.tier))
    ui.catBtn:SetText("Type: " .. (s.category == "all" and "All" or s.category))
    ui.sortBtn:SetText(s.sort == "favor" and "Sort: per Favor" or "Sort: Cost")
    SetBox(ui.nBox, tostring(ui.nBox.value or 5))
    SetBox(ui.repBox, tostring(WS.db.settings.maxRepeat or 5))
    SetBox(ui.maxBox, WS.MaxPer() and (P.Format(WS.MaxPer()):gsub(" ", "")) or "")
    local budget = WS.db.budget or 0
    SetBox(ui.cBudgetBox, budget > 0 and (P.Format(budget):gsub(" ", "")) or "")
    local nsel = WS.NumSelected()
    local selCost, selFavor = 0, 0
    for _, e in ipairs(WS.Rank(true)) do
        local n = WS.db.sel[e.crate.id] or 0
        if n > 0 and e.best then selCost = selCost + (e.cost or e.best.cost) * n; selFavor = selFavor + e.crate.favor * n end
    end
    ui.selInfo:SetText(nsel > 0 and string.format("|cffffff00%d|r crate(s) selected: about %s for %d Favor (%s per Favor)", nsel, P.Money(selCost), selFavor,
        selFavor > 0 and P.Money(math.floor(selCost / selFavor + 0.5)) or "?") or (WS.selNote and ("|cffff8040" .. WS.selNote .. "|r") or "|cff888888click crates to select|r"))
end

local function RefreshList()
    local P = WS.Prices
    HeaderLayout(LIST_COLS, { "Item", "Need", "Left", "Unit (scan)", "Total left", "Max unit price" })
    local rows, total, missing = WS.ListRows()
    for i, d in ipairs(rows) do
        local r = GetRow(i)
        Layout(r, LIST_COLS)
        r.entry = nil
        r.itemID = d.id
        local cur = WS.Buyer and WS.Buyer.Current()
        local mark = (cur and cur.id == d.id) and "|cffffd100> |r" or ""
        local nameColor = d.left == 0 and "|cff40ff40" or (d.skip and "|cff888888" or "|cffffffff")
        r.fs[1]:SetText(mark .. nameColor .. (d.isCrate and (d.label or d.name) or d.name) .. "|r" .. (d.isCrate and (" |cffaaaaaa(AH " .. AHText(d.id) .. "|cffaaaaaa)|r") or "") .. (d.skip and " |cff888888(skipped)|r" or ""))
        r.fs[2]:SetText(tostring(d.need))
        r.fs[3]:SetText(d.left == 0 and "|cff40ff40done|r" or ("|cffffff00" .. d.left .. "|r"))
        r.fs[4]:SetText(d.unit and (P.Money(d.unit) .. (d.stale and "|cff888888*|r" or "")) or "|cffff4040no price|r")
        r.fs[5]:SetText(d.total and P.Money(d.total) or (d.left > 0 and "|cffff4040?|r" or ""))
        r.fs[6]:SetText("")
        r.cap:ClearAllPoints()
        r.cap:SetPoint("LEFT", r, "LEFT", (r.capX or 450) + 6, 0)
        if r.cap.forId ~= d.id then r.cap.dirty = nil; Bad(r.cap, false); r.cap.forId = d.id end
        SetBox(r.cap, d.cap and (P.Format(d.cap):gsub(" ", "")) or "")
        r.cap:Show()
        r.capNote:ClearAllPoints()
        r.capNote:SetPoint("LEFT", r.cap, "RIGHT", 4, 0)
        local eff, why = WS.EffectiveCap(d.id)
        if why == "favor" then r.capNote:SetText("|cffffd100Favor: " .. P.Format(eff) .. "|r")
        else r.capNote:SetText(d.userCap and "set" or (d.cap and ("+" .. (WS.db.settings.capPct or 25) .. "%") or "|cffff4040none|r")) end
        r.capNote:Show()
        r:SetScript("OnClick", nil)
        r:SetScript("OnEnter", function(self)
            if not GameTooltip then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(d.name, 1, 0.82, 0)
            GameTooltip:AddLine("Price scanned " .. P.AgeText(d.age) .. ".", 0.8, 0.8, 0.8)
            GameTooltip:AddLine(string.format("Bought this run: %d of %d. Have now: %d.", d.bought, d.need, WS.ItemCount(d.id)), 1, 1, 1)
            GameTooltip:AddLine("Max unit price: type e.g. 1g20s and press Enter; empty or 'auto' = scan price + " .. (WS.db.settings.capPct or 25) .. "%.", 0.6, 0.6, 0.6, true)
            GameTooltip:Show()
        end)
        r:Show()
    end
    for i = #rows + 1, #ui.rows do ui.rows[i]:Hide() end
    ui.holder:SetHeight(math.max(10, #rows * ROW_H))
    if #rows == 0 then
        ui.empty:SetText(WS.db.list and "|cff40ff40Nothing to buy: your bags already cover the selected crates.|r" or "|cff888888No list yet. Select crates on the Crates tab and click Build list.|r")
        ui.empty:Show()
    else ui.empty:Hide() end
    local run = WS.db.run
    local budget = WS.db.budget or 0
    local fav, est, avg = WS.ListSummary()
    local L = WS.db.list
    local m = WS.MaxPer()
    ui.summary:SetText(L and string.format("%d crate(s)   Merchant's Favor: |cffffff00%d|r   Est. total: %s   Avg per Favor: %s%s", #(L.picks or {}), fav, P.Money(est),
        avg and P.Money(math.floor(avg + 0.5)) or "?", m and ("   |cff888888(limit " .. P.Format(m) .. ")|r") or "") or "")
    local warn = {}
    if L and L.overLimit and #L.overLimit > 0 then warn[#warn + 1] = "Left out (over per-Favor limit): " .. table.concat(L.overLimit, ", ") end
    if L and L.noPrice and #L.noPrice > 0 then warn[#warn + 1] = "No prices: " .. table.concat(L.noPrice, ", ") end
    if L and L.crateNoPrice and #L.crateNoPrice > 0 then warn[#warn + 1] = "Empty crate without AH price (set a cap): " .. table.concat(L.crateNoPrice, ", ") end
    if L then
        for _, so in ipairs(L.soldOut or {}) do warn[#warn + 1] = string.format("%s: only %d on AH, %d fill(s) left out", WS.CrateLabel(WS.byId[so.id]), so.listed or 0, so.n) end
        local unknown, old = WS.CrateAvailNotes(L)
        if #unknown > 0 then warn[#warn + 1] = "AH qty unknown (Scan crates): " .. table.concat(unknown, ", ") end
        if #old > 0 then warn[#warn + 1] = "AH qty old: " .. table.concat(old, ", ") end
    end
    ui.warn:SetText(#warn > 0 and ("|cffff8040" .. table.concat(warn, "   "):gsub("Waylaid Crate: ", "") .. "|r") or "")
    ui.totalFS:SetText("Left to buy: " .. P.Money(total) .. (missing > 0 and (" |cffff4040+" .. missing .. " unpriced|r") or "") ..
        "   Spent: " .. P.Money(run.spent or 0) ..
        (budget > 0 and ("   Budget left: " .. ((WS.BudgetLeft() or 0) > 0 and P.Money(WS.BudgetLeft()) or "|cffff40400|r") .. (total > (WS.BudgetLeft() or 0) and " |cffff8040(list costs more)|r" or "")) or ""))
    SetBox(ui.budgetBox, budget > 0 and (P.Format(budget):gsub(" ", "")) or "")
    local B = WS.Buyer
    if B then
        ui.buyBtn:SetText(B.ButtonText())
        local open = B.IsAHOpen()
        if ui.buyBtn.SetEnabled then ui.buyBtn:SetEnabled(open and WS.db.list ~= nil) end
        ui.status:SetText(B.status or "")
        local L = WS.db.list
        local need = B.short ~= nil or (L and L.soldOut and #L.soldOut > 0) or false
        if ui.replanBtn.SetShown then ui.replanBtn:SetShown(need and true or false) end
    end
end

function WS.RefreshUI()
    if not (win and win:IsShown()) then return end
    WS.Prices.ResetMemo()
    local crates = ui.view == "crates"
    for _, f in ipairs(ui.crateOnly) do f:SetShown(crates) end
    for _, f in ipairs(ui.listOnly) do f:SetShown(not crates) end
    ui.tabC:SetEnabled(not crates); ui.tabL:SetEnabled(crates)
    for _, c in ipairs(ui.checks) do c.sync() end
    if crates then RefreshCrates() else RefreshList() end
    local v1 = WS.Prices.API()
    ui.priceInfo:SetText(v1 and "|cff888888Prices: Auctionator scan|r" or "|cffff4040Auctionator not loaded: no prices|r")
end

function WS.Show(view)
    if not win then return end
    if view then ui.view = view end
    win:Show()
    WS.RefreshUI()
end
function WS.Toggle() if not win then return end if win:IsShown() then win:Hide() else WS.Show() end end
function WS.OnAHShow()
    if WS.db.list and #WS.db.list.order > 0 then
        for _, id in ipairs(WS.db.list.order) do if WS.Remaining(id) > 0 then WS.Show("list"); return end end
    end
end

-- copyable text window
function WS.ShowText(text)
    if not ui.textWin then
        local f = CreateFrame("Frame", "WaylaidShopperTextFrame", UIParent, BACKDROP_TMPL)
        f:SetSize(460, 340)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", function(self) self:StartMoving() end)
        f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
        SetBackdropSafe(f, WHITE, BORDER, 16, 4, { 0.05, 0.05, 0.07, 0.96 }, { 0.6, 0.6, 0.65, 1 })
        local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        t:SetPoint("TOPLEFT", 12, -10)
        t:SetText("Shopping list - Ctrl+C to copy")
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", 2, 2)
        local sf = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", 12, -32)
        sf:SetPoint("BOTTOMRIGHT", -32, 12)
        local eb = CreateFrame("EditBox", nil, sf)
        eb:SetMultiLine(true)
        eb:SetFontObject(ChatFontNormal or "GameFontHighlightSmall")
        eb:SetWidth(400)
        eb:SetAutoFocus(false)
        eb:SetScript("OnEscapePressed", function() f:Hide() end)
        sf:SetScrollChild(eb)
        f.eb = eb
        ui.textWin = f
        if UISpecialFrames then tinsert(UISpecialFrames, "WaylaidShopperTextFrame") end
    end
    ui.textWin:Show()
    ui.textWin.eb:SetText(text or "")
    ui.textWin.eb:HighlightText()
    ui.textWin.eb:SetFocus()
end

------------------------------------------------------------------------
-- build
------------------------------------------------------------------------
function WS.InitUI()
    win = CreateFrame("Frame", "WaylaidShopperFrame", UIParent, BACKDROP_TMPL)
    win:SetSize(W, H)
    win:SetFrameStrata("MEDIUM")
    if win.SetToplevel then win:SetToplevel(true) end
    win:SetClampedToScreen(true)
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", function(self) self:StartMoving() end)
    win:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, rp, x, y = self:GetPoint()
        WS.db.pos = { p, rp, x, y }
    end)
    SetBackdropSafe(win, WHITE, BORDER, 16, 4, { 0.05, 0.05, 0.07, 0.94 }, { 0.6, 0.6, 0.65, 1 })
    local pos = WS.db.pos
    if type(pos) == "table" and pos[1] then win:SetPoint(pos[1], UIParent, pos[2] or pos[1], pos[3] or 0, pos[4] or 0) else win:SetPoint("CENTER", UIParent, "CENTER", 200, 0) end
    win:SetScript("OnShow", function() WS.RefreshUI() end)

    local tb = win:CreateTexture(nil, "BORDER")
    tb:SetPoint("TOPLEFT", 4, -4); tb:SetPoint("TOPRIGHT", -4, -4); tb:SetHeight(TITLE_H - 4)
    tb:SetColorTexture(0.13, 0.13, 0.18, 1)
    local tline = win:CreateTexture(nil, "ARTWORK")
    tline:SetPoint("TOPLEFT", tb, "BOTTOMLEFT", 0, 0); tline:SetPoint("TOPRIGHT", tb, "BOTTOMRIGHT", 0, 0); tline:SetHeight(1)
    tline:SetColorTexture(1, 0.82, 0, 0.45)
    local ticon = win:CreateTexture(nil, "ARTWORK")
    ticon:SetSize(18, 18); ticon:SetPoint("LEFT", tb, "LEFT", 6, 0); ticon:SetTexture(ICON); ticon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", ticon, "RIGHT", 6, 0); title:SetText("Waylaid Shopper")
    local ver = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ver:SetPoint("LEFT", title, "RIGHT", 6, -1); ver:SetText("v" .. WS.version)
    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("RIGHT", tb, "RIGHT", 4, 0)
    close:SetScript("OnClick", function() win:Hide() end)
    ui.priceInfo = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ui.priceInfo:SetPoint("RIGHT", close, "LEFT", -4, 0)

    ui.tabC = Btn(win, "Crates", 100, function() ui.view = "crates"; WS.RefreshUI() end)
    ui.tabC:SetPoint("TOPLEFT", PAD, -(TITLE_H + 6))
    ui.tabL = Btn(win, "Shopping List", 110, function() ui.view = "list"; WS.RefreshUI() end)
    ui.tabL:SetPoint("LEFT", ui.tabC, "RIGHT", 4, 0)

    ui.crateOnly, ui.listOnly, ui.checks = {}, {}, {}
    local function C(f) ui.crateOnly[#ui.crateOnly + 1] = f; return f end
    local function Lo(f) ui.listOnly[#ui.listOnly + 1] = f; return f end

    -- crate filters
    local s = function() return WS.db.settings end
    ui.tierBtn = C(Btn(win, "Tier: All", 118, function() s().tier = Cycle({ "all", "Apprentice", "Journeyman", "Expert", "Artisan" }, s().tier); WS.RefreshUI() end))
    ui.tierBtn:SetPoint("TOPLEFT", PAD, -(TITLE_H + 34))
    ui.catBtn = C(Btn(win, "Type: All", 118, function()
        local l = { "all" }; for _, c in ipairs(WS.CATEGORIES) do l[#l + 1] = c end
        s().category = Cycle(l, s().category); WS.RefreshUI() end))
    ui.catBtn:SetPoint("LEFT", ui.tierBtn, "RIGHT", 4, 0)
    Tip(ui.catBtn, "Crate type", { "Herbs = Herbalism, Ore/Ingots = Mining, Textiles/Fabrics = cloth & leather, Curiosities = Enchanting, Parts = Engineering." })
    ui.sortBtn = C(Btn(win, "Sort: Cost", 110, function() s().sort = (s().sort == "favor") and "cost" or "favor"; WS.RefreshUI() end))
    ui.sortBtn:SetPoint("LEFT", ui.catBtn, "RIGHT", 4, 0)
    Tip(ui.sortBtn, "Sort", { "Cost: cheapest crate to fill first.", "Per favor: cheapest per Merchant's Favor (green crates pay double)." })
    local c1, t1 = Check(win, "My level", function() return s().myLevel end, function(v) s().myLevel = v end)
    c1:SetPoint("LEFT", ui.sortBtn, "RIGHT", 6, 0); C(c1); C(t1); ui.checks[#ui.checks + 1] = c1
    local c2, t2 = Check(win, "Held crates", function() return s().ownedCrates end, function(v) s().ownedCrates = v end)
    c2:SetPoint("LEFT", t1, "RIGHT", 6, 0); C(c2); C(t2); ui.checks[#ui.checks + 1] = c2
    local c6, t6 = Check(win, "Buy crates", function() return s().buyCrates end, function(v) s().buyCrates = v end)
    c6:SetPoint("LEFT", t2, "RIGHT", 6, 0); C(c6); C(t6); ui.checks[#ui.checks + 1] = c6
    Tip(c6, "Buy missing crates", { "Empty Waylaid Crates you do not hold are added to the shopping list and their AH price is counted in the cost and cost per Favor.",
        "Off: assumes you already have the crates (materials only)." })
    Tip(c2, "Held crates", { "Only crates you have in your bags or bank (or on alts, with AltStash)." })
    local c3, t3 = Check(win, "Use my mats", function() return s().useOwned end, function(v) s().useOwned = v end)
    c3:SetPoint("TOPLEFT", ui.tierBtn, "BOTTOMLEFT", 0, -2); C(c3); C(t3); ui.checks[#ui.checks + 1] = c3
    Tip(c3, "Use my mats", { "Subtract materials you already have (bags + bank; alts too with AltStash) before pricing." })
    local c4, t4 = Check(win, "Count alts (AltStash)", function() return s().useAlts end, function(v) s().useAlts = v end)
    c4:SetPoint("LEFT", t3, "RIGHT", 10, 0); C(c4); C(t4); ui.checks[#ui.checks + 1] = c4
    local function MoneyBox(w, get, set, title, lines)
        local eb = CreateFrame("EditBox", nil, win, "InputBoxTemplate")
        eb:SetSize(w, 18); eb:SetAutoFocus(false); eb:SetMaxLetters(16)
        InputBox(eb, function(txt)
            local c, msg = ReadMoney(txt, title)
            if not c then return false, msg end
            set(c); return true
        end, MoneyOk)
        Tip(eb, title, lines)
        return eb
    end
    local mlabel = C(win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
    mlabel:SetPoint("LEFT", t4, "RIGHT", 14, 0)
    mlabel:SetText("Max per Favor:")
    ui.maxBox = C(MoneyBox(56, nil, function(c) s().maxPer = c end, "Max cost per Merchant's Favor",
        { "e.g. 50s. Crates whose cheapest fill costs more per Favor are shown in red (or hidden), left out of Cheapest / Best value / Fill budget / Build list,",
          "and Buy Next will not pay a price that pushes a crate over it. Empty = no limit." }))
    ui.maxBox:SetPoint("LEFT", mlabel, "RIGHT", 8, 0)
    local c5, t5 = Check(win, "Hide over", function() return s().hideOver end, function(v) s().hideOver = v end)
    c5:SetPoint("LEFT", ui.maxBox, "RIGHT", 6, 0); C(c5); C(t5); ui.checks[#ui.checks + 1] = c5
    local cbl = C(win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
    cbl:SetPoint("LEFT", t5, "RIGHT", 10, 0)
    cbl:SetText("Budget:")
    ui.cBudgetBox = C(MoneyBox(60, nil, function(c) WS.db.budget = c end, "Budget", { "Gold for this run (e.g. 50g). Used by Fill budget and by Buy Next. Empty = none." }))
    ui.cBudgetBox:SetPoint("LEFT", cbl, "RIGHT", 8, 0)

    ui.hdr = {}
    for k = 1, 8 do
        local fs = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        ui.hdr[k] = fs
    end

    local inset = CreateFrame("Frame", nil, win, BACKDROP_TMPL)
    inset:SetPoint("TOPLEFT", PAD, LIST_TOP)
    inset:SetPoint("BOTTOMRIGHT", -PAD, 96)
    SetBackdropSafe(inset, WHITE, BORDER, 12, 3, { 0, 0, 0, 0.45 }, { 0.35, 0.35, 0.4, 1 })
    local scroll = CreateFrame("ScrollFrame", "WaylaidShopperScroll", inset, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", -26, 6)
    local holder = CreateFrame("Frame", nil, scroll)
    holder:SetSize(LIST_W, 10)
    scroll:SetScrollChild(holder)
    ui.holder = holder
    ui.empty = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.empty:SetPoint("TOPLEFT", 6, -8)

    -- crates footer
    local nlabel = C(win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
    nlabel:SetPoint("BOTTOMLEFT", PAD, 70)
    nlabel:SetText("N")
    ui.nBox = C(CreateFrame("EditBox", nil, win, "InputBoxTemplate"))
    ui.nBox:SetSize(30, 18); ui.nBox:SetPoint("LEFT", nlabel, "RIGHT", 8, 0); ui.nBox:SetAutoFocus(false); ui.nBox:SetMaxLetters(2)
    ui.nBox:SetText("5")
    ui.nBox.value = 5
    InputBox(ui.nBox, function(txt)
        local n = tonumber(txt)
        if n and n >= 1 and n <= 99 then ui.nBox.value = math.floor(n) return true end
        return false, "N: type a number from 1 to 99."
    end, function(txt) local n = tonumber(txt); return n ~= nil and n >= 1 and n <= 99 end)
    local selN = C(Btn(win, "Cheapest", 70, Guarded(function()
        local n = WS.SelectCheapest(ui.nBox.value or 5)
        WS.Print("selected the " .. n .. " cheapest crate(s).")
        WS.RefreshUI()
    end)))
    selN:SetPoint("LEFT", ui.nBox, "RIGHT", 4, 0)
    Tip(selN, "Cheapest N", { "Select the N crates that are cheapest to fill (within the per-Favor limit)." })
    local selV = C(Btn(win, "Best value", 80, Guarded(function() WS.Slash("best " .. (ui.nBox.value or 5)) end)))
    selV:SetPoint("LEFT", selN, "RIGHT", 4, 0)
    Tip(selV, "Best value N", { "Select the N best fills by cost per Merchant's Favor. The same crate can be picked more than once (up to Max each, or what you hold with Held crates).",
        "Each extra fill is priced after the ones before it: your materials used up, the cheaper bundle switching, and dearer AH listings when you have searched that item." })
    local fill = C(Btn(win, "Fill budget", 85, Guarded(function() WS.Slash("fill") end)))
    fill:SetPoint("LEFT", selV, "RIGHT", 4, 0)
    Tip(fill, "Fill to budget", { "Best value first, adding fills (repeats allowed, up to Max each / what you hold) until the next one would go past the budget left." })
    local selH = C(Btn(win, "Held", 55, function() WS.Print("selected " .. WS.SelectOwned() .. " crate(s) you hold."); WS.RefreshUI() end))
    selH:SetPoint("LEFT", fill, "RIGHT", 4, 0)
    Tip(selH, "Select held", { "Select every crate you hold (bags, bank, alts with AltStash)." })
    local clr = C(Btn(win, "Clear", 55, function() WS.ClearSel(); WS.RefreshUI() end))
    clr:SetPoint("LEFT", selH, "RIGHT", 4, 0)
    local rl = C(win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
    rl:SetPoint("LEFT", clr, "RIGHT", 8, 0)
    rl:SetText("Max each")
    ui.repBox = C(CreateFrame("EditBox", nil, win, "InputBoxTemplate"))
    ui.repBox:SetSize(24, 18); ui.repBox:SetPoint("LEFT", rl, "RIGHT", 6, 0); ui.repBox:SetAutoFocus(false); ui.repBox:SetMaxLetters(2)
    InputBox(ui.repBox, function(txt)
        local n = tonumber(txt)
        if n and n >= 1 and n <= 99 then WS.db.settings.maxRepeat = math.floor(n) return true end
        return false, "Max each: type a number from 1 to 99."
    end, function(txt) local n = tonumber(txt); return n ~= nil and n >= 1 and n <= 99 end)
    Tip(ui.repBox, "Max each", { "Best value / Fill budget may fill the same crate up to this many times (with Held crates ticked: as many as you hold)." })
    local build = C(Btn(win, "Build list", 100, Guarded(function() WS.Slash("build") end)))
    build:SetPoint("BOTTOMRIGHT", -PAD, 64)
    Tip(build, "Build list", { "Each selected crate takes its cheapest fill (after what you already have) and the materials are added up into one shopping list.", "Starts a new buying run." })
    ui.selInfo = C(win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
    ui.selInfo:SetPoint("BOTTOMLEFT", PAD, 42)
    if ui.selInfo.SetWidth then ui.selInfo:SetWidth(W - 2 * PAD - 100); ui.selInfo:SetJustifyH("LEFT") end
    ui.scanBtn = C(Btn(win, "Scan crates", 90, function() WS.Buyer.ScanCrates(IsShiftKeyDown and IsShiftKeyDown()) end))
    ui.scanBtn:SetPoint("BOTTOMRIGHT", -PAD, 36)
    Tip(ui.scanBtn, "Scan crates (at the AH)", { "Searches each empty crate (the list's, the selected ones and every crate passing the filters; Shift-click: all 30) and records how many are listed and at what prices.",
        "Auctionator only keeps one price, not the quantity. With this, Best value / Fill budget / Cheapest / Build list never plan more crates than are for sale and price each one from the real listings. The AH column shows the count (? = not scanned, grey = older than 30 min)." })
    local help = C(win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"))
    help:SetPoint("BOTTOMLEFT", PAD, 14)
    help:SetWidth(W - 2 * PAD)
    help:SetJustifyH("LEFT")
    help:SetText("+c = includes buying the empty crate. One listed bundle fills a crate. Cost = cheapest bundle at Auctionator's last scan (* = older than 3 days; ~ = estimated Favor; red = over your per-Favor limit). /wl help")

    -- list footer
    ui.summary = Lo(win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
    ui.summary:SetPoint("TOPLEFT", PAD, -(TITLE_H + 40))
    ui.summary:SetWidth(W - 2 * PAD); ui.summary:SetJustifyH("LEFT")
    ui.warn = Lo(win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
    ui.warn:SetPoint("TOPLEFT", PAD, -(TITLE_H + 58))
    ui.warn:SetWidth(W - 2 * PAD); ui.warn:SetJustifyH("LEFT")
    ui.totalFS = Lo(win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
    ui.totalFS:SetPoint("BOTTOMLEFT", PAD, 76)
    local blabel = Lo(win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
    blabel:SetPoint("BOTTOMRIGHT", -PAD - 90, 76)
    blabel:SetText("Budget:")
    ui.budgetBox = Lo(CreateFrame("EditBox", nil, win, "InputBoxTemplate"))
    ui.budgetBox:SetSize(80, 18); ui.budgetBox:SetPoint("LEFT", blabel, "RIGHT", 8, 0); ui.budgetBox:SetAutoFocus(false); ui.budgetBox:SetMaxLetters(16)
    InputBox(ui.budgetBox, function(txt)
        local c, msg = ReadMoney(txt, "Budget")
        if not c then return false, msg end
        WS.db.budget = c; return true
    end, MoneyOk)
    Tip(ui.budgetBox, "Budget", { "Total gold for this buying run (e.g. 50g). Buy Next never goes past it. Empty = no budget." })
    ui.status = Lo(win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
    ui.status:SetPoint("BOTTOMLEFT", PAD, 44)
    ui.status:SetWidth(W - 2 * PAD - 80)
    ui.replanBtn = Lo(Btn(win, "Replan", 72, Guarded(function() WS.Slash("replan") end)))
    ui.replanBtn:SetPoint("BOTTOMRIGHT", -PAD, 38)
    Tip(ui.replanBtn, "Replan", { "Rebuild the list with what the AH has: crates that are not listed (or not enough) drop out and, if the list came from Best value / Fill budget / Cheapest, that pick runs again so the money goes to the next best fills.",
        "What you bought this run (in bags or still in the mail) counts as yours; spent gold stays on the budget." })
    ui.status:SetJustifyH("LEFT")
    ui.buyBtn = Lo(Btn(win, "Search", 150, Guarded(function() WS.Buyer.Click() end)))
    ui.buyBtn:SetPoint("BOTTOMLEFT", PAD, 12)
    Tip(ui.buyBtn, "Search / Buy (at the Auction House)", { "Search: looks up the next item (waits for the AH if it is busy; re-uses results from the last 30s). The status line then shows exactly what the next click buys.",
        "Materials: next click asks the server for a quote, then a Confirm click buys.", "Never above the item's max price or your per-Favor limit, never more than you still need, never past the budget." })
    local skip = Lo(Btn(win, "Skip", 60, function() WS.Buyer.Skip() end))
    skip:SetPoint("LEFT", ui.buyBtn, "RIGHT", 4, 0)
    local exp = Lo(Btn(win, "Auctionator list", 120, function() WS.Export() end))
    exp:SetPoint("LEFT", skip, "RIGHT", 12, 0)
    Tip(exp, "Export", { "Writes (or replaces) an Auctionator shopping list named \"" .. WS.LIST_NAME .. "\" with what is left to buy." })
    local txt = Lo(Btn(win, "Copy text", 80, function() WS.ShowText(WS.ListText()) end))
    txt:SetPoint("LEFT", exp, "RIGHT", 4, 0)
    local chk = Lo(Btn(win, "Bags check", 85, function() WS.Check.Run(true) end))
    chk:SetPoint("LEFT", txt, "RIGHT", 4, 0)
    Tip(chk, "Bags check", { "Is everything to fill your planned crates (empty crates + one bundle each) in your BAGS? Bank and alts do not count; it tells you what to withdraw.",
        "Runs only when you click it (or type /wl check)." })
    local rst = Lo(Btn(win, "Reset run", 80, function() WS.ResetRun(); WS.RefreshUI() end))
    rst:SetPoint("BOTTOMRIGHT", -PAD, 12)
    Tip(rst, "Reset run", { "Clears spent gold, bought counts and skips for this list." })

    if UISpecialFrames then tinsert(UISpecialFrames, "WaylaidShopperFrame") end
    win:Hide()
end
