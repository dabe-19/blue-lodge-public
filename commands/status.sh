#!/bin/bash
# DESC: Display live George engine vitals, compute topology, and active tasks
# Usage: /status

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/endpoints.sh" 2>/dev/null || true

cmd_status() {
    ui_section "George Sovereign Status"
    
    # Active Inference
    local inf_name="${TIER1_NAME:-cuda-workhorse}"
    local inf_url="${TIER1_URL:-http://127.0.0.1:8080}"
    local inf_model="${TIER1_MODEL:-ternary-bonsai-27b}"
    echo "  Inference:   Tier 1 [Master] ($inf_model @ $inf_url)"
    echo "  Context:     ${TIER1_CONTEXT:-24576} tokens"
    echo "  Platform:    ${LODGE_PLATFORM:-linux} (WSL2 / Ubuntu)"
    
    # GPU Hardware
    if command -v nvidia-smi &>/dev/null; then
        local gpu_info
        gpu_info=$(nvidia-smi --query-gpu=name,temperature.gpu,power.draw,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -n 1)
        if [ -n "$gpu_info" ]; then
            IFS=',' read -r gname gtemp gpow gused gtot <<< "$gpu_info"
            echo "  GPU 0:       $(echo "$gname" | xargs) [${gtemp// /}°C, $(echo "$gpow" | xargs)W, $(echo "$gused" | xargs)/$(echo "$gtot" | xargs) MB VRAM]"
        fi
    fi
    
    # Workspace & Git
    echo "  Workspace:   $LODGE_DIR"
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "detached")
    echo "  Git Branch:  $branch"
    
    # Web UI Daemon
    local web_pid
    web_pid=$(pgrep -f "george-web" 2>/dev/null | head -n 1)
    if [ -n "$web_pid" ]; then
        echo "  Web UI:      Online (PID $web_pid @ http://127.0.0.1:3000)"
    else
        echo "  Web UI:      Offline"
    fi
    
    # Active Tasks
    local active_count=0
    if [ -d "$LODGE_DIR/.sandboxes" ]; then
        active_count=$(find "$LODGE_DIR/.sandboxes" -maxdepth 1 -type d ! -name ".*" ! -exec test -e "{}/.done" ';' -print 2>/dev/null | wc -l)
    fi
    echo "  Live Tasks:  $active_count active"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_status "$@"
fi
