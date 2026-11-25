#!/usr/bin/env bash
# Legacy compatibility wrapper — Blue Lodge now standardizes on upstream stock llama.cpp
# via scripts/infra/start_inference.sh.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/start_inference.sh" "$@"
