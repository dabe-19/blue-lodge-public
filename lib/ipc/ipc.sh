#!/bin/bash
# ── George: Modern IPC & Flow Control Protocol (v2) ──────────────────
# Unified entrypoint for George's async/await credit-based IPC.
source "$(dirname "${BASH_SOURCE[0]}")/fifo_ipc.sh"
source "$(dirname "${BASH_SOURCE[0]}")/event_bus.sh"
