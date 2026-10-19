#!/usr/bin/env python3
"""
Honeydew DAG Strategist (Option 4A)
Decomposes an arbitrary operator objective into a structured DAG execution plan
tailored to Blue Lodge's native bedrock capabilities and flow-control protocol.
"""

import sys
import os
import json
import re
import urllib.request
import urllib.error

def _load_grammar():
    repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    grammar_path = os.path.join(repo_root, "grammars", "honeydew-items.gbnf")
    if os.path.exists(grammar_path):
        try:
            with open(grammar_path, "r", encoding="utf-8") as f:
                return f.read()
        except Exception:
            pass
    return None


def clean_and_parse(text, original_task=""):
    if not text:
        return None
    # Strip response tags if present
    text = re.sub(r'</?response>', '', text, flags=re.IGNORECASE)
    # Strip think tags if present
    text = re.sub(r'<think>.*?</think>', '', text, flags=re.DOTALL)
    # Strip bracketed think tags like [think]...[/think] or [thought]...[/thought]
    text = re.sub(r'\[(?:think|thought)\].*?\[/(?:think|thought)\]', '', text, flags=re.DOTALL | re.IGNORECASE)
    # Strip markdown code blocks
    text = re.sub(r'^```(?:json)?\s*', '', text.strip(), flags=re.MULTILINE)
    text = re.sub(r'```$', '', text.strip(), flags=re.MULTILINE)
    text = text.strip()

    # Find first '{' and last '}'
    start = text.find('{')
    end = text.rfind('}')
    if start != -1 and end != -1 and end > start:
        candidate = text[start:end+1]
    else:
        candidate = text

    # Attempt 1: Direct JSON parse
    try:
        data = json.loads(candidate)
        if isinstance(data, dict) and 'items' in data and isinstance(data['items'], list):
            if 'task_type' not in data or data['task_type'] not in ["chat", "code", "research", "ops"]:
                data['task_type'] = classify_task(original_task or candidate)
            return data
    except Exception:
        pass

    # Attempt 2: Clean trailing quotes and commas
    cleaned = re.sub(r'\"+,\s*\"+', '\",', candidate)
    cleaned = re.sub(r',\s*([\]}])', r'\1', cleaned)
    try:
        data = json.loads(cleaned)
        if isinstance(data, dict) and 'items' in data and isinstance(data['items'], list):
            if 'task_type' not in data or data['task_type'] not in ["chat", "code", "research", "ops"]:
                data['task_type'] = classify_task(original_task or candidate)
            return data
    except Exception:
        pass

    # Attempt 3: Regex extraction of task descriptions
    task_matches = re.findall(r'\"task\"\s*:\s*\"([^\"]+)\"', text)
    if task_matches and len(task_matches) >= 2:
        return {
            'task_type': classify_task(original_task or text),
            'items': [
                {
                    'id': i + 1,
                    'task': t.strip().rstrip('",').strip(),
                    'tier': i + 1,
                    'depends_on': [i] if i > 0 else []
                }
                for i, t in enumerate(task_matches[:6])
            ]
        }

    return None

def query_strategist_endpoint(task, endpoint_url="http://127.0.0.1:8080"):
    sys_prompt = """You are the Blue Lodge Honeydew DAG Strategist.
Decompose the user objective into 2 to 6 distinct, logical, sequential or parallel milestones tailored uniquely and specifically to the operator's request.
Also classify the task into one of the following primary types:
- "chat": Pure conversational greetings, pleasantries, brief social chat, or simple Q&A requiring no external tools or code execution.
- "research": Inquiries requiring information retrieval, web search, doc reading, academic research, news analysis, or financial/market/crypto evaluation.
- "code": Software engineering, debugging, writing/modifying code, tests, refactoring, or git operations.
- "ops": System administration, cron jobs, service management, process control, or devops tasks.

Blue Lodge Sovereign Capabilities & Dynamic Tool Discovery:
- Dynamic Tool & MCP Discovery: The agent is not restricted to a fixed toolset; it dynamically searches, introspects, and mounts specialized tools and MCP servers on-the-fly using `tool_search` based on task requirements.
- Sovereign P25 SDR Radio Scanner Lab (`sdr_query`, `sdr_listen`): George operates a live local P25 trunked radio scanner database (`.george/sdr/sdr_intel.db`) and `.m4a` audio archive covering Regional County Police, Fire, Sheriff, and County EMS dispatches. `sdr_query` filters and summarizes transmissions, talkgroups, radio unit timelines, and database statistics; `sdr_listen` feeds `.m4a` audio into the Whisper P25-A100-LoRA + Gemma-4 E4B multimodal audio encoder.
- Information Retrieval & Live Research: Autonomous web investigation defaulting to sovereign metasearch (SearXNG) and web retrieval for live information, news, documentation, and academic research.
- Scheduled Research & Intelligence Cron Jobs: When the objective asks for a scheduled or recurring research, intel, or reporting cron job, decompose the plan into creating a .george/cron_jobs/<name>.sh launcher that delegates execution to the native research_sandbox runner via lodge, verifying execution, and confirming the active schedule.
- Workspace & Engineering: Inspecting, editing, refactoring, and managing code, configurations, data files, and deliverables.
- System Execution & Diagnostics: Running test suites, verifying build gates, inspecting processes, checking system vitals, and sandboxed execution.
- Synthesis & Direct In-Session Delivery: Synthesizing findings, answering inquiries, and presenting final deliverables directly to the operator in the active session. External messaging or alerts (e.g. Discord, webhooks) are used ONLY when the user's prompt explicitly requests external dispatch.

Milestone Formulation Guidelines:
- Express milestones as high-level, actionable objectives reflective of what the user is asking to achieve.
- Do NOT prescribe specific leaf tool names (e.g., do NOT write "call tool_search" or "call web_fetch" or "call discord_send"), EXCEPT for SDR scanner and Cardano trading workflows noted below.
- For police, fire, EMS, sheriff, dispatch, talkgroup, radio unit, or SDR scanner inquiries (e.g., "what happened on the police or EMS scanner today?", "check County EMS or Metro PD", "what did unit 7100001 do?"), decompose Step 1 into querying the local Sovereign P25 SDR radio intelligence database (`sdr_query`, and `sdr_listen` if audio playback/re-analysis is requested) and Step 2 into synthesizing and presenting the findings in-session. NEVER tell the agent to search external web news for local scanner traffic.
- Milestones must be tailored directly to the operator's request—never use generic boilerplate or force cron job creation unless scheduled/recurring execution was explicitly requested.
- For research, analysis, vision inspection, trading, and conversational questions, always begin the final milestone with "Synthesize and present..." (e.g., "Synthesize observations and present final response in-session"). Never phrase an in-session reply as "Deliver in-channel response" or "Post reply to channel" unless the user explicitly requested messaging a different channel or external recipient.
- For Cardano / crypto trade planning requests, decompose into: (1) Review live wallet state and scan pool signals, (2) Build policy-checked trade plan via crypto_plan, and (3) Present the proposed plan ID to the operator for confirmation (or execute immediately if Tier A). Never add a separate milestone to execute a Tier B buy plan before operator confirmation.
- Generate between 1 and 6 milestone items based on the true complexity of the request (1 item for pure conversational chat requiring no tools; 2 to 6 items for tasks requiring inspection, research, code, or ops tools).

Output ONLY valid JSON matching this schema:
{"task_type": "chat"|"code"|"research"|"ops", "items": [{"id": 1, "task": "<specific actionable objective>", "tier": 1, "depends_on": []}]}"""

    conv_hist = os.environ.get("REACT_CONVERSATION_HISTORY", "").strip()
    if conv_hist:
        user_prompt = f"Recent Conversation Context:\n{conv_hist[-1500:]}\n\nObjective: {task}"
    else:
        user_prompt = f"Objective: {task}"

    # Option C: Adaptive Thinking Mode
    # Pure conversational / social chat comes off-the-cuff (thinking disabled, fast 4-8s).
    # Complex engineering, research, and ops objectives enable thinking for deep DAG decomposition.
    pre_cls = classify_task(task + ("\n" + conv_hist[-800:] if conv_hist else ""))
    enable_thinking = (pre_cls != "chat")
    temp = 0.7 if pre_cls == "chat" else 1.0
    max_toks = 1024 if pre_cls == "chat" else 8192

    payload = {
        "messages": [
            {"role": "system", "content": sys_prompt},
            {"role": "user", "content": user_prompt}
        ],
        "temperature": temp,
        "max_tokens": max_toks,
        "presence_penalty": 0.0,
        "chat_template_kwargs": {"enable_thinking": enable_thinking},
        "stream": False
    }

    grammar = _load_grammar()
    if grammar:
        payload["grammar"] = grammar

    url = f"{endpoint_url.rstrip('/')}/v1/chat/completions"
    req = urllib.request.Request(
        url,
        headers={"Content-Type": "application/json"},
        data=json.dumps(payload).encode("utf-8")
    )

    call_timeout = int(os.environ.get("HONEYDEW_TIMEOUT", os.environ.get("LLM_TIMEOUT", "600")))

    try:
        with urllib.request.urlopen(req, timeout=call_timeout) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            msg = data.get("choices", [{}])[0].get("message", {})
            content = msg.get("content", "")
            reasoning = msg.get("reasoning_content", "")

            # First attempt: parse content
            parsed = clean_and_parse(content, original_task=task)
            if parsed:
                return parsed

            # Second attempt: check reasoning_content
            if reasoning:
                parsed = clean_and_parse(reasoning, original_task=task)
                if parsed:
                    return parsed

            # Third attempt: combined
            combined = (reasoning + "\n" + content).strip()
            return clean_and_parse(combined, original_task=task)
    except Exception as e:
        sys.stderr.write(f"[Honeydew Strategist] LLM endpoint call failed ({endpoint_url}): {e}\n")
        return None

_WRAPPER_RE = re.compile(r"\[(?:ACTIVE PRIMARY OBJECTIVE[^\]]*|Current Inbound Message from [^\]]*)\]:?", re.I)


def _objective_text(task):
    """Strip session wrapper headers (e.g. '[Current Inbound Message from @x]:')
    so their boilerplate words never drive plan classification."""
    t = task.replace("\\n", "\n")
    return _WRAPPER_RE.sub(" ", t)


def _kw(lower, words):
    """Whole-word keyword match. A trailing '*' allows a stem ('emulat*').
    Substring matching misrouted plans ('from' -> 'rom' -> gaming dossier)."""
    for w in words:
        stem = w.endswith("*")
        w = w.rstrip("*")
        if stem:
            tail = r""
        else:
            # allow simple inflections: report(s|ed|ing), schedule(d|s)
            tail = (r"(?:s|d|r)?" if w.endswith("e") else r"(?:s|es|ed|ing)?") + r"(?![a-z0-9])"
        pat = r"(?<![a-z0-9])" + re.escape(w) + tail
        if re.search(pat, lower):
            return True
    return False


def classify_task(task):
    """Deterministically classify task into one of: chat, code, research, ops."""
    lower = _objective_text(task).lower().strip()

    # 1. Chat / Social: greetings, thanks, pleasantries, conversational acknowledgements
    if re.search(r'^\s*(hi|hello|hey|gm|gn|thanks|thank you|thx|ty|cheers|appreciate it|good job|great job|good morning|good evening|good night|how are you|who are you|what\'?s up|sup|nice to meet you|ok|okay|got it|sounds good)\b', lower) \
       or _kw(lower, ["thank you", "thanks", "thx", "appreciate it"]):
        if not _kw(lower, ["repo", "codebase", "script", "test", "patch", "commit", "pr", "pull request", "build", "cargo", "pytest", "bug", "cron", "service", "daemon", "docker", "pipeline", "ada", "cardano", "arbitrage", "dex", "trade", "swap", "scanner", "sdr", "talkgroup", "p25"]):
            return "chat"

    # 1.5 Sovereign P25 SDR Radio Scanner Lab
    if _kw(lower, ["scanner", "sdr", "p25", "talkgroup", "tgid", "county ems", "metro pd", "metro fire", "city fire", "county", "county", "radio unit", "m4a"]):
        return "research"

    # 2. Crypto / Market Analysis / DEX Trading / Financial Research
    if _kw(lower, ["ada", "cardano", "arbitrage", "dex", "minswap", "sundae", "vyfi", "orderbook", "spread", "maker", "taker", "swap pair", "trading play", "play", "what is your play", "liquidity", "yield", "token", "coin", "crypto", "defi", "hedging", "slippage", "corridor"]):
        return "research"

    # 3. Code: development, bugs, refactoring, implementation, testing, git
    if _kw(lower, ["refactor", "bug", "failing", "error", "stack trace", "crash", "compile", "cargo", "pytest", "npm", "git checkout", "git commit", "pull request", "pr", "branch", "patch", "unit test"]) \
       or (_kw(lower, ["implement", "code", "write", "develop", "create", "modify", "fix", "update", "add"]) and _kw(lower, ["function", "class", "method", "module", "script", "file", "endpoint", "api", "test", "rust", "python", "bash", "repo", "codebase", "library"])):
        return "code"

    # 4. Ops: cron, daemon, system vitals, status, culling, sweeps, background services, digest
    if _kw(lower, ["cron", "schedule", "recurring", "daemon", "systemctl", "sweep", "cull", "vitals", "process", "kill", "restart", "osint digest", "hourly digest", "digest", "living tissue", "sentinel"]):
        return "ops"

    # 5. Research: investigations, due diligence, academic search, metrics, analysis, reports
    if _kw(lower, ["research", "investigate", "study", "dossier", "search", "arxiv", "paper", "sec filing", "10-k", "earnings", "valuation", "emulat*", "decompil*", "metric", "deep dive", "fact check", "news", "status of", "overview of"]):
        return "research"

    # Conversational questions without code/ops/research intent
    if re.search(r'^(how|what|why|who|where|when|are you|can you tell me|do you know)\b', lower) and len(lower) < 150:
        return "chat"

    return "ops"


def fallback_heuristic_plan(task):
    lower = _objective_text(task).lower()
    # 0. Secret-exfiltration / destructive / instruction-override requests
    if re.search(r'\b(leak|reveal|dump|print|show|expose|give me|what is (the|your))\s+(system\s+prompt|keys\.conf|api\s+key)\b', lower) \
       or _kw(lower, ["ignore all previous", "ignore previous instructions", "maintenance mode", "rm -rf", "delete all", "drop table"]):
        return [
            {"id": 1, "task": "Assess the request against operator security policy (no secret disclosure, no destructive commands on third-party authority)", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0, "task_type": "chat"},
            {"id": 2, "task": "Reply to the requester directly with a brief refusal and any safe alternative", "status": "pending", "tier": 2, "depends_on": [1], "endpoint_tier": 1, "retry_count": 0, "task_type": "chat"}
        ]
    # 0.1 Conversational greetings, gratitude, and social chat
    if re.search(r'^\s*(thanks|thank you|thx|ty|cheers|appreciate it|good job|great job|hi|hello|hey|gm|gn|good morning|good evening|good night|sup|yo|ok|okay|sounds good|understood|got it|perfect)\b', lower) \
       or (_kw(lower, ["thanks", "thank you", "thx", "how are you", "who are you"]) and not _kw(lower, ["investigate", "fix", "code", "test", "cron", "patch", "build", "script", "repo"])):
        return [
            {"id": 1, "task": "Acknowledge message and respond with polite, helpful conversational response", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0, "task_type": "chat"}
        ]
    # 0.5 Research Artifact Refinement & Verification Gate Resolution
    if ((_kw(lower, ["refining", "refine"]) and _kw(lower, ["draft", "dossier", "thread", "monograph", "gate", "trace", "violation", "artifact"]))
            or _kw(lower, ["grounding verification", "verification gate", "rejection trace"])):
        return [
            {"id": 1, "task": "Inspect flagged violations in draft and compare against evidence ledger", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0, "task_type": "research"},
            {"id": 2, "task": "Verify contested equations, bounds, and citations using calculation and search tools", "status": "pending", "tier": 2, "depends_on": [1], "endpoint_tier": 1, "retry_count": 0, "task_type": "research"},
            {"id": 3, "task": "Apply surgical patch to draft using file_edit without truncating document structure", "status": "pending", "tier": 3, "depends_on": [2], "endpoint_tier": 1, "retry_count": 0, "task_type": "research"},
            {"id": 4, "task": "Verify document integrity, resolve residual issues, and complete refinement milestone", "status": "pending", "tier": 4, "depends_on": [3], "endpoint_tier": 1, "retry_count": 0, "task_type": "research"}
        ]
    # 0.6 Hourly OSINT Intel Digest
    if _kw(lower, ["hourly osint", "osint digest", "osint intel", "intel digest", "hourly digest"]):
        return [
            {"id": 1, "task": "Read captured OSINT feed, curate key stories under character cap, and deliver digest to operator Discord DM", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0, "task_type": "ops"}
        ]
    # 0.7 Sovereign P25 SDR Radio Scanner Lab
    if _kw(lower, ["scanner", "sdr", "p25", "talkgroup", "tgid", "county ems", "metro pd", "metro fire", "city fire", "county", "county", "radio unit", "m4a"]):
        return [
            {"id": 1, "task": "Query the local Sovereign P25 SDR radio intelligence database using sdr_query (and sdr_listen if audio encoder analysis is requested) for today's dispatches, talkgroups, units, and summary statistics", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0, "task_type": "research"},
            {"id": 2, "task": "Synthesize and present the SDR radio scanner activity, key incidents, and unit narratives in-session", "status": "pending", "tier": 2, "depends_on": [1], "endpoint_tier": 1, "retry_count": 0, "task_type": "research"}
        ]
    # 0.8 Cardano / Crypto / DEX Arbitrage / Trading Play requests
    if _kw(lower, ["ada", "cardano", "arbitrage", "dex", "minswap", "sundae", "vyfi", "orderbook", "spread", "maker", "taker", "swap pair", "trading play", "what is your play", "trade play", "liquidity pool"]):
        return [
            {"id": 1, "task": "Inspect live market prices, liquidity pool depths, and orderbook spreads across target DEXs and pairs", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0, "task_type": "research"},
            {"id": 2, "task": "Evaluate pricing dislocations, inventory balance, execution risk, and net expected value", "status": "pending", "tier": 2, "depends_on": [1], "endpoint_tier": 1, "retry_count": 0, "task_type": "research"},
            {"id": 3, "task": "Synthesize concrete trade recommendations or resting limit order strategy and deliver decisive play to operator", "status": "pending", "tier": 3, "depends_on": [2], "endpoint_tier": 1, "retry_count": 0, "task_type": "research"}
        ]
    # 1. Diagnostic / Troubleshooting / Fix requests
    if _kw(lower, ["investigate", "fix", "debug", "culled", "orphan", "heartbeat", "why", "error", "failing"]):
        return [
            {"id": 1, "task": "Inspect logs, process table, and relevant script configurations in workspace", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0, "task_type": "ops"},
            {"id": 2, "task": "Analyze failure root cause (heartbeat, timeout, culling, or lock contention)", "status": "pending", "tier": 2, "depends_on": [1], "endpoint_tier": 1, "retry_count": 0, "task_type": "ops"},
            {"id": 3, "task": "Apply surgical fix and test manual execution to confirm resolution", "status": "pending", "tier": 3, "depends_on": [2], "endpoint_tier": 1, "retry_count": 0, "task_type": "ops"},
            {"id": 4, "task": "Verify operational stability and report findings to operator", "status": "pending", "tier": 4, "depends_on": [3], "endpoint_tier": 1, "retry_count": 0, "task_type": "ops"}
        ]
    elif (_kw(lower, ["cron", "schedule", "recurring", "daily", "every 24", "twice a day"]) and _kw(lower, ["research", "intel", "report", "news", "release", "finding", "announcement", "sweep"])) or _kw(lower, ["financial intel", "healthcare", "insurance", "research cron", "recurring report"]):
        return [
            {"id": 1, "task": "Create recurring research cron job script in .george/cron_jobs/ with deterministic research_sandbox runner", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0, "task_type": "ops"},
            {"id": 2, "task": "Execute initial verification run in isolated sandbox with creative non-greedy cross-section article retrieval and evidence synthesis", "status": "pending", "tier": 2, "depends_on": [1], "endpoint_tier": 1, "retry_count": 0, "task_type": "ops"},
            {"id": 3, "task": "Synthesize operational verification and deliver active recurring research schedule confirmation to operator", "status": "pending", "tier": 3, "depends_on": [2], "endpoint_tier": 1, "retry_count": 0, "task_type": "ops"}
        ]
    elif _kw(lower, ["vitals and git", "git and vitals", "system vitals and git repo", "vitals in parallel"]):
        return [
            {"id": 1, "task": "Inspect system vitals and hardware resource utilization", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0, "task_type": "ops"},
            {"id": 2, "task": "Inspect git repository status and branch state", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 2, "retry_count": 0, "task_type": "ops"},
            {"id": 3, "task": "Synthesize findings from both parallel inspections into overall readiness report", "status": "pending", "tier": 2, "depends_on": [1, 2], "endpoint_tier": 1, "retry_count": 0, "task_type": "ops"}
        ]
    elif _kw(lower, ["cron", "schedule", "recurring"]):
        return [
            {"id": 1, "task": "Implement tailored cron script in .george/cron_jobs/ for scheduled objective", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0, "task_type": "ops"},
            {"id": 2, "task": "Verify cron script permissions, interval headers, and test execution via bash_exec", "status": "pending", "tier": 2, "depends_on": [1], "endpoint_tier": 1, "retry_count": 0, "task_type": "ops"},
            {"id": 3, "task": "Synthesize operational verification and deliver active cron job status to operator", "status": "pending", "tier": 3, "depends_on": [2], "endpoint_tier": 1, "retry_count": 0, "task_type": "ops"}
        ]
    elif _kw(lower, ["live test", "run test", "execute test", "test run", "test the cron", "run a test"]):
        return [
            {"id": 1, "task": "Locate target script or test harness in workspace", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0, "task_type": "ops"},
            {"id": 2, "task": "Execute live test run and inspect terminal output via bash_exec", "status": "pending", "tier": 2, "depends_on": [1], "endpoint_tier": 1, "retry_count": 0, "task_type": "ops"},
            {"id": 3, "task": "Synthesize execution verification and report outcome to operator", "status": "pending", "tier": 3, "depends_on": [2], "endpoint_tier": 1, "retry_count": 0, "task_type": "ops"}
        ]
    elif _kw(lower, ["research", "report", "investigate", "search", "arxiv", "paper", "academic", "quantization", "quant", "study", "dossier", "find", "background"]):
        return [
            {"id": 1, "task": "Execute search and fetch deep context from live sources or local docs", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0, "task_type": "research"},
            {"id": 2, "task": "Record findings and distilled facts into working memory (mem:active_task)", "status": "pending", "tier": 2, "depends_on": [1], "endpoint_tier": 1, "retry_count": 0, "task_type": "research"},
            {"id": 3, "task": "Synthesize comprehensive, evidence-backed final report for operator", "status": "pending", "tier": 3, "depends_on": [2], "endpoint_tier": 1, "retry_count": 0, "task_type": "research"}
        ]
    elif _kw(lower, ["system status", "living tissue", "phytology", "health check", "system vitals", "service status"]):
        return [
            {"id": 1, "task": "Inspect system status, living tissue manifest, or diagnostics using domain getter tools", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0, "task_type": "ops"},
            {"id": 2, "task": "Synthesize diagnostic observations and deliver structured status report to operator", "status": "pending", "tier": 2, "depends_on": [1], "endpoint_tier": 1, "retry_count": 0, "task_type": "ops"}
        ]
    elif _kw(lower, ["edit", "modify", "update", "patch", "fix", "refactor", "change", "add"]):
        return [
            {"id": 1, "task": "Locate and inspect target code and verified state in workspace", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0, "task_type": "code"},
            {"id": 2, "task": "Apply surgical code modification or write updated content in place", "status": "pending", "tier": 2, "depends_on": [1], "endpoint_tier": 1, "retry_count": 0, "task_type": "code"},
            {"id": 3, "task": "Verify syntax, run test harness, and confirm zero regressions", "status": "pending", "tier": 3, "depends_on": [2], "endpoint_tier": 1, "retry_count": 0, "task_type": "code"}
        ]
    elif _kw(lower, ["emulat*", "decompil*", "game", "games", "gaming", "recompiler", "jit", "rom", "roms", "disassembly", "retroarch"]):
        return [
            {"id": 1, "task": "Investigate emulation architecture, hardware specs, and decompilation codebases", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0, "task_type": "research"},
            {"id": 2, "task": "Extract hardware execution bounds, cycle accuracy requirements, and JIT/assembly mechanics", "status": "pending", "tier": 2, "depends_on": [1], "endpoint_tier": 1, "retry_count": 0, "task_type": "research"},
            {"id": 3, "task": "Synthesize comprehensive technical gaming/emulation dossier with verified code & citations", "status": "pending", "tier": 3, "depends_on": [2], "endpoint_tier": 1, "retry_count": 0, "task_type": "research"}
        ]
    elif _kw(lower, ["finance", "financial", "stock", "stocks", "invest", "investing", "investment*", "investor*", "crypto*", "defi", "earnings", "revenue", "10-k", "valuation"]):
        return [
            {"id": 1, "task": "Retrieve SEC filings, earnings reports, or protocol whitepapers and capital structures", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0, "task_type": "research"},
            {"id": 2, "task": "Extract financial metrics, revenue trajectories, margins, and valuation multiples into scratchpad", "status": "pending", "tier": 2, "depends_on": [1], "endpoint_tier": 1, "retry_count": 0, "task_type": "research"},
            {"id": 3, "task": "Synthesize comprehensive financial intelligence dossier with empirical metrics and filings", "status": "pending", "tier": 3, "depends_on": [2], "endpoint_tier": 1, "retry_count": 0, "task_type": "research"}
        ]
    elif _kw(lower, ["sport", "football", "soccer", "basketball", "nfl", "nba", "car", "cars", "automotive", "engine", "porsche", "ferrari"]):
        return [
            {"id": 1, "task": "Gather official technical specs, performance statistics, and depth charts from primary sources", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0, "task_type": "research"},
            {"id": 2, "task": "Analyze tactical schemes, engineering dynamics, and benchmark measurements into scratchpad", "status": "pending", "tier": 2, "depends_on": [1], "endpoint_tier": 1, "retry_count": 0, "task_type": "research"},
            {"id": 3, "task": "Synthesize authoritative analytical report with empirical metrics and primary citations", "status": "pending", "tier": 3, "depends_on": [2], "endpoint_tier": 1, "retry_count": 0, "task_type": "research"}
        ]
    elif _kw(lower, ["status", "inspect", "check", "audit", "verify", "view"]):
        return [
            {"id": 1, "task": "Inspect target state or diagnostics using domain getter tools", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0, "task_type": "ops"},
            {"id": 2, "task": "Synthesize diagnostic observations and deliver structured status report to operator", "status": "pending", "tier": 2, "depends_on": [1], "endpoint_tier": 1, "retry_count": 0, "task_type": "ops"}
        ]
    else:
        return [
            {"id": 1, "task": "Execute targeted action to fulfill the objective", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0, "task_type": "ops"},
            {"id": 2, "task": "Synthesize results and deliver final response to operator", "status": "pending", "tier": 2, "depends_on": [1], "endpoint_tier": 1, "retry_count": 0, "task_type": "ops"}
        ]

def expand_honeydew_plan(task, hd_file, macro_file, scratchpad_file, endpoint_url="http://127.0.0.1:8080"):
    import os
    hd_data = {}
    if os.path.exists(hd_file):
        try:
            with open(hd_file, "r") as f:
                hd_data = json.load(f)
        except Exception:
            pass

    items = hd_data.get("items", [])
    if not items:
        return {"items": []}

    scratch_text = ""
    if os.path.exists(scratchpad_file):
        try:
            with open(scratchpad_file, "r") as f:
                scratch_text = f.read()
        except Exception:
            pass

    macro_data = {}
    if os.path.exists(macro_file):
        try:
            with open(macro_file, "r") as f:
                macro_data = json.load(f)
        except Exception:
            pass

    completed_summaries = [
        m.get("summary", "") for m in macro_data.get("completed_milestones", []) if isinstance(m, dict)
    ]
    all_evidence = scratch_text + "\n" + "\n".join(completed_summaries)
    lower_evidence = all_evidence.lower()

    # Heuristic & LLM-guided DAG expansion / auto-satisfaction
    modified = False
    for item in items:
        if item.get("status") == "pending":
            task_desc = item.get("task", "")
            lower_task = task_desc.lower()

            # Cross-satisfaction checks:
            # 1. Elevance / Anthem identity
            if ("anthem" in lower_task or "elevance" in lower_task) and ("elevance" in lower_evidence and "revenue" in lower_evidence):
                item["status"] = "done"
                item["resolution"] = "Satisfied by Elevance Health findings in scratchpad"
                modified = True

    # Dynamic Trajectory Pivot:
    # Only insert an adaptive remediation milestone if macro_data records an explicit action failure
    # or completed milestone summaries contain verified execution/system errors.
    # NEVER trigger on domain research notes in scratchpad.md!
    has_exec_error = False
    if macro_data.get("failed_actions") and len(macro_data.get("failed_actions", [])) > 0:
        has_exec_error = True
    else:
        summaries_text = "\n".join(completed_summaries).lower()
        if any(err_pat in summaries_text for err_pat in [
            "command not found", "permission denied", "deadlock detected",
            "connection refused", "fatal: unable to", "tool execution failed", "exit code 127"
        ]):
            has_exec_error = True

    if has_exec_error:
        has_remediation = any("remediat" in it.get("task", "").lower() or "fix" in it.get("task", "").lower() or "diagnos" in it.get("task", "").lower() for it in items if it.get("status") != "done")
        if not has_remediation and len(items) < 6:
            max_id = max((it.get("id", 0) for it in items), default=0)
            pivot_step = {
                "id": max_id + 1,
                "task": "Remediate discovered execution blocker and verify operational fix",
                "status": "pending",
                "tier": len(items) + 1,
                "depends_on": [it["id"] for it in items if it.get("status") == "done"],
                "endpoint_tier": 1,
                "retry_count": 0
            }
            if len(items) > 1 and any(k in items[-1].get("task", "").lower() for k in ["synthesize", "deliver", "final report"]):
                items.insert(-1, pivot_step)
            else:
                items.append(pivot_step)
            modified = True

    # Ensure at least one pending step exists if not all done
    pending_items = [it for it in items if it.get("status") != "done"]
    if not pending_items and items:
        # Only append synthesis if no completed step already synthesized/delivered the report or was a chat turn
        has_completed_synthesis = (
            hd_data.get("task_type") == "chat"
            or any(
                it.get("task_type") == "chat"
                or any(k in it.get("task", "").lower() for k in ["synthesize", "deliver", "final report", "dossier", "conclude", "conversational response", "acknowledge message"])
                for it in items if it.get("status") == "done"
            )
        )
        if not has_completed_synthesis:
            items.append({
                "id": len(items) + 1,
                "task": "Synthesize comprehensive, evidence-backed final report for operator",
                "status": "pending",
                "tier": len(items) + 1,
                "depends_on": [len(items)],
                "endpoint_tier": 1,
                "retry_count": 0
            })
            modified = True

    hd_data["items"] = items
    if modified:
        try:
            with open(hd_file, "w") as f:
                json.dump(hd_data, f, indent=2)
        except Exception:
            pass

    return hd_data

def main():
    if len(sys.argv) < 2:
        sys.exit(1)

    if sys.argv[1] == "--expand":
        task = sys.argv[2] if len(sys.argv) > 2 else ""
        hd_file = sys.argv[3] if len(sys.argv) > 3 else ".george/honeydew.json"
        macro_file = sys.argv[4] if len(sys.argv) > 4 else ".george/macro_memory.json"
        scratchpad_file = sys.argv[5] if len(sys.argv) > 5 else ".george/scratchpad.md"
        endpoint_url = sys.argv[6] if len(sys.argv) > 6 else "http://127.0.0.1:8080"
        result = expand_honeydew_plan(task, hd_file, macro_file, scratchpad_file, endpoint_url)
        print(json.dumps(result.get("items", [])))
        return

    task = sys.argv[1].strip()
    endpoint_url = sys.argv[2].strip() if len(sys.argv) > 2 else "http://127.0.0.1:8080"

    parsed = query_strategist_endpoint(task, endpoint_url)

    items = []
    task_type = classify_task(task)
    source = "heuristic"
    if parsed and isinstance(parsed.get("items"), list) and (len(parsed["items"]) >= 2 or (len(parsed["items"]) == 1 and parsed.get("task_type") == "chat")):
        source = "llm"
        task_type = parsed.get("task_type", task_type)
        raw_items = parsed["items"]
        for idx, item in enumerate(raw_items):
            if isinstance(item, dict):
                t_str = str(item.get("task", "")).strip().rstrip('",').strip()
                tier = int(item.get("tier", idx + 1)) if str(item.get("tier", "")).isdigit() else (idx + 1)
                deps = []
                for d in item.get("depends_on", []):
                    if isinstance(d, int):
                        deps.append(d)
                    elif isinstance(d, str) and d.isdigit():
                        deps.append(int(d))
                    elif isinstance(d, dict) and "id" in d and str(d["id"]).isdigit():
                        deps.append(int(d["id"]))
            elif isinstance(item, str):
                t_str = item.strip()
                tier = idx + 1
                deps = [idx] if idx > 0 else []
            else:
                t_str = "Execute milestone"
                tier = idx + 1
                deps = []

            items.append({
                "id": idx + 1,
                "task": t_str,
                "status": "pending",
                "tier": tier,
                "depends_on": deps,
                "endpoint_tier": 1,
                "retry_count": 0,
                "task_type": task_type
            })
        # If task_type is pure 'chat' and none of the items require tool/inspection actions,
        # collapse multi-part conversational phrasing steps into a single synthesis milestone
        # so the agent writes its reply directly on Turn 1 without stepping through a multi-turn DAG.
        if task_type == "chat" and len(items) > 1:
            _tool_re = re.compile(
                r"\b(inspect|analyze|vision|image|photo|picture|attachment|search|fetch|scrape|read|check|verify|run|test|execute|create|build|write|modify|patch|refactor|edit|commit|push|review|scan|locate|download|query)\b",
                re.I,
            )
            if not any(_tool_re.search(it.get("task", "")) for it in items):
                combined_desc = "; ".join(it.get("task", "") for it in items if it.get("task"))
                items = [{
                    "id": 1,
                    "task": f"Synthesize and present conversational response: {combined_desc}",
                    "status": "pending",
                    "tier": 1,
                    "depends_on": [],
                    "endpoint_tier": 1,
                    "retry_count": 0,
                    "task_type": "chat"
                }]
    else:
        items = fallback_heuristic_plan(task)
        if items and "task_type" in items[0]:
            task_type = items[0]["task_type"]

    print(json.dumps({"task_type": task_type, "source": source, "items": items}))

if __name__ == "__main__":
    main()

