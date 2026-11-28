-- Gold Forge: Gold Guide. What's worth farming, measured from your own farming.
-- The game doesn't tell addons drop rates or how fast you kill, so Gold Guide records your farming
-- sessions (kills, loot, skinning, gathering and raw gold per zone) and prices everything with TSM.
-- It only listens to game events (combat log kills and loot windows); it never acts for you.
local _, FF = ...
local Farm = {}
FF.Farm = Farm

local IDLE = 600          -- 10 minutes without a kill or loot ends the session
local GAP = 180           -- longer pauses than this don't count as farming time
local MIN_SAVE = 120      -- sessions shorter than 2 minutes aren't kept
local MIN_HOURS = 0.25    -- a rate needs 15 minutes of farming before it's trusted

-- Starting points: where each item comes from. No drop rates on purpose: they aren't public in a form
-- we can check for Forever, so gold/hour comes from your own sessions. "Where" is a hint, not a promise.
Farm.Spots = {
  { 12811, "Stratholme (living side)", "Crimson Legion mobs" },
  { 12808, "Stratholme, Plaguelands", "Undead" },
  { 14047, "Winterspring, Burning Steppes", "Humanoids level 50+" },
  { 15416, "Burning Steppes", "Black dragonkin, skinning", "skin" },
  { 7080, "Elemental zones", "Water elementals" },
  { 7079, "Elemental zones", "Water elementals" },
  { 7076, "Searing Gorge, Silithus", "Earth elementals" },
  { 7082, "Silithus", "Air elementals" },
  { 7078, "Searing Gorge, Burning Steppes", "Fire elementals" },
  { 7077, "Searing Gorge, Burning Steppes", "Fire elementals" },
  { 7068, "Searing Gorge, Burning Steppes", "Fire elementals" },
  { 14256, "Felwood", "Jadefire satyrs" },
  { 4306, "Arathi Highlands, Thousand Needles", "Humanoids level 20-35" },
  { 4338, "Tanaris, Feralas", "Humanoids level 35-45" },
  { 12803, "Un'Goro Crater, Felwood", "Living elementals, bog beasts" },
  { 15417, "Un'Goro Crater", "Devilsaurs, skinning", "skin" },
  { 15412, "Swamp of Sorrows", "Green dragonkin, skinning", "skin" },
  { 8171, "Winterspring, Un'Goro Crater", "Beasts 50+, skinning", "skin" },
  { 8170, "Winterspring, Un'Goro Crater", "Beasts 50+, skinning", "skin" },
  { 8154, "Tanaris, Burning Steppes", "Scorpids, skinning", "skin" },
  { 14227, "Un'Goro Crater, Silithus", "Spiders 55+" },
  { 13926, "Azshara, Feralas", "Clams from naga and fishing" },
  { 18512, "Silithus, Un'Goro Crater", "Silithids" },
  { 12809, "Un'Goro Crater", "Stone guardians" },
  { 13468, "Burning Steppes, Plaguelands, Silithus", "Herb (rare)", "gather" },
  { 8846, "Felwood, Blasted Lands", "Herb", "gather" },
  { 10620, "Un'Goro, Silithus, Burning Steppes", "Thorium veins", "gather" },
  { 12363, "Un'Goro, Silithus, Burning Steppes", "Thorium veins (rare)", "gather" },
}

local function db() FF.db.farm = FF.db.farm or {}; FF.db.farm.sessions = FF.db.farm.sessions or {}; return FF.db.farm end
local function npcID(guid) return guid and tonumber(select(6, strsplit("-", guid)) or "") end

-- value of one item: TSM value, else what a vendor pays
function Farm.ItemValue(itemID)
  return FF.Value(itemID) or FF.Raw("vendorSell", itemID) or select(11, C_Item.GetItemInfo(itemID)) or 0
end

-- ---------- the live session ----------
local S = nil              -- current session
local lootOpen, moneyAtLoot = false, 0
local looted = {}          -- guid -> what we saw the first time (to tell re-opens from skinning)

local function save()
  if S and S.active >= MIN_SAVE then
    local list = db().sessions
    table.insert(list, S)
    while #list > 150 do table.remove(list, 1) end
    FF.Log(string.format("farm session %s: %d min, %d kills, %s", S.zone, S.active / 60, S.kills, FF.Money(Farm.SessionValue(S))))
  end
  S = nil
  looted = {}
  FF:Fire("FF_FARM_CHANGED")
end

function Farm.Start()
  if S then save() end
  S = { zone = GetRealZoneText() or "?", started = time(), active = 0, last = GetTime(),
        kills = 0, mobs = {}, items = {}, money = 0, skins = 0, gathers = 0 }
  FF:Fire("FF_FARM_CHANGED")
end
function Farm.Stop() save() end
function Farm.Current() return S end

-- something happened: start a session if needed, add the time since the last event
local function touch()
  local t = GetTime()
  if S and (t - S.last > IDLE or (GetRealZoneText() or "?") ~= S.zone) then save() end
  if not S then
    if not db().auto then return false end
    Farm.Start()
  end
  local dt = t - S.last
  if dt < GAP then S.active = S.active + dt end
  S.last = t
  return true
end

function Farm.SessionValue(s)
  local v = s.money or 0
  for id, n in pairs(s.items) do v = v + Farm.ItemValue(id) * n end
  return v
end
function Farm.PerHour(s, amount) return s.active > 0 and amount * 3600 / s.active or 0 end

local function addItem(itemID, qty)
  S.items[itemID] = (S.items[itemID] or 0) + qty
end

FF:On("COMBAT_LOG_EVENT_UNFILTERED", function()
  local _, sub, _, src, _, _, _, dst, dstName = CombatLogGetCurrentEventInfo()
  if sub ~= "PARTY_KILL" then return end
  if src ~= UnitGUID("player") and src ~= UnitGUID("pet") then return end
  if not touch() then return end
  S.kills = S.kills + 1
  local map = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  if pos then
    local x, y = pos:GetXY()
    if x and x > 0 then
      S.pos = S.pos or { map = map, x = 0, y = 0, n = 0 }
      if S.pos.map == map then S.pos.x, S.pos.y, S.pos.n = S.pos.x + x, S.pos.y + y, S.pos.n + 1 end
    end
  end
  local id = npcID(dst)
  if id then
    local m = S.mobs[id] or { name = dstName, n = 0 }
    m.n = m.n + 1; S.mobs[id] = m
  end
  Farm.CheckDead(dstName)
  FF:Fire("FF_FARM_CHANGED")
end)

FF:On("LOOT_OPENED", function()
  lootOpen, moneyAtLoot = true, GetMoney()
  local fishing = IsFishingLoot and IsFishingLoot()
  local bySource = {}
  for slot = 1, GetNumLootItems() do
    local link = GetLootSlotLink(slot)
    local itemID = link and tonumber(link:match("item:(%d+)"))
    local qty = select(3, GetLootSlotInfo(slot)) or 1
    local guid = GetLootSourceInfo and GetLootSourceInfo(slot)
    if itemID then
      guid = guid or "?"
      bySource[guid] = bySource[guid] or {}
      table.insert(bySource[guid], { itemID, qty })
    end
  end
  for guid, items in pairs(bySource) do
    local sig = {}
    for _, it in ipairs(items) do table.insert(sig, it[1] .. "x" .. it[2]) end
    sig = table.concat(sig, ",")
    local kind
    if fishing then kind = "fish"
    elseif guid:find("^GameObject") then kind = "gather"
    elseif looted[guid] then kind = looted[guid] ~= sig and "skin" or nil   -- same items again = just re-opened
    else kind = "drop" end
    if kind and touch() then
      looted[guid] = sig
      if kind == "skin" then S.skins = S.skins + 1 elseif kind == "gather" then S.gathers = S.gathers + 1 end
      for _, it in ipairs(items) do addItem(it[1], it[2]) end
    end
  end
  FF:Fire("FF_FARM_CHANGED")
end)
FF:On("PLAYER_MONEY", function()
  local m = GetMoney()
  if lootOpen and m > moneyAtLoot and S then S.money = S.money + (m - moneyAtLoot); FF:Fire("FF_FARM_CHANGED") end
  moneyAtLoot = m
end)
FF:On("LOOT_CLOSED", function() lootOpen = false end)
FF:On("PLAYER_LOGOUT", function() save() end)
FF:On("PLAYER_ENTERING_WORLD", function() if S and (GetRealZoneText() or "?") ~= S.zone then save() end end)

-- ---------- what the sessions add up to ----------
-- per item: the best measured rate (per hour) in any zone with at least 15 minutes of farming
function Farm.Rates()
  local zones = {}
  for _, s in ipairs(db().sessions) do
    local z = zones[s.zone] or { zone = s.zone, active = 0, items = {}, kills = 0, money = 0, sessions = 0, last = 0 }
    z.active, z.kills, z.money, z.sessions = z.active + s.active, z.kills + s.kills, z.money + (s.money or 0), z.sessions + 1
    z.last = math.max(z.last, s.started)
    for id, n in pairs(s.items) do z.items[id] = (z.items[id] or 0) + n end
    zones[s.zone] = z
  end
  local best = {}
  for _, z in pairs(zones) do
    local hours = z.active / 3600
    if hours >= MIN_HOURS then
      for id, n in pairs(z.items) do
        local rate = n / hours
        if not best[id] or rate > best[id].rate then best[id] = { rate = rate, zone = z.zone, hours = hours } end
      end
    end
  end
  return best, zones
end

-- gold/hour of an item at a rate, counting at most one day of region sales per hour farmed
function Farm.GoldPerHour(itemID, rate)
  local s = FF.Stats(itemID)
  local sellable = rate
  if s.soldPerDay and s.soldPerDay > 0 then sellable = math.min(rate, s.soldPerDay) end
  return sellable * Farm.ItemValue(itemID), sellable < rate
end

-- the "What to farm" rows: the starting spots plus everything you've looted with a measured rate
function Farm.ItemRows()
  local best = Farm.Rates()
  local rows, seen = {}, {}
  local function add(id, where, source, kind)
    if seen[id] then return end
    seen[id] = true
    local s = FF.Stats(id)
    local r = { itemID = id, where = where, source = source, kind = kind, value = Farm.ItemValue(id),
                soldPerDay = s.soldPerDay, normal = s.historical }
    r.vs = (r.normal and r.normal > 0 and s.realm) and (s.realm / r.normal - 1) or nil
    local b = best[id]
    if b then
      r.rate, r.rateZone = b.rate, b.zone
      r.gph, r.capped = Farm.GoldPerHour(id, b.rate)
      if not where then r.where = b.zone end
    end
    -- raid demand coming? (the Investments themes)
    for _, t in ipairs(FF.Invest and FF.Invest.Themes or {}) do
      for _, it in ipairs(t.items) do
        if it[1] == id and t.sellTo and time() < t.sellTo then r.theme = t end
      end
    end
    table.insert(rows, r)
  end
  for _, sp in ipairs(Farm.Spots) do add(sp[1], sp[2], sp[3], sp[4]) end
  for id, b in pairs(best) do
    if Farm.ItemValue(id) * b.rate >= 10000 then add(id, nil, "Your loot") end   -- worth 1g+/hour
  end
  return rows
end

function Farm.ZoneRows()
  local _, zones = Farm.Rates()
  local out = {}
  for _, z in pairs(zones) do
    local value = z.money
    local top = {}
    for id, n in pairs(z.items) do
      local v = Farm.ItemValue(id) * n
      value = value + v
      table.insert(top, { id = id, n = n, v = v })
    end
    table.sort(top, function(a, b) return a.v > b.v end)
    z.value, z.top = value, top
    z.gph = z.active > 0 and value * 3600 / z.active or 0
    z.kph = z.active > 0 and z.kills * 3600 / z.active or 0
    table.insert(out, z)
  end
  table.sort(out, function(a, b) return a.gph > b.gph end)
  return out
end

-- ---------- farms (FarmData.lua) ----------
local function lower(s) return (s or ""):lower() end
local function mobMatches(f, mobName)
  local n = lower(mobName)
  for _, part in ipairs(f.mobs or {}) do if n:find(lower(part), 1, true) then return true end end
  return false
end

-- killing mobs of a farm marked dead: warn once per session
local warned = {}
function Farm.CheckDead(mobName)
  local zone = GetRealZoneText() or ""
  for _, f in ipairs(FF.FarmData or {}) do
    if f.status == "dead" and f.zone == zone and mobMatches(f, mobName) and not warned[f.id] then
      warned[f.id] = true
      local msg = "Gold Guide: " .. f.name .. " is a dead farm. " .. (f.notes or "")
      if RaidNotice_AddMessage and RaidWarningFrame then RaidNotice_AddMessage(RaidWarningFrame, msg, ChatTypeInfo.RAID_WARNING) end
      FF.Print(msg)
    end
  end
end

-- which farm a session was: the farm in that zone whose mobs you killed most
function Farm.FarmOf(s)
  local best, bestN = nil, 0
  for _, f in ipairs(FF.FarmData or {}) do
    if f.zone == s.zone and f.mobs then
      local n = 0
      for _, m in pairs(s.mobs or {}) do if mobMatches(f, m.name) then n = n + m.n end end
      if n > bestN then best, bestN = f, n end
    end
  end
  return best
end

-- live estimate from the drop chances: chance x kills/hour x today's price (only drops with a known chance)
function Farm.Estimate(f)
  local kph = db().kph or 140
  local total, any = 0, false
  for _, d in ipairs(f.drops or {}) do
    if d[2] then total = total + d[2] / 100 * kph * Farm.ItemValue(d[1]); any = true end
  end
  return any and total or nil
end

-- your skinning skill, or nil if you don't have Skinning
function Farm.SkinningSkill()
  local ok, rank = pcall(function()
    if GetProfessions then
      for _, i in ipairs({ GetProfessions() }) do
        local name, _, r, _, _, _, line = GetProfessionInfo(i)
        if line == 393 or name == "Skinning" then return r end
      end
    end
    if GetNumSkillLines then
      for i = 1, GetNumSkillLines() do
        local name, header, _, r = GetSkillLineInfo(i)
        if not header and name == "Skinning" then return r end
      end
    end
  end)
  return ok and rank or nil
end

function Farm.Get(id) for _, f in ipairs(FF.FarmData or {}) do if f.id == id then return f end end end

-- the farm your notes recommend for your skinning skill
function Farm.Suggest()
  local skill = Farm.SkinningSkill()
  if not skill then return Farm.Get(FF.FarmNoSkinning), nil end
  for _, s in ipairs(FF.FarmSkinning or {}) do
    if skill >= s[1] and skill <= s[2] then return Farm.Get(s[3]), skill end
  end
end

function Farm.FarmRows()
  local measured = {}
  for _, s in ipairs(db().sessions) do
    local f = Farm.FarmOf(s)
    if f then
      local m = measured[f.id] or { active = 0, value = 0, n = 0, kills = 0 }
      m.active, m.value, m.n, m.kills = m.active + s.active, m.value + Farm.SessionValue(s), m.n + 1, m.kills + s.kills
      measured[f.id] = m
    end
  end
  local out = {}
  for _, f in ipairs(FF.FarmData or {}) do
    local r = { farm = f, key = f.id, live = Farm.Estimate(f) }
    local m = measured[f.id]
    if m and m.active > 0 then
      r.mine, r.mineHours, r.mineKph = m.value * 3600 / m.active, m.active / 3600, m.kills * 3600 / m.active
    end
    r.sortGph = (f.status == "dead") and -1 or (r.mine and r.mineHours >= MIN_HOURS and r.mine)
      or r.live or (f.est and (f.est[1] + f.est[2]) / 2 * 10000) or 0
    table.insert(out, r)
  end
  return out
end

-- map pin for a farm's route: each click moves the pin to the next point (TomTom gets all of them)
local mapCache = {}
local function mapIDFor(zone)
  if mapCache[zone] ~= nil then return mapCache[zone] or nil end
  local here = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  local info = here and C_Map.GetMapInfo(here)
  if info and info.name == zone then mapCache[zone] = here; return here end
  for id = 1, 2500 do
    local i = C_Map.GetMapInfo(id)
    if i and i.name == zone and (not Enum.UIMapType or i.mapType == Enum.UIMapType.Zone) then mapCache[zone] = id; return id end
  end
  mapCache[zone] = false
end
-- the best place to pin for a farm: your saved spot, where you've killed its mobs, its route, or the zone
function Farm.Spot(f)
  local saved = db().spots and db().spots[f.id]
  if saved then return saved.map, saved.x, saved.y, "your saved spot" end
  local m, x, y, n = nil, 0, 0, 0
  for _, s in ipairs(db().sessions) do
    if s.pos and s.pos.n > 0 and Farm.FarmOf(s) == f then
      if not m then m = s.pos.map end
      if s.pos.map == m then x, y, n = x + s.pos.x, y + s.pos.y, n + s.pos.n end
    end
  end
  if S and S.pos and S.pos.n > 0 and Farm.FarmOf(S) == f and (not m or S.pos.map == m) then
    m = m or S.pos.map
    x, y, n = x + S.pos.x, y + S.pos.y, n + S.pos.n
  end
  if n > 0 then return m, x / n, y / n, "where you've farmed it (" .. n .. " kills)" end
  if f.route then return nil end
  local zm = mapIDFor(f.zone)
  if zm then return zm, 0.5, 0.5, "the zone only: farm here once or press Save spot for an exact pin" end
end

-- Save spot: remember where you're standing as this farm's pin
function Farm.SaveSpot(f)
  local map = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  local x, y = pos and pos:GetXY()
  if not x or x == 0 then FF.Kit.status("Can't read your position here (inside an instance?). Save the spot outside, e.g. at the entrance."); return end
  db().spots = db().spots or {}
  db().spots[f.id] = { map = map, x = x, y = y }
  FF.Kit.status(string.format("Saved this spot for %s (%.0f, %.0f).", f.name, x * 100, y * 100))
  FF:Fire("FF_FARM_CHANGED")
end

local function setPin(m, x, y)
  if not (C_Map.SetUserWaypoint and UiMapPoint) then return false end
  local ok = pcall(C_Map.SetUserWaypoint, UiMapPoint.CreateFromCoordinates(m, x, y))
  if ok and C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then C_SuperTrack.SetSuperTrackedUserWaypoint(true) end
  return ok
end

function Farm.PinNext(f)
  local sm, sx, sy, how = Farm.Spot(f)
  if sm then
    if setPin(sm, sx, sy) then
      FF.Kit.status(string.format("Map pin for %s at (%.0f, %.0f): %s.", f.name, sx * 100, sy * 100, how))
    else
      FF.Kit.status("The game didn't accept a map pin there.")
    end
    return
  end
  if not f.route then FF.Kit.status("No map position for " .. f.name .. ". Stand at the spot and press Save spot."); return end
  local m = mapIDFor(f.zone)
  if not m then FF.Kit.status("Couldn't find " .. f.zone .. " on the map."); return end
  if TomTom and TomTom.AddWaypoint and not f.tomtom then
    for _, p in ipairs(f.route) do TomTom:AddWaypoint(m, p[1] / 100, p[2] / 100, { title = f.name .. ": " .. p[3] }) end
    f.tomtom = true
  end
  f.pinIdx = (f.pinIdx or 0) % #f.route + 1
  local p = f.route[f.pinIdx]
  setPin(m, p[1] / 100, p[2] / 100)
  FF.Kit.status(string.format("Map pin %d/%d: %s (%d, %d). Click again for the next point.", f.pinIdx, #f.route, p[3], p[1], p[2]))
end

-- ---------- "where to farm" for item tooltips ----------
local whereIndex
local ratesCache, ratesAt = nil, 0
function Farm.WhereToFarm(itemID)
  if not whereIndex then
    whereIndex = {}
    local function add(id, e) whereIndex[id] = whereIndex[id] or {}; table.insert(whereIndex[id], e) end
    for _, f in ipairs(FF.FarmData or {}) do
      for _, d in ipairs(f.drops or {}) do add(d[1], { farm = f, chance = d[2] }) end
    end
    for _, sp in ipairs(Farm.Spots) do
      local dup = false
      for _, e in ipairs(whereIndex[sp[1]] or {}) do if e.farm then dup = true end end
      if not dup then add(sp[1], { where = sp[2], source = sp[3] }) end
    end
    -- best (highest chance) first, dead farms last
    for _, list in pairs(whereIndex) do
      table.sort(list, function(a, b)
        local da, db_ = a.farm and a.farm.status == "dead", b.farm and b.farm.status == "dead"
        if da ~= db_ then return db_ end
        return (a.chance or 0) > (b.chance or 0)
      end)
    end
  end
  if not ratesCache or GetTime() - ratesAt > 30 then ratesCache, ratesAt = Farm.Rates(), GetTime() end
  return whereIndex[itemID], ratesCache[itemID]
end

-- ---------- the small farming bar ----------
local bar
local function barText()
  if not S then return "Gold Guide: not farming" end
  local v = Farm.SessionValue(S)
  return string.format("|cfff2b81dFarming|r %s  ·  %dm  ·  %d kills  ·  %s  ·  |cff58c27d%s/h|r",
    S.zone, S.active / 60, S.kills, FF.Money(v), FF.Money(Farm.PerHour(S, v)))
end
function Farm.RefreshBar()
  local want = db().showBar and S ~= nil
  if not want then if bar then bar:Hide() end; return end
  if not bar then
    local K = FF.Kit
    bar = K.box(UIParent, K.COL.bg, K.COL.line2)
    bar:SetSize(420, 26); bar:SetFrameStrata("MEDIUM")
    bar:SetMovable(true); bar:EnableMouse(true); bar:RegisterForDrag("LeftButton"); bar:SetClampedToScreen(true)
    bar:SetScript("OnDragStart", bar.StartMoving)
    bar:SetScript("OnDragStop", function(s)
      s:StopMovingOrSizing()
      local x, y = s:GetCenter()
      db().barPos = { x, y }
    end)
    bar:SetScript("OnMouseUp", function(_, b) if b == "RightButton" then FF.UI.Show(); FF.UI.Go("farm") end end)
    bar.t = K.text(bar, 11, K.COL.text); bar.t:SetPoint("LEFT", 10, 0); bar.t:SetPoint("RIGHT", -10, 0)
    local p = db().barPos
    if p then bar:SetPoint("CENTER", UIParent, "BOTTOMLEFT", p[1], p[2]) else bar:SetPoint("TOP", 0, -120) end
    C_Timer.NewTicker(5, function() if bar:IsShown() then bar.t:SetText(barText()) end end)
  end
  bar.t:SetText(barText())
  bar:Show()
end
FF:On("FF_FARM_CHANGED", function() Farm.RefreshBar() end)
FF:On("PLAYER_LOGIN", function()
  local d = db()
  if d.auto == nil then d.auto = true end
  if d.showBar == nil then d.showBar = true end
  d.view = d.view or "farms"
  d.kph = d.kph or 140
end)

-- ---------- page ----------
FF.UI.RegisterPage("farm", function(parent)
  local K = FF.Kit
  local COL, text, box, button = K.COL, K.text, K.box, K.flatButton
  local page = CreateFrame("Frame", nil, parent)
  page:SetAllPoints()
  local title = text(page, 18, COL.text); title:SetPoint("TOPLEFT", 20, -16); title:SetText("Gold Guide")
  local sub = text(page, 11, COL.muted); sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -5)
  sub:SetText("What's worth farming. Gold/hour is measured from your own farming: just play, kills and loot are recorded.")

  -- live session card
  local card = box(page, COL.card, COL.line)
  card:SetPoint("TOPLEFT", 20, -62); card:SetPoint("RIGHT", -20, 0); card:SetHeight(64)
  local live = text(card, 14, COL.text, nil, true); live:SetPoint("TOPLEFT", 14, -12); live:SetJustifyH("LEFT")
  local liveSub = text(card, 11, COL.muted); liveSub:SetPoint("TOPLEFT", live, "BOTTOMLEFT", 0, -6); liveSub:SetJustifyH("LEFT")
  local startBtn = button(card, "Start", 84, 26, "primary", function()
    if Farm.Current() then Farm.Stop() else Farm.Start() end
  end)
  startBtn:SetPoint("RIGHT", -14, 0)
  local barBox = K.checkbox(card, "Farming bar", function() return db().showBar end, function(v) db().showBar = v; Farm.RefreshBar() end)
  barBox:SetPoint("RIGHT", startBtn, "LEFT", -110, 0)
  local autoBox = K.checkbox(card, "Track automatically", function() return db().auto end, function(v) db().auto = v end)
  autoBox:SetPoint("RIGHT", barBox, "LEFT", -150, 0)

  -- view picker
  local ctl = box(page, COL.card, COL.line)
  ctl:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -10); ctl:SetPoint("RIGHT", -20, 0); ctl:SetHeight(48)
  local VIEWNAMES = { farms = "Farms", items = "Items worth farming", zones = "Your farming by zone" }
  local view = K.dropdown(ctl, 200,
    function() return { { text = VIEWNAMES.farms, value = "farms" }, { text = VIEWNAMES.items, value = "items" }, { text = VIEWNAMES.zones, value = "zones" } } end,
    function() return VIEWNAMES[db().view] or VIEWNAMES.farms end, nil,
    function(v) db().view = v; page:Refresh() end)
  view:SetPoint("LEFT", 14, 0)
  local kph = K.dropdown(ctl, 150,
    function() local o = {} for _, n in ipairs({ 80, 110, 140, 170, 200 }) do table.insert(o, { text = "Estimate at " .. n .. " kills/h", value = n }) end return o end,
    function() return (db().kph or 140) .. " kills/h" end, nil,
    function(v) db().kph = v; page:Refresh() end)
  kph:SetPoint("LEFT", view, "RIGHT", 10, 0)
  local hint = text(ctl, 10, COL.dim); hint:SetPoint("LEFT", kph, "RIGHT", 14, 0); hint:SetPoint("RIGHT", -14, 0)
  hint:SetWordWrap(true); hint:SetMaxLines(2)
  hint:SetJustifyH("LEFT")

  -- table
  local list = box(page, COL.card, COL.line)
  list:SetPoint("TOPLEFT", ctl, "BOTTOMLEFT", 0, -10); list:SetPoint("BOTTOMRIGHT", -20, 34)
  local VIEWS = {
    farms = { { "Farm", 0, "LEFT" }, { "Zone", 140, "LEFT" }, { "Type", 112, "LEFT" }, { "Estimate g/h", 92 },
              { "Your g/h", 84 }, { "Farmed", 62 }, { "", 96 } },
    items = { { "Item", 0, "LEFT" }, { "Where", 220, "LEFT" }, { "Value", 80 }, { "Sold/day", 60 }, { "Vs 60-day", 66 },
              { "Your rate", 72 }, { "Gold/hour", 90 } },
    zones = { { "Zone", 0, "LEFT" }, { "Last farmed", 100, "LEFT" }, { "Time", 64 }, { "Kills/hour", 76 }, { "Total value", 100 },
              { "Raw gold", 84 }, { "Gold/hour", 90 } },
  }
  local NC = 7
  local heads = {}
  for i = 1, NC do heads[i] = text(list, 10, COL.muted, nil, true) end
  local scroll = CreateFrame("ScrollFrame", nil, list)
  scroll:SetPoint("TOPLEFT", 1, -30); scroll:SetPoint("BOTTOMRIGHT", -1, 4)
  local content = CreateFrame("Frame", nil, scroll); content:SetSize(1, 1)
  scroll:SetScrollChild(content)
  scroll:SetScript("OnSizeChanged", function(s, w) content:SetWidth(w) end)
  K.scrollbar(scroll, content)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(s, delta)
    local max = math.max(0, content:GetHeight() - s:GetHeight())
    s:SetVerticalScroll(math.min(max, math.max(0, s:GetVerticalScroll() - delta * K.ROW_H * 2)))
  end)
  local empty = text(list, 12, COL.dim); empty:SetPoint("CENTER", scroll, "CENTER")
  local function colX(cols, width)
    local fixed, out = 0, {}
    for i = 2, #cols do fixed = fixed + cols[i][2] end
    local x = 14
    for i, c in ipairs(cols) do
      local w = i == 1 and math.max(150, width - 28 - fixed) or c[2]
      out[i] = { x = x, w = w }
      x = x + w
    end
    return out
  end
  local function pct(v) return v and string.format("%+d%%", v * 100 + (v >= 0 and 0.5 or -0.5)) or "-" end

  local rows, expanded = {}, {}
  local function row(i)
    if rows[i] then return rows[i] end
    local r = CreateFrame("Button", nil, content)
    r.hl = r:CreateTexture(nil, "BACKGROUND"); r.hl:SetColorTexture(1, 1, 1, 0.035); r.hl:Hide()
    r.hl:SetPoint("TOPLEFT"); r.hl:SetPoint("TOPRIGHT"); r.hl:SetHeight(K.ROW_H)
    r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(22, 22); r.icon:SetPoint("TOPLEFT", 13, -4)
    r.cells = {}
    for c = 1, NC do r.cells[c] = text(r, 12, COL.text, nil, c == NC) end
    r.detail = text(r, 11, COL.muted, nil, false); r.detail:SetJustifyH("LEFT"); r.detail:SetWordWrap(true)
    r.pin = button(r, "Map pin", 84, 22, "ghost", function() if r.data and r.data.farm then Farm.PinNext(r.data.farm) end end)
    r.pin:SetPoint("TOPRIGHT", -12, -4)
    r.save = button(r, "Save spot", 84, 22, "ghost", function() if r.data and r.data.farm then Farm.SaveSpot(r.data.farm) end end)
    r.save:SetPoint("TOPRIGHT", r.pin, "BOTTOMRIGHT", 0, -6)
    r.save:SetScript("OnEnter", function(s)
      GameTooltip:SetOwner(s, "ANCHOR_LEFT"); GameTooltip:SetText("Save spot", 1, 1, 1)
      GameTooltip:AddLine("Stand where you farm this and click: the map pin goes here from now on.", nil, nil, nil, true); GameTooltip:Show()
    end)
    r.save:SetScript("OnLeave", GameTooltip_Hide)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r:SetScript("OnClick", function(s, mouse)
      local d = s.data
      if mouse == "RightButton" and d.itemID then FF.History.Open(d.itemID); return end
      local key = d.key or d.itemID or d.zone
      expanded[key] = not expanded[key]; page:Refresh()
    end)
    r:SetScript("OnEnter", function(s)
      s.hl:Show()
      local d = s.data
      if d.farm then
        local f = d.farm
        GameTooltip:SetOwner(s, "ANCHOR_RIGHT"); GameTooltip:SetText(f.name, 1, 1, 1)
        GameTooltip:AddLine((f.zone or "") .. (f.area and (" · " .. f.area) or ""), 0.8, 0.8, 0.85, true)
        for _, dr in ipairs(f.drops or {}) do
          GameTooltip:AddDoubleLine((C_Item.GetItemNameByID(dr[1]) or ("item " .. dr[1])) .. (dr[2] and string.format(" (%.1f%%)", dr[2]) or ""),
            FF.Money(Farm.ItemValue(dr[1])), 1, 1, 1)
        end
        if f.skill then GameTooltip:AddLine(string.format("Skinning %d-%d", f.skill[1], f.skill[2]), 0.8, 0.8, 0.85) end
        if f.notes then GameTooltip:AddLine(f.notes, 0.95, 0.72, 0.11, true) end
        if f.source == "guide" then GameTooltip:AddLine("From your gold guide", 0.56, 0.56, 0.6) end
        GameTooltip:AddLine("Click: details · Map pin: show it on the map", 0.56, 0.56, 0.6); GameTooltip:Show()
        return
      end
      if not d.itemID then return end
      GameTooltip:SetOwner(s, "ANCHOR_RIGHT"); GameTooltip:SetItemByID(d.itemID)
      if d.source then GameTooltip:AddLine(d.source .. " · " .. (d.where or ""), 0.8, 0.8, 0.85, true) end
      GameTooltip:AddLine("Click: details · Right-click: price history", 0.56, 0.56, 0.6); GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function(s) s.hl:Hide(); GameTooltip:Hide() end)
    rows[i] = r
    return r
  end

  function page:Refresh()
    if page:GetWidth() < 10 then return end
    view:Refresh(); kph:Refresh(); barBox:Refresh(); autoBox:Refresh()
    -- live card
    local s = Farm.Current()
    if s then
      local v = Farm.SessionValue(s)
      live:SetText(string.format("Farming %s  ·  |cff58c27d%s/h|r", s.zone, FF.Money(Farm.PerHour(s, v))))
      liveSub:SetText(string.format("%d min · %d kills (%d/h) · %d skinned · %d gathered · loot worth %s, incl. %s raw gold",
        s.active / 60, s.kills, Farm.PerHour(s, s.kills), s.skins, s.gathers, FF.Money(v), FF.Money(s.money)))
      startBtn:SetLabel("Stop"); startBtn:SetStyle("ghost")
    else
      live:SetText("Not farming right now")
      liveSub:SetText(db().auto and "A session starts by itself when you kill or loot something, and ends after 10 idle minutes or a zone change."
        or "Press Start before you farm.")
      startBtn:SetLabel("Start"); startBtn:SetStyle("primary")
    end

    local v = VIEWS[db().view] and db().view or "farms"
    local cols = VIEWS[v]
    local width = scroll:GetWidth()
    local cx = colX(cols, width)
    for i, h in ipairs(heads) do
      h:ClearAllPoints(); h:SetPoint("TOPLEFT", cx[i].x + (i == 1 and 30 or 0), -12); h:SetWidth(cx[i].w - 6 - (i == 1 and 30 or 0))
      h:SetText(cols[i][1]:upper()); h:SetJustifyH(cols[i][3] or "RIGHT")
    end

    local data
    if v == "farms" then
      data = Farm.FarmRows()
      table.sort(data, function(a, b) return a.sortGph > b.sortGph end)
      local sug, skill = Farm.Suggest()
      local today = FF.FarmRotation and FF.FarmRotation[tonumber(date("%w")) + 1]
      hint:SetText((sug and ("|cfff2b81dFor you" .. (skill and (" (Skinning " .. skill .. ")") or " (no Skinning)") .. ":|r " .. sug.name .. "   ") or "")
        .. (today and ("|cfff2b81dToday:|r " .. today) or ""))
    elseif v == "items" then
      data = Farm.ItemRows()
      table.sort(data, function(a, b)
        if (a.gph ~= nil) ~= (b.gph ~= nil) then return a.gph ~= nil end
        if a.gph then return a.gph > b.gph end
        return (a.value or 0) * math.min(a.soldPerDay or 0, 50) > (b.value or 0) * math.min(b.soldPerDay or 0, 50)
      end)
      hint:SetText("Gold/hour shows after 15 minutes of farming an item's zone. Until then, sorted by value and how well it sells.")
    else
      data = Farm.ZoneRows()
      hint:SetText("Every zone you've farmed, best gold/hour first. Values use today's prices.")
    end

    local y = 0
    for i, d in ipairs(data) do
      local r = row(i)
      r.data = d
      r:ClearAllPoints(); r:SetPoint("TOPLEFT", 0, -y); r:SetPoint("RIGHT", content, "RIGHT")
      local vals
      r.pin:SetShown(v == "farms" and d.farm and d.farm.zone ~= "Anywhere")
      r.save:SetShown(v == "farms" and d.farm and d.farm.zone ~= "Anywhere" and expanded[d.key] == true)
      if v == "farms" then
        local f = d.farm
        r.icon:Show()
        local first = f.drops and f.drops[1] and f.drops[1][1]
        r.icon:SetTexture(first and C_Item.GetItemIconByID(first) or "Interface\\Icons\\INV_Misc_QuestionMark")
        local dead = f.status == "dead"
        local est = d.live and (FF.Money(d.live) .. " |cff5f5f69live|r")
          or (f.est and f.est[2] > 0 and string.format("%d-%dg |cff5f5f69notes|r", f.est[1], f.est[2]))
          or (f.weekly and string.format("%dg/week", f.weekly)) or "-"
        vals = {
          (dead and "|cffe0605a" or "|cffe6e6e6") .. f.name .. "|r" .. (dead and "  |cffe0605a[DEAD]|r" or ""),
          f.zone or "-",
          f.cat .. (f.skill and string.format(" |cff8e8e99%d+|r", f.skill[1]) or (f.lvl and string.format(" |cff8e8e99Lv %d|r", f.lvl) or "")),
          dead and "|cffe0605a0|r" or est,
          d.mine and FF.Money(d.mine) or "-",
          d.mineHours and string.format("%.1fh", d.mineHours) or "-",
          "",
        }
      elseif v == "items" then
        r.icon:SetTexture(C_Item.GetItemIconByID(d.itemID)); r.icon:Show()
        local name = C_Item.GetItemNameByID(d.itemID)
        if not name and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(d.itemID) end
        local quality = select(3, C_Item.GetItemInfo(d.itemID))
        vals = {
          FF.QualityColor(quality) .. (name or ("Item " .. d.itemID)) .. "|r" .. (d.theme and "  |cfff2b81d[raid demand]|r" or ""),
          (d.where or "-") .. (d.source and ("  |cff5f5f69" .. d.source .. "|r") or ""),
          FF.Money(d.value), d.soldPerDay and string.format("%.0f", d.soldPerDay) or "-", pct(d.vs),
          d.rate and string.format("%.1f/h", d.rate) or "|cff5f5f69not farmed|r",
          d.gph and FF.Money(d.gph) or "-",
        }
      else
        r.icon:Hide()
        vals = {
          d.zone, date("%d %b %H:%M", d.last), string.format("%dh %02dm", d.active / 3600, (d.active % 3600) / 60),
          string.format("%.0f", d.kph), FF.Money(d.value), FF.Money(d.money), FF.Money(d.gph),
        }
      end
      for c, fs in ipairs(r.cells) do
        local off = (c == 1 and v ~= "zones") and 30 or 0
        fs:ClearAllPoints(); fs:SetPoint("TOPLEFT", cx[c].x + off, 0)
        fs:SetSize(cx[c].w - 6 - off, K.ROW_H); fs:SetJustifyH(cols[c][3] or "RIGHT"); fs:SetText(vals[c] or "")
        local green = (v == "farms" and c == 5) or (v ~= "farms" and c == NC)
        fs:SetTextColor(unpack(green and COL.green or COL.text))
      end
      if v == "items" and d.vs then r.cells[5]:SetTextColor(unpack(d.vs < 0 and COL.muted or COL.green)) end

      local key = d.key or d.itemID or d.zone
      local open = expanded[key]
      r.detail:SetShown(open)
      local h = K.ROW_H
      if open then
        local lines = {}
        if v == "farms" then
          local f = d.farm
          local parts = {}
          for _, dr in ipairs(f.drops or {}) do
            local name = C_Item.GetItemNameByID(dr[1]) or ("item " .. dr[1])
            table.insert(parts, string.format("%s %s%s", name, FF.Money(Farm.ItemValue(dr[1])), dr[2] and string.format(" (%.1f%%)", dr[2]) or ""))
          end
          if #parts > 0 then table.insert(lines, "|cfff2b81dDrops:|r " .. table.concat(parts, ",  ")) end
          if f.mobs then table.insert(lines, "|cfff2b81dMobs:|r " .. table.concat(f.mobs, ", ") .. (f.area and ("  ·  " .. f.area) or "")) end
          if f.skill then table.insert(lines, string.format("|cfff2b81dSkinning:|r %d-%d", f.skill[1], f.skill[2])) end
          if d.live then
            table.insert(lines, string.format("Live estimate: drop chance x %d kills/h x today's TSM price (drops with a known chance only). Your notes said %s.",
              db().kph or 140, f.est and string.format("%d-%dg/h", f.est[1], f.est[2]) or "no estimate"))
          end
          if d.mine then
            table.insert(lines, string.format("|cff58c27dYou:|r %s/h over %.1f hours, %d kills/h%s.", FF.Money(d.mine), d.mineHours, d.mineKph,
              d.mineHours < MIN_HOURS and " (under 15 min: not trusted yet)" or ""))
          end
          if f.route then
            local pts = {}
            for _, p in ipairs(f.route) do table.insert(pts, string.format("%s (%d, %d)", p[3], p[1], p[2])) end
            table.insert(lines, "|cfff2b81dRoute:|r " .. table.concat(pts, " -> ") .. "   (Map pin button: next point)")
          end
          local sm, sx, sy, how = Farm.Spot(f)
          if sm then table.insert(lines, string.format("|cfff2b81dMap pin:|r (%.0f, %.0f), %s.", sx * 100, sy * 100, how)) end
          if f.notes then table.insert(lines, "|cff8e8e99" .. f.notes .. "|r") end
          if d.key == "ungoro_devilsaur" or d.key == "weekly_elven_curiosities" then
            table.insert(lines, "|cff8e8e99Checks: " .. table.concat(FF.FarmReminders or {}, " · ") .. "|r")
          end
        elseif v == "items" then
          if d.rate then
            table.insert(lines, string.format("|cfff2b81dYour best:|r %.1f an hour in %s.", d.rate, d.rateZone))
            if d.capped then
              table.insert(lines, string.format("|cffe0605aSells only %.0f a day in the region|r, so gold/hour counts at most that many per hour farmed.", d.soldPerDay))
            end
          else
            table.insert(lines, "Not farmed yet: farm it for 15 minutes and Gold Guide measures your real rate and gold/hour.")
          end
          if d.theme then table.insert(lines, "|cfff2b81dRaid demand:|r " .. (FF.Invest.Timing(d.theme) or d.theme.name)) end
          if d.normal then table.insert(lines, "60-day normal price " .. FF.Money(d.normal) .. ", now " .. FF.Money(d.value) .. ".") end
        else
          local parts = {}
          for j = 1, math.min(8, #d.top) do
            local t = d.top[j]
            table.insert(parts, string.format("%s x%d (%s)", C_Item.GetItemNameByID(t.id) or ("item " .. t.id), t.n, FF.Money(t.v)))
          end
          table.insert(lines, string.format("%d sessions · %d kills", d.sessions, d.kills))
          table.insert(lines, "|cfff2b81dBest loot:|r " .. (#parts > 0 and table.concat(parts, ",  ") or "none"))
        end
        r.detail:ClearAllPoints(); r.detail:SetPoint("TOPLEFT", 44, -K.ROW_H); r.detail:SetWidth(width - (v == "farms" and 160 or 60))
        r.detail:SetText(table.concat(lines, "\n"))
        h = K.ROW_H + r.detail:GetStringHeight() + 10
      end
      r:SetHeight(h)
      r:Show()
      y = y + h
    end
    for i = #data + 1, #rows do rows[i]:Hide() end
    content:SetHeight(math.max(1, y))
    empty:SetShown(#data == 0)
    empty:SetText("No farming recorded yet. Go kill, skin or gather something: Gold Guide records it.")
  end
  FF:On("FF_FARM_CHANGED", function() if page:IsShown() then page:Refresh() end end)
  page:SetScript("OnSizeChanged", function() if page:IsShown() then page:Refresh() end end)
  page:SetScript("OnShow", function() page:Refresh() end)
  return page
end)
