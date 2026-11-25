#!/usr/bin/env bash
# ── scripts/infra/k8s_deploy.sh: Sovereign Kubernetes (k3s / Rancher) Manager ──
# Builds container images directly into k3s containerd (namespace k8s.io) via an
# in-cluster BuildKit builder pod (zero host Docker or sudo required) and manages
# the blue-lodge Kubernetes deployment.
#
# Usage:
#   ./scripts/infra/k8s_deploy.sh up                 # Render & apply all deploy/k8s manifests
#   ./scripts/infra/k8s_deploy.sh render             # Render node-local manifests into deploy/k8s/.rendered/
#   ./scripts/infra/k8s_deploy.sh build [all|web|inference]  # Build images into k3s
#   ./scripts/infra/k8s_deploy.sh status             # Show pods, services, ingresses & GPU
#   ./scripts/infra/k8s_deploy.sh restart [service]  # Rollout restart workload(s)
#   ./scripts/infra/k8s_deploy.sh down               # Scale down workloads

set -euo pipefail

LODGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
K8S_NS="${K8S_NAMESPACE:-blue-lodge}"
CUDA_ARCH="${CUDA_ARCHITECTURES:-86;120}"
K8S_MANIFEST_DIR="$LODGE_DIR/deploy/k8s/.rendered"

_info() { printf "\033[1;36m[k8s]\033[0m %s\n" "$1"; }
_ok()   { printf "\033[1;32m[✓]\033[0m %s\n" "$1"; }
_warn() { printf "\033[1;33m[!]\033[0m %s\n" "$1"; }
_err()  { printf "\033[1;31m[✗]\033[0m %s\n" "$1" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || _err "kubectl not found on PATH"

_render_manifests() {
    local lcfg="$LODGE_DIR/.george/configs/lodge.conf"
    [ ! -f "$lcfg" ] && [ -f "$LODGE_DIR/.george/lodge.conf" ] && lcfg="$LODGE_DIR/.george/lodge.conf"

    local host_home="${LODGE_HOST_HOME:-}"
    local models_dir="${MODELS_DIR:-}"
    local host_repo="${LODGE_HOST_REPO:-$LODGE_DIR}"

    if [ -f "$lcfg" ]; then
        [ -z "$host_home" ] && host_home=$(grep -m1 '^[[:space:]]*LODGE_HOST_HOME=' "$lcfg" 2>/dev/null | cut -d= -f2- | tr -d "\"'[:space:]" || true)
        [ -z "$models_dir" ] && models_dir=$(grep -m1 '^[[:space:]]*MODELS_DIR=' "$lcfg" 2>/dev/null | cut -d= -f2- | tr -d "\"'[:space:]" || true)
    fi
    [ -z "$host_home" ] && host_home="${HOME}"
    [ -z "$models_dir" ] && models_dir="${host_home}/models"

    if [ -x "$LODGE_DIR/deploy/k8s/render.sh" ] || [ -f "$LODGE_DIR/deploy/k8s/render.sh" ]; then
        LODGE_HOST_HOME="$host_home" \
        MODELS_DIR="$models_dir" \
        LODGE_HOST_REPO="$host_repo" \
            bash "$LODGE_DIR/deploy/k8s/render.sh" "$K8S_MANIFEST_DIR" >/dev/null
    else
        K8S_MANIFEST_DIR="$LODGE_DIR/deploy/k8s"
    fi
}

_ensure_namespace() {
    _render_manifests
    kubectl apply -f "$K8S_MANIFEST_DIR/00-namespace-rbac.yaml" >/dev/null
    kubectl apply -f "$K8S_MANIFEST_DIR/01-storage-config.yaml" >/dev/null
}

_ensure_builder_pod() {
    _ensure_namespace
    if ! kubectl -n "$K8S_NS" get pod george-image-builder -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Running"; then
        _info "Starting in-cluster BuildKit builder pod (george-image-builder)..."
        kubectl -n "$K8S_NS" delete pod george-image-builder --ignore-not-found >/dev/null 2>&1 || true
        cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: george-image-builder
  namespace: ${K8S_NS}
  labels:
    app: george-image-builder
spec:
  restartPolicy: Never
  containers:
    - name: buildkit
      image: moby/buildkit:latest
      securityContext:
        privileged: true
      volumeMounts:
        - name: workspace
          mountPath: /workspace
        - name: containerd-sock
          mountPath: /run/k3s/containerd/containerd.sock
        - name: k3s-data
          mountPath: /var/lib/rancher/k3s/data
          readOnly: true
  volumes:
    - name: workspace
      hostPath:
        path: ${LODGE_DIR}
        type: Directory
    - name: containerd-sock
      hostPath:
        path: /run/k3s/containerd/containerd.sock
        type: Socket
    - name: k3s-data
      hostPath:
        path: /var/lib/rancher/k3s/data
        type: Directory
EOF
        kubectl -n "$K8S_NS" wait --for=condition=Ready pod/george-image-builder --timeout=180s
    fi
}

_build_into_k3s() {
    local image_tag="$1"
    local context_dir="$2"
    local dockerfile="$3"
    shift 3
    local extra_opt=("$@")

    _ensure_builder_pod
    _info "Building ${image_tag} (${dockerfile}) and importing into k3s containerd (k8s.io)..."
    kubectl -n "$K8S_NS" exec george-image-builder -- sh -e -c "
        CTR_BIN=\$(find /var/lib/rancher/k3s/data -name ctr | head -1)
        buildctl --addr unix:///run/buildkit/buildkitd.sock build \
            --frontend dockerfile.v0 \
            --local context='${context_dir}' \
            --local dockerfile='${dockerfile}' \
            ${extra_opt[*]:-} \
            --output type=oci,name=docker.io/library/${image_tag},dest=/tmp/image.tar
        \"\$CTR_BIN\" --address /run/k3s/containerd/containerd.sock -n k8s.io images import --base-name docker.io/library/${image_tag} /tmp/image.tar
        rm -f /tmp/image.tar
    "
    _ok "Built and imported ${image_tag} into k3s!"
}

cmd="${1:-status}"
case "$cmd" in
    build)
        target="${2:-all}"
        if [ "$target" = "web" ] || [ "$target" = "all" ]; then
            _build_into_k3s "george-web:latest" "/workspace/web" "/workspace/web"
        fi
        if [ "$target" = "inference" ] || [ "$target" = "all" ]; then
            _build_into_k3s "george-cuda-sandbox:latest" "/workspace" "/workspace" \
                "--opt" "filename=Dockerfile.cuda-sandbox" \
                "--opt" "build-arg:CUDA_ARCHITECTURES=86" \
                "--opt" "build-arg:BUILD_PRISM_FORK=0"
        fi
        ;;
    render)
        _render_manifests
        _ok "Rendered node-local manifests into ${K8S_MANIFEST_DIR}"
        ;;
    up|start|apply)
        _render_manifests
        _info "Applying rendered Blue Lodge Kubernetes manifests (${K8S_MANIFEST_DIR}) to namespace '${K8S_NS}'..."
        for f in "$K8S_MANIFEST_DIR"/[0-9]*.yaml; do
            kubectl apply -f "$f"
        done
        _ok "All manifests applied to namespace '${K8S_NS}'."
        kubectl -n "$K8S_NS" get pods,svc,ingress
        ;;
    restart)
        svc="${2:-all}"
        if [ "$svc" = "all" ]; then
            kubectl -n "$K8S_NS" rollout restart deploy/george-inference deploy/george-searxng deploy/george-mosquitto deploy/george-web
        elif [ "$svc" = "web" ] || [ "$svc" = "george-web" ]; then
            kubectl -n "$K8S_NS" rollout restart deploy/george-web
        else
            kubectl -n "$K8S_NS" rollout restart "deploy/${svc}"
        fi
        ;;
    down|stop)
        _info "Scaling down workloads in namespace '${K8S_NS}'..."
        kubectl -n "$K8S_NS" scale deploy/george-inference deploy/george-searxng deploy/george-mosquitto deploy/george-web --replicas=0 || true
        ;;
    status|ps)
        echo "=== Blue Lodge Kubernetes Workloads (${K8S_NS}) ==="
        kubectl -n "$K8S_NS" get pods,svc,ingress -o wide
        ;;
    *)
        echo "Usage: $0 [up|render|build [all|web|inference]|status|restart [service]|down]"
        exit 1
        ;;
esac
