#!/usr/bin/env bash
#
# start-gitea.sh: Sovereign Gitea Container Bootstrap & Provisioning for George
# Launches Gitea on port 3088 (HTTP) and 2222 (SSH), initializes admin user 'george',
# registers George's SSH/GPG keys, creates 'george/blue-lodge' repository, and
# configures GitFlow branch protection rules.
#

set -eo pipefail

LODGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEORGE_DIR="${LODGE_ROOT}/.george"
GITEA_DATA_DIR="${LODGE_ROOT}/.gitea-data"
GITEA_CONF="${GEORGE_DIR}/gitea.conf"
CONTAINER_NAME="george-gitea"
GITEA_HTTP_PORT="${GITEA_HTTP_PORT:-3088}"
GITEA_SSH_PORT="${GITEA_SSH_PORT:-2222}"
GITEA_USER="george"
GITEA_REPO="blue-lodge"

# Ensure directories
mkdir -p "$GEORGE_DIR" "$GITEA_DATA_DIR/gitea/conf" 2>/dev/null || true

echo "── Sovereign Gitea: Bootstrap & Health Check ──"

# Check Docker
if ! command -v docker &>/dev/null; then
    echo "[-] Error: docker is not installed or available." >&2
    exit 1
fi

# Pre-seed app.ini if not existing
APP_INI="$GITEA_DATA_DIR/gitea/conf/app.ini"
if [ ! -f "$APP_INI" ]; then
    echo "[+] Pre-configuring Gitea app.ini for zero-browser initialization..."
    cat > "$APP_INI" << EOF
APP_NAME = Sovereign Lodge Forge
RUN_USER = git
RUN_MODE = prod

[database]
DB_TYPE = sqlite3
PATH = /data/gitea/gitea.db

[server]
SSH_DOMAIN = 127.0.0.1
DOMAIN = 127.0.0.1
HTTP_PORT = 3000
ROOT_URL = http://127.0.0.1:${GITEA_HTTP_PORT}/
DISABLE_SSH = false
SSH_PORT = ${GITEA_SSH_PORT}
LFS_START_SERVER = false

[service]
DISABLE_REGISTRATION = true
REQUIRE_SIGNIN_VIEW = false

[security]
INSTALL_LOCK = true
SECRET_KEY = lodge-secret-$(date +%s)

[actions]
ENABLED = true
DEFAULT_ACTIONS_URL = github
EOF
    chmod 666 "$APP_INI" 2>/dev/null || true
fi

# Check if container is already running
if docker ps --filter "name=${CONTAINER_NAME}" --filter "status=running" | grep -q "${CONTAINER_NAME}"; then
    echo "[✓] Container '${CONTAINER_NAME}' is already running."
else
    # Check if stopped container exists
    if docker ps -a --filter "name=${CONTAINER_NAME}" | grep -q "${CONTAINER_NAME}"; then
        echo "[+] Starting existing stopped '${CONTAINER_NAME}' container..."
        docker start "${CONTAINER_NAME}" >/dev/null
    else
        echo "[+] Launching new '${CONTAINER_NAME}' container on ports ${GITEA_HTTP_PORT} (HTTP) and ${GITEA_SSH_PORT} (SSH)..."
        docker run -d \
            --name "${CONTAINER_NAME}" \
            --restart unless-stopped \
            -p "${GITEA_HTTP_PORT}:3000" \
            -p "${GITEA_SSH_PORT}:22" \
            -v "${GITEA_DATA_DIR}:/data" \
            gitea/gitea:latest >/dev/null
    fi
fi

# Wait for Gitea API to be ready
echo -n "[+] Waiting for Gitea service on port ${GITEA_HTTP_PORT}..."
ready=0
for i in {1..30}; do
    if curl -sf "http://127.0.0.1:${GITEA_HTTP_PORT}/api/v1/version" &>/dev/null; then
        ready=1
        break
    fi
    echo -n "."
    sleep 1
done
echo ""

if [ "$ready" -ne 1 ]; then
    echo "[-] Error: Gitea failed to respond within 30 seconds." >&2
    exit 1
fi

echo "[✓] Gitea is online: $(curl -s "http://127.0.0.1:${GITEA_HTTP_PORT}/api/v1/version" | jq -r .version 2>/dev/null || echo "ready")"

# ── Provision Admin User 'george' ──────────────────────────────
ADMIN_PASSWORD=""
if [ -f "$GITEA_CONF" ]; then
    ADMIN_PASSWORD=$(grep '^GITEA_PASSWORD=' "$GITEA_CONF" 2>/dev/null | cut -d= -f2- | tr -d '"')
fi
if [ -z "$ADMIN_PASSWORD" ]; then
    ADMIN_PASSWORD="George_Lodge_$(date +%s)_${RANDOM}"
fi

# Create admin user if not exists
if ! docker exec -u git "${CONTAINER_NAME}" gitea admin user list 2>/dev/null | grep -q "^[0-9]\+[[:space:]]\+${GITEA_USER}[[:space:]]"; then
    echo "[+] Creating admin user '${GITEA_USER}' in Gitea..."
    docker exec -u git "${CONTAINER_NAME}" gitea admin user create \
        --admin \
        --username "${GITEA_USER}" \
        --password "${ADMIN_PASSWORD}" \
        --email "george@blue-lodge.local" \
        --must-change-password=false >/dev/null 2>&1 || true
fi

# Generate API token for George
echo "[+] Minting Gitea administrative API token for George..."
TOKEN=""
TOKEN=$(docker exec -u git "${CONTAINER_NAME}" gitea admin user generate-access-token \
    --username "${GITEA_USER}" \
    --token-name "george-lodge-token-$(date +%s)" \
    --raw 2>/dev/null || true)

# If token generation via CLI succeeded, save to gitea.conf
if [ -n "$TOKEN" ]; then
    cat > "$GITEA_CONF" << EOF
# Sovereign Gitea Configuration for George
GITEA_URL="http://127.0.0.1:${GITEA_HTTP_PORT}"
GITEA_SSH_URL="ssh://git@127.0.0.1:${GITEA_SSH_PORT}"
GITEA_USER="${GITEA_USER}"
GITEA_PASSWORD="${ADMIN_PASSWORD}"
GITEA_TOKEN="${TOKEN}"
GITEA_REPO="${GITEA_REPO}"
EOF
    chmod 600 "$GITEA_CONF"
    echo "[✓] Saved credentials to ${GITEA_CONF}"
elif [ -f "$GITEA_CONF" ]; then
    TOKEN=$(grep '^GITEA_TOKEN=' "$GITEA_CONF" 2>/dev/null | cut -d= -f2- | tr -d '"')
fi

# ── Register SSH Key in Gitea ──────────────────────────────────
SSH_PUB="$GEORGE_DIR/.ssh/id_ed25519.pub"
if [ -f "$SSH_PUB" ] && [ -n "$TOKEN" ]; then
    echo "[+] Registering George's SSH key with Gitea..."
    KEY_VAL=$(cat "$SSH_PUB")
    curl -s -X POST "http://127.0.0.1:${GITEA_HTTP_PORT}/api/v1/user/keys" \
        -H "Authorization: token ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"title\":\"george-sovereign-key\",\"key\":\"${KEY_VAL}\",\"read_only\":false}" >/dev/null 2>&1 || true
fi

# ── Register GPG Key in Gitea ──────────────────────────────────
GPG_PUB="$GEORGE_DIR/george_public.asc"
if [ -f "$GPG_PUB" ] && [ -n "$TOKEN" ]; then
    echo "[+] Registering George's GPG public key with Gitea for verified commits..."
    GPG_VAL=$(awk '{printf "%s\\n", $0}' "$GPG_PUB")
    curl -s -X POST "http://127.0.0.1:${GITEA_HTTP_PORT}/api/v1/user/gpg_keys" \
        -H "Authorization: token ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"armored_public_key\":\"${GPG_VAL}\"}" >/dev/null 2>&1 || true
fi

# ── Configure SSH Host Alias for Gitea ─────────────────────────
SSH_CONFIG="$GEORGE_DIR/.ssh/config"
if [ -f "$SSH_CONFIG" ]; then
    if ! grep -q "Host gitea.local" "$SSH_CONFIG"; then
        cat >> "$SSH_CONFIG" << EOF

# Sovereign Gitea instance
Host gitea.local
    HostName 127.0.0.1
    Port ${GITEA_SSH_PORT}
    User git
    IdentityFile $GEORGE_DIR/.ssh/id_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
EOF
        chmod 600 "$SSH_CONFIG"
        echo "[✓] Configured SSH alias 'gitea.local' in ${SSH_CONFIG}"
    fi
fi

# ── Create Repository 'george/blue-lodge' on Gitea ─────────────
if [ -n "$TOKEN" ]; then
    echo "[+] Ensuring repository '${GITEA_USER}/${GITEA_REPO}' exists on Gitea..."
    curl -s -X POST "http://127.0.0.1:${GITEA_HTTP_PORT}/api/v1/user/repos" \
        -H "Authorization: token ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${GITEA_REPO}\",\"description\":\"Blue Lodge Core Repository\",\"private\":false,\"auto_init\":false}" >/dev/null 2>&1 || true

    # Configure branch protection on 'main' via Gitea API
    echo "[+] Setting Gitea branch protection on 'main' (requires PR, forbids direct push)..."
    curl -s -X POST "http://127.0.0.1:${GITEA_HTTP_PORT}/api/v1/repos/${GITEA_USER}/${GITEA_REPO}/branch_protections" \
        -H "Authorization: token ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{
            "branch_name": "main",
            "enable_push": false,
            "enable_push_whitelist": false,
            "require_pull_request": true
        }' >/dev/null 2>&1 || true
fi

# ── Configure Local Git Remote 'gitea' ─────────────────────────
if git -C "$LODGE_ROOT" rev-parse --is-inside-work-tree &>/dev/null; then
    GITEA_REMOTE_URL="http://${GITEA_USER}:${TOKEN}@127.0.0.1:${GITEA_HTTP_PORT}/${GITEA_USER}/${GITEA_REPO}.git"
    if git -C "$LODGE_ROOT" remote get-url gitea &>/dev/null; then
        git -C "$LODGE_ROOT" remote set-url gitea "$GITEA_REMOTE_URL" 2>/dev/null || true
    else
        git -C "$LODGE_ROOT" remote add gitea "$GITEA_REMOTE_URL" 2>/dev/null || true
    fi
    echo "[✓] Git remote 'gitea' configured: http://127.0.0.1:${GITEA_HTTP_PORT}/${GITEA_USER}/${GITEA_REPO}.git"
fi

echo "══════════════════════════════════════════════════════"
echo "  Sovereign Gitea Ready!"
echo "  Web UI:    http://127.0.0.1:${GITEA_HTTP_PORT}/"
echo "  Username:  ${GITEA_USER}"
echo "  API Token: ${TOKEN:0:8}..."
echo "  Remote:    gitea (${GITEA_USER}/${GITEA_REPO})"
echo "══════════════════════════════════════════════════════"
