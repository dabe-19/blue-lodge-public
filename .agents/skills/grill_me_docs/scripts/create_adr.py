#!/usr/bin/env python3
import os
import sys

# Core internal utility library overview:
# - os: Handles cross-platform directory detection, creation, and filesystem checks.
# - sys: Exposes execution parameters (sys.argv) and error stream pipelines.

def main():
    if len(sys.argv) < 2:
        print("Error: Missing filename slug argument.", file=sys.stderr)
        sys.exit(1)
        
    slug = sys.argv[1]
    adr_dir = "docs/adr"
    
    # Initialize targeted directory structure lazily per specifications
    if not os.path.exists(adr_dir):
        os.makedirs(adr_dir)
        
    # Evaluate files to increment the sequential numerical sorting prefix
    existing_nums = [0]
    for filename in os.listdir(adr_dir):
        if filename.endswith(".md"):
            prefix = filename.split("-")[0]
            if prefix.isdigit():
                existing_nums.append(int(prefix))
                
    next_num = max(existing_nums) + 1
    adr_filename = f"{next_num:04d}-{slug}.md"
    full_path = os.path.join(adr_dir, adr_filename)
    
    adr_content = f"""# {next_num:04d} - {slug.replace('-', ' ').title()}

## Status
Accepted

## Context
Describe the architectural landscape and constraints driving this design decision.

## Decision
What is the explicit design choice made, and why? Limit to 1-3 sentences.

## Consequences
Detail the downstream implications, maintenance boundaries, and accepted trade-offs.
"""
    
    with open(full_path, "w", encoding="utf-8") as f:
        f.write(adr_content)
        
    print(f"SUCCESS: Emitted sequential architectural record at: {full_path}")

if __name__ == "__main__":
    main()