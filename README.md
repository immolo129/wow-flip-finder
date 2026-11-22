# Forever Flip Finder

Finds gold flips on the WoW: Forever auction houses (EU PvP, Horde by default).
It fetches Blizzard's auction data every hour, keeps the price history, and
shows the flips in your browser.

It can run in two ways:

- **On GitHub (recommended):** free and always on, and you can open it from any device. See below.
- **On your PC:** `start.bat`. It only collects while the PC is on.

## Get API keys (both ways)

Log in at https://develop.battle.net/access/clients, click **Create Client**,
give it any name and redirect URL `http://localhost`, then copy the
**Client ID** and **Client Secret**.

## Host it on GitHub (free, one-time setup, about 10 min)

GitHub runs the fetch every hour and publishes the page with GitHub Pages.

1. **Install Git** from https://git-scm.com/download/win (keep the default
   options), then restart VS Code.
2. **Create a GitHub account** at https://github.com if you don't have one.
3. **Publish the folder.** In VS Code open the Source Control tab (Ctrl+Shift+G)
   and click **Publish to GitHub**. Choose **public repository**, because free
   GitHub Pages only works on public repos. `.gitignore` keeps your `.env` file
   (your keys) and the databases out of it.
4. **Add your keys and a password as secrets.** On the repo's GitHub page go to **Settings →
   Secrets and variables → Actions → New repository secret** and add:
   - `BLIZZARD_CLIENT_ID`
   - `BLIZZARD_CLIENT_SECRET`
   - `SITE_PASSWORD`: the password for your page. Make it long and don't use
     it anywhere else, for example four random words like `lantern-otter-cobalt-mirror`.

   Secrets are encrypted and never visible, not even in a public repo.
   *Optional:* on the **Variables** tab, add `REGION`, `RULESET` or `FACTION`
   to change the defaults (eu, 1, horde).
5. **Turn on Pages.** Go to **Settings → Pages → Source** and pick **GitHub Actions**.
6. **First run.** Go to the **Actions** tab, enable workflows if GitHub asks,
   click **Collect auction data → Run workflow**, and wait about 2 minutes.
   Your page is at `https://<your-username>.github.io/<repo-name>/`
   (also shown under Settings → Pages).

After that it runs by itself every hour. Good to know:

- The page is locked with your password. Anyone who opens the link only sees a
  password box: the price data and the stored history are encrypted with it.
  Tick "Remember on this device" so it doesn't ask every time; the **Lock**
  button at the top forgets it again. The code itself is public, but it holds
  nothing private.
- If you change `SITE_PASSWORD`, the stored history can't be read any more and
  the job fails. Delete the **data** release (repo page → Releases) to start over.
- GitHub sometimes starts the hourly run 5–30 minutes late.
- The price history is stored as a file on a release called **data** in your
  repo. Don't delete that release, or the history starts over.
- If a fetch fails, the run gets a red ✗ in the Actions tab, GitHub emails
  you, and the page shows "last fetch failed" (hover it for the reason).
- If the repo gets no commits for 60 days, GitHub turns scheduled jobs off. The
  workflow makes an empty commit every 45 days to prevent that.

## Run it on your PC instead

Try it first with made-up data: double-click `demo.bat` and it opens
http://127.0.0.1:5000.

For real data:

1. Install Python 3.11+ from https://www.python.org/downloads/ and tick
   **"Add python.exe to PATH"** in the installer.
2. Double-click `start.bat`. The first time it opens `.env` in Notepad:
   paste the two keys, save, close, and run `start.bat` again.
3. Leave the black window open. It fetches right away and then every hour.
   The local version also has a "Fetch now" button.

## The pages

| Tab | What it finds | Risk |
|---|---|---|
| Underpriced (reset) | Listings far below the item's 7-day market price in the same house | Price can keep falling; check the chart |
| Between auction houses | Cheaper in Horde, dearer in Blackwater (or the other way) | Blackwater takes 15 % instead of 5 % (already counted) |
| Below vendor price | Listings cheaper than what a vendor pays | None, if it's still there |
| Crafting profits | Recipes whose result sells for more than its reagents cost | You need the profession and the recipe; prices can move while you craft |

**Crafting profits** uses Blizzard's recipe list for WoW: Forever (fetched weekly). Each reagent is
priced at its cheapest source: the Horde or Blackwater market value, or a vendor for common vendor
reagents like vials, thread and flux. The crafted item is priced at its market value after the AH cut.
Click a recipe for the reagent breakdown.

Flips need price history. "Below vendor price" works after the first fetch,
the other two tabs after about 3 hours. Confidence goes from low to high as
history builds (24+ snapshots = high).

Units are capped at what the market normally holds, so it won't tell you to
buy 500 of something that usually has 20 listed. Once sales have been tracked
for 12 hours, units are also capped at what sells within "Days to sell"
(default 2). Click any row for its price history. The "copy" button copies
the item name for the AH search box.

**Sells/day** is an estimate: auctions that disappeared between two hourly
snapshots while they still had 2+ hours left. Cancelled auctions count as sales
too, so it reads a bit high for items that people repost a lot.

**Search** any item in the game with the box at the top: it suggests matches as you type, with the price if it's
on the auction house. Pick one (or press Enter) to open its item view. The full item list comes from
Blizzard once a week.

**More stats** (columns and the item view; click an item, then Details):

| Stat | Meaning |
|---|---|
| Sell rate | Of the units that left the auction house, the share that sold rather than expired or was cancelled. An estimate on the low side. Needs 12 h of tracking. |
| Days of supply | How long the units listed now last at the current sales pace |
| Trend 24h / 7 days | Change in market value |
| 7-day range / average | Lowest, highest and average market value over the last week |
| Region price | Median market value across every auction house of every Forever server type (PvP, Normal, RP, RP-PvP), like TSM's region values |

**How the numbers are kept honest:**

- *Bait listings* far below or above an item's typical price don't move its market value (cheap ones still show as flips).
- *Cancel-and-relist* isn't counted as a sale: if an auction vanished while a cheaper one of the same item stayed up,
  it was cancelled, not bought.
- *Crafting* prices reagents by buying from the actual listings, cheapest first. Set **Crafts** (under Filters) to how
  many you plan to make: buying for 40 crafts costs more per craft than buying for 1.
- *Exp. profit* subtracts the listing deposits you'd expect to lose relisting until it sells, using the sell rate.
  **Deposit % of vendor price** (under Filters, default 15) is an estimate; adjust it if Forever's deposits differ.
- Snapshots are dated by when Blizzard generated the data, not when it was fetched.

If Blizzard hasn't updated an auction house since the last fetch, that data is
skipped instead of being saved twice.

## Settings

In `.env` (PC) or as repository variables (GitHub):

| Setting | Default | Meaning |
|---|---|---|
| REGION | eu | eu or us |
| RULESET | 1 | 1 PvP, 2 Normal, 3 Roleplay, 15 Roleplay PvP |
| FACTION | horde | Hides houses you can't use; set alliance if you switch |
| INTERVAL_MINUTES | 60 | PC only. Blizzard only updates hourly, no point going lower |
| HOST | 127.0.0.1 | PC only. Set 0.0.0.0 to open it from your phone on the same Wi-Fi (http://<PC-IP>:5000) |

## Notes

- Blizzard hasn't documented the Forever API yet. The endpoints used are the ones
  the community confirmed after launch. If Blizzard changes them, the page
  shows "last fetch failed" with the reason when you hover it.
- About 40 % of Forever items aren't in Blizzard's item database yet. Those fall
  back to Classic data, or show as "Item 12345" until Blizzard adds them.
- On the PC, data lives in `flips.db` next to the app. Delete it to start over.

## Files

| File | What it does |
|---|---|
| `blizzard.py` | Battle.net API client |
| `collector.py` | Fetches snapshots, builds price history and sales estimates |
| `export.py` | Turns the database into the JSON files the page reads |
| `static/index.html`, `static/flips.js` | The page, and the flip maths (runs in the browser) |
| `cloud.py`, `.github/workflows/collect.yml` | The hourly GitHub job |
| `app.py` | Local web server with hourly fetch |
| `config.py`, `storage.py`, `demo.py` | Settings, database, demo data |

## In-game addon: Flip Finder

A private flipping addon for WoW: Forever, in `addon/FlipFinder`. It uses **TradeSkillMaster's** price and
sales data (keep TSM and its desktop app running), so it needs no other setup.

- **Install / update:** double-click `install-addon.bat`, then `/reload` in game.
- **Tooltips:** realm value, lowest buyout, region value, region sold value, daily sold and sell chance.
- **Sniper** (opens next to the auction house, or `/ff`): pick a group (reagents & materials, consumables,
  recipes, gear, …) and press **Scan**. It finds listings below *Max % of value* that pass the sales filter
  (daily sold or sell chance), then checks each one's full price list for a **resell gap**: the cheap listings
  must be followed by a price jump of at least *Resell gap %*, or there's nothing to resell into.
  *Keep scanning* repeats the scan.
- **Buying is always your click:** commodities are *Buy* then *Confirm* (the game shows the real total first);
  single auctions are one click to refresh, then one click per auction. Bought items go to your mailbox.
- **Settings:** max % of value, daily sold / sell chance, max quantity, resell gap, price tolerance, min ROI,
  min quantity (bait filter), min quality, min profit, max spend, fast sellers first.
- **Post:** *Scan bags* prices everything worth selling against the competition: undercut the cheapest by
  your undercut amount, never below *Min % of value* or a vendor's price, never above *Max % of value*, and at
  *Normal %* when nobody else sells it. Then **Post next** posts one item per click (Blizzard requires a click
  per post). *Only items I flipped* limits it to things you bought with Flip Finder.
- **Cancel scan:** *Scan my auctions* checks each of your auctions against the competition and lists the
  undercut ones (or says to keep it up if the competitor is below your minimum). **Cancel next** cancels one
  per click; the items go to your mailbox, ready to post again.
- **Earnings:** what you've spent on flips and earned from sales, per day (green and red bars) with a gold
  line for your running profit; 7 days / 30 days / all time, optionally only items you flipped. Purchases are
  recorded when you buy through Flip Finder; sales are read from Blizzard's "Auction successful" mails when
  you open your mailbox (read only: the addon never takes mail or money).
- **Vendor Sniper:** listings priced below what a vendor pays (by at least *Min margin %*). Buy them and sell to any
  vendor: guaranteed profit, no reselling. Uses the game's own vendor prices, so it works without TSM.
- **Earnings, By item:** for every item you flipped: units bought and sold, average cost, spent, earned and profit on
  the units that sold. Sales are matched to purchases by item name.
- **Lists:** your own groups of items ("My herbs", "Recipes that sell"). Add items by clicking the box and
  shift-clicking items, dragging them onto it, or typing an item ID. Every sniper's *Scan scope* offers your lists:
  only those items are checked, so the scan is fast and has no noise.
- **Crafting:** open each profession window once and Flip Finder reads your learned recipes (per character). The
  Crafting page shows reagent cost (TSM market value or lowest buyout, or a vendor's price when cheaper), what the
  result sells for after the AH cut, profit, ROI, daily sold and sell chance. *Reagents to list* puts a recipe's
  reagents on the "Crafting reagents" list so you can snipe them cheaply.
- **Collect auction mail:** a button next to the mailbox. One click takes the gold and items from auction mail
  (sales, purchases, expired and cancelled auctions) one at a time, like Blizzard's own "Open All". It never
  touches COD mail, stops when your bags are full, and records sales for Earnings before taking them.
- **Deals list:** click a column header to sort (again to reverse), type in *Filter items* to narrow it down, and
  click a row to see the exact listings you'd buy and what comes after them. Columns include sell chance, days to
  resell at the current pace, and the price gap (with a small bar). *Alerts* plays a sound and flashes new deals
  (and the taskbar icon when WoW is in the background).
- **Window:** drag the bottom-right corner to resize; the size is remembered.
- **Keep scanning** keeps deals on the list between rounds; a deal only disappears when it's gone or no longer cheap.
- `/ff tooltip` turns the tooltip lines on/off, `/ff debug` + shift-click an item shows TSM's raw values,
  `/ff log` shows recent activity.
