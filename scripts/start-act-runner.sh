#!/bin/bash
# ── George: Sovereign Act Runner Bootstrap (2026) ─────────────────────
# Provisions and connects a local Gitea Act-Runner container to
# the sovereign Gitea forge for running CI/CD workflows and automated test gates.

set -euo pipefail

LODGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${LODGE_DIR}/.act-runner-data"
CONTAINER_NAME="george-act-runner"
GITEA_CONTAINER="george-gitea"
GITEA_URL="http://127.0.0.1:3088"

source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true

action="${1:-start}"

case "$action" in
    status)
        if docker ps --filter "name=^/${CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
            ui_ok "Act Runner '${CONTAINER_NAME}' is ACTIVE and RUNNING."
            docker ps --filter "name=^/${CONTAINER_NAME}$" --format "table {{.ID}}\t{{.Status}}\t{{.Image}}"
        else
            ui_dim "Act Runner '${CONTAINER_NAME}' is NOT running."
        fi
        exit 0
        ;;
    stop)
        ui_step "Stopping Act Runner container '${CONTAINER_NAME}'..."
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
        ui_ok "Act Runner stopped."
        exit 0
        ;;
    restart)
        ui_step "Restarting Act Runner container '${CONTAINER_NAME}'..."
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
        ;;
    start)
        ;;
    *)
        echo "Usage: $0 [start|stop|restart|status]"
        exit 1
        ;;
esac

# 1. Verify Gitea container is running
if ! docker ps --filter "name=^/${GITEA_CONTAINER}$" --format '{{.Names}}' | grep -q "^${GITEA_CONTAINER}$"; then
    ui_err "Sovereign Gitea container '${GITEA_CONTAINER}' is not running!"
    ui_info "Start Gitea first with: bash scripts/start-gitea.sh"
    exit 1
fi

# 2. Check if runner already running
if docker ps --filter "name=^/${CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    ui_ok "Act Runner '${CONTAINER_NAME}' is already running."
    exit 0
fi

# Remove stopped/dead container if present
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

# 3. Obtain runner registration token from Gitea
ui_step "Acquiring runner registration token from Gitea container..."
RUNNER_TOKEN=$(docker exec -u git "$GITEA_CONTAINER" gitea actions generate-runner-token 2>/dev/null | tr -d '\r\n')

if [ -z "$RUNNER_TOKEN" ]; then
    ui_err "Failed to obtain runner token from ${GITEA_CONTAINER}."
    exit 1
fi
ui_ok "Acquired runner token: ${RUNNER_TOKEN:0:8}..."

# 4. Prepare data directory and config
mkdir -p "$DATA_DIR"
if [ -f "${DATA_DIR}/.runner" ]; then
    sed -i 's|docker://debian:bookworm-slim|docker://node:20-bookworm|g' "${DATA_DIR}/.runner"
fi

cat <<'EOF' > "${DATA_DIR}/config.yaml"
log:
  level: info

runner:
  file: .runner
  capacity: 1
  timeout: 3h
  insecure: false
  fetch_timeout: 5s
  fetch_interval: 2s
  labels:
    - "ubuntu-latest:docker://node:20-bookworm"
    - "debian:docker://node:20-bookworm"
    - "bash:docker://node:20-bookworm"

cache:
  enabled: false

container:
  network: "host"
  force_pull: false
EOF

# 5. Launch Act Runner with host networking and Docker socket mount
ui_step "Launching '${CONTAINER_NAME}' with host networking..."
docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --net host \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${DATA_DIR}:/data" \
    -e CONFIG_FILE="/data/config.yaml" \
    -e GITEA_INSTANCE_URL="${GITEA_URL}" \
    -e GITEA_RUNNER_REGISTRATION_TOKEN="${RUNNER_TOKEN}" \
    -e GITEA_RUNNER_NAME="george-local-runner" \
    -e GITEA_RUNNER_LABELS="ubuntu-latest:docker://node:20-bookworm,debian:docker://node:20-bookworm,bash:docker://node:20-bookworm" \
    gitea/act_runner:latest >/dev/null

sleep 2

if docker ps --filter "name=^/${CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    ui_ok "Sovereign Act Runner is active and connected to Gitea at ${GITEA_URL}!"
else
    ui_err "Act Runner failed to start. Container logs:"
    docker logs "$CONTAINER_NAME" 2>&1 | tail -n 20
    exit 1
fi
