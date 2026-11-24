---
title: "Modular Heartwood Architecture, Lodge Guild App Store & Ecotype Git Model"
description: "Definitive reference for Blue Lodge's three-tier Git model (Heartwood, Node Ecotypes, External Guild Modules), module.json contract, supply-chain security, and external module runtime isolation."
subsystem: "architecture"
tags:
  - modular-architecture
  - lodge-guild
  - app-store
  - ecotype
  - git-model
  - hunting-buddy
  - shop-bench
  - skywatch
  - security
okf_id: "urn:blue-lodge:doc:modular-architecture-git-model"
related:
  - "[[INDEX]]"
  - "[[ARCHITECTURE]]"
  - "[[ARCHITECTURE_INDEX]]"
  - "[[SECURITY]]"
  - "[[SOVEREIGN_DEX_AND_LENDING_GUIDE]]"
---

# Modular Heartwood Architecture, Lodge Guild App Store & Ecotype Git Model

Blue Lodge separates its **Heartwood Core** (the agent reasoning kernel, Rust web cockpit, FIFO IPC, security guards, and orchestration services) from **Domain Modules** (installable capabilities with their own tools, skills, cron sweeps, event reactors, and native Web UI panels). This design allows brother nodes (`george`, `hiram`, family camp nodes, or community forks) to share one clean upstream codebase while installing only the domain extensions they want.

---

## 1. The Three-Tier Sovereign Git Model

```
┌────────────────────────────────────────────────────────────────────────────┐
│ TIER 1: HEARTWOOD TRUNK (blue-lodge: main / develop)                       │
│ Core Bash agent, ReAct loop, Rust george-web shell, FIFO IPC, security     │
│ guards (venv_pkg_guard, module_audit, tool_forge), built-in core panes.    │
└───────────────────────────────┬────────────────────────────────────────────┘
                                │  /ecotype sync (sandboxed worktree merge)
                                ▼
┌────────────────────────────────────────────────────────────────────────────┐
│ TIER 2: NODE ECOTYPES (blue-lodge: ecotype/<node>)                         │
│ e.g. ecotype/george, ecotype/hiram, ecotype/camp-cabin                     │
│ Per-host configs, hardware tuning, & .george/ecotype_manifest.json         │
│ (declares which built-ins & external Guild modules are active on this box).│
└───────────────────────────────┬────────────────────────────────────────────┘
                                │  /app catalog + /app install <id>
                                ▼
┌────────────────────────────────────────────────────────────────────────────┐
│ TIER 3: EXTERNAL GUILD MODULES (Independent Git Repositories)              │
│ • blue-lodge-guild/catalog.json  (SHA-pinned App Store index)              │
│ • mod-shop-bench                 (OBD-II / CAN-Bus & Fleet Workbench)      │
│ • mod-skywatch                   (Weather / Aviation / HF / ADS-B Bench)   │
│ • mod-hunting-buddy              (Sovereign GIS + Mobile GPS Bridge)       │
│ Installed into gitignored .george/modules/<id>/ with persistent state in   │
│ .george/module_data/<id>/.                                                 │
└────────────────────────────────────────────────────────────────────────────┘
```

### How Nodes & Contributors Operate Over Git

| Workflow | Command / Branch | What Happens |
| :--- | :--- | :--- |
| **Initialize a node's ecotype** | `/ecotype init <node>` | Creates/checks out `ecotype/<node>` and syncs to local Gitea + GitHub `origin`. |
| **Pull upstream Heartwood fixes** | `/ecotype sync` | Fetches `origin/develop`, performs a **sandboxed worktree test-merge**, runs syntax checks, and only updates your live `ecotype/<node>` branch if clean. |
| **Contribute a core fix back** | PR `ecotype/<node>` → `develop` | Heartwood changes flow into `develop` (then `main`), making them available to all brother nodes (`george`, `hiram`, etc.) without dragging node-specific modules or secrets along. |
| **Browse & install domain modules** | `/app catalog` then `/app install <id>` | Clones the SHA-pinned external module repo (`mod-<id>`) into `.george/modules/<id>/`, audits it via `module_audit.py`, verifies wheels via `venv_pkg_guard.py`, and records the exact commit SHA in `.george/ecotype_manifest.json`. |
| **Develop a module independently** | Work inside `mod-<id>` repo | Modules live in their own Git repos (`http://127.0.0.1:3088/george/mod-<id>.git` or GitHub). Bump the pinned SHA in `blue-lodge-guild/catalog.json` when releasing a new version. |
| **Reproduce a node on new hardware** | Clone `blue-lodge`, checkout `ecotype/<node>`, run `/app install` for manifest entries | `.george/ecotype_manifest.json` acts as the declarative lockfile of enabled built-ins and SHA-pinned external modules. |

> [!IMPORTANT]
> **Why External Modules Are Never Git Submodules:** External modules live in gitignored `.george/modules/<id>/` and are managed strictly by `lib/sys/modules.sh` (`/app`). This prevents merge conflicts during `/ecotype sync`, lets non-technical users install/remove modules from the Web UI App Store with one click, and guarantees every install passes static AST auditing and SHA pinning.

---

## 2. Core Heartwood vs. Modular Domains (Web UI Layout)

To keep the Web UI clean and intuitive as the module ecosystem grows, the top navigation drawer is divided into two rows:

1. **HEARTWOOD (5 Fixed Core Groups)**:
   - **RACK & VITALS**: Instrument Rack topology & compute telemetry.
   - **AUTOMATION**: Cron Builder & Sweeps, Event Bus, Reactors & Webhooks.
   - **APP STORE & WORKSHOP**: Lodge Guild App Store (install/enable/disable modules), MCP Hub, and Public API Catalog (1,959 zero-auth REST endpoints).
   - **CHRONICLE & HISTORY**: Chronicle/SQLite/OKF, Time-Machine Backups, Spec Sheet.
   - **MANUAL & COMMANDS**: Field Manual & Slash Commands.
2. **MODULES (Dynamic Enabled Module Bar)**:
   - Only modules enabled in `.george/ecotype_manifest.json` render pills here.
   - **Crypto 3-Module Consolidation**:
     - `sovereign-dex`: Live Minswap V2 Desk, Walk-Forward Backtests, and **Dolos Chain Ops** (folded in as a sub-tab).
     - `sovereign-fund`: P2P Microloans, Live Polymarket Surveillance, and Tax/Staking Provenance.
     - `trading-sim`: Standalone opt-in Paper Trading Sandbox (**disabled by default** — suspends its 4 paper-betting Event Bus reactors `rx_polymarket_active`, `rx_trading_poly`, `rx_trading_crypto`, `rx_trading_alert` so zero idle CPU cycles are wasted).
   - **First-Party Built-ins**: `sdr-radio-lab`, `the-tyler`, `deep-research`, `smart-home-cast`.
   - **External Guild Modules**: `shop-bench`, `skywatch`, `hunting-buddy`, plus any private or community `mod-*` repository you install.

---

## 3. Module Contract (`module.json`) & 3-Mode Runtime Isolation

Every external module declares a `module.json` at its repository root:

```json
{
  "schema_version": 1,
  "id": "hunting-buddy",
  "name": "Hunting Buddy",
  "version": "1.0.0",
  "category": "outdoors",
  "runtime": {
    "venv_mode": "shared_locked",
    "python_packages": ["matplotlib", "shapely", "pyproj", "pypdf", "scipy"]
  },
  "provides": {
    "tools_schema": "tools/schemas.json",
    "tools_dispatcher": "tools/dispatch.sh",
    "tool_bundle": "+hunting",
    "domain_keywords": "hunt parcel gis stand scent wind gpx",
    "context_hook": "hooks/context.sh",
    "strategist_hook": "hooks/strategist.txt",
    "slash_commands": ["commands/hunt.sh"],
    "cron_templates": ["cron/wind_shift_watch.sh"],
    "event_reactors": ["reactors/my_reactors.json"],
    "ui": { "js": "ui/panel.js", "css": "ui/panel.css" }
  }
}
```

### Three Runtime Isolation Modes
1. `shared_locked`: Installs allowlisted pure-Python/scientific wheels into Blue Lodge's shared `.venv` via `venv_pkg_guard.py` (fast, zero duplicate disk usage; e.g. `hunting-buddy`).
2. `isolated_venv`: Creates a dedicated `.george/modules/<id>/.venv` via `venv_pkg_guard.py --venv <path> --create-venv` for modules with conflicting Python dependencies.
3. `docker_sidecar`: Orchestrates a Docker Compose service (e.g. a custom FastAPI + database sidecar on `127.0.0.1:8765`), proxied strictly over localhost by `george-web` (`GET/POST /api/modules/:id/proxy/*`).

---

## 4. Security & Supply-Chain Protection

1. **SHA-Pinned Guild Catalog (`blue-lodge-guild/catalog.json`)**: `/app install <id>` checks out the exact pinned Git commit SHA rather than floating `main`.
2. **Static Security Auditor (`lib/tools/module_audit.py`)**: Every install runs manifest schema validation, canonical path-traversal rejection, `bash -n` syntax checks, and Python AST scanning (blocking `eval`, `exec`, `pickle.loads`, `os.system`, `curl | sh`, and shell injection).
3. **Supply-Chain Wheel Gate (`lib/tools/venv_pkg_guard.py`)**:
   - Curated `data/security/pypi_allowlist.json` (Tier A packages auto-approved; unknown packages require explicit `--approve`).
   - Enforces HTTPS PyPI JSON API metadata lookup, **wheel-only (`--only-binary=:all:`)** installs (zero arbitrary `setup.py` execution!), and **SHA-256 hash verification (`pip --require-hashes`)** to block MITM and supply-chain poisoning.
   - Audit-logged to `.george/security/pkg_install.log`.
4. **Web UI Plugin Sandbox (`web/src/routes/modules.rs` & `web/static/js/modules.js`)**:
   - Module assets are served strictly from canonicalized `.george/modules/<id>/ui/` (400/403 on path traversal).
   - All mutating module actions require `X-Lodge-Token` (in-memory token or paired HttpOnly cookie — never `localStorage`).
   - All Heartwood and Guild module JS strictly uses `document.createElement` + `textContent` (zero `innerHTML` / `outerHTML`).

---

## 5. Official Guild Modules

### A. Hunting Buddy (`mod-hunting-buddy`)
- **Offline-First Leaflet Map**: Vendored Leaflet 1.9.4 + USGS NAIP Aerial / 3DEP Topo / Hybrid tiles cached on disk via `GET /api/modules/hunting-buddy/tiles/:layer/:z/:x/:y`.
- **Pluggable State GIS Adapters**: Ships with Wisconsin SCO/WROC Statewide Parcel ArcGIS (`adapters/wi_sco.py`); community contributors can add MI, MN, IA, OH by subclassing `StateParcelProvider`.
- **Bidirectional onX Hunt Interchange**: Imports `.gpx`, `.kml`, `.kmz`, `.geojson`, county parcel PDFs (`pypdf`), and trail-cam EXIF; exports recommended stand pins & trails back to `.gpx`/`.kml` for **onX Hunt**.
- **Wind, Thermals & Scent Conflict Engine**: Open-Meteo hourly forecast + NOAA astronomical DNR legal shooting light + `shapely` downwind conflict alerts + high-DPI `matplotlib` Discord tactical map cards.
- **Camp Privacy**: Defaults to `public`; switch any property to per-Discord-channel isolation via `/hunt privacy private`.
- **Android / Mobile GPS & Compass Heading Bridge**:
  - Endpoint: `POST /api/modules/hunting-buddy/mobile/beacon`
  - Auth: Either `X-Lodge-Token` OR a per-hunter SHA-256-hashed `X-Beacon-Token` issued via `/hunt token <hunter_id> "<Name>"` or the Web UI.
  - Payload: `{"hunter_id":"hunter-alpha","hunter_name":"Hunter Alpha","lat":45.9201,"lon":-89.2501,"heading_deg":315,"speed_mps":1.1,"accuracy_m":4.5,"battery_pct":88,"status":"in_stand","property_id":1}`.
  - Renders live moving hunter vectors & breadcrumb tracks on the Leaflet map + emits `hunting/hunter_position_update` on the Event Bus. Also includes a browser **Mobile Field Beacon** streamer (`navigator.geolocation.watchPosition` + `DeviceOrientationEvent`).

### B. Shop Bench (`mod-shop-bench`)
- **OBD-II / CAN-Bus Telemetry & Fleet Ledger**: Live Torque-style radial gauges, 45+ SAE J1979 PIDs, opendbc `.dbc` signal decoding, Windows Bluetooth-to-TCP bridge for ELM327 adapters, SQLite rolling 600-sample buffer, and AI mechanic copilot reports.

### C. SkyWatch (`mod-skywatch`)
- **Zero-Key Field, Aviation, Ham Radio & Space-Weather Bench**: Live Leaflet NEXRAD radar, NWS alerts, FAA METAR/TAF, NOAA SWPC `Kp`/`SFI`/HF band matrix, 72h outdoor activity window planner, and optional local RTL-SDR `dump1090` ADS-B aircraft tracking.

### D. Private / Custom `docker_sidecar` Modules
- Operators can author private heavy-service modules (FastAPI + MariaDB/Postgres sidecars, proprietary ML tools, etc.) in local Gitea (`gitea/mod-<id>`) or private GitHub repos and install them via `lodge /app install <url>` without publishing them in `blue-lodge-guild/catalog.json`.
