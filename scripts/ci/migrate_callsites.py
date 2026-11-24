#!/usr/bin/env python3
"""
Full Call-Site Migration Script for Blue Lodge.
Migrates all unpartitioned references of lib/<file>.sh and scripts/<file>.sh
to their exact domain subdirectories, and optionally applies the changes to disk.
"""

import os
import re
import sys
from pathlib import Path

LODGE_ROOT = Path(__file__).resolve().parents[2]
APPLY = "--apply" in sys.argv

# 1. Build mapping of lib domain files
LIB_DOMAINS = ["core", "ipc", "tools", "knowledge", "sys", "comms", "memory", "agents", "ui"]
lib_map = {}
for domain in LIB_DOMAINS:
    dpath = LODGE_ROOT / "lib" / domain
    if dpath.is_dir():
        for f in dpath.glob("*"):
            if f.is_file() and not f.is_symlink():
                lib_map[f.name] = f"{domain}/{f.name}"

# Special override: auth.sh is canonical in core/auth.sh
lib_map["auth.sh"] = "core/auth.sh"

# 2. Build mapping of scripts domain files
SCRIPT_DOMAINS = ["ci", "inference", "infra", "monitor", "training", "colab_training", "quant_research", "workers"]
scripts_map = {}
for domain in SCRIPT_DOMAINS:
    dpath = LODGE_ROOT / "scripts" / domain
    if dpath.is_dir():
        for f in dpath.glob("*"):
            if f.is_file() and not f.is_symlink():
                scripts_map[f.name] = f"{domain}/{f.name}"

print(f"Loaded {len(lib_map)} lib mappings and {len(scripts_map)} script mappings.")

TARGET_EXTS = {".sh", ".py", ".md", ".rs", ".json", ".conf"}
TARGET_DIRS = ["lib", "scripts", "commands", "tests", "bin", ".agents", "web"]
TARGET_FILES = ["lodge", "soul.md", "Soul.md", "GEORGE.md"]

def get_target_files():
    files = []
    for tf in TARGET_FILES:
        p = LODGE_ROOT / tf
        if p.exists() and not p.is_symlink():
            files.append(p)
    for td in TARGET_DIRS:
        dp = LODGE_ROOT / td
        if dp.is_dir():
            for root, _, filenames in os.walk(dp):
                # Skip build artifacts, git, venvs, sandboxes, etc.
                if any(x in root for x in [".git", ".venv", "node_modules", ".sandboxes", ".george", "web/target"]):
                    continue
                for fn in filenames:
                    p = Path(root) / fn
                    if p.suffix in TARGET_EXTS or p.name in ["lodge", "scaffold", "lodge-lint", "okf", "george-ipc"]:
                        if not p.is_symlink():
                            files.append(p)
    return files

all_targets = get_target_files()
print(f"Inspecting {len(all_targets)} source files...")

changes = {}

for p in all_targets:
    if p.name == "migrate_callsites.py":
        continue
    try:
        content = p.read_text(encoding="utf-8", errors="ignore")
    except Exception as e:
        continue

    new_content = content

    # Replace lib/sys/auth.sh with lib/core/auth.sh
    new_content = re.sub(r'\blib/sys/auth\.sh\b', 'lib/core/auth.sh', new_content)

    # Replace lib/<name> with lib/<domain>/<name>
    for name, rel_path in lib_map.items():
        pattern = r'(\blib/)(?!' + '|'.join(re.escape(d + '/') for d in LIB_DOMAINS) + r')(' + re.escape(name) + r')\b'
        new_content = re.sub(pattern, r'\g<1>' + rel_path, new_content)

    # Replace scripts/<name> with scripts/<domain>/<name>
    for name, rel_path in scripts_map.items():
        pattern = r'(\bscripts/)(?!' + '|'.join(re.escape(d + '/') for d in SCRIPT_DOMAINS) + r')(' + re.escape(name) + r')\b'
        new_content = re.sub(pattern, r'\g<1>' + rel_path, new_content)

    if new_content != content:
        rel_p = str(p.relative_to(LODGE_ROOT))
        changes[rel_p] = (p, content, new_content)

print(f"\nFiles modified: {len(changes)}")
for rel_p, (p, c_old, c_new) in sorted(changes.items()):
    if APPLY:
        p.write_text(c_new, encoding="utf-8")
        print(f"  [APPLIED] {rel_p}")
    else:
        print(f"  [DRY-RUN] {rel_p}")

if APPLY:
    print("\nCall-site migration successfully written to disk.")
else:
    print("\nDry-run complete. Run with --apply to write changes to disk.")
