#!/usr/bin/env python3
"""
Build diverse multi-domain calibration dataset for llama-imatrix.
Combines:
  1. Varied Hermes agentic dialogues (code, JSON schema, tool calls, multi-turn reasoning)
  2. Dense encyclopedic text from WikiText-2
  3. Structured mathematical derivations & reasoning prompts
"""

import json
import os
import random

AGENT_JSON = "data/agent_bench/json-mode-agentic.json"
WIKI_RAW = "data/calibration/wiki.test.raw"
OUTPUT_TXT = "data/calibration/production_calibration.txt"

os.makedirs("data/calibration", exist_ok=True)

lines = []

# 1. Ingest agentic dialogues across diverse categories
if os.path.exists(AGENT_JSON):
    with open(AGENT_JSON, "r") as f:
        agent_data = json.load(f)
    
    # Group by category
    by_cat = {}
    for item in agent_data:
        cat = item.get("category", "General")
        by_cat.setdefault(cat, []).append(item)
    
    print(f"[*] Ingesting from {len(by_cat)} agent categories...")
    # Sample up to 3 per category to ensure maximum topic distribution
    for cat, items in by_cat.items():
        sample = items[:3]
        for it in sample:
            convs = it.get("conversations", [])
            for c in convs:
                role = c.get("from", "user")
                val = c.get("value", "")
                if val.strip():
                    lines.append(f"<|im_start|>{role}\n{val.strip()}<|im_end|>\n")

print(f"  ✓ Added {len(lines)} agentic dialogue turns.")

# 2. Add sections from WikiText-2
if os.path.exists(WIKI_RAW):
    with open(WIKI_RAW, "r") as f:
        wiki_text = f.read()
    paragraphs = [p.strip() for p in wiki_text.split("\n\n") if len(p.strip()) > 100]
    # Add top 150 paragraphs
    for p in paragraphs[:150]:
        lines.append(p + "\n\n")
    print(f"  ✓ Added {min(150, len(paragraphs))} diverse WikiText paragraphs.")

# 3. Add explicit mathematical and coding sequences
reasoning_samples = [
    "Solve the system of equations: 3x + 4y = 24 and 2x - y = 5.\nStep 1: Multiply second equation by 4: 8x - 4y = 20.\nStep 2: Add equations: 11x = 44 => x = 4.\nStep 3: Substitute x into 2x - y = 5: 8 - y = 5 => y = 3.\nVerification: 3(4) + 4(3) = 12 + 12 = 24. 2(4) - 3 = 5. Correct.",
    "Implement Dijkstra's shortest path algorithm in Python using heapq:\nimport heapq\ndef dijkstra(graph, start):\n    distances = {node: float('infinity') for node in graph}\n    distances[start] = 0\n    queue = [(0, start)]\n    while queue:\n        curr_dist, curr_node = heapq.heappop(queue)\n        if curr_dist > distances[curr_node]:\n            continue\n        for neighbor, weight in graph[curr_node].items():\n            dist = curr_dist + weight\n            if dist < distances[neighbor]:\n                distances[neighbor] = dist\n                heapq.heappush(queue, (dist, neighbor))\n    return distances",
    "Calculate the eigenvalue and eigenvector for matrix A = [[2, 1], [1, 2]].\nCharacteristic polynomial: det(A - lambda*I) = (2 - lambda)^2 - 1 = lambda^2 - 4*lambda + 3 = 0.\nRoots: (lambda - 3)(lambda - 1) = 0 => lambda_1 = 3, lambda_2 = 1.\nFor lambda = 3: (A - 3I)v = [[-1, 1], [1, -1]]v = 0 => v_1 = [1, 1]^T / sqrt(2).\nFor lambda = 1: (A - I)v = [[1, 1], [1, 1]]v = 0 => v_2 = [1, -1]^T / sqrt(2)."
]
for r in reasoning_samples:
    lines.append(f"<|im_start|>user\n{r}<|im_end|>\n")

with open(OUTPUT_TXT, "w") as f:
    f.writelines(lines)

size_kb = os.path.getsize(OUTPUT_TXT) / 1024
print(f"[✓] Created {OUTPUT_TXT} ({size_kb:.1f} KB, {len(lines)} blocks).")
