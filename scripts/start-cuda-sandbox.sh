#!/usr/bin/env bash
#
# start-cuda-sandbox.sh: Build and run the CUDA-enabled Docker sandbox
#

set -eo pipefail

# Ensure we are in the repository root directory
LODGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$LODGE_ROOT"

# Check for docker
if ! command -v docker &>/dev/null; then
    echo "[-] Error: docker is not installed. Please install Docker first." >&2
    exit 1
fi

# Default backend auto-detection
BACKEND="cuda"
BASE_IMAGE="nvidia/cuda:12.4.1-devel-ubuntu22.04"
DOCKER_RUN_FLAGS=""
GPU_LAYERS=99
FORCE_BUILD=0
CONTAINER_NAME="george-sandbox"

# Parse command line flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cuda)
            BACKEND="cuda"
            shift
            ;;
        --vulkan)
            BACKEND="vulkan"
            shift
            ;;
        --rocm)
            BACKEND="rocm"
            shift
            ;;
        --cpu)
            BACKEND="cpu"
            shift
            ;;
        --build|-b)
            FORCE_BUILD=1
            shift
            ;;
        *)
            echo "[-] Error: Unknown option: $1" >&2
            echo "Usage: $0 [--cuda|--vulkan|--rocm|--cpu] [--build|-b]" >&2
            exit 1
            ;;
    esac
done

# If backend is cuda (or default), verify NVIDIA Container Toolkit is functional
if [ "$BACKEND" = "cuda" ]; then
    if ! docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi &>/dev/null; then
        echo "[!] Warning: NVIDIA Container Toolkit is not responding on '--gpus all'." >&2
        echo "    Looking for Vulkan direct rendering nodes (/dev/dri) as fallback..." >&2
        if [ -e "/dev/dri" ]; then
            BACKEND="vulkan"
            echo "[+] Vulkan device nodes found. Falling back to Vulkan backend." >&2
        else
            BACKEND="cpu"
            echo "[+] No GPU acceleration options available. Falling back to CPU backend." >&2
        fi
    fi
fi

# Set backend-specific variables
if [ "$BACKEND" = "cuda" ]; then
    BASE_IMAGE="nvidia/cuda:12.4.1-devel-ubuntu22.04"
    DOCKER_RUN_FLAGS="--gpus all"
    GPU_LAYERS=99
elif [ "$BACKEND" = "vulkan" ]; then
    BASE_IMAGE="ubuntu:22.04"
    DOCKER_RUN_FLAGS="--device /dev/dri"
    GPU_LAYERS=99
elif [ "$BACKEND" = "rocm" ]; then
    BASE_IMAGE="rocm/dev-ubuntu-22.04"
    DOCKER_RUN_FLAGS="--device /dev/kfd --device /dev/dri"
    GPU_LAYERS=99
else
    # cpu
    BASE_IMAGE="ubuntu:22.04"
    DOCKER_RUN_FLAGS=""
    GPU_LAYERS=0
fi

# Check if container already exists
CONTAINER_EXISTS=0
CONTAINER_RUNNING=0
if docker ps -a --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}$"; then
    CONTAINER_EXISTS=1
    if docker ps --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}$"; then
        CONTAINER_RUNNING=1
    fi
fi

if [ "$CONTAINER_EXISTS" -eq 1 ] && [ "$FORCE_BUILD" -eq 0 ]; then
    if [ "$CONTAINER_RUNNING" -eq 1 ]; then
        echo "[+] Container '${CONTAINER_NAME}' is already running. Attaching shell..."
        docker exec -it "$CONTAINER_NAME" bash
    else
        echo "[+] Starting existing container '${CONTAINER_NAME}'..."
        docker start "$CONTAINER_NAME"
        docker exec -it "$CONTAINER_NAME" bash
    fi
    exit 0
fi

# Remove existing container if it exists so we can recreate it
if [ "$CONTAINER_EXISTS" -eq 1 ]; then
    echo "[+] Removing existing container '${CONTAINER_NAME}' for recreate..."
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

echo "[+] Building Docker image george-cuda-sandbox (Backend: $BACKEND)..."
docker build \
    --build-arg USER_ID="$(id -u)" \
    --build-arg GROUP_ID="$(id -g)" \
    --build-arg BASE_IMAGE="$BASE_IMAGE" \
    --build-arg BACKEND="$BACKEND" \
    -f Dockerfile.cuda-sandbox \
    -t george-cuda-sandbox .

echo "[+] Starting George Sandbox container (Backend: $BACKEND)..."
echo "    Workspace mounted to /workspace"
if [ "$BACKEND" = "cuda" ]; then
    echo "    Host GPU bridged to container via --gpus all"
elif [ "$BACKEND" = "vulkan" ]; then
    echo "    Host GPU bridged to container via --device /dev/dri"
elif [ "$BACKEND" = "rocm" ]; then
    echo "    Host AMD GPU bridged to container via --device /dev/kfd --device /dev/dri"
else
    echo "    Running in CPU-only mode"
fi

# Create host directory if it doesn't exist
mkdir -p "$HOME/.george" 2>/dev/null

docker run -it \
    --name "$CONTAINER_NAME" \
    $DOCKER_RUN_FLAGS \
    -v "$LODGE_ROOT:/workspace" \
    -v "$HOME/.george:/home/george/.george" \
    -p 8080:8080 \
    -e LLAMA_CPP_GPU_LAYERS=$GPU_LAYERS \
    george-cuda-sandbox bash
