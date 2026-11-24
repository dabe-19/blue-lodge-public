# Blue Lodge Multi-Node Sync, App Store & Module Contract Guide

This guide documents the standard operating procedure for synchronizing Heartwood across sovereign nodes (e.g., `ecotype/hiram` ↔ `develop` ↔ `ecotype/george`), updating Lodge Guild modules via the App Store interface, and authoring standalone module repositories.

---

## 1. Multi-Node Ecotype Git Sync (Software Phytology)

Every Blue Lodge node operates on its own ecotype branch (`ecotype/<node_name>`) while sharing the common Heartwood integration trunk (`develop` on GitHub `origin` and local Gitea `gitea`).

### Pulling Upstream Heartwood Updates Onto Your Node
```bash
# 1. Inspect divergence between your ecotype branch and origin/develop
/ecotype status
# (or from shell: bash commands/ecotype.sh status)

# 2. Sandboxed Pollination — fetches origin/develop, test-merges in an isolated
#    worktree, AST-checks modified .sh/.py files, fast-forwards ecotype/<node>
#    AND local develop, and mirrors both to local Gitea.
#    Untracked local Foliage (e.g. .george/tools/*) does NOT block pollination.
/ecotype sync
# (or from shell: bash commands/ecotype.sh sync)
```

> **If Rust cockpit files (`web/src/**`, `Cargo.toml`) changed:** `ecotype_sync` prints a rebuild notice. Rebuild and restart `george-web`:
> - **Bare-metal / WSL**: `(cd web && cargo build --release) && systemctl --user restart george-web.service` (or `bash -c 'source commands/web.sh && cmd_web restart'`)
> - **Docker**: `docker compose up -d --build george-web`
> - **K8s**: `./scripts/infra/k8s_deploy.sh build web && ./scripts/infra/k8s_deploy.sh restart web`

### Promoting Heartwood Changes Upstream From a Node
```bash
# Graft ONLY Heartwood files onto a clean candidate/* branch (blocks .george/*)
/ecotype promote --title "feat(scope): summary" --push-origin path/to/file1 path/to/file2

# Back up your node's ecotype branch to local Gitea (+ GitHub with --cloud)
/ecotype backup --cloud
```

---

## 2. Lodge Guild App Store & Module Sync Procedure

External modules live in independent Git repositories (`mod-<id>`) pinned by commit SHA in `blue-lodge-guild/catalog.json`.

### Option A — Web UI (App Store & Workshop → Lodge Guild App Store)
1. Click **SYNC GUILD CATALOG** (`POST /api/modules/catalog/sync`):
   - Mirrors `blue-lodge-guild` and every cataloged `mod-*` repository from GitHub into the node's local Gitea forge (`scripts/infra/sync_guild_gitea.sh`, non-fatal when offline/air-gapped).
   - Pulls `.george/guild_catalog/catalog.json` and compares each installed module's real `git HEAD` / `version` against the catalog pin.
2. Any outdated module displays an amber **`UPDATE vX.Y.Z → vA.B.C`** badge and a 1-click **`UPDATE TO vA.B.C`** button (plus **`UPDATE ALL (N)`** in the scope bar).
3. Clicking **UPDATE** (`POST /api/modules/:id/update`):
   - Clones the new SHA into a staging directory,
   - Runs mandatory static security & schema audit (`lib/tools/module_audit.py` — AST safety, Bash syntax, `module.json` boundaries, ALP v1 `workflows/*.loop.json` validation),
   - Verifies and installs any new Python wheels via SHA-256 supply-chain guard (`lib/tools/venv_pkg_guard.py`),
   - Atomically swaps `.george/modules/<id>/` while **100% preserving user data, SQLite/MariaDB ledgers, and local ALP v1 loop overrides in `.george/module_data/<id>/`**,
   - Re-syncs Event Bus reactors, cron templates, and `merged_tools.json`,
   - Evicts stale cached module JS/CSS so opening the module immediately renders the new version.

### Option B — CLI / Slash Commands
```bash
/app catalog                 # Mirror GitHub -> local Gitea + refresh catalog.json
/app list                    # Shows [ON] id (v1.5.0 -> v2.6.1 UPDATE) when behind
/app update <module_id>      # Safely upgrade a single module (preserves module_data)
/app update --all            # Safely upgrade all outdated modules
/app mirror-gitea            # Manually run scripts/infra/sync_guild_gitea.sh
```

---

## 3. Decoupled Module / App Contract (Zero Git Submodules)

External apps are **independent Git repositories** mounted dynamically at runtime — never Git submodules inside `blue-lodge`.

### Filesystem Boundary
| Path | Owned By | Git-Tracked in `blue-lodge`? | Purpose |
| :--- | :--- | :--- | :--- |
| `.george/modules/<id>/` | Module's own Git repo | No (ignored) | Packaged code, tools, workflows, UI panel |
| `.george/module_data/<id>/` | Local node operator | No (ignored) | Persistent DBs, maps, caches, local `.loop.json` overrides |
| `.george/ecotype_manifest.json` | Local node | No (ignored) | Installed/enabled state, pinned SHAs, built-in toggles |
| `.george/cache/merged_tools.json` | Generated | No (ignored) | Core + enabled-module OpenAI tool schemas |

### Required & Optional Files Inside a Module Repository (`mod-<id>`)
```text
mod-<id>/
├── module.json                  # Manifest: id, version, runtime, provides, permissions
├── tools/
│   ├── schemas.json             # OpenAI-format tool declarations exposed to the agent
│   ├── dispatch.sh              # Tool dispatcher invoked by native_tools_dispatch
│   └── web_action.sh            # Optional direct REST action handler (/api/modules/:id/action/:action)
├── workflows/
│   └── <loop_id>.loop.json      # ALP v1 declarative multi-phase FIFO + ReAct loops (default 200 turns)
├── ui/
│   ├── panel.js                 # Calls window.LodgeModules.register("<id>", { mount(host, ctx) {} })
│   └── panel.css                # Scoped module styles served via /api/modules/:id/assets/*
├── hooks/
│   ├── context.sh               # Optional context injected when module keywords match
│   ├── strategist.txt           # Optional Honeydew strategist hint
│   └── health.sh                # Healthcheck script (/api/modules/:id/health)
├── reactors/                    # Optional Event Bus reactor definitions
└── cron/                        # Optional scheduled sweep scripts
```

### Runtime Plugin SDK (`ctx` passed into `mount(host, ctx)`)
- `ctx.el(tag, opts, children)` — XSS-safe DOM helper (zero `innerHTML`)
- `ctx.agentName` / `ctx.getAgentName()` — dynamic ecotype node identity (`George`, `NodeB`, etc.)
- `ctx.action(name, payload)` — calls `POST /api/modules/:id/action/:name`
- `ctx.proxyGet/Post/FormData(path, ...)` — proxies to `docker_sidecar` (`sidecar_port`)
- `ctx.launchTask(workflow, payload, opts)` — launches a monitored ALP v1 loop (`default 200 turns`) streaming to both the inline `TranscriptConsole` and the main Task Bay
- `ctx.listLoops()` / `ctx.getLoop(id)` / `ctx.saveLoop(id, def, target)` / `ctx.openLoopStudio(id)` — full ALP v1 Loop Studio integration
