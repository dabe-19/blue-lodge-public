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

## 4. Routing & Intelligence Presets

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

## 5. Programmatic Invocation Example

To run a task completely locked down to a local workspace, skipping web research, using low thinking budget to save tokens, and forcing abstract mode:

```bash
docker exec -it -u george \
  -e LODGE_THINK=1 \
  -e LODGE_THINK_LEVEL=1 \
  -e AGENT_TASK_MODE=1 \
  -e AGENT_WEB_UNLOCK_ABSTRACT=99 \
  -e AGENT_MAX_STEPS=15 \
  george-sandbox ./lodge run 'Inspect and refactor local code in main.sh'
```
