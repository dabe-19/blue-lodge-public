#!/usr/bin/env python3
"""
scripts/training/sync_tool_schemas.py
Single-source-of-truth synchronizer from live `data/schemas/native_tools.json`
into `data/training/native_core_tools.json` (and optional schema manifest exports).

Ensures training (forge.py, harness_curriculum.py), evaluation (multiturn_bench.py),
and public Hugging Face release bundles NEVER drift from live George tool schemas.

Usage:
  sync_tool_schemas.py check [--json]
  sync_tool_schemas.py sync  [--json]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

LODGE_DIR = Path(os.environ.get("LODGE_DIR", Path(__file__).resolve().parent.parent.parent))
LIVE_SCHEMA_PATH = LODGE_DIR / "data" / "schemas" / "native_tools.json"
TRAIN_SCHEMA_PATH = LODGE_DIR / "data" / "training" / "native_core_tools.json"

# Essential Blue Lodge harness tools that must always be present in native_core_tools.json
REQUIRED_CORE_TOOLS = (
    "file_read", "file_edit", "file_write", "file_append", "file_grep", "dir_list",
    "code_outline", "code_symbol_get", "code_symbol_patch", "code_symbol_read", "code_validate",
    "bash_exec", "sandbox_create", "sandbox_exec", "sandbox_remove",
    "git_commit", "git_push", "git_clone", "gitea_branch_create", "gitea_pr_create", "gitea_status",
    "system_vitals", "service_list", "service_manage", "web_search", "web_fetch",
    "recall_search", "recall_archive_milestone", "journal_record", "tool_search",
    "workflow_plan", "workflow_run", "subagent_spawn", "subagent_await", "subagent_diff", "subagent_reap",
    "model_endpoint_status", "backup_list", "backup_create",
    "tyler_tshark_watch", "tyler_intervene", "discord_send_file", "slash_command_exec", "phytology_manage",
)


def load_live_tools(lodge_dir: Path | str = LODGE_DIR) -> list[dict]:
    p = Path(lodge_dir) / "data" / "schemas" / "native_tools.json"
    if not p.is_file():
        return []
    data = json.loads(p.read_text(encoding="utf-8"))
    return data if isinstance(data, list) else []


def schema_sha256(tools: list[dict]) -> str:
    canonical = json.dumps(tools, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def compute_sync_plan(lodge_dir: Path | str = LODGE_DIR) -> tuple[list[dict], dict]:
    live_path = Path(lodge_dir) / "data" / "schemas" / "native_tools.json"
    train_path = Path(lodge_dir) / "data" / "training" / "native_core_tools.json"

    live = json.loads(live_path.read_text(encoding="utf-8"))
    live_map = {t["function"]["name"]: t for t in live if isinstance(t, dict) and isinstance(t.get("function"), dict)}

    train = json.loads(train_path.read_text(encoding="utf-8")) if train_path.is_file() else []
    train_names_order = []
    train_map = {}
    for t in train:
        nm = (t.get("function") or {}).get("name")
        if nm and nm not in train_map:
            train_names_order.append(nm)
            train_map[nm] = t

    updated = []
    added = []
    preserved_legacy = []
    merged: list[dict] = []
    seen = set()

    for nm in train_names_order:
        seen.add(nm)
        if nm in live_map:
            if json.dumps(train_map[nm], sort_keys=True) != json.dumps(live_map[nm], sort_keys=True):
                updated.append(nm)
            merged.append(live_map[nm])
        else:
            preserved_legacy.append(nm)
            merged.append(train_map[nm])

    for nm in REQUIRED_CORE_TOOLS:
        if nm not in seen and nm in live_map:
            seen.add(nm)
            added.append(nm)
            merged.append(live_map[nm])

    report = {
        "live_count": len(live_map),
        "train_before_count": len(train_map),
        "train_after_count": len(merged),
        "updated": updated,
        "added": added,
        "preserved_legacy": preserved_legacy,
        "in_sync": not updated and not added,
        "live_sha256": schema_sha256(live),
        "core_sha256": schema_sha256(merged),
    }
    return merged, report


def sync_schemas(lodge_dir: Path | str = LODGE_DIR, write: bool = True) -> dict:
    merged, report = compute_sync_plan(lodge_dir)
    if write and not report["in_sync"]:
        train_path = Path(lodge_dir) / "data" / "training" / "native_core_tools.json"
        train_path.parent.mkdir(parents=True, exist_ok=True)
        train_path.write_text(json.dumps(merged, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        report["wrote"] = str(train_path)
    else:
        report["wrote"] = None
    return report


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("cmd", choices=("check", "sync"))
    ap.add_argument("--lodge-dir", default=str(LODGE_DIR))
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    rep = sync_schemas(args.lodge_dir, write=(args.cmd == "sync"))
    if args.json:
        print(json.dumps(rep, indent=2))
    else:
        print(f"Live tools: {rep['live_count']} | Core training tools: {rep['train_before_count']} -> {rep['train_after_count']}")
        print(f"Updated ({len(rep['updated'])}): {', '.join(rep['updated']) or 'none'}")
        print(f"Added   ({len(rep['added'])}): {', '.join(rep['added']) or 'none'}")
        print(f"Core SHA-256: {rep['core_sha256'][:16]} | in_sync={rep['in_sync']}")
    if args.cmd == "check" and not rep["in_sync"]:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
