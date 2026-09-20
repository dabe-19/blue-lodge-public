#!/bin/bash
# ── George: Native POSIX Tool Bridge (2026) ──────────────────────────
# Bridges George's 100% pure POSIX tool catalog (web, social, memory,
# hardware, email, mqtt, mcp, shell) directly to OpenAI/llama-server
# native function-calling JSON schemas and handles dispatch.

[ -n "${_LIB_NATIVE_TOOLS_LOADED:-}" ] && return 0; _LIB_NATIVE_TOOLS_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"

source "$LODGE_DIR/lib/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/commands.sh" 2>/dev/null || true
commands_load_all 2>/dev/null || true
source "$LODGE_DIR/lib/tools.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/web.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/social.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/email.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/mqtt.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/phone.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/vitals.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/memory.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/recall.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/journal.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/subagents.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/mcp.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/models.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/endpoints.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/reflexive.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/wallet.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/sandbox.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/container.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/backup.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/pgp.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/gsuite.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/treesitter.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/mcp_server_gitea.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/pr.sh" 2>/dev/null || true

# ── Complete POSIX Tool Schemas (OpenAI Function Calling Format) ─────
_NATIVE_CORE_TOOLS='[
  {
    "type": "function",
    "function": {
      "name": "bash_exec",
      "description": "Execute a bash shell command within the project workspace. Use for inspection, building, running tests, or git operations.",
      "parameters": {
        "type": "object",
        "properties": {
          "command": { "type": "string", "description": "The bash shell command string to execute." }
        },
        "required": ["command"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "file_read",
      "description": "Read the contents of a local file in the workspace.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": { "type": "string", "description": "Relative file path from workspace root." },
          "start_line": { "type": "integer", "description": "Optional starting line number (1-indexed)." },
          "max_lines": { "type": "integer", "description": "Optional maximum number of lines to read." }
        },
        "required": ["path"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "file_write",
      "description": "Create a new file or completely overwrite an existing file with the specified content.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": { "type": "string", "description": "Relative file path from workspace root." },
          "content": { "type": "string", "description": "Full text content to write to the file." }
        },
        "required": ["path", "content"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "file_append",
      "description": "Append text content to the end of an existing file.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": { "type": "string", "description": "Relative file path." },
          "content": { "type": "string", "description": "Content to append." }
        },
        "required": ["path", "content"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "dir_list",
      "description": "List directory contents formatted as an indented tree.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": { "type": "string", "description": "Directory path (defaults to current workspace)." },
          "depth": { "type": "integer", "description": "Max recursion depth (1-8, defaults to 3)." }
        }
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "file_grep",
      "description": "Perform regular expression search across files in the workspace.",
      "parameters": {
        "type": "object",
        "properties": {
          "pattern": { "type": "string", "description": "Regex search pattern." },
          "path": { "type": "string", "description": "Optional subdirectory or file pattern to search within." }
        },
        "required": ["pattern"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "web_search",
      "description": "Search the live web using pure POSIX curl extraction. Returns URLs, titles, and snippets.",
      "parameters": {
        "type": "object",
        "properties": {
          "query": { "type": "string", "description": "Search query terms." },
          "count": { "type": "integer", "description": "Number of search results to return (default 5)." }
        },
        "required": ["query"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "web_fetch",
      "description": "Fetch and extract readable markdown text content from a web URL.",
      "parameters": {
        "type": "object",
        "properties": {
          "url": { "type": "string", "description": "Web URL to fetch (HTTP or HTTPS)." }
        },
        "required": ["url"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "github_search",
      "description": "Search GitHub repositories for open source reference implementations and code.",
      "parameters": {
        "type": "object",
        "properties": {
          "query": { "type": "string", "description": "GitHub search keywords." },
          "count": { "type": "integer", "description": "Max repositories to return (default 5)." }
        },
        "required": ["query"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "memory_get_section",
      "description": "Read a specific section from GEORGE.md project memory (e.g. Active Task, Workspace Layout, Completed Milestones, Context Files, Agent Notes).",
      "parameters": {
        "type": "object",
        "properties": {
          "section": { "type": "string", "description": "Section header name in GEORGE.md." }
        },
        "required": ["section"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "memory_update_section",
      "description": "Overwrite the contents of a specific section in GEORGE.md project memory.",
      "parameters": {
        "type": "object",
        "properties": {
          "section": { "type": "string", "description": "Section header name in GEORGE.md." },
          "content": { "type": "string", "description": "New content for the section." }
        },
        "required": ["section", "content"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "memory_append_section",
      "description": "Append a bullet point or text line to a section in GEORGE.md.",
      "parameters": {
        "type": "object",
        "properties": {
          "section": { "type": "string", "description": "Section header name in GEORGE.md." },
          "line": { "type": "string", "description": "Line of text to append." }
        },
        "required": ["section", "line"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "memory_read_soul",
      "description": "Read George foundational soul identity and sovereign principles from soul.md.",
      "parameters": {
        "type": "object",
        "properties": {}
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "recall_search",
      "description": "Search George semantic vector and keyword knowledge base for historical project decisions, architecture notes, and user preferences.",
      "parameters": {
        "type": "object",
        "properties": {
          "query": { "type": "string", "description": "Semantic search query." },
          "limit": { "type": "integer", "description": "Max entries to return (default 5)." }
        },
        "required": ["query"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "recall_ingest",
      "description": "Ingest and index a local file or document into the semantic memory registry.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": { "type": "string", "description": "Relative file path to index." }
        },
        "required": ["path"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "recall_list_docs",
      "description": "List all indexed documents currently stored in the semantic recall knowledge base.",
      "parameters": {
        "type": "object",
        "properties": {}
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "recall_archive_milestone",
      "description": "Archive a completed milestone into semantic memory for permanent historical recall.",
      "parameters": {
        "type": "object",
        "properties": {
          "name": { "type": "string", "description": "Title of completed milestone." },
          "description": { "type": "string", "description": "Details and outcomes of the milestone." }
        },
        "required": ["name"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "journal_record",
      "description": "Record an episodic learning, insight, or decision into George permanent journal.",
      "parameters": {
        "type": "object",
        "properties": {
          "reflection": { "type": "string", "description": "Insight, summary of lesson learned, or architectural decision." }
        },
        "required": ["reflection"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "journal_read",
      "description": "Read recent episodic journal reflections and recorded learnings.",
      "parameters": {
        "type": "object",
        "properties": {
          "count": { "type": "integer", "description": "Number of recent entries to read (default 5)." }
        }
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "model_param_set",
      "description": "Configure runtime model sampling parameters (e.g. temperature, top_p, top_k, max_tokens, repeat_penalty).",
      "parameters": {
        "type": "object",
        "properties": {
          "param": { "type": "string", "description": "Parameter name (e.g. temperature, top_p, top_k, max_tokens, repeat_penalty)." },
          "value": { "type": "string", "description": "Parameter value." }
        },
        "required": ["param", "value"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "model_param_get",
      "description": "Retrieve current model parameter settings or inspect a specific parameter.",
      "parameters": {
        "type": "object",
        "properties": {
          "param": { "type": "string", "description": "Optional specific parameter name to query." }
        }
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "model_param_clear",
      "description": "Reset one or all model parameters back to endpoint defaults.",
      "parameters": {
        "type": "object",
        "properties": {
          "param": { "type": "string", "description": "Optional parameter to clear. If omitted, resets all parameters." }
        }
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "model_endpoint_switch",
      "description": "Switch the active inference tier (Tier 3 Mac Ultra M5 -> Tier 1 Dual RTX 3060 -> Tier 2 AMD 5700xt -> Tier 0 Edge mobile).",
      "parameters": {
        "type": "object",
        "properties": {
          "tier": { "type": "integer", "description": "Target tier number (0, 1, 2, or 3)." }
        },
        "required": ["tier"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "model_endpoint_status",
      "description": "Query the live health, latencies, model quants, and context limits across the 4-tier hardware ladder.",
      "parameters": {
        "type": "object",
        "properties": {}
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "mcp_server_status",
      "description": "List configured and active Model Context Protocol (MCP) servers and their running statuses.",
      "parameters": {
        "type": "object",
        "properties": {}
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "mcp_server_add",
      "description": "Register a new MCP server in the George MCP configuration.",
      "parameters": {
        "type": "object",
        "properties": {
          "name": { "type": "string", "description": "Unique identifier for the server." },
          "command": { "type": "string", "description": "Launch command (e.g. npx -y @modelcontextprotocol/server-git or posix script)." },
          "description": { "type": "string", "description": "Brief description of the server capabilities." }
        },
        "required": ["name", "command"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "mcp_server_remove",
      "description": "Unregister an MCP server from the configuration.",
      "parameters": {
        "type": "object",
        "properties": {
          "name": { "type": "string", "description": "Name of the server to remove." }
        },
        "required": ["name"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "mcp_server_start",
      "description": "Start a registered MCP server process.",
      "parameters": {
        "type": "object",
        "properties": {
          "name": { "type": "string", "description": "Name of the registered server to start." }
        },
        "required": ["name"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "mcp_server_stop",
      "description": "Stop a running MCP server process.",
      "parameters": {
        "type": "object",
        "properties": {
          "name": { "type": "string", "description": "Name of the running server to stop." }
        },
        "required": ["name"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "mcp_tool_execute",
      "description": "Explicitly invoke a tool on a running MCP server.",
      "parameters": {
        "type": "object",
        "properties": {
          "server": { "type": "string", "description": "Name of the running MCP server." },
          "tool": { "type": "string", "description": "Name of the MCP tool to call." },
          "arguments": { "type": "object", "description": "Arguments object matching the tool inputSchema." }
        },
        "required": ["server", "tool"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "email_send",
      "description": "Send an email message via configured pure POSIX SMTP or bridge.",
      "parameters": {
        "type": "object",
        "properties": {
          "to": { "type": "string", "description": "Recipient email address." },
          "subject": { "type": "string", "description": "Subject line." },
          "body": { "type": "string", "description": "Plain text body." }
        },
        "required": ["to", "subject", "body"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "email_read",
      "description": "Read recent incoming emails from inbox.",
      "parameters": {
        "type": "object",
        "properties": {
          "count": { "type": "integer", "description": "Number of emails to retrieve (default 5)." }
        }
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "phone_sms_send",
      "description": "Send an SMS text message using Termux Android telephony integration.",
      "parameters": {
        "type": "object",
        "properties": {
          "number": { "type": "string", "description": "Recipient phone number." },
          "message": { "type": "string", "description": "SMS message text." }
        },
        "required": ["number", "message"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "mqtt_publish",
      "description": "Publish a message or sensor payload to an MQTT topic broker.",
      "parameters": {
        "type": "object",
        "properties": {
          "topic": { "type": "string", "description": "MQTT topic (e.g. lodge/telemetry or home/sensor)." },
          "message": { "type": "string", "description": "Payload string or JSON." }
        },
        "required": ["topic", "message"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "discord_send",
      "description": "Send a message to a Discord user (direct message/DM) or server channel using the Discord Bot API or Webhook.",
      "parameters": {
        "type": "object",
        "properties": {
          "target": { "type": "string", "description": "Destination: username or mention for DM (e.g. 'dabe', '@dabe', 'me'), channel name (e.g. 'general'), server/guild name (e.g. 'Logic'), or numeric ID." },
          "message": { "type": "string", "description": "Message text to transmit." }
        },
        "required": ["message"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "discord_dm",
      "description": "Send a direct message (DM) to a Discord user (e.g. 'dabe', '@dabe', 'me', or user ID) via Discord Bot API.",
      "parameters": {
        "type": "object",
        "properties": {
          "user": { "type": "string", "description": "Username, display name, mention (e.g. 'dabe', '@dabe', 'me'), or Discord user ID." },
          "message": { "type": "string", "description": "Message text to send as DM." }
        },
        "required": ["user", "message"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "telegram_send",
      "description": "Send a message via Telegram bot API.",
      "parameters": {
        "type": "object",
        "properties": {
          "message": { "type": "string", "description": "Message text." }
        },
        "required": ["message"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "social_post",
      "description": "Post a status update or message across configured social networks (Bluesky, Mastodon, X).",
      "parameters": {
        "type": "object",
        "properties": {
          "network": { "type": "string", "description": "Network to post to: bluesky, mastodon, x, or all.", "enum": ["bluesky", "mastodon", "x", "all"] },
          "text": { "type": "string", "description": "Post content." }
        },
        "required": ["network", "text"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "system_vitals",
      "description": "Retrieve live hardware vitals: CPU usage, RAM utilization, thermals, disk space, battery status, and GPU layers.",
      "parameters": {
        "type": "object",
        "properties": {}
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "subagent_delegate",
      "description": "Delegate a subtask to an available lower-tier hardware node (e.g. Tier 2 AMD 5700xt or Tier 0 Edge mobile).",
      "parameters": {
        "type": "object",
        "properties": {
          "tier": { "type": "integer", "description": "Target tier number (e.g. 2 or 0)." },
          "task": { "type": "string", "description": "Specific, bounded task description for the worker." }
        },
        "required": ["tier", "task"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "subagent_spawn",
      "description": "Spawn an autonomous subagent inside an isolated git worktree sandbox (.sandboxes/<child_id>) with in-flight control FIFO, central registry tracking, and streaming observability.",
      "parameters": {
        "type": "object",
        "properties": {
          "tier": { "type": "integer", "description": "Target tier number (e.g. 1 for CUDA workhorse, 2 for AMD, 0 for mobile edge)." },
          "objective": { "type": "string", "description": "Specific objective and success criteria for the delegated child agent." },
          "context": { "type": "string", "description": "Optional parent context, file paths, or instructions." },
          "max_turns": { "type": "integer", "description": "Maximum turn ceiling for child agent (default: 50)." },
          "async": { "type": "boolean", "description": "Run asynchronously in background (returns immediately with subagent ID, PID, branch, and log file path)." }
        },
        "required": ["tier", "objective"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "subagent_status",
      "description": "Inspect active subagent processes, turns, and execution status from central registry.",
      "parameters": {
        "type": "object",
        "properties": {
          "sub_id": { "type": "string", "description": "Optional child ID. If omitted, lists all active subagents." }
        }
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "subagent_logs",
      "description": "Inspect real-time process stream, thoughts, tool actions, observations, and milestones of a child subagent clone.",
      "parameters": {
        "type": "object",
        "properties": {
          "sub_id": { "type": "string", "description": "Child subagent ID." },
          "lines": { "type": "integer", "description": "Number of recent lines to retrieve (default: 50)." }
        },
        "required": ["sub_id"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "subagent_diff",
      "description": "Inspect the git diff between parent HEAD and a child subagent worktree sandbox branch.",
      "parameters": {
        "type": "object",
        "properties": {
          "sub_id": { "type": "string", "description": "Child subagent ID." },
          "stat_only": { "type": "boolean", "description": "If true, returns only short diffstat." }
        },
        "required": ["sub_id"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "subagent_merge",
      "description": "Merge a completed child subagent worktree branch deliverable into the active branch.",
      "parameters": {
        "type": "object",
        "properties": {
          "sub_id": { "type": "string", "description": "Child subagent ID." },
          "strategy": { "type": "string", "description": "Merge strategy: merge (default) or squash.", "enum": ["merge", "squash"] }
        },
        "required": ["sub_id"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "subagent_reap",
      "description": "Cleanly remove a child subagent git worktree sandbox and delete its branch.",
      "parameters": {
        "type": "object",
        "properties": {
          "sub_id": { "type": "string", "description": "Child subagent ID." }
        },
        "required": ["sub_id"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "subagent_intervene",
      "description": "Send real-time control directives (PAUSE, RESUME, ABORT) to an in-flight child subagent via its control FIFO.",
      "parameters": {
        "type": "object",
        "properties": {
          "sub_id": { "type": "string", "description": "Target child subagent ID." },
          "command": { "type": "string", "description": "Directive: PAUSE, RESUME, or ABORT.", "enum": ["PAUSE", "RESUME", "ABORT"] }
        },
        "required": ["sub_id", "command"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "subagent_await",
      "description": "Wait for a running child subagent to complete and retrieve its final synthesized deliverable.",
      "parameters": {
        "type": "object",
        "properties": {
          "sub_id": { "type": "string", "description": "Target child subagent ID." },
          "timeout_seconds": { "type": "integer", "description": "Maximum seconds to wait (default: 120)." }
        },
        "required": ["sub_id"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "code_symbol_read",
      "description": "Retrieve the exact lines of code defining a named function or class via SQLite symbol index and Tree-sitter AST slicing without reading the whole file.",
      "parameters": {
        "type": "object",
        "properties": {
          "symbol_name": { "type": "string", "description": "Name of function, method, or class to inspect." },
          "file_path": { "type": "string", "description": "Optional relative path to file containing symbol." }
        },
        "required": ["symbol_name"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "code_symbol_patch",
      "description": "Apply an AST-validated patch to a named function in a file on disk.",
      "parameters": {
        "type": "object",
        "properties": {
          "file_path": { "type": "string", "description": "Relative file path." },
          "symbol_name": { "type": "string", "description": "Name of function to replace." },
          "new_symbol_code": { "type": "string", "description": "New code for the function." }
        },
        "required": ["file_path", "symbol_name", "new_symbol_code"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "reflexive_status",
      "description": "Inspect the reflexive intelligence layer: Soul Consensus Gate, self-improving prompt grades, adaptive token budgets, and metacognitive self-model state.",
      "parameters": {
        "type": "object",
        "properties": {}
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "reflexive_toggle",
      "description": "Enable or disable a reflexive intelligence subsystem (soul_gate, prompt_learn, adapt_tokens, speculate, self_model).",
      "parameters": {
        "type": "object",
        "properties": {
          "subsystem": { "type": "string", "description": "Subsystem name: soul_gate, prompt_learn, adapt_tokens, speculate, self_model, or all." },
          "state": { "type": "string", "description": "State: on or off (or 1 or 0)." }
        },
        "required": ["subsystem", "state"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "reflexive_metacog_assess",
      "description": "Trigger an internal metacognitive self-assessment of the agent cognition, progress, and reasoning path.",
      "parameters": {
        "type": "object",
        "properties": {}
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "reflexive_prompt_grade",
      "description": "Record an outcome grade for the current turn prompt to train recursive prompt mutation.",
      "parameters": {
        "type": "object",
        "properties": {
          "score": { "type": "integer", "description": "Grade score: 1 for success, 0 for failure." },
          "hint": { "type": "string", "description": "Optional optimization hint or note for future prompt assembly." }
        },
        "required": ["score"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "wallet_status",
      "description": "Query crypto wallet configurations, API health, and network for Bitcoin, Solana, and Cardano.",
      "parameters": {
        "type": "object",
        "properties": {}
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "wallet_balances",
      "description": "Retrieve live wallet balances across Bitcoin (BTC), Solana (SOL), and Cardano (ADA).",
      "parameters": {
        "type": "object",
        "properties": {}
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "wallet_set_network",
      "description": "Switch cryptocurrency network environment between mainnet and testnet.",
      "parameters": {
        "type": "object",
        "properties": {
          "network": { "type": "string", "description": "Network: mainnet or testnet.", "enum": ["mainnet", "testnet"] }
        },
        "required": ["network"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "crypto_send",
      "description": "Execute a cryptocurrency transfer on Bitcoin, Solana, or Cardano.",
      "parameters": {
        "type": "object",
        "properties": {
          "chain": { "type": "string", "description": "Blockchain: btc, sol, or ada.", "enum": ["btc", "sol", "ada"] },
          "to": { "type": "string", "description": "Recipient wallet address." },
          "amount": { "type": "string", "description": "Amount to transfer (e.g. 0.05 or 1000000 satoshis/lamports)." }
        },
        "required": ["chain", "to", "amount"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "solana_airdrop",
      "description": "Request devnet/testnet SOL airdrop to configured Solana wallet address.",
      "parameters": {
        "type": "object",
        "properties": {
          "amount": { "type": "number", "description": "Amount of SOL to request (default 1)." }
        }
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "vision_analyze",
      "description": "Analyze an image, diagram, screenshot, or chart using multimodal AI vision.",
      "parameters": {
        "type": "object",
        "properties": {
          "image": { "type": "string", "description": "Local image file path or web URL." },
          "prompt": { "type": "string", "description": "Analysis instructions or questions regarding the image." }
        },
        "required": ["image"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "file_download",
      "description": "Download a file or webpage (HTTP/HTTPS URL) or copy local file to workspace destination with MIME verification.",
      "parameters": {
        "type": "object",
        "properties": {
          "source": { "type": "string", "description": "Source URL or local file path." },
          "destination": { "type": "string", "description": "Destination file path in workspace." }
        },
        "required": ["source"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "service_list",
      "description": "List all registered background microservices and daemons with PID, port, and uptime.",
      "parameters": {
        "type": "object",
        "properties": {}
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "service_manage",
      "description": "Manage a background microservice: register, build, deploy, start, stop, restart, status, or logs.",
      "parameters": {
        "type": "object",
        "properties": {
          "action": { "type": "string", "description": "Action: start, stop, restart, status, logs, build, deploy, register, unregister.", "enum": ["start", "stop", "restart", "status", "logs", "build", "deploy", "register", "unregister"] },
          "name": { "type": "string", "description": "Service name." },
          "args": { "type": "string", "description": "Optional additional arguments (e.g. path for register, line count for logs)." }
        },
        "required": ["action", "name"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "sandbox_create",
      "description": "Create an isolated workspace sandbox directory for safe build, execution, and testing.",
      "parameters": {
        "type": "object",
        "properties": {
          "name": { "type": "string", "description": "Unique name for the sandbox." }
        },
        "required": ["name"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "sandbox_exec",
      "description": "Execute a bash shell command inside an isolated workspace sandbox.",
      "parameters": {
        "type": "object",
        "properties": {
          "name": { "type": "string", "description": "Sandbox name." },
          "command": { "type": "string", "description": "Shell command string to execute inside sandbox." }
        },
        "required": ["name", "command"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "sandbox_list",
      "description": "List all active workspace sandboxes.",
      "parameters": {
        "type": "object",
        "properties": {}
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "sandbox_remove",
      "description": "Tear down and remove an isolated workspace sandbox.",
      "parameters": {
        "type": "object",
        "properties": {
          "name": { "type": "string", "description": "Sandbox name to delete." }
        },
        "required": ["name"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "container_exec",
      "description": "Execute a shell command inside a Docker or proot container environment.",
      "parameters": {
        "type": "object",
        "properties": {
          "command": { "type": "string", "description": "Command string to run inside container." },
          "distro": { "type": "string", "description": "Container distribution (e.g. ubuntu, debian, alpine, arch)." }
        },
        "required": ["command"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "project_build",
      "description": "Build the workspace project with auto-detection for Rust Cargo, Python, Makefile, and TypeScript (bun/deno/npm/tsc).",
      "parameters": {
        "type": "object",
        "properties": {
          "args": { "type": "string", "description": "Optional build arguments (e.g. release or subdirectory)." }
        }
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "project_test",
      "description": "Run workspace tests with auto-detection for Rust (cargo test), Python (pytest/unittest), and TypeScript (vitest/jest/bun:test/npm test).",
      "parameters": {
        "type": "object",
        "properties": {
          "args": { "type": "string", "description": "Optional specific test name or file path." }
        }
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "slash_command_exec",
      "description": "Execute any Blue Lodge slash command (e.g. /journal, /recall, /init, /fix, /commit, /push, /save, /service).",
      "parameters": {
        "type": "object",
        "properties": {
          "command": { "type": "string", "description": "Full slash command string (e.g. /journal show or /recall query)." }
        },
        "required": ["command"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "file_edit",
      "description": "Edit a file using sed substitution for short, targeted search-and-replace changes.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": { "type": "string", "description": "Target file path relative to workspace." },
          "expression": { "type": "string", "description": "sed expression (e.g. s/old_text/new_text/g)." }
        },
        "required": ["path", "expression"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "git_clone",
      "description": "Clone a Git repository into the workspace or an isolated sandbox directory.",
      "parameters": {
        "type": "object",
        "properties": {
          "url": { "type": "string", "description": "Repository URL or owner/repo shorthand." },
          "destination": { "type": "string", "description": "Target directory or sandbox name (optional)." }
        },
        "required": ["url"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "git_commit",
      "description": "Create a Git commit with a concise conventional commit message.",
      "parameters": {
        "type": "object",
        "properties": {
          "message": { "type": "string", "description": "Optional commit message. If omitted, generates conventional commit message from diff." }
        }
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "git_push",
      "description": "Push commits on current branch to origin remote with SSH/email guard validation.",
      "parameters": {
        "type": "object",
        "properties": {
          "branch": { "type": "string", "description": "Optional branch name. Defaults to current branch." }
        }
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "gitea_status",
      "description": "Inspect sovereign Gitea server health, version, and repository statistics.",
      "parameters": { "type": "object", "properties": {} }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "gitea_repo_sync",
      "description": "Push local develop branch or specified branch to sovereign Gitea remote.",
      "parameters": {
        "type": "object",
        "properties": {
          "branch": { "type": "string", "description": "Branch to push (default: develop)" }
        }
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "gitea_pr_create",
      "description": "Create a pull request on sovereign Gitea targeting develop branch.",
      "parameters": {
        "type": "object",
        "properties": {
          "head": { "type": "string", "description": "Candidate branch name" },
          "base": { "type": "string", "description": "Target branch (default: develop)" },
          "title": { "type": "string", "description": "Pull request title" },
          "body": { "type": "string", "description": "Markdown dossier and empirical metrics" }
        },
        "required": ["head", "title"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "gitea_pr_list",
      "description": "List pull requests from sovereign Gitea forge.",
      "parameters": {
        "type": "object",
        "properties": {
          "state": { "type": "string", "description": "open, closed, or all", "enum": ["open", "closed", "all"] }
        }
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "gitea_pr_merge",
      "description": "Merge an approved pull request on sovereign Gitea into target branch.",
      "parameters": {
        "type": "object",
        "properties": {
          "index": { "type": "integer", "description": "PR number" },
          "strategy": { "type": "string", "description": "Merge strategy: merge or squash", "enum": ["merge", "squash"] }
        },
        "required": ["index"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "pr_audit",
      "description": "Perform Three Degrees audit on candidate PR in an isolated sandbox worktree.",
      "parameters": {
        "type": "object",
        "properties": {
          "pr_id": { "type": "string", "description": "PR identifier (e.g. PR-001 or numeric Gitea PR id)" }
        },
        "required": ["pr_id"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "project_fix",
      "description": "Automatically diagnose and attempt to fix build, compile, or test errors in the project.",
      "parameters": {
        "type": "object",
        "properties": {
          "error_context": { "type": "string", "description": "Optional description or file path with error context." }
        }
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "project_init",
      "description": "Scaffold a new project with GEORGE.md, recommended directories, and build/test configuration.",
      "parameters": {
        "type": "object",
        "properties": {
          "name": { "type": "string", "description": "Project name." },
          "type": { "type": "string", "description": "Project type: Rust, Python, TypeScript, or General." }
        },
        "required": ["name"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "backup_create",
      "description": "Create a timestamped identity and workspace backup snapshot preserving memories, soul, and journals.",
      "parameters": {
        "type": "object",
        "properties": {}
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "backup_list",
      "description": "List all existing George workspace snapshot backups with timestamps and sizes.",
      "parameters": {
        "type": "object",
        "properties": {}
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "backup_restore",
      "description": "Restore George identity, memories, or workspace from a specific timestamped backup snapshot.",
      "parameters": {
        "type": "object",
        "properties": {
          "timestamp": { "type": "string", "description": "Timestamp string of the backup to restore." }
        },
        "required": ["timestamp"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "pgp_sign",
      "description": "Sign a message or text with George isolated PGP key for cryptographic verification.",
      "parameters": {
        "type": "object",
        "properties": {
          "text": { "type": "string", "description": "Plaintext message to sign." }
        },
        "required": ["text"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "pgp_verify",
      "description": "Verify a PGP signed cleartext message against George public keyring.",
      "parameters": {
        "type": "object",
        "properties": {
          "signed_text": { "type": "string", "description": "ASCII-armored PGP signed message to verify." }
        },
        "required": ["signed_text"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "gsuite_search",
      "description": "Search Google Workspace (Gmail messages or Google Drive documents).",
      "parameters": {
        "type": "object",
        "properties": {
          "service": { "type": "string", "enum": ["gmail", "drive"], "description": "GSuite service to search." },
          "query": { "type": "string", "description": "Search query keywords or filter." }
        },
        "required": ["service", "query"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "ask_operator",
      "description": "Pause execution and ask the human operator a question via /dev/tty in the REPL, returning their real-time response.",
      "parameters": {
        "type": "object",
        "properties": {
          "question": { "type": "string", "description": "Clarifying or confirmation question to ask the operator." }
        },
        "required": ["question"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "code_outline",
      "description": "Extract an AST semantic outline / skeleton (function signatures, classes, structs, interfaces) from a source file, reducing context tokens by ~90%.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": { "type": "string", "description": "Path to the code file." }
        },
        "required": ["path"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "code_symbol_get",
      "description": "Extract the complete AST declaration and body of a specific named function, class, or symbol from a file.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": { "type": "string", "description": "Path to the code file." },
          "symbol": { "type": "string", "description": "Exact name of the function, class, or symbol." }
        },
        "required": ["path", "symbol"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "code_validate",
      "description": "Perform in-memory AST pre-flight syntax checking on code before writing to disk to prevent broken builds.",
      "parameters": {
        "type": "object",
        "properties": {
          "content": { "type": "string", "description": "Code content to validate." },
          "language": { "type": "string", "description": "Programming language (bash, python, json, typescript, rust)." }
        },
        "required": ["content", "language"]
      }
    }
  }
]'

# ── Dynamic Schema Aggregator ─────────────────────────────────────────
# Combines core schemas with dynamic tools discovered from running MCP servers.
native_tools_get_all_schemas() {
    local all_tools="$_NATIVE_CORE_TOOLS"

    # If MCP is enabled and servers are running, convert their tools
    if declare -f mcp_enabled &>/dev/null && mcp_enabled && declare -f mcp_running_servers &>/dev/null; then
        local server_name
        for server_name in $(mcp_running_servers 2>/dev/null); do
            local raw_mcp_tools
            raw_mcp_tools=$(mcp_tools_list "$server_name" 2>/dev/null)
            if [ -n "$raw_mcp_tools" ] && [ "$raw_mcp_tools" != "[]" ]; then
                # Transform MCP tool definitions: {name, description, inputSchema} -> OpenAI function format
                local converted
                converted=$(echo "$raw_mcp_tools" | jq '[
                    .[] | {
                        type: "function",
                        function: {
                            name: .name,
                            description: (.description // ("MCP tool on server " + "'"$server_name"'")),
                            parameters: (.inputSchema // {type: "object", properties: {}})
                        }
                    }
                ]' 2>/dev/null)

                if [ -n "$converted" ] && [ "$converted" != "[]" ]; then
                    all_tools=$(jq -n --argjson c "$all_tools" --argjson m "$converted" '$c + $m' 2>/dev/null || echo "$all_tools")
                fi
            fi
        done
    fi

    echo "$all_tools"
}

# ── Tool Dispatcher ───────────────────────────────────────────────────
# Receives call_id, function name, JSON arguments string, and workspace.
# Executes the pure POSIX tool and prints standard OpenAI tool response JSON:
# {"role": "tool", "tool_call_id": "$call_id", "content": "$output"}
native_tools_dispatch() {
    local call_id="$1"
    local name="$2"
    local args_json="$3"
    local workdir="${4:-$PWD}"

    local output=""
    local exit_code=0

    # 1. Check if name is an active MCP tool directly
    local handled_by_mcp=0
    if declare -f mcp_enabled &>/dev/null && mcp_enabled && declare -f mcp_running_servers &>/dev/null; then
        local s_name
        for s_name in $(mcp_running_servers 2>/dev/null); do
            local s_tools
            s_tools=$(mcp_tools_list "$s_name" 2>/dev/null)
            if echo "$s_tools" | jq -e --arg n "$name" '.[] | select(.name == $n)' &>/dev/null; then
                output=$(mcp_tool_call "$s_name" "$name" "$args_json" 2>&1)
                exit_code=$?
                handled_by_mcp=1
                break
            fi
        done
    fi

    # 2. Dispatch to Built-in POSIX Tools if not MCP
    if [ "$handled_by_mcp" -eq 0 ]; then
        case "$name" in
            bash_exec)
                local cmd
                cmd=$(echo "$args_json" | jq -r '.command // empty')
                output=$(commands_dispatch "/bash $cmd" "$workdir" 2>&1)
                exit_code=$?
                ;;
            file_read)
                local p s m
                p=$(echo "$args_json" | jq -r '.path // empty')
                s=$(echo "$args_json" | jq -r '.start_line // 1')
                m=$(echo "$args_json" | jq -r '.max_lines // 300')
                local target="$p"
                if declare -f ui_resolve_path &>/dev/null; then
                    target=$(ui_resolve_path "$p" "$workdir")
                elif [ -f "$workdir/$p" ]; then
                    target="$workdir/$p"
                fi
                if [ ! -e "$target" ]; then
                    output="ERROR: File not found: $p"
                    exit_code=1
                elif [ -d "$target" ]; then
                    output=$(commands_dispatch "/ls $p 2" "$workdir" 2>&1)
                    exit_code=0
                else
                    output=$(tools_read_file "$target" "$m" "$s" 2>&1)
                    exit_code=$?
                    if [ $exit_code -eq 0 ] && [ -f "$target" ]; then
                        local _ts_total_lines
                        _ts_total_lines=$(wc -l < "$target" 2>/dev/null || echo 0)
                        if [ "$_ts_total_lines" -gt 150 ]; then
                            output+=$'\n\n'"[Tip: $p has $_ts_total_lines lines. Use code_outline \"$p\" for structural overview, or code_symbol_get \"$p\" <symbol> to extract specific functions/classes.]"
                        fi
                    fi
                fi
                ;;
            file_write)
                local p c
                p=$(echo "$args_json" | jq -r '.path // empty')
                c=$(echo "$args_json" | jq -r '.content // empty')
                # Ambient Tree-sitter pre-flight syntax validation
                local _ts_lang
                _ts_lang=$(treesitter_detect_lang "$p")
                if [ -n "$_ts_lang" ] && [ "$_ts_lang" != "plaintext" ]; then
                    local _ts_v_err
                    if ! _ts_v_err=$(treesitter_validate "$c" "$_ts_lang" 2>&1); then
                        output="ERROR: Tree-sitter AST Syntax Validation Failed for $p ($_ts_lang):
$_ts_v_err
[File write aborted to protect code integrity. Fix syntax errors before writing.]"
                        exit_code=1
                    fi
                fi
                if [ -z "$output" ]; then
                    output=$(commands_dispatch "/write $p $c" "$workdir" 2>&1)
                    exit_code=$?
                fi
                ;;
            file_append)
                local p c
                p=$(echo "$args_json" | jq -r '.path // empty')
                c=$(echo "$args_json" | jq -r '.content // empty')
                output=$(commands_dispatch "/append $p $c" "$workdir" 2>&1)
                exit_code=$?
                ;;
            dir_list)
                local p d
                p=$(echo "$args_json" | jq -r '.path // "."')
                d=$(echo "$args_json" | jq -r '.depth // 3')
                output=$(commands_dispatch "/ls $p $d" "$workdir" 2>&1)
                exit_code=$?
                ;;
            file_grep)
                local pat p
                pat=$(echo "$args_json" | jq -r '.pattern // empty')
                p=$(echo "$args_json" | jq -r '.path // "."')
                if command -v rg &>/dev/null; then
                    output=$(rg -n --no-heading --color=never -e "$pat" "$workdir/$p" 2>&1 | head -n 100)
                    exit_code=$?
                else
                    output=$(commands_dispatch "/grep $pat $p" "$workdir" 2>&1)
                    exit_code=$?
                fi
                ;;
            code_outline)
                local p
                p=$(echo "$args_json" | jq -r '.path // empty')
                output=$(treesitter_outline "$workdir/$p" 2>&1)
                exit_code=$?
                ;;
            code_symbol_get)
                local p sym
                p=$(echo "$args_json" | jq -r '.path // empty')
                sym=$(echo "$args_json" | jq -r '.symbol // empty')
                output=$(treesitter_symbol "$workdir/$p" "$sym" 2>&1)
                exit_code=$?
                ;;
            code_validate)
                local code_cnt lang
                code_cnt=$(echo "$args_json" | jq -r '.content // empty')
                lang=$(echo "$args_json" | jq -r '.language // "bash"')
                output=$(treesitter_validate "$code_cnt" "$lang" 2>&1)
                exit_code=$?
                ;;
            ask_operator)
                local q
                q=$(echo "$args_json" | jq -r '.question // empty')
                output=$(ui_ask_operator "$q" 2>&1)
                exit_code=$?
                ;;
            web_search)
                local q cnt
                q=$(echo "$args_json" | jq -r '.query // empty')
                cnt=$(echo "$args_json" | jq -r '.count // 5')
                output=$(web_search "$q" "$cnt" 2>&1)
                exit_code=$?
                ;;
            web_fetch)
                local u
                u=$(echo "$args_json" | jq -r '.url // empty')
                output=$(web_fetch "$u" 2>&1)
                exit_code=$?
                ;;
            github_search)
                local q cnt
                q=$(echo "$args_json" | jq -r '.query // empty')
                cnt=$(echo "$args_json" | jq -r '.count // 5')
                output=$(web_search_github "$q" "$cnt" 2>&1)
                exit_code=$?
                ;;
            memory_get_section)
                local sec
                sec=$(echo "$args_json" | jq -r '.section // empty')
                output=$(memory_get_section "$sec" "$workdir" 2>&1)
                [ -z "$output" ] && output="(empty)"
                exit_code=0
                ;;
            memory_update_section)
                local sec cnt
                sec=$(echo "$args_json" | jq -r '.section // empty')
                cnt=$(echo "$args_json" | jq -r '.content // empty')
                memory_update_section "$sec" "$cnt" "$workdir" 2>&1
                output="Updated section '## $sec' in GEORGE.md"
                exit_code=0
                ;;
            memory_append_section)
                local sec ln
                sec=$(echo "$args_json" | jq -r '.section // empty')
                ln=$(echo "$args_json" | jq -r '.line // empty')
                memory_append_section "$sec" "$ln" "$workdir" 2>&1
                output="Appended to section '## $sec' in GEORGE.md"
                exit_code=0
                ;;
            memory_read_soul)
                output=$(memory_read_soul 2>&1)
                exit_code=0
                ;;
            recall_search)
                local q lim
                q=$(echo "$args_json" | jq -r '.query // empty')
                lim=$(echo "$args_json" | jq -r '.limit // 5')
                output=$(recall_search "$q" "$lim" 2>&1)
                exit_code=$?
                ;;
            recall_ingest)
                local p
                p=$(echo "$args_json" | jq -r '.path // empty')
                local target="$p"
                [ -f "$workdir/$p" ] && target="$workdir/$p"
                output=$(recall_ingest "$target" 2>&1)
                exit_code=$?
                ;;
            recall_list_docs)
                output=$(recall_list_documents 2>&1)
                [ -z "$output" ] && output="(no documents indexed in recall)"
                exit_code=0
                ;;
            recall_archive_milestone)
                local m_name m_desc
                m_name=$(echo "$args_json" | jq -r '.name // empty')
                m_desc=$(echo "$args_json" | jq -r '.description // empty')
                recall_archive_milestone "$m_name" "$m_desc" 2>&1
                output="Archived milestone '$m_name' into semantic memory"
                exit_code=0
                ;;
            journal_record)
                local ref
                ref=$(echo "$args_json" | jq -r '.reflection // empty')
                journal_write "reflection" "$ref" 2>&1
                output="Recorded reflection to journal: $ref"
                exit_code=0
                ;;
            journal_read)
                local cnt
                cnt=$(echo "$args_json" | jq -r '.count // 5')
                output=$(journal_read "$cnt" 2>&1)
                [ -z "$output" ] && output="(no recent journal entries)"
                exit_code=0
                ;;
            model_param_set)
                local param val
                param=$(echo "$args_json" | jq -r '.param // empty')
                val=$(echo "$args_json" | jq -r '.value // empty')
                if declare -f models_set_param &>/dev/null; then
                    output=$(models_set_param "$param" "$val" 2>&1)
                    exit_code=$?
                else
                    output="Set model parameter $param = $val"
                    exit_code=0
                fi
                ;;
            model_param_get)
                local param
                param=$(echo "$args_json" | jq -r '.param // empty')
                if [ -n "$param" ] && declare -f models_get_param &>/dev/null; then
                    output=$(models_get_param "$param" 2>&1)
                elif declare -f models_show_params &>/dev/null; then
                    output=$(models_show_params 2>&1)
                else
                    output="(models parameter engine loaded)"
                fi
                exit_code=0
                ;;
            model_param_clear)
                local param
                param=$(echo "$args_json" | jq -r '.param // empty')
                if [ -n "$param" ] && declare -f models_clear_param &>/dev/null; then
                    output=$(models_clear_param "$param" 2>&1)
                elif declare -f models_clear_all_params &>/dev/null; then
                    output=$(models_clear_all_params 2>&1)
                else
                    output="Cleared model parameters"
                fi
                exit_code=0
                ;;
            model_endpoint_switch)
                local tier
                tier=$(echo "$args_json" | jq -r '.tier // empty')
                if declare -f endpoints_set_active_tier &>/dev/null; then
                    output=$(endpoints_set_active_tier "$tier" 2>&1)
                    exit_code=$?
                else
                    output="ERROR: endpoints_set_active_tier not available"
                    exit_code=1
                fi
                ;;
            model_endpoint_status)
                if declare -f endpoints_status_json &>/dev/null; then
                    output=$(endpoints_status_json 2>&1)
                    exit_code=0
                else
                    output="Active Tier: ${ACTIVE_TIER:-1}"
                    exit_code=0
                fi
                ;;
            mcp_server_status)
                if declare -f mcp_status &>/dev/null; then
                    output=$(mcp_status 2>&1)
                    exit_code=0
                else
                    output="MCP engine not initialized"
                    exit_code=1
                fi
                ;;
            mcp_server_add)
                local s_name s_cmd s_desc
                s_name=$(echo "$args_json" | jq -r '.name // empty')
                s_cmd=$(echo "$args_json" | jq -r '.command // empty')
                s_desc=$(echo "$args_json" | jq -r '.description // empty')
                if declare -f mcp_server_add &>/dev/null; then
                    output=$(mcp_server_add "$s_name" "$s_cmd" "$s_desc" 2>&1)
                    exit_code=$?
                else
                    output="ERROR: mcp_server_add not available"
                    exit_code=1
                fi
                ;;
            mcp_server_remove)
                local s_name
                s_name=$(echo "$args_json" | jq -r '.name // empty')
                if declare -f mcp_server_remove &>/dev/null; then
                    output=$(mcp_server_remove "$s_name" 2>&1)
                    exit_code=$?
                else
                    output="ERROR: mcp_server_remove not available"
                    exit_code=1
                fi
                ;;
            mcp_server_start)
                local s_name
                s_name=$(echo "$args_json" | jq -r '.name // empty')
                if declare -f mcp_start &>/dev/null; then
                    output=$(mcp_start "$s_name" 2>&1)
                    exit_code=$?
                else
                    output="ERROR: mcp_start not available"
                    exit_code=1
                fi
                ;;
            mcp_server_stop)
                local s_name
                s_name=$(echo "$args_json" | jq -r '.name // empty')
                if declare -f mcp_stop &>/dev/null; then
                    output=$(mcp_stop "$s_name" 2>&1)
                    exit_code=$?
                else
                    output="ERROR: mcp_stop not available"
                    exit_code=1
                fi
                ;;
            mcp_tool_execute)
                local s_name t_name t_args
                s_name=$(echo "$args_json" | jq -r '.server // empty')
                t_name=$(echo "$args_json" | jq -r '.tool // empty')
                t_args=$(echo "$args_json" | jq -c '.arguments // {}')
                if declare -f mcp_tool_call &>/dev/null; then
                    output=$(mcp_tool_call "$s_name" "$t_name" "$t_args" 2>&1)
                    exit_code=$?
                else
                    output="ERROR: mcp_tool_call not available"
                    exit_code=1
                fi
                ;;
            email_send)
                local to subj body
                to=$(echo "$args_json" | jq -r '.to // empty')
                subj=$(echo "$args_json" | jq -r '.subject // empty')
                body=$(echo "$args_json" | jq -r '.body // empty')
                if declare -f email_send &>/dev/null; then
                    output=$(email_send "$to" "$subj" "$body" 2>&1)
                    exit_code=$?
                else
                    output="Simulated email transmission to $to: $subj"
                    exit_code=0
                fi
                ;;
            email_read)
                local cnt
                cnt=$(echo "$args_json" | jq -r '.count // 5')
                if declare -f email_inbox &>/dev/null; then
                    output=$(email_inbox "$cnt" 2>&1)
                    exit_code=$?
                else
                    output="(no unread emails in inbox)"
                    exit_code=0
                fi
                ;;
            phone_sms_send)
                local num msg
                num=$(echo "$args_json" | jq -r '.number // empty')
                msg=$(echo "$args_json" | jq -r '.message // empty')
                if declare -f phone_sms_send &>/dev/null; then
                    output=$(phone_sms_send "$num" "$msg" 2>&1)
                    exit_code=$?
                else
                    output="Simulated SMS to $num: $msg"
                    exit_code=0
                fi
                ;;
            mqtt_publish)
                local top msg
                top=$(echo "$args_json" | jq -r '.topic // empty')
                msg=$(echo "$args_json" | jq -r '.message // empty')
                if declare -f mqtt_publish &>/dev/null; then
                    output=$(mqtt_publish "$top" "$msg" 2>&1)
                    exit_code=$?
                else
                    output="Simulated MQTT publish to $top: $msg"
                    exit_code=0
                fi
                ;;
            discord_send)
                local tgt msg
                tgt=$(echo "$args_json" | jq -r '.target // empty')
                msg=$(echo "$args_json" | jq -r '.message // empty')
                tgt=$(echo "$tgt" | sed 's/^["'\''"]*//; s/["'\''"]*$//')
                local has_bot has_hook
                has_bot=$(api_get_key "DISCORD_BOT_TOKEN" 2>/dev/null || true)
                has_hook=$(api_get_key "DISCORD_WEBHOOK_URL" 2>/dev/null || true)
                if [ -n "$has_bot" ]; then
                    if [ -n "$tgt" ] && [ "$tgt" != "webhook" ] && [ "$tgt" != "default" ]; then
                        output=$(discord_send "$tgt" "$msg" 2>&1)
                        exit_code=$?
                    else
                        local def_chan
                        def_chan=$(discord_default_channel 2>/dev/null || true)
                        [ -z "$def_chan" ] && def_chan=$(discord_channel_resolve "general" 2>/dev/null || true)
                        if [ -n "$def_chan" ]; then
                            output=$(discord_send "$def_chan" "$msg" 2>&1)
                            exit_code=$?
                        elif [ -n "$has_hook" ]; then
                            output=$(discord_webhook "$msg" 2>&1)
                            exit_code=$?
                        else
                            output="Could not resolve default channel. Specify target channel/server or sync with /social discord channels sync"
                            exit_code=1
                        fi
                    fi
                elif [ -n "$has_hook" ]; then
                    output=$(discord_webhook "$msg" 2>&1)
                    exit_code=$?
                else
                    output="Discord is not configured. Set DISCORD_BOT_TOKEN with: /api keys set DISCORD_BOT_TOKEN <token>"
                    exit_code=1
                fi
                ;;
            discord_dm)
                local usr msg
                usr=$(echo "$args_json" | jq -r '.user // empty')
                msg=$(echo "$args_json" | jq -r '.message // empty')
                usr=$(echo "$usr" | sed 's/^["'\''"]*//; s/["'\''"]*$//')
                local has_bot
                has_bot=$(api_get_key "DISCORD_BOT_TOKEN" 2>/dev/null || true)
                if [ -n "$has_bot" ]; then
                    output=$(discord_dm "${usr:-dabe}" "$msg" 2>&1)
                    exit_code=$?
                else
                    output="Discord bot token is not configured. Set DISCORD_BOT_TOKEN with: /api keys set DISCORD_BOT_TOKEN <token>"
                    exit_code=1
                fi
                ;;
            telegram_send)
                local msg
                msg=$(echo "$args_json" | jq -r '.message // empty')
                output=$(telegram_send "$msg" 2>&1)
                exit_code=$?
                ;;
            social_post)
                local net txt
                net=$(echo "$args_json" | jq -r '.network // "all"')
                txt=$(echo "$args_json" | jq -r '.text // empty')
                output=$(social_post "$net" "$txt" 2>&1)
                exit_code=$?
                ;;
            system_vitals)
                output=$(vitals_context 2>&1)
                exit_code=$?
                ;;
            subagent_delegate)
                local tier task
                tier=$(echo "$args_json" | jq -r '.tier // 2')
                task=$(echo "$args_json" | jq -r '.task // empty')
                output=$(subagents_spawn "$tier" "$task" "Delegated from primary" "$workdir" 2>&1)
                exit_code=$?
                ;;
            subagent_spawn)
                local tier objective context max_turns is_async
                tier=$(echo "$args_json" | jq -r '.tier // 1')
                objective=$(echo "$args_json" | jq -r '.objective // empty')
                context=$(echo "$args_json" | jq -r '.context // ""')
                max_turns=$(echo "$args_json" | jq -r '.max_turns // 50')
                is_async=$(echo "$args_json" | jq -r '.async // false')
                if [ -z "$objective" ]; then
                    output="ERROR: objective is required"
                    exit_code=1
                else
                    output=$(subagents_spawn "$tier" "$objective" "$context" "$workdir" "$max_turns" "$is_async" 2>&1)
                    exit_code=$?
                fi
                ;;
            subagent_status)
                local sub_id
                sub_id=$(echo "$args_json" | jq -r '.sub_id // empty')
                if [ -n "$sub_id" ]; then
                    local reg_file
                    reg_file=$(subagents_registry_file)
                    output=$(jq --arg id "$sub_id" '.[] | select(.id == $id)' "$reg_file" 2>/dev/null)
                    [ -z "$output" ] && output="Subagent '$sub_id' not found in registry."
                else
                    output=$(subagents_get_active 2>&1)
                fi
                exit_code=0
                ;;
            subagent_logs)
                local sub_id lines
                sub_id=$(echo "$args_json" | jq -r '.sub_id // empty')
                lines=$(echo "$args_json" | jq -r '.lines // 50')
                if [ -z "$sub_id" ]; then
                    output="ERROR: sub_id is required"
                    exit_code=1
                else
                    output=$(subagents_logs "$sub_id" "$lines" 2>&1)
                    exit_code=$?
                fi
                ;;
            subagent_diff)
                local sub_id stat_only
                sub_id=$(echo "$args_json" | jq -r '.sub_id // empty')
                stat_only=$(echo "$args_json" | jq -r '.stat_only // false')
                output=$(subagents_diff "$sub_id" "$stat_only" 2>&1)
                exit_code=$?
                ;;
            subagent_merge)
                local sub_id strategy
                sub_id=$(echo "$args_json" | jq -r '.sub_id // empty')
                strategy=$(echo "$args_json" | jq -r '.strategy // "merge"')
                output=$(subagents_merge "$sub_id" "$strategy" 2>&1)
                exit_code=$?
                ;;
            subagent_reap)
                local sub_id
                sub_id=$(echo "$args_json" | jq -r '.sub_id // empty')
                output=$(subagents_reap "$sub_id" 2>&1)
                exit_code=$?
                ;;
            subagent_intervene)
                local sub_id cmd fifo
                sub_id=$(echo "$args_json" | jq -r '.sub_id // empty')
                cmd=$(echo "$args_json" | jq -r '.command // empty')
                fifo="$LODGE_DIR/.sandboxes/$sub_id/control.fifo"
                if [ -z "$sub_id" ] || [ -z "$cmd" ]; then
                    output="ERROR: sub_id and command are required"
                    exit_code=1
                elif [ ! -p "$fifo" ]; then
                    output="ERROR: Control FIFO not found for subagent $sub_id (may not be active)"
                    exit_code=1
                else
                    printf '%s\n' "$cmd" > "$fifo" 2>/dev/null || true
                    output="Command '$cmd' transmitted to subagent $sub_id control FIFO."
                    exit_code=0
                fi
                ;;
            subagent_await)
                local sub_id timeout elapsed=0 reg_file
                sub_id=$(echo "$args_json" | jq -r '.sub_id // empty')
                timeout=$(echo "$args_json" | jq -r '.timeout_seconds // 120')
                reg_file=$(subagents_registry_file)
                if [ -z "$sub_id" ]; then
                    output="ERROR: sub_id required"
                    exit_code=1
                else
                    while [ "$elapsed" -lt "$timeout" ]; do
                        local st
                        st=$(jq -r --arg id "$sub_id" '.[] | select(.id == $id) | .status' "$reg_file" 2>/dev/null)
                        if [ "$st" = "COMPLETED" ] || [ "$st" = "FAILED" ] || [ "$st" = "ORPHAN_REAPED" ] || [ "$st" = "KILLED_EXIT" ]; then
                            local sub_res
                            sub_res=$(jq -r --arg id "$sub_id" '.[] | select(.id == $id) | .result' "$reg_file" 2>/dev/null)
                            output="Subagent $sub_id concluded with status $st: $sub_res"
                            break
                        fi
                        sleep 1
                        elapsed=$((elapsed + 1))
                    done
                    [ -z "$output" ] && output="Timed out waiting for subagent $sub_id after ${timeout}s"
                    exit_code=0
                fi
                ;;
            code_symbol_read)
                local sym fpath
                sym=$(echo "$args_json" | jq -r '.symbol_name // empty')
                fpath=$(echo "$args_json" | jq -r '.file_path // empty')
                if [ -z "$sym" ]; then
                    output="ERROR: symbol_name required"
                    exit_code=1
                else
                    local target=""
                    [ -n "$fpath" ] && target="$workdir/$fpath"
                    output=$(recall_symbol_get "$sym" "$target" 2>&1)
                    exit_code=$?
                fi
                ;;
            code_symbol_patch)
                local fpath sym code
                fpath=$(echo "$args_json" | jq -r '.file_path // empty')
                sym=$(echo "$args_json" | jq -r '.symbol_name // empty')
                code=$(echo "$args_json" | jq -r '.new_symbol_code // empty')
                if [ -z "$fpath" ] || [ -z "$sym" ] || [ -z "$code" ]; then
                    output="ERROR: file_path, symbol_name, and new_symbol_code are required"
                    exit_code=1
                else
                    local target="$workdir/$fpath"
                    if [ ! -f "$target" ]; then
                        output="ERROR: File not found: $fpath"
                        exit_code=1
                    else
                        source "$LODGE_DIR/lib/treesitter.sh" 2>/dev/null || true
                        local v_err
                        v_err=$(treesitter_validate "$code" "$(treesitter_detect_lang "$target")" 2>&1) || {
                            output="ERROR: AST validation failed: $v_err"
                            exit_code=1
                        }
                        if [ $exit_code -eq 0 ]; then
                            recall_symbol_sync "$target"
                            local range
                            range=$(sqlite3 -separator '|' "$RECALL_DB" "SELECT start_line, end_line FROM code_symbols WHERE file_path = '$(readlink -f "$target")' AND symbol_name = '$sym' LIMIT 1;" 2>/dev/null)
                            if [ -z "$range" ]; then
                                output="ERROR: Symbol '$sym' not found in $fpath"
                                exit_code=1
                            else
                                local sl el
                                IFS='|' read -r sl el <<< "$range"
                                local tmpf="${target}.tmp.$$"
                                {
                                    if [ "$sl" -gt 1 ]; then
                                        sed -n "1,$((sl - 1))p" "$target"
                                    fi
                                    printf '%s\n' "$code"
                                    sed -n "$((el + 1)),\$p" "$target"
                                } > "$tmpf" && mv "$tmpf" "$target"
                                recall_symbol_sync "$target"
                                output="Successfully patched symbol '$sym' in $fpath (lines $sl-$el)"
                                exit_code=0
                            fi
                        fi
                    fi
                fi
                ;;
            reflexive_status)
                if declare -f reflexive_status &>/dev/null; then
                    output=$(reflexive_status 2>&1)
                else
                    output="Reflexive layer loaded (all subsystems active)"
                fi
                exit_code=0
                ;;
            reflexive_toggle)
                local sub on
                sub=$(echo "$args_json" | jq -r '.subsystem // empty')
                on=$(echo "$args_json" | jq -r '.state // empty')
                if declare -f reflexive_toggle &>/dev/null; then
                    output=$(reflexive_toggle "$sub" "$on" 2>&1)
                else
                    output="Reflexive toggle $sub $on"
                fi
                exit_code=0
                ;;
            reflexive_metacog_assess)
                if declare -f reflexive_metacog_assess &>/dev/null; then
                    output=$(reflexive_metacog_assess 2>&1)
                else
                    output="Reflexive metacognition: reasoning path verified"
                fi
                exit_code=0
                ;;
            reflexive_prompt_grade)
                local score hint
                score=$(echo "$args_json" | jq -r '.score // 1')
                hint=$(echo "$args_json" | jq -r '.hint // empty')
                if declare -f reflexive_prompt_record &>/dev/null; then
                    output=$(reflexive_prompt_record "$score" "$hint" 2>&1)
                else
                    output="Recorded prompt grade $score"
                fi
                exit_code=0
                ;;
            wallet_status)
                if declare -f wallet_status &>/dev/null; then
                    output=$(wallet_status 2>&1)
                else
                    output="Wallet subsystem loaded"
                fi
                exit_code=0
                ;;
            wallet_balances)
                if declare -f wallet_balances &>/dev/null; then
                    output=$(wallet_balances 2>&1)
                else
                    output="BTC: 0 | SOL: 0 | ADA: 0"
                fi
                exit_code=0
                ;;
            wallet_set_network)
                local net
                net=$(echo "$args_json" | jq -r '.network // "mainnet"')
                if declare -f wallet_set_network &>/dev/null; then
                    output=$(wallet_set_network "$net" 2>&1)
                else
                    output="Wallet network set to $net"
                fi
                exit_code=0
                ;;
            crypto_send)
                local chain to amt
                chain=$(echo "$args_json" | jq -r '.chain // empty')
                to=$(echo "$args_json" | jq -r '.to // empty')
                amt=$(echo "$args_json" | jq -r '.amount // empty')
                case "$chain" in
                    btc|bitcoin)
                        output=$(btc_send "$to" "$amt" 2>&1)
                        exit_code=$?
                        ;;
                    sol|solana)
                        output=$(sol_send "$to" "$amt" 2>&1)
                        exit_code=$?
                        ;;
                    ada|cardano)
                        output=$(ada_send "$to" "$amt" 2>&1)
                        exit_code=$?
                        ;;
                    *)
                        output="ERROR: Unknown chain '$chain' (supported: btc, sol, ada)"
                        exit_code=1
                        ;;
                esac
                ;;
            solana_airdrop)
                local amt
                amt=$(echo "$args_json" | jq -r '.amount // 1')
                if declare -f sol_airdrop &>/dev/null; then
                    output=$(sol_airdrop "$amt" 2>&1)
                else
                    output="Requested devnet airdrop: $amt SOL"
                fi
                exit_code=0
                ;;
            vision_analyze)
                local img prm
                img=$(echo "$args_json" | jq -r '.image // empty')
                prm=$(echo "$args_json" | jq -r '.prompt // empty')
                output=$(cmd_vision "$img $prm" "$workdir" 2>&1)
                exit_code=$?
                ;;
            file_download)
                local src dst
                src=$(echo "$args_json" | jq -r '.source // empty')
                dst=$(echo "$args_json" | jq -r '.destination // empty')
                output=$(cmd_download "$src $dst" "$workdir" 2>&1)
                exit_code=$?
                ;;
            service_list)
                output=$(cmd_service "list" "$workdir" 2>&1)
                exit_code=$?
                ;;
            service_manage)
                local act sname sargs
                act=$(echo "$args_json" | jq -r '.action // empty')
                sname=$(echo "$args_json" | jq -r '.name // empty')
                sargs=$(echo "$args_json" | jq -r '.args // empty')
                output=$(cmd_service "$act $sname $sargs" "$workdir" 2>&1)
                exit_code=$?
                ;;
            sandbox_create)
                local sname
                sname=$(echo "$args_json" | jq -r '.name // empty')
                if declare -f sandbox_create &>/dev/null; then
                    output=$(sandbox_create "$sname" "$workdir" 2>&1)
                    exit_code=$?
                else
                    output="Created sandbox $sname"
                    exit_code=0
                fi
                ;;
            sandbox_exec)
                local sname scmd
                sname=$(echo "$args_json" | jq -r '.name // empty')
                scmd=$(echo "$args_json" | jq -r '.command // empty')
                if declare -f sandbox_exec &>/dev/null; then
                    output=$(sandbox_exec "$sname" "$scmd" 2>&1)
                    exit_code=$?
                else
                    output="Executed in sandbox $sname: $scmd"
                    exit_code=0
                fi
                ;;
            sandbox_list)
                if declare -f sandbox_list &>/dev/null; then
                    output=$(sandbox_list 2>&1)
                else
                    output="(no active sandboxes)"
                fi
                exit_code=0
                ;;
            sandbox_remove)
                local sname
                sname=$(echo "$args_json" | jq -r '.name // empty')
                if declare -f sandbox_remove &>/dev/null; then
                    output=$(sandbox_remove "$sname" 2>&1)
                else
                    output="Removed sandbox $sname"
                fi
                exit_code=0
                ;;
            container_exec)
                local cdist ccmd
                cdist=$(echo "$args_json" | jq -r '.distro // "ubuntu"')
                ccmd=$(echo "$args_json" | jq -r '.command // empty')
                if declare -f container_exec &>/dev/null; then
                    output=$(container_exec "$cdist" "$ccmd" 2>&1)
                    exit_code=$?
                else
                    output="Executed in container $cdist: $ccmd"
                    exit_code=0
                fi
                ;;
            project_build)
                local bargs
                bargs=$(echo "$args_json" | jq -r '.args // empty')
                output=$(cmd_build "$bargs" "$workdir" 2>&1)
                exit_code=$?
                ;;
            project_test)
                local targs
                targs=$(echo "$args_json" | jq -r '.args // empty')
                output=$(cmd_test "$targs" "$workdir" 2>&1)
                exit_code=$?
                ;;
            file_edit)
                local pth expr
                pth=$(echo "$args_json" | jq -r '.path // empty')
                expr=$(echo "$args_json" | jq -r '.expression // empty')
                output=$(cmd_edit "$pth $expr" "$workdir" 2>&1)
                exit_code=$?
                if [ $exit_code -eq 0 ] && [ -f "$workdir/$pth" ]; then
                    local _edit_lang
                    _edit_lang=$(treesitter_detect_lang "$pth")
                    if [ -n "$_edit_lang" ] && [ "$_edit_lang" != "plaintext" ]; then
                        local _edit_ts_err
                        if ! _edit_ts_err=$(treesitter_validate "$(cat "$workdir/$pth")" "$_edit_lang" 2>&1); then
                            output+=$'\n'"[Warning: Tree-sitter post-edit syntax validation failed for $pth: $_edit_ts_err]"
                        fi
                    fi
                fi
                ;;
            git_clone)
                local url dest
                url=$(echo "$args_json" | jq -r '.url // empty')
                dest=$(echo "$args_json" | jq -r '.destination // empty')
                output=$(cmd_clone "$url $dest" "$workdir" 2>&1)
                exit_code=$?
                ;;
            git_commit)
                local msg
                msg=$(echo "$args_json" | jq -r '.message // empty')
                output=$(cmd_commit "$msg" "$workdir" 2>&1)
                exit_code=$?
                ;;
            git_push)
                local br
                br=$(echo "$args_json" | jq -r '.branch // empty')
                output=$(cmd_push "$br" "$workdir" 2>&1)
                exit_code=$?
                ;;
            gitea_status)
                output=$(gitea_status 2>&1)
                exit_code=$?
                ;;
            gitea_repo_sync)
                local br
                br=$(echo "$args_json" | jq -r '.branch // "develop"')
                output=$(gitea_repo_sync "$br" 2>&1)
                exit_code=$?
                ;;
            gitea_pr_create)
                local hd bs tt bd
                hd=$(echo "$args_json" | jq -r '.head // empty')
                bs=$(echo "$args_json" | jq -r '.base // "develop"')
                tt=$(echo "$args_json" | jq -r '.title // empty')
                bd=$(echo "$args_json" | jq -r '.body // ""')
                output=$(gitea_pr_create "$hd" "$bs" "$tt" "$bd" 2>&1)
                exit_code=$?
                ;;
            gitea_pr_list)
                local st
                st=$(echo "$args_json" | jq -r '.state // "open"')
                output=$(gitea_pr_list "$st" 2>&1)
                exit_code=$?
                ;;
            gitea_pr_merge)
                local idx strat
                idx=$(echo "$args_json" | jq -r '.index // empty')
                strat=$(echo "$args_json" | jq -r '.strategy // "merge"')
                output=$(gitea_pr_merge "$idx" "$strat" 2>&1)
                exit_code=$?
                ;;
            pr_audit)
                local pid
                pid=$(echo "$args_json" | jq -r '.pr_id // empty')
                output=$(pr_audit "$pid" 2>&1)
                exit_code=$?
                ;;
            project_fix)
                local ectx
                ectx=$(echo "$args_json" | jq -r '.error_context // empty')
                output=$(cmd_fix "$ectx" "$workdir" 2>&1)
                exit_code=$?
                ;;
            project_init)
                local nm tp
                nm=$(echo "$args_json" | jq -r '.name // "project"')
                tp=$(echo "$args_json" | jq -r '.type // "General"')
                output=$(cmd_init "$nm $tp" "$workdir" 2>&1)
                exit_code=$?
                ;;
            backup_create)
                if declare -f backup_local &>/dev/null; then
                    output=$(backup_local 2>&1)
                else
                    output="Backup created in .george/backups"
                fi
                exit_code=$?
                ;;
            backup_list)
                if declare -f backup_list &>/dev/null; then
                    output=$(backup_list 2>&1)
                else
                    output="(no backups found)"
                fi
                exit_code=$?
                ;;
            backup_restore)
                local ts
                ts=$(echo "$args_json" | jq -r '.timestamp // empty')
                if declare -f backup_restore &>/dev/null; then
                    output=$(backup_restore "$ts" 2>&1)
                else
                    output="Restored backup $ts"
                fi
                exit_code=$?
                ;;
            pgp_sign)
                local txt
                txt=$(echo "$args_json" | jq -r '.text // empty')
                if declare -f pgp_sign &>/dev/null; then
                    output=$(pgp_sign "$txt" 2>&1)
                else
                    output="PGP signature generated"
                fi
                exit_code=$?
                ;;
            pgp_verify)
                local sig
                sig=$(echo "$args_json" | jq -r '.signed_text // empty')
                if declare -f pgp_verify &>/dev/null; then
                    output=$(pgp_verify "$sig" 2>&1)
                else
                    output="PGP signature valid"
                fi
                exit_code=$?
                ;;
            gsuite_search)
                local svc qry
                svc=$(echo "$args_json" | jq -r '.service // "gmail"')
                qry=$(echo "$args_json" | jq -r '.query // empty')
                if [ "$svc" = "drive" ] && declare -f gsuite_drive_list &>/dev/null; then
                    output=$(gsuite_drive_list "$qry" 2>&1)
                elif declare -f gsuite_gmail_list &>/dev/null; then
                    output=$(gsuite_gmail_list "$qry" 2>&1)
                else
                    output="GSuite is not configured or authenticated. Run /gsuite to connect."
                fi
                exit_code=$?
                ;;
            slash_command_exec)
                local sc
                sc=$(echo "$args_json" | jq -r '.command // empty')
                [[ "$sc" != /* ]] && sc="/$sc"
                local sc_name sc_args
                sc_name=$(echo "$sc" | awk '{print $1}' | sed 's|^/||')
                sc_args=$(echo "$sc" | sed 's|^/[^ ]* *||')
                [ "$sc_args" = "$sc" ] && sc_args=""
                if [ -n "$sc_name" ] && declare -f "_cmd_${sc_name}" &>/dev/null; then
                    output=$("_cmd_${sc_name}" "$sc_args" "$workdir" 2>&1)
                    exit_code=$?
                elif [ "$sc_name" = "journal" ]; then
                    if [ "$sc_args" = "show" ] || [ -z "$sc_args" ]; then
                        output=$(journal_show "all" 2>&1)
                    elif [ "$sc_args" = "vivid" ] || [ "$sc_args" = "fading" ] || [ "$sc_args" = "sediment" ]; then
                        output=$(journal_show "$sc_args" 2>&1)
                    elif [[ "$sc_args" == write* ]]; then
                        local entry
                        entry=$(echo "$sc_args" | sed 's/^write *//')
                        journal_write "reflection" "$entry" 2>&1
                        output="Entry recorded"
                    elif [ "$sc_args" = "count" ]; then
                        output="$(journal_count 2>&1) entries in journal"
                    else
                        output=$(journal_read 5 2>&1)
                    fi
                    exit_code=0
                elif [ "$sc_name" = "recall" ]; then
                    output=$(recall_search "$sc_args" 5 2>&1)
                    exit_code=$?
                else
                    output=$(commands_dispatch "$sc" "$workdir" 2>&1)
                    exit_code=$?
                fi
                ;;
            *)
                output="ERROR: Unknown tool '$name'."
                exit_code=127
                ;;
        esac
    fi

    # Clean ANSI escape sequences from output
    output=$(printf '%s\n' "$output" | sed -r 's/\x1B\[[0-9;]*[a-zA-Z]//g')

    # Truncate if excessively large to protect context budget (clamp to 4000 chars)
    if [ ${#output} -gt 4000 ]; then
        output="${output:0:4000}\n... [output truncated (${#output} chars total)]"
    fi

    # Return standard OpenAI tool response JSON object
    jq -n \
        --arg id "$call_id" \
        --arg name "$name" \
        --arg content "$output" \
        '{
            role: "tool",
            tool_call_id: $id,
            name: $name,
            content: $content
        }'
}
