#!/usr/bin/env python3
"""
Generates the Google Open Knowledge Graph (OKF) JSON-LD for the Blue Lodge repository.
Maps all subsystems, source code files, exports, dependencies, and architectural standards.
Supports dynamic AST and regex filesystem discovery across lib/, commands/, web/, and scripts/.
"""

import os
import re
import ast
import json
import glob
import yaml

LODGE_DIR = os.environ.get("LODGE_DIR", os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))


def extract_bash_metadata(filepath, rel_path):
    """Extract description, exports, and source dependencies from a bash file using AST-like structural analysis."""
    desc = ""
    exports = []
    deps = []

    try:
        with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
            lines = f.readlines()
    except Exception:
        return desc, exports, deps

    # 1. Description extraction
    for line in lines[:35]:
        line_s = line.strip()
        if re.match(r"^#\s*(?:DESC|desc):\s*(.+)$", line_s):
            desc = re.sub(r"^#\s*(?:DESC|desc):\s*", "", line_s).strip()
            break
        elif line_s.startswith("# ── ") and not desc:
            desc = line_s.replace("# ── ", "").strip().rstrip("─").strip()
        elif line_s.startswith("#") and not line_s.startswith("#!") and not desc:
            cleaned = line_s.lstrip("#").strip()
            if not cleaned.startswith("════") and not cleaned.startswith("──") and len(cleaned) > 12:
                desc = cleaned

    if not desc:
        base = os.path.basename(rel_path)
        if rel_path.startswith("commands/"):
            cmd_name = base.replace(".sh", "")
            desc = f"Slash command handler for /{cmd_name}."
        elif rel_path.startswith("scripts/"):
            desc = f"Operational utility script for {base}."
        else:
            desc = f"Subsystem source module for {base}."

    # 2. Structural function definition parsing (both multi-line and single-line alias definitions)
    fn_pattern = re.compile(r"^\s*(?:function\s+)?([a-zA-Z0-9_]+)\s*(?:\(\s*\)\s*\{|\{\s*|\(\s*\))")
    # 3. Source extraction: source ".../path.sh" or . ".../path.sh"
    source_pattern = re.compile(r'^\s*(?:source|\.)\s+["\']?([^"\'\s]+)["\']?')

    for line in lines:
        m_fn = fn_pattern.match(line)
        if m_fn:
            fn_name = m_fn.group(1)
            # Include all standard functions and public SDK exports (exclude pure internal helpers unless public)
            if fn_name not in ["main", "usage", "help", "BEGIN", "END"]:
                if not fn_name.startswith("_") or fn_name.startswith("_ipc_") or fn_name.startswith("_okf_"):
                    if not fn_name.startswith("_") and fn_name not in exports:
                        exports.append(fn_name)

        m_src = source_pattern.match(line)
        if m_src:
            dep_path = m_src.group(1)
            clean_dep = os.path.basename(dep_path)
            if clean_dep.endswith(".sh") and clean_dep not in deps:
                deps.append(clean_dep)

    return desc, exports, deps


def extract_rust_metadata(filepath, rel_path):
    """Extract doc comment description and pub fn exports from Rust source code."""
    desc = ""
    exports = []
    deps = []

    try:
        with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
            lines = f.readlines()
    except Exception:
        return desc, exports, deps

    for line in lines[:25]:
        line_s = line.strip()
        if line_s.startswith("///") or line_s.startswith("//!"):
            desc = line_s.lstrip("/! ").strip()
            break

    if not desc:
        base = os.path.basename(rel_path)
        desc = f"Rust native server module for {base}."

    fn_pattern = re.compile(r"^\s*pub\s+(?:async\s+)?fn\s+([a-zA-Z0-9_]+)")
    for line in lines:
        m = fn_pattern.match(line)
        if m:
            fn_name = m.group(1)
            if fn_name not in exports:
                exports.append(fn_name)

    return desc, exports, deps


def extract_js_metadata(filepath, rel_path):
    """Extract metadata for web javascript files."""
    desc = "Sovereign Web Workbench frontend client application logic, state hydration, and telemetry UI."
    exports = ["hydrateSession", "renderAutonomicTaskBay", "pollHeartbeat", "isTaskActive"]
    return desc, exports, []


def extract_python_metadata(filepath, rel_path):
    """Extract docstrings, classes, functions, and import dependencies via Python AST."""
    desc = ""
    exports = []
    deps = []

    try:
        with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()
    except Exception:
        return desc, exports, deps

    try:
        tree = ast.parse(content, filename=filepath)

        # 1. Module-level docstring extraction
        doc = ast.get_docstring(tree)
        if doc:
            first_line = doc.strip().split("\n")[0].strip()
            if first_line:
                desc = first_line

        # 2. Extract top-level classes, functions, and async functions via AST visitor
        for node in tree.body:
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                if not node.name.startswith("_") and node.name not in ["main"]:
                    if node.name not in exports:
                        exports.append(node.name)
            elif isinstance(node, ast.Import):
                for alias in node.names:
                    mod = alias.name.split(".")[0]
                    if mod not in deps:
                        deps.append(mod)
            elif isinstance(node, ast.ImportFrom):
                if node.module:
                    mod = node.module.split(".")[0]
                    if mod not in deps:
                        deps.append(mod)
    except Exception:
        # Graceful fallback to regex for non-standard or partially templated Python
        for line in content.splitlines():
            m = re.match(r"^\s*(?:def|class)\s+([a-zA-Z0-9_]+)", line)
            if m:
                fn_name = m.group(1)
                if not fn_name.startswith("_") and fn_name not in ["main"] and fn_name not in exports:
                    exports.append(fn_name)

    if not desc:
        base = os.path.basename(rel_path)
        desc = f"Python utility module for {base}."

    return desc, exports, deps



def extract_doc_metadata(filepath, rel_path):
    """Extract YAML frontmatter, title, description, tags, okf_id, and wikilinks from a markdown doc."""
    title = ""
    desc = ""
    tags = []
    subsystem = "docs"
    okf_id = ""
    related = []
    wikilinks = []

    try:
        with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()
    except Exception:
        content = ""

    if content.startswith("---"):
        parts = content.split("---", 2)
        if len(parts) >= 3:
            fm_text = parts[1]
            try:
                fm = yaml.safe_load(fm_text)
                if isinstance(fm, dict):
                    title = fm.get("title", "")
                    desc = fm.get("description", "")
                    tags = fm.get("tags", [])
                    if isinstance(tags, str):
                        tags = [tags]
                    subsystem = fm.get("subsystem", "docs")
                    okf_id = fm.get("okf_id", "")
                    related = fm.get("related", [])
                    if isinstance(related, str):
                        related = [related]
            except Exception:
                pass

    base_no_ext = os.path.basename(rel_path).replace(".md", "")
    if not title:
        m_title = re.search(r"^#\s+(.+)$", content, re.MULTILINE)
        if m_title:
            title = m_title.group(1).strip()
        else:
            title = base_no_ext.replace("_", " ").title()

    if not desc:
        m_desc = re.search(r"^>\s+(.+)$", content, re.MULTILINE)
        if m_desc:
            desc = m_desc.group(1).strip()
        else:
            desc = f"Documentation for {title}."

    if not okf_id:
        slug = re.sub(r"[^a-zA-Z0-9]+", "-", base_no_ext).strip("-").lower()
        okf_id = f"urn:blue-lodge:doc:{slug}"

    # Extract all wikilinks [[Target]]
    for m in re.finditer(r"\[\[(.*?)\]\]", content):
        raw = m.group(1).strip()
        parts = re.split(r"\\?\|", raw)
        target = parts[0].strip().split("#")[0].strip()
        if target and not any(target.startswith(c) for c in ["-", "$", "!", "\"", "\'", "*"]) and target not in [":space:", "...", "DocName"]:
            target_slug = re.sub(r"[^a-zA-Z0-9]+", "-", os.path.basename(target).replace(".md", "")).strip("-").lower()
            target_uri = f"urn:blue-lodge:doc:{target_slug}"
            if target_uri not in wikilinks and target_uri != okf_id:
                wikilinks.append(target_uri)

    for r in related:
        clean_r = str(r).strip("[]").strip()
        parts = re.split(r"\\?\|", clean_r)
        target = parts[0].strip().split("#")[0].strip()
        if target:
            target_slug = re.sub(r"[^a-zA-Z0-9]+", "-", os.path.basename(target).replace(".md", "")).strip("-").lower()
            target_uri = f"urn:blue-lodge:doc:{target_slug}"
            if target_uri not in wikilinks and target_uri != okf_id:
                wikilinks.append(target_uri)

    subsystem_uri = f"urn:blue-lodge:subsystem:{subsystem}" if subsystem else "urn:blue-lodge:subsystem:docs"

    return {
        "@id": okf_id,
        "@type": ["TechArticle", "DigitalDocument"],
        "name": title,
        "headline": title,
        "description": desc,
        "path": rel_path,
        "encodingFormat": "text/markdown",
        "keywords": tags,
        "isPartOf": subsystem_uri,
        "related": wikilinks,
        "about": "urn:blue-lodge:core"
    }

def build_okf_graph():
    graph_nodes = []

    # 1. Root Application Node
    graph_nodes.append({
        "@id": "urn:blue-lodge:core",
        "@type": ["SoftwareApplication", "CodeRepository"],
        "name": "Blue Lodge Sovereign Agentic Architecture",
        "description": "Sovereign AI agentic coding workspace and craftsman companion featuring pure POSIX ReAct loops, Google Open Knowledge Graph representation, FIFO Async IPC flowcontrol, dual-model PRISM inference fabric, and autonomous phytology remediation.",
        "programmingLanguage": "Bash, Python, Rust, JavaScript",
        "stability": "stable",
        "hasPart": [
            "urn:blue-lodge:subsystem:core",
            "urn:blue-lodge:subsystem:tools",
            "urn:blue-lodge:subsystem:ipc",
            "urn:blue-lodge:subsystem:sys",
            "urn:blue-lodge:subsystem:comms",
            "urn:blue-lodge:subsystem:memory",
            "urn:blue-lodge:subsystem:agents",
            "urn:blue-lodge:subsystem:ui",
            "urn:blue-lodge:subsystem:knowledge",
            "urn:blue-lodge:subsystem:scripts",
            "urn:blue-lodge:subsystem:commands",
            "urn:blue-lodge:subsystem:web"
        ],
        "standards": [
            "urn:blue-lodge:standard:okf-directory-structure",
            "urn:blue-lodge:standard:fifo-async-ipc-flowcontrol",
            "urn:blue-lodge:standard:rbac-uuid-linking",
            "urn:blue-lodge:standard:polyglot-runtime-architecture",
            "urn:blue-lodge:standard:subagent-sandbox-lifecycle",
            "urn:blue-lodge:standard:telemetry-closed-loop-remediation",
            "urn:blue-lodge:standard:sovereign-inference-switching"
        ]
    })

    # 2. Curated Source Modules Definition (Ground-Truth Architectural Annotations)
    curated_modules = {
        "lib/core/agent_helpers.sh": ("agent_helpers.sh", "lib/core/agent_helpers.sh", "Bash", "Legacy-loop survivors: AGENT_* config defaults, think-block stripper, JSON extractor, /q single-shot ask and /plan plan-only strategist wrapper.", "urn:blue-lodge:subsystem:core", ["llm.sh", "memory.sh", "tools.sh"], ["agent_ask", "agent_plan", "_strip_think_blocks", "_agent_extract_json"]),
        "lib/core/agent_sm.sh": ("agent_sm.sh", "lib/core/agent_sm.sh", "Bash", "State machine tracking agent execution phases (BOOT, COGNITION, ACTUATION, IDLE).", "urn:blue-lodge:subsystem:core", ["task_sync.sh"], ["agent_sm_transition", "agent_sm_get_state"]),
        "lib/core/react.sh": ("react.sh", "lib/core/react.sh", "Bash", "Multi-turn ReAct reasoning loop with tool calling, observation aggregation, and perturbation recovery.", "urn:blue-lodge:subsystem:core", ["native_tools.sh", "llm.sh", "fifo_ipc.sh"], ["react_run", "react_step"]),
        "lib/core/reflexive.sh": ("reflexive.sh", "lib/core/reflexive.sh", "Bash", "Reflexive metacognitive self-critique, soul gating, and prompt self-correction.", "urn:blue-lodge:subsystem:core", ["soul.md"], ["reflexive_gate", "reflexive_critique"]),
        "lib/core/context_engine.sh": ("context_engine.sh", "lib/core/context_engine.sh", "Bash", "Adaptive context window compressor, relevance discriminator, and memory pruner.", "urn:blue-lodge:subsystem:core", ["memory.sh", "recall.sh"], ["context_engine_build", "context_engine_compress"]),
        "lib/core/llm.sh": ("llm.sh", "lib/core/llm.sh", "Bash", "Low-level HTTP client interfacing with vLLM/llama-server PRISM inference backends.", "urn:blue-lodge:subsystem:core", ["endpoints.sh"], ["llm_complete", "llm_stream", "llm_unload"]),
        "lib/core/endpoints.sh": ("endpoints.sh", "lib/core/endpoints.sh", "Bash", "Inference endpoint registry, multi-tier failover routing, and health checks.", "urn:blue-lodge:subsystem:core", ["endpoints.conf"], ["endpoints_init", "endpoints_select"]),
        "lib/core/providers.sh": ("providers.sh", "lib/core/providers.sh", "Bash", "Model provider configurations for local PRISM, Ollama, Anthropic, and OpenAI.", "urn:blue-lodge:subsystem:core", [], ["providers_get_config"]),
        "lib/core/limits.sh": ("limits.sh", "lib/core/limits.sh", "Bash", "Resource governor enforcing token caps, turn limits, and API budget ceilings.", "urn:blue-lodge:subsystem:core", ["limits.conf"], ["limits_check", "limits_deduct"]),
        "lib/core/auth.sh": ("auth.sh", "lib/core/auth.sh", "Bash", "Sovereign user authentication, role-based capability permissioning, and RFC 4122 UUID multi-entity graph linkage.", "urn:blue-lodge:subsystem:core", [], ["auth_verify_token", "auth_check_permission", "uuid_generate", "identity_link"]),
        "lib/core/models.sh": ("models.sh", "lib/core/models.sh", "Bash", "Model-agnostic sampling lookup from the operator's active Model Hub profile (no shipped model list).", "urn:blue-lodge:subsystem:core", [], ["models_get_param", "models_apply_defaults", "models_has_vision"]),
        "lib/core/api.sh": ("api.sh", "lib/core/api.sh", "Bash", "API key management and external service integration helpers.", "urn:blue-lodge:subsystem:core", [], ["api_keys_get", "api_keys_set"]),

        "lib/ipc/fifo_ipc.sh": ("fifo_ipc.sh", "lib/ipc/fifo_ipc.sh", "Bash", "Sovereign POSIX FIFO Async/Await, Flow Control, and Agentic IPC SDK protocol engine (v3).", "urn:blue-lodge:subsystem:ipc", ["ui.sh"], ["ipc_init", "ipc_channel_open", "ipc_channel_close", "ipc_channel_is_open", "ipc_channel_list", "ipc_status", "ipc_channel_flush", "ipc_flow_acquire", "ipc_flow_grant", "ipc_flow_send_ctrl", "ipc_flow_pause", "ipc_flow_resume", "ipc_flow_unstick", "ipc_flow_ping", "ipc_queue_flush", "ipc_validate_frame", "ipc_send", "ipc_recv", "ipc_write_frame", "ipc_read_frame", "ipc_async", "ipc_await", "ipc_await_all", "ipc_pipe", "ipc_cancel", "ipc_promise_status", "ipc_gc", "ipc_log"]),
        "lib/ipc/ipc.sh": ("ipc.sh", "lib/ipc/ipc.sh", "Bash", "Forwarding shim linking legacy IPC calls to modern FIFO flowcontrol engine.", "urn:blue-lodge:subsystem:ipc", ["fifo_ipc.sh"], []),
        "lib/ipc/task_sync.sh": ("task_sync.sh", "lib/ipc/task_sync.sh", "Bash", "Inter-task synchronization primitives, unified FIFO/MQTT routing, and cross-process promise waiting.", "urn:blue-lodge:subsystem:ipc", ["fifo_ipc.sh", "mqtt.sh"], ["task_sync_wait", "task_sync_signal", "task_sync_send", "task_sync_recv", "task_sync_async", "task_sync_await", "task_sync_flow_control"]),

        "lib/tools/native_tools.sh": ("native_tools.sh", "lib/tools/native_tools.sh", "Bash", "POSIX tool catalog bridge generating OpenAI-compatible function schemas and dispatching tools.", "urn:blue-lodge:subsystem:tools", ["tools.sh", "treesitter.sh", "web.sh"], ["native_tools_dispatch", "native_tools_schemas"]),
        "lib/tools/tools.sh": ("tools.sh", "lib/tools/tools.sh", "Bash", "Built-in POSIX file inspection, editing, and execution utilities.", "urn:blue-lodge:subsystem:tools", [], ["tool_read", "tool_write", "tool_edit", "tool_bash"]),
        "lib/tools/treesitter.sh": ("treesitter.sh", "lib/tools/treesitter.sh", "Bash", "Tree-sitter AST syntax validator and semantic symbol extractor.", "urn:blue-lodge:subsystem:tools", [], ["treesitter_validate", "treesitter_symbols"]),
        "lib/tools/research_graph.sh": ("research_graph.sh", "lib/tools/research_graph.sh", "Bash", "Autonomous deep research engine with arXiv downloading, monograph synthesis, and PGP signing.", "urn:blue-lodge:subsystem:tools", ["web.sh", "pgp.sh"], ["research_run", "research_synthesize"]),
        "lib/tools/git.sh": ("git.sh", "lib/tools/git.sh", "Bash", "Local git repository helpers and status verification.", "urn:blue-lodge:subsystem:tools", [], ["git_current_branch", "git_status_check"]),
        "lib/tools/mcp.sh": ("mcp.sh", "lib/tools/mcp.sh", "Bash", "Model Context Protocol client supervisor managing stdio server lifecycles.", "urn:blue-lodge:subsystem:tools", [], ["mcp_init", "mcp_call_tool"]),
        "lib/tools/mcp_server_fetch.sh": ("mcp_server_fetch.sh", "lib/tools/mcp_server_fetch.sh", "Bash", "MCP stdio server providing web page retrieval and markdown conversion.", "urn:blue-lodge:subsystem:tools", ["web.sh"], []),
        "lib/tools/mcp_server_git.sh": ("mcp_server_git.sh", "lib/tools/mcp_server_git.sh", "Bash", "MCP stdio server exposing git repository inspection and commit tools.", "urn:blue-lodge:subsystem:tools", [], []),
        "lib/tools/mcp_server_gitea.sh": ("mcp_server_gitea.sh", "lib/tools/mcp_server_gitea.sh", "Bash", "MCP stdio server interfacing with local Gitea issues, PRs, and milestones.", "urn:blue-lodge:subsystem:tools", [], ["mcp_gitea_create_issue", "mcp_gitea_get_pr"]),
        "lib/tools/mcp_server_inference.sh": ("mcp_server_inference.sh", "lib/tools/mcp_server_inference.sh", "Bash", "MCP stdio server exposing PRISM inference slot diagnostics.", "urn:blue-lodge:subsystem:tools", ["endpoints.sh"], []),
        "lib/tools/mcp_server_mqtt.sh": ("mcp_server_mqtt.sh", "lib/tools/mcp_server_mqtt.sh", "Bash", "MCP stdio server enabling publish/subscribe over Mosquitto MQTT broker.", "urn:blue-lodge:subsystem:tools", ["mqtt.sh"], []),
        "lib/tools/mcp_server_x.sh": ("mcp_server_x.sh", "lib/tools/mcp_server_x.sh", "Bash", "MCP stdio server providing Twitter/X timeline polling and tweeting.", "urn:blue-lodge:subsystem:tools", ["social.sh"], []),
        "lib/tools/mcp_server_gcloud.sh": ("mcp_server_gcloud.sh", "lib/tools/mcp_server_gcloud.sh", "Bash", "MCP stdio server for Google Cloud Run and Vertex integrations.", "urn:blue-lodge:subsystem:tools", [], []),

        "lib/sys/sandbox.sh": ("sandbox.sh", "lib/sys/sandbox.sh", "Bash", "Filesystem isolation sandbox ensuring execution confined to scratch trees.", "urn:blue-lodge:subsystem:sys", [], ["sandbox_init", "sandbox_exec"]),
        "lib/sys/container.sh": ("container.sh", "lib/sys/container.sh", "Bash", "Docker container manager launching and monitoring George CUDA sandbox containers.", "urn:blue-lodge:subsystem:sys", [], ["container_start", "container_exec"]),
        "lib/sys/cron.sh": ("cron.sh", "lib/sys/cron.sh", "Bash", "Autonomous background cron daemon scheduling periodic sweeps with log rotation.", "urn:blue-lodge:subsystem:sys", ["cron.conf"], ["cron_start", "cron_stop", "cron_sweep"]),
        "lib/sys/vitals.sh": ("vitals.sh", "lib/sys/vitals.sh", "Bash", "Hardware vitals probe monitoring GPU temperature, wattage, VRAM, and RAM.", "urn:blue-lodge:subsystem:sys", [], ["vitals_check", "vitals_probe_gpu"]),
        "lib/sys/backup.sh": ("backup.sh", "lib/sys/backup.sh", "Bash", "Workspace backup and snapshot archive management.", "urn:blue-lodge:subsystem:sys", [], ["backup_create", "backup_restore"]),
        "lib/sys/secrets.sh": ("secrets.sh", "lib/sys/secrets.sh", "Bash", "Encrypted secrets vault storing API keys and authentication tokens.", "urn:blue-lodge:subsystem:sys", [], ["secrets_get", "secrets_set"]),
        "lib/sys/security.sh": ("security.sh", "lib/sys/security.sh", "Bash", "Security policy validator scanning shell payloads for injection risks.", "urn:blue-lodge:subsystem:sys", [], ["security_audit_command"]),
        "lib/sys/pgp.sh": ("pgp.sh", "lib/sys/pgp.sh", "Bash", "GnuPG signing and verification engine for sovereign artifacts and journals.", "urn:blue-lodge:subsystem:sys", [], ["pgp_sign_file", "pgp_verify_file"]),
        "lib/sys/remote.sh": ("remote.sh", "lib/sys/remote.sh", "Bash", "SSH remote execution and node clustering manager.", "urn:blue-lodge:subsystem:sys", [], ["remote_exec", "remote_sync"]),
        "lib/sys/cache.sh": ("cache.sh", "lib/sys/cache.sh", "Bash", "Fast in-memory and filesystem request cache and pseudo-LRU deduplication store.", "urn:blue-lodge:subsystem:sys", [], ["cache_init", "cache_record_inbound_request", "cache_is_prior_request"]),

        "lib/comms/web.sh": ("web.sh", "lib/comms/web.sh", "Bash", "Web client engine with search fallback (SearXNG/DuckDuckGo), DOM cleaning, and rate limiting.", "urn:blue-lodge:subsystem:comms", [], ["web_search", "web_fetch", "research_sandbox"]),
        "lib/comms/discord_bridge.sh": ("discord_bridge.sh", "lib/comms/discord_bridge.sh", "Bash", "Bidirectional Discord bot bridge handling user DMs, guild channels, and tool invocation.", "urn:blue-lodge:subsystem:comms", ["api.sh", "react.sh"], ["discord_start", "discord_poll"]),
        "lib/comms/email.sh": ("email.sh", "lib/comms/email.sh", "Bash", "IMAP/SMTP email bridge for operator notifications and incoming task requests.", "urn:blue-lodge:subsystem:comms", [], ["email_send", "email_sweep"]),
        "lib/comms/mqtt.sh": ("mqtt.sh", "lib/comms/mqtt.sh", "Bash", "MQTT publisher and subscriber client interfacing with Mosquitto event buses.", "urn:blue-lodge:subsystem:comms", [], ["mqtt_publish", "mqtt_subscribe"]),
        "lib/comms/phone.sh": ("phone.sh", "lib/comms/phone.sh", "Bash", "Twilio and Termux SMS/Telephony bridge for emergency operator alerts.", "urn:blue-lodge:subsystem:comms", [], ["phone_send_sms"]),
        "lib/comms/social.sh": ("social.sh", "lib/comms/social.sh", "Bash", "Unified social orchestration layer for Mastodon and Twitter/X.", "urn:blue-lodge:subsystem:comms", [], ["social_post", "social_sweep"]),
        "lib/comms/social_blog.sh": ("social_blog.sh", "lib/comms/social_blog.sh", "Bash", "Long-form editorial blog synthesizer publishing technical updates to web portals.", "urn:blue-lodge:subsystem:comms", [], ["social_blog_publish"]),
        "lib/comms/gsuite.sh": ("gsuite.sh", "lib/comms/gsuite.sh", "Bash", "Google Workspace / GSuite API integration for Drive, Docs, and Calendar.", "urn:blue-lodge:subsystem:comms", [], ["gsuite_upload_doc"]),
        "lib/comms/wallet.sh": ("wallet.sh", "lib/comms/wallet.sh", "Bash", "Sovereign cryptocurrency wallet observer for gas and balance verification.", "urn:blue-lodge:subsystem:comms", [], ["wallet_get_balance"]),

        "lib/memory/memory.sh": ("memory.sh", "lib/memory/memory.sh", "Bash", "Macro and micro memory store managing working context and key facts.", "urn:blue-lodge:subsystem:memory", [], ["memory_get", "memory_set", "memory_save"]),
        "lib/memory/recall.sh": ("recall.sh", "lib/memory/recall.sh", "Bash", "SQLite FTS5 full-text search indexing past project milestones, files, and transcripts.", "urn:blue-lodge:subsystem:memory", ["recall.sql"], ["recall_search", "recall_index"]),
        "lib/memory/journal.sh": ("journal.sh", "lib/memory/journal.sh", "Bash", "Three-degree decaying episodic journal keeping session history and lessons learned.", "urn:blue-lodge:subsystem:memory", ["journal.md", "pgp.sh"], ["journal_write", "journal_reflect", "journal_apply_decay"]),
        "lib/memory/transcript.sh": ("transcript.sh", "lib/memory/transcript.sh", "Bash", "Session trajectory logger recording turn prompts, tool calls, and completions.", "urn:blue-lodge:subsystem:memory", [], ["transcript_record_turn"]),

        "lib/agents/subagents.sh": ("subagents.sh", "lib/agents/subagents.sh", "Bash", "Git worktree subagent manager spawning and monitoring isolated worker processes.", "urn:blue-lodge:subsystem:agents", ["fifo_ipc.sh"], ["subagents_spawn", "subagents_reap_orphans", "subagents_cleanup_all"]),
        "lib/agents/swarm.sh": ("swarm.sh", "lib/agents/swarm.sh", "Bash", "Multi-agent coordination protocol distributing parallel objectives across subagents.", "urn:blue-lodge:subsystem:agents", ["subagents.sh"], ["swarm_dispatch"]),
        "lib/agents/workflows.sh": ("workflows.sh", "lib/agents/workflows.sh", "Bash", "Deterministic workflow orchestrator executing multi-stage pipeline contracts.", "urn:blue-lodge:subsystem:agents", [], ["workflows_run"]),
        "lib/agents/skills.sh": ("skills.sh", "lib/agents/skills.sh", "Bash", "On-demand agent skills loader parsing YAML frontmatter and injecting procedures.", "urn:blue-lodge:subsystem:agents", [], ["skills_load"]),
        "lib/agents/rules.sh": ("rules.sh", "lib/agents/rules.sh", "Bash", "Behavioral rules engine injecting user-defined constraints into agent system prompts.", "urn:blue-lodge:subsystem:agents", [], ["rules_load_all"]),
        "lib/agents/remediation.sh": ("remediation.sh", "lib/agents/remediation.sh", "Bash", "Closed-loop failure remediation queue managing retry policies and escalation.", "urn:blue-lodge:subsystem:agents", ["telemetry.sh", "phytology.sh"], ["remediation_queue_add", "remediation_process"]),
        "lib/agents/phytology.sh": ("phytology.sh", "lib/agents/phytology.sh", "Bash", "Living tissue self-healing engine diagnosing and auto-patching failing scripts.", "urn:blue-lodge:subsystem:agents", [], ["phytology_audit", "phytology_heal", "phytology_rollback"]),
        "lib/agents/telemetry.sh": ("telemetry.sh", "lib/agents/telemetry.sh", "Bash", "Telemetry collector, SHA256 error fingerprinting, incident preservation, and GC.", "urn:blue-lodge:subsystem:agents", [], ["telemetry_record_event", "telemetry_preserve_incident", "telemetry_gc"]),
        "lib/agents/alerts.sh": ("alerts.sh", "lib/agents/alerts.sh", "Bash", "Operator alerting and incident notification dispatcher.", "urn:blue-lodge:subsystem:agents", [], ["alerts_send"]),
        "lib/agents/pr.sh": ("pr.sh", "lib/agents/pr.sh", "Bash", "Pull request and automated review generator.", "urn:blue-lodge:subsystem:agents", [], ["pr_create"]),
        "lib/agents/sentinel.sh": ("sentinel.sh", "lib/agents/sentinel.sh", "Bash", "Repository security and integrity watchdog.", "urn:blue-lodge:subsystem:agents", [], ["sentinel_scan"]),
        "lib/agents/reputation.sh": ("reputation.sh", "lib/agents/reputation.sh", "Bash", "Agent confidence and reliability scoring ledger.", "urn:blue-lodge:subsystem:agents", [], ["reputation_score"]),

        "lib/ui/ui.sh": ("ui.sh", "lib/ui/ui.sh", "Bash", "ANSI terminal coloring, status badges, formatted tables, and visual spinners.", "urn:blue-lodge:subsystem:ui", [], ["ui_banner", "ui_ok", "ui_err", "ui_dim", "ui_table"]),
        "lib/ui/ui_dashboard.sh": ("ui_dashboard.sh", "lib/ui/ui_dashboard.sh", "Bash", "Real-time ASCII terminal dashboard displaying subagent statuses, vitals, and queues.", "urn:blue-lodge:subsystem:ui", ["vitals.sh", "subagents.sh"], ["ui_dashboard_render"]),
        "lib/ui/popup.sh": ("popup.sh", "lib/ui/popup.sh", "Bash", "Desktop and terminal popup notification dispatcher for high-priority alerts.", "urn:blue-lodge:subsystem:ui", [], ["popup_notify"]),
        "lib/ui/slash.sh": ("slash.sh", "lib/ui/slash.sh", "Bash", "Interactive slash command menu and discovery helper.", "urn:blue-lodge:subsystem:ui", ["commands.sh"], ["slash_menu"]),
        "lib/ui/commands.sh": ("commands.sh", "lib/ui/commands.sh", "Bash", "Slash command dispatcher routing /commands to commands/*.sh handlers.", "urn:blue-lodge:subsystem:ui", [], ["commands_dispatch", "commands_register"]),

        "lib/knowledge/okf.sh": ("okf.sh", "lib/knowledge/okf.sh", "Bash", "Google Open Knowledge Graph engine for semantic querying, standards lookup, validation, and tree rendering.", "urn:blue-lodge:subsystem:knowledge", ["data/schemas/okf_graph.schema.json"], ["okf_search", "okf_query", "okf_standards", "okf_tree", "okf_validate", "okf_sync"])
    }

    modules = dict(curated_modules)

    # 3. Dynamic Discovery Pass across Codebase Hierarchies
    # Subsystem mapping rules:
    #   lib/<domain>/<file> -> urn:blue-lodge:subsystem:<domain>
    #   commands/<file>     -> urn:blue-lodge:subsystem:commands
    #   web/<src|static>/<file> -> urn:blue-lodge:subsystem:web
    #   scripts/<domain>/<file> -> urn:blue-lodge:subsystem:scripts

    # A. Scan lib/
    lib_dir = os.path.join(LODGE_DIR, "lib")
    if os.path.isdir(lib_dir):
        for root, _, files in os.walk(lib_dir):
            for file in files:
                if file.endswith(".sh") or file.endswith(".py"):
                    full_p = os.path.join(root, file)
                    rel_p = os.path.relpath(full_p, LODGE_DIR)
                    domain = os.path.basename(root)
                    subsystem_uri = f"urn:blue-lodge:subsystem:{domain}"

                    lang = "Bash" if file.endswith(".sh") else "Python"
                    dyn_desc, dyn_exports, dyn_deps = (
                        extract_bash_metadata(full_p, rel_p) if lang == "Bash"
                        else extract_python_metadata(full_p, rel_p)
                    )

                    if rel_p in modules:
                        # Merge dynamically extracted exports and deps with curated entry
                        name, path, c_lang, c_desc, c_sub, c_deps, c_exports = modules[rel_p]
                        merged_exports = list(dict.fromkeys(c_exports + dyn_exports))
                        merged_deps = list(dict.fromkeys(c_deps + dyn_deps))
                        modules[rel_p] = (name, path, c_lang, c_desc, c_sub, merged_deps, merged_exports)
                    else:
                        modules[rel_p] = (file, rel_p, lang, dyn_desc, subsystem_uri, dyn_deps, dyn_exports)

    # B. Scan commands/
    cmds_dir = os.path.join(LODGE_DIR, "commands")
    if os.path.isdir(cmds_dir):
        for file in sorted(os.listdir(cmds_dir)):
            if file.endswith(".sh"):
                full_p = os.path.join(cmds_dir, file)
                rel_p = os.path.relpath(full_p, LODGE_DIR)
                dyn_desc, dyn_exports, dyn_deps = extract_bash_metadata(full_p, rel_p)
                cmd_fn = f"cmd_{file.replace('.sh', '')}"
                if cmd_fn not in dyn_exports:
                    dyn_exports.insert(0, cmd_fn)
                modules[rel_p] = (file, rel_p, "Bash", dyn_desc, "urn:blue-lodge:subsystem:commands", dyn_deps, dyn_exports)

    # C. Scan web/
    web_dir = os.path.join(LODGE_DIR, "web")
    if os.path.isdir(web_dir):
        # Rust sources
        web_src = os.path.join(web_dir, "src")
        for root, _, files in os.walk(web_src):
            for file in files:
                if file.endswith(".rs"):
                    full_p = os.path.join(root, file)
                    rel_p = os.path.relpath(full_p, LODGE_DIR)
                    dyn_desc, dyn_exports, dyn_deps = extract_rust_metadata(full_p, rel_p)
                    modules[rel_p] = (file, rel_p, "Rust", dyn_desc, "urn:blue-lodge:subsystem:web", dyn_deps, dyn_exports)

        # Frontend JS
        app_js = os.path.join(web_dir, "static", "app.js")
        if os.path.isfile(app_js):
            rel_p = os.path.relpath(app_js, LODGE_DIR)
            dyn_desc, dyn_exports, dyn_deps = extract_js_metadata(app_js, rel_p)
            modules[rel_p] = ("app.js", rel_p, "JavaScript", dyn_desc, "urn:blue-lodge:subsystem:web", dyn_deps, dyn_exports)

    # D. Scan scripts/
    scripts_dir = os.path.join(LODGE_DIR, "scripts")
    if os.path.isdir(scripts_dir):
        for root, _, files in os.walk(scripts_dir):
            for file in files:
                if file.endswith(".sh") or file.endswith(".py"):
                    full_p = os.path.join(root, file)
                    rel_p = os.path.relpath(full_p, LODGE_DIR)
                    lang = "Bash" if file.endswith(".sh") else "Python"
                    dyn_desc, dyn_exports, dyn_deps = (
                        extract_bash_metadata(full_p, rel_p) if lang == "Bash"
                        else extract_python_metadata(full_p, rel_p)
                    )
                    modules[rel_p] = (file, rel_p, lang, dyn_desc, "urn:blue-lodge:subsystem:scripts", dyn_deps, dyn_exports)


    # E. Scan docs/
    docs_dir = os.path.join(LODGE_DIR, "docs")
    doc_nodes = []
    if os.path.isdir(docs_dir):
        for root, _, files in os.walk(docs_dir):
            for file in sorted(files):
                if file.endswith(".md"):
                    full_p = os.path.join(root, file)
                    rel_p = os.path.relpath(full_p, LODGE_DIR)
                    meta = extract_doc_metadata(full_p, rel_p)
                    doc_nodes.append(meta)

    # 4. Subsystems
    subsystems = [
        {
            "@id": "urn:blue-lodge:subsystem:core",
            "@type": "DataCatalog",
            "name": "Core Reasoning & Agent Loop",
            "description": "Foundational autonomous reasoning loop, state machines, context engine, LLM inference endpoints, and execution limits.",
            "path": "lib/core",
            "isPartOf": "urn:blue-lodge:core",
            "standards": ["urn:blue-lodge:standard:rbac-uuid-linking"]
        },
        {
            "@id": "urn:blue-lodge:subsystem:tools",
            "@type": "DataCatalog",
            "name": "Tools & Native Protocol Bridges",
            "description": "POSIX tool catalog, OpenAI/llama-server function-calling schema bridge, Tree-sitter AST symbol parser, Deep Research engine, and MCP integrations.",
            "path": "lib/tools",
            "isPartOf": "urn:blue-lodge:core"
        },
        {
            "@id": "urn:blue-lodge:subsystem:ipc",
            "@type": "DataCatalog",
            "name": "Asynchronous FIFO IPC & Flow Control",
            "description": "Kernel-backed non-blocking named pipe communication, sliding-window credit flow control, atomic directory locks, and AWK garbage collection.",
            "path": "lib/ipc",
            "isPartOf": "urn:blue-lodge:core",
            "standards": ["urn:blue-lodge:standard:fifo-async-ipc-flowcontrol"]
        },
        {
            "@id": "urn:blue-lodge:subsystem:sys",
            "@type": "DataCatalog",
            "name": "System, Security & Environment",
            "description": "Execution sandboxes, Docker CUDA runtimes, scheduled cron daemon, hardware telemetry vitals, PGP signature verification, and secrets vault.",
            "path": "lib/sys",
            "isPartOf": "urn:blue-lodge:core"
        },
        {
            "@id": "urn:blue-lodge:subsystem:comms",
            "@type": "DataCatalog",
            "name": "External Communications & Social Fabrics",
            "description": "Outbound HTTP scraping, Discord bidirectional bridge, IMAP/SMTP email, MQTT messaging, phone SMS, and social network connectors.",
            "path": "lib/comms",
            "isPartOf": "urn:blue-lodge:core"
        },
        {
            "@id": "urn:blue-lodge:subsystem:memory",
            "@type": "DataCatalog",
            "name": "Memory, Recall & Journal",
            "description": "Multi-tier memory architecture (working, short-term, long-term), SQLite FTS5 recall database, and three-degree journal system.",
            "path": "lib/memory",
            "isPartOf": "urn:blue-lodge:core"
        },
        {
            "@id": "urn:blue-lodge:subsystem:agents",
            "@type": "DataCatalog",
            "name": "Autonomous Subagents, Swarm & Remediation",
            "description": "Git worktree subagent management, swarm dispatch, autonomous phytology tissue self-healing, and closed-loop telemetry remediation.",
            "path": "lib/agents",
            "isPartOf": "urn:blue-lodge:core",
            "standards": [
                "urn:blue-lodge:standard:subagent-sandbox-lifecycle",
                "urn:blue-lodge:standard:telemetry-closed-loop-remediation"
            ]
        },
        {
            "@id": "urn:blue-lodge:subsystem:ui",
            "@type": "DataCatalog",
            "name": "Terminal UI & Interactive Shell",
            "description": "Terminal styling, ANSI mascot banners, real-time dashboard widgets, and slash command dispatcher.",
            "path": "lib/ui",
            "isPartOf": "urn:blue-lodge:core"
        },
        {
            "@id": "urn:blue-lodge:subsystem:knowledge",
            "@type": "DataCatalog",
            "name": "Google Open Knowledge Graph (OKF) Engine",
            "description": "Semantic knowledge graph traversal, schema validation, standards catalog, and code architecture search engine.",
            "path": "lib/knowledge",
            "isPartOf": "urn:blue-lodge:core",
            "standards": ["urn:blue-lodge:standard:okf-directory-structure"]
        },
        {
            "@id": "urn:blue-lodge:subsystem:scripts",
            "@type": "DataCatalog",
            "name": "Automation, Infrastructure & Model Scripts",
            "description": "PRISM inference server deployment, GPU validation, local CI runners, model profile switching, and Colab training pipelines.",
            "path": "scripts",
            "isPartOf": "urn:blue-lodge:core",
            "standards": ["urn:blue-lodge:standard:sovereign-inference-switching"]
        },
        {
            "@id": "urn:blue-lodge:subsystem:commands",
            "@type": "DataCatalog",
            "name": "Slash Command Dispatch Catalog",
            "description": "Operator slash command handlers executing structured operations across git, memory, models, web, telemetry, and OKF.",
            "path": "commands",
            "isPartOf": "urn:blue-lodge:core"
        },
        {
            "@id": "urn:blue-lodge:subsystem:web",
            "@type": "DataCatalog",
            "name": "Sovereign Web UI Sidecar",
            "description": "Axum/Tokio Rust asynchronous PTY sidecar with xterm.js terminal interface, SSE telemetry streaming, and Forge model credit dashboard.",
            "path": "web",
            "isPartOf": "urn:blue-lodge:core"
        },
        {
            "@id": "urn:blue-lodge:subsystem:docs",
            "@type": "DataCatalog",
            "name": "Obsidian Linked Wiki & Documentation",
            "description": "Comprehensive Map of Content and interconnected knowledge base organized via Google OKF schemas, YAML frontmatter, and bidirectional wikilinks.",
            "path": "docs",
            "isPartOf": "urn:blue-lodge:core"
        },
    ]

    # Populate hasPart on subsystems
    for sub in subsystems:
        sub_id = sub["@id"]
        if sub_id == "urn:blue-lodge:subsystem:docs":
            sub["hasPart"] = sorted([dn["@id"] for dn in doc_nodes])
        else:
            sub["hasPart"] = sorted([
                f"urn:blue-lodge:module:{m_path}"
                for _, (_, m_path, _, _, m_sub, *_) in modules.items()
                if m_sub == sub_id
            ])

    graph_nodes.extend(subsystems)

    # 5. Source Module Nodes
    for _, (name, path, lang, desc, subsystem, deps, exports) in sorted(modules.items(), key=lambda x: x[1][1]):
        dep_uris = []
        for d in deps:
            if d.endswith(".sh"):
                # Lookup matching module by filename or relative path
                matched_uri = None
                for _, (_, cand_path, *_) in modules.items():
                    if cand_path == d or os.path.basename(cand_path) == d:
                        matched_uri = f"urn:blue-lodge:module:{cand_path}"
                        break
                dep_uris.append(matched_uri or f"urn:blue-lodge:module:{d}")

        encoding = "text/x-shellscript"
        if lang == "Python":
            encoding = "text/x-python"
        elif lang == "Rust":
            encoding = "text/x-rust"
        elif lang == "JavaScript":
            encoding = "application/javascript"

        graph_nodes.append({
            "@id": f"urn:blue-lodge:module:{path}",
            "@type": "SoftwareSourceCode",
            "name": name,
            "path": path,
            "programmingLanguage": lang,
            "encodingFormat": encoding,
            "description": desc,
            "stability": "stable",
            "isPartOf": subsystem,
            "dependencies": dep_uris,
            "exports": exports
        })

    # 6. Standards Nodes (Loaded directly from okf/standards/*.jsonld)
    standards_files = glob.glob(os.path.join(LODGE_DIR, "okf", "standards", "*.jsonld"))
    standards = []
    for sf in sorted(standards_files):
        try:
            with open(sf, "r", encoding="utf-8") as s_file:
                s_data = json.load(s_file)
                for snode in s_data.get("@graph", []):
                    standards.append(snode)
        except Exception as e:
            print(f"Warning: could not read {sf}: {e}")
    graph_nodes.extend(standards)
    graph_nodes.extend(doc_nodes)

    full_graph = {
        "@context": {
            "@vocab": "https://schema.org/",
            "goog": "http://schema.googleapis.com/",
            "okf": "https://developers.google.com/knowledge-graph/schema/",
            "lodge": "urn:blue-lodge:schema:"
        },
        "@graph": graph_nodes
    }

    out_dir = os.path.join(LODGE_DIR, "okf")
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "blue_lodge_graph.jsonld")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(full_graph, f, indent=2)

    print(f"Successfully wrote {out_path} with {len(graph_nodes)} semantic nodes.")


if __name__ == "__main__":
    build_okf_graph()
