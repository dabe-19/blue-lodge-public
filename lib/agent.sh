#!/bin/bash
# ── George: Modern Agent Entrypoint & Backward Compatibility Adapter ─────
# Replaces the legacy 4-stage waterfall with the modern unified ReAct engine.
# Legacy implementation preserved in docs/archive/legacy_agent.sh

[ -n "${_LIB_AGENT_LOADED:-}" ] && return 0; _LIB_AGENT_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"

# Load legacy agent definitions for backward compatibility (functions, config vars, conversation buffer)
if [ -f "$LODGE_DIR/docs/archive/legacy_agent.sh" ]; then
    _LIB_AGENT_LOADED="" source "$LODGE_DIR/docs/archive/legacy_agent.sh"
fi

source "$LODGE_DIR/lib/endpoints.sh"
source "$LODGE_DIR/lib/ui_dashboard.sh"
source "$LODGE_DIR/lib/subagents.sh"
source "$LODGE_DIR/lib/react.sh"
source "$LODGE_DIR/lib/native_tools.sh"
source "$LODGE_DIR/lib/context_engine.sh"

# ── Modern ReAct Dispatch Override ──────────────────────────────────
agent_run() {
    react_run "$@"
}
