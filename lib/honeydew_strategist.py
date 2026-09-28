#!/usr/bin/env python3
"""
Honeydew DAG Strategist (Option 4A)
Decomposes an arbitrary operator objective into a structured DAG execution plan
tailored to Blue Lodge's native bedrock capabilities and flow-control protocol.
"""

import sys
import json
import re
import urllib.request
import urllib.error

def clean_and_parse(text):
    if not text:
        return None
    # Strip think tags if present
    text = re.sub(r'<think>.*?</think>', '', text, flags=re.DOTALL)
    # Strip markdown code blocks
    text = re.sub(r'^```(?:json)?\s*', '', text.strip(), flags=re.MULTILINE)
    text = re.sub(r'```$', '', text.strip(), flags=re.MULTILINE)
    text = text.strip()

    # Find first '{' and last '}'
    text = re.sub(r'<think>.*?</think>', '', text, flags=re.DOTALL)
    start = text.find('{')
    end = text.rfind('}')
    if start != -1 and end != -1 and end > start:
        candidate = text[start:end+1]
    else:
        candidate = text

    # Attempt 1: Direct JSON parse
    try:
        data = json.loads(candidate)
        if isinstance(data, dict) and 'items' in data:
            return data
    except Exception:
        pass

    # Attempt 2: Clean trailing quotes and commas
    cleaned = re.sub(r'\"+,\s*\"+', '\",', candidate)
    cleaned = re.sub(r',\s*([\]}])', r'\1', cleaned)
    try:
        data = json.loads(cleaned)
        if isinstance(data, dict) and 'items' in data:
            return data
    except Exception:
        pass

    # Attempt 3: Regex extraction of task descriptions
    task_matches = re.findall(r'\"task\"\s*:\s*\"([^\"]+)\"', text)
    if task_matches and len(task_matches) >= 2:
        return {
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

Blue Lodge Bedrock Capabilities:
- Workspace & Files: file_read, file_write, file_edit, file_grep, dir_list (inspecting code, configs, reports, or deliverables).
- Execution & Terminal: bash_exec (running test suites, executing diagnostics, running build gates, checking processes, managing sandboxes).
- External Context & Comms: web_search_cross_section, web_fetch, discord_send, discord_dm, ask_operator.
- Coordination: subagent_spawn, milestone_complete, task_complete.

Guidelines:
- Generate between 2 and 6 milestone items based on the true complexity of the request.
- Every milestone task description MUST be specific, highly relevant, and directly actionable for this exact request.
- NEVER use generic boilerplate or force cron job creation unless the user explicitly requested a scheduled or recurring task.
- The final step should focus on verifying outcomes and synthesizing the final deliverable.

Output ONLY valid JSON matching this schema:
{"items": [{"id": 1, "task": "<specific actionable objective>", "tier": 1, "depends_on": []}]}"""

    user_prompt = f"Objective: {task}"

    payload = {
        "messages": [
            {"role": "system", "content": sys_prompt},
            {"role": "user", "content": user_prompt}
        ],
        "temperature": 0.1,
        "max_tokens": 1024,
        "presence_penalty": 0.15,
        "chat_template_kwargs": {"enable_thinking": False}
    }

    url = f"{endpoint_url.rstrip('/')}/v1/chat/completions"
    req = urllib.request.Request(
        url,
        headers={"Content-Type": "application/json"},
        data=json.dumps(payload).encode("utf-8")
    )

    try:
        with urllib.request.urlopen(req, timeout=35) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            content = data.get("choices", [{}])[0].get("message", {}).get("content", "")
            return clean_and_parse(content)
    except Exception as e:
        return None

def fallback_heuristic_plan(task):
    lower = task.lower()
    # 1. Diagnostic / Troubleshooting / Fix requests
    if any(k in lower for k in ["investigate", "fix", "debug", "culled", "orphan", "heartbeat", "why", "error", "failing"]):
        return [
            {"id": 1, "task": "Inspect logs, process table, and relevant script configurations in workspace", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0},
            {"id": 2, "task": "Analyze failure root cause (heartbeat, timeout, culling, or lock contention)", "status": "pending", "tier": 2, "depends_on": [1], "endpoint_tier": 1, "retry_count": 0},
            {"id": 3, "task": "Apply surgical fix and test manual execution to confirm resolution", "status": "pending", "tier": 3, "depends_on": [2], "endpoint_tier": 1, "retry_count": 0},
            {"id": 4, "task": "Verify operational stability and report findings to operator", "status": "pending", "tier": 4, "depends_on": [3], "endpoint_tier": 1, "retry_count": 0}
        ]
    elif any(k in lower for k in ["financial intel", "healthcare", "insurance", "twice a day", "research cron", "recurring report"]):
        return [
            {"id": 1, "task": "Create recurring research cron job script in .george/cron_jobs/ with deterministic sandbox runner", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0},
            {"id": 2, "task": "Execute initial verification run in isolated sandbox with creative non-greedy cross-section article retrieval and Discord delivery", "status": "pending", "tier": 2, "depends_on": [1], "endpoint_tier": 1, "retry_count": 0},
            {"id": 3, "task": "Synthesize operational verification and deliver active recurring research schedule confirmation to operator", "status": "pending", "tier": 3, "depends_on": [2], "endpoint_tier": 1, "retry_count": 0}
        ]
    elif any(k in lower for k in ["parallel", "both", "vitals and git", "git and vitals"]):
        return [
            {"id": 1, "task": "Inspect system vitals and hardware resource utilization", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0},
            {"id": 2, "task": "Inspect git repository status and branch state", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 2, "retry_count": 0},
            {"id": 3, "task": "Synthesize findings from both parallel inspections into overall readiness report", "status": "pending", "tier": 2, "depends_on": [1, 2], "endpoint_tier": 1, "retry_count": 0}
        ]
    elif any(k in lower for k in ["cron", "schedule", "recurring"]):
        return [
            {"id": 1, "task": "Implement tailored cron script in .george/cron_jobs/ for scheduled objective", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0},
            {"id": 2, "task": "Verify cron script permissions, interval headers, and test execution via bash_exec", "status": "pending", "tier": 2, "depends_on": [1], "endpoint_tier": 1, "retry_count": 0},
            {"id": 3, "task": "Synthesize operational verification and deliver active cron job status to operator", "status": "pending", "tier": 3, "depends_on": [2], "endpoint_tier": 1, "retry_count": 0}
        ]
    elif any(k in lower for k in ["live test", "run test", "execute test", "test run", "test the cron", "run a test"]):
        return [
            {"id": 1, "task": "Locate target script or test harness in workspace", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0},
            {"id": 2, "task": "Execute live test run and inspect terminal output via bash_exec", "status": "pending", "tier": 2, "depends_on": [1], "endpoint_tier": 1, "retry_count": 0},
            {"id": 3, "task": "Synthesize execution verification and report outcome to operator", "status": "pending", "tier": 3, "depends_on": [2], "endpoint_tier": 1, "retry_count": 0}
        ]
    elif any(k in lower for k in ["status", "inspect", "check", "phytology", "health", "audit", "verify", "view"]):
        return [
            {"id": 1, "task": "Inspect system status, living tissue manifest, or diagnostics using domain getter tools", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0},
            {"id": 2, "task": "Synthesize diagnostic observations and deliver structured status report to operator", "status": "pending", "tier": 2, "depends_on": [1], "endpoint_tier": 1, "retry_count": 0}
        ]
    elif any(k in lower for k in ["edit", "modify", "update", "patch", "fix", "refactor", "change", "add"]):
        return [
            {"id": 1, "task": "Locate and inspect target code and verified state in workspace", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0},
            {"id": 2, "task": "Apply surgical code modification or write updated content in place", "status": "pending", "tier": 2, "depends_on": [1], "endpoint_tier": 1, "retry_count": 0},
            {"id": 3, "task": "Verify syntax, run test harness, and confirm zero regressions", "status": "pending", "tier": 3, "depends_on": [2], "endpoint_tier": 1, "retry_count": 0}
        ]
    elif any(k in lower for k in ["research", "report", "investigate", "search", "find", "background"]):
        return [
            {"id": 1, "task": "Execute search and fetch deep context from live sources or local docs", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0},
            {"id": 2, "task": "Record findings and distilled facts into working memory (mem:active_task)", "status": "pending", "tier": 2, "depends_on": [1], "endpoint_tier": 1, "retry_count": 0},
            {"id": 3, "task": "Synthesize comprehensive, evidence-backed final report for operator", "status": "pending", "tier": 3, "depends_on": [2], "endpoint_tier": 1, "retry_count": 0}
        ]
    else:
        return [
            {"id": 1, "task": "Execute targeted action to fulfill the objective", "status": "pending", "tier": 1, "depends_on": [], "endpoint_tier": 1, "retry_count": 0},
            {"id": 2, "task": "Synthesize results and deliver final response to operator", "status": "pending", "tier": 2, "depends_on": [1], "endpoint_tier": 1, "retry_count": 0}
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
            # 2. Record findings into working memory - if scratchpad already has content
            elif "record findings" in lower_task or "working memory" in lower_task:
                if len(scratch_text.strip()) > 100:
                    item["status"] = "done"
                    item["resolution"] = "Satisfied by active scratchpad records"
                    modified = True
            # 3. Specific URL or paper inspection if already extracted
            elif "search" in lower_task and any(k in lower_task for k in ["results", "revenue", "status"]):
                # If scratchpad already has multiple citations or numeric metrics
                if re.search(r'\$\d+(\.\d+)?\s*(billion|million|B|M)', all_evidence) and len(re.findall(r'https?://', all_evidence)) >= 2:
                    # If this wasn't the final synthesis
                    if not any(k in lower_task for k in ["synthesize", "deliver", "final report"]):
                        item["status"] = "done"
                        item["resolution"] = "Core metrics and sources already captured"
                        modified = True

    # Dynamic Trajectory Pivot:
    # If recent evidence indicates an unexpected blocker/error, insert an adaptive remediation milestone
    if any(err_word in lower_evidence for err_word in ["command not found", "no such file", "permission denied", "deadlock", "timeout", "cull", "orphan", "failed"]):
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
        # Re-open or append final synthesis deliverable
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
    if parsed and isinstance(parsed.get("items"), list) and len(parsed["items"]) >= 2:
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
                "retry_count": 0
            })
    else:
        items = fallback_heuristic_plan(task)

    print(json.dumps(items))

if __name__ == "__main__":
    main()

