-- Flip Finder: the ledger and the Earnings page.
-- Purchases are recorded when you buy through Flip Finder. Sales are read from the "Auction successful"
-- mails Blizzard sends (their invoice says the item, sale price and AH cut), whenever the mailbox is
-- open. Only reading: the addon never takes mail or money out.
local _, FF = ...
local Ledger = {}
FF.Ledger = Ledger
local DAY = 86400

local function db()
  local l = FF.db.ledger
  l.buys, l.sales, l.seen = l.buys or {}, l.sales or {}, l.seen or {}
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
    if invoiceType == "seller" and itemName then
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
  sub:SetText("Purchases made with Flip Finder, and auction sales read from your mailbox (open it to update).")

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

  -- stat cards
  local cw = (K.W - K.SIDE - 40 - 3 * 12) / 4
  local cards = {}
  for i, name in ipairs({ "Earned", "Spent", "Profit", "Sales" }) do
    local c = box(page, COL.card, COL.line)
    c:SetSize(cw, 64); c:SetPoint("TOPLEFT", 20 + (i - 1) * (cw + 12), -62)
    c.k = text(c, 11, COL.muted); c.k:SetPoint("TOPLEFT", 12, -10); c.k:SetText(name)
    c.v = text(c, 18, COL.text); c.v:SetPoint("TOPLEFT", 12, -30)
    cards[i] = c
  end

  -- chart
  local chartCard = box(page, COL.card, COL.line)
  chartCard:SetPoint("TOPLEFT", 20, -138); chartCard:SetPoint("RIGHT", -20, 0); chartCard:SetHeight(250)
  local legend = text(chartCard, 10, COL.muted); legend:SetPoint("TOPLEFT", 14, -10)
  legend:SetText("|cff4ade80■|r Earned   |cfff87171■|r Spent   |cfff2b81d—|r Running profit")
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

  -- recent purchases and sales
  local recent = box(page, COL.card, COL.line)
  recent:SetPoint("TOPLEFT", 20, -400); recent:SetPoint("BOTTOMRIGHT", -20, 34)
  local rt = text(recent, 13, COL.text); rt:SetPoint("TOPLEFT", 14, -10); rt:SetText("Recent")
  local lines = {}
  for i = 1, 5 do
    local fs = text(recent, 11, COL.text); fs:SetPoint("TOPLEFT", 14, -12 - i * 20); fs:SetWidth(K.W - K.SIDE - 80); fs:SetJustifyH("LEFT")
    lines[i] = fs
  end

  function page:Refresh()
    for _, b in ipairs(rangeBtns) do b:SetStyle(b.value == opts.range and "primary" or "ghost") end
    only:Refresh()
    local days, tot = Ledger.Days(opts.range or nil, opts.onlyFlipped)
    cards[1].v:SetText(FF.Money(tot.earned))
    cards[2].v:SetText(FF.Money(tot.spent))
    cards[3].v:SetText(FF.Money(tot.profit))
    cards[3].v:SetTextColor(unpack(tot.profit < 0 and COL.red or COL.green))
    cards[4].v:SetText(tostring(tot.sales))
    drawChart(days)
    local rec = Ledger.Recent(5, opts.onlyFlipped)
    for i, fs in ipairs(lines) do
      local e = rec[i]
      if e then
        fs:SetText(string.format("|cff8e8e99%s|r   %s %s%s   %s", date("%d %b %H:%M", e.t),
          e.kind == "sale" and "|cff4ade80Sold|r" or "|cfff87171Bought|r", e.name or "?", e.qty and e.qty > 1 and (" x" .. e.qty) or "",
          FF.Money(e.amount)))
      else
        fs:SetText(i == 1 and "|cff5f5f69Nothing recorded yet.|r" or "")
      end
    end
  end
  FF:On("FF_LEDGER_CHANGED", function() if page:IsShown() then page:Refresh() end end)
  return page
end)
