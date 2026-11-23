-- Gold Forge: mailbox helper. One click collects the gold and items from auction mail (sales, purchases,
-- expired and cancelled auctions), one mail at a time, like Blizzard's own "Open All" and the Postal addon.
-- It never touches COD mail (that would cost gold), only auction mail, and stops when the bags are full.
-- Sales are recorded for the Earnings page before their mail is taken.
local _, FF = ...
local Mail = { running = false }
FF.Mail = Mail

-- "Auction successful: %s" -> "^Auction successful: (.+)$"
local function pattern(fmt)
  if not fmt then return nil end
  local p = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", "(.+)")
  return "^" .. p .. "$"
end
local SUBJECTS = {}
for _, fmt in ipairs({
  AUCTION_SOLD_MAIL_SUBJECT or "Auction successful: %s", AUCTION_EXPIRED_MAIL_SUBJECT or "Auction expired: %s",
  AUCTION_REMOVED_MAIL_SUBJECT or "Auction cancelled: %s", AUCTION_WON_MAIL_SUBJECT or "Auction won: %s",
  AUCTION_OUTBID_MAIL_SUBJECT or "Outbid on %s",
}) do table.insert(SUBJECTS, pattern(fmt)) end

local function isAuctionMail(i, subject)
  if GetInboxInvoiceInfo(i) then return true end
  for _, p in ipairs(SUBJECTS) do if subject and subject:match(p) then return true end end
  return false
end

-- the next auction mail with something to take (from the bottom, so indexes don't shift under us)
local function nextMail()
  for i = GetInboxNumItems(), 1, -1 do
    local _, _, _, subject, money, cod, _, itemCount = GetInboxHeaderInfo(i)
    if (cod or 0) == 0 and ((money or 0) > 0 or (itemCount or 0) > 0) and isAuctionMail(i, subject) then
      return i, money or 0, itemCount or 0
    end
  end
end

function Mail.Count()
  local n = 0
  for i = 1, GetInboxNumItems() do
    local _, _, _, subject, money, cod, _, itemCount = GetInboxHeaderInfo(i)
    if (cod or 0) == 0 and ((money or 0) > 0 or (itemCount or 0) > 0) and isAuctionMail(i, subject) then n = n + 1 end
  end
  return n
end

local function freeSlots()
  local n = 0
  for bag = 0, NUM_BAG_SLOTS or 4 do n = n + (C_Container.GetContainerNumFreeSlots(bag) or 0) end
  return n
end

local taken, steps, waiting = { money = 0, mails = 0 }, 0, false
local step

function Mail.Stop(reason)
  if not Mail.running then return end
  Mail.running, waiting = false, false
  local msg = string.format("Collected %s from %d auction mail%s.", FF.Money(taken.money), taken.mails, taken.mails == 1 and "" or "s")
  FF.Print(msg .. (reason and (" " .. reason) or ""))
  FF.Log("mail: " .. msg .. (reason and (" " .. reason) or ""))
  FF:Fire("FF_MAIL_CHANGED")
end

step = function()
  if not Mail.running then return end
  if not (MailFrame and MailFrame:IsShown()) then return Mail.Stop("Mailbox closed.") end
  if FF.Ledger and FF.Ledger.ScanMail then FF.Ledger.ScanMail() end   -- record sales before their mail goes
  local i, money, items = nextMail()
  if not i then return Mail.Stop() end
  if items > 0 and freeSlots() == 0 then return Mail.Stop("Your bags are full.") end
  steps = steps + 1
  if steps > 300 then return Mail.Stop() end
  waiting = true
  if items == 0 then TakeInboxMoney(i) else AutoLootMailItem(i) end
  taken.money, taken.mails = taken.money + money, taken.mails + 1
  FF:Fire("FF_MAIL_CHANGED")
  -- go on when the mailbox has updated (or after a moment if that never comes)
  local mySteps = steps
  C_Timer.After(2, function() if Mail.running and waiting and steps == mySteps then waiting = false; step() end end)
end

-- started by the button click (one click, like Blizzard's "Open All")
function Mail.Start()
  if Mail.running then return Mail.Stop("Stopped.") end
  Mail.running, taken, steps, waiting = true, { money = 0, mails = 0 }, 0, false
  FF:Fire("FF_MAIL_CHANGED")
  step()
end

FF:On("MAIL_INBOX_UPDATE", function()
  if Mail.running and waiting then
    waiting = false
    C_Timer.After(0.15, step)
  end
  FF:Fire("FF_MAIL_CHANGED")
end)
FF:On("MAIL_CLOSED", function() Mail.Stop("Mailbox closed.") end)

-- ---------- the button, next to the mailbox ----------
local btn, info
FF:On("MAIL_SHOW", function()
  if not btn and MailFrame and FF.Kit then
    local K = FF.Kit
    btn = K.flatButton(MailFrame, "Collect auction mail", 190, 28, "primary", function() Mail.Start() end)
    btn:SetPoint("TOPLEFT", MailFrame, "TOPRIGHT", 8, -40)
    btn:SetFrameStrata("HIGH")
    btn:SetScript("OnEnter", function(s)
      GameTooltip:SetOwner(s, "ANCHOR_RIGHT"); GameTooltip:SetText("Collect auction mail", 1, 1, 1)
      GameTooltip:AddLine("Takes the gold and items from your auction mail (sales, purchases, expired and cancelled auctions), one at a time. Never COD mail.", nil, nil, nil, true)
      GameTooltip:Show()
    end)
    btn:HookScript("OnLeave", GameTooltip_Hide)
    info = K.text(MailFrame, 11, K.COL.muted)
    info:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 2, -6)
  end
  FF:Fire("FF_MAIL_CHANGED")
end)
FF:On("FF_MAIL_CHANGED", function()
  if not btn or not MailFrame:IsShown() then return end
  local n = Mail.Count()
  btn:SetLabel(Mail.running and "Stop collecting" or ("Collect auction mail" .. (n > 0 and (" (" .. n .. ")") or "")))
  btn:SetStyle(Mail.running and "ghost" or "primary")
  info:SetText(Mail.running and ("Collected " .. FF.Money(taken.money) .. " so far…") or (n == 0 and "No auction mail to collect." or ""))
end)
