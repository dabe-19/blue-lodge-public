---
trigger: always_on
---
### ⚠️ CRITICAL: Background Task Management

**1. Cancel Stale George Runs**
Whenever you start or restart a George execution task (e.g. executing `lodge` or launching docker exec sandbox tasks) in the background, you MUST check for any previously running background George tasks and terminate them first using the `manage_task` tool with `kill` action. Running duplicate background tasks concurrently on the same GPU/resource sandbox is strictly prohibited.
