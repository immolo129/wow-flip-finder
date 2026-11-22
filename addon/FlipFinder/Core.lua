-- Flip Finder: core. Settings, events, money formatting, logging and slash commands.
local ADDON, FF = ...
_G.FlipFinder = FF
FF.version = "0.1.1"

-- Settings. Money is in copper (1g = 10000), percentages are whole numbers.
local DEFAULTS = {
  tooltip = true,
  showOnAH = true,
  sniper = {
    group = "materials",
    priceSource = "realm",  -- realm = DBMarket, region = DBRegionMarketAvg, sale = DBRegionSaleAvg
    maxPct = 90,            -- only listings below this % of the value
    salesFilter = "sold",   -- "sold" = daily sold, "chance" = sell chance
    minSold = 20,           -- units sold per day (region)
    minChance = 20,         -- % sell chance (region)
    maxQty = 300,           -- most units to buy of one item
    gapPct = 20,            -- price gap after the cheap group, in %
    minRoi = 25,
    minQty = 1,             -- set 2+ to skip single bait listings
    minQuality = 1,         -- 0 poor, 1 common, 2 uncommon, 3 rare, 4 epic
    minProfit = 500,        -- 5s
    maxSpend = 5000000,     -- 500g per deal
    tolerance = 5,          -- listings within this % of the cheapest count as one price group
    fastFirst = true,       -- scan the fastest sellers first
    autoRescan = false,
  },
  -- the item sniper (recipes, gear, other single auctions): below X % of the value, no gap rule
  items = {
    group = "recipes",
    maxPct = 50,
    salesFilter = "sold",
    minSold = 0,
    minChance = 0,
    maxQty = 3,             -- recipes: buy one or a few, not 20
    minRoi = 25,
    minQuality = 1,
    minProfit = 2000,       -- 20s
    maxSpend = 5000000,
    fastFirst = true,
    autoRescan = false,
  },
  page = "commodity",
  log = {},
}

local function merge(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" then
      if type(dst[k]) ~= "table" then dst[k] = {} end
      if k ~= "log" then merge(dst[k], v) end
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
end

-- ---------- events (game events and our own messages share one registry) ----------
local eventFrame = CreateFrame("Frame")
local handlers = {}
function FF:On(event, fn)
  if not handlers[event] then
    handlers[event] = {}
    if not event:find("^FF_") then eventFrame:RegisterEvent(event) end
  end
  table.insert(handlers[event], fn)
end
function FF:Fire(event, ...)
  for _, fn in ipairs(handlers[event] or {}) do
    local ok, err = pcall(fn, ...)
    if not ok then FF.Log("error in " .. event .. ": " .. tostring(err)); geterrorhandler()(err) end
  end
end
eventFrame:SetScript("OnEvent", function(_, event, ...) FF:Fire(event, ...) end)

-- ---------- helpers ----------
function FF.Print(...)
  print("|cffe9c25aFlip Finder|r:", ...)
end

-- A short log kept in the saved variables, so problems can be looked at after a /reload.
function FF.Log(msg)
  if not FF.db then return end
  local log = FF.db.log
  table.insert(log, date("%H:%M:%S") .. " " .. tostring(msg))
  while #log > 300 do table.remove(log, 1) end
end

function FF.Money(copper)
  if not copper then return "|cff808080-|r" end
  copper = math.floor(copper + 0.5)
  local neg = copper < 0
  copper = math.abs(copper)
  local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  local out
  if g > 0 then
    out = string.format("|cffffd70a%s|rg |cffc7c7cf%d|rs", BreakUpLargeNumbers and BreakUpLargeNumbers(g) or g, s)
  elseif s > 0 then
    out = string.format("|cffc7c7cf%d|rs |cffeda55f%d|rc", s, c)
  else
    out = string.format("|cffeda55f%d|rc", c)
  end
  return (neg and "-" or "") .. out
end

function FF.QualityColor(q)
  local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q or 1]
  return c and c.hex or "|cffffffff"
end

-- ---------- start-up ----------
FF:On("ADDON_LOADED", function(name)
  if name ~= ADDON then return end
  FlipFinderDB = FlipFinderDB or {}
  merge(FlipFinderDB, DEFAULTS)
  FF.db = FlipFinderDB
  FF.Log("loaded " .. FF.version .. ", TSM " .. (FF.HasTSM() and "found" or "MISSING"))
  FF:Fire("FF_READY")
end)

FF:On("PLAYER_LOGIN", function()
  if not FF.HasTSM() then
    FF.Print("TradeSkillMaster isn't loaded, so there are no prices. Install TSM and its desktop app.")
  end
end)

-- ---------- slash commands ----------
SLASH_FLIPFINDER1 = "/ff"
SLASH_FLIPFINDER2 = "/flipfinder"
SlashCmdList.FLIPFINDER = function(msg)
  msg = strtrim(msg or "")
  local cmd, rest = msg:match("^(%S*)%s*(.-)$")
  cmd = (cmd or ""):lower()
  if cmd == "" then
    FF.UI.Toggle()
  elseif cmd == "tooltip" then
    FF.db.tooltip = not FF.db.tooltip
    FF.Print("tooltip lines " .. (FF.db.tooltip and "on" or "off"))
  elseif cmd == "debug" then
    -- /ff debug [item link]: prints and logs the raw TSM values, to check what TSM returns
    local id = rest and tonumber(rest:match("item:(%d+)") or rest)
    if not id then FF.Print("usage: /ff debug [shift-click an item]"); return end
    for _, key in ipairs(FF.SourceKeys) do
      local v = FF.Raw(key, id)
      FF.Print(key, tostring(v))
      FF.Log("debug " .. id .. " " .. key .. "=" .. tostring(v))
    end
  elseif cmd == "log" then
    for i = math.max(1, #FF.db.log - 15), #FF.db.log do FF.Print(FF.db.log[i]) end
  else
    FF.Print("/ff  open or close the window · /ff tooltip  tooltip lines on/off · /ff debug [item]  raw TSM values · /ff log  recent log")
  end
end
