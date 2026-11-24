#!/bin/bash
# INTERVAL: 3600
# DESC: Memory Flow Layer-2 TTL cache GC — prunes expired AssembledPresent cache files from the flow.cache dir. Pure one-shot; CRON-priority class maintenance, zero daemon, zero writes to recall.db.
# SCOPE: system

LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

[ -f "$LODGE_DIR/lib/memory/flow.sh" ] || exit 0

source "$LODGE_DIR/lib/memory/flow.sh"

# Default TTL is 3600s; honor operator override if exported.
flow_cache_gc

# Quiet on success (cron hygiene); log only if the GC itself errored.
exit 0
