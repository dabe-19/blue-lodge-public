# Contributing to Blue Lodge & the Guild App Store

Welcome! Blue Lodge is designed around a clean **Three-Tier Architecture** so you can customize your own node freely, contribute improvements back to core, and publish your own independent Guild modules.

---

## 1. Customizing Your Node Without Forking Core (Foliage vs. Heartwood)

Before editing tracked core files, check whether your customization belongs in node-local **Foliage** (`.george/`, gitignored):

- **Agent Name & Persona:** Set `LODGE_AGENT_NAME`, `LODGE_AGENT_TITLE`, and `LODGE_AGENT_IDENTITY_MANDATE` in `.george/configs/lodge.conf` (or drop a custom `.george/soul.override.md`). No need to modify `lib/core/context_engine.sh` or `soul.md`.
- **Kubernetes Host Paths:** Run `LODGE_HOST_HOME=$HOME MODELS_DIR=$HOME/models bash deploy/k8s/render.sh` and `kubectl apply -f deploy/k8s/.rendered/`. Never commit personal `/home/<username>` paths to `deploy/k8s/*.yaml`.
- **Hardware / Node-Specific Branches:** Use `/ecotype init <node-name>` to work on `ecotype/<node-name>`, pull upstream updates via `/ecotype sync`, and promote clean Heartwood changes via `/ecotype promote`.

---

## 2. Submitting Core Pull Requests

1. Branch off `develop` using Conventional Commits:
   - `feat(scope): ...` — triggers a **minor** SemVer bump on release
   - `fix(scope): ...` / `perf(scope): ...` — triggers a **patch** SemVer bump on release
   - `feat!(scope): ...` or `BREAKING CHANGE:` — triggers a **major** SemVer bump
2. Keep the OKF Knowledge Graph synchronized:
   ```bash
   python3 okf/generate_okf_graph.py
   bash tests/test_okf.sh
   ```
3. Run syntax & security checks before opening a PR:
   ```bash
   find lib commands tests -name "*.sh" -exec bash -n {} +
   python3 lib/tools/module_audit.py templates/mod-starter-template
   ```
4. Open a PR targeting `develop`. When `develop` is promoted to `main`, GitHub Actions automatically bumps `VERSION`, creates an annotated `vX.Y.Z` tag, and publishes a GitHub Release.

---

## 3. Building & Publishing Your Own Guild Module

Anyone can build, host, and maintain their own Blue Lodge module in their own GitHub repository:

1. **Scaffold from the Starter Template:**
   Use [`dabe-19/mod-starter-template`](https://github.com/dabe-19/mod-starter-template) (or run `/app scaffold <my-module>` inside Blue Lodge).
2. **Follow Security & ALP v1 Standards:**
   - Apache-2.0 or MIT license (`LICENSE` + `module.json`)
   - Pass `python3 lib/tools/module_audit.py <your-module-dir>` with **0 issues**
   - Strictly XSS-safe UI (zero `innerHTML`, `outerHTML`, `document.write`, `eval`, or native dialogs)
   - Zero `shell=True` in Python tools; declare any required Python packages in `module.json`
3. **Enable Automated Releases in Your Module Repo:**
   Keep `.github/workflows/module-ci.yml` and `.github/workflows/auto-tag-release.yml` so every merged PR runs security/unit checks and tags `vX.Y.Z` automatically.
4. **List in the Blue Lodge Guild App Store:**
   Open a PR to [`dabe-19/blue-lodge-guild`](https://github.com/dabe-19/blue-lodge-guild) adding or updating your module entry (`id`, `version`, `repo`, pinned `commit` SHA) in `catalog.json`. Automated Guild CI verifies your SHA, license, manifest, and static security scan before merge.
5. **Users Install Immediately:**
   ```bash
   /app install https://github.com/<your-user>/mod-<your-module>.git
   # or once listed in blue-lodge-guild:
   /app install <your-module>
   ```
