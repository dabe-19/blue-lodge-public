#!/usr/bin/env python3
"""
George: "The Tyler" Home Network Defense & Kali Linux Security MCP Server
Speaks JSON-RPC 2.0 over stdio to provide George with Layer-2/Layer-3 LAN
surveillance, Kali Linux nmap deep fingerprinting, tshark traffic metadata
inspection, UPnP port-forward auditing, device trust classification, and
policy-gated host-shield / quarantine interventions.
"""
from __future__ import annotations

import concurrent.futures
import json
import sys
import threading
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from lib.tools import tyler_guardian as tg

TOOLS_SCHEMA = [
    {
        "name": "tyler_lan_census",
        "description": "Run an active Layer-2 ARP, TCP, mDNS, and Kali arp-scan census across the home LAN. Updates .george/state/lan_devices.db, verifies mesh router integrity, and flags any unknown/untrusted devices.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "refresh": {
                    "type": "boolean",
                    "description": "Set true (default) to perform an active network sweep, or false to read cached ledger status.",
                }
            },
        },
    },
    {
        "name": "tyler_deep_fingerprint",
        "description": "Execute an authorized active Kali Linux reconnaissance & service fingerprint scan (nmap -sV -O + banner/HTTP/UPnP scripts + OUI forensic lookup) against a specific LAN IP address and record the dossier in lan_devices.db. Standing operator authorization is granted for all local LAN devices.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "ip": {
                    "type": "string",
                    "description": "Target private LAN IPv4 address (e.g. '192.168.1.38').",
                }
            },
            "required": ["ip"],
        },
    },
    {
        "name": "tyler_vuln_audit",
        "description": "Execute an authorized active Kali Linux Nmap NSE vulnerability, CVE exposure, and authentication-posture audit (--script=vuln,ssh-auth-methods,http-title,http-security-headers,http-methods,ssl-cert,smb-os-discovery,smb-enum-shares,snmp-info,upnp-info,banner) against a LAN device.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "ip": {
                    "type": "string",
                    "description": "Target private LAN IPv4 address (e.g. '192.168.1.38').",
                },
                "ports": {
                    "type": "string",
                    "description": "Optional comma-separated port list (e.g. '22,80,443,8080'). Defaults to common service ports.",
                },
            },
            "required": ["ip"],
        },
    },
    {
        "name": "tyler_traffic_inspect",
        "description": "Capture live packet metadata (DNS queries, TLS SNI server names, mDNS/SSDP broadcast volume, packet rate, and remote peers) for a LAN IP using Kali Linux tshark on eth0.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "ip": {
                    "type": "string",
                    "description": "Target private LAN IPv4 address (e.g. '192.168.1.35').",
                },
                "duration": {
                    "type": "integer",
                    "description": "Capture window in seconds (2 to 20, default: 5).",
                },
            },
            "required": ["ip"],
        },
    },
    {
        "name": "tyler_upnp_audit",
        "description": "Audit the router for unauthorized UPnP IGD port mappings opened by IoT devices on the LAN using Kali miniupnpc.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "description": "'list' (default) to inspect all active UPnP port forwards.",
                }
            },
        },
    },
    {
        "name": "tyler_set_trust",
        "description": "Update the trust classification ('trusted', 'known_iot', 'guest', 'untrusted', 'quarantined'), human label, or forensic notes of a LAN device by MAC address.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "mac": {
                    "type": "string",
                    "description": "Device MAC address (e.g. 'aa:bb:cc:dd:ee:ff').",
                },
                "level": {
                    "type": "string",
                    "description": "Trust level: 'trusted', 'known_iot', 'guest', 'untrusted', or 'quarantined'.",
                },
                "label": {
                    "type": "string",
                    "description": "Optional human-friendly device label.",
                },
                "notes": {
                    "type": "string",
                    "description": "Optional forensic notes.",
                },
            },
            "required": ["mac", "level"],
        },
    },
    {
        "name": "tyler_intervene",
        "description": "Execute an authorized active containment countermeasure or Tier B Defense Plan workflow against a compromised/untrusted LAN IP ('quarantine'/'host_block' for bidirectional iptables DROP + conntrack flush, 'port_block'/'port_unblock' for surgical single-port isolation, 'tcp_reset'/'conntrack_drop' to sever active sessions, 'upnp_kill' to delete a router UPnP forward, 'forensic_snap' to capture a .pcap + conntrack bundle, 'propose_plan' to stage a Tier B DEF-xxxx plan for operator confirmation, 'approve_plan'/'reject_plan'/'list_plans', or 'release'/'host_unblock'). Protected infrastructure and family devices cannot be blocked.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "ip": {
                    "type": "string",
                    "description": "Target LAN IPv4 address (or plan_id when approving/rejecting).",
                },
                "mode": {
                    "type": "string",
                    "description": "Mode: 'host_block', 'quarantine', 'port_block', 'port_unblock', 'tcp_reset', 'conntrack_drop', 'upnp_kill', 'forensic_snap', 'propose_plan', 'approve_plan', 'execute_plan', 'reject_plan', 'list_plans', 'host_unblock', or 'release'.",
                },
                "port": {
                    "type": "integer",
                    "description": "Port number (for 'port_block', 'port_unblock', 'upnp_kill', or 'propose_plan').",
                },
                "proto": {
                    "type": "string",
                    "description": "Protocol for port_block/port_unblock ('tcp', 'udp', or 'both').",
                },
                "duration": {
                    "type": "integer",
                    "description": "Capture window in seconds for 'forensic_snap' (default: 8).",
                },
                "rationale": {
                    "type": "string",
                    "description": "Forensic rationale when staging a Tier B 'propose_plan'.",
                },
                "plan_id": {
                    "type": "string",
                    "description": "Defense plan ID (e.g. 'DEF-38-0123') for 'approve_plan' or 'reject_plan'.",
                },
                "operator_notes": {
                    "type": "string",
                    "description": "Optional operator notes for DPO training alignment.",
                },
            },
            "required": ["mode"],
        },
    },
    {
        "name": "tyler_canary_trap",
        "description": "Deploy, inspect, or disarm T-Cell Canary Honeypot Decoy listeners (TCP 2222 SSH, 2323 Telnet, 4445 SMB, 6379 Redis) to trap compromised LAN devices attempting lateral movement or credential probing.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "description": "'start' to arm decoy listeners, 'status' or 'hits' to inspect active traps and captured probe payloads, 'stop' to disarm, or 'clear' to reset hit history.",
                },
                "ports": {
                    "type": "string",
                    "description": "Optional comma-separated TCP ports to arm (default: '2222,2323,4445,6379').",
                },
                "auto_quarantine": {
                    "type": "boolean",
                    "description": "Optional boolean to enable/disable automatic quarantine when a non-protected IP touches a canary port.",
                },
            },
            "required": ["action"],
        },
    },
    {
        "name": "tyler_tshark_watch",
        "description": "Collaboratively manage custom Kali tshark display/capture filters stored in lan_devices.db and evaluated every 15m by the immune patrol ('list', 'add', 'remove', 'test', or 'run_all'). Automatically validates Wireshark display_filter syntax via dftest/tshark inside george-kali-tyler.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "description": "'list', 'add', 'remove', 'test' (validate syntax), or 'run_all' (evaluate all active filters against live traffic).",
                },
                "name": {
                    "type": "string",
                    "description": "Rule identifier (e.g. 'iot_dns_leak', 'smb_lateral_probe').",
                },
                "display_filter": {
                    "type": "string",
                    "description": "Wireshark/tshark -Y display filter expression (e.g. 'dns and not ip.dst == 192.168.1.1').",
                },
                "bpf_filter": {
                    "type": "string",
                    "description": "Optional libpcap -f capture filter.",
                },
                "extract_fields": {
                    "type": "string",
                    "description": "Optional comma-separated -e fields to extract (default: 'ip.src,ip.dst,eth.src,frame.protocols').",
                },
                "severity": {
                    "type": "string",
                    "description": "'tier_a' (log/forensic) or 'tier_b' (triggers containment plan/reactor).",
                },
                "description": {
                    "type": "string",
                    "description": "Human-readable description of what this filter detects.",
                },
                "duration": {
                    "type": "integer",
                    "description": "Capture duration in seconds when action='run_all' (default: 8).",
                },
            },
            "required": ["action"],
        },
    },
    {
        "name": "tyler_immune_patrol",
        "description": "Execute a Natural Killer (NK) Cell active LAN patrol using Kali tshark (evaluating all enabled tshark_watch_rules), ARP gateway verification, Canary trap inspection, and 30-day rolling retention pruning.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "duration": {
                    "type": "integer",
                    "description": "Live packet patrol window in seconds (3 to 30, default: 10).",
                },
                "auto_quarantine": {
                    "type": "boolean",
                    "description": "If true, automatically quarantine any non-protected LAN IP caught performing lateral scans or rogue DHCP/DNS (default: false).",
                },
            },
        },
    },
    {
        "name": "tyler_arp_shield",
        "description": "Enforce, verify, or release Antibody Layer-2 static ARP neighbor pinning (ip neigh nud permanent) for critical LAN infrastructure (gateway, sovereign host, workstation, hypervisor) so compromised LAN devices cannot ARP-spoof host traffic.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "description": "'enforce' to pin permanent ARP entries, 'verify' to audit kernel neighbor states, or 'release' to revert to dynamic ARP.",
                },
                "ip": {
                    "type": "string",
                    "description": "Optional single LAN IP or 'critical' (default) for all protected infrastructure.",
                },
            },
            "required": ["action"],
        },
    },
    {
        "name": "tyler_baseline_diff",
        "description": "Execute a Memory B-Cell drift audit against a LAN IP (or 'all' online devices) by comparing live Nmap open ports, service banners, TLS certificate SHA-256 thumbprints, and MAC bindings against the stored baseline in lan_devices.db.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "ip": {
                    "type": "string",
                    "description": "Target LAN IPv4 address (e.g. '192.168.1.38') or 'all' to audit all online devices.",
                },
                "save_baseline": {
                    "type": "boolean",
                    "description": "Set true to snapshot the current live state as the trusted baseline in lan_devices.db (default: false).",
                },
            },
            "required": ["ip"],
        },
    },
    {
        "name": "tyler_kali_man",
        "description": "Consult the live Kali Linux manual (man page / --help / NSE script catalog) and Blue Lodge's Tactical Field Manual (active vulnerability auditing, service enumeration, & containment recipes) for any Kali tool inside george-kali-tyler ('catalog', 'nmap', 'tshark', 'arp-scan', 'arping', 'fping', 'hping3', 'p0f', 'whatweb', 'sslscan', 'upnpc', 'avahi-browse', 'snmpwalk', 'smbclient', 'iptables', 'ncat', 'scapy').",
        "inputSchema": {
            "type": "object",
            "properties": {
                "tool": {
                    "type": "string",
                    "description": "Tool name (e.g. 'nmap', 'tshark', 'hping3', 'whatweb', 'sslscan', 'avahi-browse', 'scapy') or 'catalog' to list the full Kali arsenal and tactical recipes.",
                },
                "search": {
                    "type": "string",
                    "description": "Optional keyword, flag, or NSE script pattern to search within the man page (e.g. '-sV', 'script', 'upnp', 'tls', 'syn').",
                },
                "section": {
                    "type": "string",
                    "description": "Optional man page section heading to jump to (e.g. 'EXAMPLES', 'OPTIONS').",
                },
            },
        },
    },
    {
        "name": "tyler_kali_exec",
        "description": "Execute a policy-gated Kali Linux active vulnerability audit, NSE script scan, SNMP/SMB/TLS/HTTP service enumeration, packet capture, or active containment command inside the george-kali-tyler container against the local LAN. Standing operator authorization is granted for active security testing on the local LAN.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "command": {
                    "type": "string",
                    "description": "The Kali Linux shell command to execute inside george-kali-tyler (e.g. \"nmap -Pn -sV --script=vuln,banner,http-title 192.168.1.38\" or \"snmpwalk -v2c -c public 192.168.1.38 .1.3.6.1.2.1.1.1.0\").",
                },
                "timeout": {
                    "type": "integer",
                    "description": "Execution timeout in seconds (3 to 180, default: 60).",
                },
            },
            "required": ["command"],
        },
    },
    {
        "name": "tyler_spelunk",
        "description": "Network-agnostic reconnaissance and stealth defense across any network interface ('discover' attached networks/neighbors with zero packets emitted, 'ghost_listen' zero-emission passive packet capture, 'passive_fingerprint' p0f/DHCP/TLS OS fingerprinting with zero packets emitted, 'surgical_probe', 'block_peer'/'unblock_peer', 'stealth_lockdown'/'stealth_release').",
        "inputSchema": {
            "type": "object",
            "properties": {
                "mode": {
                    "type": "string",
                    "description": "Mode: 'discover', 'ghost_listen', 'passive_fingerprint', 'surgical_probe', 'block_peer', 'unblock_peer', 'stealth_lockdown', or 'stealth_release'.",
                },
                "interface": {
                    "type": "string",
                    "description": "Optional network interface (e.g. 'eth0', 'eth1', 'wlan0').",
                },
                "ip": {
                    "type": "string",
                    "description": "Target peer IPv4 address for 'surgical_probe', 'block_peer', or 'unblock_peer'.",
                },
                "duration": {
                    "type": "integer",
                    "description": "Passive capture window in seconds (2 to 60, default: 10).",
                },
                "ports": {
                    "type": "string",
                    "description": "Comma-separated TCP ports for 'surgical_probe' (default: '22,80,443,445,8080').",
                },
            },
            "required": ["mode"],
        },
    },
    {
        "name": "tyler_wifi_spelunk",
        "description": "802.11 Wireless Airspace Scanner, Compass-Calibrated Property Perimeter Security Guard, Device-Free RF Tomographic Motion & Physical Presence Sensor, Multi-Room Peripheral RF Mesh Poller, RF Time-Series & Fresnel Diagnostic Engine, Dual-Band Spatial Triangulator, Canary Soft-AP Honeypot Monitor, RSA Cast Onboarding Controller, and 6-Layer Airlock Soft-AP Interrogator ('status', 'list_peripherals', 'poll_lan_peripherals', 'perimeter_guard', 'rf_motion_sense', 'diagnose_rf_mesh', 'rogue_ap_watch', 'scan_airspace', 'configure_adapter', 'interrogate_soft_ap', 'triangulate_airspace', 'canary_ap_watch', 'set_ap_beacon', 'provision_cast_ap', 'restore_peripheral', 'disconnect').",
        "inputSchema": {
            "type": "object",
            "properties": {
                "mode": {
                    "type": "string",
                    "description": "Mode: 'status', 'list_peripherals', 'poll_lan_peripherals', 'perimeter_guard', 'rf_motion_sense', 'diagnose_rf_mesh', 'rogue_ap_watch', 'scan_airspace', 'configure_adapter', 'interrogate_soft_ap', 'triangulate_airspace', 'canary_ap_watch', 'set_ap_beacon', 'provision_cast_ap', 'restore_peripheral', or 'disconnect'.",
                },
                "ssid": {
                    "type": "string",
                    "description": "Target wireless SSID for 'interrogate_soft_ap', 'configure_adapter', 'provision_cast_ap' (target Wi-Fi to join), or 'set_ap_beacon'.",
                },
                "bssid": {
                    "type": "string",
                    "description": "Optional target peripheral BSSID MAC address (e.g. '02:00:5e:00:01:02').",
                },
                "auth": {
                    "type": "string",
                    "description": "Authentication mode for 'configure_adapter' ('open', 'WPA2PSK', 'WPA3SAE') or 'fdr' for factory reset in 'provision_cast_ap'.",
                },
                "key": {
                    "type": "string",
                    "description": "Optional WPA passphrase for 'configure_adapter' or RSA-encrypted onboarding in 'provision_cast_ap'.",
                },
                "surprise": {
                    "type": "boolean",
                    "description": "If true during 'perimeter_guard', run a live 6-Layer Airlock dual-band scan refresh on the South-Wall Lenovo Smart Clock; if true during 'rf_motion_sense', recalibrate quiet-room RF baselines; if true during 'interrogate_soft_ap' or 'canary_ap_watch', trigger a physically observable chime/decoy lure.",
                },
                "surprise_name": {
                    "type": "string",
                    "description": "Optional custom friendly name, decoy SSID ('canary_ap_watch'), or beacon text ('set_ap_beacon').",
                },
                "timeout": {
                    "type": "integer",
                    "description": "Sampling window in seconds for 'perimeter_guard' or 'rf_motion_sense' (default: 6), history hours for 'diagnose_rf_mesh' (default: 24), or airlock timeout in seconds (default: 45).",
                },
            },
            "required": ["mode"],
        },
    },
]


def handle_tool(name: str, args: dict) -> str:
    if name == "tyler_lan_census":
        refresh = args.get("refresh", True)
        res = tg.run_lan_census() if refresh else tg.get_tyler_status()
        return json.dumps(res, indent=2)
    elif name == "tyler_deep_fingerprint":
        return json.dumps(tg.deep_fingerprint_device(str(args.get("ip", ""))), indent=2)
    elif name == "tyler_vuln_audit":
        return json.dumps(
            tg.audit_device_vulnerabilities(
                ip=str(args.get("ip", "")),
                ports=args.get("ports"),
            ),
            indent=2,
        )
    elif name == "tyler_traffic_inspect":
        dur = int(args.get("duration", 5) or 5)
        return json.dumps(tg.inspect_traffic_metadata(str(args.get("ip", "")), dur), indent=2)
    elif name == "tyler_upnp_audit":
        return json.dumps(tg.audit_upnp(str(args.get("action", "list"))), indent=2)
    elif name == "tyler_set_trust":
        return json.dumps(
            tg.set_device_trust(
                mac=str(args.get("mac", "")),
                level=str(args.get("level", "untrusted")),
                label=args.get("label"),
                notes=args.get("notes"),
            ),
            indent=2,
        )
    elif name == "tyler_intervene":
        return json.dumps(
            tg.intervene_device(
                ip=str(args.get("ip", "")),
                mode=str(args.get("mode", "host_block")),
                port=int(args["port"]) if args.get("port") is not None else None,
                proto=str(args.get("proto", "tcp")),
                duration=int(args.get("duration", 8) or 8),
                rationale=str(args.get("rationale", "")),
                plan_id=str(args.get("plan_id", "")),
                operator_notes=str(args.get("operator_notes", "")),
            ),
            indent=2,
        )
    elif name == "tyler_canary_trap":
        return json.dumps(
            tg.manage_canary_trap(
                action=str(args.get("action", "status")),
                ports=args.get("ports"),
                auto_quarantine=args.get("auto_quarantine"),
            ),
            indent=2,
        )
    elif name == "tyler_tshark_watch":
        return json.dumps(
            tg.manage_tshark_watch(
                action=str(args.get("action", "list")),
                name=args.get("name"),
                display_filter=args.get("display_filter"),
                bpf_filter=args.get("bpf_filter"),
                extract_fields=args.get("extract_fields"),
                severity=str(args.get("severity", "tier_b")),
                description=str(args.get("description", "")),
                duration=int(args.get("duration", 8) or 8),
            ),
            indent=2,
        )
    elif name == "tyler_immune_patrol":
        return json.dumps(
            tg.run_immune_patrol(
                duration=int(args.get("duration", 10) or 10),
                auto_quarantine=bool(args.get("auto_quarantine", False)),
            ),
            indent=2,
        )
    elif name == "tyler_arp_shield":
        return json.dumps(
            tg.manage_arp_shield(
                action=str(args.get("action", "verify")),
                ip=args.get("ip"),
            ),
            indent=2,
        )
    elif name == "tyler_baseline_diff":
        return json.dumps(
            tg.diff_device_baseline(
                ip=str(args.get("ip", "all")),
                save_baseline=bool(args.get("save_baseline", False)),
            ),
            indent=2,
        )
    elif name == "tyler_kali_man":
        return json.dumps(
            tg.kali_man_lookup(
                tool=str(args.get("tool", "catalog")),
                search=args.get("search"),
                section=args.get("section"),
            ),
            indent=2,
        )
    elif name == "tyler_kali_exec":
        return json.dumps(
            tg.kali_exec_tool(
                command=str(args.get("command", "")),
                timeout=int(args.get("timeout", 60) or 60),
            ),
            indent=2,
        )
    elif name == "tyler_spelunk":
        return json.dumps(
            tg.spelunk_network(
                mode=str(args.get("mode", "discover")),
                interface=args.get("interface"),
                ip=args.get("ip"),
                duration=int(args.get("duration", 10) or 10),
                ports=str(args.get("ports", "22,80,443,445,8080")),
            ),
            indent=2,
        )
    elif name == "tyler_wifi_spelunk":
        return json.dumps(
            tg.wifi_spelunk(
                mode=str(args.get("mode", "scan_airspace")),
                ssid=args.get("ssid"),
                bssid=args.get("bssid"),
                auth=str(args.get("auth", "open")),
                key=args.get("key"),
                timeout=int(args.get("timeout", 45) or 45),
                surprise=bool(args.get("surprise", False)),
                surprise_name=args.get("surprise_name"),
            ),
            indent=2,
        )
    else:
        raise ValueError(f"Unknown tool: {name}")


_STDOUT_LOCK = threading.Lock()


def _write_resp(resp: dict) -> None:
    line = json.dumps(resp) + "\n"
    with _STDOUT_LOCK:
        sys.stdout.write(line)
        sys.stdout.flush()


def _run_tool_call(req_id: object, tname: str, targs: dict) -> None:
    try:
        out = handle_tool(tname, targs)
        resp = {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {"content": [{"type": "text", "text": out}]},
        }
    except Exception as e:
        resp = {
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32000, "message": str(e)},
        }
    _write_resp(resp)


def main() -> None:
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
            except Exception:
                continue

            req_id = req.get("id")
            method = req.get("method")

            if method == "initialize":
                _write_resp(
                    {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {
                            "protocolVersion": "2024-11-05",
                            "capabilities": {"tools": {}},
                            "serverInfo": {"name": "george-tyler", "version": "1.1"},
                        },
                    }
                )
            elif method == "tools/list":
                _write_resp(
                    {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {"tools": TOOLS_SCHEMA},
                    }
                )
            elif method == "tools/call":
                params = req.get("params", {})
                tname = params.get("name", "")
                targs = params.get("arguments", {}) or {}
                pool.submit(_run_tool_call, req_id, tname, targs)


if __name__ == "__main__":
    main()

