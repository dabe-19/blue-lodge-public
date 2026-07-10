# Canonical Agent Templates

This folder holds the canonical-static agent templates the bootstrap trio renders into the operator's chosen output folder. Each template is a fully-fleshed `.agent.md` with project-specific facts replaced by `{{PLACEHOLDER}}` tokens that the secretary substitutes from the blueprint's `## Placeholder Resolutions`.

## Mandatory Canonical Roster (10 agents)

| Agent | Base Template | Notes |
|---|---|---|
| `the-architect` | `the-architect.template.agent.md` | Entry-point planner. Drafts the contract artifact. |
| `dispatcher` | `dispatcher.template.agent.md` | Pipeline orchestrator. Calls layer specialists in order. |
| `quartermaster` | `quartermaster.template.agent.md` | Toolchain / lockfiles / dev scripts / agent inventory. |
| `tester` | `tester.template.agent.md` | End-to-end verification (omit when no test harness). |
| `george` | `george.template.agent.md` | Senior auditor. Invokes the-tyler / the-warden during audit. |
| `the-tyler` | `the-tyler.template.agent.md` | Security & prompt-injection auditor (cross-cutting; invoked by george). |
| `the-warden` | `the-warden.template.agent.md` | Style author/reviewer (cross-cutting; invoked by george). |
| `the-chronicler` | `the-chronicler.template.agent.md` | Documentation steward (post-audit, pre-commit). |
| `git-manager` | `git-manager.template.agent.md` | Conventional commits + push to current branch. |
| `trowel` | `trowel.template.agent.md` | Terminal node. Updates status file. |

## Antigravity Workflow Format

These templates use the Antigravity workflow format:
- **No `handoffs:` in frontmatter.** Workflow chaining is done inline using `call /workflow-name` instructions in the `<workflow>` block.
- **No `hooks:` in frontmatter.** Antigravity does not support frontmatter hooks.
- **Description must be ≤250 characters.** Content must be ≤12,000 characters.

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
- `{{STATUS_FILE_PATH}}` — project status file (default `GEORGE.md`)
- `{{STYLE_GUIDE_PATH}}` — project style guide (default `STYLE_GUIDE.md`)
- `{{ARCHITECTURE_VISION_PATH}}` — architecture vision doc (default `docs/architecture_vision.md`)
- `{{CONTRACT_PATH}}` — fixed: `/memories/session/feature_contract.md`
- `{{TOOLING_FILES_GLOB}}` — glob of files quartermaster owns
- `{{DESTRUCTIVE_SCRIPTS_BLACKLIST}}` — paths of destructive scripts agents must not run

- `{{LAYER_SPECIALIST_LIST}}` — pre-formatted markdown list of `**Layer** → \`agent\`` lines
- `{{PIPELINE_ORDER}}` — pre-formatted markdown of fixed pipeline steps
- `{{LAYER_SPECIALIST_CONTRACT_LINES}}` — pre-formatted `- **<Layer>**: yes | no` lines

After substitution, the secretary verifies zero `{{` tokens remain.


