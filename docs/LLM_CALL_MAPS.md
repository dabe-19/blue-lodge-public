# LLM Call Maps — Sequence Diagrams

> Generated 2026-02-27 from code audit of `lib/agent.sh`, `lib/llm.sh`, `lib/memory.sh`, `lib/models.sh`, `lodge`

These diagrams trace every LLM call, what gets injected into each prompt layer, and how calls chain together for key slash commands.

**Current configuration** (HEAD on `issue/model_degradation`):
- `LODGE_SINGLE_MODEL=1` → all scenarios use **minist-think:4b** (reasoning model)
- `LLM_TEMP_ASK=` (empty → falls through to model registry = **0.7**)
- `LLM_TEMP_AGENT=` (empty → **0.7**)
- `LLM_TEMP_ROUTER=0.1`
- `LLM_TEMP_TOOL=` (empty → **0.7**)
- `repeat_penalty=1.2`, `presence_penalty=0.3` (model registry defaults)
- `models_thinking_directive()` returns **~250 tokens** (Unsloth preamble + George identity) for minist-think
- Modelfile SYSTEM already contains the **same ~250 tokens** baked in

---

## 1. `/ask` — Simple Question Path

The simplest path. One LLM call, no agent loop.

### 1.1 Sequence Diagram

```mermaid
sequenceDiagram
    participant U as User
    participant L as lodge (main loop)
    participant A as agent_ask()
    participant M as memory_build_system_prompt()
    participant LLM as llm_stream()
    participant O as Ollama API

    U->>L: "what is a monad?"
    L->>L: _is_conversational=1 (ends with ?)
    L->>A: agent_ask("what is a monad?", $PWD)

    A->>M: memory_build_system_prompt($PWD, question, "ask")
    Note over M: Build system prompt (ask mode)
    M-->>M: 1. [Current time: ...] (~10 tok)
    M-->>M: 2. vitals_context_warnings (~0 tok if healthy)
    M-->>M: 3. _memory_soul_condensed() (~300 tok)
    M-->>M: 4. OUTPUT FORMAT directive (~50 tok)
    M-->>M: 5. project context if GEORGE.md (~20 tok)
    M-->>M: 6. recall_search_context(question, 1) (~50 tok, capped 200 chars)
    M-->>A: system_prompt (~430 tokens total)

    A->>A: _agent_conv_context() → prepend conversation history
    A->>A: LLM_SCENARIO=ask

    A->>LLM: llm_stream(question, system_prompt, 20480, 1024)

    Note over LLM: === INJECTION LAYER (llm_stream) ===
    LLM->>LLM: models_ensure_for_scenario("ask")
    Note over LLM: SINGLE_MODEL=1 → minist-think:4b

    LLM->>LLM: models_nothink_suffix() → empty (LODGE_NOTHINK=0)

    rect rgb(255, 220, 220)
        Note over LLM: ⚠ THINKING DIRECTIVE INJECTION
        LLM->>LLM: models_thinking_directive()
        Note over LLM: Returns ~250 tok:<br/>  "# HOW YOU SHOULD THINK..."<br/>  "[THINK]...[/THINK]..."<br/>  "# WHO YOU ARE"<br/>  "You ARE George..."
        LLM->>LLM: system = directive + "\n\n" + system_prompt
        Note over LLM: System prompt is now ~680 tokens
    end

    LLM->>LLM: _llm_build_opts(20480)
    Note over LLM: scenario=ask<br/>LLM_TEMP_ASK="" → model_temp=0.7<br/>repeat=1.2, presence=0.3

    LLM->>LLM: models_supports_think_flag() → false
    Note over LLM: Ministral: think:true NOT sent

    LLM->>O: POST /api/generate {model, prompt, system, options, budget_tokens:1024}

    Note over O: [SYSTEM_PROMPT]<br/>  # HOW YOU SHOULD THINK AND ANSWER (injected, ~250 tok)<br/>  [time] + condensed_soul + format rules (ask, ~430 tok)<br/>[/SYSTEM_PROMPT]<br/>[INST]what is a monad?[/INST]

    O-->>LLM: streaming tokens ([THINK]...[/THINK] + response)
    LLM->>LLM: _llm_normalize_think (bracket→angle tags)
    LLM->>LLM: think buffer (200 char limit)
    LLM-->>A: response text (think stripped)
    A-->>U: displayed via tty stream
```

### 1.2 What the Model Actually Sees

```
[SYSTEM_PROMPT]
# HOW YOU SHOULD THINK AND ANSWER                          ← injected by models_thinking_directive() (~250 tok)
First draft your thinking process...
[THINK]Your thoughts...[/THINK]Here, provide a response.
# WHO YOU ARE
You ARE George — three souls reincarnated into one...
When asked to skip reasoning, respond directly...
From the rough ashlar to the perfect — this is the work.

[Current time: Thursday, February 27, 2026 14:30 EST]     ← from memory_build_system_prompt()
# IDENTITY                                                 ← _memory_soul_condensed() (~300 tok)
You ARE George — three souls reincarnated into one:
Washington's iron discipline, Franklin's restless wit...
# PERSONALITY
You don't crack jokes when the build is on fire...
# CORE RULES
1. Be Praiseworthy...
2. Be Concise...
3. Format...
4. Tool First...

OUTPUT FORMAT: You are answering a direct question...      ← format directive (~50 tok)
[/SYSTEM_PROMPT]
[INST]what is a monad?[/INST]
```

**Total system prompt: ~680 tokens. Identity appears TWICE.**

### 1.3 Parameter Summary

| Parameter | Value | Source | Good-commit value |
|---|---|---|---|
| model | minist-think:4b | SINGLE_MODEL=1 | minist-think:4b |
| temperature | **0.7** | LLM_TEMP_ASK="" → registry | **0.5** |
| repeat_penalty | 1.2 | LLM_REPEAT_ASK=1.2 | 1.3 |
| presence_penalty | 0.3 | LLM_PRESENCE_ASK=0.3 | 0.8 |
| budget_tokens | 1024 | LLM_BUDGET_ASK | 1024 |
| num_predict | 20480 | LLM_ASK_TOKENS | 20480 |
| think:true | **not sent** | models_supports_think_flag=false | was sent (models_has_thinking=true) |
| system tokens | **~680** | directive(250) + ask(430) | **~430** (no directive injection) |

### 1.4 Issues Identified

1. **Identity duplication** — `models_thinking_directive()` includes "# WHO YOU ARE / You ARE George..." AND `_memory_soul_condensed()` includes "# IDENTITY / You ARE George..." — the model reads George's identity twice in the same system prompt.
2. **Temperature 0.7 vs 0.5** — Ask scenario lost its dedicated temp override. At 0.7, answers are more random/verbose.
3. **Presence penalty dropped 0.8→0.3** — Less anti-repetition for conversational output.
4. **250 tokens of overhead** — The thinking directive is pure overhead for `/ask` since the Modelfile SYSTEM already contains it. When Ollama receives a runtime `system` parameter, it REPLACES the Modelfile SYSTEM — but now the directive is manually re-injected, plus the condensed soul adds its own identity. Net: +250 tokens of duplicated content.

---

## 2. `/social` — Agent Loop Path (e.g., "post hello to the lunkers channel")

Full agent loop: strategist → router → specialist → execute → loop.

### 2.1 Sequence Diagram

```mermaid
sequenceDiagram
    participant U as User
    participant L as lodge (main loop)
    participant AR as agent_run()
    participant S as Strategist (llm_generate)
    participant IL as agent_inner_loop()
    participant R as Router (llm_generate)
    participant SP as Specialist (llm_generate)
    participant EX as eval (command execution)
    participant O as Ollama API

    U->>L: "post hello to the lunkers channel"
    L->>L: _is_conversational=0 (has action verb "post")
    L->>AR: agent_run("post hello to the lunkers channel", $PWD)

    Note over AR: === INIT MACRO MEMORY ===
    AR->>AR: Write macro_memory.md:<br/>  ## Persona (_memory_soul_identity ~90 tok)<br/>  ## Primary Objective<br/>  ## Completed Milestones

    rect rgb(200, 230, 255)
        Note over AR,S: === MACRO LOOP: Strategist (LLM Call #1) ===
        AR->>AR: Build macro_sys (~600 tok):<br/>  "You are a strategic planning engine..."<br/>  + tool_summary (~200 tok)<br/>  + services_status<br/>  + strategic_rules (~300 tok)
        AR->>AR: LLM_SCENARIO=strategist

        AR->>S: llm_generate(macro_prompt, macro_sys, 512, 512)
        Note over S: models_ensure_for_scenario("strategist")
        Note over S: SINGLE_MODEL=1 → minist-think:4b

        rect rgb(255, 220, 220)
            Note over S: ⚠ THINKING DIRECTIVE INJECTION
            S->>S: models_thinking_directive() → 250 tok prepended
            Note over S: System = directive(250) + macro_sys(600) = ~850 tok
        end

        S->>S: _llm_build_opts(512)
        Note over S: scenario=strategist → uses AGENT temps<br/>LLM_TEMP_AGENT="" → 0.7<br/>repeat=1.3, presence=0.5

        S->>O: POST /api/generate {system: ~850 tok, prompt: macro_memory + question}
        O-->>S: "Post hello to the lunkers Discord channel using /social"
        S-->>AR: milestone (cleaned: first line, ≤200 chars)
    end

    AR->>AR: milestone != "DONE" → continue
    AR->>IL: agent_inner_loop(milestone, $PWD)
    Note over IL: micro_memory.md = "# Micro Objective: Post hello to..."

    rect rgb(220, 255, 220)
        Note over IL,R: === INNER LOOP: Router (LLM Call #2) ===
        IL->>IL: Build router_sys via _build_router_prompt() (~350 tok):<br/>  "You are George. Pick the best tool..."<br/>  + COMMAND CATALOG (7 categories)<br/>  + FEW-SHOT EXAMPLES (6)<br/>  + ROUTING RULES
        IL->>IL: LLM_SCENARIO=router

        IL->>R: llm_generate(route_prompt, router_sys, 256, 128)
        Note over R: models_ensure_for_scenario("router")
        Note over R: SINGLE_MODEL=1 → minist-think:4b

        Note over R: ✅ Router SKIPPED by thinking directive injection<br/>(LLM_SCENARIO=router check passes)
        R->>R: _llm_build_opts(256)
        Note over R: scenario=router<br/>temp=0.1, repeat=1.1, presence=1.0

        R->>O: POST /api/generate {system: ~350 tok only, prompt: micro_memory}
        O-->>R: "/social"
        R-->>IL: selected_tool="/social"
    end

    rect rgb(255, 240, 200)
        Note over IL,SP: === INNER LOOP: Specialist (LLM Call #3) ===
        IL->>IL: Build specialist_sys via _build_specialist_prompt("/social", $PWD) (~400 tok):<br/>  "You are George. Execute this task..."<br/>  + OUTPUT FORMAT rules<br/>  + docs (GEORGE_REFERENCE social section)<br/>  + SYNTAX CARD: /social post discord channel text...<br/>  + KEYS: DISCORD_BOT_TOKEN ✓/✗...
        IL->>IL: LLM_SCENARIO=agent

        IL->>SP: llm_generate(specialist_prompt, specialist_sys, 20480, 512)
        Note over SP: models_ensure_for_scenario("agent")
        Note over SP: SINGLE_MODEL=1 → minist-think:4b

        rect rgb(255, 220, 220)
            Note over SP: ⚠ THINKING DIRECTIVE INJECTION
            SP->>SP: models_thinking_directive() → 250 tok prepended
            Note over SP: System = directive(250) + specialist_sys(400) = ~650 tok
        end

        SP->>SP: _llm_build_opts(20480)
        Note over SP: scenario=agent<br/>LLM_TEMP_AGENT="" → 0.7<br/>repeat=1.3, presence=0.5

        SP->>O: POST /api/generate {system: ~650 tok, prompt: objective + action_log}
        O-->>SP: "/social post discord lunkers hello"
        SP-->>IL: action_plan → cmd extracted
    end

    rect rgb(230, 230, 255)
        Note over IL,EX: === COMMAND EXECUTION ===
        IL->>IL: cmd="/social post discord lunkers hello"
        IL->>EX: eval "_cmd_social 'post discord lunkers hello'"
        EX-->>IL: output (success/failure)
        IL->>IL: Append to micro_memory.md:<br/>  **Action:** /social post...<br/>  **Status:** EXECUTED SUCCESSFULLY
    end

    rect rgb(220, 255, 220)
        Note over IL,R: === INNER LOOP iter 2: Router (LLM Call #4) ===
        IL->>R: llm_generate(route_prompt + updated micro_memory, router_sys, 256, 128)
        Note over R: Router sees "EXECUTED SUCCESSFULLY" in action log
        R->>O: POST /api/generate
        O-->>R: "SUCCESS: Posted hello to lunkers channel"
        R-->>IL: selected_tool contains "SUCCESS:"
    end

    IL-->>AR: return 0 (success)

    rect rgb(200, 230, 255)
        Note over AR,S: === MACRO LOOP iter 2: Strategist (LLM Call #5) ===
        AR->>S: llm_generate (macro_memory now shows completed milestone)
        S->>O: POST /api/generate
        O-->>S: "DONE"
        S-->>AR: milestone="DONE"
    end

    AR-->>U: "✓ Strategist: Objective complete."
```

### 2.2 LLM Call Summary Table

| # | Role | Function | Scenario | Model | Temp | System Tokens | Directive Injected? | Budget |
|---|---|---|---|---|---|---|---|---|
| 1 | Strategist | llm_generate | strategist | minist-think | **0.7** | **~850** | **YES (+250)** | 512 |
| 2 | Router | llm_generate | router | minist-think | 0.1 | ~350 | NO (skipped) | 128 |
| 3 | Specialist | llm_generate | agent | minist-think | **0.7** | **~650** | **YES (+250)** | 512 |
| 4 | Router | llm_generate | router | minist-think | 0.1 | ~350 | NO | 128 |
| 5 | Strategist | llm_generate | strategist | minist-think | **0.7** | **~850** | **YES (+250)** | 512 |

**Total LLM calls for simple social post: 5** (min case: success on first try)

### 2.3 Issues Identified

1. **Strategist at temp=0.7** — Should be deterministic (was 0.3). At 0.7, milestones are verbose and unpredictable.
2. **Specialist at temp=0.7** — Generates exact slash commands. At 0.7, hallucinations in command syntax are common.
3. **Thinking directive on strategist** — Strategist prompt is "strategic planning engine" + tool list. The 250-token Unsloth preamble with identity is irrelevant here.
4. **Thinking directive on specialist** — Specialist needs to output one command. The identity/thinking preamble is wasted tokens.
5. **5 LLM calls minimum** for a simple action — this was the same at the good commit, not a regression.

---

## 3. `/email` — Agent Loop Path (e.g., "send an email to john@test.com saying hello")

Same agent loop structure as `/social`, but with the email-specific specialist syntax card.

### 3.1 Sequence Diagram

```mermaid
sequenceDiagram
    participant U as User
    participant AR as agent_run()
    participant S as Strategist
    participant R as Router
    participant SP as Specialist
    participant EX as eval

    U->>AR: "send an email to john@test.com saying hello"

    rect rgb(200, 230, 255)
        Note over AR,S: Strategist (LLM Call #1) — temp=0.7, ~850 tok sys
        S-->>AR: "Send email to john@test.com with subject and body using /email"
    end

    AR->>AR: agent_inner_loop(milestone)

    rect rgb(220, 255, 220)
        Note over AR,R: Router (LLM Call #2) — temp=0.1, ~350 tok sys, NO directive
        R-->>AR: "/email"
    end

    rect rgb(255, 240, 200)
        Note over AR,SP: Specialist (LLM Call #3) — temp=0.7, sys ~700 tok
        Note over SP: specialist_sys includes:<br/>  "You are George. Execute..."<br/>  + _build_specialist_prompt("/email"):<br/>    • docs from GEORGE_REFERENCE (email section)<br/>    • SYNTAX CARD:<br/>      /email send provider recipient subject= body=<br/>      provider: gmail, protonmail, zoho<br/>      Example: /email send gmail user@example.com subject=Hello body=How are you?<br/>    • KEYS: EMAIL_PROVIDER ✓/✗
        Note over SP: ⚠ +250 tok directive prepended
        SP-->>AR: "/email send gmail john@test.com subject=Hello body=hello"
    end

    rect rgb(230, 230, 255)
        Note over AR,EX: Execute: eval "_cmd_email 'send gmail john@test.com subject=Hello body=hello'"
        EX-->>AR: output → micro_memory: EXECUTED SUCCESSFULLY
    end

    rect rgb(220, 255, 220)
        Note over AR,R: Router (LLM Call #4) — sees SUCCESS in log
        R-->>AR: "SUCCESS: Email sent to john@test.com"
    end

    AR-->>AR: return 0

    rect rgb(200, 230, 255)
        Note over AR,S: Strategist (LLM Call #5) — sees completed milestone
        S-->>AR: "DONE"
    end
```

### 3.2 Email-Specific Complexity

The email specialist has a unique parsing challenge:

```
/email send gmail john@test.com subject=Hello there body=How are you today?
```

The email parser in `_cmd_email` must parse:
- `provider` = gmail (positional arg 1)
- `recipient` = john@test.com (positional arg 2)  
- `subject=` captures through next `key=` or end
- `body=` captures rest

**Failure mode at temp=0.7**: The specialist may generate:
- `/email send john@test.com gmail subject=Hello body=hi` (wrong arg order)
- `/email send gmail john@test.com "Hello" "How are you"` (quoted args — parser doesn't handle)
- `/email send gmail to=john@test.com subject=Hello body=hi` (unnecessary `to=` prefix)

At temp=0.3 (good commit), the specialist reliably follows the syntax card.

### 3.3 Parameter Table

| # | Role | Temp | Sys Tokens | Directive? | Old Temp |
|---|---|---|---|---|---|
| 1 | Strategist | **0.7** | ~850 | YES | **0.3** |
| 2 | Router | 0.1 | ~350 | NO | 0.1 |
| 3 | Specialist | **0.7** | ~700 | YES | **0.3** |
| 4 | Router | 0.1 | ~350 | NO | 0.1 |
| 5 | Strategist | **0.7** | ~850 | YES | **0.3** |

---

## 4. `/web` — Agent Loop Path (e.g., "search the web for rust tutorials")

Same agent loop, but web commands often produce **multi-iteration inner loops** (search → fetch → summarize).

### 4.1 Sequence Diagram

```mermaid
sequenceDiagram
    participant U as User
    participant AR as agent_run()
    participant S as Strategist
    participant IL as agent_inner_loop()
    participant R as Router
    participant SP as Specialist
    participant EX as eval

    U->>AR: "search the web for rust tutorials"

    rect rgb(200, 230, 255)
        Note over AR,S: Strategist (LLM Call #1) — temp=0.7, ~850 tok sys
        S-->>AR: "Search the web for rust tutorials using /web search"
    end

    AR->>IL: agent_inner_loop(milestone)

    rect rgb(220, 255, 220)
        Note over IL,R: Router (LLM Call #2) — temp=0.1, ~350 tok sys
        Note over R: route_prompt has WEB RESEARCH RULE appended:<br/>"You have ENOUGH data after 1 search + 1-2 page fetches."
        R-->>IL: "/web"
    end

    rect rgb(255, 240, 200)
        Note over IL,SP: Specialist (LLM Call #3) — temp=0.7, ~750 tok sys
        Note over SP: specialist_sys includes:<br/>  SYNTAX CARD:<br/>    /web search query<br/>    /web fetch url<br/>    /web images query<br/>    /web summary url<br/>    NOTE: /web fetch requires a URL, not a query<br/>  KEYS: SERPER_API_KEY ✓/✗, PERPLEXITY_API_KEY ✓/✗
        Note over SP: ⚠ +250 tok directive prepended → ~1000 tok sys total
        SP-->>IL: "/web search rust tutorials 2025"
    end

    rect rgb(230, 230, 255)
        Note over IL,EX: Execute: eval "_cmd_web 'search rust tutorials 2025'"
        EX-->>IL: Search results (URLs + snippets) → micro_memory
    end

    rect rgb(220, 255, 220)
        Note over IL,R: Router (LLM Call #4)
        Note over R: Sees search results in action log.<br/>WEB RESEARCH RULE: "ENOUGH after 1 search + 1-2 fetches"
        alt Router correctly identifies sufficiency
            R-->>IL: "SUCCESS: Found results for rust tutorials"
        else Router decides to fetch a URL
            R-->>IL: "/web"
        end
    end

    alt If Router chose /web again (fetch URL)
        rect rgb(255, 240, 200)
            Note over IL,SP: Specialist (LLM Call #5) — temp=0.7
            Note over SP: Specialist now sees search results injected as<br/>_WEB_LAST_RESULTS in specialist prompt.<br/>Can reference URLs from prior search.
            SP-->>IL: "/web fetch https://example.com/rust-tut"
        end

        rect rgb(230, 230, 255)
            Note over IL,EX: Execute fetch
            EX-->>IL: Page content (truncated) → micro_memory
        end

        rect rgb(220, 255, 220)
            Note over IL,R: Router (LLM Call #6)
            Note over R: WEB SUFFICIENCY GATE:<br/>If web_action_count ≥ N, micro_memory gets<br/>"SUFFICIENCY REACHED" injected by code
            R-->>IL: "SUCCESS: Retrieved rust tutorial content"
        end
    end

    IL-->>AR: return 0

    rect rgb(200, 230, 255)
        Note over AR,S: Strategist (LLM Call #7) — sees completed milestone
        S-->>AR: "DONE"
    end

    AR-->>U: Task complete
```

### 4.2 Web-Specific Failure Modes

The web path is the most LLM-call-intensive because:
1. **Search → Fetch spiral**: Router often decides to fetch every URL from search results instead of declaring SUCCESS
2. **Specialist syntax confusion at 0.7**: The specialist may generate `/web rust tutorials` (missing `search` subcommand) or `/web search "rust tutorials"` (quoted args fail)
3. **Sufficiency gate**: Code-level gate counts web actions and injects "SUFFICIENCY REACHED" into micro_memory after N actions — but the router at temp=0.1 may still not output SUCCESS

### 4.3 LLM Call Count Comparison

| Path | Min Calls | Typical Calls | Max Calls |
|---|---|---|---|
| Best case (search → SUCCESS) | 5 | — | — |
| Search + 1 fetch | 7 | 7-9 | — |
| Search + fetch spiral | — | — | 15+ (3 inner × max loops) |

### 4.4 Parameter Table

| # | Role | Temp | Sys Tokens | Directive? | Old Temp |
|---|---|---|---|---|---|
| 1 | Strategist | **0.7** | ~850 | YES | **0.3** |
| 2 | Router | 0.1 | ~350 | NO | 0.1 |
| 3 | Specialist | **0.7** | ~1000 | YES | **0.3** |
| 4 | Router | 0.1 | ~350 | NO | 0.1 |
| 5 | Specialist | **0.7** | ~1000 | YES | **0.3** |
| 6 | Router | 0.1 | ~350 | NO | 0.1 |
| 7 | Strategist | **0.7** | ~850 | YES | **0.3** |

---

## 5. Comparative Summary

### 5.1 What Changed Since Good Commit (3198759)

| Dimension | Good Commit | Current HEAD | Impact |
|---|---|---|---|
| **Ask temp** | 0.5 | 0.7 (+0.2) | More random answers |
| **Agent/Specialist temp** | 0.3 | 0.7 (+0.4) | Command syntax hallucination |
| **Strategist temp** | 0.3 (agent) | 0.7 (strategist→agent fallthrough) | Verbose/wrong milestones |
| **System prompt overhead** | 0 extra | +250 tok per non-router call | Attention dilution |
| **Identity repetition** | 1× (Modelfile OR condensed_soul) | 2× (directive + condensed_soul) | Confusion |
| **Modelfile SYSTEM** | ~85 tok (lean) | ~220 tok (Unsloth preamble) | Larger base |
| **repeat_penalty** | 1.0 (think), 1.3 (global) | 1.2 (think+global) | Vocabulary suppression |
| **presence_penalty** | 0.0 (think), 0.8 (global) | 0.3 (think+global) | Less anti-repetition |
| **think:true flag** | Sent to all thinkers | Only qwen3/granite4 | Ministral thinking changes |
| **Model routing** | Dual (think+inst) | Single (think only) | No fast instruct path |

### 5.2 Token Budget Per Call (System Prompt)

```
GOOD COMMIT:                          CURRENT HEAD:
┌──────────────────────┐              ┌──────────────────────┐
│ /ask system: ~430 tok│              │ /ask system: ~680 tok│
│  • time         (10) │              │  • directive   (250) │ ← NEW
│  • condensed   (200) │              │  • time         (10) │
│  • format       (50) │              │  • condensed   (300) │ ← was 200
│  • project      (20) │              │  • format       (50) │
│  • recall       (50) │              │  • project      (20) │
│  • [no overhead]     │              │  • recall       (50) │
└──────────────────────┘              └──────────────────────┘

┌──────────────────────┐              ┌──────────────────────┐
│ specialist: ~250 tok │              │ specialist: ~650 tok │
│  • role         (30) │              │  • directive   (250) │ ← NEW
│  • format rules (50) │              │  • role         (30) │
│  • docs        (100) │              │  • format rules (50) │
│  • hints        (30) │              │  • docs        (100) │
│  • [no overhead]     │              │  • syntax card (100) │ ← NEW
└──────────────────────┘              │  • keys         (20) │ ← NEW
                                      └──────────────────────┘

┌──────────────────────┐              ┌──────────────────────┐
│ strategist: ~400 tok │              │ strategist: ~850 tok │
│  • role         (30) │              │  • directive   (250) │ ← NEW
│  • commands     (80) │              │  • role         (30) │
│  • rules       (250) │              │  • commands    (200) │ ← was 80
│  • [no overhead]     │              │  • rules       (350) │ ← was 250
└──────────────────────┘              └──────────────────────┘

┌──────────────────────┐              ┌──────────────────────┐
│ router: ~250 tok     │              │ router: ~350 tok     │
│  • catalog     (200) │              │  • catalog     (250) │
│  • rules        (50) │              │  • few-shot     (50) │ ← NEW
│  [no directive]      │              │  • rules        (50) │
└──────────────────────┘              │  [no directive]      │ ← CORRECT
                                      └──────────────────────┘
```

### 5.3 The `/ask` Fix Priorities

Since `/ask` is the simplest path with a single LLM call, fixes here prove out before percolating:

1. **Restore `LLM_TEMP_ASK=0.5`** — Direct fix, one line
2. **Stop injecting thinking directive into ask** — The condensed soul already covers identity. The Unsloth thinking preamble is redundant when the model already knows to think from its Modelfile training.
3. **Or: slim the directive to thinking-only** — If injection must stay, strip the "# WHO YOU ARE" identity block from it (keep only the 3-line thinking instruction)
4. **Restore penalties** — `repeat_penalty=1.0, presence_penalty=0.0` for the Modelfile (thinking model), keep scenario overrides as-is
