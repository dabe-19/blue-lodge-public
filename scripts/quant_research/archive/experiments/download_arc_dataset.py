#!/usr/bin/env python3
"""
Download ARC-Challenge and ARC-Easy test datasets for standardized evaluation.
"""
import os
import json
import urllib.request

DATA_DIR = "/home/wsl-ops/blue-lodge/data/arc"
os.makedirs(DATA_DIR, exist_ok=True)

configs = ["ARC-Challenge", "ARC-Easy"]

for config in configs:
    out_file = os.path.join(DATA_DIR, f"{config.lower()}_test.json")
    if os.path.exists(out_file) and os.path.getsize(out_file) > 10000:
        print(f"[*] {config} already downloaded at {out_file}")
        continue

    print(f"[*] Fetching {config} from HuggingFace Datasets API...")
    rows = []
    offset = 0
    limit = 100

    while True:
        url = f"https://datasets-server.huggingface.co/rows?dataset=allenai%2Fai2_arc&config={config}&split=test&offset={offset}&limit={limit}"
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                data = json.loads(r.read())
                batch = [item["row"] for item in data.get("rows", [])]
                if not batch:
                    break
                rows.extend(batch)
                offset += len(batch)
                print(f"  Fetched {len(rows)} rows for {config}...")
                if len(batch) < limit:
                    break
        except Exception as e:
            print(f"  Error fetching at offset {offset}: {e}")
            break

    print(f"[✓] Saved {len(rows)} samples for {config} to {out_file}")
    with open(out_file, "w") as f:
        json.dump(rows, f, indent=2)
