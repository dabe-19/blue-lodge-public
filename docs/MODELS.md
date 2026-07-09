# Blue Lodge Model Catalog (2026)

Blue Lodge now ships a curated 2026 open-weight catalog focused on modern low-memory models and a smaller, maintainable family set.

## Defaults

- Primary default: `blue-lodge-gemma4-inst:4b`
- Secondary default: `blue-lodge-gemma4-inst:4b`
- Single-model mode remains enabled by default (`LODGE_SINGLE_MODEL=1`).
- Runtime menu order: `gemma4-e4b-inst`, `qwen35-4b-inst`, `qwen35-4b-think`, `granite41-3b-inst`, `nemotron3-nano-4b-inst`, `gemma4-e2b-inst`, `qwen35-2b-inst`, `gemma4-12b-inst`, `qwen35-9b-inst`, `granite41-8b-inst`.

## Curated Menu

| Key | Base Image | Family | Role | Tier | Notes |
| --- | --- | --- | --- | --- | --- |
| `gemma4-e2b-inst` | `hf.co/unsloth/gemma-4-E2B-it-qat-GGUF:UD-Q4_K_XL` | Gemma 4 | instruct | edge | Smallest modern default candidate |
| `gemma4-e4b-inst` | `hf.co/unsloth/gemma-4-E4B-it-qat-GGUF:UD-Q4_K_XL` | Gemma 4 | instruct | edge | Best phone-class balance |
| `qwen35-2b-inst` | `hf.co/unsloth/Qwen3.5-2B-GGUF:UD-Q8_K_XL` | Qwen 3.5 | instruct | edge | Low-memory utility model |
| `qwen35-4b-inst` | `hf.co/unsloth/Qwen3.5-4B-GGUF:UD-Q4_K_XL` | Qwen 3.5 | instruct | edge | Fast coding and ops |
| `qwen35-4b-think` | `hf.co/unsloth/Qwen3.5-4B-GGUF:UD-Q4_K_XL` | Qwen 3.5 | thinking | edge | Native `/no_think` support |
| `granite41-3b-inst` | `hf.co/unsloth/granite-4.1-3b-GGUF:Q4_K_M` | Granite 4.1 | instruct | edge | Structured deterministic output |
| `nemotron3-nano-4b-inst` | `hf.co/unsloth/NVIDIA-Nemotron-3-Nano-4B-GGUF:Q4_K_M` | Nemotron 3 | instruct | edge | Modern NVIDIA edge model |
| `gemma4-12b-inst` | `hf.co/unsloth/gemma-4-12B-it-qat-GGUF:UD-Q4_K_XL` | Gemma 4 | instruct | central | Central quality tier |
| `qwen35-9b-inst` | `hf.co/unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL` | Qwen 3.5 | instruct | central | Strong central coding tier |
| `granite41-8b-inst` | `hf.co/unsloth/granite-4.1-8b-GGUF:Q4_K_M` | Granite 4.1 | instruct | central | Central structured reasoning tier |

## Families

- `gemma4`: edge E2B/E4B and central 12B instruct
- `qwen35`: edge and central instruct plus edge thinking variant
- `granite41`: edge 3B and central 8B instruct
- `nemotron3`: edge 4B instruct

## Roles and Tiers

- **Edge tier**: `gemma4-e2b-inst`, `gemma4-e4b-inst`, `qwen35-2b-inst`, `qwen35-4b-inst`, `qwen35-4b-think`, `granite41-3b-inst`, `nemotron3-nano-4b-inst`
- **Central tier**: `gemma4-12b-inst`, `qwen35-9b-inst`, `granite41-8b-inst`
- **Thinking support**: only `qwen35-4b-think` advertises native think-flag support in the curated menu
- **Vision support**: `gemma4-e4b-inst` and `gemma4-12b-inst`

## Naming Map

The menu now separates the **registry key** from the **Ollama model name**:

| Registry Key | Ollama Model Name |
| --- | --- |
| `gemma4-e2b-inst` | `blue-lodge-gemma4-inst:2b` |
| `gemma4-e4b-inst` | `blue-lodge-gemma4-inst:4b` |
| `qwen35-2b-inst` | `blue-lodge-qwen35-inst:2b` |
| `qwen35-4b-inst` | `blue-lodge-qwen35-inst:4b` |
| `qwen35-4b-think` | `blue-lodge-qwen35-think:4b` |
| `granite41-3b-inst` | `blue-lodge-granite41-inst:3b` |
| `nemotron3-nano-4b-inst` | `blue-lodge-nemotron3-inst:4b` |
| `gemma4-12b-inst` | `blue-lodge-gemma4-inst:12b` |
| `qwen35-9b-inst` | `blue-lodge-qwen35-inst:9b` |
| `granite41-8b-inst` | `blue-lodge-granite41-inst:8b` |

## Installer Family Presets

The installer now uses this recommended family preset for additional downloads:

- `qwen35 granite41 nemotron3`

`gemma4` is treated as the default boot family and installed via the default-model prompt flow.

## Commands

```bash
# Show current model menu and active slots
lodge /models list

# Select a model for primary or secondary slot
lodge /models select primary qwen35-4b-think
lodge /models select secondary gemma4-e4b-inst

# Use single-model mode
lodge /models single gemma4-e4b-inst
```

## Thinking and Vision Notes

- Native think-flag support is enabled for `qwen35-4b-think`.
- Gemma 4 vision capability is enabled for:
  - `gemma4-e4b-inst`
  - `gemma4-12b-inst`
- All other models in this catalog are treated as text-only.

## Backward Compatibility

Legacy pre-2026 model keys were intentionally removed from the curated menu.

If you have old `LODGE_MODEL_*` values in your shell profile, update them to one of the keys listed above.
