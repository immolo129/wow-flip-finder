"""Settings from .env (local) or environment variables (GitHub Actions)."""
import os
from pathlib import Path

HERE = Path(__file__).resolve().parent
RULESET_NAMES = {1: "PvP", 2: "Normal", 3: "Roleplay", 15: "Roleplay PvP"}


def load_env(path):
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


def load():
    load_env(HERE / ".env")
    e = os.environ.get
    return {
        # strip: a space or line break pasted along with a key makes Blizzard reject it
        "client_id": e("BLIZZARD_CLIENT_ID", "").strip(),
        "client_secret": e("BLIZZARD_CLIENT_SECRET", "").strip(),
        "region": e("REGION") or "eu",
        "ruleset": int(e("RULESET") or 1),
        "faction": (e("FACTION") or "horde").lower(),
        "interval_min": int(e("INTERVAL_MINUTES") or 60),
        "host": e("HOST") or "127.0.0.1",
        "port": int(e("PORT") or 5000),
    }
