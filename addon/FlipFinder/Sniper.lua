-- Flip Finder: the sniper. Finds deals like the commodity sniper in the video:
--   1. a quick browse of a group (every item's lowest price) picks out candidates below X% of the value
--      that pass the sales filter (daily sold or sell chance),
--   2. each candidate's full price list is loaded and the "resell gap" rule is applied: the cheap listings
--      (within the price tolerance of the cheapest) must be followed by a price jump of at least gap %,
--      otherwise there's a wall of listings at the same price and nothing to resell into.
local _, FF = ...
local Sniper = {}
FF.Sniper = Sniper

local C = Enum.ItemClass or {}
local CLASS = {
  Consumable = C.Consumable or 0, Weapon = C.Weapon or 2, Gem = C.Gem or 3, Armor = C.Armor or 4,
  Reagent = C.Reagent or 5, Tradegoods = C.Tradegoods or 7, ItemEnhancement = C.ItemEnhancement or 8,
  Recipe = C.Recipe or 9, Miscellaneous = C.Miscellaneous or 15,
}
Sniper.Groups = {
  { key = "materials",   name = "Reagents & materials", filters = { { classID = CLASS.Tradegoods }, { classID = CLASS.Reagent } } },
  { key = "consumables", name = "Consumables",          filters = { { classID = CLASS.Consumable } } },
  { key = "recipes",     name = "Recipes & patterns",   filters = { { classID = CLASS.Recipe } } },
  { key = "gear",        name = "Gear (weapons & armor)", filters = { { classID = CLASS.Weapon }, { classID = CLASS.Armor } } },
  { key = "other",       name = "Gems, enchants & misc", filters = { { classID = CLASS.Gem }, { classID = CLASS.ItemEnhancement }, { classID = CLASS.Miscellaneous } } },
  { key = "everything",  name = "Everything",           filters = {} },
}
-- a scan scope: one of the categories above, or one of your lists ("list:<id>")
function Sniper.Group(key)
  local listID = type(key) == "string" and tonumber(key:match("^list:(%d+)$"))
  if listID and FF.Lists then
    local l = FF.Lists.Get(listID)
    if l then return { key = key, name = "List: " .. l.name, list = listID, filters = {} } end
  end
  for _, g in ipairs(Sniper.Groups) do if g.key == key then return g end end
  return Sniper.Groups[1]
end

-- every scope a scan can use: the categories, then your lists
function Sniper.Scopes()
  local out = {}
  for _, g in ipairs(Sniper.Groups) do table.insert(out, { text = g.name, value = g.key }) end
  for _, l in ipairs(FF.db.lists or {}) do
    table.insert(out, { text = "List: " .. l.name .. " (" .. FF.Lists.Count(l) .. ")", value = "list:" .. l.id })
  end
  return out
end

Sniper.running = false
local runID = 0
local keepSince = nil   -- when "Keep scanning" started (see Sniper.Done)

-- AH cut: 5 % at the faction auction houses, 15 % at the neutral (Blackwater) one.
local NEUTRAL_ZONES = { ["Booty Bay"] = true, ["Gadgetzan"] = true, ["Everlook"] = true }
function Sniper.Cut()
  if NEUTRAL_ZONES[GetSubZoneText() or ""] or NEUTRAL_ZONES[GetZoneText() or ""] or NEUTRAL_ZONES[GetMinimapZoneText() or ""] then
    return 0.15
  end
  return 0.05
end

-- Posting fee (deposit) for reselling `qty` of an item, at the duration set on the Post page.
-- Commodities: Blizzard's own calculation. Other items need an item in the bags for that, so they
-- use the deposit rate learned from commodities (deposit / vendor sell price), or a default.
-- The deposit comes back when the item sells; it's counted as a cost so a deal still pays
-- if the auction expires once.
local DEFAULT_RATE = { 0.05, 0.20, 0.60 }   -- share of the vendor price for 2 / 8 / 24 h (estimate)
function Sniper.Deposit(itemID, qty, isCommodity)
  local d = FF.db.post.duration or 3
  local vendor = select(11, C_Item.GetItemInfo(itemID)) or 0
  if vendor == 0 and FF.Raw then vendor = FF.Raw("vendorSell", itemID) or 0 end
  local key = d .. ":" .. Sniper.Cut()
  if isCommodity then
    local ok, dep = pcall(C_AuctionHouse.CalculateCommodityDeposit, itemID, d, qty)
    if ok and type(dep) == "number" then
      if vendor > 0 and dep > 0 then
        FF.db.depositRate = FF.db.depositRate or {}
        FF.db.depositRate[key] = dep / (vendor * qty)
      end
      return dep
    end
  end
  local rate = FF.db.depositRate and FF.db.depositRate[key] or DEFAULT_RATE[d] or 0.6
  return math.floor(vendor * qty * rate)
end

-- the listings a deal buys (rows 1..last) and the next few after them, for the expanded row
local function ladderParts(ladder, last)
  local bought, after = {}, {}
  for j = 1, last do table.insert(bought, { price = ladder[j].price, qty = ladder[j].qty }) end
  for j = last + 1, math.min(#ladder, last + 5) do table.insert(after, { price = ladder[j].price, qty = ladder[j].qty }) end
  return bought, after
end

-- The deal rules. ladder: { {price=, qty=, [auctionID=, buyout=]}, ... } cheapest first.
-- Returns a deal table or nil (and a reason, for the log).
function Sniper.Evaluate(itemID, ladder, value, cfg, cut)
  local first = ladder and ladder[1]
  if not first then return nil, "no listings" end
  if not value or value <= 0 then return nil, "no value" end
  local maxPrice = value * cfg.maxPct / 100
  if first.price > maxPrice then return nil, "not cheap" end

  -- the cheap group: listings within the tolerance of the cheapest, and below the max price
  local limit = math.min(first.price * (1 + cfg.tolerance / 100), maxPrice)
  local i, units = 1, 0
  while ladder[i] and ladder[i].price <= limit do
    units = units + ladder[i].qty
    i = i + 1
  end
  local nextPrice = ladder[i] and ladder[i].price
  if units < cfg.minQty then return nil, "bait (too few units)" end

  -- buy the whole cheap group. Buying only part of it leaves the rest just as cheap, so there'd be
  -- nothing to resell into: if the group is over the max quantity or max spend, it's not a deal.
  if units > cfg.maxQty then return nil, string.format("cheap group of %d is over max quantity", units) end
  local buy, cost, top, auctions = 0, 0, 0, {}
  for j = 1, i - 1 do
    local row = ladder[j]
    buy, cost, top = buy + row.qty, cost + row.qty * row.price, row.price
    if row.auctionID then table.insert(auctions, { auctionID = row.auctionID, buyout = row.buyout, qty = row.qty }) end
  end
  if cost > cfg.maxSpend then return nil, "over max spend" end

  -- the gap above the cheap group (none above = the cheap group is all there is)
  local gap = nextPrice and (nextPrice / top - 1) or math.huge
  if gap * 100 < cfg.gapPct then return nil, string.format("gap %d%% too small", gap * 100) end

  -- resell just under the next listing, but never above the value
  local sell = nextPrice and math.min(nextPrice - 1, value) or value
  local deposit = Sniper.Deposit(itemID, buy, true)
  local profit = buy * sell * (1 - cut) - cost - deposit
  local roi = cost > 0 and profit / cost or 0
  if profit < cfg.minProfit then return nil, "profit too small" end
  if roi * 100 < cfg.minRoi then return nil, "ROI too small" end
  local rows, after = ladderParts(ladder, i - 1)
  return {
    itemID = itemID, buy = buy, cost = cost, top = top, sell = sell, profit = profit, roi = roi,
    gap = gap, value = value, auctions = auctions, cut = cut, deposit = deposit, rows = rows, after = after,
  }
end

local function itemInfo(itemKey)
  local info = C_AuctionHouse.GetItemKeyInfo(itemKey)
  local id = itemKey.itemID
  local name, link, quality = C_Item.GetItemInfo(id)
  return {
    name = (info and info.itemName) or name or ("Item " .. id),
    quality = (info and info.quality) or quality or 1,
    isCommodity = info and info.isCommodity,
    link = link,
  }
end

local function isCommodity(itemKey, info)
  if info.isCommodity ~= nil then return info.isCommodity end
  local ok, status = pcall(function() return C_AuctionHouse.GetItemCommodityStatus(itemKey.itemID) end)
  if not ok or not status then
    -- fall back to the item's stack size: stackable trade goods are commodities
    local _, _, _, _, _, _, _, stack = C_Item.GetItemInfo(itemKey.itemID)
    return (stack or 1) > 1
  end
  return status == (Enum.ItemCommodityStatus and Enum.ItemCommodityStatus.Commodity or 2)
end

-- The item sniper (recipes, gear, anything that isn't stackable): no gap rule, just listings below
-- maxPct of the value, cheapest first, up to maxQty, resold just under the next listing or at the value.
function Sniper.EvaluateItems(itemID, ladder, value, cfg, cut)
  if not ladder or not ladder[1] then return nil, "no listings" end
  if not value or value <= 0 then return nil, "no value" end
  local maxPrice = value * cfg.maxPct / 100
  local buy, cost, top, auctions, i = 0, 0, 0, {}, 1
  while ladder[i] and ladder[i].price <= maxPrice and buy + ladder[i].qty <= cfg.maxQty do
    local row = ladder[i]
    if cost + row.price * row.qty > cfg.maxSpend then break end
    buy, cost, top = buy + row.qty, cost + row.price * row.qty, row.price
    if row.auctionID then table.insert(auctions, { auctionID = row.auctionID, buyout = row.buyout, qty = row.qty }) end
    i = i + 1
  end
  if buy == 0 then return nil, "not cheap enough" end
  local nextPrice = ladder[i] and ladder[i].price
  local sell = nextPrice and math.min(nextPrice - 1, value) or value
  local deposit = Sniper.Deposit(itemID, buy, false)
  local profit = buy * sell * (1 - cut) - cost - deposit
  local roi = cost > 0 and profit / cost or 0
  if profit < cfg.minProfit then return nil, "profit too small" end
  if roi * 100 < cfg.minRoi then return nil, "ROI too small" end
  local rows, after = ladderParts(ladder, i - 1)
  return {
    itemID = itemID, buy = buy, cost = cost, top = top, sell = sell, profit = profit, roi = roi,
    gap = nextPrice and (nextPrice / top - 1) or math.huge, value = value, auctions = auctions, cut = cut, deposit = deposit,
    rows = rows, after = after,
  }
end

-- deals the player is buying (or bought) stay on the list whatever a new round finds
local BUSY = { starting = true, confirm = true, buying = true, refreshing = true, ready = true, bought = true }

-- Put a fresh result for an item into the list: a new deal replaces the old one, no deal removes it,
-- unless the player is in the middle of buying it.
function Sniper.Merge(mode, itemID, deal)
  local list = Sniper.deals[mode]
  for i, d in ipairs(list) do
    if d.itemID == itemID then
      if BUSY[d.state] then d.stale = nil; return false end
      if deal then
        deal.newAt, deal.expanded = d.newAt, d.expanded   -- keep its flash time and open/closed state
        list[i] = deal
        return "updated"
      end
      table.remove(list, i)
      return "removed"
    end
  end
  if deal then
    deal.newAt = GetTime()
    table.insert(list, deal)
    return "new"
  end
  return false
end

-- After a round: drop deals that weren't seen again (no longer cheap, or gone), except busy ones.
function Sniper.DropStale(mode)
  local list, kept = Sniper.deals[mode], {}
  for _, d in ipairs(list) do
    if not d.stale or BUSY[d.state] then d.stale = nil; table.insert(kept, d) end
  end
  Sniper.deals[mode] = kept
  FF:Fire("FF_DEALS_CHANGED", mode)
end

-- ---------- running a scan ----------
-- mode "commodity": stackables, gap rules (FF.db.sniper). mode "items": single auctions (FF.db.items).
Sniper.deals = { commodity = {}, items = {}, vendor = {} }
Sniper.progress = { commodity = {}, items = {}, vendor = {} }
Sniper.mode = nil
function Sniper.Config(mode)
  if mode == "items" then return FF.db.items end
  if mode == "vendor" then return FF.db.vendor end
  return FF.db.sniper
end

-- what a vendor pays for one (from the game's item data; nil until the item is loaded)
function Sniper.VendorPrice(itemID)
  -- the game only knows it once the item is loaded; TSM knows it for every item
  local sell = select(11, C_Item.GetItemInfo(itemID))
  if sell == nil then
    sell = FF.Raw("vendorSell", itemID)
    if sell == nil and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
  end
  return sell
end

-- The vendor sniper: listings below what a vendor pays (by at least the margin). Buy them all and sell
-- to any vendor: no reselling, no AH cut, no waiting. Value = the vendor price.
function Sniper.EvaluateVendor(itemID, ladder, vendor, cfg)
  if not ladder or not ladder[1] then return nil, "no listings" end
  if not vendor or vendor <= 0 then return nil, "no vendor price" end
  local maxPrice = vendor * (1 - cfg.marginPct / 100)
  local buy, cost, top, auctions, i = 0, 0, 0, {}, 1
  while ladder[i] and ladder[i].price <= maxPrice do
    local row = ladder[i]
    if cost + row.price * row.qty > cfg.maxSpend then break end
    buy, cost, top = buy + row.qty, cost + row.price * row.qty, row.price
    if row.auctionID then table.insert(auctions, { auctionID = row.auctionID, buyout = row.buyout, qty = row.qty }) end
    i = i + 1
  end
  if buy == 0 then return nil, "not below the vendor price" end
  local profit = buy * vendor - cost
  if profit < cfg.minProfit then return nil, "profit too small" end
  local rows, after = ladderParts(ladder, i - 1)
  return {
    itemID = itemID, buy = buy, cost = cost, top = top, sell = vendor, profit = profit, roi = cost > 0 and profit / cost or 0,
    gap = nil, value = vendor, auctions = auctions, cut = 0, rows = rows, after = after,
  }
end

-- session numbers for the stat cards
FF.session = { since = time(), opps = 0, seen = {}, bought = 0, invested = 0, projected = 0 }
function FF.ResetSession()
  FF.session = { since = time(), opps = 0, seen = {}, bought = 0, invested = 0, projected = 0 }
  FF:Fire("FF_SESSION_CHANGED")
end
function FF.RecordPurchase(deal)
  local s = FF.session
  s.bought, s.invested, s.projected = s.bought + 1, s.invested + deal.cost, s.projected + deal.profit
  FF.db.flipped[deal.itemID] = time()   -- the Post page can offer "only items I flipped"
  if FF.Ledger then FF.Ledger.AddBuy(deal) end
  FF:Fire("FF_SESSION_CHANGED")
end

local function progress(mode, p)
  Sniper.progress[mode] = p
  FF:Fire("FF_SNIPER_PROGRESS", mode, p)
end

function Sniper.Stop()
  Sniper.running = false
  runID = runID + 1
  FF.Scan.Clear()
  if Sniper.mode then
    local p = Sniper.progress[Sniper.mode]
    p.state = "Stopped"
    progress(Sniper.mode, p)
  end
end

function Sniper.Start(mode, isRescan)
  mode = mode or "commodity"
  if not isRescan then keepSince = nil end
  Sniper.Stop()
  Sniper.running, Sniper.mode = true, mode
  runID = runID + 1
  local myRun = runID
  local cfg = Sniper.Config(mode)
  local group = Sniper.Group(cfg.group)
  if isRescan then
    -- keep last round's deals on screen; each is re-checked this round (see Sniper.Merge)
    for _, d in ipairs(Sniper.deals[mode]) do d.stale = true end
  else
    Sniper.deals[mode] = {}
  end
  FF:Fire("FF_DEALS_CHANGED", mode)
  progress(mode, { state = "Browsing", group = group.name, total = 0, done = 0, listed = 0, deals = 0 })
  FF.Log("sniper start: " .. mode .. " " .. group.key)

  -- a list: no browsing, just check each item on it
  if group.list then
    local results = {}
    for _, id in ipairs(FF.Lists.ItemIDs(group.list)) do
      table.insert(results, { itemKey = C_AuctionHouse.MakeItemKey(id), fromList = true })
    end
    return Sniper.Candidates(mode, results, myRun)
  end

  -- 1. browse every category of the group, then pick candidates
  local results, filters = {}, #group.filters > 0 and group.filters or { false }
  local pending = #filters
  for _, f in ipairs(filters) do
    FF.Scan.Browse(f and { f } or {}, function(res)
      if myRun ~= runID then return end
      for _, r in ipairs(res or {}) do table.insert(results, r) end
      pending = pending - 1
      if pending == 0 then Sniper.Candidates(mode, results, myRun) end
    end)
  end
end

function Sniper.Candidates(mode, results, myRun)
  local cfg, cut, group = Sniper.Config(mode), Sniper.Cut(), Sniper.Group(Sniper.Config(mode).group)
  local cands = {}
  for _, r in ipairs(results) do
    local key = r.itemKey
    if r.fromList and key then
      local info = itemInfo(key)
      local commodity = isCommodity(key, info)
      local value = mode == "vendor" and Sniper.VendorPrice(key.itemID) or FF.Value(key.itemID)
      if value and value > 0 and (mode == "vendor" or commodity == (mode == "commodity")) then
        table.insert(cands, { key = key, value = value, info = info, commodity = commodity,
                              sold = FF.Stats(key.itemID).soldPerDay or 0 })
      end
    elseif mode == "vendor" and key and key.battlePetSpeciesID == 0 and r.minPrice and r.minPrice > 0 then
      local vendor = Sniper.VendorPrice(key.itemID)
      if vendor and vendor > 0 and r.minPrice <= vendor * (1 - cfg.marginPct / 100) then
        local info = itemInfo(key)
        table.insert(cands, { key = key, value = vendor, info = info, commodity = isCommodity(key, info),
                              sold = vendor - r.minPrice })   -- biggest margin first
      end
    elseif key and key.battlePetSpeciesID == 0 and r.minPrice and r.minPrice > 0 then
      local value = FF.Value(key.itemID)
      if value and r.minPrice <= value * cfg.maxPct / 100 and FF.PassesSales(key.itemID, cfg) then
        local info = itemInfo(key)
        local commodity = isCommodity(key, info)
        if (info.quality or 1) >= cfg.minQuality and commodity == (mode == "commodity") then
          table.insert(cands, { key = key, value = value, info = info, commodity = commodity,
                                sold = FF.Stats(key.itemID).soldPerDay or 0 })
        end
      end
    end
  end
  if cfg.fastFirst ~= false then table.sort(cands, function(a, b) return a.sold > b.sold end) end
  FF.Log(string.format("browse: %d items, %d candidates", #results, #cands))
  local p = { state = "Checking", group = group.name, items = #results, total = #cands, done = 0, listed = 0, deals = 0,
              pct = mode == "vendor" and (100 - cfg.marginPct) or cfg.maxPct,
              source = mode == "vendor" and "vendor price" or FF.SourceNames[FF.db.sniper.priceSource] }
  progress(mode, p)
  if #cands == 0 then return Sniper.Done(mode, myRun) end

  -- 2. load each candidate's price list and apply the deal rules
  for _, c in ipairs(cands) do
    local function done(ladder)
      if myRun ~= runID then return end
      p.done = p.done + 1
      p.current = c
      if ladder and ladder[1] then p.listed = p.listed + 1 end
      local evaluate = mode == "commodity" and Sniper.Evaluate or mode == "vendor" and Sniper.EvaluateVendor or Sniper.EvaluateItems
      local ok, deal, why = pcall(evaluate, c.key.itemID, ladder, c.value, cfg, cut)
      if not ok then
        FF.Log("error checking " .. tostring(c.info.name) .. ": " .. tostring(deal))
        deal, why = nil, "error (see log)"
      end
      if deal then
        deal.itemKey, deal.name, deal.quality, deal.link = c.key, c.info.name, c.info.quality, c.info.link
        deal.isCommodity, deal.stats, deal.mode = c.commodity, FF.Stats(c.key.itemID), mode
        if Sniper.Merge(mode, c.key.itemID, deal) == "new" then FF:Fire("FF_NEW_DEAL", mode, deal) end
        p.deals = p.deals + 1
        local id = c.key.itemID .. ":" .. deal.top
        if not FF.session.seen[id] then
          FF.session.seen[id] = true
          FF.session.opps = FF.session.opps + 1
          FF:Fire("FF_SESSION_CHANGED")
        end
        FF:Fire("FF_DEALS_CHANGED", mode)
        FF.Log(string.format("deal %s: buy %d for %d, profit %d", c.info.name, deal.buy, deal.cost, deal.profit))
      else
        if Sniper.Merge(mode, c.key.itemID, nil) then FF:Fire("FF_DEALS_CHANGED", mode) end
        FF.Log(string.format("skip %s: %s", c.info.name, tostring(why)))
      end
      progress(mode, p)
      if p.done == p.total then Sniper.Done(mode, myRun) end
    end
    if c.commodity then FF.Scan.Commodity(c.key.itemID, done) else FF.Scan.Items(c.key, done) end
  end
end

-- "Keep scanning": a short pause between rounds, and it stops by itself after 30 minutes so it
-- can't run for hours unattended. Blizzard's throttle paces the queries themselves.
local RESCAN_PAUSE = 5
local RESCAN_MAX = 30 * 60

function Sniper.Done(mode, myRun)
  if myRun ~= runID then return end
  local p = Sniper.progress[mode]
  p.current = nil
  Sniper.DropStale(mode)
  if Sniper.Config(mode).autoRescan and Sniper.running then
    keepSince = keepSince or GetTime()
    if GetTime() - keepSince > RESCAN_MAX then
      keepSince, Sniper.running = nil, false
      p.state = "Done"
      p.note = "Keep scanning stopped after 30 minutes. Press Start scan to go again."
      return progress(mode, p)
    end
    p.state = "Waiting"
    p.note = string.format("Next round in %d s", RESCAN_PAUSE)
    progress(mode, p)
    C_Timer.After(RESCAN_PAUSE, function()
      if myRun == runID and Sniper.running and AuctionHouseFrame and AuctionHouseFrame:IsShown() then
        Sniper.Start(mode, true)
      end
    end)
  else
    keepSince, Sniper.running = nil, false
    p.state = "Done"
    progress(mode, p)
  end
end

FF:On("FF_SCAN_STALLED", function()
  if not Sniper.running or not Sniper.mode then return end
  local mode = Sniper.mode
  Sniper.running = false
  runID = runID + 1
  local p = Sniper.progress[mode]
  p.state, p.current = "Done", nil
  p.note = "The auction house stopped answering (busy with another search?). Press Start scan again."
  progress(mode, p)
end)

FF:On("AUCTION_HOUSE_CLOSED", function()
  Sniper.running = false
  runID = runID + 1
  if Sniper.mode then local p = Sniper.progress[Sniper.mode]; p.state = "Idle"; p.current = nil end
end)
