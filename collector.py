"""Fetches auction snapshots and turns them into price history."""
import hashlib
import logging
import math
import statistics
import time
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor

log = logging.getLogger("collector")

# An auction that disappears between two snapshots was either bought, cancelled or expired.
# Auctions that had LONG (2-12 h) or VERY_LONG time left can't expire within one gap, so
# those count as sold. Cancellations still count too, so treat sales as an estimate.
SAFE_TIME_LEFT = {"LONG", "VERY_LONG"}
MAX_GAP = int(2.5 * 3600)   # longer gaps between snapshots can't tell sales from expiries


def is_neutral(name):
    n = (name or "").lower()
    return 0 if ("alliance" in n or "horde" in n) else 1


# ---------- parsing ----------
def extract_listings(auctions):
    """-> list of (auction_id, item_id, unit_price_copper, quantity, time_left). Bid-only auctions are skipped."""
    out = []
    for a in auctions or []:
        item = a.get("item") or {}
        iid = item.get("id")
        if not iid:
            continue
        qty = int(a.get("quantity") or 1)
        if a.get("unit_price"):
            up = int(a["unit_price"])
        elif a.get("buyout"):
            up = int(math.ceil(a["buyout"] / qty))
        else:
            continue
        if up <= 0:
            continue
        out.append((a.get("id"), iid, up, qty, a.get("time_left")))
    return out


def fingerprint(rows):
    h = hashlib.sha1()
    for r in sorted(map(repr, rows)):
        h.update(r.encode())
    return h.hexdigest()


def summarize(ladder):
    """ladder: list of (unit_price, quantity), any order. Returns stats dict."""
    ladder = sorted(ladder)
    total = sum(q for _, q in ladder)
    half = total / 2
    cum = 0
    median = ladder[-1][0]
    for p, q in ladder:
        cum += q
        if cum >= half:
            median = p
            break
    # market = weighted mean of the cheapest 25 % of units (TSM-style)
    want = max(1, math.ceil(total * 0.25))
    took = 0
    acc = 0
    for p, q in ladder:
        take = min(q, want - took)
        acc += p * take
        took += take
        if took >= want:
            break
    return {
        "min_price": ladder[0][0],
        "market": int(round(acc / took)),
        "median": median,
        "quantity": total,
        "listings": len(ladder),
    }


# ---------- sales ----------
def estimate_sales(db, ruleset, house_id, auctions):
    """Compare with the previous snapshot's auctions.
    -> {item_id: (units sold, all units that left)}, or None if it can't tell.
    'Sold' counts only auctions that vanished while they still had hours left, so it's a low estimate;
    'left' also counts the ones that may have expired. sold / left is the sell rate."""
    if not any(tl for *_, tl in auctions):
        return None  # no time_left in the data: can't separate sales from expiries
    prev = db.query("SELECT auction_id, item_id, quantity, time_left FROM prev_auctions WHERE ruleset=? AND house_id=?",
                    (ruleset, house_id))
    if not prev:
        return None
    now = {aid: qty for aid, _, qty, _ in auctions if aid is not None}
    sold, gone = defaultdict(int), defaultdict(int)
    for p in prev:
        q = now.get(p["auction_id"])
        if q is None:
            gone[p["item_id"]] += p["quantity"]
            if p["time_left"] in SAFE_TIME_LEFT:
                sold[p["item_id"]] += p["quantity"]
        elif q < p["quantity"]:  # part of a commodity stack was bought
            sold[p["item_id"]] += p["quantity"] - q
            gone[p["item_id"]] += p["quantity"] - q
    return {i: (sold.get(i, 0), gone[i]) for i in gone}


# ---------- storing ----------
def store_snapshot(db, ruleset, house_id, listings, ts=None, auctions=None, sales=None, fp=None):
    """listings: list of (item_id, unit_price, quantity), one entry per auction.
    auctions: optional (auction_id, item_id, quantity, time_left) per auction, used to estimate sales.
    sales:    optional {item_id: (units sold, units that left)} since the previous snapshot, if already known (demo).
    fp:       fingerprint of the data; if it matches the house's last snapshot nothing is stored.
    Returns the snapshot id, or None when the data hasn't changed."""
    ts = int(ts or time.time())
    by_item = defaultdict(list)
    for iid, up, qty in listings:
        by_item[iid].append((up, qty))

    with db.transaction():
        prev = db.one("SELECT ts, fingerprint FROM snapshots WHERE ruleset=? AND house_id=? ORDER BY ts DESC LIMIT 1",
                      (ruleset, house_id))
        if fp and prev and prev["fingerprint"] == fp:
            return None
        gap = ts - prev["ts"] if prev else None
        if gap is not None and not 0 < gap <= MAX_GAP:
            gap = None
        if sales is None and auctions is not None and gap:
            sales = estimate_sales(db, ruleset, house_id, auctions)
        if sales is None:
            gap = None  # gap marks a snapshot whose sales were tracked

        cur = db.execute(
            "INSERT INTO snapshots (ts, ruleset, house_id, n_listings, fingerprint, gap) VALUES (?,?,?,?,?,?)",
            (ts, ruleset, house_id, len(listings), fp, gap),
        )
        sid = cur.lastrowid

        stat_rows, ladder_rows = [], []
        for iid, ladder in by_item.items():
            s = summarize(ladder)
            stat_rows.append((sid, iid, s["min_price"], s["market"], s["median"], s["quantity"], s["listings"]))
            # collapse identical prices on the ladder
            grouped = defaultdict(lambda: [0, 0])
            for up, qty in ladder:
                grouped[up][0] += qty
                grouped[up][1] += 1
            for up, (qty, n) in grouped.items():
                ladder_rows.append((ruleset, house_id, iid, up, qty, n))

        db.executemany("INSERT OR REPLACE INTO item_stats VALUES (?,?,?,?,?,?,?)", stat_rows)
        db.execute("DELETE FROM latest_listings WHERE ruleset=? AND house_id=?", (ruleset, house_id))
        db.executemany("INSERT INTO latest_listings VALUES (?,?,?,?,?,?)", ladder_rows)
        if sales:
            db.executemany("INSERT INTO sales (snapshot_id, item_id, sold, gone) VALUES (?,?,?,?)",
                           [(sid, i, sg[0], sg[1]) for i, sg in sales.items() if sg[0] > 0 or sg[1] > 0])
        if auctions is not None:
            db.execute("DELETE FROM prev_auctions WHERE ruleset=? AND house_id=?", (ruleset, house_id))
            db.executemany("INSERT INTO prev_auctions VALUES (?,?,?,?,?,?)",
                           [(ruleset, house_id, aid, iid, qty, tl) for aid, iid, qty, tl in auctions if aid is not None])
    return sid


MIN_GONE_FOR_RATE = 5   # units that must have left before a sell rate is shown


def _change(points, back, slack):
    """points: [(ts, value)] sorted. -> fractional change from ~`back` seconds before the last point, or None."""
    if len(points) < 2:
        return None
    t_last, v_last = points[-1]
    t0, v0 = min(points, key=lambda p: abs(p[0] - (t_last - back)))
    if abs(t0 - (t_last - back)) > slack or not v0 or t0 == t_last:
        return None
    return (v_last - v0) / v0


def recompute_market(db, ruleset, window_days=7, now=None):
    now = int(now or time.time())
    since = now - window_days * 86400
    rows = db.query(
        """SELECT s.house_id, st.item_id, s.ts, st.market, st.listings, st.quantity
           FROM item_stats st JOIN snapshots s ON s.id = st.snapshot_id
           WHERE s.ruleset = ? AND s.ts >= ? ORDER BY s.ts""",
        (ruleset, since),
    )
    tracked = {r["house_id"]: r["secs"] for r in db.query(
        "SELECT house_id, SUM(gap) AS secs FROM snapshots WHERE ruleset=? AND ts>=? AND gap IS NOT NULL GROUP BY house_id",
        (ruleset, since))}
    sales = {(r["house_id"], r["item_id"]): (r["sold"] or 0, r["gone"]) for r in db.query(
        """SELECT s.house_id, sa.item_id, SUM(sa.sold) AS sold, SUM(sa.gone) AS gone
           FROM sales sa JOIN snapshots s ON s.id = sa.snapshot_id
           WHERE s.ruleset=? AND s.ts>=? GROUP BY s.house_id, sa.item_id""",
        (ruleset, since))}

    acc = defaultdict(lambda: ([], [], []))
    for r in rows:
        pts, l, q = acc[(r["house_id"], r["item_id"])]
        pts.append((r["ts"], r["market"]))
        l.append(r["listings"])
        q.append(r["quantity"])
    out = []
    for (hid, iid), (pts, l, q) in acc.items():
        m = [v for _, v in pts]
        secs = tracked.get(hid) or 0
        sold, gone = sales.get((hid, iid), (0, None))
        per_day = sold / secs * 86400 if secs else None
        rate = min(1.0, sold / gone) if gone and gone >= MIN_GONE_FOR_RATE else None
        span = pts[-1][0] - pts[0][0]
        chg7 = (pts[-1][1] - pts[0][1]) / pts[0][1] if span >= 4 * 86400 and pts[0][1] else None
        out.append((ruleset, hid, iid, int(statistics.median(m)), len(m), sum(l) / len(l), sum(q) / len(q),
                    per_day, secs / 3600, rate, min(m), int(sum(m) / len(m)), max(m),
                    _change(pts, 86400, 3 * 3600), chg7))
    with db.transaction():
        db.execute("DELETE FROM market WHERE ruleset=?", (ruleset,))
        db.executemany(
            """INSERT INTO market (ruleset, house_id, item_id, market, seen, avg_listings, avg_quantity,
                                   sold_per_day, tracked_h, sell_rate, low7, avg7, high7, chg24, chg7)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""", out)


# ---------- region prices ----------
def store_region(db, per_house, ts=None):
    """per_house: {(ruleset, house): {item_id: [(unit_price, quantity), ...]}} for every house of every ruleset.
    Stores one row per item: the median of the houses' market values."""
    ts = int(ts or time.time())
    markets, qty = defaultdict(list), defaultdict(int)
    for items in per_house.values():
        for iid, ladder in items.items():
            s = summarize(ladder)
            markets[iid].append(s["market"])
            qty[iid] += s["quantity"]
    db.executemany("INSERT INTO region_stats VALUES (?,?,?,?,?)",
                   [(ts, iid, int(statistics.median(v)), qty[iid], len(v)) for iid, v in markets.items()])


def recompute_region(db, window_days=7, now=None):
    now = int(now or time.time())
    rows = db.query("SELECT ts, item_id, market, houses FROM region_stats WHERE ts >= ? ORDER BY ts",
                    (now - window_days * 86400,))
    acc = defaultdict(list)
    for r in rows:
        acc[r["item_id"]].append(r)
    with db.transaction():
        db.execute("DELETE FROM region_market")
        db.executemany("INSERT INTO region_market VALUES (?,?,?,?)",
                       [(iid, int(statistics.median(x["market"] for x in v)), v[-1]["market"], v[-1]["houses"])
                        for iid, v in acc.items()])


def prune(db, keep_days=21):
    cutoff = int(time.time()) - keep_days * 86400
    with db.transaction():
        db.execute("DELETE FROM item_stats WHERE snapshot_id IN (SELECT id FROM snapshots WHERE ts < ?)", (cutoff,))
        db.execute("DELETE FROM sales WHERE snapshot_id IN (SELECT id FROM snapshots WHERE ts < ?)", (cutoff,))
        db.execute("DELETE FROM snapshots WHERE ts < ?", (cutoff,))
        db.execute("DELETE FROM region_stats WHERE ts < ?", (cutoff,))


# ---------- item names ----------
def fetch_missing_items(db, api, max_items=3000):
    missing = db.query(
        """SELECT DISTINCT l.item_id FROM latest_listings l
           LEFT JOIN items i ON i.item_id = l.item_id
           WHERE i.item_id IS NULL OR (i.found = 0 AND i.fetched_ts < ?) LIMIT ?""",
        (int(time.time()) - 86400, max_items),  # retry unknown items once a day
    )
    ids = [r["item_id"] for r in missing]
    if not ids:
        return 0

    def one(iid):
        try:
            d = api.item(iid)
        except Exception as e:  # keep going on single failures
            log.warning("item %s: %s", iid, e)
            d = None
        if d:
            q = d.get("quality") or {}
            return (iid, d.get("name") or f"Item {iid}", q.get("type") or q.get("name"), d.get("sell_price") or 0, 1, int(time.time()))
        return (iid, f"Item {iid}", None, 0, 0, int(time.time()))

    with ThreadPoolExecutor(max_workers=8) as ex:
        rows = list(ex.map(one, ids))
    # upsert, so the icon and vendor price columns survive a re-fetch
    db.executemany("""INSERT INTO items (item_id, name, quality, sell_price, found, fetched_ts) VALUES (?,?,?,?,?,?)
                      ON CONFLICT(item_id) DO UPDATE SET
                        name=CASE WHEN excluded.found=1 OR items.name IS NULL THEN excluded.name ELSE items.name END,
                        quality=excluded.quality,
                        sell_price=excluded.sell_price, found=excluded.found, fetched_ts=excluded.fetched_ts""", rows)
    return len(rows)


def fetch_missing_icons(db, api, max_items=3000):
    """Look up icons for items that don't have one yet (listed and recipe items first); retry missing ones weekly."""
    now = int(time.time())
    ids = [r["item_id"] for r in db.query(
        """SELECT item_id FROM items
           WHERE (icon IS NULL OR (icon = '' AND icon_ts < ?))
           ORDER BY item_id IN (SELECT item_id FROM latest_listings UNION SELECT crafted_item FROM recipes
                                UNION SELECT item_id FROM recipe_reagents) DESC
           LIMIT ?""",
        (now - 7 * 86400, max_items))]
    if not ids:
        return 0

    def one(iid):
        try:
            icon = api.item_icon(iid)
        except Exception as e:  # keep going on single failures
            log.warning("icon %s: %s", iid, e)
            icon = None
        return (icon or "", now, iid)

    with ThreadPoolExecutor(max_workers=8) as ex:
        rows = list(ex.map(one, ids))
    db.executemany("UPDATE items SET icon=?, icon_ts=? WHERE item_id=?", rows)
    return sum(1 for icon, _, _ in rows if icon)


# ---------- full item list (for searching every item) ----------
INDEX_REFRESH_DAYS = 7


def _name(v):
    """Item search returns names per language ({"en_GB": ...}) unless one locale is asked for."""
    if isinstance(v, dict):
        return v.get("en_GB") or v.get("en_US") or next(iter(v.values()), None)
    return v


INDEX_NOTE = ""  # what the last item-list fetch did, for the run summary


def fetch_item_index(db, api, force=False, max_pages=200):
    """Every item in the item database (name, quality, vendor price), weekly. Tries Forever's own item
    search, then Classic Era's (Forever is built on it). -> items stored"""
    global INDEX_NOTE
    now = int(time.time())
    last = db.one("SELECT value FROM meta WHERE key='items_index_v2_ts'")
    if not force and last and now - int(last["value"]) < INDEX_REFRESH_DAYS * 86400:
        INDEX_NOTE = "item list up to date"
        return 0
    rows, notes = {}, []
    for ns in ("static-forever", "static-classic1x"):
        got, page = 0, 1
        try:
            while page <= max_pages:
                d = api.search_items(page, ns)
                if not d:
                    notes.append(f"{ns}: not found" if page == 1 else f"{ns}: stopped at page {page}")
                    break
                for res in d.get("results") or []:
                    it = res.get("data") or {}
                    name = _name(it.get("name"))
                    if not it.get("id") or not name or it["id"] in rows:
                        continue
                    q = it.get("quality") or {}
                    rows[it["id"]] = (it["id"], name, q.get("type") if isinstance(q, dict) else None, it.get("sell_price") or 0, now)
                    got += 1
                if page >= (d.get("pageCount") or 1):
                    break
                page += 1
        except Exception as e:
            notes.append(f"{ns}: {str(e)[:80]}")
        if got:
            notes.append(f"{ns}: {got} items")
    INDEX_NOTE = "item list: " + "; ".join(notes)
    if not rows:
        log.warning("Item search returned nothing (%s); searching covers known items only", "; ".join(notes))
        return 0
    # upsert: keeps icons and vendor prices; names from the search count as found items
    db.executemany("""INSERT INTO items (item_id, name, quality, sell_price, found, fetched_ts) VALUES (?,?,?,?,1,?)
                      ON CONFLICT(item_id) DO UPDATE SET name=excluded.name,
                        quality=COALESCE(excluded.quality, items.quality), sell_price=excluded.sell_price, found=1""",
                   list(rows.values()))
    db.execute("INSERT OR REPLACE INTO meta VALUES ('items_index_v2_ts', ?)", (str(now),))
    return len(rows)


# ---------- crafting ----------
RECIPE_REFRESH_DAYS = 7

# Reagents that vendors sell. Blizzard's item data has a buy price for every item but doesn't say
# whether any vendor actually sells it, so only these are priced at the vendor.
VENDOR_REAGENTS = {
    3371, 3372, 8925, 18256,                     # vials: empty, leaded, crystal, imbued
    2320, 2321, 4291, 8343, 14341,               # thread: coarse, fine, silken, heavy silken, rune
    2324, 2325, 2604, 2605, 4340, 4341, 4342, 6260, 6261, 10290,   # bleach and dyes
    2880, 3466, 3857,                            # weak flux, strong flux, coal
    2678, 2692, 3713, 159, 1179,                 # spices, spring water, milk
    4399, 4400, 4470,                            # wooden stock, heavy stock, simple wood
    6217,                                        # copper rod
}


def fetch_recipes(db, api, force=False):
    """Fetch every Forever recipe (what it makes, from what). Weekly; recipes rarely change."""
    now = int(time.time())
    last = db.one("SELECT value FROM meta WHERE key='recipes_ts'")
    if not force and last and now - int(last["value"]) < RECIPE_REFRESH_DAYS * 86400:
        return 0
    ns = "static-forever"
    todo = []  # (recipe id, profession, category)
    for p in (api.get("/data/wow/profession/index", ns) or {}).get("professions") or []:
        prof = api.get(f"/data/wow/profession/{p['id']}", ns) or {}
        for t in prof.get("skill_tiers") or []:
            tier = api.get(f"/data/wow/profession/{p['id']}/skill-tier/{t['id']}", ns) or {}
            for c in tier.get("categories") or []:
                for r in c.get("recipes") or []:
                    todo.append((r["id"], prof.get("name") or p.get("name"), c.get("name")))
    if not todo:
        log.warning("No recipes returned; keeping the old ones")
        return 0

    def one(job):
        rid, prof, cat = job
        try:
            d = api.get(f"/data/wow/recipe/{rid}", ns)
        except Exception as e:
            log.warning("recipe %s: %s", rid, e)
            return None
        made = d and (d.get("crafted_item") or d.get("horde_crafted_item") or d.get("alliance_crafted_item"))
        if not made:
            return None  # enchants on gear etc. make nothing that can be sold
        q = d.get("crafted_quantity") or {}
        qty = q.get("value") or (q.get("minimum", 1) + q.get("maximum", 1)) / 2 or 1
        reagents = [(r["reagent"]["id"], r["reagent"].get("name"), r.get("quantity") or 1)
                    for r in d.get("reagents") or [] if (r.get("reagent") or {}).get("id")]
        return rid, d.get("name"), prof, cat, made["id"], made.get("name"), qty, reagents

    with ThreadPoolExecutor(max_workers=8) as ex:
        got = [g for g in ex.map(one, todo) if g]
    with db.transaction():
        db.execute("DELETE FROM recipes")
        db.execute("DELETE FROM recipe_reagents")
        db.executemany("INSERT OR REPLACE INTO recipes VALUES (?,?,?,?,?,?)",
                       [(rid, name, prof, cat, made, qty) for rid, name, prof, cat, made, _, qty, _ in got])
        db.executemany("INSERT INTO recipe_reagents VALUES (?,?,?)",
                       [(g[0], iid, n) for g in got for iid, _, n in g[7]])
        # names for items we haven't seen on the auction house yet (found=0: details fetched later if listed)
        names = {g[4]: g[5] for g in got}
        names.update({iid: nm for g in got for iid, nm, _ in g[7]})
        db.executemany("INSERT OR IGNORE INTO items (item_id, name, found, fetched_ts) VALUES (?,?,0,0)",
                       [(i, n or f"Item {i}") for i, n in names.items()])
        db.execute("INSERT OR REPLACE INTO meta VALUES ('recipes_ts', ?)", (str(now),))
    return len(got)


def fetch_vendor_prices(db, api):
    """Vendor buy prices for the known vendor reagents that recipes use."""
    ids = [r["item_id"] for r in db.query(
        "SELECT DISTINCT item_id FROM recipe_reagents WHERE item_id IN (%s)" % ",".join(map(str, VENDOR_REAGENTS)))]
    have = {r["item_id"] for r in db.query("SELECT item_id FROM items WHERE vendor_buy IS NOT NULL")}
    rows = []
    for iid in ids:
        if iid in have:
            continue
        try:
            d = api.item(iid) or {}
        except Exception as e:
            log.warning("vendor price %s: %s", iid, e)
            continue
        if d.get("purchase_price"):
            rows.append((int(d["purchase_price"] / max(1, d.get("purchase_quantity") or 1)), iid))
    db.executemany("UPDATE items SET vendor_buy=? WHERE item_id=?", rows)
    return len(rows)


# ---------- one full run ----------
def fetch_house(api, ruleset, hid):
    """All buyout listings of one auction house. -> [(auction_id, item_id, unit_price, quantity, time_left)]"""
    data = api.house(ruleset, hid) or {}
    seen_ids, parsed = set(), []

    def add(auctions):
        for row in extract_listings(auctions):
            aid = row[0]
            if aid is not None:
                if aid in seen_ids:
                    continue
                seen_ids.add(aid)
            parsed.append(row)

    got_commodities = False
    for key in ("auctions", "commodities"):
        v = data.get(key)
        if isinstance(v, list):
            add(v)
            got_commodities |= key == "commodities"
        elif isinstance(v, dict) and v.get("href"):
            sub = api.get(v["href"], "dynamic-forever") or {}
            add(sub.get("auctions"))
            got_commodities |= key == "commodities"
    if not got_commodities:
        sub = api.commodities(ruleset, hid) or {}
        add(sub.get("auctions"))
    return parsed


def collect_house(db, api, ruleset, hid):
    """Fetch and store one auction house. -> (listings, stored?, parsed listings)"""
    parsed = fetch_house(api, ruleset, hid)
    if not parsed:
        return 0, False, parsed
    sid = store_snapshot(
        db, ruleset, hid,
        listings=[(iid, up, qty) for _, iid, up, qty, _ in parsed],
        auctions=[(aid, iid, qty, tl) for aid, iid, _, qty, tl in parsed],
        fp=fingerprint(parsed),
    )
    return len(parsed), sid is not None, parsed


def _ladders(parsed):
    out = defaultdict(list)
    for _, iid, up, qty, _ in parsed:
        out[iid].append((up, qty))
    return out


def ruleset_ids(api):
    """Every Forever ruleset (PvP, Normal, RP, RP-PvP). Falls back to the known ids."""
    try:
        idx = api.rulesets() or {}
    except Exception as e:
        log.warning("ruleset index: %s", e)
        idx = {}
    for key in ("rulesets", "ruleset", "results"):
        found = [r.get("id") for r in idx.get(key) or [] if isinstance(r, dict) and r.get("id")]
        if found:
            return found
    return [1, 2, 3, 15]


def collect_region(db, api, own_ruleset, own):
    """Region prices: this run's own houses plus every house of the other rulesets.
    Only one median price per item is stored, not the other rulesets' listings.
    own: {house_id: parsed listings} from this run. -> (houses used, problems)"""
    per_house = {(own_ruleset, hid): _ladders(p) for hid, p in own.items() if p}
    problems = []
    for rs in ruleset_ids(api):
        if rs == own_ruleset:
            continue
        try:
            houses = (api.auction_houses(rs) or {}).get("auctions") or []
        except Exception as e:
            problems.append(f"ruleset {rs}: {e}")
            continue
        for h in houses:
            try:
                per_house[(rs, h["id"])] = _ladders(fetch_house(api, rs, h["id"]))
            except Exception as e:
                problems.append(f"ruleset {rs} house {h.get('id')}: {e}")
    if per_house:
        store_region(db, per_house)
        recompute_region(db)
    return len(per_house), problems


def collect(db, api, ruleset, keep_days=21, region=True):
    """One full run. -> (summary message, list of per-house errors). Raises only if every house failed."""
    t0 = time.time()
    idx = api.auction_houses(ruleset)
    houses = idx.get("auctions") or []
    if not houses:
        raise RuntimeError(f"No auction houses returned for ruleset {ruleset}")

    total, unchanged, errors, own = 0, [], [], {}
    for h in houses:
        hid, name = h.get("id"), h.get("name") or f"House {h.get('id')}"
        if isinstance(name, dict):  # localized names come back as {en_GB: ...} without a locale
            name = next(iter(name.values()), f"House {hid}")
        try:
            db.execute("INSERT OR REPLACE INTO houses VALUES (?,?,?,?)", (ruleset, hid, name, is_neutral(name)))
            n, stored, own[hid] = collect_house(db, api, ruleset, hid)
        except Exception as e:
            log.exception("%s failed", name)
            errors.append(f"{name}: {e}")
            continue
        total += n
        if n and not stored:
            unchanged.append(name)
        log.info("%s: %d listings%s", name, n, "" if stored else " (unchanged since last fetch, not stored)")

    if len(errors) == len(houses):
        raise RuntimeError("; ".join(errors))

    recompute_market(db, ruleset)
    region_msg = ""
    if region:  # extra, like crafting: problems here are logged but don't fail the run
        try:
            n_region, problems = collect_region(db, api, ruleset, own)
            region_msg = f", region prices from {n_region} houses"
            if problems:
                log.warning("Region prices incomplete: %s", "; ".join(problems[:5]))
                region_msg += f" ({len(problems)} problems)"
        except Exception:
            log.exception("Region prices failed")
            region_msg = ", region prices failed"
    own.clear()
    try:  # crafting data is extra: a failure here mustn't lose the auction snapshot
        n_recipes = fetch_recipes(db, api)
    except Exception as e:
        log.exception("Fetching recipes failed")
        n_recipes, errors = 0, errors + [f"recipes: {e}"]
    try:  # the full item list for searching is extra too
        n_index = fetch_item_index(db, api)
    except Exception:
        log.exception("Item search failed")
        n_index = 0
    n_items = fetch_missing_items(db, api)
    fetch_vendor_prices(db, api)
    n_icons = fetch_missing_icons(db, api)
    prune(db, keep_days)
    msg = f"{len(houses)} houses, {total} listings, {n_items} new item names, {n_icons} new icons{region_msg}, {time.time() - t0:.0f}s"
    if n_recipes:
        msg += f", {n_recipes} recipes refreshed"
    if n_index:
        msg += f", item list refreshed ({n_index} items)"
    if unchanged:
        msg += f"; unchanged: {', '.join(unchanged)}"
    if errors:
        msg += f"; failed: {'; '.join(errors)}"
    db.execute("INSERT INTO runs (ts, ok, message) VALUES (?,?,?)", (int(time.time()), 0 if errors else 1, msg))
    return msg, errors
