-- Flip Finder: price lines on item tooltips.
local _, FF = ...

local function addLines(tooltip, itemID)
  if not FF.db or not FF.db.tooltip or not itemID then return end
  local s = FF.Stats(itemID)
  if not (s.realm or s.region or s.sale) then return end
  local gold = "|cffe9c25a"
  tooltip:AddLine(" ")
  tooltip:AddLine(gold .. "Flip Finder|r")
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
  tooltip:Show()
end

if TooltipDataProcessor and Enum and Enum.TooltipDataType then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
    if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
    addLines(tooltip, data and data.id)
  end)
end
