# Model Library & Dual-Model Architecture

> How to acquire, configure, and use the models in George's model library — including dual-model mode, single-model mode, and model-specific gotchas.

---

## Overview

George ships with a **model library** of 9 pre-configured models across 4 families. Two models run in tandem:

- **Primary model** — handles conversational queries (`/ask`) and agent planning/execution. Should be a strong reasoning model.
- **Secondary model** — handles fast utility tasks: tool routing, commit messages, journal reflections, web summaries. Should be a fast instruct model.

Only one model is loaded in memory at a time. George **hot-swaps** between them automatically based on what it's doing — you don't need to think about switching.

### Why Two Models?

A thinking model (Qwen3 Thinking, Granite 4, Ministral Reasoning) is excellent at planning and problem-solving but wastes time and tokens on simple tasks like "pick which tool to use" or "write a commit message." An instruct model skips the reasoning phase entirely and responds in a fraction of the time.

Dual-model mode gives you the best of both: deep reasoning where it matters, speed where it doesn't.

---

## Available Models

| Key | Base Image | Family | Role | Thinks | Context | Notes |
|-----|-----------|--------|------|--------|---------|-------|
| `qwen3-think` | Qwen3-4B-Thinking-2507 UD-Q5_K_XL | Qwen3 | thinking | Yes | 32K | **Default primary.** Extended thinking with `/no_think` soft switch. Best overall. |
| `qwen3-inst` | Qwen3-4B-Instruct-2507 UD-Q5_K_XL | Qwen3 | instruct | No | 32K | **Default secondary.** Fast instruct, no thinking phase. |
| `llama32` | llama3.2:3b | Llama 3.2 | thinking | No | 32K | Meta base model. Strong general reasoning. Huge native context window (128K). |
| `llama32-inst` | Llama-3.2-3B-Instruct UD-Q5_K_XL | Llama 3.2 | instruct | No | 32K | Llama Instruct (Unsloth quant). Fast responses. |
| `granite4` | granite4:3b | Granite 4 | instruct | No | 32K | IBM Granite 4 Micro instruct. Fast structured output. |
| `granite4-h` | granite4:3b-h | Granite 4 | instruct | No | 32K | IBM Granite 4 hybrid quant. Smaller footprint (1.9GB vs 2.1GB). |
| `granite4-preview` | ibm/granite4.0-preview:tiny | Granite 4 | thinking | Yes | 32K | IBM Granite 4 Preview. Extended thinking via Ollama `.thinking` field. |
| `minist-think` | Ministral-3-3B-Reasoning-2512 UD-Q5_K_XL | Ministral | thinking | Yes | 32K | Mistral reasoning model. Chain-of-thought with compact output. |
| `minist-inst` | Ministral-3-3B-Instruct-2512 UD-Q5_K_XL | Ministral | instruct | No | 32K | Mistral instruct model. Fast structured output. |

### Sizing

All models are 3B-4B parameters at Q5_K_XL or equivalent quantization. Approximate memory footprint:

| Component | Size |
|-----------|------|
| Model weights | ~2.5-3.5 GB |
| KV cache (32K context) | ~4-5 GB |
| Ollama overhead | ~0.5 GB |
| **Total loaded** | **~7-9 GB** |

> On a 12GB device, this leaves ~3-5 GB free. Only one model is in memory at a time — dual-model mode does **not** double RAM usage.

---

## Acquiring Models

### Fresh Install

The installer (`bash install.sh`) automatically creates the default model pair:

- Primary: `blue-lodge-qwen3-think:4b` (from `qwen3-think`)
- Secondary: `blue-lodge-qwen3-inst:4b` (from `qwen3-inst`)

Each model downloads its base weights from HuggingFace/Ollama on first creation (~3 GB per model). On a fast connection this takes 2-5 minutes per model; on mobile data, plan for 10-20 minutes.

### Adding Models After Install

Models are created on-demand when you select them. To add a model that isn't already downloaded:

```bash
george> /models select primary granite4
# George will automatically:
#   1. Generate a Modelfile with the correct parameters
#   2. Download the base weights (if not cached by Ollama)
#   3. Create the Ollama model with George's SYSTEM prompt
#   4. Set it as the primary model
```

You can also create models manually if you want to pre-download them:

```bash
# Source the model library
source ~/blue-lodge/lib/models.sh

# Generate a Modelfile
models_generate_modelfile "minist-think"
# Output: /home/user/blue-lodge/models/minist-think.Modelfile

# Create the Ollama model
ollama create blue-lodge-minist-think:4b -f ~/blue-lodge/models/minist-think.Modelfile
```

### Pre-Downloading All Models

To download all 9 models upfront (useful before going offline):

```bash
source ~/blue-lodge/lib/models.sh
for key in qwen3-think qwen3-inst llama32 llama32-inst granite4 granite4-h granite4-preview minist-think minist-inst; do
    echo "Creating $key..."
    models_create "$key"
done
```

> **Storage:** Each base image is ~2.5-3.5 GB. All 9 models share some base layers but expect ~20-25 GB total disk usage for the full library.

### Ollama Base Images

Some models use official Ollama library tags, others use HuggingFace GGUF files via the `hf.co/` URI scheme:

| Key | Source | Pull method |
|-----|--------|-------------|
| `qwen3-think` | `hf.co/unsloth/Qwen3-4B-Thinking-2507-GGUF:UD-Q5_K_XL` | Auto-downloaded by `ollama create` |
| `qwen3-inst` | `hf.co/unsloth/Qwen3-4B-Instruct-2507-GGUF:UD-Q5_K_XL` | Auto-downloaded by `ollama create` |
| `llama32` | `llama3.2:3b` | Official Ollama library (`ollama pull llama3.2:3b`) |
| `llama32-inst` | `hf.co/unsloth/Llama-3.2-3B-Instruct-GGUF:UD-Q5_K_XL` | Auto-downloaded by `ollama create` |
| `granite4` | `granite4:3b` | Official Ollama library (`ollama pull granite4:3b`) |
| `granite4-h` | `granite4:3b-h` | Official Ollama library (`ollama pull granite4:3b-h`) |
| `granite4-preview` | `ibm/granite4.0-preview:tiny` | Official Ollama library (`ollama pull ibm/granite4.0-preview:tiny`) |
| `minist-think` | `hf.co/unsloth/Ministral-3-3B-Reasoning-2512-GGUF:UD-Q5_K_XL` | Auto-downloaded by `ollama create` |
| `minist-inst` | `hf.co/unsloth/Ministral-3-3B-Instruct-2512-GGUF:UD-Q5_K_XL` | Auto-downloaded by `ollama create` |

> **Note:** The `hf.co/` URI scheme requires **Ollama 0.5.0+**. If your Ollama version doesn't support it, manually download the GGUF file and use a local `FROM ./path/to/file.gguf` in the Modelfile instead.

---

## Configuring Models

### Dual-Model Mode (Default)

After install, George runs in dual-model mode with these defaults:

```bash
# Set in your shell profile by install.sh:
export LODGE_MODEL_PRIMARY="blue-lodge-qwen3-think:4b"
export LODGE_MODEL_SECONDARY="blue-lodge-qwen3-inst:4b"
```

The routing rules are fixed:

| Scenario | Model Used | Why |
|----------|-----------|-----|
| `/ask` (conversations) | **Primary** | Needs reasoning and personality |
| Agent planning & execution | **Primary** | Needs multi-step reasoning |
| Inner loop router | **Secondary** | Just picks a tool name — speed matters |
| Tool execution (commit, web, recall) | **Secondary** | Structured output, no deep reasoning needed |
| Journal reflections | **Secondary** | Background utility, brief output |
| Everything else (default) | **Primary** | Safe fallback |

### Single-Model Mode

If you don't want model switching (simpler, no 5-15s swap cost):

```bash
george> /models single qwen3-think
```

Or via environment variable:

```bash
export LODGE_SINGLE_MODEL=1
# LODGE_MODEL_PRIMARY is used for everything
```

Single-model mode is ideal when:
- You're on extremely constrained hardware where swap time matters
- You want predictable behavior from one model
- You're testing or debugging a specific model

### Switching Models at Runtime

Use the `/models` slash command:

```bash
george> /models                        # Show status + full model list
george> /models list                   # Just the model list
george> /models status                 # Just current configuration

george> /models select primary granite4          # Change primary model
george> /models select secondary minist-inst     # Change secondary model

george> /models single llama32-inst              # Single-model mode
george> /models dual                             # Back to dual-model mode
```

> **Important:** Runtime model changes are session-only. To persist across restarts, update your shell profile:
>
> ```bash
> export LODGE_MODEL_PRIMARY="blue-lodge-granite4:3b"
> export LODGE_MODEL_SECONDARY="blue-lodge-minist-inst:4b"
> ```

### Hot-Swap Behavior

When George switches between primary and secondary:

1. The current model is **unloaded** from memory (`keep_alive: 0`)
2. The target model is **loaded** (weights + KV cache allocated)
3. A status message appears: `Switching model: qwen3-think → qwen3-inst`

**Timing:** 5-15 seconds on ARM (Snapdragon 8 Elite), 1-3 seconds on desktop with SSD. The swap happens automatically before each LLM call — you never need to trigger it manually.

**Consecutive same-model calls are free.** If George makes 5 tool calls in a row, the secondary stays loaded — no swap overhead. The swap only happens when crossing a scenario boundary (e.g., tool → ask).

---

## Model-Specific Details

### Qwen3 Family

**qwen3-think** — The default primary. Best overall model in the library.

- Produces `<think>...</think>` blocks before responding
- Supports Qwen3's native `/no_think` soft switch: append `/no_think` to the prompt to skip reasoning entirely
- Uses `/think nothink` or `LODGE_NOTHINK=1` to enable this globally
- Stop token: `<|im_end|>`
- Most battle-tested with George's harness

**qwen3-inst** — The default secondary. Same architecture, no thinking phase.

- Never produces thinking tokens — all output is response
- No nothink mechanism needed (it never thinks)
- Shares the `<|im_end|>` stop token with qwen3-think, so no stop token mismatch when swapping within the family
- Lighter on tokens per request (no think budget consumed)

### Llama 3.2 Family

**llama32** — Meta's base 3B model.

- Registered as "thinking" role but `has_thinking=0` — it doesn't produce `<think>` tags. It's included as a primary option for users who want Llama's reasoning without explicit chain-of-thought display.
- 128K native context window (largest in the library), but the Modelfile uses 32K by default to keep RAM reasonable. You can increase `num_ctx` in the generated Modelfile if you have the RAM.
- No nothink mechanism (doesn't think to begin with)
- Stop token: `<|eot_id|>`

**llama32-inst** — Unsloth-quantized Instruct variant.

- Optimized for structured output
- Same 128K context capability
- Stop token: `<|eot_id|>`

### Granite 4 Family

**granite4** — IBM's Granite 4 3B Micro model.

- Instruct model — does not produce `<think>` blocks
- No nothink mechanism needed (it never thinks)
- Stop token: `<|end_of_text|>`
- Strong at structured reasoning and instruction following

**granite4-h** — IBM's Granite 4 3B hybrid quantization.

- Same architecture as `granite4` but uses hybrid quantization (1.9GB vs 2.1GB)
- Instruct model — no thinking phase
- Stop token: `<|end_of_text|>`
- Good choice when disk/RAM is tighter

**granite4-preview** — IBM's Granite 4 Preview (tiny) thinking model.

- The actual IBM thinking model in the library — produces extended reasoning via Ollama's `.thinking` field
- Nothink method: `system` — when `LODGE_NOTHINK=1`, the Modelfile includes a system prompt instruction telling the model to skip reasoning. This is less reliable than Qwen3's `/no_think` token because it's a soft instruction, not an architectural feature.
- May emit `<response>...</response>` wrapper tags — George strips these automatically in both `llm_generate` and `llm_stream`
- The generated Modelfile includes a SYSTEM prompt instruction to not emit response tags
- Stop token: `<|end_of_text|>`
- Base image: `ibm/granite4.0-preview:tiny`

### Ministral Family

**minist-think** — Mistral's reasoning 3B model.

- Produces `<think>` blocks
- No nothink mechanism (`none`) — reasoning cannot be suppressed. Using `/think nothink` will set the flag but have no effect on this model's behavior.
- Stop token: `</s>`
- Compact chain-of-thought output

**minist-inst** — Mistral's instruct 3B model.

- No thinking phase, designed for fast structured output
- Stop token: `</s>`

---

## Gotchas & Warnings

### 1. First-Time Download Can Be Slow

Each model downloads ~3 GB of weights on first creation. If you're on mobile data or a slow connection, this can take a while. The download happens through Ollama's pull mechanism, so progress is shown in your terminal.

**Mitigation:** Pre-download models while on WiFi using the "Pre-Downloading All Models" instructions above.

### 2. Model Switching Takes Time on ARM

Hot-swap takes 5-15 seconds on ARM hardware (loading weights into memory). During an agent task, if George alternates rapidly between primary (planning) and secondary (tool execution), you'll see multiple swap messages and delays.

**Mitigation:** Use single-model mode (`/models single qwen3-think`) if swap latency is unacceptable. The tradeoff is that simple tasks like commit messages will use the thinking model (slower, wastes think tokens).

### 3. Nothink Doesn't Work on All Models

The `/think nothink` command and `LODGE_NOTHINK=1` variable behave differently per model:

| Model | Nothink Method | Effectiveness |
|-------|---------------|---------------|
| `qwen3-think` | `/no_think` prompt suffix | **Strong** — architecturally supported by Qwen3 |
| `granite4-preview` | System prompt instruction | **Weak** — model may still reason despite instruction |
| `minist-think` | None | **No effect** — model always reasons |
| `llama32` | None | **No effect** — model doesn't think to begin with |
| `granite4`, `granite4-h` | N/A | **Not applicable** — instruct models, never reason |
| All instruct models | N/A | **Not applicable** — they never reason |

**Impact:** If you switch primary to `minist-think` and use `/think nothink`, the flag will be set but reasoning will still occur. George won't error — it just won't suppress thinking.

### 4. Budget Tokens Are Qwen3-Specific

The `LLM_BUDGET_*` environment variables (`LLM_BUDGET_ASK=1024`, etc.) inject a `budget_tokens` field into the Ollama API payload. This parameter is **only respected by Qwen3 thinking models**. All other models silently ignore it.

**Impact:** No harm — the parameter is harmlessly ignored. But don't rely on `budget_tokens` to constrain thinking on non-Qwen models. Use `LLM_MAX_TOKENS` (which caps total output including thinking tokens) as the universal safety limit.

### 5. Per-Scenario Sampling Overrides the Modelfile

Each model in the registry has its own sampling parameters (temperature, penalties, etc.) baked into its generated Modelfile. However, George's per-scenario sampling system (`_llm_build_opts()` in `lib/llm.sh`) **overrides these at call time** via the Ollama `options` field.

This means:
- The Modelfile `temperature 0.4` is the baseline
- But when George makes an `/ask` call, it sends `temperature: 0.5` in the request options
- The request-level value wins

**Impact:** Changing sampling values in the Modelfile alone won't have the expected effect during normal George operation. To change sampling behavior, use:

```bash
# Runtime (session only):
george> /model temp-ask 0.3

# Persistent (shell profile):
export LLM_TEMP_ASK=0.3
```

See [TUNING.md](TUNING.md) for the full per-scenario sampling reference.

### 6. Stop Token Mismatches Cause Runaway Output

Each model family uses a different stop token. The model library handles this correctly in the generated Modelfiles, but if you manually create a model or edit a Modelfile, using the wrong stop token will cause the model to generate past its natural stopping point.

| Family | Correct Stop Token |
|--------|--------------------|
| Qwen3 | `<\|im_end\|>` |
| Llama 3.2 | `<\|eot_id\|>` |
| Granite 4 | `<\|end_of_text\|>` |
| Ministral | `</s>` |

**Mitigation:** Always use `/models select` or `models_generate_modelfile()` to create models — they set the correct stop token automatically. Never manually copy a Qwen Modelfile and change only the `FROM` line.

### 7. Cross-Family Dual-Model Pairing

You can pair models from different families (e.g., Qwen3 primary + Ministral secondary). This works correctly because George's harness is model-agnostic — it checks the registry for each model's capabilities at runtime.

However, be aware that different families have different strengths:

| Pairing | Notes |
|---------|-------|
| Qwen3 + Qwen3 (default) | Best tested. Same stop token family. Fastest swaps. |
| Qwen3 + Llama3.2 | Works well. Different stop tokens but handled automatically. |
| Granite + Ministral | Works, but nothink is weak (system prompt) or absent (none). |
| Llama + Llama | No thinking on either side — fast but less capable for complex planning. |

### 8. LODGE_MODEL Is Now Managed — Don't Set It Directly

The old `export LODGE_MODEL=blue-lodge` approach still works for backward compatibility, but it's now **overwritten at startup** by `models_init()`, which sets `LODGE_MODEL` to `LODGE_MODEL_PRIMARY`.

**Use instead:**
```bash
export LODGE_MODEL_PRIMARY="blue-lodge-granite4:3b"
export LODGE_MODEL_SECONDARY="blue-lodge-qwen3-inst:4b"
```

Setting `LODGE_MODEL` directly in your shell profile will have no effect — it gets overwritten when George starts.

### 9. Generated Modelfiles Live in `models/`

When you create or select a model, George generates a Modelfile at `~/blue-lodge/models/<key>.Modelfile`. These are auto-generated and **will be overwritten** on the next select/create for that key. If you want to customize a Modelfile, either:

- Edit the registry in `lib/models.sh` (permanent, survives updates)
- Edit the generated Modelfile and re-run `ollama create` manually (fragile, overwritten on next select)

### 10. The Root `Modelfile` Is Legacy

The `Modelfile` in the project root (`~/blue-lodge/Modelfile`) is the original single-model definition for `blue-lodge` (Qwen3 Thinking). It is **not used** by the model library system. Models are now generated into `~/blue-lodge/models/` by `models_generate_modelfile()`.

The root Modelfile is kept for reference and backward compatibility with users who haven't migrated to the model library yet.

---

## Recommended Configurations

### Default (Best Overall)

```bash
export LODGE_MODEL_PRIMARY="blue-lodge-qwen3-think:4b"
export LODGE_MODEL_SECONDARY="blue-lodge-qwen3-inst:4b"
```

Qwen3 Thinking for deep reasoning, Qwen3 Instruct for speed. Same family = same stop token = cleanest integration. This is what the installer sets up.

### Maximum Speed (Single Model)

```bash
export LODGE_MODEL_PRIMARY="blue-lodge-qwen3-inst:4b"
export LODGE_SINGLE_MODEL=1
```

No model switching, no thinking overhead. Every request is fast instruct. Best for simple tasks, quick Q&A, or when swap latency is a problem.

### Maximum Reasoning

```bash
export LODGE_MODEL_PRIMARY="blue-lodge-qwen3-think:4b"
export LODGE_SINGLE_MODEL=1
```

Thinking model for everything, including tool routing and commit messages. Slower but more thoughtful across the board.

### Cross-Family Experiment

```bash
export LODGE_MODEL_PRIMARY="blue-lodge-granite4-preview:tiny"
export LODGE_MODEL_SECONDARY="blue-lodge-minist-inst:4b"
```

IBM Granite Preview for planning, Mistral Instruct for fast utility. Good for testing different reasoning styles. Be aware that Granite Preview's nothink is system-prompt-based (weaker than Qwen3's).

### Large Context (Llama)

```bash
export LODGE_MODEL_PRIMARY="blue-lodge-llama32:3b"
export LODGE_MODEL_SECONDARY="blue-lodge-llama32-inst:3b"
```

If you need the largest context window (128K native). Note: the generated Modelfiles cap `num_ctx` at 32K by default to conserve RAM. To use the full 128K, edit `num_ctx` in `lib/models.sh` registry or in the generated Modelfile and recreate:

```bash
# After editing the Modelfile:
ollama create blue-lodge-llama32:3b -f ~/blue-lodge/models/llama32.Modelfile
```

> **Warning:** 128K context requires ~18 GB KV cache for Llama 3.2 3B. This exceeds 12 GB RAM. Only use large contexts on devices with 24+ GB RAM or GPU offload.

---

## Slash Command Reference

### `/models`

```
/models                        Show status + full model list
/models list                   List all available models
/models status                 Show current configuration (mode, slots, details)
/models select primary <key>   Set the primary model
/models select secondary <key> Set the secondary model
/models single <key>           Enter single-model mode with the given model
/models dual                   Switch back to dual-model mode
```

### `/think` (Model-Aware)

The `/think` command interacts with the model library's nothink system:

```
/think nothink     Suppress reasoning (model-specific mechanism)
/think enable      Re-enable reasoning
/think dim         Show thinking in faint text
/think bright      Show thinking in cyan
/think hide        Think but don't display
/think off         Hide thinking display (model still reasons)
/think             Cycle through modes
```

When you use `/think nothink`:
- **Qwen3 thinking models:** Appends `/no_think` to prompts (strong suppression)
- **Granite 4 Preview:** Relies on system prompt instruction (weak suppression)
- **Ministral thinking:** No effect (model always reasons)
- **Granite 4 / Granite 4-H:** No effect (instruct models, never reason)
- **Instruct models:** No effect (they never reason anyway)

### `/model` (Sampling Parameters)

The existing `/model` command controls per-scenario sampling and is separate from `/models`:

```
/model                  Show all sampling parameters
/model temp 0.3         Set global temperature
/model temp-ask 0.7     Set ask-specific temperature
/model reset            Reset all to defaults
```

See [TUNING.md](TUNING.md) for the full parameter reference.

---

## Troubleshooting

### "Switching model" messages appear constantly

George is alternating between primary and secondary on every call. This happens in agent tasks that interleave planning (primary) with tool execution (secondary).

**Fix:** If the delay is unacceptable, switch to single-model mode:
```bash
george> /models single qwen3-think
```

### Model won't download / "manifest unknown"

The HuggingFace URI (`hf.co/...`) requires Ollama 0.5.0+. Check your version:
```bash
ollama --version
```

If below 0.5.0, update Ollama:
```bash
curl -fsSL https://ollama.com/install.sh | sh
```

### "Unknown model" when selecting

Use the model **key** (short name), not the full Ollama model name:
```bash
# Correct:
george> /models select primary granite4

# Wrong:
george> /models select primary blue-lodge-granite4:3b
```

Run `/models list` to see all valid keys.

### Model generates `<think>` tags in output

This happens when a thinking model's `<think>` block isn't properly parsed. Possible causes:

1. The model is not in the registry (George doesn't know it thinks)
2. You manually created a model outside the library with `LODGE_MODEL` set directly

**Fix:** Use `/models select` to register the model properly, or add it to the `_MODELS_REGISTRY` in `lib/models.sh`.

### RAM pressure / OOM kills

Both models are never loaded simultaneously — hot-swap unloads one before loading the other. If you're still seeing OOM:

- Reduce `num_ctx` in the registry (32768 → 20480 saves ~1.7 GB KV cache)
- Use a smaller quantization (Q4_K_M instead of Q5_K_XL)
- Lower `LLM_KEEP_ALIVE` to free RAM sooner: `export LLM_KEEP_ALIVE=5m`
