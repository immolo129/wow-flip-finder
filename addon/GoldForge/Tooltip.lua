-- Gold Forge: price lines on item tooltips.
local _, FF = ...

-- where to farm it (Gold Guide): your farms, the general hints, and your own best rate
local function farmLines(tooltip, itemID, header)
  if not FF.Farm then return false end
  local list, best = FF.Farm.WhereToFarm(itemID)
  if not list and not best then return false end
  if header then tooltip:AddLine(" "); tooltip:AddLine("|cffe9c25aGold Forge|r") end
  tooltip:AddLine("Where to farm:", 0.95, 0.72, 0.11)
  for i, e in ipairs(list or {}) do
    if i > 5 then tooltip:AddLine(string.format("  ... %d more in Gold Guide", #list - 5), 0.56, 0.56, 0.6); break end
    if e.farm then
      local f = e.farm
      local dead = f.status == "dead"
      tooltip:AddDoubleLine("  " .. f.name .. (dead and " (dead)" or ""),
        (f.zone or "") .. (e.chance and string.format("  %.1f%%", e.chance) or ""),
        dead and 1 or 0.9, dead and 0.38 or 0.9, dead and 0.35 or 0.9, 0.7, 0.7, 0.75)
    else
      tooltip:AddDoubleLine("  " .. e.source, e.where, 0.9, 0.9, 0.9, 0.7, 0.7, 0.75)
    end
  end
  if best then
    tooltip:AddDoubleLine("  You: " .. best.zone, string.format("%.1f an hour", best.rate), 0.35, 0.76, 0.49, 0.35, 0.76, 0.49)
  end
  return true
end

local function addLines(tooltip, itemID)
  if not FF.db or not FF.db.tooltip or not itemID then return end
  local s = FF.Stats(itemID)
  if not (s.realm or s.region or s.sale) then
    if farmLines(tooltip, itemID, true) then tooltip:Show() end
    return
  end
  local gold = "|cffe9c25a"
  tooltip:AddLine(" ")
  tooltip:AddLine(gold .. "Gold Forge|r")
  if s.realm then tooltip:AddDoubleLine("Realm value", FF.Money(s.realm), 1, 1, 1) end
  if s.minBuyout then tooltip:AddDoubleLine("Lowest buyout", FF.Money(s.minBuyout), 1, 1, 1) end
  if s.region then tooltip:AddDoubleLine("Region value", FF.Money(s.region), 1, 1, 1) end
  if s.sale then tooltip:AddDoubleLine("Region sold value", FF.Money(s.sale), 1, 1, 1) end
  if s.soldPerDay then
    tooltip:AddDoubleLine("Daily sold", string.format("%.1f", s.soldPerDay), 1, 1, 1, 1, 1, 1)
  end
  if s.saleRate then
    local p = s.saleRate * 100
    local r, g = p < 30 and 1 or (p < 60 and 1 or 0.4), p < 30 and 0.3 or (p < 60 and 0.8 or 1)
    tooltip:AddDoubleLine("Sell chance", string.format("%d%%", p + 0.5), 1, 1, 1, r, g, 0.3)
  end
  farmLines(tooltip, itemID, false)
  tooltip:Show()
end

if TooltipDataProcessor and Enum and Enum.TooltipDataType then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
    if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
    addLines(tooltip, data and data.id)
  end)
end
