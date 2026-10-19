#!/usr/bin/env python3
"""Build a public snapshot of Blue Lodge from a git ref, then gate it with secret/PII scans.

    python3 scripts/release/export_public.py --out /tmp/blue-lodge-public [--ref HEAD] [--no-commit]

The snapshot is a fresh single-commit repository and is never pushed by this tool.
1. Files come from `git ls-tree <ref>`, filtered by scripts/release/public_manifest.txt (allow-list).
2. Machine-specific home paths are normalized in text files.
3. Gate (any failure means exit 1 and no commit):
   - denylist: literal strings from .george/release/denylist.txt (operator-local, never exported) plus
     every value in .george/keys.conf and .george/secrets.env. Hits are reported by index, never by value.
   - high-severity PII/secret regexes (wallet addresses, tokens, private keys, home paths, URL credentials).
     Reviewed false positives are listed in scripts/release/scan_allow.txt.
   - gitleaks (if installed), filtered the same way.
A JSON report is written next to the snapshot (<out>.report.json), outside the exported tree.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent

NORMALIZE = [
    ("/home/user/blue-lodge", "/home/user/blue-lodge"),
    ("/home/user", "/home/user"),
    ("user", "user"),
]

GATE_RULES = {
    "cardano_addr": re.compile(r"\b(?:addr1|stake1)[02-9ac-hj-np-z]{50,}\b"),
    "evm_privkey": re.compile(r"(?i)(?:priv(?:ate)?[_ ]?key|secret)[\"'\s:=]+[\"']?(?:0x)?[0-9a-f]{64}\b"),
    "telegram_token": re.compile(r"\b\d{8,10}:[A-Za-z0-9_-]{35}\b"),
    "discord_token": re.compile(r"\b[MNO][A-Za-z\d_-]{23,25}\.[A-Za-z\d_-]{6}\.[A-Za-z\d_-]{27,38}\b"),
    "mnemonic": re.compile(r"(?i)\b(?:seed phrase|mnemonic)\b\s*[:=]\s*[\"']?[a-z]+(?: [a-z]+){11,}"),
    "home_path": re.compile(r"/home/user\b|C:\\\\Users\\\\(?!user\b|<)[A-Za-z0-9._-]+"),
    "url_cred": re.compile(r"\b[a-z]+://[^/\s:@]+:[^/\s@]{6,}@"),
    "pem_private": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
}
INFO_RULES = {
    "lan_ip": re.compile(r"\b(?:192\.168|10\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b"),
    "email": re.compile(r"\b[A-Za-z0-9._%+-]+@(?!example\.|users\.noreply\.github\.com)[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"),
    "snowflake": re.compile(r"(?<![\d.])\d{17,20}(?![\d.])"),
}
URL_PLACEHOLDER = re.compile(r"(?i)example|placeholder|changeme|<|\$\{|\$[A-Z_]|x{4,}|user:pass")
BINARY_EXT = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".pdf", ".gguf", ".bin", ".zip", ".gz", ".woff",
              ".woff2", ".ttf", ".otf", ".sqlite", ".db", ".exe", ".so", ".onnx"}


def git(*args: str, binary: bool = False):
    out = subprocess.run(["git", "-C", str(REPO), *args], check=True, capture_output=True)
    return out.stdout if binary else out.stdout.decode()


def load_manifest(path: Path) -> list[tuple[bool, str]]:
    rules = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        sign, glob = line[0], line[1:].strip()
        if sign not in "+-" or not glob:
            raise SystemExit(f"bad manifest line: {line}")
        rules.append((sign == "+", glob))
    return rules


def included(path: str, rules: list[tuple[bool, str]]) -> bool:
    verdict = False
    for inc, glob in rules:
        if fnmatch.fnmatchcase(path, glob):
            verdict = inc
    return verdict


def load_allow(path: Path) -> set[tuple[str, str]]:
    allow = set()
    if path.exists():
        for line in path.read_text().splitlines():
            line = line.split("#", 1)[0].strip()
            if line:
                rule, _, f = line.partition("\t") if "\t" in line else line.partition(" ")
                allow.add((rule.strip(), f.strip()))
    return allow


def allowed(allow: set[tuple[str, str]], rule: str, f: str) -> bool:
    return any(r == rule and fnmatch.fnmatchcase(f, g) for r, g in allow)


def load_denylist(lodge: Path, extra: list[str]) -> list[str]:
    items: list[str] = []
    for p in [lodge / ".george/release/denylist.txt", *map(Path, extra)]:
        if p.exists():
            items += [l.strip() for l in p.read_text().splitlines() if l.strip() and not l.startswith("#")]
    secretish = re.compile(r"(?i)KEY|TOKEN|SECRET|PASS|WEBHOOK|AUTH|COOKIE|MNEMONIC|SEED|OWNER|_IDS?$|ADDR|EMAIL|USER|"
                           r"PHONE|CHAT|GUILD|CHANNEL|HOST|IP$")
    for p in (lodge / ".george/keys.conf", lodge / ".george/secrets.env"):
        if p.exists():
            for l in p.read_text(errors="replace").splitlines():
                m = re.match(r"\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$", l)
                if not m or not secretish.search(m.group(1)):
                    continue
                for v in m.group(2).strip().strip("'\"").split(","):
                    v = v.strip()
                    if len(v) < 8 or re.match(r"[~./]", v) or re.fullmatch(
                            r"(?i)(true|false|\d{1,6}|localhost|127\.0\.0\.1|0\.0\.0\.0|sdr-server|not[-_]?needed|none|changeme|"
                            r"https?://(localhost|127\.0\.0\.1)\S*|https://[a-z0-9.-]+\.(io|com|org|net)(/\S*)?)", v):
                        continue  # paths, flags, ports, public service URLs are configuration, not secrets
                    items.append(v)
    wlib = lodge / ".george/wallets/wallet_library.json"
    if wlib.exists():
        try:
            wdata = json.loads(wlib.read_text(errors="replace"))
            for w in wdata.get("wallets", []):
                for k in ("address", "stake_address"):
                    val = str(w.get(k) or "").strip()
                    if len(val) >= 12:
                        items.append(val)
        except Exception:
            pass
    ks_dir = lodge / ".george/wallets/keystore"
    if ks_dir.is_dir():
        for kp in ks_dir.glob("*.json"):
            try:
                kdata = json.loads(kp.read_text(errors="replace"))
                for k in ("address", "enterprise_address", "stake_address"):
                    val = str(kdata.get(k) or "").strip()
                    if len(val) >= 12:
                        items.append(val)
            except Exception:
                pass
    return sorted(set(items), key=len, reverse=True)


def is_text(p: Path) -> bool:
    if p.suffix.lower() in BINARY_EXT:
        return False
    try:
        p.read_text(errors="strict")
        return True
    except (UnicodeDecodeError, OSError):
        return False


def export(ref: str, out: Path, rules) -> list[str]:
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    files = []
    for line in git("ls-tree", "-r", "--full-tree", ref).splitlines():
        meta, path = line.split("\t", 1)
        mode, kind, obj = meta.split()
        if kind != "blob" or not included(path, rules):
            continue
        dst = out / path
        dst.parent.mkdir(parents=True, exist_ok=True)
        if mode == "120000":
            target = git("cat-file", "blob", obj).strip()
            if target and not os.path.isabs(target) and ".." not in Path(target).parts:
                dst.symlink_to(target)
            continue
        dst.write_bytes(git("cat-file", "blob", obj, binary=True))
        if mode == "100755":
            dst.chmod(0o755)
        files.append(path)
    return files


def normalize(out: Path, files: list[str]) -> int:
    n = 0
    for f in files:
        p = out / f
        if not is_text(p):
            continue
        s = p.read_text()
        t = s
        for a, b in NORMALIZE:
            t = t.replace(a, b)
        if t != s:
            p.write_text(t)
            n += 1
    return n


def scan(out: Path, files: list[str], deny: list[str], allow) -> dict:
    gate, info, deny_hits = [], {}, []
    for f in files:
        p = out / f
        if not is_text(p):
            data = p.read_bytes()
            for i, d in enumerate(deny):
                if d.encode() in data:
                    deny_hits.append({"file": f, "line": 0, "entry": i})
            continue
        for n, line in enumerate(p.read_text().splitlines(), 1):
            for i, d in enumerate(deny):
                if d in line:
                    deny_hits.append({"file": f, "line": n, "entry": i})
            for rule, rx in GATE_RULES.items():
                for m in rx.finditer(line[:8000]):
                    if rule == "url_cred" and URL_PLACEHOLDER.search(m.group(0)):
                        continue
                    if not allowed(allow, rule, f):
                        gate.append({"rule": rule, "file": f, "line": n})
            for rule, rx in INFO_RULES.items():
                c = len(rx.findall(line[:8000]))
                if c:
                    info[rule] = info.get(rule, 0) + c
    return {"denylist_hits": deny_hits, "gate_hits": gate, "info_counts": info}


def gitleaks(out: Path, allow) -> list[dict]:
    if not shutil.which("gitleaks"):
        return [{"rule": "gitleaks-missing", "file": "-", "line": 0}]
    rep = out.parent / (out.name + ".gitleaks.json")
    subprocess.run(["gitleaks", "dir", "--no-banner", "--redact", "--report-format", "json",
                    "--report-path", str(rep), str(out)], capture_output=True)
    hits = []
    try:
        for f in json.loads(rep.read_text() or "[]"):
            rel = os.path.relpath(f["File"], out) if os.path.isabs(f["File"]) else f["File"]
            if not allowed(allow, "gitleaks:" + f["RuleID"], rel):
                hits.append({"rule": "gitleaks:" + f["RuleID"], "file": rel, "line": f.get("StartLine", 0)})
    finally:
        rep.unlink(missing_ok=True)
    return hits


def commit(out: Path, ref: str) -> str:
    sha = git("rev-parse", "--short", ref).strip()
    env = {**os.environ, "GIT_AUTHOR_NAME": os.environ.get("RELEASE_AUTHOR_NAME", "Blue Lodge"),
           "GIT_AUTHOR_EMAIL": os.environ.get("RELEASE_AUTHOR_EMAIL", "blue-lodge@users.noreply.github.com")}
    env["GIT_COMMITTER_NAME"], env["GIT_COMMITTER_EMAIL"] = env["GIT_AUTHOR_NAME"], env["GIT_AUTHOR_EMAIL"]
    run = lambda *a: subprocess.run(["git", "-C", str(out), *a], check=True, capture_output=True, env=env)
    run("init", "-q", "-b", "main")
    run("add", "-A")
    run("commit", "-q", "-m", f"Blue Lodge public snapshot (source {sha})")
    return subprocess.run(["git", "-C", str(out), "rev-parse", "--short", "HEAD"], capture_output=True,
                          text=True).stdout.strip()


def main() -> int:
    global REPO
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--ref", default="HEAD")
    ap.add_argument("--manifest", default=str(HERE / "public_manifest.txt"))
    ap.add_argument("--allow", default=str(HERE / "scan_allow.txt"))
    ap.add_argument("--denylist", action="append", default=[])
    ap.add_argument("--lodge-dir", default=os.environ.get("LODGE_DIR", str(REPO)),
                    help="where .george/{keys.conf,secrets.env,release/denylist.txt} live")
    ap.add_argument("--no-commit", action="store_true")
    ap.add_argument("--repo", default=str(REPO), help="source repository (default: this checkout)")
    ap.add_argument("--skip-gitleaks", action="store_true", help="do not run gitleaks (default: required)")
    a = ap.parse_args()

    REPO = Path(a.repo).resolve()
    out = Path(a.out).resolve()
    if REPO == out or REPO in out.parents:
        print("refusing to export inside the source repository", file=sys.stderr)
        return 2
    rules = load_manifest(Path(a.manifest))
    allow = load_allow(Path(a.allow))
    deny = load_denylist(Path(a.lodge_dir), a.denylist)

    files = export(a.ref, out, rules)
    normalized = normalize(out, files)
    res = scan(out, files, deny, allow)
    if not a.skip_gitleaks:
        res["gate_hits"] += gitleaks(out, allow)
    res.update({"ref": a.ref, "files": len(files), "normalized_files": normalized, "denylist_entries": len(deny)})
    ok = not res["denylist_hits"] and not res["gate_hits"]
    res["passed"] = ok
    if ok and not a.no_commit:
        res["commit"] = commit(out, a.ref)
    report = out.parent / (out.name + ".report.json")
    report.write_text(json.dumps(res, indent=1))

    print(f"exported {len(files)} files from {a.ref} -> {out} ({normalized} normalized)")
    print(f"denylist entries checked: {len(deny)}  hits: {len(res['denylist_hits'])}")
    print(f"gate hits: {len(res['gate_hits'])}  info: {res['info_counts']}")
    for h in (res["denylist_hits"][:20]):
        print(f"  DENY entry#{h['entry']} {h['file']}:{h['line']}")
    for h in res["gate_hits"][:40]:
        print(f"  GATE {h['rule']} {h['file']}:{h['line']}")
    print(("PASS" + (f" - committed {res.get('commit')} (not pushed)" if res.get("commit") else "")) if ok else
          f"FAIL - see {report}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
