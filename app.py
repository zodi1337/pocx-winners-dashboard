from __future__ import annotations

import csv
import json
import os
from pathlib import Path
from typing import Any

from flask import Flask, jsonify, render_template, request

app = Flask(__name__)


def load_shell_config(path: str | None) -> dict[str, str]:
    cfg: dict[str, str] = {}
    if not path:
        path = os.environ.get("POCX_WINNERS_CONFIG")
    if not path:
        path = str(Path.cwd() / "config" / "pocx-winners.conf")
    p = Path(path)
    if not p.exists():
        return cfg
    for raw in p.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip().strip('"').strip("'")
        value = value.replace("$HOME", str(Path.home()))
        cfg[key.strip()] = value
    return cfg


CONFIG = load_shell_config(None)
BASE_DIR = Path(CONFIG.get("BASE_DIR", str(Path.home() / "pocx-winners-dashboard")))
DATA_DIR = BASE_DIR / "pocx_winners"
SUMMARY = DATA_DIR / "winners_summary.csv"
META = DATA_DIR / "meta.json"
LATEST = DATA_DIR / "latest_blocks.json"


def read_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def read_rows() -> list[dict[str, Any]]:
    if not SUMMARY.exists():
        return []
    rows: list[dict[str, Any]] = []
    with SUMMARY.open("r", encoding="utf-8", newline="") as f:
        for row in csv.DictReader(f):
            rows.append(row)
    return rows


@app.route("/")
def index():
    range_name = request.args.get("range", "24h").lower()
    if range_name not in {"24h", "7d", "30d", "all"}:
        range_name = "24h"
    return render_template("index.html", range_name=range_name)


@app.route("/api/data")
def api_data():
    rows = read_rows()
    meta = read_json(META, {})
    latest = read_json(LATEST, [])
    return jsonify({"rows": rows, "meta": meta, "latest_blocks": latest})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(CONFIG.get("WEB_PORT", "8082")))
