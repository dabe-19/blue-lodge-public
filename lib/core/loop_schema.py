#!/usr/bin/env python3
"""Blue Lodge Sovereign Agentic Loop Protocol (ALP v1) — Schema, Resolver & Template Helper.

Provides deterministic, zero-dependency JSON validation, layered loop resolution
(override > repo/module source), path-boundary enforcement, template rendering,
and verification gate evaluation for both Bash (`lib/core/loop_engine.sh`) and
Rust (`web/src/routes/loops.rs`).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{1,48}$")
TOOL_RE = re.compile(r"^[a-zA-Z0-9_.*-]{1,80}$")
BUNDLE_RE = re.compile(r"^\+?[a-z0-9_-]{1,40}$")
VALID_PHASE_KINDS = {"fifo_parallel", "fifo_pipe", "react", "delegate_script"}
VALID_GATE_TYPES = {"none", "json_file", "markdown_file", "research_verifier"}
VALID_GATE_ON_FAIL = {"retry", "quarantine", "warn", "fail"}
VALID_INPUT_TYPES = {"string", "text", "number", "boolean", "select", "images", "json"}

DEFAULT_MAX_TURNS = 200
MAX_ALLOWED_TURNS = 500


def get_roots() -> Tuple[Path, Path]:
    lodge = Path(os.environ.get("LODGE_DIR") or Path(__file__).resolve().parents[2]).resolve()
    george = Path(os.environ.get("GEORGE_DIR") or (lodge / ".george")).resolve()
    return lodge, george


def valid_id(val: str) -> bool:
    return bool(isinstance(val, str) and ID_RE.match(val))


def safe_under(path: Path, base: Path) -> bool:
    """Verify resolved path stays strictly inside base directory (trailing sep check)."""
    try:
        base_real = os.path.realpath(str(base))
        target_real = os.path.realpath(str(path))
        return target_real == base_real or target_real.startswith(base_real + os.sep)
    except Exception:
        return False


def normalize_owner(owner: str) -> str:
    raw = (owner or "").strip().lower()
    if raw in ("heartwood", "core", "blue-lodge", "bluelodge"):
        return "heartwood"
    return raw


def loop_dirs_for_owner(owner: str, lodge: Path, george: Path) -> Tuple[Path, Path, str]:
    """Return (source_dir, override_dir, owner_type) for an owner."""
    norm = normalize_owner(owner)
    if norm == "heartwood":
        return (
            lodge / "data" / "workflows" / "loops",
            george / "workflows" / "loops",
            "heartwood",
        )
    if not valid_id(norm):
        raise ValueError(f"invalid owner id: {owner!r}")
    mod_dir = george / "modules" / norm
    if not safe_under(mod_dir, george / "modules"):
        raise ValueError("owner escapes modules directory")
    data_dir = george / "module_data" / norm
    if not safe_under(data_dir, george / "module_data"):
        raise ValueError("owner escapes module_data directory")
    return (mod_dir / "workflows", data_dir / "workflows", "module")


def validate_loop(data: Any, expected_owner: Optional[str] = None, expected_id: Optional[str] = None) -> Tuple[bool, List[str], Optional[Dict[str, Any]]]:
    errors: List[str] = []
    if not isinstance(data, dict):
        return False, ["Loop definition must be a JSON object"], None

    sv = data.get("schema_version", 1)
    if sv != 1:
        errors.append(f"Unsupported schema_version: {sv!r} (expected 1)")

    lid = expected_id or data.get("id")
    if not valid_id(str(lid or "")):
        errors.append(f"Invalid loop id: {lid!r} (must match ^[a-z0-9][a-z0-9_-]{{1,48}}$)")

    owner = normalize_owner(expected_owner or str(data.get("owner") or "heartwood"))
    if owner != "heartwood" and not valid_id(owner):
        errors.append(f"Invalid owner: {owner!r}")

    name = str(data.get("name") or "").strip()
    if not name or len(name) > 120:
        errors.append("Field 'name' must be a non-empty string (<=120 chars)")

    desc = str(data.get("description") or "").strip()
    if len(desc) > 1000:
        errors.append("Field 'description' exceeds 1000 characters")

    defaults_in = data.get("defaults") or {}
    if not isinstance(defaults_in, dict):
        errors.append("Field 'defaults' must be an object")
        defaults_in = {}

    try:
        max_turns = int(defaults_in.get("max_turns", DEFAULT_MAX_TURNS))
    except Exception:
        max_turns = -1
    if max_turns < 1 or max_turns > MAX_ALLOWED_TURNS:
        errors.append(f"defaults.max_turns must be between 1 and {MAX_ALLOWED_TURNS} (got {defaults_in.get('max_turns')!r})")

    try:
        ipc_priority = int(defaults_in.get("ipc_priority", 100))
    except Exception:
        ipc_priority = -1
    if ipc_priority < 10 or ipc_priority > 100:
        errors.append(f"defaults.ipc_priority must be 10..100 (got {defaults_in.get('ipc_priority')!r})")

    try:
        fifo_window = int(defaults_in.get("fifo_window", 16))
    except Exception:
        fifo_window = -1
    if fifo_window < 2 or fifo_window > 256:
        errors.append(f"defaults.fifo_window must be 2..256 (got {defaults_in.get('fifo_window')!r})")

    try:
        tool_timeout = int(defaults_in.get("tool_timeout_sec", 180))
    except Exception:
        tool_timeout = -1
    if tool_timeout < 5 or tool_timeout > 3600:
        errors.append("defaults.tool_timeout_sec must be 5..3600")

    output_artifact = str(defaults_in.get("output_artifact") or "result.json").strip()
    if ".." in output_artifact or output_artifact.startswith("/") or "\\" in output_artifact:
        errors.append(f"defaults.output_artifact must be a relative filename without path traversal: {output_artifact!r}")

    tools_in = data.get("tools") or {}
    if not isinstance(tools_in, dict):
        errors.append("Field 'tools' must be an object")
        tools_in = {}
    bundles = []
    for b in (tools_in.get("bundles") or []):
        bs = str(b).strip()
        if not BUNDLE_RE.match(bs):
            errors.append(f"Invalid tool bundle name: {bs!r}")
        else:
            bundles.append(bs)
    allow_tools = []
    for t in (tools_in.get("allow") or []):
        ts = str(t).strip()
        if not TOOL_RE.match(ts):
            errors.append(f"Invalid tool name in tools.allow: {ts!r}")
        else:
            allow_tools.append(ts)
    deny_tools = []
    for t in (tools_in.get("deny") or []):
        ts = str(t).strip()
        if not TOOL_RE.match(ts):
            errors.append(f"Invalid tool name in tools.deny: {ts!r}")
        else:
            deny_tools.append(ts)

    inputs_norm: List[Dict[str, Any]] = []
    for idx, inp in enumerate(data.get("inputs") or []):
        if not isinstance(inp, dict):
            errors.append(f"inputs[{idx}] must be an object")
            continue
        iname = str(inp.get("name") or "").strip()
        if not valid_id(iname):
            errors.append(f"inputs[{idx}].name invalid: {iname!r}")
            continue
        itype = str(inp.get("type") or "string").strip().lower()
        if itype not in VALID_INPUT_TYPES:
            errors.append(f"inputs[{idx}].type invalid: {itype!r}")
            continue
        entry: Dict[str, Any] = {
            "name": iname,
            "type": itype,
            "label": str(inp.get("label") or iname)[:80],
            "required": bool(inp.get("required", False)),
        }
        if "default" in inp:
            entry["default"] = inp["default"]
        if "placeholder" in inp:
            entry["placeholder"] = str(inp["placeholder"])[:160]
        if "options" in inp and isinstance(inp["options"], list):
            entry["options"] = [str(o)[:80] for o in inp["options"][:30]]
        inputs_norm.append(entry)

    phases_in = data.get("phases")
    if not isinstance(phases_in, list) or len(phases_in) == 0:
        errors.append("Field 'phases' must be a non-empty array")
        phases_in = []

    phases_norm: List[Dict[str, Any]] = []
    seen_pids = set()
    for idx, ph in enumerate(phases_in):
        if not isinstance(ph, dict):
            errors.append(f"phases[{idx}] must be an object")
            continue
        pid = str(ph.get("id") or f"phase_{idx + 1}").strip()
        if not valid_id(pid):
            errors.append(f"phases[{idx}].id invalid: {pid!r}")
            continue
        if pid in seen_pids:
            errors.append(f"Duplicate phase id: {pid!r}")
            continue
        seen_pids.add(pid)

        pkind = str(ph.get("kind") or "react").strip().lower()
        if pkind not in VALID_PHASE_KINDS:
            errors.append(f"phases[{idx}].kind invalid: {pkind!r} (allowed: {sorted(VALID_PHASE_KINDS)})")
            continue

        pname = str(ph.get("name") or pid).strip()[:120]
        penabled = bool(ph.get("enabled", True))
        ph_out: Dict[str, Any] = {
            "id": pid,
            "name": pname,
            "kind": pkind,
            "enabled": penabled,
        }

        if "description" in ph:
            ph_out["description"] = str(ph.get("description") or "")[:400]
        if "continue_on_error" in ph:
            ph_out["continue_on_error"] = bool(ph["continue_on_error"])
        if "timeout_sec" in ph:
            try:
                ts = int(ph["timeout_sec"])
                if ts < 5 or ts > 3600:
                    errors.append(f"phases[{idx}].timeout_sec must be 5..3600")
                else:
                    ph_out["timeout_sec"] = ts
            except Exception:
                errors.append(f"phases[{idx}].timeout_sec must be an integer")

        if pkind == "react":
            if "max_turns" in ph and ph["max_turns"] is not None:
                try:
                    pmt = int(ph["max_turns"])
                    if pmt < 1 or pmt > MAX_ALLOWED_TURNS:
                        errors.append(f"phases[{idx}].max_turns must be 1..{MAX_ALLOWED_TURNS}")
                    else:
                        ph_out["max_turns"] = pmt
                except Exception:
                    errors.append(f"phases[{idx}].max_turns must be an integer")
            else:
                ph_out["max_turns"] = max_turns
            tf = str(ph.get("tool_filter") or "default").strip()
            if not re.match(r"^[a-zA-Z0-9_,-]{1,64}$", tf):
                errors.append(f"phases[{idx}].tool_filter invalid: {tf!r}")
            ph_out["tool_filter"] = tf
            p_allow = []
            for t in (ph.get("tools_allow") or []):
                ts = str(t).strip()
                if not TOOL_RE.match(ts):
                    errors.append(f"phases[{idx}].tools_allow invalid tool: {ts!r}")
                else:
                    p_allow.append(ts)
            ph_out["tools_allow"] = p_allow
            ph_out["prompt_template"] = str(ph.get("prompt_template") or "")
            if "prompt_append" in ph:
                ph_out["prompt_append"] = str(ph.get("prompt_append") or "")

        elif pkind in ("fifo_parallel", "fifo_pipe"):
            tasks_in = ph.get("tasks") or []
            if not isinstance(tasks_in, list):
                errors.append(f"phases[{idx}].tasks must be an array")
                tasks_in = []
            tasks_norm = []
            for tidx, tk in enumerate(tasks_in):
                if not isinstance(tk, dict):
                    errors.append(f"phases[{idx}].tasks[{tidx}] must be an object")
                    continue
                tid = str(tk.get("id") or f"task_{tidx + 1}").strip()
                ttool = str(tk.get("tool") or "").strip()
                if not valid_id(tid):
                    errors.append(f"phases[{idx}].tasks[{tidx}].id invalid: {tid!r}")
                    continue
                if not TOOL_RE.match(ttool) or "*" in ttool:
                    errors.append(f"phases[{idx}].tasks[{tidx}].tool invalid: {ttool!r}")
                    continue
                targs = tk.get("args_template") if "args_template" in tk else tk.get("args", {})
                if not isinstance(targs, dict):
                    errors.append(f"phases[{idx}].tasks[{tidx}].args_template must be an object")
                    targs = {}
                tk_out = {
                    "id": tid,
                    "tool": ttool,
                    "args_template": targs,
                    "output_key": str(tk.get("output_key") or tid).strip(),
                }
                if "when" in tk and tk["when"]:
                    tk_out["when"] = str(tk["when"]).strip()[:120]
                tasks_norm.append(tk_out)
            ph_out["tasks"] = tasks_norm

        elif pkind == "delegate_script":
            handler = str(ph.get("handler") or "").strip()
            if not re.match(r"^[a-zA-Z0-9_.:/-]{1,120}$", handler) or ".." in handler or handler.startswith("/"):
                errors.append(f"phases[{idx}].handler invalid: {handler!r}")
            ph_out["handler"] = handler
            if "prompt_append" in ph:
                ph_out["prompt_append"] = str(ph.get("prompt_append") or "")
            if "config" in ph and isinstance(ph["config"], dict):
                ph_out["config"] = ph["config"]

        gate_in = ph.get("gate")
        if gate_in is not None:
            if not isinstance(gate_in, dict):
                errors.append(f"phases[{idx}].gate must be an object")
            else:
                gtype = str(gate_in.get("type") or "none").strip().lower()
                if gtype not in VALID_GATE_TYPES:
                    errors.append(f"phases[{idx}].gate.type invalid: {gtype!r}")
                gonfail = str(gate_in.get("on_fail") or "warn").strip().lower()
                if gonfail not in VALID_GATE_ON_FAIL:
                    errors.append(f"phases[{idx}].gate.on_fail invalid: {gonfail!r}")
                gpath = str(gate_in.get("path") or output_artifact).strip()
                if ".." in gpath or gpath.startswith("/") or "\\" in gpath:
                    errors.append(f"phases[{idx}].gate.path invalid: {gpath!r}")
                try:
                    mret = int(gate_in.get("max_retries", 1))
                except Exception:
                    mret = 1
                mret = max(0, min(5, mret))
                gate_norm: Dict[str, Any] = {
                    "type": gtype,
                    "path": gpath,
                    "on_fail": gonfail,
                    "max_retries": mret,
                }
                if isinstance(gate_in.get("required_keys"), list):
                    gate_norm["required_keys"] = [str(k) for k in gate_in["required_keys"][:32]]
                if "min_words" in gate_in:
                    try:
                        gate_norm["min_words"] = max(0, int(gate_in["min_words"]))
                    except Exception:
                        pass
                ph_out["gate"] = gate_norm

        phases_norm.append(ph_out)

    if errors:
        return False, errors, None

    normalized: Dict[str, Any] = {
        "schema_version": 1,
        "id": str(lid),
        "name": name,
        "owner": owner,
        "owner_type": "heartwood" if owner == "heartwood" else "module",
        "category": str(data.get("category") or ("core" if owner == "heartwood" else "module")).strip()[:40],
        "version": str(data.get("version") or "1.0.0").strip()[:24],
        "description": desc,
        "defaults": {
            "max_turns": max_turns,
            "ipc_priority": ipc_priority,
            "fifo_window": fifo_window,
            "tool_timeout_sec": tool_timeout,
            "require_result_json": bool(defaults_in.get("require_result_json", True)),
            "output_artifact": output_artifact,
        },
        "inputs": inputs_norm,
        "tools": {
            "bundles": bundles,
            "allow": allow_tools,
            "deny": deny_tools,
        },
        "phases": phases_norm,
    }
    if "runner" in data and isinstance(data["runner"], str):
        runner_val = data["runner"].strip()
        if re.match(r"^[a-z0-9_-]{1,40}$", runner_val):
            normalized["runner"] = runner_val
    return True, [], normalized


def _load_json_safe(path: Path) -> Optional[Dict[str, Any]]:
    try:
        with open(path, "r", encoding="utf-8") as f:
            obj = json.load(f)
        return obj if isinstance(obj, dict) else None
    except Exception:
        return None


def _discover_owners(lodge: Path, george: Path, filter_owner: Optional[str]) -> List[str]:
    if filter_owner:
        return [normalize_owner(filter_owner)]
    owners = ["heartwood"]
    mods_dir = george / "modules"
    if mods_dir.is_dir():
        for entry in sorted(mods_dir.iterdir()):
            if entry.is_dir() and valid_id(entry.name) and (entry / "module.json").is_file():
                owners.append(entry.name)
    return owners


def list_loops(lodge: Path, george: Path, filter_owner: Optional[str] = None) -> List[Dict[str, Any]]:
    results: List[Dict[str, Any]] = []
    for owner in _discover_owners(lodge, george, filter_owner):
        try:
            src_dir, ovr_dir, owner_type = loop_dirs_for_owner(owner, lodge, george)
        except ValueError:
            continue

        found: Dict[str, Dict[str, Optional[Path]]] = {}
        if src_dir.is_dir():
            for f in sorted(src_dir.glob("*.loop.json")):
                lid = f.name[:-len(".loop.json")]
                if valid_id(lid):
                    found.setdefault(lid, {"source": None, "override": None})["source"] = f
        if ovr_dir.is_dir():
            for f in sorted(ovr_dir.glob("*.loop.json")):
                lid = f.name[:-len(".loop.json")]
                if valid_id(lid):
                    found.setdefault(lid, {"source": None, "override": None})["override"] = f

        for lid, paths in sorted(found.items()):
            active_path = paths["override"] or paths["source"]
            if not active_path:
                continue
            raw = _load_json_safe(active_path)
            if not raw:
                continue
            phases = raw.get("phases") or []
            fifo_phases = sum(1 for p in phases if isinstance(p, dict) and p.get("kind") in ("fifo_parallel", "fifo_pipe") and p.get("enabled", True))
            react_phases = sum(1 for p in phases if isinstance(p, dict) and p.get("kind") == "react" and p.get("enabled", True))
            defaults = raw.get("defaults") or {}
            tools = raw.get("tools") or {}
            results.append({
                "id": lid,
                "owner": owner,
                "owner_type": owner_type,
                "name": raw.get("name", lid),
                "description": raw.get("description", ""),
                "category": raw.get("category", owner_type),
                "version": raw.get("version", "1.0.0"),
                "runner": raw.get("runner", "loop_engine"),
                "max_turns": int(defaults.get("max_turns", DEFAULT_MAX_TURNS)),
                "ipc_priority": int(defaults.get("ipc_priority", 100)),
                "phase_count": len(phases),
                "enabled_phase_count": sum(1 for p in phases if isinstance(p, dict) and p.get("enabled", True)),
                "fifo_phases": fifo_phases,
                "react_phases": react_phases,
                "tool_count": len(tools.get("allow") or []),
                "has_override": paths["override"] is not None,
                "is_custom": paths["source"] is None and paths["override"] is not None,
                "source_path": str(paths["source"]) if paths["source"] else None,
                "override_path": str(paths["override"]) if paths["override"] else None,
                "active_path": str(active_path),
            })
    return results


def available_tools_for_owner(owner: str, lodge: Path, george: Path) -> Dict[str, Any]:
    norm = normalize_owner(owner)
    core_tools: List[Dict[str, str]] = []
    module_tools: List[Dict[str, str]] = []

    core_schema = lodge / "data" / "schemas" / "native_tools.json"
    if core_schema.is_file():
        try:
            for item in json.load(open(core_schema, "r", encoding="utf-8")):
                fn = item.get("function") or {}
                tname = fn.get("name")
                if tname:
                    core_tools.append({
                        "name": tname,
                        "description": str(fn.get("description") or "")[:160],
                        "scope": "core",
                    })
        except Exception:
            pass

    if norm != "heartwood" and valid_id(norm):
        mj_path = george / "modules" / norm / "module.json"
        if mj_path.is_file():
            mj = _load_json_safe(mj_path) or {}
            ts_rel = (mj.get("provides") or {}).get("tools_schema")
            if ts_rel:
                ts_path = george / "modules" / norm / ts_rel
                if ts_path.is_file() and safe_under(ts_path, george / "modules" / norm):
                    try:
                        for item in json.load(open(ts_path, "r", encoding="utf-8")):
                            fn = item.get("function") or {}
                            tname = fn.get("name")
                            if tname:
                                module_tools.append({
                                    "name": tname,
                                    "description": str(fn.get("description") or "")[:160],
                                    "scope": norm,
                                })
                    except Exception:
                        pass

    core_tools.sort(key=lambda x: x["name"])
    module_tools.sort(key=lambda x: x["name"])
    return {"owner": norm, "module_tools": module_tools, "core_tools": core_tools}


def resolve_loop(owner: str, loop_id: str, lodge: Path, george: Path) -> Optional[Dict[str, Any]]:
    norm = normalize_owner(owner)
    if not valid_id(loop_id):
        return None
    src_dir, ovr_dir, owner_type = loop_dirs_for_owner(norm, lodge, george)
    src_path = src_dir / f"{loop_id}.loop.json"
    ovr_path = ovr_dir / f"{loop_id}.loop.json"
    if not safe_under(src_path, src_dir) or not safe_under(ovr_path, ovr_dir):
        return None

    src_obj = _load_json_safe(src_path) if src_path.is_file() else None
    ovr_obj = _load_json_safe(ovr_path) if ovr_path.is_file() else None
    active_obj = ovr_obj or src_obj
    if not active_obj:
        return None

    return {
        "owner": norm,
        "owner_type": owner_type,
        "id": loop_id,
        "has_override": ovr_obj is not None,
        "is_custom": src_obj is None and ovr_obj is not None,
        "source_path": str(src_path) if src_obj is not None else None,
        "override_path": str(ovr_path) if ovr_obj is not None else None,
        "active_path": str(ovr_path if ovr_obj is not None else src_path),
        "loop": active_obj,
        "source_loop": src_obj,
        "available_tools": available_tools_for_owner(norm, lodge, george),
    }


def _lookup_path(ctx: Dict[str, Any], expr: str) -> Any:
    cur: Any = ctx
    for part in expr.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        elif isinstance(cur, list):
            try:
                cur = cur[int(part)]
            except Exception:
                return None
        else:
            return None
    return cur


TEMPLATE_TOKEN_RE = re.compile(r"\{\{\s*([a-zA-Z0-9_.-]+)(?:\s*\|\s*([^}]+))?\s*\}\}")


def render_value(val: Any, ctx: Dict[str, Any]) -> Any:
    if isinstance(val, dict):
        return {k: render_value(v, ctx) for k, v in val.items()}
    if isinstance(val, list):
        return [render_value(v, ctx) for v in val]
    if not isinstance(val, str):
        return val

    # Exact single-placeholder expression preserves non-string types (lists, numbers, dicts)
    m_full = TEMPLATE_TOKEN_RE.fullmatch(val.strip())
    if m_full:
        key, default_raw = m_full.group(1), m_full.group(2)
        found = _lookup_path(ctx, key)
        if found is not None and found != "":
            return found
        if default_raw is not None:
            ds = default_raw.strip()
            try:
                return json.loads(ds)
            except Exception:
                return ds.strip("\"'")
        return ""

    def repl(m: re.Match[str]) -> str:
        key, default_raw = m.group(1), m.group(2)
        found = _lookup_path(ctx, key)
        if found is None or found == "":
            if default_raw is not None:
                return default_raw.strip().strip("\"'")
            return ""
        if isinstance(found, (dict, list)):
            return json.dumps(found)
        return str(found)

    return TEMPLATE_TOKEN_RE.sub(repl, val)


def check_condition(expr: Optional[str], ctx: Dict[str, Any]) -> bool:
    if not expr:
        return True
    neg = False
    clean = expr.strip()
    if clean.startswith("!"):
        neg = True
        clean = clean[1:].strip()
    val = _lookup_path(ctx, clean)
    truthy = bool(val)
    return (not truthy) if neg else truthy


def check_gate(sandbox_dir: Path, gate: Dict[str, Any]) -> Dict[str, Any]:
    gtype = str(gate.get("type") or "none").lower()
    if gtype == "none":
        return {"passed": True, "reason": "no gate"}

    rel_path = str(gate.get("path") or "result.json").strip()
    target = (sandbox_dir / rel_path).resolve()
    if not safe_under(target, sandbox_dir):
        return {"passed": False, "reason": f"gate path escapes sandbox: {rel_path}"}
    if not target.is_file():
        return {"passed": False, "reason": f"expected artifact missing: {rel_path}"}

    if gtype == "json_file":
        try:
            obj = json.load(open(target, "r", encoding="utf-8"))
        except Exception as e:
            return {"passed": False, "reason": f"{rel_path} is not valid JSON: {e}"}
        if not isinstance(obj, dict):
            return {"passed": False, "reason": f"{rel_path} root must be a JSON object"}
        missing = [k for k in (gate.get("required_keys") or []) if k not in obj or obj[k] is None]
        if missing:
            return {"passed": False, "reason": f"{rel_path} missing required keys: {', '.join(missing)}"}
        return {"passed": True, "reason": f"{rel_path} verified ({len(obj)} keys)"}

    if gtype == "markdown_file":
        try:
            text = open(target, "r", encoding="utf-8").read()
        except Exception as e:
            return {"passed": False, "reason": f"failed to read {rel_path}: {e}"}
        words = len(text.split())
        min_words = int(gate.get("min_words") or 0)
        if words < min_words:
            return {"passed": False, "reason": f"{rel_path} too short ({words} words < {min_words})"}
        return {"passed": True, "reason": f"{rel_path} verified ({words} words)"}

    return {"passed": True, "reason": f"gate {gtype} delegated"}


def main() -> int:
    lodge, george = get_roots()
    parser = argparse.ArgumentParser(description="Blue Lodge ALP v1 Loop Schema & Resolver")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_list = sub.add_parser("list")
    p_list.add_argument("--owner", default=None)

    p_res = sub.add_parser("resolve")
    p_res.add_argument("owner")
    p_res.add_argument("loop_id")

    p_rpath = sub.add_parser("resolve-path")
    p_rpath.add_argument("owner")
    p_rpath.add_argument("loop_id")

    p_val = sub.add_parser("validate")
    p_val.add_argument("file", help="Path to .loop.json or '-' for stdin")
    p_val.add_argument("--owner", default=None)
    p_val.add_argument("--id", dest="loop_id", default=None)

    p_save = sub.add_parser("save")
    p_save.add_argument("owner")
    p_save.add_argument("loop_id")
    p_save.add_argument("--target", choices=["override", "source"], default="override")

    p_del = sub.add_parser("delete")
    p_del.add_argument("owner")
    p_del.add_argument("loop_id")
    p_del.add_argument("--target", choices=["override", "source"], default="override")

    p_tools = sub.add_parser("available-tools")
    p_tools.add_argument("owner")

    p_ren = sub.add_parser("render")
    p_ren.add_argument("--context-file", required=True)
    p_ren.add_argument("--template-file", default=None)
    p_ren.add_argument("--json-template", default=None)
    p_ren.add_argument("--when", default=None)

    p_gate = sub.add_parser("check-gate")
    p_gate.add_argument("sandbox_dir")
    p_gate.add_argument("gate_json")

    args = parser.parse_args()

    if args.cmd == "list":
        loops = list_loops(lodge, george, args.owner)
        print(json.dumps({"status": "ok", "loops": loops}, indent=2))
        return 0

    if args.cmd == "resolve":
        res = resolve_loop(args.owner, args.loop_id, lodge, george)
        if not res:
            print(json.dumps({"status": "error", "message": f"Loop '{args.owner}/{args.loop_id}' not found"}))
            return 1
        print(json.dumps({"status": "ok", **res}, indent=2))
        return 0

    if args.cmd == "resolve-path":
        res = resolve_loop(args.owner, args.loop_id, lodge, george)
        if not res:
            return 1
        print(res["active_path"])
        return 0

    if args.cmd == "validate":
        try:
            raw = json.load(sys.stdin) if args.file == "-" else json.load(open(args.file, "r", encoding="utf-8"))
        except Exception as e:
            print(json.dumps({"valid": False, "errors": [f"Invalid JSON: {e}"]}))
            return 1
        ok, errs, norm = validate_loop(raw, args.owner, args.loop_id)
        if not ok:
            print(json.dumps({"valid": False, "errors": errs}, indent=2))
            return 1
        print(json.dumps({"valid": True, "normalized": norm}, indent=2))
        return 0

    if args.cmd == "save":
        try:
            raw = json.load(sys.stdin)
        except Exception as e:
            print(json.dumps({"status": "error", "message": f"Invalid JSON payload: {e}"}))
            return 1
        norm_owner = normalize_owner(args.owner)
        ok, errs, norm = validate_loop(raw, expected_owner=norm_owner, expected_id=args.loop_id)
        if not ok or not norm:
            print(json.dumps({"status": "error", "message": "; ".join(errs), "errors": errs}))
            return 1
        src_dir, ovr_dir, _ = loop_dirs_for_owner(norm_owner, lodge, george)
        target_dir = src_dir if args.target == "source" else ovr_dir
        if args.target == "source" and norm_owner != "heartwood":
            if not (george / "modules" / norm_owner / "module.json").is_file():
                print(json.dumps({"status": "error", "message": f"Module '{norm_owner}' is not installed"}))
                return 1
        target_dir.mkdir(parents=True, exist_ok=True)
        dst = target_dir / f"{args.loop_id}.loop.json"
        if not safe_under(dst, target_dir):
            print(json.dumps({"status": "error", "message": "Destination path escapes allowed directory"}))
            return 1
        tmp = dst.with_suffix(".loop.json.tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(norm, f, indent=2)
            f.write("\n")
        os.replace(tmp, dst)
        print(json.dumps({"status": "ok", "target": args.target, "path": str(dst), "loop": norm}, indent=2))
        return 0

    if args.cmd == "delete":
        norm_owner = normalize_owner(args.owner)
        if not valid_id(args.loop_id):
            print(json.dumps({"status": "error", "message": "Invalid loop id"}))
            return 1
        src_dir, ovr_dir, _ = loop_dirs_for_owner(norm_owner, lodge, george)
        target_dir = src_dir if args.target == "source" else ovr_dir
        dst = target_dir / f"{args.loop_id}.loop.json"
        if not safe_under(dst, target_dir):
            print(json.dumps({"status": "error", "message": "Path escapes allowed directory"}))
            return 1
        if not dst.is_file():
            print(json.dumps({"status": "error", "message": f"No {args.target} file exists for {norm_owner}/{args.loop_id}"}))
            return 1
        dst.unlink()
        print(json.dumps({"status": "ok", "deleted": str(dst), "target": args.target}))
        return 0

    if args.cmd == "available-tools":
        print(json.dumps({"status": "ok", **available_tools_for_owner(args.owner, lodge, george)}, indent=2))
        return 0

    if args.cmd == "render":
        ctx = _load_json_safe(Path(args.context_file)) or {}
        if args.when is not None:
            if not check_condition(args.when, ctx):
                print("__SKIP__")
                return 0
        if args.json_template is not None:
            tmpl = json.loads(args.json_template)
            rendered = render_value(tmpl, ctx)
            print(json.dumps(rendered))
            return 0
        if args.template_file:
            tmpl_str = open(args.template_file, "r", encoding="utf-8").read()
            print(render_value(tmpl_str, ctx))
            return 0
        tmpl_str = sys.stdin.read()
        print(render_value(tmpl_str, ctx))
        return 0

    if args.cmd == "check-gate":
        gate = json.loads(args.gate_json)
        res = check_gate(Path(args.sandbox_dir), gate)
        print(json.dumps(res))
        return 0 if res.get("passed") else 1

    return 1


if __name__ == "__main__":
    sys.exit(main())
