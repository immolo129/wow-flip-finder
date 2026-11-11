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
4. **Add your keys as secrets.** On the repo's GitHub page go to **Settings →
   Secrets and variables → Actions → New repository secret** and add:
   - `BLIZZARD_CLIENT_ID`
   - `BLIZZARD_CLIENT_SECRET`

   Secrets are encrypted and never visible, not even in a public repo.
   *Optional:* on the **Variables** tab, add `REGION`, `RULESET` or `FACTION`
   to change the defaults (eu, 1, horde).
5. **Turn on Pages.** Go to **Settings → Pages → Source** and pick **GitHub Actions**.
6. **First run.** Go to the **Actions** tab, enable workflows if GitHub asks,
   click **Collect auction data → Run workflow**, and wait about 2 minutes.
   Your page is at `https://<your-username>.github.io/<repo-name>/`
   (also shown under Settings → Pages).

After that it runs by itself every hour. Good to know:

- Anyone with the link can see the page (it's public, but nobody will find it unless you share it).
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

## The three tabs

| Tab | What it finds | Risk |
|---|---|---|
| Underpriced (reset) | Listings far below the item's 7-day market price in the same house | Price can keep falling; check the chart |
| Between auction houses | Cheaper in Horde, dearer in Blackwater (or the other way) | Blackwater takes 15 % instead of 5 % (already counted) |
| Below vendor price | Listings cheaper than what a vendor pays | None, if it's still there |

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
