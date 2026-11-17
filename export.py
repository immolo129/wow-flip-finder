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


def latest(db, cfg, extra=None):
    rs = cfg["ruleset"]
    ladders = defaultdict(list)
    for r in db.query("""SELECT house_id, item_id, unit_price, quantity, listings FROM latest_listings
                         WHERE ruleset=? ORDER BY house_id, item_id, unit_price""", (rs,)):
        ladders[(r["house_id"], r["item_id"])].append([r["unit_price"], r["quantity"], r["listings"]])
    markets = [
        [m["house_id"], m["item_id"], m["market"], m["seen"], round(m["avg_listings"], 2),
         round(m["avg_quantity"], 2), None if m["sold_per_day"] is None else round(m["sold_per_day"], 4),
         round(m["tracked_h"] or 0, 1)]
        for m in db.query("SELECT * FROM market WHERE ruleset=?", (rs,))
        if (m["house_id"], m["item_id"]) in ladders
    ]
    ids = {i for _, i in ladders}
    # item id -> [name, quality, vendor price, icon file name or ""]
    items = {str(r["item_id"]): [r["name"], (r["quality"] or "").lower(), r["sell_price"] or 0, r["icon"] or ""]
             for r in db.query("SELECT item_id, name, quality, sell_price, icon FROM items") if r["item_id"] in ids}
    return {
        "status": status(db, cfg, extra),
        "houses": [[h["house_id"], h["name"], h["neutral"]]
                   for h in db.query("SELECT house_id, name, neutral FROM houses WHERE ruleset=? ORDER BY name", (rs,))],
        "items": items,
        # house, item, market, seen, avg_listings, avg_quantity, sold_per_day, tracked_h
        "markets": markets,
        # house, item, [[unit_price, quantity, auctions], ...] cheapest first
        "ladders": [[h, i, lad] for (h, i), lad in ladders.items()],
    }


def _history_rows(db, ruleset, shard=None, days=HISTORY_DAYS):
    sql = """SELECT s.house_id, st.item_id, s.ts, st.min_price, st.market
             FROM item_stats st JOIN snapshots s ON s.id = st.snapshot_id
             WHERE s.ruleset=? AND s.ts>=?"""
    params = [ruleset, int(time.time()) - days * 86400]
    if shard is not None:
        sql += " AND st.item_id % ? = ?"
        params += [SHARDS, shard]
    return db.query(sql + " ORDER BY s.ts", params)


def _group(rows):
    """-> {shard: {"house:item": [[ts, min_price, market], ...]}}"""
    out = defaultdict(dict)
    for r in rows:
        out[r["item_id"] % SHARDS].setdefault(f"{r['house_id']}:{r['item_id']}", []).append(
            [r["ts"], r["min_price"], r["market"]])
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
    dump(latest(db, cfg, extra), out / "data" / "latest.json")
    shards = _group(_history_rows(db, cfg["ruleset"]))
    for k in range(SHARDS):
        dump(shards.get(k, {}), out / "data" / "history" / f"{k}.json")
    (out / ".nojekyll").write_text("")
