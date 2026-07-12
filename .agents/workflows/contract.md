### Feature Overview
Implement loop recovery and process isolation guards to protect George's memory state and optimize token efficiency under L2 failure escalation:
1. **Atomic & Validated JSON State Updates**: Prevent state corruption by verifying JSON syntax via `jq` before writing memory files.
2. **Concurrency Lock Gating**: Implement a lockfile inside `lodge` to prevent duplicate task loops from executing concurrently in the same workspace.
3. **Specialist Action Log Compaction**: Reduce prompt size and prevent LLM timeouts during L2 escalation by dynamically limiting the action log injected into the specialist after repeated failures.

### Layer Changes

#### [MODIFY] [lib/memory.sh](file:///home/wsl-ops/blue-lodge/lib/memory.sh)
- Implement a `memory_json_commit` validation function to verify JSON syntax before renaming temp files.

#### [MODIFY] [lib/agent.sh](file:///home/wsl-ops/blue-lodge/lib/agent.sh)
- Replace standard `jq ... > "$tmp" && mv "$tmp" "$file"` occurrences with `jq ... > "$tmp" && memory_json_commit "$tmp" "$file"`.
- Refactor `_micro_serialize` to support custom output limits, and dynamically compact the action log size to 3 items when consecutive failures reach 3+.

#### [MODIFY] [lodge](file:///home/wsl-ops/blue-lodge/lodge)
- Implement process-level lock gating (`.lodge.lock`) at startup and release it in `_lodge_exit_cleanup`.

#### [MODIFY] [tests/test_memory_tier.sh](file:///home/wsl-ops/blue-lodge/tests/test_memory_tier.sh)
- Add unit tests validating `memory_json_commit` JSON protection and `_micro_serialize` compaction scaling.

### Scope Boundaries
Focuses strictly on internal state stability, lock safety, and specialist prompt limits. No provider endpoints or capability locks are modified.

### Touched Layers (Handoff Routing)
- **core-specialist**: yes — memory state validation and serialization helpers in `lib/memory.sh` and `lib/agent.sh`.
- **commands-specialist**: yes — process lock gates in the main `lodge` entrypoint script.
- **ui-specialist**: no — no UI rendering modifications.
- **tests-specialist**: yes — unit test validations.

### Tooling Layer (Provisioning)
- **Tooling**: no

### Functional Verification
- **Verification**: yes — sandbox execution run.

### Security
- **Security**: no

### Style
- **Style**: no
