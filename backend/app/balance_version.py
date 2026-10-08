"""Version of the workbook-derived balance shipped with this account backend."""
from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path

_FILE = Path(__file__).resolve().parents[2] / "data/balance/final_status.json"


@lru_cache(maxsize=1)
def current() -> str:
    value = json.loads(_FILE.read_text(encoding="utf-8"))["balance_version"]
    if not isinstance(value, str) or len(value) != 64:
        raise ValueError("Invalid final status balance_version")
    return value
