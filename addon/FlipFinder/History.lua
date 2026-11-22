-- Flip Finder: price history and the item window.
-- TSM doesn't share its price history with other addons, so Flip Finder records its own: whenever a scan
-- sees an item you care about (on a list, an alert, a deal, a known recipe, or opened in the item window),
-- its lowest price is saved, one point per 2 hours, kept for 7 days. The chart fills in as you scan.
local _, FF = ...
local History = {}
FF.History = History
local BUCKET, KEEP = 2 * 3600, 7 * 86400

local function hist() FF.db.history = FF.db.history or {}; return FF.db.history end
local function tracked() FF.db.tracked = FF.db.tracked or {}; return FF.db.tracked end

-- items worth recording: tracked by hand, on a list, on an alert, or part of a known recipe
local recipeItems, recipeItemsAt = {}, 0
local function isWanted(itemID)
  if tracked()[itemID] or (FF.db.watch and FF.db.watch[itemID]) then return true end
  for _, l in ipairs(FF.db.lists or {}) do if l.items[itemID] then return true end end
  if GetTime() - recipeItemsAt > 60 then   -- rebuild at most once a minute
    recipeItems, recipeItemsAt = {}, GetTime()
    for _, profs in pairs(FF.db.recipes or {}) do
      for _, data in pairs(profs) do
        for _, r in pairs(data.recipes or {}) do
          recipeItems[r.out] = true
          for _, rg in ipairs(r.reagents or {}) do recipeItems[rg[1]] = true end
        end
      end
    end
  end
  return recipeItems[itemID] or false
end

function History.Track(itemID) tracked()[itemID] = true end

-- record the lowest price seen for an item in the current 2-hour bucket
function History.Record(itemID, price, force)
  if not itemID or not price or price <= 0 then return end
  if not force and not isWanted(itemID) then return end
  local h = hist()
  local list = h[itemID]
  if not list then list = {}; h[itemID] = list end
  local now = time()
  local b = math.floor(now / BUCKET) * BUCKET
  local last = list[#list]
  if last and last[1] == b then
    if price < last[2] then last[2] = price end
  else
    table.insert(list, { b, price, FF.Raw("realm", itemID) })
  end
  while list[1] and now - list[1][1] > KEEP do table.remove(list, 1) end
end

-- a scan saw these prices
FF:On("FF_PRICE_SEEN", function(itemID, price) History.Record(itemID, price, true) end)  -- checked on purpose: keep it
FF:On("FF_BROWSE_SEEN", function(results)
  for _, r in ipairs(results) do
    if r.itemKey and r.minPrice then History.Record(r.itemKey.itemID, r.minPrice) end
  end
end)
FF:On("FF_NEW_DEAL", function(_, deal) if deal then History.Track(deal.itemID) end end)

-- forget items not seen for longer than we keep history
FF:On("FF_READY", function()
  local now = time()
  for id, list in pairs(hist()) do
    while list[1] and now - list[1][1] > KEEP do table.remove(list, 1) end
    if #list == 0 then hist()[id] = nil end
  end
end)

-- ---------- the item window ----------
local win
local RANGES = { { "24h", 1 }, { "3 days", 3 }, { "7 days", 7 } }

local function buildWindow()
  local K = FF.Kit
  local COL, text, box, button = K.COL, K.text, K.box, K.flatButton
  win = box(UIParent, COL.bg, COL.line2)
  win:SetSize(620, 400); win:SetPoint("CENTER", 0, 60); win:SetFrameStrata("DIALOG"); win:SetToplevel(true)
  win:SetMovable(true); win:EnableMouse(true); win:RegisterForDrag("LeftButton"); win:SetClampedToScreen(true)
  win:SetScript("OnDragStart", win.StartMoving); win:SetScript("OnDragStop", win.StopMovingOrSizing)
  _G.FlipFinderItemWindow = win
  table.insert(UISpecialFrames, "FlipFinderItemWindow")
  win.range = FF.db.historyRange or 7

  win.icon = win:CreateTexture(nil, "ARTWORK"); win.icon:SetSize(36, 36); win.icon:SetPoint("TOPLEFT", 16, -14)
  win.name = text(win, 16, COL.text); win.name:SetPoint("TOPLEFT", win.icon, "TOPRIGHT", 12, -2)
  win.sub = text(win, 10, COL.muted); win.sub:SetPoint("TOPLEFT", win.name, "BOTTOMLEFT", 0, -4)
  local close = button(win, "x", 26, 26, "ghost", function() win:Hide() end); close:SetPoint("TOPRIGHT", -10, -10)
  win.alert = button(win, "Set alert", 90, 26, "ghost", function()
    if FF.Alerts then FF.Alerts.Prefill(win.itemID) end
  end)
  win.alert:SetPoint("RIGHT", close, "LEFT", -8, 0)

  -- numbers
  win.stats = {}
  local labels = { "Realm value", "Lowest buyout", "Region value", "Daily sold", "Sell chance", "Lowest seen (range)" }
  for i, l in ipairs(labels) do
    local c = box(win, COL.card, COL.line)
    c:SetSize(186, 44); c:SetPoint("TOPLEFT", 16 + ((i - 1) % 3) * 196, -64 - math.floor((i - 1) / 3) * 52)
    c.k = text(c, 10, COL.muted); c.k:SetPoint("TOPLEFT", 10, -7); c.k:SetText(l)
    c.v = text(c, 13, COL.text); c.v:SetPoint("TOPLEFT", 10, -22)
    win.stats[i] = c
  end

  -- range buttons and chart
  win.rangeBtns = {}
  for i, r in ipairs(RANGES) do
    local b = button(win, r[1], 64, 22, "ghost", function() win.range = r[2]; FF.db.historyRange = r[2]; History.Draw() end)
    b:SetPoint("TOPRIGHT", -16 - (3 - i) * 70, -172)
    b.value = r[2]
    win.rangeBtns[i] = b
  end
  local legend = text(win, 10, COL.muted); legend:SetPoint("TOPLEFT", 16, -177)
  legend:SetText("|cff3aa8ff—|r Lowest price seen   |cfff2b81d—|r TSM market value")
  win.plot = CreateFrame("Frame", nil, win)
  win.plot:SetPoint("TOPLEFT", 76, -206); win.plot:SetPoint("BOTTOMRIGHT", -16, 28)
  win.empty = text(win, 11, COL.dim); win.empty:SetPoint("CENTER", win.plot, "CENTER")
  win.pool = { tex = {}, lines = {}, labels = {} }
  win.hover = CreateFrame("Frame", nil, win.plot); win.hover:SetAllPoints(); win.hover:EnableMouse(true)
  win.hover:SetScript("OnLeave", GameTooltip_Hide)
  win:Hide()
end

-- draw the chart for the current item and range
function History.Draw()
  if not win or not win:IsShown() then return end
  local K = FF.Kit
  local COL = K.COL
  for _, b in ipairs(win.rangeBtns) do b:SetStyle(b.value == win.range and "primary" or "ghost") end
  local plot, pool = win.plot, win.pool
  local used = { tex = 0, lines = 0, labels = 0 }
  local function tex(r, g, b, a)
    used.tex = used.tex + 1
    local t = pool.tex[used.tex] or plot:CreateTexture(nil, "ARTWORK"); pool.tex[used.tex] = t
    t:ClearAllPoints(); t:SetColorTexture(r, g, b, a or 1); t:Show(); return t
  end
  local function line(x1, y1, x2, y2, r, g, b)
    used.lines = used.lines + 1
    local l = pool.lines[used.lines] or plot:CreateLine(nil, "OVERLAY"); pool.lines[used.lines] = l
    l:SetThickness(2); l:SetColorTexture(r, g, b, 1)
    l:SetStartPoint("BOTTOMLEFT", x1, y1); l:SetEndPoint("BOTTOMLEFT", x2, y2); l:Show()
  end
  local function label(s)
    used.labels = used.labels + 1
    local fs = pool.labels[used.labels] or K.text(win, 10, COL.dim); pool.labels[used.labels] = fs
    fs:ClearAllPoints(); fs:SetText(s); fs:Show(); return fs
  end

  local now = time()
  local pts = {}
  for _, p in ipairs(hist()[win.itemID] or {}) do
    if now - p[1] <= win.range * 86400 then table.insert(pts, p) end
  end
  local lowest
  for _, p in ipairs(pts) do lowest = math.min(lowest or p[2], p[2]) end
  win.stats[6].v:SetText(lowest and FF.Money(lowest) or "|cff5f5f69-|r")
  local w, h = plot:GetWidth(), plot:GetHeight()
  win.empty:SetShown(#pts < 2)
  win.empty:SetText(#pts == 0 and "No price history yet. It builds up as Flip Finder sees this item in your scans."
    or "Only one price so far. The line appears after the next scan in a later 2-hour window.")
  if #pts >= 2 and w > 10 then
    local lo, hi = math.huge, 0
    for _, p in ipairs(pts) do
      lo = math.min(lo, p[2], p[3] or p[2]); hi = math.max(hi, p[2], p[3] or p[2])
    end
    lo, hi = lo * 0.95, hi * 1.05
    local t0, t1 = now - win.range * 86400, now
    local X = function(t) return (t - t0) / (t1 - t0) * w end
    local Y = function(v) return (v - lo) / math.max(1, hi - lo) * h end
    for i = 0, 3 do
      local v = lo + (hi - lo) * i / 3
      local g = tex(1, 1, 1, 0.06); g:SetHeight(1); g:SetPoint("BOTTOMLEFT", 0, Y(v)); g:SetPoint("BOTTOMRIGHT", 0, Y(v))
      label(FF.Money(v)):SetPoint("RIGHT", plot, "BOTTOMLEFT", -6, Y(v))
    end
    for i = 0, 3 do
      local t = t0 + (t1 - t0) * i / 3
      label(date(win.range <= 1 and "%H:%M" or "%d %b", t)):SetPoint("TOP", plot, "BOTTOMLEFT", X(t), -6)
    end
    local prevL, prevM
    for _, p in ipairs(pts) do
      local x = X(p[1] + BUCKET / 2)
      local yl = Y(p[2])
      if prevL then line(prevL[1], prevL[2], x, yl, 0.23, 0.66, 1) end
      prevL = { x, yl }
      if p[3] then
        local ym = Y(p[3])
        if prevM then line(prevM[1], prevM[2], x, ym, 0.95, 0.72, 0.11) end
        prevM = { x, ym }
      end
      local dot = tex(0.23, 0.66, 1, 1); dot:SetSize(4, 4); dot:SetPoint("CENTER", plot, "BOTTOMLEFT", x, yl)
    end
    -- hover: nearest point
    win.hover:SetScript("OnUpdate", function(s)
      if not s:IsMouseOver() then return end
      local cx = GetCursorPosition() / s:GetEffectiveScale() - s:GetLeft()
      local best
      for _, p in ipairs(pts) do
        local d = math.abs(X(p[1] + BUCKET / 2) - cx)
        if not best or d < best[1] then best = { d, p } end
      end
      if best and best[2] ~= s.last then
        s.last = best[2]
        GameTooltip:SetOwner(s, "ANCHOR_CURSOR")
        GameTooltip:SetText(date("%a %d %b %H:%M", best[2][1]), 1, 1, 1)
        GameTooltip:AddDoubleLine("Lowest price seen", FF.Money(best[2][2]), 0.23, 0.66, 1)
        if best[2][3] then GameTooltip:AddDoubleLine("TSM market value", FF.Money(best[2][3]), 0.95, 0.72, 0.11) end
        GameTooltip:Show()
      end
    end)
  else
    win.hover:SetScript("OnUpdate", nil)
  end
  for i = used.tex + 1, #pool.tex do pool.tex[i]:Hide() end
  for i = used.lines + 1, #pool.lines do pool.lines[i]:Hide() end
  for i = used.labels + 1, #pool.labels do pool.labels[i]:Hide() end
end

-- open the item window for an item (and keep recording its price from now on)
function History.Open(itemID)
  if not itemID then return end
  if not win then buildWindow() end
  History.Track(itemID)
  win.itemID = itemID
  win.icon:SetTexture(C_Item.GetItemIconByID(itemID))
  local quality = select(3, C_Item.GetItemInfo(itemID))
  win.name:SetText(FF.QualityColor(quality) .. (C_Item.GetItemNameByID(itemID) or ("Item " .. itemID)) .. "|r")
  local s = FF.Stats(itemID)
  local n = #(hist()[itemID] or {})
  win.sub:SetText(n > 0 and string.format("%d price points from your scans (kept 7 days)", n) or "Price history builds up from your scans")
  local vals = {
    FF.Money(s.realm), FF.Money(s.minBuyout), FF.Money(s.region),
    s.soldPerDay and string.format("%.0f", s.soldPerDay) or "-", s.saleRate and string.format("%d%%", s.saleRate * 100 + 0.5) or "-",
  }
  for i = 1, 5 do win.stats[i].v:SetText(vals[i]) end
  win:Show()
  win:Raise()
  C_Timer.After(0, History.Draw)
end
