#!/usr/bin/env python3
"""
Blue Lodge Craftsman Tool Forger (tool_forge.py)
Enables George to safely craft, AST-audit, smoke-test, register, and invoke
reusable custom tools inside .george/tools/ without restarting daemons.

Actions:
  forge   --name <n> --lang python|bash --description <d> --code <src> [--smoke-args <json>]
  run     --name <n> [--args <json>]
  test    --name <n> [--smoke-args <json>]
  list
  remove  --name <n>
"""

import argparse
import ast
import datetime
import json
import os
import re
import subprocess
import sys

REPO_ROOT = os.environ.get(
    "LODGE_DIR",
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
)
GEORGE_DIR = os.environ.get("GEORGE_DIR", os.path.join(REPO_ROOT, ".george"))
TOOLS_DIR = os.path.join(GEORGE_DIR, "tools")
REGISTRY_PATH = os.path.join(TOOLS_DIR, "registry.json")
VENV_PYTHON = os.path.join(REPO_ROOT, ".venv", "bin", "python")

_NAME_RE = re.compile(r"^[a-z][a-z0-9_]{1,48}$")
_SENSITIVE_PATHS_RE = re.compile(
    r"(keys\.conf|secrets\.env|/\.ssh/|id_rsa|id_ed25519|wallet\.skey|payment\.skey|/etc/shadow)",
    re.I,
)
_BANNED_PY_CALLS = {"eval", "exec", "compile", "__import__"}
_BANNED_PY_MODULES = {"ctypes", "pty"}


def _load_registry():
    if os.path.exists(REGISTRY_PATH):
        try:
            with open(REGISTRY_PATH, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {"tools": {}}


def _save_registry(reg):
    os.makedirs(TOOLS_DIR, exist_ok=True)
    tmp = REGISTRY_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(reg, f, indent=2)
    os.replace(tmp, REGISTRY_PATH)


def audit_python_code(code: str):
    issues = []
    if _SENSITIVE_PATHS_RE.search(code):
        issues.append("References sensitive credential/key path (keys.conf, secrets.env, .ssh, or .skey)")
    try:
        tree = ast.parse(code)
    except SyntaxError as e:
        return [f"Python SyntaxError at line {e.lineno}: {e.msg}"]

    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                top = alias.name.split(".")[0]
                if top in _BANNED_PY_MODULES:
                    issues.append(f"Disallowed module import: {top}")
        elif isinstance(node, ast.ImportFrom):
            if node.module and node.module.split(".")[0] in _BANNED_PY_MODULES:
                issues.append(f"Disallowed module import: {node.module}")
        elif isinstance(node, ast.Call):
            if isinstance(node.func, ast.Name) and node.func.id in _BANNED_PY_CALLS:
                issues.append(f"Disallowed dynamic execution call: {node.func.id}()")
            elif isinstance(node.func, ast.Attribute):
                if node.func.attr in ("system", "popen") and isinstance(node.func.value, ast.Name) and node.func.value.id == "os":
                    issues.append(f"Disallowed shell call: os.{node.func.attr}() (use subprocess without shell=True)")
                if node.func.attr in ("Popen", "run", "call", "check_output"):
                    for kw in node.keywords:
                        if kw.arg == "shell" and isinstance(kw.value, ast.Constant) and kw.value.value is True:
                            issues.append("Disallowed subprocess(..., shell=True)")
    return issues


def audit_bash_code(code: str):
    issues = []
    if _SENSITIVE_PATHS_RE.search(code):
        issues.append("References sensitive credential/key path")
    if re.search(r"\brm\s+-[a-zA-Z]*r[a-zA-Z]*f?\s+(/|\$HOME|\~)", code):
        issues.append("Dangerous recursive delete against root or home directory")
    if re.search(r"\bcurl\b[^|\n]+\|\s*(ba)?sh\b", code):
        issues.append("Disallowed curl-pipe-shell execution")
    proc = subprocess.run(["bash", "-n"], input=code, capture_output=True, text=True, timeout=10)
    if proc.returncode != 0:
        issues.append(f"Bash syntax error: {proc.stderr.strip()}")
    return issues


def _run_tool_file(path: str, lang: str, args_json: str = "{}", timeout: int = 30):
    py_bin = VENV_PYTHON if os.path.exists(VENV_PYTHON) else sys.executable
    cmd = [py_bin, path] if lang == "python" else ["bash", path]
    env = os.environ.copy()
    env["LODGE_DIR"] = REPO_ROOT
    env["GEORGE_DIR"] = GEORGE_DIR
    env["TOOL_ARGS_JSON"] = args_json
    proc = subprocess.run(
        cmd,
        input=args_json,
        capture_output=True,
        text=True,
        timeout=timeout,
        env=env,
        cwd=REPO_ROOT,
    )
    return {
        "exit_code": proc.returncode,
        "stdout": proc.stdout[-8000:],
        "stderr": proc.stderr[-2000:],
    }


def forge_tool(name: str, lang: str, description: str, code: str, smoke_args: str = "{}"):
    if not _NAME_RE.match(name):
        return {"status": "ERROR", "reason": "Tool name must match ^[a-z][a-z0-9_]{1,48}$"}
    if lang not in ("python", "bash"):
        return {"status": "ERROR", "reason": "lang must be 'python' or 'bash'"}

    issues = audit_python_code(code) if lang == "python" else audit_bash_code(code)
    if issues:
        return {"status": "REJECTED_SAFETY_AUDIT", "name": name, "issues": issues}

    os.makedirs(TOOLS_DIR, exist_ok=True)
    ext = ".py" if lang == "python" else ".sh"
    tool_path = os.path.join(TOOLS_DIR, f"{name}{ext}")
    tmp_path = tool_path + ".staging"
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.write(code)
    os.chmod(tmp_path, 0o755)

    # Smoke test before promoting into active registry
    try:
        smoke = _run_tool_file(tmp_path, lang, smoke_args or "{}", timeout=20)
    except subprocess.TimeoutExpired:
        os.remove(tmp_path)
        return {"status": "SMOKE_TEST_TIMEOUT", "name": name, "reason": "Tool exceeded 20s smoke test timeout"}

    if smoke["exit_code"] != 0:
        os.remove(tmp_path)
        return {
            "status": "SMOKE_TEST_FAILED",
            "name": name,
            "exit_code": smoke["exit_code"],
            "stderr": smoke["stderr"],
            "stdout": smoke["stdout"],
        }

    os.replace(tmp_path, tool_path)
    reg = _load_registry()
    reg["tools"][name] = {
        "name": name,
        "lang": lang,
        "path": tool_path,
        "description": description.strip(),
        "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "verified": True,
    }
    _save_registry(reg)
    return {
        "status": "FORGED_AND_VERIFIED",
        "name": name,
        "path": tool_path,
        "smoke_stdout": smoke["stdout"][:600],
    }


def main():
    p = argparse.ArgumentParser(description="Blue Lodge Craftsman Tool Forger")
    sub = p.add_subparsers(dest="cmd", required=True)

    pf = sub.add_parser("forge")
    pf.add_argument("--name", required=True)
    pf.add_argument("--lang", default="python", choices=["python", "bash"])
    pf.add_argument("--description", required=True)
    pf.add_argument("--code", required=True)
    pf.add_argument("--smoke-args", default="{}")

    pr = sub.add_parser("run")
    pr.add_argument("--name", required=True)
    pr.add_argument("--args", default="{}")
    pr.add_argument("--timeout", type=int, default=60)

    sub.add_parser("list")

    pd = sub.add_parser("remove")
    pd.add_argument("--name", required=True)

    args = p.parse_args()
    if args.cmd == "list":
        print(json.dumps(_load_registry(), indent=2))
        return 0
    if args.cmd == "forge":
        res = forge_tool(args.name, args.lang, args.description, args.code, args.smoke_args)
        print(json.dumps(res, indent=2))
        return 0 if res["status"] == "FORGED_AND_VERIFIED" else 2
    if args.cmd == "run":
        reg = _load_registry()
        entry = reg.get("tools", {}).get(args.name)
        if not entry or not os.path.exists(entry["path"]):
            print(json.dumps({"status": "ERROR", "reason": f"Forged tool '{args.name}' not found"}))
            return 1
        res = _run_tool_file(entry["path"], entry["lang"], args.args, timeout=args.timeout)
        print(json.dumps({"status": "OK" if res["exit_code"] == 0 else "ERROR", **res}, indent=2))
        return 0 if res["exit_code"] == 0 else 1
    if args.cmd == "remove":
        reg = _load_registry()
        entry = reg.get("tools", {}).pop(args.name, None)
        if entry and os.path.exists(entry["path"]):
            os.remove(entry["path"])
        _save_registry(reg)
        print(json.dumps({"status": "REMOVED", "name": args.name}))
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
