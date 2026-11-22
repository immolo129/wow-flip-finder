-- Flip Finder: minimap button. Left-click opens or closes Flip Finder, right-click opens Price alerts,
-- drag it around the minimap edge (the spot is remembered). /ff minimap hides or shows it.
local _, FF = ...
local Minimap_ = {}
FF.MinimapButton = Minimap_
local btn

local function place()
  local a = math.rad(FF.db.minimap.angle or 215)
  local r = (Minimap:GetWidth() / 2) + 10
  btn:ClearAllPoints()
  btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

local function build()
  btn = CreateFrame("Button", "FlipFinderMinimapButton", Minimap)
  btn:SetSize(31, 31)
  btn:SetFrameStrata("MEDIUM")
  btn:SetFrameLevel(8)
  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  btn:RegisterForDrag("LeftButton")
  btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  local bg = btn:CreateTexture(nil, "BACKGROUND")
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  bg:SetSize(20, 20); bg:SetPoint("TOPLEFT", 7, -5)
  local icon = btn:CreateTexture(nil, "ARTWORK")
  icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_02")
  icon:SetSize(18, 18); icon:SetPoint("TOPLEFT", 7, -6)
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  local border = btn:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetSize(53, 53); border:SetPoint("TOPLEFT")

  btn:SetScript("OnClick", function(_, mouse)
    if mouse == "RightButton" then
      FF.UI.Show(); FF.UI.Go("alerts")
    else
      FF.UI.Toggle()
    end
  end)
  btn:SetScript("OnDragStart", function(s)
    s:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local cx, cy = GetCursorPosition()
      local scale = Minimap:GetEffectiveScale()
      FF.db.minimap.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
      place()
    end)
  end)
  btn:SetScript("OnDragStop", function(s) s:SetScript("OnUpdate", nil) end)
  btn:SetScript("OnEnter", function(s)
    GameTooltip:SetOwner(s, "ANCHOR_LEFT")
    GameTooltip:SetText("Flip Finder", 0.95, 0.72, 0.11)
    GameTooltip:AddLine("Left-click: open or close", 1, 1, 1)
    GameTooltip:AddLine("Right-click: price alerts", 1, 1, 1)
    GameTooltip:AddLine("Drag: move this button", 0.56, 0.56, 0.6)
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", GameTooltip_Hide)
  place()
end

function Minimap_.Refresh()
  if FF.db.minimap.hide then
    if btn then btn:Hide() end
  else
    if not btn then build() end
    btn:Show()
  end
end

function Minimap_.Toggle()
  FF.db.minimap.hide = not FF.db.minimap.hide
  Minimap_.Refresh()
  FF.Print("minimap button " .. (FF.db.minimap.hide and "hidden (/ff minimap to show it)" or "shown"))
end

FF:On("PLAYER_LOGIN", function() Minimap_.Refresh() end)
