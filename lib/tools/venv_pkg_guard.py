#!/usr/bin/env python3
"""
Sovereign .venv Supply-Chain Guard & Package Installer (venv_pkg_guard.py)
Protects Blue Lodge's .venv against MITM, PyPI typosquatting, dependency confusion,
malicious setup.py execution, and known malware/CVEs (OSV.dev).

Defense-in-Depth Pipeline:
  1. Strict PEP 508 name validation (rejects URLs, git+, local paths, custom indexes).
  2. Typosquatting detection (Levenshtein edit distance against allowlist + popular packages).
  3. Live PyPI JSON API inspection over verified HTTPS (package age, yanked check, wheel presence).
  4. Tier A/B/C Policy Gate:
     - Tier A: Package in curated allowlist (+ optional local operator allowlist) -> auto-installable.
     - Tier B: Novel vetted package (age >= 30d, clean OSV, wheels-only) -> requires operator approval (--approve).
     - Tier C: Hard block (typosquat, MAL-* malware, CRITICAL/HIGH CVE, non-pythonhosted host, sdist-only RCE).
  5. Zero-execution transitive closure dry-run (`pip install --dry-run --only-binary=:all: --report`).
  6. Full transitive graph verification:
     - Every wheel URL host MUST be `files.pythonhosted.org`.
     - Every artifact MUST be a `.whl` (zero `setup.py` arbitrary code execution).
     - Every (name, version) in the closure is scanned against OSV.dev.
     - Every wheel SHA-256 is cross-verified against official PyPI JSON metadata.
  7. Locked install via `pip install --only-binary=:all: --require-hashes --no-deps -r <lockfile>`.
  8. Immutable audit log in `.george/security/pkg_audit.jsonl`.
"""

import argparse
import datetime
import json
import os
import re
import shutil
import ssl
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

REPO_ROOT = os.environ.get(
    "LODGE_DIR",
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
)
GEORGE_DIR = os.environ.get("GEORGE_DIR", os.path.join(REPO_ROOT, ".george"))
ALLOWLIST_PATH = os.path.join(REPO_ROOT, "data", "security", "pypi_allowlist.json")
LOCAL_ALLOWLIST_PATH = os.path.join(GEORGE_DIR, "security", "pypi_allowlist.local.json")
AUDIT_LOG_PATH = os.path.join(GEORGE_DIR, "security", "pkg_audit.jsonl")
VENV_PIP = os.path.join(REPO_ROOT, ".venv", "bin", "pip")
VENV_PYTHON = os.path.join(REPO_ROOT, ".venv", "bin", "python")


def _find_uv():
    uv = shutil.which("uv")
    if uv:
        return uv
    cand = os.path.expanduser("~/.local/bin/uv")
    return cand if os.path.exists(cand) else None

_PKG_NAME_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9._-]{0,126}[A-Za-z0-9])?$")
_VER_RE = re.compile(r"^[0-9][A-Za-z0-9.+-]{0,40}$")


def pep503_norm(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def levenshtein(a: str, b: str) -> int:
    if a == b:
        return 0
    if len(a) < len(b):
        a, b = b, a
    if not b:
        return len(a)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        curr = [i]
        for j, cb in enumerate(b, 1):
            cost = 0 if ca == cb else 1
            curr.append(min(curr[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost))
        prev = curr
    return prev[-1]


def load_policy():
    with open(ALLOWLIST_PATH, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    allow = {pep503_norm(k): v for k, v in cfg.get("allowlist", {}).items()}
    if os.path.exists(LOCAL_ALLOWLIST_PATH):
        try:
            with open(LOCAL_ALLOWLIST_PATH, "r", encoding="utf-8") as f:
                loc = json.load(f)
            for k, v in loc.get("allowlist", {}).items():
                allow[pep503_norm(k)] = v
        except Exception:
            pass
    pop = {pep503_norm(n) for n in cfg.get("popular_reference_names", [])}
    pop.update(allow.keys())
    return cfg.get("policy", {}), allow, pop


def check_typosquat(norm_name: str, reference_names: set, max_dist: int = 2):
    if norm_name in reference_names:
        return None
    if len(norm_name) <= 3:
        return None
    for ref in sorted(reference_names):
        if abs(len(ref) - len(norm_name)) > max_dist:
            continue
        d = levenshtein(norm_name, ref)
        # Distance 1 for >=4 chars, or distance 2 for >=6 chars
        if d == 1 or (d == 2 and len(norm_name) >= 6 and len(ref) >= 6):
            return {"suspect_of": ref, "edit_distance": d}
    return None


def _https_json(url: str, body: dict = None, timeout: int = 20):
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https":
        raise ValueError(f"Non-HTTPS URL blocked: {url}")
    ctx = ssl.create_default_context()
    headers = {"User-Agent": "BlueLodge-VenvGuard/1.0", "Accept": "application/json"}
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
        return json.loads(resp.read().decode("utf-8"))


def fetch_pypi_meta(pkg: str, version: str = None):
    url = (
        f"https://pypi.org/pypi/{urllib.parse.quote(pkg)}/{urllib.parse.quote(version)}/json"
        if version
        else f"https://pypi.org/pypi/{urllib.parse.quote(pkg)}/json"
    )
    return _https_json(url, timeout=20)


def check_osv(pkg: str, version: str, policy: dict):
    """Query OSV.dev for known malware (MAL-*) and CVEs on (PyPI, pkg, version)."""
    try:
        resp = _https_json(
            "https://api.osv.dev/v1/query",
            body={"version": version, "package": {"name": pkg, "ecosystem": "PyPI"}},
            timeout=15,
        )
    except Exception as e:
        return {"ok": False, "error": f"OSV query failed: {e}", "blocked": [], "warnings": []}

    vulns = resp.get("vulns") or []
    block_prefixes = tuple(policy.get("block_osv_prefixes", ["MAL-"]))
    block_sevs = {s.upper() for s in policy.get("block_osv_severities", ["CRITICAL", "HIGH"])}
    blocked = []
    warnings = []
    for v in vulns:
        vid = v.get("id", "UNKNOWN")
        summary = (v.get("summary") or v.get("details") or "")[:180]
        db_sev = (v.get("database_specific") or {}).get("severity", "").upper()
        is_mal = vid.startswith(block_prefixes) or any(
            a.startswith(block_prefixes) for a in (v.get("aliases") or [])
        )
        # Check CVSS score if severity string missing
        sev_high = db_sev in block_sevs
        for s in v.get("severity") or []:
            score_str = str(s.get("score", ""))
            # CVSS numeric fallback if present
            try:
                if float(score_str) >= 7.0:
                    sev_high = True
            except ValueError:
                pass
        entry = {"id": vid, "severity": db_sev or ("MALWARE" if is_mal else "UNKNOWN"), "summary": summary}
        if is_mal or sev_high:
            blocked.append(entry)
        else:
            warnings.append(entry)
    return {"ok": True, "blocked": blocked, "warnings": warnings}


def package_age_days(pypi_meta: dict):
    releases = pypi_meta.get("releases") or {}
    earliest = None
    for files in releases.values():
        for f in files or []:
            ts = f.get("upload_time_iso_8601") or f.get("upload_time")
            if not ts:
                continue
            try:
                dt = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
                if dt.tzinfo is None:
                    dt = dt.replace(tzinfo=datetime.timezone.utc)
                if earliest is None or dt < earliest:
                    earliest = dt
            except Exception:
                continue
    if earliest is None:
        return None
    now = datetime.datetime.now(datetime.timezone.utc)
    return max(0, (now - earliest).days)


def append_audit(record: dict):
    try:
        os.makedirs(os.path.dirname(AUDIT_LOG_PATH), exist_ok=True)
        record["timestamp"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        with open(AUDIT_LOG_PATH, "a", encoding="utf-8") as f:
            f.write(json.dumps(record) + "\n")
    except Exception:
        pass


def parse_spec(raw: str):
    raw = raw.strip()
    if any(tok in raw for tok in ("://", "git+", "file:", "@", "/", "\\", " ", ";", "[", "]")):
        raise ValueError(f"Rejected unsafe package specifier (URL/path/extras forbidden): {raw}")
    if "==" in raw:
        name, ver = raw.split("==", 1)
        if not _PKG_NAME_RE.match(name) or not _VER_RE.match(ver):
            raise ValueError(f"Invalid package==version format: {raw}")
        return name, ver
    if not _PKG_NAME_RE.match(raw):
        raise ValueError(f"Invalid PEP 508 package name: {raw}")
    return raw, None


def audit_package(spec: str):
    policy, allowlist, popular = load_policy()
    try:
        raw_name, req_ver = parse_spec(spec)
    except ValueError as e:
        return {"status": "BLOCKED", "tier": "C", "reason": str(e), "package": spec}

    norm = pep503_norm(raw_name)
    in_allowlist = norm in allowlist

    # 1. Typosquatting check (always runs for non-allowlisted packages)
    if not in_allowlist:
        typo = check_typosquat(norm, popular, int(policy.get("typosquat_max_distance", 2)))
        if typo:
            res = {
                "status": "BLOCKED",
                "tier": "C",
                "package": norm,
                "reason": f"TYPOSQUAT_SUSPECT: '{norm}' is edit-distance {typo['edit_distance']} from vetted package '{typo['suspect_of']}'",
                "typosquat": typo,
            }
            append_audit({"action": "audit", **res})
            return res

    # 2. PyPI metadata over verified HTTPS
    try:
        meta = fetch_pypi_meta(norm, req_ver)
        full_meta = fetch_pypi_meta(norm) if req_ver else meta
    except urllib.error.HTTPError as e:
        return {"status": "BLOCKED", "tier": "C", "package": norm, "reason": f"PyPI lookup failed (HTTP {e.code})"}
    except Exception as e:
        return {"status": "BLOCKED", "tier": "C", "package": norm, "reason": f"PyPI HTTPS error: {e}"}

    info = meta.get("info") or {}
    version = info.get("version") or req_ver
    urls = meta.get("urls") or []
    wheels = [u for u in urls if u.get("packagetype") == "bdist_wheel" and not u.get("yanked")]
    if not wheels:
        return {
            "status": "BLOCKED",
            "tier": "C",
            "package": norm,
            "version": version,
            "reason": "NO_WHEEL_AVAILABLE: package has no binary/pure wheel (sdist setup.py execution is forbidden by policy)",
        }

    age = package_age_days(full_meta)
    if not in_allowlist and age is not None and age < int(policy.get("hard_block_age_days", 14)):
        res = {
            "status": "BLOCKED",
            "tier": "C",
            "package": norm,
            "version": version,
            "age_days": age,
            "reason": f"TOO_NEW_PACKAGE: unvetted package is only {age} days old (<{policy.get('hard_block_age_days', 14)}d hard floor)",
        }
        append_audit({"action": "audit", **res})
        return res

    # 3. OSV.dev live check
    osv = check_osv(norm, version, policy)
    if not osv.get("ok"):
        return {
            "status": "BLOCKED",
            "tier": "C",
            "package": norm,
            "version": version,
            "reason": f"OSV_UNAVAILABLE: fail-closed security gate ({osv.get('error')})",
        }
    if osv.get("blocked"):
        res = {
            "status": "BLOCKED",
            "tier": "C",
            "package": norm,
            "version": version,
            "reason": f"OSV_BLOCKED: {len(osv['blocked'])} malware/critical/high advisory(ies)",
            "osv_blocked": osv["blocked"],
        }
        append_audit({"action": "audit", **res})
        return res

    tier = "A" if in_allowlist else "B"
    res = {
        "status": "APPROVED_TIER_A" if tier == "A" else "APPROVAL_REQUIRED_TIER_B",
        "tier": tier,
        "package": norm,
        "version": version,
        "allowlisted": in_allowlist,
        "allowlist_note": allowlist.get(norm, ""),
        "summary": (info.get("summary") or "")[:160],
        "age_days": age,
        "wheel_count": len(wheels),
        "osv_warnings": osv.get("warnings", []),
    }
    if tier == "B" and age is not None and age < int(policy.get("min_novel_package_age_days", 30)):
        res["age_warning"] = f"Package is {age}d old (<30d recommended maturity)"
    return res


def _parse_uv_compiled_lock(lock_text: str):
    """Parse `uv pip compile --generate-hashes` output into [(name, ver, [sha256, ...])]."""
    entries = []
    cur_name, cur_ver, cur_hashes = None, None, []
    for raw_line in lock_text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        m_pkg = re.match(r"^([A-Za-z0-9._-]+)==([^\s\\]+)", line)
        if m_pkg:
            if cur_name:
                entries.append((pep503_norm(cur_name), cur_ver, cur_hashes))
            cur_name, cur_ver, cur_hashes = m_pkg.group(1), m_pkg.group(2), []
        for hm in re.findall(r"--hash=sha256:([0-9a-fA-F]{64})", line):
            cur_hashes.append(hm.lower())
    if cur_name:
        entries.append((pep503_norm(cur_name), cur_ver, cur_hashes))
    return entries


def install_packages(specs: list, approve_tier_b: bool = False, venv_dir: str = None, create_venv: bool = False):
    policy, allowlist, popular = load_policy()
    allowed_hosts = set(policy.get("allowed_download_hosts", ["files.pythonhosted.org"]))

    uv_bin = _find_uv()
    target_venv = os.path.abspath(venv_dir) if venv_dir else os.path.join(REPO_ROOT, ".venv")
    venv_py = os.path.join(target_venv, "bin", "python")
    venv_pip = os.path.join(target_venv, "bin", "pip")

    if create_venv and not os.path.exists(venv_py):
        os.makedirs(os.path.dirname(target_venv), exist_ok=True)
        if uv_bin:
            mk = subprocess.run([uv_bin, "venv", target_venv], capture_output=True, text=True, timeout=60)
        else:
            mk = subprocess.run([sys.executable, "-m", "venv", target_venv], capture_output=True, text=True, timeout=60)
        if mk.returncode != 0:
            return {"status": "ERROR", "reason": f"Failed to create venv at {target_venv}: {(mk.stderr or mk.stdout)[-400:]}"}

    has_pip = os.path.exists(venv_pip)
    if not uv_bin and not has_pip:
        return {"status": "ERROR", "reason": f"Neither uv nor {venv_pip} found for {target_venv}"}
    if not os.path.exists(venv_py):
        return {"status": "ERROR", "reason": f"venv python not found at {venv_py}"}

    # Step 1: Audit every requested top-level package first
    audits = []
    pinned_targets = []
    for s in specs:
        a = audit_package(s)
        audits.append(a)
        if a["tier"] == "C":
            return {"status": "BLOCKED", "tier": "C", "audits": audits, "reason": a.get("reason")}
        if a["tier"] == "B" and not approve_tier_b:
            return {
                "status": "APPROVAL_REQUIRED",
                "tier": "B",
                "audits": audits,
                "reason": f"Package '{a['package']}' ({a['version']}) is not on Tier A allowlist; operator confirmation required.",
            }
        pinned_targets.append(f"{a['package']}=={a['version']}")

    # Step 2 & 3: Zero-execution transitive closure resolution + full graph verification
    with tempfile.TemporaryDirectory(prefix="venv-guard-") as tmpdir:
        verified_graph = []
        lock_lines = []

        if uv_bin:
            req_in = os.path.join(tmpdir, "req.in")
            with open(req_in, "w", encoding="utf-8") as f:
                f.write("\n".join(pinned_targets) + "\n")
            comp_cmd = [
                uv_bin,
                "pip",
                "compile",
                "--generate-hashes",
                "--only-binary",
                ":all:",
                "--python",
                venv_py,
                "--no-header",
                req_in,
            ]
            comp = subprocess.run(comp_cmd, capture_output=True, text=True, timeout=180)
            if comp.returncode != 0:
                return {
                    "status": "BLOCKED",
                    "tier": "C",
                    "reason": "uv wheel-only resolution failed (likely requires unsafe sdist/setup.py build or incompatible wheel)",
                    "stderr": (comp.stderr or comp.stdout)[-1200:],
                }
            closure = _parse_uv_compiled_lock(comp.stdout)
            if not closure:
                return {"status": "ERROR", "reason": "Empty dependency closure from uv pip compile"}

            for name, ver, hashes in closure:
                if not hashes:
                    return {
                        "status": "BLOCKED",
                        "tier": "C",
                        "reason": f"MISSING_SHA256: '{name}=={ver}' had no generated hashes",
                    }
                try:
                    p_meta = fetch_pypi_meta(name, ver)
                    wheel_entries = [
                        u for u in (p_meta.get("urls") or [])
                        if u.get("packagetype") == "bdist_wheel" and not u.get("yanked")
                    ]
                    official_hashes = {
                        (u.get("digests") or {}).get("sha256", "").lower()
                        for u in wheel_entries
                    }
                    # Verify every wheel URL on PyPI is hosted on allowed hosts
                    for u in wheel_entries:
                        parsed = urllib.parse.urlparse(u.get("url", ""))
                        if parsed.scheme != "https" or parsed.hostname not in allowed_hosts:
                            return {
                                "status": "BLOCKED",
                                "tier": "C",
                                "reason": f"HOST_VIOLATION for '{name}=={ver}': {u.get('url')}",
                            }
                except Exception as e:
                    return {
                        "status": "BLOCKED",
                        "tier": "C",
                        "reason": f"PYPI_CROSSCHECK_FAILED for '{name}=={ver}': {e}",
                    }
                # Restrict lockfile strictly to official wheel SHA-256 digests (drop any sdist hash)
                verified_wheel_hashes = sorted(h for h in hashes if h in official_hashes)
                if not verified_wheel_hashes:
                    return {
                        "status": "BLOCKED",
                        "tier": "C",
                        "reason": f"SHA256_MISMATCH (possible MITM or sdist-only): '{name}=={ver}' hashes did not match official PyPI wheel digests",
                    }
                osv = check_osv(name, ver, policy)
                if not osv.get("ok") or osv.get("blocked"):
                    return {
                        "status": "BLOCKED",
                        "tier": "C",
                        "reason": f"TRANSITIVE_OSV_BLOCKED: '{name}=={ver}' failed OSV check ({osv.get('blocked') or osv.get('error')})",
                    }
                hash_flags = " ".join(f"--hash=sha256:{h}" for h in verified_wheel_hashes)
                lock_lines.append(f"{name}=={ver} {hash_flags}")
                verified_graph.append({"name": name, "version": ver, "wheel_hashes": len(verified_wheel_hashes)})

            lock_path = os.path.join(tmpdir, "verified.lock.txt")
            with open(lock_path, "w", encoding="utf-8") as f:
                f.write("\n".join(lock_lines) + "\n")

            inst_cmd = [
                uv_bin,
                "pip",
                "install",
                "--python",
                venv_py,
                "--only-binary",
                ":all:",
                "--require-hashes",
                "--no-deps",
                "-r",
                lock_path,
            ]
        else:
            report_path = os.path.join(tmpdir, "pip_report.json")
            cmd = [
                venv_pip,
                "install",
                "--dry-run",
                "--only-binary=:all:",
                "--no-input",
                "--report",
                report_path,
                *pinned_targets,
            ]
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
            if proc.returncode != 0:
                return {
                    "status": "BLOCKED",
                    "tier": "C",
                    "reason": "pip wheel-only resolution failed (likely requires unsafe sdist/setup.py build or incompatible wheel)",
                    "stderr": (proc.stderr or proc.stdout)[-1200:],
                }
            with open(report_path, "r", encoding="utf-8") as f:
                report = json.load(f)

            to_install = report.get("install") or []
            if not to_install:
                return {
                    "status": "ALREADY_INSTALLED",
                    "tier": "A",
                    "packages": pinned_targets,
                    "audits": audits,
                }

            for item in to_install:
                meta = item.get("metadata") or {}
                dl = item.get("download_info") or {}
                name = pep503_norm(meta.get("name", ""))
                ver = meta.get("version", "")
                url = dl.get("url", "")
                hashes = (dl.get("archive_info") or {}).get("hashes") or {}
                sha256 = hashes.get("sha256", "").lower()

                parsed = urllib.parse.urlparse(url)
                if parsed.scheme != "https" or parsed.hostname not in allowed_hosts:
                    return {
                        "status": "BLOCKED",
                        "tier": "C",
                        "reason": f"HOST_VIOLATION: transitive dependency '{name}=={ver}' attempted download from untrusted URL '{url}'",
                    }
                if not parsed.path.endswith(".whl"):
                    return {
                        "status": "BLOCKED",
                        "tier": "C",
                        "reason": f"NON_WHEEL_DEPENDENCY: '{name}=={ver}' resolved to non-wheel '{parsed.path}'",
                    }
                if not sha256 or len(sha256) != 64:
                    return {
                        "status": "BLOCKED",
                        "tier": "C",
                        "reason": f"MISSING_SHA256: '{name}=={ver}' has no SHA-256 hash in pip report",
                    }
                try:
                    p_meta = fetch_pypi_meta(name, ver)
                    official_hashes = {
                        (u.get("digests") or {}).get("sha256", "").lower()
                        for u in (p_meta.get("urls") or [])
                        if u.get("packagetype") == "bdist_wheel" and not u.get("yanked")
                    }
                except Exception as e:
                    return {
                        "status": "BLOCKED",
                        "tier": "C",
                        "reason": f"PYPI_CROSSCHECK_FAILED for '{name}=={ver}': {e}",
                    }
                if sha256 not in official_hashes:
                    return {
                        "status": "BLOCKED",
                        "tier": "C",
                        "reason": f"SHA256_MISMATCH (possible MITM): '{name}=={ver}' hash {sha256} not in official PyPI digests",
                    }
                osv = check_osv(name, ver, policy)
                if not osv.get("ok") or osv.get("blocked"):
                    return {
                        "status": "BLOCKED",
                        "tier": "C",
                        "reason": f"TRANSITIVE_OSV_BLOCKED: '{name}=={ver}' failed OSV check ({osv.get('blocked') or osv.get('error')})",
                    }
                lock_lines.append(f"{name}=={ver} --hash=sha256:{sha256}")
                verified_graph.append({"name": name, "version": ver, "sha256": sha256, "url": url})

            lock_path = os.path.join(tmpdir, "verified.lock.txt")
            with open(lock_path, "w", encoding="utf-8") as f:
                f.write("\n".join(lock_lines) + "\n")

            inst_cmd = [
                venv_pip,
                "install",
                "--only-binary=:all:",
                "--require-hashes",
                "--no-deps",
                "--no-input",
                "-r",
                lock_path,
            ]

        inst = subprocess.run(inst_cmd, capture_output=True, text=True, timeout=300)
        if inst.returncode != 0:
            res = {
                "status": "INSTALL_FAILED",
                "reason": "Hash-verified wheel install failed",
                "stderr": (inst.stderr or inst.stdout)[-1200:],
            }
            append_audit({"action": "install_failed", "requested": pinned_targets, **res})
            return res

        res = {
            "status": "INSTALLED",
            "tier": "B_APPROVED" if approve_tier_b else "A",
            "installer": "uv" if uv_bin else "pip",
            "requested": pinned_targets,
            "installed_count": len(verified_graph),
            "verified_graph": verified_graph,
        }
        append_audit({"action": "install_ok", **res})
        return res


def main():
    p = argparse.ArgumentParser(description="Blue Lodge Sovereign .venv Package Guard")
    sub = p.add_subparsers(dest="cmd", required=True)

    p_aud = sub.add_parser("audit", help="Audit package(s) without installing")
    p_aud.add_argument("packages", nargs="+")

    p_inst = sub.add_parser("install", help="Verify and hash-pin install wheel(s) into .venv")
    p_inst.add_argument("packages", nargs="+")
    p_inst.add_argument("--approve", action="store_true", help="Operator approval for Tier B packages")
    p_inst.add_argument("--venv", default=None, help="Target virtualenv path (default: $LODGE_DIR/.venv)")
    p_inst.add_argument("--create-venv", action="store_true", help="Create isolated virtualenv if missing")

    sub.add_parser("allowlist", help="Show curated Tier A allowlist")

    args = p.parse_args()
    if args.cmd == "allowlist":
        policy, allow, _ = load_policy()
        print(json.dumps({"policy": policy, "allowlist": allow}, indent=2))
        return 0
    if args.cmd == "audit":
        out = [audit_package(pkg) for pkg in args.packages]
        print(json.dumps(out if len(out) > 1 else out[0], indent=2))
        return 0 if all(r["tier"] != "C" for r in out) else 2
    if args.cmd == "install":
        res = install_packages(args.packages, approve_tier_b=args.approve, venv_dir=args.venv, create_venv=args.create_venv)
        print(json.dumps(res, indent=2))
        return 0 if res["status"] in ("INSTALLED", "ALREADY_INSTALLED") else 2
    return 1


if __name__ == "__main__":
    sys.exit(main())
