-- Gold Forge: the investment scanner.
-- Finds items trading well below their normal price that should sell higher later, for example
-- before a raid opens. "Normal" is TSM's 60-day historical price on this auction house (falls back
-- to the region average). Gold Forge's own 7-day price history adds a short-term trend.
-- It only reads the auction house; every purchase is one click to start and one click to confirm.
local _, FF = ...
local Invest = { rows = {}, state = "Idle", done = 0, total = 0 }
FF.Invest = Invest

local function day(y, m, d) return time({ year = y, month = m, day = d, hour = 12 }) end

-- Themes: item groups with the event they're bought for and when to sell.
-- Dates and notes come from your market research of 23 Nov 2026 (wow.gg, PvP Horde EU).
-- Rune Thread and Elemental Flux are left out: vendors sell them, so their price can't rise much.
Invest.Themes = {
  { key = "tier", name = "Tier set materials",
    event = "Hyjal Summit & Barrow Deeps open", eventAt = day(2026, 12, 9),
    sellFrom = day(2026, 12, 10), sellPeak = day(2026, 12, 14), sellTo = day(2027, 1, 5),
    why = "Tier recipes cost Malleable Essence of Nature, which only drops in the new raids, so nobody can craft tier before 9 Dec. "
      .. "The cheap materials are only 1-3% of a craft's cost, so crafters keep buying even if their price doubles. "
      .. "Demand builds slowly (players need Essence and Friendly with Guardians of Hyjal first).",
    items = {
      { 248825, "Leatherworking tier, 4 classes; used in 52 recipes" },
      { 251291, "Blacksmithing tier; used in 42 recipes" },
      { 14048, "Tailoring tier; lots on the market" },
      { 14047, "Makes Bolts of Runecloth; low risk, low gain" },
      { 12360, "Blacksmithing tier; expensive, buy only a little" },
      { 14342, "Tailoring tier; most of the craft cost" },
      { 15407, "Leatherworking tier; most of the craft cost" },
    } },
  { key = "raid", name = "Raid consumables",
    event = "Raid week", eventAt = day(2026, 12, 9),
    sellFrom = day(2026, 12, 7), sellPeak = day(2026, 12, 9), sellTo = day(2026, 12, 16),
    why = "Raiders stock up on flasks, potions, protection potions and food in the days before a new raid opens.",
    items = {
      { 13510 }, { 13511 }, { 13512 }, { 13513 }, { 13444 }, { 13446 }, { 13452 }, { 9206 }, { 13454 },
      { 13457, "Fire protection" }, { 13456, "Frost protection" }, { 13458, "Nature protection" }, { 13459, "Shadow protection" },
      { 3387 }, { 9088 }, { 12820 }, { 20452 }, { 12404 }, { 13468, "Black Market NPC caps it at 50g" }, { 8846 },
    } },
  { key = "ench", name = "Enchanting & crafting materials",
    why = "Materials for enchants and crafted gear. No fixed date: buy when they're cheap, sell when they're back to normal.",
    items = {
      { 16203 }, { 14344 }, { 12363 }, { 12359 }, { 12808 }, { 7076 }, { 7078 }, { 7080 }, { 7082 }, { 15416 }, { 18512 },
    } },
}

function Invest.Theme(key)
  for _, t in ipairs(Invest.Themes) do if t.key == key then return t end end
end

-- everything the scanner can look at: themes, the browse categories, your lists
function Invest.Scopes()
  local out = {}
  for _, t in ipairs(Invest.Themes) do table.insert(out, { text = "Theme: " .. t.name, value = "theme:" .. t.key }) end
  for _, key in ipairs({ "materials", "consumables" }) do
    local g = FF.Sniper.Group(key)
    table.insert(out, { text = "Whole AH: " .. g.name, value = "cat:" .. key })
  end
  for _, l in ipairs(FF.db.lists or {}) do
    table.insert(out, { text = "List: " .. l.name .. " (" .. FF.Lists.Count(l) .. ")", value = "list:" .. l.id })
  end
  return out
end

function Invest.ScopeName(v)
  for _, o in ipairs(Invest.Scopes()) do if o.value == v then return o.text end end
  return Invest.Scopes()[1].text
end

-- the theme a scope (or an item) belongs to
local function themeOf(scope, itemID)
  local key = scope and scope:match("^theme:(.+)$")
  if key then return Invest.Theme(key) end
  for _, t in ipairs(Invest.Themes) do
    for _, it in ipairs(t.items) do if it[1] == itemID then return t end end
  end
end

local function noteOf(theme, itemID)
  if not theme then return nil end
  for _, it in ipairs(theme.items) do if it[1] == itemID then return it[2] end end
end

-- Judge one item. now = cheapest price on the AH right now, ladder = the full price list (or nil).
-- Fills in the row: normal price, how far below it we are, a buy plan and a verdict.
function Invest.Evaluate(row, now, ladder)
  local cfg = FF.db.invest
  local id = row.itemID
  local s = FF.Stats(id)
  row.now = now or s.minBuyout
  row.normal = s.historical or s.region or s.realm
  row.region, row.market, row.soldPerDay, row.numAuctions = s.region, s.realm, s.soldPerDay, s.numAuctions
  row.trend = FF.History.Change(id)
  if not row.now or not row.normal or row.normal <= 0 then
    row.verdict, row.why = "nodata", "TSM has no price history for this item yet, or nobody is selling it."
    return row
  end
  row.vs = row.now / row.normal - 1
  -- what we expect to resell at: back to normal, but never more than a vendor charges for it
  local target = row.normal
  local vendorBuy = FF.Raw("vendorBuy", id)
  if vendorBuy and vendorBuy > 0 and vendorBuy < target then target = vendorBuy end
  row.target = target

  -- buy plan: listings at or below max % of normal, within the budget and a few days of sales
  local maxPrice = row.normal * cfg.maxBuyPct / 100
  local cap = math.max(1, math.floor((row.soldPerDay or 0) * cfg.holdDays))
  local qty, cost, top = 0, 0, nil
  for _, l in ipairs(ladder or { { price = row.now, qty = cap } }) do
    if l.price > maxPrice then break end
    local take = math.min(l.qty, cap - qty, math.floor((cfg.budget - cost) / l.price))
    if take <= 0 then break end
    qty, cost, top = qty + take, cost + take * l.price, l.price
    if take < l.qty then break end
  end
  row.buy, row.cost, row.top = qty, cost, top
  row.deposit = qty > 0 and FF.Sniper.Deposit(id, qty, true) or 0
  row.profit = qty > 0 and (qty * target * (1 - FF.Sniper.Cut()) - cost - row.deposit) or nil
  row.onAH = 0
  for _, l in ipairs(ladder or {}) do row.onAH = row.onAH + l.qty end
  if not ladder then row.onAH = nil end

  -- verdict
  if row.vs * 100 >= cfg.risenPct then
    row.verdict, row.why = "risen", string.format("Already %d%% above its normal price: the rise has happened, don't buy now.", row.vs * 100 + 0.5)
  elseif (row.soldPerDay or 0) < cfg.minSold then
    row.verdict, row.why = "slow", string.format("Sells only %.1f a day in the region: hard to sell again.", row.soldPerDay or 0)
  elseif -row.vs * 100 >= cfg.minDiscount and qty > 0 and (row.profit or 0) > 0 then
    row.verdict, row.why = "buy", string.format("%d%% below its normal price and sells %d a day.", -row.vs * 100 + 0.5, row.soldPerDay or 0)
  elseif -row.vs * 100 >= cfg.minDiscount then
    row.verdict, row.why = "watch", "Cheap, but nothing fits your budget or max % of normal at the moment."
  else
    row.verdict, row.why = "fair", "Near its normal price: no discount to buy into right now."
  end
  if row.trend and row.trend < -0.1 and row.verdict == "buy" then
    row.why = row.why .. string.format(" Still falling (%d%% in your 7-day history): you could wait a little.", row.trend * 100)
  end
  return row
end

local runID = 0
local function changed() FF:Fire("FF_INVEST_CHANGED") end

local function newRow(itemID, scope)
  local theme = themeOf(scope, itemID)
  return {
    itemID = itemID, name = C_Item.GetItemNameByID(itemID) or ("Item " .. itemID),
    quality = select(3, C_Item.GetItemInfo(itemID)), theme = theme, note = noteOf(theme, itemID),
    verdict = "checking",
  }
end

local function stepDone(my)
  if my ~= runID then return end
  Invest.done = Invest.done + 1
  if Invest.done >= Invest.total then
    Invest.state = "Done"
    local n = 0
    for _, r in ipairs(Invest.rows) do if r.verdict == "buy" then n = n + 1 end end
    FF.Log(string.format("invest scan %s: %d items, %d to buy", FF.db.invest.scope, #Invest.rows, n))
  end
  changed()
end

-- look up the price list of each row, one at a time (the scan queue keeps it slow and polite)
local function priceRows(my)
  Invest.total = #Invest.rows
  Invest.done = 0
  if Invest.total == 0 then Invest.state = "Done"; changed(); return end
  for _, row in ipairs(Invest.rows) do
    FF.History.Track(row.itemID)
    FF.Scan.Commodity(row.itemID, function(ladder)
      if my ~= runID then return end
      if ladder and ladder[1] then Invest.Evaluate(row, ladder[1].price, ladder)
      else
        Invest.Evaluate(row, nil, {})
        row.verdict, row.why, row.onAH = "nolist", "Nobody is selling it right now: nothing to buy.", 0
      end
      stepDone(my)
    end)
  end
  changed()
end

function Invest.Scan()
  if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then FF.Kit.status("Open the auction house first."); return end
  if not FF.HasTSM() then FF.Kit.status("TSM isn't loaded: the investment scanner needs its price history."); return end
  runID = runID + 1
  local my, scope = runID, FF.db.invest.scope
  Invest.rows, Invest.state, Invest.done, Invest.total = {}, "Scanning", 0, 0
  local kind, arg = scope:match("^(%a+):(.+)$")
  if kind == "theme" then
    local t = Invest.Theme(arg) or Invest.Themes[1]
    for _, it in ipairs(t.items) do table.insert(Invest.rows, newRow(it[1], scope)) end
    priceRows(my)
  elseif kind == "list" then
    for _, id in ipairs(FF.Lists.ItemIDs(tonumber(arg))) do
      local stack = select(8, C_Item.GetItemInfo(id))
      if not stack or stack > 1 then table.insert(Invest.rows, newRow(id, scope)) end  -- stackables only
    end
    priceRows(my)
  else
    -- a whole category: one quick browse, then the price list only for the cheapest-looking items
    Invest.state = "Browsing"
    changed()
    FF.Scan.Browse(FF.Sniper.Group(arg).filters, function(results)
      if my ~= runID then return end
      local cfg, cands = FF.db.invest, {}
      for _, r in ipairs(results or {}) do
        local key = r.itemKey
        local info = key and C_AuctionHouse.GetItemKeyInfo(key)
        if key and r.minPrice and (not info or info.isCommodity) then
          local row = Invest.Evaluate(newRow(key.itemID, scope), r.minPrice, nil)
          if row.vs and -row.vs * 100 >= cfg.minDiscount and (row.soldPerDay or 0) >= cfg.minSold then
            table.insert(cands, row)
          end
        end
      end
      table.sort(cands, function(a, b) return a.vs < b.vs end)
      for i = 1, math.min(#cands, 30) do cands[i].verdict = "checking"; table.insert(Invest.rows, cands[i]) end
      Invest.state = "Checking prices"
      FF.Log(string.format("invest browse: %d items, %d cheap enough to check", #(results or {}), #cands))
      priceRows(my)
    end)
  end
  changed()
end

function Invest.Stop() runID = runID + 1; Invest.state = "Stopped"; changed() end
FF:On("AUCTION_HOUSE_CLOSED", function() if Invest.state ~= "Done" and Invest.state ~= "Idle" then Invest.Stop() end end)

-- days from now to a date, for "in 16 days"
local function inDays(t)
  local d = math.floor((t - time()) / 86400 + 0.5)
  if d > 1 then return "in " .. d .. " days" elseif d == 1 then return "tomorrow" elseif d == 0 then return "today" end
  return (-d) .. " days ago"
end
local function dateText(t) return date("%d %b", t) end

-- one line about the theme's timing: when to sell
function Invest.Timing(t)
  if not t or not t.eventAt then return nil end
  local now = time()
  local when
  if now < t.sellFrom then
    when = string.format("Buy now, sell from %s (%s)", dateText(t.sellFrom), inDays(t.sellFrom))
  elseif now <= t.sellTo then
    when = string.format("|cff58c27dSell now|r: %s to %s", dateText(t.sellPeak or t.sellFrom), dateText(t.sellTo))
  else
    when = "The selling window is over"
  end
  return string.format("%s %s (%s)  ·  %s", t.event, dateText(t.eventAt), inDays(t.eventAt), when)
end

-- ---------- page ----------
local VERDICT = {
  buy = { "Buy", "green" }, watch = { "Watch", "gold" }, fair = { "Fair price", "muted" },
  risen = { "Already up", "red" }, slow = { "Sells slowly", "muted" }, nodata = { "No data", "dim" }, nolist = { "None on AH", "dim" }, checking = { "…", "dim" },
}

FF.UI.RegisterPage("invest", function(parent)
  local K = FF.Kit
  local COL, text, box, button = K.COL, K.text, K.box, K.flatButton
  local cfg = function() return FF.db.invest end
  local page = CreateFrame("Frame", nil, parent)
  page:SetAllPoints()
  local title = text(page, 18, COL.text); title:SetPoint("TOPLEFT", 20, -16); title:SetText("Investments")
  local sub = text(page, 11, COL.muted); sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -5)
  sub:SetText("Items trading below their normal (60-day) price that should sell higher later, e.g. before a raid.")

  -- controls
  local card = box(page, COL.card, COL.line)
  card:SetPoint("TOPLEFT", 20, -62); card:SetPoint("RIGHT", -20, 0); card:SetHeight(54)
  local scope = K.dropdown(card, 290, Invest.Scopes, function() return Invest.ScopeName(cfg().scope) end, nil,
    function(v) cfg().scope = v; Invest.rows = {}; Invest.state = "Idle"; page:Refresh() end)
  scope:SetPoint("LEFT", 14, 0)
  local go = button(card, "Scan", 96, 28, "primary", function()
    if Invest.state == "Scanning" or Invest.state == "Browsing" or Invest.state == "Checking prices" then Invest.Stop() else Invest.Scan() end
  end)
  go:SetPoint("LEFT", scope, "RIGHT", 12, 0)
  local only = K.checkbox(card, "Only buys", function() return cfg().onlyBuys end, function(v) cfg().onlyBuys = v; page:Refresh() end)
  only:SetPoint("LEFT", go, "RIGHT", 16, 0)
  local prog = text(card, 11, COL.muted); prog:SetPoint("RIGHT", -14, 0); prog:SetJustifyH("RIGHT")

  -- the theme's timing and reasoning
  local banner = box(page, COL.card, COL.line)
  banner:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -10); banner:SetPoint("RIGHT", -20, 0); banner:SetHeight(46)
  local bLine = text(banner, 12, COL.text); bLine:SetPoint("TOPLEFT", 14, -9); bLine:SetPoint("RIGHT", -14, 0); bLine:SetJustifyH("LEFT")
  local bWhy = text(banner, 10, COL.muted); bWhy:SetPoint("TOPLEFT", bLine, "BOTTOMLEFT", 0, -4); bWhy:SetPoint("RIGHT", -14, 0)
  bWhy:SetJustifyH("LEFT"); bWhy:SetWordWrap(false)
  banner:SetScript("OnEnter", function(s)
    local t = themeOf(cfg().scope)
    if not t then return end
    GameTooltip:SetOwner(s, "ANCHOR_BOTTOM"); GameTooltip:SetText(t.name, 1, 1, 1)
    GameTooltip:AddLine(t.why, nil, nil, nil, true); GameTooltip:Show()
  end)
  banner:SetScript("OnLeave", GameTooltip_Hide)

  -- settings
  local set = box(page, COL.card, COL.line)
  set:SetPoint("TOPLEFT", banner, "BOTTOMLEFT", 0, -10); set:SetPoint("RIGHT", -20, 0); set:SetHeight(66)
  local FIELDS = {
    { "Min discount %", "minDiscount", nil, "Buy only when the price is at least this much below its normal (60-day) price." },
    { "Pay up to % of normal", "maxBuyPct", nil, "The buy plan takes listings up to this % of the normal price." },
    { "Min sold/day", "minSold", nil, "Units sold per day in the region. Slow items are hard to sell again." },
    { "Budget per item (g)", "budget", 10000, "The most the buy plan spends on one item." },
    { "Days of sales", "holdDays", nil, "Buy at most this many days of region sales, so you can sell it all again." },
    { "Already up %", "risenPct", nil, "Items this far above normal have already risen: flagged as 'Already up'." },
  }
  local fields = {}
  for i, f in ipairs(FIELDS) do
    local nf = K.numberField(set, f[1], cfg, f[2], f[3], f[4])
    nf:SetWidth(118); nf.eb:SetWidth(104)
    nf:SetPoint("TOPLEFT", 14 + (i - 1) * 124, -8)
    fields[i] = nf
  end

  -- table
  local list = box(page, COL.card, COL.line)
  list:SetPoint("TOPLEFT", set, "BOTTOMLEFT", 0, -10); list:SetPoint("BOTTOMRIGHT", -20, 34)
  local COLS = {
    { "Item", 0, "LEFT" }, { "Now", 78 }, { "Normal", 78 }, { "Vs normal", 66 }, { "Sold/day", 58 },
    { "Buy", 46 }, { "Profit", 78 }, { "Verdict", 86 },
  }
  local BTN = 100
  local heads = {}
  for i, c in ipairs(COLS) do
    local h = text(list, 10, COL.muted, nil, true); h:SetText(c[1]:upper()); h:SetJustifyH(c[3] or "RIGHT")
    heads[i] = h
  end
  local scroll = CreateFrame("ScrollFrame", nil, list)
  scroll:SetPoint("TOPLEFT", 1, -30); scroll:SetPoint("BOTTOMRIGHT", -1, 4)
  local content = CreateFrame("Frame", nil, scroll); content:SetSize(1, 1)
  scroll:SetScrollChild(content)
  scroll:SetScript("OnSizeChanged", function(s, w) content:SetWidth(w) end)
  K.scrollbar(scroll, content)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(s, delta)
    local max = math.max(0, content:GetHeight() - s:GetHeight())
    s:SetVerticalScroll(math.min(max, math.max(0, s:GetVerticalScroll() - delta * K.ROW_H * 2)))
  end)
  local empty = text(list, 12, COL.dim); empty:SetPoint("CENTER", scroll, "CENTER")
  local function colX(width)
    local fixed, out = 0, {}
    for i = 2, #COLS do fixed = fixed + COLS[i][2] end
    local x = 14
    for i, c in ipairs(COLS) do
      local w = i == 1 and math.max(150, width - 28 - fixed - BTN) or c[2]
      out[i] = { x = x, w = w }
      x = x + w
    end
    return out
  end

  local function pct(v) return v and string.format("%+d%%", v * 100 + (v >= 0 and 0.5 or -0.5)) or "-" end
  local function buyLabel(d)
    if d.state == "starting" or d.state == "buying" then return "…", "ghost" end
    if d.state == "confirm" then return "Confirm", "primary" end
    if d.state == "bought" then return "Bought", "ghost" end
    if d.state == "failed" then return "Failed", "ghost" end
    return "Buy " .. (d.buy or 0), d.verdict == "buy" and "primary" or "ghost"
  end

  local rows, expanded = {}, {}
  local function row(i)
    if rows[i] then return rows[i] end
    local r = CreateFrame("Button", nil, content)
    r.hl = r:CreateTexture(nil, "BACKGROUND"); r.hl:SetColorTexture(1, 1, 1, 0.035); r.hl:Hide()
    r.hl:SetPoint("TOPLEFT"); r.hl:SetPoint("TOPRIGHT"); r.hl:SetHeight(K.ROW_H)
    r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(22, 22); r.icon:SetPoint("TOPLEFT", 13, -4)
    r.cells = {}
    for c = 1, #COLS do
      r.cells[c] = text(r, 12, COL.text, nil, c == 7)
      r.cells[c]:SetJustifyH(COLS[c][3] or "RIGHT")
    end
    r.detail = text(r, 11, COL.muted, nil, false); r.detail:SetJustifyH("LEFT"); r.detail:SetWordWrap(true)
    -- ONE purchase per click: Buy asks the server for the total, then Confirm buys (Blizzard's rule)
    r.buy = button(r, "Buy", 90, 22, "ghost", function()
      local d = r.data
      if not d or not d.buy or d.buy <= 0 or d.state == "bought" or d.state == "buying" or d.state == "starting" then return end
      FF.UI.BuyCommodity(d)
      page:Refresh()
    end)
    r.buy:SetPoint("TOPRIGHT", -12, -4)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r:SetScript("OnClick", function(s, mouse)
      if mouse == "RightButton" then FF.History.Open(s.data.itemID); return end
      expanded[s.data.itemID] = not expanded[s.data.itemID]; page:Refresh()
    end)
    r:SetScript("OnEnter", function(s)
      s.hl:Show()
      local d = s.data
      GameTooltip:SetOwner(s, "ANCHOR_RIGHT"); GameTooltip:SetItemByID(d.itemID)
      if d.why then GameTooltip:AddLine(" "); GameTooltip:AddLine(d.why, 0.95, 0.72, 0.11, true) end
      if d.note then GameTooltip:AddLine(d.note, 0.8, 0.8, 0.85, true) end
      GameTooltip:AddLine("Click: details · Right-click: price history", 0.56, 0.56, 0.6); GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function(s) s.hl:Hide(); GameTooltip:Hide() end)
    rows[i] = r
    return r
  end

  local ORDER = { buy = 1, watch = 2, checking = 3, fair = 4, slow = 5, risen = 6, nolist = 7, nodata = 8 }

  function page:Refresh()
    if page:GetWidth() < 10 then return end
    scope:Refresh(); only:Refresh()
    for _, f in ipairs(fields) do f.Refresh() end
    local busy = Invest.state == "Scanning" or Invest.state == "Browsing" or Invest.state == "Checking prices"
    go:SetLabel(busy and "Stop" or "Scan")
    prog:SetText(busy and string.format("%s  %d / %d", Invest.state, Invest.done, Invest.total)
      or (Invest.state == "Done" and string.format("%d items checked", #Invest.rows) or ""))

    local t = themeOf(cfg().scope)
    if t and t.eventAt then
      bLine:SetText(Invest.Timing(t)); bWhy:SetText(t.why .. "  (hover for more)")
    elseif t then
      bLine:SetText(t.name .. ": no fixed date"); bWhy:SetText(t.why)
    else
      bLine:SetText("Normal price = TSM's 60-day historical price on this auction house (region average when there's none).")
      bWhy:SetText("Profit assumes you resell at the normal price, after the AH cut and the deposit. Prices can stay low for longer than you expect.")
    end

    local width = scroll:GetWidth()
    local cx = colX(width)
    for i, h in ipairs(heads) do
      h:ClearAllPoints(); h:SetPoint("TOPLEFT", cx[i].x + (i == 1 and 30 or 0), -12); h:SetWidth(cx[i].w - 6 - (i == 1 and 30 or 0))
    end
    local shown = {}
    for _, d in ipairs(Invest.rows) do
      if not cfg().onlyBuys or d.verdict == "buy" then table.insert(shown, d) end
    end
    table.sort(shown, function(a, b)
      local oa, ob = ORDER[a.verdict] or 9, ORDER[b.verdict] or 9
      if oa ~= ob then return oa < ob end
      if (a.profit or 0) ~= (b.profit or 0) then return (a.profit or 0) > (b.profit or 0) end
      return (a.vs or 0) < (b.vs or 0)
    end)
    local y = 0
    for i, d in ipairs(shown) do
      local r = row(i)
      r.data = d
      r:ClearAllPoints(); r:SetPoint("TOPLEFT", 0, -y); r:SetPoint("RIGHT", content, "RIGHT")
      r.icon:SetTexture(C_Item.GetItemIconByID(d.itemID))
      local name = FF.UI.ItemName(d) or "?"
      local v = VERDICT[d.verdict] or VERDICT.checking
      local vals = {
        FF.QualityColor(d.quality) .. name .. "|r",
        d.now and FF.Money(d.now) or "-", d.normal and FF.Money(d.normal) or "-", pct(d.vs),
        d.soldPerDay and string.format("%.0f", d.soldPerDay) or "-",
        (d.buy and d.buy > 0) and tostring(d.buy) or "-",
        d.profit and FF.Money(d.profit) or "-", v[1],
      }
      for c, fs in ipairs(r.cells) do
        fs:ClearAllPoints(); fs:SetPoint("TOPLEFT", cx[c].x + (c == 1 and 30 or 0), 0)
        fs:SetSize(cx[c].w - 6 - (c == 1 and 30 or 0), K.ROW_H); fs:SetText(vals[c])
      end
      r.cells[4]:SetTextColor(unpack(d.vs and (d.vs < 0 and COL.green or COL.red) or COL.dim))
      r.cells[7]:SetTextColor(unpack(d.profit and d.profit < 0 and COL.red or COL.green))
      r.cells[8]:SetTextColor(unpack(COL[v[2]] or COL.muted))
      local label, style = buyLabel(d)
      r.buy:SetLabel(label); r.buy:SetStyle(style)
      r.buy:SetShown(d.buy and d.buy > 0 or d.state ~= nil)
      local open = expanded[d.itemID]
      r.detail:SetShown(open)
      local h = K.ROW_H
      if open then
        local parts = {}
        table.insert(parts, string.format("|cfff2b81dPlan:|r buy %d up to %s each for %s, resell at %s each  ->  %s profit after %d%% AH cut and %s deposit",
          d.buy or 0, FF.Money(d.top), FF.Money(d.cost), FF.Money(d.target), FF.Money(d.profit),
          FF.Sniper.Cut() * 100, FF.Money(d.deposit)))
        table.insert(parts, string.format("Region average %s  ·  Market (recent) %s  ·  Your 7-day history %s  ·  On the AH %s%s",
          FF.Money(d.region), FF.Money(d.market), d.trend and pct(d.trend) or "not enough scans yet",
          d.onAH and tostring(d.onAH) or "-",
          (d.onAH and d.soldPerDay and d.soldPerDay > 0) and string.format(" (%.1f days of sales)", d.onAH / d.soldPerDay) or ""))
        if d.why then table.insert(parts, "|cff8e8e99" .. d.why .. (d.note and ("  " .. d.note) or "") .. "|r") end
        r.detail:ClearAllPoints(); r.detail:SetPoint("TOPLEFT", 44, -K.ROW_H); r.detail:SetWidth(width - 60)
        r.detail:SetText(table.concat(parts, "\n"))
        h = K.ROW_H + r.detail:GetStringHeight() + 10
      end
      r:SetHeight(h)
      r:Show()
      y = y + h
    end
    for i = #shown + 1, #rows do rows[i]:Hide() end
    content:SetHeight(math.max(1, y))
    empty:SetShown(#shown == 0)
    empty:SetText(#Invest.rows == 0 and "Pick a theme or category and press Scan (the auction house must be open)."
      or "Nothing to buy right now. Untick \"Only buys\" to see everything.")
  end
  FF:On("FF_INVEST_CHANGED", function() if page:IsShown() then page:Refresh() end end)
  page:SetScript("OnSizeChanged", function() if page:IsShown() then page:Refresh() end end)
  return page
end)
