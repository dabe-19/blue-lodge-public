#!/bin/bash
# ── install/profile_mobile.sh: Mobile & SBC Edge Node Installer (Model Hub + Swarm + Cloud Fallback) ──
# Supports LPDDR5+ phones (Termux/PRoot), ARM64 SBCs (Jetson/Pi5/OrangePi/RK3588), and thin edge nodes.
#
# Operating modes (interactive prompt or non-interactive via MOBILE_MODE):
#   local — Standalone Model Hub + stock llama-server (e.g. Gemma-4 E2B/E4B, Qwen 3.5/3.8 2B-9B, Nemotron-Nano 4B)
#   swarm — Thin swarm node pointing at a remote inference-only endpoint node (LAN/Tailscale) + optional MQTT mesh
#   cloud — Zero-GPU free-tier cloud API node via lib/core/providers.sh with auto-paced rate limits & backoff
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LODGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GEORGE_DIR="${GEORGE_DIR:-$LODGE_DIR/.george}"
source "$SCRIPT_DIR/common.sh"

_detect_ram_gb() {
    if [ -r /proc/meminfo ]; then
        awk '/^MemTotal:/ { printf "%d", int(($2 + 524288) / 1048576) }' /proc/meminfo 2>/dev/null || echo 0
    elif command -v sysctl &>/dev/null; then
        echo $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
    else
        echo 0
    fi
}

_upsert_conf() {
    local file="$1" key="$2" val="$3"
    mkdir -p "$(dirname "$file")"
    touch "$file"
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$file"
    else
        printf '%s=%s\n' "$key" "$val" >> "$file"
    fi
}

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Blue Lodge: Mobile & SBC Edge Node Profile (Model Hub)${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"

detect_environment
ARCH="$(uname -m 2>/dev/null || echo unknown)"
RAM_GB="$(_detect_ram_gb)"
info "Environment: arch=${ARCH}, RAM=${RAM_GB}GB, Termux=${IS_TERMUX}, PRoot=${IS_PROOT}, iSH=${IS_ISH}"

# Recommend Model Hub GGUF tier from unified/LPDDR5+ RAM
REC_TIER="thin-client"
REC_MODELS="Use swarm inference endpoint or free-tier cloud fallback"
REC_CTX=8192
if [ "$RAM_GB" -ge 16 ]; then
    REC_TIER="sbc-16gb"
    REC_MODELS="Gemma-4 E4B (Q4_K_XL/Q8_0), Qwen 3.5/3.8 9B (Q4_K_M), Nemotron-Nano 4B"
    REC_CTX=32768
elif [ "$RAM_GB" -ge 10 ]; then
    REC_TIER="edge-12gb"
    REC_MODELS="Gemma-4 E4B (Q4_K_M), Qwen 3.5 4B (Q4_K_XL), Nemotron-Nano 4B"
    REC_CTX=16384
elif [ "$RAM_GB" -ge 6 ]; then
    REC_TIER="mobile-8gb"
    REC_MODELS="Gemma-4 E2B (Q4_K_M), Qwen 3.5 2B/4B (Q4_K_M)"
    REC_CTX=8192
fi
info "Detected edge tier: ${CYAN}${REC_TIER}${RESET} — recommended: ${REC_MODELS}"

# Choose operating mode
INTERACTIVE=0
[ -t 0 ] && [ -z "${MOBILE_MODE:-}" ] && [ "${NON_INTERACTIVE:-0}" != "1" ] && INTERACTIVE=1

MODE="${MOBILE_MODE:-}"
if [ -z "$MODE" ]; then
    if [ "$INTERACTIVE" -eq 1 ]; then
        echo ""
        echo "  Select Mobile / SBC Edge operating mode:"
        echo "    1) local — Standalone Model Hub + llama-server (runs E2B/E4B/small GGUFs locally)"
        echo "    2) swarm — Swarm / Thin Edge Node (routes inference to a remote LAN/Tailscale inference node)"
        echo "    3) cloud — Zero-GPU Free-Tier Cloud Fallback (Google AI Studio / Groq / OpenRouter via providers.sh)"
        printf "  Choice [1/2/3] (default: %s): " "$([ "$RAM_GB" -ge 6 ] && echo 1 || echo 2)"
        read -r choice
        case "${choice:-}" in
            2|swarm) MODE="swarm" ;;
            3|cloud) MODE="cloud" ;;
            1|local) MODE="local" ;;
            "") MODE="$( [ "$RAM_GB" -ge 6 ] && echo "local" || echo "swarm" )" ;;
            *) MODE="local" ;;
        esac
    else
        MODE="$( [ "$RAM_GB" -ge 6 ] && echo "local" || echo "swarm" )"
    fi
fi

# 1. Setup Model Hub directory layout (needed for local GGUFs & SVD-32 adapters, harmless in swarm/cloud)
if [ "${MOBILE_SKIP_MODEL_DIR_SETUP:-0}" != "1" ]; then
    setup_model_directory "${CUSTOM_MODELS_DIR:-}" "$LODGE_DIR"
fi

CONF_FILE="$GEORGE_DIR/lodge.conf"
mkdir -p "$GEORGE_DIR/models/profiles" "$GEORGE_DIR/swarm"

SWARM_URL="${SWARM_INFERENCE_URL:-}"
SWARM_BROKER="${MQTT_BROKER:-}"
NODE_ID="${SWARM_NODE_ID:-$(hostname -s 2>/dev/null || echo "edge-node")}"
FALLBACK_PROV="${MOBILE_FALLBACK_PROVIDER:-}"

if [ "$MODE" = "swarm" ] || [ -n "$SWARM_URL" ]; then
    if [ -z "$SWARM_URL" ] && [ "$INTERACTIVE" -eq 1 ]; then
        printf "  Remote Swarm Inference Endpoint URL (e.g. http://hiram:8080): "
        read -r SWARM_URL
    fi
    SWARM_URL="${SWARM_URL:-http://127.0.0.1:8080}"
    if [ -z "$SWARM_BROKER" ] && [ "$INTERACTIVE" -eq 1 ]; then
        printf "  Optional Swarm MQTT Broker (e.g. hiram:1883, Enter to skip): "
        read -r SWARM_BROKER
    fi
fi

if [ "$MODE" = "cloud" ] || [ -n "$FALLBACK_PROV" ]; then
    if [ -z "$FALLBACK_PROV" ] && [ "$INTERACTIVE" -eq 1 ]; then
        printf "  Free-tier cloud provider [google|groq|openrouter] (default: google): "
        read -r FALLBACK_PROV
    fi
    FALLBACK_PROV="${FALLBACK_PROV:-google}"
fi

# 2. Write Model Hub-native configuration to .george/lodge.conf (no Ollama Modelfiles)
_upsert_conf "$CONF_FILE" "PROFILE_NAME" "\"mobile_edge_node\""
_upsert_conf "$CONF_FILE" "EDGE_TIER" "\"$REC_TIER\""
_upsert_conf "$CONF_FILE" "MOBILE_INFERENCE_MODE" "\"$MODE\""
_upsert_conf "$CONF_FILE" "INFERENCE_BACKEND" "\"llamacpp\""
_upsert_conf "$CONF_FILE" "SWARM_ROLE" "\"mobile_edge\""
_upsert_conf "$CONF_FILE" "SWARM_NODE_ID" "\"$NODE_ID\""
_upsert_conf "$CONF_FILE" "LOW_MEMORY_MODE" "1"
_upsert_conf "$CONF_FILE" "AUTONOMIC_ENABLED" "0"

if [ "$MODE" = "swarm" ]; then
    _upsert_conf "$CONF_FILE" "LLAMA_CPP_URL" "\"$SWARM_URL\""
    _upsert_conf "$CONF_FILE" "ACTIVE_ENDPOINT_URL" "\"$SWARM_URL\""
    _upsert_conf "$CONF_FILE" "REMOTE_SENTINEL_LLM_URL" "\"$SWARM_URL\""
    [ -n "$SWARM_BROKER" ] && _upsert_conf "$CONF_FILE" "MQTT_BROKER" "\"$SWARM_BROKER\""

    # Register remote inference endpoint in .george/endpoints.conf for instant /endpoint switching
    EP_FILE="$GEORGE_DIR/endpoints.conf"
    touch "$EP_FILE"
    if ! grep -q "^swarm_inference|" "$EP_FILE" 2>/dev/null; then
        printf 'swarm_inference|%s|llamacpp|Swarm Inference-Only Node (%s)\n' "$SWARM_URL" "$NODE_ID" >> "$EP_FILE"
    fi
    ok "Registered Swarm inference endpoint: ${CYAN}${SWARM_URL}${RESET} in ${EP_FILE}"
else
    _upsert_conf "$CONF_FILE" "LLAMA_CPP_URL" "\"http://127.0.0.1:8080\""
    if [ -n "$SWARM_URL" ]; then
        _upsert_conf "$CONF_FILE" "SWARM_INFERENCE_URL" "\"$SWARM_URL\""
    fi
fi

if [ -n "$FALLBACK_PROV" ]; then
    _upsert_conf "$CONF_FILE" "MOBILE_FALLBACK_PROVIDER" "\"$FALLBACK_PROV\""
    if [ "$MODE" = "cloud" ]; then
        _upsert_conf "$CONF_FILE" "GEORGE_PROVIDER" "\"$FALLBACK_PROV\""
    fi
    # Apply conservative free-tier pacing defaults from free-tier-limits.json if jq is present
    LIMITS_JSON="$LODGE_DIR/models/free-tier-limits.json"
    [ ! -f "$LIMITS_JSON" ] && LIMITS_JSON="$LODGE_DIR/configs/free-tier-limits.json"
    if [ -f "$LIMITS_JSON" ] && command -v jq &>/dev/null; then
        d_delay=$(jq -r --arg p "$FALLBACK_PROV" '.[$p].suggested["api-delay"] // 5' "$LIMITS_JSON" 2>/dev/null || echo 5)
        d_retries=$(jq -r --arg p "$FALLBACK_PROV" '.[$p].suggested["api-retries"] // 4' "$LIMITS_JSON" 2>/dev/null || echo 4)
        d_backoff=$(jq -r --arg p "$FALLBACK_PROV" '.[$p].suggested["api-backoff"] // 5' "$LIMITS_JSON" 2>/dev/null || echo 5)
        _upsert_conf "$CONF_FILE" "PROVIDER_CALL_DELAY" "$d_delay"
        _upsert_conf "$CONF_FILE" "PROVIDER_MAX_RETRIES" "$d_retries"
        _upsert_conf "$CONF_FILE" "PROVIDER_INITIAL_BACKOFF" "$d_backoff"
        ok "Configured free-tier cloud pacing for '${FALLBACK_PROV}' (delay=${d_delay}s, retries=${d_retries}, backoff=${d_backoff}s)"
    fi
fi

# 3. Write starter Model Hub profile for local edge inference (model-agnostic; operator picks exact GGUF via /models)
STARTER_PROFILE="$GEORGE_DIR/models/profiles/mobile-edge.json"
if [ ! -f "$STARTER_PROFILE" ]; then
    cat > "$STARTER_PROFILE" << EOF
{
  "name": "mobile-edge",
  "description": "Mobile/SBC LPDDR5+ edge profile (${REC_TIER}: ${REC_MODELS})",
  "backend": "llamacpp",
  "server": {
    "ctx": ${REC_CTX},
    "threads": $(nproc 2>/dev/null || echo 4),
    "flash_attn": true,
    "cache_type_k": "q8_0",
    "cache_type_v": "q8_0",
    "parallel": 1
  },
  "sampling": {
    "temperature": 0.4,
    "top_p": 0.95,
    "top_k": 40,
    "min_p": 0.05,
    "repeat_penalty": 1.05
  },
  "files": []
}
EOF
    ok "Created starter Model Hub profile: ${STARTER_PROFILE}"
fi

ok "Configured ${CONF_FILE} (mode=${MODE}, tier=${REC_TIER})"
echo ""
echo -e "${BOLD}Next Steps:${RESET}"
case "$MODE" in
    local)
        echo "  1. Browse & install a model for your RAM tier (${REC_MODELS}):"
        echo "       ./lodge   ->  /models search gemma-4-e4b   (or qwen3.5, nemotron)"
        echo "       /models fit && /models install <repo> <gguf>"
        echo "       /models activate <profile>"
        echo "  2. Optional: apply an SVD-32 role adapter via MODELS_DIR/adapters/<slug>/<role>/active.gguf"
        ;;
    swarm)
        echo "  1. Verify connectivity to your swarm inference node: curl -sf ${SWARM_URL}/health"
        echo "  2. Switch endpoints anytime with: /endpoint status  or  /endpoint switch swarm_inference"
        [ -n "$SWARM_BROKER" ] && echo "  3. Start lightweight sentinel triage worker: source lib/agents/remote_sentinel.sh && remote_sentinel_start"
        ;;
    cloud)
        echo "  1. Add your free-tier API key: ./lodge -> /api key ${FALLBACK_PROV} <YOUR_KEY>"
        echo "  2. Inspect rate-limit pacing: /limits models ${FALLBACK_PROV}  &&  /limits suggest ${FALLBACK_PROV}"
        echo "  3. Activate cloud harness:    /api use ${FALLBACK_PROV}"
        ;;
esac
echo -e "${GREEN}✓ Mobile / SBC Edge Profile Ready!${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
