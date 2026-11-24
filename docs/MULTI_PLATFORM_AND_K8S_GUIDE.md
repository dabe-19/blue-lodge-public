# Blue Lodge (George) — Multi-Platform & Kubernetes GitOps Guide

This document describes how to deploy, operate, and develop **Blue Lodge (George)** across heterogeneous compute environments—from a **Kubernetes (`k3s` + Rancher + Fleet) GPU cluster** on WSL2/Linux to **standalone Docker Compose workstations** and **macOS edge clients**—from a single unified codebase.

---

## 1. Platform Support Matrix

| Platform | Inference Engine | Orchestration & Sidecars | GPU Acceleration | Primary Use Case |
| :--- | :--- | :--- | :--- | :--- |
| **Kubernetes (`k3s` / Rancher)** *(WSL2 or Linux)* | Stock `ggml-org/llama.cpp` (`george-inference` Deployment) | Native K8s pods in `blue-lodge` namespace (`george-web`, `george-searxng`, `george-mosquitto`) + in-cluster Gitea | WSL2 `/dev/dxg` + `/usr/lib/wsl/lib` passthrough or Linux NVIDIA Device Plugin (`sm_86;120`) | Multi-service cluster management via Rancher UI & Fleet GitOps |
| **Linux / WSL2 Docker Compose** | Stock `llama.cpp` (`george-prism-server`) | `docker-compose.yml` (`scripts/infra/compose.sh`) | NVIDIA Container Toolkit (`--gpus all`), ROCm (`/dev/kfd`), or Vulkan (`/dev/dri`) | Single-host sovereign workstation or dual-GPU split node |
| **Native Linux / Workstation** | Host `llama-server` binary (`--runtime native`) | Host systemd user services + optional sidecars | Native CUDA / ROCm / Vulkan | Bare-metal developer environment |
| **macOS (Apple Silicon)** | Remote Tailscale endpoint (`TIER1_URL`) or native Metal `llama-server` | `./lodge` CLI + native `george-web` (`cargo build --release`) | Apple Metal (local) or remote Blackwell/Ampere GPU over Tailscale | Thin workstation or mobile/laptop client |

---

## 2. Kubernetes Architecture (`deploy/k8s/` + Rancher + Gitea)

When running inside Kubernetes (`k3s` managed by Rancher), all George services reside in the **`blue-lodge`** namespace (bound to Rancher Project `p-qjdml`):

* **`george-inference` (`Deployment`, strategy `Recreate`):**
  * Runs upstream `ggml-org/llama.cpp` compiled for **NVIDIA Blackwell (`sm_120`)** and **Ampere (`sm_86`)**.
  * Mounts `/dev/dxg` and `/usr/lib/wsl` (for zero-friction WSL2 CUDA 13.2 passthrough) and `/home/user/models` at `/models`.
  * Reads runtime flags (`LLAMA_ARG_MODEL`, `LLAMA_ARG_MMPROJ`, `LLAMA_ARG_MODEL_DRAFT`, `LLAMA_ARG_SPEC_TYPE=draft-mtp`, `LLAMA_ARG_CTX_SIZE=98304`) from `ConfigMap/george-inference-profile-env`.
  * Exposed internally at `http://george-inference:8080`, via `hostPort: 8080` (`http://127.0.0.1:8080`), and externally via Traefik TLS Ingress (`cert-manager.io/cluster-issuer: local-ca-issuer`) at **`https://llm.localhost`**.
* **`george-web` (`Deployment`, strategy `Recreate`, `serviceAccountName: george-operator`):**
  * Runs the Rust Axum Workbench (`george-web`) + embedded PTY `./lodge` runtime with `git`, `jq`, `bwrap`, `sqlite3`, `uv`, and `kubectl`.
  * Mounts `/home/user/projects/blue-lodge` directly at `/workspace` (and mirrored at `/home/user/projects/blue-lodge`) so file edits, `.george/` state, and `recall.db` are shared live between the host IDE and the cluster pod.
  * Automatically recognizes local host desktop sessions over `https://george.localhost` and `http://localhost:3000` (`cni0`/Traefik CNI hops `10.42.0.0/16` with loopback `Host`), and transparently routes in-pod `127.0.0.1:8080` / `llm.localhost` calls to `http://george-inference:8080`.
  * Exposed via Traefik TLS Ingress (`local-ca-issuer`) at **`https://george.localhost`**.
* **`george-searxng` & `george-mosquitto` (`Deployments`):**
  * Provide in-cluster metasearch (`http://george-searxng:8080` / **`https://searxng.localhost`**) and MQTT event bus (`george-mosquitto:1883`).

---

## 3. The Two-Loop Development Workflow on Kubernetes

You **always edit code in `/home/user/projects/blue-lodge`** on your workstation (e.g. in Antigravity IDE or VS Code):

### Loop A: Instant Live Reload (95% of Feature Work — 0s Delay)
* All Bash modules (`lodge`, `lib/**/*.sh`, `commands/*.sh`), Python backends (`lib/**/*.py`), agent workflows (`.agents/`), configs (`configs/`), and Web UI frontend files (`web/static/*`) live inside `/home/user/projects/blue-lodge`, which is mounted into the `george-web` pod as `/workspace`.
* **Saving a file on the host immediately updates the running Kubernetes pod.** No container rebuild or rollout is needed.

### Loop B: Compiled Rust (`web/src/*.rs`), Dockerfiles & K8s Manifests
When you modify compiled Rust routes in `web/src/`, `Dockerfile.cuda-sandbox`, or Kubernetes manifests in `deploy/k8s/`:

1. **Local One-Command Build & Rollout:**
   ```bash
   # Rebuild george-web into k3s containerd and restart the Deployment:
   ./scripts/infra/k8s_deploy.sh build web
   ./scripts/infra/k8s_deploy.sh restart web

   # Apply updated Kubernetes YAML manifests:
   ./scripts/infra/k8s_deploy.sh up
   ```
2. **GitOps via Local Gitea & Rancher Fleet (`git push gitea`):**
   * Push your branch to the in-cluster Gitea instance (`https://gitea.localhost`) and open a Pull Request into `develop`.
   * **Rancher Fleet** (`deploy/k8s/fleet.yaml`) watches `deploy/k8s/` in your local Gitea repository and automatically reconciles Kubernetes manifest changes in the `blue-lodge` namespace.
   * Once verified on your local cluster, push to upstream GitHub (`git push origin <branch>`) to share the platform-agnostic improvements with other nodes.

---

## 4. Multi-Node Cron Fencing (`CRON_ALLOWLIST_ONLY`)

Because `.george/cron_jobs/*.sh` scripts are tracked in Git with `# ENABLED: 1` headers for Node 1, secondary compute nodes use `.george/configs/cron.conf` (untracked) to fence off device-specific jobs (crypto trading, X/Twitter posting, Discord polling, Tyler RF sweeps):

```ini
# .george/configs/cron.conf
CRON_NODE_ROLE="k8s_compute_node"
CRON_ALLOWLIST_ONLY=1
CRON_ENABLED_JOBS="flow_cache_gc,journal_decay,scene_sync_catchup,storage_janitor,session_sweeper,sandbox_stub_sweeper"

CRON_INTERVAL_SENTINEL=0
CRON_INTERVAL_PR=0
CRON_INTERVAL_ISSUE=0
CRON_INTERVAL_DISCORD=0
CRON_INTERVAL_EMAIL=0
CRON_INTERVAL_X=0
CRON_INTERVAL_MASTODON=0
CRON_INTERVAL_CI=0
```

When `CRON_ALLOWLIST_ONLY=1` is set, [lib/sys/cron.sh](file:///home/user/projects/blue-lodge/lib/sys/cron.sh) ignores `# ENABLED: 1` headers in `.george/cron_jobs/*.sh` and only permits jobs explicitly listed in `CRON_ENABLED_JOBS`.

---

## 5. Multi-Node Identity, Discord Swarm Topologies & Config Backups

Multiple Blue Lodge nodes can coexist on the same Discord server (using separate Discord Bot tokens and callsigns, e.g. Node 1 `@george` and Node 2 `@hiram`) and transition dynamically between `independent`, `federated`, and `swarm` modes:

* **Web UI (`https://george.localhost` → Spec Sheet Drawer):**
  * **Chamber 2 (`[COMMS] NODE IDENTITY, DISCORD & SOCIALS`):** Edit node callsign, topology mode (`independent` | `federated` | `swarm`), swarm channel posture (`direct-on-mention` | `strict-subordinate`), Master/Peer Bot IDs, and Discord/Mastodon/Bluesky/Telegram tokens, or run live `/social validate` checks.
  * **Chamber 3 (`RAW BLUEPRINT SHEET & BACKUPS`):** Edit raw `limits.conf`, `endpoints.conf`, `keys.conf`, `lodge.conf`, and `cron.conf`, or 1-click **EXPORT / BACKUP CONFIGS (.JSON)** (also saved to `.george/backups/` with `0600` permissions) and **IMPORT / RESTORE BACKUP**.
* **CLI (`/node` — [commands/node.sh](file:///home/user/projects/blue-lodge/commands/node.sh)):**
  ```bash
  ./lodge /node status
  ./lodge /node callsign hiram
  ./lodge /node mode federated       # independent | federated | swarm
  ./lodge /node posture direct-on-mention  # direct-on-mention | strict-subordinate
  ./lodge /node master <NODE1_BOT_ID>
  ./lodge /node peer add <NODE1_BOT_ID>
  ```

---

## 6. Gemma 4 + MTP + LoRA SVD32 on 24 GB Blackwell

### Hybrid Sliding-Window Attention (SWA) Memory Math
Gemma 4 (`gemma-4-31B-it` and `gemma-4-26B-A4B-it`) uses a **5:1 Hybrid SWA** architecture:
* **50 of 60 layers (31B)** or **25 of 30 layers (26B-A4B)** use a `1,024`-token sliding window (`head_dim=256`).
* Only **10 of 60 layers (31B, 4 KV heads)** or **5 of 30 layers (26B-A4B, 2 KV heads)** scale with the full `98,304` context window (`head_dim=512`).
* Keeping `-np 1` (`parallel: 1`) and `-ub 512` (`ubatch: 512`) with `-ctk q4_0 -ctv q4_0` keeps the entire 98k KV cache under **2.5 GB on 31B** (`22.5 MB / 1k tokens`) and **0.6 GB on 26B-A4B** (`5.6 MB / 1k tokens`).

### Switching Models & Attaching Colab Forge LoRA Adapters
```bash
# Switch active K8s inference pod to Gemma 4 31B-it (UD-Q4_K_XL + MTP + Vision):
./scripts/inference/activate_profile.sh gemma-4-31b-it-ud-q4_k_xl --runtime k8s

# Switch active K8s inference pod to Gemma 4 26B-A4B-it (MoE + MTP + Vision):
./scripts/inference/activate_profile.sh gemma-4-26b-a4b-it-ud-q4_k_xl --runtime k8s

# Attach a fine-tuned LoRA / SVD32 adapter exported from Colab Forge:
python3 lib/tools/model_hub_cli.py attach gemma-4-31b-it-ud-q4_k_xl lora /path/to/adapter.gguf --scale 1.0
python3 lib/tools/model_hub_cli.py approve gemma-4-31b-it-ud-q4_k_xl
./scripts/inference/activate_profile.sh gemma-4-31b-it-ud-q4_k_xl --runtime k8s
```
