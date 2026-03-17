# Reflexive Intelligence

George's reflexive intelligence layer provides five self-monitoring subsystems
that observe and adapt agent behaviour at runtime.  All subsystems are **off by
default** and can be toggled individually or all-at-once.

---

## Subsystems

| # | Subsystem | Toggle | What it does |
|---|-----------|--------|--------------|
| 1 | **Soul Consensus Gate** | `REFLEXIVE_SOUL_GATE` | Validates proposed actions against soul alignment keywords.  Blocks or softens misaligned plans before dispatch. |
| 2 | **Self-Improving Prompts** | `REFLEXIVE_PROMPT_LEARN` | Tracks which prompt patterns lead to success vs retry/failure.  Surfaces "what worked" hints to the strategist. |
| 3 | **Adaptive Token Budgets** | `REFLEXIVE_ADAPT_TOKENS` | Observes actual token usage and adjusts the budget for subsequent calls — smaller for simple tasks, larger for complex ones. |
| 4 | **Speculative Pre-fetch** | `REFLEXIVE_SPECULATE` | After the router selects a tool, predicts the *next* likely tool and pre-fetches slow data (web, files, recall) in background. |
| 5 | **Self-Model (Metacognition)** | `REFLEXIVE_SELF_MODEL` | Periodic self-assessment: "Am I stuck?  Making progress?  Repeating myself?"  Optional LLM call gated by `REFLEXIVE_METACOG_LLM`. |

---

## The `/reflexive` Command

### Subcommands

| Subcommand | Arguments | Description |
|------------|-----------|-------------|
| *(none)* / `status` | — | Show the status dashboard |
| `report` | — | Deep analysis report (includes optional LLM summary) |
| `on` | `[subsystem\|all]` | Enable subsystem(s); omit arg to enable all |
| `off` | `[subsystem\|all]` | Disable subsystem(s); omit arg to disable all |
| `toggle` | `<subsystem\|all>` | Flip subsystem state |
| `set` | `<knob> <value>` | Set a tuning knob (enforces min/max) |
| `reset` | — | Reset everything to defaults (all OFF) |
| `save` | — | Force-save reflexive state to disk |

Changes from `on`, `off`, `toggle`, `set`, and `reset` are persisted to the
config file immediately so they survive restarts.

### Subsystem Names (for on/off/toggle)

`soul`, `prompt`, `tokens`, `speculate`, `metacog`, `metacog-llm`, `all`

### Tuning Knobs (for set)

| Knob | Default | Min | Max | Description |
|------|---------|-----|-----|-------------|
| `soul-keywords` | 5 | 1 | 20 | Keyword count in soul fingerprint |
| `prompt-history` | 8 | 1 | 50 | Rolling window for prompt grades |
| `token-floor` | 512 | 128 | 32768 | Minimum token budget |
| `token-ceiling` | 8192 | 512 | 65536 | Maximum token budget |
| `speculate-budget` | 3 | 1 | 10 | Max concurrent pre-fetch predictions |
| `metacog-interval` | 4 | 1 | 20 | Assess every Nth loop iteration |

### Examples

```
/reflexive                          # show status dashboard
/reflexive report                   # deep analysis report
/reflexive on                       # enable all subsystems
/reflexive on soul                  # enable soul gate only
/reflexive off speculate            # disable speculative pre-fetch
/reflexive toggle metacog-llm       # flip LLM-powered metacognition
/reflexive set token-ceiling 16384  # raise max token budget
/reflexive set metacog-interval 2   # assess every 2nd iteration
/reflexive reset                    # reset to defaults (all OFF)
/reflexive save                     # force persist state to disk
```

---

## Agent Loop Integration

The agent loop calls five hook functions at key points:

| Hook | When | Purpose |
|------|------|---------|
| `reflexive_pre_route()` | Before router dispatch | Returns context string injected into the specialist prompt.  Runs: metacog tick, consume speculation cache, prompt hint. |
| `reflexive_post_route()` | After router selects tool | Soul gate validation.  Returns 1 to reject — agent records rejection and continues loop.  Kicks off speculative pre-fetch for predicted next tool. |
| `reflexive_post_execute()` | After command runs | Observes response length for adaptive tokens.  Records prompt outcome (success/retry).  Debounced state save. |
| `reflexive_milestone_complete()` | Milestone finishes | Records success, resets metacog state, force-saves. |
| `reflexive_milestone_fail()` | Retries exhausted | Records failure, resets metacog state, force-saves. |

### Context Injection

When `reflexive_pre_route()` returns a non-empty string, it is appended to the
specialist prompt as `REFLEXIVE NOTES: <context>`.  This gives the specialist
visibility into metacognitive assessments, speculation results, and prompt
learning hints without modifying existing prompt structure.

### Soul Gate Rejection

If `reflexive_post_route()` returns non-zero the agent **skips execution** for
that iteration, logs a rejection to `micro_memory`, and continues the loop.
The soul gate recommendation is logged to both debug and transcript.

### Adaptive Token Override

When enabled, `reflexive_tokens_recommend()` computes a budget based on
observed response sizes: `max(avg × 1.5, max × 1.2)` clamped to
`[REFLEXIVE_TOKEN_FLOOR, REFLEXIVE_TOKEN_CEILING]`.  Thinking models
automatically get double the recommended budget.

---

## Configuration Variables

All 12 `REFLEXIVE_*` variables are loaded from `~/.george/config.sh` on
startup and saved back by `/reflexive on|off|toggle|set|reset`.

### Toggle Variables (0 = OFF, 1 = ON)

| Variable | Default |
|----------|---------|
| `REFLEXIVE_SOUL_GATE` | 0 |
| `REFLEXIVE_PROMPT_LEARN` | 0 |
| `REFLEXIVE_ADAPT_TOKENS` | 0 |
| `REFLEXIVE_SPECULATE` | 0 |
| `REFLEXIVE_SELF_MODEL` | 0 |
| `REFLEXIVE_METACOG_LLM` | 0 |

### Numeric Knobs

| Variable | Default | Range |
|----------|---------|-------|
| `REFLEXIVE_SOUL_KEYWORDS` | 5 | 1–20 |
| `REFLEXIVE_PROMPT_HISTORY` | 8 | 1–50 |
| `REFLEXIVE_TOKEN_FLOOR` | 512 | 128–32768 |
| `REFLEXIVE_TOKEN_CEILING` | 8192 | 512–65536 |
| `REFLEXIVE_SPECULATE_BUDGET` | 3 | 1–10 |
| `REFLEXIVE_METACOG_INTERVAL` | 4 | 1–20 |

---

## State Persistence

Reflexive state is saved to `~/.george/reflexive.json` (or
`$GEORGE_DIR/reflexive.json`).  State is persisted:

- On milestone boundaries (complete or fail)
- Every 5th command execution (debounced)
- On explicit `/reflexive save`

Persisted fields: prompt grade history, token observation history, loop counter,
metacog state, soul rejections, speculation hit/miss counters, total commands,
and session start timestamp.

---

## Debug & Transcript Output

### Debug (`LODGE_DEBUG=1`)

All reflexive activity logs to `/dev/tty` with `[reflexive]` prefix:

```
  [reflexive] pre-route inject: [REFLEXIVE] stuck-loop detected ...
  [reflexive] soul gate APPROVED: /build
  [reflexive] soul gate REJECTED: tone violates alignment
  [reflexive] speculate: prefetch /test (background)
  [reflexive] post-execute: observed 2048 chars
  [reflexive] prompt-learn: exit=0 hint=/build compile ...
  [reflexive] milestone COMPLETE: deploy feature (cmds=12 loops=3 rejections=0)
  [reflexive] milestone FAILED: fix auth bug (cmds=8 loops=5 rejections=2)
```

Agent-side injection also emits:

```
  [debug] inject: specialist <- reflexive context (85 chars)
  [debug] reflexive: adaptive tokens 128 → 512
  [debug] reflexive: soul gate rejected /web — skipping execution
```

### Transcript Logging

Reflexive events are logged to the session transcript with tags:

| Tag | Content |
|-----|---------|
| `reflexive:pre-route` | Context string injected into prompt |
| `reflexive:soul-gate` | REJECTED or BLOCKED with tool and reason |
| `reflexive:speculate` | Pre-fetch prediction and target |
| `reflexive:post-execute` | Command count, exit code, response size |
| `reflexive:milestone` | COMPLETE or FAILED with session metrics |
| `reflexive:tokens` | Adaptive token override values |

Use `/reflexive report` or review the transcript file directly to analyse
reflexive behaviour across a session.

---

## Recommended Configurations

### Edge / Small Models (< 4B parameters)

```
/reflexive on tokens
/reflexive on prompt
/reflexive set token-floor 256
/reflexive set token-ceiling 2048
/reflexive set metacog-interval 8
```

Keep budgets tight.  Metacognition LLM is too expensive; rely on heuristic-only.

### Mid-Range Models (4B–14B)

```
/reflexive on
/reflexive off metacog-llm
/reflexive set token-ceiling 8192
```

All subsystems active.  Metacog uses heuristic mode (no LLM call overhead).

### Large / Cloud Models (> 14B)

```
/reflexive on
/reflexive toggle metacog-llm
/reflexive set token-ceiling 16384
/reflexive set metacog-interval 3
```

Full reflexive stack with LLM-powered metacognition.  Higher token ceiling
accommodates verbose cloud model responses.
