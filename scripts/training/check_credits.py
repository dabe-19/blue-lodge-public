#!/usr/bin/env python3
"""
scripts/training/check_credits.py
Queries Google Colab Compute Units (ADC or OAuth2) AND returns structured prerequisite
readiness diagnostics (Colab CLI, gcloud CLI, Google ADC, OAuth2, HF Token, Local CUDA)
for both the Forge Web UI and pre-start preflight checks.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

WORKSPACE_ROOT = Path(os.environ.get("LODGE_DIR", Path(__file__).resolve().parent.parent.parent))
GEORGE_DIR = Path(os.environ.get("GEORGE_DIR", WORKSPACE_ROOT / ".george"))
VENV_COLAB = WORKSPACE_ROOT / ".venv" / "bin" / "colab"
SYSTEM_COLAB = shutil.which("colab")
COLAB_BIN = os.environ.get("COLAB_BIN") or (str(VENV_COLAB) if VENV_COLAB.exists() else (SYSTEM_COLAB or ""))


def _read_key_from_files(names: tuple[str, ...]) -> tuple[str | None, str | None]:
    for n in names:
        v = os.environ.get(n, "").strip()
        if v:
            return v, f"env:{n}"
    for fname in (GEORGE_DIR / "keys.conf", GEORGE_DIR / "secrets.env"):
        if not fname.is_file():
            continue
        try:
            for line in fname.read_text(encoding="utf-8", errors="ignore").splitlines():
                s = line.strip()
                if not s or s.startswith("#") or "=" not in s:
                    continue
                k, val = s.split("=", 1)
                k = k.strip().removeprefix("export ").strip()
                val = val.strip().strip('"').strip("'")
                if k in names and val:
                    return val, str(fname.name)
        except OSError:
            continue
    return None, None


def _find_gcloud() -> str | None:
    p = shutil.which("gcloud")
    if p:
        return p
    for cand in (
        Path.home() / "google-cloud-sdk" / "bin" / "gcloud",
        Path("/usr/local/bin/gcloud"),
        Path("/opt/google-cloud-sdk/bin/gcloud"),
    ):
        if cand.is_file() and os.access(cand, os.X_OK):
            return str(cand)
    return None


def _find_adc() -> tuple[bool, str | None]:
    cands = []
    env_p = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS", "").strip()
    if env_p:
        cands.append(Path(env_p))
    cands.append(Path.home() / ".config" / "gcloud" / "application_default_credentials.json")
    cands.append(Path("/root/.config/gcloud/application_default_credentials.json"))
    for p in cands:
        try:
            if p.is_file() and p.stat().st_size > 20:
                try:
                    json.loads(p.read_text(encoding="utf-8"))
                    return True, str(p)
                except (OSError, ValueError):
                    return False, str(p)
        except OSError:
            continue
    return False, None


def _find_colab_oauth() -> tuple[bool, str | None]:
    for base in (Path.home() / ".config" / "colab-cli", Path("/root/.config/colab-cli")):
        try:
            if not base.is_dir():
                continue
            for fname in ("token.json", "credentials.json", "oauth_token.json"):
                p = base / fname
                if p.is_file() and p.stat().st_size > 20:
                    return True, str(p)
        except OSError:
            continue
    return False, None


def get_prerequisites() -> dict:
    """Return structured readiness for every Colab and Local training dependency."""
    colab_ok = bool(COLAB_BIN and os.path.isfile(COLAB_BIN) and os.access(COLAB_BIN, os.X_OK))
    colab_ver = None
    if colab_ok:
        try:
            r = subprocess.run([COLAB_BIN, "version"], capture_output=True, text=True, timeout=10, check=False)
            colab_ver = (r.stdout or r.stderr).strip().splitlines()[0] if (r.stdout or r.stderr).strip() else None
        except (OSError, subprocess.TimeoutExpired):
            pass

    gcloud_path = _find_gcloud()
    adc_ok, adc_path = _find_adc()
    oauth_ok, oauth_path = _find_colab_oauth()
    hf_val, hf_src = _read_key_from_files(("HF_TOKEN", "HUGGINGFACE_TOKEN", "HUGGING_FACE_HUB_TOKEN"))

    local_gpus = []
    if shutil.which("nvidia-smi"):
        try:
            r = subprocess.run(
                ["nvidia-smi", "--query-gpu=index,name,memory.used,memory.total", "--format=csv,noheader,nounits"],
                capture_output=True, text=True, timeout=10, check=False,
            )
            for line in r.stdout.strip().splitlines():
                parts = [x.strip() for x in line.split(",")]
                if len(parts) >= 4:
                    local_gpus.append({
                        "index": int(parts[0]), "name": parts[1],
                        "used_mb": int(parts[2]), "total_mb": int(parts[3]),
                    })
        except (OSError, subprocess.TimeoutExpired, ValueError):
            pass

    train_py = os.environ.get("BLUE_LODGE_TRAIN_PYTHON", "").strip()
    local_env_ok = False
    if train_py and os.path.isfile(train_py) and os.access(train_py, os.X_OK):
        local_env_ok = True
    else:
        for cand in (WORKSPACE_ROOT / ".venv" / "bin" / "python3", Path(sys.executable)):
            if cand.is_file():
                try:
                    r = subprocess.run(
                        [str(cand), "-c", "import torch, transformers, peft, trl, datasets"],
                        capture_output=True, text=True, timeout=15, check=False,
                    )
                    if r.returncode == 0:
                        train_py = str(cand)
                        local_env_ok = True
                        break
                except (OSError, subprocess.TimeoutExpired):
                    pass

    issues = []
    if not colab_ok:
        issues.append({
            "component": "colab_cli",
            "severity": "error",
            "message": "Colab CLI not installed (.venv/bin/colab missing).",
            "fix": "uv pip install --python .venv/bin/python colab-cli",
        })
    if not gcloud_path and not adc_ok and not oauth_ok:
        issues.append({
            "component": "gcloud_cli",
            "severity": "warning",
            "message": "Google Cloud CLI (gcloud) not installed.",
            "fix": "curl -fsSL https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz | tar -xz -C \"$HOME\" && \"$HOME/google-cloud-sdk/install.sh\" --quiet --path-update true",
        })
    if not adc_ok and not oauth_ok:
        issues.append({
            "component": "adc_credentials",
            "severity": "error",
            "message": "Google ADC credentials not configured (no application_default_credentials.json found).",
            "fix": "gcloud auth application-default login --no-launch-browser",
        })
    if not hf_val:
        issues.append({
            "component": "hf_token",
            "severity": "info",
            "message": "HF_TOKEN not set in .george/keys.conf (required for gated models like google/gemma-4-31b-it or private HF backups).",
            "fix": "Add HF_TOKEN=\"hf_...\" to .george/keys.conf (or set via Forge UI Settings).",
        })

    return {
        "colab_ready": colab_ok and (adc_ok or oauth_ok),
        "preferred_auth": "adc" if adc_ok else ("oauth2" if oauth_ok else "adc"),
        "colab_cli": {"installed": colab_ok, "path": COLAB_BIN or None, "version": colab_ver},
        "gcloud_cli": {"installed": bool(gcloud_path), "path": gcloud_path},
        "adc_credentials": {"configured": adc_ok, "path": adc_path},
        "oauth2_credentials": {"configured": oauth_ok, "path": oauth_path},
        "hf_token": {"configured": bool(hf_val), "source": hf_src},
        "local_train_env": {"installed": local_env_ok, "python": train_py or None, "gpus": local_gpus},
        "issues": issues,
    }


def get_colab_usage(auth: str | None = None) -> dict:
    prereqs = get_prerequisites()
    eff_auth = auth or prereqs["preferred_auth"]
    if not prereqs["colab_cli"]["installed"]:
        return {
            "status": "error",
            "auth": eff_auth,
            "message": "Colab CLI is not installed (.venv/bin/colab missing).",
            "prerequisites": prereqs,
        }
    if eff_auth == "adc" and not prereqs["adc_credentials"]["configured"]:
        return {
            "status": "error",
            "auth": eff_auth,
            "message": "Google ADC credentials not configured. Run: gcloud auth application-default login --no-launch-browser",
            "prerequisites": prereqs,
        }

    cmd = [COLAB_BIN, f"--auth={eff_auth}", "usage"]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=30, check=False)
        if res.returncode != 0:
            return {
                "status": "error",
                "auth": eff_auth,
                "message": res.stderr.strip() or res.stdout.strip() or "Failed to run colab usage",
                "prerequisites": prereqs,
            }

        balance = None
        rate = None
        assignments = 0
        for line in res.stdout.splitlines():
            line_clean = line.strip()
            if "Current balance:" in line_clean:
                parts = line_clean.split("Current balance:")[1].strip().split()
                if parts:
                    try:
                        balance = float(parts[0])
                    except ValueError:
                        balance = parts[0]
            elif "Usage rate:" in line_clean:
                rate = line_clean.split("Usage rate:")[1].strip()
            elif "Active assignments:" in line_clean:
                try:
                    assignments = int(line_clean.split("Active assignments:")[1].strip())
                except ValueError:
                    assignments = 0

        return {
            "status": "ok",
            "auth": eff_auth,
            "balance": balance,
            "rate": rate,
            "active_assignments": assignments,
            "raw": res.stdout.strip(),
            "prerequisites": prereqs,
        }
    except subprocess.TimeoutExpired:
        return {"status": "error", "auth": eff_auth, "message": "Timed out contacting Google Colab API", "prerequisites": prereqs}
    except Exception as e:
        return {"status": "error", "auth": eff_auth, "message": str(e), "prerequisites": prereqs}


def main():
    as_json = "--json" in sys.argv
    auth_arg = None
    for a in sys.argv[1:]:
        if a.startswith("--auth="):
            auth_arg = a.split("=", 1)[1]
    data = get_colab_usage(auth=auth_arg)
    if as_json:
        print(json.dumps(data, indent=2))
        return

    if data["status"] == "ok":
        print(f"Colab Compute Units Balance: {data['balance']} CU (Rate: {data['rate']}, Active: {data['active_assignments']}, Auth: {data['auth']})")
    else:
        print(f"Error querying Colab balance: {data['message']}", file=sys.stderr)
        for iss in data.get("prerequisites", {}).get("issues", []):
            print(f"  [{iss['severity'].upper()}] {iss['component']}: {iss['message']}", file=sys.stderr)
            print(f"    Fix: {iss['fix']}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
