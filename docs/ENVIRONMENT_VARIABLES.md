# Environment Variables Library Reference Guide

This document lists all user-configurable environment variables available in Blue Lodge. You can use these parameters to customize model behaviors, thresholds, execution guards, and routing paths programmatically.

---

## 1. LLM & Reasoning Parameters

### `LODGE_THINK`
- **Description**: Enable or disable model thinking (reasoning) capabilities for compatible reasoning models.
- **Type**: Boolean (`0` or `1`)
- **Default**: `1` (enabled)
- **Usage Example**:
  ```bash
  LODGE_THINK=0 ./lodge run "Direct objective"
  ```

### `LODGE_THINK_STREAM`
- **Description**: Stream the model's thinking process to the terminal in real-time.
- **Type**: Boolean (`0` or `1`)
- **Default**: `0` (disabled in non-interactive terminals, enabled by default in TTY environments)
- **Usage Example**:
  ```bash
  LODGE_THINK_STREAM=1 ./lodge run "Search for company info"
  ```

### `LODGE_NOTHINK`
- **Description**: Bypasses the thinking prompt instruction block entirely for instruct scenarios.
- **Type**: Boolean (`0` or `1`)
- **Default**: `0`
- **Usage Example**:
  ```bash
  LODGE_NOTHINK=1 ./lodge run "Simple task"
  ```

### `LODGE_THINK_LEVEL`
- **Description**: Sets the depth of the model's reasoning/thinking monologue. Maps both to prompt guidelines and max reasoning token budgets.
- **Type**: Integer or String (`1` / `low`, `2` / `medium`, `3` / `high`)
- **Default**: `2` (`medium`)
- **Levels**:
  - `1` / `low`: Sets think budget to `1024` tokens. Instructs model to respond directly and concisely.
  - `2` / `medium`: Sets think budget to `4096` tokens. Default reasoning guidelines.
  - `3` / `high`: Sets think budget to `16384` tokens. Instructs model to reason exhaustively, checking edge cases and alternative approaches.
- **Usage Example**:
  ```bash
  LODGE_THINK_LEVEL=3 ./lodge run "Exhaustively audit security code"
  ```

### `LODGE_MODEL`
- **Description**: Sourced registry model to use for core agent reasoning.
- **Type**: String (e.g. `blue-lodge`, `blue-lodge-qwen35-think:4b`)
- **Default**: `blue-lodge`
- **Usage Example**:
  ```bash
  LODGE_MODEL="blue-lodge-qwen35-think:4b" ./lodge run "Solve problem"
  ```

---

## 2. Gating and Unlock Thresholds

### `AGENT_TASK_MODE`
- **Description**: Force a specific classification for the task type.
- **Type**: Integer (`0`=auto-classifier, `1`=abstract, `2`=concrete, `3`=combined)
- **Default**: `0` (automatically classified by the LLM)
- **Usage Example**:
  ```bash
  AGENT_TASK_MODE=2 ./lodge run "Write code in main.py"
  ```

### `AGENT_WEB_UNLOCK_ABSTRACT`
- **Description**: Number of milestones to complete before the `/web` search and scrape commands are unlocked for **abstract** tasks.
- **Type**: Integer
- **Default**: `1`
- **Usage Example**:
  ```bash
  AGENT_WEB_UNLOCK_ABSTRACT=0 ./lodge run "Examine workspace files"
  ```

### `AGENT_WEB_UNLOCK_COMBINED`
- **Description**: Number of milestones to complete before the `/web` search and scrape commands are unlocked for **combined** tasks.
- **Type**: Integer
- **Default**: `0` (immediate unlock since combined tasks require research)
- **Usage Example**:
  ```bash
  AGENT_WEB_UNLOCK_COMBINED=1 ./lodge run "Find latest news and write report"
  ```

### `AGENT_GIT_UNLOCK_ABSTRACT`
- **Description**: Number of completed milestones before `/git` commands are unlocked for **abstract** tasks.
- **Type**: Integer
- **Default**: `1`
- **Usage Example**:
  ```bash
  AGENT_GIT_UNLOCK_ABSTRACT=0 ./lodge run "Refactor code"
  ```

### `AGENT_GIT_UNLOCK_COMBINED`
- **Description**: Number of completed milestones before `/git` commands are unlocked for **combined** tasks.
- **Type**: Integer
- **Default**: `1`
- **Usage Example**:
  ```bash
  AGENT_GIT_UNLOCK_COMBINED=0 ./lodge run "Implement feature and commit"
  ```

---

## 3. Loop Guards and Thresholds

### `AGENT_MAX_STEPS`
- **Description**: Upper limit of completed milestones before the macro agent loop terminates automatically (to prevent runaways).
- **Type**: Integer
- **Default**: `40`
- **Usage Example**:
  ```bash
  AGENT_MAX_STEPS=10 ./lodge run "Short task"
  ```

### `AGENT_MAX_MILESTONE_RETRIES`
- **Description**: Maximum retry count for a failed milestone before giving up or triggering pressure relief.
- **Type**: Integer
- **Default**: `3`
- **Usage Example**:
  ```bash
  AGENT_MAX_MILESTONE_RETRIES=2 ./lodge run "Failable action"
  ```

### `AGENT_MAX_CMD_FAMILY`
- **Description**: Maximum number of consecutive milestones that are allowed to call the same tool command group (e.g., `/read`, `/web`). Prevents repetitive task stagnation.
- **Type**: Integer
- **Default**: `5`
- **Usage Example**:
  ```bash
  AGENT_MAX_CMD_FAMILY=3 ./lodge run "Batch work"
  ```

### `AGENT_WEB_SEARCH_CONSEC_MAX`
- **Description**: Maximum consecutive `/web search` actions allowed before the agent is programmatically forced to perform `/web scrape` or `/web fetch` on the search results.
- **Type**: Integer
- **Default**: `2`
- **Usage Example**:
  ```bash
  AGENT_WEB_SEARCH_CONSEC_MAX=1 ./lodge run "Deep scrape"
  ```

### `AGENT_PRESSURE_RELIEF`
- **Description**: Number of consecutive milestones that are allowed to be skipped during evaluation before the agent triggers pressure relief (skips to next target or rewrites task).
- **Type**: Integer
- **Default**: `2`
- **Usage Example**:
  ```bash
  AGENT_PRESSURE_RELIEF=3 ./lodge run "Difficult verification"
  ```

---

## 4. Routing & Preset Variables

### `AGENT_SMART_ROUTE`
- **Description**: Controls routing presets and fallback mechanisms during command dispatch.
- **Type**: Integer
  - `0`: Smart routing disabled (literal match only)
  - `1`: Post-dispatch reroute only
  - `2`: Fuzzy keyword catalog injection only
  - `3`: Combined (both post-dispatch and keyword injection)
- **Default**: `3`
- **Usage Example**:
  ```bash
  AGENT_SMART_ROUTE=0 ./lodge run "Deterministic script run"
  ```

### `AGENT_EVAL_MODE`
- **Description**: Task completion validation mode.
- **Type**: String (`auto` | `interactive` | `disabled`)
- **Default**: `auto` (evaluated programmatically by model)
- **Usage Example**:
  ```bash
  AGENT_EVAL_MODE=interactive ./lodge run "UI design check"
  ```

---

## 5. Remote Host & SSH Tunneling

If you run model inference on a remote server, Blue Lodge can launch backends, forward ports, and manage the execution lifecycle over SSH.

### `REMOTE_SSH_TARGET`
- **Description**: The remote host SSH connection target string.
- **Type**: String (e.g. `user@host.example.com` or SSH config alias)
- **Default**: Unset
- **Usage Example**:
  ```bash
  REMOTE_SSH_TARGET="ubuntu@10.0.0.50" ./lodge run "Audit codebase"
  ```

### `REMOTE_SSH_PORT`
- **Description**: The SSH daemon port on the remote target.
- **Type**: Integer
- **Default**: `22`

### `REMOTE_SSH_KEY`
- **Description**: Path to the private SSH key file used to establish the connection.
- **Type**: String (file path)
- **Default**: `$GEORGE_DIR/ssh/id_ed25519`

### `REMOTE_JUMP_HOST`
- **Description**: Optional SSH Jump Host target (bastion server) if the GPU server is within a private subnet. Passes to `ssh -J`.
- **Type**: String
- **Default**: Unset

### `REMOTE_FORWARD_HOST`
- **Description**: Local target host for SSH tunnel port forwarding.
- **Type**: String
- **Default**: `localhost`

### `REMOTE_LLAMACPP_BIN`
- **Description**: Path to the `llama-server` binary on the remote server. If unset, it will attempt automatic resolution.
- **Type**: String
- **Default**: Unset

### `REMOTE_LLAMACPP_PORT`
- **Description**: The inference port assigned on the remote host.
- **Type**: Integer
- **Default**: `8080`

### `REMOTE_LOCAL_LLAMACPP_PORT`
- **Description**: The local forward port on the client client side where the SSH tunnel will expose the remote `llama-server`.
- **Type**: Integer
- **Default**: `8080`

### `REMOTE_GPU_BACKEND`
- **Description**: Backend type to load on the remote llama-server.
- **Type**: String (`auto` | `cuda` | `vulkan` | `cpu`)
- **Default**: `auto`

### `REMOTE_LLAMACPP_CTX_SIZE`
- **Description**: Remote model execution context length limit.
- **Type**: Integer
- **Default**: `32768`

---

## 6. Speculative Decoding & MTP Models

Speculative decoding accelerates inference of larger thinking models by using a smaller draft model or Multi-Token Prediction (MTP) model to verify sequences of tokens.

### `LLAMA_CPP_SPEC_MTP`
- **Description**: Enable speculative decoding with Multi-Token Prediction (MTP) draft models.
- **Type**: Boolean (`0` or `1`)
- **Default**: `0` (disabled)
- **Usage Example**:
  ```bash
  LLAMA_CPP_SPEC_MTP=1 ./lodge run "Generate large code module"
  ```

### `LLAMA_CPP_SPEC_DRAFT_N_MAX`
- **Description**: Maximum number of draft tokens predicted per spec loop execution step.
- **Type**: Integer
- **Default**: `4`

### `LLAMA_CPP_DRAFT_MODEL`
- **Description**: Absolute path to a local GGUF draft model file to use as the speculative decoder.
- **Type**: String (file path)
- **Default**: Unset

### `LLAMA_CPP_SPEC_DRAFT_HF`
- **Description**: Sourced Hugging Face model repository and file tag to download and use as the draft MTP model (e.g. `unsloth/gemma-4-E2B-it-qat-GGUF:mtp-gemma-4-E2B-it`).
- **Type**: String
- **Default**: Unset

---

## 7. Cloud Integration & Provider API Keys

When local execution is bypassed, Blue Lodge can route queries directly to cloud models. Sourced keys are validated in precedence order: Environment Variables first, then local `keys.conf` file records.

### `GEORGE_PROVIDER`
- **Description**: Set to route reasoning calls directly through a cloud provider model instead of local llama-server/Ollama.
- **Type**: String (`openai` | `anthropic` | `google` | `groq` | `mistral` | `together` | `perplexity` | `cohere` | `deepseek` | `xai`)
- **Default**: Unset (use local backends)
- **Usage Example**:
  ```bash
  GEORGE_PROVIDER="anthropic" ./lodge run "Perform security audit"
  ```

### `PROVIDER_MODEL_<PROVIDER>`
- **Description**: Override the default model used for a specific cloud provider.
- **Type**: String
- **Default**: Default models (e.g. `claude-3-5-sonnet`, `gpt-4o`, `gemini-2.5-pro`)
- **Usage Example**:
  ```bash
  PROVIDER_MODEL_ANTHROPIC="claude-3-5-haiku" ./lodge run "Quick check"
  ```

### Integration Key Reference Table

| Key Name | Description | Base URL Override |
|---|---|---|
| `OPENAI_API_KEY` | OpenAI authentication key | `OPENAI_API_BASE` |
| `ANTHROPIC_API_KEY` | Anthropic Claude key | `ANTHROPIC_API_BASE` |
| `GEMINI_API_KEY` / `GOOGLE_API_KEY` | Google Gemini key | — |
| `DEEPSEEK_API_KEY` | DeepSeek API key | — |
| `GROQ_API_KEY` | Groq API key | — |
| `MISTRAL_API_KEY` | Mistral client key | — |
| `TOGETHER_API_KEY` | Together AI key | — |
| `PERPLEXITY_API_KEY` | Perplexity Sonar API key | — |
| `COHERE_API_KEY` | Cohere Command key | — |
| `XAI_API_KEY` | xAI Grok key | — |
| `SERPER_API_KEY` / `SERPER_API` | Google Search API key | — |

---

## 8. Programmatic Invocation Examples

### Example A: Fully Local & Token-Saver Mode
- Forces abstract local mode, disables web access, limits thinking depth, and restricts step size to save local GPU compute.
```bash
docker exec -it -u george \
  -e LODGE_THINK=1 \
  -e LODGE_THINK_LEVEL=1 \
  -e AGENT_TASK_MODE=1 \
  -e AGENT_WEB_UNLOCK_ABSTRACT=99 \
  -e AGENT_MAX_STEPS=15 \
  george-sandbox ./lodge run 'Inspect and refactor local code in main.sh'
```

### Example B: Speculative Decoding GPU Mode
- Runs locally utilizing gemma-4 E2B main model and accelerates inference via the MTP draft model downloaded from Hugging Face.
```bash
docker exec -it -u george \
  -e LODGE_THINK=1 \
  -e LODGE_THINK_LEVEL=2 \
  -e LLAMA_CPP_SPEC_MTP=1 \
  -e LLAMA_CPP_SPEC_DRAFT_HF="unsloth/gemma-4-E2B-it-qat-GGUF:mtp-gemma-4-E2B-it" \
  george-sandbox ./lodge run 'Generate a comprehensive Rust library for network parsing'
```

### Example C: Remote SSH GPU Server Forwarding
- Establishes a secure SSH tunnel to a GPU server, starts the remote llama-server with Flash Attention on, and binds the inference port locally to `8080`.
```bash
docker exec -it -u george \
  -e REMOTE_SSH_TARGET="admin@gpu-node.internal" \
  -e REMOTE_SSH_PORT=2222 \
  -e REMOTE_SSH_KEY="/home/george/.ssh/gpu_key" \
  -e REMOTE_FLASH_ATTN="on" \
  -e REMOTE_GPU_BACKEND="cuda" \
  george-sandbox ./lodge run 'Run E2E model evaluation and record findings'
```

### Example D: Cloud Claude Gated Pipeline
- Bypasses local backends to run the entire loop via Anthropic API using your custom model target.
```bash
docker exec -it -u george \
  -e GEORGE_PROVIDER="anthropic" \
  -e PROVIDER_MODEL_ANTHROPIC="claude-3-5-sonnet-latest" \
  -e ANTHROPIC_API_KEY="sk-ant-abc..." \
  george-sandbox ./lodge run 'Analyze repository structure and draft API endpoints documentation'
```
