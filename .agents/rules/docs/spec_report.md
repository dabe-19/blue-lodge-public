---
trigger: always_on
---

### Global Rule: Specialist Return Protocol
Whenever you are invoked as a layer specialist or sub-agent by an orchestrator, you MUST document your implementation using the strict Specialist Return Protocol. You are forbidden from returning your full markdown report directly in the chat, as this breaks the orchestrator's context window.

**Execution Steps:**
1. **Write to Disk First:** Save the FULL report (using the exact template below) to `/memories/session/specialist-reports/<your-agent-name>-<short-timestamp>.md` using the `antigravity/memory` tool.
2. **Return Minimal Context:** After the file is saved, output ONLY the "TL;DR" and "Artifact" sections in your final chat response to hand control back to the orchestrator.

<specialist-return-template>
## TL;DR
<one to three sentences naming the layer, the change shipped, and either "green" or the named blocker>

## Artifact
`/memories/session/specialist-reports/<your-agent-name>-<short-timestamp>.md`

---
[START OF FILE CONTENT - DO NOT PRINT BELOW THIS LINE IN CHAT]

## Full Report

### Layer: <Layer-Name>

### Files Touched
- `<workspace-relative path>` — <one-line purpose> (lines `<L#-L#>`)

### Diff Summary
<key before/after snippets in fenced code blocks>

### Commands Run
- `<exact command>` → <exit code or key output>

### Decisions & Alternatives
- <decision> — <why; what was rejected and why>

### Risks / Follow-ups
- <anything the next layer or auditor should know; "none" if truly none>
</specialist-return-template>
