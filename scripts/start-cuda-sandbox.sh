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

# Check for nvidia-container-toolkit (optional warning)
if ! docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi &>/dev/null; then
    echo "[!] Warning: NVIDIA Container Toolkit is not responding on '--gpus all'." >&2
    echo "    Confirm your driver and docker integration are configured." >&2
    echo "    We will attempt to start the container anyway." >&2
fi

echo "[+] Building Docker image george-cuda-sandbox..."
docker build \
    --build-arg USER_ID="$(id -u)" \
    --build-arg GROUP_ID="$(id -g)" \
    -f Dockerfile.cuda-sandbox \
    -t george-cuda-sandbox .

echo "[+] Starting CUDA-enabled George Sandbox container..."
echo "    Workspace mounted to /workspace"
echo "    Host GPU RTX 3060 bridged to container"

# Create host directory if it doesn't exist
mkdir -p "$HOME/.george" 2>/dev/null

docker run -it --rm \
    --gpus all \
    -v "$LODGE_ROOT:/workspace" \
    -v "$HOME/.george:/home/george/.george" \
    -p 8080:8080 \
    -e LLAMA_CPP_GPU_LAYERS=99 \
    george-cuda-sandbox bash
