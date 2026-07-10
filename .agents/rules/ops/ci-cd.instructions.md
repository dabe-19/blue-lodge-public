---
trigger: glob
globs:{{{.github/workflows,**/buildkite}/**/*,**/azure-pipelines*,.gitlab-ci,.circleci/config}.{yml,yaml},**/Jenkinsfile}
---

# CI/CD Pipeline Standards

- **Pin Action / Image Versions**: Reference third-party actions and container images by full SHA or immutable tag (`actions/checkout@v4` minimum; `@<sha>` for security-sensitive workflows). Floating tags like `@latest` or `@main` are forbidden.
- **Least Privilege Tokens**: Set `permissions:` explicitly at the workflow or job level. Default to `contents: read`; grant `write` only on the specific job that needs it. Never use the default token's full permission set.
- **Secrets Discipline**: Reference secrets via the platform's secret store (`${{ secrets.X }}`, `$CI_VARIABLE`). Mask in logs. Never `echo` a secret. Rotate on suspicion of leak.
- **Untrusted Input**: Treat `pull_request` events from forks as untrusted. Use `pull_request_target` only with extreme care and never check out the PR's code into a privileged context. Sanitize any `${{ github.event.* }}` interpolations into shell — they enable injection.
- **Concurrency Control**: Set `concurrency:` groups so duplicate pushes cancel in-flight runs (`concurrency: { group: ci-${{ github.ref }}, cancel-in-progress: true }`).
- **Caching**: Cache dependency directories (`~/.cache/pip`, `node_modules` or package-manager store, `~/.cargo`, `~/.gradle/caches`) keyed on the lockfile hash. Restore-keys for partial hits.
- **Reproducible Builds**: Pin language/runtime versions (`actions/setup-node` with explicit `node-version`, `setup-python` with explicit `python-version`). Use the project's lockfile (`npm ci`, `pip install -r requirements.txt --no-deps` only when reproducibility matters).
- **Fail Fast, Fail Loud**: Use `set -euo pipefail` at the top of every multi-line shell step. A silently-passing CI is worse than a noisy red build.
- **Required Checks**: Lint, unit tests, type-check, and security scanners (SAST, dependency audit) are required status checks on the protected branch. No green-merge bypass.
- **Artifact Promotion**: Build once, promote the same artifact through environments. Do not rebuild between staging and prod — that's how reproducibility dies.
- **Deployment Gating**: Production deploys require manual approval (environments with `required_reviewers`) or a successful staging smoke-test gate. Never auto-deploy to prod from a feature branch merge.
- **Observability**: Emit structured logs and a workflow-summary block (`$GITHUB_STEP_SUMMARY`). Surface test/coverage reports as artifacts and PR comments.
