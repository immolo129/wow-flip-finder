-- Flip Finder: the window next to the auction house. Toolbar, settings, deals list and buy buttons.
-- Every purchase is a click (Blizzard requires one for buying): Buy, then Confirm for commodities;
-- for single auctions the first click refreshes the listing and each click after that buys one.
local _, FF = ...
local UI = {}
FF.UI = UI
local AH = C_AuctionHouse

local W, H, ROW_H = 860, 480, 26
local frame, rows, list, settings, statusText = nil, {}, nil, nil, nil
local pending = nil  -- the commodity deal waiting for Confirm

-- ---------- small widgets ----------
local function label(parent, text, size, color)
  local fs = parent:CreateFontString(nil, "OVERLAY", size or "GameFontHighlightSmall")
  fs:SetText(text or "")
  if color then fs:SetTextColor(unpack(color)) end
  return fs
end

local function button(parent, text, width, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width or 90, 22)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

-- numeric setting box; `scale` converts stored copper to gold for display
local function numberBox(parent, caption, key, scale, tip)
  local holder = CreateFrame("Frame", nil, parent)
  holder:SetSize(150, 40)
  local cap = label(holder, caption, "GameFontNormalSmall")
  cap:SetPoint("TOPLEFT")
  local box = CreateFrame("EditBox", nil, holder, "InputBoxTemplate")
  box:SetSize(110, 20)
  box:SetPoint("TOPLEFT", cap, "BOTTOMLEFT", 6, -3)
  box:SetAutoFocus(false)
  local function show()
    local v = FF.db.sniper[key]
    box:SetText(scale and tostring(v / scale) or tostring(v))
    box:SetCursorPosition(0)
  end
  local function save()
    local v = tonumber(box:GetText())
    if v then FF.db.sniper[key] = scale and math.floor(v * scale + 0.5) or v end
    show()
  end
  box:SetScript("OnEnterPressed", function(self) save(); self:ClearFocus() end)
  box:SetScript("OnEditFocusLost", save)
  box:SetScript("OnEscapePressed", function(self) show(); self:ClearFocus() end)
  if tip then
    holder:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText(caption, 1, 1, 1); GameTooltip:AddLine(tip, nil, nil, nil, true); GameTooltip:Show()
    end)
    holder:SetScript("OnLeave", GameTooltip_Hide)
  end
  holder.Refresh = show
  return holder
end

-- button that cycles through options
local function cycleButton(parent, width, getText, onClick)
  local b = button(parent, "", width, function(self) onClick(); self:SetText(getText()) end)
  b.Refresh = function() b:SetText(getText()) end
  return b
end

-- ---------- settings panel ----------
local QUALITY = { [0] = "Poor", "Common", "Uncommon", "Rare", "Epic" }

local function buildSettings(parent)
  local p = CreateFrame("Frame", nil, parent, "InsetFrameTemplate")
  p:SetPoint("TOPLEFT", 10, -62)
  p:SetPoint("BOTTOMRIGHT", -10, 30)
  p:Hide()
  local s = FF.db.sniper
  local items = {
    numberBox(p, "Max % of value", "maxPct", nil, "Only listings below this % of the value (price source)."),
    numberBox(p, "Min daily sold", "minSold", nil, "Used when the sales filter is 'Daily sold'. Region units sold per day (TSM)."),
    numberBox(p, "Min sell chance %", "minChance", nil, "Used when the sales filter is 'Sell chance'. Region chance a posted auction sells (TSM)."),
    numberBox(p, "Max quantity", "maxQty", nil, "Most units to buy of one item. With daily sold this caps how long reselling takes."),
    numberBox(p, "Resell gap %", "gapPct", nil, "The price must jump at least this much after the cheap listings, so there's room to resell."),
    numberBox(p, "Price tolerance %", "tolerance", nil, "Listings within this % of the cheapest count as one cheap group."),
    numberBox(p, "Min ROI %", "minRoi"),
    numberBox(p, "Min quantity", "minQty", nil, "Set to 2 or more to skip single bait listings."),
    numberBox(p, "Min profit (gold)", "minProfit", 10000),
    numberBox(p, "Max spend per deal (gold)", "maxSpend", 10000),
  }
  for i, w in ipairs(items) do
    local col, row = (i - 1) % 4, math.floor((i - 1) / 4)
    w:SetPoint("TOPLEFT", 14 + col * 200, -14 - row * 52)
  end
  local sales = cycleButton(p, 180,
    function() return "Sales filter: " .. (s.salesFilter == "chance" and "Sell chance" or "Daily sold") end,
    function() s.salesFilter = s.salesFilter == "chance" and "sold" or "chance" end)
  sales:SetPoint("TOPLEFT", 20, -14 - 3 * 52)
  local quality = cycleButton(p, 180,
    function() return "Min quality: " .. QUALITY[s.minQuality] end,
    function() s.minQuality = (s.minQuality + 1) % 5 end)
  quality:SetPoint("LEFT", sales, "RIGHT", 20, 0)
  local fast = CreateFrame("CheckButton", nil, p, "UICheckButtonTemplate")
  fast:SetPoint("LEFT", quality, "RIGHT", 20, 0)
  fast.text = label(fast, "Fast sellers first", "GameFontHighlightSmall")
  fast.text:SetPoint("LEFT", fast, "RIGHT", 2, 0)
  fast:SetScript("OnClick", function(self) s.fastFirst = self:GetChecked() and true or false end)
  local tip = label(p, "Values come from TradeSkillMaster: daily sold and sell chance are region-wide (all Forever auction houses in your region). " ..
    "Every purchase needs your click; the scan never buys anything by itself.", "GameFontDisableSmall")
  tip:SetPoint("BOTTOMLEFT", 16, 12); tip:SetPoint("BOTTOMRIGHT", -16, 12); tip:SetJustifyH("LEFT")
  p.Refresh = function()
    for _, w in ipairs(items) do w.Refresh() end
    sales.Refresh(); quality.Refresh(); fast:SetChecked(s.fastFirst)
  end
  return p
end

-- ---------- deals list ----------
local COLS = {
  { "Item", 230, "LEFT" }, { "Buy", 50 }, { "Pay up to", 90 }, { "Cost", 90 }, { "Sell at", 90 },
  { "Profit", 90 }, { "ROI", 50 }, { "Sold/day", 60 }, { "", 90 },
}

local function dealButtonText(d)
  if d.state == "bought" then return "|cff40ff40Bought|r" end
  if d.state == "failed" then return "|cffff6060Failed|r" end
  if d.isCommodity then
    if d.state == "starting" then return "Wait…" end
    if d.state == "confirm" then return "Confirm" end
    if d.state == "buying" then return "Buying…" end
    return "Buy " .. d.buy
  end
  if d.state == "refreshing" then return "Wait…" end
  if d.state == "ready" then
    local n, done = #d.auctions, 0
    for _, a in ipairs(d.auctions) do if a.bought then done = done + 1 end end
    return string.format("Buy %d/%d", done + 1, n)
  end
  return "Buy " .. d.buy
end

local function setStatus(text) if statusText then statusText:SetText(text or "") end end

-- commodity: Buy -> Start (game reports the real total) -> Confirm
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

-- single auctions: first click refreshes the listing, then each click buys one auction
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
      if #left == 0 then setStatus(d.name .. ": already sold") end
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
  if all then d.state = "bought" end
end

local function rowFor(i)
  if rows[i] then return rows[i] end
  local r = CreateFrame("Button", nil, list.content)
  r:SetSize(W - 50, ROW_H)
  r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
  r.bg = r:CreateTexture(nil, "BACKGROUND")
  r.bg:SetAllPoints()
  r.bg:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.04 or 0)
  r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  r.icon = r:CreateTexture(nil, "ARTWORK")
  r.icon:SetSize(20, 20)
  r.icon:SetPoint("LEFT", 4, 0)
  r.cells = {}
  local x = 0
  for c, col in ipairs(COLS) do
    if c < #COLS then
      local fs = label(r, "", "GameFontHighlightSmall")
      fs:SetWidth(col[2] - 6)
      fs:SetJustifyH(col[3] or "RIGHT")
      fs:SetWordWrap(false)
      fs:SetPoint("LEFT", x + (c == 1 and 28 or 0), 0)
      if c == 1 then fs:SetWidth(col[2] - 30) end
      r.cells[c] = fs
    end
    x = x + col[2]
  end
  r.buy = button(r, "Buy", 84)
  r.buy:SetPoint("RIGHT", -4, 0)
  r.buy:SetScript("OnClick", function()
    local d = r.deal
    if not d or d.state == "bought" or d.state == "buying" then return end
    if d.isCommodity then buyCommodity(d) else buyItems(d) end
    UI.Refresh()
  end)
  r:SetScript("OnEnter", function(self)
    if not self.deal then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(self.deal.itemID)
    local d = self.deal
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("Price gap after the cheap group", d.gap == math.huge and "nothing above" or string.format("%d%%", d.gap * 100 + 0.5), 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("Value (" .. (FF.SourceNames[FF.db.sniper.priceSource] or "") .. ")", FF.Money(d.value), 1, 1, 1)
    GameTooltip:AddDoubleLine("AH cut used", string.format("%d%%", d.cut * 100), 1, 1, 1, 1, 1, 1)
    GameTooltip:Show()
  end)
  r:SetScript("OnLeave", GameTooltip_Hide)
  rows[i] = r
  return r
end

function UI.Refresh()
  if not frame or not frame:IsShown() then return end
  local deals = FF.Sniper.deals
  for i, d in ipairs(deals) do
    local r = rowFor(i)
    r.deal = d
    r.icon:SetTexture(C_Item.GetItemIconByID(d.itemID))
    local s = d.stats or {}
    r.cells[1]:SetText(FF.QualityColor(d.quality) .. (d.name or "?") .. "|r")
    r.cells[2]:SetText(tostring(d.buy))
    r.cells[3]:SetText(FF.Money(d.top))
    r.cells[4]:SetText(FF.Money(d.cost))
    r.cells[5]:SetText(FF.Money(d.sell))
    r.cells[6]:SetText(FF.Money(d.profit))
    r.cells[7]:SetText(string.format("|cff40ff40%d%%|r", d.roi * 100 + 0.5))
    r.cells[8]:SetText(s.soldPerDay and string.format("%.0f", s.soldPerDay) or "-")
    r.buy:SetText(dealButtonText(d))
    r.buy:SetEnabled(d.state ~= "bought" and d.state ~= "buying" and d.state ~= "starting" and d.state ~= "refreshing")
    r:Show()
  end
  for i = #deals + 1, #rows do rows[i]:Hide(); rows[i].deal = nil end
  list.content:SetHeight(math.max(1, #deals * ROW_H))
  list.empty:SetShown(#deals == 0)
end

-- ---------- main window ----------
local function build()
  frame = CreateFrame("Frame", "FlipFinderFrame", UIParent, "BasicFrameTemplateWithInset")
  frame:SetSize(W, H)
  frame:SetPoint("CENTER")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetFrameStrata("HIGH")
  frame:SetClampedToScreen(true)
  if not frame.TitleText then
    frame.TitleText = label(frame, "", "GameFontHighlight")
    frame.TitleText:SetPoint("TOP", 0, -5)
  end
  frame.TitleText:SetText("Flip Finder  |cff808080v" .. FF.version .. "|r")
  table.insert(UISpecialFrames, "FlipFinderFrame")
  local s = FF.db.sniper

  -- toolbar
  local group = cycleButton(frame, 210,
    function() return "Group: " .. FF.Sniper.Group(s.group).name end,
    function()
      local gs = FF.Sniper.Groups
      for i, g in ipairs(gs) do if g.key == s.group then s.group = gs[i % #gs + 1].key; return end end
      s.group = gs[1].key
    end)
  group:SetPoint("TOPLEFT", 14, -32)
  local source = cycleButton(frame, 190,
    function() return "Value: " .. FF.SourceNames[s.priceSource] end,
    function() s.priceSource = ({ realm = "region", region = "sale", sale = "realm" })[s.priceSource] or "realm" end)
  source:SetPoint("LEFT", group, "RIGHT", 6, 0)
  local scan = button(frame, "Scan", 80, function(self)
    if FF.Sniper.running then FF.Sniper.Stop() else FF.Sniper.Start() end
  end)
  scan:SetPoint("LEFT", source, "RIGHT", 6, 0)
  local auto = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
  auto:SetPoint("LEFT", scan, "RIGHT", 6, 0)
  auto:SetChecked(s.autoRescan)
  auto:SetScript("OnClick", function(self) s.autoRescan = self:GetChecked() and true or false end)
  local autoText = label(auto, "Keep scanning", "GameFontHighlightSmall")
  autoText:SetPoint("LEFT", auto, "RIGHT", 0, 0)
  local gear = button(frame, "Settings", 90, function()
    settings:SetShown(not settings:IsShown())
    list:SetShown(not settings:IsShown())
    if settings:IsShown() then settings.Refresh() end
  end)
  gear:SetPoint("TOPRIGHT", -14, -32)

  -- column headers
  local x = 18
  for _, col in ipairs(COLS) do
    local h = label(frame, col[1], "GameFontNormalSmall")
    h:SetWidth(col[2] - 6)
    h:SetJustifyH(col[3] or "RIGHT")
    h:SetPoint("TOPLEFT", x + (col[1] == "Item" and 28 or 0), -66)
    x = x + col[2]
  end

  -- deals list
  list = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
  list:SetPoint("TOPLEFT", 14, -82)
  list:SetPoint("BOTTOMRIGHT", -34, 30)
  list.content = CreateFrame("Frame", nil, list)
  list.content:SetSize(W - 50, 1)
  list:SetScrollChild(list.content)
  list.empty = label(list, "Open the auction house and press Scan.", "GameFontDisable")
  list.empty:SetPoint("TOP", 0, -40)

  settings = buildSettings(frame)

  statusText = label(frame, "", "GameFontDisableSmall")
  statusText:SetPoint("BOTTOMLEFT", 16, 10)
  statusText:SetPoint("BOTTOMRIGHT", -16, 10)
  statusText:SetJustifyH("LEFT")

  frame.Refresh = function()
    group.Refresh(); source.Refresh(); auto:SetChecked(s.autoRescan)
    scan:SetText(FF.Sniper.running and "Stop" or "Scan")
    if not FF.HasTSM() then setStatus("|cffff6060TradeSkillMaster isn't loaded: no prices, so no deals.|r") end
  end
  frame:SetScript("OnShow", function() frame.Refresh(); UI.Refresh() end)
  frame:Hide()
end

function UI.Show()
  if not frame then build() end
  if AuctionHouseFrame and AuctionHouseFrame:IsShown() then
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 4, 0)
  end
  frame:Show()
end
function UI.Toggle()
  if frame and frame:IsShown() then frame:Hide() else UI.Show() end
end

-- ---------- events ----------
FF:On("FF_DEALS_CHANGED", function() UI.Refresh() end)
FF:On("FF_SNIPER_STATUS", function(text)
  setStatus(text)
  if frame and frame.Refresh then frame.Refresh() end
end)

FF:On("AUCTION_HOUSE_SHOW", function()
  if not UI.ahButton and AuctionHouseFrame then
    UI.ahButton = button(AuctionHouseFrame, "Flip Finder", 100, UI.Toggle)
    UI.ahButton:SetPoint("TOPRIGHT", AuctionHouseFrame, "TOPRIGHT", -60, -1)
  end
  if FF.db.showOnAH then UI.Show() end
end)
FF:On("AUCTION_HOUSE_CLOSED", function()
  pending = nil
  if frame then frame:Hide() end
end)

-- commodity purchase answers
FF:On("COMMODITY_PRICE_UPDATED", function(unitPrice, totalPrice)
  local d = pending
  if not d or d.state ~= "starting" then return end
  d.state = "confirm"
  if totalPrice and totalPrice > d.cost * 1.02 then
    setStatus(string.format("%s: the price went up to %s (was %s). Confirm only if it's still worth it.", d.name, FF.Money(totalPrice), FF.Money(d.cost)))
  else
    setStatus(string.format("%s: total %s. Click Confirm to buy.", d.name, FF.Money(totalPrice)))
  end
  UI.Refresh()
end)
FF:On("COMMODITY_PRICE_UNAVAILABLE", function()
  if pending then pending.state = "failed"; setStatus(pending.name .. ": no longer available."); pending = nil; UI.Refresh() end
end)
FF:On("COMMODITY_PURCHASE_SUCCEEDED", function()
  if pending then
    pending.state = "bought"
    FF.Log(string.format("bought %d %s for %d", pending.buy, pending.name, pending.cost))
    setStatus("Bought " .. pending.buy .. " " .. pending.name .. ". It arrives in your mailbox.")
    pending = nil
    UI.Refresh()
  end
end)
FF:On("COMMODITY_PURCHASE_FAILED", function()
  if pending then pending.state = "failed"; setStatus(pending.name .. ": purchase failed."); pending = nil; UI.Refresh() end
end)
