#!/usr/bin/env python3
import json
import os
import re

GEORGE_DIR = os.path.expanduser("/opt/blue-lodge/.george")
RESEARCH_DIR = os.path.join(GEORGE_DIR, "research")
INDEX_PATH = os.path.join(RESEARCH_DIR, "research_index.jsonl")

DOMAIN_METADATA = {
    "academic": {
        "category": "AI / ML Science",
        "theme": "Autonomous Intelligence & Deep Learning"
    },
    "engineering": {
        "category": "Systems & Security",
        "theme": "Engineering & Systems Integrity"
    },
    "finance": {
        "category": "Finance & Macro",
        "theme": "Cardano DeFi & Global Macro"
    },
    "gaming": {
        "category": "Gaming & Emulation",
        "theme": "Interactive Mechanics & Emulation R&D"
    },
    "general_sports_auto": {
        "category": "Sports & Automotive",
        "theme": "Athletic Science & Automotive Engineering"
    }
}

def classify(slug, scratchpad_path=""):
    # 1. Check scratchpad first
    if scratchpad_path and os.path.isfile(scratchpad_path):
        try:
            with open(scratchpad_path, "r", encoding="utf-8") as f:
                for line in f:
                    if line.strip().startswith("**Domain:**"):
                        val = line.strip().replace("**Domain:**", "").strip().lower()
                        if "eng" in val or "sys" in val: return "engineering"
                        if "fin" in val: return "finance"
                        if "gam" in val: return "gaming"
                        if "sport" in val or "auto" in val: return "general_sports_auto"
                        if "acad" in val: return "academic"
        except Exception:
            pass

    # 2. Tokenize slug
    tokens = set(re.findall(r'[a-zA-Z0-9]+', slug.lower()))
    if tokens & {"sport", "sports", "racing", "porsche", "nfl", "f1", "automotive", "telemetry", "dyno"}:
        return "general_sports_auto"
    if tokens & {"pgp", "ed25519", "kernel", "linux", "ebpf", "driver", "rfc", "cve", "protocol", "attestation", "attestations"}:
        return "engineering"
    if tokens & {"cardano", "finance", "defi", "sec", "stock", "tokenomics", "hydra"}:
        return "finance"
    if tokens & {"emulat", "emulation", "decompil", "ps5", "ps2", "n64", "jit", "game", "gaming"}:
        return "gaming"
    return "academic"

def process_dossiers():
    if not os.path.exists(RESEARCH_DIR):
        print("Research dir does not exist")
        return

    migrated_count = 0
    for entry in sorted(os.listdir(RESEARCH_DIR)):
        entry_path = os.path.join(RESEARCH_DIR, entry)
        if not os.path.isdir(entry_path) or entry in ["quarantine", ".git"]:
            continue

        dossier_path = os.path.join(entry_path, "dossier.md")
        scratchpad_path = os.path.join(entry_path, "scratchpad.md")
        if not os.path.isfile(dossier_path):
            continue

        domain = classify(entry, scratchpad_path)
        meta = DOMAIN_METADATA.get(domain, DOMAIN_METADATA["academic"])
        cat = meta["category"]
        thm = meta["theme"]

        with open(dossier_path, "r", encoding="utf-8") as f:
            content = f.read()

        # If already starts with frontmatter, strip it and re-write cleanly
        body = content
        title = entry.replace("-", " ")
        if content.startswith("---"):
            lines = content.split("\n")
            end_idx = -1
            for idx, line in enumerate(lines[1:], start=1):
                if line.strip() == "---":
                    end_idx = idx
                    break
            if end_idx != -1:
                body = "\n".join(lines[end_idx + 1:]).lstrip()

        for line in body.split("\n"):
            if line.strip().startswith("# "):
                title = line.strip().lstrip("# ").replace("Sovereign Research Dossier:", "").strip()
                break

        frontmatter = (
            f"---\n"
            f"topic: \"{title}\"\n"
            f"category: \"{cat}\"\n"
            f"domain: \"{domain}\"\n"
            f"theme: \"{thm}\"\n"
            f"date: \"2026-10-11\"\n"
            f"status: \"verified\"\n"
            f"---\n\n"
        )
        with open(dossier_path, "w", encoding="utf-8") as f:
            f.write(frontmatter + body)
        migrated_count += 1
        print(f"[{domain.upper()}] {entry} -> {cat}")

    print(f"\nCleanly regenerated frontmatter for {migrated_count} dossiers.")

def process_index():
    if not os.path.exists(INDEX_PATH):
        return
    updated_lines = []
    with open(INDEX_PATH, "r", encoding="utf-8") as f:
        for line in f:
            if not line.strip(): continue
            try:
                rec = json.loads(line)
                slug = rec.get("slug", "")
                scratchpad_path = os.path.join(RESEARCH_DIR, slug, "scratchpad.md")
                dom = classify(slug, scratchpad_path)
                meta = DOMAIN_METADATA.get(dom, DOMAIN_METADATA["academic"])
                rec["domain"] = dom
                rec["category"] = meta["category"]
                rec["theme"] = meta["theme"]
                updated_lines.append(json.dumps(rec))
            except Exception as e:
                updated_lines.append(line.strip())

    with open(INDEX_PATH, "w", encoding="utf-8") as f:
        f.write("\n".join(updated_lines) + "\n")
    print(f"Updated {len(updated_lines)} index records in {INDEX_PATH}")

if __name__ == "__main__":
    process_dossiers()
    process_index()
