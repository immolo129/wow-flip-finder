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
function Sniper.Group(key)
  for _, g in ipairs(Sniper.Groups) do if g.key == key then return g end end
  return Sniper.Groups[1]
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
  local profit = buy * sell * (1 - cut) - cost
  local roi = cost > 0 and profit / cost or 0
  if profit < cfg.minProfit then return nil, "profit too small" end
  if roi * 100 < cfg.minRoi then return nil, "ROI too small" end
  return {
    itemID = itemID, buy = buy, cost = cost, top = top, sell = sell, profit = profit, roi = roi,
    gap = gap, value = value, auctions = auctions, cut = cut,
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
  local status = C_AuctionHouse.GetItemCommodityStatus and C_AuctionHouse.GetItemCommodityStatus(itemKey.itemID)
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
  local profit = buy * sell * (1 - cut) - cost
  local roi = cost > 0 and profit / cost or 0
  if profit < cfg.minProfit then return nil, "profit too small" end
  if roi * 100 < cfg.minRoi then return nil, "ROI too small" end
  return {
    itemID = itemID, buy = buy, cost = cost, top = top, sell = sell, profit = profit, roi = roi,
    gap = nextPrice and (nextPrice / top - 1) or math.huge, value = value, auctions = auctions, cut = cut,
  }
end

-- ---------- running a scan ----------
-- mode "commodity": stackables, gap rules (FF.db.sniper). mode "items": single auctions (FF.db.items).
Sniper.deals = { commodity = {}, items = {} }
Sniper.progress = { commodity = {}, items = {} }
Sniper.mode = nil
function Sniper.Config(mode) return mode == "items" and FF.db.items or FF.db.sniper end

-- session numbers for the stat cards
FF.session = { since = time(), opps = 0, seen = {}, bought = 0, invested = 0, projected = 0 }
function FF.ResetSession()
  FF.session = { since = time(), opps = 0, seen = {}, bought = 0, invested = 0, projected = 0 }
  FF:Fire("FF_SESSION_CHANGED")
end
function FF.RecordPurchase(deal)
  local s = FF.session
  s.bought, s.invested, s.projected = s.bought + 1, s.invested + deal.cost, s.projected + deal.profit
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
  Sniper.deals[mode] = {}
  FF:Fire("FF_DEALS_CHANGED", mode)
  progress(mode, { state = "Browsing", group = group.name, total = 0, done = 0, listed = 0, deals = 0 })
  FF.Log("sniper start: " .. mode .. " " .. group.key)

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
    if key and key.battlePetSpeciesID == 0 and r.minPrice and r.minPrice > 0 then
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
              pct = cfg.maxPct, source = FF.SourceNames[FF.db.sniper.priceSource] }
  progress(mode, p)
  if #cands == 0 then return Sniper.Done(mode, myRun) end

  -- 2. load each candidate's price list and apply the deal rules
  for _, c in ipairs(cands) do
    local function done(ladder)
      if myRun ~= runID then return end
      p.done = p.done + 1
      p.current = c
      if ladder and ladder[1] then p.listed = p.listed + 1 end
      local evaluate = mode == "commodity" and Sniper.Evaluate or Sniper.EvaluateItems
      local deal, why = evaluate(c.key.itemID, ladder, c.value, cfg, cut)
      if deal then
        deal.itemKey, deal.name, deal.quality, deal.link = c.key, c.info.name, c.info.quality, c.info.link
        deal.isCommodity, deal.stats, deal.mode = c.commodity, FF.Stats(c.key.itemID), mode
        local list = Sniper.deals[mode]
        table.insert(list, deal)
        table.sort(list, function(a, b) return a.profit > b.profit end)
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

FF:On("AUCTION_HOUSE_CLOSED", function()
  Sniper.running = false
  runID = runID + 1
  if Sniper.mode then local p = Sniper.progress[Sniper.mode]; p.state = "Idle"; p.current = nil end
end)
