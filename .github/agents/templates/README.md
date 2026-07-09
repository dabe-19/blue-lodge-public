# Canonical Agent Templates

This folder holds the canonical-static agent templates the bootstrap trio renders into the operator's chosen output folder. Each template is a fully-fleshed `.agent.md` with project-specific facts replaced by `{{PLACEHOLDER}}` tokens that the secretary substitutes from the dossier's `### Tool Inventory` and the blueprint's `## Placeholder Resolutions`.

## Mandatory Canonical Roster (10 agents)

| Agent | Base Template | Notes |
|---|---|---|
| `the-architect` | `the-architect.template.agent.md` | Entry-point planner. Drafts the contract artifact. |
| `dispatcher` | `dispatcher.template.agent.md` | Pipeline orchestrator. Forwards Security/Style flags to george. |
| `quartermaster` | `quartermaster.template.agent.md` | Toolchain / lockfiles / dev scripts / agent inventory. |
| `tester` | `tester.template.agent.md` | End-to-end verification (variant rendered when test harness present). |
| `george` | `george.template.agent.md` | Senior auditor. Invokes the-tyler / the-warden during audit. |
| `the-tyler` | `the-tyler.template.agent.md` | Security & prompt-injection auditor (cross-cutting; invoked by george). |
| `the-warden` | `the-warden.template.agent.md` | Style author/reviewer (cross-cutting; invoked by george). |
| `the-chronicler` | `the-chronicler.template.agent.md` | Documentation steward (post-audit, pre-commit). |
| `git-manager` | `git-manager.template.agent.md` | Conventional commits + push to current branch. |
| `trowel` | `trowel.template.agent.md` | Terminal node. Updates status file. |

## Variant Convention

When a canonical agent's behavior must diverge based on a binary dossier signal, a separate variant template MAY be authored alongside the base and selected by the architect in the blueprint's `## Roster` block via a `Template Variant:` line.

Naming convention if/when a variant is added: `<base>.<variant-axis>.template.agent.md`. Variants are bytewise-distinct files (no `{{#IF}}` blocks); the secretary's substitution remains dumb find-and-replace.

**No variant templates ship in this tier today.** The canonical-base templates listed above are the complete set. Architects who need behavior splits should either (a) absorb the divergence into the blueprint's `### Platform Context` block for that agent, or (b) propose a new variant file in this folder via a doc/template change.

## Placeholder Vocabulary

The secretary substitutes these from the blueprint's `## Placeholder Resolutions` block:

- `{{PROJECT_NAME}}` — project name
- `{{PRIMARY_LANGUAGE}}` — primary language
- `{{BUILD_CMD}}` — exact build command
- `{{BUILD_FLAG_GLOSSARY}}` — flag meanings for BUILD_CMD
- `{{TEST_CMD}}` — exact test command
- `{{TEST_FLAG_GLOSSARY}}` — flag meanings for TEST_CMD
- `{{LINT_CMD}}` — exact lint command
- `{{FORMAT_CMD}}` — exact format command
- `{{RUN_CMD}}` — exact run/serve command
- `{{CONTAINER_STACK_CMD}}` — containerized-stack wrapper command (variants only)
- `{{CONTAINER_STACK_TEARDOWN}}` — teardown command (variants only)
- `{{CONTAINER_HOST_PORTS}}` — `127.0.0.1:port` mappings (variants only)
- `{{STATUS_FILE_PATH}}` — project status file (default `GEORGE.md`)
- `{{STYLE_GUIDE_PATH}}` — project style guide (default `STYLE_GUIDE.md`)
- `{{ARCHITECTURE_VISION_PATH}}` — architecture vision doc (default `docs/architecture_vision.md`)
- `{{CONTRACT_PATH}}` — fixed: `/memories/session/feature_contract.md`
- `{{TOOLING_FILES_GLOB}}` — glob of files quartermaster owns
- `{{DESTRUCTIVE_SCRIPTS_BLACKLIST}}` — paths of destructive scripts agents must not run
- `{{TOOLS_<AGENT_NAME>}}` — per-agent tools list (Tool Floor Table ∩ dossier Tool Inventory)
- `{{LAYER_SPECIALIST_LIST}}` — pre-formatted markdown list of `**Layer** → \`agent\`` lines
- `{{LAYER_HALT_HANDOFFS}}` — pre-formatted YAML block of `Halt — <Layer> Gap` handoffs
- `{{LAYER_REFACTOR_HANDOFFS}}` — pre-formatted YAML block of `Refactor <Layer>` handoffs
- `{{PIPELINE_ORDER}}` — pre-formatted markdown of fixed pipeline steps for this project
- `{{LAYER_SPECIALIST_CONTRACT_LINES}}` — pre-formatted `- **<Layer>**: yes | no` lines for the contract template
- `{{LAYER_SPECIALIST_TOUCHED_LIST}}` — comma-separated list of layer names for prose

After substitution, the secretary verifies zero `{{` tokens remain in the rendered file.

## Tool Floor Table

The architect (`the-trestleboard`) MUST use this table as the starting point for every `{{TOOLS_<AGENT_NAME>}}` resolution. The floor lists the MINIMUM tokens each canonical agent needs to perform its workflow. The architect then reconciles that floor against the dossier's `### Tool Inventory` and appends any project-specific MCP tokens that surfaced in discovery (e.g. `pylance-mcp-server/*` for Python projects, `ms-python.python/*` for Python env management, `docker/*` for containerized stacks). A bootstrap agent's own local tool grant or local write restrictions are NOT evidence about the host session's global tool surface.

**Default tier note:** the floor below assumes a full-context VS Code host. No budget-driven trimming is required; the floor IS the canonical baseline. Architects on this tier should ADD project-specific tokens (MCP servers, browser/UI tooling) rather than removing default tokens. If you find yourself wanting to trim, switch to the `agents_64k/` or `agents_32k/` tier instead.

| Agent | Tool Floor |
|---|---|
| `the-architect` | `vscode/memory`, `vscode/resolveMemoryFileUri`, `vscode/askQuestions`, `vscode/toolSearch`, `execute/runInTerminal`, `execute/getTerminalOutput`, `read`, `agent`, `search`, `web`, `todo` |
| `dispatcher` | `vscode/memory`, `vscode/resolveMemoryFileUri`, `vscode/askQuestions`, `read`, `agent`, `todo` |
| `quartermaster` | `vscode/memory`, `vscode/resolveMemoryFileUri`, `vscode/askQuestions`, `vscode/runCommand`, `vscode/vscodeAPI`, `execute/runInTerminal`, `execute/getTerminalOutput`, `execute/killTerminal`, `read`, `edit`, `search`, `agent`, `web`, `todo` |
| `tester` | `vscode/memory`, `vscode/resolveMemoryFileUri`, `vscode/askQuestions`, `execute/runInTerminal`, `execute/getTerminalOutput`, `execute/killTerminal`, `execute/runTests`, `read`, `agent`, `search`, `todo`, `browser` |
| `george` | `vscode/memory`, `vscode/resolveMemoryFileUri`, `vscode/askQuestions`, `vscode/toolSearch`, `execute/runInTerminal`, `execute/getTerminalOutput`, `read`, `agent`, `search`, `web`, `todo`, `browser` |
| `the-tyler` | `vscode/memory`, `vscode/resolveMemoryFileUri`, `vscode/askQuestions`, `execute/runInTerminal`, `execute/getTerminalOutput`, `read`, `agent`, `search`, `web`, `todo` |
| `the-warden` | `vscode/memory`, `vscode/resolveMemoryFileUri`, `vscode/askQuestions`, `read`, `edit`, `search`, `web`, `todo` (edit scoped via rules to `{{STYLE_GUIDE_PATH}}`) |
| `the-chronicler` | `vscode/memory`, `vscode/resolveMemoryFileUri`, `vscode/askQuestions`, `read`, `edit`, `search`, `web`, `todo` (edit scoped via rules to `*.md` and `{{STATUS_FILE_PATH}}`) |
| `git-manager` | `vscode/memory`, `vscode/askQuestions`, `execute/runInTerminal`, `execute/getTerminalOutput`, `read`, `search` |
| `trowel` | `edit`, `vscode/memory`, `read` (already hardcoded in the template; not subject to substitution) |

### Project-specific MCP tokens (append per dossier signal)

- **Python projects** (when `pyproject.toml` / `requirements.txt` / `*.py` detected): append `pylance-mcp-server/*`, `ms-python.python/getPythonEnvironmentInfo`, `ms-python.python/getPythonExecutableCommand`, `ms-python.python/installPythonPackage`, `ms-python.python/configurePythonEnvironment` to `quartermaster`, `tester`, and any Python-owning layer specialist.
- **Notebook projects** (when `*.ipynb` detected): append `execute/runNotebookCell`, `vscode.mermaid-chat-features/renderMermaidDiagram` to `george` and the analytics/ML layer specialist.
- **Browser/UI projects** (when frontend detected): append `browser` to the UI-owning layer specialist and `george`.
- **Containerized test stack** (when `docker-compose.yml` / `test_env.sh`-equivalent detected): append `execute/killTerminal` to `tester` (already in the floor) and ensure the architect's blueprint embeds the container-stack-up, container-stack-teardown, and host-port-mapping commands into `tester`'s `### Platform Context` block. No dispatcher variant is required.

### MCP server tokens (append when the dossier's `### MCP Servers` lists them)

MCP servers extend the tool surface with namespaced sub-tools (e.g. `playwright/browser_navigate`, `github/create_issue`). The architect MUST grant a `<server>/*` wildcard ONLY when the dossier confirms that server is loaded in the workspace's `.vscode/mcp.json` or user `mcp.json`. NEVER add an MCP token speculatively. See `example.mcp.jsonc` at the repo root for canonical configuration shapes.

- **`playwright/*`** — browser automation MCP (Microsoft `microsoft/playwright-mcp`). Append to `tester` when the dossier shows a frontend layer AND the operator wants real-browser end-to-end coverage. Append to `george` when end-to-end smoke audits cross the UI. Implies the host can launch a headless Chromium; the quartermaster's bootstrap-doctor entry should verify `npx playwright install` has been run.
- **`github/*`** — GitHub MCP (`io.github.github/github-mcp-server`). Append to `git-manager` when the operator wants automated PR creation / issue linking on commit-and-push. Append to `the-chronicler` when changelog entries should be cross-referenced to issues or PRs. Requires a GitHub PAT (or device-flow auth) configured in the host; quartermaster's bootstrap-doctor should fail loudly if the credential is missing.
- **Other write-capable MCP servers** (`filesystem/*`, `memory/*` from anthropic-style memory MCP, `fetch/*`): treat with the same discipline — only append when the dossier proves presence, document the exact sub-tools the agent will use, and prefer narrow per-tool grants over wildcards when the agent only needs one or two operations.

### Forge rule (re-stated for emphasis)

EVERY token written into a `{{TOOLS_*}}` resolution MUST appear in the dossier's `### Tool Inventory` as `present`, `present-via-alias`, or `unverified-in-current-scout-host`. The floor table above defines INTENT — the dossier defines the scout's current evidence. Explicit `absent` means the token is known unavailable and must be omitted via a compatible variant or the architect must halt for re-scout. `unverified-in-current-scout-host` means the scout could not prove availability from its current host and MUST NOT be silently downgraded to `absent`.
