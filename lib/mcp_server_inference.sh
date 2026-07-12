#!/bin/bash
# ── George: Pure-Bash MCP Inference Server ─────────────────────
# A self-contained MCP server that speaks JSON-RPC 2.0 over stdio.
# Bridges George to remote Ollama + llama-server APIs for catalog
# management, health checks, and model pulling.
#
# Tools exposed:
#   inference_status  — Health check for Ollama + llama-server
#   inference_models  — List models on remote Ollama
#   inference_ps      — Show loaded model and VRAM usage
#   inference_pull    — Pull a model to remote Ollama
#   inference_load    — Pre-warm a model into memory
#
# Usage:
#   Register as MCP server:
#     /mcp add george-inference "bash $LODGE_DIR/lib/mcp_server_inference.sh"
#
#   Or run standalone:
#     echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | bash lib/mcp_server_inference.sh

set -uo pipefail

# ── Bootstrap George libraries ─────────────────────────────────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="${LODGE_DIR:-$(cd "$_SCRIPT_DIR/.." && pwd)}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR:-.}/.george}"

# Source dependencies
source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true

# ── Endpoint URLs ──────────────────────────────────────────────
OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
LLAMA_CPP_URL="${LLAMA_CPP_URL:-http://127.0.0.1:8080}"

# ── jq ────────────────────────────────────────────────────────
_JQ="jq"
command -v gojq >/dev/null 2>&1 && _JQ="gojq"

# ── JSON-RPC Response Helpers ──────────────────────────────────

_respond_result() {
    local id="$1"
    local result_json="$2"
    $_JQ -n -c \
        --argjson id "$id" \
        --argjson result "$result_json" \
        '{"jsonrpc":"2.0","id":$id,"result":$result}'
}

_respond_error() {
    local id="$1"
    local code="$2"
    local message="$3"
    if [ "$id" = "null" ]; then
        $_JQ -n -c \
            --argjson code "$code" \
            --arg message "$message" \
            '{"jsonrpc":"2.0","id":null,"error":{"code":$code,"message":$message}}'
    else
        $_JQ -n -c \
            --argjson id "$id" \
            --argjson code "$code" \
            --arg message "$message" \
            '{"jsonrpc":"2.0","id":$id,"error":{"code":$code,"message":$message}}'
    fi
}

_text_content() {
    local text="$1"
    $_JQ -n -c --arg text "$text" \
        '{"content":[{"type":"text","text":$text}]}'
}

# ── Tool Definitions ───────────────────────────────────────────

_TOOLS_JSON='[
  {
    "name": "inference_status",
    "description": "Check health of remote Ollama and llama-server endpoints. Returns connection status, loaded model, GPU device, and model count.",
    "inputSchema": {
      "type": "object",
      "properties": {},
      "required": []
    }
  },
  {
    "name": "inference_models",
    "description": "List all models available on the remote Ollama instance. Returns model names, sizes, quantization levels, and parameter counts.",
    "inputSchema": {
      "type": "object",
      "properties": {},
      "required": []
    }
  },
  {
    "name": "inference_ps",
    "description": "Show currently loaded model(s) on the remote Ollama instance, including VRAM usage and processor type.",
    "inputSchema": {
      "type": "object",
      "properties": {},
      "required": []
    }
  },
  {
    "name": "inference_pull",
    "description": "Pull (download) a model to the remote Ollama instance by exact tag. Use exact Ollama tags like qwen3:8b, llama3.1:8b, etc. This blocks until the download completes.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "model": {
          "type": "string",
          "description": "The exact Ollama model tag to pull (e.g. qwen3:8b, llama3.1:8b-instruct-q4_K_M)"
        }
      },
      "required": ["model"]
    }
  },
  {
    "name": "inference_load",
    "description": "Pre-warm a model into memory on the remote Ollama instance. Sends a minimal request with keep_alive to load the model without generating a full response.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "model": {
          "type": "string",
          "description": "The Ollama model name to load into memory (e.g. qwen3:8b)"
        },
        "keep_alive": {
          "type": "string",
          "description": "How long to keep the model loaded (e.g. 5m, 1h, -1 for indefinite). Default: 5m"
        }
      },
      "required": ["model"]
    }
  }
]'

# ── Tool Dispatch ──────────────────────────────────────────────

_handle_tool_call() {
    local id="$1"
    local tool_name="$2"
    local arguments="$3"

    case "$tool_name" in
        inference_status)
            local _result=""
            local _ollama_ok=0 _llamacpp_ok=0

            # Probe Ollama
            local _tags
            _tags=$(curl -sf --max-time 5 "$OLLAMA_URL/api/tags" 2>/dev/null)
            if [ $? -eq 0 ] && [ -n "$_tags" ]; then
                local _model_count
                _model_count=$(printf '%s' "$_tags" | $_JQ '.models | length' 2>/dev/null)
                _result="Ollama: running (${_model_count:-0} models at $OLLAMA_URL)"
                _ollama_ok=1
            else
                _result="Ollama: unreachable at $OLLAMA_URL"
            fi

            # Probe llama-server
            local _health
            _health=$(curl -sf --max-time 5 "$LLAMA_CPP_URL/health" 2>/dev/null)
            if [ $? -eq 0 ] && [ -n "$_health" ]; then
                local _lstatus
                _lstatus=$(printf '%s' "$_health" | $_JQ -r '.status // "unknown"' 2>/dev/null)
                _result="${_result}\nllama-server: ${_lstatus} at $LLAMA_CPP_URL"
                _llamacpp_ok=1

                # Get props for GPU info
                local _props
                _props=$(curl -sf --max-time 5 "$LLAMA_CPP_URL/props" 2>/dev/null)
                if [ $? -eq 0 ] && [ -n "$_props" ]; then
                    _result="${_result}\nServer props: $(printf '%s' "$_props" | $_JQ -c '.' 2>/dev/null)"
                fi
            else
                _result="${_result}\nllama-server: unreachable at $LLAMA_CPP_URL"
            fi

            _respond_result "$id" "$(_text_content "$(echo -e "$_result")")"
            ;;

        inference_models)
            local _tags
            _tags=$(curl -sf --max-time 10 "$OLLAMA_URL/api/tags" 2>/dev/null)
            if [ $? -ne 0 ] || [ -z "$_tags" ]; then
                _respond_result "$id" "$(_text_content "Error: Cannot reach Ollama at $OLLAMA_URL")"
                return
            fi

            local _models
            _models=$(printf '%s' "$_tags" | $_JQ -r '
                .models[] |
                "\(.name)\t\(.details.parameter_size // "?")\t\(.details.quantization_level // "?")\t\(.size / 1073741824 | . * 100 | floor / 100)GB\t\(.details.family // "?")"
            ' 2>/dev/null)

            if [ -z "$_models" ]; then
                _respond_result "$id" "$(_text_content "No models found on remote Ollama.")"
                return
            fi

            local _header="NAME\tPARAMS\tQUANT\tSIZE\tFAMILY"
            _respond_result "$id" "$(_text_content "$(printf '%s\n%s' "$_header" "$_models")")"
            ;;

        inference_ps)
            local _ps
            _ps=$(curl -sf --max-time 5 "$OLLAMA_URL/api/ps" 2>/dev/null)
            if [ $? -ne 0 ] || [ -z "$_ps" ]; then
                _respond_result "$id" "$(_text_content "Error: Cannot reach Ollama at $OLLAMA_URL")"
                return
            fi

            local _loaded
            _loaded=$(printf '%s' "$_ps" | $_JQ -r '
                if (.models | length) == 0 then "No models currently loaded."
                else .models[] | "Model: \(.name)\n  Size: \(.size / 1073741824 | . * 100 | floor / 100)GB\n  VRAM: \(.size_vram / 1073741824 | . * 100 | floor / 100)GB\n  Processor: \(.details.quantization_level // "?")\n  Expires: \(.expires_at // "unknown")"
                end
            ' 2>/dev/null)

            _respond_result "$id" "$(_text_content "${_loaded:-No data}")"
            ;;

        inference_pull)
            local _model
            _model=$(printf '%s' "$arguments" | $_JQ -r '.model // empty' 2>/dev/null)

            if [ -z "$_model" ]; then
                _respond_result "$id" "$(_text_content "Error: model parameter is required")"
                return
            fi

            # Validate model tag format (basic check)
            if [[ "$_model" =~ [^a-zA-Z0-9_./:@-] ]]; then
                _respond_result "$id" "$(_text_content "Error: Invalid model tag format: $_model")"
                return
            fi

            local _pull_result
            _pull_result=$(curl -sf --max-time 600 "$OLLAMA_URL/api/pull" \
                -d "{\"name\":\"$_model\",\"stream\":false}" 2>&1)
            local _rc=$?

            if [ $_rc -eq 0 ]; then
                local _status
                _status=$(printf '%s' "$_pull_result" | $_JQ -r '.status // "unknown"' 2>/dev/null)
                _respond_result "$id" "$(_text_content "Pull $_model: $_status")"
            else
                _respond_result "$id" "$(_text_content "Error pulling $_model: $_pull_result")"
            fi
            ;;

        inference_load)
            local _model _keep_alive
            _model=$(printf '%s' "$arguments" | $_JQ -r '.model // empty' 2>/dev/null)
            _keep_alive=$(printf '%s' "$arguments" | $_JQ -r '.keep_alive // "5m"' 2>/dev/null)

            if [ -z "$_model" ]; then
                _respond_result "$id" "$(_text_content "Error: model parameter is required")"
                return
            fi

            # Pre-warm: send a minimal generate request with keep_alive
            local _load_result
            _load_result=$(curl -sf --max-time 600 "$OLLAMA_URL/api/generate" \
                -d "{\"model\":\"$_model\",\"prompt\":\"\",\"keep_alive\":\"$_keep_alive\",\"stream\":false}" 2>&1)
            local _rc=$?

            if [ $_rc -eq 0 ]; then
                _respond_result "$id" "$(_text_content "Model $_model loaded (keep_alive=$_keep_alive)")"
            else
                _respond_result "$id" "$(_text_content "Error loading $_model: $_load_result")"
            fi
            ;;

        *)
            _respond_error "$id" -32601 "Unknown tool: $tool_name"
            ;;
    esac
}

# ── Main JSON-RPC Loop ────────────────────────────────────────

while IFS= read -r line; do
    [ -z "$line" ] && continue

    local_id=$(printf '%s' "$line" | $_JQ -r '.id // "null"' 2>/dev/null)
    local_method=$(printf '%s' "$line" | $_JQ -r '.method // empty' 2>/dev/null)

    if [ -z "$local_method" ]; then
        continue
    fi

    case "$local_method" in
        initialize)
            _respond_result "$local_id" '{
                "protocolVersion": "2024-11-05",
                "capabilities": {
                    "tools": {}
                },
                "serverInfo": {
                    "name": "george-inference",
                    "version": "1.0"
                }
            }'
            ;;

        tools/list)
            _respond_result "$local_id" "{\"tools\":$_TOOLS_JSON}"
            ;;

        tools/call)
            tool_name=$(printf '%s' "$line" | $_JQ -r '.params.name // empty' 2>/dev/null)
            tool_args=$(printf '%s' "$line" | $_JQ -r '.params.arguments // {}' 2>/dev/null)
            _handle_tool_call "$local_id" "$tool_name" "$tool_args"
            ;;

        notifications/*)
            ;;

        *)
            _respond_error "$local_id" -32601 "Method not found: $local_method"
            ;;
    esac
done
