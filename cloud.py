"""Run by GitHub Actions every hour (.github/workflows/collect.yml):
fetch the auction data into flips.db, then write the static site for GitHub Pages.

    python cloud.py --db flips.db --out site --require-password
    python cloud.py --demo --out site       site with demo data, to check the build without keys

The data files are encrypted with the SITE_PASSWORD environment variable when it's set.
--require-password refuses to publish anything readable without one (used on GitHub).
"""
import argparse
import logging
import os
import time

import collector
import config
import export
from storage import DB

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("cloud")

KEEP_DAYS = 8  # 7 days for the market value + 1 spare; keeps the stored database small


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--db", default="flips.db")
    p.add_argument("--out", default="site")
    p.add_argument("--demo", action="store_true")
    p.add_argument("--require-password", action="store_true")
    args = p.parse_args()
    cfg = config.load()
    password = os.environ.get("SITE_PASSWORD", "")
    if args.require_password and not password:
        raise SystemExit("SITE_PASSWORD is not set. Refusing to publish the data unencrypted.")

    db = DB(args.db)
    extra = {"live": False, "demo": args.demo, "last_error": None}
    if args.demo:
        import demo
        demo.build(db, cfg["ruleset"])
    else:
        from blizzard import BlizzardAPI
        try:
            api = BlizzardAPI(cfg["client_id"], cfg["client_secret"], cfg["region"])
            msg, errors = collector.collect(db, api, cfg["ruleset"], keep_days=KEEP_DAYS)
            log.info("Collection done: %s", msg)
            extra["last_error"] = "; ".join(errors) or None
        except Exception as e:
            log.exception("Collection failed")
            extra["last_error"] = str(e)
            db.execute("INSERT INTO runs (ts, ok, message) VALUES (?,?,?)", (int(time.time()), 0, str(e)))
            if "401" in str(e):
                # safe hint for the log: lengths only, never the keys themselves
                print(f"::warning::BLIZZARD_CLIENT_ID is {len(cfg['client_id'])} characters and "
                      f"BLIZZARD_CLIENT_SECRET is {len(cfg['client_secret'])}. Blizzard's are normally 32 each. "
                      "If they look right, check they aren't swapped.")

    # the page is published even after a failed fetch, so the error shows on it
    export.write_site(db, cfg, args.out, config.HERE / "static", extra,
                      password=password or None, site_id=os.environ.get("GITHUB_REPOSITORY", "local"))

    # shrink the database before it's uploaded, and fold the WAL file back into it
    db.execute("VACUUM")
    db.execute("PRAGMA journal_mode=DELETE")
    db.conn.close()

    if extra["last_error"]:
        print(f"::error::Fetch failed: {extra['last_error']}")  # shows on the run in the Actions tab
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a") as f:
                f.write("failed=true\n")


if __name__ == "__main__":
    main()
