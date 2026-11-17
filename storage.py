"""SQLite storage. One small file (flips.db) next to the app."""
import sqlite3
import threading
from contextlib import contextmanager

SCHEMA = """
CREATE TABLE IF NOT EXISTS houses (
    ruleset   INTEGER,
    house_id  INTEGER,
    name      TEXT,
    neutral   INTEGER DEFAULT 0,
    PRIMARY KEY (ruleset, house_id)
);
CREATE TABLE IF NOT EXISTS snapshots (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    ts          INTEGER,
    ruleset     INTEGER,
    house_id    INTEGER,
    n_listings  INTEGER,
    fingerprint TEXT,      -- hash of the auction data, to skip unchanged data
    gap         INTEGER    -- seconds since the previous snapshot, only when sales were tracked
);
CREATE INDEX IF NOT EXISTS ix_snap ON snapshots (ruleset, house_id, ts);

-- one row per item per snapshot (aggregated, keeps the DB small)
CREATE TABLE IF NOT EXISTS item_stats (
    snapshot_id INTEGER,
    item_id     INTEGER,
    min_price   INTEGER,   -- copper per unit
    market      INTEGER,   -- weighted mean of the cheapest 25 % of units
    median      INTEGER,   -- quantity-weighted median
    quantity    INTEGER,
    listings    INTEGER,
    PRIMARY KEY (snapshot_id, item_id)
);

-- estimated units sold since the previous snapshot (only items with sales > 0)
CREATE TABLE IF NOT EXISTS sales (
    snapshot_id INTEGER,
    item_id     INTEGER,
    sold        INTEGER,
    PRIMARY KEY (snapshot_id, item_id)
);

-- auctions of the most recent snapshot, to see which ones disappear by the next one
CREATE TABLE IF NOT EXISTS prev_auctions (
    ruleset    INTEGER,
    house_id   INTEGER,
    auction_id INTEGER,
    item_id    INTEGER,
    quantity   INTEGER,
    time_left  TEXT
);
CREATE INDEX IF NOT EXISTS ix_prev ON prev_auctions (ruleset, house_id);

-- full price ladder of the most recent snapshot only (replaced every run)
CREATE TABLE IF NOT EXISTS latest_listings (
    ruleset    INTEGER,
    house_id   INTEGER,
    item_id    INTEGER,
    unit_price INTEGER,
    quantity   INTEGER,
    listings   INTEGER
);
CREATE INDEX IF NOT EXISTS ix_latest ON latest_listings (ruleset, house_id, item_id, unit_price);

-- rolling market value, recomputed after every collection
CREATE TABLE IF NOT EXISTS market (
    ruleset      INTEGER,
    house_id     INTEGER,
    item_id      INTEGER,
    market       INTEGER,  -- median of snapshot market values over the window
    seen         INTEGER,  -- snapshots the item appeared in
    avg_listings REAL,
    avg_quantity REAL,
    sold_per_day REAL,     -- estimated, NULL until sales have been tracked
    tracked_h    REAL,     -- hours of sales tracking behind sold_per_day
    PRIMARY KEY (ruleset, house_id, item_id)
);

CREATE TABLE IF NOT EXISTS items (
    item_id    INTEGER PRIMARY KEY,
    name       TEXT,
    quality    TEXT,
    sell_price INTEGER,   -- vendor sell price, copper
    found      INTEGER,
    fetched_ts INTEGER,
    icon       TEXT,      -- icon file name, e.g. inv_enchant_dustillusion; '' = not found
    icon_ts    INTEGER    -- when the icon was last looked up
);

CREATE TABLE IF NOT EXISTS runs (
    id       INTEGER PRIMARY KEY AUTOINCREMENT,
    ts       INTEGER,
    ok       INTEGER,
    message  TEXT
);
"""

# columns added after the first release; added to older databases on start-up
MIGRATIONS = {
    "snapshots": [("fingerprint", "TEXT"), ("gap", "INTEGER")],
    "market": [("sold_per_day", "REAL"), ("tracked_h", "REAL")],
    "items": [("icon", "TEXT"), ("icon_ts", "INTEGER")],
}


class DB:
    def __init__(self, path):
        self.path = path
        self.lock = threading.RLock()
        self._depth = 0
        self.conn = sqlite3.connect(path, check_same_thread=False, timeout=30)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA synchronous=NORMAL")
        self.conn.executescript(SCHEMA)
        for table, cols in MIGRATIONS.items():
            have = {r[1] for r in self.conn.execute(f"PRAGMA table_info({table})")}
            for name, typ in cols:
                if name not in have:
                    self.conn.execute(f"ALTER TABLE {table} ADD COLUMN {name} {typ}")
        self.conn.commit()

    @contextmanager
    def transaction(self):
        """Everything inside is committed together, or not at all."""
        with self.lock:
            self._depth += 1
            try:
                yield self
            except BaseException:
                self._depth -= 1
                if not self._depth:
                    self.conn.rollback()
                raise
            self._depth -= 1
            if not self._depth:
                self.conn.commit()

    def _commit(self):
        if not self._depth:
            self.conn.commit()

    def execute(self, sql, params=()):
        with self.lock:
            cur = self.conn.execute(sql, params)
            self._commit()
            return cur

    def executemany(self, sql, rows):
        with self.lock:
            self.conn.executemany(sql, rows)
            self._commit()

    def query(self, sql, params=()):
        with self.lock:
            return [dict(r) for r in self.conn.execute(sql, params).fetchall()]

    def one(self, sql, params=()):
        rows = self.query(sql, params)
        return rows[0] if rows else None
