# Cloud AI Providers — Setup, Usage & Cost Guide

> How to connect George to cloud AI providers, use the provider harness to run without llama.cpp, and avoid surprise API bills.

---

## Overview

George supports **10 cloud AI providers** as alternatives (or supplements) to the local llama.cpp/Ollama backend. There are two usage modes:

| Mode | What it does | When to use |
|------|-------------|-------------|
| **One-shot** (`/provider chat`) | Send a single message to a cloud provider | Quick test, compare models, one-off question |
| **Harness** (`/provider use`) | Route **ALL** George's LLM calls through a provider | No local GPU, stronger model needed, mobile use |

The harness mode is the transformative feature: it lets George run on any machine — even without llama.cpp or Ollama installed — by sending every strategist, evaluator, router, specialist, and `/ask` call through a cloud API.

---

## Quick Start

```bash
# 1. Set your API key
/api keys set GOOGLE_AI_API_KEY AIza...

# 2. Activate the provider harness
/provider use google

# 3. Use George normally — all LLM calls go to Google AI
/ask what is a monad?

# 4. Switch back to local backend when done
/provider use local
```

---

## Supported Providers

| Provider | Aliases | Default Model | API Key | Free Tier? |
|----------|---------|---------------|---------|------------|
| **OpenAI** | `openai`, `gpt` | `gpt-4o-mini` | `OPENAI_API_KEY` | No (pay-as-you-go) |
| **Anthropic** | `anthropic`, `claude` | `claude-sonnet-4-20250514` | `ANTHROPIC_API_KEY` | No (pay-as-you-go) |
| **Google AI** | `google`, `gemini` | `gemini-2.0-flash` | `GOOGLE_AI_API_KEY` | **Yes** (generous free tier) |
| **Groq** | `groq` | `llama-3.3-70b-versatile` | `GROQ_API_KEY` | **Yes** (rate-limited) |
| **Mistral** | `mistral` | `mistral-large-latest` | `MISTRAL_API_KEY` | Limited free tier |
| **Together** | `together` | `Llama-3.3-70B-Instruct-Turbo` | `TOGETHER_API_KEY` | $5 free credit |
| **Perplexity** | `perplexity`, `pplx` | `sonar` | `PERPLEXITY_API_KEY` | No |
| **Cohere** | `cohere` | `command-r-plus` | `COHERE_API_KEY` | **Yes** (trial keys) |
| **DeepSeek** | `deepseek` | `deepseek-chat` | `DEEPSEEK_API_KEY` | $5 free credit |
| **xAI** | `xai`, `grok` | `grok-2` | `XAI_API_KEY` | $25/mo free on X Premium |

> **Best for getting started free:** Google AI (Gemini 2.0 Flash) or Groq (Llama 3.3 70B). Both have generous free tiers and fast responses.

---

## Setting Up API Keys

```bash
# Set a key
/api keys set OPENAI_API_KEY sk-proj-abc123...

# Check which providers are configured
/provider status

# List all stored keys (names only, values hidden)
/api keys list
```

Keys are stored in `~/.george/keys.conf` (or `$LODGE_DIR/.george/keys.conf`) with `chmod 600` permissions. They are never committed to git.

### Where to Get Keys

| Provider | URL | Notes |
|----------|-----|-------|
| OpenAI | https://platform.openai.com/api-keys | Requires payment method |
| Anthropic | https://console.anthropic.com/settings/keys | Requires payment method |
| Google AI | https://aistudio.google.com/apikey | Free, instant, no credit card |
| Groq | https://console.groq.com/keys | Free, instant |
| Mistral | https://console.mistral.ai/api-keys | Free tier available |
| Together | https://api.together.xyz/settings/api-keys | $5 free credit on signup |
| Perplexity | https://www.perplexity.ai/settings/api | Requires Perplexity Pro |
| Cohere | https://dashboard.cohere.com/api-keys | Free trial key available |
| DeepSeek | https://platform.deepseek.com/api_keys | $5 free credit on signup |
| xAI | https://console.x.ai | Free with X Premium+ |

---

## Commands Reference

### `/provider use` — Activate/Deactivate the Harness

```bash
# Activate a provider (all LLM calls routed through it)
/provider use google
/provider use anthropic
/provider use openai

# Activate with a specific model
/provider use google/gemini-2.5-pro
/provider use anthropic/claude-opus-4-20250514

# Deactivate (back to local llama.cpp/Ollama)
/provider use local
/provider use off
```

The harness setting **persists** across George sessions. If you close and reopen George, it will remember your active provider and skip local backend startup entirely.

### `/provider chat` — One-Shot Message

```bash
# Send a single message (doesn't activate the harness)
/provider chat google "explain quantum entanglement"
/provider chat anthropic "write a haiku about bash"

# Use a specific model for this message only
/provider chat google/gemini-2.5-pro "explain monads"
/provider chat openai/gpt-4o "debug this error: ..."
```

### `/provider model` — Manage Default Models

```bash
# Show the current default model for a provider
/provider model google

# Set a custom default model
/provider model google gemini-2.5-pro
/provider model openai gpt-4o
/provider model anthropic claude-opus-4-20250514

# Reset to built-in default
/provider model google clear
```

Model resolution order: **explicit arg** > **stored default** > **built-in fallback**.

### `/provider models` — List Available Models

```bash
# Query the provider's API for available models
/provider models openai
/provider models google
/provider models anthropic
```

### `/provider status` — Show Configuration

```bash
/provider status
```

Displays all configured providers with green dots, unconfigured ones with open circles, and the active harness (if any) with a star.

---

## How the Harness Works (Technical)

When you run `/provider use google`, three things happen:

1. **`GEORGE_PROVIDER`** is set to `"google"` (global variable + persisted to `keys.conf`)
2. **`llm_ensure()`** and **`llm_check()`** short-circuit — no local backend is started or checked
3. Every **`llm_generate()`**, **`llm_stream()`**, and **`llm_chat()`** call checks `GEORGE_PROVIDER` first, and if set, routes through `provider_chat()` instead of curl-to-llama-server

This means **all** George functionality works through the provider:

| George Feature | LLM Function | Calls per Task |
|----------------|-------------|----------------|
| `/ask` (conversation) | `llm_stream` | 1 |
| Strategist (decomposition) | `llm_generate` | 1-2 |
| Router (tool selection) | `llm_generate` | 1 per step |
| Specialist (command gen) | `llm_generate` | 1 per step |
| Evaluator (verdict) | `llm_generate` | 1-3 per milestone |
| Milestone reflections | `llm_generate` | 1 per milestone |
| Goal refinement | `llm_generate` | 0-1 per milestone |
| Guided completion | `llm_stream` | 0-1 (fallback) |

A typical **5-step task** generates roughly **8-15 API calls**. A complex multi-milestone task with retries could trigger **20-40+ calls**.

### System Prompt Passthrough

When the harness is active, George's system prompts (soul, identity, command catalogs, memory) are passed through to the cloud provider. All 10 providers accept system prompts:

- **OpenAI-compatible** (OpenAI, Groq, Mistral, Together, Perplexity, DeepSeek, xAI): `messages[0].role = "system"`
- **Anthropic**: Top-level `"system"` field
- **Google Gemini**: `"systemInstruction"` field
- **Cohere**: `"preamble"` field

### What the Harness Does NOT Do

- **No streaming**: Provider responses arrive all at once (not token-by-token). The `llm_stream` intercept prints the full response to the terminal when it arrives, but there's no progressive display.
- **No thinking tokens**: The `<think>` block parsing, thinking budgets, and thinking token multipliers are all skipped. Cloud models do their reasoning internally.
- **No sampling parameters**: Temperature, repeat_penalty, top_p, etc. are set to the provider defaults (temperature=0.3, max_tokens=4096) rather than George's per-scenario fine-tuning.
- **No model switching**: The harness uses one provider+model for all scenarios. Unlike local mode where George can switch between thinking and non-thinking models, the provider always uses the same model.
- **No token counting**: George's debug profiling (`/debug`) tracks request time but cannot count input/output tokens from provider responses.

---

## Cost Awareness

### Understanding API Pricing

Cloud LLM APIs charge **per token** — both input (your prompt) and output (the model's response). Pricing varies dramatically:

| Provider | Model | Input (per 1M tokens) | Output (per 1M tokens) | Notes |
|----------|-------|----------------------|------------------------|-------|
| **Google AI** | gemini-2.0-flash | **Free** | **Free** | 15 RPM free tier; 1500 RPD |
| **Google AI** | gemini-2.5-pro | $1.25 / $2.50 | $10.00 / $15.00 | 128K/longer context pricing |
| **Groq** | llama-3.3-70b | **Free** | **Free** | Rate-limited: 30 RPM, 14.4K tok/min |
| **DeepSeek** | deepseek-chat | $0.27 | $1.10 | Cache hits: $0.07 input |
| **OpenAI** | gpt-4o-mini | $0.15 | $0.60 | Cheapest OpenAI option |
| **OpenAI** | gpt-4o | $2.50 | $10.00 | High quality, high cost |
| **Anthropic** | claude-sonnet-4 | $3.00 | $15.00 | Strong reasoning |
| **Anthropic** | claude-opus-4 | $15.00 | $75.00 | **Extremely expensive** |
| **Mistral** | mistral-large | $2.00 | $6.00 | Good multilingual |
| **Together** | llama-3.3-70b-turbo | $0.88 | $0.88 | Open-source models |
| **Perplexity** | sonar | $1.00 | $1.00 | Includes web search |
| **Cohere** | command-r-plus | $2.50 | $10.00 | Free trial keys |
| **xAI** | grok-2 | $2.00 | $10.00 | Free with X Premium+ |

> **Prices are approximate and change frequently.** Always check the provider's current pricing page.

### Cost Estimates for George Operations

George's prompts include system prompts (~300-5000 tokens), memory context, command catalogs, and conversation history. Here are rough estimates:

| Operation | API Calls | ~Input Tokens | ~Output Tokens | Cost (gpt-4o-mini) | Cost (gemini-flash) |
|-----------|-----------|---------------|----------------|---------------------|---------------------|
| `/ask` (simple question) | 1 | ~500-1,000 | ~200-500 | ~$0.0004 | **Free** |
| `/ask` (with context) | 1 | ~1,500-3,000 | ~500-2,000 | ~$0.002 | **Free** |
| 5-step task | 8-15 | ~10,000-30,000 | ~3,000-10,000 | ~$0.01-0.03 | **Free** |
| Complex multi-milestone | 20-40 | ~50,000-100,000 | ~10,000-30,000 | ~$0.03-0.10 | **Free** |
| Heavy coding session (1hr) | 50-150 | ~150,000-500,000 | ~30,000-100,000 | ~$0.10-0.50 | **Free** |

### Cost-Saving Tips

1. **Start with free providers**: Google AI (Gemini 2.0 Flash) and Groq are both free and fast. This is the recommended starting point.

2. **Use cheap defaults**: If you need paid providers, use the cheapest model available:
   ```bash
   /provider model openai gpt-4o-mini      # $0.15/$0.60 per 1M tokens
   /provider model deepseek deepseek-chat   # $0.27/$1.10 per 1M tokens
   ```

3. **Avoid expensive models for routine work**: Don't use `claude-opus-4` or `gpt-4o` as your harness provider for general tasks. Reserve them for one-shot `/provider chat` calls when you need their quality.

4. **Switch back to local when possible**: If you have llama.cpp working, use `local` for routine coding and only switch to cloud for complex reasoning:
   ```bash
   /provider use local    # Day-to-day coding (free, unlimited)
   /provider use google   # When you need Gemini's power
   ```

5. **Monitor your usage**: Check your provider dashboard regularly. Set billing alerts:
   - OpenAI: Settings → Organization → Billing → Usage limits
   - Anthropic: Console → Plans & Billing
   - Google AI: No alerts needed on free tier (just rate limits)

6. **Limit agent complexity**: George's agent loop generates the most API calls. Reduce with:
   ```bash
   /limits max_steps 3      # Fewer steps per milestone
   /limits milestones 2     # Fewer milestones per task
   /limits rewrite_rounds 1 # Fewer goal refinements
   ```

### Rate Limits

Free tiers have rate limits that can interrupt George mid-task:

| Provider | Free Tier Limits | What Happens When Hit |
|----------|-----------------|----------------------|
| Google AI | 15 requests/min, 1,500/day | 429 error, George reports failure |
| Groq | 30 requests/min, 14,400 tokens/min | 429 error, brief pause needed |
| Together | $5 credit, then pay | Credit exhausted → 402 error |
| DeepSeek | $5 credit, then pay | Credit exhausted → 402 error |
| Cohere | 20 requests/min (trial) | 429 error |

If George reports errors during a task, check if you've hit rate limits. Wait 60 seconds and try again, or switch to a different provider.

---

## Provider Comparison — Which to Choose?

### Best for Free Usage
- **Google AI** (`gemini-2.0-flash`): Most generous free tier, fast, good quality. Best default for harness mode.
- **Groq** (`llama-3.3-70b-versatile`): Free, extremely fast inference. Rate limits can bite during longer agent tasks.

### Best for Quality
- **Anthropic** (`claude-sonnet-4`): Excellent reasoning, especially for code. Expensive.
- **OpenAI** (`gpt-4o`): Strong all-around. Expensive.
- **Google AI** (`gemini-2.5-pro`): Strong reasoning, inline search. Moderate cost.

### Best for Cost/Quality Ratio
- **DeepSeek** (`deepseek-chat`): Very cheap, surprisingly good for code. Chinese company (data consideration).
- **OpenAI** (`gpt-4o-mini`): Cheap, reliable, good enough for most George tasks.
- **Together** (`llama-3.3-70b-turbo`): Open-source models at low cost.

### Best for Specific Use Cases
- **Perplexity** (`sonar`): Includes web search — useful for research tasks.
- **Mistral** (`mistral-large`): Strong multilingual support.
- **xAI** (`grok-2`): Free with X Premium+; good general model.

---

## Troubleshooting

### "No API key configured for ..."
```bash
/api keys set <KEY_NAME> <your-key>
# Example: /api keys set GOOGLE_AI_API_KEY AIza...
```

### Provider returns errors during agent task
The agent may be hitting rate limits. Options:
1. Wait 60 seconds and retry
2. Switch to a different provider: `/provider use openai`
3. Reduce agent steps: `/limits max_steps 3`

### "empty or blocked response"
The API returned 200 OK but no content. Common causes:
- Content policy filter triggered (try rephrasing)
- Model overloaded (retry)
- Invalid model name: `/provider model google clear` to reset

### Harness active but George seems slow
Provider calls have network latency (100-3000ms per call). A 10-call agent task takes 1-30 seconds on cloud vs near-instant on a fast local GPU. This is normal.

### George starts without local backend when I don't want that
The harness persists. To clear it:
```bash
/provider use local
```
Or manually remove from `keys.conf`:
```bash
# In .george/keys.conf, delete: GEORGE_PROVIDER=...
```

### Provider works for /ask but fails during agent tasks
Some providers (especially free tiers) have aggressive rate limits. The agent fires many rapid calls. Try:
1. A paid provider or higher-limit tier
2. Groq can handle short bursts well
3. Google AI's 15 RPM limit works for most tasks

---

## Security Notes

- API keys are stored in `.george/keys.conf` with `chmod 600` (owner read/write only)
- Keys are never logged, displayed, or committed to git
- The `.george/` directory is gitignored by default
- API calls use HTTPS (TLS) to all provider endpoints
- The `PROVIDER_TIMEOUT` (default: 120s) prevents hung connections
- No telemetry or usage data is sent anywhere besides the provider API itself

---

## Architecture Summary

```
User Input
    ↓
lodge REPL → /ask or agent task
    ↓
llm_generate() / llm_stream() / llm_chat()
    ↓
┌─ GEORGE_PROVIDER set? ─────────────────┐
│                                         │
│  YES → provider_chat()                  │  NO → _llm_detect_backend()
│         ↓                               │         ↓
│    dispatcher (case $provider)          │    llamacpp or ollama path
│         ↓                               │         ↓
│    openai_chat / google_chat / ...      │    curl → llama-server / Ollama
│         ↓                               │         ↓
│    curl → cloud API                     │    SSE streaming + think parsing
│         ↓                               │         ↓
│    response text (all at once)          │    token-by-token response
│                                         │
└─────────────────────────────────────────┘
    ↓
Agent/REPL receives response
```

Files involved:
- **`lib/providers.sh`** — All provider functions, harness control, dispatcher
- **`lib/llm.sh`** — Intercepts at `llm_generate`, `llm_stream`, `llm_chat`, `llm_ensure`, `llm_check`
- **`lib/api.sh`** — HTTP client (`api_post`), key storage (`api_get_key`/`api_set_key`)
- **`lodge`** — `/provider` command handler, startup bootstrap
- **`.george/keys.conf`** — API keys and persisted `GEORGE_PROVIDER` setting
