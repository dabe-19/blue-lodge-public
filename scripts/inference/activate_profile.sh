#!/usr/bin/env bash
# ── George Model Hub: activate an installed profile ───────────────────
# Usage: activate_profile.sh <profile> [--dry-run] [--runtime auto|docker|native] [--port 8080]
#        activate_profile.sh --rollback
# Serves the profile with upstream llama.cpp (official ghcr image per GPU backend, or a native
# llama-server binary), points George's Tier 1 at it, and records how to roll back.
set -uo pipefail
LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
GEORGE_DIR="${GEORGE_DIR:-$LODGE_DIR/.george}"
STATE_DIR="$GEORGE_DIR/models"; mkdir -p "$STATE_DIR"
STATE="$STATE_DIR/active_profile.json"
ENDPOINTS="$GEORGE_DIR/endpoints.conf"
CONTAINER="george-hub-inference"
STOP_LIST="${MODEL_HUB_STOP_CONTAINERS:-george-prism-server george-prism-worker}"

die() { echo "✗ $*" >&2; exit 1; }
MH() { python3 "$LODGE_DIR/lib/tools/model_hub_cli.py" "$@"; }

name="" dry=0 runtime="${MODEL_HUB_RUNTIME:-auto}" port="${HUB_PORT:-8080}" rollback=0
# Native runtime binary: any llama.cpp-compatible llama-server (upstream or your own fork).
SERVER_BIN="${LLAMA_SERVER_BIN:-${LLAMA_CPP_SERVER_BIN:-llama-server}}"
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) dry=1 ;;
        --runtime) runtime="${2:-}"; shift ;;
        --port) port="${2:-}"; shift ;;
        --rollback) rollback=1 ;;
        -*) die "unknown flag $1" ;;
        *) name="$1" ;;
    esac
    shift
done
[[ "$port" =~ ^[0-9]{2,5}$ ]] || die "invalid port"
[[ "$runtime" =~ ^(auto|docker|native)$ ]] || die "runtime must be auto|docker|native"

run() { if [ "$dry" = 1 ]; then printf 'DRY-RUN:'; printf ' %q' "$@"; echo; else "$@"; fi; }

if [ "$rollback" = 1 ]; then
    [ -f "$STATE" ] || die "nothing to roll back (no $STATE)"
    rt=$(jq -r '.runtime' "$STATE")
    if [ "$rt" = "docker" ]; then run docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    else pid=$(jq -r '.pid // empty' "$STATE"); [ -n "$pid" ] && run kill "$pid" 2>/dev/null || true; fi
    for c in $(jq -r '.stopped_containers[]?' "$STATE"); do run docker start "$c" >/dev/null && echo "↺ restarted $c"; done
    bak=$(jq -r '.endpoints_backup // empty' "$STATE")
    [ -n "$bak" ] && [ -f "$bak" ] && run cp "$bak" "$ENDPOINTS" && echo "↺ restored $ENDPOINTS"
    [ "$dry" = 1 ] || rm -f "$STATE"
    echo "✓ rolled back"
    exit 0
fi

[[ "$name" =~ ^[a-z0-9][a-z0-9._-]{1,63}$ ]] || die "usage: activate_profile.sh <profile> [--dry-run]"
profile=$(MH show "$name") || die "$(jq -r '.error' <<<"$profile" 2>/dev/null || echo "$profile")"
[ "$(jq -r '.status' <<<"$profile")" = "installed" ] || die "profile '$name' is not installed (run /models install $name)"
[ "$(jq -r '.approved_valid' <<<"$profile")" = "true" ] || die "profile '$name' approval is no longer valid (edited after approval)"

backend=$(MH hw | jq -r '.gpu_backend // "cpu"')
if [ "$runtime" = "auto" ]; then
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then runtime=docker
    elif command -v "$SERVER_BIN" >/dev/null 2>&1; then runtime=native
    else die "no runtime: install Docker, put llama-server on PATH, or set LLAMA_SERVER_BIN"; fi
fi
native_flag=(); [ "$runtime" = "native" ] && native_flag=(--native)
envjson=$(MH env "$name" "${native_flag[@]}") || die "$(jq -r '.error' <<<"$envjson")"
envfile="$STATE_DIR/active.env"
jq -r 'to_entries[] | select((.value|tostring|test("[\n\r]"))|not) | "\(.key)=\(.value)"' <<<"$envjson" > "$envfile.tmp" || die "env render failed"
if [ "$dry" = 1 ]; then sed 's/^/ENV: /' "$envfile.tmp"; rm -f "$envfile.tmp"; else mv "$envfile.tmp" "$envfile"; fi
chmod 600 "$envfile" 2>/dev/null || true

# LoRA / control vectors: llama.cpp has no LLAMA_ARG_* env for these, so they are CLI args.
# render_args re-hashes every adapter and refuses if one changed since approval.
argsjson=$(MH args "$name" "${native_flag[@]}") || die "$(jq -r '.error' <<<"$argsjson")"
extra=()
while IFS= read -r a; do
    [[ "$a" =~ ^(--lora-scaled|--control-vector-scaled|/[A-Za-z0-9._/,:+-]+)$ ]] || die "refusing unexpected server arg: $a"
    extra+=("$a")
done < <(jq -r '.[]' <<<"$argsjson")
[ "$dry" = 1 ] && [ ${#extra[@]} -gt 0 ] && printf 'ARGS:%s\n' "$(printf ' %q' "${extra[@]}")"

ctx=$(jq -r '.server.ctx // 32768' <<<"$profile")
temp=$(jq -r '.sampling.temperature // empty' <<<"$profile")
topp=$(jq -r '.sampling.top_p // empty' <<<"$profile")

stopped=()
start_docker() {
    local tag dev=()
    case "$backend" in
        cuda)   tag=server-cuda;   dev=(--gpus all) ;;
        rocm)   tag=server-rocm;   dev=(--device /dev/kfd --device /dev/dri --group-add video) ;;
        vulkan) tag=server-vulkan; dev=(--device /dev/dri) ;;
        metal)  die "Metal is not available inside Docker; use --runtime native with a macOS llama-server" ;;
        *)      tag=server ;;
    esac
    tag="${HUB_IMAGE_TAG:-$tag}"
    for c in $STOP_LIST "$CONTAINER"; do
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then
            run docker stop "$c" >/dev/null && echo "■ stopped $c"
            [ "$c" != "$CONTAINER" ] && stopped+=("$c")
        fi
    done
    run docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    run docker run -d --name "$CONTAINER" --restart unless-stopped \
        -p "127.0.0.1:${port}:8080" --env-file "$envfile" \
        -e LLAMA_ARG_HOST=0.0.0.0 -e LLAMA_ARG_PORT=8080 \
        -v "${MODELS_DIR:-${MODELS_HOST_DIR:-$HOME/models}}":/models:ro "${dev[@]}" \
        "ghcr.io/ggml-org/llama.cpp:${tag}" "${extra[@]}" >/dev/null || die "docker run failed"
}

pid=""
start_native() {
    if [ "$dry" = 1 ]; then echo "DRY-RUN: env \$(cat $envfile) $SERVER_BIN --host 127.0.0.1 --port $port ${extra[*]}"; return; fi
    ( set -a; source "$envfile"; set +a
      exec nohup "$SERVER_BIN" --host 127.0.0.1 --port "$port" "${extra[@]}" >"$STATE_DIR/llama-server.log" 2>&1 ) &
    pid=$!
}

bak=""
if [ -f "$ENDPOINTS" ]; then
    bak="$STATE_DIR/endpoints.conf.pre-$(date +%Y%m%d%H%M%S)"
    run cp "$ENDPOINTS" "$bak"
fi

if [ "$runtime" = docker ]; then start_docker; else start_native; fi

if [ -f "$ENDPOINTS" ]; then
    setkv() { run sed -i "s|^$1=.*|$1=$2|" "$ENDPOINTS"; grep -q "^$1=" "$ENDPOINTS" || run sh -c "echo '$1=$2' >> '$ENDPOINTS'"; }
    setkv TIER1_URL "\"http://127.0.0.1:${port}\""
    setkv TIER1_MODEL "\"${name}\""
    setkv TIER1_CONTEXT "$ctx"
    setkv TIER1_MAX_TOKENS "$(( ctx * 95 / 100 ))"
    setkv TIER1_COMPACT_TOKENS "$(( ctx * 85 / 100 ))"
    [ -n "$temp" ] && setkv TIER1_TEMPERATURE "$temp"
    [ -n "$topp" ] && setkv TIER1_TOP_P "$topp"
    setkv TIER2_ENABLED 0
fi

if [ "$dry" = 0 ]; then
    jq -n --arg n "$name" --arg rt "$runtime" --arg b "$backend" --arg bak "$bak" --arg pid "$pid" --argjson port "$port" \
        --args '{name:$n, runtime:$rt, backend:$b, port:$port, endpoints_backup:$bak, pid:($pid|select(.!="")),
                 stopped_containers:$ARGS.positional, activated_at:(now|floor)}' "${stopped[@]}" > "$STATE"
    echo "… waiting for llama-server on :$port (model load can take minutes)"
    for _ in $(seq 1 "${HUB_HEALTH_WAIT:-180}"); do
        curl -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1 && { echo "✓ $name is serving on http://127.0.0.1:${port} (ctx $ctx)"; echo "  rollback: /models activate --rollback"; exit 0; }
        sleep 2
    done
    die "server did not become healthy; see 'docker logs $CONTAINER' or $STATE_DIR/llama-server.log — rollback with: /models activate --rollback"
fi
echo "DRY-RUN complete (runtime=$runtime backend=$backend)"
