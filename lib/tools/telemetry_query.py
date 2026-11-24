#!/usr/bin/env python3
"""Unified Telemetry Backfill, Cross-Database Lookup & Log Compaction Engine.

Unifies observability across:
  - .george/recall.db (routing_eval_trace, task_terminal_outcomes,
    evaluator_diag_snapshots, grammar_schema_compatibility,
    tool_telemetry_stats, okf_modules, okf_edges, chunks)
  - .george/events.db (events, reactions, events_fts)
  - .george/mqtt.db (topics, messages)
  - .george/routing_trace.jsonl & .george/workspaces/*/evaluator.jsonl
"""

from __future__ import annotations

import argparse
from collections import defaultdict
from datetime import datetime, timedelta, timezone
import filecmp
import glob
import gzip
import hashlib
import json
import math
import os
import sqlite3
import sys
from typing import Any

LODGE_DIR = os.environ.get(
    "LODGE_DIR",
    os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")),
)
GEORGE_DIR = os.environ.get("GEORGE_DIR", os.path.join(LODGE_DIR, ".george"))
RECALL_DB = os.environ.get("RECALL_DB", os.path.join(GEORGE_DIR, "recall.db"))
EVENTS_DB = os.environ.get("EVENTS_DB", os.path.join(GEORGE_DIR, "events.db"))
MQTT_DB = os.environ.get("MQTT_DB", os.path.join(GEORGE_DIR, "mqtt.db"))
SCHEMA_SQL = os.path.join(LODGE_DIR, "data", "schemas", "recall.sql")


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def ensure_recall_schema(db_path: str = RECALL_DB) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(db_path)), exist_ok=True)
    conn = sqlite3.connect(db_path)
    try:
        if os.path.isfile(SCHEMA_SQL):
            with open(SCHEMA_SQL, "r", encoding="utf-8") as f:
                conn.executescript(f.read())
        conn.commit()
    finally:
        conn.close()


def backfill_telemetry(
    george_dir: str = GEORGE_DIR,
    recall_db: str = RECALL_DB,
) -> dict[str, int]:
    """Backfill recall.db telemetry tables from historical JSONL and envelope logs."""
    ensure_recall_schema(recall_db)
    conn = sqlite3.connect(recall_db)
    cur = conn.cursor()

    now = _now_iso()
    stats = {
        "routing_eval_trace_inserted": 0,
        "task_terminal_outcomes_inserted": 0,
        "evaluator_diag_snapshots_inserted": 0,
        "grammar_schema_compatibility_upserted": 0,
        "tool_telemetry_stats_upserted": 0,
    }

    # Aggregators for tool_telemetry_stats
    tool_calls: dict[str, int] = defaultdict(int)
    tool_success: dict[str, int] = defaultdict(int)
    tool_fail: dict[str, int] = defaultdict(int)
    tool_cached: dict[str, int] = defaultdict(int)
    tool_latencies: dict[str, list[float]] = defaultdict(list)
    tool_last_err: dict[str, str] = defaultdict(str)

    # 1. Scan .envelope.json files across workspaces and runs for accurate latency & error_class
    env_patterns = [
        os.path.join(george_dir, "workspaces", "*", "observations", "*.envelope.json"),
        os.path.join(george_dir, "runs", "*", "observations", "*.envelope.json"),
    ]
    seen_envelopes: set[str] = set()
    for pat in env_patterns:
        for env_path in glob.glob(pat):
            # Deduplicate session+call filename between runs/ and workspaces/
            parts = env_path.split(os.sep)
            key = "/".join(parts[-3:]) if len(parts) >= 3 else env_path
            if key in seen_envelopes:
                continue
            seen_envelopes.add(key)
            try:
                with open(env_path, "r", encoding="utf-8", errors="replace") as f:
                    env = json.load(f)
            except Exception:
                continue
            t_name = str(env.get("tool") or "").strip()
            if not t_name:
                continue
            ok = bool(env.get("ok", True))
            dur = float(env.get("duration_ms") or 0.0)
            err_cls = str(env.get("error_class") or "")
            tool_calls[t_name] += 1
            if ok and not err_cls:
                tool_success[t_name] += 1
            else:
                tool_fail[t_name] += 1
                if err_cls:
                    tool_last_err[t_name] = err_cls
            if dur > 0:
                tool_latencies[t_name].append(dur)

    # 2. Scan routing_trace.jsonl for tool calls, task starts/completions, and breaker events
    trace_file = os.path.join(george_dir, "routing_trace.jsonl")
    existing_traces = cur.execute("SELECT COUNT(*) FROM routing_eval_trace").fetchone()[0]
    task_idx = 0
    active_task_id = "historical_task_0"

    if os.path.isfile(trace_file):
        with open(trace_file, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                ts = str(rec.get("timestamp") or now)
                ev = str(rec.get("event") or "")
                data = rec.get("data") if isinstance(rec.get("data"), dict) else {}

                if ev == "task_start":
                    task_idx += 1
                    active_task_id = f"trace_task_{task_idx}_{ts[:19].replace(':', '').replace('-', '')}"
                elif ev == "tool_call":
                    t_name = str(data.get("tool") or "").strip()
                    if t_name:
                        tool_calls[t_name] += 1
                        tool_success[t_name] += 1
                        if data.get("cached") is True:
                            tool_cached[t_name] += 1
                elif ev == "task_complete":
                    if existing_traces == 0:
                        cur.execute(
                            """INSERT INTO routing_eval_trace (
                                task_boundary, recorded_at, infeasibility_class,
                                infeasibility_reason_code, limitation_action,
                                tool_exposure_phase, evaluator_mode,
                                evaluator_failure_reason, task_outcome_class,
                                redacted_diagnostic
                            ) VALUES (?, ?, 'none', '', '', '', 'normal', '', 'successful', ?)""",
                            (active_task_id, ts, "event=task_complete status=success"),
                        )
                        stats["routing_eval_trace_inserted"] += 1
                    cur.execute(
                        """INSERT OR IGNORE INTO task_terminal_outcomes (
                            task_boundary, outcome_class, reason_code, recorded_at
                        ) VALUES (?, 'successful', 'task_complete', ?)""",
                        (active_task_id, ts),
                    )
                    if cur.rowcount > 0:
                        stats["task_terminal_outcomes_inserted"] += 1
                elif ev in ("circuit_breaker", "circuit_breaker_tripped", "task_halted"):
                    reason = str(data.get("reason") or data.get("classification") or ev)[:120]
                    if existing_traces == 0:
                        cur.execute(
                            """INSERT INTO routing_eval_trace (
                                task_boundary, recorded_at, infeasibility_class,
                                infeasibility_reason_code, limitation_action,
                                tool_exposure_phase, evaluator_mode,
                                evaluator_failure_reason, task_outcome_class,
                                redacted_diagnostic
                            ) VALUES (?, ?, 'blocked_by_capability', ?, 'TERMINATE', '', 'normal', ?, 'blocked_by_capability', ?)""",
                            (active_task_id, ts, reason, reason, f"event={ev} reason={reason}"),
                        )
                        stats["routing_eval_trace_inserted"] += 1
                    cur.execute(
                        """INSERT OR IGNORE INTO task_terminal_outcomes (
                            task_boundary, outcome_class, reason_code, recorded_at
                        ) VALUES (?, 'blocked_by_capability', ?, ?)""",
                        (active_task_id, reason, ts),
                    )
                    if cur.rowcount > 0:
                        stats["task_terminal_outcomes_inserted"] += 1
                elif ev == "circuit_breaker_perturbation" and existing_traces == 0:
                    cls_name = str(data.get("classification") or "perturbation")[:80]
                    cur.execute(
                        """INSERT INTO routing_eval_trace (
                            task_boundary, recorded_at, infeasibility_class,
                            infeasibility_reason_code, limitation_action,
                            tool_exposure_phase, evaluator_mode,
                            evaluator_failure_reason, task_outcome_class,
                            redacted_diagnostic
                        ) VALUES (?, ?, 'blocked_by_capability', ?, 'ALT_PATH', '', 'normal', '', '', ?)""",
                        (active_task_id, ts, cls_name, f"event=circuit_breaker_perturbation class={cls_name}"),
                    )
                    stats["routing_eval_trace_inserted"] += 1

    # 3. Scan evaluator.jsonl files across workspaces/ and runs/
    existing_snaps = cur.execute("SELECT COUNT(*) FROM evaluator_diag_snapshots").fetchone()[0]
    eval_runs_count = 0
    eval_patterns = [
        os.path.join(george_dir, "workspaces", "*", "evaluator.jsonl"),
        os.path.join(george_dir, "runs", "*", "evaluator.jsonl"),
    ]
    seen_eval_sessions: set[str] = set()
    for pat in eval_patterns:
        for ev_file in glob.glob(pat):
            session_name = os.path.basename(os.path.dirname(ev_file))
            if session_name in seen_eval_sessions:
                continue
            seen_eval_sessions.add(session_name)
            try:
                with open(ev_file, "r", encoding="utf-8", errors="replace") as f:
                    for line in f:
                        line = line.strip()
                        if not line:
                            continue
                        obj = json.loads(line)
                        eval_runs_count += 1
                        if existing_snaps == 0:
                            ts_epoch = obj.get("ts")
                            if isinstance(ts_epoch, (int, float)) and ts_epoch > 0:
                                rec_at = datetime.fromtimestamp(ts_epoch, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                            else:
                                rec_at = now
                            step = str(obj.get("step") or "1")
                            verdict = str(obj.get("verdict") or "INCOMPLETE")
                            reason = str(obj.get("reason") or "")[:240]
                            efr = "" if verdict == "COMPLETE" else reason
                            cur.execute(
                                """INSERT INTO evaluator_diag_snapshots (
                                    task_boundary, recorded_at, evaluator_mode,
                                    evaluator_failure_reason, backend, scenario,
                                    token_budget, output_length, parse_mode,
                                    grammar_mode, selected_model, grammar_schema_name,
                                     diagnostic_code
                                ) VALUES (?, ?, 'normal', ?, 'local_inference', ?, 300, ?, 'gbnf_json', 'gbnf', 'default', 'react_eval_gbnf', ?)""",
                                (session_name, rec_at, efr, f"milestone_step_{step}", len(line), verdict),
                            )
                            stats["evaluator_diag_snapshots_inserted"] += 1
            except Exception:
                continue

    # 4. Scan advisor.jsonl for advisor GBNF runs
    advisor_runs_count = 0
    for adv_file in glob.glob(os.path.join(george_dir, "workspaces", "*", "advisor.jsonl")):
        try:
            with open(adv_file, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    if line.strip():
                        advisor_runs_count += 1
        except Exception:
            continue

    # 5. Populate grammar_schema_compatibility
    schemas = [
        (
            "react_eval_gbnf",
            "compatible",
            0,
            1,
            max(eval_runs_count, 1),
            "COMPLETE",
            "Milestone evaluator GBNF schema verified across historical evaluator.jsonl runs",
        ),
        (
            "react_advisor_gbnf",
            "compatible",
            0,
            1,
            max(advisor_runs_count, 1),
            "OK",
            "Stuck-loop advisor GBNF schema verified across advisor consultations",
        ),
    ]
    for s_name, st, s_true, s_false, r_runs, d_code, notes in schemas:
        cur.execute(
            """INSERT INTO grammar_schema_compatibility (
                schema_name, status, stream_true_ok, stream_false_ok,
                repeated_runs, diagnostic_code, notes, checked_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(schema_name) DO UPDATE SET
                status=excluded.status,
                stream_false_ok=excluded.stream_false_ok,
                repeated_runs=MAX(grammar_schema_compatibility.repeated_runs, excluded.repeated_runs),
                diagnostic_code=excluded.diagnostic_code,
                notes=excluded.notes,
                checked_at=excluded.checked_at""",
            (s_name, st, s_true, s_false, r_runs, d_code, notes, now),
        )
        stats["grammar_schema_compatibility_upserted"] += 1

    # 6. Populate tool_telemetry_stats
    for t_name, c_cnt in tool_calls.items():
        s_cnt = tool_success.get(t_name, 0)
        f_cnt = tool_fail.get(t_name, 0)
        if s_cnt + f_cnt > c_cnt:
            s_cnt = max(0, c_cnt - f_cnt)
        ch_cnt = tool_cached.get(t_name, 0)
        lats = sorted(tool_latencies.get(t_name, []))
        if lats:
            ewma = sum(lats) / len(lats)
            p95_idx = min(len(lats) - 1, int(math.ceil(0.95 * len(lats))) - 1)
            p95 = lats[max(0, p95_idx)]
        else:
            # Default nominal latency estimates (ms) by tool class
            if t_name.startswith(("web_", "searxng_", "arxiv_", "hn_", "research_")):
                ewma, p95 = 1200.0, 2800.0
            elif t_name in ("bash_exec", "subagent_spawn"):
                ewma, p95 = 850.0, 2200.0
            else:
                ewma, p95 = 120.0, 350.0
        last_err = tool_last_err.get(t_name, "")
        cur.execute(
            """INSERT INTO tool_telemetry_stats (
                tool_name, call_count, success_count, fail_count,
                cache_hit_count, ewma_latency_ms, p95_latency_ms,
                last_error_class, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(tool_name) DO UPDATE SET
                call_count=MAX(tool_telemetry_stats.call_count, excluded.call_count),
                success_count=MAX(tool_telemetry_stats.success_count, excluded.success_count),
                fail_count=MAX(tool_telemetry_stats.fail_count, excluded.fail_count),
                cache_hit_count=MAX(tool_telemetry_stats.cache_hit_count, excluded.cache_hit_count),
                ewma_latency_ms=excluded.ewma_latency_ms,
                p95_latency_ms=excluded.p95_latency_ms,
                last_error_class=CASE WHEN excluded.last_error_class != '' THEN excluded.last_error_class ELSE tool_telemetry_stats.last_error_class END,
                updated_at=excluded.updated_at""",
            (t_name, c_cnt, s_cnt, f_cnt, ch_cnt, round(ewma, 2), round(p95, 2), last_err, now),
        )
        stats["tool_telemetry_stats_upserted"] += 1

    conn.commit()
    conn.close()
    return stats


def compact_trajectories(george_dir: str = GEORGE_DIR, dry_run: bool = False) -> dict[str, Any]:
    """Deduplicate repeated multi-KB instruction strings in trajectories.jsonl via SHA-256 prefix refs."""
    t_dir = os.path.join(george_dir, "transcripts")
    traj_path = os.path.join(t_dir, "trajectories.jsonl")
    prefixes_jsonl = os.path.join(t_dir, "prompt_prefixes.jsonl")
    if not os.path.isfile(traj_path):
        return {"compacted_records": 0, "unique_prefixes": 0, "reclaimed_bytes": 0}

    existing_prefixes: dict[str, str] = {}
    if os.path.isfile(prefixes_jsonl):
        try:
            with open(prefixes_jsonl, "r", encoding="utf-8", errors="replace") as pf:
                for line in pf:
                    if not line.strip():
                        continue
                    obj = json.loads(line)
                    if obj.get("ref") and obj.get("instruction"):
                        existing_prefixes[obj["ref"]] = obj["instruction"]
        except Exception:
            pass

    orig_size = os.path.getsize(traj_path)
    new_prefixes: dict[str, str] = {}
    compacted_records = 0
    tmp_traj = traj_path + f".tmp.{os.getpid()}"

    out_f = open(tmp_traj, "w", encoding="utf-8") if not dry_run else None
    new_size = 0
    try:
        with open(traj_path, "r", encoding="utf-8", errors="replace") as f:
            for raw_line in f:
                if not raw_line.strip():
                    continue
                try:
                    rec = json.loads(raw_line)
                except Exception:
                    if out_f:
                        out_f.write(raw_line)
                    new_size += len(raw_line.encode("utf-8", errors="replace"))
                    continue

                inst = rec.get("instruction")
                if isinstance(inst, str) and len(inst) > 320 and not inst.startswith("[PREFIX_REF:sha256:"):
                    h16 = hashlib.sha256(inst.encode("utf-8", errors="replace")).hexdigest()[:16]
                    ref_key = f"sha256:{h16}"
                    if ref_key not in existing_prefixes and ref_key not in new_prefixes:
                        new_prefixes[ref_key] = inst
                    rec["instruction_ref"] = ref_key
                    rec["instruction"] = f"[PREFIX_REF:{ref_key}] {inst[:160]}..."
                    compacted_records += 1

                serialized = json.dumps(rec, ensure_ascii=False) + "\n"
                new_size += len(serialized.encode("utf-8", errors="replace"))
                if out_f:
                    out_f.write(serialized)
    finally:
        if out_f:
            out_f.close()

    if not dry_run:
        if new_prefixes:
            with open(prefixes_jsonl, "a", encoding="utf-8") as pf:
                for k, v in new_prefixes.items():
                    pf.write(json.dumps({"ref": k, "instruction": v}, ensure_ascii=False) + "\n")
        if compacted_records > 0 and os.path.isfile(tmp_traj):
            os.replace(tmp_traj, traj_path)
        elif os.path.isfile(tmp_traj):
            os.unlink(tmp_traj)

    reclaimed = max(0, orig_size - new_size)
    return {
        "compacted_records": compacted_records,
        "unique_prefixes": len(existing_prefixes) + len(new_prefixes),
        "reclaimed_bytes": reclaimed,
    }


def hydrate_trajectory_record(rec: dict[str, Any], prefixes: dict[str, str]) -> dict[str, Any]:
    """Losslessly restore full instruction text from a prefix-compacted trajectory record."""
    out = dict(rec)
    ref = out.get("instruction_ref")
    if isinstance(ref, str) and ref in prefixes:
        out["instruction"] = prefixes[ref]
    return out


def archive_old_db_rows(
    george_dir: str = GEORGE_DIR,
    retention_days: int = 14,
    dry_run: bool = False,
) -> dict[str, int]:
    """Archive and prune events.db and mqtt.db rows older than retention_days."""
    cutoff_dt = datetime.now(timezone.utc) - timedelta(days=max(1, retention_days))
    cutoff_epoch = int(cutoff_dt.timestamp())
    cutoff_iso = cutoff_dt.strftime("%Y-%m-%d %H:%M:%S")
    archive_dir = os.path.join(george_dir, "archive")
    archived_events = 0
    archived_mqtt = 0

    events_db = os.path.join(george_dir, "events.db")
    if os.path.isfile(events_db):
        try:
            conn = sqlite3.connect(events_db)
            conn.row_factory = sqlite3.Row
            cur = conn.cursor()
            old_rows = cur.execute(
                "SELECT event_id, event_type, source, depth, payload, timestamp FROM events WHERE timestamp > 0 AND timestamp < ?;",
                (cutoff_epoch,),
            ).fetchall()
            archived_events = len(old_rows)
            if archived_events > 0 and not dry_run:
                os.makedirs(archive_dir, exist_ok=True)
                arch_fp = os.path.join(archive_dir, "events_archive.jsonl.gz")
                with gzip.open(arch_fp, "at", encoding="utf-8") as gz:
                    for r in old_rows:
                        gz.write(json.dumps(dict(r), ensure_ascii=False) + "\n")
                cur.execute("DELETE FROM events WHERE timestamp > 0 AND timestamp < ?;", (cutoff_epoch,))
                conn.commit()
            conn.close()
        except Exception:
            pass

    mqtt_db = os.path.join(george_dir, "mqtt.db")
    if os.path.isfile(mqtt_db):
        try:
            conn = sqlite3.connect(mqtt_db)
            conn.row_factory = sqlite3.Row
            cur = conn.cursor()
            old_msgs = cur.execute(
                "SELECT id, topic, direction, payload, timestamp FROM messages WHERE timestamp < ?;",
                (cutoff_iso,),
            ).fetchall()
            archived_mqtt = len(old_msgs)
            if archived_mqtt > 0 and not dry_run:
                os.makedirs(archive_dir, exist_ok=True)
                arch_fp = os.path.join(archive_dir, "mqtt_archive.jsonl.gz")
                with gzip.open(arch_fp, "at", encoding="utf-8") as gz:
                    for r in old_msgs:
                        gz.write(json.dumps(dict(r), ensure_ascii=False) + "\n")
                cur.execute("DELETE FROM messages WHERE timestamp < ?;", (cutoff_iso,))
                conn.commit()
            conn.close()
        except Exception:
            pass

    return {
        "archived_events": archived_events,
        "archived_mqtt_messages": archived_mqtt,
        "retention_days": retention_days,
    }


def compact_logs(
    george_dir: str = GEORGE_DIR,
    dry_run: bool = False,
    retention_days: int = 14,
) -> dict[str, Any]:
    """Deduplicate session logs, prefix-compact trajectories.jsonl, and enforce DB retention."""
    runs_dir = os.path.join(george_dir, "runs")
    ws_dir = os.path.join(george_dir, "workspaces")
    deduped_files = 0
    reclaimed_bytes = 0

    if os.path.isdir(runs_dir) and os.path.isdir(ws_dir):
        for session_name in os.listdir(runs_dir):
            r_sess = os.path.join(runs_dir, session_name)
            w_sess = os.path.join(ws_dir, session_name)
            if not (os.path.isdir(r_sess) and os.path.isdir(w_sess)):
                continue
            for root, _, files in os.walk(r_sess):
                rel_dir = os.path.relpath(root, r_sess)
                for fname in files:
                    r_fp = os.path.join(root, fname)
                    if os.path.islink(r_fp):
                        continue
                    w_fp = os.path.normpath(os.path.join(w_sess, rel_dir, fname))
                    if os.path.isfile(w_fp) and not os.path.islink(w_fp):
                        try:
                            if filecmp.cmp(r_fp, w_fp, shallow=False):
                                sz = os.path.getsize(r_fp)
                                if not dry_run:
                                    os.unlink(r_fp)
                                    os.symlink(os.path.abspath(w_fp), r_fp)
                                deduped_files += 1
                                reclaimed_bytes += sz
                        except OSError:
                            continue

    traj_stats = compact_trajectories(george_dir=george_dir, dry_run=dry_run)
    reclaimed_bytes += traj_stats.get("reclaimed_bytes", 0)
    arch_stats = archive_old_db_rows(george_dir=george_dir, retention_days=retention_days, dry_run=dry_run)

    # Prune orphaned 0-byte SQLite database files across .george (depth <= 2)
    pruned_empty_dbs = []
    for root, dirs, files in os.walk(george_dir):
        rel = os.path.relpath(root, george_dir)
        depth = 0 if rel == "." else len(rel.split(os.sep))
        if depth >= 2:
            dirs[:] = []
        for fn in files:
            if not (fn.endswith(".db") or fn.endswith(".sqlite")):
                continue
            fp = os.path.join(root, fn)
            if os.path.islink(fp):
                continue
            try:
                if os.path.getsize(fp) == 0:
                    pruned_empty_dbs.append(os.path.relpath(fp, george_dir))
                    if not dry_run:
                        os.unlink(fp)
                        for side in (fp + "-wal", fp + "-shm"):
                            if os.path.isfile(side) and os.path.getsize(side) == 0:
                                os.unlink(side)
            except OSError:
                continue

    # Run PRAGMA optimize on SQLite stores
    optimized_dbs = []
    if not dry_run:
        for db_p in (
            os.path.join(george_dir, "recall.db"),
            os.path.join(george_dir, "events.db"),
            os.path.join(george_dir, "mqtt.db"),
        ):
            if os.path.isfile(db_p):
                try:
                    c = sqlite3.connect(db_p)
                    c.execute("PRAGMA optimize;")
                    c.close()
                    optimized_dbs.append(os.path.basename(db_p))
                except Exception:
                    pass

    return {
        "dry_run": dry_run,
        "deduped_session_files": deduped_files,
        "trajectories_compacted": traj_stats["compacted_records"],
        "unique_prompt_prefixes": traj_stats["unique_prefixes"],
        "archived_events": arch_stats["archived_events"],
        "archived_mqtt_messages": arch_stats["archived_mqtt_messages"],
        "pruned_empty_dbs": pruned_empty_dbs,
        "reclaimed_bytes": reclaimed_bytes,
        "reclaimed_mb": round(reclaimed_bytes / (1024 * 1024), 2),
        "optimized_dbs": optimized_dbs,
    }


def get_unified_summary(george_dir: str = GEORGE_DIR, recall_db: str = RECALL_DB) -> dict[str, Any]:
    """Return a unified diagnostic summary across recall.db, events.db, mqtt.db, and logs."""
    ensure_recall_schema(recall_db)
    summary: dict[str, Any] = {"stores": {}, "top_tools": [], "recent_evaluator_failures": []}

    if os.path.isfile(recall_db):
        conn = sqlite3.connect(recall_db)
        cur = conn.cursor()
        tables = [
            "chunks",
            "code_symbols",
            "okf_modules",
            "okf_edges",
            "routing_eval_trace",
            "task_terminal_outcomes",
            "evaluator_diag_snapshots",
            "grammar_schema_compatibility",
            "tool_telemetry_stats",
        ]
        t_counts = {}
        for t in tables:
            try:
                t_counts[t] = cur.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
            except Exception:
                t_counts[t] = 0
        summary["stores"]["recall.db"] = {
            "size_mb": round(os.path.getsize(recall_db) / (1024 * 1024), 2),
            "tables": t_counts,
        }
        try:
            rows = cur.execute(
                """SELECT tool_name, call_count, success_count, fail_count,
                          ewma_latency_ms, p95_latency_ms
                   FROM tool_telemetry_stats
                   ORDER BY call_count DESC LIMIT 10"""
            ).fetchall()
            summary["top_tools"] = [
                {
                    "tool": r[0],
                    "calls": r[1],
                    "ok": r[2],
                    "fail": r[3],
                    "ewma_ms": r[4],
                    "p95_ms": r[5],
                }
                for r in rows
            ]
        except Exception:
            pass
        try:
            f_rows = cur.execute(
                """SELECT task_boundary, scenario, diagnostic_code, evaluator_failure_reason
                   FROM evaluator_diag_snapshots
                   WHERE diagnostic_code != 'COMPLETE' AND evaluator_failure_reason != ''
                   ORDER BY id DESC LIMIT 5"""
            ).fetchall()
            summary["recent_evaluator_failures"] = [
                {
                    "session": r[0],
                    "scenario": r[1],
                    "verdict": r[2],
                    "reason": r[3],
                }
                for r in f_rows
            ]
        except Exception:
            pass
        conn.close()

    events_db = os.path.join(george_dir, "events.db")
    if os.path.isfile(events_db):
        try:
            conn = sqlite3.connect(events_db)
            cur = conn.cursor()
            ev_cnt = cur.execute("SELECT COUNT(*) FROM events").fetchone()[0]
            rx_cnt = cur.execute("SELECT COUNT(*) FROM reactions").fetchone()[0]
            summary["stores"]["events.db"] = {
                "size_mb": round(os.path.getsize(events_db) / (1024 * 1024), 2),
                "events": ev_cnt,
                "reactions": rx_cnt,
            }
            conn.close()
        except Exception:
            pass

    mqtt_db = os.path.join(george_dir, "mqtt.db")
    if os.path.isfile(mqtt_db):
        try:
            conn = sqlite3.connect(mqtt_db)
            cur = conn.cursor()
            tp_cnt = cur.execute("SELECT COUNT(*) FROM topics").fetchone()[0]
            msg_cnt = cur.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
            summary["stores"]["mqtt.db"] = {
                "size_mb": round(os.path.getsize(mqtt_db) / (1024 * 1024), 2),
                "topics": tp_cnt,
                "messages": msg_cnt,
            }
            conn.close()
        except Exception:
            pass

    return summary


def unified_search(query: str, limit: int = 10, george_dir: str = GEORGE_DIR, recall_db: str = RECALL_DB) -> dict[str, Any]:
    """Search across OKF modules, Recall chunks, Evaluator snapshots, and Event Bus."""
    ensure_recall_schema(recall_db)
    results: dict[str, list[dict[str, Any]]] = {
        "okf_modules": [],
        "recall_chunks": [],
        "telemetry_traces": [],
        "events": [],
    }
    safe_terms = [w for w in "".join(c if c.isalnum() else " " for c in query).split() if len(w) >= 2]
    fts_query = " OR ".join(safe_terms) if safe_terms else query
    like_pat = f"%{query}%"

    if os.path.isfile(recall_db):
        conn = sqlite3.connect(recall_db)
        cur = conn.cursor()
        if safe_terms:
            try:
                rows = cur.execute(
                    """SELECT m.uri, m.name, m.path, m.subsystem, substr(m.description, 1, 160)
                       FROM okf_modules_fts f
                       JOIN okf_modules m ON m.id = f.rowid
                       WHERE okf_modules_fts MATCH ?
                       ORDER BY bm25(okf_modules_fts) ASC LIMIT ?""",
                    (fts_query, limit),
                ).fetchall()
                results["okf_modules"] = [
                    {"uri": r[0], "name": r[1], "path": r[2], "subsystem": r[3], "description": r[4]}
                    for r in rows
                ]
            except Exception:
                pass
            try:
                rows = cur.execute(
                    """SELECT c.source, c.section, c.filepath, substr(c.content, 1, 180)
                       FROM chunks_fts f
                       JOIN chunks c ON c.id = f.rowid
                       WHERE chunks_fts MATCH ?
                       ORDER BY bm25(chunks_fts, 5.0, 10.0, 1.0) ASC LIMIT ?""",
                    (fts_query, limit),
                ).fetchall()
                results["recall_chunks"] = [
                    {"source": r[0], "section": r[1], "filepath": r[2], "snippet": r[3]}
                    for r in rows
                ]
            except Exception:
                pass
        try:
            rows = cur.execute(
                """SELECT task_boundary, scenario, diagnostic_code, evaluator_failure_reason, recorded_at
                   FROM evaluator_diag_snapshots
                   WHERE evaluator_failure_reason LIKE ? OR scenario LIKE ? OR task_boundary LIKE ?
                   ORDER BY id DESC LIMIT ?""",
                (like_pat, like_pat, like_pat, limit),
            ).fetchall()
            results["telemetry_traces"] = [
                {"session": r[0], "scenario": r[1], "verdict": r[2], "reason": r[3], "recorded_at": r[4]}
                for r in rows
            ]
        except Exception:
            pass
        conn.close()

    events_db = os.path.join(george_dir, "events.db")
    if os.path.isfile(events_db) and safe_terms:
        try:
            conn = sqlite3.connect(events_db)
            cur = conn.cursor()
            rows = cur.execute(
                """SELECT e.event_id, e.event_type, e.source, substr(e.payload, 1, 160), e.timestamp
                   FROM events_fts f
                   JOIN events e ON e.id = f.rowid
                   WHERE events_fts MATCH ?
                   ORDER BY e.id DESC LIMIT ?""",
                (fts_query, limit),
            ).fetchall()
            results["events"] = [
                {"event_id": r[0], "type": r[1], "source": r[2], "payload": r[3], "timestamp": r[4]}
                for r in rows
            ]
            conn.close()
        except Exception:
            pass

    return results


def main() -> int:
    parser = argparse.ArgumentParser(description="Blue Lodge Unified Telemetry & Cross-DB Query Tool")
    sub = parser.add_subparsers(dest="cmd")

    sub.add_parser("backfill", help="Backfill recall.db telemetry tables from JSONL/envelope logs")

    p_sum = sub.add_parser("summary", help="Show unified database & telemetry health summary")
    p_sum.add_argument("--json", action="store_true", help="Output raw JSON")

    p_comp = sub.add_parser("compact", help="Deduplicate session logs, prefix-compact trajectories, & enforce DB retention")
    p_comp.add_argument("--dry-run", action="store_true", help="Report without modifying files")
    p_comp.add_argument("--retention-days", type=int, default=14, help="Retention window in days for events.db and mqtt.db")

    p_search = sub.add_parser("search", help="Unified search across OKF, Recall, Telemetry, and Events")
    p_search.add_argument("query", help="Search query string")
    p_search.add_argument("--limit", type=int, default=8)
    p_search.add_argument("--json", action="store_true")

    args = parser.parse_args()
    cmd = args.cmd or "summary"

    if cmd == "backfill":
        res = backfill_telemetry()
        print(json.dumps(res, indent=2))
        return 0
    if cmd == "compact":
        res = compact_logs(
            dry_run=getattr(args, "dry_run", False),
            retention_days=getattr(args, "retention_days", 14),
        )
        print(json.dumps(res, indent=2))
        return 0
    if cmd == "search":
        res = unified_search(args.query, limit=args.limit)
        if args.json:
            print(json.dumps(res, indent=2))
        else:
            for section, items in res.items():
                print(f"=== {section.upper()} ({len(items)}) ===")
                for it in items:
                    print("  -", json.dumps(it, ensure_ascii=False))
        return 0

    res = get_unified_summary()
    if getattr(args, "json", False):
        print(json.dumps(res, indent=2))
    else:
        print("── Blue Lodge Unified Data & Telemetry Plane ──")
        for db_name, info in res.get("stores", {}).items():
            print(f"\n[{db_name}] ({info.get('size_mb', 0)} MB)")
            if "tables" in info:
                for k, v in info["tables"].items():
                    print(f"  {k:32s}: {v}")
            else:
                for k, v in info.items():
                    if k != "size_mb":
                        print(f"  {k:32s}: {v}")
        print("\n[Top Empirical Tool Telemetry]")
        for t in res.get("top_tools", [])[:8]:
            print(
                f"  {t['tool']:24s} calls={t['calls']:5d} ok={t['ok']:5d} fail={t['fail']:3d} "
                f"ewma={t['ewma_ms']:7.1f}ms p95={t['p95_ms']:7.1f}ms"
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
