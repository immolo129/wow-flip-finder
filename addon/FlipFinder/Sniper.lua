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

Sniper.deals = {}
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

function Sniper.Stop()
  Sniper.running = false
  runID = runID + 1
  FF.Scan.Clear()
  FF:Fire("FF_SNIPER_STATUS", "Stopped")
end

function Sniper.Start(isRescan)
  if not isRescan then keepSince = nil end
  Sniper.Stop()
  Sniper.running = true
  runID = runID + 1
  local myRun = runID
  local cfg, group = FF.db.sniper, Sniper.Group(FF.db.sniper.group)
  Sniper.deals = {}
  FF:Fire("FF_DEALS_CHANGED")
  FF:Fire("FF_SNIPER_STATUS", "Browsing " .. group.name .. "…")
  FF.Log("sniper start: " .. group.key)

  -- 1. browse every category of the group, then pick candidates
  local results, pending = {}, #group.filters
  if pending == 0 then pending = 1 end
  local filters = #group.filters > 0 and group.filters or { false }
  for _, f in ipairs(filters) do
    FF.Scan.Browse(f and { f } or {}, function(res)
      if myRun ~= runID then return end
      for _, r in ipairs(res or {}) do table.insert(results, r) end
      pending = pending - 1
      if pending == 0 then Sniper.Candidates(results, myRun) end
    end)
  end
end

function Sniper.Candidates(results, myRun)
  local cfg, cut = FF.db.sniper, Sniper.Cut()
  local cands = {}
  for _, r in ipairs(results) do
    local key = r.itemKey
    if key and key.battlePetSpeciesID == 0 and r.minPrice and r.minPrice > 0 then
      local value = FF.Value(key.itemID)
      if value and r.minPrice <= value * cfg.maxPct / 100 and FF.PassesSales(key.itemID) then
        local info = itemInfo(key)
        if (info.quality or 1) >= cfg.minQuality then
          table.insert(cands, { key = key, value = value, info = info, sold = FF.Stats(key.itemID).soldPerDay or 0 })
        end
      end
    end
  end
  if cfg.fastFirst then table.sort(cands, function(a, b) return a.sold > b.sold end) end
  FF.Log(string.format("browse: %d items, %d candidates", #results, #cands))
  if #cands == 0 then return Sniper.Done(myRun, #results, 0) end

  -- 2. load each candidate's price list and apply the deal rules
  local left = #cands
  FF:Fire("FF_SNIPER_STATUS", string.format("Checking %d candidates…", left))
  for _, c in ipairs(cands) do
    local function done(ladder)
      if myRun ~= runID then return end
      left = left - 1
      local deal, why = Sniper.Evaluate(c.key.itemID, ladder, c.value, cfg, cut)
      if deal then
        deal.itemKey, deal.name, deal.quality, deal.link = c.key, c.info.name, c.info.quality, c.info.link
        deal.isCommodity = c.commodity
        deal.stats = FF.Stats(c.key.itemID)
        table.insert(Sniper.deals, deal)
        table.sort(Sniper.deals, function(a, b) return a.profit > b.profit end)
        FF:Fire("FF_DEALS_CHANGED")
        FF.Log(string.format("deal %s: buy %d for %d, profit %d", c.info.name, deal.buy, deal.cost, deal.profit))
      else
        FF.Log(string.format("skip %s: %s", c.info.name, tostring(why)))
      end
      FF:Fire("FF_SNIPER_STATUS", left > 0 and string.format("Checking candidates… %d left", left) or "Done")
      if left == 0 then Sniper.Done(myRun, #results, #cands) end
    end
    c.commodity = isCommodity(c.key, c.info)
    if c.commodity then FF.Scan.Commodity(c.key.itemID, done) else FF.Scan.Items(c.key, done) end
  end
end

-- "Keep scanning" is gentle on Blizzard's servers: a pause between rounds, and it stops by itself
-- after a while so it can't run for hours unattended.
local RESCAN_PAUSE = 15          -- seconds between rounds
local RESCAN_MAX = 30 * 60       -- stop keep-scanning after 30 minutes

function Sniper.Done(myRun, nItems, nCands)
  if myRun ~= runID then return end
  local msg = string.format("Done: %d items, %d candidates, %d deals", nItems, nCands, #Sniper.deals)
  if FF.db.sniper.autoRescan and Sniper.running then
    keepSince = keepSince or GetTime()
    if GetTime() - keepSince > RESCAN_MAX then
      keepSince, Sniper.running = nil, false
      FF:Fire("FF_SNIPER_STATUS", msg .. ". Keep scanning stopped after 30 minutes; press Scan to start again.")
      return
    end
    FF:Fire("FF_SNIPER_STATUS", msg .. string.format(". Next round in %d s.", RESCAN_PAUSE))
    C_Timer.After(RESCAN_PAUSE, function()
      if myRun == runID and Sniper.running and AuctionHouseFrame and AuctionHouseFrame:IsShown() then
        Sniper.Start(true)
      end
    end)
  else
    keepSince, Sniper.running = nil, false
    FF:Fire("FF_SNIPER_STATUS", msg)
  end
end

FF:On("AUCTION_HOUSE_CLOSED", function() Sniper.running = false; runID = runID + 1 end)
