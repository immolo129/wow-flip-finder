-- Gold Forge: the ledger and the Earnings page.
-- Purchases are recorded when you buy through Gold Forge. Sales are read from the "Auction successful"
-- mails Blizzard sends (their invoice says the item, sale price and AH cut), whenever the mailbox is
-- open. Only reading: the addon never takes mail or money out.
local _, FF = ...
local Ledger = {}
FF.Ledger = Ledger
local DAY = 86400

local function db()
  local l = FF.db.ledger
  l.buys, l.sales, l.seen, l.expired = l.buys or {}, l.sales or {}, l.seen or {}, l.expired or {}
  return l
end

-- ---------- recording ----------
function Ledger.AddBuy(deal)
  table.insert(db().buys, { t = time(), itemID = deal.itemID, name = deal.name, qty = deal.buy, cost = math.floor(deal.cost) })
  FF.db.flippedNames = FF.db.flippedNames or {}
  if deal.name then FF.db.flippedNames[deal.name] = true end
  FF:Fire("FF_LEDGER_CHANGED")
end

-- read every auction-sale invoice in the mailbox once
local function scanMail()
  if not GetInboxNumItems then return end
  local l, now, added = db(), time(), 0
  for i = 1, GetInboxNumItems() do
    local invoiceType, itemName, _, bid, _, _, consignment = GetInboxInvoiceInfo(i)
    if not invoiceType then
      -- "Auction expired: X" mails: the auction didn't sell and its deposit is gone
      local _, _, _, subject, _, _, daysLeft = GetInboxHeaderInfo(i)
      local pat = AUCTION_EXPIRED_MAIL_SUBJECT and ("^" .. AUCTION_EXPIRED_MAIL_SUBJECT:gsub("[%-%.%?%[%]%(%)%+%*%^%$]", "%%%0"):gsub("%%s", "(.+)") .. "$")
      local name = pat and subject and subject:match(pat)
      if name then
        local qty = tonumber(name:match("%((%d+)%)$")) or 1
        name = name:gsub("%s*%(%d+%)$", "")
        local arrived = now - math.floor((30 - (daysLeft or 30)) * DAY)
        local key = "x:" .. name .. ":" .. qty .. ":" .. math.floor(arrived / 900)
        if not l.seen[key] then
          l.seen[key] = arrived
          table.insert(l.expired, { t = arrived, name = name, qty = qty })
          added = added + 1
        end
      end
    elseif invoiceType == "seller" and itemName then
      local _, _, _, subject, money, _, daysLeft = GetInboxHeaderInfo(i)
      -- auction mails last 30 days, so this is when it arrived (to the minute or so)
      local arrived = now - math.floor((30 - (daysLeft or 30)) * DAY)
      local bucket = math.floor(arrived / 900)
      local base = itemName .. ":" .. tostring(money) .. ":"
      if not (l.seen[base .. bucket] or l.seen[base .. (bucket - 1)] or l.seen[base .. (bucket + 1)]) then
        l.seen[base .. bucket] = arrived
        local qty = tonumber((subject or ""):match("%((%d+)%)")) or 1
        table.insert(l.sales, { t = arrived, name = itemName, qty = qty, money = money or 0, price = bid or 0, cut = consignment or 0 })
        added = added + 1
      end
    end
  end
  -- forget dedupe keys older than the mail itself can be
  for k, t in pairs(l.seen) do if now - t > 35 * DAY then l.seen[k] = nil end end
  if added > 0 then
    FF.Log(string.format("ledger: %d new sales from the mailbox", added))
    FF:Fire("FF_LEDGER_CHANGED")
  end
end
FF:On("MAIL_INBOX_UPDATE", scanMail)
Ledger.ScanMail = scanMail   -- the mailbox helper calls this before taking a mail

-- ---------- sell-through: how often your auctions of an item sell instead of expiring ----------
-- From your own auction mail: each "sold" mail is one auction that sold, each "expired" mail one that didn't.
local stCache
FF:On("FF_LEDGER_CHANGED", function() stCache = nil end)
Ledger.MIN_AUCTIONS = 3
function Ledger.SellThrough(name)
  if not name then return nil end
  if not stCache then
    stCache = {}
    local l = db()
    for _, s in ipairs(l.sales) do
      local e = stCache[s.name] or { sold = 0, expired = 0 }; e.sold = e.sold + 1; stCache[s.name] = e
    end
    for _, x in ipairs(l.expired) do
      local e = stCache[x.name] or { sold = 0, expired = 0 }; e.expired = e.expired + 1; stCache[x.name] = e
    end
    for _, e in pairs(stCache) do
      e.total = e.sold + e.expired
      e.rate = e.total > 0 and e.sold / e.total or nil
    end
  end
  local e = stCache[name]
  if not e or e.total < Ledger.MIN_AUCTIONS then return nil, e end
  return e.rate, e
end
-- short text like "2 of 6 sold (33%)"
function Ledger.SellThroughText(e)
  return e and string.format("%d of %d sold (%d%%)", e.sold, e.total, (e.rate or 0) * 100 + 0.5) or nil
end

-- ---------- numbers ----------
local function isFlipped(name) return FF.db.flippedNames and FF.db.flippedNames[name] end

-- per-day totals for the last `days` days (or since the first entry when days is nil)
function Ledger.Days(days, onlyFlipped)
  local l = db()
  local today = math.floor(time() / DAY)
  local first = today
  for _, b in ipairs(l.buys) do first = math.min(first, math.floor(b.t / DAY)) end
  for _, s in ipairs(l.sales) do first = math.min(first, math.floor(s.t / DAY)) end
  local start = days and (today - days + 1) or math.max(first, today - 89)
  local out = {}
  for d = start, today do out[d - start + 1] = { day = d, earned = 0, spent = 0, sales = 0, buys = 0 } end
  local tot = { earned = 0, spent = 0, sales = 0, buys = 0 }
  for _, b in ipairs(l.buys) do
    local row = out[math.floor(b.t / DAY) - start + 1]
    if row then row.spent, row.buys = row.spent + b.cost, row.buys + 1; tot.spent, tot.buys = tot.spent + b.cost, tot.buys + 1 end
  end
  for _, s in ipairs(l.sales) do
    if not onlyFlipped or isFlipped(s.name) then
      local row = out[math.floor(s.t / DAY) - start + 1]
      if row then row.earned, row.sales = row.earned + s.money, row.sales + 1; tot.earned, tot.sales = tot.earned + s.money, tot.sales + 1 end
    end
  end
  local run = 0
  for _, row in ipairs(out) do run = run + row.earned - row.spent; row.profit = run end
  tot.profit = tot.earned - tot.spent
  return out, tot
end

-- Profit per flipped item, all time: what you bought it for (average per unit) against what it sold for.
-- Sales mails only carry the item name, so sales are matched to purchases by name.
function Ledger.ByItem()
  local l, by = db(), {}
  for _, b in ipairs(l.buys) do
    local e = by[b.name or "?"]
    if not e then e = { name = b.name or "?", itemID = b.itemID, bought = 0, cost = 0, sold = 0, earned = 0, sales = 0 }; by[e.name] = e end
    e.bought, e.cost = e.bought + (b.qty or 0), e.cost + (b.cost or 0)
  end
  for _, s in ipairs(l.sales) do
    local e = by[s.name]
    if e then e.sold, e.earned, e.sales = e.sold + (s.qty or 1), e.earned + (s.money or 0), e.sales + 1 end
  end
  for _, x in ipairs(l.expired) do
    local e = by[x.name]
    if e then e.expired = (e.expired or 0) + 1 end
  end
  local out = {}
  for _, e in pairs(by) do
    e.avg = e.bought > 0 and e.cost / e.bought or 0
    e.costOfSold = e.avg * e.sold
    e.profit = e.earned - e.costOfSold           -- realised: only the units that sold
    e.roi = e.costOfSold > 0 and e.profit / e.costOfSold or nil
    e.left = math.max(0, e.bought - e.sold)      -- still in bags, mail or on the AH
    table.insert(out, e)
  end
  table.sort(out, function(a, b)
    if (a.sold > 0) ~= (b.sold > 0) then return a.sold > 0 end   -- items with sales first
    return a.profit > b.profit
  end)
  return out
end

function Ledger.Recent(n, onlyFlipped)
  local l, all = db(), {}
  for _, b in ipairs(l.buys) do table.insert(all, { t = b.t, kind = "buy", name = b.name, itemID = b.itemID, qty = b.qty, amount = -b.cost }) end
  for _, s in ipairs(l.sales) do
    if not onlyFlipped or isFlipped(s.name) then table.insert(all, { t = s.t, kind = "sale", name = s.name, qty = s.qty, amount = s.money }) end
  end
  table.sort(all, function(a, b) return a.t > b.t end)
  local out = {}
  for i = 1, math.min(n, #all) do out[i] = all[i] end
  return out
end

-- ---------- page ----------
FF.UI.RegisterPage("earnings", function(parent)
  local K = FF.Kit
  local COL, text, box, button = K.COL, K.text, K.box, K.flatButton
  local opts = FF.db.earnings
  local page = CreateFrame("Frame", nil, parent)
  page:SetAllPoints()
  local title = text(page, 18, COL.text); title:SetPoint("TOPLEFT", 20, -16); title:SetText("Earnings")
  local sub = text(page, 11, COL.muted); sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -5)
  sub:SetText("Purchases made with Gold Forge, and auction sales read from your mailbox (open it to update).")

  local ranges = { { "7 days", 7 }, { "30 days", 30 }, { "All", false } }
  local rangeBtns = {}
  for i, r in ipairs(ranges) do
    local b = button(page, r[1], 70, 24, "ghost", function() opts.range = r[2]; page:Refresh() end)
    b:SetPoint("TOPRIGHT", -20 - (3 - i) * 76, -18)
    b.value = r[2]
    rangeBtns[i] = b
  end
  local only = K.checkbox(page, "Only items I flipped", function() return opts.onlyFlipped end,
    function(v) opts.onlyFlipped = v; page:Refresh() end)
  only:SetPoint("TOPRIGHT", -380, -20)
  sub:SetPoint("RIGHT", only, "LEFT", -16, 0)

  -- stat cards
  local cards = {}
  for i, name in ipairs({ "Earned", "Spent", "Profit", "Sales" }) do
    local c = box(page, COL.card, COL.line)
    c:SetHeight(64)
    c.k = text(c, 11, COL.muted); c.k:SetPoint("TOPLEFT", 12, -10); c.k:SetText(name)
    c.v = text(c, 18, COL.text); c.v:SetPoint("TOPLEFT", 12, -30)
    cards[i] = c
  end

  -- chart
  local chartCard = box(page, COL.card, COL.line)
  chartCard:SetPoint("TOPLEFT", 20, -138); chartCard:SetPoint("RIGHT", -20, 0); chartCard:SetHeight(210)
  local legend = text(chartCard, 10, COL.muted); legend:SetPoint("TOPLEFT", 14, -10)
  legend:SetText("|cff4ade80■|r Earned   |cfff87171■|r Spent   |cffe8b13a—|r Running profit")
  local plot = CreateFrame("Frame", nil, chartCard)
  plot:SetPoint("TOPLEFT", 74, -30); plot:SetPoint("BOTTOMRIGHT", -14, 26)
  local pool = { tex = {}, lines = {}, labels = {}, hits = {} }
  local used
  local function tex(r, g, b, a)
    used.tex = used.tex + 1
    local t = pool.tex[used.tex] or plot:CreateTexture(nil, "ARTWORK")
    pool.tex[used.tex] = t
    t:ClearAllPoints(); t:SetColorTexture(r, g, b, a or 1); t:Show()
    return t
  end
  local function line(x1, y1, x2, y2, r, g, b, thick)
    used.lines = used.lines + 1
    local l = pool.lines[used.lines] or plot:CreateLine(nil, "OVERLAY")
    pool.lines[used.lines] = l
    l:SetThickness(thick or 2); l:SetColorTexture(r, g, b, 1)
    l:SetStartPoint("BOTTOMLEFT", x1, y1); l:SetEndPoint("BOTTOMLEFT", x2, y2); l:Show()
  end
  local function label(parentFrame, s, size, color)
    used.labels = used.labels + 1
    local fs = pool.labels[used.labels] or text(chartCard, size or 10, color or COL.dim)
    pool.labels[used.labels] = fs
    fs:ClearAllPoints(); fs:SetText(s); fs:Show()
    return fs
  end
  local empty = text(chartCard, 12, COL.dim); empty:SetPoint("CENTER", plot, "CENTER")

  local function drawChart(days)
    used = { tex = 0, lines = 0, labels = 0, hits = 0 }
    local w, h = plot:GetWidth(), plot:GetHeight()
    if w < 10 then C_Timer.After(0.05, function() if page:IsShown() then page:Refresh() end end); return end
    local lo, hi = 0, 0
    for _, d in ipairs(days) do
      hi = math.max(hi, d.earned, d.spent, d.profit)
      lo = math.min(lo, d.profit)
    end
    local anything = hi > 0 or lo < 0
    empty:SetShown(not anything)
    empty:SetText("No purchases or sales yet. Buy a deal, sell it, and open your mailbox.")
    if not anything then hi = 1 end
    local span = hi - lo
    local Y = function(v) return (v - lo) / span * h end
    -- grid lines and money labels
    for i = 0, 3 do
      local v = lo + span * i / 3
      local t = tex(1, 1, 1, 0.06); t:SetHeight(1); t:SetPoint("BOTTOMLEFT", 0, Y(v)); t:SetPoint("BOTTOMRIGHT", 0, Y(v))
      local l = label(chartCard, FF.Money(v)); l:SetPoint("RIGHT", plot, "BOTTOMLEFT", -6, Y(v))
    end
    local zero = tex(1, 1, 1, 0.25); zero:SetHeight(1); zero:SetPoint("BOTTOMLEFT", 0, Y(0)); zero:SetPoint("BOTTOMRIGHT", 0, Y(0))
    -- bars per day: earned (green) and spent (red) side by side
    local n = #days
    local slot = w / n
    local bw = math.max(1, slot * 0.38)
    local prev
    for i, d in ipairs(days) do
      local x = (i - 1) * slot + slot / 2
      if d.earned > 0 then
        local t = tex(0.29, 0.87, 0.5, 0.85); t:SetSize(bw, math.max(1, Y(d.earned) - Y(0))); t:SetPoint("BOTTOMLEFT", x - bw, Y(0))
      end
      if d.spent > 0 then
        local t = tex(0.97, 0.44, 0.44, 0.85); t:SetSize(bw, math.max(1, Y(d.spent) - Y(0))); t:SetPoint("BOTTOMLEFT", x, Y(0))
      end
      local py = Y(d.profit)
      if prev then line(prev[1], prev[2], x, py, 0.95, 0.72, 0.11, 2) end
      prev = { x, py }
      -- date labels: about 7 across
      if n <= 8 or (i - 1) % math.ceil(n / 7) == 0 or i == n then
        local l = label(chartCard, date("%d %b", d.day * DAY)); l:SetPoint("TOP", plot, "BOTTOMLEFT", x, -6)
      end
      -- hover area for the day
      used.hits = used.hits + 1
      local hit = pool.hits[used.hits]
      if not hit then
        hit = CreateFrame("Frame", nil, plot); hit:EnableMouse(true)
        hit:SetScript("OnEnter", function(s)
          local dd = s.data
          GameTooltip:SetOwner(s, "ANCHOR_TOP")
          GameTooltip:SetText(date("%A %d %B", dd.day * DAY), 1, 1, 1)
          GameTooltip:AddDoubleLine("Earned (" .. dd.sales .. " sales)", FF.Money(dd.earned), 0.29, 0.87, 0.5)
          GameTooltip:AddDoubleLine("Spent (" .. dd.buys .. " buys)", FF.Money(dd.spent), 0.97, 0.44, 0.44)
          GameTooltip:AddDoubleLine("Running profit", FF.Money(dd.profit), 0.95, 0.72, 0.11)
          GameTooltip:Show()
        end)
        hit:SetScript("OnLeave", GameTooltip_Hide)
        pool.hits[used.hits] = hit
      end
      hit.data = d
      hit:ClearAllPoints(); hit:SetPoint("BOTTOMLEFT", (i - 1) * slot, 0); hit:SetSize(slot, h); hit:Show()
    end
    for i = used.tex + 1, #pool.tex do pool.tex[i]:Hide() end
    for i = used.lines + 1, #pool.lines do pool.lines[i]:Hide() end
    for i = used.labels + 1, #pool.labels do pool.labels[i]:Hide() end
    for i = used.hits + 1, #pool.hits do pool.hits[i]:Hide() end
  end

  -- bottom card: recent purchases and sales, or profit per item
  local recent = box(page, COL.card, COL.line)
  recent:SetPoint("TOPLEFT", 20, -360); recent:SetPoint("BOTTOMRIGHT", -20, 34)
  opts.tab = opts.tab or "byitem"
  local tabs = {}
  for i, tdef in ipairs({ { "byitem", "By item" }, { "recent", "Recent" } }) do
    local b = button(recent, tdef[2], 80, 22, "ghost", function() opts.tab = tdef[1]; page:Refresh() end)
    b:SetPoint("TOPLEFT", 12 + (i - 1) * 86, -8)
    b.key = tdef[1]
    tabs[i] = b
  end
  local note = text(recent, 10, COL.dim); note:SetPoint("TOPRIGHT", -14, -14)
  -- columns for "By item"
  local ICOLS = { { "Item", 0, "LEFT" }, { "Bought", 60 }, { "Sold", 96 }, { "Avg cost", 84 }, { "Spent", 84 }, { "Earned", 84 }, { "Profit", 84 }, { "ROI", 50 } }
  local heads = {}
  for i, c in ipairs(ICOLS) do
    local h = text(recent, 11, COL.muted, nil, true); h:SetJustifyH(c[3] or "RIGHT"); h:SetText(c[1])
    heads[i] = h
  end
  local lines, cells = {}, {}
  local NLINES = 8
  for i = 1, NLINES do
    local fs = text(recent, 11, COL.text); fs:SetPoint("TOPLEFT", 14, -24 - i * 20); fs:SetPoint("RIGHT", -14, 0); fs:SetJustifyH("LEFT")
    lines[i] = fs
    cells[i] = {}
    for c = 1, #ICOLS do
      local cf = text(recent, 11, c == 7 and COL.green or COL.text, nil, c == 7)
      cf:SetJustifyH(ICOLS[c][3] or "RIGHT")
      cells[i][c] = cf
    end
  end
  local function layoutItemCols()
    local width = recent:GetWidth() - 28
    local fixed = 0
    for i = 2, #ICOLS do fixed = fixed + ICOLS[i][2] end
    local x = 14
    for c, col in ipairs(ICOLS) do
      local w = c == 1 and math.max(140, width - fixed) or col[2]
      heads[c]:ClearAllPoints(); heads[c]:SetPoint("TOPLEFT", x, -40); heads[c]:SetWidth(w - 6)
      for i = 1, NLINES do
        local cf = cells[i][c]
        cf:ClearAllPoints(); cf:SetPoint("TOPLEFT", x, -40 - i * 20); cf:SetWidth(w - 6)
      end
      x = x + w
    end
  end

  function page:Refresh()
    local cw = (page:GetWidth() - 40 - 3 * 12) / 4
    for i, c in ipairs(cards) do c:ClearAllPoints(); c:SetWidth(cw); c:SetPoint("TOPLEFT", 20 + (i - 1) * (cw + 12), -62) end
    for _, b in ipairs(rangeBtns) do b:SetStyle(b.value == opts.range and "primary" or "ghost") end
    only:Refresh()
    local days, tot = Ledger.Days(opts.range or nil, opts.onlyFlipped)
    cards[1].v:SetText(FF.Money(tot.earned))
    cards[2].v:SetText(FF.Money(tot.spent))
    cards[3].v:SetText(FF.Money(tot.profit))
    cards[3].v:SetTextColor(unpack(tot.profit < 0 and COL.red or COL.green))
    cards[4].v:SetText(tostring(tot.sales))
    drawChart(days)
    for _, b in ipairs(tabs) do b:SetStyle(b.key == opts.tab and "primary" or "ghost") end
    local byItem = opts.tab == "byitem"
    for _, h in ipairs(heads) do h:SetShown(byItem) end
    -- only as many rows as fit in the card at this window size
    local fit = math.max(1, math.min(NLINES, math.floor((recent:GetHeight() - (byItem and 48 or 30)) / 20)))
    for i = 1, NLINES do
      lines[i]:SetShown(not byItem and i <= fit)
      for _, cf in ipairs(cells[i]) do cf:SetShown(byItem and i <= fit) end
    end
    if byItem then
      layoutItemCols()
      local items = Ledger.ByItem()
      note:SetText(#items > 0 and string.format("All time · %d items · sales matched to purchases by name · %d expired auctions (deposit lost)",
        #items, #db().expired) or "")
      for i = 1, NLINES do
        local e, c = items[i], cells[i]
        if e then
          c[1]:SetText(e.name)
          c[2]:SetText(tostring(e.bought))
          c[3]:SetText((e.sold > 0 and tostring(e.sold) or "|cff6e665b-|r")
            .. ((e.expired or 0) > 0 and string.format(" |cffe0605a(%d exp.)|r", e.expired) or ""))
          c[4]:SetText(FF.Money(e.avg))
          c[5]:SetText(FF.Money(e.cost))
          c[6]:SetText(e.earned > 0 and FF.Money(e.earned) or "|cff6e665b-|r")
          c[7]:SetText(e.sold > 0 and FF.Money(e.profit) or "|cff6e665bnot sold yet|r")
          c[7]:SetTextColor(unpack(e.profit < 0 and COL.red or COL.green))
          c[8]:SetText(e.roi and string.format("%d%%", e.roi * 100 + 0.5) or "-")
        else
          for k, cf in ipairs(c) do cf:SetText(i == 1 and k == 1 and #items == 0 and "|cff6e665bNo flips recorded yet.|r" or "") end
        end
      end
    else
      note:SetText("")
      local rec = Ledger.Recent(NLINES, opts.onlyFlipped)
      for i, fs in ipairs(lines) do
        local e = rec[i]
        if e then
          fs:SetText(string.format("|cffa39a8c%s|r   %s %s%s   %s", date("%d %b %H:%M", e.t),
            e.kind == "sale" and "|cff4ade80Sold|r" or "|cfff87171Bought|r", e.name or "?", e.qty and e.qty > 1 and (" x" .. e.qty) or "",
            FF.Money(e.amount)))
        else
          fs:SetText(i == 1 and "|cff6e665bNothing recorded yet.|r" or "")
        end
      end
    end
  end
  FF:On("FF_LEDGER_CHANGED", function() if page:IsShown() then page:Refresh() end end)
  page:SetScript("OnSizeChanged", function() if page:IsShown() then page:Refresh() end end)
  return page
end)
