# __MOD_NAME__ (`mod-__MOD_ID__`)

A sovereign **Blue Lodge Guild Module** built on the official `mod-starter-template` (ALP v1 + FIFO IPC + XSS-safe Web UI).

## Architecture
- **Standalone First**: Works completely offline with a local SQLite WAL ledger stored under `.george/module_data/__MOD_ID__/app.db` (preserved across upgrades).
- **Agent-Native Tools**: `tools/schemas.json` + `tools/dispatch.sh` expose `__MOD_PREFIX___list_entries` and `__MOD_PREFIX___save_entry` under the `+__MOD_PREFIX__` tool bundle.
- **Declarative ALP v1 Loop**: `workflows/sample_briefing.loop.json` runs a concurrent FIFO pre-flight stage (`fifo_parallel`) followed by a 200-turn ReAct phase with a JSON verification gate — editable live inside Blue Lodge's **Loop Studio**.
- **XSS-Safe UI**: `ui/panel.js` registers with `window.LodgeModules.register` using `ctx.el`, `ctx.agentName`, `ctx.action`, `ctx.launchTask`, and `ctx.openLoopStudio`.

## Quickstart
```bash
# Audit locally before publishing
python3 ~/blue-lodge/lib/tools/module_audit.py .

# Install into any Blue Lodge node
/app install <git_url_or_gitea/mod-__MOD_ID__>
```
