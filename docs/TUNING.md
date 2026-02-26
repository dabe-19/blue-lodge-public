# Token & Context Tuning Guide

> How to fine-tune George's token budgets, context window, and model parameters — especially when using custom models.

---

## Architecture Overview

George uses a **three-tier prompt system** that keeps token usage within budget:

| Mode | Used by | System prompt size | Output cap | Total budget |
|------|---------|-------------------|------------|-------------|
| **ask** | `/ask`, short questions | ~250 tokens (condensed soul) | 20,480 tokens | ~20,730 tokens |
| **plan** (light) | `agent_plan` (LODGE_SOUL=0) | ~700 tokens (condensed soul + catalog) | 20,480 tokens | ~21,180 tokens |
| **plan** (dense) | `agent_plan` (LODGE_SOUL=1) | ~5,000 tokens (full soul + catalog) | 20,480 tokens | ~25,480 tokens |
| **task** | `memory_build_system_prompt` task mode | ~3,500 tokens | 20,480 tokens | ~24,000 tokens |

> **Note:** The thinking model uses ~200-2000 think tokens per response. These count against the output cap. Per-call limits match the Modelfile `num_predict` ceiling (32768) — the model stops at its natural `<|im_end|>` stop token well before hitting the cap.

The **Modelfile SYSTEM prompt** (~300 tokens) is baked into every request by Ollama automatically but is **overridden** when a function passes its own system prompt. George always knows who he is because every prompt tier includes soul content.

> **Note:** Plan mode uses a **lean command catalog** (`commands_catalog_plan()`, ~400 tokens) instead of the full catalog (~1,443 tokens). The `/soul` toggle controls whether planning gets the condensed soul (~250 tokens) or the full soul.md (~4,500 tokens) — allowing the operator to trade token budget for richer ethical grounding in plans.

### Soul Injection Tiers

The soul.md document (~4,500 tokens) is the source of George's identity and philosophy. Three canonical excerpts are derived from it:

| Tier | Source | ~Tokens | Used by |
|------|--------|---------|--------|
| **Identity** | Top of soul.md (before TMS section) | ~90 | `agent_run()` macro memory seed |
| **Condensed** | `_memory_soul_condensed()` in memory.sh | ~250 | `/ask`, planning (LODGE_SOUL=0) |
| **Full** | `cat soul.md` | ~4,500 | Planning (LODGE_SOUL=1), task mode |

Toggle with `/soul` (or `/soul on`/`/soul off`). Default is light (condensed).

### Why George doesn't need everything in-context

George has three persistent memory layers that survive between LLM calls:

- **GEORGE.md** — project state: current task, plan, completed steps, key files
- **Journal** — reflections, learnings, struggles (with temporal decay) — up to 500 tokens injected in task mode
- **FTS5 Recall** — BM25-ranked search over RECALL_INDEX.md, journal, GEORGE.md, and ingested files — 4 chunks in task mode, 1 chunk (200 char cap) in ask mode
- **Conversation history** — ring buffer of last 3 exchanges (~300-600 tokens) injected into `/ask` for conversational continuity

The system prompt builder automatically injects the **most relevant** pieces from each layer. George doesn't need his full life story in every prompt because he can look things up via `/recall`, `/journal`, and `/memory`.

---

## Environment Variables

All token/context settings can be overridden via environment variables. Set them in your shell profile (`.bashrc`, `.zshrc`) or export them before launching George.

### Core Token Budgets

```bash
# Maximum output tokens for task execution (agent_execute_step)
# Default: 20480. Model stops at <|im_end|>; this is a safety cap.
export LLM_MAX_TOKENS=1024

# Maximum output tokens for /ask (think + response)
# Default: 20480. Model stops at <|im_end|>; this is a safety cap.
export LLM_ASK_TOKENS=2048

# Safety timeout per LLM request (seconds)
# Default: 600. Set to 0 to disable (Ctrl+C only).
export LLM_TIMEOUT=120

# How long the model stays loaded in RAM after last request
# Default: 30m. Increase if you take long breaks between commands.
# Set to "0" to unload immediately after each request (saves RAM).
export LLM_KEEP_ALIVE=30m
```

### Agent Planning Limits

These control how many steps, milestones, and retries George uses during task execution. All are adjustable at runtime via the `/limits` slash command or environment variables.

```bash
# Max steps per plan/subtask (default: 5)
# Controls the "Maximum: N steps" instruction in agent_plan().
# Higher = more detailed subtask decomposition.
export AGENT_PLAN_STEPS=5

# Max macro loop milestones (default: 20)
# Safety ceiling for the Strategist loop in agent_run().
export AGENT_MAX_STEPS=20

# Inner loop escalation ceiling (default: 6)
# How many route→execute cycles before human intervention.
export AGENT_INNER_LOOPS=6

# Subtask recursion depth (default: 2)
# How deep [SUBTASK] nesting can go.
export AGENT_MAX_DEPTH=2

# Seconds between milestones (default: 1)
export AGENT_STEP_DELAY=1
```

> **Runtime adjustment:** Use `/limits` to view or change any of these without restarting. For example: `/limits steps 8` raises the plan step cap to 8 for the current session. `/limits reset` restores all defaults.

### Model Selection

George uses a **dual-model architecture** with a model library. See [MODELS.md](MODELS.md) for the full model library documentation.

```bash
# Which models to use (set by install.sh, persisted in shell profile)
export LODGE_MODEL_PRIMARY="blue-lodge-minist-think:4b"   # Reasoning/planning
export LODGE_MODEL_SECONDARY="blue-lodge-minist-inst:4b"  # Fast utility tasks

# Single-model mode (no switching)
export LODGE_SINGLE_MODEL=1

# Ollama API endpoint (default: local)
export OLLAMA_URL=http://127.0.0.1:11434
```

Runtime model switching via `/models`:

```bash
george> /models select primary granite4
george> /models select secondary minist-inst
george> /models single qwen3-think
george> /models dual
```

> **Note:** The old `LODGE_MODEL` variable still exists for backward compatibility but is overwritten at startup by `models_init()`. Use `LODGE_MODEL_PRIMARY` and `LODGE_MODEL_SECONDARY` instead.

### Example: Low-RAM Device (4-8GB)

```bash
export LLM_MAX_TOKENS=2048
export LLM_ASK_TOKENS=1024
export LLM_TIMEOUT=120
export LLM_KEEP_ALIVE=10m
```

### Example: Desktop with GPU (16GB+ VRAM)

```bash
export LLM_MAX_TOKENS=16384
export LLM_ASK_TOKENS=8192
export LLM_TIMEOUT=300
export LLM_KEEP_ALIVE=2h
```

---

## Modelfile Parameters

The `Modelfile` in the project root controls Ollama model behavior. After any change, recreate the model:

```bash
ollama create blue-lodge -f ~/blue-lodge/Modelfile
```

### Parameter Reference

| Parameter | Default | Description | Tuning guidance |
|-----------|---------|-------------|-----------------|
| `num_ctx` | 32768 | Context window (tokens). All input + output must fit. | KV cache ≈ 144KB/token for Qwen3-4B. 32768 uses ~4.5GB. Reduce to 20480 (~2.81GB) on tight RAM. |
| `num_predict` | 32768 | Max output tokens (overridden per-call by env vars). | Modelfile-level ceiling. Per-call overrides (`LLM_MAX_TOKENS`, `LLM_ASK_TOKENS`) take precedence. Thinking model needs generous budget (think tokens + response). |
| `num_thread` | 8 | CPU threads for inference. | Match your physical core count. 8 for Snapdragon 8 Elite, 4 for typical laptops. |
| `num_gpu` | 0 | GPU layers to offload. 0 = pure CPU. | Set to 99 (all layers) if you have a GPU. Partial offload: try 20-40. |
| `temperature` | 0.6 | Randomness. Default matches per-model registry. | Per-scenario overrides via `_llm_build_opts()` adjust temperature per use case (0.1 for router, 0.6 for journal). See Per-Scenario Sampling below. |
| `top_p` | 0.95 | Nucleus sampling threshold. | Lower (0.7) for focused output, higher (0.95) for variety. |
| `top_k` | 20 | Top-K sampling. Limits token candidates per step. | Unsloth-recommended. Keeps generation focused despite moderate temperature. |
| `repeat_penalty` | 1.3 | Penalty for repeating tokens. | Mild penalty to discourage token-level loops. Works alongside presence_penalty. |
| `presence_penalty` | 0.8 | Penalty for tokens already in context. | Moderate anti-repetition. Discourages re-treading the same ideas. Works alongside repeat_penalty. |
| `stop` | `<\|im_end\|>` | Stop sequence. Model-specific. | Check your model's chat template for the correct stop token. |

### Per-Scenario Sampling

George doesn't use a single temperature for everything. The `_llm_build_opts()` function in `lib/llm.sh` resolves sampling parameters based on `LLM_SCENARIO` — a variable set by each caller before invoking the LLM. This allows different tasks to use different creativity/focus levels.

**Five scenarios** with independent `temperature`, `repeat_penalty`, and `presence_penalty`:

| Scenario | Used by | Temp | Repeat | Presence | Rationale |
|----------|---------|------|--------|----------|-----------|
| `ask` | `/ask`, quick questions | 0.5 | 1.3 | 0.8 | Conversational, moderate creativity |
| `agent` | `agent_plan`, `agent_execute_step` | 0.3 | 1.3 | 0.8 | Focused execution, low creativity |
| `router` | Inner loop tool selection | 0.1 | 1.1 | 1.0 | Near-deterministic routing, moderate anti-loop |
| `journal` | Background reflections | 0.6 | 1.3 | 1.0 | Slightly creative, moderate anti-repetition |
| `tool` | `/commit`, `/web summary`, `/recall`, `/slash` | 0.3 | 1.3 | 0.8 | Structured output, focused |

**Global defaults** (used when no scenario is set or as fallback):
- `LLM_TEMPERATURE=0.6`, `LLM_REPEAT_PENALTY=1.3`, `LLM_PRESENCE_PENALTY=0.8`

**Override individual scenarios** via environment variables:

```bash
# Make /ask more creative
export LLM_TEMP_ASK=0.8

# Make the router completely deterministic
export LLM_TEMP_ROUTER=0.0

# Reduce journal anti-repetition
export LLM_PRESENCE_JOURNAL=1.5

# Per-scenario vars follow the pattern:
#   LLM_TEMP_<SCENARIO>      (temperature)
#   LLM_REPEAT_<SCENARIO>    (repeat_penalty)
#   LLM_PRESENCE_<SCENARIO>  (presence_penalty)
# Where <SCENARIO> is ASK, AGENT, ROUTER, JOURNAL, or TOOL
```

**Runtime adjustment:** Use `/model` to view or change any sampling parameter without restarting. For example:

```bash
george> /model                    # Show all current values
george> /model temp 0.3           # Set global temperature
george> /model temp-ask 0.7       # Set ask-specific temperature
george> /model presence-router 2.5 # Set router presence penalty
george> /model reset              # Reset all to defaults
```

The `/model` command supports all global (`temp`, `repeat`, `presence`) and per-scenario variants (`temp-ask`, `repeat-agent`, `presence-router`, etc.).

### Context Window Math

The golden rule: **input tokens + output tokens must fit in `num_ctx`**.

```
num_ctx = Modelfile_SYSTEM + system_prompt + user_prompt + output
32768  =     ~300         +   variable    +   variable  + num_predict
```

Budget breakdown by mode (thinking model — think tokens included in output budget):

| Mode | System prompt | User prompt | Output budget | Remaining |
|------|---------------|-------------|---------------|---------|
| ask | ~250 (condensed soul) | ~20 | 20,480 | ~12,018 |
| plan (light) | ~700 (condensed soul + catalog) | ~100 | 20,480 | ~11,488 |
| plan (dense) | ~5,000 (full soul + catalog) | ~100 | 20,480 | ~7,188 |
| task | ~3,500 | ~100 | 20,480 | ~8,688 |
| inner loop | ~500 (router or specialist) | ~200 | 20,480 | ~11,588 |

> **Note:** The Modelfile SYSTEM (~300 tokens) is overridden whenever a system prompt is passed via `llm_generate`/`llm_stream`. The inner loop (router + specialist) deliberately strips all personality for speed.

**If your model has a smaller context window** (e.g., 2048 or 4096), you must reduce token budgets:

```bash
# For a 4096-context model:
export LLM_MAX_TOKENS=512
export LLM_ASK_TOKENS=200
```

And in the Modelfile:
```
PARAMETER num_ctx 4096
PARAMETER num_predict 256
```

---

## Using Custom Models

> **Model Library:** George ships with 9 pre-configured models across 4 families. Before creating a custom model from scratch, check whether [MODELS.md](MODELS.md) already covers your use case. The model library handles stop tokens, sampling, nothink mechanisms, and dual-model routing automatically.

### Step 1: Choose a model

George works with any Ollama-compatible model. Tested recommendations:

| Model | Size | RAM needed | Context | Notes |
|-------|------|-----------|---------|-------|
| Ministral-3-3B-Reasoning-2512 UD-Q5_K_XL | ~2.5GB | 7-10GB | 32K | **Default primary.** Thinking/reasoning. Optimized for mobile. |
| Ministral-3-3B-Instruct-2512 UD-Q5_K_XL | ~2.5GB | 7-10GB | 32K | **Default secondary.** Fast instruct with vision support. |
| Qwen3-4B-Thinking-2507 UD-Q5_K_XL | ~3.5GB | 8-12GB | 20K | Thinking/reasoning. Strongest nothink support. |
| Qwen3-4B-Instruct-2507 Q5_K_M | ~3GB | 6-10GB | 16K | Non-thinking fallback. Faster inference. |
| Qwen3-8B Q5_K_M | ~6GB | 10-12GB | 32K | More capable. Needs more RAM. |
| Llama 3.1 8B Q4_K_M | ~5GB | 8-10GB | 8K-128K | Excellent code reasoning. |
| DeepSeek-Coder-V2-Lite Q4 | ~2.5GB | 4-6GB | 16K | Coding specialist. |
| Phi-3 Mini Q4 | ~2.5GB | 4-6GB | 4K-128K | Small but punchy. |
| Gemma 2 2B Q5 | ~2GB | 3-4GB | 8K | Google's compact model. |

### Step 2: Create a custom Modelfile

Copy and modify the existing Modelfile:

```bash
cp ~/blue-lodge/Modelfile ~/blue-lodge/Modelfile.custom
```

Edit `Modelfile.custom`:

```dockerfile
# Change the base model
FROM llama3.1:8b-instruct-q4_K_M

# Adjust for your hardware
PARAMETER num_ctx 32768    # Llama 3.1 supports 128K, but 32K is practical
PARAMETER num_thread 8     # Your CPU core count
PARAMETER num_gpu 99       # Offload all layers to GPU (if available)
PARAMETER num_predict 1024 # Higher budget for larger context
PARAMETER temperature 0.2
PARAMETER top_p 0.9
PARAMETER stop <|eot_id|>  # Llama 3's stop token (NOT <|im_end|>)
PARAMETER repeat_penalty 1.1

# Keep George's personality (or customize it)
SYSTEM """You are George — named for Brother George Washington, with the wit of Benjamin Franklin and the moral philosophy of Adam Smith's Theory of Moral Sentiments. You are a craftsman, not merely a tool. You run locally, sovereign and self-contained.

Output rules: Shell commands in ```bash blocks. Files in code blocks with '# filepath: ./path' on line 1. Plans as short numbered lists (use [SUBTASK] for complex work). Answers in 1-5 sentences. Never exceed 300 lines. Never hallucinate. If uncertain, say so."""
```

### Step 3: Build and use

```bash
# Build the custom model
ollama create blue-lodge -f ~/blue-lodge/Modelfile.custom

# Or use a different model name
ollama create george-llama -f ~/blue-lodge/Modelfile.custom
export LODGE_MODEL=george-llama
```

### Step 4: Adjust token budgets

If your model has a larger context window, you can increase budgets:

```bash
# For a 32K context model with GPU
export LLM_MAX_TOKENS=2048
export LLM_ASK_TOKENS=800
export LLM_TIMEOUT=300
```

If your model is smaller (1.7B params or 2K context):

```bash
# Conservative budgets for a tiny model
export LLM_MAX_TOKENS=256
export LLM_ASK_TOKENS=128
export LLM_TIMEOUT=60
```

### Important: Stop Tokens

Different model families use different stop tokens. Using the wrong one makes the model ramble past its natural stopping point, wasting tokens and time.

| Model family | Stop token |
|-------------|------------|
| Qwen3 | `<\|im_end\|>` |
| Llama 3.x | `<\|eot_id\|>` |
| Phi-3 / Phi-4 | `<\|end\|>` |
| Gemma 2 | `<end_of_turn>` |
| DeepSeek-Coder | `<\|EOT\|>` |
| Mistral / Mixtral | `[/INST]` |

If the model produces runaway output, check your stop token first.

---

## Performance Tuning for Mobile

George's default configuration targets the Galaxy Fold 7 (Snapdragon 8 Elite, 12GB RAM, 100% CPU inference) with a **32K context window** (`num_ctx=32768`). The thinking model (Ministral-3-3B-Reasoning-2512 UD-Q5_K_XL) weighs ~2.5GB with ~4.5GB KV cache (144KB/token), totaling ~7.0GB loaded — leaving ~5GB free for multitasking. Here's how to squeeze better performance:

### Reduce prefill time (prompt processing)

The biggest bottleneck on CPU is processing the system prompt. Options:

1. **Use the "ask" mode more often** — ~250 tokens vs 3,500 for task mode
2. **Keep `/soul off` (default)** — Light planning uses ~250 token condensed soul instead of ~4,500 full soul
3. **Lower `num_ctx`** — Smaller context = smaller KV cache = faster prefill

```
# In Modelfile — try 4096 if you mostly do /ask
PARAMETER num_ctx 4096
```

> **Note:** The default `num_ctx=32768` uses ~4.5GB KV cache (3.5GB weights + 4.5GB KV = 8.0GB total on 12GB). Can reduce to `num_ctx=20480` (~2.81GB KV, ~6.3GB total) if RAM is tight. George's enrichments scale down gracefully.

### Reduce generation time

1. **Lower `num_predict`** — The model stops at its natural end token, but allocates KV cache for the full budget
2. **Lower `temperature`** — More deterministic = fewer "thinking" tokens
3. **Use smaller quantization** — Q4_K_M is ~20% faster than Q5_K_M but slightly less accurate

### RAM management

On a 12GB device, the model (~3.5GB) + KV cache (~4.5GB at 32K) + Ollama overhead (~0.5GB) + OS leaves ~3.5GB free.

```bash
# Unload model when not actively using George
export LLM_KEEP_ALIVE=10m

# Or unload immediately after each request (slowest per-command, but frees RAM)
export LLM_KEEP_ALIVE=0
```

### Monitor inference speed

Check Ollama's stats for your setup:

```bash
# While George is generating, in another terminal:
curl -s http://localhost:11434/api/ps | jq '.models[] | {name, size, expires_at}'
```

After a generation, Ollama's response includes timing:

```bash
curl -s http://localhost:11434/api/generate \
  -d '{"model":"blue-lodge","prompt":"Hello","stream":false,"options":{"num_predict":1}}' \
  | jq '{prompt_eval_rate: (.prompt_eval_count / .prompt_eval_duration * 1e9),
         eval_rate: (.eval_count / .eval_duration * 1e9)}'
```

This shows tokens/second for prompt processing and generation.

---

## Advanced: Per-Command Token Overrides

George right-sizes token budgets per command:

| Command | Output tokens | Think budget | Why |
|---------|--------------|-------------|-----|
| `/ask` | 20,480 (`LLM_ASK_TOKENS`) | 1,024 (`LLM_BUDGET_ASK`) | Safety cap; model stops at `<\|im_end\|>` naturally |
| `/plan` | 512 | 512 (`LLM_BUDGET_AGENT`) | Numbered lists, 1-N steps (AGENT_PLAN_STEPS) |
| `/commit` | 128 | 256 (`LLM_BUDGET_TOOL`) | Single commit message line |
| `/reflect` | 1,024 | 64 (`LLM_BUDGET_JOURNAL`) | Journal reflection entry |
| `/web summary` | 256 | 256 (`LLM_BUDGET_TOOL`) | 3-5 bullet points |
| `/ingest summarize` | 256 | 256 (`LLM_BUDGET_TOOL`) | Document summary |
| Inner loop (router) | 256 (`LLM_ROUTER_TOKENS`) | 128 (`LLM_BUDGET_ROUTER`) | Tool selection (just pick a name) |
| Inner loop (specialist) | 20,480 (`LLM_AGENT_TOKENS`) | 512 (`LLM_BUDGET_AGENT`) | Command generation |
| Macro loop (strategist) | 20,480 (`LLM_AGENT_TOKENS`) | 512 (`LLM_BUDGET_AGENT`) | Next milestone |
| Journal quip | 512 | 64 (`LLM_BUDGET_JOURNAL`) | Background quip |
| Journal decay | 512 | 64 (`LLM_BUDGET_JOURNAL`) | Sediment compression |

Output tokens and think budgets are hardcoded per call. To change output tokens, modify the third argument to `llm_generate` or `llm_stream` in the source. Think budgets can be overridden via environment variables (`LLM_BUDGET_ASK`, `LLM_BUDGET_AGENT`, `LLM_BUDGET_ROUTER`, `LLM_BUDGET_JOURNAL`, `LLM_BUDGET_TOOL`).

---

## Troubleshooting

### "George sits for minutes with no output"

1. **Check if model is loaded**: `curl -s http://localhost:11434/api/ps | jq .`
3. **Check system prompt size**: The full task prompt is ~3,500 tokens — if your model's `num_ctx` is 2048, it won't fit. Default is 32768.
3. **Try `/ask` first** — it uses ~500 total tokens, much faster
4. **Check available RAM**: `free -h` — if swap is active, inference will be extremely slow
5. **Set a timeout**: `export LLM_TIMEOUT=120` prevents indefinite hangs

### "Model generates garbage or doesn't stop"

- Wrong stop token in Modelfile — see the stop token table above
- `num_predict` too high — the model has no reason to stop at its intended length
- Try lowering `temperature` to 0.1

### "Context window exceeded" errors

- Your total input + output exceeds `num_ctx`
- Reduce `LLM_MAX_TOKENS` or increase `num_ctx` in the Modelfile
- Run `/compact` to compress GEORGE.md

### "Model unloads between commands"

- Increase `LLM_KEEP_ALIVE`: `export LLM_KEEP_ALIVE=1h`
- Check if another process is using Ollama (competing `keep_alive` values)

---

## Quick Reference

```bash
# See what George is sending to the model (debug)
LODGE_DEBUG=1 lodge /ask "hello"

# Warm up the model manually
curl -s http://localhost:11434/api/generate \
  -d '{"model":"blue-lodge-qwen3-think:4b","prompt":"hi","stream":false,"options":{"num_predict":1}}'

# Check model info
curl -s http://localhost:11434/api/show -d '{"name":"blue-lodge-qwen3-think:4b"}' | jq .details

# Recreate model after Modelfile changes
ollama create blue-lodge-qwen3-think:4b -f ~/blue-lodge/models/qwen3-think.Modelfile

# Switch models at runtime (see docs/MODELS.md for full reference)
george> /models select primary granite4
george> /models single qwen3-think
```
