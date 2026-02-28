#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# test-llama-server.sh — Quick llama-server smoke test
# ═══════════════════════════════════════════════════════════════
# Resolves an Ollama model's GGUF blob, starts llama-server,
# sends a test prompt, and prints the response.
#
# Usage:
#   ./scripts/test-llama-server.sh                     # uses default model
#   ./scripts/test-llama-server.sh blue-lodge-minist-inst:4b
#   ./scripts/test-llama-server.sh -ngl 0              # CPU-only override
#
# Run from Termux (not proot) for direct hardware access.

set -euo pipefail

# ── Error trap ──────────────────────────────────────────────────
# Show exactly where the script died instead of crashing silently
trap 'printf "\n\033[31m✗ Script failed at line %s\033[0m\n" "$LINENO"; exit 1' ERR

# ── Proot guard ────────────────────────────────────────────────
# llama-server is a Termux-native binary (Bionic) and needs direct
# GPU driver access — neither works inside proot's glibc environment.
if [ -f /etc/os-release ] && [ -d /data/data/com.termux ] && [ "$HOME" = "/root" ]; then
    printf '\033[31m✗ Running inside proot — this won'\''t work.\033[0m\n'
    printf '  llama-server needs Termux native for Bionic libs + GPU access.\n'
    printf '  Exit proot first, then run from Termux:\n\n'
    printf '    exit\n'
    _repo_path="$(cd "$(dirname "$0")/.." && pwd)"
    printf '    %s/scripts/test-llama-server.sh\n\n' "$_repo_path"
    exit 1
fi

# ── Config ─────────────────────────────────────────────────────
TERMUX_HOME="${TERMUX_HOME:-/data/data/com.termux/files/home}"
# Fall back to $HOME if not on Android
[ -d "$TERMUX_HOME" ] || TERMUX_HOME="$HOME"

OLLAMA_DIR="$TERMUX_HOME/.ollama/models"
LLAMA_BIN="${LLAMA_BIN:-$TERMUX_HOME/llama.cpp/build/bin/llama-server}"
PORT="${PORT:-8090}"
GPU_LAYERS="${GPU_LAYERS:-99}"
CTX_SIZE="${CTX_SIZE:-4096}"
THREADS="${THREADS:-$(nproc 2>/dev/null || echo 4)}"
MODEL_REF="${1:-blue-lodge-minist-inst:4b}"
PROMPT="${PROMPT:-Hello! Tell me a one-sentence fun fact.}"

# Allow -ngl override as first arg
if [[ "${1:-}" == -ngl ]]; then
    GPU_LAYERS="${2:-0}"
    MODEL_REF="${3:-blue-lodge-minist-inst:4b}"
fi

# ── Colors ─────────────────────────────────────────────────────
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_CYAN='\033[36m'
C_GREEN='\033[32m'
C_RED='\033[31m'
C_YELLOW='\033[33m'
C_RESET='\033[0m'

_step()  { printf "${C_BOLD}${C_CYAN}[%s]${C_RESET} %s\n" "$1" "$2"; }
_ok()    { printf "${C_GREEN}  ✓ %s${C_RESET}\n" "$1"; }
_fail()  { printf "${C_RED}  ✗ %s${C_RESET}\n" "$1"; }
_warn()  { printf "${C_YELLOW}  ⚠ %s${C_RESET}\n" "$1"; }
_dim()   { printf "${C_DIM}    %s${C_RESET}\n" "$1"; }

# ── Cleanup ────────────────────────────────────────────────────
SERVER_PID=""
cleanup() {
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        _step "CLEANUP" "Stopping llama-server (PID $SERVER_PID)"
        kill "$SERVER_PID" 2>/dev/null
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# ═══════════════════════════════════════════════════════════════
printf "\n${C_BOLD}═══ llama-server Smoke Test ═══${C_RESET}\n\n"

# ── Step 0: Check dependencies ────────────────────────────────
_missing_deps=()
command -v jq    &>/dev/null || _missing_deps+=(jq)
command -v curl  &>/dev/null || _missing_deps+=(curl)
if [ ${#_missing_deps[@]} -gt 0 ]; then
    _fail "Missing required tools: ${_missing_deps[*]}"
    if [ -d /data/data/com.termux ]; then
        _dim "Install with: pkg install ${_missing_deps[*]}"
    else
        _dim "Install with your package manager (apt, brew, etc.)"
    fi
    exit 1
fi

# ── Step 1: Check binary ──────────────────────────────────────
_step "1" "Checking llama-server binary"
if [ ! -x "$LLAMA_BIN" ]; then
    _fail "Not found: $LLAMA_BIN"
    _dim "Set LLAMA_BIN or build llama.cpp first"
    _dim "See: docs/BACKEND_VALIDATION.md"
    exit 1
fi
_ok "Binary: $LLAMA_BIN"

# ── Step 2: Check Ollama isn't hogging RAM ────────────────────
_step "2" "Checking for running Ollama"
if pgrep -x ollama &>/dev/null; then
    _warn "Ollama is running — loading the same model twice WILL cause OOM"
    read -rp "    Kill Ollama before continuing? [Y/n] " _ans
    if [[ ! "${_ans:-y}" =~ ^[Nn] ]]; then
        killall ollama 2>/dev/null || true
        sleep 2
        if pgrep -x ollama &>/dev/null; then
            _warn "Ollama still running — trying SIGKILL"
            killall -9 ollama 2>/dev/null || true
            sleep 1
        fi
        _ok "Ollama stopped"
    else
        _warn "Continuing with Ollama running — expect OOM on low-RAM devices"
    fi
fi

# ── Step 3: Resolve GGUF blob ─────────────────────────────────
_step "3" "Resolving model: $MODEL_REF"

# Parse model reference into manifest path
_tag="${MODEL_REF##*:}"
_name="${MODEL_REF%:*}"
[ "$_tag" = "$_name" ] && _tag="latest"

# Try all Ollama manifest conventions
MANIFEST=""
for _prefix in \
    "$OLLAMA_DIR/manifests/registry.ollama.ai/library/$_name/$_tag" \
    "$OLLAMA_DIR/manifests/registry.ollama.ai/$_name/$_tag" \
    "$OLLAMA_DIR/manifests/$_name/$_tag"; do
    if [ -f "$_prefix" ]; then
        MANIFEST="$_prefix"
        break
    fi
done

# Also try HuggingFace convention (hf.co/org/repo)
if [ -z "$MANIFEST" ] && [[ "$_name" == hf.co/* ]]; then
    _hf_path="$OLLAMA_DIR/manifests/$_name/$_tag"
    [ -f "$_hf_path" ] && MANIFEST="$_hf_path"
fi

if [ -z "$MANIFEST" ]; then
    _fail "No manifest found for '$MODEL_REF'"
    _dim "Available models:"
    if [ -d "$OLLAMA_DIR/manifests" ]; then
        find "$OLLAMA_DIR/manifests" -type f 2>/dev/null | while read -r mf; do
            _dim "  $(echo "$mf" | sed "s|$OLLAMA_DIR/manifests/||; s|registry.ollama.ai/library/||; s|/|:|g")" || true
        done || true
    else
        _dim "  (no models found at $OLLAMA_DIR)"
    fi
    exit 1
fi

DIGEST=$(jq -r '.layers[] | select(.mediaType == "application/vnd.ollama.image.model") | .digest' "$MANIFEST" 2>&1) || {
    _fail "Failed to parse manifest with jq"
    _dim "Manifest: $MANIFEST"
    _dim "jq output: $DIGEST"
    exit 1
}
if [ -z "$DIGEST" ]; then
    _fail "Could not extract GGUF digest from manifest"
    _dim "Manifest: $MANIFEST"
    _dim "Check: cat $MANIFEST | jq ."
    exit 1
fi

GGUF="$OLLAMA_DIR/blobs/${DIGEST//:/-}"
if [ ! -f "$GGUF" ]; then
    _fail "GGUF blob not found: $GGUF"
    exit 1
fi

GGUF_SIZE=$(du -h "$GGUF" 2>/dev/null | cut -f1)
_ok "Resolved: $MODEL_REF → $GGUF_SIZE GGUF"
_dim "$GGUF"

# ── Step 3a: Extract chat template from Ollama ────────────────
# Ollama stores the chat template as a separate blob, not in the GGUF.
# Without it, /v1/chat/completions returns empty because llama-server
# can't format the messages array into a prompt.
_chat_template_file=""
_tmpl_digest=$(jq -r '.layers[] | select(.mediaType == "application/vnd.ollama.image.template") | .digest' "$MANIFEST" 2>/dev/null || true)
if [ -n "$_tmpl_digest" ]; then
    _tmpl_blob="$OLLAMA_DIR/blobs/${_tmpl_digest//:/-}"
    if [ -f "$_tmpl_blob" ]; then
        _chat_template_file="$_tmpl_blob"
        _ok "Found Ollama chat template"
        _dim "$(head -c 80 "$_chat_template_file")..."
    fi
fi

# ── Step 4: Start server ──────────────────────────────────────
_step "4" "Starting llama-server"
_dim "Port: $PORT | GPU layers: $GPU_LAYERS | Context: $CTX_SIZE | Threads: $THREADS"

SERVER_LOG="${TMPDIR:-/tmp}/test-llama-server.log"
> "$SERVER_LOG"

# Build launch args
_launch_args=(
    -m "$GGUF"
    --port "$PORT"
    -ngl "$GPU_LAYERS"
    -c "$CTX_SIZE"
    --threads "$THREADS"
)

# Pass chat template if we found one
if [ -n "$_chat_template_file" ]; then
    _launch_args+=(--chat-template-file "$_chat_template_file")
    _dim "Chat template: from Ollama metadata"
else
    _warn "No chat template found — /v1/chat/completions may not work"
    _dim "Will fall back to /completion endpoint"
fi

"$LLAMA_BIN" "${_launch_args[@]}" \
    > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!
_dim "PID: $SERVER_PID"

# Wait for healthy
_step "4a" "Waiting for server..."
_tries=0
_healthy=0
while [ $_tries -lt 60 ]; do
    sleep 1

    # Check if server process is still alive
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo ""
        _fail "Server died during startup"
        _dim "Last 20 lines of log:"
        tail -20 "$SERVER_LOG" | while IFS= read -r line; do _dim "$line"; done || true
        SERVER_PID=""
        exit 1
    fi

    # Probe health endpoint (must not let set -e kill us here)
    _status=$(curl -sf --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null || true)
    _status=$(echo "$_status" | jq -r '.status // empty' 2>/dev/null || true)

    if [ "$_status" = "ok" ]; then
        _healthy=1
        break
    elif [ "$_status" = "loading model" ]; then
        printf "\r${C_DIM}    Loading model... (%ds)${C_RESET}  " "$_tries"
    else
        printf "\r${C_DIM}    Waiting for server... (%ds)${C_RESET}  " "$_tries"
    fi
    _tries=$((_tries + 1))
done
echo ""

if [ "$_healthy" -eq 0 ]; then
    _fail "Server not healthy after 60s"
    _dim "Log tail:"
    tail -20 "$SERVER_LOG" | while IFS= read -r line; do _dim "$line"; done || true
    exit 1
fi
_ok "Server healthy"

# Check GPU offload
_gpu_offloaded=$(grep -c "offloaded.*layers to GPU" "$SERVER_LOG" 2>/dev/null || echo "0")
_gpu_layers=$(grep "offloaded" "$SERVER_LOG" 2>/dev/null | grep -oP '\d+(?=/\d+ layers)' 2>/dev/null || echo "0")
if [ "${_gpu_layers:-0}" -gt 0 ]; then
    _ok "GPU offload: $_gpu_layers layers"
else
    _warn "CPU-only mode (0 layers offloaded to GPU)"
fi

# ── Step 5: Send test prompt ──────────────────────────────────
_step "5" "Sending test prompt"
_dim "\"$PROMPT\""
echo ""

_start_time=$(date +%s)
# Try OpenAI-compatible endpoint first, fall back to legacy /completion
_request_body=$(jq -n \
    --arg prompt "$PROMPT" \
    '{messages: [{role: "user", content: $prompt}], max_tokens: 200, temperature: 0.7}')

_response=$(curl -s --max-time 120 "http://127.0.0.1:$PORT/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$_request_body" 2>&1) || true

# If empty reply (exit 52) or no response, check if server died
if [ -z "$_response" ]; then
    # Check if server process is still alive
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        _fail "Server crashed during inference (likely OOM)"
        _dim "Server log (last 30 lines):"
        tail -30 "$SERVER_LOG" | while IFS= read -r line; do _dim "$line"; done || true
        _dim ""
        _dim "Try: killall ollama first, or use -ngl 0 for CPU-only"
        SERVER_PID=""
        exit 1
    fi

    # Server alive but empty reply — try legacy /completion endpoint
    _warn "Empty reply from /v1/chat/completions — trying /completion"
    _legacy_body=$(jq -n \
        --arg prompt "$PROMPT" \
        '{prompt: $prompt, n_predict: 200, temperature: 0.7}')
    _response=$(curl -s --max-time 120 "http://127.0.0.1:$PORT/completion" \
        -H "Content-Type: application/json" \
        -d "$_legacy_body" 2>&1) || true
    _is_legacy=1
fi

if [ -z "$_response" ]; then
    _fail "No response from either endpoint"
    _dim "Server log (last 20 lines):"
    tail -20 "$SERVER_LOG" | while IFS= read -r line; do _dim "$line"; done || true
    exit 1
fi
_end_time=$(date +%s)
_elapsed=$((_end_time - _start_time))

_content=$(echo "$_response" | jq -r '.choices[0].message.content // empty' 2>/dev/null || true)
# Legacy /completion endpoint uses .content directly
if [ -z "$_content" ]; then
    _content=$(echo "$_response" | jq -r '.content // empty' 2>/dev/null || true)
fi
_total_tokens=$(echo "$_response" | jq -r '.usage.total_tokens // .tokens_evaluated // empty' 2>/dev/null || true)
_completion_tokens=$(echo "$_response" | jq -r '.usage.completion_tokens // .tokens_predicted // empty' 2>/dev/null || true)

if [ -n "$_content" ]; then
    printf "  ${C_GREEN}Response:${C_RESET} %s\n" "$_content"
    echo ""
    _ok "Completed in ${_elapsed}s"
    [ -n "$_total_tokens" ] && _dim "Tokens: $_total_tokens total ($_completion_tokens completion)"
    if [ "${_elapsed:-0}" -gt 0 ] && [ -n "$_completion_tokens" ] && [ "$_completion_tokens" -gt 0 ] 2>/dev/null; then
        _dim "Speed: ~$((_completion_tokens / _elapsed)) tok/s"
    fi
else
    _fail "No response from server"
    _dim "Raw response (first 500 chars):"
    echo "$_response" | head -c 500 | while IFS= read -r line; do _dim "$line"; done || true
fi

# ── Step 6: Summary ───────────────────────────────────────────
echo ""
printf "${C_BOLD}═══ Summary ═══${C_RESET}\n"
_dim "Model:    $MODEL_REF ($GGUF_SIZE)"
_dim "Binary:   $LLAMA_BIN"
_dim "GPU:      ${_gpu_layers:-0} layers offloaded"
_dim "Response: ${_elapsed}s"
_dim "Log:      $SERVER_LOG"
echo ""
_dim "Server still running on port $PORT (PID $SERVER_PID)"
_dim "Press Ctrl+C to stop, or send more requests to http://127.0.0.1:$PORT"

# Keep server alive for interactive use
_dim "Waiting... (Ctrl+C to exit)"
wait "$SERVER_PID" 2>/dev/null || true
