#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# start-local-prism.sh — Local CUDA llama.cpp-prism Sandbox Runner
# ═══════════════════════════════════════════════════════════════
# Launches the george-cuda-sandbox container with llama.cpp-prism
# and optimized flags for NVIDIA Ampere (RTX 3060 12GB / Dual 3060).
#
# Usage:
#   ./scripts/start-local-prism.sh [model.gguf]           # Run in foreground
#   ./scripts/start-local-prism.sh -d [model.gguf]        # Run as background daemon
#   ./scripts/start-local-prism.sh --stop                 # Stop local prism container
#   ./scripts/start-local-prism.sh --status               # Check container & server health
#
# Environment Overrides:
#   PORT                Host port (default: 8080, falls back to 8082 if 8080 in use)
#   CTX_SIZE            Context window size (default: 8192)
#   GPU_LAYERS          Layers to offload (default: 99 = all)
#   BATCH_SIZE          Batch size (default: 512)
#   UBATCH_SIZE         Micro-batch size (default: 256)
#   TENSOR_SPLIT        Multi-GPU split (e.g. "12,12" for dual 3060)

set -eo pipefail

LODGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER_NAME="george-prism-server"
DEFAULT_PORT=8080
DAEMON=0

# Colors
C_BOLD='\033[1m'
C_CYAN='\033[36m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_RED='\033[31m'
C_RESET='\033[0m'

_info() { printf "${C_BOLD}${C_CYAN}[+]${C_RESET} %s\n" "$1"; }
_ok()   { printf "${C_GREEN}[✓]${C_RESET} %s\n" "$1"; }
_warn() { printf "${C_YELLOW}[!]${C_RESET} %s\n" "$1"; }
_err()  { printf "${C_RED}[✗]${C_RESET} %s\n" "$1"; exit 1; }

# Parse arguments
MODEL_ARG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--daemon)
            DAEMON=1
            shift ;;
        --stop)
            if docker ps -a --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}$"; then
                _info "Stopping ${CONTAINER_NAME}..."
                docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
                _ok "Stopped ${CONTAINER_NAME}"
            else
                _warn "Container ${CONTAINER_NAME} is not running."
            fi
            exit 0 ;;
        --status)
            if docker ps --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}$"; then
                _ok "Container ${CONTAINER_NAME} is RUNNING"
                docker ps --filter "name=${CONTAINER_NAME}" --format "table {{.ID}}\t{{.Status}}\t{{.Ports}}"
                echo ""
                _info "Probing llama-server health..."
                curl -sf --max-time 3 http://127.0.0.1:8080/health 2>/dev/null || \
                curl -sf --max-time 3 http://127.0.0.1:8082/health 2>/dev/null || \
                _warn "Could not reach HTTP health endpoint yet (model may still be loading)."
            else
                _warn "Container ${CONTAINER_NAME} is NOT running."
            fi
            exit 0 ;;
        *)
            if [ -z "$MODEL_ARG" ]; then
                MODEL_ARG="$1"
            fi
            shift ;;
    esac
done

# Check Docker
command -v docker &>/dev/null || _err "Docker is not installed."

# Verify Image exists
if ! docker image inspect george-cuda-sandbox:latest &>/dev/null; then
    _err "Image george-cuda-sandbox:latest not found. Run ./scripts/start-cuda-sandbox.sh --build first."
fi

# Locate Model
GGUF_PATH=""
if [ -n "$MODEL_ARG" ]; then
    if [ -f "$MODEL_ARG" ]; then
        GGUF_PATH="$(readlink -f "$MODEL_ARG")"
    else
        _err "Specified model file does not exist: $MODEL_ARG"
    fi
else
    # Auto-detect Bonsai / Ternary in common locations
    for d in "$LODGE_ROOT/.george/models" "$HOME/models" "$HOME/.george/models"; do
        if [ -d "$d" ]; then
            m=$(find "$d" -maxdepth 3 -type f \( -iname "*bonsai*.gguf" -o -iname "*ternary*.gguf" \) 2>/dev/null | head -1)
            if [ -n "$m" ]; then
                GGUF_PATH="$m"
                break
            fi
        fi
    done
fi

[ -z "$GGUF_PATH" ] && _err "No model specified and none found in ~/models or .george/models. Usage: $0 [path/to/model.gguf]"
_ok "Selected model: $GGUF_PATH"

# Determine port
PORT="${PORT:-$DEFAULT_PORT}"
if lsof -i :"$PORT" &>/dev/null || netstat -tuln 2>/dev/null | grep -q ":$PORT "; then
    if [ "$PORT" -eq "$DEFAULT_PORT" ]; then
        _warn "Port $DEFAULT_PORT is already in use (e.g. by existing service). Falling back to port 8082."
        PORT=8082
    fi
fi
_info "Binding host port: $PORT"

# Clean existing container if needed
if docker ps -a --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}$"; then
    _info "Removing previous container ${CONTAINER_NAME}..."
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

# Build model mount
MODEL_DIR="$(dirname "$GGUF_PATH")"
MODEL_FILE="$(basename "$GGUF_PATH")"

# Build runtime flags for llama-server-prism
CTX_SIZE="${CTX_SIZE:-8192}"
GPU_LAYERS="${GPU_LAYERS:-99}"
BATCH_SIZE="${BATCH_SIZE:-512}"
UBATCH_SIZE="${UBATCH_SIZE:-256}"
EXTRA_FLAGS=(
    -m "/models/$MODEL_FILE"
    -ngl "$GPU_LAYERS"
    -c "$CTX_SIZE"
    -b "$BATCH_SIZE"
    -ub "$UBATCH_SIZE"
    --flash-attn on
    --no-mmap
    --parallel 1
    --jinja
    --host 0.0.0.0
    --port "$PORT"
)

# Optional KV Cache quantization (e.g. CTK=q4_0 CTV=q4_0 for PQ2_0)
if [ -n "${CTK:-}" ]; then
    EXTRA_FLAGS+=(-ctk "$CTK")
fi
if [ -n "${CTV:-}" ]; then
    EXTRA_FLAGS+=(-ctv "$CTV")
fi

# Dual GPU split if configured
if [ -n "${TENSOR_SPLIT:-}" ]; then
    EXTRA_FLAGS+=(-sm layer -ts "$TENSOR_SPLIT")
fi

mkdir -p "$HOME/.george" 2>/dev/null

DOCKER_ARGS=(
    --name "$CONTAINER_NAME"
    --gpus all
    -v "$LODGE_ROOT:/workspace"
    -v "$HOME/.george:/home/george/.george"
    -v "$MODEL_DIR:/models:ro"
    -p "${PORT}:${PORT}"
)

if [ "$DAEMON" -eq 1 ]; then
    _info "Launching ${CONTAINER_NAME} in background on port $PORT..."
    docker run -d "${DOCKER_ARGS[@]}" george-cuda-sandbox /usr/local/bin/llama-server-prism "${EXTRA_FLAGS[@]}"
    _ok "Container started. Check logs: docker logs -f $CONTAINER_NAME"
    _ok "Endpoint: http://127.0.0.1:${PORT}"
else
    _info "Launching ${CONTAINER_NAME} in foreground (Ctrl+C to stop)..."
    docker run --rm -it "${DOCKER_ARGS[@]}" george-cuda-sandbox /usr/local/bin/llama-server-prism "${EXTRA_FLAGS[@]}"
fi
