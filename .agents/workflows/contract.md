# Contract: Fix Gemma 4 <unused25> Token Issue

## Feature Overview
Implement API-level stop token enforcement for the `llamacpp` backend to act as a safety net against model tokenizer loop failures, and provide instructions to recompile/update `llama-server` to fix the Gemma 4 vocab compatibility bug.

## Layer Changes

### Core Engine Layer
- **[llm.sh](file:///home/wsl-ops/blue-lodge/lib/llm.sh)**: Update payload builder and API calls to pass the active model's `stop` token in the request payload.

### Tooling Layer
- **[quartermaster.agent.md](file:///home/wsl-ops/blue-lodge/.agents/workflows/quartermaster.agent.md)**: Document/implement environment validation and re-build steps for `llama-server`.

## Touched Layers (Handoff Routing)
- **core-specialist**: yes — implement stop token passing in `lib/llm.sh`.
- **commands-specialist**: no
- **ui-specialist**: no
- **tests-specialist**: no

## Tooling Layer (Provisioning)
- **Tooling**: yes — recompile/update `llama-server` to resolve vocab bugs.

## Functional Verification
- **Verification**: yes — run `scripts/validate-gpu.sh` on `gemma4-e4b-inst` and verify test suite passes.

## Security
- **Security**: no

## Style
- **Style**: no
