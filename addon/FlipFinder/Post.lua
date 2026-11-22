-- Flip Finder: posting. Scans your bags, checks each item's competition and works out a price
-- (undercut the cheapest, within your min/max % of value). Posting itself is ONE CLICK PER AUCTION:
-- Blizzard only lets addons post from a real click, so "Post next" posts one item per press.
local _, FF = ...
local AH = C_AuctionHouse
local Post = { rows = {}, state = "Idle" }
FF.Post = Post
local DURATIONS = { { text = "Duration: 2 hours", value = 1 }, { text = "Duration: 8 hours", value = 2 }, { text = "Duration: 24 hours", value = 3 } }
local posting = nil  -- the row waiting for the server's answer

local function commodityStatus(loc)
  local ok, status = pcall(AH.GetItemCommodityStatus, loc)
  local enum = Enum.ItemCommodityStatus
  return ok and enum and status == enum.Commodity
end

-- last bag to look in: the backpack + 4 bags, plus the reagent bag (bag 5) when the client has one.
-- Reagents like Essence of Water go straight into the reagent bag, so it must be included.
local function lastBag()
  return NUM_TOTAL_EQUIPPED_BAG_SLOTS or ((NUM_BAG_SLOTS or 4) + (NUM_REAGENTBAG_SLOTS or 1))
end

-- everything in the bags that can go on the auction house; commodities merged per item.
-- Items that can't be listed go into `skipped` with the reason.
local function bagItems(skipped)
  local out, merged, seen = {}, {}, {}
  for bag = 0, lastBag() do
    for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.itemID and info.isBound then
        if not seen[info.itemID] then seen[info.itemID] = true; table.insert(skipped, { itemID = info.itemID, link = info.hyperlink, reason = "Soulbound" }) end
      elseif info and info.itemID then
        local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
        local okValid, valid = pcall(AH.IsSellItemValid, loc, false)
        if not (okValid and valid) then
          if not seen[info.itemID] then
            seen[info.itemID] = true
            table.insert(skipped, { itemID = info.itemID, link = info.hyperlink, reason = okValid and "The AH won't take it" or "AH check failed" })
          end
        else
          if commodityStatus(loc) then
            local r = merged[info.itemID]
            if r then
              r.qty = r.qty + (info.stackCount or 1)
            else
              r = { itemID = info.itemID, isCommodity = true, qty = info.stackCount or 1, loc = loc, link = info.hyperlink, quality = info.quality }
              merged[info.itemID] = r
              table.insert(out, r)
            end
          else
            local ok, key = pcall(AH.GetItemKeyFromItem, loc)
            table.insert(out, { itemID = info.itemID, isCommodity = false, qty = info.stackCount or 1, loc = loc,
                                link = info.hyperlink, quality = info.quality, itemKey = ok and key or AH.MakeItemKey(info.itemID) })
          end
        end
      end
    end
  end
  return out
end

-- price for one row from the competition. -> price (per unit) and a note, or nil and the reason
function Post.Price(row, ladder)
  local cfg = FF.db.post
  local v = row.value
  local floor, normal, cap = v * cfg.floorPct / 100, v * cfg.normalPct / 100, v * cfg.maxPct / 100
  local vendor = select(11, C_Item.GetItemInfo(row.itemID)) or 0
  local lowest = ladder and ladder[1] and ladder[1].price
  row.lowest = lowest
  local price, note
  row.floor = floor
  if not lowest then
    price, note, row.why = normal, "No competition", "Nobody else is selling it, so it's listed at your normal % of value."
  else
    price, note, row.why = lowest - cfg.undercut, "Undercut", "1 step below the cheapest other listing."
    if price > cap then price, note, row.why = cap, "Capped at max %", "The cheapest other listing is above your max % of value." end
  end
  price = math.floor(price)
  if price < floor then
    row.why = "The cheapest other listing is below your minimum (" .. FF.Money(floor) .. " = your min % of value), so it stays in your bags."
    return nil, "Below your min: kept"
  end
  if vendor > 0 and price <= vendor then
    row.why = "A vendor pays " .. FF.Money(vendor) .. ", at least as much as you'd get here."
    return nil, "Vendor pays more: kept"
  end
  return price, note
end

local function deposit(row)
  local d = FF.db.post.duration
  local ok, v
  if row.isCommodity then ok, v = pcall(AH.CalculateCommodityDeposit, row.itemID, d, row.qty)
  else ok, v = pcall(AH.CalculateItemDeposit, row.loc, d, row.qty) end
  return ok and v or nil
end

local function changed() FF:Fire("FF_POST_CHANGED") end

function Post.Scan()
  if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then FF.Kit.status("Open the auction house first."); return end
  local cfg = FF.db.post
  Post.rows = {}
  local skipped, kept, inBags = {}, {}, {}
  local function nameOf(r) return C_Item.GetItemNameByID(r.itemID) or (r.link and r.link:match("%[(.-)%]")) or ("Item " .. r.itemID) end
  for _, r in ipairs(bagItems(skipped)) do
    inBags[r.itemID] = true
    r.value = FF.Value(r.itemID)
    r.name = nameOf(r)
    -- worth listing if the whole stack is worth the minimum (one Heavy Leather is cheap, 35 aren't)
    if not r.value then
      r.state, r.note, r.why = "skip", "No TSM price", "TSM has no price for this item yet. Open the TSM app so it syncs, then /reload."
      table.insert(kept, r)
    elseif cfg.onlyFlipped and not FF.db.flipped[r.itemID] then
      r.state, r.note, r.why = "skip", "Not flipped", "\"Only items I flipped\" is on and you didn't buy this with Flip Finder."
      table.insert(kept, r)
    elseif r.value * r.qty < cfg.minValue then
      r.state, r.note = "skip", "Under min value"
      r.why = "The stack is worth " .. FF.Money(r.value * r.qty) .. ", under your minimum of " .. FF.Money(cfg.minValue) .. ". Lower \"Min stack value\" to list it."
      table.insert(kept, r)
    else
      r.state = "checking"
      table.insert(Post.rows, r)
    end
  end
  for _, s in ipairs(skipped) do
    s.name = nameOf(s)
    FF.Log("post: left out " .. s.name .. " (" .. s.itemID .. "): " .. s.reason)
  end
  for _, r in ipairs(kept) do FF.Log("post: kept " .. r.name .. " x" .. r.qty .. ": " .. r.note) end
  -- bought with the sniper in the last 2 days but not in the bags? It's waiting in the mailbox.
  local inMail = 0
  for id, t in pairs(FF.db.flipped) do
    if type(t) == "number" and time() - t < 2 * 86400 and not inBags[id] then inMail = inMail + 1 end
  end
  Post.hint = inMail > 0 and (inMail .. " item(s) you bought aren't in your bags: purchases arrive in the mailbox. Collect them, then scan again.") or nil
  Post.state = #Post.rows > 0 and "Checking prices" or "Nothing to post"
  Post.left = #Post.rows
  for _, r in ipairs(kept) do table.insert(Post.rows, r) end
  FF.Log(string.format("post scan: %d to price, %d kept, %d left out (bags 0-%d)", Post.left, #kept, #skipped, lastBag()))
  if Post.hint then FF.Kit.status(Post.hint) end
  changed()
  for _, r in ipairs(Post.rows) do if r.state == "checking" then
    local function priced(ladder)
      r.price, r.note = Post.Price(r, ladder)
      r.deposit = r.price and deposit(r) or nil
      r.state = r.price and "ready" or "skip"
      Post.left = Post.left - 1
      if Post.left == 0 then Post.state = "Ready" end
      changed()
    end
    if r.isCommodity then FF.Scan.Commodity(r.itemID, priced) else FF.Scan.Items(r.itemKey, priced) end
  end end
  if Post.left == 0 then Post.state = #kept > 0 and "Nothing to post" or Post.state; changed() end
end

-- MUST be called from a click (Blizzard requires one for posting): posts this one row.
function Post.Do(row)
  local d = FF.db.post.duration
  if row.state == "warn" then
    if row.isCommodity then AH.ConfirmPostCommodity(row.loc, d, row.qty, row.price)
    else AH.ConfirmPostItem(row.loc, d, row.qty, nil, row.price * row.qty) end
    row.state, posting = "posting", row
    return changed()
  end
  if row.state ~= "ready" or not row.price then return end
  if not C_Item.DoesItemExist(row.loc) or C_Item.GetItemID(row.loc) ~= row.itemID then
    row.state, row.note = "skip", "Moved in your bags: scan again"
    return changed()
  end
  row.state, posting = "posting", row
  if row.isCommodity then AH.PostCommodity(row.loc, d, row.qty, row.price)
  else AH.PostItem(row.loc, d, row.qty, nil, row.price * row.qty) end
  FF.Log(string.format("post %s x%d at %d", row.name, row.qty, row.price))
  changed()
end

-- the next row "Post next" would post, or nil
function Post.NextRow()
  for _, r in ipairs(Post.rows) do if r.state == "warn" then return r end end
  for _, r in ipairs(Post.rows) do if r.state == "ready" then return r end end
end

FF:On("AUCTION_HOUSE_AUCTION_CREATED", function()
  if posting then posting.state = "posted"; posting = nil; changed() end
end)
FF:On("AUCTION_HOUSE_POST_WARNING", function()
  if posting then
    posting.state, posting.note = "warn", "The game asks to confirm this price: click Confirm"
    posting = nil
    changed()
  end
end)
FF:On("AUCTION_HOUSE_SHOW_ERROR", function()
  if posting then posting.state, posting.note = "skip", "The game refused this post"; posting = nil; changed() end
end)
FF:On("AUCTION_HOUSE_CLOSED", function() posting = nil; Post.rows = {}; Post.state = "Idle" end)
FF:On("FF_SCAN_STALLED", function()
  local any = false
  for _, r in ipairs(Post.rows) do
    if r.state == "checking" then r.state, r.note, r.why, any = "skip", "AH didn't answer", "Press Scan bags again.", true end
  end
  if any then Post.state = "Scan again"; changed() end
end)

-- ---------- page ----------
FF.UI.RegisterPage("post", function(parent)
  local K = FF.Kit
  local COL, text, box, button = K.COL, K.text, K.box, K.flatButton
  local cfg = function() return FF.db.post end
  local page = CreateFrame("Frame", nil, parent)
  page:SetAllPoints()
  local title = text(page, 18, COL.text); title:SetPoint("TOPLEFT", 20, -16); title:SetText("Post")
  local sub = text(page, 11, COL.muted); sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -5)
  sub:SetText("Prices your bags against the competition. One click posts one auction (Blizzard requires a click per post).")

  -- settings
  local set = box(page, COL.card, COL.line)
  set:SetPoint("TOPLEFT", 20, -62); set:SetPoint("RIGHT", -20, 0); set:SetHeight(124)
  local fields = {
    K.numberField(set, "Min % of value", cfg, "floorPct", nil, "Never post below this. If the cheapest competitor is lower, the item stays in your bags."),
    K.numberField(set, "Normal % (no competition)", cfg, "normalPct", nil, "Price when nobody else is selling it."),
    K.numberField(set, "Max % of value", cfg, "maxPct", nil, "Never post above this."),
    K.numberField(set, "Undercut (copper)", cfg, "undercut", nil, "How far below the cheapest competitor to post."),
  }
  for i, f in ipairs(fields) do f:SetPoint("TOPLEFT", 14 + (i - 1) * 186, -12) end
  local minv = K.numberField(set, "Min stack value (gold)", cfg, "minValue", 10000, "Skip items whose whole stack in your bags is worth less than this.")
  minv:SetPoint("TOPLEFT", 14, -66)
  table.insert(fields, minv)
  local dur = K.dropdown(set, 170, function() return DURATIONS end,
    function() return DURATIONS[cfg().duration] and DURATIONS[cfg().duration].text or "Duration" end, nil,
    function(v) cfg().duration = v end)
  dur:SetPoint("TOPLEFT", 200, -84)
  local only = K.checkbox(set, "Only items I flipped", function() return cfg().onlyFlipped end, function(v) cfg().onlyFlipped = v end)
  only:SetPoint("TOPLEFT", 390, -88)

  -- actions
  local scan = button(page, "Scan bags", 110, 28, "ghost", function() Post.Scan() end)
  scan:SetPoint("TOPLEFT", 20, -198)
  local nextBtn = button(page, "Post next", 160, 28, "primary", function()
    local r = Post.NextRow()
    if r then Post.Do(r) end
  end)
  nextBtn:SetPoint("LEFT", scan, "RIGHT", 10, 0)
  local state = K.pill(page, "Idle"); state:SetPoint("LEFT", nextBtn, "RIGHT", 12, 0)

  -- list
  local list = box(page, COL.card, COL.line)
  list:SetPoint("TOPLEFT", 20, -236); list:SetPoint("BOTTOMRIGHT", -20, 34)
  local COLS = { { "Item", 200, "LEFT" }, { "Qty", 40 }, { "Cheapest", 86 }, { "Post at", 86 }, { "Deposit", 70 }, { "", 170, "LEFT" } }
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
      local fs = text(r, c == 6 and 10 or 12, c == 6 and COL.muted or COL.text)
      fs:SetWidth(col[2] - 6 - (c == 1 and 30 or 0)); fs:SetJustifyH(col[3] or "RIGHT")
      fs:SetPoint("LEFT", cx + (c == 1 and 30 or 0) + (c == 6 and 10 or 0), 0)
      r.cells[c] = fs
      cx = cx + col[2]
    end
    r.btn = button(r, "Post", 86, 22, "primary", function() if r.data then Post.Do(r.data) end end)
    r.btn:SetPoint("RIGHT", -12, 0)
    r:SetScript("OnEnter", function(s)
      local d = s.data
      if not d then return end
      GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
      GameTooltip:SetHyperlink(d.link or ("item:" .. d.itemID))
      if d.why then GameTooltip:AddLine(" "); GameTooltip:AddLine(d.why, 0.95, 0.72, 0.11, true) end
      if d.floor then GameTooltip:AddDoubleLine("Your minimum", FF.Money(d.floor), 1, 1, 1) end
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", GameTooltip_Hide)
    rows[i] = r
    return r
  end

  local LABEL = { checking = { "Wait…", "ghost" }, ready = { "Post", "primary" }, posting = { "Posting…", "ghost" },
                  posted = { "Posted", "done" }, skip = { "Kept", "bad" }, warn = { "Confirm", "primary" } }
  function page:Refresh()
    for _, f in ipairs(fields) do f.Refresh() end
    dur:Refresh(); only:Refresh()
    state:Set(Post.state, Post.state == "Ready" and COL.green or COL.muted)
    local nr = Post.NextRow()
    nextBtn:SetLabel(nr and ("Post next: " .. (nr.name or "")):sub(1, 22) or "Post next")
    nextBtn:SetEnabled(nr ~= nil)
    for i, d in ipairs(Post.rows) do
      local r = row(i)
      r.data = d
      r.icon:SetTexture(C_Item.GetItemIconByID(d.itemID))
      r.cells[1]:SetText(FF.QualityColor(d.quality) .. (d.name or "?") .. "|r")
      r.cells[2]:SetText(tostring(d.qty))
      r.cells[3]:SetText(d.state == "checking" and "…" or (d.lowest and FF.Money(d.lowest) or "none"))
      r.cells[4]:SetText(d.price and FF.Money(d.price) or "-")
      r.cells[5]:SetText(d.deposit and FF.Money(d.deposit) or "-")
      r.cells[6]:SetText(d.note or "")
      local l = LABEL[d.state] or LABEL.checking
      r.btn:SetLabel(l[1]); r.btn:SetStyle(l[2])
      r.btn:SetEnabled(d.state == "ready" or d.state == "warn")
      r:Show()
    end
    for i = #Post.rows + 1, #rows do rows[i]:Hide(); rows[i].data = nil end
    content:SetHeight(math.max(1, #Post.rows * K.ROW_H))
    empty:SetShown(#Post.rows == 0)
    empty:SetText(Post.state == "Nothing to post" and "Nothing in your bags matches these settings." or "Press Scan bags to price what you can sell.")
  end
  FF:On("FF_POST_CHANGED", function() if page:IsShown() then page:Refresh() end end)
  FF:On("BAG_UPDATE_DELAYED", function() if page:IsShown() then page:Refresh() end end)
  return page
end)
