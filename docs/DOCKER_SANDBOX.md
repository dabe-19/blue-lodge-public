# George Docker Sandbox Setup and Operation Guide

The George Docker Sandbox (`george-cuda-sandbox`) provides an isolated, GPU-accelerated environment to execute and test the George agent (`lodge`) without impacting the host workstation's files or system configuration. 

This guide details how to build, run, configure, and maintain the sandbox across different GPU architectures, how to manage models, and how to operate George inside it.

---

## Table of Contents
1. [Architecture Overview](#architecture-overview)
2. [Prerequisites](#prerequisites)
3. [Building the Sandbox Image](#building-the-sandbox-image)
4. [Running the Sandbox Container](#running-the-sandbox-container)
5. [Operating George inside the Sandbox](#operating-george-inside-the-sandbox)
6. [Managing Models & Adding More Powerful Models](#managing-models--adding-more-powerful-models)
7. [Hardware Profiles (NVIDIA, AMD, Intel, Apple Silicon)](#hardware-profiles-nvidia-amd-intel-apple-silicon)

---

## Architecture Overview

```
┌────────────────────────────────────────────────────────┐
│                   Host Workstation                     │
│  ┌──────────────────────────────────────────────────┐  │
│  │               George Sandbox Container           │  │
│  │                                                  │  │
│  │   /workspace/lodge                               │  │
│  │   (George CLI Client / REPL)                     │  │
│  │        │                                         │  │
│  │        ▼ (API Call on localhost:11434)           │  │
│  │   Ollama Server Daemon                           │  │
│  │        │                                         │  │
│  │        ▼ (Direct GPU Acceleration)               │  │
│  │   llama-server / libggml-cuda                    │  │
│  └────────┼─────────────────────────────────────────┘  │
│           │                                            │
│           ▼ (Bridged GPU Access via Docker Driver)     │
│      Physical GPU (RTX 3060, etc.)                     │
└────────────────────────────────────────────────────────┘
```

---

## Prerequisites
To run the GPU-accelerated container, your host workstation must have:
*   **Docker Engine** (or Docker Desktop) installed.
*   **GPU Drivers** installed on the host system.
*   **GPU Container Runtime Bridge** (e.g., [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) for NVIDIA cards) configured in Docker.

---

## Building the Sandbox Image

The sandbox builds a native compilation of `llama.cpp` (`llama-server`) with GPU support.

### The Build Command
From the root of the `blue-lodge` repository, run:
```bash
# Build the NVIDIA CUDA enabled sandbox image
docker build \
  --build-arg USER_ID="$(id -u)" \
  --build-arg GROUP_ID="$(id -g)" \
  -f Dockerfile.cuda-sandbox \
  -t george-cuda-sandbox .
```

> [!NOTE]
> **Linker Stub Symlink Resolution:** During image creation, Docker does not bridge physical GPU devices. As a result, the linker fails to resolve transitive dynamic dependencies (like `libcuda.so.1`) needed by `libggml-cuda.so`. 
> 
> The Dockerfile resolves this by setting `ENV LIBRARY_PATH=/usr/local/cuda/lib64/stubs`, symlinking `libcuda.so.1` to the unversioned stub `libcuda.so`, and passing the `-Wl,-rpath-link,/usr/local/cuda/lib64/stubs` flag to CMake. At runtime, the real host GPU driver overrides this stub.

---

## Running the Sandbox Container

To run the container persistently in the background (as a daemon) with GPU bridge access, active project directories mounted, and configuration files linked:

### 1. Launch the Container
```bash
# Start container with CUDA bridging, workspace mount, and local configuration mount
docker run -d -t --name george-sandbox \
    --gpus all \
    -v ta_notebookrag_ollama_data:/home/george/.ollama \
    -v "$PWD:/workspace" \
    -v "$HOME/.george:/home/george/.george" \
    -p 8080:8080 \
    -e LLAMA_CPP_GPU_LAYERS=99 \
    george-cuda-sandbox tail -f /dev/null
```
*   `--gpus all`: Bridged access to all host NVIDIA GPUs.
*   `-v ta_notebookrag_ollama_data:/home/george/.ollama`: Mounts the persistent Ollama model blobs storage volume.
*   `-v "$PWD:/workspace"`: Mounts the current repository code directly inside `/workspace`.
*   `tail -f /dev/null`: Keeps the container alive persistently in the background.

### 2. Start the Ollama Service
Once the container is running, start the Ollama background daemon under the standard `george` user:
```bash
# Start Ollama serve in the background inside the container
docker exec -d -u george george-sandbox ollama serve
```

---

## Operating George inside the Sandbox

### 1. Configure Backend Preferences
To ensure George uses the local Ollama service instead of attempting to start local `llama-server` instances, ensure the following is set in your configuration file:

In [lodge.conf](file:///home/wsl-ops/blue-lodge/.george/lodge.conf):
```ini
LLM_BACKEND=ollama
```

### 2. Run George Interactively (REPL)
To drop into the interactive George shell (`lodge`) inside the container:
```bash
# Execute interactive bash session inside the sandbox
docker exec -it -u george george-sandbox env LODGE_DIR=/workspace /workspace/lodge
```

### 3. Run One-Shot Tasks in the Background
To trigger George on a background task and redirect all console outputs to a log file on the host:
```bash
# Execute one-shot task and write output to george.log
docker exec george-sandbox env LODGE_DIR=/workspace LLM_BACKEND=ollama /workspace/lodge "your task prompt here" > george.log 2>&1 &
```
You can stream and watch George working on the host terminal in real time:
```bash
# Stream the active run log
tail -f george.log
```

---

## Managing Models & Adding More Powerful Models

### How GGUF Model Resolution Works
George resolves GGUF files by matching custom registry keys defined in [lib/models.sh](file:///home/wsl-ops/blue-lodge/lib/models.sh) to downloaded Ollama manifest blobs.

### 1. Downloading/Pulling a Model
To pull a model (for example, the Qwen 2.5 Coding model or a larger Gemma 4 checkpoint) inside the container:
```bash
# Pull model directly using Ollama CLI in the sandbox
docker exec george-sandbox ollama pull qwen2.5-coder:7b
```

### 2. Mapping the Model in George
If the model you pulled does not match the default names expected by the codebase, you can map them using symlinks inside the Ollama manifests folder inside the container:
```bash
# Map custom model key name to downloaded registry model
docker exec -u root george-sandbox bash -c "mkdir -p /home/george/.ollama/models/manifests/registry.ollama.ai/library/blue-lodge-gemma4-inst && ln -sf /home/george/.ollama/models/manifests/registry.ollama.ai/library/gemma4/e2b /home/george/.ollama/models/manifests/registry.ollama.ai/library/blue-lodge-gemma4-inst/4b && chown -R george:george /home/george/.ollama"
```

---

## Hardware Profiles

### NVIDIA (CUDA)
*   **Base Image:** `nvidia/cuda:12.4.1-devel-ubuntu22.04`
*   **Compile Flag:** `-DGGML_CUDA=ON`
*   **Runtime Flag:** `--gpus all`
*   **Description:** Leverages CUDA cores and tensor cores for maximum throughput.

### AMD (Vulkan / ROCm)
*   **Base Image:** `ubuntu:22.04` (for Vulkan) or `rocm/dev-ubuntu-22.04` (for ROCm)
*   **Compile Flag:** `-DGGML_VULKAN=ON` (Mesa/Vulkan) or `-DGGML_HIPBLAS=ON` (ROCm)
*   **Runtime Flag:** `--device /dev/kfd --device /dev/dri`
*   **Description:** Vulkan is the preferred backend for consumer Radeon GPUs (Navi 10, Polaris, etc.) as it bypasses ROCm compatibility limitations. ROCm is preferred for enterprise Instinct cards.

### Intel (SYCL)
*   **Base Image:** `intel/oneapi-basekit`
*   **Compile Flag:** `-DGGML_SYCL=ON`
*   **Runtime Flag:** `--device /dev/dri`
*   **Description:** Uses Intel oneAPI SDK to target Intel Arc or Data Center Max/Flex GPUs.

### Apple Silicon (Metal)
*   **Docker Limitation:** Docker Desktop on macOS runs inside a Linux virtual machine and **cannot access the host's Apple Silicon Metal GPU API**. Building the sandbox in Docker on macOS will result in CPU-only inference.
*   **Native Run:** For GPU-accelerated development on Apple Silicon, bypass Docker and run the code natively on the host system using the metal framework. See [IOS_MACOS_SETUP.md](file:///home/wsl-ops/blue-lodge/docs/IOS_MACOS_SETUP.md) for native instructions.
