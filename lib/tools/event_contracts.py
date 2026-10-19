#!/usr/bin/env python3
"""Event contract registry auditor (refinement P1/1.1).

Registry: config/event_contracts.json

Subcommands:
  static              Scan the codebase for emitted event types; report types
                      missing from the registry and registry schema errors.
  live [--days N]     Compare the live reactor registry (.george/reactors.json)
                      and recent events.db traffic against the registry.
  validate TYPE JSON  Validate one payload against its contract.
  sync-db             Upsert contracts into the events.db event_contracts table.

Exit codes: 0 clean, 1 findings, 2 usage/registry error.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
import time
from pathlib import Path
from typing import Any

REPO = Path(os.environ.get("LODGE_DIR") or Path(__file__).resolve().parents[2])
REGISTRY = Path(os.environ.get("EVENT_CONTRACTS_FILE") or REPO / "configs" / "event_contracts.json")
HANDLINGS = {"reactor", "store", "test_only", "deprecated"}
TYPE_RE = r"[A-Za-z0-9_.:/-]+"

SHELL_EMIT = re.compile(r'event_bus_emit\s+"(' + TYPE_RE + r')"')
PY_EMIT = re.compile(r'\bemit\w*\(\s*["\'](' + TYPE_RE + r')["\']', re.S)
YAML_EMIT = re.compile(r'^\s*emit_event:\s*["\']?(' + TYPE_RE + r')["\']?\s*$', re.M)
SCAN_DIRS = ("lib", "commands", "scripts", "bin")
SKIP_PARTS = {"node_modules", ".venv", "target", "__pycache__", "okf", "build_prism"}


def load_registry(path: Path = REGISTRY) -> dict[str, dict[str, Any]]:
    data = json.loads(path.read_text())
    out: dict[str, dict[str, Any]] = {}
    for c in data.get("contracts", []):
        out[c["type"]] = c
    return out


def registry_errors(reg: dict[str, dict[str, Any]]) -> list[str]:
    errs: list[str] = []
    for t, c in reg.items():
        h = c.get("handling")
        if h not in HANDLINGS:
            errs.append(f"{t}: invalid handling {h!r}")
        if not c.get("domain"):
            errs.append(f"{t}: missing domain")
        if not c.get("description"):
            errs.append(f"{t}: missing description")
        if h == "reactor" and not c.get("reactors"):
            errs.append(f"{t}: handling=reactor but no reactors listed")
        if h == "deprecated" and c.get("alias_of") and c["alias_of"] not in reg:
            errs.append(f"{t}: alias_of {c['alias_of']!r} not in registry")
        req = c.get("required", [])
        if not isinstance(req, list) or not all(isinstance(x, str) for x in req):
            errs.append(f"{t}: required must be a list of strings")
    return errs


def _iter_files(root: Path, exts: tuple[str, ...]):
    for d in SCAN_DIRS:
        base = root / d
        if not base.exists():
            continue
        for p in base.rglob("*"):
            if not p.is_file() or SKIP_PARTS.intersection(p.parts):
                continue
            if p.suffix in exts or (exts == (".sh",) and p.suffix == "" and p.parent.name == "bin"):
                yield p
    if exts == (".sh",) and (root / "lodge").is_file():
        yield root / "lodge"


def scan_emitted(root: Path = REPO) -> dict[str, set[str]]:
    found: dict[str, set[str]] = {}

    def add(t: str, where: str) -> None:
        found.setdefault(t, set()).add(where)

    for p in _iter_files(root, (".sh",)):
        try:
            txt = p.read_text(errors="ignore")
        except OSError:
            continue
        for m in SHELL_EMIT.finditer(txt):
            add(m.group(1), str(p.relative_to(root)))
    for p in _iter_files(root, (".py",)):
        try:
            txt = p.read_text(errors="ignore")
        except OSError:
            continue
        for m in PY_EMIT.finditer(txt):
            add(m.group(1), str(p.relative_to(root)))
    cfg = root / "config"
    if cfg.exists():
        for p in list(cfg.glob("*.yaml")) + list(cfg.glob("*.yaml.template")) + list(cfg.glob("*.yml")):
            for m in YAML_EMIT.finditer(p.read_text(errors="ignore")):
                add(m.group(1), str(p.relative_to(root)))
    return found


def validate(reg: dict[str, dict[str, Any]], etype: str, payload: Any) -> tuple[int, str]:
    c = reg.get(etype)
    if c is None:
        return 3, f"uncontracted event type {etype!r}"
    if c.get("handling") == "deprecated":
        return 3, f"deprecated event type {etype!r} (use {c.get('alias_of')})"
    req = c.get("required", [])
    if req:
        if not isinstance(payload, dict):
            return 4, f"{etype}: payload must be an object with {req}"
        missing = [k for k in req if payload.get(k) is None]
        if missing:
            return 4, f"{etype}: missing required fields {missing}"
    return 0, "ok"


def cmd_static(_: argparse.Namespace) -> int:
    reg = load_registry()
    errs = registry_errors(reg)
    emitted = scan_emitted()
    missing = {t: sorted(w) for t, w in emitted.items() if t not in reg}
    deprecated_emitted = {t: sorted(w) for t, w in emitted.items()
                          if reg.get(t, {}).get("handling") == "deprecated"}
    report = {"registry_errors": errs, "uncontracted": missing,
              "deprecated_emitted": deprecated_emitted, "emitted_types": len(emitted),
              "contracts": len(reg)}
    print(json.dumps(report, indent=2))
    return 1 if (errs or missing or deprecated_emitted) else 0


def cmd_live(a: argparse.Namespace) -> int:
    reg = load_registry()
    gdir = Path(a.george_dir or os.environ.get("GEORGE_DIR") or REPO / ".george")
    report: dict[str, Any] = {}
    rx_file = gdir / "reactors.json"
    if rx_file.exists():
        rx = json.loads(rx_file.read_text()).get("reactors", [])
        live_ids = {r.get("id") for r in rx if r.get("enabled", True)}
        report["reactors_on_uncontracted_types"] = sorted(
            f"{r.get('id')}:{r.get('event_type')}" for r in rx if r.get("event_type") not in reg)
        report["reactors_on_deprecated_types"] = sorted(
            f"{r.get('id')}:{r.get('event_type')}" for r in rx
            if reg.get(r.get("event_type"), {}).get("handling") == "deprecated")
        report["declared_reactors_missing_live"] = sorted(
            f"{t}:{rid}" for t, c in reg.items() if c.get("handling") == "reactor"
            for rid in c.get("reactors", []) if rid not in live_ids)
    db = gdir / "events.db"
    if db.exists():
        since = int(time.time()) - a.days * 86400
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5)
        rows = con.execute("SELECT event_type, COUNT(*) FROM events WHERE timestamp > ? GROUP BY 1",
                           (since,)).fetchall()
        con.close()
        report["observed_uncontracted"] = {t: n for t, n in rows if t not in reg}
        report["observed_test_only"] = {t: n for t, n in rows
                                        if reg.get(t, {}).get("handling") == "test_only"}
    print(json.dumps(report, indent=2))
    bad = any(report.get(k) for k in ("reactors_on_uncontracted_types", "reactors_on_deprecated_types",
                                       "observed_uncontracted"))
    return 1 if bad else 0


def cmd_validate(a: argparse.Namespace) -> int:
    reg = load_registry()
    try:
        payload = json.loads(a.payload)
    except json.JSONDecodeError:
        payload = a.payload
    code, msg = validate(reg, a.type, payload)
    print(msg)
    return code


def cmd_sync_db(a: argparse.Namespace) -> int:
    reg = load_registry()
    gdir = Path(a.george_dir or os.environ.get("GEORGE_DIR") or REPO / ".george")
    db = Path(os.environ.get("GEORGE_EVENTS_DB") or gdir / "events.db")
    if not db.exists():
        print(f"no events.db at {db}", file=sys.stderr)
        return 2
    con = sqlite3.connect(str(db), timeout=5)
    now = int(time.time())
    with con:
        for t, c in reg.items():
            schema = {k: c[k] for k in ("handling", "required", "reactors", "alias_of") if k in c}
            con.execute(
                """INSERT INTO event_contracts (event_type, domain, description, retention_days, schema_json, created_at)
                   VALUES (?, ?, ?, ?, ?, ?)
                   ON CONFLICT(event_type) DO UPDATE SET domain=excluded.domain,
                     description=excluded.description, retention_days=excluded.retention_days,
                     schema_json=excluded.schema_json""",
                (t, c["domain"], c["description"], int(c.get("retention_days", 90)), json.dumps(schema), now))
    con.close()
    print(f"synced {len(reg)} contracts into {db}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("static").set_defaults(fn=cmd_static)
    lv = sub.add_parser("live")
    lv.add_argument("--days", type=int, default=14)
    lv.add_argument("--george-dir")
    lv.set_defaults(fn=cmd_live)
    va = sub.add_parser("validate")
    va.add_argument("type")
    va.add_argument("payload")
    va.set_defaults(fn=cmd_validate)
    sd = sub.add_parser("sync-db")
    sd.add_argument("--george-dir")
    sd.set_defaults(fn=cmd_sync_db)
    a = ap.parse_args(argv)
    try:
        return a.fn(a)
    except (OSError, json.JSONDecodeError, KeyError) as e:
        print(f"registry error: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
