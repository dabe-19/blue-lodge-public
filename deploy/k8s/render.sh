#!/usr/bin/env bash
# deploy/k8s/render.sh — Zero-dependency K8s hostPath renderer for multi-node Blue Lodge deployments.
# Renders tracked deploy/k8s/*.yaml templates into gitignored deploy/k8s/.rendered/ with each node's
# local LODGE_HOST_HOME and MODELS_DIR so ecotype/* branches never need to fork tracked K8s YAML files.
#
# Usage:
#   LODGE_HOST_HOME=/home/operator MODELS_DIR=/home/operator/models bash deploy/k8s/render.sh
#   kubectl apply -f deploy/k8s/.rendered/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:-$SCRIPT_DIR/.rendered}"
HOST_HOME="${LODGE_HOST_HOME:-$HOME}"
MODELS="${MODELS_DIR:-$HOST_HOME/models}"
REPO_PATH="${LODGE_HOST_REPO:-$HOST_HOME/projects/blue-lodge}"

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/*.yaml

for f in "$SCRIPT_DIR"/*.yaml; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    sed \
        -e "s|/home/user/projects/blue-lodge|${REPO_PATH}|g" \
        -e "s|/home/user/models|${MODELS}|g" \
        -e "s|/home/user|${HOST_HOME}|g" \
        "$f" > "$OUT_DIR/$base"
done

printf '[✓] Rendered %d Kubernetes manifest(s) into %s\n' "$(ls -1 "$OUT_DIR"/*.yaml 2>/dev/null | wc -l)" "$OUT_DIR"
printf '    LODGE_HOST_HOME=%s | MODELS_DIR=%s | LODGE_HOST_REPO=%s\n' "$HOST_HOME" "$MODELS" "$REPO_PATH"
