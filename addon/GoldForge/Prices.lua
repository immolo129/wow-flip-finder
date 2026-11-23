-- Gold Forge: prices and sales data from TradeSkillMaster's public API (TSM_API).
-- TSM's desktop app keeps this data fresh; we only read it.
local _, FF = ...

local SOURCES = {
  realm      = "DBMarket",           -- market value on this auction house
  minBuyout  = "DBMinBuyout",        -- lowest buyout at TSM's last scan
  historical = "DBHistorical",       -- 60-day historical price on this auction house
  region     = "DBRegionMarketAvg",  -- market value across all Forever auction houses in the region
  sale       = "DBRegionSaleAvg",    -- average price items actually sold for (region)
  saleRate   = "DBRegionSaleRate",   -- chance that a posted auction sells (region)
  soldPerDay = "DBRegionSoldPerDay", -- units sold per day (region)
  numAuctions = "DBNumAuctions",
  vendorSell = "VendorSell",         -- what a vendor pays (TSM knows it for every item)
  vendorBuy = "VendorBuy",           -- what a vendor charges, for items vendors sell (crafting reagents)
}
FF.SourceKeys = { "realm", "minBuyout", "historical", "region", "sale", "saleRate", "soldPerDay", "numAuctions" }
FF.SourceNames = { realm = "Realm value", region = "Region value", sale = "Region sold value" }

function FF.HasTSM()
  return type(TSM_API) == "table" and type(TSM_API.GetCustomPriceValue) == "function"
end

function FF.Raw(key, itemID)
  if not FF.HasTSM() or not SOURCES[key] or not itemID then return nil end
  local ok, v = pcall(TSM_API.GetCustomPriceValue, SOURCES[key], "i:" .. itemID)
  if ok and type(v) == "number" then return v end
  return nil
end

-- TSM may give the sale rate as a fraction (0.91) or per mille (910); normalise to a fraction.
local function asFraction(v)
  if not v then return nil end
  if v > 1 then v = v / 1000 end
  return v
end

-- Everything we know about an item, cached briefly (tooltips ask many times a second).
local cache, cacheTime = {}, 0
function FF.Stats(itemID)
  if not itemID then return {} end
  local now = GetTime()
  if now - cacheTime > 30 then cache = {}; cacheTime = now end
  local s = cache[itemID]
  if not s then
    s = {
      realm = FF.Raw("realm", itemID),
      minBuyout = FF.Raw("minBuyout", itemID),
      historical = FF.Raw("historical", itemID),
      region = FF.Raw("region", itemID),
      sale = FF.Raw("sale", itemID),
      saleRate = asFraction(FF.Raw("saleRate", itemID)),
      soldPerDay = FF.Raw("soldPerDay", itemID),
      numAuctions = FF.Raw("numAuctions", itemID),
    }
    cache[itemID] = s
  end
  return s
end

-- The value deals are measured against (the "Price source" setting), with fallbacks.
function FF.Value(itemID)
  local s = FF.Stats(itemID)
  local pick = FF.db.sniper.priceSource
  return s[pick] or s.realm or s.region or s.sale
end

-- Does the item pass the sales filter? (daily sold or sell chance, as chosen)
function FF.PassesSales(itemID, cfg)
  cfg = cfg or FF.db.sniper
  local s = FF.Stats(itemID)
  if cfg.salesFilter == "chance" then
    return (s.saleRate or 0) * 100 >= cfg.minChance
  end
  return (s.soldPerDay or 0) >= cfg.minSold
end
