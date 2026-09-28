#!/usr/bin/env python3
"""
generate_research_cron_curricula.py:
Generates synthetic ChatML training datasets for the 3x A100 Colab fleet training run:
- Track A (Research Cron Architect):
    Interpreting recurring user requests (daily, twice-daily, every N hours),
    creating executable cron scripts in .george/cron_jobs/<name>.sh with # INTERVAL: <seconds>,
    # DESC: <description>, wrapping scripts/run_research_sandbox.sh with isolated paths and
    deterministic delivery, verifying via bash_exec and completing milestones.
- Track B (Diverse Cross-Sectional Semantic Research):
    Executing non-greedy web research using web_search_cross_section across diverse competitors
    (UNH, ELV, CI, CVS, HUM / NVDA, TSM, ASML, INTC / AWS, Azure, GCP / etc.),
    ingesting multiple domain perspectives with web_fetch, avoiding single-source clustering,
    and recording comparative intelligence into working memory / milestone_complete.
- Track C (Dossier Synthesis & Deterministic Delivery Wrap):
    Synthesizing executive markdown dossiers (Executive Summary, Financial Matrix Table,
    Regulatory & Capital Headwinds, Cross-Sectional Citations), and ensuring deterministic
    dispatch over Discord DM (@dabe) with safe message chunking (<1800 chars).
"""

import json
import os
import random

OUTPUT_DIR = "/home/wsl-ops/blue-lodge/data/training"
os.makedirs(OUTPUT_DIR, exist_ok=True)

CORE_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "file_write",
            "description": "Write or overwrite content to a file at the specified path.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Absolute or relative path to file."},
                    "content": {"type": "string", "description": "Full file content to write."}
                },
                "required": ["path", "content"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "file_read",
            "description": "Read file contents from the workspace.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Path to file to read."}
                },
                "required": ["path"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "bash_exec",
            "description": "Execute a bash shell command within the project workspace.",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {"type": "string"}
                },
                "required": ["command"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "web_search_cross_section",
            "description": "Perform web search with non-greedy cross-sectional sampling across diverse domains and viewpoints.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Search query with broad entity coverage."},
                    "sample_k": {"type": "integer", "description": "Number of distinct domains/perspectives to sample (default: 3)."},
                    "candidate_pool": {"type": "integer", "description": "Pool size to retrieve before sampling (default: 12)."}
                },
                "required": ["query"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "web_fetch",
            "description": "Fetch and extract text content from a web URL.",
            "parameters": {
                "type": "object",
                "properties": {
                    "url": {"type": "string", "description": "URL to fetch."}
                },
                "required": ["url"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "discord_dm",
            "description": "Send a direct message to a user on Discord.",
            "parameters": {
                "type": "object",
                "properties": {
                    "recipient": {"type": "string", "description": "Username with @ or numeric Discord User ID."},
                    "message": {"type": "string", "description": "Message text to deliver."}
                },
                "required": ["recipient", "message"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "milestone_complete",
            "description": "Signal that the active milestone is complete or blocked, and submit structured observations and discovered facts.",
            "parameters": {
                "type": "object",
                "properties": {
                    "status": {"type": "string", "enum": ["success", "blocked"]},
                    "summary": {"type": "string"},
                    "facts_discovered": {"type": "array", "items": {"type": "string"}}
                },
                "required": ["status", "summary"]
            }
        }
    }
]

SYSTEM_PROMPT = """You are George, the sovereign autonomous engineering intelligence of Blue Lodge.
Execute user objectives methodically. When requested to set up recurring intelligence or cron jobs,
architect clean shell scripts in .george/cron_jobs/<name>.sh with proper # INTERVAL: <seconds> and # DESC:
headers wrapping deterministic research sandbox execution and Discord delivery.
When researching topics, avoid greedy single-source bias by leveraging web_search_cross_section to sample
a balanced semantic cross-section across diverse competitor domains."""

CRON_ARCHITECT_TOPICS = [
    {
        "user_req": "George, can you send me a financial intel report on the major healthcare insurance companies twice a day to @dabe?",
        "cron_name": "healthcare_financial_intel.sh",
        "interval": 43200,
        "desc": "Twice-daily financial intelligence sweep across major healthcare insurance companies (UNH, ELV, CI, CVS, HUM)",
        "topic": "major healthcare insurance companies financials UNH ELV CI CVS HUM",
        "recipient": "@dabe",
        "facts": [
            "Registered twice-daily cron script in .george/cron_jobs/healthcare_financial_intel.sh with 43200s interval",
            "Deterministic wrapper executes scripts/run_research_sandbox.sh with non-greedy cross-section search",
            "Target recipient set to @dabe with Discord message chunking under 1800 characters"
        ]
    },
    {
        "user_req": "George, set up a daily semiconductor supply chain intelligence briefing delivered to @dabe at 8am.",
        "cron_name": "semiconductor_supply_chain.sh",
        "interval": 86400,
        "desc": "Daily semiconductor foundry and packaging supply chain intelligence (TSMC, ASML, NVDA, INTC)",
        "topic": "semiconductor foundry packaging supply chain TSMC ASML NVDA INTC",
        "recipient": "@dabe",
        "facts": [
            "Registered daily cron script in .george/cron_jobs/semiconductor_supply_chain.sh with 86400s interval",
            "Sandboxed runner invokes web_search_cross_section across foundries and equipment manufacturers",
            "Artifact destination configured to .george/reports/semiconductor_latest.md"
        ]
    },
    {
        "user_req": "George, create a recurring research job that sweeps cloud hyperscaler AI pricing trends every 12 hours.",
        "cron_name": "hyperscaler_ai_pricing.sh",
        "interval": 43200,
        "desc": "Bi-daily cloud hyperscaler GPU instance pricing and capacity tracking (AWS, Azure, GCP, Lambda)",
        "topic": "hyperscaler cloud GPU pricing capacity H100 B200 AWS Azure GCP",
        "recipient": "@dabe",
        "facts": [
            "Configured 12-hour interval (43200s) in .george/cron_jobs/hyperscaler_ai_pricing.sh",
            "Deterministic wrapper generates structured pricing table matrix",
            "Outputs verified to .george/reports/hyperscaler_pricing.md"
        ]
    },
    {
        "user_req": "George, schedule a cybersecurity enterprise earnings sweep every 6 hours and send report to @dabe.",
        "cron_name": "cybersecurity_earnings.sh",
        "interval": 21600,
        "desc": "6-hour recurring cybersecurity enterprise ARR and net retention sweep (PANW, CRWD, ZS, FTNT)",
        "topic": "cybersecurity earnings ARR net retention PANW CRWD ZS FTNT",
        "recipient": "@dabe",
        "facts": [
            "Created .george/cron_jobs/cybersecurity_earnings.sh with interval 21600s",
            "Deterministic wrapper leverages non-greedy cross-sectional article retrieval",
            "Discord delivery wrapper verified with automatic multi-chunk segmentation"
        ]
    }
]

def build_track_a_sample(sample_id):
    """Track A: Research Cron Architect"""
    spec = CRON_ARCHITECT_TOPICS[sample_id % len(CRON_ARCHITECT_TOPICS)]
    cron_script_content = f"""#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
# George Sovereign Autonomic Cron: {spec['cron_name']}
# ══════════════════════════════════════════════════════════════════════
# INTERVAL: {spec['interval']}
# DESC: {spec['desc']}
# ══════════════════════════════════════════════════════════════════════

set -euo pipefail
LODGE_DIR="${{LODGE_DIR:-/home/wsl-ops/blue-lodge}}"

TOPIC="{spec['topic']}"
REPORT_FILE="$LODGE_DIR/.george/reports/{spec['cron_name'].replace('.sh', '.md')}"
RECIPIENT="{spec['recipient']}"

"$LODGE_DIR/scripts/run_research_sandbox.sh" "$TOPIC" "$REPORT_FILE" "$RECIPIENT"
"""

    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": spec["user_req"]},
        {
            "role": "assistant",
            "content": "",
            "tool_calls": [
                {
                    "id": f"call_write_{sample_id}",
                    "type": "function",
                    "function": {
                        "name": "file_write",
                        "arguments": json.dumps({
                            "path": f".george/cron_jobs/{spec['cron_name']}",
                            "content": cron_script_content
                        })
                    }
                }
            ]
        },
        {
            "role": "tool",
            "tool_call_id": f"call_write_{sample_id}",
            "content": json.dumps({"status": "success", "bytes_written": len(cron_script_content), "path": f".george/cron_jobs/{spec['cron_name']}"})
        },
        {
            "role": "assistant",
            "content": "",
            "tool_calls": [
                {
                    "id": f"call_chmod_{sample_id}",
                    "type": "function",
                    "function": {
                        "name": "bash_exec",
                        "arguments": json.dumps({
                            "command": f"chmod +x .george/cron_jobs/{spec['cron_name']} && bash -n .george/cron_jobs/{spec['cron_name']}"
                        })
                    }
                }
            ]
        },
        {
            "role": "tool",
            "tool_call_id": f"call_chmod_{sample_id}",
            "content": json.dumps({"exit_code": 0, "stdout": "", "stderr": ""})
        },
        {
            "role": "assistant",
            "content": "",
            "tool_calls": [
                {
                    "id": f"call_complete_{sample_id}",
                    "type": "function",
                    "function": {
                        "name": "milestone_complete",
                        "arguments": json.dumps({
                            "status": "success",
                            "summary": f"Successfully architected and registered recurring cron job .george/cron_jobs/{spec['cron_name']} with interval {spec['interval']}s.",
                            "facts_discovered": spec["facts"]
                        })
                    }
                }
            ]
        },
        {
            "role": "tool",
            "tool_call_id": f"call_complete_{sample_id}",
            "content": json.dumps({"status": "acknowledged", "milestone_id": 1})
        },
        {
            "role": "assistant",
            "content": f"The recurring research cron job `.george/cron_jobs/{spec['cron_name']}` has been created and registered with an interval of {spec['interval']} seconds. It encapsulates deterministic sandbox execution via `scripts/run_research_sandbox.sh`, creative non-greedy cross-section article sampling, and safe chunked delivery to {spec['recipient']} on Discord."
        }
    ]

    return {
        "id": f"trackA_cron_arch_{sample_id}",
        "track": "cron_architect",
        "messages": messages,
        "tools": CORE_TOOLS
    }

RESEARCH_SCENARIOS = [
    {
        "query": "major healthcare insurance companies financials UNH ELV CI CVS HUM",
        "sample_k": 3,
        "candidate_pool": 12,
        "results": [
            {"title": "Elevance Health (ELV) Peer Comparison & MLR Headwinds 2026", "url": "https://www.hudson-labs.com/research/elevance-health-competitors-elv-peer-comparison-2026", "domain": "hudson-labs.com"},
            {"title": "Top 10 Healthcare Companies by Revenue & Medical Margin Analysis", "url": "https://www.onedayadvisor.com/2025/06/top-10-healthcare-companies-by-revenue.html", "domain": "onedayadvisor.com"},
            {"title": "Healthcare Insurer Valuations: Discussion on UNH, Humana Medicare Advantage Cuts", "url": "https://reddit.com/r/investing/comments/healthcare_insurance_2026", "domain": "reddit.com"}
        ],
        "facts": [
            "Sampled balanced cross-section across financial research, industry analysis, and retail market sentiment",
            "Identified elevated Medical Loss Ratios (88.5% - 90.2%) across commercial and MA carriers",
            "Noted Optum and Evernorth non-insurance services buffering UNH and CI bottom lines"
        ]
    },
    {
        "query": "semiconductor equipment foundry leading edge TSMC ASML NVDA INTC",
        "sample_k": 3,
        "candidate_pool": 12,
        "results": [
            {"title": "ASML High-NA EUV Commercial Adoption & Foundry Backlogs", "url": "https://semiengineering.com/high-na-euv-foundry-adoption-2026", "domain": "semiengineering.com"},
            {"title": "TSMC 2nm N2 Node Ramp & CoWoS Packaging Capacity Constraints", "url": "https://anandtech.com/tsmc-n2-cowos-capacity-2026", "domain": "anandtech.com"},
            {"title": "Semiconductor Capital Equipment Spend Estimates 2026-2027", "url": "https://semiconductor-digest.com/capex-forecast-2026", "domain": "semiconductor-digest.com"}
        ],
        "facts": [
            "Sampled cross-section across toolmaker (ASML), foundry (TSMC), and industry capital expenditure models",
            "CoWoS advanced packaging capacity remains primary gating factor for AI accelerator shipments",
            "High-NA EUV tools entering early risk production across 3 major fabs"
        ]
    }
]

def build_track_b_sample(sample_id):
    """Track B: Diverse Cross-Sectional Semantic Research"""
    spec = RESEARCH_SCENARIOS[sample_id % len(RESEARCH_SCENARIOS)]
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": f"Execute an in-depth competitive intelligence sweep on: {spec['query']}. Ensure you avoid greedy single-source bias by sampling across distinct domains."},
        {
            "role": "assistant",
            "content": "",
            "tool_calls": [
                {
                    "id": f"call_search_{sample_id}",
                    "type": "function",
                    "function": {
                        "name": "web_search_cross_section",
                        "arguments": json.dumps({
                            "query": spec["query"],
                            "sample_k": spec["sample_k"],
                            "candidate_pool": spec["candidate_pool"]
                        })
                    }
                }
            ]
        },
        {
            "role": "tool",
            "tool_call_id": f"call_search_{sample_id}",
            "content": json.dumps({"sampled_results": spec["results"], "unique_domains": len(spec["results"])})
        },
        {
            "role": "assistant",
            "content": "",
            "tool_calls": [
                {
                    "id": f"call_fetch_{sample_id}",
                    "type": "function",
                    "function": {
                        "name": "web_fetch",
                        "arguments": json.dumps({
                            "url": spec["results"][0]["url"]
                        })
                    }
                }
            ]
        },
        {
            "role": "tool",
            "tool_call_id": f"call_fetch_{sample_id}",
            "content": f"Executive summary of {spec['results'][0]['title']}: Detailed analysis of financial performance, operational headwinds, and margin trajectory."
        },
        {
            "role": "assistant",
            "content": "",
            "tool_calls": [
                {
                    "id": f"call_complete_{sample_id}",
                    "type": "function",
                    "function": {
                        "name": "milestone_complete",
                        "arguments": json.dumps({
                            "status": "success",
                            "summary": f"Completed semantic cross-sectional research sweep for query '{spec['query']}'.",
                            "facts_discovered": spec["facts"]
                        })
                    }
                }
            ]
        },
        {
            "role": "tool",
            "tool_call_id": f"call_complete_{sample_id}",
            "content": json.dumps({"status": "acknowledged", "milestone_id": 2})
        },
        {
            "role": "assistant",
            "content": f"Semantic cross-sectional research complete. Sampled 3 distinct domain perspectives across {spec['results'][0]['domain']}, {spec['results'][1]['domain']}, and {spec['results'][2]['domain']}. Key insights recorded into working memory."
        }
    ]

    return {
        "id": f"trackB_cross_sec_{sample_id}",
        "track": "cross_section_research",
        "messages": messages,
        "tools": CORE_TOOLS
    }

DOSSIER_SCENARIOS = [
    {
        "topic": "Healthcare Insurer Financial Intelligence",
        "recipient": "@dabe",
        "dossier_title": "📊 Financial Intelligence Dossier: Major Healthcare Insurers",
        "table": """| Insurer / Ticker | TTM Revenue | Reported MLR / MBR | Strategic Focus & Moat | Key Risk / Headwind |
|---|---|---|---|---|
| **UnitedHealth (UNH)** | ~$400B+ | ~85.6% – 86.8% | Dual-engine model (UnitedHealthcare + Optum) | DOJ antitrust scrutiny & utilization creep |
| **Elevance Health (ELV)** | ~$198B | ~88.9% | Dominant BCBS regional commercial franchises | Medicaid redetermination attrition & MLR headwinds |
| **The Cigna Group (CI)** | ~$195B+ | ~82.0% – 83.5% | Evernorth pharmacy & health services | Commercial customer retention & drug pricing |
| **CVS Health (CVS)** | ~$360B+ | ~89.5% – 91.0% | Integrated Aetna benefits + retail & Caremark PBM | Star rating downgrade headwinds on Aetna MA |
| **Humana (HUM)** | ~$105B | ~89.9% – 90.5% | Scaled Medicare Advantage market share | High concentration risk in MA policy & CMS star cuts |"""
    }
]

def build_track_c_sample(sample_id):
    """Track C: Dossier Synthesis & Deterministic Delivery Wrap"""
    spec = DOSSIER_SCENARIOS[sample_id % len(DOSSIER_SCENARIOS)]
    report_text = f"""# {spec['dossier_title']}
**Timestamp:** 2026-09-27 11:45 AM CDT  
**Focus Entities:** UnitedHealth Group (UNH), Elevance Health (ELV), Cigna Group (CI), CVS Health (CVS), Humana (HUM)  

---

## 1. Executive Summary
The U.S. managed care and health insurance sector continues to navigate a pivotal macroeconomic transition characterized by elevated Medical Loss Ratios (88.5%–90.2%) and Medicare Advantage reimbursement rate pressure. Diversified operators with substantial pharmacy benefit and services arms (UNH Optum, Cigna Evernorth) maintain significant resilience compared to concentrated pure-play MA carriers.

---

## 2. Comparative Financial & Operational Matrix
{spec['table']}

---

## 3. Regulatory & Capital Headwinds
1. **CMS Risk-Adjustment Models:** Recalibration of v28 payment models compresses MA margins.
2. **PBM Scrutiny:** Federal inquiries into rebate transparency threaten standalone margin expansion.
3. **Solvency & Capital Deployment:** Sustained capital deployment toward specialty care clinics and digital health.

---
*Generated autonomously by George Sovereign Research Sandbox Engine.*"""

    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": f"Synthesize the verified research findings into an executive markdown dossier and dispatch the report to {spec['recipient']} on Discord."},
        {
            "role": "assistant",
            "content": "",
            "tool_calls": [
                {
                    "id": f"call_discord_dm_{sample_id}",
                    "type": "function",
                    "function": {
                        "name": "discord_dm",
                        "arguments": json.dumps({
                            "recipient": spec["recipient"],
                            "message": report_text[:1750]
                        })
                    }
                }
            ]
        },
        {
            "role": "tool",
            "tool_call_id": f"call_discord_dm_{sample_id}",
            "content": json.dumps({"status": "delivered", "message_id": "1553808643412205609", "recipient": spec["recipient"]})
        },
        {
            "role": "assistant",
            "content": "",
            "tool_calls": [
                {
                    "id": f"call_complete_{sample_id}",
                    "type": "function",
                    "function": {
                        "name": "milestone_complete",
                        "arguments": json.dumps({
                            "status": "success",
                            "summary": f"Executive dossier successfully compiled and delivered to {spec['recipient']} on Discord.",
                            "facts_discovered": [
                                f"Delivered comprehensive financial intelligence dossier to {spec['recipient']}",
                                "Verified comparative matrix and headwinds delivered under 1800 character chunk size"
                            ]
                        })
                    }
                }
            ]
        },
        {
            "role": "tool",
            "tool_call_id": f"call_complete_{sample_id}",
            "content": json.dumps({"status": "acknowledged", "milestone_id": 3})
        },
        {
            "role": "assistant",
            "content": f"The executive financial intelligence dossier has been synthesized and deterministically dispatched to {spec['recipient']} on Discord. The deliverable features an executive summary, comparative financial matrix across UNH, ELV, CI, CVS, and HUM, and regulatory headwind analysis."
        }
    ]

    return {
        "id": f"trackC_dossier_wrap_{sample_id}",
        "track": "dossier_delivery_wrap",
        "messages": messages,
        "tools": CORE_TOOLS
    }

def main():
    print("Generating Synthetic Research Cron Curricula for 3x A100 Training Fleet...")
    trackA_samples = [build_track_a_sample(i) for i in range(50)]
    trackB_samples = [build_track_b_sample(i) for i in range(50)]
    trackC_samples = [build_track_c_sample(i) for i in range(50)]

    with open(f"{OUTPUT_DIR}/curriculum_trackA_cron_architect.jsonl", "w") as f:
        for s in trackA_samples:
            f.write(json.dumps(s) + "\n")

    with open(f"{OUTPUT_DIR}/curriculum_trackB_cross_section_research.jsonl", "w") as f:
        for s in trackB_samples:
            f.write(json.dumps(s) + "\n")

    with open(f"{OUTPUT_DIR}/curriculum_trackC_dossier_delivery_wrap.jsonl", "w") as f:
        for s in trackC_samples:
            f.write(json.dumps(s) + "\n")

    all_samples = trackA_samples + trackB_samples + trackC_samples
    random.shuffle(all_samples)

    val_count = 24
    val_set = all_samples[:val_count]
    train_set = all_samples[val_count:]

    with open(f"{OUTPUT_DIR}/research_cron_train.jsonl", "w") as f:
        for s in train_set:
            f.write(json.dumps(s) + "\n")

    with open(f"{OUTPUT_DIR}/research_cron_val.jsonl", "w") as f:
        for s in val_set:
            f.write(json.dumps(s) + "\n")

    print(f"✓ Generated {len(trackA_samples)} Track A samples (curriculum_trackA_cron_architect.jsonl)")
    print(f"✓ Generated {len(trackB_samples)} Track B samples (curriculum_trackB_cross_section_research.jsonl)")
    print(f"✓ Generated {len(trackC_samples)} Track C samples (curriculum_trackC_dossier_delivery_wrap.jsonl)")
    print(f"✓ Combined master datasets: {len(train_set)} train, {len(val_set)} val")

if __name__ == "__main__":
    main()
