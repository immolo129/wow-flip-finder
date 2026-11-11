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
    """Compare with the previous snapshot's auctions. -> {item_id: units sold}, or None if it can't tell."""
    if not any(tl for *_, tl in auctions):
        return None  # no time_left in the data: can't separate sales from expiries
    prev = db.query("SELECT auction_id, item_id, quantity, time_left FROM prev_auctions WHERE ruleset=? AND house_id=?",
                    (ruleset, house_id))
    if not prev:
        return None
    now = {aid: qty for aid, _, qty, _ in auctions if aid is not None}
    sold = defaultdict(int)
    for p in prev:
        q = now.get(p["auction_id"])
        if q is None:
            if p["time_left"] in SAFE_TIME_LEFT:
                sold[p["item_id"]] += p["quantity"]
        elif q < p["quantity"]:  # part of a commodity stack was bought
            sold[p["item_id"]] += p["quantity"] - q
    return sold


# ---------- storing ----------
def store_snapshot(db, ruleset, house_id, listings, ts=None, auctions=None, sales=None, fp=None):
    """listings: list of (item_id, unit_price, quantity), one entry per auction.
    auctions: optional (auction_id, item_id, quantity, time_left) per auction, used to estimate sales.
    sales:    optional {item_id: units sold since the previous snapshot}, if already known (demo).
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
            db.executemany("INSERT INTO sales VALUES (?,?,?)", [(sid, i, n) for i, n in sales.items() if n > 0])
        if auctions is not None:
            db.execute("DELETE FROM prev_auctions WHERE ruleset=? AND house_id=?", (ruleset, house_id))
            db.executemany("INSERT INTO prev_auctions VALUES (?,?,?,?,?,?)",
                           [(ruleset, house_id, aid, iid, qty, tl) for aid, iid, qty, tl in auctions if aid is not None])
    return sid


def recompute_market(db, ruleset, window_days=7, now=None):
    now = int(now or time.time())
    since = now - window_days * 86400
    rows = db.query(
        """SELECT s.house_id, st.item_id, st.market, st.listings, st.quantity
           FROM item_stats st JOIN snapshots s ON s.id = st.snapshot_id
           WHERE s.ruleset = ? AND s.ts >= ?""",
        (ruleset, since),
    )
    tracked = {r["house_id"]: r["secs"] for r in db.query(
        "SELECT house_id, SUM(gap) AS secs FROM snapshots WHERE ruleset=? AND ts>=? AND gap IS NOT NULL GROUP BY house_id",
        (ruleset, since))}
    sold = {(r["house_id"], r["item_id"]): r["n"] for r in db.query(
        """SELECT s.house_id, sa.item_id, SUM(sa.sold) AS n
           FROM sales sa JOIN snapshots s ON s.id = sa.snapshot_id
           WHERE s.ruleset=? AND s.ts>=? GROUP BY s.house_id, sa.item_id""",
        (ruleset, since))}

    acc = defaultdict(lambda: ([], [], []))
    for r in rows:
        m, l, q = acc[(r["house_id"], r["item_id"])]
        m.append(r["market"])
        l.append(r["listings"])
        q.append(r["quantity"])
    out = []
    for (hid, iid), (m, l, q) in acc.items():
        secs = tracked.get(hid) or 0
        per_day = sold.get((hid, iid), 0) / secs * 86400 if secs else None
        out.append((ruleset, hid, iid, int(statistics.median(m)), len(m), sum(l) / len(l), sum(q) / len(q),
                    per_day, secs / 3600))
    with db.transaction():
        db.execute("DELETE FROM market WHERE ruleset=?", (ruleset,))
        db.executemany(
            """INSERT INTO market (ruleset, house_id, item_id, market, seen, avg_listings, avg_quantity,
                                   sold_per_day, tracked_h) VALUES (?,?,?,?,?,?,?,?,?)""", out)


def prune(db, keep_days=21):
    cutoff = int(time.time()) - keep_days * 86400
    with db.transaction():
        db.execute("DELETE FROM item_stats WHERE snapshot_id IN (SELECT id FROM snapshots WHERE ts < ?)", (cutoff,))
        db.execute("DELETE FROM sales WHERE snapshot_id IN (SELECT id FROM snapshots WHERE ts < ?)", (cutoff,))
        db.execute("DELETE FROM snapshots WHERE ts < ?", (cutoff,))


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
    db.executemany("INSERT OR REPLACE INTO items VALUES (?,?,?,?,?,?)", rows)
    return len(rows)


# ---------- one full run ----------
def collect_house(db, api, ruleset, hid):
    """Fetch and store one auction house. -> (listings, stored?)"""
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

    if not parsed:
        return 0, False
    sid = store_snapshot(
        db, ruleset, hid,
        listings=[(iid, up, qty) for _, iid, up, qty, _ in parsed],
        auctions=[(aid, iid, qty, tl) for aid, iid, _, qty, tl in parsed],
        fp=fingerprint(parsed),
    )
    return len(parsed), sid is not None


def collect(db, api, ruleset, keep_days=21):
    """One full run. -> (summary message, list of per-house errors). Raises only if every house failed."""
    t0 = time.time()
    idx = api.auction_houses(ruleset)
    houses = idx.get("auctions") or []
    if not houses:
        raise RuntimeError(f"No auction houses returned for ruleset {ruleset}")

    total, unchanged, errors = 0, [], []
    for h in houses:
        hid, name = h.get("id"), h.get("name") or f"House {h.get('id')}"
        if isinstance(name, dict):  # localized names come back as {en_GB: ...} without a locale
            name = next(iter(name.values()), f"House {hid}")
        try:
            db.execute("INSERT OR REPLACE INTO houses VALUES (?,?,?,?)", (ruleset, hid, name, is_neutral(name)))
            n, stored = collect_house(db, api, ruleset, hid)
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
    n_items = fetch_missing_items(db, api)
    prune(db, keep_days)
    msg =f"{len(houses)} houses, {total} listings, {n_items} new item names, {time.time() - t0:.0f}s"
    if unchanged:
        msg += f"; unchanged: {', '.join(unchanged)}"
    if errors:
        msg += f"; failed: {'; '.join(errors)}"
    db.execute("INSERT INTO runs (ts, ok, message) VALUES (?,?,?)", (int(time.time()), 0 if errors else 1, msg))
    return msg, errors
