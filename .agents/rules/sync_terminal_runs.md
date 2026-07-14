### ⚠️ CRITICAL: Synchronous Terminal Execution

**1. Force Synchronous Output Monitoring**
Whenever you run shell/terminal commands using the `run_command` tool, you MUST set the `WaitMsBeforeAsync` parameter to `10000` (the maximum allowed synchronous limit of 10 seconds) to ensure that command outputs are rendered inline in the chat interface for live monitoring. Do not run commands in the background or asynchronously unless they are daemon/server processes.
