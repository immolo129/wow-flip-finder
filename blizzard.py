"""Minimal Battle.net API client for WoW: Forever.

WoW Forever is not documented by Blizzard yet. Endpoints below are the ones the
community confirmed after launch (Nov 2026):
  dynamic-forever-{region}  /data/wow/ruleset/index
  dynamic-forever-{region}  /data/wow/ruleset/{id}/auctions/            (trailing slash!)
  dynamic-forever-{region}  /data/wow/ruleset/{id}/auctions/{houseId}
  dynamic-forever-{region}  /data/wow/ruleset/{id}/auctions/{houseId}/commodities
  static-forever-{region}   /data/wow/item/{id}
"""
import time
import logging

import requests

log = logging.getLogger("blizzard")

TOKEN_URL = "https://oauth.battle.net/token"


class BlizzardError(RuntimeError):
    pass


class BlizzardAPI:
    def __init__(self, client_id, client_secret, region="eu", locale="en_GB"):
        if not client_id or not client_secret:
            raise BlizzardError("Missing BLIZZARD_CLIENT_ID / BLIZZARD_CLIENT_SECRET "
                                "(the .env file on your PC, or the repository secrets on GitHub)")
        self.client_id = client_id
        self.client_secret = client_secret
        self.region = region.lower()
        self.locale = locale
        self.base = f"https://{self.region}.api.blizzard.com"
        self.session = requests.Session()
        self._token = None
        self._token_exp = 0

    # ---------- auth ----------
    def _get_token(self):
        if self._token and time.time() < self._token_exp - 60:
            return self._token
        r = self.session.post(
            TOKEN_URL,
            data={"grant_type": "client_credentials"},
            auth=(self.client_id, self.client_secret),
            timeout=30,
        )
        if r.status_code == 401:
            raise BlizzardError("Blizzard rejected the client id/secret (401). Check the keys: "
                                "the .env file on your PC, or the repository secrets on GitHub.")
        r.raise_for_status()
        j = r.json()
        self._token = j["access_token"]
        self._token_exp = time.time() + int(j.get("expires_in", 3600))
        return self._token

    # ---------- generic GET ----------
    def get(self, path_or_url, namespace, extra=None):
        """GET a path or full href. Returns parsed JSON, or None on 404."""
        if path_or_url.startswith("http"):
            url = path_or_url.split("?")[0]
        else:
            url = self.base + path_or_url
        params = {"namespace": f"{namespace}-{self.region}", "locale": self.locale, **(extra or {})}
        last = None
        for attempt in range(5):
            headers = {"Authorization": f"Bearer {self._get_token()}"}
            try:
                r = self.session.get(url, params=params, headers=headers, timeout=90)
            except requests.RequestException as e:
                last = e
                time.sleep(2 ** attempt)
                continue
            if r.status_code == 404:
                return None
            if r.status_code == 401:
                self._token = None
                continue
            if r.status_code == 429 or r.status_code >= 500:
                last = BlizzardError(f"HTTP {r.status_code} on {url}")
                time.sleep(2 ** attempt)
                continue
            if r.status_code == 403:
                raise BlizzardError(f"403 Forbidden on {url} (namespace {params['namespace']})")
            r.raise_for_status()
            return r.json()
        raise BlizzardError(f"Giving up on {url}: {last}")

    # ---------- Forever endpoints ----------
    def rulesets(self):
        return self.get("/data/wow/ruleset/index", "dynamic-forever") or {}

    def auction_houses(self, ruleset_id):
        return self.get(f"/data/wow/ruleset/{ruleset_id}/auctions/", "dynamic-forever") or {}

    def house(self, ruleset_id, house_id):
        return self.get(f"/data/wow/ruleset/{ruleset_id}/auctions/{house_id}", "dynamic-forever")

    def commodities(self, ruleset_id, house_id):
        return self.get(f"/data/wow/ruleset/{ruleset_id}/auctions/{house_id}/commodities", "dynamic-forever")

    def _static(self, path, what):
        """Forever's item data is incomplete, so fall back to Classic Era's static namespace."""
        for ns in ("static-forever", "static-classic1x"):
            try:
                data = self.get(path, ns)
            except BlizzardError as e:
                log.debug("%s in %s failed: %s", what, ns, e)
                data = None
            if data:
                return data
        return None

    def item(self, item_id):
        return self._static(f"/data/wow/item/{item_id}", f"item {item_id}")

    def search_items(self, page, page_size=1000):
        """One page of Blizzard's item search, ordered by id. -> {"pageCount": n, "results": [{"data": {...}}]}"""
        return self.get("/data/wow/search/item", "static-forever",
                        {"orderby": "id", "_page": page, "_pageSize": page_size})

    def item_icon(self, item_id):
        """-> icon file name (e.g. 'inv_enchant_dustillusion'), or None."""
        data = self._static(f"/data/wow/media/item/{item_id}", f"item media {item_id}") or {}
        for a in data.get("assets") or []:
            if a.get("key") == "icon" and a.get("value"):
                # .../icons/56/inv_enchant_dustillusion.jpg -> inv_enchant_dustillusion
                return a["value"].rsplit("/", 1)[-1].rsplit(".", 1)[0]
        return None
