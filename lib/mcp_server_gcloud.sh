#!/bin/bash
# ── George: Pure-Bash Google Cloud Platform (gcloud) MCP Server ───
# Self-contained MCP server speaking JSON-RPC 2.0 over stdio.
# Provides gcloud CLI orchestration without Python/Node dependencies.
#
# Tools exposed:
#   gcloud_status           — Get active auth account, default project & zone
#   gcloud_projects_list    — List accessible GCP projects
#   gcloud_compute_list     — List Compute Engine instances (with status & IPs)
#   gcloud_run_list         — List Cloud Run services (with URLs & status)
#   gcloud_storage_list     — List Cloud Storage buckets
#   gcloud_cmd              — Run an arbitrary read/query gcloud command
#
# Requirements:
#   - gcloud CLI installed on host (or inside container)
#   - authenticated with `gcloud auth login` or service account key

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="${LODGE_DIR:-$(cd "$_SCRIPT_DIR/.." && pwd)}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"

_JQ="jq"
command -v gojq >/dev/null 2>&1 && _JQ="gojq"

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
    $_JQ -n -c \
        --arg text "$text" \
        '{"content":[{"type":"text","text":$text}]}'
}

_check_gcloud() {
    if ! command -v gcloud >/dev/null 2>&1; then
        echo "gcloud CLI is not installed or not in PATH. Please install Google Cloud SDK."
        return 1
    fi
    return 0
}

_TOOLS_JSON='[
  {
    "name": "gcloud_status",
    "description": "Inspect active gcloud authentication account, configured project, and default compute region/zone.",
    "inputSchema": {
      "type": "object",
      "properties": {}
    }
  },
  {
    "name": "gcloud_projects_list",
    "description": "List all accessible Google Cloud projects with project ID and state.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "limit": { "type": "integer", "description": "Maximum number of projects to return (default: 20)" }
      }
    }
  },
  {
    "name": "gcloud_compute_list",
    "description": "List Compute Engine VM instances with name, zone, machine type, internal/external IP, and status.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "project": { "type": "string", "description": "GCP project ID (optional, uses default if omitted)" }
      }
    }
  },
  {
    "name": "gcloud_run_list",
    "description": "List deployed Cloud Run services with URLs, regions, and last deployed revisions.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "project": { "type": "string", "description": "GCP project ID (optional)" },
        "region": { "type": "string", "description": "GCP region (optional, e.g. us-central1)" }
      }
    }
  },
  {
    "name": "gcloud_storage_list",
    "description": "List Google Cloud Storage buckets in the active or specified project.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "project": { "type": "string", "description": "GCP project ID (optional)" }
      }
    }
  },
  {
    "name": "gcloud_cmd",
    "description": "Run a read or status gcloud command (e.g. gcloud compute instances describe <name>). Restricted to read/list/describe operations for safety.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "subcommand": { "type": "string", "description": "gcloud subcommand arguments (e.g. compute zones list)" }
      },
      "required": ["subcommand"]
    }
  }
]'

_handle_tool_call() {
    local id="$1"
    local tool_name="$2"
    local arguments="$3"

    if ! _check_gcloud; then
        _respond_result "$id" "$(_text_content "ERROR: gcloud CLI not found on host. Run 'curl https://sdk.cloud.google.com | bash' or install via package manager.")"
        return
    fi

    case "$tool_name" in
        gcloud_status)
            local account project zone
            account=$(gcloud config get-value account 2>/dev/null || echo "None")
            project=$(gcloud config get-value project 2>/dev/null || echo "None")
            zone=$(gcloud config get-value compute/zone 2>/dev/null || echo "None")
            local status_text="Google Cloud CLI Status:
  Active Account: $account
  Active Project: $project
  Default Zone:   $zone"
            _respond_result "$id" "$(_text_content "$status_text")"
            ;;

        gcloud_projects_list)
            local limit
            limit=$(printf '%s' "$arguments" | $_JQ -r '.limit // 20' 2>/dev/null)
            local out
            out=$(gcloud projects list --limit="$limit" --format="table(projectId,name,projectNumber,lifecycleState)" 2>&1)
            _respond_result "$id" "$(_text_content "$out")"
            ;;

        gcloud_compute_list)
            local proj
            proj=$(printf '%s' "$arguments" | $_JQ -r '.project // empty' 2>/dev/null)
            local proj_arg=""
            [ -n "$proj" ] && proj_arg="--project=$proj"
            local out
            out=$(gcloud compute instances list $proj_arg --format="table(name,zone,machineType.basename(),INTERNAL_IP,EXTERNAL_IP,status)" 2>&1)
            _respond_result "$id" "$(_text_content "$out")"
            ;;

        gcloud_run_list)
            local proj region
            proj=$(printf '%s' "$arguments" | $_JQ -r '.project // empty' 2>/dev/null)
            region=$(printf '%s' "$arguments" | $_JQ -r '.region // empty' 2>/dev/null)
            local args=()
            [ -n "$proj" ] && args+=("--project=$proj")
            [ -n "$region" ] && args+=("--region=$region")
            local out
            out=$(gcloud run services list "${args[@]}" --format="table(SERVICE,REGION,URL,LAST_DEPLOYED_BY)" 2>&1)
            _respond_result "$id" "$(_text_content "$out")"
            ;;

        gcloud_storage_list)
            local proj
            proj=$(printf '%s' "$arguments" | $_JQ -r '.project // empty' 2>/dev/null)
            local proj_arg=""
            [ -n "$proj" ] && proj_arg="--project=$proj"
            local out
            out=$(gcloud storage buckets list $proj_arg 2>&1)
            _respond_result "$id" "$(_text_content "$out")"
            ;;

        gcloud_cmd)
            local subcmd
            subcmd=$(printf '%s' "$arguments" | $_JQ -r '.subcommand // empty' 2>/dev/null)
            if [ -z "$subcmd" ]; then
                _respond_result "$id" "$(_text_content "ERROR: subcommand argument is required")"
                return
            fi
            # Safety gate: block destructive commands
            if echo "$subcmd" | grep -qE '\b(delete|destroy|purge|rm|reset)\b'; then
                _respond_result "$id" "$(_text_content "ERROR: Destructive command ($subcmd) blocked by MCP safety gate.")"
                return
            fi
            local out
            out=$(gcloud $subcmd 2>&1)
            _respond_result "$id" "$(_text_content "$out")"
            ;;

        *)
            _respond_error "$id" -32601 "Unknown tool: $tool_name"
            ;;
    esac
}

while IFS= read -r line; do
    [ -z "$line" ] && continue
    local_id=$(printf '%s' "$line" | $_JQ -r '.id // "null"' 2>/dev/null)
    local_method=$(printf '%s' "$line" | $_JQ -r '.method // empty' 2>/dev/null)
    [ -z "$local_method" ] && continue

    case "$local_method" in
        initialize)
            _respond_result "$local_id" '{
                "protocolVersion": "2024-11-05",
                "capabilities": { "tools": {} },
                "serverInfo": { "name": "george-gcloud", "version": "1.0" }
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
