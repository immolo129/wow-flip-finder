-- Flip Finder: talks to the auction house. One query at a time, waiting for Blizzard's throttle.
-- Searching is allowed without clicks (like TSM and Auctionator do); buying is not done here.
local _, FF = ...
local Scan = {}
FF.Scan = Scan

local AH = C_AuctionHouse
local queue, job = {}, nil
local TIMEOUT = 8       -- seconds to wait for an answer before retrying
local MAX_TRIES = 2     -- send a query at most twice before skipping it
local STALL_LIMIT = 4   -- this many skipped queries in a row: the AH stopped answering, give up
local unanswered = 0
local PRICE_SORT = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }

local function isOpen()
  return AuctionHouseFrame and AuctionHouseFrame:IsShown()
end

local function finish(result)
  local j = job
  job = nil
  if result ~= nil then unanswered = 0 end
  -- tell price history and alerts what was seen (lowest price per item)
  if j and result then
    if j.kind == "browse" then
      FF:Fire("FF_BROWSE_SEEN", result)
    elseif j.kind == "commodity" then
      FF:Fire("FF_PRICE_SEEN", j.itemID, result[1] and result[1].price)
    elseif j.kind == "items" and j.itemKey then
      FF:Fire("FF_PRICE_SEEN", j.itemKey.itemID, result[1] and result[1].price)
    end
  end
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
  Scan.Send(job)
end

-- The auction house stopped answering (often because Blizzard's own window is searching at the same
-- time): drop everything and tell the pages, instead of crawling on with timeouts.
function Scan.Stall()
  FF.Log("auction house stopped answering; scan stopped")
  job, queue, unanswered = nil, {}, 0
  FF:Fire("FF_SCAN_STALLED")
end

-- (re)send the current job's query when the throttle allows
function Scan.Resend()
  local j = job
  if not j then return end
  if not AH.IsThrottledMessageSystemReady() then
    C_Timer.After(0.2, function() if job == j then Scan.Resend() end end)
    return
  end
  Scan.Send(j)
end

-- (re)start the wait for an answer. Big browse results arrive in many pages, so every page restarts it.
local function arm(j)
  local token = {}
  j.token = token
  C_Timer.After(TIMEOUT, function()
    if job ~= j or j.token ~= token then return end
    if j.kind == "browse" and j.gotPage then
      -- the pages stopped coming: use what arrived rather than nothing
      local res = AH.GetBrowseResults() or {}
      FF.Log("browse: no more pages after " .. #res .. " items, using those")
      unanswered = 0
      return finish(res)
    end
    if j.tries < MAX_TRIES then
      FF.Log("no answer, asking again: " .. j.kind)
      Scan.Resend()
    else
      FF.Log("timeout: " .. j.kind)
      unanswered = unanswered + 1
      if unanswered >= STALL_LIMIT then Scan.Stall() else finish(nil) end
    end
  end)
end

function Scan.Send(j)
  j.tries = (j.tries or 0) + 1
  arm(j)
  if job.kind == "browse" then
    job.results = {}
    AH.SendBrowseQuery({ searchString = "", filters = {}, itemClassFilters = job.classFilters or {}, sorts = PRICE_SORT })
  elseif job.kind == "commodity" then
    AH.SendSearchQuery(AH.MakeItemKey(job.itemID), PRICE_SORT, true)
  elseif job.kind == "items" then
    AH.SendSearchQuery(job.itemKey, PRICE_SORT, true)
  elseif job.kind == "owned" then
    AH.QueryOwnedAuctions({ { sortOrder = Enum.AuctionHouseSortOrder.Name, reverseSort = false } })
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

-- Your own auctions. cb(list of OwnedAuctionInfo) or nil
function Scan.Owned(cb)
  add({ kind = "owned", cb = cb })
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
  job.gotPage = true
  arm(job)   -- a page arrived: wait afresh for the next one
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
  -- the ladder holds other players' listings (we can't buy our own); ladder.own maps our own
  -- auction ids to their unit price (used by the cancel scan)
  local ladder = { own = {} }
  for i = 1, AH.GetNumCommoditySearchResults(itemID) do
    local r = AH.GetCommoditySearchResultInfo(itemID, i)
    if r and r.unitPrice then
      local mine = r.numOwnerItems or 0
      if mine > 0 and r.auctionID then ladder.own[r.auctionID] = r.unitPrice end
      if mine < (r.quantity or 0) then
        table.insert(ladder, { price = r.unitPrice, qty = r.quantity - mine })
      end
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

FF:On("OWNED_AUCTIONS_UPDATED", function()
  if not job or job.kind ~= "owned" then return end
  local list = {}
  for i = 1, AH.GetNumOwnedAuctions() do
    local a = AH.GetOwnedAuctionInfo(i)
    if a then table.insert(list, a) end
  end
  finish(list)
end)

FF:On("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function() Scan.Next() end)
-- Blizzard dropped our query (too busy): send it again right away instead of waiting for the timeout
FF:On("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED", function()
  if job then FF.Log("query dropped, sending again: " .. job.kind); Scan.Resend() end
end)
FF:On("AUCTION_HOUSE_CLOSED", function() Scan.Clear(); FF:Fire("FF_SCAN_STOPPED") end)
