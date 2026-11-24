#!/usr/bin/env python3
"""
Blue Lodge Module Manifest & Static Security Auditor (module_audit.py)
Validates module.json schema, directory boundaries, Python AST safety,
and Bash syntax before a module can be enabled in Blue Lodge.
"""

import ast
import json
import os
import re
import subprocess
import sys

_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{1,48}$")
_VALID_VENV_MODES = {"shared_locked", "isolated_venv", "docker_sidecar", "none"}
_SENSITIVE_RE = re.compile(
    r"(keys\.conf|secrets\.env|/\.ssh/|id_rsa|id_ed25519|wallet\.skey|payment\.skey|/etc/shadow)",
    re.I,
)
_BANNED_PY_CALLS = {"eval", "exec", "compile", "__import__"}
_BANNED_PY_MODS = {"ctypes", "pty"}


def _safe_rel(root: str, rel: str):
    if not rel or os.path.isabs(rel) or ".." in rel.replace("\\", "/").split("/"):
        return None
    full = os.path.realpath(os.path.join(root, rel))
    root_real = os.path.realpath(root)
    if full == root_real or full.startswith(root_real + os.sep):
        return full
    return None


def audit_module_dir(mod_dir: str) -> dict:
    issues = []
    warnings = []
    manifest_path = os.path.join(mod_dir, "module.json")
    if not os.path.isfile(manifest_path):
        return {"ok": False, "issues": ["Missing module.json"], "warnings": []}

    try:
        with open(manifest_path, "r", encoding="utf-8") as f:
            m = json.load(f)
    except Exception as e:
        return {"ok": False, "issues": [f"Invalid module.json JSON: {e}"], "warnings": []}

    mod_id = str(m.get("id", ""))
    if not _ID_RE.match(mod_id):
        issues.append(f"Invalid module id '{mod_id}' (must match ^[a-z0-9][a-z0-9_-]{{1,48}}$)")
    for req in ("name", "version", "category"):
        if not m.get(req):
            issues.append(f"Missing required manifest field: {req}")

    rt = m.get("runtime") or {}
    venv_mode = rt.get("venv_mode", "shared_locked")
    if venv_mode not in _VALID_VENV_MODES:
        issues.append(f"Invalid runtime.venv_mode '{venv_mode}' (allowed: {sorted(_VALID_VENV_MODES)})")

    # Verify declared relative files do not escape module root
    provides = m.get("provides") or {}
    for key in ("tools_schema", "tools_dispatcher", "context_hook", "strategist_hook", "api_entries", "workflows_dir"):
        val = provides.get(key)
        if val:
            resolved = _safe_rel(mod_dir, val)
            if not resolved:
                issues.append(f"Path traversal or absolute path in provides.{key}: {val}")
            elif not os.path.exists(resolved):
                warnings.append(f"Declared provides.{key} does not exist yet: {val}")

    # Validate declarative ALP v1 workflows/*.loop.json if present
    wf_dir = _safe_rel(mod_dir, provides.get("workflows_dir") or "workflows")
    if wf_dir and os.path.isdir(wf_dir):
        loop_schema_py = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "core", "loop_schema.py")
        for wname in sorted(os.listdir(wf_dir)):
            if not wname.endswith(".loop.json"):
                continue
            wpath = os.path.join(wf_dir, wname)
            if os.path.isfile(loop_schema_py):
                vproc = subprocess.run(
                    ["python3", loop_schema_py, "validate", wpath, "--owner", mod_id],
                    capture_output=True, text=True, timeout=10,
                )
                if vproc.returncode != 0:
                    issues.append(f"workflows/{wname}: ALP v1 loop schema validation failed: {vproc.stdout.strip() or vproc.stderr.strip()}")

    ui = provides.get("ui") or {}
    for key in ("js", "css", "panel_json"):
        val = ui.get(key)
        if val:
            resolved = _safe_rel(mod_dir, val)
            if not resolved:
                issues.append(f"Path traversal in provides.ui.{key}: {val}")

    # Validate tools/schemas.json if present
    ts = provides.get("tools_schema")
    if ts:
        ts_path = _safe_rel(mod_dir, ts)
        if ts_path and os.path.isfile(ts_path):
            try:
                with open(ts_path, "r", encoding="utf-8") as f:
                    schemas = json.load(f)
                if not isinstance(schemas, list):
                    issues.append("tools_schema must be a JSON array of OpenAI tool definitions")
            except Exception as e:
                issues.append(f"Invalid tools_schema JSON: {e}")

    # Static AST & shell syntax scan across module files (skipping .git, .venv, .george, .sandboxes, __pycache__, vendor)
    skip_dirs = {".git", ".venv", ".george", ".sandboxes", "__pycache__", "node_modules", "vendor", "data"}
    py_scanned = 0
    sh_scanned = 0
    for cur, dirs, files in os.walk(mod_dir):
        dirs[:] = [d for d in dirs if d not in skip_dirs]
        for fname in files:
            fpath = os.path.join(cur, fname)
            rel = os.path.relpath(fpath, mod_dir)
            if fname.endswith(".py"):
                py_scanned += 1
                try:
                    src = open(fpath, "r", encoding="utf-8", errors="replace").read()
                    if _SENSITIVE_RE.search(src):
                        issues.append(f"{rel}: references sensitive credential/key path")
                    tree = ast.parse(src, filename=rel)
                    for node in ast.walk(tree):
                        if isinstance(node, ast.Import):
                            for a in node.names:
                                if a.name.split(".")[0] in _BANNED_PY_MODS:
                                    issues.append(f"{rel}: disallowed import '{a.name}'")
                        elif isinstance(node, ast.ImportFrom):
                            if node.module and node.module.split(".")[0] in _BANNED_PY_MODS:
                                issues.append(f"{rel}: disallowed import '{node.module}'")
                        elif isinstance(node, ast.Call):
                            if isinstance(node.func, ast.Name) and node.func.id in _BANNED_PY_CALLS:
                                issues.append(f"{rel}: disallowed call '{node.func.id}()'")
                            elif isinstance(node.func, ast.Attribute):
                                if node.func.attr in ("system", "popen") and isinstance(node.func.value, ast.Name) and node.func.value.id == "os":
                                    issues.append(f"{rel}: disallowed os.{node.func.attr}()")
                except SyntaxError as e:
                    issues.append(f"{rel}: Python SyntaxError line {e.lineno}: {e.msg}")
            elif fname.endswith(".sh"):
                sh_scanned += 1
                try:
                    src = open(fpath, "r", encoding="utf-8", errors="replace").read()
                    if re.search(r"\bcurl\b[^|\n]+\|\s*(ba)?sh\b", src):
                        issues.append(f"{rel}: disallowed curl-pipe-shell pattern")
                    proc = subprocess.run(["bash", "-n", fpath], capture_output=True, text=True, timeout=10)
                    if proc.returncode != 0:
                        issues.append(f"{rel}: Bash syntax error: {proc.stderr.strip()}")
                except Exception as e:
                    warnings.append(f"{rel}: shell audit skipped: {e}")

    return {
        "ok": len(issues) == 0,
        "module_id": mod_id,
        "version": m.get("version", ""),
        "venv_mode": venv_mode,
        "py_scanned": py_scanned,
        "sh_scanned": sh_scanned,
        "issues": issues,
        "warnings": warnings,
    }


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"ok": False, "issues": ["Usage: module_audit.py <module_dir>"]}))
        return 1
    res = audit_module_dir(sys.argv[1])
    print(json.dumps(res, indent=2))
    return 0 if res["ok"] else 2


if __name__ == "__main__":
    sys.exit(main())
