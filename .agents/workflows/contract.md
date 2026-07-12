### Feature Overview
Optimize the LLM harness for NVIDIA Nemotron 3 Nano GGUF model and enable dynamic model-switching fallback for vision scenarios:
1. **Nemotron 3 Configuration Fix**: Update the GGUF stop token from `<|eot_id|>` to `<|im_end|>` and map the chat template to `chatml` (matching the model's native format).
2. **Scenario-Based Vision Fallback**: Add a custom `vision` scenario to `models_for_scenario` that dynamically resolves to a vision-capable model (e.g. `gemma4-e4b-inst`) when the active primary model is text-only.
3. **Vision Scenario Dispatch**: Modify `/vision` to execute under `LLM_SCENARIO=vision` instead of `ask`.
4. **Unit Test Updates**: Update assertions in `tests/test_models.sh` and `tests/test_llm.sh` to match the corrected template/token mappings.

### Layer Changes

#### [MODIFY] [lib/models.sh](file:///home/wsl-ops/blue-lodge/lib/models.sh)
- Update `nemotron3-nano-4b-inst` entry in `_MODELS_REGISTRY` to use `<|im_end|>` stop token.
- Update `_MODELS_CHAT_TEMPLATE_BY_KEY[nemotron3-nano-4b-inst]` to `"chatml"`.
- Update `_models_chat_template_name` to map `*nemotron*3*` to `"chatml"`.
- Update `models_for_scenario` to resolve `vision` scenario with fallback to `blue-lodge-gemma4-inst:4b`.

#### [MODIFY] [commands/vision.sh](file:///home/wsl-ops/blue-lodge/commands/vision.sh)
- Change `LLM_SCENARIO=ask` to `LLM_SCENARIO=vision`.

#### [MODIFY] [tests/test_models.sh](file:///home/wsl-ops/blue-lodge/tests/test_models.sh)
- Update Nemotron chat template assertion to expect `chatml`.

#### [MODIFY] [tests/test_llm.sh](file:///home/wsl-ops/blue-lodge/tests/test_llm.sh)
- Update Nemotron chat template name and stop token assertions.

### Scope Boundaries
Focuses strictly on model catalog correction and `/vision` command scenario routing. No inference servers or provider endpoints are modified.

### Touched Layers (Handoff Routing)
- **core-specialist**: yes — update `lib/models.sh` catalog and routing.
- **commands-specialist**: yes — update `commands/vision.sh` scenario.
- **ui-specialist**: no — no UI updates.
- **tests-specialist**: yes — update unit test assertions.

### Tooling Layer (Provisioning)
- **Tooling**: no

### Functional Verification
- **Verification**: yes — run the test suite inside the container.

### Security
- **Security**: no

### Style
- **Style**: no
