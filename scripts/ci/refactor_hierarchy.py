#!/usr/bin/env python3
"""
Refactors flat lib/ and scripts/ directories into clean domain-based hierarchies
with backward-compatible relative symlinks for 100% zero-regression.
"""

import os
import shutil

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

LIB_MAP = {
    "core": [
        "agent.sh", "agent_sm.sh", "react.sh", "reflexive.sh",
        "context_engine.sh", "llm.sh", "endpoints.sh", "providers.sh", "limits.sh",
        "api.sh", "models.sh"
    ],
    "tools": [
        "tools.sh", "native_tools.sh", "treesitter.sh", "research_graph.sh",
        "mcp.sh", "mcp_server_fetch.sh", "mcp_server_fusion.py", "mcp_server_gcloud.sh",
        "mcp_server_git.sh", "mcp_server_gitea.sh", "mcp_server_inference.sh",
        "mcp_server_mqtt.sh", "mcp_server_x.sh", "honeydew_strategist.py", "nvim_pty.py",
        "git.sh"
    ],
    "ipc": [
        "fifo_ipc.sh", "ipc.sh", "task_sync.sh"
    ],
    "sys": [
        "sandbox.sh", "container.sh", "cron.sh", "vitals.sh", "backup.sh",
        "auth.sh", "secrets.sh", "security.sh", "pgp.sh", "remote.sh", "cache.sh"
    ],
    "comms": [
        "web.sh", "discord_bridge.sh", "email.sh", "mqtt.sh", "phone.sh",
        "social.sh", "social_blog.sh", "social_cookie.py", "gsuite.sh", "wallet.sh"
    ],
    "memory": [
        "memory.sh", "recall.sh", "journal.sh", "transcript.sh"
    ],
    "agents": [
        "subagents.sh", "swarm.sh", "workflows.sh", "skills.sh", "rules.sh",
        "remediation.sh", "phytology.sh", "telemetry.sh", "alerts.sh",
        "reputation.sh", "pr.sh", "sentinel.sh"
    ],
    "ui": [
        "ui.sh", "ui_dashboard.sh", "popup.sh", "slash.sh", "commands.sh"
    ],
    "knowledge": [
        "okf.sh"
    ]
}

SCRIPTS_MAP = {
    "infra": [
        "start_prism.sh", "start-local-prism.sh", "start-cuda-sandbox.sh",
        "start-gitea.sh", "start-act-runner.sh", "compose.sh", "validate-gpu.sh"
    ],
    "inference": [
        "switch_inference.sh", "switch_model.sh", "test-llama-server.sh",
        "inference-server-deploy.sh", "inference-server-install.sh",
        "inference-server-models.sh", "chat.py", "stress_test_context.py"
    ],
    "monitor": [
        "discord_live_monitor.sh", "discord_send_report.py", "discord_send_report.sh",
        "remediation_live_monitor.sh", "research_live_monitor.sh", "cron_visual_sweep.sh"
    ],
    "ci": [
        "ci_local.sh", "security_injection_scanner.py", "scrape.sh",
        "research_sandbox.sh", "run_research_sandbox.sh"
    ]
}

def refactor_lib():
    lib_dir = os.path.join(REPO_ROOT, "lib")
    moved_count = 0
    symlink_count = 0

    for domain, files in LIB_MAP.items():
        domain_dir = os.path.join(lib_dir, domain)
        os.makedirs(domain_dir, exist_ok=True)
        for fname in files:
            src = os.path.join(lib_dir, fname)
            dst = os.path.join(domain_dir, fname)
            
            # If src exists and is not already a symlink pointing to dst
            if os.path.exists(src) and not os.path.islink(src):
                shutil.move(src, dst)
                moved_count += 1
                # Create relative symlink
                rel_target = os.path.join(domain, fname)
                os.symlink(rel_target, src)
                symlink_count += 1
            elif not os.path.exists(src) and os.path.exists(dst):
                # Ensure symlink exists
                rel_target = os.path.join(domain, fname)
                os.symlink(rel_target, src)
                symlink_count += 1

    print(f"[lib/] Organized {moved_count} modules into {len(LIB_MAP)} domains with {symlink_count} backward-compatible symlinks.")

def refactor_scripts():
    scripts_dir = os.path.join(REPO_ROOT, "scripts")
    moved_count = 0
    symlink_count = 0

    for domain, files in SCRIPTS_MAP.items():
        domain_dir = os.path.join(scripts_dir, domain)
        os.makedirs(domain_dir, exist_ok=True)
        for fname in files:
            src = os.path.join(scripts_dir, fname)
            dst = os.path.join(domain_dir, fname)
            
            if os.path.exists(src) and not os.path.islink(src):
                shutil.move(src, dst)
                moved_count += 1
                rel_target = os.path.join(domain, fname)
                os.symlink(rel_target, src)
                symlink_count += 1
            elif not os.path.exists(src) and os.path.exists(dst):
                rel_target = os.path.join(domain, fname)
                os.symlink(rel_target, src)
                symlink_count += 1

    print(f"[scripts/] Organized {moved_count} scripts into {len(SCRIPTS_MAP)} domains with {symlink_count} backward-compatible symlinks.")

if __name__ == "__main__":
    refactor_lib()
    refactor_scripts()
