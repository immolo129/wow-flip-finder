"""Turns the database into the JSON the page reads:

    data/latest.json        status, houses, item names, market values and current price ladders
    data/history/<n>.json   price history, split into SHARDS files by item_id % SHARDS

The local app serves these on the fly; on GitHub, cloud.py writes them into the static site.
The flip maths itself runs in the browser (static/flips.js).

With a password, every JSON file is written encrypted instead:
    {"enc": 1, "salt": b64, "iter": n, "iv": b64, "ct": b64}
AES-256-GCM with a key from PBKDF2-SHA256(password, salt, iter). The page asks for the
password and decrypts with WebCrypto (see unlock() in index.html).
"""
import base64
import hashlib
import json
import os
import shutil
import time
from collections import defaultdict
from pathlib import Path

from config import RULESET_NAMES

SHARDS = 64
HISTORY_DAYS = 7
PBKDF2_ITER = 600_000  # slows down password guessing; the browser derives the key once per visit


def make_encryptor(password, site_id):
    """-> function(bytes) -> encrypted wrapper dict. The salt is fixed per site (not per build),
    so a key remembered in the browser keeps working after each hourly update."""
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM  # only needed on GitHub

    salt = hashlib.sha256(f"forever-flip-finder:{site_id}".encode()).digest()[:16]
    aes = AESGCM(hashlib.pbkdf2_hmac("sha256", password.encode(), salt, PBKDF2_ITER, 32))
    b64 = lambda b: base64.b64encode(b).decode()

    def encrypt(data):
        iv = os.urandom(12)
        return {"enc": 1, "salt": b64(salt), "iter": PBKDF2_ITER, "iv": b64(iv), "ct": b64(aes.encrypt(iv, data, None))}
    return encrypt


def status(db, cfg, extra=None):
    rs = cfg["ruleset"]
    # snapshots are per house, so count the hours of history of the best-covered house
    snaps = db.one("""SELECT MAX(n) AS n, MIN(first) AS first, MAX(last) AS last FROM (
                        SELECT COUNT(*) AS n, MIN(ts) AS first, MAX(ts) AS last
                        FROM snapshots WHERE ruleset=? GROUP BY house_id)""", (rs,))
    return {
        "generated": int(time.time()),
        "region": cfg["region"].upper(), "ruleset": rs,
        "ruleset_name": RULESET_NAMES.get(rs, str(rs)), "faction": cfg["faction"],
        "snapshots": snaps, "last_run": db.one("SELECT * FROM runs ORDER BY id DESC LIMIT 1"),
        **(extra or {}),
    }


def _r(v, n):
    return None if v is None else round(v, n)


def latest(db, cfg, extra=None):
    rs = cfg["ruleset"]
    ladders = defaultdict(list)
    for r in db.query("""SELECT house_id, item_id, unit_price, quantity, listings FROM latest_listings
                         WHERE ruleset=? ORDER BY house_id, item_id, unit_price""", (rs,)):
        ladders[(r["house_id"], r["item_id"])].append([r["unit_price"], r["quantity"], r["listings"]])
    markets = [
        [m["house_id"], m["item_id"], m["market"], m["seen"], round(m["avg_listings"], 2),
         round(m["avg_quantity"], 2), None if m["sold_per_day"] is None else round(m["sold_per_day"], 4),
         round(m["tracked_h"] or 0, 1), _r(m["sell_rate"], 3), m["low7"], m["avg7"], m["high7"],
         _r(m["chg24"], 3), _r(m["chg7"], 3)]
        for m in db.query("SELECT * FROM market WHERE ruleset=?", (rs,))
        if (m["house_id"], m["item_id"]) in ladders
    ]
    ids = {i for _, i in ladders}
    # recipes whose result is on the auction house (others can't be priced)
    reagents = defaultdict(list)
    for r in db.query("SELECT recipe_id, item_id, quantity FROM recipe_reagents"):
        reagents[r["recipe_id"]].append([r["item_id"], r["quantity"]])
    recipes = [[r["recipe_id"], r["name"], r["profession"], r["crafted_item"], r["crafted_qty"], reagents[r["recipe_id"]]]
               for r in db.query("SELECT * FROM recipes ORDER BY profession, name")
               if r["crafted_item"] in ids and reagents[r["recipe_id"]]]
    ids |= {i for rc in recipes for i, _ in rc[5]}
    # item id -> [name, quality, vendor sell price, icon file name or "", vendor buy price (vendor reagents only)]
    items = {str(r["item_id"]): [r["name"], (r["quality"] or "").lower(), r["sell_price"] or 0, r["icon"] or "", r["vendor_buy"] or 0]
             for r in db.query("SELECT item_id, name, quality, sell_price, icon, vendor_buy FROM items") if r["item_id"] in ids}
    return {
        "status": status(db, cfg, extra),
        "houses": [[h["house_id"], h["name"], h["neutral"]]
                   for h in db.query("SELECT house_id, name, neutral FROM houses WHERE ruleset=? ORDER BY name", (rs,))],
        "items": items,
        # house, item, market, seen, avg_listings, avg_quantity, sold_per_day, tracked_h,
        # sell_rate, low7, avg7, high7, chg24, chg7
        "markets": markets,
        # item -> [region price over the window, region price now, houses listed in]
        "region": {str(r["item_id"]): [r["market7"], r["current"], r["houses"]]
                   for r in db.query("SELECT * FROM region_market") if r["item_id"] in ids},
        # house, item, [[unit_price, quantity, auctions], ...] cheapest first
        "ladders": [[h, i, lad] for (h, i), lad in ladders.items()],
        # recipe id, name, profession, crafted item, crafted quantity, [[reagent item, quantity], ...]
        "recipes": recipes,
    }


def _history_rows(db, ruleset, shard=None, days=HISTORY_DAYS):
    sql = """SELECT s.house_id, st.item_id, s.ts, st.min_price, st.market, st.quantity
             FROM item_stats st JOIN snapshots s ON s.id = st.snapshot_id
             WHERE s.ruleset=? AND s.ts>=?"""
    params = [ruleset, int(time.time()) - days * 86400]
    if shard is not None:
        sql += " AND st.item_id % ? = ?"
        params += [SHARDS, shard]
    return db.query(sql + " ORDER BY s.ts", params)


def _group(rows):
    """-> {shard: {"house:item": [[ts, min_price, market, quantity], ...]}}"""
    out = defaultdict(dict)
    for r in rows:
        out[r["item_id"] % SHARDS].setdefault(f"{r['house_id']}:{r['item_id']}", []).append(
            [r["ts"], r["min_price"], r["market"], r["quantity"]])
    return out


def history_shard(db, ruleset, shard):
    return _group(_history_rows(db, ruleset, shard)).get(shard, {})


def write_site(db, cfg, out_dir, static_dir, extra=None, password=None, site_id="local"):
    """Write the complete static site (page + data) into out_dir, encrypted if a password is given."""
    encrypt = make_encryptor(password, site_id) if password else None

    def dump(obj, path):
        text = json.dumps(obj, separators=(",", ":"))
        if encrypt:
            text = json.dumps(encrypt(text.encode()), separators=(",", ":"))
        path.write_text(text, encoding="utf-8")

    out = Path(out_dir)
    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(static_dir, out)
    (out / "data" / "history").mkdir(parents=True)
    data = latest(db, cfg, extra)
    dump(data, out / "data" / "latest.json")
    shards = _group(_history_rows(db, cfg["ruleset"]))
    for k in range(SHARDS):
        dump(shards.get(k, {}), out / "data" / "history" / f"{k}.json")
    (out / ".nojekyll").write_text("")
    # counts only (nothing secret), for the run log
    return {"houses": len(data["houses"]), "items listed": len(data["ladders"]),
            "recipes": len(data["recipes"]), "professions": len({r[2] for r in data["recipes"]}),
            "icons": sum(1 for it in data["items"].values() if it[3]), "items": len(data["items"]),
            "region prices": len(data["region"]), "sell rates": sum(1 for m in data["markets"] if m[8] is not None)}
