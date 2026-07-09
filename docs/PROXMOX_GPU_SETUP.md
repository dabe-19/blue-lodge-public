# Proxmox GPU Passthrough — Remote Inference Node

End-to-end guide for setting up a Proxmox VM with PCI GPU passthrough
to serve as a George remote inference node. Covers IOMMU, VFIO, VM
creation, Vulkan/CUDA driver setup, Ollama + llama-server as systemd
services, network topology, and firewall configuration.

This guide was born from real-world debugging — every gotcha listed here
was hit in production and resolved.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Hardware Requirements](#hardware-requirements)
- [Part 1: Proxmox Host Configuration](#part-1-proxmox-host-configuration)
  - [Enable IOMMU](#1-enable-iommu)
  - [Load VFIO Modules](#2-load-vfio-modules)
  - [Blacklist Host GPU Driver](#3-blacklist-host-gpu-driver)
  - [Verify IOMMU Groups](#4-verify-iommu-groups)
- [Part 2: Create the GPU VM](#part-2-create-the-gpu-vm)
  - [VM Settings](#vm-settings)
  - [Pass Through the GPU](#pass-through-the-gpu)
- [Part 3: VM Network Setup](#part-3-vm-network-setup)
  - [Option A: Bridged (Same Subnet)](#option-a-bridged-same-subnet)
  - [Option B: NAT (Separate Subnet)](#option-b-nat-separate-subnet)
  - [Firewall Rules](#firewall-rules)
- [Part 4: GPU Software Stack (Inside the VM)](#part-4-gpu-software-stack-inside-the-vm)
  - [Vulkan Drivers (AMD)](#vulkan-drivers-amd)
  - [CUDA Drivers (NVIDIA)](#cuda-drivers-nvidia)
  - [Verify GPU Access](#verify-gpu-access)
- [Part 5: Inference Services](#part-5-inference-services)
  - [Ollama as a Service](#ollama-as-a-service)
  - [Build llama-server](#build-llama-server)
  - [llama-server as a Service](#llama-server-as-a-service)
  - [Loading Models](#loading-models)
- [Part 6: Connect George via SSH Tunnel](#part-6-connect-george-via-ssh-tunnel)
  - [Direct Topology](#direct-topology)
  - [Jump Host Topology](#jump-host-topology)
- [Troubleshooting](#troubleshooting)
- [Performance Reference](#performance-reference)

---

## Architecture Overview

```
┌──────────────────┐     SSH Tunnel      ┌─────────────────┐      ┌─────────────────────────┐
│  George Node     │ ─────────────────── │  Proxmox Host   │ ──── │  GPU VM                 │
│  Phone / Laptop  │   localhost ports   │  (jump host)    │ NAT  │  Debian 12              │
│  proot / WSL     │                     │  10.0.0.1       │      │  10.0.0.100             │
│                  │                     └─────────────────┘      │                         │
│  lib/remote.sh   │ ◄── HTTP ──────────────────────────────────► │  llama-server :8080     │
│  lib/llm.sh      │    127.0.0.1:8080                            │  Ollama :11434          │
│                  │                                              │  GPU: full passthrough   │
└──────────────────┘                                              └─────────────────────────┘
```

The phone/laptop never talks directly to the VM. Everything goes through
an SSH tunnel that forwards `localhost:PORT` through the Proxmox host to
the VM's services.

---

## Hardware Requirements

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| CPU | VT-d / AMD-Vi capable | Any modern Intel/AMD |
| RAM | 16GB (host + VM) | 32GB+ |
| GPU | Any discrete PCIe GPU | AMD RX 5700 XT (8GB) or NVIDIA with CUDA |
| Storage | 50GB for VM | 100GB+ (models are 4-8GB each) |

### Tested GPUs
- **AMD RX 5700 XT** (Navi 10, 8GB VRAM) — Vulkan via RADV, 60 tok/s on 8B Q4_K_M
- **AMD RX 580 / RX 570** (Polaris, 4-8GB) — Vulkan works, limited to 4B models on 4GB
- **NVIDIA GTX 1070/1080** — CUDA passthrough, slightly different driver setup
- Most GPUs with PCIe passthrough support will work

### Important: Older AMD GPUs and ROCm

AMD GPUs older than RDNA2 (gfx1030+) are **not supported by ROCm**.
This means Ollama cannot use the GPU (Ollama relies on ROCm for AMD).
However, **llama-server with Vulkan works on any GPU that Mesa supports**,
including Navi 10, Polaris, and older. This is why we run both services:

- **Ollama** = model manager (runs on CPU, that's fine)
- **llama-server** = GPU inference via Vulkan (runs on the GPU)

---

## Part 1: Proxmox Host Configuration

### 1. Enable IOMMU

Edit the kernel command line. On Proxmox (grub-based):

```bash
# Edit grub:
nano /etc/default/grub

# For Intel CPU:
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"

# For AMD CPU:
GRUB_CMDLINE_LINUX_DEFAULT="quiet amd_iommu=on iommu=pt"
```

Update grub and reboot:
```bash
update-grub
reboot
```

**For systemd-boot** (some Proxmox installs):
```bash
# Edit /etc/kernel/cmdline instead:
echo "root=ZFS=rpool/ROOT/pve-1 boot=zfs quiet intel_iommu=on iommu=pt" > /etc/kernel/cmdline
pve-efiboot-tool refresh
reboot
```

Verify after reboot:
```bash
dmesg | grep -e DMAR -e IOMMU
# Should see: "DMAR: IOMMU enabled" or "AMD-Vi: AMD IOMMUv2 loaded"
```

### 2. Load VFIO Modules

```bash
# Add VFIO modules
cat >> /etc/modules << 'EOF'
vfio
vfio_iommu_type1
vfio_pci
vfio_virqfd
EOF

# Apply
update-initramfs -u -k all
```

### 3. Blacklist Host GPU Driver

Prevent the Proxmox host from claiming the GPU:

```bash
# For AMD:
echo "blacklist amdgpu" >> /etc/modprobe.d/blacklist.conf
echo "blacklist radeon" >> /etc/modprobe.d/blacklist.conf

# For NVIDIA:
echo "blacklist nouveau" >> /etc/modprobe.d/blacklist.conf
echo "blacklist nvidia" >> /etc/modprobe.d/blacklist.conf
```

Optionally bind the GPU to VFIO at boot (use your GPU's PCI IDs):

```bash
# Find your GPU's vendor:device IDs:
lspci -nn | grep -i vga
# Example output: 01:00.0 VGA compatible controller [0300]: AMD ... [1002:731f]

# Also find the audio device in the same IOMMU group:
lspci -nn | grep -i "01:00"
# Example: 01:00.1 Audio device [0403]: AMD ... [1002:ab38]

# Bind both to VFIO:
echo "options vfio-pci ids=1002:731f,1002:ab38" > /etc/modprobe.d/vfio.conf
```

Reboot:
```bash
update-initramfs -u -k all
reboot
```

### 4. Verify IOMMU Groups

```bash
# List all IOMMU groups and their devices:
for d in /sys/kernel/iommu_groups/*/devices/*; do
    n=${d#*/iommu_groups/}; n=${n%%/*}
    printf "IOMMU Group %s: " "$n"
    lspci -nns "${d##*/}"
done | sort -t: -k1 -n
```

Find your GPU's IOMMU group. **All devices in the same group must be
passed through together** (GPU + HDMI audio is typical).

Verify the GPU is bound to VFIO:
```bash
lspci -nnk -s 01:00
# Should show: Kernel driver in use: vfio-pci
```

---

## Part 2: Create the GPU VM

### VM Settings

Create a new VM in Proxmox with these settings:

| Setting | Value | Why |
|---------|-------|-----|
| OS | Debian 12 (Bookworm) | Stable Vulkan/CUDA support |
| Machine | q35 | Required for PCIe passthrough |
| BIOS | OVMF (UEFI) | Required for GPU passthrough |
| CPU | host | Exposes real CPU features |
| RAM | 8-16GB | 8GB minimum for 8B models + OS |
| Disk | 60-100GB | Models are 4-8GB each |
| Network | virtio | Best performance |

### Pass Through the GPU

In the Proxmox web UI:
1. Go to **VM → Hardware → Add → PCI Device**
2. Select your GPU (e.g., `01:00.0`)
3. Check: **All Functions** (passes GPU + audio together)
4. Check: **PCI-Express** (passthrough mode)
5. Check: **Primary GPU** only if the VM has no other display
6. **ROM-Bar**: Check it (most GPUs need this)

Or via CLI:
```bash
# Edit VM config (replace VMID with your VM ID):
nano /etc/pve/qemu-server/<VMID>.conf

# Add:
hostpci0: 01:00,pcie=1,x-vga=1
```

**Note on `x-vga=1`**: Only set this if the GPU should be the VM's primary
display adapter. If you're running headless (SSH only), you can omit it
and keep the default VirtIO display for console access.

Start the VM and verify the GPU is visible inside:
```bash
lspci | grep -i vga
# Should show your passed-through GPU
```

---

## Part 3: VM Network Setup

### Option A: Bridged (Same Subnet)

The VM gets an IP on your LAN. Simplest setup — George SSHes directly to the VM.

In Proxmox, attach the VM's network interface to `vmbr0` (your LAN bridge).
The VM gets a DHCP address on your home network.

```
George (192.168.1.50)  ──SSH──►  GPU VM (192.168.1.100)
  REMOTE_SSH_TARGET=user@192.168.1.100
  REMOTE_FORWARD_HOST=localhost              ← default
```

### Option B: NAT (Separate Subnet)

The VM is on a private subnet behind the Proxmox host. George SSHes to
the Proxmox host, which forwards to the VM. More secure — the GPU VM
isn't directly exposed to your LAN.

#### Create a NAT bridge on the Proxmox host:

```bash
# /etc/network/interfaces (add to existing):
auto vmbr1
iface vmbr1 inet static
    address 10.0.0.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up   iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s 10.0.0.0/24 -o vmbr0 -j MASQUERADE
```

Apply: `ifreload -a`

#### Set static IP in the VM:

```bash
# /etc/network/interfaces (inside VM):
auto ens18
iface ens18 inet static
    address 10.0.0.100/24
    gateway 10.0.0.1
    dns-nameservers 1.1.1.1 8.8.8.8
```

#### SSH from George:

```
George (192.168.1.50)  ──SSH──►  Proxmox Host (192.168.1.10)  ──NAT──►  GPU VM (10.0.0.100)
  REMOTE_SSH_TARGET=user@192.168.1.10
  REMOTE_FORWARD_HOST=10.0.0.100
```

### Firewall Rules

If using Proxmox's built-in firewall or `ufw` on the host:

```bash
# On Proxmox host — allow SSH from your LAN:
iptables -A INPUT -p tcp --dport 22 -s 192.168.1.0/24 -j ACCEPT

# Allow forwarding from host to VM subnet:
iptables -A FORWARD -i vmbr0 -o vmbr1 -d 10.0.0.0/24 -j ACCEPT
iptables -A FORWARD -i vmbr1 -o vmbr0 -s 10.0.0.0/24 -j ACCEPT
```

**Inside the VM** — only allow SSH from the host and localhost:

```bash
# Install ufw:
sudo apt install ufw

# Default deny incoming:
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Allow SSH from the Proxmox host subnet:
sudo ufw allow from 10.0.0.0/24 to any port 22

# Allow Ollama + llama-server from the host (for tunnel forwarding):
sudo ufw allow from 10.0.0.0/24 to any port 11434
sudo ufw allow from 10.0.0.0/24 to any port 8080

# Enable:
sudo ufw enable
```

> **Critical lesson learned**: Ollama binds to `127.0.0.1` by default.
> When using a jump host / NAT topology, the SSH tunnel forwards to
> `10.0.0.100:11434` — which Ollama rejects because it's not localhost.
> You **must** bind Ollama to `0.0.0.0` (see [Ollama as a Service](#ollama-as-a-service)).
> llama-server also needs `--host 0.0.0.0`.

---

## Part 4: GPU Software Stack (Inside the VM)

### Vulkan Drivers (AMD)

For AMD GPUs (Polaris, Navi 10, RDNA):

```bash
sudo apt update && sudo apt install -y \
    mesa-vulkan-drivers vulkan-tools libvulkan-dev \
    firmware-amd-graphics
```

Verify:
```bash
vulkaninfo --summary
# Should show your GPU name, e.g.:
#   deviceName = AMD Radeon RX 5700 XT (RADV NAVI10)
#   deviceType = PHYSICAL_DEVICE_TYPE_DISCRETE_GPU
```

### CUDA Drivers (NVIDIA)

For NVIDIA GPUs:
```bash
# Install NVIDIA drivers (Debian non-free repo):
sudo apt install -y nvidia-driver firmware-misc-nonfree

# Verify:
nvidia-smi
# Should show GPU name, VRAM, driver version
```

### Verify GPU Access

Run the George GPU validation script (from the VM):
```bash
# If blue-lodge is cloned on the VM:
bash scripts/validate-gpu.sh

# Or manually:
vulkaninfo --summary 2>/dev/null | grep -i "deviceName\|deviceType"
```

---

## Part 5: Inference Services

### Ollama as a Service

Ollama's official installer creates a systemd service automatically:

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

**Critical**: Override the bind address to accept connections from the
Proxmox host (needed for SSH tunnel forwarding in NAT topology):

```bash
sudo systemctl edit ollama
```

Add above the "Edits below this comment will be discarded" line:
```ini
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
```

Apply:
```bash
sudo systemctl daemon-reload
sudo systemctl restart ollama
sudo systemctl enable ollama
```

Verify:
```bash
# Must show 0.0.0.0:11434, NOT 127.0.0.1:11434
ss -tlnp | grep 11434

# Test the API:
curl -s http://127.0.0.1:11434/api/tags | jq .
```

> **If the override file doesn't save** (editor shows a `.#override.conf`
> temp file), create it directly:
> ```bash
> sudo mkdir -p /etc/systemd/system/ollama.service.d
> echo -e '[Service]\nEnvironment="OLLAMA_HOST=0.0.0.0:11434"' | \
>     sudo tee /etc/systemd/system/ollama.service.d/override.conf
> sudo systemctl daemon-reload && sudo systemctl restart ollama
> ```

### Build llama-server

```bash
sudo apt install -y build-essential cmake git curl jq pkg-config libcurl4-openssl-dev

git clone --depth 1 https://github.com/ggerganov/llama.cpp.git ~/llama.cpp
cd ~/llama.cpp

# AMD Vulkan:
cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_VULKAN=ON

# NVIDIA CUDA:
# cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON

cmake --build build --config Release -j $(nproc) -- llama-server
```

Verify:
```bash
~/llama.cpp/build/bin/llama-server --help | head -5
```

### llama-server as a Service

llama-server needs a GGUF model file to start. First make sure one of the
current Blue Lodge Ollama models is available, then resolve the blob path:

```bash
MODEL_REF=blue-lodge-gemma4-inst:4b

# Confirm the model is present in Ollama:
ollama ls | grep "$MODEL_REF"

# Resolve the GGUF blob:
GGUF_PATH=$(bash inference-server-models.sh --resolve "$MODEL_REF")

echo "GGUF: $GGUF_PATH"
ls -lh "$GGUF_PATH"
```

Create the service file (update the `ExecStart` path):

```bash
sudo tee /etc/systemd/system/llama-server.service << EOF
[Unit]
Description=llama.cpp inference server (George remote node)
After=network.target ollama.service

[Service]
Type=simple
User=$(whoami)
ExecStart=$(echo ~)/llama.cpp/build/bin/llama-server \\
    -m ${GGUF_PATH} \\
    --port 8080 --host 0.0.0.0 \\
    --jinja -ngl 99
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now llama-server
```

Verify:
```bash
# Check it's running:
sudo systemctl status llama-server

# Check health:
curl -s http://127.0.0.1:8080/health
# Should return: {"status":"ok"}

# Check GPU offload in logs:
sudo journalctl -u llama-server | grep -i "offloaded\|vulkan\|cuda" | tail -5
```

### Loading Models

To switch models, update the service file's `-m` path and restart:

```bash
# Find a different GGUF:
GGUF_PATH=$(bash inference-server-models.sh --resolve blue-lodge-qwen35-inst:9b)

# Update service:
sudo systemctl edit llama-server
# Override ExecStart with new model path

sudo systemctl restart llama-server
```

Or use George's provisioning script from any device:
```bash
./scripts/inference-server-models.sh blue-lodge-gemma4-inst:4b    # resolves blob + restarts llama-server
```

---

## Part 6: Connect George via SSH Tunnel

### Direct Topology

When George can SSH directly to the GPU VM (bridged networking):

```bash
/remote setup user@192.168.1.100
/remote connect
/remote status      # both endpoints should show "running"
/remote benchmark   # verify tok/s
```

### Jump Host Topology

When the GPU VM is behind NAT on the Proxmox host:

```bash
# 1. Setup SSH to the Proxmox host (jump host):
/remote setup user@192.168.1.10

# 2. Tell George where to forward through the jump host:
/remote forward 10.0.0.100

# 3. Connect:
/remote connect

# 4. Verify:
/remote status
/remote models
/remote benchmark
```

George opens:
```
ssh -N -L 11434:10.0.0.100:11434 -L 8080:10.0.0.100:8080 user@192.168.1.10
```

All George code talks to `http://127.0.0.1:8080` — the tunnel handles the rest.

---

## Troubleshooting

### GPU not visible inside VM

```bash
# Inside VM:
lspci | grep -i vga
```

If your GPU doesn't appear:
- Verify IOMMU is enabled: `dmesg | grep -i iommu` on host
- Verify VFIO claimed the GPU: `lspci -nnk -s 01:00` on host should show `vfio-pci`
- Check VM config has `hostpci0: ...` line
- Ensure the GPU and its audio device are in the same IOMMU group and both passed through

### Vulkan works but llama-server says "0 layers offloaded"

The GPU might not have enough VRAM for the model:
```bash
vulkaninfo --summary | grep -i "memory\|deviceName"
```

Try a smaller model or more aggressive quantization (Q4_K_S vs Q4_K_M).

### Ollama unreachable through tunnel

**Symptom**: SSH tunnel is up, llama-server works, but Ollama doesn't respond.

**Cause**: Ollama binds to `127.0.0.1` by default. The tunnel forwards to
the VM's LAN IP, which Ollama refuses.

**Fix**:
```bash
sudo systemctl edit ollama
# Add: Environment="OLLAMA_HOST=0.0.0.0:11434"
sudo systemctl daemon-reload && sudo systemctl restart ollama
ss -tlnp | grep 11434
# Must show 0.0.0.0:11434
```

### Services not running on VM

**Symptom**: Tunnel connects but both endpoints unreachable.

**Check**:
```bash
# On the VM:
ss -tlnp | grep -E '11434|8080'
```

If nothing is listening, the services aren't running:
```bash
sudo systemctl status ollama
sudo systemctl status llama-server
sudo journalctl -u ollama -n 20 --no-pager
sudo journalctl -u llama-server -n 20 --no-pager
```

### Port conflicts (local services shadow the tunnel)

If Ollama or llama-server is also running locally (on the phone/laptop),
the tunnel can't bind to ports 11434/8080. George auto-detects this and
remaps to +10000 (21434/18080). Check with `/remote status`.

### Tunnel connects but nothing responds

Run `/remote diagnose` for a full diagnostic. Or manually:
```bash
# Verbose SSH test (from George device):
ssh -v -N \
  -o BatchMode=yes -o ConnectTimeout=10 \
  -o ExitOnForwardFailure=yes \
  -L 21434:<vm-ip>:11434 \
  -L 18080:<vm-ip>:8080 \
  user@<proxmox-host> 2>&1 | head -80
```

Look for:
- `Authenticated to ...` — SSH auth works
- `Local forwarding listening on 127.0.0.1 port ...` — tunnel is bound
- No `channel ... open failed` — forwarding is working

If auth fails, run `/remote setup user@<host>` to copy your SSH key.

### systemctl edit doesn't save override

Some editors create a temp `.#override.conf...` file instead of saving.
Create the file directly:
```bash
sudo mkdir -p /etc/systemd/system/ollama.service.d
echo -e '[Service]\nEnvironment="OLLAMA_HOST=0.0.0.0:11434"' | \
    sudo tee /etc/systemd/system/ollama.service.d/override.conf
```

### GGUF blob path changed after Ollama update

If llama-server fails to start after an Ollama update, the blob hash may
have changed. Re-resolve:
```bash
bash inference-server-models.sh --resolve blue-lodge-gemma4-inst:4b
# Re-run the GGUF resolution and update the service file
```

---

## Performance Reference

### AMD RX 5700 XT (Navi 10, 8GB VRAM, Vulkan via RADV)

| Model | Quant | VRAM | Gen tok/s | Prompt tok/s |
|-------|-------|------|-----------|--------------|
| Granite 4.1 3B | Q4_K_M | ~2.2 GB | ~90 | ~200 |
| Gemma 4 E4B | UD-Q4_K_XL | ~3.4 GB | ~75 | ~150 |
| Qwen 3.5 9B | UD-Q4_K_XL | ~5.5 GB | ~55 | ~100 |
| Gemma 4 12B | UD-Q4_K_XL | ~7 GB | ~40 | ~70 |

### VRAM Budget

| GPU VRAM | Max Model Size (Q4_K_M) | Examples |
|----------|------------------------|----------|
| 4 GB | ~4B params | Gemma 4 E2B, Granite 4.1 3B |
| 6 GB | ~8B params | Gemma 4 E4B, Qwen 3.5 4B |
| 8 GB | ~12B params | Granite 4.1 8B, Qwen 3.5 9B, Gemma 4 12B (tight) |
| 12 GB | ~20B params | Larger models with room to spare |
| 24 GB | ~70B params | Llama 3.1 70B Q4_K_M |

---

## Quick Reference Card

```bash
# === On Proxmox Host (one-time) ===
# Enable IOMMU, load VFIO, blacklist GPU driver, reboot
# Create VM with q35/OVMF, pass through GPU

# === Inside GPU VM (one-time) ===
sudo apt install mesa-vulkan-drivers vulkan-tools build-essential cmake git curl jq
curl -fsSL https://ollama.com/install.sh | sh
sudo mkdir -p /etc/systemd/system/ollama.service.d
echo -e '[Service]\nEnvironment="OLLAMA_HOST=0.0.0.0:11434"' | \
    sudo tee /etc/systemd/system/ollama.service.d/override.conf
sudo systemctl daemon-reload && sudo systemctl enable --now ollama

git clone --depth 1 https://github.com/ggerganov/llama.cpp.git ~/llama.cpp
cd ~/llama.cpp && cmake -B build -DGGML_VULKAN=ON && cmake --build build -j$(nproc) -- llama-server

bash inference-server-models.sh blue-lodge-gemma4-inst:4b
# Resolve GGUF blob, create llama-server.service, enable + start

# === On George device (each session) ===
/remote setup user@<proxmox-host>      # one-time SSH key setup
/remote forward <vm-ip>                # if using jump host topology
/remote connect                        # opens tunnel
/remote status                         # verify
/remote benchmark                      # check tok/s
```

---

*See also: [INFERENCE_FABRIC.md](INFERENCE_FABRIC.md) for the full remote
inference architecture, model registry, and provisioning script details.*
