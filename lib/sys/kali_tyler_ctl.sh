#!/usr/bin/env bash
# ── George: Kali Linux "Tyler" Outer Guard Container Controller ──────────────
[ -n "${_LIB_KALI_TYLER_CTL_LOADED:-}" ] && return 0
_LIB_KALI_TYLER_CTL_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-$LODGE_DIR/.george}"
KALI_TYLER_IMAGE="${KALI_TYLER_IMAGE:-george-kali-tyler:latest}"
KALI_TYLER_CONTAINER="${KALI_TYLER_CONTAINER:-george-kali-tyler}"
KALI_TYLER_WORK="${KALI_TYLER_WORK:-$GEORGE_DIR/tyler}"

kali_tyler_is_running() {
    docker inspect -f '{{.State.Running}}' "$KALI_TYLER_CONTAINER" 2>/dev/null | grep -q "true"
}

kali_tyler_build() {
    local df_dir="$LODGE_DIR/containers/kali-tyler"
    [ -f "$df_dir/Dockerfile" ] || { echo "ERROR: $df_dir/Dockerfile not found" >&2; return 1; }
    docker build -t "$KALI_TYLER_IMAGE" "$df_dir"
}

kali_tyler_ensure_running() {
    mkdir -p "$KALI_TYLER_WORK"
    if kali_tyler_is_running; then
        return 0
    fi
    if ! docker image inspect "$KALI_TYLER_IMAGE" >/dev/null 2>&1; then
        kali_tyler_build || return 1
    fi
    docker rm -f "$KALI_TYLER_CONTAINER" >/dev/null 2>&1 || true
    docker run -d \
        --name "$KALI_TYLER_CONTAINER" \
        --restart unless-stopped \
        --network host \
        --cap-add=NET_RAW \
        --cap-add=NET_ADMIN \
        -v "$KALI_TYLER_WORK:/tyler" \
        "$KALI_TYLER_IMAGE" >/dev/null
}

kali_tyler_exec() {
    kali_tyler_ensure_running || return 1
    docker exec "$KALI_TYLER_CONTAINER" "$@"
}

kali_tyler_status_json() {
    local running="false"
    if kali_tyler_is_running; then
        running="true"
    fi
    local image_present="false"
    if docker image inspect "$KALI_TYLER_IMAGE" >/dev/null 2>&1; then
        image_present="true"
    fi
    printf '{"container":"%s","image":"%s","running":%s,"image_present":%s}\n' \
        "$KALI_TYLER_CONTAINER" "$KALI_TYLER_IMAGE" "$running" "$image_present"
}

