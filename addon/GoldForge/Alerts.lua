-- Gold Forge: price alerts. "Tell me when Black Lotus is below 30g." Every scan checks the prices it sees
-- against your alerts; "Check now" and "Keep checking" look up just your alert items while you're at the
-- auction house. An alert shows on screen, plays a sound, prints in chat and flashes the taskbar icon,
-- at most once every 10 minutes per item. Alerts only notify: nothing is ever bought by itself.
local _, FF = ...
local Alerts = {}
FF.Alerts = Alerts
local REPEAT = 10 * 60        -- seconds before the same item can alert again
local KEEP_EVERY = 60         -- "Keep checking": a round every minute
local KEEP_MAX = 30 * 60      -- and it stops by itself after 30 minutes

local function watch() FF.db.watch = FF.db.watch or {}; return FF.db.watch end
local function itemName(id) return C_Item.GetItemNameByID(id) or ("Item " .. id) end

function Alerts.Set(itemID, price)
  if not itemID or not price or price <= 0 then return end
  local w = watch()[itemID] or {}
  w.price = math.floor(price)
  watch()[itemID] = w
  if FF.History then FF.History.Track(itemID) end
  FF:Fire("FF_ALERTS_CHANGED")
end
function Alerts.Remove(itemID) watch()[itemID] = nil; FF:Fire("FF_ALERTS_CHANGED") end

local function notify(itemID, price, w)
  local msg = string.format("%s is listed at %s (your alert: below %s)", itemName(itemID), FF.Money(price), FF.Money(w.price))
  FF.Print("|cff4ade80Alert:|r " .. msg)
  FF.Log("alert: " .. msg)
  if RaidNotice_AddMessage and RaidWarningFrame then
    RaidNotice_AddMessage(RaidWarningFrame, "Gold Forge: " .. msg, ChatTypeInfo and ChatTypeInfo.RAID_WARNING or { r = 1, g = 0.8, b = 0.1 })
  end
  local kit = SOUNDKIT and (SOUNDKIT.RAID_WARNING or SOUNDKIT.UI_RAID_BOSS_WHISPER_WARNING)
  if kit then pcall(PlaySound, kit, "Master") end
  if FlashClientIcon then pcall(FlashClientIcon) end
end

-- a price was seen for an item: remember it and alert if it's below the alert price
function Alerts.Check(itemID, price)
  local w = itemID and watch()[itemID]
  if not w or not price or price <= 0 then return end
  w.seen, w.seenAt = price, time()
  if price <= w.price and time() - (w.alertedAt or 0) > REPEAT then
    w.alertedAt = time()
    notify(itemID, price, w)
  end
  FF:Fire("FF_ALERTS_CHANGED")
end

FF:On("FF_PRICE_SEEN", function(itemID, price) Alerts.Check(itemID, price) end)
FF:On("FF_BROWSE_SEEN", function(results)
  local w = watch()
  for _, r in ipairs(results) do
    if r.itemKey and w[r.itemKey.itemID] then Alerts.Check(r.itemKey.itemID, r.minPrice) end
  end
end)

-- look up just the alert items (searching only, at the auction house)
local function ahOpen() return AuctionHouseFrame and AuctionHouseFrame:IsShown() end
function Alerts.CheckNow()
  if not ahOpen() then FF.Kit.status("Open the auction house to check prices."); return false end
  local n = 0
  for itemID in pairs(watch()) do
    local stack = select(8, C_Item.GetItemInfo(itemID)) or 1
    if stack > 1 then FF.Scan.Commodity(itemID, function() end)
    else FF.Scan.Items(C_AuctionHouse.MakeItemKey(itemID), function() end) end
    n = n + 1
  end
  FF.Kit.status(n > 0 and ("Checking " .. n .. " alert item" .. (n == 1 and "" or "s") .. "…") or "No alerts yet.")
  return n > 0
end

-- "Keep checking": a round every minute while the auction house is open, for at most 30 minutes
local keepRun, keepSince = 0, nil
function Alerts.Keep(on)
  FF.db.alertKeep = on and true or false
  keepRun = keepRun + 1
  keepSince = on and GetTime() or nil
  if not on then return FF:Fire("FF_ALERTS_CHANGED") end
  local myRun = keepRun
  local function round()
    if myRun ~= keepRun or not FF.db.alertKeep then return end
    if not ahOpen() then return end
    if GetTime() - keepSince > KEEP_MAX then
      FF.db.alertKeep = false
      FF.Kit.status("Keep checking stopped after 30 minutes. Tick it again to continue.")
      return FF:Fire("FF_ALERTS_CHANGED")
    end
    if not FF.Scan.Busy() then Alerts.CheckNow() end   -- don't get in the way of a running sniper scan
    C_Timer.After(KEEP_EVERY, round)
  end
  round()
  FF:Fire("FF_ALERTS_CHANGED")
end
FF:On("AUCTION_HOUSE_CLOSED", function() if FF.db and FF.db.alertKeep then FF.db.alertKeep = false; keepRun = keepRun + 1 end end)

-- open the Alerts page with an item filled in (from the item window's "Set alert")
function Alerts.Prefill(itemID)
  Alerts.pending = itemID
  FF.UI.Show()
  FF.UI.Go("alerts")
end

-- ---------- page ----------
FF.UI.RegisterPage("alerts", function(parent)
  local K = FF.Kit
  local COL, text, box, button = K.COL, K.text, K.box, K.flatButton
  local page = CreateFrame("Frame", nil, parent)
  page:SetAllPoints()
  local title = text(page, 18, COL.text); title:SetPoint("TOPLEFT", 20, -16); title:SetText("Price alerts")
  local sub = text(page, 11, COL.muted); sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -5)
  sub:SetText("Get told when an item is listed below your price. Prices are seen during scans, or with Check now at the auction house.")

  -- add an alert
  local card = box(page, COL.card, COL.line)
  card:SetPoint("TOPLEFT", 20, -62); card:SetPoint("RIGHT", -20, 0); card:SetHeight(92)
  local item = K.input(card, 300, "Shift-click or drag an item, or type its ID")
  item:SetPoint("TOPLEFT", 14, -14)
  local price = K.input(card, 120, "Below (gold)")
  price:SetPoint("LEFT", item, "RIGHT", 10, 0)
  local chosen
  local function choose(id)
    chosen = id
    item:SetText(id and (C_Item.GetItemNameByID(id) or ("item " .. id)) or "")
    if id and price:GetText() == "" then
      local v = FF.Value(id)
      if v then price:SetText(string.format("%.2f", v * 0.8 / 10000)) end   -- suggest 80 % of its value
    end
  end
  local function add()
    local id = chosen or (FF.Lists and FF.Lists.ParseItem(item:GetText()))
    local g = tonumber(price:GetText())
    if not id then K.status("Pick an item first: click the item box and shift-click an item."); return end
    if not g or g <= 0 then K.status("Enter the price in gold, e.g. 2.5 for 2g 50s."); return end
    Alerts.Set(id, g * 10000)
    K.status(string.format("Alert set: %s below %s.", itemName(id), FF.Money(g * 10000)))
    chosen = nil; item:SetText(""); price:SetText("")
    item:ClearFocus(); price:ClearFocus()
  end
  local addBtn = button(card, "Add alert", 100, 26, "primary", add)
  addBtn:SetPoint("LEFT", price, "RIGHT", 10, 0)
  item:SetScript("OnEnterPressed", function(s) choose(FF.Lists and FF.Lists.ParseItem(s:GetText())); price:SetFocus() end)
  price:SetScript("OnEnterPressed", add)
  local function dropped()
    local kind, id = GetCursorInfo()
    if kind == "item" then ClearCursor(); choose(id) end
  end
  item:SetScript("OnReceiveDrag", dropped)
  item:SetScript("OnMouseDown", function() if GetCursorInfo() == "item" then dropped() end end)
  hooksecurefunc("ChatEdit_InsertLink", function(link)
    if item:HasFocus() and link and link:find("item:") then choose(tonumber(link:match("item:(%d+)"))) end
  end)
  local check = button(card, "Check now", 110, 26, "ghost", function() Alerts.CheckNow() end)
  check:SetPoint("TOPLEFT", 14, -54)
  local keep = K.checkbox(card, "Keep checking (every minute, while the auction house is open)",
    function() return FF.db.alertKeep end, function(v) Alerts.Keep(v) end)
  keep:SetPoint("LEFT", check, "RIGHT", 14, 0)

  -- the alerts
  local list = box(page, COL.card, COL.line)
  list:SetPoint("TOPLEFT", 20, -166); list:SetPoint("BOTTOMRIGHT", -20, 34)
  local COLS = { { "Item", 0, "LEFT" }, { "Alert below", 96 }, { "Last seen", 96 }, { "Seen", 80 }, { "", 120, "LEFT" } }
  local heads = {}
  for i, c in ipairs(COLS) do
    local h = text(list, 11, COL.muted, nil, true); h:SetText(c[1]); h:SetJustifyH(c[3] or "RIGHT"); heads[i] = h
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
  local rows = {}
  local function ago(t)
    if not t then return "-" end
    local m = math.floor((time() - t) / 60)
    return m < 1 and "just now" or m < 60 and (m .. " min ago") or m < 1440 and (math.floor(m / 60) .. " h ago") or (math.floor(m / 1440) .. " d ago")
  end

  function page:Refresh()
    if page:GetWidth() < 10 then return end
    if Alerts.pending then choose(Alerts.pending); Alerts.pending = nil; price:SetFocus() end
    keep:Refresh()
    local width = scroll:GetWidth()
    local fixed, cx, x = 0, {}, 14
    for i = 2, #COLS do fixed = fixed + COLS[i][2] end
    for i, c in ipairs(COLS) do
      local w = i == 1 and math.max(160, width - 28 - fixed - 40) or c[2]
      cx[i] = { x = x, w = w }; x = x + w
    end
    for i, h in ipairs(heads) do h:ClearAllPoints(); h:SetPoint("TOPLEFT", cx[i].x + (i == 1 and 28 or 0), -12); h:SetWidth(cx[i].w - 6) end
    local ids = {}
    for id in pairs(watch()) do table.insert(ids, id) end
    table.sort(ids, function(a, b) return itemName(a) < itemName(b) end)
    for i, id in ipairs(ids) do
      local w = watch()[id]
      local r = rows[i]
      if not r then
        r = CreateFrame("Button", nil, content)
        r:SetHeight(K.ROW_H)
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(20, 20); r.icon:SetPoint("LEFT", 14, 0)
        r.cells = {}
        for c = 1, #COLS do r.cells[c] = text(r, 12, COL.text); r.cells[c]:SetJustifyH(COLS[c][3] or "RIGHT") end
        r.chart = button(r, "Chart", 60, 22, "ghost")
        r.remove = button(r, "x", 24, 22, "ghost")
        r.remove:SetPoint("RIGHT", -12, 0); r.chart:SetPoint("RIGHT", r.remove, "LEFT", -6, 0)
        r:SetScript("OnClick", function(s) FF.History.Open(s.itemID) end)
        r:SetScript("OnEnter", function(s) GameTooltip:SetOwner(s, "ANCHOR_RIGHT"); GameTooltip:SetItemByID(s.itemID); GameTooltip:AddLine("Click for the price history.", 0.56, 0.56, 0.6); GameTooltip:Show() end)
        r:SetScript("OnLeave", GameTooltip_Hide)
        rows[i] = r
      end
      r.itemID = id
      r:ClearAllPoints(); r:SetPoint("TOPLEFT", 0, -(i - 1) * K.ROW_H); r:SetPoint("RIGHT", content, "RIGHT")
      r.icon:SetTexture(C_Item.GetItemIconByID(id))
      local below = w.seen and w.seen <= w.price
      local quality = select(3, C_Item.GetItemInfo(id))
      local vals = { FF.QualityColor(quality) .. itemName(id) .. "|r", FF.Money(w.price), w.seen and FF.Money(w.seen) or "-", ago(w.seenAt),
                     below and "|cff4ade80Below your price!|r" or (w.seen and "|cffa39a8cAbove|r" or "|cff6e665bNot seen yet|r") }
      for c, fs in ipairs(r.cells) do
        fs:ClearAllPoints(); fs:SetPoint("LEFT", cx[c].x + (c == 1 and 28 or 0) + (c == 5 and 10 or 0), 0)
        fs:SetWidth(cx[c].w - 6 - (c == 1 and 28 or 0)); fs:SetText(vals[c])
      end
      r.chart:SetScript("OnClick", function() FF.History.Open(id) end)
      r.remove:SetScript("OnClick", function() Alerts.Remove(id) end)
      r:Show()
    end
    for i = #ids + 1, #rows do rows[i]:Hide() end
    content:SetHeight(math.max(1, #ids * K.ROW_H))
    empty:SetShown(#ids == 0)
    empty:SetText("No alerts yet. Pick an item and a price above.")
  end
  FF:On("FF_ALERTS_CHANGED", function() if page:IsShown() then page:Refresh() end end)
  page:SetScript("OnSizeChanged", function() if page:IsShown() then page:Refresh() end end)
  return page
end)
