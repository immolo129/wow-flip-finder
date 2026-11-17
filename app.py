"""WoW Forever flip finder, local version.

    python app.py          real data (needs .env with Blizzard API keys)
    python app.py --demo   fake data, to try the UI without keys

Serves the same page as the GitHub-hosted version (static/), with the data built on the fly
from the local database. The flip maths runs in the browser (static/flips.js).
"""
import argparse
import logging
import threading
import time

from flask import Flask, abort, jsonify, send_from_directory

import collector
import config
import export
from storage import DB

HERE = config.HERE
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("app")

CFG = config.load()
app = Flask(__name__, static_folder=str(HERE / "static"), static_url_path="")
STATE = {"demo": False, "live": False, "running": False, "last_error": None, "next_run": None}
RUN_LOCK = threading.Lock()  # the hourly fetch and "Fetch now" must never run at the same time
db = None
api = None


# ---------- background collector ----------
def run_once():
    if not RUN_LOCK.acquire(blocking=False):
        return
    STATE["running"] = True
    try:
        msg, errors = collector.collect(db, api, CFG["ruleset"])
        STATE["last_error"] = "; ".join(errors) or None
        log.info("Collection done: %s", msg)
    except Exception as e:
        log.exception("Collection failed")
        STATE["last_error"] = str(e)
        db.execute("INSERT INTO runs (ts, ok, message) VALUES (?,?,?)", (int(time.time()), 0, str(e)))
    finally:
        STATE["running"] = False
        RUN_LOCK.release()


def loop():
    while True:
        run_once()
        STATE["next_run"] = int(time.time()) + CFG["interval_min"] * 60
        time.sleep(CFG["interval_min"] * 60)


# ---------- routes ----------
@app.route("/")
def index():
    return send_from_directory(app.static_folder, "index.html")


@app.route("/data/latest.json")
def latest():
    return jsonify(export.latest(db, CFG, STATE))


@app.route("/data/items.json")
def items():
    return jsonify(export.item_index(db))


@app.route("/data/history/<int:shard>.json")
def history(shard):
    if not 0 <= shard < export.SHARDS:
        abort(404)
    return jsonify(export.history_shard(db, CFG["ruleset"], shard))


@app.route("/api/status")
def status():
    return jsonify(STATE)


@app.route("/api/collect", methods=["POST"])
def collect_now():
    if STATE["demo"]:
        return jsonify({"ok": False, "message": "Demo mode: no live collection"})
    if STATE["running"]:
        return jsonify({"ok": False, "message": "Already running"})
    STATE["running"] = True  # so the page's first poll doesn't see "done" before the thread starts
    threading.Thread(target=run_once, daemon=True).start()
    return jsonify({"ok": True, "message": "Started"})


def main():
    global db, api
    p = argparse.ArgumentParser()
    p.add_argument("--demo", action="store_true", help="use generated sample data")
    args = p.parse_args()

    if args.demo:
        import demo
        STATE["demo"] = True
        db = DB(str(HERE / "demo.db"))
        demo.build(db, CFG["ruleset"])
    else:
        from blizzard import BlizzardAPI
        STATE["live"] = True
        db = DB(str(HERE / "flips.db"))
        api = BlizzardAPI(CFG["client_id"], CFG["client_secret"], CFG["region"])
        threading.Thread(target=loop, daemon=True).start()

    log.info("Open http://%s:%d in your browser", "127.0.0.1" if CFG["host"] == "0.0.0.0" else CFG["host"], CFG["port"])
    app.run(host=CFG["host"], port=CFG["port"], debug=False, use_reloader=False)


if __name__ == "__main__":
    main()
