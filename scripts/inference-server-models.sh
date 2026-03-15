#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# inference-server-models.sh — Model Loader for George Remote Nodes
# ═══════════════════════════════════════════════════════════════
# Pulls a model via Ollama, resolves the GGUF blob path, and
# starts llama-server pointing at it with Jinja chat templates.
#
# This is the bridge between Ollama (model manager) and
# llama-server (GPU inference engine).
#
# Usage:
#   ./scripts/inference-server-models.sh qwen3:8b        # pull + start
#   ./scripts/inference-server-models.sh --list           # list available
#   ./scripts/inference-server-models.sh --resolve qwen3:8b  # print GGUF path
#   ./scripts/inference-server-models.sh --stop           # stop running server
#
# Environment overrides:
#   LLAMA_BIN           llama-server binary (default: ~/llama.cpp/build/bin/llama-server)
#   LLAMA_PORT          Listen port (default: 8080)
#   LLAMA_HOST          Bind address (default: 0.0.0.0)
#   GPU_LAYERS          GPU layers to offload (default: 99 = all)
#   CTX_SIZE            Context window (default: 8192)
#   OLLAMA_URL          Ollama API (default: http://127.0.0.1:11434)
#   OLLAMA_MODELS       Ollama model storage dir (default: auto-detect)

set -euo pipefail

trap 'printf "\n\033[31m✗ Failed at line %s: %s\033[0m\n" "$LINENO" "$BASH_COMMAND"; exit 1' ERR

# ── Colors ─────────────────────────────────────────────────────
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_CYAN='\033[36m'
C_GREEN='\033[32m'
C_RED='\033[31m'
C_YELLOW='\033[33m'
C_RESET='\033[0m'

_step()  { printf "\n${C_BOLD}${C_CYAN}[%s]${C_RESET} %s\n" "$1" "$2"; }
_ok()    { printf "${C_GREEN}  ✓ %s${C_RESET}\n" "$1"; }
_fail()  { printf "${C_RED}  ✗ %s${C_RESET}\n" "$1"; exit 1; }
_warn()  { printf "${C_YELLOW}  ⚠ %s${C_RESET}\n" "$1"; }
_dim()   { printf "${C_DIM}    %s${C_RESET}\n" "$1"; }

# ── Config ─────────────────────────────────────────────────────
LLAMA_BIN="${LLAMA_BIN:-$HOME/llama.cpp/build/bin/llama-server}"
LLAMA_PORT="${LLAMA_PORT:-8080}"
LLAMA_HOST="${LLAMA_HOST:-0.0.0.0}"
GPU_LAYERS="${GPU_LAYERS:-99}"
CTX_SIZE="${CTX_SIZE:-8192}"
OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
THREADS="${THREADS:-$(nproc 2>/dev/null || echo 4)}"

# Auto-detect Ollama models directory
_detect_ollama_dir() {
    if [ -n "${OLLAMA_MODELS:-}" ] && [ -d "$OLLAMA_MODELS" ]; then
        echo "$OLLAMA_MODELS"
        return
    fi
    # systemd default
    if [ -d "/usr/share/ollama/.ollama/models" ]; then
        echo "/usr/share/ollama/.ollama/models"
        return
    fi
    # user-local
    if [ -d "$HOME/.ollama/models" ]; then
        echo "$HOME/.ollama/models"
        return
    fi
    echo ""
}

OLLAMA_DIR="$(_detect_ollama_dir)"
PID_FILE="${TMPDIR:-/tmp}/george-llama-server.pid"
LOG_FILE="${TMPDIR:-/tmp}/george-llama-server.log"

# ── GGUF Blob Resolution ──────────────────────────────────────
# Given an Ollama model reference (e.g. "qwen3:8b"), resolve the
# GGUF file path from Ollama's blob store.
#
# Ollama stores models as:
#   manifests/registry.ollama.ai/library/<name>/<tag>   (library models)
#   manifests/registry.ollama.ai/<org>/<name>/<tag>     (namespaced)
#   manifests/hf.co/<org>/<repo>/<tag>                  (HuggingFace)
#
# The manifest JSON has layers[]; the GGUF is the one with
# mediaType "application/vnd.ollama.image.model".
# Its digest (sha256:xxx) maps to blobs/sha256-xxx.

_resolve_gguf() {
    local model_ref="$1"
    local ollama_dir="$OLLAMA_DIR"

    if [ -z "$ollama_dir" ] || [ ! -d "$ollama_dir" ]; then
        echo ""
        return 1
    fi

    # Split name:tag
    local _name _tag
    _tag="${model_ref##*:}"
    _name="${model_ref%:*}"
    [ "$_tag" = "$_name" ] && _tag="latest"

    # Try manifest conventions
    local _manifest=""
    local _prefix
    for _prefix in \
        "$ollama_dir/manifests/registry.ollama.ai/library/$_name/$_tag" \
        "$ollama_dir/manifests/registry.ollama.ai/$_name/$_tag" \
        "$ollama_dir/manifests/$_name/$_tag"; do
        if [ -f "$_prefix" ]; then
            _manifest="$_prefix"
            break
        fi
    done

    # HuggingFace convention
    if [ -z "$_manifest" ] && [[ "$_name" == hf.co/* ]]; then
        local _hf_path="$ollama_dir/manifests/$_name/$_tag"
        [ -f "$_hf_path" ] && _manifest="$_hf_path"
    fi

    if [ -z "$_manifest" ]; then
        echo ""
        return 1
    fi

    # Extract GGUF digest
    local _digest
    _digest=$(jq -r '.layers[] | select(.mediaType == "application/vnd.ollama.image.model") | .digest' "$_manifest" 2>/dev/null)
    if [ -z "$_digest" ]; then
        echo ""
        return 1
    fi

    local _blob="$ollama_dir/blobs/${_digest//:/-}"
    if [ -f "$_blob" ]; then
        echo "$_blob"
        return 0
    fi

    echo ""
    return 1
}

# ── Stop running server ────────────────────────────────────────
_stop_server() {
    if [ -f "$PID_FILE" ]; then
        local _pid
        _pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
            kill "$_pid" 2>/dev/null
            local _i=0
            while kill -0 "$_pid" 2>/dev/null && [ $_i -lt 20 ]; do
                sleep 0.5
                _i=$((_i + 1))
            done
            _ok "Stopped llama-server (PID $_pid)"
        fi
        rm -f "$PID_FILE"
    fi

    # Also check if anything is on the port
    local _port_pid
    _port_pid=$(lsof -ti :"$LLAMA_PORT" 2>/dev/null || true)
    if [ -n "$_port_pid" ]; then
        _warn "Port $LLAMA_PORT still in use by PID $_port_pid"
    fi
}

# ── List models ────────────────────────────────────────────────
_list_models() {
    _step "LIST" "Models available on this node"

    # From Ollama API
    local _tags
    _tags=$(curl -sf --max-time 5 "${OLLAMA_URL}/api/tags" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$_tags" ]; then
        printf "\n  ${C_DIM}%-30s %-10s %-8s %-8s %s${C_RESET}\n" "NAME" "PARAMS" "QUANT" "SIZE" "GGUF RESOLVED"
        echo "$_tags" | jq -r '.models[] | "\(.name)\t\(.details.parameter_size // "?")\t\(.details.quantization_level // "?")\t\(.size)"' 2>/dev/null | \
        while IFS=$'\t' read -r _n _p _q _s; do
            local _size_gb
            _size_gb=$(echo "scale=1; $_s / 1073741824" | bc 2>/dev/null || echo "?")
            local _gguf
            _gguf=$(_resolve_gguf "$_n" 2>/dev/null)
            local _resolved="✗"
            [ -n "$_gguf" ] && _resolved="✓"
            printf "  %-30s %-10s %-8s %-7sGB %s\n" "$_n" "$_p" "$_q" "$_size_gb" "$_resolved"
        done
    else
        _warn "Cannot reach Ollama at $OLLAMA_URL"
        _dim "Start Ollama: ollama serve"
    fi

    # Show what's loaded in Ollama
    local _ps
    _ps=$(curl -sf --max-time 3 "${OLLAMA_URL}/api/ps" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$_ps" ]; then
        local _loaded
        _loaded=$(echo "$_ps" | jq '.models | length' 2>/dev/null)
        if [ "${_loaded:-0}" -gt 0 ]; then
            echo ""
            _dim "Currently loaded in Ollama:"
            echo "$_ps" | jq -r '.models[] | "    \(.name)  vram=\(.size_vram / 1073741824 | . * 100 | floor / 100)GB"' 2>/dev/null
        fi
    fi

    # Show llama-server status
    echo ""
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
        local _health
        _health=$(curl -sf --max-time 2 "http://127.0.0.1:${LLAMA_PORT}/health" 2>/dev/null)
        local _status
        _status=$(echo "$_health" | jq -r '.status // "unknown"' 2>/dev/null)
        _ok "llama-server running on port $LLAMA_PORT (status: ${_status})"
    else
        _dim "llama-server: not running"
    fi
}

# ── Pull + Start ───────────────────────────────────────────────
_pull_and_start() {
    local model_ref="$1"

    printf "\n${C_BOLD}═══ George Model Loader ═══${C_RESET}\n"
    _dim "Model: $model_ref"
    _dim "GPU layers: $GPU_LAYERS | Context: $CTX_SIZE | Port: $LLAMA_PORT"

    # ── Step 1: Ensure model is pulled ─────────────────────────
    _step "1" "Ensuring model is pulled: $model_ref"

    # Check if already available
    local _gguf
    _gguf=$(_resolve_gguf "$model_ref" 2>/dev/null)
    if [ -n "$_gguf" ]; then
        _ok "Already pulled — GGUF resolved"
    else
        _dim "Pulling via Ollama..."
        if ! ollama pull "$model_ref"; then
            # Try via API if CLI not in path
            local _result
            _result=$(curl -sf --max-time 600 "${OLLAMA_URL}/api/pull" \
                -d "{\"name\":\"$model_ref\",\"stream\":false}" 2>/dev/null)
            if [ $? -ne 0 ]; then
                _fail "Pull failed for $model_ref"
            fi
        fi
        _ok "Pull complete"

        # Re-resolve
        _gguf=$(_resolve_gguf "$model_ref" 2>/dev/null)
        if [ -z "$_gguf" ]; then
            _fail "Model pulled but GGUF blob not found — check OLLAMA_MODELS dir"
        fi
    fi

    local _gguf_size
    _gguf_size=$(du -h "$_gguf" 2>/dev/null | cut -f1)
    _ok "GGUF: $_gguf ($_gguf_size)"

    # ── Step 2: Stop existing server ───────────────────────────
    _step "2" "Stopping existing llama-server (if running)"
    _stop_server

    # ── Step 3: Unload from Ollama ─────────────────────────────
    # If Ollama has this model loaded, it's holding VRAM. Unload it
    # so llama-server can use the GPU.
    _step "3" "Unloading model from Ollama (freeing VRAM)"
    curl -sf --max-time 10 "${OLLAMA_URL}/api/generate" \
        -d "{\"model\":\"$model_ref\",\"keep_alive\":0}" &>/dev/null || true
    sleep 1
    _ok "Ollama VRAM released"

    # ── Step 4: Check binary ───────────────────────────────────
    _step "4" "Checking llama-server binary"
    if [ ! -x "$LLAMA_BIN" ]; then
        _fail "llama-server not found: $LLAMA_BIN (run inference-server-install.sh first)"
    fi
    _ok "$LLAMA_BIN"

    # ── Step 5: Start llama-server ─────────────────────────────
    _step "5" "Starting llama-server"

    local _launch_args=(
        -m "$_gguf"
        --port "$LLAMA_PORT"
        --host "$LLAMA_HOST"
        -ngl "$GPU_LAYERS"
        -c "$CTX_SIZE"
        --threads "$THREADS"
        --parallel 1
        --jinja
    )

    _dim "Command: llama-server ${_launch_args[*]}"

    > "$LOG_FILE"
    "$LLAMA_BIN" "${_launch_args[@]}" > "$LOG_FILE" 2>&1 &
    local _server_pid=$!
    echo "$_server_pid" > "$PID_FILE"
    _dim "PID: $_server_pid"

    # ── Step 6: Wait for healthy ───────────────────────────────
    _step "6" "Waiting for server to become healthy"
    local _tries=0
    local _healthy=0
    while [ $_tries -lt 60 ]; do
        sleep 1

        if ! kill -0 "$_server_pid" 2>/dev/null; then
            echo ""
            _fail "Server died during startup. Log tail:\n$(tail -15 "$LOG_FILE")"
        fi

        local _status
        _status=$(curl -sf --max-time 2 "http://127.0.0.1:${LLAMA_PORT}/health" 2>/dev/null | jq -r '.status // ""' 2>/dev/null || true)

        if [ "$_status" = "ok" ]; then
            _healthy=1
            break
        elif [ "$_status" = "loading model" ]; then
            printf "\r${C_DIM}    Loading model... (%ds)${C_RESET}  " "$_tries"
        else
            printf "\r${C_DIM}    Waiting... (%ds)${C_RESET}  " "$_tries"
        fi
        _tries=$((_tries + 1))
    done
    echo ""

    if [ "$_healthy" -eq 0 ]; then
        _fail "Server not healthy after 60s. Log:\n$(tail -20 "$LOG_FILE")"
    fi

    # Check GPU offload
    local _gpu_info
    _gpu_info=$(grep "offloaded" "$LOG_FILE" 2>/dev/null | head -1 || true)
    if [ -n "$_gpu_info" ]; then
        _ok "GPU offload: $_gpu_info"
    fi

    _ok "Server healthy and ready"

    # ── Summary ────────────────────────────────────────────────
    printf "\n${C_BOLD}═══ Ready ═══${C_RESET}\n\n"
    printf "  %-22s %s\n" "Model:" "$model_ref"
    printf "  %-22s %s\n" "GGUF:" "$_gguf"
    printf "  %-22s %s\n" "Endpoint:" "http://${LLAMA_HOST}:${LLAMA_PORT}"
    printf "  %-22s %s\n" "PID:" "$_server_pid"
    printf "  %-22s %s\n" "Log:" "$LOG_FILE"
    echo ""
    _dim "Test: curl http://localhost:${LLAMA_PORT}/v1/chat/completions -d '{\"model\":\"default\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}'"
    _dim "Stop: $0 --stop"
    echo ""
}

# ═══════════════════════════════════════════════════════════════
# Main dispatch
# ═══════════════════════════════════════════════════════════════
case "${1:-}" in
    --list|-l)
        _list_models ;;
    --resolve|-r)
        [ -z "${2:-}" ] && _fail "Usage: $0 --resolve <model_ref>"
        _gguf=$(_resolve_gguf "$2")
        if [ -n "$_gguf" ]; then
            echo "$_gguf"
        else
            _fail "Could not resolve GGUF for: $2"
        fi
        ;;
    --stop|-s)
        _stop_server ;;
    --help|-h|"")
        printf "${C_BOLD}inference-server-models.sh${C_RESET} — Model loader for George remote nodes\n\n"
        printf "Usage:\n"
        _dim "$0 <model_ref>          Pull model + start llama-server"
        _dim "$0 --list               List available models"
        _dim "$0 --resolve <model>    Print GGUF blob path"
        _dim "$0 --stop               Stop running llama-server"
        echo ""
        printf "Examples:\n"
        _dim "$0 qwen3:8b"
        _dim "$0 llama3.1:8b"
        _dim "$0 mistral-nemo:12b"
        echo ""
        printf "Environment:\n"
        _dim "LLAMA_BIN=$LLAMA_BIN"
        _dim "LLAMA_PORT=$LLAMA_PORT"
        _dim "GPU_LAYERS=$GPU_LAYERS"
        _dim "CTX_SIZE=$CTX_SIZE"
        _dim "OLLAMA_URL=$OLLAMA_URL"
        _dim "OLLAMA_MODELS=${OLLAMA_DIR:-<not found>}"
        echo ""
        ;;
    -*)
        _fail "Unknown flag: $1 (try --help)" ;;
    *)
        _pull_and_start "$1" ;;
esac
