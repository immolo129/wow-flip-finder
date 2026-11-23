-- Gold Forge: your own lists ("My herbs", "Recipes that sell"). Any sniper can scan a list instead of a
-- whole category: only those items are checked, so the scan is fast and has no noise.
local _, FF = ...
local Lists = {}
FF.Lists = Lists

local function all() FF.db.lists = FF.db.lists or {}; return FF.db.lists end

function Lists.Get(id)
  for _, l in ipairs(all()) do if l.id == id then return l end end
end

function Lists.Create(name)
  FF.db.nextListID = (FF.db.nextListID or 0) + 1
  local l = { id = FF.db.nextListID, name = name or ("List " .. FF.db.nextListID), items = {} }
  table.insert(all(), l)
  FF:Fire("FF_LISTS_CHANGED")
  return l
end

function Lists.Delete(id)
  local ls = all()
  for i, l in ipairs(ls) do if l.id == id then table.remove(ls, i); break end end
  -- a sniper scanning the deleted list goes back to its first group
  for _, cfg in ipairs({ FF.db.sniper, FF.db.items, FF.db.vendor }) do
    if cfg.group == "list:" .. id then cfg.group = FF.Sniper.Groups[1].key end
  end
  FF:Fire("FF_LISTS_CHANGED")
end

function Lists.Add(id, itemID)
  local l = Lists.Get(id)
  if not l or not itemID then return false end
  if l.items[itemID] then return false end
  l.items[itemID] = true
  if C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
  FF:Fire("FF_LISTS_CHANGED")
  return true
end

function Lists.Remove(id, itemID)
  local l = Lists.Get(id)
  if l then l.items[itemID] = nil; FF:Fire("FF_LISTS_CHANGED") end
end

function Lists.Count(l)
  local n = 0
  for _ in pairs(l.items) do n = n + 1 end
  return n
end

-- item IDs of a list, for scanning
function Lists.ItemIDs(id)
  local out, l = {}, Lists.Get(id)
  if l then for itemID in pairs(l.items) do table.insert(out, itemID) end end
  table.sort(out)
  return out
end

-- "item:12345", a full item link, or a plain number -> 12345
function Lists.ParseItem(s)
  if not s then return nil end
  return tonumber(s:match("item:(%d+)") or s:match("^%s*(%d+)%s*$"))
end

-- ---------- page ----------
FF.UI.RegisterPage("lists", function(parent)
  local K = FF.Kit
  local COL, text, box, button = K.COL, K.text, K.box, K.flatButton
  local selected
  local page = CreateFrame("Frame", nil, parent)
  page:SetAllPoints()
  local title = text(page, 18, COL.text); title:SetPoint("TOPLEFT", 20, -16); title:SetText("Lists")
  local sub = text(page, 11, COL.muted); sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -5)
  sub:SetText("Your own groups of items. Pick one as the Scan scope in any sniper to check only those items.")

  -- left: the lists
  local left = box(page, COL.card, COL.line)
  left:SetPoint("TOPLEFT", 20, -62); left:SetPoint("BOTTOMLEFT", 20, 34); left:SetWidth(230)
  local newBtn = button(left, "+ New list", 206, 26, "primary", function()
    selected = Lists.Create("New list").id
    page:Refresh()
    page.name:SetFocus(); page.name:HighlightText()
  end)
  newBtn:SetPoint("TOP", 0, -10)
  local listBtns = {}

  -- right: the selected list
  local right = box(page, COL.card, COL.line)
  right:SetPoint("TOPLEFT", left, "TOPRIGHT", 12, 0); right:SetPoint("BOTTOMRIGHT", -20, 34)
  local name = K.input(right, 260, "List name")
  name:SetPoint("TOPLEFT", 14, -12)
  name:SetScript("OnEnterPressed", function(s) s:ClearFocus() end)
  name:SetScript("OnEditFocusLost", function(s)
    local l = selected and Lists.Get(selected)
    if l and strtrim(s:GetText()) ~= "" then l.name = strtrim(s:GetText()); FF:Fire("FF_LISTS_CHANGED") end
  end)
  page.name = name
  local del = button(right, "Delete list", 100, 26, "ghost", function()
    if selected then Lists.Delete(selected); selected = nil; page:Refresh() end
  end)
  del:SetPoint("TOPRIGHT", -14, -12)

  local add = K.input(right, 360, "Shift-click or drag an item here, or type an item ID")
  add:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -12)
  local function addFrom(s)
    local id = Lists.ParseItem(s)
    if not selected then K.status("Make a list first."); return end
    if not id then K.status("That isn't an item. Shift-click an item or type its ID."); return end
    if Lists.Add(selected, id) then K.status("Added " .. (C_Item.GetItemNameByID(id) or ("item " .. id)) .. ".") end
    add:SetText("")
    page:Refresh()
  end
  add:SetScript("OnEnterPressed", function(s) addFrom(s:GetText()) end)
  -- drag an item from the bags onto the box
  local function dropped()
    local kind, itemID = GetCursorInfo()
    if kind == "item" then ClearCursor(); addFrom(tostring(itemID)) end
  end
  add:SetScript("OnReceiveDrag", dropped)
  add:SetScript("OnMouseDown", function() if GetCursorInfo() == "item" then dropped() end end)
  -- shift-click an item while the box has focus
  hooksecurefunc("ChatEdit_InsertLink", function(link)
    if add:HasFocus() and link and link:find("item:") then addFrom(link) end
  end)
  local addHint = text(right, 10, COL.dim); addHint:SetPoint("LEFT", add, "RIGHT", 10, 0)
  addHint:SetText("Click the box first, then shift-click items.")

  local COLS = { { "Item", 0, "LEFT" }, { "Value", 90 }, { "Sold/day", 70 }, { "Sell %", 60 } }
  local heads = {}
  for i, c in ipairs(COLS) do
    local h = text(right, 10, COL.muted, nil, true); h:SetText(c[1]:upper()); h:SetJustifyH(c[3] or "RIGHT")
    heads[i] = h
  end
  local scroll = CreateFrame("ScrollFrame", nil, right)
  scroll:SetPoint("TOPLEFT", 1, -110); scroll:SetPoint("BOTTOMRIGHT", -1, 4)
  local content = CreateFrame("Frame", nil, scroll); content:SetSize(1, 1)
  scroll:SetScrollChild(content)
  scroll:SetScript("OnSizeChanged", function(s, w) content:SetWidth(w) end)
  K.scrollbar(scroll, content)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(s, delta)
    local max = math.max(0, content:GetHeight() - s:GetHeight())
    s:SetVerticalScroll(math.min(max, math.max(0, s:GetVerticalScroll() - delta * K.ROW_H * 2)))
  end)
  local empty = text(right, 12, COL.dim); empty:SetPoint("CENTER", scroll, "CENTER")
  local rows = {}
  local function colX(width)
    local fixed, out = 0, {}
    for i = 2, #COLS do fixed = fixed + COLS[i][2] end
    local x = 14
    for i, c in ipairs(COLS) do
      local w = i == 1 and math.max(160, width - 28 - fixed - 40) or c[2]
      out[i] = { x = x, w = w }
      x = x + w
    end
    return out
  end

  function page:Refresh()
    -- lists on the left
    local ls = all()
    if not selected and ls[1] then selected = ls[1].id end
    for i, l in ipairs(ls) do
      local b = listBtns[i]
      if not b then
        b = button(left, "", 206, 26, "ghost")
        b:SetPoint("TOP", 0, -44 - (i - 1) * 30)
        b.label:ClearAllPoints(); b.label:SetPoint("LEFT", 10, 0)
        b.count = text(b, 11, COL.muted); b.count:SetPoint("RIGHT", -10, 0)
        listBtns[i] = b
      end
      b:SetScript("OnClick", function() selected = l.id; page:Refresh() end)
      b:SetLabel(l.name); b.count:SetText(Lists.Count(l))
      b:SetStyle(l.id == selected and "primary" or "ghost")
      b.count:SetTextColor(unpack(l.id == selected and COL.goldText or COL.muted))
      b:Show()
    end
    for i = #ls + 1, #listBtns do listBtns[i]:Hide() end
    -- the selected list
    local l = selected and Lists.Get(selected)
    name:SetShown(l ~= nil); del:SetShown(l ~= nil); add:SetShown(l ~= nil); addHint:SetShown(l ~= nil)
    if l and not name:HasFocus() then name:SetText(l.name) end
    local width = scroll:GetWidth()
    local cx = colX(width)
    for i, h in ipairs(heads) do
      h:ClearAllPoints(); h:SetPoint("TOPLEFT", cx[i].x + (i == 1 and 28 or 0), -92); h:SetWidth(cx[i].w - 6); h:SetShown(l ~= nil)
    end
    local ids = l and Lists.ItemIDs(l.id) or {}
    -- sort by name
    table.sort(ids, function(a, b) return (C_Item.GetItemNameByID(a) or "") < (C_Item.GetItemNameByID(b) or "") end)
    for i, id in ipairs(ids) do
      local r = rows[i]
      if not r then
        r = CreateFrame("Frame", nil, content)
        r:SetHeight(K.ROW_H)
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(20, 20); r.icon:SetPoint("LEFT", 14, 0)
        r.cells = {}
        for c = 1, #COLS do r.cells[c] = text(r, 12, COL.text); r.cells[c]:SetJustifyH(COLS[c][3] or "RIGHT") end
        r.remove = button(r, "x", 24, 22, "ghost")
        r.remove:SetPoint("RIGHT", -12, 0)
        r:EnableMouse(true)
        r:SetScript("OnEnter", function(s)
          GameTooltip:SetOwner(s, "ANCHOR_RIGHT"); GameTooltip:SetItemByID(s.itemID)
          GameTooltip:AddLine("Click for the price history.", 0.56, 0.56, 0.6); GameTooltip:Show()
        end)
        r:SetScript("OnMouseUp", function(s) FF.History.Open(s.itemID) end)
        r:SetScript("OnLeave", GameTooltip_Hide)
        rows[i] = r
      end
      r.itemID = id
      r:ClearAllPoints(); r:SetPoint("TOPLEFT", 0, -(i - 1) * K.ROW_H); r:SetPoint("RIGHT", content, "RIGHT")
      r.icon:SetTexture(C_Item.GetItemIconByID(id))
      local quality = select(3, C_Item.GetItemInfo(id))
      local s = FF.Stats(id)
      local vals = { FF.QualityColor(quality) .. (C_Item.GetItemNameByID(id) or ("Item " .. id)) .. "|r", FF.Money(FF.Value(id)),
                     s.soldPerDay and string.format("%.0f", s.soldPerDay) or "-", s.saleRate and string.format("%d%%", s.saleRate * 100 + 0.5) or "-" }
      for c, fs in ipairs(r.cells) do
        fs:ClearAllPoints(); fs:SetPoint("LEFT", cx[c].x + (c == 1 and 28 or 0), 0); fs:SetWidth(cx[c].w - 6 - (c == 1 and 28 or 0))
        fs:SetText(vals[c])
      end
      r.remove:SetScript("OnClick", function() Lists.Remove(l.id, id); page:Refresh() end)
      r:Show()
    end
    for i = #ids + 1, #rows do rows[i]:Hide() end
    content:SetHeight(math.max(1, #ids * K.ROW_H))
    empty:SetShown(#ids == 0)
    empty:SetText(not l and "Make a list with + New list." or "This list is empty. Add items with the box above.")
  end
  FF:On("FF_LISTS_CHANGED", function() if page:IsShown() then page:Refresh() end end)
  local soon = false
  FF:On("GET_ITEM_INFO_RECEIVED", function()
    if soon or not page:IsShown() then return end
    soon = true
    C_Timer.After(0.3, function() soon = false; if page:IsShown() then page:Refresh() end end)
  end)
  page:SetScript("OnSizeChanged", function() if page:IsShown() then page:Refresh() end end)
  return page
end)
