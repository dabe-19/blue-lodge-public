#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# validate-gpu.sh — llama.cpp GPU Offload Validation Script
# ═══════════════════════════════════════════════════════════════
# Fully automated end-to-end test:
#   1. Lists Ollama models → lets you pick one (or pass as arg)
#   2. Resolves the GGUF blob from Ollama's storage
#   3. Starts llama-server with Vulkan GPU offloading
#   4. Sends a streaming test prompt
#   5. Captures and displays the response
#   6. Checks server log for GPU offload confirmation
#   7. Measures tokens/sec performance
#   8. Writes a full log file
#
# Usage:
#   ./commands/validate-gpu.sh                  # interactive model picker
#   ./commands/validate-gpu.sh minist-inst      # registry key
#   ./commands/validate-gpu.sh qwen3:8b         # Ollama model name
#   ./commands/validate-gpu.sh /path/to.gguf    # direct GGUF path
#
# Environment overrides:
#   LLAMA_CPP_SERVER_BIN   llama-server binary path
#   LLAMA_CPP_GPU_LAYERS   GPU layers to offload (default: 99)
#   LLAMA_CPP_CTX_SIZE     Context window (default: 4096)
#   VALIDATE_PORT          Port for test server (default: 8090)
#   VALIDATE_PROMPT        Custom test prompt

set -euo pipefail

# ── Termux home resolution ─────────────────────────────────────
# Inside proot-distro, $HOME=/root/ but Ollama+llama.cpp live in Termux's
# native home. Detect and resolve the correct path.
_resolve_termux_home() {
    # proot-distro: $HOME=/root/ but Ollama+llama.cpp live in Termux native home.
    # Detect proot first — /root/.ollama/models may exist (empty) inside proot.
    if [ -d "/data/data/com.termux/files/home" ] && [ "$HOME" != "/data/data/com.termux/files/home" ]; then
        echo "/data/data/com.termux/files/home"
    elif [ -d "$HOME/.ollama/models" ]; then
        echo "$HOME"
    else
        echo "$HOME"
    fi
}
_TERMUX_HOME="$(_resolve_termux_home)"

# ── Config ─────────────────────────────────────────────────────
# Auto-detect from script location (works regardless of install path)
LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
LLAMA_CPP_SERVER_BIN="${LLAMA_CPP_SERVER_BIN:-$_TERMUX_HOME/llama.cpp/build/bin/llama-server}"
LLAMA_CPP_GPU_LAYERS="${LLAMA_CPP_GPU_LAYERS:-99}"
LLAMA_CPP_CTX_SIZE="${LLAMA_CPP_CTX_SIZE:-4096}"
VALIDATE_PORT="${VALIDATE_PORT:-8090}"
VALIDATE_URL="http://127.0.0.1:$VALIDATE_PORT"
VALIDATE_PROMPT="${VALIDATE_PROMPT:-What is the capital of France? Answer in one sentence.}"
OLLAMA_DIR="$_TERMUX_HOME/.ollama/models"
LOGFILE="${TMPDIR:-/tmp}/lodge-gpu-validate-$(date +%Y%m%d-%H%M%S).log"
SERVER_LOG="${TMPDIR:-/tmp}/lodge-gpu-validate-server.log"
SERVER_PID=""

# Source model registry if available (for registry key resolution)
if [ -f "$LODGE_DIR/lib/models.sh" ]; then
    # Need ui.sh for models.sh to source cleanly 
    source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
    source "$LODGE_DIR/lib/models.sh" 2>/dev/null || true
    _HAS_REGISTRY=1
else
    _HAS_REGISTRY=0
fi

# ── Display helpers ────────────────────────────────────────────
_C_RESET='\033[0m'
_C_BOLD='\033[1m'
_C_DIM='\033[2m'
_C_GREEN='\033[32m'
_C_RED='\033[31m'
_C_YELLOW='\033[33m'
_C_CYAN='\033[36m'
_C_BLUE='\033[34m'

_header()  { printf "\n${_C_BOLD}${_C_BLUE}═══ %s ═══${_C_RESET}\n\n" "$1"; }
_step()    { printf "${_C_BOLD}${_C_CYAN}[%s]${_C_RESET} %s\n" "$1" "$2"; }
_ok()      { printf "${_C_GREEN}  ✓ %s${_C_RESET}\n" "$1"; }
_fail()    { printf "${_C_RED}  ✗ %s${_C_RESET}\n" "$1"; }
_warn()    { printf "${_C_YELLOW}  ⚠ %s${_C_RESET}\n" "$1"; }
_dim()     { printf "${_C_DIM}    %s${_C_RESET}\n" "$1"; }
_log()     { echo "[$(date '+%H:%M:%S')] $*" >> "$LOGFILE"; }

# ── Cleanup on exit ───────────────────────────────────────────
cleanup() {
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        _step "CLEANUP" "Stopping llama-server (PID $SERVER_PID)"
        kill "$SERVER_PID" 2>/dev/null
        wait "$SERVER_PID" 2>/dev/null || true
        _ok "Server stopped"
    fi
}
trap cleanup EXIT INT TERM

# ═══════════════════════════════════════════════════════════════
# Step 1: Resolve model to GGUF path
# ═══════════════════════════════════════════════════════════════
_header "llama.cpp GPU Offload Validation"

echo "" >> "$LOGFILE"
echo "═══════════════════════════════════════════════════════════" >> "$LOGFILE"
echo "  GPU Validation — $(date)" >> "$LOGFILE"
echo "═══════════════════════════════════════════════════════════" >> "$LOGFILE"
_log "Host: $(uname -a)"
_log "Binary: $LLAMA_CPP_SERVER_BIN"

_step "1" "Resolving model"

GGUF_PATH=""
MODEL_LABEL=""

resolve_model() {
    local input="$1"

    # Direct GGUF path
    if [ -f "$input" ]; then
        GGUF_PATH="$input"
        MODEL_LABEL="$(basename "$input")"
        return 0
    fi

    # Try Blue Lodge registry key (e.g., "minist-inst")
    if [ "$_HAS_REGISTRY" = "1" ]; then
        local _resolved
        _resolved=$(_models_resolve_gguf "$input" 2>/dev/null)
        if [ -n "$_resolved" ] && [ -f "$_resolved" ]; then
            GGUF_PATH="$_resolved"
            MODEL_LABEL="$input (registry)"
            return 0
        fi
    fi

    # Try Ollama model name (e.g., "qwen3:8b")
    if [ "$_HAS_REGISTRY" = "1" ]; then
        local _resolved
        _resolved=$(_models_find_ollama_gguf "$input" 2>/dev/null)
        if [ -n "$_resolved" ] && [ -f "$_resolved" ]; then
            GGUF_PATH="$_resolved"
            MODEL_LABEL="$input (ollama)"
            return 0
        fi
    fi

    # Manual Ollama resolution (in case registry not available)
    if [ -d "$OLLAMA_DIR/manifests" ]; then
        local _lib _tag _manifest _digest _blob
        _tag="${input##*:}"
        _lib="${input%:*}"
        [ "$_tag" = "$_lib" ] && _tag="latest"
        for _prefix in "registry.ollama.ai/library" "registry.ollama.ai" "hf.co"; do
            _manifest="$OLLAMA_DIR/manifests/$_prefix/$_lib/$_tag"
            if [ -f "$_manifest" ]; then
                _digest=$(jq -r '.layers[] | select(.mediaType == "application/vnd.ollama.image.model") | .digest' "$_manifest" 2>/dev/null)
                if [ -n "$_digest" ]; then
                    _blob="$OLLAMA_DIR/blobs/${_digest//:/-}"
                    if [ -f "$_blob" ]; then
                        GGUF_PATH="$_blob"
                        MODEL_LABEL="$input (ollama)"
                        return 0
                    fi
                fi
            fi
        done
    fi

    return 1
}

# ── Model selection ────────────────────────────────────────────
if [ -n "${1:-}" ]; then
    # Argument provided
    if resolve_model "$1"; then
        _ok "Resolved: $MODEL_LABEL"
    else
        _fail "Could not resolve model: $1"
        exit 1
    fi
else
    # Interactive: list available models
    _step "1a" "Scanning available models..."
    echo ""

    declare -a _MODELS_AVAILABLE=()
    declare -a _MODELS_LABELS=()
    declare -a _MODELS_SIZES=()
    _idx=0

    # List registry models first
    if [ "$_HAS_REGISTRY" = "1" ]; then
        for entry in "${_MODELS_REGISTRY[@]}"; do
            _models_parse_entry "$entry"
            _gguf=""
            _gguf=$(_models_resolve_gguf "$_ME_KEY" 2>/dev/null) || true
            if [ -n "$_gguf" ] && [ -f "$_gguf" ]; then
                _idx=$((_idx + 1))
                _MODELS_AVAILABLE+=("$_gguf")
                _MODELS_LABELS+=("$_ME_KEY ($_ME_ROLE)")
                _MODELS_SIZES+=("$(du -h "$_gguf" 2>/dev/null | cut -f1)")
            fi
        done
    fi

    # Also list raw Ollama models not in registry
    if [ -d "$OLLAMA_DIR/manifests" ]; then
        while IFS= read -r mf; do
            _name="" _digest="" _blob=""
            # Derive human name from path
            _name=$(echo "$mf" | sed 's|.*/manifests/||; s|registry.ollama.ai/library/||; s|/|:|g')
            _digest=$(jq -r '.layers[] | select(.mediaType == "application/vnd.ollama.image.model") | .digest' "$mf" 2>/dev/null)
            if [ -n "$_digest" ]; then
                _blob="$OLLAMA_DIR/blobs/${_digest//:/-}"
                if [ -f "$_blob" ]; then
                    # Check if already listed via registry
                    _dup=0
                    for _existing in "${_MODELS_AVAILABLE[@]+"${_MODELS_AVAILABLE[@]}"}"; do
                        [ "$_existing" = "$_blob" ] && _dup=1 && break
                    done
                    if [ "$_dup" -eq 0 ]; then
                        _idx=$((_idx + 1))
                        _MODELS_AVAILABLE+=("$_blob")
                        _MODELS_LABELS+=("$_name (ollama)")
                        _MODELS_SIZES+=("$(du -h "$_blob" 2>/dev/null | cut -f1)")
                    fi
                fi
            fi
        done < <(find "$OLLAMA_DIR/manifests" -type f 2>/dev/null)
    fi

    if [ ${#_MODELS_AVAILABLE[@]} -eq 0 ]; then
        _fail "No models found in Ollama storage or registry"
        _dim "Pull a model first:  ollama pull qwen3:8b"
        exit 1
    fi

    printf "  ${_C_BOLD}%-4s %-35s %s${_C_RESET}\n" "#" "MODEL" "SIZE"
    printf "  %-4s %-35s %s\n" "---" "-----------------------------------" "------"
    for (( i=0; i<${#_MODELS_AVAILABLE[@]}; i++ )); do
        printf "  ${_C_CYAN}%-4s${_C_RESET} %-35s %s\n" "$((i+1))" "${_MODELS_LABELS[$i]}" "${_MODELS_SIZES[$i]}"
    done
    echo ""

    _choice=""
    read -rp "  Select model [1-${#_MODELS_AVAILABLE[@]}]: " _choice
    if ! [[ "$_choice" =~ ^[0-9]+$ ]] || [ "$_choice" -lt 1 ] || [ "$_choice" -gt ${#_MODELS_AVAILABLE[@]} ]; then
        _fail "Invalid selection"
        exit 1
    fi
    GGUF_PATH="${_MODELS_AVAILABLE[$((_choice-1))]}"
    MODEL_LABEL="${_MODELS_LABELS[$((_choice-1))]}"
    _ok "Selected: $MODEL_LABEL"
fi

GGUF_SIZE=$(du -h "$GGUF_PATH" 2>/dev/null | cut -f1)
_dim "GGUF: $GGUF_PATH ($GGUF_SIZE)"
_log "Model: $MODEL_LABEL"
_log "GGUF: $GGUF_PATH ($GGUF_SIZE)"

# ═══════════════════════════════════════════════════════════════
# Step 2: Validate binary
# ═══════════════════════════════════════════════════════════════
echo ""
_step "2" "Checking llama-server binary"

if [ ! -x "$LLAMA_CPP_SERVER_BIN" ]; then
    _fail "Not found: $LLAMA_CPP_SERVER_BIN"
    _dim "Set LLAMA_CPP_SERVER_BIN or build with: docs/ADRENO_GPU_SETUP.md"
    exit 1
fi
_ok "Binary: $LLAMA_CPP_SERVER_BIN"

# Check Vulkan support in the binary
_VULKAN_SUPPORT=0
if "$LLAMA_CPP_SERVER_BIN" --help 2>&1 | grep -qi "vulkan\|vk\|gpu"; then
    _VULKAN_SUPPORT=1
    _ok "Vulkan/GPU flags detected in binary"
else
    _warn "Could not confirm Vulkan support from --help output"
fi
_log "Vulkan support flag: $_VULKAN_SUPPORT"

# Check for existing process on our port
if curl -sf --max-time 1 "$VALIDATE_URL/health" &>/dev/null; then
    _warn "Port $VALIDATE_PORT already in use — killing existing process"
    _existing_pid=$(pgrep -f "llama-server.*--port.*$VALIDATE_PORT" 2>/dev/null | head -1)
    if [ -n "$_existing_pid" ]; then
        kill "$_existing_pid" 2>/dev/null
        sleep 2
    fi
fi

# ═══════════════════════════════════════════════════════════════
# Step 3: Start llama-server
# ═══════════════════════════════════════════════════════════════
echo ""
_step "3" "Starting llama-server with GPU offloading"
_dim "Port: $VALIDATE_PORT | GPU layers: $LLAMA_CPP_GPU_LAYERS | Context: $LLAMA_CPP_CTX_SIZE"

> "$SERVER_LOG"  # Clear server log

"$LLAMA_CPP_SERVER_BIN" \
    -m "$GGUF_PATH" \
    --port "$VALIDATE_PORT" \
    -ngl "$LLAMA_CPP_GPU_LAYERS" \
    -c "$LLAMA_CPP_CTX_SIZE" \
    --threads "$(nproc 2>/dev/null || echo 4)" \
    > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!
_dim "PID: $SERVER_PID"
_log "Server PID: $SERVER_PID"
_log "Server flags: -ngl $LLAMA_CPP_GPU_LAYERS -c $LLAMA_CPP_CTX_SIZE"

# Wait for healthy
_step "3a" "Waiting for server to become healthy..."
_tries=0
_healthy=0
while [ $_tries -lt 45 ]; do
    sleep 1

    # Check if process died
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        _fail "Server process died during startup"
        _dim "Last 10 lines of log:"
        tail -10 "$SERVER_LOG" | while IFS= read -r line; do _dim "$line"; done
        _log "FAIL: Server died during startup"
        cat "$SERVER_LOG" >> "$LOGFILE"
        SERVER_PID=""
        exit 1
    fi

    _health=$(curl -sf --max-time 2 "$VALIDATE_URL/health" 2>/dev/null || true)
    _status=$(echo "$_health" | jq -r '.status // empty' 2>/dev/null)
    if [ "$_status" = "ok" ]; then
        _healthy=1
        break
    elif [ "$_status" = "loading model" ]; then
        printf "\r${_C_DIM}    Loading model... (%ds)${_C_RESET}  " "$_tries"
    fi
    _tries=$((_tries + 1))
done
echo ""

if [ "$_healthy" -eq 0 ]; then
    _fail "Server did not become healthy within 45s"
    _dim "Log tail:"
    tail -10 "$SERVER_LOG" | while IFS= read -r line; do _dim "$line"; done
    _log "FAIL: Timeout waiting for healthy"
    cat "$SERVER_LOG" >> "$LOGFILE"
    exit 1
fi
_ok "Server healthy (${_tries}s startup)"
_log "Server healthy after ${_tries}s"

# ═══════════════════════════════════════════════════════════════
# Step 4: Check GPU offloading from server log
# ═══════════════════════════════════════════════════════════════
echo ""
_step "4" "Checking GPU offloading"

_GPU_OFFLOADED=0
_GPU_LAYERS_OFFLOADED="0"
_GPU_BACKEND=""

# Look for offload messages in server log
# llama.cpp logs lines like:
#   "offloaded 33/33 layers to GPU"
#   "VULKAN0: ..."
#   "ggml_vulkan: ..."
#   "GPU: ..."
if grep -qi "offloaded.*layers.*GPU\|ggml_vulkan\|VULKAN\|GPU.*offload\|vk_" "$SERVER_LOG" 2>/dev/null; then
    _GPU_OFFLOADED=1
fi

# Extract specific offload count
_offload_line=$(grep -i "offloaded.*layers" "$SERVER_LOG" 2>/dev/null | tail -1)
if [ -n "$_offload_line" ]; then
    _GPU_LAYERS_OFFLOADED=$(echo "$_offload_line" | grep -oP '\d+(?=/\d+ layers)' || echo "?")
fi

# Detect GPU backend name
_vulkan_line=$(grep -iP "VULKAN|ggml_vulkan|vk_device" "$SERVER_LOG" 2>/dev/null | head -1)
if [ -n "$_vulkan_line" ]; then
    _GPU_BACKEND="Vulkan"
fi
_cuda_line=$(grep -iP "CUDA|cublas|ggml_cuda" "$SERVER_LOG" 2>/dev/null | head -1)
if [ -n "$_cuda_line" ]; then
    _GPU_BACKEND="CUDA"
fi

if [ "$_GPU_OFFLOADED" -eq 1 ]; then
    _ok "GPU offloading CONFIRMED"
    _dim "Layers offloaded: $_GPU_LAYERS_OFFLOADED"
    [ -n "$_GPU_BACKEND" ] && _dim "Backend: $_GPU_BACKEND"
    [ -n "$_offload_line" ] && _dim "Log: $_offload_line"
    [ -n "$_vulkan_line" ] && _dim "Device: $_vulkan_line"
    _log "GPU offload: YES | Layers: $_GPU_LAYERS_OFFLOADED | Backend: ${_GPU_BACKEND:-unknown}"
else
    _fail "GPU offloading NOT detected"
    _warn "Model may be running on CPU only"
    _dim "Check -ngl flag and Vulkan driver availability"
    _dim "Relevant log lines:"
    grep -iP "GPU|vulkan|cuda|offload|device|error|warn" "$SERVER_LOG" 2>/dev/null | head -5 | while IFS= read -r line; do
        _dim "  $line"
    done
    _log "GPU offload: NO (CPU-only detected)"
fi

# Also extract model metadata from log
_model_info=$(grep -i "model.*param\|model.*layers\|model.*context" "$SERVER_LOG" 2>/dev/null | head -3)
if [ -n "$_model_info" ]; then
    _dim ""
    _dim "Model info from server:"
    echo "$_model_info" | while IFS= read -r line; do _dim "  $line"; done
fi

# ═══════════════════════════════════════════════════════════════
# Step 5: Send streaming test prompt
# ═══════════════════════════════════════════════════════════════
echo ""
_step "5" "Sending test prompt (streaming)"
_dim "Prompt: \"$VALIDATE_PROMPT\""
echo ""

_log "Prompt: $VALIDATE_PROMPT"

# Build payload
_payload=$(jq -n \
    --arg prompt "$VALIDATE_PROMPT" \
    '{
        model: "test",
        messages: [
            {role: "user", content: $prompt}
        ],
        stream: true,
        max_tokens: 256,
        temperature: 0.3
    }')

# Stream the response, collecting tokens and timing
_response=""
_token_count=0
_start_time=$(date +%s%N)
_first_token_time=""

printf "  ${_C_GREEN}"

# Use curl streaming with SSE parsing
while IFS= read -r line; do
    # Skip empty lines and SSE comments
    [[ "$line" == data:* ]] || continue
    json="${line#data: }"
    [ "$json" = "[DONE]" ] && break

    # Extract content token
    token=$(echo "$json" | jq -r '.choices[0].delta.content // empty' 2>/dev/null)
    if [ -n "$token" ]; then
        # Record time to first token
        if [ -z "$_first_token_time" ]; then
            _first_token_time=$(date +%s%N)
        fi
        printf "%s" "$token"
        _response+="$token"
        _token_count=$((_token_count + 1))
    fi
done < <(curl -sf --max-time 60 -N \
    "$VALIDATE_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$_payload" 2>/dev/null)

printf "${_C_RESET}\n"
_end_time=$(date +%s%N)

# ═══════════════════════════════════════════════════════════════
# Step 6: Performance analysis
# ═══════════════════════════════════════════════════════════════
echo ""
_step "6" "Performance analysis"

_response_len=${#_response}

if [ "$_token_count" -gt 0 ] && [ -n "$_first_token_time" ]; then
    # Time to first token (TTFT) in ms
    _ttft_ns=$(( _first_token_time - _start_time ))
    _ttft_ms=$(( _ttft_ns / 1000000 ))

    # Total generation time in ms
    _total_ns=$(( _end_time - _start_time ))
    _total_ms=$(( _total_ns / 1000000 ))

    # Tokens per second (generation phase only, after first token)
    _gen_ns=$(( _end_time - _first_token_time ))
    if [ "$_gen_ns" -gt 0 ] && [ "$_token_count" -gt 1 ]; then
        # tok/s = (tokens - 1) / gen_seconds  (first token is prompt eval)
        _tps=$(awk "BEGIN { printf \"%.1f\", ($_token_count - 1) / ($_gen_ns / 1000000000) }")
    else
        _tps="N/A"
    fi

    _ok "Response received: $_token_count tokens, $_response_len chars"
    _dim "Time to first token:  ${_ttft_ms}ms"
    _dim "Total generation:     ${_total_ms}ms"
    _dim "Generation speed:     ${_tps} tok/s"

    _log "Tokens: $_token_count | Chars: $_response_len"
    _log "TTFT: ${_ttft_ms}ms | Total: ${_total_ms}ms | Speed: ${_tps} tok/s"

    # Performance assessment
    echo ""
    if [ "$_tps" != "N/A" ]; then
        _tps_int=$(printf "%.0f" "$_tps" 2>/dev/null || echo 0)
        if [ "$_tps_int" -ge 15 ]; then
            _ok "GPU acceleration CONFIRMED (${_tps} tok/s — expected for GPU)"
        elif [ "$_tps_int" -ge 5 ]; then
            _warn "Moderate speed (${_tps} tok/s — partial GPU or small model)"
        else
            _warn "Low speed (${_tps} tok/s — likely CPU-only)"
            _dim "Expected >15 tok/s for GPU-offloaded 4B models"
        fi
        _log "Assessment: ${_tps_int} tok/s"
    fi
else
    _fail "No response received from server"
    _dim "Check server log: $SERVER_LOG"
    _log "FAIL: No response tokens received"
fi

# ═══════════════════════════════════════════════════════════════
# Step 7: Server metrics (if available)
# ═══════════════════════════════════════════════════════════════
echo ""
_step "7" "Server metrics"

_metrics=$(curl -sf --max-time 5 "$VALIDATE_URL/metrics" 2>/dev/null)
if [ -n "$_metrics" ]; then
    # Extract key prometheus metrics
    _prompt_tps=$(echo "$_metrics" | grep "^llamacpp:prompt_tokens_seconds" | awk '{print $2}' | head -1)
    _gen_tps=$(echo "$_metrics" | grep "^llamacpp:tokens_predicted_seconds" | awk '{print $2}' | head -1)
    _prompt_total=$(echo "$_metrics" | grep "^llamacpp:prompt_tokens_total" | awk '{print $2}' | head -1)
    _gen_total=$(echo "$_metrics" | grep "^llamacpp:tokens_predicted_total" | awk '{print $2}' | head -1)

    if [ -n "$_prompt_tps" ] || [ -n "$_gen_tps" ]; then
        [ -n "$_prompt_tps" ] && _dim "Prompt eval: ${_prompt_tps} tok/s"
        [ -n "$_gen_tps" ] && _dim "Generation:  ${_gen_tps} tok/s"
        [ -n "$_prompt_total" ] && _dim "Prompt tokens processed: $_prompt_total"
        [ -n "$_gen_total" ] && _dim "Tokens generated: $_gen_total"
        _log "Metrics — Prompt: ${_prompt_tps:-?} tok/s | Gen: ${_gen_tps:-?} tok/s"
    else
        _dim "Metrics endpoint available but no token data yet"
    fi
else
    _dim "Metrics endpoint not available (normal for some builds)"
fi

# Also try /slots for slot info
_slots=$(curl -sf --max-time 5 "$VALIDATE_URL/slots" 2>/dev/null)
if [ -n "$_slots" ]; then
    _slot_prompt_tps=$(echo "$_slots" | jq -r '.[0].t_prompt_processing // empty' 2>/dev/null)
    _slot_gen_tps=$(echo "$_slots" | jq -r '.[0].t_token_generation // empty' 2>/dev/null)
    if [ -n "$_slot_prompt_tps" ] || [ -n "$_slot_gen_tps" ]; then
        _dim ""
        _dim "Slot timing:"
        [ -n "$_slot_prompt_tps" ] && _dim "  Prompt processing: ${_slot_prompt_tps}ms"
        [ -n "$_slot_gen_tps" ] && _dim "  Token generation:  ${_slot_gen_tps}ms"
    fi
fi

# ═══════════════════════════════════════════════════════════════
# Step 8: Summary
# ═══════════════════════════════════════════════════════════════
echo ""
_header "Validation Summary"

printf "  ${_C_BOLD}%-22s${_C_RESET} %s\n" "Model:" "$MODEL_LABEL"
printf "  ${_C_BOLD}%-22s${_C_RESET} %s\n" "GGUF size:" "$GGUF_SIZE"
printf "  ${_C_BOLD}%-22s${_C_RESET} %s\n" "GPU offload:" "$( [ "$_GPU_OFFLOADED" -eq 1 ] && echo "YES ($_GPU_LAYERS_OFFLOADED layers)" || echo "NO (CPU only)" )"
printf "  ${_C_BOLD}%-22s${_C_RESET} %s\n" "GPU backend:" "${_GPU_BACKEND:-not detected}"
printf "  ${_C_BOLD}%-22s${_C_RESET} %s\n" "Response tokens:" "${_token_count:-0}"
printf "  ${_C_BOLD}%-22s${_C_RESET} %s\n" "Speed:" "${_tps:-N/A} tok/s"
printf "  ${_C_BOLD}%-22s${_C_RESET} %s\n" "Time to first token:" "${_ttft_ms:-N/A}ms"
echo ""

# Overall verdict
if [ "$_GPU_OFFLOADED" -eq 1 ] && [ "${_token_count:-0}" -gt 0 ]; then
    printf "  ${_C_BOLD}${_C_GREEN}PASS — GPU offloading active, model responding${_C_RESET}\n"
    _log "RESULT: PASS"
elif [ "${_token_count:-0}" -gt 0 ]; then
    printf "  ${_C_BOLD}${_C_YELLOW}PARTIAL — Model responding but GPU offload unconfirmed${_C_RESET}\n"
    _log "RESULT: PARTIAL"
else
    printf "  ${_C_BOLD}${_C_RED}FAIL — No response from model${_C_RESET}\n"
    _log "RESULT: FAIL"
fi

# Append server log to validation log
echo "" >> "$LOGFILE"
echo "─── Server Log ───" >> "$LOGFILE"
cat "$SERVER_LOG" >> "$LOGFILE" 2>/dev/null

# Append response
echo "" >> "$LOGFILE"
echo "─── Response ───" >> "$LOGFILE"
echo "$_response" >> "$LOGFILE"

echo ""
printf "  ${_C_DIM}Log: %s${_C_RESET}\n" "$LOGFILE"
printf "  ${_C_DIM}Server log: %s${_C_RESET}\n" "$SERVER_LOG"
echo ""

_log "Done."
