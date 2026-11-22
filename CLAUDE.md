# CLAUDE.md

Forever Flip Finder fetches WoW: Forever auction house data from the Blizzard API every hour, stores price history in SQLite (`flips.db`), and shows gold-making flips in a single-page browser UI. See README.md for the user-facing description.

It runs two ways, sharing all code except the entry point:
- **GitHub (main way):** `.github/workflows/collect.yml` runs `cloud.py` hourly, which collects and writes a static site (`export.write_site`) that is published to GitHub Pages. `flips.db` is kept gzipped as an asset on a release named `data`, not in git.
  The repo and Pages are public, so everything published is encrypted with the `SITE_PASSWORD` secret: the JSON files (AES-256-GCM, PBKDF2 key, see `export.make_encryptor`; decrypted in the browser by `unlock()` in `index.html`) and the release asset `flips.db.gz.enc` (openssl in the workflow). `cloud.py --require-password` refuses to publish without it. Never publish data unencrypted.
- **Local:** `app.py` (Flask) collects hourly and serves the same page, building the same JSON on the fly.

The flip maths runs in the browser (`static/flips.js`) on `data/latest.json`, so both ways compute flips identically.

## Who uses it
The owner is a player, not a developer. They start the app by double-clicking `start.bat` or `demo.bat` on Windows. Keep that working. Don't add build steps, extra services or setup that needs a terminal.

README.md is written for that user in plain language. Update it whenever settings, tabs or behaviour change.

## Running and checking changes
There are no tests. To check a change, run demo mode, which needs no API keys and builds fake data into `demo.db`:

```powershell
.venv\Scripts\python app.py --demo     # http://127.0.0.1:5000
.venv\Scripts\python cloud.py --demo --db demo_site.db --out site   # the static GitHub site, with fake data
```

- Real mode is `.venv\Scripts\python app.py`. It needs `BLIZZARD_CLIENT_ID` and `BLIZZARD_CLIENT_SECRET` in `.env`.
- Never print, log or copy the contents of `.env`.
- The shell is Windows PowerShell 5.1.
- The folder is not a git repo, so there is no undo. Check before you delete or overwrite files.

## Files
| File | What it does |
|---|---|
| `app.py` | Local Flask server: serves `static/`, `data/latest.json`, `data/history/<n>.json`, `api/collect`; the hourly background loop |
| `cloud.py` | GitHub Actions entry point: collect, then write the static site to `site/` (`--demo` builds one with fake data) |
| `.github/workflows/collect.yml` | Hourly job: download db from the `data` release, run `cloud.py`, upload db, deploy Pages, keep-alive commit |
| `config.py` | Settings from `.env` or environment variables |
| `export.py` | Database → JSON for the page: `latest()` (status, houses, items, markets, price ladders) and history split into 64 shards by `item_id % 64` |
| `blizzard.py` | Battle.net API client: OAuth, retries, Forever endpoints |
| `collector.py` | Parses auctions, stores snapshots, estimates sales, recomputes the 7-day market, prunes data, fetches item names |
| `storage.py` | SQLite schema, migrations, and the thread-safe `DB` wrapper |
| `demo.py` | Fake houses, items and snapshots for demo mode |
| `static/flips.js` | The flip strategies (`reset`, `arbitrage`, `vendor`) and crafting profits (`craft`) |
| `static/index.html` | The whole UI: one file, plain JS, no framework, no build step |

## Things that aren't obvious from the code
- **Units.** All prices in the database, JSON and `flips.js` are integer copper per unit (1 g = 10 000 c). The page's filter boxes are in gold and whole percentages; `toCalc()` in `index.html` converts them to copper and fractions before calling `flips.js`.
- **AH cut.** Faction houses take 5 % and the neutral Blackwater house takes 15 % (`FACTION_CUT`/`NEUTRAL_CUT` in `flips.js`). Profit figures already include the cut.
- **Static site paths.** The page is served from a GitHub Pages subpath (`/<repo>/`), so `index.html` must use relative URLs (`data/latest.json`, not `/data/latest.json`).
- **Sales and region stats.** `sales.gone` counts every unit that left; `sold` only the ones that surely sold, so `sell_rate = sold / gone` (shown once 12 h are tracked and at least `MIN_GONE_FOR_RATE` units left). Region prices: each run also fetches every other ruleset's houses (`collect_region`) but stores only one median per item in `region_stats`; `region_market` holds the window median. Region problems are logged, never fail the run.
- **Accuracy rules.** `summarize` ignores listings outside `BAIT_LOW`..`BAIT_HIGH` x the median for the market value (min_price stays raw). `estimate_sales` treats an auction that vanished while a cheaper one of the same item stayed listed as cancelled (not sold, not gone); needs `prev_auctions.unit_price`. Snapshots use Blizzard's `Last-Modified` (`api.last_modified`) when it's within 6 h of now. Crafting reagents are priced by walking the current ladders (`reagentCost` in flips.js) for `crafts` crafts. `expectedProfit` in index.html = profit - units x deposit x (1-s)/s.
- **Recipes.** `collector.fetch_recipes` walks Blizzard's `static-forever` profession index → skill tiers → recipes once a week (`meta.recipes_ts`). Recipes that make no item (gear enchants) are skipped. Vendor-bought reagents are only the ids in `VENDOR_REAGENTS`, because Blizzard's item data has a buy price for every item without saying whether a vendor sells it.
- **Item icons.** `items.icon` holds just the icon file name from Blizzard's item media endpoint (`'' ` = none found, retried weekly via `icon_ts`). The page builds the image URL itself: Blizzard's render server first, Wowhead's CDN as a backup, then a letter square (`itemIcon()` in `index.html`).
- **Global names in `index.html`.** Scripts there are plain globals, so don't name functions after browser globals (`history`, `close`, `open`, `name`, `status`...). A function called `history` silently broke the price chart once.
- **Testing the locked page headless.** Edge's `--virtual-time-budget` doesn't wait for the 600 000-round PBKDF2, so set `export.PBKDF2_ITER` low for browser tests.
- **Database size on GitHub.** `cloud.py` keeps only 8 days (`KEEP_DAYS`) and VACUUMs before upload; the local app keeps 21.
- **The Forever API is undocumented.** It uses the `dynamic-forever-{region}` and `static-forever-{region}` namespaces. The auction house index URL needs its trailing slash. Item lookups fall back to `static-classic1x` because Forever item data is incomplete. Don't "fix" these endpoints without evidence.
- **Schema changes.** `CREATE TABLE IF NOT EXISTS` doesn't change tables in an existing `flips.db`. When you add a column, also add it to `MIGRATIONS` in `storage.py`.
- **Database access.** The app shares one SQLite connection across threads, guarded by an `RLock`. Do multi-statement writes inside `with db.transaction():`, which can be nested. Single `execute` calls commit on their own when they run outside a transaction.
- **Collection runs.** `RUN_LOCK` makes sure the hourly run and "Fetch now" never overlap. A snapshot whose fingerprint matches the previous one for that house is skipped.
- **Sales estimate.** `snapshots.gap` is set only when sales were tracked for that snapshot (gap ≤ 2.5 h and the data has `time_left`). Sells/day is trusted only after 12 tracked hours (`MIN_TRACKED_H`).
- **Faction filter.** A house's faction comes from its name: "horde" or "alliance" in the name, otherwise neutral (`is_neutral` in `collector.py`, `accessible` in `flips.js`).

## Style
- Keep it small and dependency-light. Flask and requests are the only dependencies.
- Use plain functions, short docstrings, and comments that explain *why*.
- Match the existing code style. Don't add type hints, classes or frameworks the code doesn't already use.

## In-game addon (`addon/FlipFinder`)
**Blizzard's rules come first, always.** The owner wants the addon and the website within Blizzard's Terms of Use, addon policy and API terms at all times. Before adding anything, check it against these:
- Every purchase, post, cancel or other action that spends or moves gold or items must come from the player's own click (an `OnClick` handler), one action per click. Never chain them, never trigger them from timers, events or loops, never auto-confirm.
- The one exception to one-action-per-click is the mailbox helper (`Mail.lua`): one click collects auction mail in sequence, exactly like Blizzard's own "Open All" button and the Postal addon. It only takes gold/items from the player's own auction mail, never COD mail, and never buys, posts or cancels.
- Only Blizzard's addon API and TSM's public API. No memory reading, input automation, external programs driving the game, or anything that works around a protected function.
- Be gentle on the servers: one auction-house query at a time, wait for `IsThrottledMessageSystemReady`, stop when the AH closes; "Keep scanning" pauses 5 s between rounds and stops by itself after 30 minutes.
- Addon stays free, private and readable (no obfuscation, ads or payments). Website: respect Blizzard API rate limits and use the data privately.
- If a requested feature would break these rules, say so and offer a compliant alternative instead of building it.

- Lua for the WoW: Forever client (Interface 16001, client 1.60). Forever uses the **modern auction house API** (`C_AuctionHouse`, commodities vs items), like retail; Auctionator's `Source_ModernAH` with its `IsForever` branches is a good reference for quirks (copper prices allowed, 2/8/24 h durations, one AH per ruleset and faction).
- Prices come from TradeSkillMaster's public API (`TSM_API.GetCustomPriceValue("DBMarket", "i:<id>")` etc.), see `Prices.lua`. TSM's desktop app keeps that data fresh.
- Buying, posting and cancelling need a hardware click (protected API). Never automate them; scanning (search queries) is fine.
- WoW is installed at `C:\Program Files (x86)\World of Warcraft\_forever_`. After the user plays, errors are in `WTF/Account/*/SavedVariables/BugSack.lua` and the addon's log in `.../SavedVariables/FlipFinder.lua` (written on logout or /reload).
- Install with `install-addon.bat` (copies to the AddOns folder). No Lua runtime here; `luaparser` (pip) does syntax checks.
