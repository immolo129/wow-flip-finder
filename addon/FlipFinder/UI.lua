-- Flip Finder: the window. Dark panels, a left menu, stat cards and a live list of deals.
-- Every purchase is a click (Blizzard requires one for buying): Buy, then Confirm for commodities;
-- for single auctions the first click refreshes the listing and each click after that buys one.
local _, FF = ...
local UI = {}
FF.UI = UI
local AH = C_AuctionHouse

-- ---------- look ----------
local COL = {
  bg = { 0.055, 0.055, 0.063, 0.97 }, side = { 0.043, 0.043, 0.05, 1 }, card = { 0.09, 0.09, 0.105, 1 },
  field = { 0.115, 0.115, 0.13, 1 }, line = { 0.17, 0.17, 0.19, 1 }, line2 = { 0.24, 0.24, 0.27, 1 },
  text = { 0.93, 0.93, 0.95 }, muted = { 0.56, 0.56, 0.6 }, dim = { 0.38, 0.38, 0.42 },
  gold = { 0.95, 0.72, 0.11 }, goldText = { 0.1, 0.07, 0 }, green = { 0.29, 0.87, 0.5 }, red = { 0.97, 0.44, 0.44 },
}
local FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
local W, H, SIDE, HEAD = 980, 600, 176, 44
local ROW_H = 30

local function box(parent, bg, border, level)
  local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
  f:SetBackdropColor(unpack(bg or COL.card))
  f:SetBackdropBorderColor(unpack(border or COL.line))
  if level then f:SetFrameLevel(level) end
  return f
end

local function text(parent, size, color, flags)
  local fs = parent:CreateFontString(nil, "OVERLAY")
  fs:SetFont(FONT, size or 12, flags or "")
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

-- number field for the rules page; `scale` converts stored copper to gold
local function numberField(parent, caption, cfg, key, scale, tip)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(180, 50)
  local cap = text(f, 11, COL.muted); cap:SetPoint("TOPLEFT"); cap:SetText(caption)
  local eb = CreateFrame("EditBox", nil, f, "BackdropTemplate")
  eb:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
  eb:SetBackdropColor(unpack(COL.field)); eb:SetBackdropBorderColor(unpack(COL.line2))
  eb:SetSize(164, 26); eb:SetPoint("TOPLEFT", cap, "BOTTOMLEFT", 0, -5)
  eb:SetFont(FONT, 12, ""); eb:SetTextColor(unpack(COL.text)); eb:SetTextInsets(8, 8, 0, 0); eb:SetAutoFocus(false)
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
local LIST_COLS = {
  { "Item", 190, "LEFT" }, { "Qty", 40 }, { "Pay up to", 78 }, { "Cost", 78 }, { "Sell at", 78 },
  { "Profit", 78 }, { "ROI", 44 }, { "Sold/day", 52 },
}

local function buildSniperPage(parent, mode)
  local cfg = function() return FF.Sniper.Config(mode) end
  local page = CreateFrame("Frame", nil, parent)
  page:SetAllPoints()
  local isC = mode == "commodity"

  local title = text(page, 18, COL.text); title:SetPoint("TOPLEFT", 20, -16)
  title:SetText(isC and "Commodity Sniper" or "Item Sniper")
  local sub = text(page, 11, COL.muted); sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -5)
  sub:SetText(isC and "Finds stackable goods priced far enough below the next price tier to resell at a profit."
    or "Finds single auctions (recipes, gear) listed far below their value. Buy one or a few, not twenty.")

  -- scanner card
  local card = box(page, COL.card, COL.line)
  card:SetPoint("TOPLEFT", 20, -62); card:SetPoint("RIGHT", -20, 0); card:SetHeight(84)
  local ct = text(card, 13, COL.text); ct:SetPoint("TOPLEFT", 14, -14)
  ct:SetText(isC and "Commodity gap scanner" or "Below-value scanner")
  local state = pill(card, "Idle", COL.muted); state:SetPoint("LEFT", ct, "RIGHT", 10, 0)
  local scopeCap = text(card, 11, COL.muted); scopeCap:SetPoint("TOPLEFT", 14, -52); scopeCap:SetText("Scan scope")
  local scope = dropdown(card, 420,
    function()
      local out = {}
      for _, g in ipairs(FF.Sniper.Groups) do table.insert(out, { text = g.name, value = g.key }) end
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

  -- stat cards
  local stats = {}
  local defs = {
    { "Opportunities", function() return tostring(FF.session.opps) end, function() return "Since " .. date("%H:%M", FF.session.since) end },
    { "Purchased", function() return tostring(FF.session.bought) end, function() return "Confirmed buys" end },
    { "Gold invested", function() return money(FF.session.invested) end, function() return "Purchase cost" end },
    { "Projected profit", function() return money(FF.session.projected) end, function() return "After AH cut" end },
  }
  local cw = (W - SIDE - 40 - 3 * 12) / 4
  for i, def in ipairs(defs) do
    local c = box(page, COL.card, COL.line)
    c:SetSize(cw, 70)
    c:SetPoint("TOPLEFT", 20 + (i - 1) * (cw + 12), -158)
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

  -- live opportunities
  local live = box(page, COL.card, COL.line)
  live:SetPoint("TOPLEFT", 20, -240); live:SetPoint("BOTTOMRIGHT", -20, 34)
  local lt = text(live, 13, COL.text); lt:SetPoint("TOPLEFT", 14, -12); lt:SetText("Live opportunities")
  local keep = checkbox(live, "Keep scanning", function() return cfg().autoRescan end, function(v) cfg().autoRescan = v end)
  keep:SetPoint("TOPRIGHT", -110, -9)

  local x = 14
  for _, col in ipairs(LIST_COLS) do
    local h = text(live, 10, COL.muted)
    h:SetWidth(col[2] - 6); h:SetJustifyH(col[3] or "RIGHT")
    h:SetPoint("TOPLEFT", x + (col[1] == "Item" and 30 or 0), -40)
    h:SetText(col[1]:upper())
    x = x + col[2]
  end
  local sep = live:CreateTexture(nil, "ARTWORK"); sep:SetColorTexture(unpack(COL.line))
  sep:SetPoint("TOPLEFT", 1, -54); sep:SetPoint("TOPRIGHT", -1, -54); sep:SetHeight(1)

  local scroll = CreateFrame("ScrollFrame", nil, live)
  scroll:SetPoint("TOPLEFT", 1, -55); scroll:SetPoint("BOTTOMRIGHT", -1, 60)
  local content = CreateFrame("Frame", nil, scroll); content:SetSize(W - SIDE - 42, 1)
  scroll:SetScrollChild(content)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(s, delta)
    local max = math.max(0, content:GetHeight() - s:GetHeight())
    s:SetVerticalScroll(math.min(max, math.max(0, s:GetVerticalScroll() - delta * ROW_H * 2)))
  end)
  local empty = text(live, 12, COL.dim); empty:SetPoint("CENTER", scroll, "CENTER")

  -- progress strip at the bottom of the card
  local prog = CreateFrame("Frame", nil, live)
  prog:SetPoint("BOTTOMLEFT", 14, 10); prog:SetPoint("BOTTOMRIGHT", -14, 10); prog:SetHeight(46)
  prog.icon = prog:CreateTexture(nil, "ARTWORK"); prog.icon:SetSize(20, 20); prog.icon:SetPoint("TOPLEFT", 0, 0)
  prog.name = text(prog, 12, COL.text); prog.name:SetPoint("LEFT", prog.icon, "RIGHT", 8, 0)
  prog.count = text(prog, 11, COL.muted); prog.count:SetPoint("TOPRIGHT", 0, -4)
  prog.track = prog:CreateTexture(nil, "ARTWORK"); prog.track:SetColorTexture(unpack(COL.line))
  prog.track:SetPoint("TOPLEFT", 0, -26); prog.track:SetPoint("TOPRIGHT", 0, -26); prog.track:SetHeight(3)
  prog.bar = prog:CreateTexture(nil, "OVERLAY"); prog.bar:SetColorTexture(unpack(COL.gold))
  prog.bar:SetPoint("TOPLEFT", prog.track, "TOPLEFT"); prog.bar:SetHeight(3)
  prog.left = text(prog, 10, COL.muted); prog.left:SetPoint("BOTTOMLEFT", 0, 0)
  prog.right = text(prog, 10, COL.muted); prog.right:SetPoint("BOTTOMRIGHT", 0, 0)

  local rows = {}
  local function row(i)
    if rows[i] then return rows[i] end
    local r = CreateFrame("Button", nil, content)
    r:SetSize(W - SIDE - 42, ROW_H); r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    r.hl = r:CreateTexture(nil, "BACKGROUND"); r.hl:SetAllPoints(); r.hl:SetColorTexture(1, 1, 1, 0.035); r.hl:Hide()
    r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(22, 22); r.icon:SetPoint("LEFT", 13, 0)
    r.cells = {}
    local cx = 14
    for c, col in ipairs(LIST_COLS) do
      local fs = text(r, 12, c == 6 and COL.green or COL.text)
      fs:SetWidth(col[2] - 6 - (c == 1 and 30 or 0)); fs:SetJustifyH(col[3] or "RIGHT")
      fs:SetPoint("LEFT", cx + (c == 1 and 30 or 0), 0)
      r.cells[c] = fs
      cx = cx + col[2]
    end
    r.buy = flatButton(r, "Buy", 86, 22, "primary", function()
      local d = r.deal
      if not d or d.state == "bought" or d.state == "buying" or d.state == "failed" then return end
      if d.isCommodity then buyCommodity(d) else buyItems(d) end
      UI.Refresh()
    end)
    r.buy:SetPoint("RIGHT", -12, 0)
    r:SetScript("OnEnter", function(s)
      s.hl:Show()
      local d = s.deal; if not d then return end
      GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(d.itemID)
      GameTooltip:AddLine(" ")
      if d.mode == "commodity" then
        GameTooltip:AddDoubleLine("Price gap after the cheap group", d.gap == math.huge and "nothing above" or string.format("%d%%", d.gap * 100 + 0.5), 1, 1, 1, 1, 1, 1)
      end
      GameTooltip:AddDoubleLine("Value (" .. (FF.SourceNames[FF.db.sniper.priceSource] or "") .. ")", money(d.value), 1, 1, 1)
      GameTooltip:AddDoubleLine("AH cut used", string.format("%d%%", d.cut * 100), 1, 1, 1, 1, 1, 1)
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function(s) s.hl:Hide(); GameTooltip:Hide() end)
    rows[i] = r
    return r
  end

  function page:Refresh()
    -- scanner card
    local p = FF.Sniper.progress[mode] or {}
    local running = FF.Sniper.running and FF.Sniper.mode == mode
    local st = running and (p.state == "Waiting" and "Waiting" or "Scanning") or (p.state == "Done" and "Done" or "Idle")
    state:Set(st, running and COL.green or COL.muted)
    go:SetLabel(running and "Stop scan" or "Start scan")
    scope:Refresh(); fast:Refresh(); keep:Refresh()
    -- stat cards
    for _, c in ipairs(stats) do c.v:SetText(c.def[2]()); c.s:SetText(c.def[3]()) end
    -- deals
    local deals = FF.Sniper.deals[mode] or {}
    for i, d in ipairs(deals) do
      local r = row(i)
      r.deal = d
      r.icon:SetTexture(C_Item.GetItemIconByID(d.itemID))
      local s = d.stats or {}
      r.cells[1]:SetText(FF.QualityColor(d.quality) .. (d.name or "?") .. "|r")
      r.cells[2]:SetText(tostring(d.buy))
      r.cells[3]:SetText(money(d.top))
      r.cells[4]:SetText(money(d.cost))
      r.cells[5]:SetText(money(d.sell))
      r.cells[6]:SetText(money(d.profit))
      r.cells[7]:SetText(string.format("%d%%", d.roi * 100 + 0.5))
      r.cells[8]:SetText(s.soldPerDay and string.format("%.0f", s.soldPerDay) or "-")
      local label, style = buyLabel(d)
      r.buy:SetLabel(label); r.buy:SetStyle(style)
      r:Show()
    end
    for i = #deals + 1, #rows do rows[i]:Hide(); rows[i].deal = nil end
    content:SetHeight(math.max(1, #deals * ROW_H))
    empty:SetShown(#deals == 0)
    empty:SetText(running and "No deals yet. Checking the auction house…"
      or (AuctionHouseFrame and AuctionHouseFrame:IsShown() and "Pick a scan scope and press Start scan." or "Open the auction house to scan."))
    -- progress strip
    local total, done = p.total or 0, p.done or 0
    prog:SetShown(running or st == "Done")
    if p.current then
      prog.icon:SetTexture(C_Item.GetItemIconByID(p.current.key.itemID)); prog.icon:Show()
      prog.name:SetText(FF.QualityColor(p.current.info.quality) .. p.current.info.name .. "|r")
    else
      prog.icon:Hide()
      prog.name:SetText(p.state == "Browsing" and ("Browsing " .. (p.group or "") .. "…") or (p.note or ""))
    end
    prog.count:SetText(total > 0 and string.format("%d / %d", done, total) or "")
    local w = prog.track:GetWidth()
    prog.bar:SetWidth(math.max(0.01, (total > 0 and done / total or 0) * (w > 0 and w or 1)))
    prog.left:SetText(string.format("%d checked · %d with listings · %d deals", done, p.listed or 0, p.deals or 0))
    prog.right:SetText(p.group and string.format("%s · %s items · %d%% of %s", p.group, p.items or "?", p.pct or cfg().maxPct, p.source or "value") or "")
  end
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
  local function section(y, name, cfgFn, defs, extra)
    local c = box(page, COL.card, COL.line)
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
  table.insert(toggles, src)

  local first = section(-62, "Commodity Sniper", sniper, {
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
  section(-62 - first:GetHeight() - 12, "Item Sniper", items, {
    { "Max % of value", "maxPct", nil, "Only auctions below this % of the value." },
    { "Max quantity", "maxQty", nil, "Recipes and gear: buy one or a few." },
    { "Min ROI %", "minRoi" },
    { "Min profit (gold)", "minProfit", 10000 },
    { "Min daily sold", "minSold" },
    { "Min sell chance %", "minChance" },
    { "Max spend per deal (gold)", "maxSpend", 10000 },
  }, salesAndQuality(items))
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
  { key = "commodity", name = "Commodity Sniper" },
  { key = "items", name = "Item Sniper" },
  { key = "rules", name = "Rules" },
  { sep = true },
  { key = "post", name = "Post" },
  { key = "cancel", name = "Cancel scan" },
}

function UI.Go(key)
  current = key
  FF.db.page = key
  for k, p in pairs(pages) do p:SetShown(k == key) end
  for _, n in ipairs(nav) do
    local on = n.key == key
    n.bar:SetShown(on); n.bg:SetShown(on)
    n.label:SetTextColor(unpack(on and COL.text or (n.soon and COL.dim or COL.muted)))
  end
  if pages[key] then pages[key]:Refresh() end
end

local function build()
  frame = box(UIParent, COL.bg, COL.line2)
  frame:SetSize(W, H)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("HIGH")
  frame:SetMovable(true); frame:EnableMouse(true); frame:SetClampedToScreen(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  _G.FlipFinderFrame = frame
  table.insert(UISpecialFrames, "FlipFinderFrame")

  -- header
  local head = box(frame, COL.side, COL.line)
  head:SetPoint("TOPLEFT", 1, -1); head:SetPoint("TOPRIGHT", -1, -1); head:SetHeight(HEAD)
  local logo = text(head, 17, COL.gold, "OUTLINE"); logo:SetPoint("LEFT", 16, 0); logo:SetText("FLIP FINDER")
  local ver = text(head, 10, COL.dim); ver:SetPoint("LEFT", logo, "RIGHT", 8, -1); ver:SetText("v" .. FF.version)
  local close = flatButton(head, "x", 26, 26, "ghost", function() frame:Hide() end)
  close:SetPoint("RIGHT", -10, 0)
  frame.blizz = flatButton(head, "Blizzard AH", 96, 24, "ghost", function() UI.Undock() end)
  frame.blizz:SetPoint("RIGHT", close, "LEFT", -10, 0)
  frame.blizz:SetScript("OnEnter", function(s)
    s:SetBackdropBorderColor(unpack(COL.gold))
    GameTooltip:SetOwner(s, "ANCHOR_BOTTOM"); GameTooltip:SetText("Switch to Blizzard's auction house window", 1, 1, 1)
    GameTooltip:AddLine("The Flip Finder button on it switches back.", nil, nil, nil, true); GameTooltip:Show()
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
      b.bg = b:CreateTexture(nil, "BACKGROUND"); b.bg:SetAllPoints(); b.bg:SetColorTexture(1, 1, 1, 0.05)
      b.bar = b:CreateTexture(nil, "ARTWORK"); b.bar:SetColorTexture(unpack(COL.gold))
      b.bar:SetPoint("TOPLEFT"); b.bar:SetPoint("BOTTOMLEFT"); b.bar:SetWidth(3)
      b.label = text(b, 12, COL.muted); b.label:SetPoint("LEFT", 14, 0); b.label:SetText(n.name)
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
  COL = COL, box = box, text = text, flatButton = flatButton, pill = pill, checkbox = checkbox,
  dropdown = dropdown, numberField = numberField, W = W, SIDE = SIDE, ROW_H = ROW_H,
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
-- At the auction house, Flip Finder takes the place of Blizzard's window (like TSM does): Blizzard's
-- window stays open but invisible underneath (closing it would close the auction house). Only the
-- look changes; buying, posting and cancelling still go through the player's own clicks.
local docked = false
local function ahOpen() return AuctionHouseFrame and AuctionHouseFrame:IsShown() end

function UI.Dock()
  if not frame then build() end
  if not ahOpen() then return UI.Show() end
  docked = true
  FF.db.replaceAH = true
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
  FF.db.replaceAH = false
  if AuctionHouseFrame then AuctionHouseFrame:SetAlpha(1) end
  if UI.ahButton then UI.ahButton:Show() end
  if frame then
    frame.undocking = true
    frame:Hide()
    frame.undocking = nil
  end
end

-- outside the auction house (/ff): a normal movable window
function UI.Show()
  if not frame then build() end
  if ahOpen() and FF.db.replaceAH ~= false then return UI.Dock() end
  frame:SetFrameStrata("HIGH")
  frame.blizz:SetShown(ahOpen() and true or false)
  if ahOpen() then
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 6, 0)
  end
  frame:Show()
end
function UI.Toggle()
  if frame and frame:IsShown() then frame:Hide() else UI.Show() end
end

-- closing Flip Finder while it stands in for the auction house closes the auction house too
function UI.OnHide()
  if docked and not frame.undocking and ahOpen() then
    docked = false
    AuctionHouseFrame:SetAlpha(1)
    C_AuctionHouse.CloseAuctionHouse()
  end
end

-- ---------- events ----------
FF:On("FF_DEALS_CHANGED", function() UI.Refresh() end)
FF:On("FF_SNIPER_PROGRESS", function() UI.Refresh() end)
FF:On("FF_SESSION_CHANGED", function() UI.Refresh() end)
FF:On("PLAYER_MONEY", function() UI.Header() end)

FF:On("AUCTION_HOUSE_SHOW", function()
  if not UI.ahButton and AuctionHouseFrame then
    -- on Blizzard's window: switch (back) to Flip Finder
    UI.ahButton = flatButton(AuctionHouseFrame, "Flip Finder", 100, 22, "primary", function() UI.Dock() end)
    UI.ahButton:SetPoint("TOPRIGHT", AuctionHouseFrame, "TOPRIGHT", -60, -2)
    UI.ahButton:SetFrameLevel(AuctionHouseFrame:GetFrameLevel() + 20)
  end
  if FF.db.replaceAH ~= false then
    UI.Dock()
  else
    if UI.ahButton then UI.ahButton:Show() end
    if FF.db.showOnAH then UI.Show() end
  end
end)
FF:On("AUCTION_HOUSE_CLOSED", function()
  pending = nil
  docked = false
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
