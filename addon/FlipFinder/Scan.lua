-- Flip Finder: talks to the auction house. One query at a time, waiting for Blizzard's throttle.
-- Searching is allowed without clicks (like TSM and Auctionator do); buying is not done here.
local _, FF = ...
local Scan = {}
FF.Scan = Scan

local AH = C_AuctionHouse
local queue, job = {}, nil
local TIMEOUT = 15      -- seconds to wait for an answer before moving on
local PRICE_SORT = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }

local function isOpen()
  return AuctionHouseFrame and AuctionHouseFrame:IsShown()
end

local function finish(result)
  local j = job
  job = nil
  if j and j.cb then
    local ok, err = pcall(j.cb, result)
    if not ok then FF.Log("scan callback: " .. tostring(err)); geterrorhandler()(err) end
  end
  Scan.Next()
end

function Scan.Next()
  if job or #queue == 0 then return end
  if not isOpen() then queue = {}; return end
  if not AH.IsThrottledMessageSystemReady() then
    C_Timer.After(0.2, Scan.Next)  -- also woken by AUCTION_HOUSE_THROTTLED_SYSTEM_READY
    return
  end
  job = table.remove(queue, 1)
  job.started = GetTime()
  local thisJob = job
  C_Timer.After(TIMEOUT, function()
    if job == thisJob then FF.Log("timeout: " .. thisJob.kind); finish(nil) end
  end)
  if job.kind == "browse" then
    job.results = {}
    AH.SendBrowseQuery({ searchString = "", filters = {}, itemClassFilters = job.classFilters or {}, sorts = PRICE_SORT })
  elseif job.kind == "commodity" then
    AH.SendSearchQuery(AH.MakeItemKey(job.itemID), PRICE_SORT, true)
  elseif job.kind == "items" then
    AH.SendSearchQuery(job.itemKey, PRICE_SORT, true)
  end
end

local function add(j)
  table.insert(queue, j)
  Scan.Next()
end

function Scan.Clear()
  queue = {}
  job = nil
end

function Scan.Busy()
  return job ~= nil or #queue > 0
end

-- Browse: every item for sale in these categories, with its lowest price. Fast: one row per item.
-- cb(list of { itemKey, minPrice, totalQuantity })
function Scan.Browse(classFilters, cb)
  add({ kind = "browse", classFilters = classFilters, cb = cb })
end

-- Commodity: the price ladder of a stackable item. cb({ {price=, qty=}, ... } cheapest first) or nil
function Scan.Commodity(itemID, cb)
  add({ kind = "commodity", itemID = itemID, cb = cb })
end

-- Items: the individual auctions of a non-stackable item. cb({ {price=, qty=, auctionID=, buyout=}, ... }) or nil
function Scan.Items(itemKey, cb)
  add({ kind = "items", itemKey = itemKey, cb = cb })
end

-- Same as Items, but ahead of everything else in the queue (used right before buying).
function Scan.ItemsNow(itemKey, cb)
  table.insert(queue, 1, { kind = "items", itemKey = itemKey, cb = cb })
  Scan.Next()
end

-- ---------- answers ----------
local function browseDone()
  local res = AH.GetBrowseResults() or {}
  finish(res)
end

local function browseUpdate()
  if not job or job.kind ~= "browse" then return end
  if AH.HasFullBrowseResults() then
    browseDone()
  else
    -- more pages: ask for them when the throttle allows
    local function more()
      if not job or job.kind ~= "browse" then return end
      if AH.IsThrottledMessageSystemReady() then AH.RequestMoreBrowseResults() else C_Timer.After(0.2, more) end
    end
    more()
  end
end
FF:On("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", browseUpdate)
FF:On("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", browseUpdate)
FF:On("AUCTION_HOUSE_BROWSE_FAILURE", function()
  if job and job.kind == "browse" then FF.Log("browse failed"); finish(nil) end
end)

FF:On("COMMODITY_SEARCH_RESULTS_UPDATED", function(itemID)
  if not job or job.kind ~= "commodity" or itemID ~= job.itemID then return end
  local ladder = {}
  for i = 1, AH.GetNumCommoditySearchResults(itemID) do
    local r = AH.GetCommoditySearchResultInfo(itemID, i)
    -- skip our own auctions: we can't buy them
    if r and r.unitPrice and (r.numOwnerItems or 0) < (r.quantity or 0) then
      table.insert(ladder, { price = r.unitPrice, qty = r.quantity - (r.numOwnerItems or 0) })
    end
  end
  finish(ladder)
end)

FF:On("ITEM_SEARCH_RESULTS_UPDATED", function(itemKey)
  if not job or job.kind ~= "items" or not itemKey or itemKey.itemID ~= job.itemKey.itemID then return end
  local ladder = {}
  for i = 1, AH.GetNumItemSearchResults(job.itemKey) do
    local r = AH.GetItemSearchResultInfo(job.itemKey, i)
    if r and r.buyoutAmount and r.buyoutAmount > 0 and not r.containsOwnerItem then
      local q = math.max(1, r.quantity or 1)
      table.insert(ladder, { price = math.ceil(r.buyoutAmount / q), qty = q, auctionID = r.auctionID, buyout = r.buyoutAmount })
    end
  end
  table.sort(ladder, function(a, b) return a.price < b.price end)
  finish(ladder)
end)

FF:On("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function() Scan.Next() end)
FF:On("AUCTION_HOUSE_CLOSED", function() Scan.Clear(); FF:Fire("FF_SCAN_STOPPED") end)
