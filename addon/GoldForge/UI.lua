-- Gold Forge: the window. Dark panels, a left menu, stat cards and a live list of deals.
-- Every purchase is a click (Blizzard requires one for buying): Buy, then Confirm for commodities;
-- for single auctions the first click refreshes the listing and each click after that buys one.
local _, FF = ...
local UI = {}
FF.UI = UI
local AH = C_AuctionHouse

-- ---------- look ----------
-- The forge palette: warm soot and anvil blacks, bronze edges, parchment text, one molten gold.
local COL = {
  bg = { 0.102, 0.094, 0.086, 0.97 },   -- soot     #1A1816  window
  side = { 0.071, 0.067, 0.063, 1 },    -- anvil    #121110  header and menu
  card = { 0.133, 0.122, 0.110, 1 },    -- slag     #221F1C  panels
  field = { 0.165, 0.149, 0.133, 1 },   --          #2A2622  inputs and buttons
  line = { 0.227, 0.204, 0.176, 1 },    -- bronze   #3A342D  borders
  line2 = { 0.302, 0.271, 0.231, 1 },   --          #4D453B  stronger borders
  text = { 0.929, 0.902, 0.855 },       -- parchment #EDE6DA
  muted = { 0.639, 0.604, 0.549 },      --          #A39A8C
  dim = { 0.431, 0.400, 0.357 },        --          #6E665B
  gold = { 0.910, 0.694, 0.227 },       -- molten gold #E8B13A
  goldText = { 0.12, 0.08, 0.02 },      -- text on gold
  green = { 0.42, 0.82, 0.48 }, red = { 0.94, 0.42, 0.38 },
}
-- Inter (SIL Open Font License, see Media/FONTS-LICENSE.txt); the game's font if it can't load
local FONT = "Interface\\AddOns\\GoldForge\\Media\\Inter-Regular.ttf"
local FONT_B = "Interface\\AddOns\\GoldForge\\Media\\Inter-SemiBold.ttf"
local FALLBACK = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
local W, H, SIDE, HEAD = 1120, 640, 176, 44      -- default size; the window can be resized
local MIN_W, MIN_H = 1000, 560
local ROW_H = 30

local function box(parent, bg, border, level)
  local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
  f:SetBackdropColor(unpack(bg or COL.card))
  f:SetBackdropBorderColor(unpack(border or COL.line))
  if level then f:SetFrameLevel(level) end
  return f
end

local function setFont(obj, size, flags, bold)
  if not obj:SetFont(bold and FONT_B or FONT, size or 12, flags or "") then obj:SetFont(FALLBACK, size or 12, flags or "") end
end

-- text: bold for headings (size 13+) unless told otherwise
local function text(parent, size, color, flags, bold)
  local fs = parent:CreateFontString(nil, "OVERLAY")
  if bold == nil then bold = (size or 12) >= 13 end
  setFont(fs, size, flags, bold)
  fs:SetTextColor(unpack(color or COL.text))
  fs:SetWordWrap(false)
  return fs
end

-- flat button: style "primary" (gold), "ghost" (outline) or "link"
local function flatButton(parent, label, w, h, style, onClick)
  local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
  b:SetSize(w or 100, h or 26)
  b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
  b.label = text(b, 12, style == "primary" and COL.goldText or COL.text)
  b.label:SetPoint("CENTER")
  b.label:SetText(label or "")
  function b:SetStyle(st)
    self.style = st
    if st == "primary" then
      self:SetBackdropColor(unpack(COL.gold)); self:SetBackdropBorderColor(unpack(COL.gold)); self.label:SetTextColor(unpack(COL.goldText))
    elseif st == "done" then
      self:SetBackdropColor(0, 0, 0, 0); self:SetBackdropBorderColor(0, 0, 0, 0); self.label:SetTextColor(unpack(COL.green))
    elseif st == "bad" then
      self:SetBackdropColor(0, 0, 0, 0); self:SetBackdropBorderColor(0, 0, 0, 0); self.label:SetTextColor(unpack(COL.red))
    else
      self:SetBackdropColor(unpack(COL.field)); self:SetBackdropBorderColor(unpack(COL.line2)); self.label:SetTextColor(unpack(COL.text))
    end
  end
  b:SetStyle(style)
  b:SetScript("OnEnter", function(self) if self:IsEnabled() and self.style ~= "done" then self:SetBackdropBorderColor(unpack(COL.gold)) end end)
  b:SetScript("OnLeave", function(self) self:SetStyle(self.style) end)
  b:SetScript("OnClick", onClick)
  function b:SetLabel(t) self.label:SetText(t) end
  return b
end

local function pill(parent, label, color)
  local p = box(parent, { 0, 0, 0, 0 }, COL.line2)
  p.label = text(p, 11, color or COL.muted)
  p.label:SetPoint("CENTER")
  function p:Set(t, c)
    self.label:SetText(t)
    if c then self.label:SetTextColor(unpack(c)); self:SetBackdropBorderColor(c[1] * 0.6, c[2] * 0.6, c[3] * 0.6, 1) end
    self:SetSize(self.label:GetStringWidth() + 18, 20)
  end
  p:Set(label, color)
  return p
end

local function checkbox(parent, label, get, set)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(20, 20)
  b.box = box(b, COL.field, COL.line2)
  b.box:SetAllPoints()
  b.mark = b.box:CreateTexture(nil, "OVERLAY")
  b.mark:SetPoint("TOPLEFT", 3, -3); b.mark:SetPoint("BOTTOMRIGHT", -3, 3)
  b.mark:SetColorTexture(unpack(COL.gold))
  b.label = text(b, 12, COL.text)
  b.label:SetPoint("LEFT", b, "RIGHT", 8, 0)
  b.label:SetText(label)
  b:SetHitRectInsets(0, -(b.label:GetStringWidth() + 10), 0, 0)
  function b:Refresh() self.mark:SetShown(get()) end
  b:SetScript("OnClick", function(self) set(not get()); self:Refresh() end)
  b:Refresh()
  return b
end

-- a dropdown field: shows the current choice, opens a list of choices
local catcher
local function dropdown(parent, w, getChoices, getText, getRight, onPick)
  local d = flatButton(parent, "", w, 28, "ghost")
  d.label:ClearAllPoints(); d.label:SetPoint("LEFT", 10, 0); d.label:SetJustifyH("LEFT")
  d.right = text(d, 11, COL.muted); d.right:SetPoint("RIGHT", -24, 0)
  d.arrow = text(d, 12, COL.gold); d.arrow:SetPoint("RIGHT", -9, 0); d.arrow:SetText("v")
  function d:Refresh() self.label:SetText(getText()); self.right:SetText(getRight and getRight() or "") end
  d:SetScript("OnClick", function(self)
    if not catcher then
      catcher = CreateFrame("Button", nil, UIParent)
      catcher:SetAllPoints(UIParent); catcher:SetFrameStrata("FULLSCREEN_DIALOG")
      catcher:SetScript("OnClick", function(c) c:Hide() end)
      catcher.list = box(catcher, COL.card, COL.line2)
      catcher.items = {}
    end
    local choices = getChoices()
    local l = catcher.list
    l:ClearAllPoints(); l:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2); l:SetSize(self:GetWidth(), #choices * 26 + 8)
    for i, ch in ipairs(choices) do
      local it = catcher.items[i]
      if not it then
        it = CreateFrame("Button", nil, l)
        it:SetHeight(26)
        it.hl = it:CreateTexture(nil, "BACKGROUND"); it.hl:SetAllPoints(); it.hl:SetColorTexture(1, 1, 1, 0.06); it.hl:Hide()
        it.t = text(it, 12, COL.text); it.t:SetPoint("LEFT", 10, 0)
        it:SetScript("OnEnter", function(s) s.hl:Show() end)
        it:SetScript("OnLeave", function(s) s.hl:Hide() end)
        catcher.items[i] = it
      end
      it:SetParent(l); it:ClearAllPoints()
      it:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 26); it:SetPoint("RIGHT", -4, 0)
      it.t:SetText(ch.text)
      it:SetScript("OnClick", function() catcher:Hide(); onPick(ch.value); d:Refresh() end)
      it:Show()
    end
    for i = #choices + 1, #catcher.items do catcher.items[i]:Hide() end
    catcher:Show()
  end)
  d:Refresh()
  return d
end

-- A slim scrollbar for a scroll frame: shows there's more below, and the thumb can be dragged.
-- Hidden when everything fits.
local function scrollbar(scroll, content)
  local track = CreateFrame("Frame", nil, scroll:GetParent())
  track:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", -2, -2); track:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", -2, 2)
  track:SetWidth(5); track:SetFrameLevel(scroll:GetFrameLevel() + 5)
  local bg = track:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetColorTexture(1, 1, 1, 0.05)
  local thumb = CreateFrame("Frame", nil, track); thumb:SetWidth(5); thumb:EnableMouse(true)
  local tt = thumb:CreateTexture(nil, "ARTWORK"); tt:SetAllPoints(); tt:SetColorTexture(unpack(COL.line2))
  local function update()
    local view, total = scroll:GetHeight(), content:GetHeight()
    if total <= view + 1 or view <= 0 then track:Hide(); return end
    track:Show()
    local th = math.max(24, track:GetHeight() * view / total)
    local max = total - view
    local pos = max > 0 and scroll:GetVerticalScroll() / max or 0
    thumb:SetHeight(th)
    thumb:ClearAllPoints(); thumb:SetPoint("TOP", track, "TOP", 0, -(track:GetHeight() - th) * pos)
  end
  thumb:SetScript("OnEnter", function() tt:SetColorTexture(unpack(COL.gold)) end)
  thumb:SetScript("OnLeave", function() if not thumb.drag then tt:SetColorTexture(unpack(COL.line2)) end end)
  thumb:SetScript("OnMouseDown", function()
    local _, startY = GetCursorPosition()
    local startScroll, scale = scroll:GetVerticalScroll(), track:GetEffectiveScale()
    thumb.drag = true
    thumb:SetScript("OnUpdate", function()
      local _, y = GetCursorPosition()
      local max = content:GetHeight() - scroll:GetHeight()
      local per = max / math.max(1, track:GetHeight() - thumb:GetHeight())
      scroll:SetVerticalScroll(math.min(max, math.max(0, startScroll + (startY - y) / scale * per)))
      update()
    end)
  end)
  thumb:SetScript("OnMouseUp", function()
    thumb.drag = nil; thumb:SetScript("OnUpdate", nil); tt:SetColorTexture(unpack(COL.line2))
  end)
  scroll:HookScript("OnVerticalScroll", update)
  scroll:HookScript("OnSizeChanged", update)
  content:HookScript("OnSizeChanged", update)
  track:Hide()
  return track
end

-- a text field with a grey placeholder
local function input(parent, w, placeholder)
  local eb = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
  eb:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
  eb:SetBackdropColor(unpack(COL.field)); eb:SetBackdropBorderColor(unpack(COL.line2))
  eb:SetSize(w or 200, 26)
  setFont(eb, 12, ""); eb:SetTextColor(unpack(COL.text)); eb:SetTextInsets(8, 8, 0, 0); eb:SetAutoFocus(false)
  eb.hint = text(eb, 11, COL.dim); eb.hint:SetPoint("LEFT", 8, 0); eb.hint:SetText(placeholder or "")
  eb:HookScript("OnTextChanged", function(s) s.hint:SetShown(s:GetText() == "") end)
  eb:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
  eb:HookScript("OnEditFocusGained", function(s) s:SetBackdropBorderColor(unpack(COL.gold)) end)
  eb:HookScript("OnEditFocusLost", function(s) s:SetBackdropBorderColor(unpack(COL.line2)) end)
  return eb
end

-- number field for the rules page; `scale` converts stored copper to gold
local function numberField(parent, caption, cfg, key, scale, tip)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(180, 50)
  local cap = text(f, 11, COL.muted); cap:SetPoint("TOPLEFT"); cap:SetText(caption)
  local eb = CreateFrame("EditBox", nil, f, "BackdropTemplate")
  eb:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
  eb:SetBackdropColor(unpack(COL.field)); eb:SetBackdropBorderColor(unpack(COL.line2))
  eb:SetSize(164, 26); eb:SetPoint("TOPLEFT", cap, "BOTTOMLEFT", 0, -5)
  setFont(eb, 12, ""); eb:SetTextColor(unpack(COL.text)); eb:SetTextInsets(8, 8, 0, 0); eb:SetAutoFocus(false)
  local function show() local v = cfg()[key]; eb:SetText(scale and tostring(v / scale) or tostring(v)); eb:SetCursorPosition(0) end
  local function save() local v = tonumber(eb:GetText()); if v then cfg()[key] = scale and math.floor(v * scale + 0.5) or v end; show() end
  eb:SetScript("OnEnterPressed", function(s) save(); s:ClearFocus() end)
  eb:SetScript("OnEditFocusLost", save)
  eb:SetScript("OnEscapePressed", function(s) show(); s:ClearFocus() end)
  eb:SetScript("OnEditFocusGained", function(s) s:SetBackdropBorderColor(unpack(COL.gold)) end)
  eb:HookScript("OnEditFocusLost", function(s) s:SetBackdropBorderColor(unpack(COL.line2)) end)
  if tip then
    eb:SetScript("OnEnter", function(s) GameTooltip:SetOwner(s, "ANCHOR_TOP"); GameTooltip:SetText(caption, 1, 1, 1); GameTooltip:AddLine(tip, nil, nil, nil, true); GameTooltip:Show() end)
    eb:SetScript("OnLeave", GameTooltip_Hide)
  end
  f.Refresh = show
  f.eb = eb
  return f
end

-- Pages defined in other files (Post.lua, Cancel.lua) register a builder here before the window is built.
UI.builders = {}
function UI.RegisterPage(key, builder) UI.builders[key] = builder end

-- ---------- state ----------
local frame, pages, nav = nil, {}, {}
local pending = nil  -- the commodity deal waiting for Confirm
local current = "commodity"

local function money(c) return FF.Money(c) end
local function status(msg) if frame then frame.status:SetText(msg or "") end end

-- ---------- buying ----------
local function buyCommodity(d)
  if d.state == "confirm" and pending == d then
    d.state = "buying"
    AH.ConfirmCommoditiesPurchase(d.itemID, d.buy)
    return
  end
  if pending and pending ~= d and pending.state ~= "bought" then
    AH.CancelCommoditiesPurchase()
    pending.state = nil
  end
  pending = d
  d.state = "starting"
  AH.StartCommoditiesPurchase(d.itemID, d.buy)
end

UI.BuyCommodity = buyCommodity   -- the Investments page buys through the same two-click flow

local function buyItems(d)
  if d.state ~= "ready" then
    d.state = "refreshing"
    FF.Scan.ItemsNow(d.itemKey, function(ladder)
      local alive = {}
      for _, r in ipairs(ladder or {}) do alive[r.auctionID] = r.buyout end
      local left = {}
      for _, a in ipairs(d.auctions) do
        if alive[a.auctionID] and alive[a.auctionID] <= a.buyout then table.insert(left, a) end
      end
      d.auctions = left
      d.state = #left > 0 and "ready" or "failed"
      if #left == 0 then status(d.name .. ": already sold.") end
      UI.Refresh()
    end)
    return
  end
  for _, a in ipairs(d.auctions) do
    if not a.bought then
      AH.PlaceBid(a.auctionID, a.buyout)
      a.bought = true
      FF.Log(string.format("bought %s auction %s for %d", d.name, tostring(a.auctionID), a.buyout))
      break
    end
  end
  local all = true
  for _, a in ipairs(d.auctions) do if not a.bought then all = false end end
  if all then d.state = "bought"; FF.RecordPurchase(d); status("Bought " .. d.name .. ". It arrives in your mailbox.") end
end

local function buyLabel(d)
  if d.state == "bought" then return "Bought", "done" end
  if d.state == "failed" then return "Gone", "bad" end
  if d.isCommodity then
    if d.state == "starting" then return "Wait…", "ghost" end
    if d.state == "confirm" then return "Confirm", "primary" end
    if d.state == "buying" then return "Buying…", "ghost" end
    return "Buy " .. d.buy, "primary"
  end
  if d.state == "refreshing" then return "Wait…", "ghost" end
  if d.state == "ready" then
    local n, done = #d.auctions, 0
    for _, a in ipairs(d.auctions) do if a.bought then done = done + 1 end end
    return string.format("Buy %d/%d", done + 1, n), "primary"
  end
  return "Buy " .. d.buy, "primary"
end

-- ---------- sniper page (commodity or items) ----------
-- Columns: key, header, width (the item column takes what's left), alignment, sort value.
local function soldOf(d) return d.stats and d.stats.soldPerDay end
local function chanceOf(d) return d.stats and d.stats.saleRate end
local function daysOf(d) local s = soldOf(d); return s and s > 0 and d.buy / s or nil end
local DEAL_COLS = {
  { key = "name", label = "Item", width = 0, align = "LEFT", sort = function(d) return d.name or "" end },
  { key = "buy", label = "Qty", width = 42, sort = function(d) return d.buy end },
  { key = "top", label = "Pay up to", width = 74, sort = function(d) return d.top end },
  { key = "cost", label = "Cost", width = 74, sort = function(d) return d.cost end },
  { key = "sell", label = "Sell at", width = 74, sort = function(d) return d.sell end },
  { key = "profit", label = "Profit", width = 78, sort = function(d) return d.profit end },
  { key = "roi", label = "ROI", width = 46, sort = function(d) return d.roi end },
  { key = "sold", label = "Sold/day", width = 54, sort = soldOf },
  { key = "chance", label = "Sell %", width = 48, sort = chanceOf },
  { key = "days", label = "Days", width = 44, sort = daysOf },
  { key = "gap", label = "Gap", width = 66, sort = function(d) return d.gap end },
}
local BTN_W, PAD, ICON = 100, 14, 30

local function fmtNum(v, dec) if not v then return "-" end return string.format(dec and "%.1f" or "%.0f", v) end
-- the next sellers after your buy, each with how much dearer it is than the top price you pay
local function nextRow(rows, top)
  local parts = {}
  for _, r in ipairs(rows or {}) do
    local jump = top and top > 0 and string.format("  |cff58c27d+%d%%|r", (r.price / top - 1) * 100) or ""
    table.insert(parts, r.qty .. " x " .. FF.Money(r.price) .. jump)
  end
  return #parts > 0 and table.concat(parts, "   ") or "|cffa39a8cnobody else: you'd be the only seller|r"
end

-- the deal's item name; if the game hadn't loaded it yet ("Item 4411"), ask for it again
function UI.ItemName(d)
  if d.name and not d.name:match("^Item %d+$") then return d.name end
  local n = C_Item.GetItemNameByID(d.itemID)
  if n then d.name = n; return n end
  if C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(d.itemID) end
  return d.name
end
local nameRefresh = false
FF:On("GET_ITEM_INFO_RECEIVED", function()
  if nameRefresh then return end
  nameRefresh = true
  C_Timer.After(0.5, function() nameRefresh = false; if UI.Refresh then UI.Refresh() end end)
end)

local function listRow(rows) -- "12 x 2s 66c, 5 x 2s 67c"
  local parts = {}
  for _, r in ipairs(rows or {}) do table.insert(parts, r.qty .. " x " .. FF.Money(r.price)) end
  return #parts > 0 and table.concat(parts, ",  ") or "none"
end

local function buildSniperPage(parent, mode)
  local cfg = function() return FF.Sniper.Config(mode) end
  FF.db.sort = FF.db.sort or {}
  FF.db.sort[mode] = FF.db.sort[mode] or { key = "profit", asc = false }
  local sortState = FF.db.sort[mode]
  local filterText = ""
  local page = CreateFrame("Frame", nil, parent)
  page:SetAllPoints()
  local isC = mode == "commodity"

  local title = text(page, 18, COL.text); title:SetPoint("TOPLEFT", 20, -16)
  local isV = mode == "vendor"
  title:SetText(isC and "Commodity Sniper" or isV and "Vendor Sniper" or "Item Sniper")
  local sub = text(page, 11, COL.muted); sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -5)
  sub:SetText(isC and "Finds stackable goods priced far enough below the next price tier to resell at a profit."
    or isV and "Finds listings below what a vendor pays. Buy them and sell to any vendor: guaranteed profit, no waiting."
    or "Finds single auctions (recipes, gear) listed far below their value. Buy one or a few, not twenty.")

  -- scanner card
  local card = box(page, COL.card, COL.line)
  card:SetPoint("TOPLEFT", 20, -62); card:SetPoint("RIGHT", -20, 0); card:SetHeight(84)
  local ct = text(card, 13, COL.text); ct:SetPoint("TOPLEFT", 14, -14)
  ct:SetText(isC and "Commodity gap scanner" or isV and "Below-vendor scanner" or "Below-value scanner")
  local state = pill(card, "Idle", COL.muted); state:SetPoint("LEFT", ct, "RIGHT", 10, 0)
  local scopeCap = text(card, 11, COL.muted); scopeCap:SetPoint("TOPLEFT", 14, -52); scopeCap:SetText("Scan scope")
  local scope = dropdown(card, 420,
    function()
      local out = {}
      out = FF.Sniper.Scopes()
      return out
    end,
    function() return FF.Sniper.Group(cfg().group).name end,
    function() local p = FF.Sniper.progress[mode]; return p and p.total and p.total > 0 and (p.total .. " candidates") or "" end,
    function(v) cfg().group = v end)
  scope:SetPoint("LEFT", scopeCap, "RIGHT", 18, 0)
  local go = flatButton(card, "Start scan", 110, 28, "primary", function()
    if FF.Sniper.running and FF.Sniper.mode == mode then FF.Sniper.Stop()
    else
      if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then status("Open the auction house first."); return end
      FF.Sniper.Start(mode)
    end
    UI.Refresh()
  end)
  go:SetPoint("TOPRIGHT", -14, -46)
  local rules = flatButton(card, "Edit rules", 96, 26, "ghost", function() UI.Go("rules") end)
  rules:SetPoint("TOPRIGHT", -14, -10)
  local fast = checkbox(card, "Fast sellers first", function() return cfg().fastFirst ~= false end, function(v) cfg().fastFirst = v end)
  fast:SetPoint("RIGHT", rules, "LEFT", -150, 0)

  -- stat cards (they stretch with the window)
  local stats = {}
  local defs = {
    { "Opportunities", function() return tostring(FF.session.opps) end, function() return "Since " .. date("%H:%M", FF.session.since) end },
    { "Purchased", function() return tostring(FF.session.bought) end, function() return "Confirmed buys" end },
    { "Gold invested", function() return FF.Money(FF.session.invested) end, function() return "Purchase cost" end },
    { "Projected profit", function() return FF.Money(FF.session.projected) end, function() return "After AH cut and deposits" end },
  }
  for i, def in ipairs(defs) do
    local c = box(page, COL.card, COL.line)
    c:SetHeight(70)
    c.k = text(c, 11, COL.muted); c.k:SetPoint("TOPLEFT", 12, -10); c.k:SetText(def[1])
    c.v = text(c, 18, COL.text); c.v:SetPoint("TOPLEFT", 12, -28)
    c.s = text(c, 10, COL.dim); c.s:SetPoint("TOPLEFT", 12, -52)
    c.def = def
    if i == 1 then
      local reset = flatButton(c, "Reset", 50, 20, "ghost", function() FF.ResetSession() end)
      reset:SetPoint("TOPRIGHT", -8, -8)
    end
    stats[i] = c
  end
  local function layoutCards()
    local w = (page:GetWidth() - 40 - 3 * 12) / 4
    for i, c in ipairs(stats) do
      c:ClearAllPoints(); c:SetWidth(w); c:SetPoint("TOPLEFT", 20 + (i - 1) * (w + 12), -158)
    end
  end

  -- live opportunities
  local live = box(page, COL.card, COL.line)
  live:SetPoint("TOPLEFT", 20, -240); live:SetPoint("BOTTOMRIGHT", -20, 34)
  local lt = text(live, 13, COL.text); lt:SetPoint("TOPLEFT", PAD, -12); lt:SetText("Live opportunities")
  local count = text(live, 11, COL.muted); count:SetPoint("LEFT", lt, "RIGHT", 8, 0)
  local keep = checkbox(live, "Keep scanning", function() return cfg().autoRescan end, function(v) cfg().autoRescan = v end)
  keep:SetPoint("TOPRIGHT", -128, -9)
  local alerts = checkbox(live, "Alerts", function() return FF.db.alerts.sound end,
    function(v) FF.db.alerts.sound = v; FF.db.alerts.flash = v end)
  alerts:SetPoint("RIGHT", keep, "LEFT", -90, 0)
  alerts:SetScript("OnEnter", function(s) GameTooltip:SetOwner(s, "ANCHOR_TOP"); GameTooltip:SetText("Alerts", 1, 1, 1)
    GameTooltip:AddLine("A sound and a gold flash when a new deal appears; the taskbar icon flashes if WoW is in the background.", nil, nil, nil, true); GameTooltip:Show() end)
  alerts:SetScript("OnLeave", GameTooltip_Hide)
  -- filter box
  local filter = CreateFrame("EditBox", nil, live, "BackdropTemplate")
  filter:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
  filter:SetBackdropColor(unpack(COL.field)); filter:SetBackdropBorderColor(unpack(COL.line2))
  filter:SetSize(170, 22); filter:SetPoint("RIGHT", alerts, "LEFT", -24, 0)
  setFont(filter, 11, ""); filter:SetTextColor(unpack(COL.text)); filter:SetTextInsets(8, 8, 0, 0); filter:SetAutoFocus(false)
  local hint = text(filter, 11, COL.dim); hint:SetPoint("LEFT", 8, 0); hint:SetText("Filter items…")
  filter:SetScript("OnTextChanged", function(s) filterText = s:GetText():lower(); hint:SetShown(s:GetText() == ""); page:Refresh() end)
  filter:SetScript("OnEscapePressed", function(s) s:SetText(""); s:ClearFocus() end)
  filter:SetScript("OnEnterPressed", function(s) s:ClearFocus() end)

  -- column headers (click to sort)
  local headers = {}
  local headRow = CreateFrame("Frame", nil, live)
  headRow:SetPoint("TOPLEFT", 0, -36); headRow:SetPoint("TOPRIGHT", 0, -36); headRow:SetHeight(18)
  for i, col in ipairs(DEAL_COLS) do
    local h = CreateFrame("Button", nil, headRow)
    h:SetHeight(18)
    h.t = text(h, 11, COL.muted, nil, true); h.t:SetAllPoints(); h.t:SetJustifyH(col.align or "RIGHT")
    h:SetScript("OnClick", function()
      if sortState.key == col.key then sortState.asc = not sortState.asc
      else sortState.key, sortState.asc = col.key, col.key == "name" end
      page:Refresh()
    end)
    h:SetScript("OnEnter", function(s) s.t:SetTextColor(unpack(COL.text)) end)
    h:SetScript("OnLeave", function() page:Refresh() end)
    h.col = col
    headers[i] = h
  end
  local sep = live:CreateTexture(nil, "ARTWORK"); sep:SetColorTexture(unpack(COL.line))
  sep:SetPoint("TOPLEFT", 1, -56); sep:SetPoint("TOPRIGHT", -1, -56); sep:SetHeight(1)

  local scroll = CreateFrame("ScrollFrame", nil, live)
  scroll:SetPoint("TOPLEFT", 1, -57); scroll:SetPoint("BOTTOMRIGHT", -1, 60)
  local content = CreateFrame("Frame", nil, scroll); content:SetSize(1, 1)
  scroll:SetScrollChild(content)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(s, delta)
    local max = math.max(0, content:GetHeight() - s:GetHeight())
    s:SetVerticalScroll(math.min(max, math.max(0, s:GetVerticalScroll() - delta * ROW_H * 2)))
  end)
  scroll:SetScript("OnSizeChanged", function(s, w) content:SetWidth(w) end)
  scrollbar(scroll, content)
  local empty = text(live, 12, COL.dim); empty:SetPoint("CENTER", scroll, "CENTER")

  -- column x positions for the current width; the item column takes what's left
  local colX = {}
  local function layoutCols(width)
    local fixed = 0
    for i = 2, #DEAL_COLS do fixed = fixed + DEAL_COLS[i].width end
    local itemW = math.max(150, width - PAD * 2 - BTN_W - fixed)
    local x = PAD
    for i, col in ipairs(DEAL_COLS) do
      local w = i == 1 and itemW or col.width
      colX[i] = { x = x, w = w }
      x = x + w
    end
    for i, h in ipairs(headers) do
      h:ClearAllPoints()
      h:SetPoint("LEFT", colX[i].x + (i == 1 and ICON or 0), 0); h:SetWidth(colX[i].w - 6 - (i == 1 and ICON or 0))
    end
  end

  -- progress strip at the bottom of the card
  local prog = CreateFrame("Frame", nil, live)
  prog:SetPoint("BOTTOMLEFT", PAD, 10); prog:SetPoint("BOTTOMRIGHT", -PAD, 10); prog:SetHeight(46)
  prog.icon = prog:CreateTexture(nil, "ARTWORK"); prog.icon:SetSize(20, 20); prog.icon:SetPoint("TOPLEFT", 0, 0)
  prog.name = text(prog, 12, COL.text); prog.name:SetPoint("LEFT", prog.icon, "RIGHT", 8, 0)
  prog.count = text(prog, 11, COL.muted); prog.count:SetPoint("TOPRIGHT", 0, -4)
  prog.track = prog:CreateTexture(nil, "ARTWORK"); prog.track:SetColorTexture(unpack(COL.line))
  prog.track:SetPoint("TOPLEFT", 0, -26); prog.track:SetPoint("TOPRIGHT", 0, -26); prog.track:SetHeight(3)
  prog.bar = prog:CreateTexture(nil, "OVERLAY"); prog.bar:SetColorTexture(unpack(COL.gold))
  prog.bar:SetPoint("TOPLEFT", prog.track, "TOPLEFT"); prog.bar:SetHeight(3)
  prog.left = text(prog, 10, COL.muted); prog.left:SetPoint("BOTTOMLEFT", 0, 0)
  prog.right = text(prog, 10, COL.muted); prog.right:SetPoint("BOTTOMRIGHT", 0, 0)

  -- rows (pooled); click a row to expand it
  local rows = {}
  local EXPAND_H = 68
  local function row(i)
    if rows[i] then return rows[i] end
    local r = CreateFrame("Button", nil, content)
    r:SetHeight(ROW_H)
    r.hl = r:CreateTexture(nil, "BACKGROUND"); r.hl:SetColorTexture(1, 1, 1, 0.035); r.hl:Hide()
    r.hl:SetPoint("TOPLEFT"); r.hl:SetPoint("TOPRIGHT"); r.hl:SetHeight(ROW_H)
    r.flash = r:CreateTexture(nil, "BACKGROUND", nil, 1); r.flash:SetColorTexture(unpack(COL.gold))
    r.flash:SetPoint("TOPLEFT"); r.flash:SetPoint("TOPRIGHT"); r.flash:SetHeight(ROW_H); r.flash:SetAlpha(0)
    r.anim = r.flash:CreateAnimationGroup()
    local a1 = r.anim:CreateAnimation("Alpha"); a1:SetFromAlpha(0); a1:SetToAlpha(0.35); a1:SetDuration(0.15); a1:SetOrder(1)
    local a2 = r.anim:CreateAnimation("Alpha"); a2:SetFromAlpha(0.35); a2:SetToAlpha(0); a2:SetDuration(2.5); a2:SetOrder(2)
    r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(22, 22)
    r.cells = {}
    for c = 1, #DEAL_COLS do
      local fs = text(r, 12, DEAL_COLS[c].key == "profit" and COL.green or COL.text, nil, DEAL_COLS[c].key == "profit")
      fs:SetJustifyH(DEAL_COLS[c].align or "RIGHT")
      r.cells[c] = fs
    end
    -- gap bar inside the Gap cell
    r.gapTrack = r:CreateTexture(nil, "ARTWORK"); r.gapTrack:SetColorTexture(unpack(COL.line)); r.gapTrack:SetHeight(4)
    r.gapBar = r:CreateTexture(nil, "OVERLAY"); r.gapBar:SetColorTexture(unpack(COL.gold)); r.gapBar:SetHeight(4)
    -- expanded details
    r.detail = text(r, 11, COL.muted, nil, false); r.detail:SetJustifyH("LEFT")
    r.detail2 = text(r, 11, COL.muted, nil, false); r.detail2:SetJustifyH("LEFT")
    r.detail3 = text(r, 11, COL.muted, nil, false); r.detail3:SetJustifyH("LEFT")
    r.buy = flatButton(r, "Buy", 90, 22, "primary", function()
      local d = r.deal
      if not d or d.state == "bought" or d.state == "buying" or d.state == "failed" then return end
      if d.isCommodity then buyCommodity(d) else buyItems(d) end
      UI.Refresh()
    end)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r:SetScript("OnClick", function(s, mouse)
      if not s.deal then return end
      if mouse == "RightButton" then FF.History.Open(s.deal.itemID); return end
      s.deal.expanded = not s.deal.expanded; page:Refresh()
    end)
    r:SetScript("OnEnter", function(s)
      s.hl:Show()
      local d = s.deal; if not d then return end
      GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(d.itemID)
      GameTooltip:AddLine(" ")
      GameTooltip:AddDoubleLine("Value (" .. (FF.SourceNames[FF.db.sniper.priceSource] or "") .. ")", FF.Money(d.value), 1, 1, 1)
      GameTooltip:AddDoubleLine("AH cut used", string.format("%d%%", d.cut * 100), 1, 1, 1, 1, 1, 1)
      if d.deposit then
        GameTooltip:AddDoubleLine("Posting fee (deposit)", FF.Money(d.deposit), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddLine("Profit already has the AH cut and the deposit taken off.", 0.56, 0.56, 0.6, true)
      end
      GameTooltip:AddLine("Click: the listings you'd buy · Right-click: price history", 0.56, 0.56, 0.6)
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function(s) s.hl:Hide(); GameTooltip:Hide() end)
    rows[i] = r
    return r
  end

  local function fill(r, d, width)
    r.deal = d
    r.icon:ClearAllPoints(); r.icon:SetPoint("TOPLEFT", PAD - 1, -4)
    r.icon:SetTexture(C_Item.GetItemIconByID(d.itemID))
    local s = d.stats or {}
    local values = {
      FF.QualityColor(d.quality) .. (UI.ItemName(d) or "?") .. "|r",
      tostring(d.buy), FF.Money(d.top), FF.Money(d.cost), FF.Money(d.sell), FF.Money(d.profit),
      string.format("%d%%", d.roi * 100 + 0.5), fmtNum(s.soldPerDay),
      s.saleRate and string.format("%d%%", s.saleRate * 100 + 0.5) or "-",
      daysOf(d) and (daysOf(d) < 1 and "<1" or fmtNum(daysOf(d), daysOf(d) < 10)) or "-",
      d.gap == nil and "-" or d.gap == math.huge and "open" or string.format("%d%%", d.gap * 100 + 0.5),
    }
    for c, fs in ipairs(r.cells) do
      local cx = colX[c]
      fs:ClearAllPoints()
      local off = c == 1 and ICON or 0
      fs:SetPoint("TOPLEFT", cx.x + off, 0); fs:SetSize(cx.w - 6 - off, ROW_H)
      fs:SetText(values[c])
    end
    -- the Gap cell: a small bar under the number (full at 100 %+)
    local g = colX[#DEAL_COLS]
    local frac = d.gap == nil and 0 or d.gap == math.huge and 1 or math.min(1, math.max(0, d.gap))
    r.gapTrack:SetShown(d.gap ~= nil); r.gapBar:SetShown(d.gap ~= nil)
    r.gapTrack:ClearAllPoints(); r.gapTrack:SetPoint("TOPLEFT", g.x + 8, -ROW_H + 7); r.gapTrack:SetWidth(g.w - 14)
    r.gapBar:ClearAllPoints(); r.gapBar:SetPoint("TOPLEFT", r.gapTrack, "TOPLEFT"); r.gapBar:SetWidth(math.max(1, (g.w - 14) * frac))
    r.cells[#DEAL_COLS]:SetPoint("TOPLEFT", g.x, 3)
    local label, style = buyLabel(d)
    r.buy:SetLabel(label); r.buy:SetStyle(style)
    r.buy:ClearAllPoints(); r.buy:SetPoint("TOPRIGHT", -12, -4)
    -- expanded: the listings you'd buy, and what comes after them
    r.detail:SetShown(d.expanded); r.detail2:SetShown(d.expanded); r.detail3:SetShown(d.expanded)
    if d.expanded then
      local w = width - PAD * 2 - ICON
      r.detail:ClearAllPoints(); r.detail:SetPoint("TOPLEFT", PAD + ICON, -ROW_H); r.detail:SetWidth(w)
      r.detail2:ClearAllPoints(); r.detail2:SetPoint("TOPLEFT", r.detail, "BOTTOMLEFT", 0, -4); r.detail2:SetWidth(w)
      r.detail3:ClearAllPoints(); r.detail3:SetPoint("TOPLEFT", r.detail2, "BOTTOMLEFT", 0, -4); r.detail3:SetWidth(w)
      r.detail:SetText("|cffe8b13aYou buy:|r  " .. listRow(d.rows))
      r.detail2:SetText("|cffede6daNext sellers:|r  " .. nextRow(d.after, d.top))
      local nxt = d.after and d.after[1]
      if d.mode == "vendor" then
        r.detail3:SetText("|cffa39a8cA vendor pays " .. FF.Money(d.sell) .. " each.|r")
      elseif nxt then
        r.detail3:SetText(string.format("|cffa39a8cPrice jump:|r  %s  ->  %s  |cff58c27d(+%d%%)|r   |cffa39a8cYou resell at %s each, just under the next seller.|r",
          FF.Money(d.top), FF.Money(nxt.price), (nxt.price / d.top - 1) * 100, FF.Money(d.sell)))
      else
        r.detail3:SetText("|cffa39a8cNo one else is selling it: you'd resell at its value, " .. FF.Money(d.sell) .. " each.|r")
      end
    end
    r:SetHeight(d.expanded and ROW_H + EXPAND_H - 8 or ROW_H)
  end

  local function sorted()
    local list = {}
    for _, d in ipairs(FF.Sniper.deals[mode] or {}) do
      if filterText == "" or (d.name or ""):lower():find(filterText, 1, true) then table.insert(list, d) end
    end
    local col
    for _, c in ipairs(DEAL_COLS) do if c.key == sortState.key then col = c end end
    col = col or DEAL_COLS[6]
    table.sort(list, function(a, b)
      local x, y = col.sort(a), col.sort(b)
      if x == nil and y == nil then return (a.profit or 0) > (b.profit or 0) end
      if x == nil then return false end
      if y == nil then return true end
      if x == y then return (a.profit or 0) > (b.profit or 0) end
      if sortState.asc then return x < y end
      return x > y
    end)
    return list
  end

  function page:Refresh()
    if page:GetWidth() < 10 then return end
    layoutCards()
    local width = scroll:GetWidth()
    layoutCols(width)
    -- headers with the sort arrow
    for _, h in ipairs(headers) do
      local on = h.col.key == sortState.key
      h.t:SetText(h.col.label .. (on and (sortState.asc and " ^" or " v") or ""))
      h.t:SetTextColor(unpack(on and COL.gold or COL.muted))
    end
    -- scanner card
    local p = FF.Sniper.progress[mode] or {}
    local running = FF.Sniper.running and FF.Sniper.mode == mode
    local st = running and (p.state == "Waiting" and "Waiting" or "Scanning") or (p.state == "Done" and "Done" or "Idle")
    state:Set(st, running and COL.green or COL.muted)
    go:SetLabel(running and "Stop scan" or "Start scan")
    scope:Refresh(); fast:Refresh(); keep:Refresh(); alerts:Refresh()
    for _, c in ipairs(stats) do c.v:SetText(c.def[2]()); c.s:SetText(c.def[3]()) end
    -- deals
    local list = sorted()
    local total = #(FF.Sniper.deals[mode] or {})
    count:SetText(total > 0 and (#list < total and string.format("%d of %d", #list, total) or tostring(total)) or "")
    local y = 0
    for i, d in ipairs(list) do
      local r = row(i)
      r:ClearAllPoints(); r:SetPoint("TOPLEFT", 0, -y); r:SetPoint("RIGHT", content, "RIGHT")
      fill(r, d, width)
      r:Show()
      -- flash rows that just appeared
      if d.newAt and not d.flashed and FF.db.alerts.flash and GetTime() - d.newAt < 3 then
        d.flashed = true
        r.anim:Stop(); r.anim:Play()
      end
      y = y + r:GetHeight()
    end
    for i = #list + 1, #rows do rows[i]:Hide(); rows[i].deal = nil end
    content:SetHeight(math.max(1, y))
    empty:SetShown(#list == 0)
    empty:SetText(total > 0 and "No deals match the filter."
      or running and "No deals yet. Checking the auction house…"
      or (AuctionHouseFrame and AuctionHouseFrame:IsShown() and "Pick a scan scope and press Start scan." or "Open the auction house to scan."))
    -- progress strip
    local ptotal, done = p.total or 0, p.done or 0
    prog:SetShown(running or st == "Done")
    if p.current then
      prog.icon:SetTexture(C_Item.GetItemIconByID(p.current.key.itemID)); prog.icon:Show()
      prog.name:SetText(FF.QualityColor(p.current.info.quality) .. p.current.info.name .. "|r")
    else
      prog.icon:Hide()
      prog.name:SetText(p.state == "Browsing" and ("Browsing " .. (p.group or "") .. "…") or (p.note or ""))
    end
    prog.count:SetText(ptotal > 0 and string.format("%d / %d", done, ptotal) or "")
    local w = prog.track:GetWidth()
    prog.bar:SetWidth(math.max(0.01, (ptotal > 0 and done / ptotal or 0) * (w > 0 and w or 1)))
    prog.left:SetText(string.format("%d checked · %d with listings · %d deals", done, p.listed or 0, p.deals or 0))
    prog.right:SetText(p.group and string.format("%s · %s items · %d%% of %s", p.group, p.items or "?", p.pct or cfg().maxPct, p.source or "value") or "")
  end
  page:SetScript("OnSizeChanged", function() page:Refresh() end)
  return page
end

-- ---------- rules page ----------
local function buildRulesPage(parent)
  local page = CreateFrame("Frame", nil, parent)
  page:SetAllPoints()
  local title = text(page, 18, COL.text); title:SetPoint("TOPLEFT", 20, -16); title:SetText("Rules")
  local sub = text(page, 11, COL.muted); sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -5)
  sub:SetText("What counts as a deal. Values and sales data come from TradeSkillMaster (region = all Forever auction houses in your region).")
  local fields = {}
  local scroll = CreateFrame("ScrollFrame", nil, page)
  scroll:SetPoint("TOPLEFT", 0, -56); scroll:SetPoint("BOTTOMRIGHT", 0, 30)
  local inner = CreateFrame("Frame", nil, scroll); inner:SetSize(1, 1)
  scroll:SetScrollChild(inner)
  scroll:SetScript("OnSizeChanged", function(s, w) inner:SetWidth(w) end)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(s, delta)
    local max = math.max(0, inner:GetHeight() - s:GetHeight())
    s:SetVerticalScroll(math.min(max, math.max(0, s:GetVerticalScroll() - delta * 60)))
  end)
  local function section(y, name, cfgFn, defs, extra)
    local c = box(inner, COL.card, COL.line)
    c:SetPoint("TOPLEFT", 20, y); c:SetPoint("RIGHT", -20, 0)
    local rowsN = math.ceil(#defs / 4) + (extra and 1 or 0)
    c:SetHeight(44 + rowsN * 54)
    local t = text(c, 13, COL.text); t:SetPoint("TOPLEFT", 14, -12); t:SetText(name)
    for i, d in ipairs(defs) do
      local f = numberField(c, d[1], cfgFn, d[2], d[3], d[4])
      f:SetPoint("TOPLEFT", 14 + ((i - 1) % 4) * 186, -40 - math.floor((i - 1) / 4) * 54)
      table.insert(fields, f)
    end
    if extra then extra(c, -40 - math.ceil(#defs / 4) * 54) end
    return c
  end
  local sniper, items = function() return FF.db.sniper end, function() return FF.db.items end
  local QUALITY = { [0] = "Poor", "Common", "Uncommon", "Rare", "Epic" }
  local toggles = {}
  local function salesAndQuality(cfgFn)
    return function(c, y)
      local sales = dropdown(c, 190,
        function() return { { text = "Sales filter: Daily sold", value = "sold" }, { text = "Sales filter: Sell chance", value = "chance" } } end,
        function() return "Sales filter: " .. (cfgFn().salesFilter == "chance" and "Sell chance" or "Daily sold") end, nil,
        function(v) cfgFn().salesFilter = v end)
      sales:SetPoint("TOPLEFT", 14, y - 16)
      local q = dropdown(c, 170,
        function() local o = {} for i = 0, 4 do table.insert(o, { text = "Min quality: " .. QUALITY[i], value = i }) end return o end,
        function() return "Min quality: " .. QUALITY[cfgFn().minQuality] end, nil,
        function(v) cfgFn().minQuality = v end)
      q:SetPoint("LEFT", sales, "RIGHT", 16, 0)
      table.insert(toggles, sales); table.insert(toggles, q)
    end
  end
  local src = dropdown(page, 230,
    function() return { { text = "Value: Realm value", value = "realm" }, { text = "Value: Region value", value = "region" }, { text = "Value: Region sold value", value = "sale" } } end,
    function() return "Value: " .. FF.SourceNames[FF.db.sniper.priceSource] end, nil,
    function(v) FF.db.sniper.priceSource = v end)
  src:SetPoint("TOPRIGHT", -20, -18)
  sub:SetPoint("RIGHT", src, "LEFT", -16, 0)
  table.insert(toggles, src)

  local first = section(-6, "Commodity Sniper", sniper, {
    { "Max % of value", "maxPct", nil, "Only listings below this % of the value." },
    { "Resell gap %", "gapPct", nil, "The price must jump at least this much after the cheap listings, so there's room to resell." },
    { "Price tolerance %", "tolerance", nil, "Listings within this % of the cheapest count as one cheap group." },
    { "Max quantity", "maxQty", nil, "Most units to buy of one item. With daily sold, this caps how long reselling takes." },
    { "Min daily sold", "minSold", nil, "Used with the Daily sold filter." },
    { "Min sell chance %", "minChance", nil, "Used with the Sell chance filter." },
    { "Min ROI %", "minRoi" },
    { "Min quantity", "minQty", nil, "Set 2 or more to skip single bait listings." },
    { "Min profit (gold)", "minProfit", 10000 },
    { "Max spend per deal (gold)", "maxSpend", 10000 },
  }, salesAndQuality(sniper))
  local second = section(-6 - first:GetHeight() - 12, "Item Sniper", items, {
    { "Max % of value", "maxPct", nil, "Only auctions below this % of the value." },
    { "Max quantity", "maxQty", nil, "Recipes and gear: buy one or a few." },
    { "Min ROI %", "minRoi" },
    { "Min profit (gold)", "minProfit", 10000 },
    { "Min daily sold", "minSold" },
    { "Min sell chance %", "minChance" },
    { "Max spend per deal (gold)", "maxSpend", 10000 },
  }, salesAndQuality(items))
  local vendorTop = -6 - first:GetHeight() - 12 - second:GetHeight() - 12
  local third = section(vendorTop, "Vendor Sniper", function() return FF.db.vendor end, {
    { "Min margin %", "marginPct", nil, "Only listings at least this % below what a vendor pays." },
    { "Min profit (gold)", "minProfit", 10000 },
    { "Max spend per deal (gold)", "maxSpend", 10000 },
  })
  inner:SetHeight(-vendorTop + third:GetHeight() + 20)
  local hint = text(page, 10, COL.dim); hint:SetPoint("BOTTOMLEFT", 20, 12); hint:SetText("Scroll for more rules.")
  function page:Refresh()
    for _, f in ipairs(fields) do f.Refresh() end
    for _, t in ipairs(toggles) do t:Refresh() end
  end
  return page
end

-- ---------- placeholder page for things not built yet ----------
local function buildSoonPage(parent, name, what)
  local page = CreateFrame("Frame", nil, parent)
  page:SetAllPoints()
  local title = text(page, 18, COL.text); title:SetPoint("TOPLEFT", 20, -16); title:SetText(name)
  local t = text(page, 12, COL.muted); t:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12); t:SetText(what)
  function page:Refresh() end
  return page
end

-- ---------- main window ----------
local NAV = {
  { key = "commodity", name = "Commodity Sniper", icon = "Interface\\Icons\\INV_Misc_Herb_07" },
  { key = "items", name = "Item Sniper", icon = "Interface\\Icons\\INV_Scroll_03" },
  { key = "vendor", name = "Vendor Sniper", icon = "Interface\\Icons\\INV_Misc_Coin_01" },
  { key = "lists", name = "Lists", icon = "Interface\\Icons\\INV_Misc_Bag_08" },
  { key = "alerts", name = "Price alerts", icon = "Interface\\Icons\\INV_Misc_PocketWatch_01" },
  { key = "rules", name = "Rules", icon = "Interface\\Icons\\INV_Misc_Note_01" },
  { sep = true },
  { key = "post", name = "Post", icon = "Interface\\Icons\\INV_Letter_15" },
  { key = "cancel", name = "Cancel scan", icon = "Interface\\Icons\\Spell_ChargeNegative" },
  { key = "crafting", name = "Crafting", icon = "Interface\\Icons\\Trade_BlackSmithing" },
  { key = "invest", name = "Investments", icon = "Interface\\Icons\\INV_Misc_Coin_17" },
  { key = "farm", name = "Gold Guide", icon = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01" },
  { sep = true },
  { key = "earnings", name = "Earnings", icon = "Interface\\Icons\\INV_Misc_Coin_02" },
}

function UI.Go(key)
  current = key
  FF.db.page = key
  for k, p in pairs(pages) do p:SetShown(k == key) end
  for _, n in ipairs(nav) do
    local on = n.key == key
    n.bar:SetShown(on); n.bg:SetShown(on)
    n.label:SetTextColor(unpack(on and COL.text or (n.soon and COL.dim or COL.muted)))
    if n.icon then n.icon:SetDesaturated(not on); n.icon:SetAlpha(on and 1 or 0.6) end
  end
  if pages[key] then pages[key]:Refresh() end
end

local function build()
  frame = box(UIParent, COL.bg, COL.line2)
  local size = FF.db.size or {}
  frame:SetSize(math.max(MIN_W, size.w or W), math.max(MIN_H, size.h or H))
  frame:SetResizable(true)
  if frame.SetResizeBounds then frame:SetResizeBounds(MIN_W, MIN_H, 1900, 1200) elseif frame.SetMinResize then frame:SetMinResize(MIN_W, MIN_H) end
  local grip = CreateFrame("Button", nil, frame)
  grip:SetSize(16, 16); grip:SetPoint("BOTTOMRIGHT", -2, 2); grip:SetFrameLevel(frame:GetFrameLevel() + 50)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
  grip:SetScript("OnMouseUp", function()
    frame:StopMovingOrSizing()
    FF.db.size = { w = math.floor(frame:GetWidth()), h = math.floor(frame:GetHeight()) }
    if UI.IsDocked() then UI.Dock() end   -- keep it in place over the auction house
  end)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("HIGH")
  frame:SetMovable(true); frame:EnableMouse(true); frame:SetClampedToScreen(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  _G.GoldForgeFrame = frame
  table.insert(UISpecialFrames, "GoldForgeFrame")

  -- header
  local head = box(frame, COL.side, COL.line)
  head:SetPoint("TOPLEFT", 1, -1); head:SetPoint("TOPRIGHT", -1, -1); head:SetHeight(HEAD)
  local mark = head:CreateTexture(nil, "ARTWORK"); mark:SetSize(22, 22); mark:SetPoint("LEFT", 14, 0)
  mark:SetTexture("Interface\\Icons\\INV_Misc_Coin_02"); mark:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  local logo = text(head, 16, COL.gold, nil, true); logo:SetPoint("LEFT", mark, "RIGHT", 9, 0); logo:SetText("Gold Forge")
  -- the forge glow: one thin line of molten gold under the header, cooling to nothing on the right
  local glow = head:CreateTexture(nil, "OVERLAY"); glow:SetHeight(2)
  glow:SetPoint("BOTTOMLEFT", head, "BOTTOMLEFT", 0, 0); glow:SetPoint("BOTTOMRIGHT", head, "BOTTOMRIGHT", 0, 0)
  glow:SetColorTexture(1, 1, 1, 1)
  local glowOK = glow.SetGradient and CreateColor
    and pcall(glow.SetGradient, glow, "HORIZONTAL", CreateColor(0.91, 0.69, 0.23, 0.9), CreateColor(0.91, 0.45, 0.12, 0))
  if not glowOK then glow:SetColorTexture(0.91, 0.69, 0.23, 0.6) end
  local ver = text(head, 10, COL.dim); ver:SetPoint("LEFT", logo, "RIGHT", 8, -1); ver:SetText("v" .. FF.version)
  local close = flatButton(head, "x", 26, 26, "ghost", function() frame:Hide() end)
  close:SetPoint("RIGHT", -10, 0)
  frame.blizz = flatButton(head, "Blizzard AH", 96, 24, "ghost", function() UI.Undock() end)
  frame.blizz:SetPoint("RIGHT", close, "LEFT", -10, 0)
  frame.blizz:SetScript("OnEnter", function(s)
    s:SetBackdropBorderColor(unpack(COL.gold))
    GameTooltip:SetOwner(s, "ANCHOR_BOTTOM"); GameTooltip:SetText("Switch to Blizzard's auction house window", 1, 1, 1)
    GameTooltip:AddLine("The Gold Forge button on it switches back.", nil, nil, nil, true); GameTooltip:Show()
  end)
  frame.blizz:HookScript("OnLeave", GameTooltip_Hide)
  frame.blizz:Hide()
  frame.gold = pill(head, "", COL.gold); frame.gold:SetPoint("RIGHT", frame.blizz, "LEFT", -10, 0)
  frame.tsm = pill(head, "", COL.green); frame.tsm:SetPoint("RIGHT", frame.gold, "LEFT", -6, 0)
  frame.region = pill(head, "", COL.muted); frame.region:SetPoint("RIGHT", frame.tsm, "LEFT", -6, 0)
  frame.faction = pill(head, "", COL.muted); frame.faction:SetPoint("RIGHT", frame.region, "LEFT", -6, 0)

  -- sidebar
  local side = box(frame, COL.side, COL.line)
  side:SetPoint("TOPLEFT", 1, -HEAD); side:SetPoint("BOTTOMLEFT", 1, 1); side:SetWidth(SIDE)
  local y = -12
  for _, n in ipairs(NAV) do
    if n.sep then
      local l = side:CreateTexture(nil, "ARTWORK"); l:SetColorTexture(unpack(COL.line))
      l:SetPoint("TOPLEFT", 12, y - 6); l:SetPoint("TOPRIGHT", -12, y - 6); l:SetHeight(1)
      y = y - 14
    else
      local b = CreateFrame("Button", nil, side)
      b:SetPoint("TOPLEFT", 6, y); b:SetPoint("TOPRIGHT", -6, y); b:SetHeight(28)
      b.bg = b:CreateTexture(nil, "BACKGROUND"); b.bg:SetAllPoints(); b.bg:SetColorTexture(0.91, 0.69, 0.23, 0.10)
      b.bar = b:CreateTexture(nil, "ARTWORK"); b.bar:SetColorTexture(unpack(COL.gold))
      b.bar:SetPoint("TOPLEFT"); b.bar:SetPoint("BOTTOMLEFT"); b.bar:SetWidth(3)
      if n.icon then
        b.icon = b:CreateTexture(nil, "ARTWORK"); b.icon:SetSize(16, 16); b.icon:SetPoint("LEFT", 12, 0)
        b.icon:SetTexture(n.icon); b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
      end
      b.label = text(b, 12, COL.muted); b.label:SetPoint("LEFT", n.icon and 36 or 14, 0); b.label:SetText(n.name)
      if n.soon then
        local s = text(b, 9, COL.dim); s:SetPoint("RIGHT", -8, 0); s:SetText("v0.2")
      end
      b.key, b.soon = n.key, n.soon
      b:SetScript("OnClick", function() UI.Go(n.key) end)
      b:SetScript("OnEnter", function(s) if current ~= s.key then s.label:SetTextColor(unpack(COL.text)) end end)
      b:SetScript("OnLeave", function(s) if current ~= s.key then s.label:SetTextColor(unpack(s.soon and COL.dim or COL.muted)) end end)
      table.insert(nav, b)
      y = y - 30
    end
  end
  local foot = text(side, 10, COL.dim); foot:SetPoint("BOTTOMLEFT", 14, 12); foot:SetWidth(SIDE - 28)
  foot:SetWordWrap(true); foot:SetJustifyH("LEFT")
  foot:SetText("Every purchase is your click. Data: TradeSkillMaster.")

  -- pages
  local body = CreateFrame("Frame", nil, frame)
  body:SetPoint("TOPLEFT", SIDE + 1, -HEAD); body:SetPoint("BOTTOMRIGHT", -1, 1)
  pages.commodity = buildSniperPage(body, "commodity")
  pages.items = buildSniperPage(body, "items")
  pages.vendor = buildSniperPage(body, "vendor")
  pages.rules = buildRulesPage(body)
  for key, builder in pairs(UI.builders) do pages[key] = builder(body) end
  for _, n in ipairs(NAV) do
    if n.key and not pages[n.key] then pages[n.key] = buildSoonPage(body, n.name, "Not available.") end
  end

  frame.status = text(body, 11, COL.muted); frame.status:SetPoint("BOTTOMLEFT", 20, 12); frame.status:SetPoint("BOTTOMRIGHT", -20, 12)
  frame.status:SetJustifyH("LEFT")

  frame:SetScript("OnShow", function() UI.Header(); UI.Go(FF.db.page or "commodity") end)
  frame:SetScript("OnHide", function() UI.OnHide() end)
  frame:Hide()
end

-- building blocks for pages in other files
FF.Kit = {
  COL = COL, box = box, text = text, setFont = setFont, flatButton = flatButton, pill = pill, checkbox = checkbox,
  dropdown = dropdown, numberField = numberField, input = input, scrollbar = scrollbar, W = W, SIDE = SIDE, ROW_H = ROW_H,
  status = function(msg) status(msg) end,
}

function UI.Header()
  if not frame then return end
  local faction = UnitFactionGroup("player") or ""
  frame.faction:Set(faction, faction == "Horde" and { 0.9, 0.35, 0.35 } or { 0.4, 0.6, 1 })
  local region = (GetCurrentRegionName and GetCurrentRegionName()) or ""
  frame.region:Set((region ~= "" and region .. " · " or "") .. "WoW Forever", COL.muted)
  if FF.HasTSM() then frame.tsm:Set("TSM data", COL.green) else frame.tsm:Set("No TSM", COL.red) end
  frame.gold:Set(FF.Money(GetMoney()), COL.gold)
end

function UI.Refresh()
  if frame and frame:IsShown() and pages[current] then pages[current]:Refresh() end
end

-- ---------- one auction house window ----------
-- At the auction house, Gold Forge takes the place of Blizzard's window (like TSM does): Blizzard's
-- window stays open but invisible underneath (closing it would close the auction house). Only the
-- look changes; buying, posting and cancelling still go through the player's own clicks.
local docked = false
local blizzardThisVisit = false   -- "Blizzard AH" pressed: Blizzard's window until the AH is closed
function UI.IsDocked() return docked end
local function ahOpen() return AuctionHouseFrame and AuctionHouseFrame:IsShown() end

function UI.Dock()
  if not frame then build() end
  if not ahOpen() then return UI.Show() end
  docked = true
  blizzardThisVisit = false
  AuctionHouseFrame:SetAlpha(0)
  frame:ClearAllPoints()
  frame:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPLEFT", 0, 0)
  frame:SetFrameStrata("DIALOG")
  frame:Show()
  frame.blizz:Show()
  if UI.ahButton then UI.ahButton:Hide() end
end

-- back to Blizzard's own auction house window
function UI.Undock()
  docked = false
  blizzardThisVisit = true
  if AuctionHouseFrame then AuctionHouseFrame:SetAlpha(1) end
  if UI.ahButton then UI.ahButton:Show() end
  if frame then
    frame.undocking = true
    frame:Hide()
    frame.undocking = nil
  end
end

-- outside the auction house (/gf): a normal movable window
function UI.Show()
  if not frame then build() end
  if ahOpen() and not blizzardThisVisit then return UI.Dock() end
  frame:SetFrameStrata("HIGH")
  frame.blizz:SetShown(ahOpen() and true or false)
  if ahOpen() then
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 6, 0)
  end
  frame:Show()
end
function UI.Toggle()
  if frame and frame:IsShown() then frame:Hide()
  elseif ahOpen() then UI.Dock()      -- /gf at the auction house always brings Gold Forge back
  else UI.Show() end
end

-- closing Gold Forge while it stands in for the auction house closes the auction house too
function UI.OnHide()
  if docked and not frame.undocking and ahOpen() then
    docked = false
    AuctionHouseFrame:SetAlpha(1)
    C_AuctionHouse.CloseAuctionHouse()
  end
end

-- ---------- events ----------
FF:On("FF_DEALS_CHANGED", function() UI.Refresh() end)
local lastAlert = 0
FF:On("FF_NEW_DEAL", function()
  if not FF.db.alerts.sound or GetTime() - lastAlert < 3 then return end
  lastAlert = GetTime()
  local kit = SOUNDKIT and (SOUNDKIT.AUCTION_WINDOW_OPEN or SOUNDKIT.IG_QUEST_LIST_OPEN)
  if kit then pcall(PlaySound, kit, "Master") end
  if FlashClientIcon then pcall(FlashClientIcon) end
end)
FF:On("FF_SNIPER_PROGRESS", function() UI.Refresh() end)
FF:On("FF_SESSION_CHANGED", function() UI.Refresh() end)
FF:On("PLAYER_MONEY", function() UI.Header() end)

-- Blizzard's auction house window only exists once its code has loaded, and the "auction house opened"
-- event can come before the window is visible. So we hook the window itself: whenever it appears,
-- Gold Forge takes its place (or, in Blizzard mode, the switch-back button shows).
local hooked = false
local function hookAuctionHouse()
  if hooked or not AuctionHouseFrame then return end
  hooked = true
  UI.ahButton = flatButton(AuctionHouseFrame, "Gold Forge", 110, 24, "primary", function() UI.Dock() end)
  UI.ahButton:SetPoint("TOPRIGHT", AuctionHouseFrame, "TOPRIGHT", -70, -3)
  UI.ahButton:SetFrameStrata("HIGH")
  UI.ahButton:SetScript("OnEnter", function(s)
    s:SetBackdropBorderColor(1, 1, 1, 1)
    GameTooltip:SetOwner(s, "ANCHOR_BOTTOM"); GameTooltip:SetText("Switch to Gold Forge", 1, 1, 1); GameTooltip:Show()
  end)
  UI.ahButton:HookScript("OnLeave", GameTooltip_Hide)
  AuctionHouseFrame:HookScript("OnShow", function() C_Timer.After(0, UI.OnAuctionHouseShown) end)
end

function UI.OnAuctionHouseShown()
  if not ahOpen() then return end
  if blizzardThisVisit then
    if UI.ahButton then UI.ahButton:Show() end
  else
    UI.Dock()
  end
end

FF:On("ADDON_LOADED", function(name) if name == "Blizzard_AuctionHouseUI" then hookAuctionHouse() end end)
FF:On("AUCTION_HOUSE_SHOW", function()
  hookAuctionHouse()
  -- the window may appear a moment after the event; try now and right after
  C_Timer.After(0, UI.OnAuctionHouseShown)
  C_Timer.After(0.2, UI.OnAuctionHouseShown)
end)
FF:On("AUCTION_HOUSE_CLOSED", function()
  pending = nil
  docked = false
  blizzardThisVisit = false   -- next visit: Gold Forge again
  if AuctionHouseFrame then AuctionHouseFrame:SetAlpha(1) end
  if frame then frame:Hide() end
end)

-- commodity purchase answers
FF:On("COMMODITY_PRICE_UPDATED", function(unitPrice, totalPrice)
  local d = pending
  if not d or d.state ~= "starting" then return end
  d.state = "confirm"
  if totalPrice and totalPrice > d.cost * 1.02 then
    status(string.format("%s: the price went up to %s (was %s). Confirm only if it's still worth it.", d.name, money(totalPrice), money(d.cost)))
  else
    status(string.format("%s: total %s. Click Confirm to buy.", d.name, money(totalPrice)))
  end
  UI.Refresh()
end)
FF:On("COMMODITY_PRICE_UNAVAILABLE", function()
  if pending then pending.state = "failed"; status(pending.name .. ": no longer available."); pending = nil; UI.Refresh() end
end)
FF:On("COMMODITY_PURCHASE_SUCCEEDED", function()
  if pending then
    pending.state = "bought"
    FF.RecordPurchase(pending)
    FF.Log(string.format("bought %d %s for %d", pending.buy, pending.name, pending.cost))
    status("Bought " .. pending.buy .. " " .. pending.name .. ". It arrives in your mailbox.")
    pending = nil
    UI.Refresh()
  end
end)
FF:On("COMMODITY_PURCHASE_FAILED", function()
  if pending then pending.state = "failed"; status(pending.name .. ": purchase failed."); pending = nil; UI.Refresh() end
end)
