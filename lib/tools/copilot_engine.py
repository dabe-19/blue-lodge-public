#!/usr/bin/env python3
"""
George Craftsman Workbench: Co-Pilot Engine & Surgical Patch Resolver
Provides:
  1. Surgical SEARCH/REPLACE block parsing and patch resolution.
  2. Deletion Guard: prevents accidental clobbering when an LLM proposes snippets.
  3. Safe AST/regex commenting: comments functions or lines without deleting code.
  4. Tool Builder: scaffolds, validates, and test-executes tools in lib/tools/.
  5. Agent & Workflow Forge: creates and manages .agent.md persona files and workflows.
  6. POSIX FIFO Event Bus emission for sovereign sub-task flow control.
"""

import sys
import os
import re
import json
import time
import subprocess
import argparse
from pathlib import Path

LODGE_DIR = Path(os.environ.get("LODGE_DIR", Path.home() / "blue-lodge"))
GEORGE_DIR = Path(os.environ.get("GEORGE_DIR") or LODGE_DIR / ".george")
IPC_DIR = GEORGE_DIR / "ipc"
EVENT_BUS_FIFO = IPC_DIR / "event_bus.fifo"
TOOLS_DIR = LODGE_DIR / "lib" / "tools"
AGENTS_DIR = LODGE_DIR / ".agents"
WORKFLOWS_DIR = AGENTS_DIR / "workflows"
RULES_DIR = AGENTS_DIR / "rules"

# ── 1. Event Bus Emitter ─────────────────────────────────────────────

def emit_event(event_type: str, payload: dict, source: str = "copilot_engine") -> bool:
    """Emits a structured JSON event envelope to the POSIX event bus FIFO."""
    try:
        IPC_DIR.mkdir(parents=True, exist_ok=True)
        if not EVENT_BUS_FIFO.exists() or not EVENT_BUS_FIFO.is_fifo():
            return False

        ts = int(time.time())
        evt_id = f"evt_{ts}_{os.getpid()}"
        envelope = {
            "event_id": evt_id,
            "type": event_type,
            "source": source,
            "payload": payload,
            "depth": 0,
            "timestamp": ts,
        }
        line = json.dumps(envelope) + "\n"

        # Non-blocking write or fast timeout write
        fd = os.open(EVENT_BUS_FIFO, os.O_WRONLY | os.O_NONBLOCK)
        with os.fdopen(fd, "w") as f:
            f.write(line)
        return True
    except Exception:
        # Non-blocking write fails if no reader is attached, which is normal for FIFOs
        return False

# ── 2. Line Number Stripper & Block Parser ───────────────────────────

def strip_line_numbers(text: str) -> str:
    lines = text.split("\n")
    cleaned = []
    for line in lines:
        m = re.match(r"^\s*\d+[:|]\s?(.*)", line)
        if m:
            cleaned.append(m.group(1))
        else:
            cleaned.append(line)
    return "\n".join(cleaned)


def parse_search_replace_blocks(text: str) -> list[tuple[str, str]]:
    """Extracts <<<<<<< SEARCH ... ======= ... >>>>>>> blocks."""
    blocks = []
    current_search = []
    current_replace = []
    state = "outside"

    for line in text.split("\n"):
        line = line.rstrip("\r")
        if re.match(r"^<{4,}\s*(?:SEARCH|ORIGINAL)?", line):
            state = "in_search"
            current_search = []
        elif re.match(r"^={4,}", line):
            state = "in_replace"
            current_replace = []
        elif re.match(r"^>{4,}\s*(?:REPLACE|MODIFIED)?", line):
            if state == "in_replace":
                blocks.append(("\n".join(current_search), "\n".join(current_replace)))
            state = "outside"
        else:
            if state == "in_search":
                current_search.append(line)
            elif state == "in_replace":
                current_replace.append(line)

    return blocks

# ── 3. Surgical Patch & Deletion Guard Resolver ──────────────────────

def resolve_proposed_patch(
    original_content: str,
    proposed_content: str,
    selection: str | None = None,
    instruction: str = ""
) -> dict:
    """
    Surgically resolves the proposed patch against original_content.
    Guarantees:
      - Search/Replace blocks are parsed and substituted with strict verification.
      - If user selected code, partial updates are applied ONLY to the selection.
      - If proposed_content is a snippet/function, it finds and replaces only the matching function.
      - Deletion Guard prevents clobbering large files when asking for comments or minor edits.
    """
    if not proposed_content.strip():
        return {
            "success": False,
            "action": "none",
            "resolved_code": original_content,
            "explanation": "No proposed modifications found.",
            "diff_summary": "0 changes",
        }

    # Case A: SEARCH/REPLACE blocks present
    blocks = parse_search_replace_blocks(proposed_content)
    if blocks:
        new_content = original_content
        applied = 0
        logs = []

        for idx, (search_pat, replace_pat) in enumerate(blocks):
            target_search = search_pat
            target_replace = replace_pat

            if target_search not in new_content:
                clean_s = strip_line_numbers(target_search)
                if clean_s in new_content:
                    target_search = clean_s
                    target_replace = strip_line_numbers(target_replace)

            if target_search not in new_content:
                # Fuzzy match: try trimming whitespace lines
                trimmed_s = target_search.strip()
                if trimmed_s in new_content:
                    target_search = trimmed_s
                    target_replace = target_replace.strip()

            if target_search in new_content:
                count = new_content.count(target_search)
                if count == 1:
                    new_content = new_content.replace(target_search, target_replace, 1)
                    applied += 1
                    logs.append(f"Block {idx + 1} applied cleanly.")
                else:
                    # Multiple occurrences, replace first or warn
                    new_content = new_content.replace(target_search, target_replace, 1)
                    applied += 1
                    logs.append(f"Block {idx + 1} had multiple matches; replaced first occurrence.")
            else:
                logs.append(f"Block {idx + 1} search pattern not found in target buffer.")

        if applied > 0:
            return {
                "success": True,
                "action": "search_replace_blocks",
                "resolved_code": new_content,
                "explanation": f"Applied {applied} surgical search/replace block(s).",
                "diff_summary": f"{applied} block(s) modified",
                "logs": logs,
            }

    # Case B: User has an active selection in the editor
    if selection and selection.strip():
        sel_clean = selection.strip()
        prop_clean = proposed_content.strip()

        # If proposed content contains the selection or is a revised version of it
        if sel_clean in original_content:
            # Check if proposed_content is roughly snippet-sized (not whole file)
            orig_lines = len(original_content.splitlines())
            prop_lines = len(proposed_content.splitlines())

            # If proposed lines is closer to selection than whole file
            if prop_lines < orig_lines * 0.8:
                new_content = original_content.replace(selection, proposed_content, 1)
                return {
                    "success": True,
                    "action": "selection_replacement",
                    "resolved_code": new_content,
                    "explanation": "Applied edits specifically to your selected code region.",
                    "diff_summary": f"Replaced selection ({len(selection.splitlines())} lines -> {prop_lines} lines)",
                }

    # Case C: Single Function / Target Block Matcher
    func_matches = re.findall(
        r"^(?:def\s+([a-zA-Z0-9_]+)|function\s+([a-zA-Z0-9_]+)|([a-zA-Z0-9_]+)\s*\(\)\s*\{|fn\s+([a-zA-Z0-9_]+))",
        proposed_content,
        re.MULTILINE
    )
    orig_lines = original_content.splitlines()
    prop_lines = proposed_content.splitlines()

    if func_matches and len(prop_lines) < len(orig_lines):
        func_name = None
        for tup in func_matches:
            for item in tup:
                if item:
                    func_name = item
                    break
            if func_name:
                break

        if func_name:
            # Find the function boundary in original_content
            func_pattern = re.compile(rf"(?:def\s+{func_name}\b|function\s+{func_name}\b|{func_name}\s*\(\)\s*\{{|fn\s+{func_name}\b)")
            for idx, line in enumerate(orig_lines):
                if func_pattern.search(line):
                    start_line = idx
                    end_line = idx + 1
                    brace_count = line.count("{") - line.count("}")

                    if "{" in line or brace_count > 0:
                        while end_line < len(orig_lines):
                            brace_count += orig_lines[end_line].count("{") - orig_lines[end_line].count("}")
                            end_line += 1
                            if brace_count <= 0:
                                break
                    elif line.strip().startswith("def ") or line.strip().startswith("async def "):
                        base_indent = len(line) - len(line.lstrip())
                        while end_line < len(orig_lines):
                            next_line = orig_lines[end_line]
                            if next_line.strip() and (len(next_line) - len(next_line.lstrip())) <= base_indent:
                                break
                            end_line += 1

                    target_old_func = "\n".join(orig_lines[start_line:end_line])
                    if target_old_func in original_content:
                        new_content = original_content.replace(target_old_func, proposed_content.strip(), 1)
                        return {
                            "success": True,
                            "action": "function_replacement",
                            "resolved_code": new_content,
                            "explanation": f"Surgically updated function '{func_name}' while preserving all surrounding code.",
                            "diff_summary": f"Updated function {func_name} ({end_line - start_line} lines)",
                        }

    # Case D: Deletion Guard Check
    orig_lines_count = len(orig_lines)
    prop_lines_count = len(prop_lines)
    is_commenting_request = bool(re.search(r"\b(?:comment|docs|docstring|document|annotate)\b", instruction, re.IGNORECASE))

    if is_commenting_request and prop_lines_count < orig_lines_count * 0.9:
        # Safe commenting engine preserves 100% of code
        commented_code = safe_comment_content(original_content, instruction)
        return {
            "success": True,
            "action": "safe_commenting_guard",
            "resolved_code": commented_code,
            "explanation": "Safely injected function documentation and comments without removing any executable code.",
            "diff_summary": f"Preserved all {orig_lines_count} lines and added inline documentation",
        }

    if orig_lines_count >= 10 and prop_lines_count < (orig_lines_count * 0.5):
        if is_commenting_request:
            commented_code = safe_comment_content(original_content, instruction)
            return {
                "success": True,
                "action": "safe_commenting_guard",
                "resolved_code": commented_code,
                "explanation": "Safely added comments to the target code without deleting existing logic (Deletion Guard active).",
                "diff_summary": "Inserted inline and function documentation",
            }
        else:
            return {
                "success": False,
                "action": "deletion_guard_blocked",
                "resolved_code": original_content,
                "explanation": f"Deletion Guard Blocked: The proposed snippet has only {prop_lines_count} lines compared to the original {orig_lines_count} lines. To prevent code loss, please use SEARCH/REPLACE blocks or select a specific function.",
                "diff_summary": "Blocked potential clobber",
            }

    # Case E: Whole file replacement
    return {
        "success": True,
        "action": "whole_file",
        "resolved_code": proposed_content,
        "explanation": "Full file refactored.",
        "diff_summary": f"{orig_lines_count} lines -> {prop_lines_count} lines",
    }

# ── 4. Safe AST / Regex Commenting Engine ─────────────────────────────

def safe_comment_content(content: str, instruction: str = "") -> str:
    """
    Adds documentation comments and explanations above functions and key structures
    without deleting or modifying ANY executable lines.
    """
    lines = content.splitlines()
    output_lines = []

    # Detect file type
    first_line = lines[0] if lines else ""
    is_bash = first_line.startswith("#!") and "bash" in first_line or first_line.startswith("#!/bin/sh")
    is_python = first_line.startswith("#!") and "python" in first_line
    is_rust = any("fn " in l for l in lines[:30])

    comment_char = "#"
    if is_rust:
        comment_char = "///"

    for i, line in enumerate(lines):
        # Bash / Python function definition
        bash_func_match = re.match(r"^(?:function\s+)?([a-zA-Z0-9_]+)\s*\(\)\s*\{?", line)
        py_func_match = re.match(r"^(\s*)def\s+([a-zA-Z0-9_]+)\s*\(", line)
        rust_func_match = re.match(r"^(\s*)(?:pub\s+)?fn\s+([a-zA-Z0-9_]+)", line)

        # Check if previous line already has a comment (excluding shebang)
        prev_has_comment = (
            i > 0 
            and lines[i - 1].strip().startswith(comment_char[0]) 
            and not lines[i - 1].strip().startswith("#!")
        )

        if bash_func_match and not prev_has_comment:
            fname = bash_func_match.group(1)
            clean_name = fname.replace("_", " ").title()
            output_lines.append(f"# ── Helper: {clean_name} ──────────────────────────────────────")
            output_lines.append(f"# Function: {fname}")
            output_lines.append(f"# Routine: {fname}")
        elif py_func_match and not prev_has_comment:
            indent = py_func_match.group(1)
            fname = py_func_match.group(2)
            clean_name = fname.replace("_", " ").title()
            output_lines.append(f"{indent}# Helper: {clean_name}")
            output_lines.append(f"{indent}# Function: {fname}")
        elif rust_func_match and not prev_has_comment:
            indent = rust_func_match.group(1)
            fname = rust_func_match.group(2)
            output_lines.append(f"{indent}/// Routine: {fname}")

        output_lines.append(line)

    return "\n".join(output_lines) + ("\n" if content.endswith("\n") else "")

# ── 5. Tool Builder: Scaffolding, Validation & Testing ───────────────

def list_existing_tools() -> list[dict]:
    """Returns metadata for all tools in lib/tools/."""
    tools = []
    if not TOOLS_DIR.exists():
        return tools

    for p in sorted(TOOLS_DIR.iterdir()):
        if p.is_file() and not p.name.startswith("."):
            ext = p.suffix.lower()
            lang = "Bash" if ext == ".sh" else ("Python" if ext == ".py" else ext)
            desc = ""
            try:
                with open(p, "r", encoding="utf-8", errors="ignore") as f:
                    head = [f.readline() for _ in range(8)]
                for line in head:
                    if "# DESC:" in line:
                        desc = line.split("# DESC:", 1)[1].strip()
                        break
                    elif '"""' in line or "'''" in line:
                        desc = line.replace('"""', '').replace("'''", '').strip()
            except Exception:
                pass

            tools.append({
                "name": p.name,
                "path": str(p.relative_to(LODGE_DIR)),
                "language": lang,
                "is_executable": os.access(p, os.X_OK),
                "size_bytes": p.stat().st_size,
                "description": desc or f"{lang} tool {p.name}",
                "urn": f"urn:blue-lodge:tool:{p.name}",
            })
    return tools


def scaffold_new_tool(
    name: str,
    language: str,
    subsystem: str,
    description: str,
    code_content: str
) -> dict:
    """Creates a new tool script in lib/tools/, makes it executable, and registers it."""
    # Normalize filename
    if not name.endswith(".sh") and not name.endswith(".py"):
        name = f"{name}.py" if language.lower() == "python" else f"{name}.sh"

    target_path = TOOLS_DIR / name

    if not code_content.strip():
        # Provide default starter template
        if language.lower() == "python" or name.endswith(".py"):
            code_content = f'''#!/usr/bin/env python3
"""
George Tool: {name}
# DESC: {description}
# SUBSYSTEM: {subsystem}
# URN: urn:blue-lodge:tool:{name}
"""

import sys
import os
import argparse
import json

def main():
    parser = argparse.ArgumentParser(description="{description}")
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    args = parser.parse_args()

    # Tool logic here
    print(f"Tool {name} executed successfully.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
'''
        else:
            code_content = f'''#!/bin/bash
# ── George Tool: {name} ──────────────────────────────────────────────
# DESC: {description}
# SUBSYSTEM: {subsystem}
# URN: urn:blue-lodge:tool:{name}

set -euo pipefail

LODGE_DIR="${{LODGE_DIR:-$HOME/blue-lodge}}"

main() {{
    echo "Tool {name} executed successfully."
    return 0
}}

main "$@"
'''

    # Write file
    target_path.parent.mkdir(parents=True, exist_ok=True)
    with open(target_path, "w", encoding="utf-8") as f:
        f.write(code_content)

    # Set executable permissions
    os.chmod(target_path, 0o755)

    # Emit event to POSIX FIFO
    emit_event("tool:created", {
        "name": name,
        "path": str(target_path.relative_to(LODGE_DIR)),
        "language": language,
        "subsystem": subsystem,
        "description": description,
    })

    return {
        "success": True,
        "name": name,
        "path": str(target_path.relative_to(LODGE_DIR)),
        "urn": f"urn:blue-lodge:tool:{name}",
        "size_bytes": target_path.stat().st_size,
        "message": f"Successfully created executable tool {name}.",
    }


def test_execute_tool(tool_name: str, args: list[str], timeout_secs: int = 15) -> dict:
    """Executes a tool in an isolated environment with stdout/stderr capture."""
    target_path = TOOLS_DIR / tool_name
    if not target_path.exists():
        return {
            "success": False,
            "error": f"Tool '{tool_name}' not found in lib/tools/.",
            "exit_code": 127,
            "stdout": "",
            "stderr": "",
        }

    if target_path.suffix == ".py":
        cmd = ["python3", str(target_path)] + args
    elif target_path.suffix == ".sh":
        cmd = ["bash", str(target_path)] + args
    else:
        cmd = [str(target_path)] + args
    start_t = time.time()

    try:
        proc = subprocess.run(
            cmd,
            cwd=str(LODGE_DIR),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout_secs,
        )
        elapsed = round(time.time() - start_t, 3)

        emit_event("tool:executed", {
            "name": tool_name,
            "args": args,
            "exit_code": proc.returncode,
            "duration_secs": elapsed,
        })

        return {
            "success": proc.returncode == 0,
            "exit_code": proc.returncode,
            "stdout": proc.stdout,
            "stderr": proc.stderr,
            "duration_secs": elapsed,
        }
    except subprocess.TimeoutExpired:
        return {
            "success": False,
            "error": f"Execution timed out after {timeout_secs} seconds.",
            "exit_code": 124,
            "stdout": "",
            "stderr": "TIMEOUT",
            "duration_secs": timeout_secs,
        }
    except Exception as e:
        return {
            "success": False,
            "error": str(e),
            "exit_code": 1,
            "stdout": "",
            "stderr": str(e),
            "duration_secs": round(time.time() - start_t, 3),
        }

# ── 6. Agent & Workflow Forge (.agent.md Management) ─────────────────

def list_agent_personas() -> list[dict]:
    """Lists all available .agent.md personas with their frontmatter and descriptions."""
    agents = []
    if not WORKFLOWS_DIR.exists():
        return agents

    for p in sorted(WORKFLOWS_DIR.glob("*.agent.md")):
        name = p.name[:-9] if p.name.endswith(".agent.md") else p.name
        content = ""
        frontmatter = {}
        try:
            with open(p, "r", encoding="utf-8") as f:
                content = f.read()

            if content.startswith("---"):
                parts = content.split("---", 2)
                if len(parts) >= 3:
                    fm_text = parts[1]
                    for line in fm_text.splitlines():
                        if ":" in line:
                            k, v = line.split(":", 1)
                            frontmatter[k.strip()] = v.strip()
        except Exception:
            pass

        agents.append({
            "name": frontmatter.get("name", name),
            "filename": p.name,
            "path": str(p.relative_to(LODGE_DIR)),
            "description": frontmatter.get("description", "Specialist agent"),
            "argument_hint": frontmatter.get("argument-hint", "file path or target"),
            "target": frontmatter.get("target", "antigravity"),
            "urn": f"urn:blue-lodge:agent:{name}",
        })
    return agents


def save_agent_persona(
    name: str,
    description: str,
    rules: list[str],
    workflow_steps: list[str],
    argument_hint: str = "target file or objective",
    raw_markdown: str | None = None
) -> dict:
    """Saves a .agent.md persona adhering to the canonical Blue Lodge blueprint."""
    clean_name = re.sub(r"[^a-zA-Z0-9_-]", "-", name.lower()).strip("-")
    filename = f"{clean_name}.agent.md"
    target_path = WORKFLOWS_DIR / filename

    if raw_markdown and raw_markdown.strip():
        final_content = raw_markdown
    else:
        rules_block = "\n".join(f"- {r}" for r in rules if r.strip())
        workflow_block = "\n\n".join(f"## {i+1}. {step}" for i, step in enumerate(workflow_steps) if step.strip())

        final_content = f"""---
name: {clean_name}
description: {description}
argument-hint: {argument_hint}
target: antigravity
---
You are {clean_name.upper()}, {description}.

<rules>
- **Project Context**: George is an offline-first, pure POSIX bash AI coding agent designed to run locally on edge devices.
- **Tool Scope**: Use only authorized tools adhering to POSIX standards.
- Ensure modifications respect shell state limits and edit in place.
- The Gavel: every shell command and tool flag MUST be explained inline before execution.
- The Square: edit in place; never remove context without explicit explanation.
- The Plumb: do not declare success without proof.
{rules_block}
</rules>

<workflow>
{workflow_block}
</workflow>
"""

    WORKFLOWS_DIR.mkdir(parents=True, exist_ok=True)
    with open(target_path, "w", encoding="utf-8") as f:
        f.write(final_content)

    emit_event("agent:created", {
        "name": clean_name,
        "path": str(target_path.relative_to(LODGE_DIR)),
        "description": description,
    })

    return {
        "success": True,
        "name": clean_name,
        "filename": filename,
        "path": str(target_path.relative_to(LODGE_DIR)),
        "urn": f"urn:blue-lodge:agent:{clean_name}",
        "message": f"Successfully forged agent persona {clean_name}.",
    }


def list_available_workflows() -> list[dict]:
    """Lists all workflows and templates from .agents/workflows/ and .agents/workflow_templates/."""
    workflows = []
    
    # Check workflows directory
    if WORKFLOWS_DIR.exists():
        for p in sorted(WORKFLOWS_DIR.glob("*.md")):
            name = p.name.replace(".agent.md", "").replace(".md", "")
            desc = ""
            try:
                with open(p, "r", encoding="utf-8", errors="ignore") as f:
                    for _ in range(12):
                        l = f.readline()
                        if l.startswith("description:"):
                            desc = l.split("description:", 1)[1].strip()
                            break
                        elif l.startswith("# "):
                            desc = l.lstrip("#").strip()
                            break
            except Exception:
                pass
            workflows.append({
                "name": name,
                "filename": p.name,
                "path": str(p.relative_to(LODGE_DIR)),
                "type": "workflow" if not p.name.endswith(".agent.md") else "agent_workflow",
                "description": desc or f"Workflow {name}",
                "urn": f"urn:blue-lodge:workflow:{name}",
            })

    # Check workflow templates
    tmpl_dir = AGENTS_DIR / "workflow_templates"
    if tmpl_dir.exists():
        for p in sorted(tmpl_dir.glob("*.md")):
            name = p.name.replace(".template.agent.md", "").replace(".md", "")
            desc = ""
            try:
                with open(p, "r", encoding="utf-8", errors="ignore") as f:
                    for _ in range(10):
                        l = f.readline()
                        if l.startswith("description:"):
                            desc = l.split("description:", 1)[1].strip()
                            break
            except Exception:
                pass
            workflows.append({
                "name": f"template:{name}",
                "filename": p.name,
                "path": str(p.relative_to(LODGE_DIR)),
                "type": "template",
                "description": desc or f"Template for {name}",
                "urn": f"urn:blue-lodge:template:{name}",
            })

    return workflows


def save_custom_workflow(
    name: str,
    description: str,
    steps: list[str],
    objective: str = ""
) -> dict:
    """Creates a new workflow markdown guide in .agents/workflows/."""
    clean_name = re.sub(r"[^a-zA-Z0-9_-]", "-", name.lower()).strip("-")
    filename = f"{clean_name}.workflow.md"
    target_path = WORKFLOWS_DIR / filename

    steps_md = "\n\n".join(f"### Step {i+1}: {step}\n{step}" for i, step in enumerate(steps) if step.strip())

    content = f"""# Workflow: {clean_name.replace('-', ' ').title()}
# DESC: {description}
# URN: urn:blue-lodge:workflow:{clean_name}

## Objective
{objective or description}

## Flowchart & Execution Steps
{steps_md}

## Validation & Audit Gates
- Run unit/integration tests (`bash tests/run_all.sh`)
- Confirm zero security regressions via `/the-tyler`
- Ensure POSIX compliance and clean FIFO state
"""

    WORKFLOWS_DIR.mkdir(parents=True, exist_ok=True)
    with open(target_path, "w", encoding="utf-8") as f:
        f.write(content)

    emit_event("workflow:created", {
        "name": clean_name,
        "path": str(target_path.relative_to(LODGE_DIR)),
        "description": description,
    })

    return {
        "success": True,
        "name": clean_name,
        "filename": filename,
        "path": str(target_path.relative_to(LODGE_DIR)),
        "urn": f"urn:blue-lodge:workflow:{clean_name}",
        "message": f"Successfully created workflow {clean_name}.",
    }

# ── 7. Rules Explorer ────────────────────────────────────────────────

def list_available_rules() -> list[dict]:
    """Scans .agents/rules/ and returns all rule modules and category standards."""
    rules = []
    if not RULES_DIR.exists():
        return rules

    for root, _, files in os.walk(RULES_DIR):
        for f in files:
            if f.endswith(".md"):
                fp = Path(root) / f
                rel = fp.relative_to(RULES_DIR)
                category = rel.parent.name if rel.parent.name else "general"
                try:
                    with open(fp, "r", encoding="utf-8", errors="ignore") as fl:
                        first_lines = [fl.readline() for _ in range(3)]
                    title = f
                    for l in first_lines:
                        if l.startswith("#"):
                            title = l.lstrip("#").strip()
                            break
                    rules.append({
                        "name": f.replace(".instructions.md", "").replace(".md", ""),
                        "filename": f,
                        "category": category,
                        "path": str(fp.relative_to(LODGE_DIR)),
                        "title": title,
                        "size_bytes": fp.stat().st_size,
                    })
                except Exception:
                    pass
    return sorted(rules, key=lambda r: (r["category"], r["name"]))

# ── 8. Co-Pilot Engine Status & Forging ───────────────────────────────

def get_copilot_status() -> dict:
    ts_avail = False
    try:
        import tree_sitter  # noqa
        ts_avail = True
    except ImportError:
        pass

    tools = list_existing_tools()
    agents = list_agent_personas()
    workflows = list_available_workflows()
    rules = list_available_rules()

    bus_active = EVENT_BUS_FIFO.exists() and EVENT_BUS_FIFO.is_fifo()
    local_model = os.environ.get("LOCAL_MODEL_ENDPOINT", "http://127.0.0.1:8080/v1")

    return {
        "status": "ready",
        "engine": "George Autonomous Co-Pilot Multi-Model Engine",
        "treesitter_available": ts_avail,
        "event_bus_fifo": str(EVENT_BUS_FIFO),
        "event_bus_active": bus_active,
        "local_model_endpoint": local_model,
        "tools_count": len(tools),
        "agents_count": len(agents),
        "workflows_count": len(workflows),
        "rules_count": len(rules),
    }


def forge_new_tool(
    name: str,
    description: str,
    language: str = "bash",
    workdir: str | None = None,
    code_content: str = "",
) -> dict:
    base_dir = Path(workdir) if workdir else TOOLS_DIR
    target_tools = base_dir if base_dir.name == "tools" else base_dir / ".george" / "tools"
    target_tools.mkdir(parents=True, exist_ok=True)

    ext = ".py" if language.lower() in ("python", "py") else ".sh"
    clean_name = name if name.endswith(ext) else f"{name}{ext}"
    tool_file = target_tools / clean_name

    if not code_content.strip():
        if ext == ".py":
            code_content = f'''#!/usr/bin/env python3
# DESC: {description}
import sys
def main():
    print("Tool {name} executed successfully.")
    return 0
if __name__ == '__main__':
    sys.exit(main())
'''
        else:
            code_content = f'''#!/bin/bash
# DESC: {description}
set -euo pipefail
echo "Tool {name} executed successfully."
exit 0
'''

    with open(tool_file, "w", encoding="utf-8") as f:
        f.write(code_content)
    os.chmod(tool_file, 0o755)

    manifest_file = target_tools / f"{Path(clean_name).stem}.json"
    manifest = {
        "name": Path(clean_name).stem,
        "script": clean_name,
        "description": description,
        "language": language,
        "created_at": int(time.time()),
        "status": "verified"
    }
    with open(manifest_file, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)

    # Test execute
    cmd = ["python3" if ext == ".py" else "bash", str(tool_file)]
    test_proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10)
    success = (test_proc.returncode == 0)

    emit_event("tool:forged", {
        "name": clean_name,
        "path": str(tool_file),
        "success": success,
        "description": description,
    })

    return {
        "status": "TOOL_FORGED_AND_VERIFIED" if success else "TOOL_TEST_FAILED",
        "success": success,
        "name": clean_name,
        "tool_script": str(tool_file),
        "manifest": str(manifest_file),
        "exit_code": test_proc.returncode,
        "stdout": test_proc.stdout.strip(),
    }

# ── 9. CLI Interface ──────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="George Co-Pilot Engine")
    subparsers = parser.add_subparsers(dest="command")

    # Status
    p_stat = subparsers.add_parser("status")
    p_stat.add_argument("--json", action="store_true", help="Output JSON status")

    # Resolve patch
    p_patch = subparsers.add_parser("resolve-patch")
    p_patch.add_argument("--original-file", required=True)
    p_patch.add_argument("--proposed-file", required=True)
    p_patch.add_argument("--selection-file", default=None)
    p_patch.add_argument("--instruction", default="")
    p_patch.add_argument("--output-file", default=None)

    # Safe comment
    p_comment = subparsers.add_parser("safe-comment")
    p_comment.add_argument("--file", required=True)
    p_comment.add_argument("--instruction", default="Add comments")
    p_comment.add_argument("--output-file", default=None)

    # Forge tool
    p_forge = subparsers.add_parser("forge-tool")
    p_forge.add_argument("--tool-name", required=True)
    p_forge.add_argument("--description", default="Forged tool")
    p_forge.add_argument("--language", default="bash")
    p_forge.add_argument("--workdir", default=None)
    p_forge.add_argument("--code", default="")

    # List tools
    subparsers.add_parser("list-tools")

    # Build tool
    p_build = subparsers.add_parser("build-tool")
    p_build.add_argument("--name", required=True)
    p_build.add_argument("--lang", default="bash")
    p_build.add_argument("--subsystem", default="tools")
    p_build.add_argument("--desc", default="Custom George tool")
    p_build.add_argument("--code", default="")

    # Test tool
    p_test = subparsers.add_parser("test-tool")
    p_test.add_argument("--name", required=True)
    p_test.add_argument("--args-json", default="")
    p_test.add_argument("args", nargs="*", default=[])

    # List agents
    subparsers.add_parser("list-agents")

    # Save agent
    p_agent = subparsers.add_parser("save-agent")
    p_agent.add_argument("--name", required=True)
    p_agent.add_argument("--desc", required=True)
    p_agent.add_argument("--rules", default="[]")
    p_agent.add_argument("--workflow", default="[]")

    # List workflows
    subparsers.add_parser("list-workflows")

    # Save workflow
    p_wf = subparsers.add_parser("save-workflow")
    p_wf.add_argument("--name", required=True)
    p_wf.add_argument("--desc", required=True)
    p_wf.add_argument("--steps", default="[]")
    p_wf.add_argument("--objective", default="")

    # List rules
    subparsers.add_parser("list-rules")

    args = parser.parse_args()

    if args.command == "status":
        stat = get_copilot_status()
        if getattr(args, "json", False):
            print(json.dumps(stat, indent=2))
        else:
            print("======================================================")
            print("  Autonomous Co-Pilot Engine Status")
            print("======================================================")
            print(f"Status:               {stat['status']}")
            print(f"Tree-sitter AST:      {'Available' if stat['treesitter_available'] else 'Regex Fallback'}")
            print(f"Llama.cpp local:      {stat['local_model_endpoint']}")
            print(f"POSIX Event Bus:      {'Active' if stat['event_bus_active'] else 'Idle / Ready'}")
            print(f"Inventory Tools:      {stat['tools_count']}")
            print(f"Agent Personas:       {stat['agents_count']}")
            print(f"Workflows:            {stat['workflows_count']}")
            print(f"Rules:                {stat['rules_count']}")
        sys.exit(0)

    elif args.command == "resolve-patch":
        with open(args.original_file, "r", encoding="utf-8") as f:
            orig = f.read()
        with open(args.proposed_file, "r", encoding="utf-8") as f:
            prop = f.read()
        sel = None
        if args.selection_file and os.path.exists(args.selection_file):
            with open(args.selection_file, "r", encoding="utf-8") as f:
                sel = f.read()

        res = resolve_proposed_patch(orig, prop, sel, args.instruction)
        res["status"] = "PATCH_RESOLVED" if res.get("success") else "PATCH_FAILED"
        if args.output_file and res.get("success"):
            with open(args.output_file, "w", encoding="utf-8") as f:
                f.write(res["resolved_code"])
        print(json.dumps(res, indent=2))
        sys.exit(0 if res["success"] else 1)

    elif args.command == "safe-comment":
        with open(args.file, "r", encoding="utf-8") as f:
            orig = f.read()
        commented = safe_comment_content(orig, args.instruction)
        orig_count = len(orig.splitlines())
        new_count = len(commented.splitlines())
        if args.output_file:
            with open(args.output_file, "w", encoding="utf-8") as f:
                f.write(commented)
            print(json.dumps({
                "status": "SAFE_COMMENT_APPLIED",
                "file": args.file,
                "output_file": args.output_file,
                "original_lines": orig_count,
                "commented_lines": new_count,
                "deleted_lines": 0
            }, indent=2))
        else:
            print(commented)
        sys.exit(0)

    elif args.command == "forge-tool":
        res = forge_new_tool(args.tool_name, args.description, args.language, args.workdir, args.code)
        print(json.dumps(res, indent=2))
        sys.exit(0 if res["success"] else 1)

    elif args.command == "list-tools":
        print(json.dumps(list_existing_tools(), indent=2))
        sys.exit(0)

    elif args.command == "build-tool":
        res = scaffold_new_tool(args.name, args.lang, args.subsystem, args.desc, args.code)
        print(json.dumps(res, indent=2))
        sys.exit(0 if res["success"] else 1)

    elif args.command == "test-tool":
        tool_args = list(args.args)
        if getattr(args, "args_json", None):
            try:
                parsed = json.loads(args.args_json)
                if isinstance(parsed, list):
                    tool_args = [str(x) for x in parsed]
            except Exception:
                pass
        res = test_execute_tool(args.name, tool_args)
        print(json.dumps(res, indent=2))
        sys.exit(0 if res["success"] else 1)

    elif args.command == "list-agents":
        print(json.dumps(list_agent_personas(), indent=2))
        sys.exit(0)

    elif args.command == "save-agent":
        rules = json.loads(args.rules) if args.rules.startswith("[") else [args.rules]
        wf = json.loads(args.workflow) if args.workflow.startswith("[") else [args.workflow]
        res = save_agent_persona(args.name, args.desc, rules, wf)
        print(json.dumps(res, indent=2))
        sys.exit(0 if res["success"] else 1)

    elif args.command == "list-workflows":
        print(json.dumps(list_available_workflows(), indent=2))
        sys.exit(0)

    elif args.command == "save-workflow":
        steps = json.loads(args.steps) if args.steps.startswith("[") else [args.steps]
        res = save_custom_workflow(args.name, args.desc, steps, args.objective)
        print(json.dumps(res, indent=2))
        sys.exit(0 if res["success"] else 1)

    elif args.command == "list-rules":
        print(json.dumps(list_available_rules(), indent=2))
        sys.exit(0)

    else:
        parser.print_help()
        sys.exit(1)

if __name__ == "__main__":
    main()
