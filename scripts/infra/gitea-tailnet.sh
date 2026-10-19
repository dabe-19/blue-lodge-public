#!/usr/bin/env bash
# Exposes the local Gitea forge on this node's tailnet address only (never LAN).
# Docker keeps binding 127.0.0.1; tailscaled forwards raw TCP from the tailnet
# IP, so the client's Host header reaches Gitea (PUBLIC_URL_DETECTION=auto).
# Needs `tailscale set --operator=$USER` once. Config persists in tailscaled.
#   gitea-tailnet.sh [on|off|status]
set -euo pipefail

HTTP_PORT="${GITEA_HTTP_PORT:-3088}"
SSH_PORT="${GITEA_SSH_PORT:-2222}"

command -v tailscale >/dev/null 2>&1 || { echo "tailscale not installed" >&2; exit 1; }

case "${1:-on}" in
    on)
        tailscale serve --bg --tcp "$HTTP_PORT" "tcp://127.0.0.1:${HTTP_PORT}"
        tailscale serve --bg --tcp "$SSH_PORT" "tcp://127.0.0.1:${SSH_PORT}"
        name=$(tailscale status --self --json 2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//')
        echo "Gitea on tailnet: http://${name:-$(tailscale ip -4)}:${HTTP_PORT}/"
        echo "SSH clone:        ssh://git@${name:-$(tailscale ip -4)}:${SSH_PORT}/<owner>/<repo>.git"
        ;;
    off)
        tailscale serve --tcp "$HTTP_PORT" off || true
        tailscale serve --tcp "$SSH_PORT" off || true
        ;;
    status) tailscale serve status ;;
    *) echo "usage: $0 [on|off|status]" >&2; exit 2 ;;
esac
