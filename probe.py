"""One-off check: which Blizzard endpoints for professions and recipes exist for WoW: Forever?

Run by .github/workflows/probe.yml (Actions tab -> Probe Blizzard API -> Run workflow).
Prints only what exists and a few field names, as ::notice:: lines so they show on the run's
summary page. Never prints the keys.
"""
import config
from blizzard import BlizzardAPI, BlizzardError

NAMESPACES = ("static-forever", "static-classic1x")


def note(msg):
    print(f"::notice::{msg}")


def try_get(api, path, ns):
    try:
        return api.get(path, ns), None
    except BlizzardError as e:
        return None, str(e)[:120]


def main():
    cfg = config.load()
    api = BlizzardAPI(cfg["client_id"], cfg["client_secret"], cfg["region"])

    for ns in NAMESPACES:
        data, err = try_get(api, "/data/wow/profession/index", ns)
        profs = (data or {}).get("professions") or []
        note(f"{ns} profession index: {'ERROR ' + err if err else ('not found' if data is None else f'{len(profs)} professions: ' + ', '.join(p.get('name', '?') if isinstance(p.get('name'), str) else str(p.get('id')) for p in profs[:12]))}")
        if not profs:
            continue
        # look inside the first few professions: skill tiers and recipe counts
        for p in profs[:3]:
            prof, err = try_get(api, f"/data/wow/profession/{p['id']}", ns)
            tiers = (prof or {}).get("skill_tiers") or []
            note(f"{ns} profession {p['id']}: {'ERROR ' + err if err else ('not found' if prof is None else f'keys={sorted(prof.keys())} tiers={len(tiers)}')}")
            for t in tiers[:2]:
                tier, err = try_get(api, f"/data/wow/profession/{p['id']}/skill-tier/{t['id']}", ns)
                cats = (tier or {}).get("categories") or []
                n = sum(len(c.get("recipes") or []) for c in cats)
                note(f"{ns} tier {t['id']}: {'ERROR ' + err if err else ('not found' if tier is None else f'{len(cats)} categories, {n} recipes')}")
                if n:
                    rid = next(r["id"] for c in cats for r in (c.get("recipes") or []))
                    rec, err = try_get(api, f"/data/wow/recipe/{rid}", ns)
                    note(f"{ns} recipe {rid}: {'ERROR ' + err if err else ('not found' if rec is None else f'keys={sorted(rec.keys())}')}")
                    if rec:
                        note(f"{ns} recipe {rid} sample: crafted={rec.get('crafted_item') or rec.get('alliance_crafted_item')} qty={rec.get('crafted_quantity')} reagents={(rec.get('reagents') or [])[:3]}")
                    return

    # vendor prices for reagents bought from vendors (e.g. Crystal Vial 8925)
    for ns in NAMESPACES:
        item, err = try_get(api, "/data/wow/item/8925", ns)
        if item:
            note(f"{ns} item 8925 purchase_price={item.get('purchase_price')} sell_price={item.get('sell_price')}")


if __name__ == "__main__":
    main()
