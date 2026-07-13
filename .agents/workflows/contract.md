### Feature Overview
Improve the test runner concurrency and the agent's image acquisition/analysis capabilities by:
1. **Enabling Test Concurrency by Default**: Modify `tests/run_all.sh` to allow overlapping runs by default (setting `RUN_ALL_ALLOW_CONCURRENT` default to `1`), avoiding blocking locks during rapid iterations.
2. **Correcting Router Command Eligibility**: Add `download`, `vision`, and other registered commands to the `eligible` command array in `_agent_router_eligibility_pass` in `lib/agent.sh`. This ensures they can be shortlisted and selected by the LLM and fast-route routers instead of being gated out.
3. **Optimizing Image Acquisition and Analysis Guidance**:
   * Add `vision` to the `advisory` catalog returned by the eligibility pass.
   * Standardize and correct the `/vision` syntax spec in `lib/agent.sh` to use consistent placeholder names.
   * Add explicit guidance and clear flow chain examples in both `lib/agent.sh` and `lib/commands.sh` detailing how to use `/download` to fetch web images locally and run `/vision` on them, or run `/vision` directly on the URL.

### Layer Changes

#### [MODIFY] [tests/run_all.sh](file:///home/wsl-ops/blue-lodge/tests/run_all.sh)
* Change the default value check for `RUN_ALL_ALLOW_CONCURRENT` from `0` to `1` so concurrent test executions are permitted by default.

#### [MODIFY] [lib/agent.sh](file:///home/wsl-ops/blue-lodge/lib/agent.sh)
* Add `download`, `vision`, `pgp`, `phone`, `container`, `sandbox`, `wallet`, `backup`, `secret`, and `gsuite` to the `eligible` commands array in `_agent_router_eligibility_pass`.
* Add `vision` to `advisory_json` list.
* Align syntax placeholder `<image>` to `<image_path_or_url>` in the `vision` command prompt card.
* Update prompt examples and flow chains to explicitly highlight the image acquisition flow: `/web scrape-images <url>` -> `/download <image_url>` -> `/vision <local_image_path>`.

#### [MODIFY] [lib/commands.sh](file:///home/wsl-ops/blue-lodge/lib/commands.sh)
* Update flow chain documentation and help notes to emphasize the download and local vision analysis workflow.

### Scope Boundaries
* Focuses strictly on `tests/run_all.sh` concurrency guard defaults and `lib/agent.sh` / `lib/commands.sh` routing eligibility and prompt catalog mappings.
* No changes to underlying tool implementations.

### Touched Layers (Handoff Routing)
- **core-specialist**: yes — update `lib/agent.sh` and `lib/commands.sh` eligibility, specs, and prompts.
- **commands-specialist**: no — no changes to command behavior scripts.
- **ui-specialist**: no — no UI updates.
- **tests-specialist**: yes — update `tests/run_all.sh` process guard default.

### Tooling Layer (Provisioning)
- **Tooling**: no

### Functional Verification
- **Verification**: yes — run the unit tests inside the CUDA sandbox.

### Security
- **Security**: no

### Style
- **Style**: no
