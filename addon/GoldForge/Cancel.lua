-- Gold Forge: the cancel scan. Checks each of your auctions against the competition and lists the
-- ones you've been undercut on. Cancelling is ONE CLICK PER AUCTION (Blizzard requires a click);
-- cancelled items go to your mailbox, ready to post again.
local _, FF = ...
local AH = C_AuctionHouse
local Cancel = { rows = {}, state = "Idle" }
FF.Cancel = Cancel
local SOLD = Enum.AuctionStatus and Enum.AuctionStatus.Sold or 1

local function changed() FF:Fire("FF_CANCEL_CHANGED") end

local function isCommodity(itemKey)
  local info = AH.GetItemKeyInfo(itemKey)
  if info and info.isCommodity ~= nil then return info.isCommodity end
  local _, _, _, _, _, _, _, stack = C_Item.GetItemInfo(itemKey.itemID)
  return (stack or 1) > 1
end

-- decide what to do with one auction, given the other players' listings
local function judge(row, ladder)
  local cfg = FF.db.post
  if row.isCommodity then
    row.mine = ladder and ladder.own and ladder.own[row.auctionID] or row.mine
  end
  local competitor = ladder and ladder[1] and ladder[1].price
  row.competitor = competitor
  if not row.mine then
    FF.Log(string.format("cancel scan: no own price for %s (auction %s, commodity %s)", row.name, tostring(row.auctionID), tostring(row.isCommodity)))
    row.state, row.note = "ok", "Couldn't find your price: left alone"
  elseif not competitor or competitor >= row.mine then
    row.state, row.note = "ok", "You're the cheapest"
  else
    local value = FF.Value(row.itemID)
    local floor = value and value * cfg.floorPct / 100 or 0
    if competitor - cfg.undercut < floor then
      row.state, row.note = "keep", "Undercut below your minimum: keep it up"
    else
      row.state, row.note = "undercut", string.format("Undercut by %s", FF.Money(row.mine - competitor))
    end
  end
end

function Cancel.Scan()
  if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then FF.Kit.status("Open the auction house first."); return end
  Cancel.rows, Cancel.state = {}, "Loading your auctions"
  changed()
  FF.Scan.Owned(function(list)
    local ladders = {}  -- one price check per item, shared by your auctions of it
    for _, a in ipairs(list or {}) do
      if a.status ~= SOLD and a.itemKey and a.buyoutAmount then
        local commodity = isCommodity(a.itemKey)
        local qty = math.max(1, a.quantity or 1)
        table.insert(Cancel.rows, {
          auctionID = a.auctionID, itemID = a.itemKey.itemID, itemKey = a.itemKey, link = a.itemLink, qty = qty,
          isCommodity = commodity, mine = (not commodity) and math.ceil(a.buyoutAmount / qty) or nil,
          name = C_Item.GetItemNameByID(a.itemKey.itemID) or ("Item " .. a.itemKey.itemID),
          quality = select(3, C_Item.GetItemInfo(a.itemKey.itemID)), state = "checking",
        })
      end
    end
    Cancel.state = #Cancel.rows > 0 and "Checking competition" or "No active auctions"
    Cancel.left = #Cancel.rows
    changed()
    for _, row in ipairs(Cancel.rows) do
      local key = row.isCommodity and ("c" .. row.itemID) or ("i" .. row.auctionID)
      local function done(ladder)
        judge(row, ladder)
        Cancel.left = Cancel.left - 1
        if Cancel.left == 0 then Cancel.state = "Done" end
        changed()
      end
      if row.isCommodity then
        if ladders[key] then
          table.insert(ladders[key], done)
        else
          ladders[key] = { done }
          FF.Scan.Commodity(row.itemID, function(ladder) for _, cb in ipairs(ladders[key]) do cb(ladder) end end)
        end
      else
        FF.Scan.Items(row.itemKey, done)
      end
    end
  end)
end

-- MUST be called from a click (Blizzard requires one for cancelling): cancels this one auction.
function Cancel.Do(row)
  if row.state ~= "undercut" then return end
  local ok, can = pcall(AH.CanCancelAuction, row.auctionID)
  if ok and can == false then row.state, row.note = "ok", "The game won't cancel this one"; return changed() end
  row.state = "cancelling"
  AH.CancelAuction(row.auctionID)
  FF.Log(string.format("cancel %s auction %s", row.name, tostring(row.auctionID)))
  changed()
end

function Cancel.NextRow()
  for _, r in ipairs(Cancel.rows) do if r.state == "undercut" then return r end end
end

function Cancel.CountUndercut()
  local n = 0
  for _, r in ipairs(Cancel.rows) do if r.state == "undercut" then n = n + 1 end end
  return n
end

FF:On("AUCTION_CANCELED", function(auctionID)
  for _, r in ipairs(Cancel.rows) do
    if r.auctionID == auctionID or (r.state == "cancelling" and not auctionID) then
      r.state, r.note = "cancelled", "Cancelled: it's in your mailbox"
    end
  end
  changed()
end)
FF:On("AUCTION_HOUSE_CLOSED", function() Cancel.rows = {}; Cancel.state = "Idle" end)
FF:On("FF_SCAN_STALLED", function()
  local any = false
  for _, r in ipairs(Cancel.rows) do
    if r.state == "checking" then r.state, r.note, any = "ok", "AH didn't answer: scan again", true end
  end
  if any or Cancel.state == "Loading your auctions" then Cancel.state = "Scan again"; changed() end
end)

-- ---------- page ----------
FF.UI.RegisterPage("cancel", function(parent)
  local K = FF.Kit
  local COL, text, box, button = K.COL, K.text, K.box, K.flatButton
  local page = CreateFrame("Frame", nil, parent)
  page:SetAllPoints()
  local title = text(page, 18, COL.text); title:SetPoint("TOPLEFT", 20, -16); title:SetText("Cancel scan")
  local sub = text(page, 11, COL.muted); sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -5)
  sub:SetText("Finds your auctions that were undercut. One click cancels one auction (Blizzard requires a click). Uses the Post page's min % and undercut.")

  local scan = button(page, "Scan my auctions", 140, 28, "ghost", function() Cancel.Scan() end)
  scan:SetPoint("TOPLEFT", 20, -62)
  local nextBtn = button(page, "Cancel next", 170, 28, "primary", function()
    local r = Cancel.NextRow()
    if r then Cancel.Do(r) end
  end)
  nextBtn:SetPoint("LEFT", scan, "RIGHT", 10, 0)
  local state = K.pill(page, "Idle"); state:SetPoint("LEFT", nextBtn, "RIGHT", 12, 0)

  local list = box(page, COL.card, COL.line)
  list:SetPoint("TOPLEFT", 20, -100); list:SetPoint("BOTTOMRIGHT", -20, 34)
  local COLS = { { "Item", 210, "LEFT" }, { "Qty", 40 }, { "Your price", 90 }, { "Cheapest other", 100 }, { "", 210, "LEFT" } }
  local x = 14
  for _, c in ipairs(COLS) do
    local h = text(list, 10, COL.muted); h:SetWidth(c[2] - 6); h:SetJustifyH(c[3] or "RIGHT")
    h:SetPoint("TOPLEFT", x + (c[1] == "Item" and 30 or 0) + (c[3] == "LEFT" and c[1] ~= "Item" and 10 or 0), -12); h:SetText(c[1]:upper())
    x = x + c[2]
  end
  local scroll = CreateFrame("ScrollFrame", nil, list)
  scroll:SetPoint("TOPLEFT", 1, -30); scroll:SetPoint("BOTTOMRIGHT", -1, 4)
  local content = CreateFrame("Frame", nil, scroll); content:SetSize(1, 1)
  scroll:SetScript("OnSizeChanged", function(s, w) content:SetWidth(w) end)
  K.scrollbar(scroll, content)
  scroll:SetScrollChild(content); scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(s, delta)
    local max = math.max(0, content:GetHeight() - s:GetHeight())
    s:SetVerticalScroll(math.min(max, math.max(0, s:GetVerticalScroll() - delta * K.ROW_H * 2)))
  end)
  local empty = text(list, 12, COL.dim); empty:SetPoint("CENTER")
  local rows = {}
  local function row(i)
    if rows[i] then return rows[i] end
    local r = CreateFrame("Button", nil, content)
    r:SetHeight(K.ROW_H); r:SetPoint("TOPLEFT", 0, -(i - 1) * K.ROW_H); r:SetPoint("RIGHT", content, "RIGHT")
    r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(22, 22); r.icon:SetPoint("LEFT", 13, 0)
    r.cells = {}
    local cx = 14
    for c, col in ipairs(COLS) do
      local fs = text(r, c == 5 and 10 or 12, c == 5 and COL.muted or COL.text)
      fs:SetWidth(col[2] - 6 - (c == 1 and 30 or 0)); fs:SetJustifyH(col[3] or "RIGHT")
      fs:SetPoint("LEFT", cx + (c == 1 and 30 or 0) + (c == 5 and 10 or 0), 0)
      r.cells[c] = fs
      cx = cx + col[2]
    end
    r.btn = button(r, "Cancel", 86, 22, "primary", function() if r.data then Cancel.Do(r.data) end end)
    r.btn:SetPoint("RIGHT", -12, 0)
    r:SetScript("OnEnter", function(s) if s.data then GameTooltip:SetOwner(s, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink(s.data.link or ("item:" .. s.data.itemID)); GameTooltip:Show() end end)
    r:SetScript("OnLeave", GameTooltip_Hide)
    rows[i] = r
    return r
  end
  local LABEL = { checking = { "Wait…", "ghost" }, undercut = { "Cancel", "primary" }, cancelling = { "Cancelling…", "ghost" },
                  cancelled = { "Cancelled", "done" }, ok = { "OK", "done" }, keep = { "Keep", "ghost" } }
  function page:Refresh()
    state:Set(Cancel.state, Cancel.state == "Done" and COL.green or COL.muted)
    local n = Cancel.CountUndercut()
    nextBtn:SetLabel(n > 0 and string.format("Cancel next (%d left)", n) or "Cancel next")
    nextBtn:SetEnabled(n > 0)
    -- undercut ones first
    table.sort(Cancel.rows, function(a, b)
      local ua, ub = a.state == "undercut" and 0 or 1, b.state == "undercut" and 0 or 1
      if ua ~= ub then return ua < ub end
      return (a.name or "") < (b.name or "")
    end)
    for i, d in ipairs(Cancel.rows) do
      local r = row(i)
      r.data = d
      r.icon:SetTexture(C_Item.GetItemIconByID(d.itemID))
      r.cells[1]:SetText(FF.QualityColor(d.quality) .. (d.name or "?") .. "|r")
      r.cells[2]:SetText(tostring(d.qty))
      r.cells[3]:SetText(d.mine and FF.Money(d.mine) or "-")
      r.cells[4]:SetText(d.state == "checking" and "…" or (d.competitor and FF.Money(d.competitor) or "none"))
      r.cells[5]:SetText(d.note or "")
      local l = LABEL[d.state] or LABEL.checking
      r.btn:SetLabel(l[1]); r.btn:SetStyle(l[2])
      r.btn:SetEnabled(d.state == "undercut")
      r:Show()
    end
    for i = #Cancel.rows + 1, #rows do rows[i]:Hide(); rows[i].data = nil end
    content:SetHeight(math.max(1, #Cancel.rows * K.ROW_H))
    empty:SetShown(#Cancel.rows == 0)
    empty:SetText(Cancel.state == "No active auctions" and "You have no active auctions." or "Press Scan my auctions to check for undercuts.")
  end
  FF:On("FF_CANCEL_CHANGED", function() if page:IsShown() then page:Refresh() end end)
  return page
end)
