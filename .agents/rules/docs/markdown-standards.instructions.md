---
trigger: glob
globs:**/*{.md,.mdx}
---

# Markdown & Documentation Standards

- **One H1 Per Document**: The first non-frontmatter line is a single `#` heading. All subsequent headings step down (`##`, `###`) without skipping levels.
- **Reference Links for Repeated URLs**: When the same URL appears more than once, define it as a reference link at the bottom and use `[label][ref]` inline. Easier to update, harder to break.
- **Relative Links Within Repo**: Cross-reference repo files with relative paths (`../guides/setup.md`), not absolute URLs to the hosted site. They survive forks, mirrors, and offline clones.
- **Code Fences Are Tagged**: Every fenced block declares its language (` ```python`, ` ```bash`, ` ```json`). Untagged fences break syntax highlighting and accessibility tooling.
- **Line-Wrap Discipline**: Either wrap at 80–100 columns consistently or use semantic line breaks (one sentence per line). Pick one per repo and stick with it; both produce clean diffs, mixing them produces noise.
- **No Smart Quotes / Em-Dashes In Code**: Editors love to autocorrect `"` → `"` and `--` → `—` inside fenced blocks. Disable smart-substitutions or proofread fenced content.
- **Tables for Tabular Data Only**: If the content isn't a grid, use a list. Wide markdown tables render poorly on mobile and in PR diffs.
- **Front-Matter Consistency**: When using YAML front-matter (Hugo, Jekyll, MkDocs, Docusaurus, VS Code prompts/instructions), keep keys consistent across files (`title`, `description`, `applyTo`, `tags`). Validate in CI when the static-site generator supports it.
- **Link Hygiene**: Run a link-checker (`lychee`, `markdown-link-check`) in CI. Broken links to deleted internal docs or dead external sites erode trust fast.
- **Alt Text Always**: Every image gets descriptive alt text (`![architecture diagram showing three services](path/to/img.png)`). Empty alt is acceptable only for purely decorative images.
- **Diagrams as Text When Possible**: Prefer Mermaid, PlantUML, or D2 fenced blocks over committed PNGs. Diffs are reviewable; PNG re-renders are not.
- **README Anchors**: A repo `README.md` answers four questions in the first screen: what is this, how do I install/run it, where do I read more, how do I contribute. Optimize for the first-time reader.
