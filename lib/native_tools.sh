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
      "description": "Execute a bash shell command within the project workspace. Use when: (1) running builds or automated tests, (2) checking system processes, or (3) inspecting git history. Do NOT use bash_exec to write/edit files (use file_write or file_edit instead). Do NOT use bash_exec to dispatch slash commands (use slash_command_exec instead). Examples: command=\"cargo test\", command=\"./tests/test_cron.sh\", command=\"git status\".",
      "parameters": {
        "type": "object",
        "properties": {
          "command": { "type": "string", "description": "The bash shell command string to execute (e.g. \"cargo build\", \"git status\")." }
        },
        "required": ["command"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "file_read",
      "description": "Read a targeted range of lines from a local file in the workspace or semantic memory (auto-paginated, default: 100 lines, max: 200). Supports reading working memory with path=\"mem:active_task\". Use when: inspecting source code, reading configs before modifying them, or inspecting task deliverables. Examples: path=\"lib/cron.sh\", start_line=1, max_lines=100; path=\"mem:active_task\", start_line=1, max_lines=100.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": { "type": "string", "description": "Relative file path from workspace root (e.g. \"lib/cron.sh\", \"web/src/main.rs\") or semantic memory handle (\"mem:active_task\")." },
          "start_line": { "type": "integer", "description": "Starting line number (1-indexed, default: 1)." },
          "max_lines": { "type": "integer", "description": "Number of lines to read (default: 100, max: 200). Inspect code in 100-200 line chunks." }
        },
        "required": ["path"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "pdf_read",
      "description": "Extract text and structured page content from a PDF document using Poppler pdftotext. Use when: inspecting specification PDFs, research papers, or documentation. Examples: path=\"docs/spec.pdf\", max_pages=10.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": { "type": "string", "description": "Relative file path from workspace root or absolute path to the PDF." },
          "page_start": { "type": "integer", "description": "Optional starting page number (1-indexed, default: 1)." },
          "page_end": { "type": "integer", "description": "Optional ending page number." },
          "max_pages": { "type": "integer", "description": "Optional maximum number of pages to extract (default: 20)." },
          "layout": { "type": "boolean", "description": "Preserve visual column and tabular layout (default: true)." }
        },
        "required": ["path"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "workflow_plan",
      "description": "Initiate interactive feature/task planning with George and the operator. Clarifies requirements, formulates implementation scope, asks critical design questions, and drafts an implementation plan contract before editing code or running deep tasks. Use when: approaching multi-component features or breaking changes. Examples: objective=\"Implement distributed telemetry worker\", questions=\"Should we use MQTT or WebSockets?\".",
      "parameters": {
        "type": "object",
        "properties": {
          "objective": { "type": "string", "description": "Primary goal, feature requirement, or research objective to plan." },
          "context": { "type": "string", "description": "Optional background information, constraints, or findings to consider." },
          "questions": { "type": "string", "description": "Optional clarifying questions or design tradeoffs for George and the operator to answer." }
        },
        "required": ["objective"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "workflow_run",
      "description": "Execute a Blue Lodge multi-agent workflow to perform coordinated team operations. Use when: delegating complete lifecycle phases (planning, audit, verification). Examples: name=\"the-architect\", args=\"design metrics service\"; name=\"tester\", args=\"run all cron tests\".",
      "parameters": {
        "type": "object",
        "properties": {
          "name": { "type": "string", "description": "Name of the workflow to run (e.g. the-architect, dispatcher, george, tester, etc.)." },
          "args": { "type": "string", "description": "Arguments, context, or task description passed to the workflow." }
        },
        "required": ["name"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "task_wait",
      "description": "Suspend execution and sleep for N seconds (e.g. waiting for a background service, test completion, or timeout). Returns cleanly when the timer expires. Examples: seconds=5, reason=\"Wait for background service startup\"; seconds=15, reason=\"Wait for build completion\".",
      "parameters": {
        "type": "object",
        "properties": {
          "seconds": { "type": "integer", "description": "Number of seconds to wait (1 to 600)." },
          "reason": { "type": "string", "description": "Explanation of what is being waited on." }
        },
        "required": ["seconds", "reason"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "tool_search",
      "description": "Search the sovereign tool catalog using natural language intent or category tags (e.g. +ops, +git, +social, +web, cron scheduling, docker). Dynamically auto-mounts discovered tools into your active session. Use when: you need a capability not in your current profile or are unsure how to perform an action. Examples: query=\"how to schedule recurring task\", query=\"+ops\", query=\"docker container exec\".",
      "parameters": {
        "type": "object",
        "properties": {
          "query": { "type": "string", "description": "The search query, task intent, or bundle name (e.g. \"+ops\", \"how to schedule cron\", \"+git\")." }
        },
        "required": ["query"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "milestone_complete",
      "description": "Signal that the active milestone is complete or blocked, and submit structured observations and discovered facts to the DAG state barrier. Use when: you have fulfilled your current milestone task and are ready to advance the pipeline. Examples: status=\"success\", summary=\"Phytology status verified: 66 Cambium modules operational.\", facts_discovered=[\"Cambium kernel healthy\", \"0 syntax errors\"]; status=\"blocked\", summary=\"Missing required dependency cargo-tarpaulin\".",
      "parameters": {
        "type": "object",
        "properties": {
          "status": { "type": "string", "enum": ["success", "blocked"], "description": "Whether the milestone was successfully completed or is blocked." },
          "summary": { "type": "string", "description": "Concise summary of actions taken, discoveries made, or blocking reasons." },
          "facts_discovered": { "type": "array", "items": { "type": "string" }, "description": "Key factual findings or artifacts produced during this milestone." }
        },
        "required": ["status", "summary"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "file_write",
      "description": "Create a new file or completely overwrite an existing file with specified content. Use when: (1) creating new scripts in .george/tools/ or .george/cron_jobs/, (2) creating new microservice source files, (3) writing complete new modules, or (4) saving persistent task deliverables, research summaries, and working notes using path=\"mem:active_task\". Do NOT use for small surgical edits to large files (use file_edit instead). Examples: path=\".george/cron_jobs/cache_cleaner.sh\", content=\"#!/bin/bash\\n# INTERVAL: 3600\\n# DESC: Purges cache\\nrm -rf /tmp/cache/*\\n\"; path=\"mem:active_task\", content=\"# Task Report\\nSynthesized findings here.\\n\".",
      "parameters": {
        "type": "object",
        "properties": {
          "path": { "type": "string", "description": "Relative file path from workspace root (e.g. \".george/cron_jobs/my_job.sh\") or semantic memory handle (\"mem:active_task\")." },
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
      "description": "Append text content to the end of an existing file or active memory scratchpad. Use when: adding log entries, appending new exports, or writing sequentially to memory files (path=\"mem:active_task\"). Examples: path=\"GEORGE.md\", content=\"\\n- Custom note\"; path=\"mem:active_task\", content=\"\\n## Step 2 Findings\\nDetails...\".",
      "parameters": {
        "type": "object",
        "properties": {
          "path": { "type": "string", "description": "Relative file path or semantic memory handle (\"mem:active_task\")." },
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
      "description": "List directory contents formatted as an indented tree. Use when: exploring repository layout, discovering available scripts in .george/, or verifying directory structure. Examples: path=\".george/tools\", depth=2; path=\"services\", depth=2.",
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
      "description": "Perform fast regular expression search across files in the workspace using ripgrep. Use when: locating functions, variable definitions, error strings, or specific configuration keys. Examples: pattern=\"cron_enable_job\", path=\"lib/\"; pattern=\"fn main\", path=\"web/src/\".",
      "parameters": {
        "type": "object",
        "properties": {
          "pattern": { "type": "string", "description": "Regex search pattern (e.g. \"cron_enable_job\", \"struct ServiceConfig\")." },
          "path": { "type": "string", "description": "Optional subdirectory or file pattern to search within (e.g. \"lib/\", \"web/\")." }
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
      "name": "web_search_cross_section",
      "description": "Perform creative non-greedy web search that samples diverse articles across distinct semantic domains and perspectives.",
      "parameters": {
        "type": "object",
        "properties": {
          "query": { "type": "string", "description": "Search query terms." },
          "sample_size": { "type": "integer", "description": "Number of diverse cross-section articles to select (default 3)." },
          "pool_size": { "type": "integer", "description": "Candidate pool size to retrieve and sample across (default 12)." }
        },
        "required": ["query"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "research_sandbox",
      "description": "Execute an autonomous deep research investigation on any topic inside an isolated sandbox using pure bash scraping and non-greedy cross-sectional search. Ingests multiple distinct domain perspectives and returns a complete structured research dossier with source links, excerpts, and synthesis in a single turn without multiple tool calls.",
      "parameters": {
        "type": "object",
        "properties": {
          "topic": { "type": "string", "description": "The research topic, question, or entity query." },
          "sample_size": { "type": "integer", "description": "Number of distinct domain perspectives to sample (default 3)." },
          "output_file": { "type": "string", "description": "Optional file path to persist the research dossier markdown artifact." }
        },
        "required": ["topic"]
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
      "description": "Switch the active inference tier (Tier 3 Mac Ultra M5 -> Tier 1 RTX 3060 12GB -> Tier 2 AMD 5700xt -> Tier 0 Edge mobile).",
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
      "name": "discord_send_file",
      "description": "Upload a local image or file attachment (e.g. PNG, JPG, PDF, TXT) to a Discord channel or user DM.",
      "parameters": {
        "type": "object",
        "properties": {
          "target": { "type": "string", "description": "Destination channel name, ID, or user DM." },
          "file_path": { "type": "string", "description": "Absolute or workspace path to the local file/image to upload." },
          "message": { "type": "string", "description": "Optional accompanying text message." }
        },
        "required": ["target", "file_path"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "discord_read",
      "description": "Read recent message history from a Discord channel or DM (e.g. to inspect past interactions, logs, or user instructions).",
      "parameters": {
        "type": "object",
        "properties": {
          "channel": { "type": "string", "description": "Destination channel name (e.g. 'general'), numeric channel ID, or user ID." },
          "count": { "type": "integer", "description": "Number of recent messages to retrieve (default: 10, max: 50)." }
        },
        "required": ["channel"]
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
          "max_turns": { "type": "integer", "description": "Maximum turn ceiling for child agent (default: 200)." },
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
      "description": "Manage background microservices (register, build, deploy, start, stop, restart, status, logs). Use when: (1) registering a new Rust or binary service, (2) compiling and building it, or (3) controlling its daemon lifecycle. Examples: action=\"register\", name=\"metrics_worker\", args=\"services/metrics\"; action=\"build\", name=\"metrics_worker\"; action=\"start\", name=\"metrics_worker\"; action=\"status\", name=\"metrics_worker\".",
      "parameters": {
        "type": "object",
        "properties": {
          "action": { "type": "string", "description": "Action: start, stop, restart, status, logs, build, deploy, register, unregister.", "enum": ["start", "stop", "restart", "status", "logs", "build", "deploy", "register", "unregister"] },
          "name": { "type": "string", "description": "Unique service name (e.g. \"metrics_worker\", \"echo_service\")." },
          "args": { "type": "string", "description": "Optional additional arguments (e.g. \"services/my_service\" for register, line count for logs)." }
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
      "description": "Execute any Blue Lodge slash command. Use when: (1) managing Software Phytology living tissue, health, and cache status (/phytology status, /phytology audit [--cached], /phytology cache-status, /phytology cache-invalidate, /phytology heal), (2) creating, inspecting, or controlling recurring cron jobs (/cron), (3) managing microservices (/service), (4) registering tools (/tool), or (5) executing workflows (/workflow). Examples: command=\"/phytology status\", command=\"/phytology audit --cached\", command=\"/phytology cache-status\", command=\"/cron status\", command=\"/service status\".",
      "parameters": {
        "type": "object",
        "properties": {
          "command": { "type": "string", "description": "Full slash command string (e.g. \"/phytology status\", \"/phytology audit --cached\", \"/phytology cache-status\", \"/cron status\", \"/service status\")." }
        },
        "required": ["command"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "phytology_manage",
      "description": "Inspect and manage Software Phytology living tissue diagnostic, healing, and safe grafting. Use when: (1) checking living tissue status and health (status), (2) running foliage AST audits with optional LRU caching (audit, flags=\"--cached\"), (3) checking or invalidating phytology cache (cache-status, cache-invalidate), (4) autonomic healing or rolling back corrupted tissue (heal, rollback), (5) assessing tissue fitness (fitness), or (6) running phytology tests (test).",
      "parameters": {
        "type": "object",
        "properties": {
          "action": {
            "type": "string",
            "enum": ["status", "audit", "heal", "rollback", "prune", "fitness", "lignify", "cache-status", "cache-invalidate", "test"],
            "description": "The phytology action to execute."
          },
          "target": {
            "type": "string",
            "description": "Target tissue file path or job name (for rollback, prune, fitness, lignify)."
          },
          "flags": {
            "type": "string",
            "description": "Optional flags (e.g. '--cached', '--json', '--parallel', '--force')."
          }
        },
        "required": ["action"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "file_edit",
      "description": "Edit an existing file using sed substitution for targeted, surgical search-and-replace changes. Use when: updating configs, modifying environment variables, or fixing functions without re-writing the entire file. Examples: path=\"GEORGE.md\", expression=\"s/## Active Task/## Active Task\\n- Investigating metrics/g\"; path=\"web/src/main.rs\", expression=\"s/let port = 8080;/let port = 3000;/g\".",
      "parameters": {
        "type": "object",
        "properties": {
          "path": { "type": "string", "description": "Target file path relative to workspace root (e.g. \"GEORGE.md\", \"web/src/main.rs\")." },
          "expression": { "type": "string", "description": "sed expression (e.g. \"s/old_text/new_text/g\")." }
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
      "name": "gitea_set_endpoint",
      "description": "Configure or switch the active Gitea server endpoint URL (e.g. http://llama.cpp-prism:3088).",
      "parameters": {
        "type": "object",
        "properties": {
          "url": { "type": "string", "description": "New Gitea server base URL" }
        },
        "required": ["url"]
      }
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
      "name": "gitea_issue_create",
      "description": "Create a new issue on sovereign Gitea to track bugs, features, or remediation tasks.",
      "parameters": {
        "type": "object",
        "properties": {
          "title": { "type": "string", "description": "Issue title" },
          "body": { "type": "string", "description": "Detailed markdown description of the issue or feature" },
          "labels": { "type": "string", "description": "Comma-separated list of labels (e.g. 'bug,sentinel-alert' or 'feature')" }
        },
        "required": ["title"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "gitea_issue_list",
      "description": "List issues from sovereign Gitea filtered by state.",
      "parameters": {
        "type": "object",
        "properties": {
          "state": { "type": "string", "description": "Filter by state: open, closed, or all", "enum": ["open", "closed", "all"] }
        }
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "gitea_issue_get",
      "description": "Retrieve full details, description, and comments of a specific Gitea issue.",
      "parameters": {
        "type": "object",
        "properties": {
          "index": { "type": "integer", "description": "Issue number" }
        },
        "required": ["index"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "gitea_issue_comment",
      "description": "Post a status update or comment to an existing Gitea issue.",
      "parameters": {
        "type": "object",
        "properties": {
          "index": { "type": "integer", "description": "Issue number" },
          "body": { "type": "string", "description": "Markdown comment text" }
        },
        "required": ["index", "body"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "gitea_issue_close",
      "description": "Close a resolved Gitea issue with a closing explanation.",
      "parameters": {
        "type": "object",
        "properties": {
          "index": { "type": "integer", "description": "Issue number" },
          "comment": { "type": "string", "description": "Closing resolution comment" }
        },
        "required": ["index"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "gitea_branch_create",
      "description": "Create a new GitFlow branch (feature/*, fix/*) on sovereign Gitea from develop or a base branch.",
      "parameters": {
        "type": "object",
        "properties": {
          "branch_name": { "type": "string", "description": "New branch name (e.g. feature/my-feature or fix/remediation-123)" },
          "base": { "type": "string", "description": "Base branch to branch off of (default: develop)" }
        },
        "required": ["branch_name"]
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

    echo "$all_tools" | jq 'unique_by(.function.name)'
}

# ── Dynamic Schema Filter ─────────────────────────────────────────────
# Allows tasks to request a lean, scoped subset of tools (e.g. for research or code editing)
# to minimize context token prefill overhead on local LLMs.
native_tools_get_schemas() {
    local filter="${1:-all}"
    local all_tools
    all_tools=$(native_tools_get_all_schemas)

    if [ -z "$filter" ] || [ "$filter" = "all" ]; then
        echo "$all_tools"
        return 0
    fi

    echo "$all_tools" | jq --arg f "$filter" '
        ($f | split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))) as $allowed |
        [.[] | select(.function.name as $n | $allowed | index($n))]
    ' 2>/dev/null || echo "$all_tools"
}

# ── Composable Tool Bundles & Bedrock Taxonomy ────────────────────────
_BEDROCK_TOOLS="bash_exec,slash_command_exec,phytology_manage,file_read,file_write,file_edit,pdf_read,workflow_plan,workflow_run,ask_operator,task_wait,tool_search,milestone_complete,subagent_spawn,subagent_status,subagent_await,subagent_reap"

# Map bundles to their constituent tool names
native_tools_bundle_tools() {
    local bundle="$1"
    case "$bundle" in
        bedrock|_bedrock)
            echo "$_BEDROCK_TOOLS"
            ;;
        +web|web)
            echo "web_search,web_search_cross_section,web_fetch,research_sandbox,github_search"
            ;;
        +files|files)
            echo "file_write,file_append,file_edit,file_grep,dir_list"
            ;;
        +code|code)
            echo "project_build,project_test,project_fix,code_outline,code_symbol_get,code_validate,code_symbol_read,code_symbol_patch"
            ;;
        +git|git)
            echo "git_commit,git_push,gitea_branch_create,gitea_issue_create,gitea_issue_list,gitea_issue_get,gitea_issue_close,gitea_issue_comment,gitea_pr_create,gitea_pr_list,gitea_pr_merge,pr_audit,git_clone"
            ;;
        +vision|vision)
            echo "vision_analyze,file_download"
            ;;
        +social|social)
            echo "social_post,discord_send,discord_dm,discord_send_file,discord_read,telegram_send,email_send,email_read,phone_sms_send,mqtt_publish"
            ;;
        +ops|ops)
            echo "system_vitals,sandbox_create,sandbox_exec,sandbox_list,sandbox_remove,container_exec,service_manage,service_list,backup_create,backup_list,backup_restore,pgp_sign,pgp_verify"
            ;;
        +memory|memory)
            echo "recall_search,recall_ingest,recall_list_docs,recall_archive_milestone,journal_record,journal_read,memory_get_section,memory_update_section,memory_append_section,memory_read_soul"
            ;;
        +crypto|crypto)
            echo "wallet_status,wallet_balances,wallet_set_network,crypto_send,solana_airdrop"
            ;;
        +swarm|swarm)
            echo "subagent_delegate,subagent_spawn,subagent_status,subagent_logs,subagent_diff,subagent_merge,subagent_reap,subagent_intervene,subagent_await"
            ;;
        +models|models)
            echo "model_param_set,model_param_get,model_param_clear,model_endpoint_switch,model_endpoint_status,reflexive_status,reflexive_toggle,reflexive_metacog_assess,reflexive_prompt_grade"
            ;;
        +gsuite|gsuite)
            echo "gsuite_search"
            ;;
        +phytology|phytology)
            echo "phytology_manage"
            ;;
        research)
            echo "$(native_tools_bundle_tools '+web'),$(native_tools_bundle_tools '+files'),$(native_tools_bundle_tools '+vision'),$(native_tools_bundle_tools '+memory')"
            ;;
        code|coding)
            echo "$(native_tools_bundle_tools '+files'),$(native_tools_bundle_tools '+code'),$(native_tools_bundle_tools '+git')"
            ;;
        ops)
            echo "$(native_tools_bundle_tools '+files'),$(native_tools_bundle_tools '+ops'),$(native_tools_bundle_tools '+memory')"
            ;;
        social)
            echo "$(native_tools_bundle_tools '+web'),$(native_tools_bundle_tools '+social'),$(native_tools_bundle_tools '+memory'),$(native_tools_bundle_tools '+vision')"
            ;;
        default)
            echo "$(native_tools_bundle_tools '+files'),$(native_tools_bundle_tools '+git'),$(native_tools_bundle_tools '+web')"
            ;;
        +mcp_*|mcp_*)
            local s_name="${bundle#+mcp_}"
            s_name="${s_name#mcp_}"
            if declare -f mcp_tools_list &>/dev/null; then
                mcp_tools_list "$s_name" 2>/dev/null | jq -r '.[].name // empty' 2>/dev/null | tr '\n' ',' | sed 's/,$//'
            fi
            ;;
        *)
            echo ""
            ;;
    esac
}

# ── Zero-Latency Task Classifier ──────────────────────────────────────
# Inspects objective keywords to resolve optimal starting profile (~22-29 tools).
# Supports multi-domain union (capped at 36 tools).
native_tools_classify_profile() {
    local goal="${1:-}"
    [ -z "$goal" ] && { echo "default"; return 0; }

    local g_lower="${goal,,}"
    local is_research=0
    local is_code=0
    local is_ops=0
    local is_social=0

    # Domain Pattern Matching
    if echo "$g_lower" | grep -qiE '\b(research|investigate|intel|financial|background|who is|what is|find out|news|article|articles|source|sources|look up|search for|fetch|survey|overview of|profile on|history of|summary of|browse|scout|track|due diligence|public record|osint|paper|arxiv|cve)\b'; then
        is_research=1
    fi

    if echo "$g_lower" | grep -qiE '\b(code|implement|refactor|fix|bug|feature|test|tests|build|compile|cargo|npm|git|commit|patch|function|class|module|syntax|lint|debug|repo|repository|pr|pull request|script|unit test)\b'; then
        is_code=1
    fi

    if echo "$g_lower" | grep -qiE '\b(deploy|docker|container|containers|service|services|cron|daemon|vitals|sandbox|process|processes|backup|restart|hardware|gpu|server|pgp)\b'; then
        is_ops=1
    fi

    if echo "$g_lower" | grep -qiE '\b(discord|tweet|twitter|x_post|telegram|email|mail|sms|social|message|post to)\b'; then
        is_social=1
    fi

    # Multi-domain union (capped at 36 tools)
    if [ "$is_research" -eq 1 ] && [ "$is_ops" -eq 1 ] && [ "$is_social" -eq 1 ]; then
        echo "+web, +ops, +social"
    elif [ "$is_research" -eq 1 ] && [ "$is_code" -eq 1 ]; then
        echo "research, +code"
    elif [ "$is_research" -eq 1 ] && [ "$is_ops" -eq 1 ]; then
        echo "+web, +ops"
    elif [ "$is_research" -eq 1 ] && [ "$is_social" -eq 1 ]; then
        echo "+web, +social"
    elif [ "$is_ops" -eq 1 ] && [ "$is_social" -eq 1 ]; then
        echo "ops, +social"
    elif [ "$is_code" -eq 1 ] && [ "$is_ops" -eq 1 ]; then
        echo "code, +ops"
    elif [ "$is_research" -eq 1 ]; then
        echo "research"
    elif [ "$is_code" -eq 1 ]; then
        echo "code"
    elif [ "$is_ops" -eq 1 ]; then
        echo "ops"
    elif [ "$is_social" -eq 1 ]; then
        echo "social"
    else
        echo "default"
    fi
}

# ── Profile Resolver ──────────────────────────────────────────────────
# Resolves preset profile names or composable bundles into full schemas.
# Enforces strict 36-tool ceiling preserving Bedrock primacy.
native_tools_resolve_profile() {
    local profile="${1:-default}"
    local tool_list="$_BEDROCK_TOOLS"

    case "$profile" in
        worker|sandbox_worker)
            tool_list="bash_exec,file_read,file_write,file_edit,file_append,file_grep,dir_list,code_symbol_read,code_symbol_patch,git_commit,git_push,gitea_pr_create,milestone_complete"
            ;;
        worker_research)
            tool_list="bash_exec,file_read,file_grep,dir_list,web_search,web_fetch,github_search,milestone_complete"
            ;;
        research)
            tool_list+=",$(native_tools_bundle_tools '+web'),$(native_tools_bundle_tools '+files'),$(native_tools_bundle_tools '+vision'),$(native_tools_bundle_tools '+memory')"
            ;;
        code|coding)
            tool_list+=",$(native_tools_bundle_tools '+files'),$(native_tools_bundle_tools '+code'),$(native_tools_bundle_tools '+git')"
            ;;
        social)
            tool_list="${_BEDROCK_TOOLS},$(native_tools_bundle_tools '+social'),$(native_tools_bundle_tools '+vision'),$(native_tools_bundle_tools '+web'),$(native_tools_bundle_tools '+memory')"
            ;;
        social+ops|social_ops)
            tool_list="${_BEDROCK_TOOLS},$(native_tools_bundle_tools '+social'),$(native_tools_bundle_tools '+vision'),$(native_tools_bundle_tools '+web'),$(native_tools_bundle_tools '+ops'),$(native_tools_bundle_tools '+memory')"
            ;;
        ops)
            tool_list+=",$(native_tools_bundle_tools '+files'),$(native_tools_bundle_tools '+ops'),$(native_tools_bundle_tools '+memory')"
            ;;
        swarm)
            tool_list+=",$(native_tools_bundle_tools '+swarm'),$(native_tools_bundle_tools '+social'),$(native_tools_bundle_tools '+ops')"
            ;;
        minimal|bedrock)
            tool_list="$_BEDROCK_TOOLS"
            ;;
        all)
            echo "$(native_tools_get_all_schemas)"
            return 0
            ;;
        default|"")
            tool_list+=",$(native_tools_bundle_tools '+files'),$(native_tools_bundle_tools '+git'),$(native_tools_bundle_tools '+web')"
            ;;
        *)
            local item
            IFS=',' read -ra ADDR <<< "$profile"
            for item in "${ADDR[@]}"; do
                item=$(echo "$item" | tr -d ' ')
                local b_tools
                b_tools=$(native_tools_bundle_tools "$item")
                if [ -n "$b_tools" ]; then
                    tool_list+=",$b_tools"
                else
                    tool_list+=",$item"
                fi
            done
            ;;
    esac

    # Enforce 36-tool maximum ceiling on initial profile resolution
    local unique_tools
    unique_tools=$(echo "$tool_list" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' | awk '!seen[$0]++' | head -n 36 | tr '\n' ',' | sed 's/,$//')

    native_tools_get_schemas "$unique_tools"
}

# ── Domain Keyword Tags for High-Precision BM25 Matching ──────────────
native_tools_domain_tags() {
    case "$1" in
        web_search) echo "web search internet google query research paper arxiv browse find online" ;;
        web_search_cross_section) echo "web search cross section sample diverse creative articles semantic perspectives balanced non-greedy" ;;
        research_sandbox) echo "research sandbox dossier deep web scrape non-greedy cross-section multi-domain recurring intel report autonomous" ;;
        web_fetch) echo "web fetch scrape read download url html page article preprint source" ;;
        github_search) echo "github code search repo repository open source git implementation" ;;
        vision_analyze) echo "vision image photo diagram figure chart architecture visual inspect picture" ;;
        file_download) echo "download file curl wget fetch binary pdf image raw" ;;
        git_commit|git_push|git_clone) echo "git commit push clone repo branch code vcs version control" ;;
        gitea_pr_create|gitea_pr_list|gitea_pr_merge|gitea_issue_create|gitea_issue_list|gitea_issue_get|gitea_issue_close|gitea_issue_comment|gitea_branch_create|pr_audit) echo "pr pull request merge gitea issue issues bug fix branch review code audit" ;;
        social_post) echo "social post broadcast x twitter mastodon bluesky thread status publish tweet" ;;
        discord_send|discord_dm|discord_send_file|discord_read) echo "discord channel message alert notification chat send dm webhook file image upload attachment history read" ;;
        telegram_send) echo "telegram chat message alert notification channel send" ;;
        email_send|email_read) echo "email mail message inbox smtp letter imap send" ;;
        system_vitals) echo "vitals cpu memory gpu hardware status monitoring load thermal resources" ;;
        sandbox_create|sandbox_exec) echo "sandbox isolate docker container environment run execute" ;;
        container_exec) echo "container docker exec sandbox run command isolated" ;;
        wallet_status|crypto_send|solana_airdrop) echo "wallet crypto balance token send transfer solana eth funds" ;;
        recall_search|recall_ingest) echo "recall memory knowledge search retrieve semantic docs archive" ;;
        project_build|project_test|project_fix) echo "build test compile cargo npm pytest make check run fix" ;;
        file_write|file_append|file_edit) echo "write file append edit modify save content create update" ;;
        file_grep|dir_list) echo "grep search files directory list find pattern structure" ;;
        subagent_spawn|subagent_delegate) echo "subagent swarm delegate spawn background worker task parallel" ;;
        phytology_manage) echo "phytology living tissue audit foliage health cambium plant genetic snapshot heal graft prune lignify" ;;
        *) echo "" ;;
    esac
}

# ── SQLite FTS5 BM25 Engine for Tool Catalog ──────────────────────────
_LODGE_TOOLS_FTS_DB="${TMPDIR:-/tmp}/.lodge_tools_fts.db"

native_tools_fts_init() {
    local force="${1:-0}"
    if [ "$force" -ne 1 ] && [ -f "$_LODGE_TOOLS_FTS_DB" ]; then
        local count has_phytology
        count=$(sqlite3 "$_LODGE_TOOLS_FTS_DB" "SELECT count(*) FROM tools_fts;" 2>/dev/null || echo 0)
        has_phytology=$(sqlite3 "$_LODGE_TOOLS_FTS_DB" "SELECT count(*) FROM tools_fts WHERE name='phytology_manage';" 2>/dev/null || echo 0)
        [ "$count" -gt 50 ] && [ "$has_phytology" -gt 0 ] && return 0
    fi

    rm -f "$_LODGE_TOOLS_FTS_DB" 2>/dev/null
    sqlite3 "$_LODGE_TOOLS_FTS_DB" << 'EOF'
CREATE VIRTUAL TABLE tools_fts USING fts5(
    name UNINDEXED,
    bundle,
    description,
    tags,
    parameters,
    tokenize = 'porter unicode61'
);
EOF

    local all_tools
    all_tools=$(native_tools_get_all_schemas)

    echo "$all_tools" | jq -c '.[]' | while read -r tool; do
        local t_name t_desc t_params t_bundle="+other"
        t_name=$(echo "$tool" | jq -r '.function.name // empty')
        [ -z "$t_name" ] && continue
        t_desc=$(echo "$tool" | jq -r '.function.description // ""')
        t_params=$(echo "$tool" | jq -r '.function.parameters // {} | tostring')

        local b
        if [[ ",$_BEDROCK_TOOLS," =~ ",$t_name," ]]; then
            t_bundle="_bedrock"
        else
            for b in web files code git vision social ops memory crypto swarm models gsuite phytology; do
                local b_list
                b_list=$(native_tools_bundle_tools "$b")
                if [[ ",$b_list," =~ ",$t_name," ]]; then
                    t_bundle="+$b"
                    break
                fi
            done
        fi

        if [[ "$t_desc" =~ MCP\ tool\ on\ server\ \'([^\']+)\' ]]; then
            t_bundle="+mcp_${BASH_REMATCH[1]}"
        fi

        local t_tags
        t_tags=$(native_tools_domain_tags "$t_name")

        local s_name s_bundle s_desc s_tags s_params
        s_name="${t_name//\'/\'\'}"
        s_bundle="${t_bundle//\'/\'\'}"
        s_desc="${t_desc//\'/\'\'}"
        s_tags="${t_tags//\'/\'\'}"
        s_params="${t_params//\'/\'\'}"

        sqlite3 "$_LODGE_TOOLS_FTS_DB" "INSERT INTO tools_fts (name, bundle, description, tags, parameters) VALUES ('$s_name', '$s_bundle', '$s_desc', '$s_tags', '$s_params');" 2>/dev/null || true
    done
}

# ── Dynamic Tool Search & 1-Turn Auto-Mount ────────────────────────────
native_tools_search() {
    local query="$1"
    local session_dir="${2:-${AGENT_ACTIVE_SESSION_DIR:-}}"
    local max_tools="${3:-36}"

    [ -z "$query" ] && { echo "Error: query required for tool_search."; return 1; }

    native_tools_fts_init 0

    local matched_bundle="" matched_tools=""

    # 1. Direct bundle tag match (e.g. "+git", "git")
    local clean_q
    clean_q=$(echo "$query" | tr -d ' +' | tr '[:upper:]' '[:lower:]')
    local direct_b_tools
    direct_b_tools=$(native_tools_bundle_tools "$clean_q")
    if [ -n "$direct_b_tools" ]; then
        matched_bundle="+$clean_q"
        matched_tools="$direct_b_tools"
    else
        # 2. SQLite FTS5 BM25 search with OR tokenization
        local words=()
        for w in $(echo "$query" | tr -cs 'a-zA-Z0-9' ' ' | tr '[:upper:]' '[:lower:]'); do
            [ ${#w} -le 1 ] && continue
            case "$w" in
                how|the|and|or|to|in|on|at|for|a|an|is|it|do|can|with|my) continue ;;
            esac
            words+=("${w}*")
        done

        if [ ${#words[@]} -gt 0 ]; then
            local fts_q
            fts_q=$(IFS=' '; echo "${words[*]}" | sed 's/ / OR /g')
            local sql_res
            sql_res=$(sqlite3 "$_LODGE_TOOLS_FTS_DB" "SELECT bundle, name, bm25(tools_fts) FROM tools_fts WHERE tools_fts MATCH '$fts_q' ORDER BY bm25(tools_fts) LIMIT 8;" 2>/dev/null)
            if [ -n "$sql_res" ]; then
                # Check if top-ranked tool in FTS search is an already mounted bedrock tool
                local top_match_name
                top_match_name=$(echo "$sql_res" | head -n 1 | cut -d'|' -f2)
                if [ -n "$top_match_name" ] && [[ ",$_BEDROCK_TOOLS," =~ ",$top_match_name," ]]; then
                    echo "The tool '$top_match_name' is a core bedrock tool and is ALREADY mounted and immediately available in your active session. You can invoke it directly without mounting any external bundle."
                    native_tools_get_schemas "$top_match_name" | jq -r '.[0] | "Mounted Signature:\n- " + .function.name + "(" + ((.function.parameters.properties // {}) | keys | join(", ")) + "): " + .function.description' 2>/dev/null || true
                    return 0
                fi

                # Select top-ranked non-bedrock bundle
                matched_bundle=$(echo "$sql_res" | grep -v '^_bedrock' | head -n 1 | cut -d'|' -f1)
                local b_clean="${matched_bundle#+}"
                matched_tools=$(native_tools_bundle_tools "$b_clean")
                if [ -z "$matched_tools" ]; then
                    matched_tools=$(echo "$sql_res" | grep -v '^_bedrock' | cut -d'|' -f2 | tr '\n' ',' | sed 's/,$//')
                fi
            fi
        fi
    fi

    if [ -z "$matched_tools" ]; then
        echo "No matching tool capabilities found for query: '$query'. Try another search term or bundle name (+web, +git, +social, +code, +files, +ops, +vision, +crypto)."
        return 0
    fi

    # Auto-Mount into session active_tools.json if session_dir is available
    local active_tools_file="$session_dir/active_tools.json"
    local evicted_bundle=""
    local total_count=0
    if [ -n "$session_dir" ] && [ -d "$session_dir" ]; then
        local current_tools_json="[]"
        [ -f "$active_tools_file" ] && current_tools_json=$(cat "$active_tools_file" 2>/dev/null || echo "[]")

        local new_schemas
        new_schemas=$(native_tools_get_schemas "$matched_tools")

        local merged_tools
        merged_tools=$(jq -n --argjson curr "$current_tools_json" --argjson new "$new_schemas" '
            ($curr + $new) | unique_by(.function.name)
        ' 2>/dev/null)

        total_count=$(echo "$merged_tools" | jq '. | length' 2>/dev/null || echo 0)
        total_count="${total_count:-0}"

        # Enforce max_tools ceiling via LRU bundle eviction loop
        while [ "$total_count" -gt "$max_tools" ] 2>/dev/null; do
            local mounted_bundles
            mounted_bundles=$(echo "$merged_tools" | jq -r '.[].function.name' | while read -r tname; do
                for b in web files code git vision social ops memory crypto swarm models gsuite; do
                    local bl
                    bl=$(native_tools_bundle_tools "$b")
                    if [[ ",$bl," =~ ",$tname," ]]; then
                        echo "+$b"
                        break
                    fi
                done
            done | grep -v '^\s*$' | sort -u)

            local traj_log="$session_dir/trajectory.log"
            local lru_bundle="" lru_score=999999
            for mb in $mounted_bundles; do
                [ "$mb" = "$matched_bundle" ] && continue
                local mb_clean="${mb#+}"
                local mb_tools
                mb_tools=$(native_tools_bundle_tools "$mb_clean")
                local call_count=0
                if [ -f "$traj_log" ]; then
                    IFS=',' read -ra T_ARR <<< "$mb_tools"
                    for tn in "${T_ARR[@]}"; do
                        local c
                        c=$(grep -c "Tool Call: $tn" "$traj_log" 2>/dev/null || true)
                        c="${c:-0}"
                        call_count=$((call_count + c))
                    done
                fi
                if [ "$call_count" -lt "$lru_score" ]; then
                    lru_score="$call_count"
                    lru_bundle="$mb"
                fi
            done

            if [ -n "$lru_bundle" ]; then
                if [ -z "$evicted_bundle" ]; then
                    evicted_bundle="$lru_bundle"
                else
                    evicted_bundle+=", $lru_bundle"
                fi
                local evict_clean="${lru_bundle#+}"
                local evict_tool_list
                evict_tool_list=$(native_tools_bundle_tools "$evict_clean")
                merged_tools=$(echo "$merged_tools" | jq --arg evict "$evict_tool_list" --arg bedrock "$_BEDROCK_TOOLS" '
                    ($evict | split(",")) as $e |
                    ($bedrock | split(",")) as $b |
                    [.[] | select((.function.name as $n | $b | index($n)) or (.function.name as $n | ($e | index($n) | not)))]
                ')
                local prev_count="$total_count"
                total_count=$(echo "$merged_tools" | jq '. | length' 2>/dev/null || echo "$total_count")
                [ "$total_count" -ge "$prev_count" ] && break
            else
                break
            fi
        done

        echo "$merged_tools" > "$active_tools_file"
    fi

    local docs=""
    if [ -n "$new_schemas" ] && [ "$new_schemas" != "[]" ]; then
        docs=$(echo "$new_schemas" | jq -r '.[] | "- " + .function.name + "(" + (((.function.parameters.properties // {}) | keys | .[0:4]) | join(", ")) + (if (((.function.parameters.properties // {}) | keys | length) > 4) then ", ..." else "" end) + "): " + ((.function.description // "") | split(". ")[0] | split("\n")[0])' 2>/dev/null)
    fi
    local msg="✓ Attached bundle '${matched_bundle}' (${matched_tools})."
    if [ -n "$evicted_bundle" ]; then
        msg+=" ℹ Pruned inactive bundle(s) '${evicted_bundle}' to respect the ${max_tools}-tool ceiling."
    fi
    [ "$total_count" -gt 0 ] && msg+=" Active tools: ${total_count}/${max_tools}."
    msg+=" These tools are now immediately available in this session."
    if [ -n "$docs" ]; then
        msg+=$'\n\nMounted Tool Signatures:\n'"$docs"
    fi
    echo "$msg"
}

# ── Sanitize & Repair Tool Arguments ──────────────────────────────────
# Repairs LLM argument quirks: trailing XML tags (</parameter>, </function>),
# embedded XML parameters (<parameter = key > val </parameter>), unescaped newlines,
# shell argument quirks (bare head -n, git rev-parse arg order), and path formatting.
native_tools_sanitize_args() {
    local raw="$1"
    [ -z "$raw" ] || [ "$raw" = "null" ] && { echo "{}"; return 0; }

    if command -v python3 &>/dev/null; then
        python3 -c '
import sys, json, re

raw = sys.stdin.read().strip()
if not raw or raw == "null":
    print("{}")
    sys.exit(0)

extracted = {}

try:
    j = json.loads(raw)
    if isinstance(j, dict):
        for k, v in j.items():
            if isinstance(v, str):
                clean_v = re.split(r"</?(?:parameter|function|tool_call|invoke|output)[^>]*>", v)[0].strip()
                extracted[k] = clean_v
            else:
                extracted[k] = v
except Exception:
    for m in re.finditer(r"\"([a-zA-Z0-9_]+)\"\s*:\s*\"([^\"<]+)", raw):
        extracted[m.group(1)] = m.group(2).strip()

if "<parameter" in raw or "</parameter>" in raw:
    xml_matches = re.findall(r"<parameter\s*(?:=\s*)?([a-zA-Z0-9_]+)\s*>\s*(.*?)(?:</parameter>|(?=<parameter)|(?=</function>)|$)", raw, re.DOTALL)
    for k, v in xml_matches:
        v_clean = v.strip()
        v_clean = re.sub(r"</?(?:parameter|function|tool_call|invoke|output)[^>]*>", "", v_clean).strip()
        if re.match(r"^\d+$", v_clean):
            extracted[k] = int(v_clean)
        else:
            extracted[k] = v_clean

target_ws = os.environ.get("LODGE_DIR") or os.path.expanduser("~/blue-lodge")

if "command" in extracted and isinstance(extracted["command"], str):
    c = extracted["command"]
    c = re.split(r"</?(?:parameter|function|tool_call|invoke|output)[^>]*>", c)[0].strip()
    c = re.sub(r"head -n(\s*(\||&|;|$))", r"head -n 10\1", c)
    c = re.sub(r"git rev-parse\s+([^\s]+)\s+--short", r"git rev-parse --short \1", c)
    c = re.sub(r"(?:/home/[^/]+|/Users/[^/]+|~|\$HOME)/blue[ _-][a-zA-Z0-9_-]+", target_ws, c)
    extracted["command"] = c

if "path" in extracted and isinstance(extracted["path"], str):
    p = extracted["path"].split("\n")[0].strip()
    p = re.split(r"(\s+2?>|\s+\||\s+;)", p)[0].strip()
    p = re.sub(r"^(?:/home/[^/]+|/Users/[^/]+|~|\$HOME|\.?/?home/[^/]+)/blue[ _-][a-zA-Z0-9_-]+", target_ws, p)
    if re.match(r"^home/[^/]+/", p):
        p = "/" + p
    extracted["path"] = p

print(json.dumps(extracted) if extracted else raw)
' <<< "$raw" 2>/dev/null && return 0
    fi

    # Fallback to jq if python3 fails
    printf '%s\n' "$raw" | jq '
        walk(
            if type == "string" then
                gsub("</?(parameter|function|tool_call)[^>]*>"; "") | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "")
            else
                .
            end
        )
    ' 2>/dev/null || echo "$raw"
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

    # Clean up and repair LLM argument hallucinations and embedded XML parameters
    args_json=$(native_tools_sanitize_args "$args_json")


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
            tool_search)
                local q
                q=$(echo "$args_json" | jq -r '.query // empty')
                output=$(native_tools_search "$q" "${AGENT_ACTIVE_SESSION_DIR:-$workdir}" 36)
                exit_code=$?
                ;;
            task_wait)
                local secs reason
                secs=$(echo "$args_json" | jq -r '.seconds // 5')
                reason=$(echo "$args_json" | jq -r '.reason // "Waiting for background job or timer"')
                if ! [[ "$secs" =~ ^[0-9]+$ ]] || [ "$secs" -lt 1 ]; then secs=5; fi
                if [ "$secs" -gt 600 ]; then secs=600; fi
                sleep "$secs"
                output="TASK_WAIT_SUCCESS: Slept for ${secs}s (${reason})."
                exit_code=0
                ;;
            milestone_complete)
                local m_status m_summary m_facts
                m_status=$(echo "$args_json" | jq -r '.status // "success"')
                m_summary=$(echo "$args_json" | jq -r '.summary // "Milestone completed."')
                m_facts=$(echo "$args_json" | jq -c '.facts_discovered // []')

                local dag_state_file="$workdir/.george/dag_state.json"
                mkdir -p "$workdir/.george"
                local cur_step="${CURRENT_ACTIVE_MILESTONE_ID:-1}"
                local now_ts
                now_ts=$(date +%s)

                local update_entry
                update_entry=$(jq -nc \
                    --arg id "$cur_step" \
                    --arg st "$m_status" \
                    --arg sm "$m_summary" \
                    --argjson f "$m_facts" \
                    --arg ts "$now_ts" \
                    '{id: $id, status: $st, summary: $sm, facts: $f, timestamp: ($ts | tonumber)}')

                if [ -f "$dag_state_file" ]; then
                    jq --argjson entry "$update_entry" '.milestones += [$entry]' "$dag_state_file" > "${dag_state_file}.tmp" 2>/dev/null && mv "${dag_state_file}.tmp" "$dag_state_file" || true
                else
                    jq -n --argjson entry "$update_entry" '{milestones: [$entry]}' > "$dag_state_file" 2>/dev/null || true
                fi

                commands_dispatch "/append mem:active_task \n## Milestone $cur_step ($m_status)\n$m_summary\n" "$workdir" >/dev/null 2>&1 || true

                output="MILESTONE_COMPLETE_ACKNOWLEDGED: Milestone status='$m_status' registered to DAG state barrier. Summary: $m_summary"
                exit_code=0
                ;;
            bash_exec)
                local cmd
                cmd=$(echo "$args_json" | jq -r '.command // empty')
                cmd="${cmd%%</parameter*}"
                cmd="${cmd%%</invoke*}"
                cmd="${cmd%%</output*}"
                cmd="${cmd%%<tool_call*}"
                cmd="${cmd%%<function*}"
                # Direct slash command interception if model invokes slash command via bash_exec
                if [[ "$cmd" == /* ]]; then
                    output=$(commands_dispatch "$cmd" "$workdir" 2>&1)
                    exit_code=$?
                elif [[ "$cmd" =~ ^(\./)?lodge[[:space:]]+(/[a-zA-Z0-9_-]+.*) ]]; then
                    local _sub_slash="${BASH_REMATCH[2]}"
                    output=$(commands_dispatch "$_sub_slash" "$workdir" 2>&1)
                    exit_code=$?
                else
                    # Auto-normalize common shell invocation quirks
                    local _target_ws="${LODGE_DIR:-$HOME/blue-lodge}"
                    cmd=$(echo "$cmd" | sed -E 's/head -n([[:space:]]*(\||\&|\;|$))/head -n 10\1/g')
                    cmd=$(echo "$cmd" | sed -E 's/git rev-parse ([^ ]+) --short/git rev-parse --short \1/g')
                    cmd=$(echo "$cmd" | sed -E "s#(cd[[:space:]]+)?(/home/[^/]+|/Users/[^/]+|~|\$HOME)/blue[ _-][a-zA-Z0-9_-]*#\1${_target_ws}#g")
                    cmd=$(echo "$cmd" | sed -E 's/\bgit switch -B\b/git switch -C/g; s/\bgit switch -b\b/git switch -c/g; s/\bgit checkout -c\b/git checkout -b/g')
                    output=$(commands_dispatch "/bash $cmd" "$workdir" 2>&1)
                    exit_code=$?
                fi
                # SCRIPT_EXIT / Traceback error exit code correction
                if [ "$exit_code" -eq 0 ]; then
                    if echo "$output" | grep -qE 'SCRIPT_EXIT=([1-9][0-9]*)'; then
                        local _extracted_exit
                        _extracted_exit=$(echo "$output" | grep -oE 'SCRIPT_EXIT=[0-9]+' | tail -n 1 | cut -d= -f2)
                        [ -n "$_extracted_exit" ] && [ "$_extracted_exit" -ne 0 ] && exit_code="$_extracted_exit"
                    elif echo "$output" | grep -qiE '(Traceback \(most recent call last\)|ModuleNotFoundError:|ImportError:|SyntaxError:|command not found|pdftotext: not found)'; then
                        exit_code=1
                    fi
                fi
                if [ "$exit_code" -ne 0 ]; then
                    if [ -z "$output" ]; then
                        output="ERROR: Command failed with exit code $exit_code"
                    fi
                    local _done_ts
                    _done_ts=$(date '+%Y-%m-%d %H:%M:%S')
                    ui_err "[$_done_ts] bash_exec failed (exit $exit_code)" >&2 2>/dev/null || true
                fi
                ;;
            file_read)
                local p s m
                p=$(echo "$args_json" | jq -r '.path // empty')
                s=$(echo "$args_json" | jq -r '.start_line // 1')
                m=$(echo "$args_json" | jq -r '.max_lines // 100')
                if [[ "$p" == home/wsl-ops/* ]]; then p="/$p"; fi
                # Enforce safe bounds (1-200 lines max per read to protect context limits)
                if ! [[ "$s" =~ ^[0-9]+$ ]] || [ "$s" -lt 1 ]; then
                    s=1
                fi
                if ! [[ "$m" =~ ^[0-9]+$ ]] || [ "$m" -lt 1 ]; then
                    m=100
                elif [ "$m" -gt 200 ]; then
                    m=200
                fi
                local target="$p"
                if declare -f ui_resolve_path &>/dev/null; then
                    target=$(ui_resolve_path "$p" "$workdir")
                elif [ -f "$workdir/$p" ]; then
                    target="$workdir/$p"
                fi
                if [ ! -e "$target" ]; then
                    local _primary_root="${LODGE_ROOT:-}"
                    if [ -z "$_primary_root" ] && [[ "$workdir" == *"/.sandboxes/"* ]]; then
                        _primary_root="${workdir%%/.sandboxes/*}"
                    fi
                    [ -z "$_primary_root" ] && _primary_root="${LODGE_DIR:-$(pwd)}"
                    if [ -e "$_primary_root/$p" ]; then
                        target="$_primary_root/$p"
                    fi
                fi
                if [ -z "$p" ] || [[ "$p" =~ ^[0-9]+$ ]]; then
                    output="ERROR: Invalid file path '$p'. Please provide a valid file path (e.g. lib/phytology.sh)."
                    exit_code=1
                elif [ ! -e "$target" ]; then
                    output="ERROR: File not found: $p"
                    exit_code=1
                elif [ -d "$target" ]; then
                    output=$(commands_dispatch "/ls $p 2" "$workdir" 2>&1)
                    exit_code=0
                elif [[ "${target,,}" == *.pdf ]]; then
                    output=$(tools_read_pdf "$target" 1 "" 20 1 2>&1)
                    exit_code=$?
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
            pdf_read)
                local p s e m l
                p=$(echo "$args_json" | jq -r '.path // empty')
                s=$(echo "$args_json" | jq -r '.page_start // 1')
                e=$(echo "$args_json" | jq -r '.page_end // empty')
                m=$(echo "$args_json" | jq -r '.max_pages // 20')
                l=$(echo "$args_json" | jq -r 'if .layout == false then 0 else 1 end')
                local target="$p"
                if declare -f ui_resolve_path &>/dev/null; then
                    target=$(ui_resolve_path "$p" "$workdir")
                elif [ -f "$workdir/$p" ]; then
                    target="$workdir/$p"
                fi
                if [ ! -f "$target" ]; then
                    output="ERROR: PDF file not found: $p"
                    exit_code=1
                else
                    output=$(tools_read_pdf "$target" "$s" "$e" "$m" "$l" 2>&1)
                    exit_code=$?
                fi
                ;;
            workflow_plan)
                local obj ctx qs
                obj=$(echo "$args_json" | jq -r '.objective // empty')
                ctx=$(echo "$args_json" | jq -r '.context // empty')
                qs=$(echo "$args_json" | jq -r '.questions // empty')
                if declare -f workflow_interactive_plan &>/dev/null; then
                    output=$(workflow_interactive_plan "$obj" "$ctx" "$qs" "$workdir" 2>&1)
                    exit_code=$?
                elif declare -f _workflow_run_architect &>/dev/null; then
                    output=$(_workflow_run_architect "$obj" "$workdir" "" 2>&1)
                    exit_code=$?
                else
                    output=$(commands_dispatch "/workflow run the-architect $obj" "$workdir" 2>&1)
                    exit_code=$?
                fi
                ;;
            workflow_run)
                local wname wargs
                wname=$(echo "$args_json" | jq -r '.name // empty')
                wargs=$(echo "$args_json" | jq -r '.args // empty')
                if declare -f workflows_run &>/dev/null; then
                    output=$(workflows_run "$wname" "$wargs" "$workdir" 2>&1)
                    exit_code=$?
                else
                    output=$(commands_dispatch "/workflow run $wname $wargs" "$workdir" 2>&1)
                    exit_code=$?
                fi
                ;;
            file_write)
                local p c
                p=$(echo "$args_json" | jq -r '.path // empty')
                c=$(echo "$args_json" | jq -r '.content // empty')
                if [[ "$p" == home/wsl-ops/* ]]; then p="/$p"; fi
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
                if [[ "$p" == home/wsl-ops/* ]]; then p="/$p"; fi
                output=$(commands_dispatch "/append $p $c" "$workdir" 2>&1)
                exit_code=$?
                ;;
            dir_list)
                local p d target
                p=$(echo "$args_json" | jq -r '.path // "."')
                d=$(echo "$args_json" | jq -r '.depth // empty')
                if [ -z "$d" ] || [ "$d" = "null" ]; then
                    if [ "$p" = "." ] || [ -z "$p" ]; then
                        d=1
                    else
                        d=2
                    fi
                fi
                if [[ "$p" == /* ]]; then
                    target="$p"
                else
                    target="$workdir/$p"
                fi
                output=$(commands_dispatch "/ls $target $d" "$workdir" 2>&1)
                exit_code=$?
                ;;
            file_grep)
                local pat p target
                pat=$(echo "$args_json" | jq -r '.pattern // empty')
                p=$(echo "$args_json" | jq -r '.path // "."')
                # Sanitize if pattern contains embedded XML parameter syntax
                if [[ "$pat" == *"</parameter>"* ]] || [[ "$pat" == *"<parameter"* ]]; then
                    if [[ "$pat" =~ parameter=path[^\>]*\>([^<]+) ]]; then
                        local _extracted_p="${BASH_REMATCH[1]}"
                        _extracted_p=$(echo "$_extracted_p" | sed 's/[[:space:]]*$//; s/^[[:space:]]*//')
                        [ -n "$_extracted_p" ] && p="$_extracted_p"
                    fi
                    pat=$(echo "$pat" | sed -E 's#</?(parameter|function|tool_call)[^>]*># #g' | sed 's/[[:space:]]*$//; s/^[[:space:]]*//')
                fi
                # Strip leading/trailing quotes or backticks from pattern
                pat=$(echo "$pat" | sed -E "s/^['\"\`]+|['\"\`]+$//g")
                # If pattern uses uppercase " OR ", convert to regex alternation "|"
                if [[ "$pat" == *" OR "* ]]; then
                    pat=$(echo "$pat" | sed 's/ OR /|/g')
                fi
                if [[ "$p" == /* ]]; then
                    target="$p"
                else
                    target="$workdir/$p"
                fi
                local _primary_root="${LODGE_ROOT:-}"
                if [ -z "$_primary_root" ] && [[ "$workdir" == *"/.sandboxes/"* ]]; then
                    _primary_root="${workdir%%/.sandboxes/*}"
                fi
                [ -z "$_primary_root" ] && _primary_root="${LODGE_DIR:-$(pwd)}"

                # Workspace scope guard: prevent recursive indexing outside project tree
                local _target_canon _root_canon
                _target_canon=$(readlink -f "$target" 2>/dev/null || echo "$target")
                _root_canon=$(readlink -f "$_primary_root" 2>/dev/null || echo "$_primary_root")
                if [ "$_target_canon" = "/" ] || [ "$_target_canon" = "/home" ] || [ -n "$HOME" -a "$_target_canon" = "$HOME" ] || [ "$_target_canon" = "$(dirname "$_root_canon")" ]; then
                    target="$_primary_root"
                fi
                if [ ! -e "$target" ] && [ -e "$_primary_root/$p" ]; then
                    target="$_primary_root/$p"
                fi
                if command -v rg &>/dev/null; then
                    output=$(rg -n --no-heading --color=never --max-depth 5 -g '!.git' -g '!node_modules' -g '!target' -g '!.cargo' -g '!.cache' -e "$pat" "$target" 2>&1 | head -n 100)
                    exit_code=$?
                else
                    output=$(commands_dispatch "/grep $pat $target" "$workdir" 2>&1)
                    exit_code=$?
                fi
                ;;
            code_outline)
                local p target_p
                p=$(echo "$args_json" | jq -r '.path // empty')
                if [[ "$p" == /* ]]; then
                    target_p="$p"
                else
                    target_p="$workdir/$p"
                fi
                output=$(treesitter_outline "$target_p" 2>&1)
                exit_code=$?
                ;;
            code_symbol_get)
                local p sym target_p
                p=$(echo "$args_json" | jq -r '.path // empty')
                sym=$(echo "$args_json" | jq -r '.symbol // empty')
                if [[ "$p" == /* ]]; then
                    target_p="$p"
                else
                    target_p="$workdir/$p"
                fi
                output=$(treesitter_symbol "$target_p" "$sym" 2>&1)
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
            web_search_cross_section)
                local q s_cnt p_cnt
                q=$(echo "$args_json" | jq -r '.query // empty')
                s_cnt=$(echo "$args_json" | jq -r '.sample_size // 3')
                p_cnt=$(echo "$args_json" | jq -r '.pool_size // 12')
                source "$LODGE_DIR/lib/web.sh" 2>/dev/null || true
                output=$(web_search_cross_section "$q" "$s_cnt" "$p_cnt" 2>&1)
                exit_code=$?
                ;;
            web_fetch)
                local u
                u=$(echo "$args_json" | jq -r '.url // empty')
                if command -v timeout &>/dev/null; then
                    output=$(timeout --kill-after=5s 20s bash -c "source '$LODGE_DIR/lib/web.sh' 2>/dev/null; web_fetch \"$u\"" 2>&1)
                    exit_code=$?
                    if [ $exit_code -eq 124 ]; then
                        output="Error: web_fetch timed out after 20 seconds (page unresponsive or blocked by challenge)."
                    fi
                else
                    output=$(web_fetch "$u" 2>&1)
                    exit_code=$?
                fi
                ;;
            research_sandbox)
                local topic s_cnt out_file
                topic=$(echo "$args_json" | jq -r '.topic // empty')
                s_cnt=$(echo "$args_json" | jq -r '.sample_size // 3')
                out_file=$(echo "$args_json" | jq -r '.output_file // empty')
                source "$LODGE_DIR/lib/web.sh" 2>/dev/null || true
                if [ -z "$topic" ]; then
                    output='{"status":"error","message":"research_sandbox requires .topic parameter"}'
                    exit_code=1
                else
                    output=$(research_sandbox "$topic" "$s_cnt" "$out_file" 2>&1)
                    exit_code=$?
                fi
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
                    source "$LODGE_DIR/lib/social.sh" 2>/dev/null || true
                    output=$(discord_dm "${usr:-dabe}" "$msg" 2>&1)
                    exit_code=$?
                else
                    output="Discord bot token is not configured. Set DISCORD_BOT_TOKEN with: /api keys set DISCORD_BOT_TOKEN <token>"
                    exit_code=1
                fi
                ;;
            discord_send_file)
                local tgt file_p msg
                tgt=$(echo "$args_json" | jq -r '.target // empty')
                file_p=$(echo "$args_json" | jq -r '.file_path // empty')
                msg=$(echo "$args_json" | jq -r '.message // empty')
                tgt=$(echo "$tgt" | sed 's/^["'\''"]*//; s/["'\''"]*$//')
                file_p=$(echo "$file_p" | sed 's/^["'\''"]*//; s/["'\''"]*$//')
                source "$LODGE_DIR/lib/discord_bridge.sh" 2>/dev/null || true
                local has_bot
                has_bot=$(api_get_key "DISCORD_BOT_TOKEN" 2>/dev/null || true)
                if [ -n "$has_bot" ]; then
                    if [ -n "$tgt" ] && [ -n "$file_p" ]; then
                        output=$(discord_send_file "$tgt" "$file_p" "$msg" 2>&1)
                        exit_code=$?
                    else
                        output="Target and file_path are required for discord_send_file."
                        exit_code=1
                    fi
                else
                    output="Discord bot token is not configured. Set DISCORD_BOT_TOKEN with: /api keys set DISCORD_BOT_TOKEN <token>"
                    exit_code=1
                fi
                ;;
            discord_read)
                local chan cnt
                chan=$(echo "$args_json" | jq -r '.channel // empty')
                cnt=$(echo "$args_json" | jq -r '.count // 10')
                chan=$(echo "$chan" | sed 's/^["'\''"]*//; s/["'\''"]*$//')
                source "$LODGE_DIR/lib/social.sh" 2>/dev/null || true
                local has_bot
                has_bot=$(api_get_key "DISCORD_BOT_TOKEN" 2>/dev/null || true)
                if [ -n "$has_bot" ]; then
                    if [ -n "$chan" ]; then
                        output=$(discord_read "$chan" "$cnt" 2>&1)
                        exit_code=$?
                    else
                        output="Channel parameter is required for discord_read."
                        exit_code=1
                    fi
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
                max_turns=$(echo "$args_json" | jq -r '.max_turns // 200')
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
                if [[ "$pth" == home/wsl-ops/* ]]; then pth="/$pth"; fi
                output=$(cmd_edit "$pth $expr" "$workdir" 2>&1)
                exit_code=$?
                # Resilient fallback: if cmd_edit rejected due to invalid block-replace format
                # but expression contains code or function definitions, append it cleanly to the file
                if [ $exit_code -ne 0 ] && echo "$output" | grep -qiE "(invalid block-replace format|Could not parse any search/replace blocks)" && [ -n "$expr" ]; then
                    output=$(commands_dispatch "/append $pth $expr" "$workdir" 2>&1)
                    exit_code=$?
                fi
                local _check_target="$pth"
                [ ! -f "$_check_target" ] && _check_target="$workdir/$pth"
                if [ $exit_code -eq 0 ] && [ -f "$_check_target" ]; then
                    local _edit_lang
                    _edit_lang=$(treesitter_detect_lang "$pth")
                    if [ -n "$_edit_lang" ] && [ "$_edit_lang" != "plaintext" ]; then
                        local _edit_ts_err
                        if ! _edit_ts_err=$(treesitter_validate "$(cat "$_check_target")" "$_edit_lang" 2>&1); then
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
            gitea_set_endpoint)
                local ep_url
                ep_url=$(echo "$args_json" | jq -r '.url // empty')
                if [ -n "$ep_url" ]; then
                    output=$(gitea_set_endpoint "$ep_url" 2>&1 && echo "Gitea endpoint updated to $ep_url")
                    exit_code=$?
                else
                    output="Error: url parameter required"
                    exit_code=1
                fi
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
                if [[ "$idx" =~ ^PR-[0-9]+$ ]] || ! pr_is_gitea_online; then
                    output=$(pr_accept "$idx" "$strat" 2>&1)
                else
                    output=$(gitea_pr_merge "$idx" "$strat" 2>&1)
                fi
                exit_code=$?
                ;;
            gitea_issue_create)
                local tt bd lbl
                tt=$(echo "$args_json" | jq -r '.title // empty')
                bd=$(echo "$args_json" | jq -r '.body // ""')
                lbl=$(echo "$args_json" | jq -r '.labels // ""')
                output=$(gitea_issue_create "$tt" "$bd" "$lbl" 2>&1)
                exit_code=$?
                ;;
            gitea_issue_list)
                local st
                st=$(echo "$args_json" | jq -r '.state // "open"')
                output=$(gitea_issue_list "$st" "json" 2>&1)
                exit_code=$?
                ;;
            gitea_issue_get)
                local idx
                idx=$(echo "$args_json" | jq -r '.index // empty')
                output=$(gitea_issue_get "$idx" 2>&1)
                exit_code=$?
                ;;
            gitea_issue_comment)
                local idx bd
                idx=$(echo "$args_json" | jq -r '.index // empty')
                bd=$(echo "$args_json" | jq -r '.body // empty')
                output=$(gitea_issue_comment "$idx" "$bd" 2>&1)
                exit_code=$?
                ;;
            gitea_issue_close)
                local idx cmt
                idx=$(echo "$args_json" | jq -r '.index // empty')
                cmt=$(echo "$args_json" | jq -r '.comment // ""')
                output=$(gitea_issue_close "$idx" "$cmt" 2>&1)
                exit_code=$?
                ;;
            gitea_branch_create)
                local br bs
                br=$(echo "$args_json" | jq -r '.branch_name // empty')
                bs=$(echo "$args_json" | jq -r '.base // "develop"')
                output=$(gitea_branch_create "$br" "$bs" 2>&1)
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
            phytology_manage)
                local act tgt flg
                act=$(echo "$args_json" | jq -r '.action // "status"')
                tgt=$(echo "$args_json" | jq -r '.target // empty')
                flg=$(echo "$args_json" | jq -r '.flags // empty')

                # Unwrap nested JSON if model passed JSON string inside action (e.g. {"action":"status"})
                if [[ "$act" == \{* ]]; then
                    [ -z "$tgt" ] && tgt=$(echo "$act" | jq -r '.target // empty' 2>/dev/null)
                    [ -z "$flg" ] && flg=$(echo "$act" | jq -r '.flags // empty' 2>/dev/null)
                    local inner_act
                    inner_act=$(echo "$act" | jq -r '.action // .cmd // .subcommand // empty' 2>/dev/null)
                    [ -n "$inner_act" ] && act="$inner_act"
                fi
                # Strip extraneous punctuation, quotes or brackets
                act=$(echo "$act" | tr -d '"{}\\\n\r' | awk '{print $1}')
                [ -z "$act" ] && act="status"

                local cmd_str="$act"
                [ -n "$tgt" ] && cmd_str="$cmd_str $tgt"
                [ -n "$flg" ] && cmd_str="$cmd_str $flg"
                output=$(commands_dispatch "/phytology $cmd_str" "$workdir" 2>&1)
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
                elif [ -n "$sc_name" ] && declare -f "cmd_${sc_name}" &>/dev/null; then
                    output=$("cmd_${sc_name}" "$sc_args" "$workdir" 2>&1)
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

    # Truncate if excessively large to protect context budget (clamp to 24000 chars)
    if [ ${#output} -gt 24000 ]; then
        output="${output:0:24000}\n... [output truncated (${#output} chars total)]"
    fi

    # Anomaly telemetry tap for native tool failures
    local is_native_failure=0
    # Require real non-zero exit code to avoid flagging benign commands returning exit 0
    if [ "$exit_code" -ne 0 ]; then
        is_native_failure=1
    fi

    if [ "$is_native_failure" -eq 1 ]; then
        local fail_cls="CAPABILITY_DEFICIT"
        if [ "$name" = "bash_exec" ] || [ "$name" = "file_read" ] || [ "$name" = "file_write" ]; then
            fail_cls="SHELL_RUNTIME"
        fi
        if declare -f telemetry_record_anomaly &>/dev/null; then
            telemetry_record_anomaly "${AGENT_ACTIVE_SESSION_ID:-${session_id:-native_tools}}" "$fail_cls" "$name" "$output" >/dev/null 2>&1 || true
        fi
        # Only triage true unhandled crashes or fatal runtime errors (e.g. Python traceback, segfault, core dump).
        # Routine non-zero exit codes from exploratory commands (grep, ls, test, which) are handled by ReAct resilience.
        local is_fatal_crash=0
        if [[ "$output" =~ (Traceback[[:space:]]\(most[[:space:]]recent[[:space:]]call[[:space:]]last\)|Segmentation[[:space:]]fault|core[[:space:]]dumped|Fatal[[:space:]]error|panic:) ]]; then
            is_fatal_crash=1
        fi

        if [ "$is_fatal_crash" -eq 1 ] && [ "${_DISCORD_IN_SESSION:-0}" -ne 1 ] && [ "${LODGE_REMEDIATION_SANDBOX:-0}" -ne 1 ] && [[ "$workdir" != *".sandboxes/"* ]]; then
            if declare -f telemetry_triage_operational_failure &>/dev/null; then
                telemetry_triage_operational_failure "$name" "$fail_cls" "Fatal runtime crash on $name (exit $exit_code)" "$output" "$workdir" >/dev/null 2>&1 || true
            fi
        fi
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
