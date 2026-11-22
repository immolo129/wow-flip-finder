-- Flip Finder: crafting profit for the recipes you know. Open a profession window once and the learned
-- recipes are saved (per character). Prices come from TSM; a reagent a vendor sells cheaper is priced
-- at the vendor. Nothing is crafted or bought here: it only calculates.
local _, FF = ...
local Crafting = {}
FF.Crafting = Crafting
local CUT = 0.05

local function charKey() return (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?") end
local function mine()
  FF.db.recipes = FF.db.recipes or {}
  FF.db.recipes[charKey()] = FF.db.recipes[charKey()] or {}
  return FF.db.recipes[charKey()]
end

-- ---------- reading recipes from the open profession window ----------
local BASIC = Enum.CraftingReagentType and Enum.CraftingReagentType.Basic or 1

local function professionName()
  local ok, info = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
  if ok and info and info.professionName and info.professionName ~= "" then return info.professionName end
  ok, info = pcall(C_TradeSkillUI.GetChildProfessionInfo)
  if ok and info then return info.parentProfessionName or info.professionName end
end

function Crafting.ReadOpenProfession()
  if not (C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs) then return end
  local prof = professionName()
  if not prof or prof == "" then return end
  local recipes, n = {}, 0
  for _, rid in ipairs(C_TradeSkillUI.GetAllRecipeIDs() or {}) do
    local info = C_TradeSkillUI.GetRecipeInfo(rid)
    if info and info.learned then
      local ok, sch = pcall(C_TradeSkillUI.GetRecipeSchematic, rid, false)
      if ok and sch and sch.outputItemID then   -- enchants on gear make no item: skipped
        local reagents = {}
        for _, slot in ipairs(sch.reagentSlotSchematics or {}) do
          local basic = slot.reagentType == nil or slot.reagentType == BASIC
          local first = slot.reagents and slot.reagents[1]
          if basic and slot.required ~= false and first and first.itemID then
            table.insert(reagents, { first.itemID, slot.quantityRequired or 1 })
          end
        end
        if #reagents > 0 then
          recipes[rid] = { name = info.name, out = sch.outputItemID, qmin = sch.quantityMin or 1,
                           qmax = sch.quantityMax or sch.quantityMin or 1, reagents = reagents }
          n = n + 1
        end
      end
    end
  end
  if n == 0 then return end
  local before = mine()[prof] and mine()[prof].count
  mine()[prof] = { at = time(), recipes = recipes, count = n }
  if before ~= n then FF.Log(string.format("crafting: read %d %s recipes", n, prof)) end
  FF:Fire("FF_CRAFTING_CHANGED")
end

local pendingRead = false
local function readSoon()
  if pendingRead then return end
  pendingRead = true
  C_Timer.After(0.5, function() pendingRead = false; Crafting.ReadOpenProfession() end)
end
FF:On("TRADE_SKILL_SHOW", readSoon)
FF:On("TRADE_SKILL_LIST_UPDATE", readSoon)

-- ---------- prices ----------
-- one reagent: TSM's market value (or lowest buyout), or the vendor's price when that's cheaper
function Crafting.ReagentPrice(itemID)
  local s = FF.Stats(itemID)
  local useMin = FF.db.craftOpts.source == "minbuyout"
  local ah = useMin and (s.minBuyout or s.realm) or (s.realm or s.minBuyout)
  local vendor = FF.Raw("vendorBuy", itemID)
  if vendor and vendor > 0 and (not ah or vendor < ah) then return vendor, "vendor" end
  return ah, "AH"
end

-- every known recipe with its numbers. -> list of rows
function Crafting.Rows(profFilter)
  local out = {}
  for prof, data in pairs(mine()) do
    if not profFilter or profFilter == "" or profFilter == prof then
      for rid, r in pairs(data.recipes or {}) do
        local cost, missing, parts = 0, false, {}
        for _, rg in ipairs(r.reagents) do
          local price, src = Crafting.ReagentPrice(rg[1])
          if not price then missing = true else cost = cost + price * rg[2] end
          table.insert(parts, { itemID = rg[1], qty = rg[2], price = price, src = src })
        end
        local qty = (r.qmin + r.qmax) / 2
        local value = FF.Value(r.out)
        local sells = value and value * qty * (1 - CUT)
        local s = FF.Stats(r.out)
        local row = {
          recipeID = rid, profession = prof, name = r.name, itemID = r.out, qty = qty, parts = parts,
          cost = not missing and cost or nil, sells = sells, soldPerDay = s.soldPerDay, saleRate = s.saleRate,
        }
        if row.cost and row.sells then
          row.profit = row.sells - row.cost
          row.roi = row.cost > 0 and row.profit / row.cost or nil
        end
        table.insert(out, row)
      end
    end
  end
  return out
end

function Crafting.Professions()
  local out = {}
  for prof, data in pairs(mine()) do table.insert(out, { name = prof, count = data.count or 0, at = data.at }) end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- put a recipe's reagents on the "Crafting reagents" list, to snipe them cheaply
function Crafting.AddReagentsToList(row)
  local L = FF.Lists
  local list
  for _, l in ipairs(FF.db.lists or {}) do if l.name == "Crafting reagents" then list = l end end
  list = list or L.Create("Crafting reagents")
  local added = 0
  for _, p in ipairs(row.parts) do if L.Add(list.id, p.itemID) then added = added + 1 end end
  return list, added
end

-- ---------- page ----------
FF.UI.RegisterPage("crafting", function(parent)
  local K = FF.Kit
  local COL, text, box, button = K.COL, K.text, K.box, K.flatButton
  local opts = FF.db.craftOpts
  local page = CreateFrame("Frame", nil, parent)
  page:SetAllPoints()
  local title = text(page, 18, COL.text); title:SetPoint("TOPLEFT", 20, -16); title:SetText("Crafting")
  local sub = text(page, 11, COL.muted); sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -5)
  sub:SetText("Profit for the recipes you know. Open each profession window once so Flip Finder can read your recipes.")

  -- controls
  local card = box(page, COL.card, COL.line)
  card:SetPoint("TOPLEFT", 20, -62); card:SetPoint("RIGHT", -20, 0); card:SetHeight(54)
  local prof = K.dropdown(card, 220,
    function()
      local o = { { text = "All professions", value = "" } }
      for _, p in ipairs(Crafting.Professions()) do table.insert(o, { text = p.name .. " (" .. p.count .. ")", value = p.name }) end
      return o
    end,
    function() return opts.profession ~= "" and opts.profession or "All professions" end, nil,
    function(v) opts.profession = v; page:Refresh() end)
  prof:SetPoint("LEFT", 14, 0)
  local src = K.dropdown(card, 230,
    function() return { { text = "Reagents at: Market value", value = "market" }, { text = "Reagents at: Lowest buyout", value = "minbuyout" } } end,
    function() return opts.source == "minbuyout" and "Reagents at: Lowest buyout" or "Reagents at: Market value" end, nil,
    function(v) opts.source = v; page:Refresh() end)
  src:SetPoint("LEFT", prof, "RIGHT", 12, 0)
  local only = K.checkbox(card, "Only profitable", function() return opts.onlyProfitable end, function(v) opts.onlyProfitable = v; page:Refresh() end)
  only:SetPoint("LEFT", src, "RIGHT", 16, 0)
  local known = text(card, 10, COL.dim); known:SetPoint("RIGHT", -14, 0); known:SetJustifyH("RIGHT")

  -- table
  local list = box(page, COL.card, COL.line)
  list:SetPoint("TOPLEFT", 20, -128); list:SetPoint("BOTTOMRIGHT", -20, 34)
  local COLS = {
    { "Crafted item", 0, "LEFT" }, { "Profession", 110, "LEFT" }, { "Reagent cost", 86 }, { "Sells for", 86 },
    { "Profit", 86 }, { "ROI", 50 }, { "Sold/day", 58 }, { "Sell %", 50 },
  }
  local BTN = 120
  local heads = {}
  for i, c in ipairs(COLS) do
    local h = text(list, 10, COL.muted, nil, true); h:SetText(c[1]:upper()); h:SetJustifyH(c[3] or "RIGHT")
    heads[i] = h
  end
  local scroll = CreateFrame("ScrollFrame", nil, list)
  scroll:SetPoint("TOPLEFT", 1, -30); scroll:SetPoint("BOTTOMRIGHT", -1, 4)
  local content = CreateFrame("Frame", nil, scroll); content:SetSize(1, 1)
  scroll:SetScrollChild(content)
  scroll:SetScript("OnSizeChanged", function(s, w) content:SetWidth(w) end)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(s, delta)
    local max = math.max(0, content:GetHeight() - s:GetHeight())
    s:SetVerticalScroll(math.min(max, math.max(0, s:GetVerticalScroll() - delta * K.ROW_H * 2)))
  end)
  local empty = text(list, 12, COL.dim); empty:SetPoint("CENTER", scroll, "CENTER")
  local function colX(width)
    local fixed, out = 0, {}
    for i = 2, #COLS do fixed = fixed + COLS[i][2] end
    local x = 14
    for i, c in ipairs(COLS) do
      local w = i == 1 and math.max(160, width - 28 - fixed - BTN) or c[2]
      out[i] = { x = x, w = w }
      x = x + w
    end
    return out
  end

  local rows, expanded = {}, {}
  local function row(i)
    if rows[i] then return rows[i] end
    local r = CreateFrame("Button", nil, content)
    r.hl = r:CreateTexture(nil, "BACKGROUND"); r.hl:SetColorTexture(1, 1, 1, 0.035); r.hl:Hide()
    r.hl:SetPoint("TOPLEFT"); r.hl:SetPoint("TOPRIGHT"); r.hl:SetHeight(K.ROW_H)
    r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(22, 22); r.icon:SetPoint("TOPLEFT", 13, -4)
    r.cells = {}
    for c = 1, #COLS do
      r.cells[c] = text(r, 12, c == 5 and COL.green or COL.text, nil, c == 5)
      r.cells[c]:SetJustifyH(COLS[c][3] or "RIGHT")
    end
    r.detail = text(r, 11, COL.muted, nil, false); r.detail:SetJustifyH("LEFT"); r.detail:SetWordWrap(true)
    r.add = button(r, "Reagents to list", 112, 22, "ghost")
    r.add:SetPoint("TOPRIGHT", -12, -4)
    r:SetScript("OnClick", function(s) expanded[s.data.recipeID] = not expanded[s.data.recipeID]; page:Refresh() end)
    r:SetScript("OnEnter", function(s)
      s.hl:Show()
      GameTooltip:SetOwner(s, "ANCHOR_RIGHT"); GameTooltip:SetItemByID(s.data.itemID)
      GameTooltip:AddLine("Click the row to see the reagents.", 0.56, 0.56, 0.6); GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function(s) s.hl:Hide(); GameTooltip:Hide() end)
    rows[i] = r
    return r
  end

  function page:Refresh()
    if page:GetWidth() < 10 then return end
    prof:Refresh(); src:Refresh(); only:Refresh()
    local profs = Crafting.Professions()
    local names = {}
    for _, p in ipairs(profs) do table.insert(names, string.format("%s %d", p.name, p.count)) end
    known:SetText(#names > 0 and ("Read: " .. table.concat(names, " · ")) or "No recipes read yet")
    local width = scroll:GetWidth()
    local cx = colX(width)
    for i, h in ipairs(heads) do
      h:ClearAllPoints(); h:SetPoint("TOPLEFT", cx[i].x + (i == 1 and 30 or 0), -12); h:SetWidth(cx[i].w - 6 - (i == 1 and 30 or 0))
    end
    local data = Crafting.Rows(opts.profession)
    local shown = {}
    for _, d in ipairs(data) do
      if not opts.onlyProfitable or (d.profit and d.profit > 0) then table.insert(shown, d) end
    end
    table.sort(shown, function(a, b)
      if (a.profit ~= nil) ~= (b.profit ~= nil) then return a.profit ~= nil end
      return (a.profit or 0) > (b.profit or 0)
    end)
    local y = 0
    for i, d in ipairs(shown) do
      local r = row(i)
      r.data = d
      r:ClearAllPoints(); r:SetPoint("TOPLEFT", 0, -y); r:SetPoint("RIGHT", content, "RIGHT")
      r.icon:SetTexture(C_Item.GetItemIconByID(d.itemID))
      local quality = select(3, C_Item.GetItemInfo(d.itemID))
      local vals = {
        FF.QualityColor(quality) .. (C_Item.GetItemNameByID(d.itemID) or d.name or "?") .. "|r" .. (d.qty ~= 1 and ("  |cff8e8e99x" .. d.qty .. "|r") or ""),
        d.profession, d.cost and FF.Money(d.cost) or "|cff5f5f69no price|r", d.sells and FF.Money(d.sells) or "|cff5f5f69no price|r",
        d.profit and FF.Money(d.profit) or "-", d.roi and string.format("%d%%", d.roi * 100 + 0.5) or "-",
        d.soldPerDay and string.format("%.0f", d.soldPerDay) or "-", d.saleRate and string.format("%d%%", d.saleRate * 100 + 0.5) or "-",
      }
      for c, fs in ipairs(r.cells) do
        fs:ClearAllPoints(); fs:SetPoint("TOPLEFT", cx[c].x + (c == 1 and 30 or 0), 0)
        fs:SetSize(cx[c].w - 6 - (c == 1 and 30 or 0), K.ROW_H); fs:SetText(vals[c])
      end
      r.cells[5]:SetTextColor(unpack(d.profit and d.profit < 0 and COL.red or COL.green))
      r.add:SetScript("OnClick", function()
        local l, n = Crafting.AddReagentsToList(d)
        K.status(n > 0 and string.format("Added %d reagents to the list \"%s\". Scan it in a sniper to buy them cheaply.", n, l.name)
          or "Those reagents are already on the list \"" .. l.name .. "\".")
      end)
      local open = expanded[d.recipeID]
      r.detail:SetShown(open)
      local h = K.ROW_H
      if open then
        local parts = {}
        for _, p in ipairs(d.parts) do
          table.insert(parts, string.format("%d x %s (%s%s)", p.qty, C_Item.GetItemNameByID(p.itemID) or ("item " .. p.itemID),
            p.price and FF.Money(p.price) or "no price", p.src == "vendor" and ", vendor" or ""))
        end
        r.detail:ClearAllPoints(); r.detail:SetPoint("TOPLEFT", 44, -K.ROW_H); r.detail:SetWidth(width - 60)
        r.detail:SetText("|cfff2b81dReagents:|r  " .. table.concat(parts, ",  "))
        h = K.ROW_H + r.detail:GetStringHeight() + 10
      end
      r:SetHeight(h)
      r:Show()
      y = y + h
    end
    for i = #shown + 1, #rows do rows[i]:Hide() end
    content:SetHeight(math.max(1, y))
    empty:SetShown(#shown == 0)
    empty:SetText(#data == 0 and "Open a profession window (e.g. press K or click a profession) and your recipes appear here."
      or "No recipes match. Untick \"Only profitable\" to see all.")
  end
  FF:On("FF_CRAFTING_CHANGED", function() if page:IsShown() then page:Refresh() end end)
  page:SetScript("OnSizeChanged", function() if page:IsShown() then page:Refresh() end end)
  return page
end)
