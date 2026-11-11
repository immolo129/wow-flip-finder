"""Generates believable fake auction data so the UI can be tried without API keys."""
import random
import time

import collector

HOUSES = [(2, "Horde Auction House", 0), (6, "Alliance Auction House", 0), (7, "Blackwater Auction House", 1)]

# item_id, name, quality, vendor sell price (c), typical AH price (c), typical units listed
ITEMS = [
    (14047, "Runecloth", "common", 400, 1500, 900),
    (14048, "Bolt of Runecloth", "common", 1000, 4400, 200),
    (4306, "Silk Cloth", "common", 150, 900, 600),
    (4338, "Mageweave Cloth", "common", 250, 1100, 500),
    (2589, "Linen Cloth", "common", 13, 30, 1500),
    (2592, "Wool Cloth", "common", 33, 160, 800),
    (12359, "Thorium Bar", "common", 600, 3200, 300),
    (10620, "Thorium Ore", "common", 250, 2900, 250),
    (3575, "Iron Bar", "common", 100, 1800, 200),
    (2772, "Iron Ore", "common", 150, 1500, 220),
    (13463, "Dreamfoil", "common", 200, 6500, 120),
    (13464, "Golden Sansam", "common", 200, 5200, 90),
    (8831, "Purple Lotus", "common", 300, 3900, 110),
    (3820, "Stranglekelp", "common", 15, 900, 150),
    (8838, "Sungrass", "common", 60, 2600, 140),
    (13465, "Mountain Silversage", "common", 300, 9000, 80),
    (13467, "Icecap", "common", 300, 7800, 70),
    (14344, "Large Brilliant Shard", "rare", 0, 180000, 25),
    (16204, "Illusion Dust", "common", 0, 22000, 160),
    (16203, "Greater Eternal Essence", "uncommon", 0, 95000, 30),
    (7078, "Essence of Fire", "uncommon", 400, 150000, 15),
    (12808, "Essence of Undeath", "uncommon", 400, 60000, 30),
    (7076, "Essence of Earth", "uncommon", 400, 90000, 20),
    (12662, "Demonic Rune", "uncommon", 1000, 45000, 25),
    (13444, "Major Mana Potion", "common", 1000, 18000, 120),
    (13446, "Major Healing Potion", "common", 1000, 9000, 140),
    (8170, "Rugged Leather", "common", 375, 2400, 300),
    (15417, "Devilsaur Leather", "uncommon", 1500, 160000, 12),
    (12361, "Blue Sapphire", "uncommon", 1500, 42000, 30),
    (7910, "Star Ruby", "uncommon", 1000, 21000, 40),
    (12800, "Azerothian Diamond", "uncommon", 1500, 52000, 20),
    (2318, "Light Leather", "common", 15, 38, 900),
    (4234, "Heavy Leather", "common", 75, 550, 300),
    (3356, "Kingsblood", "common", 30, 1300, 160),
    (12037, "Mystery Meat", "common", 100, 300, 200),
    (8146, "Wicked Claw", "common", 150, 5800, 40),
    (11178, "Large Radiant Shard", "rare", 0, 95000, 20),
    (10940, "Strange Dust", "common", 0, 600, 500),
    (11083, "Soul Dust", "common", 0, 1100, 300),
    (6037, "Truesilver Bar", "uncommon", 500, 9500, 80),
    (7909, "Aquamarine", "uncommon", 500, 6500, 60),
    (14256, "Felcloth", "common", 2000, 52000, 30),
    (12655, "Enchanted Thorium Bar", "common", 1000, 14000, 40),
    (9262, "Black Vitriol", "common", 1250, 7500, 50),
    (13926, "Golden Pearl", "rare", 1000, 110000, 10),
    (7972, "Ichor of Undeath", "common", 100, 2900, 120),
]

HOUSE_FACTOR = {2: 1.00, 6: 1.08, 7: 1.25}
HOUSE_SUPPLY = {2: 1.0, 6: 1.1, 7: 0.25}


def _ladder(rng, price, units, house_id):
    rows = []
    left = max(1, int(units * HOUSE_SUPPLY[house_id] * rng.uniform(0.6, 1.4)))
    while left > 0:
        stack = min(left, rng.choice([1, 1, 2, 5, 10, 20]))
        p = int(price * rng.lognormvariate(0.05, 0.12))
        rows.append((p, stack))
        left -= stack
    return rows


def build(db, ruleset, hours=96, seed=42):
    if db.one("SELECT COUNT(*) AS n FROM snapshots")["n"]:
        return  # already built
    rng = random.Random(seed)
    now = int(time.time()) - 60
    for hid, name, neutral in HOUSES:
        db.execute("INSERT OR REPLACE INTO houses VALUES (?,?,?,?)", (ruleset, hid, name, neutral))
    db.executemany("INSERT OR REPLACE INTO items VALUES (?,?,?,?,?,?)",
                   [(i, n, q, v, 1, now) for i, n, q, v, _, _ in ITEMS])

    drift = {i: 1.0 for i, *_ in ITEMS}
    turnover = {i: rng.uniform(0.005, 0.06) for i, *_ in ITEMS}  # share of listed units sold per hour
    for h in range(hours, -1, -1):
        ts = now - h * 3600
        for i in drift:
            drift[i] *= rng.uniform(0.985, 1.015)
        for hid, _, _ in HOUSES:
            listings = []
            for iid, _, _, vendor, base, units in ITEMS:
                price = base * HOUSE_FACTOR[hid] * drift[iid]
                for p, q in _ladder(rng, price, units, hid):
                    listings.append((iid, p, q))
            if h == 0:
                listings += _plant(rng, hid)
            sales = None if h == hours else {
                iid: int(units * HOUSE_SUPPLY[hid] * turnover[iid] * rng.uniform(0.3, 1.7))
                for iid, _, _, _, _, units in ITEMS}
            collector.store_snapshot(db, ruleset, hid, listings, ts=ts, sales=sales)
    collector.recompute_market(db, ruleset, now=now)


def _plant(rng, hid):
    """Underpriced listings in the latest snapshot, so the demo shows real-looking flips."""
    base = {i: b for i, _, _, _, b, _ in ITEMS}
    vend = {i: v for i, _, _, v, _, _ in ITEMS}
    if hid == 2:      # Horde
        return [
            (14344, int(base[14344] * 0.55), 3), (14344, int(base[14344] * 0.62), 2),
            (13463, int(base[13463] * 0.6), 20), (7078, int(base[7078] * 0.5), 4),
            (16204, int(base[16204] * 0.7), 40), (13444, int(base[13444] * 0.65), 15),
            (12037, int(vend[12037] * 0.5), 20), (4306, int(vend[4306] * 0.6), 40),
            (2589, 9, 200), (14048, int(vend[14048] * 0.8), 10),
        ]
    if hid == 7:      # Blackwater: a few items dumped cheap -> buy here, sell on Horde
        return [(15417, int(base[15417] * 0.6), 4), (12361, int(base[12361] * 0.6), 6),
                (13465, int(base[13465] * 0.55), 15)]
    if hid == 6:      # Alliance (only shows with "include alt routes")
        return [(14256, int(base[14256] * 0.45), 8), (12808, int(base[12808] * 0.5), 10)]
    return []
