### Feature Overview
Implement a tiered memory management system for George consisting of a live completed milestone LRU cache inside `GEORGE.md` and a long-term SQLite FTS5 milestone archive inside the recall database to prevent context window saturation while maintaining historical continuity.

### Layer Changes

#### Core Engine (`lib/memory.sh`, `lib/recall.sh`)
- Register `milestone_archive` in `recall.sh` as a dynamic source.
- Add `recall_archive_milestone()` to persist completed milestones directly into the SQLite database.
- Add `recall_search_milestones()` to search the archived milestones using BM25 ranking.
- Modify `memory_compact()` to trim milestones exceeding the configured limit (e.g., last 5) from `GEORGE.md` without losing them (already saved in SQLite).

#### Agent Loop (`lib/agent.sh`)
- Modify the cross-task sieve to query `milestone_archive` in SQLite at task start or milestone planning.
- Inject matched archived milestones directly into the strategist's context prompt as a dedicated prior-context block.

#### Verification/Tests (`tests/`)
- Add a new unit test suite `tests/test_memory_tier.sh` to verify archiving, compaction, and search-based injection.

### Scope Boundaries
This feature focuses strictly on archiving completed milestones and retrieving them lexically. It does not introduce semantic vector embeddings or external database dependencies.

### Touched Layers (Handoff Routing)
- **core-specialist**: yes — implementing memory compaction and SQLite FTS milestone archiving.
- **commands-specialist**: no — no slash command parser modifications.
- **ui-specialist**: no — no UI rendering modifications.
- **tests-specialist**: yes — creating automated test suite for memory tiers.

### Tooling Layer (Provisioning)
- **Tooling**: no

### Functional Verification
- **Verification**: yes — test run via `tests/run_all.sh`.

### Security
- **Security**: no

### Style
- **Style**: no
