# Debian & Chrome OS (Crostini) Setup Guide

This guide covers the necessary steps to get George running on standard Debian-based Linux environments, including Chrome OS Linux containers (Crostini). Because these environments often start as minimal installations and handle system services differently than Termux or macOS, additional dependencies and symlinks are required.

## 1. Install Core Dependencies & Build Tools

Standard Debian environments lack the required tools for downloading archives, managing system paths, compiling C++ projects using Ninja, and unpacking modern compression formats like Zstandard.

Run the following command to install the required environment packages:

```bash
sudo apt update
sudo apt install -y curl jq git sqlite3 build-essential cmake python3 python3-venv vulkan-tools libvulkan-dev ninja-build clang glslc zstd
```

### Command & Package Breakdown

* **`apt`**: The Advanced Package Tool used in Debian to handle the installation, removal, and management of software packages.
  * `update`: Refreshes the local cache of available packages from the remote repositories.
  * `install`: Instructs the package manager to download and install the specified packages.
  * `-y`: The "yes" flag. Automatically answers "yes" to any confirmation prompts to allow unattended installation.

* **`curl`**: A command-line tool capable of transferring data over various network protocols (used here to download Ollama and model weights).
* **`jq`**: A lightweight, flexible command-line JSON processor used by George's backend scripts for parsing API responses.
* **`git`**: A distributed version control system capable of tracking changes in source code. Used to clone repositories.
* **`sqlite3`**: A terminal-based front-end to the SQLite library capable of managing local databases (used for George's memory and recall features).
* **`build-essential`**: A meta-package that installs the GNU C/C++ compilers (gcc/g++) and essential build utilities (like `make`).
* **`cmake`**: A cross-platform tool capable of generating native build environments (like Makefiles or Ninja build files) from configuration scripts.
* **`python3` & `python3-venv`**: The Python 3 interpreter and its module capable of creating isolated virtual environments to prevent dependency conflicts.
* **`vulkan-tools` & `libvulkan-dev`**: Diagnostic utilities (like `vulkaninfo`) and development headers required to compile software with Vulkan GPU acceleration.
* **`ninja-build`**: A small, highly optimized build system designed to compile code significantly faster than traditional Makefiles.
* **`clang`**: A C language family frontend for LLVM, serving as a modern, fast alternative to the GNU compiler.
* **`glslc`**: The Google shader compiler, capable of compiling Vulkan compute shaders into the required SPIR-V format.
* **`zstd`**: A real-time data compression utility capable of high compression ratios. Required to unpack the official Ollama installation binaries.

---

## 2. Configure Ollama System Symlinks

When Ollama is installed via its official Linux script (`curl -fsSL https://ollama.com/install.sh | sh`), it installs as a system service under the `ollama` user. The model weights are saved to `/usr/share/ollama/.ollama/models` rather than your local home directory.

To allow George and `llama-server` to find and read these models, you must create a symlink (shortcut) in your home directory and adjust the read permissions.

Run the following commands:

```bash
mkdir -p ~/.ollama
sudo ln -s /usr/share/ollama/.ollama/models ~/.ollama/models
sudo chmod -R a+rX /usr/share/ollama/.ollama/models
```

### Command & Flag Breakdown

* **`mkdir`**: A utility capable of creating new directories.
  * `-p`: The "parents" flag. It creates any necessary parent directories in the requested path and suppresses error messages if the directory already exists.

* **`ln`**: A utility capable of creating hard links or symbolic links between files and directories.
  * `-s`: The "symbolic" flag. It creates a soft shortcut pointing to the target path rather than a hard file link.

* **`chmod`**: A utility capable of changing access permissions for files and directories.
  * `-R`: The "recursive" flag. It applies the permission changes to the target directory and all files/folders nested within it.
  * `a+rX`: The permission modifier. `a` targets "all" users (owner, group, and others). `+` adds the permissions. `r` grants "read" access. `X` (capital) grants "execute" access conditionally, meaning it only makes directories traversable without making standard files executable.

---

## 3. Compile llama.cpp (Standard CPU Build)

For most standard laptops and Chromebooks, running inference on the CPU is the most stable path. Modern Intel/AMD processors will utilize AVX2 instructions to run George's models efficiently.

Run the following commands to compile `llama.cpp` for CPU:

```bash
git clone https://github.com/ggml-org/llama.cpp.git ~/llama.cpp
cd ~/llama.cpp
cmake -B build -DCMAKE_BUILD_TYPE=Release -G Ninja
cmake --build build --config Release -j$(nproc)
```

### Command & Flag Breakdown

* **`cmake` Flags:**
  * `-B <dir>`: The build directory flag. Tells CMake where to place all the generated build configuration files (in this case, the `build` folder).
  * `-D<var>=<value>`: The define flag. It sets a specific CMake variable.
    * `CMAKE_BUILD_TYPE=Release`: Instructs the compiler to apply aggressive performance optimizations and strip debugging symbols to maximize runtime speed.
  * `-G <generator>`: The generator flag. Specifies which build system to target (here, telling it to use `Ninja`).
  * `--build <dir>`: Instructs CMake to execute the actual compilation process using the files generated in the specified directory.
  * `--config <type>`: Ensures the build toolchain uses the specified configuration (`Release`).
  * `-j<jobs>`: The jobs flag. Dictates the number of concurrent parallel threads to use during compilation. The `$(nproc)` command is evaluated first to automatically inject your host system's total CPU core count, maximizing compile speed.

---

## 4. Compile llama.cpp (Experimental Vulkan GPU Build)

> **Note:** Hardware GPU passthrough inside Chrome OS Linux containers (Crostini) is highly experimental and often fails. Attempt this build only if you are running a native Linux desktop or have explicitly configured Crostini for Vulkan passthrough.

To compile with Vulkan support for integrated graphics or discrete GPUs:

```bash
cd ~/llama.cpp
rm -rf build
cmake -B build -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release -G Ninja
cmake --build build --config Release -j$(nproc)
```

### Command & Flag Breakdown

* **`rm -rf build`**: Removes the old build directory to ensure a clean slate. `-r` is "recursive" (deletes the folder and contents), and `-f` is "force" (suppresses confirmation prompts).
* **`-DGGML_VULKAN=ON`**: A CMake define flag that explicitly instructs the build system to include the Vulkan GPU acceleration backend during compilation.

---

## 5. Install & Configure George

Once Ollama is running and llama.cpp is compiled, install George:

```bash
git clone https://github.com/djmccabe/blue-lodge.git ~/blue-lodge
cd ~/blue-lodge
bash install.sh
```

The installer will:
- Detect your platform (Debian/Chrome OS)
- Locate Ollama and `llama-server` automatically (checks `~/llama.cpp/build/bin/` and common system paths)
- Pull default model weights via Ollama
- Configure `~/.lodgerc` with your backend settings

### Post-Install Verification

```bash
source ~/.bashrc    # or restart your terminal
lodge               # Start George
/vitals             # Check system status — confirms backend, model, and memory
```

---

## Hardware Notes: Chrome OS (Crostini)

| Component | Details |
|---|---|
| **CPU** | Intel Core i5-6300HQ @ 2.30 GHz (Skylake, 4C/4T) |
| **RAM** | 16 GB DDR3 (shared with Chrome OS host) |
| **GPU** | Intel HD Graphics 530 (Vulkan passthrough unreliable in Crostini) |
| **Backend** | CPU inference recommended (`llama-server` or Ollama) |
| **Models** | 4B-class models (Gemma 4 E4B, Qwen 3.5 4B, Nemotron 3 Nano 4B) run well at ~3-5 tok/s |

### Crostini-Specific Gotchas

- **Memory pressure**: Chrome OS reserves RAM for the host. If George's model loads are slow or Ollama OOMs, close Chrome tabs to free memory for the Linux container.
- **No GPU acceleration**: The Crostini VM does not reliably pass through Vulkan to the guest. Stick with CPU builds.
- **Ollama service**: Crostini uses systemd. Ollama runs as `ollama.service` — use `sudo systemctl status ollama` to verify.
- **Sleep/suspend**: Closing the Chromebook lid suspends the VM. Ollama and `llama-server` will need a moment to recover after waking. George handles reconnection automatically.
