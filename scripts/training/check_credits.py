#!/usr/bin/env python3
"""
scripts/training/check_credits.py
Queries Google Cloud Colab Application Default Credentials (ADC) for compute units balance,
burn rate, and active assignments.
"""

import sys
import json
import shutil
import subprocess
from pathlib import Path

WORKSPACE_ROOT = Path(__file__).resolve().parent.parent.parent
VENV_COLAB = WORKSPACE_ROOT / ".venv" / "bin" / "colab"
SYSTEM_COLAB = shutil.which("colab")

COLAB_BIN = str(VENV_COLAB) if VENV_COLAB.exists() else (SYSTEM_COLAB or "colab")

def get_colab_usage(auth="adc"):
    cmd = [COLAB_BIN, f"--auth={auth}", "usage"]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if res.returncode != 0:
            return {
                "status": "error",
                "message": res.stderr.strip() or res.stdout.strip() or "Failed to run colab usage"
            }
        
        # Parse output:
        # Current balance: 1806.53 compute units
        # Usage rate: 0.00/hr
        # Active assignments: 0
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
            "balance": balance,
            "rate": rate,
            "active_assignments": assignments,
            "raw": res.stdout.strip()
        }
    except subprocess.TimeoutExpired:
        return {"status": "error", "message": "Timed out contacting Google Colab API"}
    except Exception as e:
        return {"status": "error", "message": str(e)}

def main():
    as_json = "--json" in sys.argv
    data = get_colab_usage()
    if as_json:
        print(json.dumps(data, indent=2))
        return

    if data["status"] == "ok":
        print(f"Colab Compute Units Balance: {data['balance']} CU (Rate: {data['rate']}, Active: {data['active_assignments']})")
    else:
        print(f"Error querying Colab balance: {data['message']}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
