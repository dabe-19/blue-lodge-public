---
trigger: glob
globs:**/{*.{sh,bash,zsh,ksh},.bashrc,.zshrc,.profile,Makefile}
---

# Shell Scripting & Automation Standards

- **Safety First (Unofficial Bash Strict Mode)**: Always start scripts with `set -euo pipefail` to ensure the script exits immediately on errors, undefined variables, or failed pipe commands.
- **Portability**: Use `#!/usr/bin/env bash` rather than hardcoding the path to bash to ensure cross-platform compatibility.
- **Modularity**: Break complex scripts down into smaller, named functions. Group functions at the top of the file and invoke the main logic at the bottom.
- **Documentation & Usage**: Provide a `help` or `usage` function that explains what the script does and lists accepted arguments. If adding command-line flags to external tools (like `docker run -d -p`), provide inline comments explaining what those flags do.
