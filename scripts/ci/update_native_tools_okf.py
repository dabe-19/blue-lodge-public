#!/usr/bin/env python3
import json

path = "data/schemas/native_tools.json"
with open(path, "r", encoding="utf-8") as f:
    tools = json.load(f)

existing_names = [t.get("function", {}).get("name") for t in tools]

new_tools = [
    {
        "type": "function",
        "function": {
            "name": "okf_search",
            "description": "Search the Google Open Knowledge Graph (OKF) for Blue Lodge architecture, modules, exported symbols, and programming standards. Use when: exploring repository subsystems, locating code entities, or discovering architectural standards. Examples: query=\"fifo_ipc\", query=\"telemetry\", query=\"standards\".",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Search query or keyword (e.g. 'fifo_ipc', 'standards', 'remediation', 'inference')."
                    }
                },
                "required": ["query"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "okf_query",
            "description": "Query detailed semantic metadata, dependencies, exported interfaces, and governing standards for a specific module, subsystem, or standard in the Google Open Knowledge Graph (OKF). Examples: target=\"lib/ipc/fifo_ipc.sh\", target=\"urn:blue-lodge:standard:fifo-async-ipc-flowcontrol\".",
            "parameters": {
                "type": "object",
                "properties": {
                    "target": {
                        "type": "string",
                        "description": "Entity URI (e.g. 'urn:blue-lodge:standard:fifo-async-ipc-flowcontrol') or module path (e.g. 'lib/ipc/fifo_ipc.sh', 'core')."
                    }
                },
                "required": ["target"]
            }
        }
    }
]

added = 0
for nt in new_tools:
    nname = nt["function"]["name"]
    if nname not in existing_names:
        tools.append(nt)
        added += 1

with open(path, "w", encoding="utf-8") as f:
    json.dump(tools, f, indent=2)

print(f"Added {added} new OKF tools to {path}. Total tools: {len(tools)}")
