### ⚠️ CRITICAL: Synchronous Terminal Execution

**1. Force Live Terminal Streaming**
Whenever you execute terminal commands using the `run_command` tool, you MUST set the `RunPersistent` parameter to `true` (and specify a `RequestedTerminalID` to reuse a terminal if applicable). This ensures that the command executes in the user's interactive login shell (with `oh-my-zsh` and custom styling loaded) and streams the colored output live directly in the chat/terminal pane instead of running in a silent headless subshell.
