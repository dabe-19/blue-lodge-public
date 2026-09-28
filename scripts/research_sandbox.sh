#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
# George Sovereign Research Sandbox CLI Wrapper
# ══════════════════════════════════════════════════════════════════════
# Completely general research collection engine:
# 1. Takes an arbitrary topic query.
# 2. Performs non-greedy semantic cross-sectional search across diverse domains.
# 3. Ingests source page contents and extracts salient excerpts.
# 4. Compiles a structured research dossier with source links and citations.
# 5. Saves artifact if requested and returns full dossier to stdout for George.
#
# Usage:
#   research_sandbox.sh "<topic>" [sample_k] [output_file]
# ══════════════════════════════════════════════════════════════════════

set -euo pipefail

LODGE_DIR="${LODGE_DIR:-/home/wsl-ops/blue-lodge}"
export GEORGE_CONFIG_DIR="${GEORGE_CONFIG_DIR:-$LODGE_DIR/.george}"
source "$LODGE_DIR/lib/web.sh"

research_sandbox "$@"
