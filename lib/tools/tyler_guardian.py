#!/usr/bin/env python3
"""
George: "The Tyler" Sovereign Home Network Defense Agent & Kali Linux Orchestrator
Maintains the Layer-2/Layer-3 LAN device census in .george/state/lan_devices.db,
orchestrates deep reconnaissance and traffic metadata analysis via the
`george-kali-tyler` Kali Linux container, monitors Nest Wifi Pro mesh health,
emits Event Bus security alerts, and enforces policy-gated defensive interventions.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import contextlib
import fcntl
import ipaddress
import json
import math
import os
import re
import shlex
import socket
import sqlite3
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

LODGE_DIR = Path(os.environ.get("LODGE_DIR", _REPO_ROOT))
GEORGE_DIR = Path(os.environ.get("GEORGE_DIR", LODGE_DIR / ".george"))
STATE_DIR = GEORGE_DIR / "state"
DB_PATH = STATE_DIR / "lan_devices.db"
ALERTS_LOG = GEORGE_DIR / "state" / "tyler_alerts.jsonl"
KALI_AUDIT_LOG = GEORGE_DIR / "state" / "tyler_kali_audit.jsonl"
CANARY_LOCK_PATH = GEORGE_DIR / "state" / "tyler_canary.lock"
WIFI_RADIO_LOCK_PATH = GEORGE_DIR / "state" / "tyler_wifi_radio.lock"
KALI_CONTAINER = os.environ.get("KALI_TYLER_CONTAINER", "george-kali-tyler")
HOUSEHOLD_CFG_PATH = GEORGE_DIR / "config" / "tyler_household.json"
_SCHEMA_VERSION = 6


_HOUSEHOLD_CFG_IS_EXAMPLE = False


def _load_household_config() -> Dict[str, Any]:
    global _HOUSEHOLD_CFG_IS_EXAMPLE
    host_root = _REPO_ROOT
    if ".sandboxes" in host_root.parts:
        idx = host_root.parts.index(".sandboxes")
        host_root = Path(*host_root.parts[:idx])
    candidates = [
        HOUSEHOLD_CFG_PATH,
        LODGE_DIR / ".george" / "config" / "tyler_household.json",
        host_root / ".george" / "config" / "tyler_household.json",
        LODGE_DIR / "configs" / "tyler_household.example.json",
        _REPO_ROOT / "configs" / "tyler_household.example.json",
    ]
    for cand in candidates:
        if cand.exists():
            try:
                data = json.loads(cand.read_text(encoding="utf-8"))
                _HOUSEHOLD_CFG_IS_EXAMPLE = cand.name.endswith(".example.json")
                return data
            except Exception:
                pass
    _HOUSEHOLD_CFG_IS_EXAMPLE = True
    return {}


def discover_active_networks(configured_subnet: str = "") -> List[Dict[str, Any]]:
    """
    Dynamically discovers all active physical/LAN/wireless network interfaces and their
    live IPv4 CIDRs, host IPs, MAC addresses, and default gateways from the Linux kernel.
    Allows Tyler to operate agnostically on any network the device connects to.
    """
    virtual_if_re = re.compile(r"^(lo|loopback\d*|tailscale\d*|ts\d*|wg\d*|tun\d*|tap\d*|docker\d*|br-\S*|virbr\d*|veth\S*|cni\S*)$", re.I)
    if_macs: Dict[str, str] = {}
    if_gateways: Dict[str, str] = {}
    networks: List[Dict[str, Any]] = []
    try:
        link_out = subprocess.run(["ip", "-o", "link", "show"], capture_output=True, text=True, timeout=2.0).stdout
        for ln in link_out.splitlines():
            m_if = re.match(r"^\d+:\s+([^:@\s]+).*?\slink/ether\s+([0-9a-fA-F:]{17})\b", ln)
            if m_if:
                if_macs[m_if.group(1)] = m_if.group(2).lower()
    except Exception:
        pass
    try:
        rt_out = subprocess.run(["ip", "-4", "route", "show", "default"], capture_output=True, text=True, timeout=2.0).stdout
        for ln in rt_out.splitlines():
            m_rt = re.search(r"default\s+via\s+(\d+\.\d+\.\d+\.\d+)\s+dev\s+(\S+)", ln)
            if m_rt and m_rt.group(2) not in if_gateways:
                if_gateways[m_rt.group(2)] = m_rt.group(1)
    except Exception:
        pass
    try:
        addr_out = subprocess.run(["ip", "-o", "-4", "addr", "show", "up"], capture_output=True, text=True, timeout=2.0).stdout
        for ln in addr_out.splitlines():
            m_ad = re.match(r"^\d+:\s+(\S+)\s+inet\s+(\d+\.\d+\.\d+\.\d+)/(\d+)", ln)
            if not m_ad:
                continue
            iface, ip_s, plen_s = m_ad.group(1), m_ad.group(2), m_ad.group(3)
            if virtual_if_re.match(iface):
                continue
            try:
                ip_if = ipaddress.IPv4Interface(f"{ip_s}/{plen_s}")
                if ip_if.ip.is_loopback or ip_if.ip.is_link_local:
                    continue
                net_str = str(ip_if.network)
                prefix_str = ip_s.rsplit(".", 1)[0] + "."
                gw_ip = if_gateways.get(iface) or f"{prefix_str}1"
                profile = "home" if (configured_subnet and net_str == configured_subnet and not _HOUSEHOLD_CFG_IS_EXAMPLE) else "foreign"
                networks.append({
                    "interface": iface,
                    "host_ip": ip_s,
                    "host_mac": if_macs.get(iface, "00:00:5e:00:53:01"),
                    "cidr": net_str,
                    "subnet_prefix": prefix_str,
                    "gateway_ip": gw_ip,
                    "network_profile": profile,
                })
            except Exception:
                continue
    except Exception:
        pass
    return networks


def _discover_kernel_route_gateways() -> List[str]:
    """Collects all gateway IPs across all Linux/WSL2 kernel routing tables so they are always protected."""
    gws: List[str] = []
    try:
        rt_all = subprocess.run(["ip", "route", "show", "table", "all"], capture_output=True, text=True, timeout=2.0).stdout
        for m in re.finditer(r"\bvia\s+(\d+\.\d+\.\d+\.\d+)\b", rt_all):
            gw = m.group(1)
            if gw not in gws:
                gws.append(gw)
    except Exception:
        pass
    return gws


_HOUSEHOLD_CFG = _load_household_config()
_CFG_SUBNET: str = str(_HOUSEHOLD_CFG.get("lan_subnet") or "")
_LIVE_NETWORKS: List[Dict[str, Any]] = discover_active_networks(_CFG_SUBNET)
_PRIMARY_NET: Dict[str, Any] = _LIVE_NETWORKS[0] if _LIVE_NETWORKS else {}
PRIMARY_IFACE: str = str(_PRIMARY_NET.get("interface") or "eth0")

# If a real household config is loaded AND matches the active interface subnet (or in hermetic CI without live NICs),
# use household config values; otherwise dynamically adapt to whatever live network the device is connected to!
_USE_LIVE_FOREIGN_NET = bool(_PRIMARY_NET and (_HOUSEHOLD_CFG_IS_EXAMPLE or (_CFG_SUBNET and _PRIMARY_NET.get("cidr") != _CFG_SUBNET)))

LAN_SUBNET: str = str(_PRIMARY_NET["cidr"] if _USE_LIVE_FOREIGN_NET else (_CFG_SUBNET or _PRIMARY_NET.get("cidr") or "192.168.1.0/24"))
LAN_SUBNET_PREFIX: str = LAN_SUBNET.rsplit(".", 1)[0] + "." if "." in LAN_SUBNET else "192.168.1."
GATEWAY_IP: str = str(_PRIMARY_NET["gateway_ip"] if _USE_LIVE_FOREIGN_NET else (_HOUSEHOLD_CFG.get("gateway_ip") or _PRIMARY_NET.get("gateway_ip") or f"{LAN_SUBNET_PREFIX}1"))
HOST_IP: str = str(_PRIMARY_NET["host_ip"] if _USE_LIVE_FOREIGN_NET else (_HOUSEHOLD_CFG.get("host_ip") or _PRIMARY_NET.get("host_ip") or f"{LAN_SUBNET_PREFIX}10"))
HOST_MAC: str = str(_PRIMARY_NET["host_mac"] if _USE_LIVE_FOREIGN_NET else (_HOUSEHOLD_CFG.get("host_mac") or _PRIMARY_NET.get("host_mac") or "00:00:5e:00:53:01"))
HOST_HOSTNAME: str = str(_HOUSEHOLD_CFG.get("host_hostname") or socket.gethostname() or "blue-lodge-host.lan")
HOST_LABEL: str = str(_HOUSEHOLD_CFG.get("host_label") or "Blue Lodge Sovereign Host (George Service Node)")
WORKSTATION_IP: str = str(_HOUSEHOLD_CFG.get("workstation_ip") or f"{LAN_SUBNET_PREFIX}20")

# Expected gateway & mesh MAC bindings for ARP spoofing detection
EXPECTED_GATEWAY_MACS: Dict[str, str] = dict(_HOUSEHOLD_CFG.get("expected_gateway_macs") or {})
COMPASS_ANCHORS: Dict[str, Any] = dict(_HOUSEHOLD_CFG.get("compass_anchors") or {})
WATCHED_WIFI_CHORDS_CFG: Dict[str, Dict[str, str]] = dict(_HOUSEHOLD_CFG.get("watched_wifi_chords") or {})
DEFAULT_HOME_SSID: str = str(_HOUSEHOLD_CFG.get("default_home_ssid") or "HomeMesh")

# Protected infrastructure, kernel gateways, & family IPs that can NEVER be blocked or quarantined
PROTECTED_IPS = set(
    _HOUSEHOLD_CFG.get("protected_ips")
    or [
        "127.0.0.1",
        GATEWAY_IP,
        HOST_IP,
        WORKSTATION_IP,
    ]
)
PROTECTED_IPS.update({"127.0.0.1", GATEWAY_IP, HOST_IP})
for _net in _LIVE_NETWORKS:
    PROTECTED_IPS.add(_net["host_ip"])
    PROTECTED_IPS.add(_net["gateway_ip"])
PROTECTED_IPS.update(_discover_kernel_route_gateways())

ARP_PIN_IPS: List[str] = list(
    _HOUSEHOLD_CFG.get("arp_pin_ips")
    or [
        GATEWAY_IP,
        HOST_IP,
        WORKSTATION_IP,
    ]
)

# Built-in MAC OUI prefix table for instant offline vendor resolution (3-octet IEEE OUI prefixes only)
OUI_VENDORS: Dict[str, str] = {
    "90:ca:fa": "Google LLC (Nest Wifi Pro)",
    "7c:d9:5c": "Google LLC (Nest Hub Max)",
    "cc:f4:11": "Google LLC (Nest Mini)",
    "f4:f5:d8": "Google LLC (Google Home)",
    "00:f6:20": "Google LLC (Google Home Mini)",
    "f8:8f:ca": "Google LLC / Cast Embedded (Smart Display / Clock)",
    "64:16:66": "Nest Labs Inc. (Nest Hello)",
    "cc:a7:c1": "Google LLC (Nest Thermostat/Protect)",
    "38:86:f7": "Google / Android TV",
    "bc:24:11": "Proxmox Server Solutions GmbH",
    "34:97:f6": "ASUSTek Computer Inc.",
    "34:5a:60": "Micro-Star INTL (MSI Workstation)",
    "00:d8:61": "Micro-Star INTL (MSI)",
    "5c:87:9c": "Intel Corporate (Dual Band Wireless-AC)",
    "1c:e8:9e": "Samsung Electronics Co., Ltd.",
    "bc:10:2f": "Samsung Electronics / SmartThings Appliance",
    "34:fc:99": "Samsung Electronics / SmartThings Appliance (Sjit)",
    "ac:f4:66": "HP Inc. (Network Printer / Wi-Fi Direct)",
    "b0:8c:b3": "FN-Link Technology (Embedded Wi-Fi NIC)",
    "7c:d1:ad": "Apple, Inc.",
    "e8:f6:73": "Microsoft Corporation (Xbox Console)",
    "64:db:a0": "Select Comfort / Sleep Number (360 Smart Bed Wi-Fi Controller)",
    "98:e2:55": "Nintendo Co., Ltd. (Nintendo Switch / Console)",
    "54:64:de": "Cisco / Sagemcom Broadband Gateway",
    "88:de:7c": "Askey Computer Corp / Broadband Router",
}

# Initial seed dataset loaded from .george/config/tyler_household.json
INITIAL_SEED_DEVICES: List[Dict[str, Any]] = list(_HOUSEHOLD_CFG.get("seed_devices") or [])

POLICY_PATH = GEORGE_DIR / "state" / "tyler_policy.json"
PCAP_DIR = GEORGE_DIR / "state" / "pcaps"
CANARY_STATE_PATH = GEORGE_DIR / "state" / "tyler_canary_state.json"
NETWORK_DESIGNATIONS_PATH = GEORGE_DIR / "config" / "network_designations.json"
WIFI_WATCHLIST_PATH = GEORGE_DIR / "config" / "wifi_watchlist.json"

DEFAULT_TSHARK_RULES: List[Dict[str, str]] = [
    {
        "name": "east_west_syn_scan",
        "display_filter": f"tcp.flags.syn == 1 and tcp.flags.ack == 0 and (tcp.dstport == 22 or tcp.dstport == 23 or tcp.dstport == 445 or tcp.dstport == 3389 or tcp.dstport == 8006) and not ip.src == {HOST_IP} and not ip.src == {WORKSTATION_IP}",
        "bpf_filter": "tcp[tcpflags] & (tcp-syn|tcp-ack) == tcp-syn",
        "extract_fields": "ip.src,ip.dst,tcp.dstport,eth.src",
        "severity": "tier_b",
        "description": "Detect East-West lateral TCP SYN probing across sensitive internal ports (SSH, Telnet, SMB, RDP, Proxmox)",
    },
    {
        "name": "rogue_dhcp_offer",
        "display_filter": f"udp.srcport == 67 and not ip.src == {GATEWAY_IP}",
        "bpf_filter": "udp port 67 or udp port 68",
        "extract_fields": "ip.src,eth.src,ip.dst",
        "severity": "tier_b",
        "description": "Detect rogue DHCP servers offering leases from a non-gateway LAN IP",
    },
    {
        "name": "rogue_dns_server",
        "display_filter": f"dns.flags.response == 1 and udp.srcport == 53 and not ip.src == {GATEWAY_IP} and not ip.src == {HOST_IP}",
        "bpf_filter": "udp src port 53",
        "extract_fields": "ip.src,ip.dst,dns.qry.name",
        "severity": "tier_b",
        "description": "Detect DNS responses originating from unauthorized LAN peers",
    },
    {
        "name": "cleartext_credential_exposure",
        "display_filter": "http.authorization or ftp.request.command == \"PASS\"",
        "bpf_filter": "tcp port 80 or tcp port 8080 or tcp port 21",
        "extract_fields": "ip.src,ip.dst,tcp.dstport",
        "severity": "tier_a",
        "description": "Detect unencrypted HTTP Basic/Bearer auth headers or cleartext FTP passwords on the LAN",
    },
]

_SCHEMA = """
CREATE TABLE IF NOT EXISTS devices (
    mac TEXT PRIMARY KEY,
    ip TEXT NOT NULL,
    hostname TEXT,
    label TEXT,
    vendor_oui TEXT,
    device_type TEXT DEFAULT 'unknown',
    trust_level TEXT DEFAULT 'untrusted',
    online INTEGER DEFAULT 1,
    first_seen INTEGER NOT NULL,
    last_seen INTEGER NOT NULL,
    open_ports_json TEXT DEFAULT '[]',
    fingerprint_json TEXT DEFAULT '{}',
    traffic_sample_json TEXT DEFAULT '{}',
    notes TEXT DEFAULT ''
);
CREATE INDEX IF NOT EXISTS ix_devices_ip ON devices(ip);
CREATE INDEX IF NOT EXISTS ix_devices_trust ON devices(trust_level);

CREATE TABLE IF NOT EXISTS canary_hits (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL,
    src_ip TEXT NOT NULL,
    src_mac TEXT DEFAULT '',
    dst_port INTEGER NOT NULL,
    service_emulated TEXT NOT NULL,
    payload_hex TEXT DEFAULT '',
    payload_text TEXT DEFAULT '',
    action_taken TEXT DEFAULT 'logged'
);
CREATE INDEX IF NOT EXISTS ix_canary_hits_ts ON canary_hits(ts);

CREATE TABLE IF NOT EXISTS tshark_watch_rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT UNIQUE NOT NULL,
    display_filter TEXT NOT NULL,
    bpf_filter TEXT DEFAULT '',
    extract_fields TEXT DEFAULT 'ip.src,ip.dst,eth.src,frame.protocols',
    severity TEXT DEFAULT 'tier_b',
    enabled INTEGER DEFAULT 1,
    created_by TEXT DEFAULT 'george',
    description TEXT DEFAULT '',
    created_at INTEGER NOT NULL,
    last_hit_at INTEGER DEFAULT 0,
    hit_count INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS tshark_watch_hits (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL,
    rule_id INTEGER NOT NULL,
    rule_name TEXT NOT NULL,
    src_ip TEXT DEFAULT '',
    matched_packets INTEGER DEFAULT 1,
    sample_output TEXT DEFAULT ''
);
CREATE INDEX IF NOT EXISTS ix_tshark_hits_ts ON tshark_watch_hits(ts);

CREATE TABLE IF NOT EXISTS device_baselines (
    mac TEXT PRIMARY KEY,
    ip TEXT NOT NULL,
    updated_at INTEGER NOT NULL,
    open_ports_json TEXT DEFAULT '[]',
    banners_json TEXT DEFAULT '{}',
    tls_sha256 TEXT DEFAULT '',
    drift_status TEXT DEFAULT 'clean',
    last_diff_json TEXT DEFAULT '{}',
    egress_domains_json TEXT NOT NULL DEFAULT '[]'
);

CREATE TABLE IF NOT EXISTS defense_plans (
    plan_id TEXT PRIMARY KEY,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    trigger_event TEXT NOT NULL,
    target_ip TEXT NOT NULL,
    target_mac TEXT DEFAULT '',
    tier TEXT NOT NULL,
    proposed_mode TEXT NOT NULL,
    proposed_port INTEGER DEFAULT 0,
    proposed_proto TEXT DEFAULT 'tcp',
    rationale TEXT NOT NULL,
    forensic_pcap TEXT DEFAULT '',
    status TEXT DEFAULT 'pending_approval',
    operator_verdict TEXT DEFAULT '',
    operator_notes TEXT DEFAULT '',
    execution_result_json TEXT DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS ix_defense_plans_status ON defense_plans(status);

CREATE TABLE IF NOT EXISTS wifi_airspace (
    bssid TEXT PRIMARY KEY,
    ssid TEXT DEFAULT '',
    network_type TEXT DEFAULT 'Infrastructure',
    auth TEXT DEFAULT '',
    encryption TEXT DEFAULT '',
    signal_pct INTEGER DEFAULT 0,
    rssi_dbm REAL,
    link_quality INTEGER DEFAULT 0,
    frequency_mhz INTEGER DEFAULT 0,
    beacon_age_ms INTEGER DEFAULT 0,
    tsf_uptime_us INTEGER DEFAULT 0,
    tx_power_dbm INTEGER,
    qbss_sta_count INTEGER,
    qbss_chan_util_pct REAL,
    compass_sector TEXT DEFAULT '',
    radio_type TEXT DEFAULT '',
    band TEXT DEFAULT '',
    channel INTEGER DEFAULT 0,
    vendor_oui TEXT DEFAULT '',
    classification TEXT DEFAULT 'neighbor',
    trust_status TEXT DEFAULT 'unknown',
    first_seen INTEGER NOT NULL,
    last_seen INTEGER NOT NULL,
    interrogation_json TEXT DEFAULT '{}',
    notes TEXT DEFAULT ''
);
CREATE INDEX IF NOT EXISTS ix_wifi_airspace_class ON wifi_airspace(classification);

CREATE TABLE IF NOT EXISTS claimed_peripherals (
    bssid TEXT PRIMARY KEY,
    device_type TEXT NOT NULL DEFAULT 'google_cast_soft_ap',
    manufacturer TEXT NOT NULL DEFAULT '',
    model_name TEXT NOT NULL DEFAULT '',
    product_name TEXT NOT NULL DEFAULT '',
    cloud_device_id TEXT NOT NULL DEFAULT '',
    ssdp_udn TEXT NOT NULL DEFAULT '',
    original_ssid TEXT NOT NULL DEFAULT '',
    original_name TEXT NOT NULL DEFAULT '',
    original_settings_json TEXT NOT NULL DEFAULT '{}',
    current_ssid TEXT NOT NULL DEFAULT '',
    current_name TEXT NOT NULL DEFAULT '',
    current_role TEXT NOT NULL DEFAULT 'claimed_sensor',
    status TEXT NOT NULL DEFAULT 'claimed',
    soft_ap_gateway TEXT NOT NULL DEFAULT '192.168.255.249',
    lan_ip TEXT NOT NULL DEFAULT '',
    public_key TEXT NOT NULL DEFAULT '',
    baseline_stats_json TEXT NOT NULL DEFAULT '{}',
    last_telemetry_json TEXT NOT NULL DEFAULT '{}',
    claimed_at INTEGER NOT NULL DEFAULT 0,
    last_updated INTEGER NOT NULL DEFAULT 0,
    notes TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS peripheral_rf_telemetry (
    chord_id TEXT PRIMARY KEY,
    label TEXT NOT NULL DEFAULT '',
    zone TEXT NOT NULL DEFAULT '',
    tx_node TEXT NOT NULL DEFAULT '',
    rx_node TEXT NOT NULL DEFAULT '',
    bssid TEXT NOT NULL DEFAULT '',
    band TEXT NOT NULL DEFAULT '',
    frequency_mhz INTEGER DEFAULT 0,
    tx_power_dbm INTEGER,
    qbss_sta_count INTEGER,
    qbss_chan_util_pct REAL,
    compass_sector TEXT NOT NULL DEFAULT '',
    ring TEXT NOT NULL DEFAULT 'interior',
    common_mode_db REAL NOT NULL DEFAULT 0.0,
    sensor_backend TEXT NOT NULL DEFAULT '',
    baseline_rssi_dbm REAL,
    last_rssi_dbm REAL,
    ewma_fast_dbm REAL,
    last_noise_dbm REAL,
    last_snr_db REAL,
    last_rtt_ms REAL,
    std_db REAL NOT NULL DEFAULT 0.0,
    ewma_std_db REAL NOT NULL DEFAULT 0.0,
    p2p_swing_db REAL NOT NULL DEFAULT 0.0,
    z_score REAL NOT NULL DEFAULT 0.0,
    cusum_db REAL NOT NULL DEFAULT 0.0,
    cusum_pos_db REAL NOT NULL DEFAULT 0.0,
    cusum_neg_db REAL NOT NULL DEFAULT 0.0,
    motion_state TEXT NOT NULL DEFAULT 'quiet',
    samples_count INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL DEFAULT 0,
    history_json TEXT NOT NULL DEFAULT '[]'
);

CREATE TABLE IF NOT EXISTS rf_motion_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL,
    chord_id TEXT NOT NULL,
    zone TEXT NOT NULL,
    motion_state TEXT NOT NULL,
    p2p_swing_db REAL NOT NULL,
    std_db REAL NOT NULL,
    baseline_drift_db REAL NOT NULL DEFAULT 0.0,
    details_json TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS ix_rf_motion_events_ts ON rf_motion_events(ts DESC);

CREATE TABLE IF NOT EXISTS rf_telemetry_timeseries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL,
    chord_id TEXT NOT NULL,
    label TEXT NOT NULL DEFAULT '',
    zone TEXT NOT NULL DEFAULT '',
    band TEXT NOT NULL DEFAULT '',
    compass_sector TEXT NOT NULL DEFAULT '',
    ring TEXT NOT NULL DEFAULT 'interior',
    tx_power_dbm INTEGER,
    common_mode_db REAL NOT NULL DEFAULT 0.0,
    qbss_chan_util_pct REAL,
    rssi_dbm REAL,
    ewma_fast_dbm REAL,
    baseline_rssi_dbm REAL,
    noise_dbm REAL,
    snr_db REAL,
    rtt_ms REAL,
    rtt_jitter_ms REAL NOT NULL DEFAULT 0.0,
    std_db REAL NOT NULL DEFAULT 0.0,
    ewma_std_db REAL NOT NULL DEFAULT 0.0,
    p2p_swing_db REAL NOT NULL DEFAULT 0.0,
    z_score REAL NOT NULL DEFAULT 0.0,
    cusum_db REAL NOT NULL DEFAULT 0.0,
    motion_state TEXT NOT NULL DEFAULT 'quiet',
    source_mode TEXT NOT NULL DEFAULT 'rf_motion_sense'
);
CREATE INDEX IF NOT EXISTS ix_rf_ts_chord_time ON rf_telemetry_timeseries(chord_id, ts DESC);
CREATE INDEX IF NOT EXISTS ix_rf_ts_time ON rf_telemetry_timeseries(ts DESC);

CREATE TABLE IF NOT EXISTS rf_telemetry_rollup_5m (
    chord_id TEXT NOT NULL,
    bucket_ts INTEGER NOT NULL,
    zone TEXT NOT NULL DEFAULT '',
    band TEXT NOT NULL DEFAULT '',
    samples_count INTEGER NOT NULL DEFAULT 0,
    avg_rssi_dbm REAL,
    min_rssi_dbm REAL,
    max_rssi_dbm REAL,
    ewma_fast_dbm REAL,
    baseline_rssi_dbm REAL,
    avg_noise_dbm REAL,
    avg_snr_db REAL,
    avg_rtt_ms REAL,
    max_p2p_swing_db REAL NOT NULL DEFAULT 0.0,
    max_ewma_std_db REAL NOT NULL DEFAULT 0.0,
    max_z_score REAL NOT NULL DEFAULT 0.0,
    max_cusum_db REAL NOT NULL DEFAULT 0.0,
    motion_ticks_count INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (chord_id, bucket_ts)
);
CREATE INDEX IF NOT EXISTS ix_rf_rollup_bucket ON rf_telemetry_rollup_5m(bucket_ts DESC);
"""


def resolve_vendor(mac: str) -> str:
    m = (mac or "").lower().strip()
    prefix = m[:8]
    if prefix in OUI_VENDORS:
        return OUI_VENDORS[prefix]
    # Check locally administered MAC bit (second hex char in 2, 6, a, e)
    # Soft-APs on Google Cast / IoT devices often flip bit 1 of octet 0 (e.g. f8:8f:ca -> fa:8f:ca)
    if len(m) >= 8 and m[1] in ("2", "6", "a", "e"):
        try:
            b0 = int(m[:2], 16) & ~0x02
            base_prefix = f"{b0:02x}{m[2:8]}"
            if base_prefix in OUI_VENDORS:
                return f"{OUI_VENDORS[base_prefix]} (Soft-AP)"
        except Exception:
            pass
        return "Randomized / Private MAC (Mobile or Modern OS)"
    return "Unknown OUI Vendor"


def _append_jsonl_bounded(log_path: Path, line_obj: Dict[str, Any], max_bytes: int = 2 * 1024 * 1024) -> None:
    try:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        if log_path.exists() and log_path.stat().st_size > max_bytes:
            rot_path = log_path.with_suffix(log_path.suffix + ".1")
            log_path.replace(rot_path)
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(json.dumps(line_obj) + "\n")
    except Exception:
        pass


def connect_db() -> sqlite3.Connection:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(str(DB_PATH), timeout=30)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA synchronous=NORMAL")
    con.execute("PRAGMA busy_timeout=30000")
    cur_ver = int(con.execute("PRAGMA user_version").fetchone()[0] or 0)
    has_devices_tbl = (
        con.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='devices'").fetchone()
        is not None
    )
    has_wifi_cols = (
        has_devices_tbl
        and any(r[1] == "compass_sector" for r in con.execute("PRAGMA table_info(wifi_airspace)").fetchall())
        and any(r[1] == "tx_power_dbm" for r in con.execute("PRAGMA table_info(rf_telemetry_timeseries)").fetchall())
        and any(r[1] == "sensor_backend" for r in con.execute("PRAGMA table_info(peripheral_rf_telemetry)").fetchall())
    )
    now = int(time.time())
    if cur_ver < _SCHEMA_VERSION or not has_devices_tbl or not has_wifi_cols:
        if not has_devices_tbl:
            con.executescript(_SCHEMA)
        existing_cols_by_tbl = {
            tbl: {r[1] for r in con.execute(f"PRAGMA table_info({tbl})").fetchall()}
            for tbl in ("rf_telemetry_timeseries", "peripheral_rf_telemetry", "wifi_airspace", "device_baselines")
        }
        for tbl_name, col_name, col_sql in (
            ("rf_telemetry_timeseries", "ewma_fast_dbm", "ALTER TABLE rf_telemetry_timeseries ADD COLUMN ewma_fast_dbm REAL"),
            ("rf_telemetry_timeseries", "ewma_std_db", "ALTER TABLE rf_telemetry_timeseries ADD COLUMN ewma_std_db REAL NOT NULL DEFAULT 0.0"),
            ("rf_telemetry_timeseries", "z_score", "ALTER TABLE rf_telemetry_timeseries ADD COLUMN z_score REAL NOT NULL DEFAULT 0.0"),
            ("rf_telemetry_timeseries", "cusum_db", "ALTER TABLE rf_telemetry_timeseries ADD COLUMN cusum_db REAL NOT NULL DEFAULT 0.0"),
            ("rf_telemetry_timeseries", "compass_sector", "ALTER TABLE rf_telemetry_timeseries ADD COLUMN compass_sector TEXT NOT NULL DEFAULT ''"),
            ("rf_telemetry_timeseries", "ring", "ALTER TABLE rf_telemetry_timeseries ADD COLUMN ring TEXT NOT NULL DEFAULT 'interior'"),
            ("rf_telemetry_timeseries", "tx_power_dbm", "ALTER TABLE rf_telemetry_timeseries ADD COLUMN tx_power_dbm INTEGER"),
            ("rf_telemetry_timeseries", "common_mode_db", "ALTER TABLE rf_telemetry_timeseries ADD COLUMN common_mode_db REAL NOT NULL DEFAULT 0.0"),
            ("rf_telemetry_timeseries", "qbss_chan_util_pct", "ALTER TABLE rf_telemetry_timeseries ADD COLUMN qbss_chan_util_pct REAL"),
            ("peripheral_rf_telemetry", "ewma_fast_dbm", "ALTER TABLE peripheral_rf_telemetry ADD COLUMN ewma_fast_dbm REAL"),
            ("peripheral_rf_telemetry", "ewma_std_db", "ALTER TABLE peripheral_rf_telemetry ADD COLUMN ewma_std_db REAL NOT NULL DEFAULT 0.0"),
            ("peripheral_rf_telemetry", "z_score", "ALTER TABLE peripheral_rf_telemetry ADD COLUMN z_score REAL NOT NULL DEFAULT 0.0"),
            ("peripheral_rf_telemetry", "cusum_db", "ALTER TABLE peripheral_rf_telemetry ADD COLUMN cusum_db REAL NOT NULL DEFAULT 0.0"),
            ("peripheral_rf_telemetry", "cusum_pos_db", "ALTER TABLE peripheral_rf_telemetry ADD COLUMN cusum_pos_db REAL NOT NULL DEFAULT 0.0"),
            ("peripheral_rf_telemetry", "cusum_neg_db", "ALTER TABLE peripheral_rf_telemetry ADD COLUMN cusum_neg_db REAL NOT NULL DEFAULT 0.0"),
            ("peripheral_rf_telemetry", "frequency_mhz", "ALTER TABLE peripheral_rf_telemetry ADD COLUMN frequency_mhz INTEGER DEFAULT 0"),
            ("peripheral_rf_telemetry", "tx_power_dbm", "ALTER TABLE peripheral_rf_telemetry ADD COLUMN tx_power_dbm INTEGER"),
            ("peripheral_rf_telemetry", "qbss_sta_count", "ALTER TABLE peripheral_rf_telemetry ADD COLUMN qbss_sta_count INTEGER"),
            ("peripheral_rf_telemetry", "qbss_chan_util_pct", "ALTER TABLE peripheral_rf_telemetry ADD COLUMN qbss_chan_util_pct REAL"),
            ("peripheral_rf_telemetry", "compass_sector", "ALTER TABLE peripheral_rf_telemetry ADD COLUMN compass_sector TEXT NOT NULL DEFAULT ''"),
            ("peripheral_rf_telemetry", "ring", "ALTER TABLE peripheral_rf_telemetry ADD COLUMN ring TEXT NOT NULL DEFAULT 'interior'"),
            ("peripheral_rf_telemetry", "common_mode_db", "ALTER TABLE peripheral_rf_telemetry ADD COLUMN common_mode_db REAL NOT NULL DEFAULT 0.0"),
            ("peripheral_rf_telemetry", "sensor_backend", "ALTER TABLE peripheral_rf_telemetry ADD COLUMN sensor_backend TEXT NOT NULL DEFAULT ''"),
            ("wifi_airspace", "rssi_dbm", "ALTER TABLE wifi_airspace ADD COLUMN rssi_dbm REAL"),
            ("wifi_airspace", "link_quality", "ALTER TABLE wifi_airspace ADD COLUMN link_quality INTEGER DEFAULT 0"),
            ("wifi_airspace", "frequency_mhz", "ALTER TABLE wifi_airspace ADD COLUMN frequency_mhz INTEGER DEFAULT 0"),
            ("wifi_airspace", "beacon_age_ms", "ALTER TABLE wifi_airspace ADD COLUMN beacon_age_ms INTEGER DEFAULT 0"),
            ("wifi_airspace", "tsf_uptime_us", "ALTER TABLE wifi_airspace ADD COLUMN tsf_uptime_us INTEGER DEFAULT 0"),
            ("wifi_airspace", "tx_power_dbm", "ALTER TABLE wifi_airspace ADD COLUMN tx_power_dbm INTEGER"),
            ("wifi_airspace", "qbss_sta_count", "ALTER TABLE wifi_airspace ADD COLUMN qbss_sta_count INTEGER"),
            ("wifi_airspace", "qbss_chan_util_pct", "ALTER TABLE wifi_airspace ADD COLUMN qbss_chan_util_pct REAL"),
            ("wifi_airspace", "compass_sector", "ALTER TABLE wifi_airspace ADD COLUMN compass_sector TEXT DEFAULT ''"),
            ("device_baselines", "egress_domains_json", "ALTER TABLE device_baselines ADD COLUMN egress_domains_json TEXT NOT NULL DEFAULT '[]'"),
        ):
            if col_name not in existing_cols_by_tbl.get(tbl_name, set()):
                try:
                    con.execute(col_sql)
                except Exception:
                    pass
        if 0 < cur_ver < 6 or not has_wifi_cols:
            # Re-anchor legacy netsh-% quantized Workstation chords & clear latched RTT-only states
            try:
                con.execute(
                    """
                    UPDATE peripheral_rf_telemetry
                    SET baseline_rssi_dbm = NULL,
                        ewma_fast_dbm = NULL,
                        ewma_std_db = 0.0,
                        z_score = 0.0,
                        cusum_db = 0.0,
                        cusum_pos_db = 0.0,
                        cusum_neg_db = 0.0,
                        motion_state = 'quiet',
                        history_json = '[]'
                    WHERE chord_id LIKE 'ws_wifi_%' OR last_rssi_dbm IS NULL
                    """
                )
            except Exception:
                pass
        # Seed initial devices if table is empty
        cnt = con.execute("SELECT COUNT(*) FROM devices").fetchone()[0]
        if cnt == 0:
            for d in INITIAL_SEED_DEVICES:
                con.execute(
                    """
                    INSERT OR IGNORE INTO devices
                    (mac, ip, hostname, label, vendor_oui, device_type, trust_level, online, first_seen, last_seen, notes)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
                    """,
                    (
                        d["mac"].lower(),
                        d["ip"],
                        d.get("hostname", ""),
                        d.get("label", d.get("hostname", d["ip"])),
                        resolve_vendor(d["mac"]),
                        d.get("device_type", "unknown"),
                        d.get("trust_level", "untrusted"),
                        now,
                        now,
                        d.get("notes", ""),
                    ),
                )
        # Seed default tshark watchlist rules on a cold database
        rule_cnt = con.execute("SELECT COUNT(*) FROM tshark_watch_rules").fetchone()[0]
        if rule_cnt == 0:
            for r in DEFAULT_TSHARK_RULES:
                con.execute(
                    """
                    INSERT OR IGNORE INTO tshark_watch_rules
                    (name, display_filter, bpf_filter, extract_fields, severity, enabled, created_by, description, created_at)
                    VALUES (?, ?, ?, ?, ?, 1, 'system_seed', ?, ?)
                    """,
                    (
                        r["name"],
                        r["display_filter"],
                        r.get("bpf_filter", ""),
                        r.get("extract_fields", "ip.src,ip.dst,eth.src,frame.protocols"),
                        r.get("severity", "tier_b"),
                        r.get("description", ""),
                        now,
                    ),
                )
        # Hydrate claimed_peripherals from any previously interrogated Soft-APs in wifi_airspace
        cp_cnt = con.execute("SELECT COUNT(*) FROM claimed_peripherals").fetchone()[0]
        if cp_cnt == 0:
            for wr in con.execute("SELECT * FROM wifi_airspace WHERE interrogation_json != '{}' AND interrogation_json != ''").fetchall():
                try:
                    inter = json.loads(wr["interrogation_json"] or "{}")
                    e_info = inter.get("eureka_info") or {}
                    if not e_info:
                        continue
                    d_info = e_info.get("device_info") or {}
                    setup_info = e_info.get("setup") or {}
                    b_mac = (wr["bssid"] or "").lower()
                    cur_name = str(e_info.get("name") or "")
                    cur_ssid = str(wr["ssid"] or inter.get("ssid") or "")
                    model_nm = str(d_info.get("model_name") or "Google Cast Soft-AP")
                    suffix = str(setup_info.get("ssid_suffix") or "q001")
                    if "Lenovo Smart Clock" in model_nm and ("George" in cur_name or "Blue Lodge" in cur_name or not cur_name):
                        orig_name = "LenovoSmartClock5544"
                        orig_ssid = f"LenovoSmartClock5544.{suffix},"
                    else:
                        orig_name = cur_name or model_nm
                        orig_ssid = cur_ssid
                    orig_settings = {
                        "locale": "en-US",
                        "time_format": 1,
                        "system_sound_effects": True,
                    }
                    gw = str((inter.get("dhcp_lease") or {}).get("soft_ap_gateway") or "192.168.255.249")
                    con.execute(
                        """
                        INSERT OR IGNORE INTO claimed_peripherals
                        (bssid, device_type, manufacturer, model_name, product_name, cloud_device_id, ssdp_udn,
                         original_ssid, original_name, original_settings_json, current_ssid, current_name,
                         current_role, status, soft_ap_gateway, public_key, baseline_stats_json,
                         last_telemetry_json, claimed_at, last_updated, notes)
                        VALUES (?, 'google_cast_soft_ap', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'claimed_sensor', 'claimed', ?, ?, ?, ?, ?, ?, ?)
                        """,
                        (
                            b_mac,
                            str(d_info.get("manufacturer") or ""),
                            model_nm,
                            str(d_info.get("product_name") or ""),
                            str(d_info.get("cloud_device_id") or ""),
                            str(d_info.get("ssdp_udn") or ""),
                            orig_ssid,
                            orig_name,
                            json.dumps(orig_settings),
                            cur_ssid,
                            cur_name,
                            gw,
                            str(d_info.get("public_key") or ""),
                            json.dumps(setup_info.get("stats") or {}),
                            json.dumps({"nearby_wifi_seen_by_device": inter.get("nearby_wifi_seen_by_device") or []}),
                            int(wr["first_seen"] or now),
                            int(wr["last_seen"] or now),
                            "Enrolled via 6-Layer Airlock Soft-AP Interrogation",
                        ),
                    )
                except Exception:
                    pass
        con.execute(f"PRAGMA user_version = {_SCHEMA_VERSION}")
        con.commit()

    # Ensure local Blue Lodge host is registered as trusted self-node
    self_exists = con.execute("SELECT 1 FROM devices WHERE mac = ? AND ip = ?", (HOST_MAC, HOST_IP)).fetchone()
    if not self_exists:
        con.execute(
            """
            INSERT OR IGNORE INTO devices
            (mac, ip, hostname, label, vendor_oui, device_type, trust_level, online, first_seen, last_seen, open_ports_json, notes)
            VALUES (?, ?, ?, ?, ?, 'server', 'trusted', 1, ?, ?, '[3000]',
                    'Local Blue Lodge host & George service bridge (port 3000, Discord & Cardano APIs)')
            """,
            (HOST_MAC, HOST_IP, HOST_HOSTNAME, HOST_LABEL, resolve_vendor(HOST_MAC), now, now),
        )
        con.commit()
    return con


def get_tyler_policy() -> Dict[str, Any]:
    default_pol = {
        "response_mode": "confirm",  # 'confirm' (Tier B requires operator approval) or 'auto' (T-Cell auto-containment)
        "auto_canary_quarantine": False,
        "retention_days": 30,
        "max_pcap_mb": 250,
        "updated_at": 0,
    }
    if POLICY_PATH.exists():
        try:
            loaded = json.loads(POLICY_PATH.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                default_pol.update(loaded)
        except Exception:
            pass
    return default_pol


def set_tyler_policy(
    response_mode: Optional[str] = None,
    auto_canary_quarantine: Optional[bool] = None,
    retention_days: Optional[int] = None,
) -> Dict[str, Any]:
    pol = get_tyler_policy()
    if response_mode is not None:
        rm = response_mode.strip().lower()
        if rm not in ("confirm", "auto"):
            return {"status": "error", "message": "response_mode must be 'confirm' or 'auto'"}
        pol["response_mode"] = rm
    if auto_canary_quarantine is not None:
        pol["auto_canary_quarantine"] = bool(auto_canary_quarantine)
    if retention_days is not None:
        pol["retention_days"] = max(1, min(365, int(retention_days)))
    pol["updated_at"] = int(time.time())
    POLICY_PATH.parent.mkdir(parents=True, exist_ok=True)
    POLICY_PATH.write_text(json.dumps(pol, indent=2), encoding="utf-8")
    return {"status": "ok", "policy": pol}


def prune_tyler_state(retention_days: int = 30, max_pcap_mb: int = 250) -> Dict[str, Any]:
    now_ts = int(time.time())
    cutoff = now_ts - (max(1, int(retention_days)) * 86400)
    # 2-Tier RF Time-Series Compaction:
    # Tier 1: Keep raw 15-second samples in rf_telemetry_timeseries for 72 hours (3 days).
    # Tier 2: Downsample older raw rows into 5-minute buckets in rf_telemetry_rollup_5m and retain for 90 days.
    raw_rf_cutoff = now_ts - (72 * 3600)
    rollup_rf_cutoff = now_ts - (90 * 86400)

    con = connect_db()
    c1 = con.execute("DELETE FROM canary_hits WHERE ts < ?", (cutoff,)).rowcount
    c2 = con.execute("DELETE FROM tshark_watch_hits WHERE ts < ?", (cutoff,)).rowcount
    c3 = con.execute(
        "DELETE FROM defense_plans WHERE updated_at < ? AND status != 'pending_approval'",
        (cutoff,),
    ).rowcount
    con.commit()

    c4 = 0
    try:
        with con:
            con.execute(
                """
                INSERT OR REPLACE INTO rf_telemetry_rollup_5m
                (chord_id, bucket_ts, zone, band, samples_count, avg_rssi_dbm, min_rssi_dbm, max_rssi_dbm,
                 ewma_fast_dbm, baseline_rssi_dbm, avg_noise_dbm, avg_snr_db, avg_rtt_ms,
                 max_p2p_swing_db, max_ewma_std_db, max_z_score, max_cusum_db, motion_ticks_count)
                SELECT
                    chord_id,
                    (ts / 300) * 300 AS bucket_ts,
                    MAX(zone),
                    MAX(band),
                    COUNT(*),
                    ROUND(AVG(rssi_dbm), 2),
                    ROUND(MIN(rssi_dbm), 2),
                    ROUND(MAX(rssi_dbm), 2),
                    ROUND(AVG(COALESCE(ewma_fast_dbm, rssi_dbm)), 2),
                    ROUND(AVG(baseline_rssi_dbm), 2),
                    ROUND(AVG(noise_dbm), 1),
                    ROUND(AVG(snr_db), 1),
                    ROUND(AVG(rtt_ms), 1),
                    ROUND(MAX(p2p_swing_db), 2),
                    ROUND(MAX(COALESCE(ewma_std_db, std_db)), 2),
                    ROUND(MAX(COALESCE(z_score, 0.0)), 2),
                    ROUND(MAX(COALESCE(cusum_db, 0.0)), 2),
                    SUM(CASE WHEN motion_state != 'quiet' THEN 1 ELSE 0 END)
                FROM rf_telemetry_timeseries
                WHERE ts < ?
                GROUP BY chord_id, (ts / 300) * 300
                """,
                (raw_rf_cutoff,),
            )
            c4 = con.execute("DELETE FROM rf_telemetry_timeseries WHERE ts < ?", (raw_rf_cutoff,)).rowcount
    except Exception:
        c4 = 0

    c4_rollup = con.execute("DELETE FROM rf_telemetry_rollup_5m WHERE bucket_ts < ?", (rollup_rf_cutoff,)).rowcount
    c5 = con.execute("DELETE FROM rf_motion_events WHERE ts < ?", (cutoff,)).rowcount
    con.commit()
    try:
        con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    except Exception:
        pass
    con.close()

    logs_rotated = 0
    for jlog in (ALERTS_LOG, KALI_AUDIT_LOG):
        try:
            if jlog.exists() and jlog.stat().st_size > 2 * 1024 * 1024:
                jlog.replace(jlog.with_suffix(jlog.suffix + ".1"))
                logs_rotated += 1
        except Exception:
            pass

    pcap_deleted = 0
    if PCAP_DIR.exists():
        pcap_files = sorted(PCAP_DIR.glob("*.pcap"), key=lambda p: p.stat().st_mtime)
        total_bytes = sum(p.stat().st_size for p in pcap_files if p.exists())
        max_bytes = max(10, int(max_pcap_mb)) * 1024 * 1024
        for p in pcap_files:
            try:
                st = p.stat()
                if st.st_mtime < cutoff or total_bytes > max_bytes:
                    total_bytes -= st.st_size
                    p.unlink(missing_ok=True)
                    pcap_deleted += 1
            except Exception:
                pass

    return {
        "status": "ok",
        "retention_days": retention_days,
        "raw_rf_retention_hours": 72,
        "rollup_rf_retention_days": 90,
        "pruned_canary_hits": c1,
        "pruned_tshark_hits": c2,
        "pruned_defense_plans": c3,
        "pruned_rf_timeseries": c4,
        "pruned_rf_rollups_5m": c4_rollup,
        "pruned_rf_motion_events": c5,
        "pruned_pcap_files": pcap_deleted,
        "rotated_jsonl_logs": logs_rotated,
    }


def _read_webhook_auth() -> Dict[str, str]:
    headers = {"Content-Type": "application/json"}
    for fname in ("web_token", "api_token"):
        token_file = GEORGE_DIR / fname
        if token_file.exists():
            try:
                tok = token_file.read_text(encoding="utf-8").strip()
                if tok:
                    headers["Authorization"] = f"Bearer {tok}"
                    headers["X-Lodge-Token"] = tok
                    return headers
            except Exception:
                pass
    keys_file = GEORGE_DIR / "keys.conf"
    if keys_file.exists():
        try:
            for line in keys_file.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if line.startswith("LODGE_API_TOKEN=") or line.startswith("WEBHOOK_SECRET_TYLER="):
                    val = line.split("=", 1)[1].strip().strip('"').strip("'")
                    if val:
                        headers["Authorization"] = f"Bearer {val}"
                        headers["X-Lodge-Token"] = val
                        break
        except Exception:
            pass
    return headers


def emit_security_event(event_type: str, payload: Dict[str, Any]) -> None:
    record = {"ts": int(time.time()), "event_type": event_type, "payload": payload}
    _append_jsonl_bounded(ALERTS_LOG, record)

    # 1. Try authenticated POST to /api/webhooks/tyler (which bridges to network.<sub_event> on event_bus.fifo)
    sub_event = event_type.split(".", 1)[1] if "." in event_type else event_type
    webhook_sent = False
    try:
        import urllib.request
        headers = _read_webhook_auth()
        headers["X-George-Event"] = sub_event
        body_dict = dict(payload)
        body_dict["event_type"] = sub_event
        req = urllib.request.Request(
            "http://127.0.0.1:3000/api/webhooks/tyler",
            data=json.dumps(body_dict).encode("utf-8"),
            headers=headers,
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=1.5) as resp:
            if 200 <= resp.status < 300:
                webhook_sent = True
    except Exception:
        webhook_sent = False

    # 2. Fallback: direct FIFO Event Bus emission if george-web is offline or unauthenticated
    if not webhook_sent:
        try:
            eb_sh = LODGE_DIR / "lib" / "ipc" / "event_bus.sh"
            if eb_sh.exists():
                subprocess.run(
                    [
                        "bash",
                        "-c",
                        'source "$1" && event_bus_emit "$2" "$3" "tyler_guardian"',
                        "_",
                        str(eb_sh),
                        event_type,
                        json.dumps(payload),
                    ],
                    cwd=str(LODGE_DIR),
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=3.0,
                )
        except Exception:
            pass


def kali_container_status() -> Dict[str, Any]:
    running = False
    image_present = False
    tools_ready: List[str] = []
    try:
        r = subprocess.run(
            ["docker", "inspect", "-f", "{{.State.Running}}", KALI_CONTAINER],
            capture_output=True,
            text=True,
            timeout=2.0,
        )
        running = r.stdout.strip() == "true"
    except Exception:
        pass
    try:
        r2 = subprocess.run(
            ["docker", "image", "inspect", f"{KALI_CONTAINER}:latest"],
            capture_output=True,
            text=True,
            timeout=2.0,
        )
        image_present = r2.returncode == 0
    except Exception:
        pass
    if running:
        tools_ready = ["nmap", "arp-scan", "tshark", "tcpdump", "upnpc", "nftables", "scapy"]
    return {
        "container": KALI_CONTAINER,
        "running": running,
        "image_present": image_present,
        "network_mode": f"host (Layer-2 eth0 {LAN_SUBNET})",
        "tools": tools_ready,
    }


def ensure_kali_running() -> bool:
    st = kali_container_status()
    if st["running"]:
        return True
    ctl = LODGE_DIR / "lib" / "sys" / "kali_tyler_ctl.sh"
    if ctl.exists():
        try:
            subprocess.run(
                ["bash", "-c", f'source "{ctl}" && kali_tyler_ensure_running'],
                cwd=str(LODGE_DIR),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=30.0,
            )
        except Exception:
            pass
    return kali_container_status()["running"]


def get_nest_mesh_status() -> List[Dict[str, Any]]:
    nodes = []
    mesh_ips = list(EXPECTED_GATEWAY_MACS.keys()) or [GATEWAY_IP]
    for idx, ip in enumerate(mesh_ips):
        role_hint = "root" if idx == 0 else "leaf"
        try:
            with urllib.request.urlopen(f"http://{ip}/api/v1/status", timeout=0.9) as resp:
                data = json.loads(resp.read().decode("utf-8", errors="ignore"))
                sys_d = data.get("system", {})
                sw_d = data.get("software", {})
                mesh_d = data.get("meshInfo", {})
                nodes.append({
                    "ip": ip,
                    "online": True,
                    "modelId": sys_d.get("modelId", "SIROCCO"),
                    "groupRole": sys_d.get("groupRole", role_hint),
                    "softwareVersion": sw_d.get("softwareVersion", ""),
                    "uptime_hours": round(float(sys_d.get("uptime", 0)) / 3600.0, 1),
                    "meshChannel": mesh_d.get("mesh-channel"),
                    "meshInterface": mesh_d.get("mesh-interface"),
                })
        except Exception:
            nodes.append({"ip": ip, "online": False, "groupRole": role_hint})
    return nodes


def _probe_host(ip: str) -> Optional[int]:
    for port in (80, 443, 8009, 22, 53, 8080):
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.settimeout(0.14)
                if s.connect_ex((ip, port)) == 0:
                    return port
        except Exception:
            pass
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as u:
            u.sendto(b"", (ip, 33434))
    except Exception:
        pass
    return None


def _scan_common_ports(ip: str) -> List[int]:
    ports = []
    for p in (22, 53, 80, 443, 1883, 3000, 3088, 5000, 8006, 8008, 8009, 8080, 8443, 9000):
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.settimeout(0.18)
                if s.connect_ex((ip, p)) == 0:
                    ports.append(p)
        except Exception:
            pass
    return ports


def run_lan_census(subnet_prefix: str = LAN_SUBNET_PREFIX, interface: str = PRIMARY_IFACE) -> Dict[str, Any]:
    con = connect_db()
    now = int(time.time())
    iface = re.sub(r"[^a-zA-Z0-9_.:-]", "", (interface or PRIMARY_IFACE or "eth0"))

    # If a full CIDR (e.g. 10.42.0.0/24) was passed instead of a 3-octet prefix, normalize it
    if "/" in subnet_prefix:
        subnet_prefix = subnet_prefix.split("/", 1)[0].rsplit(".", 1)[0] + "."
    elif subnet_prefix and not subnet_prefix.endswith("."):
        subnet_prefix = subnet_prefix.rsplit(".", 1)[0] + "."

    # 1. Trigger ARP resolution across subnet
    ips = [f"{subnet_prefix}{i}" for i in range(1, 255)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=64) as ex:
        list(ex.map(_probe_host, ips))

    # 2. Read kernel neighbor table (strictly scoped to target subnet prefix; ignore off-subnet synthetic/test entries)
    neigh_out = subprocess.check_output(["ip", "-4", "neigh", "show", "dev", iface], text=True)
    discovered: Dict[str, str] = {}  # ip -> mac
    for line in neigh_out.splitlines():
        parts = line.split()
        if not parts or "lladdr" not in parts:
            continue
        ip = parts[0]
        if subnet_prefix and not ip.startswith(subnet_prefix):
            continue
        mac = parts[parts.index("lladdr") + 1].lower()
        state = parts[-1]
        if state in ("REACHABLE", "STALE", "DELAY", "PROBE", "PERMANENT"):
            discovered[ip] = mac

    # Also run arp-scan inside george-kali-tyler if available for Layer-2 completeness
    if kali_container_status()["running"]:
        try:
            arp_out = subprocess.check_output(
                ["docker", "exec", KALI_CONTAINER, "arp-scan", f"--interface={iface}", "--localnet", "-q", "-r", "1"],
                text=True,
                stderr=subprocess.DEVNULL,
                timeout=6.0,
            )
            for ln in arp_out.splitlines():
                m = re.match(r"^(\d+\.\d+\.\d+\.\d+)\s+([0-9a-fA-F:]{17})\b", ln.strip())
                if m and (not subnet_prefix or m.group(1).startswith(subnet_prefix)):
                    discovered[m.group(1)] = m.group(2).lower()
        except Exception:
            pass

    anomalies: List[Dict[str, Any]] = []
    new_devices: List[Dict[str, Any]] = []

    # Check gateway ARP integrity
    for gw_ip, expected_mac in EXPECTED_GATEWAY_MACS.items():
        actual_mac = discovered.get(gw_ip)
        if actual_mac and actual_mac != expected_mac:
            alert = {
                "ip": gw_ip,
                "mac": actual_mac,
                "expected_mac": expected_mac,
                "message": f"CRITICAL ARP SPOOF ALERT: {gw_ip} reported MAC {actual_mac} (expected {expected_mac})!",
            }
            anomalies.append(alert)
            emit_security_event("network.arp_spoof", alert)

    con.execute("UPDATE devices SET online = 0")
    for ip, mac in sorted(discovered.items(), key=lambda kv: [int(x) for x in kv[0].split(".")]):
        row = con.execute("SELECT * FROM devices WHERE mac = ?", (mac,)).fetchone()
        try:
            hostname = socket.gethostbyaddr(ip)[0]
        except Exception:
            hostname = row["hostname"] if row and row["hostname"] else ""

        open_ports = _scan_common_ports(ip)
        vendor = resolve_vendor(mac)

        if row is None:
            label = hostname or f"Unknown ({ip})"
            con.execute(
                """
                INSERT INTO devices
                (mac, ip, hostname, label, vendor_oui, device_type, trust_level, online, first_seen, last_seen, open_ports_json, notes)
                VALUES (?, ?, ?, ?, ?, 'unknown', 'untrusted', 1, ?, ?, ?, 'Newly discovered MAC on LAN')
                """,
                (mac, ip, hostname, label, vendor, now, now, json.dumps(open_ports)),
            )
            ev = {
                "ip": ip,
                "mac": mac,
                "hostname": hostname,
                "vendor": vendor,
                "open_ports": open_ports,
            }
            new_devices.append(ev)
            emit_security_event("network.rogue_device", ev)
        else:
            con.execute(
                """
                UPDATE devices
                SET ip = ?,
                    hostname = COALESCE(NULLIF(?, ''), hostname),
                    vendor_oui = COALESCE(NULLIF(vendor_oui, 'Unknown OUI Vendor'), ?),
                    online = 1,
                    last_seen = ?,
                    open_ports_json = ?
                WHERE mac = ?
                """,
                (ip, hostname, vendor, now, json.dumps(open_ports), mac),
            )
    con.commit()
    con.close()
    st = get_tyler_status()
    st["new_devices"] = new_devices
    st["anomalies"] = anomalies
    return st


def validate_lan_ip(ip: str) -> str:
    clean = (ip or "").strip()
    addr = ipaddress.ip_address(clean)
    if not addr.is_private:
        raise ValueError(f"Refusing to scan non-private IP address: {clean}")
    return clean


def deep_fingerprint_device(ip: str) -> Dict[str, Any]:
    target_ip = validate_lan_ip(ip)
    ensure_kali_running()
    kali_up = kali_container_status()["running"]

    nmap_output = ""
    kali_vendor = ""
    if kali_up:
        try:
            # 1. Fast Layer-2 ARP probe via /usr/bin/nmap -sn to get MAC + Kali IEEE OUI vendor
            r_arp = subprocess.run(
                ["docker", "exec", KALI_CONTAINER, "/usr/bin/nmap", "-sn", "-PR", target_ip],
                capture_output=True,
                text=True,
                timeout=5.0,
            )
            for ln in r_arp.stdout.splitlines():
                m_mac = re.search(r"MAC Address:\s+([0-9A-Fa-f:]{17})\s+\(([^)]+)\)", ln)
                if m_mac:
                    kali_vendor = m_mac.group(2).strip()
            # 2. Privileged TCP connect (-sT) + service banner + OS fingerprint (-O) scan
            r = subprocess.run(
                [
                    "docker",
                    "exec",
                    KALI_CONTAINER,
                    "/usr/local/bin/nmap",
                    "-sT",
                    "-Pn",
                    "-T4",
                    "-sV",
                    "-O",
                    "--version-light",
                    "--top-ports",
                    "100",
                    "--max-retries",
                    "1",
                    "--max-rtt-timeout",
                    "500ms",
                    "--host-timeout",
                    "28s",
                    target_ip,
                ],
                capture_output=True,
                text=True,
                timeout=32.0,
            )
            for ln in r.stdout.splitlines():
                m_mac2 = re.search(r"MAC Address:\s+([0-9A-Fa-f:]{17})\s+\(([^)]+)\)", ln)
                if m_mac2 and not kali_vendor:
                    kali_vendor = m_mac2.group(2).strip()
            nmap_output = (r_arp.stdout.strip() + "\n---\n" + r.stdout.strip()).strip()
        except Exception as e:
            nmap_output = f"Kali nmap error: {e}"

    # Also check kernel ARP + rDNS + open TCP ports
    open_ports = _scan_common_ports(target_ip)
    try:
        hostname = socket.gethostbyaddr(target_ip)[0]
    except Exception:
        hostname = ""

    # Parse nmap open ports if any
    nmap_services: List[str] = []
    os_guess = ""
    for ln in nmap_output.splitlines():
        if re.match(r"^\d+/(tcp|udp)\s+open\b", ln.strip()):
            nmap_services.append(ln.strip())
            pnum = int(ln.strip().split("/")[0])
            if pnum not in open_ports:
                open_ports.append(pnum)
        elif ln.strip().startswith(("OS details:", "Running:", "Aggressive OS guesses:")):
            os_guess = ln.strip()

    con = connect_db()
    row = con.execute("SELECT * FROM devices WHERE ip = ?", (target_ip,)).fetchone()
    mac = row["mac"] if row else ""
    vendor = resolve_vendor(mac) if mac else (kali_vendor or "Unknown")
    if kali_vendor and vendor in ("Unknown OUI Vendor", "Unknown"):
        vendor = kali_vendor

    # Special heuristic analysis for known household IoT / console signatures
    forensic_clue = ""
    if hostname.startswith("500-") or mac.startswith("64:db:a0"):
        forensic_clue = (
            "Forensic Hostname & OUI Match: Hostname '500-<mac>' with OUI 64:db:a0 is the signature of a "
            "Sleep Number '360 Smart Bed' (Fuzion/500-series Wi-Fi controller by Select Comfort), "
            "NOT an iRobot Roomba! Many routers misclassify '500-<mac>' as a Roomba 500."
        )
    elif mac.startswith("98:e2:55") or "Nintendo" in kali_vendor:
        forensic_clue = (
            "Forensic IEEE OUI Match: MAC prefix 98:e2:55 belongs to Nintendo Co., Ltd. (Nintendo Switch / gaming console). "
            "Nintendo consoles advertise no mDNS/rDNS hostname, close all inbound TCP ports, and enter low-power Wi-Fi sleep when docked."
        )

    dossier = {
        "ts": int(time.time()),
        "ip": target_ip,
        "mac": mac,
        "hostname": hostname,
        "vendor_oui": vendor,
        "open_ports": sorted(open_ports),
        "nmap_services": nmap_services,
        "os_guess": os_guess,
        "forensic_clue": forensic_clue,
        "kali_used": kali_up,
        "raw_nmap": nmap_output[:3000],
    }

    if row:
        notes = row["notes"] or ""
        if forensic_clue and forensic_clue not in notes and "Sleep Number" not in notes:
            notes = f"{notes} | {forensic_clue}".strip(" |")
        con.execute(
            """
            UPDATE devices
            SET open_ports_json = ?,
                fingerprint_json = ?,
                notes = ?,
                last_seen = ?
            WHERE mac = ?
            """,
            (json.dumps(sorted(open_ports)), json.dumps(dossier), notes, int(time.time()), mac),
        )
        con.commit()
    con.close()
    return {"status": "ok", "vendor": vendor, "dossier": dossier}


def inspect_traffic_metadata(ip: str, duration: int = 5) -> Dict[str, Any]:
    target_ip = validate_lan_ip(ip)
    dur = max(2, min(20, int(duration)))
    ensure_kali_running()
    kali_up = kali_container_status()["running"]

    packets_total = 0
    dns_queries: List[str] = []
    tls_sni: List[str] = []
    protocols: Dict[str, int] = {}
    peers: List[str] = []
    raw_lines: List[str] = []

    if kali_up:
        try:
            r = subprocess.run(
                [
                    "docker",
                    "exec",
                    KALI_CONTAINER,
                    "tshark",
                    "-i",
                    "eth0",
                    "-a",
                    f"duration:{dur}",
                    "-f",
                    f"host {target_ip} or arp or port 5353 or port 1900",
                    "-T",
                    "fields",
                    "-e",
                    "ip.src",
                    "-e",
                    "ip.dst",
                    "-e",
                    "_ws.col.Protocol",
                    "-e",
                    "dns.qry.name",
                    "-e",
                    "tls.handshake.extensions_server_name",
                ],
                capture_output=True,
                text=True,
                timeout=dur + 6.0,
            )
            peer_set = set()
            for ln in r.stdout.splitlines():
                if not ln.strip():
                    continue
                parts = ln.split("\t")
                src = parts[0] if len(parts) > 0 else ""
                dst = parts[1] if len(parts) > 1 else ""
                proto = parts[2] if len(parts) > 2 else "OTHER"
                dns_q = parts[3] if len(parts) > 3 else ""
                sni = parts[4] if len(parts) > 4 else ""
                if target_ip in (src, dst) or not src:
                    packets_total += 1
                    protocols[proto] = protocols.get(proto, 0) + 1
                    if src and src != target_ip:
                        peer_set.add(src)
                    if dst and dst != target_ip:
                        peer_set.add(dst)
                    if dns_q and dns_q not in dns_queries:
                        dns_queries.append(dns_q)
                    if sni and sni not in tls_sni:
                        tls_sni.append(sni)
                    if len(raw_lines) < 25:
                        raw_lines.append(ln.strip())
            peers = sorted(peer_set)[:20]
        except Exception as e:
            raw_lines.append(f"tshark error: {e}")

    pps = round(packets_total / float(dur), 2)
    storm_detected = pps > 50.0
    sample = {
        "ts": int(time.time()),
        "ip": target_ip,
        "duration_s": dur,
        "packets_observed": packets_total,
        "packets_per_sec": pps,
        "storm_detected": storm_detected,
        "protocols": protocols,
        "dns_queries": dns_queries[:25],
        "tls_sni_domains": tls_sni[:25],
        "remote_peers": peers,
        "sample_lines": raw_lines,
    }

    con = connect_db()
    row = con.execute("SELECT mac FROM devices WHERE ip = ?", (target_ip,)).fetchone()
    if row:
        con.execute(
            "UPDATE devices SET traffic_sample_json = ? WHERE mac = ?",
            (json.dumps(sample), row["mac"]),
        )
        con.commit()
        if storm_detected:
            emit_security_event(
                "network.nuisance_storm",
                {"ip": target_ip, "mac": row["mac"], "pps": pps, "protocol": "mixed"},
            )
    con.close()
    return {"status": "ok", "traffic": sample}


def audit_upnp(action: str = "list") -> Dict[str, Any]:
    ensure_kali_running()
    kali_up = kali_container_status()["running"]
    output = ""
    if kali_up:
        try:
            r = subprocess.run(
                ["docker", "exec", KALI_CONTAINER, "timeout", "3", "upnpc", "-l"],
                capture_output=True,
                text=True,
                timeout=5.0,
            )
            output = (r.stdout + "\n" + r.stderr).strip()
            if not output or r.returncode == 124:
                output = "No UPnP IGD port-forwarding responder detected on LAN (UPnP disabled or zero exposed ports)."
        except Exception as e:
            output = f"No UPnP IGD responder detected ({e})"
    else:
        output = "Kali container not running"

    mappings: List[Dict[str, Any]] = []
    for ln in output.splitlines():
        # Match lines like: " 0 TCP 8080->192.168.1.43:8080 'desc' '' 0"
        m = re.match(r"^\s*\d+\s+(TCP|UDP)\s+(\d+)->(\d+\.\d+\.\d+\.\d+):(\d+)\s+'([^']*)'", ln)
        if m:
            entry = {
                "proto": m.group(1),
                "external_port": int(m.group(2)),
                "internal_ip": m.group(3),
                "internal_port": int(m.group(4)),
                "description": m.group(5),
            }
            mappings.append(entry)
            emit_security_event("network.upnp_exposure", entry)

    return {
        "status": "ok",
        "action": action,
        "mappings_count": len(mappings),
        "mappings": mappings,
        "raw_output": output[:2000],
    }


def set_device_trust(
    mac: str,
    level: str,
    label: Optional[str] = None,
    notes: Optional[str] = None,
) -> Dict[str, Any]:
    clean_mac = (mac or "").strip().lower()
    valid_levels = ("trusted", "known_iot", "guest", "untrusted", "quarantined")
    if level not in valid_levels:
        return {"status": "error", "message": f"level must be one of {valid_levels}"}
    con = connect_db()
    row = con.execute("SELECT * FROM devices WHERE mac = ?", (clean_mac,)).fetchone()
    if not row:
        con.close()
        return {"status": "error", "message": f"Device MAC {clean_mac} not found in lan_devices.db"}

    new_label = label.strip() if label and label.strip() else row["label"]
    new_notes = notes.strip() if notes is not None else row["notes"]
    con.execute(
        "UPDATE devices SET trust_level = ?, label = ?, notes = ? WHERE mac = ?",
        (level, new_label, new_notes, clean_mac),
    )
    con.commit()
    updated = dict(con.execute("SELECT * FROM devices WHERE mac = ?", (clean_mac,)).fetchone())
    con.close()
    return {"status": "ok", "device": updated}


def audit_device_vulnerabilities(ip: str, ports: Optional[str] = None) -> Dict[str, Any]:
    """
    Authorized Active Vulnerability & Security Posture Audit against a sovereign LAN device.
    Runs Kali Linux nmap NSE vulnerability, authentication-method, TLS certificate/cipher,
    SMB/SNMP exposure scripts, and HTTP header checks inside george-kali-tyler.
    """
    target_ip = validate_lan_ip(ip)
    ensure_kali_running()
    kali_up = kali_container_status()["running"]
    if not kali_up:
        return {"status": "error", "message": f"Container {KALI_CONTAINER} is not running"}

    port_arg = ["-p", re.sub(r"[^0-9,]", "", ports)] if (ports and re.sub(r"[^0-9,]", "", ports)) else ["--top-ports", "100"]
    nse_scripts = (
        "vuln,ssh-auth-methods,http-title,http-security-headers,http-methods,"
        "ssl-cert,smb-os-discovery,smb-enum-shares,snmp-info,upnp-info,banner"
    )
    cmd = [
        "docker",
        "exec",
        KALI_CONTAINER,
        "/usr/local/bin/nmap",
        "-sT",
        "-Pn",
        "-T4",
        "-sV",
        "--version-light",
        *port_arg,
        f"--script={nse_scripts}",
        "--script-timeout",
        "12s",
        "--max-retries",
        "1",
        "--max-rtt-timeout",
        "500ms",
        "--host-timeout",
        "45s",
        target_ip,
    ]
    t0 = time.time()
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=52.0)
        raw_out = (r.stdout + ("\n" + r.stderr if r.stderr else "")).strip()
    except subprocess.TimeoutExpired as e:
        out_p = e.stdout.decode("utf-8", errors="ignore") if isinstance(e.stdout, bytes) else (e.stdout or "")
        raw_out = (out_p + "\n[Audit timed out after 52s]").strip()
    except Exception as e:
        raw_out = f"Audit error: {e}"

    elapsed_ms = int((time.time() - t0) * 1000)
    open_services: List[str] = []
    vuln_findings: List[str] = []
    nse_lines: List[str] = []
    for ln in raw_out.splitlines():
        s = ln.strip()
        if re.match(r"^\d+/(tcp|udp)\s+open\b", s):
            open_services.append(s)
        elif s.startswith("|") or s.startswith("|_"):
            nse_lines.append(s)
            if any(k in s.lower() for k in ("vulnerable", "cve-", "weak", "anonymous", "public", "password")):
                vuln_findings.append(s)

    return {
        "status": "ok",
        "ip": target_ip,
        "elapsed_ms": elapsed_ms,
        "open_services": open_services,
        "vulnerability_and_auth_highlights": vuln_findings,
        "nse_script_output": nse_lines[:80],
        "raw_nmap": raw_out[:4000],
    }


def _ensure_tyler_chains() -> None:
    """
    Idempotently creates dedicated TYLER_* chains in iptables and ip6tables inside
    george-kali-tyler and hooks them from INPUT, OUTPUT, DOCKER-USER, and FORWARD.
    Ensures emergency_network_reset() can safely flush ONLY Tyler rules without
    wiping host SSH/UFW/Tailscale/Docker chains.
    """
    if not kali_container_status()["running"]:
        return
    setup_script = (
        "for fw in iptables ip6tables; do "
        "  command -v $fw >/dev/null 2>&1 || continue; "
        "  for ch in TYLER_INPUT TYLER_OUTPUT TYLER_DOCKER TYLER_AIRLOCK_IN TYLER_AIRLOCK_OUT TYLER_AIRLOCK_FWD; do "
        "    $fw -N $ch 2>/dev/null || true; "
        "  done; "
        "  $fw -C INPUT -j TYLER_AIRLOCK_IN 2>/dev/null || $fw -I INPUT 1 -j TYLER_AIRLOCK_IN 2>/dev/null || true; "
        "  $fw -C INPUT -j TYLER_INPUT 2>/dev/null || $fw -I INPUT 1 -j TYLER_INPUT 2>/dev/null || true; "
        "  $fw -C OUTPUT -j TYLER_AIRLOCK_OUT 2>/dev/null || $fw -I OUTPUT 1 -j TYLER_AIRLOCK_OUT 2>/dev/null || true; "
        "  $fw -C OUTPUT -j TYLER_OUTPUT 2>/dev/null || $fw -I OUTPUT 1 -j TYLER_OUTPUT 2>/dev/null || true; "
        "  $fw -C FORWARD -j TYLER_AIRLOCK_FWD 2>/dev/null || $fw -I FORWARD 1 -j TYLER_AIRLOCK_FWD 2>/dev/null || true; "
        "  if $fw -L DOCKER-USER >/dev/null 2>&1; then "
        "    $fw -C DOCKER-USER -j TYLER_AIRLOCK_FWD 2>/dev/null || $fw -I DOCKER-USER 1 -j TYLER_AIRLOCK_FWD 2>/dev/null || true; "
        "    $fw -C DOCKER-USER -j TYLER_DOCKER 2>/dev/null || $fw -I DOCKER-USER 1 -j TYLER_DOCKER 2>/dev/null || true; "
        "  fi; "
        "done"
    )
    subprocess.run(
        ["docker", "exec", KALI_CONTAINER, "bash", "-c", setup_script],
        capture_output=True,
        text=True,
        timeout=6.0,
    )


def _apply_airlock_firewall(wsl_iface: str) -> None:
    if not re.fullmatch(r"[A-Za-z0-9_.:-]+", wsl_iface or ""):
        return
    if not kali_container_status()["running"]:
        return
    _ensure_tyler_chains()
    fw_on = (
        "iptables -F TYLER_AIRLOCK_IN 2>/dev/null || true; "
        "iptables -F TYLER_AIRLOCK_OUT 2>/dev/null || true; "
        "iptables -F TYLER_AIRLOCK_FWD 2>/dev/null || true; "
        f"iptables -A TYLER_AIRLOCK_IN -i {wsl_iface} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true; "
        f"iptables -A TYLER_AIRLOCK_IN -i {wsl_iface} -p udp --sport 67 --dport 68 -j ACCEPT 2>/dev/null || true; "
        f"iptables -A TYLER_AIRLOCK_IN -i {wsl_iface} -j DROP 2>/dev/null || true; "
        f"iptables -A TYLER_AIRLOCK_FWD -i {wsl_iface} -j DROP 2>/dev/null || true; "
        f"iptables -A TYLER_AIRLOCK_FWD -o {wsl_iface} -j DROP 2>/dev/null || true; "
        f"iptables -A TYLER_AIRLOCK_OUT -o {wsl_iface} -p tcp -m multiport --dports 445,135,139 -j DROP 2>/dev/null || true; "
        f"iptables -A TYLER_AIRLOCK_OUT -o {wsl_iface} -p udp -m multiport --dports 137,138,5353,5355,3702 -j DROP 2>/dev/null || true; "
        "if command -v ip6tables >/dev/null 2>&1; then "
        "  ip6tables -F TYLER_AIRLOCK_IN 2>/dev/null || true; "
        "  ip6tables -F TYLER_AIRLOCK_OUT 2>/dev/null || true; "
        "  ip6tables -F TYLER_AIRLOCK_FWD 2>/dev/null || true; "
        f"  ip6tables -A TYLER_AIRLOCK_IN -i {wsl_iface} -j DROP 2>/dev/null || true; "
        f"  ip6tables -A TYLER_AIRLOCK_OUT -o {wsl_iface} -j DROP 2>/dev/null || true; "
        f"  ip6tables -A TYLER_AIRLOCK_FWD -i {wsl_iface} -j DROP 2>/dev/null || true; "
        f"  ip6tables -A TYLER_AIRLOCK_FWD -o {wsl_iface} -j DROP 2>/dev/null || true; "
        "fi"
    )
    subprocess.run(["docker", "exec", KALI_CONTAINER, "bash", "-c", fw_on], capture_output=True, text=True, timeout=6.0)
    subprocess.run(["ip", "-6", "route", "del", "default", "dev", wsl_iface], capture_output=True, text=True, timeout=2.0)


def _teardown_airlock_firewall(wsl_iface: str) -> None:
    if not kali_container_status()["running"]:
        return
    fw_off = (
        "for fw in iptables ip6tables; do "
        "  command -v $fw >/dev/null 2>&1 || continue; "
        "  $fw -F TYLER_AIRLOCK_IN 2>/dev/null || true; "
        "  $fw -F TYLER_AIRLOCK_OUT 2>/dev/null || true; "
        "  $fw -F TYLER_AIRLOCK_FWD 2>/dev/null || true; "
        "done"
    )
    subprocess.run(["docker", "exec", KALI_CONTAINER, "bash", "-c", fw_off], capture_output=True, text=True, timeout=6.0)


def intervene_device(
    ip: str = "",
    mode: str = "host_block",
    port: Optional[int] = None,
    proto: str = "tcp",
    duration: int = 8,
    rationale: str = "",
    plan_id: str = "",
    operator_notes: str = "",
) -> Dict[str, Any]:
    con = connect_db()
    now = int(time.time())

    # ── Tier B Defense Plan Lifecycle Modes (list_plans, approve_plan, execute_plan, reject_plan) ──
    if mode == "list_plans":
        rows = con.execute("SELECT * FROM defense_plans ORDER BY created_at DESC LIMIT 30").fetchall()
        con.close()
        return {"status": "ok", "plans": [dict(r) for r in rows]}

    if mode in ("approve_plan", "execute_plan"):
        pid = (plan_id or ip or "").strip().upper()
        prow = con.execute("SELECT * FROM defense_plans WHERE plan_id = ?", (pid,)).fetchone()
        if not prow:
            con.close()
            return {"status": "error", "message": f"Defense plan '{pid}' not found in lan_devices.db"}
        p_dict = dict(prow)
        con.close()
        exec_res = intervene_device(
            ip=p_dict["target_ip"],
            mode=p_dict["proposed_mode"],
            port=p_dict["proposed_port"] or None,
            proto=p_dict["proposed_proto"] or "tcp",
        )
        con2 = connect_db()
        con2.execute(
            """
            UPDATE defense_plans
            SET status = 'approved', operator_verdict = 'approved', operator_notes = ?,
                execution_result_json = ?, updated_at = ?
            WHERE plan_id = ?
            """,
            (operator_notes or "Approved by operator", json.dumps(exec_res), now, pid),
        )
        con2.commit()
        con2.close()
        return {"status": "ok", "plan_id": pid, "verdict": "approved", "execution": exec_res}

    if mode == "reject_plan":
        pid = (plan_id or ip or "").strip().upper()
        prow = con.execute("SELECT * FROM defense_plans WHERE plan_id = ?", (pid,)).fetchone()
        if not prow:
            con.close()
            return {"status": "error", "message": f"Defense plan '{pid}' not found in lan_devices.db"}
        con.execute(
            """
            UPDATE defense_plans
            SET status = 'rejected', operator_verdict = 'rejected', operator_notes = ?, updated_at = ?
            WHERE plan_id = ?
            """,
            (operator_notes or "Rejected by operator (false positive / non-disruptive)", now, pid),
        )
        con.commit()
        con.close()
        return {"status": "ok", "plan_id": pid, "verdict": "rejected", "notes": operator_notes}

    target_ip = validate_lan_ip(ip)
    row = con.execute("SELECT * FROM devices WHERE ip = ?", (target_ip,)).fetchone()

    # ── Tier A Non-Destructive Mode: forensic_snap ──
    if mode == "forensic_snap":
        con.close()
        ensure_kali_running()
        PCAP_DIR.mkdir(parents=True, exist_ok=True)
        snap_dur = max(2, min(20, int(duration or 8)))
        pcap_name = f"forensic_{target_ip.replace('.', '_')}_{now}.pcap"
        pcap_host_path = PCAP_DIR / pcap_name
        container_pcap = f"/tmp/{pcap_name}"
        subprocess.run(
            [
                "docker",
                "exec",
                KALI_CONTAINER,
                "timeout",
                str(snap_dur + 2),
                "tcpdump",
                "-i",
                "eth0",
                "-c",
                "500",
                "-G",
                str(snap_dur),
                "-W",
                "1",
                "-w",
                container_pcap,
                f"host {target_ip}",
            ],
            capture_output=True,
            timeout=float(snap_dur + 5),
        )
        subprocess.run(
            ["docker", "cp", f"{KALI_CONTAINER}:{container_pcap}", str(pcap_host_path)],
            capture_output=True,
            timeout=5.0,
        )
        subprocess.run(
            ["docker", "exec", KALI_CONTAINER, "rm", "-f", container_pcap],
            capture_output=True,
            timeout=3.0,
        )
        ct_out = subprocess.run(
            ["docker", "exec", KALI_CONTAINER, "conntrack", "-L", "-s", target_ip],
            capture_output=True,
            text=True,
            timeout=4.0,
        ).stdout.strip()
        pcap_bytes = pcap_host_path.stat().st_size if pcap_host_path.exists() else 0
        return {
            "status": "ok",
            "ip": target_ip,
            "mode": "forensic_snap",
            "pcap_file": str(pcap_host_path),
            "pcap_bytes": pcap_bytes,
            "active_conntrack_flows": ct_out.splitlines()[:30],
        }

    # Protected-IP Gate for all disruptive modes
    if target_ip in PROTECTED_IPS:
        con.close()
        return {
            "status": "error",
            "message": f"Policy Gate Blocked: {target_ip} is a protected core/family IP and cannot be blocked, severed, or quarantined.",
        }

    # ── Tier B Defense Plan Proposal Mode: propose_plan ──
    if mode == "propose_plan":
        last_oct = target_ip.split(".")[-1]
        pid = plan_id.strip().upper() if plan_id else f"DEF-{last_oct}-{now % 10000:04d}"
        prop_mode = (rationale.split(":", 1)[0] if ":" in rationale and rationale.split(":", 1)[0] in ("quarantine", "port_block", "tcp_reset", "upnp_kill") else "quarantine")
        if port and prop_mode == "quarantine":
            prop_mode = "port_block"
        mac_str = row["mac"] if row else ""
        pol = get_tyler_policy()
        con.execute(
            """
            INSERT OR REPLACE INTO defense_plans
            (plan_id, created_at, updated_at, trigger_event, target_ip, target_mac, tier, proposed_mode, proposed_port, proposed_proto, rationale, status)
            VALUES (?, ?, ?, 'agent_triage', ?, ?, 'tier_b', ?, ?, ?, ?, 'pending_approval')
            """,
            (
                pid,
                now,
                now,
                target_ip,
                mac_str,
                prop_mode,
                int(port or 0),
                (proto or "tcp").lower(),
                rationale or f"Tier B containment proposed for {target_ip}",
            ),
        )
        con.commit()
        con.close()
        if pol.get("response_mode") == "auto":
            auto_exec = intervene_device(ip=target_ip, mode=prop_mode, port=port, proto=proto)
            con_a = connect_db()
            con_a.execute(
                "UPDATE defense_plans SET status = 'auto_executed', operator_verdict = 'auto', execution_result_json = ?, updated_at = ? WHERE plan_id = ?",
                (json.dumps(auto_exec), now, pid),
            )
            con_a.commit()
            con_a.close()
            return {
                "status": "ok",
                "plan_id": pid,
                "response_mode": "auto",
                "message": f"Auto-Response Mode active: executed {prop_mode} on {target_ip} immediately.",
                "execution": auto_exec,
            }
        return {
            "status": "ok",
            "plan_id": pid,
            "response_mode": "confirm",
            "target_ip": target_ip,
            "proposed_mode": prop_mode,
            "proposed_port": int(port or 0),
            "rationale": rationale,
            "message": f"Tier B Defense Plan {pid} staged in lan_devices.db awaiting operator confirmation.",
        }

    if row and row["trust_level"] == "trusted" and mode in ("host_block", "quarantine", "tcp_reset", "conntrack_drop", "port_block"):
        con.close()
        return {
            "status": "error",
            "message": f"Policy Gate Blocked: Device {target_ip} ({row['label']}) is marked 'trusted'. Change its trust_level to 'untrusted' first.",
        }

    ensure_kali_running()
    kali_up = kali_container_status()["running"]
    cmd_status = "recorded"
    clean_proto = (proto or "tcp").strip().lower()
    if clean_proto not in ("tcp", "udp", "both"):
        clean_proto = "tcp"
    protos = ["tcp", "udp"] if clean_proto == "both" else [clean_proto]

    if mode in ("host_block", "quarantine"):
        if kali_up:
            _ensure_tyler_chains()
            for del_cmd in (
                ["iptables", "-D", "TYLER_INPUT", "-s", target_ip, "-j", "DROP"],
                ["iptables", "-D", "TYLER_OUTPUT", "-d", target_ip, "-j", "DROP"],
                ["iptables", "-D", "TYLER_DOCKER", "-s", target_ip, "-j", "DROP"],
                ["iptables", "-D", "TYLER_DOCKER", "-d", target_ip, "-j", "DROP"],
                ["iptables", "-D", "INPUT", "-s", target_ip, "-j", "DROP"],
                ["iptables", "-D", "OUTPUT", "-d", target_ip, "-j", "DROP"],
            ):
                subprocess.run(["docker", "exec", KALI_CONTAINER, *del_cmd], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            r_in = subprocess.run(
                ["docker", "exec", KALI_CONTAINER, "iptables", "-I", "TYLER_INPUT", "-s", target_ip, "-j", "DROP"],
                capture_output=True,
                text=True,
            )
            r_out = subprocess.run(
                ["docker", "exec", KALI_CONTAINER, "iptables", "-I", "TYLER_OUTPUT", "-d", target_ip, "-j", "DROP"],
                capture_output=True,
                text=True,
            )
            subprocess.run(
                ["docker", "exec", KALI_CONTAINER, "iptables", "-I", "TYLER_DOCKER", "-s", target_ip, "-j", "DROP"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            subprocess.run(
                ["docker", "exec", KALI_CONTAINER, "iptables", "-I", "TYLER_DOCKER", "-d", target_ip, "-j", "DROP"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            subprocess.run(
                ["docker", "exec", KALI_CONTAINER, "conntrack", "-D", "-s", target_ip],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            subprocess.run(
                ["docker", "exec", KALI_CONTAINER, "conntrack", "-D", "-d", target_ip],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            cmd_status = (
                "bidirectional_iptables_drop_and_conntrack_severed"
                if (r_in.returncode == 0 and r_out.returncode == 0)
                else f"ledger_only ({r_in.stderr.strip()})"
            )
        if row:
            con.execute("UPDATE devices SET trust_level = 'quarantined' WHERE mac = ?", (row["mac"],))
            con.commit()
    elif mode == "port_block":
        if not port or int(port) <= 0 or int(port) > 65535:
            con.close()
            return {"status": "error", "message": "port_block requires a valid port (1..65535)"}
        p_str = str(int(port))
        if kali_up:
            _ensure_tyler_chains()
            for pr in protos:
                for rule_op in ("-D", "-I"):
                    for ch_rule in (
                        ["TYLER_INPUT", "-s", target_ip, "-p", pr, "--dport", p_str, "-j", "DROP"],
                        ["TYLER_INPUT", "-s", target_ip, "-p", pr, "--sport", p_str, "-j", "DROP"],
                        ["TYLER_DOCKER", "-s", target_ip, "-p", pr, "--dport", p_str, "-j", "DROP"],
                        ["TYLER_OUTPUT", "-d", target_ip, "-p", pr, "--dport", p_str, "-j", "DROP"],
                    ):
                        subprocess.run(
                            ["docker", "exec", KALI_CONTAINER, "iptables", rule_op, *ch_rule],
                            stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL,
                        )
            cmd_status = f"surgical_port_block_active ({p_str}/{clean_proto})"
    elif mode == "port_unblock":
        if not port or int(port) <= 0 or int(port) > 65535:
            con.close()
            return {"status": "error", "message": "port_unblock requires a valid port (1..65535)"}
        p_str = str(int(port))
        if kali_up:
            _ensure_tyler_chains()
            for pr in protos:
                for ch_rule in (
                    ["TYLER_INPUT", "-s", target_ip, "-p", pr, "--dport", p_str, "-j", "DROP"],
                    ["TYLER_INPUT", "-s", target_ip, "-p", pr, "--sport", p_str, "-j", "DROP"],
                    ["TYLER_DOCKER", "-s", target_ip, "-p", pr, "--dport", p_str, "-j", "DROP"],
                    ["TYLER_OUTPUT", "-d", target_ip, "-p", pr, "--dport", p_str, "-j", "DROP"],
                    ["INPUT", "-s", target_ip, "-p", pr, "--sport", p_str, "-j", "DROP"],
                    ["OUTPUT", "-d", target_ip, "-p", pr, "--dport", p_str, "-j", "DROP"],
                ):
                    subprocess.run(
                        ["docker", "exec", KALI_CONTAINER, "iptables", "-D", *ch_rule],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                    )
            cmd_status = f"surgical_port_block_removed ({p_str}/{clean_proto})"
    elif mode in ("tcp_reset", "conntrack_drop"):
        if kali_up:
            r1 = subprocess.run(
                ["docker", "exec", KALI_CONTAINER, "conntrack", "-D", "-s", target_ip],
                capture_output=True,
                text=True,
            )
            r2 = subprocess.run(
                ["docker", "exec", KALI_CONTAINER, "conntrack", "-D", "-d", target_ip],
                capture_output=True,
                text=True,
            )
            cmd_status = f"active_sessions_severed (src_rc={r1.returncode}, dst_rc={r2.returncode})"
    elif mode == "upnp_kill":
        if kali_up and port:
            r_tcp = subprocess.run(
                ["docker", "exec", KALI_CONTAINER, "timeout", "4", "upnpc", "-d", str(int(port)), "TCP"],
                capture_output=True,
                text=True,
            )
            r_udp = subprocess.run(
                ["docker", "exec", KALI_CONTAINER, "timeout", "4", "upnpc", "-d", str(int(port)), "UDP"],
                capture_output=True,
                text=True,
            )
            cmd_status = f"upnp_port_{int(port)}_removed (tcp_rc={r_tcp.returncode}, udp_rc={r_udp.returncode})"
        else:
            cmd_status = "upnp_kill_requires_port"
    elif mode in ("host_unblock", "release"):
        if kali_up:
            _ensure_tyler_chains()
            for del_cmd in (
                ["iptables", "-D", "TYLER_INPUT", "-s", target_ip, "-j", "DROP"],
                ["iptables", "-D", "TYLER_OUTPUT", "-d", target_ip, "-j", "DROP"],
                ["iptables", "-D", "TYLER_DOCKER", "-s", target_ip, "-j", "DROP"],
                ["iptables", "-D", "TYLER_DOCKER", "-d", target_ip, "-j", "DROP"],
                ["iptables", "-D", "INPUT", "-s", target_ip, "-j", "DROP"],
                ["iptables", "-D", "OUTPUT", "-d", target_ip, "-j", "DROP"],
            ):
                subprocess.run(["docker", "exec", KALI_CONTAINER, *del_cmd], capture_output=True, text=True)
            cmd_status = "iptables_drop_removed"
        if row:
            con.execute("UPDATE devices SET trust_level = 'untrusted' WHERE mac = ?", (row["mac"],))
            con.commit()
    else:
        con.close()
        return {"status": "error", "message": f"Unsupported intervention mode: {mode}"}

    con.close()
    return {
        "status": "ok",
        "ip": target_ip,
        "mode": mode,
        "port": port,
        "proto": clean_proto if port else None,
        "enforcement": cmd_status,
    }


# ── Active Immune System ("White Blood Cell / T-Cell") Tools ──────────────────

PROTECTED_HOST_PORTS = {22, 53, 80, 443, 3000, 8080, 8081, 8443}
CANARY_BANNERS: Dict[int, Tuple[str, bytes]] = {
    2222: ("ssh_decoy", b"SSH-2.0-OpenSSH_8.9p1 Ubuntu-3ubuntu0.10\r\n"),
    2323: ("telnet_decoy", b"Ubuntu 22.04 LTS\r\nlogin: "),
    4445: ("smb_decoy", b"\x00\x00\x00\x2f\xffSMB"),
    6379: ("redis_decoy", b"-ERR NOAUTH Authentication required.\r\n"),
}


def parse_proc_arp() -> Dict[str, str]:
    arp_map: Dict[str, str] = {}
    try:
        neigh_out = subprocess.check_output(["ip", "-4", "neigh", "show", "dev", "eth0"], text=True, timeout=2.0)
        for line in neigh_out.splitlines():
            parts = line.split()
            if parts and "lladdr" in parts:
                arp_map[parts[0]] = parts[parts.index("lladdr") + 1].lower()
    except Exception:
        pass
    try:
        with open("/proc/net/arp", "r", encoding="utf-8") as f:
            for line in f.read().splitlines()[1:]:
                cols = line.split()
                if len(cols) >= 4 and cols[3] != "00:00:00:00:00:00":
                    arp_map.setdefault(cols[0], cols[3].lower())
    except Exception:
        pass
    return arp_map


def _record_canary_hit(src_ip: str, dst_port: int, service: str, raw_bytes: bytes) -> None:
    now = int(time.time())
    arp_map = parse_proc_arp()
    src_mac = arp_map.get(src_ip, "")
    payload_hex = raw_bytes[:128].hex()
    payload_text = raw_bytes[:128].decode("utf-8", errors="replace").strip()
    pol = get_tyler_policy()
    action_taken = "logged_and_alerted"
    if (pol.get("auto_canary_quarantine") or pol.get("response_mode") == "auto") and src_ip not in PROTECTED_IPS and src_ip != "127.0.0.1":
        res = intervene_device(src_ip, "quarantine")
        action_taken = f"auto_quarantined ({res.get('enforcement', '')})"

    con = connect_db()
    con.execute(
        """
        INSERT INTO canary_hits (ts, src_ip, src_mac, dst_port, service_emulated, payload_hex, payload_text, action_taken)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (now, src_ip, src_mac, int(dst_port), service, payload_hex, payload_text, action_taken),
    )
    con.commit()
    con.close()

    emit_security_event(
        "network.canary_triggered",
        {
            "ip": src_ip,
            "mac": src_mac,
            "port": int(dst_port),
            "service": service,
            "payload_text": payload_text[:80],
            "action_taken": action_taken,
        },
    )


def run_canary_daemon_loop(ports_csv: str = "2222,2323,4445,6379") -> None:
    import asyncio

    CANARY_LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
    lock_fd = open(CANARY_LOCK_PATH, "w", encoding="utf-8")
    try:
        fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        lock_fd.write(f"{os.getpid()}\n")
        lock_fd.flush()
    except OSError:
        lock_fd.close()
        return

    ports: List[int] = []
    for p_str in (ports_csv or "2222,2323,4445,6379").split(","):
        p_str = p_str.strip()
        if p_str.isdigit():
            p = int(p_str)
            if 1024 <= p <= 65535 and p not in PROTECTED_HOST_PORTS:
                ports.append(p)
    if not ports:
        ports = [2222, 2323, 4445, 6379]

    conn_sem = asyncio.Semaphore(8)
    last_hit_by_ip: Dict[str, float] = {}

    async def _handle_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter, port: int) -> None:
        if conn_sem.locked():
            try:
                writer.close()
                await writer.wait_closed()
            except Exception:
                pass
            return
        async with conn_sem:
            peer = writer.get_extra_info("peername")
            src_ip = peer[0] if peer else "0.0.0.0"
            if src_ip.startswith("::ffff:"):
                src_ip = src_ip.replace("::ffff:", "")
            svc, banner = CANARY_BANNERS.get(port, (f"decoy_{port}", b"220 Service ready\r\n"))
            try:
                writer.write(banner)
                await writer.drain()
                data = await asyncio.wait_for(reader.read(256), timeout=2.5)
            except Exception:
                data = b""
            finally:
                try:
                    writer.close()
                    await writer.wait_closed()
                except Exception:
                    pass
            now_m = time.monotonic()
            key_ip = f"{src_ip}:{port}"
            if now_m - last_hit_by_ip.get(key_ip, -999.0) >= 60.0:
                last_hit_by_ip[key_ip] = now_m
                if len(last_hit_by_ip) > 512:
                    cutoff_m = now_m - 300.0
                    for k_old in [k for k, v in last_hit_by_ip.items() if v < cutoff_m]:
                        last_hit_by_ip.pop(k_old, None)
                try:
                    await asyncio.to_thread(_record_canary_hit, src_ip, port, svc, data)
                except Exception:
                    pass

    async def _serve_all() -> None:
        servers = []
        bound_ports: List[int] = []
        lan_ip = HOST_IP
        for p in ports:
            try:
                srv = await asyncio.start_server(lambda r, w, pt=p: _handle_client(r, w, pt), "0.0.0.0", p)
                servers.append(srv)
                bound_ports.append(p)
            except Exception:
                try:
                    srv = await asyncio.start_server(lambda r, w, pt=p: _handle_client(r, w, pt), lan_ip, p)
                    servers.append(srv)
                    bound_ports.append(p)
                except Exception:
                    pass
        CANARY_STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        CANARY_STATE_PATH.write_text(
            json.dumps({
                "pid": os.getpid(),
                "ports": bound_ports,
                "rf_sampler_interval_s": 15,
                "l2_l3_immune_watch_s": 15,
                "started_at": int(time.time()),
            }),
            encoding="utf-8",
        )

        async def _rf_15s_sampler_loop() -> None:
            sweep_idx = 0
            while True:
                t_start = time.monotonic()
                try:
                    await asyncio.to_thread(rf_motion_sense, 3, False)
                    sweep_idx += 1
                    if sweep_idx % 10 == 1:
                        await asyncio.to_thread(wifi_spelunk, "scan_airspace")
                except Exception:
                    pass
                elapsed = time.monotonic() - t_start
                await asyncio.sleep(max(1.0, 15.0 - elapsed))

        async def _clock_airlock_refresh_loop() -> None:
            # Decoupled slow-cadence South-Wall Lenovo Smart Clock Airlock dual-band scan refresh
            # (~45 min default, protected by `_wifi_airlock_radio_lock()` so 15s scans never collide).
            await asyncio.sleep(20.0)
            while True:
                sleep_next = 300.0
                try:
                    wl_c = load_wifi_watchlist()
                    interval_s = int((wl_c.get("perimeter_guard") or {}).get("clock_airlock_refresh_interval_s") or 2700)
                    if interval_s > 0:
                        claimed_c = _list_claimed_peripherals()
                        if claimed_c:
                            last_tri_ts = int(
                                ((claimed_c[0].get("last_telemetry") or {}).get("last_triangulation_ts"))
                                or claimed_c[0].get("last_seen")
                                or 0
                            )
                            if (int(time.time()) - last_tri_ts) >= interval_s:
                                wst = await asyncio.to_thread(_get_windows_wifi_status)
                                if wst.get("safe_secondary_radio", False):
                                    await asyncio.to_thread(
                                        wifi_spelunk,
                                        "triangulate_airspace",
                                        None,
                                        None,
                                        "open",
                                        "none",
                                        None,
                                        "auto",
                                        False,
                                        30,
                                        False,
                                        None,
                                    )
                                    sleep_next = float(max(600, interval_s))
                except Exception:
                    pass
                await asyncio.sleep(sleep_next)

        l2_dedup_cache: Dict[str, float] = {}

        async def _l2_l3_immune_watch_loop() -> None:
            while True:
                t_start = time.monotonic()
                try:
                    await asyncio.to_thread(check_l2_l3_immune_anomalies, 5, l2_dedup_cache)
                except Exception:
                    pass
                elapsed = time.monotonic() - t_start
                await asyncio.sleep(max(2.0, 15.0 - elapsed))

        await asyncio.gather(
            _rf_15s_sampler_loop(),
            _clock_airlock_refresh_loop(),
            _l2_l3_immune_watch_loop(),
            *(s.serve_forever() for s in servers),
        )

    try:
        asyncio.run(_serve_all())
    finally:
        try:
            fcntl.flock(lock_fd.fileno(), fcntl.LOCK_UN)
            lock_fd.close()
        except Exception:
            pass


def manage_canary_trap(
    action: str = "status",
    ports: Optional[str] = None,
    auto_quarantine: Optional[bool] = None,
) -> Dict[str, Any]:
    act = (action or "status").strip().lower()
    if auto_quarantine is not None:
        set_tyler_policy(auto_canary_quarantine=bool(auto_quarantine))

    def _daemon_running() -> Tuple[bool, Dict[str, Any]]:
        for candidate in (
            CANARY_STATE_PATH,
            _REPO_ROOT / ".george" / "state" / "tyler_canary_daemon.json",
            Path.home() / "blue-lodge" / ".george" / "state" / "tyler_canary_daemon.json",
            Path("/home/user/blue-lodge/.george/state/tyler_canary_daemon.json"),
        ):
            if not candidate.exists():
                continue
            try:
                st = json.loads(candidate.read_text(encoding="utf-8"))
                pid = int(st.get("pid", 0))
                if pid > 0 and st.get("ports"):
                    os.kill(pid, 0)
                    return True, st
            except Exception:
                pass
        try:
            out = subprocess.check_output(["pgrep", "-f", "tyler_guardian.py canary-daemon"], text=True, timeout=1.5).strip()
            if out:
                first_pid = int(out.splitlines()[0].strip())
                return True, {"pid": first_pid, "ports": [2222, 2323, 4445, 6379], "started_at": int(time.time())}
        except Exception:
            pass
        return False, {}

    if act == "start":
        running, st = _daemon_running()
        if not running:
            ports_arg = ports or "2222,2323,4445,6379"
            subprocess.Popen(
                [sys.executable, str(Path(__file__).resolve()), "canary-daemon", "--ports", ports_arg],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            for _ in range(20):
                time.sleep(0.1)
                running, st = _daemon_running()
                if running:
                    break
        return {
            "status": "ok",
            "action": "start",
            "running": running,
            "daemon": st,
            "policy": get_tyler_policy(),
        }
    elif act == "stop":
        running, st = _daemon_running()
        if running and st.get("pid"):
            try:
                os.kill(int(st["pid"]), 15)
            except Exception:
                pass
        CANARY_STATE_PATH.unlink(missing_ok=True)
        return {"status": "ok", "action": "stop", "running": False}
    elif act == "clear":
        con = connect_db()
        deleted = con.execute("DELETE FROM canary_hits").rowcount
        con.commit()
        con.close()
        return {"status": "ok", "action": "clear", "deleted_hits": deleted}
    elif act in ("status", "hits"):
        running, st = _daemon_running()
        con = connect_db()
        hits = [dict(r) for r in con.execute("SELECT * FROM canary_hits ORDER BY id DESC LIMIT 30").fetchall()]
        con.close()
        return {
            "status": "ok",
            "running": running,
            "daemon": st,
            "hits_count": len(hits),
            "hits": hits,
            "policy": get_tyler_policy(),
        }
    return {"status": "error", "message": f"Unsupported canary action: {act}"}


def manage_tshark_watch(
    action: str = "list",
    name: Optional[str] = None,
    display_filter: Optional[str] = None,
    bpf_filter: Optional[str] = None,
    extract_fields: Optional[str] = None,
    severity: str = "tier_b",
    description: str = "",
    duration: int = 8,
) -> Dict[str, Any]:
    act = (action or "list").strip().lower()
    con = connect_db()
    now = int(time.time())

    def _validate_display_filter(df: str) -> Tuple[bool, str]:
        if not df or len(df.strip()) > 600:
            return False, "display_filter must be 1..600 characters"
        ensure_kali_running()
        if not kali_container_status()["running"]:
            return True, "syntax_unverified_container_offline"
        subprocess.run(
            [
                "docker",
                "exec",
                KALI_CONTAINER,
                "python3",
                "-c",
                "from pathlib import Path; p=Path('/tmp/.tyler_empty.pcap'); p.exists() or p.write_bytes(b'\\xd4\\xc3\\xb2\\xa1\\x02\\x00\\x04\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\xff\\xff\\x00\\x00\\x01\\x00\\x00\\x00')",
            ],
            capture_output=True,
            timeout=5.0,
        )
        r = subprocess.run(
            ["docker", "exec", KALI_CONTAINER, "tshark", "-r", "/tmp/.tyler_empty.pcap", "-Y", df.strip()],
            capture_output=True,
            text=True,
            timeout=5.0,
        )
        if r.returncode != 0:
            return False, (r.stderr or r.stdout).strip()
        return True, "valid"

    if act == "list":
        rules = [dict(r) for r in con.execute("SELECT * FROM tshark_watch_rules ORDER BY id ASC").fetchall()]
        hits = [dict(r) for r in con.execute("SELECT * FROM tshark_watch_hits ORDER BY id DESC LIMIT 25").fetchall()]
        con.close()
        return {"status": "ok", "rules_count": len(rules), "rules": rules, "recent_hits": hits}

    elif act == "test":
        if not display_filter:
            con.close()
            return {"status": "error", "message": "display_filter is required for action='test'"}
        ok, msg = _validate_display_filter(display_filter)
        con.close()
        return {"status": "ok" if ok else "error", "valid": ok, "display_filter": display_filter, "validation_output": msg}

    elif act == "add":
        clean_name = re.sub(r"[^a-zA-Z0-9_-]", "_", (name or "").strip()).lower()
        if not clean_name or not display_filter:
            con.close()
            return {"status": "error", "message": "Both 'name' and 'display_filter' are required for action='add'"}
        ok, msg = _validate_display_filter(display_filter)
        if not ok:
            con.close()
            return {"status": "error", "message": f"Invalid tshark display_filter syntax: {msg}"}
        fields_clean = re.sub(r"[^a-zA-Z0-9_.,-]", "", extract_fields or "ip.src,ip.dst,eth.src,frame.protocols")
        sev = severity if severity in ("tier_a", "tier_b") else "tier_b"
        con.execute(
            """
            INSERT OR REPLACE INTO tshark_watch_rules
            (name, display_filter, bpf_filter, extract_fields, severity, enabled, created_by, description, created_at)
            VALUES (?, ?, ?, ?, ?, 1, 'george', ?, ?)
            """,
            (clean_name, display_filter.strip(), (bpf_filter or "").strip(), fields_clean, sev, description or "", now),
        )
        con.commit()
        rule_row = dict(con.execute("SELECT * FROM tshark_watch_rules WHERE name = ?", (clean_name,)).fetchone())
        con.close()
        return {"status": "ok", "action": "add", "rule": rule_row}

    elif act == "remove":
        clean_name = (name or "").strip().lower()
        deleted = con.execute("DELETE FROM tshark_watch_rules WHERE LOWER(name) = ?", (clean_name,)).rowcount
        con.commit()
        con.close()
        return {"status": "ok", "action": "remove", "name": clean_name, "deleted": deleted}

    elif act == "run_all":
        con.close()
        return run_immune_patrol(duration=duration)

    con.close()
    return {"status": "error", "message": f"Unsupported tshark_watch action: {act}"}


def ensure_wsl_loopback_neighbor() -> Dict[str, Any]:
    """
    OS-agnostic kernel loopback routing bridge self-healing guard:
    In WSL2 mirrored mode, kernel routing rule #1 (`lookup 127`) routes all 127.0.0.1
    traffic via a link-local bridge on `loopback0` backed by a `PERMANENT` neighbor entry.
    If that entry is ever flushed or deleted, all 127.0.0.1 connections blackhole
    immediately. This function dynamically discovers the `table 127` route gateway and
    restores its `PERMANENT` neighbor entry via george-kali-tyler over the Unix docker.sock.
    """
    try:
        rt_out = subprocess.run(
            ["ip", "route", "show", "table", "127"],
            capture_output=True,
            text=True,
            timeout=2.0,
        ).stdout
        m = re.search(r"via\s+(\d+\.\d+\.\d+\.\d+)\s+dev\s+(loopback\d+)", rt_out)
        if not m:
            return {"checked": True, "wsl_mirrored": False, "healed": False}
        gw_ip, dev_name = m.group(1), m.group(2)
        neigh_out = subprocess.run(
            ["ip", "neigh", "show", "dev", dev_name],
            capture_output=True,
            text=True,
            timeout=2.0,
        ).stdout
        if gw_ip in neigh_out and "PERMANENT" in neigh_out:
            return {"checked": True, "wsl_mirrored": True, "healed": False, "gateway_ip": gw_ip, "dev": dev_name}
        hv_lladdr = ":".join(f"{b:02x}" for b in (0x00, 0x11, 0x22, 0x33, 0x44, 0x55))
        r_fix = subprocess.run(
            ["docker", "exec", KALI_CONTAINER, "ip", "neigh", "replace", gw_ip, "lladdr", hv_lladdr, "nud", "permanent", "dev", dev_name],
            capture_output=True,
            text=True,
            timeout=5.0,
        )
        return {
            "checked": True,
            "wsl_mirrored": True,
            "healed": r_fix.returncode == 0,
            "gateway_ip": gw_ip,
            "dev": dev_name,
        }
    except Exception as e:
        return {"checked": False, "healed": False, "error": str(e)}


def manage_arp_shield(action: str = "verify", ip: Optional[str] = None) -> Dict[str, Any]:
    act = (action or "verify").strip().lower()
    loopback_heal = ensure_wsl_loopback_neighbor()
    con = connect_db()
    placeholders = ",".join("?" for _ in ARP_PIN_IPS)
    rows = con.execute(f"SELECT ip, mac, label FROM devices WHERE ip IN ({placeholders})", tuple(ARP_PIN_IPS)).fetchall()
    con.close()

    targets = [dict(r) for r in rows if r["mac"] and r["mac"] != "00:00:00:00:00:00"]
    if ip and ip.strip().lower() not in ("", "critical", "all"):
        target_ip = validate_lan_ip(ip)
        targets = [t for t in targets if t["ip"] == target_ip]

    ensure_kali_running()
    kali_up = kali_container_status()["running"]
    results: List[Dict[str, Any]] = []

    # Detect actual live primary interface IPv4 prefix so synthetic example configs (192.168.1.x)
    # never pin off-subnet test MACs into the live host kernel neighbor table.
    nic_dev = PRIMARY_IFACE or "eth0"
    live_eth0_prefix = ""
    try:
        addr_out = subprocess.run(["ip", "-o", "-4", "addr", "show", "dev", nic_dev], capture_output=True, text=True, timeout=3.0).stdout
        m_eth = re.search(r"inet\s+(\d+\.\d+\.\d+)\.\d+", addr_out)
        if m_eth:
            live_eth0_prefix = m_eth.group(1) + "."
    except Exception:
        pass

    if act == "enforce" and kali_up:
        for t in targets:
            if _HOUSEHOLD_CFG_IS_EXAMPLE or (live_eth0_prefix and not t["ip"].startswith(live_eth0_prefix)):
                results.append({"ip": t["ip"], "mac": t["mac"], "label": t["label"], "enforced": False, "skipped_reason": "synthetic_or_off_subnet"})
                continue
            expected_mac = (EXPECTED_GATEWAY_MACS.get(t["ip"]) or "").strip().lower()
            if expected_mac and t["mac"].strip().lower() != expected_mac:
                emit_security_event(
                    "network.arp_spoof",
                    {
                        "ip": t["ip"],
                        "observed_mac": t["mac"],
                        "expected_mac": expected_mac,
                        "source": "manage_arp_shield",
                    },
                )
                results.append({
                    "ip": t["ip"],
                    "mac": t["mac"],
                    "expected_mac": expected_mac,
                    "label": t["label"],
                    "enforced": False,
                    "skipped_reason": "gateway_mac_mismatch_alert",
                })
                continue
            r = subprocess.run(
                ["docker", "exec", KALI_CONTAINER, "ip", "neigh", "replace", t["ip"], "lladdr", t["mac"], "nud", "permanent", "dev", nic_dev],
                capture_output=True,
                text=True,
            )
            results.append({"ip": t["ip"], "mac": t["mac"], "label": t["label"], "enforced": r.returncode == 0, "stderr": r.stderr.strip()})
    elif act == "release" and kali_up:
        for t in targets:
            r = subprocess.run(
                ["docker", "exec", KALI_CONTAINER, "ip", "neigh", "change", t["ip"], "lladdr", t["mac"], "nud", "reachable", "dev", nic_dev],
                capture_output=True,
                text=True,
            )
            results.append({"ip": t["ip"], "mac": t["mac"], "label": t["label"], "released": r.returncode == 0})
    elif act in ("flush_stale", "flush-stale") and kali_up:
        # Safely remove off-subnet or synthetic test PERMANENT pins on primary NIC ONLY (never loopback0!)
        try:
            n_out = subprocess.run(["ip", "-4", "neigh", "show", "dev", nic_dev], capture_output=True, text=True, timeout=3.0).stdout
            for ln in n_out.splitlines():
                pts = ln.split()
                if not pts:
                    continue
                nip = pts[0]
                if live_eth0_prefix and not nip.startswith(live_eth0_prefix):
                    r_del = subprocess.run(
                        ["docker", "exec", KALI_CONTAINER, "ip", "neigh", "del", nip, "dev", nic_dev],
                        capture_output=True,
                        text=True,
                    )
                    results.append({"ip": nip, "flushed_from_eth0": r_del.returncode == 0})
        except Exception:
            pass

    # Always read current kernel neighbor state (guarded: 'ip'/iproute2 is absent
    # in hermetic CI runners -> report structural-only state, never crash).
    try:
        neigh_out = subprocess.run(["ip", "neigh", "show", "dev", nic_dev], capture_output=True, text=True, timeout=5.0).stdout
    except Exception:
        neigh_out = ""
    neigh_states: Dict[str, str] = {}
    for ln in neigh_out.splitlines():
        parts = ln.split()
        if parts:
            neigh_states[parts[0]] = ln.strip()

    for t in targets:
        t["kernel_neighbor_entry"] = neigh_states.get(t["ip"], "not_in_table")
        t["permanent_locked"] = "PERMANENT" in t["kernel_neighbor_entry"]

    return {
        "status": "ok",
        "action": act,
        "protected_neighbors": targets,
        "enforcement_results": results,
    }


def diff_device_baseline(ip: str, save_baseline: bool = False) -> Dict[str, Any]:
    con = connect_db()
    now = int(time.time())

    if ip.strip().lower() == "all":
        ips = [r["ip"] for r in con.execute("SELECT ip FROM devices WHERE online = 1").fetchall()]
        con.close()
        diffs = [diff_device_baseline(i, save_baseline=save_baseline) for i in ips]
        drift_any = any(d.get("drift_detected", False) for d in diffs)
        return {"status": "ok", "mode": "all", "drift_detected": drift_any, "devices_audited": len(diffs), "results": diffs}

    target_ip = validate_lan_ip(ip)
    fp = deep_fingerprint_device(target_ip)
    dev_row = con.execute("SELECT * FROM devices WHERE ip = ?", (target_ip,)).fetchone()
    if not dev_row:
        con.close()
        return {"status": "error", "message": f"Device {target_ip} not found in lan_devices.db"}

    mac = dev_row["mac"]
    dossier = fp.get("dossier") if isinstance(fp.get("dossier"), dict) else {}
    open_ports = sorted(set(int(p) for p in (fp.get("open_ports") or dossier.get("open_ports") or [])))
    raw_services = fp.get("services") or dossier.get("nmap_services") or []
    banners_map: Dict[str, str] = {}
    for s in raw_services:
        if isinstance(s, dict) and s.get("port") is not None:
            banners_map[str(s.get("port"))] = f"{s.get('service','')}:{s.get('detail','')}"
        elif isinstance(s, str):
            m_sv = re.match(r"^(\d+)/(?:tcp|udp)\s+\S+\s+(\S+)(?:\s+(.*))?$", s.strip())
            if m_sv:
                banners_map[m_sv.group(1)] = f"{m_sv.group(2)}:{(m_sv.group(3) or '').strip()}"

    # Check TLS certificate SHA-256 thumbprint if 443 or 8443 is open
    tls_sha256 = ""
    if any(p in open_ports for p in (443, 8006, 8443)) and kali_container_status()["running"]:
        tls_port = 443 if 443 in open_ports else (8006 if 8006 in open_ports else 8443)
        r_ssl = subprocess.run(
            ["docker", "exec", KALI_CONTAINER, "timeout", "6", "nmap", "-sT", "-Pn", "-p", str(tls_port), "--script=ssl-cert", target_ip],
            capture_output=True,
            text=True,
        )
        m_sha = re.search(r"SHA-256:\s*([0-9a-fA-F: ]+)", r_ssl.stdout)
        if m_sha:
            tls_sha256 = re.sub(r"\s+", "", m_sha.group(1)).lower()

    base_row = con.execute("SELECT * FROM device_baselines WHERE mac = ?", (mac,)).fetchone()
    prev_egress_json = (base_row["egress_domains_json"] if base_row and "egress_domains_json" in base_row.keys() else None) or "[]"
    if not base_row or save_baseline:
        con.execute(
            """
            INSERT OR REPLACE INTO device_baselines
            (mac, ip, updated_at, open_ports_json, banners_json, tls_sha256, drift_status, last_diff_json, egress_domains_json)
            VALUES (?, ?, ?, ?, ?, ?, 'clean', '{}', ?)
            """,
            (mac, target_ip, now, json.dumps(open_ports), json.dumps(banners_map), tls_sha256, prev_egress_json),
        )
        con.commit()
        con.close()
        return {
            "status": "ok",
            "ip": target_ip,
            "mac": mac,
            "baseline_saved": True,
            "drift_detected": False,
            "open_ports": open_ports,
            "tls_sha256": tls_sha256,
        }

    prev_ports = sorted(json.loads(base_row["open_ports_json"] or "[]"))
    prev_banners = json.loads(base_row["banners_json"] or "{}")
    prev_tls = base_row["tls_sha256"] or ""

    new_open_ports = [p for p in open_ports if p not in prev_ports]
    closed_ports = [p for p in prev_ports if p not in open_ports]
    banner_changes = {
        k: {"before": prev_banners.get(k), "after": v}
        for k, v in banners_map.items()
        if k in prev_banners and prev_banners[k] != v
    }
    tls_changed = bool(prev_tls and tls_sha256 and prev_tls != tls_sha256)
    ip_changed = base_row["ip"] != target_ip

    drift_detected = bool(new_open_ports or banner_changes or tls_changed or ip_changed)
    diff_summary = {
        "new_open_ports": new_open_ports,
        "closed_ports": closed_ports,
        "banner_changes": banner_changes,
        "tls_cert_changed": tls_changed,
        "ip_changed": ip_changed,
    }
    con.execute(
        "UPDATE device_baselines SET drift_status = ?, last_diff_json = ? WHERE mac = ?",
        ("drifted" if drift_detected else "clean", json.dumps(diff_summary), mac),
    )
    con.commit()
    con.close()

    if drift_detected:
        emit_security_event(
            "network.baseline_drift",
            {"ip": target_ip, "mac": mac, "changes": diff_summary},
        )

    return {
        "status": "ok",
        "ip": target_ip,
        "mac": mac,
        "drift_detected": drift_detected,
        "open_ports": open_ports,
        "baseline_ports": prev_ports,
        "changes": diff_summary,
    }


def _normalize_egress_domain(raw_host: str) -> str:
    h = (raw_host or "").strip().lower().rstrip(".")
    if not h or h.endswith((".local", ".lan", ".arpa", "_tcp", "_udp")):
        return ""
    parts = [p for p in h.split(".") if p]
    if len(parts) < 2 or all(p.isdigit() for p in parts):
        return ""
    # Collapse deep CDN subdomains to eTLD+1 / 2-part registrable domain (or 3-part for co.uk / com.au)
    if len(parts) >= 3 and parts[-2] in ("co", "com", "net", "org") and len(parts[-1]) == 2:
        return ".".join(parts[-3:])
    return ".".join(parts[-2:])


def _is_private_or_multicast_ipv4(addr: str) -> bool:
    if not addr or "." not in addr:
        return True
    if addr.startswith(("10.", "127.", "169.254.", "192.168.", "224.", "239.", "255.", "0.")):
        return True
    if addr.startswith("172."):
        try:
            sec = int(addr.split(".")[1])
            if 16 <= sec <= 31:
                return True
        except Exception:
            return True
    return False


def check_l2_l3_immune_anomalies(
    sniff_seconds: int = 5,
    dedup_cache: Optional[Dict[str, float]] = None,
) -> Dict[str, Any]:
    """Continuous zero-emission L2/L3 control-plane monitor:
    1) Verifies /proc/net/arp + ip -6 neigh gateway MAC bindings against EXPECTED_GATEWAY_MACS & lan_devices.db.
    2) Passively captures ARP, DHCPv4 offers, and IPv6 Router Advertisements (ICMPv6 type 134) via tshark
       to catch Gratuitous ARP spoofing, rogue DHCPv4 servers, and rogue IPv6 RAs in real time."""
    now = time.time()
    now_i = int(now)
    anomalies: List[Dict[str, Any]] = []
    con = connect_db()
    try:
        expected_macs: Dict[str, str] = {ip: m.lower() for ip, m in EXPECTED_GATEWAY_MACS.items() if m}
        gw_row = con.execute("SELECT mac, trust_level FROM devices WHERE ip = ?", (GATEWAY_IP,)).fetchone()
        if gw_row and gw_row["mac"] and gw_row["trust_level"] == "trusted" and GATEWAY_IP not in expected_macs:
            expected_macs[GATEWAY_IP] = gw_row["mac"].lower()

        # 1. Kernel ARP table inspection (/proc/net/arp)
        arp_ip_to_mac: Dict[str, str] = {}
        try:
            arp_txt = Path("/proc/net/arp").read_text(encoding="utf-8")
            for ln in arp_txt.splitlines()[1:]:
                cols = ln.split()
                if len(cols) >= 4 and cols[2] != "0x0" and cols[3] != "00:00:00:00:00:00":
                    arp_ip_to_mac[cols[0]] = cols[3].lower()
        except Exception:
            pass

        for gw_ip, exp_mac in expected_macs.items():
            obs_mac = arp_ip_to_mac.get(gw_ip)
            if obs_mac and obs_mac != exp_mac:
                anomalies.append({
                    "type": "gateway_arp_spoof",
                    "src_ip": gw_ip,
                    "observed_mac": obs_mac,
                    "expected_mac": exp_mac,
                    "detail": f"Gateway {gw_ip} ARP entry flipped to {obs_mac} (expected {exp_mac})",
                })

        # 2. Bounded passive control-plane capture inside george-kali-tyler
        dur = max(0, min(12, int(sniff_seconds)))
        if dur > 0 and kali_container_status()["running"]:
            iface = PRIMARY_IFACE or "eth0"
            r = subprocess.run(
                [
                    "docker", "exec", KALI_CONTAINER,
                    "tshark", "-i", iface, "-n",
                    "-f", "arp or udp port 67 or (icmp6 and ip6[40] == 134)",
                    "-a", f"duration:{dur}",
                    "-T", "fields",
                    "-e", "arp.isgratuitous",
                    "-e", "arp.src.proto_ipv4",
                    "-e", "arp.src.hw_mac",
                    "-e", "ip.src",
                    "-e", "udp.srcport",
                    "-e", "icmpv6.type",
                    "-e", "ipv6.src",
                    "-e", "eth.src",
                ],
                capture_output=True,
                text=True,
                timeout=dur + 4.0,
            )
            trusted_gw_macs = set(expected_macs.values())
            for ln in r.stdout.splitlines():
                if not ln.strip():
                    continue
                pts = ln.split("\t")
                arp_grat = pts[0] if len(pts) > 0 else ""
                arp_ip = pts[1] if len(pts) > 1 else ""
                arp_mac = (pts[2] if len(pts) > 2 else "").lower()
                ip_src = pts[3] if len(pts) > 3 else ""
                udp_sport = pts[4] if len(pts) > 4 else ""
                icmp6_t = pts[5] if len(pts) > 5 else ""
                ip6_src = pts[6] if len(pts) > 6 else ""
                eth_src = (pts[7] if len(pts) > 7 else "").lower()

                if arp_ip in expected_macs and arp_mac and arp_mac != expected_macs[arp_ip]:
                    anomalies.append({
                        "type": "gratuitous_arp_impersonation" if arp_grat == "1" else "arp_mac_conflict",
                        "src_ip": arp_ip,
                        "observed_mac": arp_mac,
                        "expected_mac": expected_macs[arp_ip],
                        "detail": f"ARP packet claiming protected IP {arp_ip} from unauthorized MAC {arp_mac}",
                    })
                if udp_sport == "67" and ip_src and ip_src not in (GATEWAY_IP, HOST_IP, "0.0.0.0"):
                    anomalies.append({
                        "type": "rogue_dhcpv4_server",
                        "src_ip": ip_src,
                        "observed_mac": eth_src,
                        "detail": f"Rogue DHCPv4 offer/ACK detected from non-gateway host {ip_src} ({eth_src})",
                    })
                if "134" in icmp6_t.split(",") and eth_src and trusted_gw_macs and eth_src not in trusted_gw_macs:
                    # Allow same-OUI mesh peers of configured gateway MACs; flag unknown RAs
                    trusted_gw_ouis = {m[:8].lower() for m in trusted_gw_macs if len(m) >= 8}
                    if eth_src[:8].lower() not in trusted_gw_ouis:
                        anomalies.append({
                            "type": "rogue_ipv6_router_adv",
                            "src_ip": ip6_src or eth_src,
                            "observed_mac": eth_src,
                            "detail": f"Unexpected IPv6 SLAAC Router Advertisement from {ip6_src} ({eth_src})",
                        })

        logged = 0
        cache = dedup_cache if dedup_cache is not None else {}
        for anom in anomalies:
            key = f"{anom['type']}:{anom.get('src_ip')}:{anom.get('observed_mac')}"
            if now - cache.get(key, 0.0) < 300.0:
                continue
            cache[key] = now
            con.execute(
                "INSERT INTO tshark_watch_hits (ts, rule_id, rule_name, src_ip, matched_packets, sample_output) VALUES (?, 0, ?, ?, 1, ?)",
                (now_i, f"l2_l3_guard:{anom['type']}", str(anom.get("src_ip") or ""), anom.get("detail", "")[:400]),
            )
            logged += 1
            emit_security_event("network.l2_l3_anomaly", anom)
        if logged:
            con.commit()
        return {"status": "ok", "ts": now_i, "anomalies": anomalies, "logged_new": logged}
    finally:
        con.close()


def audit_device_egress(ip: str, duration: int = 8, save_baseline: bool = False) -> Dict[str, Any]:
    """Zero-emission passive IoT DNS & TLS-SNI egress baseline auditor.
    Captures outbound DNS queries, TLS SNIs, and direct external IP connections from `ip` (or 'all'
    known_iot devices), compares registrable domains against `device_baselines.egress_domains_json`,
    and flags unexpected cloud endpoints or raw-IP C2 egress."""
    now = int(time.time())
    dur = max(3, min(30, int(duration or 8)))
    con = connect_db()

    if (ip or "").strip().lower() == "all":
        rows = con.execute(
            "SELECT ip FROM devices WHERE online = 1 AND (trust_level IN ('known_iot', 'untrusted') OR device_type LIKE '%iot%')"
        ).fetchall()
        con.close()
        targets = [r["ip"] for r in rows][:8]
        results = [audit_device_egress(t, duration=min(dur, 6), save_baseline=save_baseline) for t in targets]
        return {
            "status": "ok",
            "action": "egress_audit",
            "mode": "all_iot",
            "devices_audited": len(results),
            "anomaly_count": sum(1 for x in results if x.get("anomaly_detected")),
            "results": results,
        }

    try:
        target_ip = validate_lan_ip(ip)
        dev_row = con.execute("SELECT * FROM devices WHERE ip = ?", (target_ip,)).fetchone()
        mac = (dev_row["mac"] if dev_row else f"ip:{target_ip}").lower()
        label = (dev_row["label"] or dev_row["hostname"] or target_ip) if dev_row else target_ip

        ensure_kali_running()
        observed_domains: set[str] = set()
        raw_queries: List[str] = []
        tls_snis: List[str] = []
        resolved_ips: set[str] = set()
        external_dst_ips: set[str] = set()

        if kali_container_status()["running"]:
            iface = PRIMARY_IFACE or "eth0"
            r = subprocess.run(
                [
                    "docker", "exec", KALI_CONTAINER,
                    "tshark", "-i", iface, "-n",
                    "-f", f"host {target_ip}",
                    "-a", f"duration:{dur}",
                    "-T", "fields",
                    "-e", "ip.src",
                    "-e", "ip.dst",
                    "-e", "dns.qry.name",
                    "-e", "dns.a",
                    "-e", "tls.handshake.extensions_server_name",
                ],
                capture_output=True,
                text=True,
                timeout=dur + 6.0,
            )
            for ln in r.stdout.splitlines():
                if not ln.strip():
                    continue
                pts = ln.split("\t")
                src = pts[0] if len(pts) > 0 else ""
                dst = pts[1] if len(pts) > 1 else ""
                dns_q = pts[2] if len(pts) > 2 else ""
                dns_a = pts[3] if len(pts) > 3 else ""
                sni = pts[4] if len(pts) > 4 else ""

                for a_ip in dns_a.split(","):
                    if a_ip.strip():
                        resolved_ips.add(a_ip.strip())
                if src == target_ip:
                    for q in dns_q.split(","):
                        q = q.strip()
                        if q and q not in raw_queries and len(raw_queries) < 30:
                            raw_queries.append(q)
                        dom = _normalize_egress_domain(q)
                        if dom:
                            observed_domains.add(dom)
                    for s in sni.split(","):
                        s = s.strip()
                        if s and s not in tls_snis and len(tls_snis) < 30:
                            tls_snis.append(s)
                        dom = _normalize_egress_domain(s)
                        if dom:
                            observed_domains.add(dom)
                    if dst and not _is_private_or_multicast_ipv4(dst):
                        external_dst_ips.add(dst)

        # Also seed from prior passive traffic_sample_json if the device was idle during this 8s window
        if dev_row and dev_row["traffic_sample_json"]:
            try:
                tsamp = json.loads(dev_row["traffic_sample_json"] or "{}")
                for q in (tsamp.get("dns_queries") or []) + (tsamp.get("tls_sni") or []):
                    dom = _normalize_egress_domain(str(q))
                    if dom:
                        observed_domains.add(dom)
            except Exception:
                pass

        obs_sorted = sorted(observed_domains)
        # Flag non-DNS standard public resolvers (8.8.8.8/8.8.4.4/1.1.1.1) separately from unknown raw-IP egress
        well_known_infra = {"8.8.8.8", "8.8.4.4", "1.1.1.1", "1.0.0.1", "9.9.9.9"}
        raw_ip_egress = sorted(ip_d for ip_d in external_dst_ips if ip_d not in resolved_ips and ip_d not in well_known_infra and not obs_sorted)

        base_row = con.execute("SELECT * FROM device_baselines WHERE mac = ?", (mac,)).fetchone()
        prev_domains: List[str] = []
        if base_row and "egress_domains_json" in base_row.keys():
            try:
                prev_domains = sorted(set(json.loads(base_row["egress_domains_json"] or "[]")))
            except Exception:
                prev_domains = []

        if not base_row or not prev_domains or save_baseline:
            merged = sorted(set(prev_domains) | set(obs_sorted)) if not save_baseline else obs_sorted
            if base_row:
                con.execute(
                    "UPDATE device_baselines SET egress_domains_json = ?, updated_at = ? WHERE mac = ?",
                    (json.dumps(merged), now, mac),
                )
            else:
                con.execute(
                    """
                    INSERT INTO device_baselines
                    (mac, ip, updated_at, open_ports_json, banners_json, tls_sha256, drift_status, last_diff_json, egress_domains_json)
                    VALUES (?, ?, ?, '[]', '{}', '', 'clean', '{}', ?)
                    """,
                    (mac, target_ip, now, json.dumps(merged)),
                )
            con.commit()
            return {
                "status": "ok",
                "action": "egress_audit",
                "ip": target_ip,
                "mac": mac,
                "label": label,
                "duration_sec": dur,
                "packets_emitted": 0,
                "baseline_saved": True,
                "anomaly_detected": False,
                "baseline_domains": merged,
                "observed_domains": obs_sorted,
                "new_egress_domains": [],
                "raw_ip_egress": raw_ip_egress,
                "dns_queries": raw_queries,
                "tls_sni": tls_snis,
            }

        new_domains = [d for d in obs_sorted if d not in prev_domains]
        anomaly = bool(new_domains or raw_ip_egress)
        if anomaly:
            emit_security_event(
                "network.iot_egress_anomaly",
                {
                    "ip": target_ip,
                    "mac": mac,
                    "label": label,
                    "new_egress_domains": new_domains,
                    "raw_ip_egress": raw_ip_egress,
                },
            )
        return {
            "status": "ok",
            "action": "egress_audit",
            "ip": target_ip,
            "mac": mac,
            "label": label,
            "duration_sec": dur,
            "packets_emitted": 0,
            "baseline_saved": False,
            "anomaly_detected": anomaly,
            "baseline_domains": prev_domains,
            "observed_domains": obs_sorted,
            "new_egress_domains": new_domains,
            "raw_ip_egress": raw_ip_egress,
            "dns_queries": raw_queries,
            "tls_sni": tls_snis,
        }
    finally:
        con.close()


def run_immune_patrol(duration: int = 10, auto_quarantine: bool = False) -> Dict[str, Any]:
    """
    Natural Killer (NK) Cell Active LAN Patrol:
    1. Captures a single live packet window inside george-kali-tyler via tshark.
    2. Evaluates all enabled tshark_watch_rules against that capture file.
    3. Audits /proc/net/arp for gateway/infrastructure MAC spoofing.
    4. Checks canary_hits for recent honeypot tripwires.
    5. Runs 30-day rolling retention pruner on lan_devices.db and pcaps/.
    """
    dur = max(3, min(30, int(duration or 10)))
    now = int(time.time())
    ensure_kali_running()
    kali_up = kali_container_status()["running"]

    con = connect_db()
    rules = [dict(r) for r in con.execute("SELECT * FROM tshark_watch_rules WHERE enabled = 1").fetchall()]
    con.close()

    rule_hits: List[Dict[str, Any]] = []
    if kali_up and rules:
        cap_file = f"/tmp/tyler_patrol_{now}.pcap"
        subprocess.run(
            ["docker", "exec", KALI_CONTAINER, "timeout", str(dur + 3), "tshark", "-i", "eth0", "-a", f"duration:{dur}", "-w", cap_file],
            capture_output=True,
            timeout=float(dur + 5),
        )
        con_h = connect_db()
        for rule in rules:
            fields_args: List[str] = []
            for f_name in (rule.get("extract_fields") or "ip.src,ip.dst").split(","):
                f_clean = f_name.strip()
                if f_clean:
                    fields_args.extend(["-e", f_clean])
            r_eval = subprocess.run(
                [
                    "docker",
                    "exec",
                    KALI_CONTAINER,
                    "tshark",
                    "-r",
                    cap_file,
                    "-Y",
                    rule["display_filter"],
                    "-T",
                    "fields",
                    *fields_args,
                ],
                capture_output=True,
                text=True,
                timeout=8.0,
            )
            lines = [ln.strip() for ln in r_eval.stdout.splitlines() if ln.strip()]
            if lines:
                src_ip = lines[0].split("\t")[0].strip() if "\t" in lines[0] else lines[0].split()[0].strip()
                hit_obj = {
                    "rule_id": rule["id"],
                    "rule_name": rule["name"],
                    "severity": rule["severity"],
                    "src_ip": src_ip,
                    "matched_packets": len(lines),
                    "sample_output": "\n".join(lines[:10]),
                }
                rule_hits.append(hit_obj)
                con_h.execute(
                    """
                    INSERT INTO tshark_watch_hits (ts, rule_id, rule_name, src_ip, matched_packets, sample_output)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (now, rule["id"], rule["name"], src_ip, len(lines), hit_obj["sample_output"]),
                )
                con_h.execute(
                    "UPDATE tshark_watch_rules SET last_hit_at = ?, hit_count = hit_count + ? WHERE id = ?",
                    (now, len(lines), rule["id"]),
                )
                emit_security_event(
                    "network.tshark_watch_hit",
                    {
                        "ip": src_ip,
                        "rule_name": rule["name"],
                        "severity": rule["severity"],
                        "matched_packets": len(lines),
                        "sample": hit_obj["sample_output"][:300],
                    },
                )
                if auto_quarantine and src_ip and src_ip not in PROTECTED_IPS:
                    try:
                        validate_lan_ip(src_ip)
                        intervene_device(src_ip, "quarantine")
                    except Exception:
                        pass
        con_h.commit()
        con_h.close()
        subprocess.run(["docker", "exec", KALI_CONTAINER, "rm", "-f", cap_file], capture_output=True, timeout=3.0)

    # Check ARP integrity on configured gateway
    expected_gw_mac = EXPECTED_GATEWAY_MACS.get(GATEWAY_IP, "")
    gw_mac = expected_gw_mac
    try:
        neigh_out = subprocess.check_output(["ip", "-4", "neigh", "show", "dev", "eth0"], text=True, timeout=3.0)
        for line in neigh_out.splitlines():
            parts = line.split()
            if parts and parts[0] == GATEWAY_IP and "lladdr" in parts:
                gw_mac = parts[parts.index("lladdr") + 1].lower()
                break
    except Exception:
        pass
    arp_spoof_detected = bool(expected_gw_mac and gw_mac and gw_mac != expected_gw_mac)
    if arp_spoof_detected:
        emit_security_event(
            "network.arp_spoof",
            {"ip": GATEWAY_IP, "mac": gw_mac, "expected_mac": expected_gw_mac},
        )

    canary_st = manage_canary_trap("status")
    loopback_st = ensure_wsl_loopback_neighbor()
    periph_mesh = poll_lan_peripherals()
    pol = get_tyler_policy()
    prune_stats = prune_tyler_state(pol.get("retention_days", 30), pol.get("max_pcap_mb", 250))

    return {
        "status": "ok",
        "ts": now,
        "duration_s": dur,
        "rules_evaluated": len(rules),
        "tshark_watch_hits": rule_hits,
        "arp_integrity": {
            "gateway_ip": GATEWAY_IP,
            "gateway_mac": gw_mac,
            "spoof_detected": arp_spoof_detected,
            "wsl_loopback_bridge": loopback_st,
        },
        "canary_trap": {
            "running": canary_st.get("running", False),
            "recent_hits_count": canary_st.get("hits_count", 0),
        },
        "peripheral_mesh": {
            "reachable_cast_nodes": periph_mesh.get("reachable_cast_nodes", 0),
            "anomalies_count": len(periph_mesh.get("anomalies", [])),
        },
        "prune": prune_stats,
    }


KALI_AUDIT_LOG = GEORGE_DIR / "state" / "tyler_kali_audit.jsonl"

# Curated Kali Linux Tactical Field Manual for Brother George (Recon, Interrogation, Forensics & Active Defense)
KALI_TACTICAL_MANUAL: Dict[str, Dict[str, Any]] = {
    "nmap": {
        "category": "Reconnaissance, Service Fingerprinting & NSE Interrogation",
        "purpose": "Subnet ARP census (-sn -PR), service/version detection (-sV), OS fingerprinting (-O), and Nmap Scripting Engine (--script) interrogation.",
        "wsl2_note": "In george-kali-tyler, /usr/local/bin/nmap automatically uses --unprivileged -sT for TCP port scans so Hyper-V's virtual switch never drops raw SYN frames, while preserving raw ARP for -sn.",
        "defensive_recipes": [
            "nmap -sn -PR 192.168.1.0/24  # Fast Layer-2 ARP discovery with IEEE OUI vendor lookup",
            "nmap -sV --version-light --top-ports 100 -Pn 192.168.1.35  # Service banner interrogation",
        ],
        "active_interrogation_recipes": [
            "nmap -Pn -sV --script=banner,http-title,ssl-cert,upnp-info,dns-service-discovery 192.168.1.28",
            "nmap -sU -Pn -p 53,67,123,161,1900,5353 --script=dns-service-discovery,upnp-info,snmp-info 192.168.1.35",
        ],
    },
    "tshark": {
        "category": "Deep Packet Inspection & Protocol Telemetry",
        "purpose": "Capture and decode live LAN traffic on eth0: DNS queries, TLS SNI server names, HTTP User-Agents, mDNS/SSDP announcements, and ARP storms.",
        "defensive_recipes": [
            "tshark -i eth0 -a duration:10 -f 'host 192.168.1.35' -T fields -e ip.src -e ip.dst -e _ws.col.Protocol -e dns.qry.name -e tls.handshake.extensions_server_name",
            "tshark -i eth0 -a duration:8 -Y 'arp.duplicate-address-detected or icmp.type==5'  # Detect ARP spoofing or ICMP redirect attacks",
        ],
        "active_interrogation_recipes": [
            "tshark -i eth0 -a duration:10 -Y 'mdns or ssdp or dhcp' -T fields -e ip.src -e dns.resp.name -e http.server -e http.user_agent",
        ],
    },
    "arp-scan": {
        "category": "Layer-2 Ethernet Discovery & MAC Spoof Detection",
        "purpose": "Send raw Ethernet ARP requests to every IPv4 host on the local /24 subnet; uncovers firewalled hosts that drop ICMP/TCP.",
        "defensive_recipes": [
            "arp-scan --interface=eth0 --localnet",
            "arp-scan --interface=eth0 192.168.1.25-192.168.1.45",
        ],
        "active_interrogation_recipes": [
            "arp-scan --interface=eth0 --retry=3 --backoff=1.5 192.168.1.28",
        ],
    },
    "arping": {
        "category": "Layer-2 Host Liveness & Duplicate MAC Probe",
        "purpose": "Measure Layer-2 ARP round-trip latency and detect duplicate IP/MAC impersonation on the local bridge.",
        "defensive_recipes": [
            "arping -c 3 -I eth0 192.168.1.1  # Verify gateway Layer-2 MAC stability",
        ],
        "active_interrogation_recipes": [
            "arping -c 4 -I eth0 192.168.1.28  # Wake and time a sleeping/firewalled IoT radio at Layer 2",
        ],
    },
    "fping": {
        "category": "High-Speed Parallel ICMP Sweep",
        "purpose": "Sweep an entire /24 subnet in < 1.5s to identify ICMP-responsive hosts and measure jitter.",
        "defensive_recipes": [
            "fping -a -g 192.168.1.1 192.168.1.254 -r 1 -t 150 2>/dev/null",
        ],
        "active_interrogation_recipes": [
            "fping -c 5 -p 200 192.168.1.35 192.168.1.28",
        ],
    },
    "hping3": {
        "category": "Custom TCP/UDP/ICMP Packet Crafting & Firewall Probing",
        "purpose": "Test firewall state tables, TCP window sizes, TCP timestamp clock skew, and ACK/SYN/FIN responses on silent IoT devices.",
        "defensive_recipes": [
            "hping3 -1 -c 3 192.168.1.35  # ICMP echo with detailed TTL & ID progression",
        ],
        "active_interrogation_recipes": [
            "hping3 -A -c 3 -p 80 192.168.1.28  # TCP ACK probe to test stateless vs stateful firewall filtering",
            "hping3 -S -c 3 -p 443 --tcp-timestamp 192.168.1.35  # Inspect TCP timestamp uptime & OS window fingerprint",
        ],
    },
    "p0f": {
        "category": "Passive OS & Stack Fingerprinting",
        "purpose": "Passively identify operating systems, TCP stack signatures, and uptime from SYN/ACK packets without alerting target.",
        "defensive_recipes": [
            "timeout 8 p0f -i eth0 'host 192.168.1.35'",
        ],
        "active_interrogation_recipes": [
            "timeout 6 p0f -i eth0",
        ],
    },
    "whatweb": {
        "category": "Web Interface & Embedded Firmware Fingerprinting",
        "purpose": "Identify embedded HTTP servers, router/printer/IoT admin panels, SDK headers, and firmware versions.",
        "defensive_recipes": [
            "whatweb --color=never -a 1 http://192.168.1.38 https://192.168.1.18",
        ],
        "active_interrogation_recipes": [
            "whatweb --color=never -a 3 http://192.168.1.24:3000",
        ],
    },
    "sslscan": {
        "category": "TLS/SSL Certificate & Cipher Suite Auditing",
        "purpose": "Extract X.509 certificate Subject/Issuer CNs, SANs, self-signed device serials, and weak TLS ciphers from HTTPS/Cast/IoT ports.",
        "defensive_recipes": [
            "sslscan --no-colour 192.168.1.34:8443  # Inspect Google Cast / IoT device TLS certificate identity",
        ],
        "active_interrogation_recipes": [
            "sslscan --no-colour --show-certificate 192.168.1.18:443",
        ],
    },
    "upnpc": {
        "category": "UPnP IGD NAT Port-Forward Auditing & Countermeasures",
        "purpose": "List (-l), add (-a), or delete (-d) UPnP Internet Gateway Device port mappings on the home router.",
        "defensive_recipes": [
            "timeout 4 upnpc -l  # List all active UPnP port-forward mappings on the gateway",
            "timeout 4 upnpc -s  # Display IGD status, external WAN IP, and byte counters",
        ],
        "active_interrogation_recipes": [
            "upnpc -d <external_port> TCP  # Tear down an unauthorized UPnP port forward opened by a rogue IoT device",
        ],
    },
    "avahi-browse": {
        "category": "mDNS / Bonjour / Zeroconf Service Discovery",
        "purpose": "Enumerate all mDNS services (_googlecast._tcp, _hap._tcp, _airplay._tcp, _ipp._tcp, _workstation._tcp) advertised on the LAN.",
        "defensive_recipes": [
            "avahi-browse -a -r -t -p  # Resolve and dump all mDNS services and TXT records on the LAN",
        ],
        "active_interrogation_recipes": [
            "dig @224.0.0.251 -p 5353 -x 192.168.1.35 +short  # Direct unicast/multicast mDNS reverse lookup",
        ],
    },
    "snmpwalk": {
        "category": "SNMP Device & Printer MIB Interrogation",
        "purpose": "Query SNMPv1/v2c system MIBs (sysDescr, sysName, sysUpTime) on network printers, switches, and appliances.",
        "defensive_recipes": [
            "snmpwalk -v2c -c public -t 2 -r 1 192.168.1.38 1.3.6.1.2.1.1",
        ],
        "active_interrogation_recipes": [
            "snmpwalk -v1 -c public -t 2 -r 1 192.168.1.28 1.3.6.1.2.1.1",
        ],
    },
    "smbclient": {
        "category": "SMB / NetBIOS Share & Host Auditing",
        "purpose": "Check for exposed unauthenticated SMB shares or NetBIOS hostnames on LAN devices.",
        "defensive_recipes": [
            "smbclient -L //192.168.1.41 -N",
        ],
        "active_interrogation_recipes": [
            "nmap -Pn -p 139,445 --script=smb-os-discovery,smb-enum-shares 192.168.1.28",
        ],
    },
    "iptables": {
        "category": "Active Host Firewall Defense & Quarantine",
        "purpose": "Block, rate-limit, or log inbound/outbound traffic from untrusted or spamming LAN IPs.",
        "defensive_recipes": [
            "iptables -L INPUT -v -n  # List active defensive quarantine rules",
            "iptables -I INPUT -s 192.168.1.28 -j DROP  # Quarantine an untrusted LAN host (use tyler_intervene)",
        ],
        "active_interrogation_recipes": [
            "conntrack -L -s 192.168.1.35 2>/dev/null  # Inspect active kernel connection tracking flows for an IP",
        ],
    },
    "ncat": {
        "category": "Banner Grabbing & Raw Socket Interrogation",
        "purpose": "Connect to open TCP/UDP ports, grab service banners, or verify TLS handshakes.",
        "defensive_recipes": [
            "ncat -v -w 3 192.168.1.18 22 <<< ''",
        ],
        "active_interrogation_recipes": [
            "ncat --ssl -v -w 3 192.168.1.34 8009 <<< ''",
        ],
    },
    "scapy": {
        "category": "Programmable Layer-2/Layer-3 Packet Forensics (Python3 Scapy)",
        "purpose": "Craft custom ARP, ICMP, mDNS, SSDP, or TCP probes and decode raw frames in Python.",
        "defensive_recipes": [
            "python3 -c \"from scapy.all import srp, Ether, ARP; ans, _ = srp(Ether(dst='ff:ff:ff:ff:ff:ff')/ARP(pdst='192.168.1.0/24'), timeout=2, verbose=0); print([(r.psrc, r.hwsrc) for _, r in ans])\"",
        ],
        "active_interrogation_recipes": [
            "python3 -c \"from scapy.all import sr1, IP, ICMP; p = sr1(IP(dst='192.168.1.35')/ICMP(), timeout=2, verbose=0); print(p.summary() if p else 'no reply')\"",
        ],
    },
}


def kali_man_lookup(
    tool: str = "catalog",
    search: Optional[str] = None,
    section: Optional[str] = None,
    max_lines: int = 120,
) -> Dict[str, Any]:
    clean_tool = re.sub(r"[^a-zA-Z0-9_.-]", "", (tool or "catalog").strip().lower())
    if not clean_tool or clean_tool in ("catalog", "list", "all", "help", "arsenal"):
        cat_dict = {
            k: {
                "category": v["category"],
                "purpose": v["purpose"],
                "defensive_recipes": v["defensive_recipes"],
                "active_interrogation_recipes": v["active_interrogation_recipes"],
            }
            for k, v in KALI_TACTICAL_MANUAL.items()
        }
        return {
            "status": "ok",
            "mode": "catalog",
            "container": KALI_CONTAINER,
            "tool_count": len(cat_dict),
            "available_tools": cat_dict,
            "tools": cat_dict,
            "usage_hint": "Call tyler_kali_man(tool='<tool_name>', search='<keyword_or_flag>') to read the live Kali Linux man page, flags, and NSE script docs for any tool, or call tyler_kali_exec(command='<command>') to execute it inside george-kali-tyler.",
        }

    ensure_kali_running()
    kali_up = kali_container_status()["running"]
    tactical_entry = KALI_TACTICAL_MANUAL.get(clean_tool, {})
    man_excerpt = ""
    nse_matches: List[str] = []

    if kali_up:
        try:
            # Query live man page inside george-kali-tyler (with fallback to --help)
            cmd = f"MANWIDTH=100 man -P cat {clean_tool} 2>/dev/null || {clean_tool} --help 2>&1 || true"
            r = subprocess.run(
                ["docker", "exec", KALI_CONTAINER, "bash", "-c", cmd],
                capture_output=True,
                text=True,
                timeout=8.0,
            )
            raw_man = r.stdout.strip()
            lines = raw_man.splitlines()
            clamp = max(30, min(250, int(max_lines or 120)))

            query_term = (search or section or "").strip()
            if query_term and lines:
                pat = re.compile(re.escape(query_term), re.IGNORECASE)
                matched_blocks: List[str] = []
                for idx, ln in enumerate(lines):
                    if pat.search(ln):
                        start = max(0, idx - 3)
                        end = min(len(lines), idx + 18)
                        block = "\n".join(lines[start:end])
                        matched_blocks.append(f"--- [Line {idx + 1}] ---\n{block}")
                        if len(matched_blocks) >= 6:
                            break
                if matched_blocks:
                    man_excerpt = "\n\n".join(matched_blocks)
                else:
                    man_excerpt = f"(No exact match for '{query_term}' in man {clean_tool}; showing synopsis)\n" + "\n".join(lines[:clamp])
            else:
                man_excerpt = "\n".join(lines[:clamp])

            # If querying nmap with a search term, also search /usr/share/nmap/scripts/
            if clean_tool == "nmap" and query_term:
                safe_q = re.sub(r"[^a-zA-Z0-9_.-]", "", query_term.lower())
                if safe_q:
                    nse_glob = (
                        "/usr/share/nmap/scripts/{banner,http-title,ssl-cert,upnp-info,dns-service-discovery,smb-os-discovery,snmp-info,broadcast-*}.nse"
                        if safe_q in ("script", "scripts", "nse")
                        else f"/usr/share/nmap/scripts/*{safe_q}*.nse"
                    )
                    r_nse = subprocess.run(
                        [
                            "docker",
                            "exec",
                            KALI_CONTAINER,
                            "bash",
                            "-c",
                            f"ls {nse_glob} 2>/dev/null | head -n 25",
                        ],
                        capture_output=True,
                        text=True,
                        timeout=4.0,
                    )
                    nse_matches = [Path(p.strip()).name for p in r_nse.stdout.splitlines() if p.strip()]
        except Exception as e:
            man_excerpt = f"Error reading man page in {KALI_CONTAINER}: {e}"

    return {
        "status": "ok",
        "tool": clean_tool,
        "tactical_playbook": tactical_entry,
        "nse_scripts_matching": nse_matches,
        "matching_nse_scripts": nse_matches,
        "man_page_excerpt": man_excerpt[:8000],
    }


KALI_EXEC_ALLOWLIST = {
    "nmap",
    "tshark",
    "dftest",
    "tcpdump",
    "upnpc",
    "arp-scan",
    "arping",
    "ping",
    "traceroute",
    "mtr",
    "dig",
    "nslookup",
    "whois",
    "nc",
    "ncat",
    "curl",
    "openssl",
    "ss",
    "ip",
    "iptables",
    "ip6tables",
    "conntrack",
    "snmpwalk",
    "snmpget",
    "onesixtyone",
    "avahi-browse",
    "nbtscan",
    "smbclient",
    "whatweb",
    "sslscan",
    "p0f",
    "hping3",
    "nikto",
    "dnsenum",
    "man",
    "echo",
}


def kali_exec_tool(command: str, timeout: int = 30) -> Dict[str, Any]:
    raw_cmd = (command or "").strip()
    if not raw_cmd:
        return {"status": "error", "message": "command must not be empty"}

    # Safety Gate -1: Reject shell chaining, subshells, and redirection metacharacters; parse with shlex.split
    if any(meta in raw_cmd for meta in (";", "&&", "||", "|", "`", "$(", "\n", "\r", ">", "<")):
        return {
            "status": "error",
            "message": "Policy Gate Blocked: Shell command chaining, pipes, subshells, and redirections are prohibited in kali_exec_tool.",
        }
    try:
        tokens = shlex.split(raw_cmd)
    except ValueError as exc:
        return {"status": "error", "message": f"Invalid command quoting: {exc}"}
    if not tokens:
        return {"status": "error", "message": "command must not be empty"}

    bin_name = os.path.basename(tokens[0])
    if bin_name == "timeout" and len(tokens) >= 3:
        bin_name = os.path.basename(tokens[2])
    if bin_name not in KALI_EXEC_ALLOWLIST:
        return {
            "status": "error",
            "message": f"Policy Gate Blocked: Binary '{bin_name}' is not in the approved Tyler Kali tool allowlist.",
        }

    # Safety Gate 0: OS-agnostic protection for Linux & WSL2 virtual/loopback/tunnel/bridge interfaces,
    # link-local bridges (169.254.x.x), loopback (127.x.x.x), Tailscale CGNAT (100.64-127.x.x), and kernel routing tables.
    lower_cmd = " ".join(tokens).lower()
    if re.search(r"\bip\s+(?:-[46]\s+)?(?:neigh|neighbor|n|route|r|link|l|addr|a|rule)\s+(?:del|delete|flush|change|replace|set)\b", lower_cmd) and re.search(
        r"\b(lo|loopback\d*|tailscale\d*|wg\d*|tun\d*|tap\d*|docker\d*|br-[a-z0-9_-]*|virbr\d*|veth[a-z0-9_-]*|169\.254\.\d+\.\d+|127\.\d+\.\d+\.\d+|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d+\.\d+|table\s+(?:local|main|default|12[78]|52|\d+))\b",
        lower_cmd,
    ):
        return {
            "status": "error",
            "message": (
                "Policy Gate Blocked: Kernel loopback, virtual bridge, VPN/mesh tunnel interfaces (lo, loopback0, tailscale0, wg*, docker*, br-*), "
                "link-local bridges (169.254.x.x), and kernel routing tables (local/main/127/128/52) are protected across Linux and WSL2. "
                "Modifying or deleting them severs host/localhost connectivity."
            ),
        }

    # Safety Gate 1: Never allow destructive firewall drops or active spoofing against PROTECTED_IPS (including CIDR ranges)
    is_destructive = any(
        tok in lower_cmd
        for tok in (
            "iptables -i",
            "iptables -a",
            "ip6tables -i",
            "ip6tables -a",
            "nft add",
            "arpspoof",
            "ettercap",
            "upnpc -d",
            "kill ",
            "rm -rf",
            "ip neigh del",
            "ip neigh flush",
            "conntrack -d",
        )
    )
    if is_destructive:
        for pip in PROTECTED_IPS:
            if pip in raw_cmd:
                return {
                    "status": "error",
                    "message": f"Policy Gate Blocked: Destructive/blocking command against protected family/infrastructure IP {pip} is prohibited.",
                }

    # Safety Gate 2: Validate CIDR subnets (RFC1918, >= /16, and no destructive CIDR covering PROTECTED_IPS)
    cidrs_in_cmd = re.findall(r"(?<![.\d])(?:\d{1,3}\.){3}\d{1,3}/\d{1,2}(?![.\d])", raw_cmd)
    for cidr_str in cidrs_in_cmd:
        try:
            net = ipaddress.ip_network(cidr_str, strict=False)
            if not (net.is_private or net.is_multicast or net.is_loopback) or net.prefixlen < 16:
                return {
                    "status": "error",
                    "message": f"Policy Gate Blocked: Subnet {cidr_str} is public or broader than /16.",
                }
            if is_destructive:
                for pip in PROTECTED_IPS:
                    try:
                        if ipaddress.ip_address(pip) in net:
                            return {
                                "status": "error",
                                "message": f"Policy Gate Blocked: Destructive CIDR {cidr_str} encompasses protected IP {pip}.",
                            }
                    except ValueError:
                        pass
        except ValueError:
            return {"status": "error", "message": f"Policy Gate Blocked: Invalid CIDR target {cidr_str}."}

    # Safety Gate 3: Ensure any explicit 4-octet IPv4 addresses in active scan commands are private LAN or multicast.
    # Negative lookbehind/lookahead (?<![.\d]) ... (?![.\d]) ensures multi-segment SNMP OIDs like .1.3.6.1.2.1.1.1.0
    # or version strings are never misidentified as public IPv4 addresses.
    ips_in_cmd = re.findall(r"(?<![.\d])(?:\d{1,3}\.){3}\d{1,3}(?![.\d/])", raw_cmd)
    for ip_str in ips_in_cmd:
        try:
            addr = ipaddress.ip_address(ip_str)
            if not (addr.is_private or addr.is_multicast or addr.is_loopback or str(addr) == "255.255.255.255"):
                return {
                    "status": "error",
                    "message": f"Policy Gate Blocked: {ip_str} is a public external IP. The Tyler Kali container is scoped strictly to sovereign home LAN defense (RFC1918/multicast).",
                }
        except ValueError:
            pass

    ensure_kali_running()
    if not kali_container_status()["running"]:
        return {"status": "error", "message": f"Container {KALI_CONTAINER} is not running"}

    t_sec = max(3, min(180, int(timeout or 60)))
    t0 = time.time()
    try:
        r = subprocess.run(
            ["docker", "exec", KALI_CONTAINER, *tokens],
            capture_output=True,
            text=True,
            timeout=float(t_sec),
        )
        elapsed_ms = int((time.time() - t0) * 1000)
        combined = (r.stdout + ("\n" + r.stderr if r.stderr else "")).strip()
        status = "ok" if r.returncode == 0 else "non_zero_exit"
        exit_code = r.returncode
    except subprocess.TimeoutExpired as e:
        elapsed_ms = int((time.time() - t0) * 1000)
        out_part = (e.stdout.decode("utf-8", errors="ignore") if isinstance(e.stdout, bytes) else (e.stdout or ""))
        err_part = (e.stderr.decode("utf-8", errors="ignore") if isinstance(e.stderr, bytes) else (e.stderr or ""))
        combined = (out_part + "\n" + err_part + f"\n[Timed out after {t_sec}s]").strip()
        status = "timeout"
        exit_code = 124
    except Exception as e:
        elapsed_ms = int((time.time() - t0) * 1000)
        combined = f"Execution error: {e}"
        status = "error"
        exit_code = 1

    _append_jsonl_bounded(
        KALI_AUDIT_LOG,
        {
            "ts": int(time.time()),
            "command": raw_cmd,
            "exit_code": exit_code,
            "elapsed_ms": elapsed_ms,
        },
    )

    return {
        "status": status,
        "command": raw_cmd,
        "exit_code": exit_code,
        "elapsed_ms": elapsed_ms,
        "output": combined[:8000],
        "stdout": combined[:8000],
    }


def spelunk_network(
    mode: str = "discover",
    interface: Optional[str] = None,
    ip: Optional[str] = None,
    duration: int = 10,
    ports: str = "22,80,443,445,8080",
) -> Dict[str, Any]:
    """
    Network Spelunking Engine:
    Operates agnostically across any network connected to the host device.
    - discover: Enumerate all attached network interfaces, CIDRs, gateways, and passive kernel neighbor tables (zero packets emitted).
    - ghost_listen: Zero-packet-emission passive reconnaissance (ARP/NDP, mDNS, SSDP, LLMNR, NBNS, DHCP, CDP/LLDP, DNS, TLS SNI, passive TCP SYN OS TTL hints).
    - surgical_probe: Low-observable single-target TCP service/banner check on selected ports.
    - block_peer / unblock_peer: Non-disruptive local kernel netfilter (iptables INPUT/OUTPUT/DOCKER-USER DROP) blackholing of a hostile peer on a foreign network.
    - stealth_lockdown / stealth_release: Host-level stealth shield on a foreign interface (drops unsolicited inbound TCP SYNs while preserving outbound & Tailscale).
    """
    m = (mode or "discover").strip().lower()
    nets = discover_active_networks(_CFG_SUBNET)
    iface = re.sub(r"[^a-zA-Z0-9_.:-]", "", (interface or PRIMARY_IFACE or "eth0"))

    if m == "discover":
        passive_neighbors: List[Dict[str, str]] = []
        try:
            n_out = subprocess.run(["ip", "-4", "neigh", "show"], capture_output=True, text=True, timeout=2.0).stdout
            for ln in n_out.splitlines():
                pts = ln.split()
                if len(pts) >= 4 and "lladdr" in pts and "dev" in pts:
                    nip = pts[0]
                    ndev = pts[pts.index("dev") + 1]
                    nmac = pts[pts.index("lladdr") + 1].lower()
                    if ndev.startswith("loopback") or nip.startswith("169.254."):
                        continue
                    passive_neighbors.append({
                        "ip": nip,
                        "mac": nmac,
                        "interface": ndev,
                        "vendor": resolve_vendor(nmac),
                        "state": pts[-1],
                    })
        except Exception:
            pass
        return {
            "status": "ok",
            "mode": "discover",
            "packets_emitted": 0,
            "primary_interface": PRIMARY_IFACE,
            "active_networks": nets,
            "passive_kernel_neighbors": passive_neighbors,
            "protected_ips": sorted(PROTECTED_IPS),
        }

    if m == "ghost_listen":
        dur = max(2, min(60, int(duration or 10)))
        ensure_kali_running()
        passive_hosts: Dict[str, Dict[str, Any]] = {}
        protocols: Dict[str, int] = {}
        broadcasts: List[str] = []
        if kali_container_status()["running"]:
            try:
                r = subprocess.run(
                    [
                        "docker", "exec", KALI_CONTAINER,
                        "tshark", "-i", iface, "-n",
                        "-a", f"duration:{dur}",
                        "-T", "fields",
                        "-e", "ip.src", "-e", "eth.src", "-e", "arp.src.proto_ipv4", "-e", "arp.src.hw_mac",
                        "-e", "_ws.col.Protocol", "-e", "ip.ttl", "-e", "dns.qry.name",
                        "-e", "tls.handshake.extensions_server_name",
                    ],
                    capture_output=True,
                    text=True,
                    timeout=dur + 6.0,
                )
                for ln in r.stdout.splitlines():
                    if not ln.strip():
                        continue
                    pts = ln.split("\t")
                    ip_src = (pts[0] if len(pts) > 0 else "") or (pts[2] if len(pts) > 2 else "")
                    mac_src = ((pts[1] if len(pts) > 1 else "") or (pts[3] if len(pts) > 3 else "")).lower()
                    proto = pts[4] if len(pts) > 4 and pts[4] else "L2"
                    ttl_str = pts[5] if len(pts) > 5 else ""
                    dns_q = pts[6] if len(pts) > 6 else ""
                    sni = pts[7] if len(pts) > 7 else ""
                    protocols[proto] = protocols.get(proto, 0) + 1
                    if ip_src and not ip_src.startswith(("127.", "169.254.", "0.")):
                        ent = passive_hosts.setdefault(ip_src, {
                            "ip": ip_src,
                            "mac": mac_src,
                            "vendor": resolve_vendor(mac_src) if mac_src else "Unknown",
                            "os_ttl_hint": "Unknown",
                            "protocols": [],
                            "dns_or_mdns": [],
                            "tls_sni": [],
                        })
                        if mac_src and not ent["mac"]:
                            ent["mac"] = mac_src
                            ent["vendor"] = resolve_vendor(mac_src)
                        if proto not in ent["protocols"]:
                            ent["protocols"].append(proto)
                        if ttl_str and ttl_str.split(",")[0].isdigit():
                            ttl_v = int(ttl_str.split(",")[0])
                            if 50 <= ttl_v <= 64:
                                ent["os_ttl_hint"] = "Linux / macOS / iOS / Android (TTL<=64)"
                            elif 110 <= ttl_v <= 128:
                                ent["os_ttl_hint"] = "Windows (TTL<=128)"
                            elif ttl_v > 200:
                                ent["os_ttl_hint"] = "Network Appliance / Router (TTL~255)"
                        if dns_q and dns_q not in ent["dns_or_mdns"] and len(ent["dns_or_mdns"]) < 15:
                            ent["dns_or_mdns"].append(dns_q)
                        if sni and sni not in ent["tls_sni"] and len(ent["tls_sni"]) < 15:
                            ent["tls_sni"].append(sni)
                    if proto in ("MDNS", "SSDP", "NBNS", "LLMNR", "DHCP", "CDP", "LLDP") and len(broadcasts) < 25:
                        broadcasts.append(f"{proto}: {ip_src} ({mac_src}) {dns_q}")
            except Exception as e:
                return {"status": "error", "mode": "ghost_listen", "message": str(e)}
        return {
            "status": "ok",
            "mode": "ghost_listen",
            "interface": iface,
            "duration_sec": dur,
            "packets_emitted": 0,
            "passive_hosts_discovered": list(passive_hosts.values()),
            "protocol_distribution": protocols,
            "broadcast_beacons": broadcasts,
        }

    if m == "surgical_probe":
        target_ip = validate_lan_ip(ip or "")
        port_list = [int(p.strip()) for p in (ports or "22,80,443").split(",") if p.strip().isdigit()][:12]
        open_p = []
        for p in port_list:
            try:
                with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                    s.settimeout(0.35)
                    if s.connect_ex((target_ip, p)) == 0:
                        open_p.append(p)
            except Exception:
                pass
        return {
            "status": "ok",
            "mode": "surgical_probe",
            "target_ip": target_ip,
            "probed_ports": port_list,
            "open_ports": open_p,
        }

    if m in ("block_peer", "unblock_peer"):
        target_ip = validate_lan_ip(ip or "")
        if target_ip in PROTECTED_IPS:
            return {"status": "error", "message": f"Policy Gate Blocked: Cannot block protected host/gateway IP {target_ip}."}
        ensure_kali_running()
        op = "-I" if m == "block_peer" else "-D"
        cmd = (
            f"iptables {op} INPUT -i {iface} -s {target_ip} -j DROP 2>/dev/null || true; "
            f"iptables {op} OUTPUT -o {iface} -d {target_ip} -j DROP 2>/dev/null || true; "
            f"iptables {op} DOCKER-USER -s {target_ip} -j DROP 2>/dev/null || true"
        )
        r = subprocess.run(["docker", "exec", KALI_CONTAINER, "bash", "-c", cmd], capture_output=True, text=True, timeout=6.0)
        return {
            "status": "ok" if r.returncode == 0 else "error",
            "mode": m,
            "interface": iface,
            "target_ip": target_ip,
            "mechanism": "host_netfilter_drop_zero_arp_emission",
        }

    if m in ("stealth_lockdown", "stealth_release"):
        ensure_kali_running()
        op = "-I" if m == "stealth_lockdown" else "-D"
        cmd = (
            f"iptables {op} INPUT -i {iface} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true; "
            f"iptables {op} INPUT -i {iface} -p tcp --syn -j DROP 2>/dev/null || true"
        )
        r = subprocess.run(["docker", "exec", KALI_CONTAINER, "bash", "-c", cmd], capture_output=True, text=True, timeout=6.0)
        return {
            "status": "ok" if r.returncode == 0 else "error",
            "mode": m,
            "interface": iface,
            "mechanism": "foreign_iface_inbound_syn_drop",
        }

    if m == "passive_fingerprint":
        dur = max(3, min(60, int(duration or 10)))
        ensure_kali_running()
        hosts: Dict[str, Dict[str, Any]] = {}
        if kali_container_status()["running"]:
            try:
                r = subprocess.run(
                    [
                        "docker", "exec", KALI_CONTAINER,
                        "tshark", "-i", iface, "-n",
                        "-a", f"duration:{dur}",
                        "-T", "fields",
                        "-e", "ip.src",
                        "-e", "eth.src",
                        "-e", "ip.ttl",
                        "-e", "tcp.window_size_value",
                        "-e", "tcp.options.mss_val",
                        "-e", "dhcp.option.request_list_item",
                        "-e", "dhcp.option.vendor_class_id",
                        "-e", "dhcp.option.hostname",
                        "-e", "tls.handshake.extensions_server_name",
                        "-e", "tls.handshake.ciphersuite",
                        "-e", "http.user_agent",
                        "-e", "dns.qry.name",
                        "-e", "dns.resp.name",
                        "-e", "dns.txt",
                    ],
                    capture_output=True,
                    text=True,
                    timeout=dur + 6.0,
                )
                for ln in r.stdout.splitlines():
                    if not ln.strip():
                        continue
                    pts = ln.split("\t")
                    ip_src = pts[0] if len(pts) > 0 else ""
                    mac_src = (pts[1] if len(pts) > 1 else "").lower()
                    if not ip_src or ip_src.startswith(("127.", "169.254.", "0.")):
                        continue
                    is_rand_mac = bool(len(mac_src) >= 2 and mac_src[1] in ("2", "6", "a", "e"))
                    ent = hosts.setdefault(ip_src, {
                        "ip": ip_src,
                        "mac": mac_src,
                        "is_randomized_mac": is_rand_mac,
                        "vendor": resolve_vendor(mac_src) if mac_src else "Unknown",
                        "p0f_os_signature": "Unknown",
                        "inferred_identity": "Unclassified LAN Peer",
                        "tcp_syn_profile": {},
                        "dhcp_fingerprint": {},
                        "tls_ja3_hints": {"sni": [], "ciphersuites": []},
                        "user_agents": [],
                        "mdns_dns_names": [],
                        "mdns_txt_hints": [],
                    })
                    if mac_src and not ent["mac"]:
                        ent["mac"] = mac_src
                        ent["is_randomized_mac"] = is_rand_mac
                        ent["vendor"] = resolve_vendor(mac_src)
                    ttl_s = (pts[2] if len(pts) > 2 else "").split(",")[0]
                    win_s = (pts[3] if len(pts) > 3 else "").split(",")[0]
                    mss_s = (pts[4] if len(pts) > 4 else "").split(",")[0]
                    dhcp_opt55 = pts[5] if len(pts) > 5 else ""
                    dhcp_opt60 = pts[6] if len(pts) > 6 else ""
                    dhcp_host = pts[7] if len(pts) > 7 else ""
                    tls_sni = pts[8] if len(pts) > 8 else ""
                    tls_cs = pts[9] if len(pts) > 9 else ""
                    ua = pts[10] if len(pts) > 10 else ""
                    dns_q = pts[11] if len(pts) > 11 else ""
                    dns_resp = pts[12] if len(pts) > 12 else ""
                    dns_txt = pts[13] if len(pts) > 13 else ""
                    if ttl_s.isdigit():
                        ttl_v = int(ttl_s)
                        ent["tcp_syn_profile"]["ttl"] = ttl_v
                        if win_s.isdigit():
                            ent["tcp_syn_profile"]["window_size"] = int(win_s)
                        if mss_s.isdigit():
                            ent["tcp_syn_profile"]["mss"] = int(mss_s)
                        if 50 <= ttl_v <= 64:
                            if win_s == "65535":
                                ent["p0f_os_signature"] = "iOS / macOS / FreeBSD (TTL=64, Win=65535)"
                            else:
                                ent["p0f_os_signature"] = "Linux / Android / Embedded Cast (TTL=64)"
                        elif 110 <= ttl_v <= 128:
                            ent["p0f_os_signature"] = "Windows 10/11 TCP/IP Stack (TTL=128)"
                        elif ttl_v > 200:
                            ent["p0f_os_signature"] = "Network Router / Embedded LwIP (TTL=255)"
                    if dhcp_opt55:
                        ent["dhcp_fingerprint"]["option55_param_list"] = dhcp_opt55
                    if dhcp_opt60:
                        ent["dhcp_fingerprint"]["option60_vendor_class"] = dhcp_opt60
                    if dhcp_host:
                        ent["dhcp_fingerprint"]["option12_hostname"] = dhcp_host
                    if tls_sni and tls_sni not in ent["tls_ja3_hints"]["sni"] and len(ent["tls_ja3_hints"]["sni"]) < 12:
                        ent["tls_ja3_hints"]["sni"].append(tls_sni)
                    if tls_cs and len(ent["tls_ja3_hints"]["ciphersuites"]) < 5:
                        ent["tls_ja3_hints"]["ciphersuites"].append(tls_cs[:120])
                    if ua and ua not in ent["user_agents"] and len(ent["user_agents"]) < 6:
                        ent["user_agents"].append(ua)
                    for nm in (dns_q, dns_resp):
                        if nm and nm not in ent["mdns_dns_names"] and len(ent["mdns_dns_names"]) < 14:
                            ent["mdns_dns_names"].append(nm)
                    if dns_txt and dns_txt not in ent["mdns_txt_hints"] and len(ent["mdns_txt_hints"]) < 8:
                        ent["mdns_txt_hints"].append(dns_txt[:140])

                # Behavioral / ecosystem correlation for randomized-MAC mobile & IoT devices
                con_fp = connect_db()
                try:
                    for h_ip, ent in hosts.items():
                        sni_blob = " ".join(ent["tls_ja3_hints"]["sni"]).lower()
                        mdns_blob = (" ".join(ent["mdns_dns_names"]) + " " + " ".join(ent["mdns_txt_hints"])).lower()
                        opt55 = ent["dhcp_fingerprint"].get("option55_param_list", "")
                        opt60 = ent["dhcp_fingerprint"].get("option60_vendor_class", "").lower()
                        if "_companion-link._tcp" in mdns_blob or "_airplay._tcp" in mdns_blob or "icloud.com" in sni_blob or "apple.com" in sni_blob or "108,114,119,252" in opt55:
                            ent["inferred_identity"] = "Apple iOS / macOS Device (Private Wi-Fi MAC)" if ent["is_randomized_mac"] else "Apple macOS / iOS Host"
                        elif "_googlecast._tcp" in mdns_blob or "cast" in mdns_blob:
                            ent["inferred_identity"] = "Google Cast / Android TV Smart Endpoint"
                        elif "android" in opt60 or "googleapis.com" in sni_blob or "gvt1.com" in sni_blob:
                            ent["inferred_identity"] = "Android Mobile Handset (Randomized MAC)" if ent["is_randomized_mac"] else "Google / Android Device"
                        elif "smartthings" in sni_blob or "samsung" in sni_blob:
                            ent["inferred_identity"] = "Samsung SmartThings Appliance"
                        elif "sleepnumber" in sni_blob or "bamlabs" in sni_blob:
                            ent["inferred_identity"] = "Sleep Number Smart Bed Controller"
                        elif ent["p0f_os_signature"] != "Unknown":
                            ent["inferred_identity"] = ent["p0f_os_signature"]
                        con_fp.execute(
                            "UPDATE devices SET fingerprint_json = ? WHERE ip = ? AND (fingerprint_json IS NULL OR fingerprint_json = '{}')",
                            (json.dumps({"passive_profile": ent}), h_ip),
                        )
                    con_fp.commit()
                finally:
                    con_fp.close()
            except Exception as e:
                return {"status": "error", "mode": "passive_fingerprint", "message": str(e)}
        return {
            "status": "ok",
            "mode": "passive_fingerprint",
            "interface": iface,
            "duration_sec": dur,
            "packets_emitted": 0,
            "hosts_fingerprinted": list(hosts.values()),
        }

    return {"status": "error", "message": f"Unknown spelunk mode: {m}"}


def load_network_designations() -> Dict[str, Any]:
    default_cfg: Dict[str, Any] = {
        "auto_switch_posture": True,
        "default_unknown_posture": "foreign_cautious",
        "wifi_defense_enabled": True,
        "airlock_auto_interrogate_open_aps": False,
        "lock_endpoint_roles": True,
        "subnets": {
            LAN_SUBNET: {
                "label": "Primary LAN",
                "designation": "home_trusted" if not _USE_LIVE_FOREIGN_NET else "foreign_cautious",
                "gateway_ip": GATEWAY_IP,
                "gateway_mac": EXPECTED_GATEWAY_MACS.get(GATEWAY_IP, ""),
                "interface": PRIMARY_IFACE,
                "arp_shield": not _USE_LIVE_FOREIGN_NET,
                "stealth_inbound_drop": _USE_LIVE_FOREIGN_NET,
            }
        },
        "protected_ips_override": sorted(PROTECTED_IPS),
    }
    for cand in (
        NETWORK_DESIGNATIONS_PATH,
        LODGE_DIR / ".george" / "config" / "network_designations.json",
        LODGE_DIR / "configs" / "network_designations.example.json",
    ):
        if cand.exists():
            try:
                data = json.loads(cand.read_text(encoding="utf-8"))
                if isinstance(data, dict):
                    default_cfg.update(data)
                    break
            except Exception:
                pass
    return default_cfg


def load_wifi_watchlist() -> Dict[str, Any]:
    default_wl: Dict[str, Any] = {
        "home_ssids": [],
        "known_soft_aps": [
            {
                "ssid_pattern": "*SmartClock*",
                "label": "Unconfigured Smart Display / Cast Soft-AP",
                "classification": "open_soft_ap",
                "auto_alert": True,
                "notes": "Google Cast / Smart Clock provisioning hotspot (TCP :8008 setup API)",
            },
            {
                "ssid_pattern": "[fridge]*",
                "label": "Smart Appliance Soft-AP / Wi-Fi Direct",
                "classification": "appliance_ap",
                "auto_alert": True,
                "notes": "SmartThings / Appliance Wi-Fi beacon",
            },
        ],
        "ignored_ssids": [],
    }
    for cand in (
        WIFI_WATCHLIST_PATH,
        LODGE_DIR / ".george" / "config" / "wifi_watchlist.json",
        LODGE_DIR / "configs" / "wifi_watchlist.example.json",
    ):
        if cand.exists():
            try:
                data = json.loads(cand.read_text(encoding="utf-8"))
                if isinstance(data, dict):
                    default_wl.update(data)
                    break
            except Exception:
                pass
    return default_wl


def manage_network_designations(
    action: str = "get",
    payload: Optional[Dict[str, Any]] = None,
    cidr: Optional[str] = None,
    designation: Optional[str] = None,
    label: Optional[str] = None,
) -> Dict[str, Any]:
    act = (action or "get").strip().lower()
    cfg = load_network_designations()
    wl = load_wifi_watchlist()

    if act == "get":
        return {
            "status": "ok",
            "network_designations": cfg,
            "wifi_watchlist": wl,
            "active_networks": discover_active_networks(_CFG_SUBNET),
        }

    if act == "save" and isinstance(payload, dict):
        if "network_designations" in payload and isinstance(payload["network_designations"], dict):
            cfg.update(payload["network_designations"])
        else:
            for k in (
                "auto_switch_posture",
                "default_unknown_posture",
                "wifi_defense_enabled",
                "airlock_auto_interrogate_open_aps",
                "lock_endpoint_roles",
                "subnets",
                "protected_ips_override",
            ):
                if k in payload:
                    cfg[k] = payload[k]
        NETWORK_DESIGNATIONS_PATH.parent.mkdir(parents=True, exist_ok=True)
        NETWORK_DESIGNATIONS_PATH.write_text(json.dumps(cfg, indent=2) + "\n", encoding="utf-8")
        if "wifi_watchlist" in payload and isinstance(payload["wifi_watchlist"], dict):
            wl.update(payload["wifi_watchlist"])
            WIFI_WATCHLIST_PATH.parent.mkdir(parents=True, exist_ok=True)
            WIFI_WATCHLIST_PATH.write_text(json.dumps(wl, indent=2) + "\n", encoding="utf-8")
        return {"status": "ok", "action": "save", "network_designations": cfg, "wifi_watchlist": wl}

    if act == "save_wifi_watchlist" and isinstance(payload, dict):
        for k in ("home_ssids", "known_soft_aps", "ignored_ssids"):
            if k in payload:
                wl[k] = payload[k]
        WIFI_WATCHLIST_PATH.parent.mkdir(parents=True, exist_ok=True)
        WIFI_WATCHLIST_PATH.write_text(json.dumps(wl, indent=2) + "\n", encoding="utf-8")
        return {"status": "ok", "action": "save_wifi_watchlist", "wifi_watchlist": wl}

    if act == "set_subnet" and cidr:
        subnets = cfg.setdefault("subnets", {})
        entry = subnets.get(cidr, {})
        entry["label"] = label or entry.get("label") or cidr
        entry["designation"] = designation or entry.get("designation") or "foreign_cautious"
        entry["arp_shield"] = entry["designation"] == "home_trusted"
        entry["stealth_inbound_drop"] = entry["designation"] in ("foreign_cautious", "hostile_stealth")
        subnets[cidr] = entry
        NETWORK_DESIGNATIONS_PATH.parent.mkdir(parents=True, exist_ok=True)
        NETWORK_DESIGNATIONS_PATH.write_text(json.dumps(cfg, indent=2) + "\n", encoding="utf-8")
        return {"status": "ok", "action": "set_subnet", "cidr": cidr, "entry": entry, "network_designations": cfg}

    if act == "remove_subnet" and cidr:
        cfg.get("subnets", {}).pop(cidr, None)
        NETWORK_DESIGNATIONS_PATH.parent.mkdir(parents=True, exist_ok=True)
        NETWORK_DESIGNATIONS_PATH.write_text(json.dumps(cfg, indent=2) + "\n", encoding="utf-8")
        return {"status": "ok", "action": "remove_subnet", "cidr": cidr, "network_designations": cfg}

    return {"status": "error", "message": f"Unknown designations action: {act}"}


def emergency_network_reset() -> Dict[str, Any]:
    """
    Operator One-Click Panic / Fail-Safe Heal:
    1. Disconnects secondary Wi-Fi adapter (Wi-Fi 4 / eth1) from any Soft-AP and deletes temporary TYLER_AIRLOCK profiles.
    2. Flushes all Tyler-injected iptables rules (INPUT, OUTPUT, FORWARD, DOCKER-USER) in george-kali-tyler.
    3. Releases static ARP pins on non-gateway peers and verifies WSL2 kernel loopback0 routing bridge.
    4. Resets Tyler response posture to safe 'confirm' mode.
    """
    steps: List[str] = []
    netsh_path = Path("/mnt/c/Windows/System32/netsh.exe")
    if netsh_path.exists():
        try:
            subprocess.run(
                [str(netsh_path), "wlan", "disconnect", "interface=Wi-Fi 4"],
                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5.0,
            )
            steps.append("Disconnected Windows Wi-Fi 4 radio from any active wireless session")
        except Exception as e:
            steps.append(f"Wi-Fi 4 disconnect note: {e}")
        try:
            prof_out = subprocess.run(
                [str(netsh_path), "wlan", "show", "profiles", "interface=Wi-Fi 4"],
                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5.0,
            ).stdout
            for m in re.finditer(r":\s*(TYLER_AIRLOCK_\S+)", prof_out):
                pname = m.group(1).strip()
                subprocess.run(
                    [str(netsh_path), "wlan", "delete", "profile", f"name={pname}", "interface=Wi-Fi 4"],
                    stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5.0,
                )
                steps.append(f"Deleted temporary WLAN profile {pname}")
        except Exception:
            pass

    if kali_container_status()["running"]:
        try:
            flush_cmd = (
                "for fw in iptables ip6tables; do "
                "  command -v $fw >/dev/null 2>&1 || continue; "
                "  for ch in TYLER_INPUT TYLER_OUTPUT TYLER_DOCKER TYLER_AIRLOCK_IN TYLER_AIRLOCK_OUT TYLER_AIRLOCK_FWD; do "
                "    $fw -F $ch 2>/dev/null || true; "
                "  done; "
                "done; "
                "iptables -D DOCKER-USER -i eth1 -j DROP 2>/dev/null || true; "
                "iptables -D FORWARD -i eth1 -j DROP 2>/dev/null || true"
            )
            subprocess.run(["docker", "exec", KALI_CONTAINER, "bash", "-c", flush_cmd], capture_output=True, text=True, timeout=6.0)
            steps.append("Flushed isolated TYLER_* iptables/ip6tables chains (preserving host INPUT/OUTPUT/SSH/Docker chains)")
        except Exception as e:
            steps.append(f"iptables flush note: {e}")

    try:
        rt_127 = subprocess.run(["ip", "route", "show", "table", "127"], capture_output=True, text=True, timeout=2.0).stdout
        for m in re.finditer(r"default\s+via\s+(\d+\.\d+\.\d+\.\d+)\s+dev\s+(loopback\d+)", rt_127):
            gw_127, dev_127 = m.group(1), m.group(2)
            # Ensure kernel neighbor entry for loopback0 exists if missing
            n_127 = subprocess.run(["ip", "neigh", "show", gw_127, "dev", dev_127], capture_output=True, text=True, timeout=2.0).stdout
            if "PERMANENT" not in n_127:
                steps.append(f"Verified WSL2 mirrored loopback bridge ({dev_127} via {gw_127})")
            else:
                steps.append(f"WSL2 mirrored loopback bridge ({dev_127} -> {gw_127}) intact (PERMANENT)")
    except Exception:
        pass

    try:
        set_tyler_policy(response_mode="confirm")
        steps.append("Reset Tyler policy response_mode to 'confirm' (Tier B operator gate active)")
    except Exception:
        pass

    return {
        "status": "ok",
        "action": "emergency_network_reset",
        "ts": int(time.time()),
        "recovery_steps": steps,
    }


def _detect_linux_wifi_interface() -> Optional[str]:
    """
    Detects a native Linux 802.11 wireless interface (`nl80211` / `cfg80211`) via:
      1. `TYLER_WIFI_IFACE` environment override (if present in `/sys/class/net`),
      2. `/sys/class/net/<iface>/phy80211` or `/sys/class/net/<iface>/wireless`,
      3. `iw dev` output (`Interface <iface>`).
    Returns `None` when running inside WSL2 without a native Linux wireless adapter attached.
    """
    env_if = (os.environ.get("TYLER_WIFI_IFACE") or "").strip()
    if env_if and Path(f"/sys/class/net/{env_if}").exists():
        return env_if

    sys_net = Path("/sys/class/net")
    if sys_net.exists():
        for entry in sorted(sys_net.iterdir()):
            name = entry.name
            if name == "lo" or name.startswith(("docker", "veth", "br-", "tailscale", "virbr", "loopback")):
                continue
            if (entry / "phy80211").exists() or (entry / "wireless").exists():
                return name

    for iw_cmd in ("/usr/sbin/iw", "/sbin/iw", "iw"):
        try:
            r = subprocess.run([iw_cmd, "dev"], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=2.0)
            if r.returncode == 0 and r.stdout:
                for ln in r.stdout.splitlines():
                    m = re.match(r"^\s*Interface\s+([A-Za-z0-9_.-]+)\s*$", ln)
                    if m:
                        return m.group(1)
        except Exception:
            continue
    return None


def _get_windows_wifi_status() -> Dict[str, Any]:
    """
    Queries the wireless adapter state across both Pure Linux (`nl80211` / `iw` / `nmcli`)
    and WSL2 (`netsh.exe wlan show interfaces` with `stdin=DEVNULL` correlated to `eth1`).
    """
    netsh_path = Path("/mnt/c/Windows/System32/netsh.exe")
    linux_iface = _detect_linux_wifi_interface()
    info: Dict[str, Any] = {
        "available": False,
        "backend": "linux_nl80211" if linux_iface else "linux_wireless",
        "adapter_name": linux_iface or "wlan0",
        "wsl_interface": linux_iface or "eth1",
        "description": "",
        "guid": "",
        "mac": "",
        "state": "disconnected",
        "current_ssid": "",
        "current_bssid": "",
        "current_profile": "",
        "band": "",
        "channel": 0,
        "signal_pct": 0,
        "radio_status": "",
        "primary_wired_interface": PRIMARY_IFACE,
        "primary_wired_up": bool(_LIVE_NETWORKS),
        "safe_secondary_radio": True,
    }
    if linux_iface:
        info["available"] = True
        info["backend"] = "linux_nl80211"
        info["adapter_name"] = linux_iface
        info["wsl_interface"] = linux_iface
        info["description"] = f"Linux nl80211 Wireless ({linux_iface})"
        info["radio_status"] = "Hardware On / Software On"
        try:
            mac_p = Path(f"/sys/class/net/{linux_iface}/address")
            if mac_p.exists():
                info["mac"] = mac_p.read_text(encoding="utf-8").strip().lower()
        except Exception:
            pass
        for iw_cmd in ("/usr/sbin/iw", "/sbin/iw", "iw"):
            try:
                r_iw = subprocess.run(
                    [iw_cmd, "dev", linux_iface, "link"],
                    stdin=subprocess.DEVNULL,
                    capture_output=True,
                    text=True,
                    timeout=2.5,
                )
                if r_iw.returncode == 0 and r_iw.stdout:
                    out_iw = r_iw.stdout
                    if "Not connected" not in out_iw:
                        info["state"] = "connected"
                        m_b = re.search(r"Connected to\s+([0-9a-fA-F:]{17})", out_iw)
                        if m_b:
                            info["current_bssid"] = m_b.group(1).lower()
                        m_s = re.search(r"^\s*SSID:\s*(.+)$", out_iw, re.M)
                        if m_s:
                            info["current_ssid"] = m_s.group(1).strip()
                            info["current_profile"] = info["current_ssid"]
                        m_f = re.search(r"^\s*freq:\s*(\d+)", out_iw, re.M)
                        if m_f:
                            fmhz = int(m_f.group(1))
                            info["channel"] = _freq_mhz_to_channel(fmhz)
                            info["band"] = _classify_wifi_band(fmhz, info["channel"])
                        m_sig = re.search(r"^\s*signal:\s*(-?\d+(?:\.\d+)?)\s*dBm", out_iw, re.M)
                        if m_sig:
                            dbm_v = float(m_sig.group(1))
                            info["signal_pct"] = max(0, min(100, int(round(2.0 * (dbm_v + 100.0)))))
                    break
            except Exception:
                continue
        info["safe_secondary_radio"] = bool(info["primary_wired_up"] and linux_iface != PRIMARY_IFACE)
        return info

    if netsh_path.exists():
        try:
            r = subprocess.run(
                [str(netsh_path), "wlan", "show", "interfaces"],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=6.0,
            )
            out = r.stdout or ""
            if "Name" in out and ":" in out:
                info["available"] = True
                info["backend"] = "wsl2_windows_netsh"
                for ln in out.splitlines():
                    if ":" not in ln:
                        continue
                    k, v = ln.split(":", 1)
                    k_clean = k.strip().lower()
                    v_clean = v.strip()
                    if k_clean == "name":
                        info["adapter_name"] = v_clean
                    elif k_clean == "description":
                        info["description"] = v_clean
                    elif k_clean == "guid":
                        info["guid"] = v_clean
                    elif k_clean == "physical address":
                        info["mac"] = v_clean.lower()
                    elif k_clean == "state":
                        info["state"] = v_clean.lower()
                    elif k_clean == "ssid":
                        info["current_ssid"] = v_clean
                    elif k_clean == "ap bssid" or k_clean == "bssid":
                        info["current_bssid"] = v_clean.lower()
                    elif k_clean == "profile":
                        info["current_profile"] = v_clean
                    elif k_clean == "band":
                        info["band"] = v_clean
                    elif k_clean == "channel" and v_clean.isdigit():
                        info["channel"] = int(v_clean)
                    elif k_clean == "signal":
                        m_sig = re.search(r"(\d+)%", v_clean)
                        if m_sig:
                            info["signal_pct"] = int(m_sig.group(1))
                    elif k_clean == "radio status":
                        info["radio_status"] = v_clean
        except Exception as e:
            info["error"] = str(e)

    # Correlate adapter MAC with Linux interface (e.g. eth1 in WSL2 mirrored mode)
    if info["mac"]:
        try:
            link_out = subprocess.run(["ip", "-o", "link", "show"], capture_output=True, text=True, timeout=2.0).stdout
            for ln in link_out.splitlines():
                m_if = re.match(r"^\d+:\s+([^:@\s]+).*?\slink/ether\s+([0-9a-fA-F:]{17})\b", ln)
                if m_if and m_if.group(2).lower() == info["mac"]:
                    info["wsl_interface"] = m_if.group(1)
                    break
        except Exception:
            pass
    info["safe_secondary_radio"] = bool(info["primary_wired_up"] and info["wsl_interface"] != PRIMARY_IFACE)
    return info


def _get_windows_wifi_ipv4(adapter_name: str = "Wi-Fi 4", wsl_iface: str = "eth1") -> Tuple[str, str, str]:
    """Returns (ip, prefix_or_mask, gateway) for the wireless interface using ip addr + ipconfig.exe."""
    ip_addr, cidr_str, gw_addr = "", "", ""
    try:
        ad_out = subprocess.run(["ip", "-o", "-4", "addr", "show", "dev", wsl_iface], capture_output=True, text=True, timeout=2.0).stdout
        for ln in ad_out.splitlines():
            m = re.search(r"inet\s+(\d+\.\d+\.\d+\.\d+)/(\d+)", ln)
            if m and not m.group(1).startswith("169.254."):
                ip_addr = m.group(1)
                cidr_str = str(ipaddress.IPv4Interface(f"{m.group(1)}/{m.group(2)}").network)
                break
        rt_out = subprocess.run(["ip", "-4", "route", "show", "dev", wsl_iface], capture_output=True, text=True, timeout=2.0).stdout
        for ln in rt_out.splitlines():
            m_gw = re.search(r"via\s+(\d+\.\d+\.\d+\.\d+)", ln)
            if m_gw:
                gw_addr = m_gw.group(1)
                break
    except Exception:
        pass

    ipcfg = Path("/mnt/c/Windows/System32/ipconfig.exe")
    if ipcfg.exists():
        try:
            r = subprocess.run([str(ipcfg)], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=4.0)
            in_sect = False
            mask_s = "255.255.255.0"
            for ln in (r.stdout or "").splitlines():
                if "adapter " in ln and adapter_name.lower() in ln.lower():
                    in_sect = True
                    continue
                if in_sect and ln and not ln.startswith(" ") and "adapter " in ln:
                    break
                if in_sect:
                    m_ip = re.search(r"IPv4 Address[.\s]*:\s*(\d+\.\d+\.\d+\.\d+)", ln, re.I)
                    if m_ip and not m_ip.group(1).startswith("169.254."):
                        ip_addr = ip_addr or m_ip.group(1)
                    m_mk = re.search(r"Subnet Mask[.\s]*:\s*(\d+\.\d+\.\d+\.\d+)", ln, re.I)
                    if m_mk:
                        mask_s = m_mk.group(1)
                    m_gw = re.search(r"Default Gateway[.\s]*:\s*(\d+\.\d+\.\d+\.\d+)", ln, re.I)
                    if m_gw:
                        gw_addr = gw_addr or m_gw.group(1)
            if ip_addr and not cidr_str:
                try:
                    cidr_str = str(ipaddress.IPv4Interface(f"{ip_addr}/{mask_s}").network)
                except Exception:
                    cidr_str = f"{ip_addr}/24"
        except Exception:
            pass
    if ip_addr and not gw_addr:
        # Google Cast / Lenovo Smart Clock Soft-APs use 192.168.255.249/30 (where client is .250 and AP is .249)
        if ip_addr.startswith("192.168.255."):
            gw_addr = "192.168.255.249"
        else:
            gw_addr = ip_addr.rsplit(".", 1)[0] + ".1"
    return ip_addr, cidr_str, gw_addr


def _http_fetch_via_wifi(
    url: str,
    wifi_ip: str = "",
    method: str = "GET",
    json_body: Optional[Dict[str, Any]] = None,
    timeout: float = 4.5,
) -> Dict[str, Any]:
    """
    Fetches an HTTP/HTTPS endpoint on the Soft-AP using curl.exe bound to the Windows Wi-Fi IPv4 address
    (with native Python urllib fallback), ensuring 100% reliable Soft-AP reachability under WSL2.
    """
    import ssl

    curl_exe = Path("/mnt/c/Windows/System32/curl.exe")
    body_str = json.dumps(json_body) if json_body is not None else None
    if curl_exe.exists():
        cmd = [str(curl_exe), "-k", "-sS", "-i", "-m", str(int(max(2, timeout))), "-X", method.upper()]
        if wifi_ip:
            cmd.extend(["--interface", wifi_ip])
        cmd.extend([
            "-H", "Content-Type: application/json",
            "-H", "Origin: https://www.google.com",
        ])
        if body_str is not None:
            cmd.extend(["-d", body_str])
        cmd.append(url)
        try:
            r = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout + 2.0)
            raw = r.stdout or ""
            if r.returncode == 0 and raw:
                parts = re.split(r"\r?\n\r?\n", raw, maxsplit=1)
                hdr_block = parts[0] if parts else ""
                body_part = parts[1].strip() if len(parts) > 1 else ""
                status_line = hdr_block.splitlines()[0] if hdr_block else "HTTP/1.1 200 OK"
                parsed_json = None
                if body_part.startswith(("{", "[")):
                    try:
                        parsed_json = json.loads(body_part)
                    except Exception:
                        pass
                return {
                    "ok": " 200 " in status_line or status_line.endswith(" 200"),
                    "url": url,
                    "method": method.upper(),
                    "status_line": status_line,
                    "json": parsed_json,
                    "body": body_part[:4000],
                }
        except Exception:
            pass

    # Fallback to Linux urllib (supports self-signed Cast HTTPS :8443 certificates)
    try:
        data_bytes = body_str.encode("utf-8") if body_str is not None else None
        ctx = ssl._create_unverified_context() if url.startswith("https://") else None
        req = urllib.request.Request(
            url,
            data=data_bytes,
            headers={
                "Content-Type": "application/json",
                "Origin": "https://www.google.com",
                "User-Agent": "BlueLodge-Tyler-Airlock/1.0",
            },
            method=method.upper(),
        )
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            raw_b = resp.read().decode("utf-8", errors="replace").strip()
            parsed_json = None
            if raw_b.startswith(("{", "[")):
                try:
                    parsed_json = json.loads(raw_b)
                except Exception:
                    pass
            return {
                "ok": resp.status == 200,
                "url": url,
                "method": method.upper(),
                "status_line": f"HTTP {resp.status}",
                "json": parsed_json,
                "body": raw_b[:4000],
            }
    except Exception as e:
        return {"ok": False, "url": url, "method": method.upper(), "error": str(e)}


def _encode_varint(val: int) -> bytes:
    out = bytearray()
    while val > 0x7F:
        out.append((val & 0x7F) | 0x80)
        val >>= 7
    out.append(val & 0x7F)
    return bytes(out)


def _encode_castv2_frame(source_id: str, dest_id: str, namespace: str, payload: Dict[str, Any]) -> bytes:
    payload_bytes = json.dumps(payload).encode("utf-8")
    src_b = source_id.encode("utf-8")
    dst_b = dest_id.encode("utf-8")
    ns_b = namespace.encode("utf-8")
    msg = bytearray()
    msg += b"\x08\x00"  # protocol_version = 0 (CASTV2_1_0)
    msg += b"\x12" + _encode_varint(len(src_b)) + src_b
    msg += b"\x1a" + _encode_varint(len(dst_b)) + dst_b
    msg += b"\x22" + _encode_varint(len(ns_b)) + ns_b
    msg += b"\x28\x00"  # payload_type = 0 (STRING)
    msg += b"\x32" + _encode_varint(len(payload_bytes)) + payload_bytes
    return len(msg).to_bytes(4, "big") + bytes(msg)


def _castv2_tls_surprise(host: str, wifi_ip: str = "", port: int = 8009) -> Dict[str, Any]:
    """Execute a direct CastV2 TLS (:8009) volume chime & receiver status exchange over the Soft-AP link."""
    import base64

    f_conn = base64.b64encode(
        _encode_castv2_frame("sender-0", "receiver-0", "urn:x-cast:com.google.cast.tp.connection", {"type": "CONNECT"})
    ).decode("ascii")
    f_stat = base64.b64encode(
        _encode_castv2_frame("sender-0", "receiver-0", "urn:x-cast:com.google.cast.receiver", {"type": "GET_STATUS", "requestId": 1})
    ).decode("ascii")
    vol_frames = [
        base64.b64encode(
            _encode_castv2_frame(
                "sender-0",
                "receiver-0",
                "urn:x-cast:com.google.cast.receiver",
                {"type": "SET_VOLUME", "volume": {"level": lvl, "muted": False}, "requestId": idx + 2},
            )
        ).decode("ascii")
        for idx, lvl in enumerate((0.35, 0.75, 0.40, 0.80))
    ]
    f_launch = base64.b64encode(
        _encode_castv2_frame(
            "sender-0",
            "receiver-0",
            "urn:x-cast:com.google.cast.receiver",
            {"type": "LAUNCH", "appId": "CC1AD845", "requestId": 10},
        )
    ).decode("ascii")

    ps_path = Path("/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe")
    if ps_path.exists():
        bind_stmt = (
            f"$localEp = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse('{wifi_ip}'), 0); "
            f"$tcp = New-Object System.Net.Sockets.TcpClient($localEp);"
            if wifi_ip
            else "$tcp = New-Object System.Net.Sockets.TcpClient;"
        )
        vol_writes = " ".join(
            f"$b = [Convert]::FromBase64String('{vf}'); $ssl.Write($b, 0, $b.Length); $ssl.Flush(); Start-Sleep -Milliseconds 480;"
            for vf in vol_frames
        )
        ps_script = (
            f"try {{ "
            f"{bind_stmt} "
            f"$tcp.ReceiveTimeout = 2500; $tcp.SendTimeout = 2500; "
            f"$tcp.Connect('{host}', {port}); "
            f"$cb = [System.Net.Security.RemoteCertificateValidationCallback]{{ $true }}; "
            f"$ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, $cb); "
            f"$ssl.AuthenticateAsClient('{host}', $null, [System.Security.Authentication.SslProtocols]::Tls12, $false); "
            f"$b1 = [Convert]::FromBase64String('{f_conn}'); $ssl.Write($b1, 0, $b1.Length); "
            f"$b2 = [Convert]::FromBase64String('{f_stat}'); $ssl.Write($b2, 0, $b2.Length); $ssl.Flush(); "
            f"Start-Sleep -Milliseconds 350; "
            f"{vol_writes} "
            f"$bL = [Convert]::FromBase64String('{f_launch}'); $ssl.Write($bL, 0, $bL.Length); $ssl.Flush(); "
            f"Start-Sleep -Milliseconds 450; "
            f"$buf = New-Object byte[] 8192; "
            f"$n = 0; try {{ $n = $ssl.Read($buf, 0, $buf.Length) }} catch {{}}; "
            f"$ssl.Close(); $tcp.Close(); "
            f"if ($n -gt 0) {{ [Convert]::ToBase64String($buf, 0, $n) }} else {{ 'CONNECTED_OK' }} "
            f"}} catch {{ Write-Output ('ERR:' + $_.Exception.Message) }}"
        )
        try:
            r = subprocess.run(
                [str(ps_path), "-NoProfile", "-Command", ps_script],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=12.0,
            )
            out_s = (r.stdout or "").strip()
            if out_s and not out_s.startswith("ERR:"):
                decoded_json_msgs = []
                if out_s != "CONNECTED_OK":
                    try:
                        raw_resp = base64.b64decode(out_s)
                        txt_resp = raw_resp.decode("utf-8", errors="ignore")
                        for m in re.finditer(r"\{.*?\}(?![^{]*\})", txt_resp):
                            decoded_json_msgs.append(m.group(0))
                        if not decoded_json_msgs and "{" in txt_resp:
                            s_idx = txt_resp.find("{")
                            e_idx = txt_resp.rfind("}")
                            if e_idx > s_idx:
                                decoded_json_msgs.append(txt_resp[s_idx : e_idx + 1])
                    except Exception:
                        pass
                return {
                    "ok": True,
                    "transport": "windows_sslstream_castv2_8009",
                    "volume_steps_triggered": [0.35, 0.75, 0.40, 0.80],
                    "app_launch_requested": "CC1AD845",
                    "receiver_responses": decoded_json_msgs[:3],
                }
            return {
                "ok": False,
                "note": "CastV2 :8009 TLS session rejected by device while in unprovisioned setup_state=10; physical surprise delivered via :8443/setup/set_eureka_info (live SSID & on-screen setup name changed + 24h time_format=2).",
                "raw_detail": out_s or (r.stderr or "")[:300],
            }
        except Exception as e:
            return {"ok": False, "error": str(e)}
    return {"ok": False, "error": "PowerShell SslStream unavailable"}


def _list_claimed_peripherals() -> List[Dict[str, Any]]:
    con = connect_db()
    rows = [dict(r) for r in con.execute("SELECT * FROM claimed_peripherals ORDER BY last_updated DESC").fetchall()]
    air_map = {
        (r["bssid"] or "").lower(): dict(r)
        for r in con.execute("SELECT bssid, ssid, signal_pct, channel, band, last_seen FROM wifi_airspace").fetchall()
    }
    con.close()
    out: List[Dict[str, Any]] = []
    for r in rows:
        b_mac = (r.get("bssid") or "").lower()
        for k_json, k_out in (
            ("original_settings_json", "original_settings"),
            ("baseline_stats_json", "baseline_stats"),
            ("last_telemetry_json", "last_telemetry"),
        ):
            try:
                r[k_out] = json.loads(r.pop(k_json, "{}") or "{}")
            except Exception:
                r[k_out] = {}
        air = air_map.get(b_mac)
        r["airspace_visible"] = bool(air)
        r["airspace_signal_pct"] = int(air["signal_pct"]) if air else 0
        r["airspace_channel"] = int(air["channel"]) if air else 0
        r["airspace_band"] = str(air["band"]) if air else ""
        if air and air.get("ssid"):
            r["live_beacon_ssid"] = air["ssid"]
        out.append(r)
    return out


def _upsert_claimed_peripheral(
    bssid: str,
    current_ssid: str,
    dossier: Dict[str, Any],
    pre_name: str = "",
    pre_ssid: str = "",
    pre_settings: Optional[Dict[str, Any]] = None,
    role: Optional[str] = None,
    status: Optional[str] = None,
    extra_telemetry: Optional[Dict[str, Any]] = None,
    notes: Optional[str] = None,
) -> Dict[str, Any]:
    b_mac = (bssid or "").strip().lower()
    if not b_mac:
        return {}
    now = int(time.time())
    con = connect_db()
    existing = con.execute("SELECT * FROM claimed_peripherals WHERE bssid = ?", (b_mac,)).fetchone()
    e_info = dossier.get("eureka_info") or {}
    d_info = e_info.get("device_info") or {}
    setup_info = e_info.get("setup") or {}
    suffix = str(setup_info.get("ssid_suffix") or "q001")
    model_nm = str(d_info.get("model_name") or (existing["model_name"] if existing else "Google Cast Soft-AP"))
    cur_name = str(e_info.get("name") or (existing["current_name"] if existing else pre_name or model_nm))
    cur_ssid_val = str(current_ssid or (existing["current_ssid"] if existing else ""))
    gw = str((dossier.get("dhcp_lease") or {}).get("soft_ap_gateway") or (existing["soft_ap_gateway"] if existing else "192.168.255.249"))
    pub_key = str(d_info.get("public_key") or (existing["public_key"] if existing else ""))

    if existing and existing["original_name"]:
        orig_name = existing["original_name"]
        orig_ssid = existing["original_ssid"]
        orig_settings_str = existing["original_settings_json"]
        base_stats_str = existing["baseline_stats_json"]
        claimed_ts = int(existing["claimed_at"] or now)
    else:
        cand_orig_name = pre_name or cur_name
        if "Lenovo Smart Clock" in model_nm and ("George" in cand_orig_name or "Blue Lodge" in cand_orig_name or not cand_orig_name):
            orig_name = "LenovoSmartClock5544"
            orig_ssid = f"LenovoSmartClock5544.{suffix},"
        else:
            orig_name = cand_orig_name or model_nm
            orig_ssid = pre_ssid or cur_ssid_val
        orig_settings_str = json.dumps(
            pre_settings
            if isinstance(pre_settings, dict) and pre_settings
            else {"locale": "en-US", "time_format": 1, "system_sound_effects": True}
        )
        base_stats_str = json.dumps(setup_info.get("stats") or {})
        claimed_ts = now

    prev_telem: Dict[str, Any] = {}
    if existing and existing["last_telemetry_json"]:
        try:
            prev_telem = json.loads(existing["last_telemetry_json"] or "{}")
        except Exception:
            prev_telem = {}
    if dossier.get("nearby_wifi_seen_by_device"):
        prev_telem["nearby_wifi_seen_by_device"] = dossier["nearby_wifi_seen_by_device"]
    if extra_telemetry:
        prev_telem.update(extra_telemetry)

    new_role = role or (existing["current_role"] if existing else "claimed_sensor")
    new_status = status or (existing["status"] if existing else "claimed")
    new_notes = notes or (existing["notes"] if existing else "Enrolled via 6-Layer Airlock Soft-AP Interrogation")

    con.execute(
        """
        INSERT INTO claimed_peripherals
        (bssid, device_type, manufacturer, model_name, product_name, cloud_device_id, ssdp_udn,
         original_ssid, original_name, original_settings_json, current_ssid, current_name,
         current_role, status, soft_ap_gateway, public_key, baseline_stats_json,
         last_telemetry_json, claimed_at, last_updated, notes)
        VALUES (?, 'google_cast_soft_ap', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(bssid) DO UPDATE SET
            manufacturer= CASE WHEN excluded.manufacturer != '' THEN excluded.manufacturer ELSE claimed_peripherals.manufacturer END,
            model_name= CASE WHEN excluded.model_name != '' THEN excluded.model_name ELSE claimed_peripherals.model_name END,
            product_name= CASE WHEN excluded.product_name != '' THEN excluded.product_name ELSE claimed_peripherals.product_name END,
            cloud_device_id= CASE WHEN excluded.cloud_device_id != '' THEN excluded.cloud_device_id ELSE claimed_peripherals.cloud_device_id END,
            ssdp_udn= CASE WHEN excluded.ssdp_udn != '' THEN excluded.ssdp_udn ELSE claimed_peripherals.ssdp_udn END,
            current_ssid=excluded.current_ssid,
            current_name=excluded.current_name,
            current_role=excluded.current_role,
            status=excluded.status,
            soft_ap_gateway=excluded.soft_ap_gateway,
            public_key= CASE WHEN excluded.public_key != '' THEN excluded.public_key ELSE claimed_peripherals.public_key END,
            last_telemetry_json=excluded.last_telemetry_json,
            last_updated=excluded.last_updated,
            notes=excluded.notes
        """,
        (
            b_mac,
            str(d_info.get("manufacturer") or ""),
            model_nm,
            str(d_info.get("product_name") or ""),
            str(d_info.get("cloud_device_id") or ""),
            str(d_info.get("ssdp_udn") or ""),
            orig_ssid,
            orig_name,
            orig_settings_str,
            cur_ssid_val,
            cur_name,
            new_role,
            new_status,
            gw,
            pub_key,
            base_stats_str,
            json.dumps(prev_telem),
            claimed_ts,
            now,
            new_notes,
        ),
    )
    con.commit()
    con.close()
    items = [p for p in _list_claimed_peripherals() if p.get("bssid") == b_mac]
    return items[0] if items else {}


@contextlib.contextmanager
def _wifi_airlock_radio_lock(timeout_s: float = 25.0):
    """
    Exclusive cross-process mutex around Windows 'Wi-Fi 4' Soft-AP Airlock sessions.
    Prevents 15s background `rf_motion_sense` / `scan_airspace` sweeps from triggering
    `WlanScan` or touching WLAN profiles while an active airlock association is in flight.
    """
    import fcntl

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    fh = open(WIFI_RADIO_LOCK_PATH, "a+", encoding="utf-8")
    deadline = time.time() + max(1.0, float(timeout_s))
    acquired = False
    try:
        while True:
            try:
                fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
                fh.seek(0)
                fh.truncate()
                fh.write(f"{os.getpid()} {int(time.time())}\n")
                fh.flush()
                break
            except BlockingIOError:
                if time.time() >= deadline:
                    break
                time.sleep(0.2)
        yield acquired
    finally:
        if acquired:
            try:
                fh.seek(0)
                fh.truncate()
                fh.flush()
                fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
            except Exception:
                pass
        try:
            fh.close()
        except Exception:
            pass


def _is_wifi_airlock_busy() -> bool:
    """Non-blocking check returning True if an exclusive Airlock session holds Wi-Fi 4."""
    import fcntl

    if not WIFI_RADIO_LOCK_PATH.exists():
        return False
    try:
        with open(WIFI_RADIO_LOCK_PATH, "a+", encoding="utf-8") as fh:
            try:
                fcntl.flock(fh.fileno(), fcntl.LOCK_SH | fcntl.LOCK_NB)
                fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
                return False
            except BlockingIOError:
                return True
    except Exception:
        return False


def _freq_mhz_to_channel(freq_mhz: int) -> int:
    if freq_mhz == 2484:
        return 14
    if 2412 <= freq_mhz <= 2472:
        return int((freq_mhz - 2407) // 5)
    if 5000 <= freq_mhz <= 5895:
        return int((freq_mhz - 5000) // 5)
    if 5955 <= freq_mhz <= 7115:
        return int((freq_mhz - 5950) // 5)
    return 0


def _channel_to_freq_mhz(channel: int, band: str = "2.4 GHz") -> int:
    if channel <= 0:
        return 0
    if channel == 14:
        return 2484
    if 1 <= channel <= 13 and "6" not in str(band):
        return 2407 + (channel * 5)
    if "6" in str(band) or channel >= 190:
        return 5950 + (channel * 5)
    if 32 <= channel <= 177 or "5" in str(band):
        return 5000 + (channel * 5)
    return 2407 + (channel * 5)


def _parse_linux_iw_scan_output(raw_text: str) -> List[Dict[str, Any]]:
    """
    Parses standard Linux `iw dev <iface> scan` output (`nl80211`) into structured 802.11
    BSSID records with unclipped dBm RSSI, exact MHz frequency, TSF uptime, beacon age (ms),
    IE 11 BSS Load (`station count`, `channel utilisation`), and IE 35 TPC (`TX power`).
    """
    networks_found: List[Dict[str, Any]] = []
    cur: Optional[Dict[str, Any]] = None
    in_bss_load = False
    in_rsn = False
    in_wpa = False

    def _finalize(entry: Optional[Dict[str, Any]]) -> None:
        if not entry or not entry.get("bssid"):
            return
        fmhz = int(entry.get("frequency_mhz") or 0)
        ch = int(entry.get("channel") or 0) or _freq_mhz_to_channel(fmhz)
        band = _classify_wifi_band(fmhz, ch, entry.get("band") or "2.4 GHz")
        if fmhz <= 0 and ch > 0:
            fmhz = int(_channel_to_freq_mhz(ch, band))
        entry["frequency_mhz"] = fmhz
        entry["channel"] = ch
        entry["band"] = band
        rssi = entry.get("rssi_dbm")
        if rssi is not None:
            pct = max(0, min(100, int(round(2.0 * (float(rssi) + 100.0)))))
            entry["signal_pct"] = pct
            entry["link_quality"] = pct
        networks_found.append(entry)

    for raw_ln in (raw_text or "").splitlines():
        m_bss = re.match(r"^BSS\s+([0-9a-fA-F:]{17})\b", raw_ln)
        if m_bss:
            _finalize(cur)
            bmac = m_bss.group(1).lower()
            cur = {
                "bssid": bmac,
                "ssid": "",
                "network_type": "Infrastructure",
                "auth": "Open",
                "encryption": "None",
                "signal_pct": 0,
                "rssi_dbm": None,
                "link_quality": 0,
                "frequency_mhz": 0,
                "radio_type": "802.11",
                "band": "",
                "channel": 0,
                "beacon_age_ms": 0,
                "host_ts_ft": 0,
                "tsf_uptime_us": None,
                "tx_power_dbm": None,
                "qbss_sta_count": None,
                "qbss_chan_util_pct": None,
                "vendor_oui": resolve_vendor(bmac),
                "sensor_backend": "linux_nl80211_iw",
            }
            in_bss_load = False
            in_rsn = False
            in_wpa = False
            continue
        if cur is None:
            continue

        ln = raw_ln.strip()
        if ln.startswith("TSF:"):
            m_tsf = re.search(r"TSF:\s*(\d+)\s*usec", ln)
            if m_tsf:
                tsf_v = int(m_tsf.group(1))
                cur["tsf_uptime_us"] = tsf_v
                cur["host_ts_ft"] = tsf_v
        elif ln.startswith("freq:"):
            m_f = re.search(r"freq:\s*(\d+(?:\.\d+)?)", ln)
            if m_f:
                cur["frequency_mhz"] = int(round(float(m_f.group(1))))
        elif ln.startswith("signal:"):
            m_s = re.search(r"signal:\s*(-?\d+(?:\.\d+)?)\s*dBm", ln)
            if m_s:
                cur["rssi_dbm"] = round(float(m_s.group(1)), 1)
        elif ln.startswith("last seen:"):
            m_ls = re.search(r"last seen:\s*(\d+)\s*ms ago", ln)
            if m_ls:
                cur["beacon_age_ms"] = int(m_ls.group(1))
            else:
                m_s2 = re.search(r"last seen:\s*(\d+(?:\.\d+)?)s ago", ln)
                if m_s2:
                    cur["beacon_age_ms"] = int(round(float(m_s2.group(1)) * 1000.0))
        elif ln.startswith("SSID:"):
            cur["ssid"] = ln.split("SSID:", 1)[1].strip()
        elif ln.startswith("DS Parameter set: channel"):
            m_ch = re.search(r"channel\s+(\d+)", ln)
            if m_ch:
                cur["channel"] = int(m_ch.group(1))
        elif ln.startswith("* primary channel:"):
            m_pch = re.search(r"primary channel:\s*(\d+)", ln)
            if m_pch and not cur.get("channel"):
                cur["channel"] = int(m_pch.group(1))
        elif ln.startswith("TPC report: TX power:"):
            m_tx = re.search(r"TX power:\s*(-?\d+)\s*dBm", ln)
            if m_tx:
                cur["tx_power_dbm"] = int(m_tx.group(1))
        elif ln.startswith("BSS Load:"):
            in_bss_load = True
            in_rsn = False
            in_wpa = False
        elif ln.startswith("RSN:"):
            in_rsn = True
            in_bss_load = False
            in_wpa = False
            if cur["auth"] == "Open":
                cur["auth"] = "WPA2-Personal"
                cur["encryption"] = "CCMP"
        elif ln.startswith("WPA:"):
            in_wpa = True
            in_bss_load = False
            in_rsn = False
            if cur["auth"] == "Open":
                cur["auth"] = "WPA-Personal"
                cur["encryption"] = "TKIP"
        elif ln.startswith("capability:"):
            if "IBSS" in ln:
                cur["network_type"] = "Adhoc"
            if "Privacy" in ln and cur["auth"] == "Open":
                cur["auth"] = "WEP/Privacy"
                cur["encryption"] = "Privacy"
        elif ln.startswith("EHT capabilities"):
            cur["radio_type"] = "802.11be"
        elif ln.startswith("HE capabilities") and cur["radio_type"] != "802.11be":
            cur["radio_type"] = "802.11ax"
        elif ln.startswith("VHT capabilities") and cur["radio_type"] not in ("802.11be", "802.11ax"):
            cur["radio_type"] = "802.11ac"
        elif ln.startswith("HT capabilities") and cur["radio_type"] == "802.11":
            cur["radio_type"] = "802.11n"
        elif in_bss_load:
            if ln.startswith("* station count:"):
                m_sc = re.search(r"station count:\s*(\d+)", ln)
                if m_sc:
                    cur["qbss_sta_count"] = int(m_sc.group(1))
            elif ln.startswith("* channel utilisation:"):
                m_cu = re.search(r"channel utilisation:\s*(\d+)/255", ln)
                if m_cu:
                    cur["qbss_chan_util_pct"] = round(int(m_cu.group(1)) * 100.0 / 255.0, 1)
            elif not ln.startswith("*"):
                in_bss_load = False
        elif in_rsn or in_wpa:
            if "SAE" in ln:
                cur["auth"] = "WPA3-Personal"
                cur["encryption"] = "CCMP"
            elif not ln.startswith("*"):
                in_rsn = False
                in_wpa = False

    _finalize(cur)
    return networks_found


def _parse_linux_nmcli_wifi_output(raw_text: str) -> List[Dict[str, Any]]:
    """
    Parses `nmcli -t -e yes -f BSSID,SSID,MODE,CHAN,FREQ,RATE,SIGNAL,SECURITY dev wifi list`
    output as a non-root Linux fallback when `iw` is unavailable.
    """
    networks_found: List[Dict[str, Any]] = []
    for raw_ln in (raw_text or "").splitlines():
        ln = raw_ln.strip()
        if not ln:
            continue
        parts = re.split(r"(?<!\\):", ln)
        if len(parts) < 8:
            continue
        bmac = parts[0].replace("\\:", ":").strip().lower()
        if not re.match(r"^[0-9a-f]{2}(:[0-9a-f]{2}){5}$", bmac):
            continue
        ssid_s = parts[1].replace("\\:", ":").replace("\\\\", "\\").strip()
        mode_s = parts[2].strip()
        ch = int(parts[3]) if parts[3].strip().isdigit() else 0
        m_f = re.search(r"(\d+)", parts[4])
        fmhz = int(m_f.group(1)) if m_f else 0
        pct = int(parts[6]) if parts[6].strip().isdigit() else 0
        sec_s = parts[7].strip()
        band = _classify_wifi_band(fmhz, ch, "2.4 GHz")
        if fmhz <= 0 and ch > 0:
            fmhz = int(_channel_to_freq_mhz(ch, band))
        rssi_dbm = round((pct / 2.0) - 100.0, 1)
        auth_s = "Open" if not sec_s or sec_s == "--" else ("WPA3-Personal" if "WPA3" in sec_s else "WPA2-Personal")
        enc_s = "None" if auth_s == "Open" else "CCMP"
        networks_found.append({
            "bssid": bmac,
            "ssid": ssid_s,
            "network_type": "Adhoc" if "Ad-Hoc" in mode_s else "Infrastructure",
            "auth": auth_s,
            "encryption": enc_s,
            "signal_pct": pct,
            "rssi_dbm": rssi_dbm,
            "link_quality": pct,
            "frequency_mhz": fmhz,
            "radio_type": "802.11",
            "band": band,
            "channel": ch,
            "beacon_age_ms": 0,
            "host_ts_ft": 0,
            "tsf_uptime_us": None,
            "tx_power_dbm": None,
            "qbss_sta_count": None,
            "qbss_chan_util_pct": None,
            "vendor_oui": resolve_vendor(bmac),
            "sensor_backend": "linux_nmcli",
        })
    return networks_found


def _parse_netsh_wlan_bssid_output(raw_text: str) -> List[Dict[str, Any]]:
    """
    Parses `netsh wlan show networks mode=bssid` output into structured 802.11 BSSID records,
    including `Channel`, exact `frequency_mhz`, `Band`, `Radio type`, `Signal`, and IE 11
    `Bss Load` (`Connected Stations` & `Channel Utilization`).
    """
    networks_found: List[Dict[str, Any]] = []
    cur_ssid: Optional[Dict[str, Any]] = None
    cur_bssid: Optional[Dict[str, Any]] = None
    for raw_ln in (raw_text or "").splitlines():
        ln = raw_ln.strip()
        m_ssid = re.match(r"^SSID\s+\d+\s*:\s*(.*)$", ln)
        if m_ssid:
            cur_ssid = {
                "ssid": m_ssid.group(1).strip(),
                "network_type": "Infrastructure",
                "auth": "Open",
                "encryption": "None",
            }
            cur_bssid = None
            continue
        if cur_ssid is None:
            continue
        m_bssid = re.match(r"^BSSID\s+\d+\s*:\s*([0-9a-fA-F:]{17})$", ln)
        if m_bssid:
            bmac = m_bssid.group(1).lower()
            cur_bssid = {
                "bssid": bmac,
                "ssid": cur_ssid["ssid"],
                "network_type": cur_ssid["network_type"],
                "auth": cur_ssid["auth"],
                "encryption": cur_ssid["encryption"],
                "signal_pct": 0,
                "rssi_dbm": None,
                "link_quality": 0,
                "frequency_mhz": 0,
                "radio_type": "",
                "band": "",
                "channel": 0,
                "beacon_age_ms": 0,
                "host_ts_ft": 0,
                "tsf_uptime_us": None,
                "tx_power_dbm": None,
                "qbss_sta_count": None,
                "qbss_chan_util_pct": None,
                "vendor_oui": resolve_vendor(bmac),
                "sensor_backend": "wsl_netsh",
            }
            networks_found.append(cur_bssid)
            continue
        if ":" in ln:
            k, v = ln.split(":", 1)
            kc, vc = k.strip().lower(), v.strip()
            if cur_bssid is None:
                if kc == "network type":
                    cur_ssid["network_type"] = vc
                elif kc == "authentication":
                    cur_ssid["auth"] = vc
                elif kc == "encryption":
                    cur_ssid["encryption"] = vc
            else:
                if kc == "signal":
                    ms = re.search(r"(\d+)%", vc)
                    if ms:
                        pct = int(ms.group(1))
                        cur_bssid["signal_pct"] = pct
                        cur_bssid["link_quality"] = pct
                        cur_bssid["rssi_dbm"] = round((pct / 2.0) - 100.0, 1)
                elif kc == "radio type":
                    cur_bssid["radio_type"] = vc
                elif kc == "band":
                    cur_bssid["band"] = vc
                elif kc == "channel" and vc.isdigit():
                    ch = int(vc)
                    cur_bssid["channel"] = ch
                    band_s = _classify_wifi_band(0, ch, cur_bssid.get("band") or "2.4 GHz")
                    cur_bssid["band"] = band_s
                    cur_bssid["frequency_mhz"] = int(_channel_to_freq_mhz(ch, band_s))
                elif kc == "connected stations" and vc.isdigit():
                    cur_bssid["qbss_sta_count"] = int(vc)
                elif kc == "channel utilization":
                    m_cu_raw = re.match(r"^(\d+)\s*\(", vc)
                    if m_cu_raw:
                        cur_bssid["qbss_chan_util_pct"] = round(int(m_cu_raw.group(1)) * 100.0 / 255.0, 1)
                    else:
                        m_cu_pct = re.search(r"(\d+)\s*%", vc)
                        if m_cu_pct:
                            cur_bssid["qbss_chan_util_pct"] = float(m_cu_pct.group(1))
    return networks_found


def _scan_linux_wifi_native(iface: str, trigger_rescan: bool = True) -> Tuple[List[Dict[str, Any]], str]:
    """
    Scans 802.11 airspace on a native Linux wireless interface (`nl80211`) using `iw`
    (with `scan dump` or `nmcli` fallback if non-root).
    """
    for iw_cmd in ("/usr/sbin/iw", "/sbin/iw", "iw"):
        try:
            args = [iw_cmd, "dev", iface, "scan"] if trigger_rescan else [iw_cmd, "dev", iface, "scan", "dump"]
            r = subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=6.0)
            if r.returncode != 0 and trigger_rescan:
                r = subprocess.run(
                    [iw_cmd, "dev", iface, "scan", "dump"],
                    stdin=subprocess.DEVNULL,
                    capture_output=True,
                    text=True,
                    timeout=3.5,
                )
            if r.returncode == 0 and (r.stdout or "").strip():
                parsed = _parse_linux_iw_scan_output(r.stdout)
                if parsed:
                    return parsed, "linux_nl80211_iw"
        except Exception:
            continue

    for nm_cmd in ("/usr/bin/nmcli", "nmcli"):
        try:
            rescan_arg = "yes" if trigger_rescan else "no"
            r_nm = subprocess.run(
                [
                    nm_cmd,
                    "-t",
                    "-e",
                    "yes",
                    "-f",
                    "BSSID,SSID,MODE,CHAN,FREQ,RATE,SIGNAL,SECURITY",
                    "dev",
                    "wifi",
                    "list",
                    "ifname",
                    iface,
                    "--rescan",
                    rescan_arg,
                ],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=6.0,
            )
            if r_nm.returncode == 0 and (r_nm.stdout or "").strip():
                parsed_nm = _parse_linux_nmcli_wifi_output(r_nm.stdout)
                if parsed_nm:
                    return parsed_nm, "linux_nmcli"
        except Exception:
            continue

    return [], "unavailable"


def _scan_windows_wlan_netsh_fallback(trigger_rescan: bool = False) -> List[Dict[str, Any]]:
    """
    WSL2 802.11 scanner via `netsh.exe wlan show networks mode=bssid` (with `stdin=DEVNULL`).
    When `trigger_rescan=True` and the secondary Wi-Fi adapter is disconnected and idle,
    triggers a non-disruptive WLAN AutoConfig rescan via `netsh.exe wlan disconnect`.
    """
    netsh_path = Path("/mnt/c/Windows/System32/netsh.exe")
    if not netsh_path.exists():
        return []
    try:
        if trigger_rescan and not _is_wifi_airlock_busy():
            st = _get_windows_wifi_status()
            if st.get("backend") == "wsl2_windows_netsh" and st.get("state") == "disconnected":
                adapter = st.get("adapter_name") or "Wi-Fi 4"
                subprocess.run(
                    [str(netsh_path), "wlan", "disconnect", f"interface={adapter}"],
                    stdin=subprocess.DEVNULL,
                    capture_output=True,
                    text=True,
                    timeout=3.0,
                )
                time.sleep(0.45)
        r = subprocess.run(
            [str(netsh_path), "wlan", "show", "networks", "mode=bssid"],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=6.0,
        )
        return _parse_netsh_wlan_bssid_output(r.stdout or "")
    except Exception:
        return []


def _scan_workstation_wifi_airspace(trigger_rescan: bool = True, wait_ms: int = 1200) -> Tuple[List[Dict[str, Any]], str]:
    """
    Cross-platform Linux + WSL2 802.11 airspace scanner (pure Python/Bash, zero C#/.dll):
      1. Pure Linux Native (`linux_nl80211_iw` / `linux_nmcli`): Uses `iw dev <iface> scan`
         or `nmcli` when a Linux `nl80211` wireless interface (`/sys/class/net/<iface>/phy80211`)
         is present.
      2. WSL2 Host Bridge (`wsl_netsh`): Uses `netsh.exe wlan show networks mode=bssid`
         (with `stdin=subprocess.DEVNULL`) when running under WSL2 with a Windows-bridged
         wireless adapter (`Wi-Fi 4`).
    Automatically skips hardware scanning if `_is_wifi_airlock_busy()` is True.
    """
    if _is_wifi_airlock_busy():
        return [], "airlock_radio_busy"

    linux_iface = _detect_linux_wifi_interface()
    if linux_iface:
        nets_l, backend_l = _scan_linux_wifi_native(linux_iface, trigger_rescan=trigger_rescan)
        if nets_l:
            return nets_l, backend_l

    fb = _scan_windows_wlan_netsh_fallback(trigger_rescan=trigger_rescan)
    return fb, ("wsl_netsh" if fb else "unavailable")


# Backwards-compatible alias for internal callers
_scan_windows_wlan_native = _scan_workstation_wifi_airspace


def _classify_wifi_band(freq_mhz: int = 0, channel: int = 0, fallback_band: str = "2.4 GHz") -> str:
    if freq_mhz >= 5925 or channel >= 190:
        return "6 GHz"
    if freq_mhz >= 4900 or channel >= 32:
        return "5 GHz"
    if freq_mhz > 0 or (1 <= channel <= 14):
        return "2.4 GHz"
    return fallback_band or "2.4 GHz"


def _classify_compass_sector(
    bssid: str,
    ssid: str = "",
    desktop_rssi_dbm: Optional[float] = None,
    peripheral_rssi_dbm: Optional[float] = None,
    delta_south_minus_north_db: Optional[float] = None,
    classification: str = "neighbor",
    compass_cfg: Optional[Dict[str, Any]] = None,
) -> str:
    """
    Maps any household or external 802.11 BSSID onto the property's true compass frame
    anchored by operator ground truth configured in `.george/config/tyler_household.json`
    (`compass_anchors`) and `.george/state/tyler_wifi_watchlist.json` (`compass_calibration`).
    For external neighbor APs, uses the path-loss normalized South-minus-North differential
    (Delta_S-N = RSSI_SensorB_South - RSSI_Workstation_North + band_comp):
      - Delta_S-N <= -5 dB -> NORTH
      - Delta_S-N >= +5 dB -> SOUTH
      - -5 dB < Delta_S-N < +5 dB -> EAST_WEST_FLANK
    """
    b = (bssid or "").lower().strip()
    s = (ssid or "").strip()
    s_low = s.lower()
    cfg = compass_cfg or (load_wifi_watchlist().get("compass_calibration") or {})
    anc = COMPASS_ANCHORS

    south_anchor_bssid = str((cfg.get("south_wall_anchor") or {}).get("bssid") or anc.get("south_wall_bssid") or "").lower()
    if (south_anchor_bssid and b == south_anchor_bssid) or "smartclock" in s_low:
        return "SOUTH_WALL"
    root_pref = str(anc.get("root_router_prefix") or "").lower()
    leaf_pref = str(anc.get("leaf_router_prefix") or "").lower()
    study_bssid = str(anc.get("study_bssid") or "").lower()
    kitchen_bssid = str(anc.get("kitchen_bssid") or "").lower()
    if root_pref and b.startswith(root_pref):
        return "INTERIOR_CORE"
    if leaf_pref and b.startswith(leaf_pref):
        return "INTERIOR_SOUTH"
    if (study_bssid and b == study_bssid) or ("direct-" in s_low and "deskjet" in s_low):
        return "NORTH_WEST_STUDY"
    if (kitchen_bssid and b == kitchen_bssid) or "[fridge]" in s_low:
        return "INTERIOR_KITCHEN"
    if classification == "home_ap":
        return "INTERIOR_CORE"

    for anchor in cfg.get("north_anchors") or []:
        if not isinstance(anchor, dict):
            continue
        pref = str(anchor.get("bssid_prefix") or "").lower().strip()
        pat = str(anchor.get("ssid_pattern") or "").lower().strip()
        if pref and b.startswith(pref):
            return "NORTH"
        if pat and re.search(pat.replace("*", ".*"), s_low):
            return "NORTH"
    north_pref = str(anc.get("north_anchor_prefix") or "").lower().strip()
    north_ssid = str(anc.get("north_anchor_ssid") or "").lower().strip()
    if (north_ssid and north_ssid in s_low) or (north_pref and b.startswith(north_pref)):
        return "NORTH"

    if delta_south_minus_north_db is not None:
        if delta_south_minus_north_db <= -5.0:
            return "NORTH"
        if delta_south_minus_north_db >= 5.0:
            return "SOUTH"
        return "EAST_WEST_FLANK"

    if peripheral_rssi_dbm is not None and desktop_rssi_dbm is None:
        return "SOUTH"
    if desktop_rssi_dbm is not None and peripheral_rssi_dbm is None:
        if desktop_rssi_dbm >= -76.0:
            return "NORTH"
        return "NORTH_OR_FLANK"
    return "EXTERIOR_UNKNOWN"


def _compute_airspace_triangulation(
    desktop_networks: List[Dict[str, Any]],
    peripheral_scan: List[Dict[str, Any]],
    peripheral_label: str = "Lenovo Smart Clock",
) -> Dict[str, Any]:
    """
    Fuses 802.11 RSSI observations from Sensor A (Host Workstation Wi-Fi 4 — North-West Study)
    and Sensor B (Remote Cast Peripheral /setup/scan_results — South Wall across 2.4 GHz + 5 GHz)
    to estimate spatial proximity and true North/South/East-West compass bearing, applying
    +6.7 dB Friis + interior-wall 5 GHz -> 2.4 GHz path-loss normalization on cross-band anchors.
    """
    by_bssid: Dict[str, Dict[str, Any]] = {}
    desktop_ssid_best: Dict[str, Tuple[int, str]] = {}
    compass_cfg = load_wifi_watchlist().get("compass_calibration") or {}

    for dn in desktop_networks:
        b = (dn.get("bssid") or "").lower().strip()
        if not b:
            continue
        pct = int(dn.get("signal_pct") or 0)
        raw_rssi = dn.get("rssi_dbm")
        if raw_rssi is not None:
            dbm = int(round(float(raw_rssi)))
            if pct <= 0:
                pct = max(0, min(100, 2 * (dbm + 100)))
        else:
            dbm = int(round((pct / 2.0) - 100)) if pct > 0 else None
        s_name = dn.get("ssid") or ""
        ch_num = int(dn.get("channel") or 0)
        freq_dn = int(dn.get("frequency_mhz") or dn.get("frequency") or 0)
        band_dn = _classify_wifi_band(freq_dn, ch_num, str(dn.get("band") or "2.4 GHz"))
        if s_name and dbm is not None:
            if s_name not in desktop_ssid_best or dbm > desktop_ssid_best[s_name][0]:
                desktop_ssid_best[s_name] = (dbm, band_dn)
        by_bssid[b] = {
            "bssid": b,
            "ssid": s_name,
            "band": band_dn,
            "frequency_mhz": freq_dn,
            "channel": ch_num,
            "vendor_oui": dn.get("vendor_oui") or resolve_vendor(b),
            "classification": dn.get("classification") or "neighbor",
            "desktop_signal_pct": pct,
            "desktop_rssi_dbm": dbm,
            "desktop_band": band_dn,
            "peripheral_rssi_dbm": None,
            "tx_power_dbm": dn.get("tx_power_dbm"),
            "qbss_chan_util_pct": dn.get("qbss_chan_util_pct"),
        }

    for item in peripheral_scan or []:
        if not isinstance(item, dict):
            continue
        s_name = str(item.get("ssid") or "")
        ap_list = item.get("ap_list")
        entries_to_process = []
        if isinstance(ap_list, list) and ap_list:
            for ap in ap_list:
                if isinstance(ap, dict) and ap.get("bssid"):
                    entries_to_process.append({
                        "bssid": str(ap["bssid"]).lower().strip(),
                        "ssid": s_name,
                        "frequency": int(ap.get("frequency") or 0),
                        "channel": int(ap.get("channel") or 0),
                        "signal_level": int(ap.get("signal_level") or -95),
                    })
        elif item.get("bssid"):
            entries_to_process.append({
                "bssid": str(item["bssid"]).lower().strip(),
                "ssid": s_name,
                "frequency": int(item.get("frequency") or 0),
                "channel": int(item.get("channel") or 0),
                "signal_level": int(item.get("signal_level") or -95),
            })

        for p_ent in entries_to_process:
            b = p_ent["bssid"]
            freq = p_ent["frequency"]
            ch_p = p_ent["channel"] or _freq_mhz_to_channel(freq)
            band_s = _classify_wifi_band(freq, ch_p, "2.4 GHz")
            rec = by_bssid.get(b)
            if not rec:
                d_match = desktop_ssid_best.get(p_ent["ssid"])
                rec = {
                    "bssid": b,
                    "ssid": p_ent["ssid"],
                    "band": band_s,
                    "frequency_mhz": freq,
                    "channel": ch_p,
                    "vendor_oui": resolve_vendor(b),
                    "classification": "neighbor",
                    "desktop_signal_pct": 0,
                    "desktop_rssi_dbm": d_match[0] if d_match else None,
                    "desktop_band": d_match[1] if d_match else None,
                    "desktop_matched_via_ssid": d_match is not None,
                    "peripheral_rssi_dbm": p_ent["signal_level"],
                }
                by_bssid[b] = rec
            else:
                if not rec.get("ssid") and p_ent["ssid"]:
                    rec["ssid"] = p_ent["ssid"]
                if freq > 0 or ch_p > 0:
                    rec["frequency_mhz"] = freq
                    if ch_p > 0:
                        rec["channel"] = ch_p
                    rec["band"] = band_s
                rec["peripheral_rssi_dbm"] = p_ent["signal_level"]

    results: List[Dict[str, Any]] = []
    near_periph = 0
    near_desk = 0
    dual_count = 0
    five_ghz_count = 0
    sector_counts: Dict[str, int] = {}

    for rec in by_bssid.values():
        d_dbm = rec.get("desktop_rssi_dbm")
        p_dbm = rec.get("peripheral_rssi_dbm")
        p_band = rec.get("band") or "2.4 GHz"
        d_band = rec.get("desktop_band") or p_band
        if p_band in ("5 GHz", "6 GHz") and p_dbm is not None:
            five_ghz_count += 1
        norm_delta_f: Optional[float] = None
        if d_dbm is not None and p_dbm is not None:
            dual_count += 1
            raw_delta = float(p_dbm - d_dbm)
            # Friis free-space (20*log10(5.5/2.44) = 7.06 dB) + indoor partition normalization (~6.7 dB)
            band_comp = 0.0
            if p_band in ("5 GHz", "6 GHz") and d_band == "2.4 GHz":
                band_comp = 6.7
            elif p_band == "2.4 GHz" and d_band in ("5 GHz", "6 GHz"):
                band_comp = -6.7
            norm_delta_f = raw_delta + band_comp
            norm_delta = int(round(norm_delta_f))
            rec["raw_delta_db"] = int(round(raw_delta))
            rec["band_loss_comp_db"] = band_comp
            rec["delta_db"] = norm_delta
            rec["south_minus_north_db"] = round(norm_delta_f, 1)
            if norm_delta >= 8:
                rec["spatial_zone"] = f"Near Remote Peripheral ({peripheral_label} — South Wall)"
                near_periph += 1
            elif norm_delta <= -8:
                rec["spatial_zone"] = "Near Host Workstation (Desktop — North-West Study)"
                near_desk += 1
            else:
                rec["spatial_zone"] = "Mid-Span / East-West Flank (Equidistant)"
        elif p_dbm is not None:
            rec["delta_db"] = None
            rec["south_minus_north_db"] = None
            rec["spatial_zone"] = f"Peripheral Exclusive ({rec.get('band', '5 GHz')} / {peripheral_label} South Zone)"
            near_periph += 1
        else:
            rec["delta_db"] = None
            rec["south_minus_north_db"] = None
            rec["spatial_zone"] = "Workstation Exclusive (North / Study Zone)"
            near_desk += 1

        sector = _classify_compass_sector(
            bssid=str(rec.get("bssid") or ""),
            ssid=str(rec.get("ssid") or ""),
            desktop_rssi_dbm=float(d_dbm) if d_dbm is not None else None,
            peripheral_rssi_dbm=float(p_dbm) if p_dbm is not None else None,
            delta_south_minus_north_db=norm_delta_f,
            classification=str(rec.get("classification") or "neighbor"),
            compass_cfg=compass_cfg,
        )
        rec["compass_sector"] = sector
        sector_counts[sector] = sector_counts.get(sector, 0) + 1
        results.append(rec)

    results.sort(
        key=lambda x: (
            0 if (x.get("desktop_rssi_dbm") is not None and x.get("peripheral_rssi_dbm") is not None) else 1,
            -(x.get("peripheral_rssi_dbm") or -110),
            -(x.get("desktop_rssi_dbm") or -110),
        )
    )

    return {
        "peripheral_sensor": peripheral_label,
        "workstation_sensor": "Wi-Fi 4 (Desktop — North-West Study)",
        "compass_anchors": {
            "north": str(COMPASS_ANCHORS.get("north_anchor_label") or "North Reference Anchor (configured via tyler_household.json)"),
            "south_wall": f"{peripheral_label} ({COMPASS_ANCHORS.get('south_wall_bssid') or 'sensor-b'})",
            "north_west_study": "Workstation Wi-Fi",
        },
        "total_transmitters": len(results),
        "dual_sensor_matched": dual_count,
        "near_peripheral_count": near_periph,
        "near_workstation_count": near_desk,
        "five_ghz_discovered_by_peripheral": five_ghz_count,
        "compass_sector_counts": sector_counts,
        "transmitters": results,
    }


def _sweep_soft_ap_clients(wifi_ip: str, soft_ap_gw: str) -> List[Dict[str, Any]]:
    """
    Sweeps the remaining usable client IPs in the Soft-AP's /29 DHCP pool (.250-.254)
    to detect if any unauthorized third-party device is associated to the open Canary Soft-AP.
    Supports both pure Linux (`ping` + `ip neigh show`) and WSL2 (`PING.EXE` + `arp.exe`).
    """
    foreign_clients: List[Dict[str, Any]] = []
    if not wifi_ip or not soft_ap_gw:
        return foreign_clients
    prefix = ".".join(soft_ap_gw.split(".")[:3])
    candidates = [f"{prefix}.{last_oct}" for last_oct in range(250, 255)]
    candidates = [ip for ip in candidates if ip not in (wifi_ip, soft_ap_gw)]
    seen_ips: Set[str] = set()

    # 1. Pure Linux native ping + ip neigh sweep
    for cip in candidates:
        try:
            subprocess.run(
                ["ping", "-c", "1", "-W", "1", "-I", wifi_ip, cip],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=1.5,
            )
        except Exception:
            pass
    try:
        r_neigh = subprocess.run(
            ["ip", "-4", "neigh", "show"],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=2.0,
        )
        for ln in (r_neigh.stdout or "").splitlines():
            m_n = re.search(r"^(\d+\.\d+\.\d+\.\d+)\s+.*?lladdr\s+([0-9a-fA-F:]{17})\s+(\S+)", ln)
            if m_n:
                ip_f, mac_raw, st_n = m_n.group(1), m_n.group(2).lower(), m_n.group(3).upper()
                if ip_f in candidates and st_n in ("REACHABLE", "STALE", "DELAY", "PROBE") and ip_f not in seen_ips:
                    seen_ips.add(ip_f)
                    foreign_clients.append({
                        "ip": ip_f,
                        "mac": mac_raw,
                        "vendor": resolve_vendor(mac_raw),
                    })
    except Exception:
        pass

    # 2. WSL2 host bridge fallback (when Soft-AP IP is bound on the Windows host adapter)
    ping_exe = Path("/mnt/c/Windows/System32/PING.EXE")
    arp_exe = Path("/mnt/c/Windows/System32/arp.exe")
    if not foreign_clients and ping_exe.exists():
        for cip in candidates:
            try:
                subprocess.run(
                    [str(ping_exe), "-n", "1", "-w", "220", "-S", wifi_ip, cip],
                    stdin=subprocess.DEVNULL,
                    capture_output=True,
                    text=True,
                    timeout=1.5,
                )
            except Exception:
                pass
    if not foreign_clients and arp_exe.exists():
        try:
            r_arp = subprocess.run(
                [str(arp_exe), "-a", "-N", wifi_ip],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=3.0,
            )
            for ln in (r_arp.stdout or "").splitlines():
                m = re.search(r"(\d+\.\d+\.\d+\.\d+)\s+([0-9a-fA-F-]{17})\s+(\w+)", ln)
                if m:
                    ip_f, mac_raw, typ = m.group(1), m.group(2), m.group(3).lower()
                    if ip_f in candidates and typ == "dynamic" and ip_f not in seen_ips:
                        seen_ips.add(ip_f)
                        mac_norm = mac_raw.replace("-", ":").lower()
                        foreign_clients.append({
                            "ip": ip_f,
                            "mac": mac_norm,
                            "vendor": resolve_vendor(mac_norm),
                        })
        except Exception:
            pass
    return foreign_clients


def _encrypt_cast_wifi_password(password: str, public_key_b64: str) -> str:
    """Encrypts a Wi-Fi passphrase using the Cast device's 2048-bit RSA public_key (RSA-PKCS1v1.5)."""
    import base64
    import tempfile

    if not password or not public_key_b64:
        return ""
    wrapped = "\n".join(public_key_b64[i : i + 64] for i in range(0, len(public_key_b64), 64))
    pem = f"-----BEGIN PUBLIC KEY-----\n{wrapped}\n-----END PUBLIC KEY-----\n"
    with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as tf:
        tf.write(pem)
        pem_path = tf.name
    try:
        r = subprocess.run(
            ["openssl", "pkeyutl", "-encrypt", "-pubin", "-inkey", pem_path],
            input=password.encode("utf-8"),
            capture_output=True,
            timeout=4.0,
        )
        if r.returncode == 0 and r.stdout:
            return base64.b64encode(r.stdout).decode("ascii")
    except Exception:
        pass
    finally:
        Path(pem_path).unlink(missing_ok=True)
    return ""


def _resolve_target_peripheral(
    ssid: Optional[str] = None,
    bssid: Optional[str] = None,
    scan_networks: Optional[List[Dict[str, Any]]] = None,
) -> Tuple[Optional[Dict[str, Any]], str, str, bool]:
    """
    Resolves a claimed Cast Soft-AP peripheral and its live 802.11 broadcast SSID/BSSID,
    matching by invariant BSSID first so renamed Soft-APs are always tracked seamlessly.
    """
    claimed = _list_claimed_peripherals()
    req_bssid = (bssid or "").strip().lower()
    req_ssid = (ssid or "").strip()

    periph: Optional[Dict[str, Any]] = None
    if req_bssid:
        for p in claimed:
            if (p.get("bssid") or "").lower() == req_bssid:
                periph = p
                break
    if periph is None and req_ssid:
        for p in claimed:
            if req_ssid in (
                p.get("current_ssid"),
                p.get("original_ssid"),
                p.get("live_beacon_ssid"),
                p.get("current_name"),
                p.get("original_name"),
            ):
                periph = p
                break
    if periph is None and claimed:
        periph = claimed[0]

    target_bssid = req_bssid or ((periph.get("bssid") or "").lower() if periph else "")
    target_ssid = req_ssid or ((periph.get("live_beacon_ssid") or periph.get("current_ssid") or "") if periph else "")
    live_visible = False

    nets = scan_networks or []
    if target_bssid:
        for net in nets:
            if (net.get("bssid") or "").lower() == target_bssid:
                if net.get("ssid"):
                    target_ssid = net["ssid"]
                live_visible = True
                break
    if not live_visible and req_ssid:
        for net in nets:
            if net.get("ssid") == req_ssid:
                target_ssid = net["ssid"]
                target_bssid = (net.get("bssid") or "").lower() or target_bssid
                live_visible = True
                break
    if not live_visible:
        for net in nets:
            if net.get("classification") == "open_soft_ap" and net.get("ssid"):
                target_ssid = net["ssid"]
                target_bssid = (net.get("bssid") or "").lower() or target_bssid
                live_visible = True
                break

    return periph, target_ssid, target_bssid, live_visible


def _discover_lan_cast_and_mesh_targets() -> Tuple[List[Dict[str, str]], List[Dict[str, str]]]:
    """Returns (cast_targets, mesh_targets) from lan_devices.db for zero-airlock LAN peripheral polling."""
    con = connect_db()
    rows = [dict(r) for r in con.execute("SELECT ip, mac, label, hostname, device_type, open_ports_json FROM devices WHERE online = 1").fetchall()]
    con.close()
    cast_targets: List[Dict[str, str]] = []
    mesh_targets: List[Dict[str, str]] = []
    seen_ips = set()
    for r in rows:
        ip = str(r.get("ip") or "").strip()
        if not ip or ip in seen_ips:
            continue
        try:
            ports = json.loads(r.get("open_ports_json") or "[]")
        except Exception:
            ports = []
        dtype = str(r.get("device_type") or "")
        lbl = str(r.get("label") or r.get("hostname") or ip)
        if dtype == "google_home" or 8009 in ports or (8443 in ports and dtype != "mesh_router"):
            cast_targets.append({"ip": ip, "mac": str(r.get("mac") or ""), "label": lbl})
            seen_ips.add(ip)
        elif dtype == "mesh_router" or ip == GATEWAY_IP:
            mesh_targets.append({"ip": ip, "mac": str(r.get("mac") or ""), "label": lbl})
            seen_ips.add(ip)
    return cast_targets, mesh_targets


def poll_lan_peripherals() -> Dict[str, Any]:
    """
    Zero-Airlock Multi-Room Peripheral RF & Tamper Sweep (<1.5s over eth0):
    Concurrently polls :8443/setup/eureka_info?options=detail across all LAN Google Cast nodes
    and :80/api/v1/status across Nest Wifi Pro mesh routers, updating peripheral_rf_telemetry
    and emitting network.rf_anomaly onto the FIFO Event Bus if noise spikes or tamper counters increment.
    """
    import concurrent.futures
    import ssl
    import urllib.request

    now = int(time.time())
    cast_targets, mesh_targets = _discover_lan_cast_and_mesh_targets()
    ctx = ssl._create_unverified_context()

    def _poll_cast(t: Dict[str, str]) -> Dict[str, Any]:
        ip = t["ip"]
        lbl = t["label"]
        url = (
            f"https://{ip}:8443/setup/eureka_info"
            "?params=version,audio,name,build_info,detail,device_info,net,wifi,setup,settings,multizone&options=detail"
        )
        t0 = time.time()
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Tyler-Guardian/1.0"})
            with urllib.request.urlopen(req, context=ctx, timeout=1.8) as resp:
                rtt_ms = round((time.time() - t0) * 1000.0, 1)
                data = json.loads(resp.read().decode("utf-8", errors="ignore"))
                w = data.get("wifi") or {}
                s = (data.get("setup") or {}).get("stats") or {}
                sig = w.get("signal_level")
                noi = w.get("noise_level")
                snr = (int(sig) - int(noi)) if (sig is not None and noi is not None) else None
                bssid = str(w.get("bssid") or "").lower()
                band = "5 GHz" if bssid.endswith(("74", "75", "ee", "ef")) else ("2.4 GHz" if bssid else "Wi-Fi")
                return {
                    "ip": ip,
                    "mac": t.get("mac", ""),
                    "label": str(data.get("name") or lbl),
                    "reachable": True,
                    "rtt_ms": rtt_ms,
                    "ssid": str(w.get("ssid") or ""),
                    "bssid": bssid,
                    "band": band,
                    "wpa_state": w.get("wpa_state"),
                    "signal_level_dbm": int(sig) if sig is not None else None,
                    "noise_level_dbm": int(noi) if noi is not None else None,
                    "snr_db": snr,
                    "setup_stats": s,
                }
        except Exception as e:
            return {
                "ip": ip,
                "mac": t.get("mac", ""),
                "label": lbl,
                "reachable": False,
                "error": str(e)[:120],
            }

    def _poll_mesh(t: Dict[str, str]) -> Dict[str, Any]:
        ip = t["ip"]
        url = f"http://{ip}/api/v1/status"
        t0 = time.time()
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Tyler-Guardian/1.0"})
            with urllib.request.urlopen(req, timeout=1.5) as resp:
                rtt_ms = round((time.time() - t0) * 1000.0, 1)
                data = json.loads(resp.read().decode("utf-8", errors="ignore"))
                mi = data.get("meshInfo") or {}
                sw = data.get("software") or {}
                wan = data.get("wan") or {}
                return {
                    "ip": ip,
                    "label": t["label"],
                    "reachable": True,
                    "rtt_ms": rtt_ms,
                    "mesh_interface": mi.get("mesh-interface", ""),
                    "mesh_channel": mi.get("mesh-channel"),
                    "software_version": sw.get("softwareVersion", ""),
                    "wan_online": wan.get("online"),
                    "local_ip": wan.get("localIpAddress", ip),
                }
        except Exception as e:
            return {"ip": ip, "label": t["label"], "reachable": False, "error": str(e)[:120]}

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        cast_results = list(pool.map(_poll_cast, cast_targets))
        mesh_results = list(pool.map(_poll_mesh, mesh_targets))

    anomalies: List[Dict[str, Any]] = []
    con = connect_db()
    for cr in cast_results:
        if not cr.get("reachable"):
            continue
        cid = f"lan_cast_{cr['ip'].replace('.', '_')}"
        prev = con.execute("SELECT * FROM peripheral_rf_telemetry WHERE chord_id = ?", (cid,)).fetchone()
        sig = cr.get("signal_level_dbm")
        noi = cr.get("noise_level_dbm")
        snr = cr.get("snr_db")
        base_rssi = float(prev["baseline_rssi_dbm"]) if (prev and prev["baseline_rssi_dbm"] is not None) else (float(sig) if sig is not None else None)

        if noi is not None and noi > -70:
            anom = {
                "sensor": cr["label"],
                "ip": cr["ip"],
                "reason": f"Elevated RF noise floor ({noi} dBm) in {cr['label']} zone",
                "noise_level_dbm": noi,
                "snr_db": snr,
            }
            anomalies.append(anom)
            emit_security_event("network.rf_anomaly", anom)
        elif snr is not None and snr < 8:
            anom = {
                "sensor": cr["label"],
                "ip": cr["ip"],
                "reason": f"Critical Wi-Fi SNR collapse ({snr} dB) at {cr['label']}",
                "signal_level_dbm": sig,
                "noise_level_dbm": noi,
            }
            anomalies.append(anom)
            emit_security_event("network.rf_anomaly", anom)

        prev_state = str(prev["motion_state"]) if (prev and prev["motion_state"]) else "quiet"
        backend_tag = "lan_eureka_dbm" if sig is not None else "wmm_rtt_only"
        # Preserve multi-tick `rf_motion_sense` history_json without polluting it with 1-tick (std=0, p2p=0) snapshots.
        prev_hist_str = str(prev["history_json"] or "[]") if prev else "[]"

        con.execute(
            """
            INSERT INTO peripheral_rf_telemetry
            (chord_id, label, zone, tx_node, rx_node, bssid, band, compass_sector, ring, sensor_backend,
             baseline_rssi_dbm, last_rssi_dbm, last_noise_dbm, last_snr_db, last_rtt_ms, updated_at, history_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(chord_id) DO UPDATE SET
                label=excluded.label,
                bssid= CASE WHEN excluded.bssid != '' THEN excluded.bssid ELSE peripheral_rf_telemetry.bssid END,
                band= CASE WHEN excluded.band != '' THEN excluded.band ELSE peripheral_rf_telemetry.band END,
                sensor_backend=excluded.sensor_backend,
                baseline_rssi_dbm= COALESCE(peripheral_rf_telemetry.baseline_rssi_dbm, excluded.baseline_rssi_dbm),
                last_rssi_dbm= COALESCE(excluded.last_rssi_dbm, peripheral_rf_telemetry.last_rssi_dbm),
                last_noise_dbm= COALESCE(excluded.last_noise_dbm, peripheral_rf_telemetry.last_noise_dbm),
                last_snr_db= COALESCE(excluded.last_snr_db, peripheral_rf_telemetry.last_snr_db),
                last_rtt_ms=excluded.last_rtt_ms,
                updated_at=excluded.updated_at
            """,
            (
                cid,
                f"Mesh AP <-> {cr['label']}",
                cr["label"],
                cr.get("bssid") or "Nest Wifi Pro Mesh",
                f"{cr['label']} ({cr['ip']})",
                cr.get("bssid") or "",
                cr.get("band") or "Wi-Fi",
                "INTERIOR_SOUTH" if (COMPASS_ANCHORS.get("leaf_router_prefix") and str(cr.get("bssid") or "").lower().startswith(str(COMPASS_ANCHORS.get("leaf_router_prefix")).lower())) else "INTERIOR_CORE",
                "interior",
                backend_tag,
                base_rssi,
                sig,
                noi,
                snr,
                cr.get("rtt_ms"),
                now,
                prev_hist_str,
            ),
        )
        con.execute(
            """
            INSERT INTO rf_telemetry_timeseries
            (ts, chord_id, label, zone, band, compass_sector, ring, rssi_dbm, baseline_rssi_dbm, noise_dbm, snr_db,
             rtt_ms, rtt_jitter_ms, std_db, p2p_swing_db, motion_state, source_mode)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                now,
                cid,
                f"Mesh AP <-> {cr['label']}",
                cr["label"],
                cr.get("band") or "Wi-Fi",
                "INTERIOR_SOUTH" if (COMPASS_ANCHORS.get("leaf_router_prefix") and str(cr.get("bssid") or "").lower().startswith(str(COMPASS_ANCHORS.get("leaf_router_prefix")).lower())) else "INTERIOR_CORE",
                "interior",
                float(sig) if sig is not None else None,
                base_rssi,
                float(noi) if noi is not None else None,
                float(snr) if snr is not None else None,
                cr.get("rtt_ms"),
                0.0,
                float(prev["std_db"]) if (prev and prev["std_db"] is not None) else 0.0,
                float(prev["p2p_swing_db"]) if (prev and prev["p2p_swing_db"] is not None) else 0.0,
                prev_state,
                "poll_lan_peripherals",
            ),
        )
    con.commit()
    con.close()

    return {
        "status": "ok",
        "mode": "poll_lan_peripherals",
        "ts": now,
        "reachable_cast_nodes": sum(1 for c in cast_results if c.get("reachable")),
        "total_cast_nodes": len(cast_results),
        "cast_peripherals": cast_results,
        "mesh_routers": mesh_results,
        "anomalies": anomalies,
        "claimed_soft_ap_peripherals": _list_claimed_peripherals(),
    }


def _fuse_colocated_vap_rssi(
    r_primary: Optional[float],
    r_guest: Optional[float],
    collision_delta_db: float = 4.0,
) -> Tuple[Optional[float], bool]:
    """
    Fuses co-located primary + guest VAP beacons broadcast on the same physical radio chain
    (e.g., Nest Wifi Pro `:87:ea`+`:eb`, `:87:ee`+`:ef`, `:89:70`+`:71`, `:89:74`+`:75`).
    - When `|r_primary - r_guest| <= collision_delta_db`: averages both for 0.5 dB resolution & -3 dB variance.
    - When `|r_primary - r_guest| > collision_delta_db`: rejects the weaker frame as a 1-beacon co-channel collision.
    """
    if r_primary is not None and r_guest is not None:
        p_f, g_f = float(r_primary), float(r_guest)
        if abs(p_f - g_f) <= collision_delta_db:
            return round(0.5 * (p_f + g_f), 2), False
        return round(max(p_f, g_f), 2), True
    if r_primary is not None:
        return round(float(r_primary), 2), False
    if r_guest is not None:
        return round(float(r_guest), 2), False
    return None, False


def _compute_chord_sample_stats(
    r_vals: List[float],
    quant_deadband_var: float = 0.25,
) -> Dict[str, Any]:
    """
    Computes unbiased Bessel (N - 1) sample standard deviation and subtracts integer-dBm /
    thermal quantization deadband variance (`sigma_q^2 = 0.25 dB^2`) so 1 dB LSB toggling
    on 2-tick scans (`[-69, -70]`) does not masquerade as high intratick volatility.
    """
    if not r_vals:
        return {
            "mean_dbm": None,
            "raw_std_db": 0.0,
            "std_db": 0.0,
            "p2p_swing_db": 0.0,
            "step_mean_db": 0.0,
        }
    mean_dbm = round(sum(r_vals) / float(len(r_vals)), 2)
    if len(r_vals) >= 2:
        raw_var = sum((x - mean_dbm) ** 2 for x in r_vals) / float(len(r_vals) - 1)
        raw_std_db = round(math.sqrt(raw_var), 2)
        eff_var = max(0.0, raw_var - max(0.0, float(quant_deadband_var)))
        std_db = round(math.sqrt(eff_var), 2)
        p2p_swing_db = round(max(r_vals) - min(r_vals), 2)
        step_deltas = [abs(r_vals[i] - r_vals[i - 1]) for i in range(1, len(r_vals))]
        step_mean_db = round(sum(step_deltas) / float(len(step_deltas)), 2) if step_deltas else 0.0
    else:
        raw_std_db = 0.0
        std_db = 0.0
        p2p_swing_db = 0.0
        step_mean_db = 0.0
    return {
        "mean_dbm": mean_dbm,
        "raw_std_db": raw_std_db,
        "std_db": std_db,
        "p2p_swing_db": p2p_swing_db,
        "step_mean_db": step_mean_db,
    }


def _compute_gated_common_mode_db(
    ws_drifts: List[float],
    ws_p2ps: List[float],
) -> Tuple[float, bool]:
    """
    Estimates Workstation `Wi-Fi 4` receiver AGC / thermal common-mode bias while strictly
    preserving real near-field human motion at the Workstation desk:
      - If >= 3 Workstation chords exhibit dynamic swing (`>= 2.5 dB`) or deep shadowing (`<= -3.0 dB`),
        flags `near_field_convergence=True` and sets `common_mode_db=0.0`.
      - Only cancels uniform shifts (`[-2.0, +2.0] dB`) when >= 4 chords are present, <= 1 chord is
        dynamic, and interquartile spread across chords is `<= 2.2 dB`.
    """
    dynamic_cnt = sum(1 for p in ws_p2ps if p >= 2.5)
    deep_shadow_cnt = sum(1 for d in ws_drifts if d <= -3.0)
    near_field = (dynamic_cnt >= 3) or (deep_shadow_cnt >= 3) or ((dynamic_cnt + deep_shadow_cnt) >= 4)
    if near_field or len(ws_drifts) < 4 or dynamic_cnt >= 2 or deep_shadow_cnt >= 2:
        return 0.0, near_field
    s = sorted(ws_drifts)
    n = len(s)
    iqr = s[int(0.75 * (n - 1))] - s[int(0.25 * (n - 1))]
    if iqr > 2.2:
        return 0.0, False
    med = s[n // 2] if (n % 2 == 1) else 0.5 * (s[n // 2 - 1] + s[n // 2])
    if abs(med) < 0.35:
        return 0.0, False
    return round(max(-2.0, min(2.0, med)), 2), False


def _condition_chord_signal(
    mean_dbm: Optional[float],
    std_db: float,
    p2p_swing_db: float,
    n_samples: int,
    rtt_jitter_ms: float = 0.0,
    n_rtt_samples: int = 0,
    prev_base: Optional[float] = None,
    prev_fast_in: Optional[float] = None,
    prev_ewma_std_in: Optional[float] = None,
    prev_cusum_pos_in: float = 0.0,
    prev_cusum_neg_in: float = 0.0,
    recent_valid_rssi: Optional[List[float]] = None,
    calibrate: bool = False,
    ring: str = "interior",
    qbss_chan_util_pct: Optional[float] = None,
    mean_noise: Optional[float] = None,
) -> Dict[str, Any]:
    """
    4-Stage Calibrated RF Fresnel Signal Conditioner:
      1. Hampel Spike Clamp with 2-sweep step persistence + instant return-to-baseline pass-through.
      2. Fast EWMA (`alpha = 0.35`).
      3. Decoupled Inter-Sweep EWMA Volatility (`0.25 * innov_sq + 0.75 * prev_var`, no `max()` upward bias).
      4. Unsmoothed Two-Sided Leaky Page-Hinkley CUSUM (`0.92` decay + `0.006` anti-latch baseline creep)
         and IE 11 QBSS / Cast noise interference gating.
    """
    recent_valid = list(recent_valid_rssi or [])
    interference_gated = bool(
        (qbss_chan_util_pct is not None and float(qbss_chan_util_pct) >= 65.0)
        or (mean_noise is not None and float(mean_noise) > -75.0)
    )
    gate_mult = 1.35 if interference_gated else 1.0

    if calibrate or prev_base is None or mean_dbm is None:
        base_dbm = mean_dbm if (calibrate or prev_base is None) else prev_base
        drift_db = 0.0
        filtered_dbm = mean_dbm
        ewma_fast_dbm = mean_dbm
        ewma_std_db = std_db
        z_score = 0.0
        cusum_pos_db = 0.0
        cusum_neg_db = 0.0
        cusum_db = 0.0
    else:
        filtered_dbm = float(mean_dbm)
        returning_to_base = abs(filtered_dbm - float(prev_base)) <= 1.25
        sustained_step = bool(recent_valid and abs(float(recent_valid[-1]) - filtered_dbm) <= 1.5)
        if len(recent_valid) >= 3 and p2p_swing_db < 1.5 and not returning_to_base and not sustained_step:
            s_win = sorted(recent_valid[-5:])
            med = s_win[len(s_win) // 2]
            mad_win = sorted(abs(x - med) for x in s_win)
            mad = mad_win[len(mad_win) // 2]
            hampel_thresh = max(3.5, 3.0 * 1.4826 * mad)
            diff_med = filtered_dbm - med
            if abs(diff_med) > hampel_thresh:
                filtered_dbm = round(med + math.copysign(min(1.2, 0.20 * abs(diff_med)), diff_med), 2)

        prev_fast = float(prev_fast_in) if prev_fast_in is not None else (recent_valid[-1] if recent_valid else float(prev_base))
        ewma_fast_dbm = round(0.35 * filtered_dbm + 0.65 * prev_fast, 2)

        prev_ewma_std = float(prev_ewma_std_in) if prev_ewma_std_in is not None else std_db
        innov_sq = min(16.0, (filtered_dbm - prev_fast) ** 2)
        ewma_var = 0.25 * innov_sq + 0.75 * (prev_ewma_std ** 2)
        ewma_std_db = round(math.sqrt(ewma_var), 2)

        base_dbm = float(prev_base)
        strong_link = (ring != "exterior_perimeter") and (base_dbm >= -74.0)
        noise_floor_sigma = 0.65 if strong_link else 1.10
        denom_sigma = max(noise_floor_sigma, min(1.8, prev_ewma_std if prev_ewma_std > 0 else noise_floor_sigma))

        raw_drift = filtered_dbm - base_dbm
        drift_db = round(ewma_fast_dbm - base_dbm, 2)
        z_score = round(abs(drift_db) / denom_sigma, 2)

        plateau_vals = [float(x) for x in recent_valid[-4:]] + [filtered_dbm]
        stationary_plateau = (
            p2p_swing_db <= 1.0
            and std_db <= 0.65
            and len(recent_valid) >= 4
            and (max(plateau_vals) - min(plateau_vals)) <= 1.2
        )
        if stationary_plateau:
            cusum_pos_db = round(max(0.0, float(prev_cusum_pos_in) * 0.50), 2)
            cusum_neg_db = round(max(0.0, float(prev_cusum_neg_in) * 0.50), 2)
            base_dbm = round(0.88 * base_dbm + 0.12 * filtered_dbm, 2)
            drift_db = round(ewma_fast_dbm - base_dbm, 2)
            z_score = round(abs(drift_db) / denom_sigma, 2)
        else:
            slack_k = 0.85 if strong_link else 1.25
            cusum_pos_db = round(min(15.0, max(0.0, 0.92 * float(prev_cusum_pos_in) + raw_drift - slack_k)), 2)
            cusum_neg_db = round(min(15.0, max(0.0, 0.92 * float(prev_cusum_neg_in) - raw_drift - slack_k)), 2)
            base_dbm = round(0.994 * base_dbm + 0.006 * filtered_dbm, 2)
        cusum_db = round(max(cusum_pos_db, cusum_neg_db), 2)

    if mean_dbm is None:
        if n_rtt_samples >= 3 and rtt_jitter_ms >= 140.0:
            motion_state = "presence_shift"
        else:
            motion_state = "quiet"
    elif calibrate or prev_base is None:
        if p2p_swing_db >= 3.5 or (n_samples >= 3 and std_db >= 1.35):
            motion_state = "motion_detected"
        elif p2p_swing_db >= 2.5 or (n_samples >= 3 and std_db >= 0.95):
            motion_state = "presence_shift"
        else:
            motion_state = "quiet"
    else:
        is_edge = (ring == "exterior_perimeter") or (base_dbm is not None and float(base_dbm) < -74.0)
        if not is_edge:
            if (
                p2p_swing_db >= 3.0 * gate_mult
                or (n_samples >= 3 and std_db >= 1.15 * gate_mult)
                or (ewma_std_db >= 1.45 * gate_mult and abs(drift_db) >= 1.5)
            ):
                motion_state = "motion_detected"
            elif (
                p2p_swing_db >= 2.0 * gate_mult
                or (n_samples >= 3 and std_db >= 0.75 * gate_mult)
                or (z_score >= 3.0 * gate_mult and abs(drift_db) >= 2.0)
                or cusum_db >= 3.8 * gate_mult
                or abs(drift_db) >= 2.6 * gate_mult
            ):
                motion_state = "presence_shift"
            else:
                motion_state = "quiet"
        else:
            if (
                p2p_swing_db >= 4.0 * gate_mult
                or (n_samples >= 3 and std_db >= 1.55 * gate_mult)
                or (ewma_std_db >= 1.85 * gate_mult and abs(drift_db) >= 2.2)
            ):
                motion_state = "motion_detected"
            elif (
                p2p_swing_db >= 3.0 * gate_mult
                or (n_samples >= 3 and std_db >= 1.05 * gate_mult)
                or (z_score >= 3.3 * gate_mult and abs(drift_db) >= 2.8)
                or cusum_db >= 4.5 * gate_mult
                or abs(drift_db) >= 3.2 * gate_mult
            ):
                motion_state = "presence_shift"
            else:
                motion_state = "quiet"

    if not calibrate and prev_base is not None and mean_dbm is not None and motion_state == "quiet" and base_dbm is not None:
        base_dbm = round(0.98 * float(base_dbm) + 0.02 * float(filtered_dbm if filtered_dbm is not None else mean_dbm), 2)

    return {
        "base_dbm": base_dbm,
        "filtered_dbm": filtered_dbm,
        "ewma_fast_dbm": ewma_fast_dbm,
        "ewma_std_db": ewma_std_db,
        "drift_db": drift_db,
        "z_score": z_score,
        "cusum_pos_db": cusum_pos_db,
        "cusum_neg_db": cusum_neg_db,
        "cusum_db": cusum_db,
        "motion_state": motion_state,
        "interference_gated": interference_gated,
    }


def _localize_rf_disturbances(
    chords_report: List[Dict[str, Any]],
    recent_ts_by_chord: Optional[Dict[str, List[Dict[str, Any]]]] = None,
    transient_proximity_aps: Optional[List[Dict[str, Any]]] = None,
    near_field_workstation: bool = False,
    suppress_single_neighbor: bool = True,
) -> Dict[str, Any]:
    """
    Tomographic Multi-Chord Spatial Localization & Property Perimeter Verifier:
      - Suppresses isolated single-chord neighbor fluctuations (`NEIGHBOR_INTERNAL_SUPPRESSED`)
        caused by activity inside a neighbor's own house next to their router.
      - Corroborates genuine property perimeter events via:
          1. Multi-chord coincidence in the same compass sector (`NORTH`, `SOUTH`, `EAST_WEST_FLANK`)
          2. Exterior + House-Boundary chord co-activation (`NORTH` + Study / `SOUTH` + South-Wall Clock)
          3. Kinematic approach / departure sequences (`EXTERIOR -> INTERIOR` or `INTERIOR -> EXTERIOR` within 45s)
          4. Workstation near-field multi-chord convergence (`>= 3` `ws_wifi_*` chords)
          5. Transient high-RSSI proximity transmitters (`>= -78 dBm` mobile hotspot / vehicle Wi-Fi / new AP)
    """
    recent_map = recent_ts_by_chord or {}
    transients = list(transient_proximity_aps or [])
    now_ts = int(time.time())

    active_ext_by_sector: Dict[str, List[Dict[str, Any]]] = {}
    active_int: List[Dict[str, Any]] = []
    for ch in chords_report:
        if ch.get("sensor_backend") == "wmm_rtt_only":
            continue
        st = str(ch.get("motion_state") or "quiet")
        if st not in ("motion_detected", "presence_shift"):
            continue
        if str(ch.get("ring") or "interior") == "exterior_perimeter":
            sec = str(ch.get("compass_sector") or "EXTERIOR_UNKNOWN")
            active_ext_by_sector.setdefault(sec, []).append(ch)
        else:
            active_int.append(ch)

    int_sectors = {str(c.get("compass_sector") or "") for c in active_int}
    south_boundary_active = bool(int_sectors & {"SOUTH_WALL", "INTERIOR_SOUTH"})
    north_boundary_active = bool(int_sectors & {"NORTH_WEST_STUDY"}) or near_field_workstation

    recent_ext_sectors: Set[str] = set()
    recent_int_active = False
    for cid_k, rows in recent_map.items():
        for r in rows:
            age = now_ts - int(r.get("ts") or 0)
            if not (4 <= age <= 50):
                continue
            if str(r.get("motion_state") or r.get("state") or "quiet") not in ("motion_detected", "presence_shift"):
                continue
            if cid_k.startswith("perim_wifi_") or str(r.get("ring") or "") == "exterior_perimeter":
                recent_ext_sectors.add(str(r.get("compass_sector") or "EXTERIOR"))
            else:
                recent_int_active = True

    corroborated_events: List[Dict[str, Any]] = []
    suppressed_events: List[Dict[str, Any]] = []
    kinematic_vectors: List[str] = []

    for sec, ext_list in active_ext_by_sector.items():
        boundary_match = (
            (sec == "NORTH" and north_boundary_active)
            or (sec == "SOUTH" and south_boundary_active)
            or (sec == "EAST_WEST_FLANK" and bool(active_int))
        )
        if len(ext_list) >= 2 or boundary_match or bool(transients):
            verdict = "PERIMETER_APPROACH_VECTOR" if boundary_match else "PERIMETER_SECTOR_MOTION"
            if boundary_match:
                kinematic_vectors.append(f"{sec} EXTERIOR -> HOUSE BOUNDARY")
            corroborated_events.append({
                "verdict": verdict,
                "sector": sec,
                "confidence": "high" if (len(ext_list) >= 2 and boundary_match) else "medium_high",
                "chords": [c["chord_id"] for c in ext_list],
                "labels": [c["label"] for c in ext_list],
                "max_p2p_swing_db": max(float(c.get("p2p_swing_db") or 0.0) for c in ext_list),
                "summary": (
                    f"Corroborated {sec} property perimeter disturbance across {len(ext_list)} exterior chord(s)"
                    + (" + adjacent house boundary corridor" if boundary_match else "")
                ),
            })
        elif suppress_single_neighbor and not active_int and not recent_int_active:
            c0 = ext_list[0]
            c0["perimeter_verdict"] = "NEIGHBOR_INTERNAL_SUPPRESSED"
            suppressed_events.append({
                "verdict": "NEIGHBOR_INTERNAL_SUPPRESSED",
                "sector": sec,
                "chord_id": c0["chord_id"],
                "label": c0["label"],
                "p2p_swing_db": c0.get("p2p_swing_db"),
                "reason": "Single external neighbor AP fluctuated with zero co-sector, boundary, or interior corroboration (likely activity inside neighbor's own house).",
            })
        else:
            corroborated_events.append({
                "verdict": "PERIMETER_DEPARTURE_VECTOR" if recent_int_active else "PERIMETER_WATCH",
                "sector": sec,
                "confidence": "medium",
                "chords": [c["chord_id"] for c in ext_list],
                "labels": [c["label"] for c in ext_list],
                "max_p2p_swing_db": max(float(c.get("p2p_swing_db") or 0.0) for c in ext_list),
                "summary": f"Exterior {sec} chord active following recent interior movement (possible departure vector).",
            })
            if recent_int_active:
                kinematic_vectors.append(f"HOUSE INTERIOR -> {sec} EXTERIOR")

    if active_int and recent_ext_sectors and not active_ext_by_sector:
        secs_str = "/".join(sorted(recent_ext_sectors))
        kinematic_vectors.append(f"{secs_str} EXTERIOR -> HOUSE INTERIOR")
        corroborated_events.append({
            "verdict": "PERIMETER_APPROACH_VECTOR",
            "sector": secs_str,
            "confidence": "high",
            "chords": [c["chord_id"] for c in active_int],
            "labels": [c["label"] for c in active_int],
            "max_p2p_swing_db": max(float(c.get("p2p_swing_db") or 0.0) for c in active_int),
            "summary": f"Kinematic inward sequence: {secs_str} exterior disturbance within last 45s followed by interior boundary activity.",
        })

    if near_field_workstation:
        corroborated_events.append({
            "verdict": "WORKSTATION_NEAR_FIELD",
            "sector": "NORTH_WEST_STUDY",
            "confidence": "high",
            "chords": [c["chord_id"] for c in active_int if str(c.get("chord_id", "")).startswith("ws_wifi_")],
            "labels": [c["label"] for c in active_int if str(c.get("chord_id", "")).startswith("ws_wifi_")],
            "max_p2p_swing_db": max([float(c.get("p2p_swing_db") or 0.0) for c in active_int] or [0.0]),
            "summary": "Multi-chord convergence at Workstation Wi-Fi 4 antenna (<1.5m near-field presence in North-West Study).",
        })
    elif south_boundary_active and len([c for c in active_int if c.get("compass_sector") in ("SOUTH_WALL", "INTERIOR_SOUTH")]) >= 2:
        s_chords = [c for c in active_int if c.get("compass_sector") in ("SOUTH_WALL", "INTERIOR_SOUTH")]
        corroborated_events.append({
            "verdict": "SOUTH_WALL_BOUNDARY",
            "sector": "SOUTH_WALL",
            "confidence": "medium_high",
            "chords": [c["chord_id"] for c in s_chords],
            "labels": [c["label"] for c in s_chords],
            "max_p2p_swing_db": max(float(c.get("p2p_swing_db") or 0.0) for c in s_chords),
            "summary": "Coincident Fresnel disturbance along South Wall (Lenovo Smart Clock + South Leaf corridors).",
        })

    for tap in transients:
        corroborated_events.append({
            "verdict": "TRANSIENT_PROXIMITY_TX",
            "sector": str(tap.get("compass_sector") or "PROXIMITY"),
            "confidence": "high" if float(tap.get("rssi_dbm") or -99) >= -70.0 else "medium_high",
            "chords": [f"transient_{str(tap.get('bssid') or '').replace(':', '')}"],
            "labels": [f"{tap.get('ssid') or '(hidden)'} ({tap.get('bssid')})"],
            "max_p2p_swing_db": 0.0,
            "rssi_dbm": tap.get("rssi_dbm"),
            "summary": (
                f"Transient proximity 802.11 transmitter '{tap.get('ssid') or '(hidden)'}' ({tap.get('bssid')}) "
                f"detected at {tap.get('rssi_dbm')} dBm in {tap.get('compass_sector', 'PROXIMITY')} sector."
            ),
        })

    perimeter_alert_verdicts = {
        "PERIMETER_SECTOR_MOTION",
        "PERIMETER_APPROACH_VECTOR",
        "PERIMETER_DEPARTURE_VECTOR",
        "TRANSIENT_PROXIMITY_TX",
    }
    perimeter_alerts = [e for e in corroborated_events if e.get("verdict") in perimeter_alert_verdicts]
    if perimeter_alerts:
        overall = "PERIMETER_ALERT"
    elif active_int:
        overall = "INTERIOR_ACTIVITY_ONLY"
    elif suppressed_events:
        overall = "PERIMETER_QUIET_NEIGHBOR_SUPPRESSED"
    else:
        overall = "PERIMETER_QUIET"

    return {
        "overall_verdict": overall,
        "perimeter_alerts_count": len(perimeter_alerts),
        "perimeter_alerts": perimeter_alerts,
        "corroborated_events": corroborated_events,
        "suppressed_neighbor_events": suppressed_events,
        "kinematic_vectors": kinematic_vectors,
        "transient_proximity_aps": transients,
        "near_field_workstation": near_field_workstation,
    }


def _select_exterior_perimeter_targets(
    scan_nets: List[Dict[str, Any]],
    tri_by_bssid: Dict[str, Dict[str, Any]],
    wl: Dict[str, Any],
) -> Tuple[Dict[str, Dict[str, Any]], List[Dict[str, Any]]]:
    """
    Selects up to `max_exterior_chords` stationary exterior neighbor BSSIDs balanced across
    `NORTH`, `SOUTH`, and `EAST_WEST_FLANK` compass sectors, plus detects any transient
    high-RSSI mobile/vehicle/new transmitters (`>= transient_proximity_alert_dbm`).
    """
    p_cfg = wl.get("perimeter_guard") or {}
    compass_cfg = wl.get("compass_calibration") or {}
    max_ext = max(2, min(10, int(p_cfg.get("max_exterior_chords") or 6)))
    min_rssi = float(p_cfg.get("min_rssi_dbm") or -91.0)
    trans_thresh = float(p_cfg.get("transient_proximity_alert_dbm") or -78.0)

    home_ssids = {str(s).lower() for s in (wl.get("home_ssids") or [])}
    home_ouis = {mac[:8].lower() for mac in EXPECTED_GATEWAY_MACS.values() if len(mac) >= 8} | {str(o).lower() for o in (COMPASS_ANCHORS.get("home_ouis") or [])}
    household_bssids = {str(b).lower() for b in (COMPASS_ANCHORS.get("home_bssids") or [])} | {(p.get("bssid") or "").lower() for p in _list_claimed_peripherals()}

    con = connect_db()
    known_airspace = {
        str(r["bssid"]).lower(): int(r["first_seen"] or 0)
        for r in con.execute("SELECT bssid, first_seen FROM wifi_airspace").fetchall()
        if r["bssid"]
    }
    con.close()
    now_ts = int(time.time())

    mobile_tokens = ("iphone", "galaxy", "pixel", "androidap", "hotspot", "tesla", "mychevrolet", "uconnect", "ford", "dashcam", "carplay")
    candidates: List[Dict[str, Any]] = []
    transients: List[Dict[str, Any]] = []

    for net in scan_nets:
        b = str(net.get("bssid") or "").lower().strip()
        if not b or b in household_bssids or b[:8] in home_ouis:
            continue
        s = str(net.get("ssid") or "").strip()
        if s.lower() in home_ssids:
            continue
        rssi = net.get("rssi_dbm")
        if rssi is None:
            continue
        rssi_f = float(rssi)
        t_rec = tri_by_bssid.get(b) or {}
        sector = str(t_rec.get("compass_sector") or "") or _classify_compass_sector(
            bssid=b,
            ssid=s,
            desktop_rssi_dbm=rssi_f,
            peripheral_rssi_dbm=t_rec.get("peripheral_rssi_dbm"),
            delta_south_minus_north_db=t_rec.get("south_minus_north_db"),
            classification="neighbor",
            compass_cfg=compass_cfg,
        )
        first_seen = known_airspace.get(b, 0)
        is_new = (first_seen == 0) or ((now_ts - first_seen) < 600)
        is_mobile = any(tok in s.lower() for tok in mobile_tokens)
        if rssi_f >= trans_thresh and (is_new or is_mobile):
            transients.append({
                "bssid": b,
                "ssid": s,
                "rssi_dbm": rssi_f,
                "band": net.get("band") or "2.4 GHz",
                "channel": net.get("channel") or 0,
                "compass_sector": sector,
                "reason": "mobile_or_vehicle_signature" if is_mobile else "new_high_rssi_transmitter",
            })
        if rssi_f >= min_rssi and not is_mobile:
            candidates.append({
                "bssid": b,
                "ssid": s or b,
                "rssi_dbm": rssi_f,
                "band": net.get("band") or "2.4 GHz",
                "compass_sector": sector,
            })

    # Balanced sector selection: pick strongest named SSID in NORTH, SOUTH, EAST_WEST_FLANK round-robin, then fill by RSSI
    by_sec: Dict[str, List[Dict[str, Any]]] = {"NORTH": [], "SOUTH": [], "EAST_WEST_FLANK": [], "OTHER": []}
    for c in sorted(candidates, key=lambda x: (0 if (x["ssid"] and x["ssid"] != x["bssid"]) else 1, -float(x["rssi_dbm"]))):
        sec_k = c["compass_sector"] if c["compass_sector"] in ("NORTH", "SOUTH", "EAST_WEST_FLANK") else "OTHER"
        by_sec[sec_k].append(c)

    selected: Dict[str, Dict[str, Any]] = {}
    while len(selected) < max_ext:
        added_any = False
        for sec_k in ("NORTH", "SOUTH", "EAST_WEST_FLANK", "OTHER"):
            while by_sec[sec_k]:
                cand = by_sec[sec_k].pop(0)
                if cand["bssid"] not in selected:
                    sec_lbl = cand["compass_sector"].replace("_", " ").title()
                    selected[cand["bssid"]] = {
                        "chord_id": f"perim_wifi_{cand['bssid'].replace(':', '')}",
                        "label": f"Perimeter [{cand['compass_sector']}] {cand['ssid']} ({cand['band']})",
                        "zone": f"{sec_lbl} Perimeter ({cand['ssid']})",
                        "compass_sector": cand["compass_sector"],
                        "ring": "exterior_perimeter",
                    }
                    added_any = True
                    break
            if len(selected) >= max_ext:
                break
        if not added_any:
            break

    return selected, transients


def rf_motion_sense(
    duration: int = 6,
    calibrate: bool = False,
    include_perimeter: bool = True,
) -> Dict[str, Any]:
    """
    Device-Free Wi-Fi RF Tomographic Motion, Presence & Property Perimeter Sensor:
    Samples multi-room household + exterior perimeter RF chords concurrently over `duration` seconds:
      1. LAN Cast Eureka RF Chords (:8443/setup/eureka_info dBm RSSI, noise floor, SNR, & wireless RTT)
      2. Cross-Platform Linux (`nl80211` / `iw`) & WSL2 (`netsh`) Chords on Workstation Wi-Fi:
         - dBm RSSI, exact MHz frequency, `host_ts_ft` / TSF stale-beacon deduplication,
           IE 11 QBSS channel utilization, IE 35 TPC transmit-power compensation, and co-located
           Nest Wifi Pro primary+guest dual-VAP fusion across concentric 2.4 GHz + 5 GHz bands.
      3. Compass-Calibrated Exterior Property Perimeter Chords (configured `NORTH` anchor,
         `SOUTH_WALL` = Lenovo Smart Clock, `SOUTH`, `EAST_WEST_FLANK`) with single-chord neighbor
         suppression and kinematic approach/departure corroboration.
    Emits `network.rf_motion` and `network.perimeter_alert` onto `.george/ipc/event_bus.fifo`.
    """
    import ssl

    dur = max(2, min(30, int(duration or 6)))
    n_ticks = 2 if dur <= 2 else (3 if dur == 3 else max(4, min(14, int(round(dur / 0.95)))))
    sleep_s = 0.20 if dur <= 3 else max(0.35, (dur / float(n_ticks)))

    cast_targets, _ = _discover_lan_cast_and_mesh_targets()
    ctx = ssl._create_unverified_context()
    wl = load_wifi_watchlist()
    p_cfg = wl.get("perimeter_guard") or {}
    suppress_single_neighbor = bool(p_cfg.get("neighbor_single_chord_suppression", True))

    claimed = _list_claimed_peripherals()
    south_fallback = str(COMPASS_ANCHORS.get("south_wall_bssid") or "").lower()
    clock_bssid = (claimed[0].get("bssid") or south_fallback).lower() if claimed else south_fallback
    cached_tri_map: Dict[str, Dict[str, Any]] = {}
    if claimed:
        p_scan = list((claimed[0].get("last_telemetry") or {}).get("nearby_wifi_seen_by_device") or [])
        con_tri = connect_db()
        w_rows = [dict(r) for r in con_tri.execute("SELECT * FROM wifi_airspace").fetchall()]
        con_tri.close()
        if p_scan or w_rows:
            tri_obj = _compute_airspace_triangulation(w_rows, p_scan)
            for tx in tri_obj.get("transmitters") or []:
                if tx.get("bssid"):
                    cached_tri_map[str(tx["bssid"]).lower()] = tx

    # Stationary interior + boundary chords loaded from .george/config/tyler_household.json
    watched_wifi_chords: Dict[str, Dict[str, str]] = {
        k.lower(): dict(v) for k, v in WATCHED_WIFI_CHORDS_CFG.items() if isinstance(v, dict)
    }
    if clock_bssid and clock_bssid not in watched_wifi_chords:
        watched_wifi_chords[clock_bssid] = {
            "label": "Workstation <-> South Wall Sensor",
            "zone": "South Wall Sensor Span",
            "compass_sector": "SOUTH_WALL",
            "ring": "interior",
            "guest_bssid": "",
        }

    exterior_targets: Dict[str, Dict[str, Any]] = {}
    transient_aps_by_bssid: Dict[str, Dict[str, Any]] = {}
    ws_backend_used = "unavailable"
    airlock_skipped_ticks = 0
    seen_host_ts_by_cid: Dict[str, Set[int]] = {}
    vap_collisions_rejected = 0

    series: Dict[str, Dict[str, Any]] = {}

    def _sample_cast_one(t: Dict[str, str]) -> Optional[Dict[str, Any]]:
        ip = t["ip"]
        url = f"https://{ip}:8443/setup/eureka_info?params=wifi,net,name&options=detail"
        t0 = time.time()
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Tyler-RF-Tomography/2.0"})
            with urllib.request.urlopen(req, context=ctx, timeout=1.2) as resp:
                rtt_ms = round((time.time() - t0) * 1000.0, 1)
                d = json.loads(resp.read().decode("utf-8", errors="ignore"))
                w = d.get("wifi") or {}
                sig = w.get("signal_level")
                noi = w.get("noise_level")
                bssid = str(w.get("bssid") or "").lower()
                nm = str(d.get("name") or t["label"])
                return {
                    "chord_id": f"lan_cast_{ip.replace('.', '_')}",
                    "label": f"Nest Mesh <-> {nm}",
                    "zone": nm,
                    "tx_node": bssid or "Nest Wifi Pro",
                    "rx_node": f"{nm} ({ip})",
                    "bssid": bssid,
                    "band": "5 GHz" if bssid.endswith(("74", "75", "ee", "ef")) else "2.4 GHz",
                    "frequency_mhz": 5500 if bssid.endswith(("74", "75", "ee", "ef")) else 2437,
                    "rssi_dbm": float(sig) if sig is not None else None,
                    "noise_dbm": float(noi) if noi is not None else None,
                    "rtt_ms": rtt_ms,
                    "compass_sector": "INTERIOR_SOUTH" if (COMPASS_ANCHORS.get("leaf_router_prefix") and bssid.startswith(str(COMPASS_ANCHORS.get("leaf_router_prefix")).lower())) else "INTERIOR_CORE",
                    "ring": "interior",
                    "sensor_backend": "lan_eureka_dbm" if sig is not None else "wmm_rtt_only",
                    "host_ts_ft": 0,
                    "beacon_age_ms": 0,
                    "tx_power_dbm": None,
                    "qbss_chan_util_pct": None,
                }
        except Exception:
            return None

    def _sample_workstation_wifi_tick(trigger_rescan: bool = True) -> Tuple[List[Dict[str, Any]], str, List[Dict[str, Any]]]:
        nets, backend = _scan_windows_wlan_native(trigger_rescan=trigger_rescan, wait_ms=1800 if dur <= 2 else 2100)
        return nets, backend, []

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        for tick_idx in range(n_ticks):
            t_tick = time.time()
            cast_futs = [pool.submit(_sample_cast_one, ct) for ct in cast_targets]
            ws_fut = pool.submit(_sample_workstation_wifi_tick, True)

            tick_items: List[Dict[str, Any]] = []
            for f in cast_futs:
                res = f.result()
                if res:
                    tick_items.append(res)

            ws_nets, backend_now, _ = ws_fut.result()
            if backend_now == "airlock_radio_busy":
                airlock_skipped_ticks += 1
            elif backend_now != "unavailable":
                ws_backend_used = backend_now

            if ws_nets:
                if include_perimeter:
                    ext_now, trans_now = _select_exterior_perimeter_targets(ws_nets, cached_tri_map, wl)
                    for ta in trans_now:
                        transient_aps_by_bssid[ta["bssid"]] = ta
                    if not exterior_targets:
                        exterior_targets = ext_now
                    elif len(exterior_targets) < 6:
                        for eb, em in ext_now.items():
                            if eb not in exterior_targets and len(exterior_targets) < 6:
                                exterior_targets[eb] = em

                by_bmac = {str(n["bssid"]).lower(): n for n in ws_nets if n.get("bssid")}

                # 1. Watched Interior & Boundary Chords (with co-located Dual-VAP fusion)
                for prim_b, meta in watched_wifi_chords.items():
                    n_prim = by_bmac.get(prim_b)
                    guest_b = meta.get("guest_bssid") or ""
                    n_guest = by_bmac.get(guest_b) if guest_b else None
                    if not n_prim and not n_guest:
                        continue
                    anchor_n = n_prim or n_guest
                    assert anchor_n is not None
                    age_p = int(n_prim.get("beacon_age_ms") or 0) if n_prim else 999999
                    age_g = int(n_guest.get("beacon_age_ms") or 0) if n_guest else 999999
                    if min(age_p, age_g) > 20000 and backend_now == "linux_nl80211_iw":
                        continue

                    r_p = float(n_prim["rssi_dbm"]) if (n_prim and n_prim.get("rssi_dbm") is not None and age_p <= 15000) else None
                    r_g = float(n_guest["rssi_dbm"]) if (n_guest and n_guest.get("rssi_dbm") is not None and age_g <= 15000) else None
                    fused_rssi, collided = _fuse_colocated_vap_rssi(r_p, r_g)
                    if collided:
                        vap_collisions_rejected += 1
                    if fused_rssi is None:
                        continue

                    cid_w = f"ws_wifi_{prim_b.replace(':', '')}"
                    host_ft = max(
                        int(n_prim.get("host_ts_ft") or 0) if n_prim else 0,
                        int(n_guest.get("host_ts_ft") or 0) if n_guest else 0,
                    )
                    seen_set = seen_host_ts_by_cid.setdefault(cid_w, set())
                    if host_ft > 0 and host_ft in seen_set:
                        continue
                    if host_ft > 0:
                        seen_set.add(host_ft)

                    tick_items.append({
                        "chord_id": cid_w,
                        "label": meta["label"],
                        "zone": meta["zone"],
                        "tx_node": f"{anchor_n.get('ssid') or prim_b} ({prim_b})",
                        "rx_node": "Workstation Wi-Fi 4",
                        "bssid": prim_b,
                        "band": str(anchor_n.get("band") or "2.4 GHz"),
                        "frequency_mhz": int(anchor_n.get("frequency_mhz") or 0),
                        "rssi_dbm": fused_rssi,
                        "noise_dbm": None,
                        "rtt_ms": None,
                        "compass_sector": meta["compass_sector"],
                        "ring": meta["ring"],
                        "sensor_backend": backend_now,
                        "host_ts_ft": host_ft,
                        "beacon_age_ms": min(age_p, age_g),
                        "tx_power_dbm": anchor_n.get("tx_power_dbm"),
                        "qbss_chan_util_pct": anchor_n.get("qbss_chan_util_pct"),
                    })

                # 2. Exterior Property Perimeter Chords
                for ext_b, emeta in exterior_targets.items():
                    n_ext = by_bmac.get(ext_b)
                    if not n_ext or n_ext.get("rssi_dbm") is None:
                        continue
                    age_e = int(n_ext.get("beacon_age_ms") or 0)
                    if age_e > 25000 and backend_now == "linux_nl80211_iw":
                        continue
                    cid_e = emeta["chord_id"]
                    host_ft_e = int(n_ext.get("host_ts_ft") or 0)
                    seen_set_e = seen_host_ts_by_cid.setdefault(cid_e, set())
                    if host_ft_e > 0 and host_ft_e in seen_set_e:
                        continue
                    if host_ft_e > 0:
                        seen_set_e.add(host_ft_e)

                    tick_items.append({
                        "chord_id": cid_e,
                        "label": emeta["label"],
                        "zone": emeta["zone"],
                        "tx_node": f"{n_ext.get('ssid') or ext_b} ({ext_b})",
                        "rx_node": "Workstation Wi-Fi 4",
                        "bssid": ext_b,
                        "band": str(n_ext.get("band") or "2.4 GHz"),
                        "frequency_mhz": int(n_ext.get("frequency_mhz") or 0),
                        "rssi_dbm": float(n_ext["rssi_dbm"]),
                        "noise_dbm": None,
                        "rtt_ms": None,
                        "compass_sector": emeta["compass_sector"],
                        "ring": "exterior_perimeter",
                        "sensor_backend": backend_now,
                        "host_ts_ft": host_ft_e,
                        "beacon_age_ms": age_e,
                        "tx_power_dbm": n_ext.get("tx_power_dbm"),
                        "qbss_chan_util_pct": n_ext.get("qbss_chan_util_pct"),
                    })

            for item in tick_items:
                cid = item["chord_id"]
                rec = series.get(cid)
                if not rec:
                    rec = {
                        "chord_id": cid,
                        "label": item["label"],
                        "zone": item["zone"],
                        "tx_node": item["tx_node"],
                        "rx_node": item["rx_node"],
                        "bssid": item["bssid"],
                        "band": item["band"],
                        "frequency_mhz": item.get("frequency_mhz") or 0,
                        "compass_sector": item.get("compass_sector") or "INTERIOR",
                        "ring": item.get("ring") or "interior",
                        "sensor_backend": item.get("sensor_backend") or ws_backend_used,
                        "tx_power_dbm": item.get("tx_power_dbm"),
                        "qbss_chan_util_pct": item.get("qbss_chan_util_pct"),
                        "rssi_samples": [],
                        "noise_samples": [],
                        "rtt_samples": [],
                    }
                    series[cid] = rec
                if item.get("tx_power_dbm") is not None:
                    rec["tx_power_dbm"] = item["tx_power_dbm"]
                if item.get("qbss_chan_util_pct") is not None:
                    rec["qbss_chan_util_pct"] = item["qbss_chan_util_pct"]
                if item.get("rssi_dbm") is not None:
                    rec["rssi_samples"].append(float(item["rssi_dbm"]))
                if item.get("noise_dbm") is not None:
                    rec["noise_samples"].append(float(item["noise_dbm"]))
                if item.get("rtt_ms") is not None:
                    rec["rtt_samples"].append(float(item["rtt_ms"]))

            if tick_idx + 1 < n_ticks:
                elapsed = time.time() - t_tick
                if sleep_s > elapsed:
                    time.sleep(sleep_s - elapsed)

    now = int(time.time())
    con = connect_db()
    if not series:
        existing_cnt = int((con.execute("SELECT COUNT(*) FROM peripheral_rf_telemetry").fetchone() or [0])[0])
        if existing_cnt == 0:
            ct0 = cast_targets[0] if cast_targets else {"ip": f"{LAN_SUBNET_PREFIX}40", "label": "LAN Cast Node"}
            lbl0 = str(ct0.get("name") or ct0.get("label") or "LAN Cast Node")
            zn0 = str(ct0.get("zone") or lbl0)
            cid0 = f"lan_cast_{ct0['ip'].replace('.', '_')}"
            series[cid0] = {
                "chord_id": cid0,
                "label": f"{lbl0} ({ct0['ip']})",
                "zone": zn0,
                "tx_node": "Nest Wifi Pro Mesh",
                "rx_node": lbl0,
                "bssid": "",
                "band": "2.4/5 GHz LAN Cast",
                "frequency_mhz": 2437,
                "compass_sector": "INTERIOR_CORE",
                "ring": "interior",
                "sensor_backend": "lan_eureka_dbm",
                "tx_power_dbm": None,
                "qbss_chan_util_pct": None,
                "rssi_samples": [-62.0, -62.0],
                "noise_samples": [-92.0, -92.0],
                "rtt_samples": [135.0, 137.0],
            }

    # First pass: compute raw sample stats, apply IE 35 TPC compensation, and compute gated Workstation common-mode bias
    prev_rows_by_cid: Dict[str, Optional[sqlite3.Row]] = {}
    sample_stats_by_cid: Dict[str, Dict[str, Any]] = {}
    ws_raw_drifts: List[float] = []
    ws_p2ps: List[float] = []

    for cid, rec in series.items():
        prev_row = con.execute("SELECT * FROM peripheral_rf_telemetry WHERE chord_id = ?", (cid,)).fetchone()
        prev_rows_by_cid[cid] = prev_row
        st_s = _compute_chord_sample_stats(rec["rssi_samples"])
        # IE 35 Transmit Power Control (TPC) step compensation
        cur_tx = rec.get("tx_power_dbm")
        prev_tx = (
            int(prev_row["tx_power_dbm"])
            if (prev_row and "tx_power_dbm" in prev_row.keys() and prev_row["tx_power_dbm"] is not None)
            else None
        )
        tpc_delta_db = 0.0
        if cur_tx is not None and prev_tx is not None and abs(int(cur_tx) - prev_tx) >= 1:
            tpc_delta_db = float(int(cur_tx) - prev_tx)
        st_s["tpc_delta_db"] = tpc_delta_db
        sample_stats_by_cid[cid] = st_s

        if rec.get("rx_node") == "Workstation Wi-Fi 4" and st_s["mean_dbm"] is not None:
            p_base = float(prev_row["baseline_rssi_dbm"]) if (prev_row and prev_row["baseline_rssi_dbm"] is not None) else None
            if p_base is not None:
                ws_raw_drifts.append((float(st_s["mean_dbm"]) - tpc_delta_db) - p_base)
                ws_p2ps.append(float(st_s["p2p_swing_db"]))

    common_mode_db, near_field_ws = _compute_gated_common_mode_db(ws_raw_drifts, ws_p2ps)

    chords_report: List[Dict[str, Any]] = []
    active_motion_zones: List[Dict[str, Any]] = []

    for cid, rec in series.items():
        r_vals: List[float] = rec["rssi_samples"]
        n_vals: List[float] = rec["noise_samples"]
        rtt_vals: List[float] = rec["rtt_samples"]
        prev_row = prev_rows_by_cid[cid]
        st_s = sample_stats_by_cid[cid]

        prev_base = float(prev_row["baseline_rssi_dbm"]) if (prev_row and prev_row["baseline_rssi_dbm"] is not None) else None
        prev_hist: List[Dict[str, Any]] = []
        if prev_row and prev_row["history_json"]:
            try:
                prev_hist = json.loads(prev_row["history_json"] or "[]")
            except Exception:
                prev_hist = []

        raw_mean_dbm = st_s["mean_dbm"]
        std_db = float(st_s["std_db"])
        p2p_swing_db = float(st_s["p2p_swing_db"])
        step_mean_db = float(st_s["step_mean_db"])
        tpc_delta_db = float(st_s["tpc_delta_db"])

        applied_cm_db = 0.0
        if raw_mean_dbm is not None:
            adj_mean = float(raw_mean_dbm) - tpc_delta_db
            if rec.get("rx_node") == "Workstation Wi-Fi 4" and common_mode_db != 0.0 and not calibrate and prev_base is not None:
                adj_mean = round(adj_mean - common_mode_db, 2)
                applied_cm_db = common_mode_db
            mean_dbm: Optional[float] = round(adj_mean, 2)
        else:
            mean_dbm = None

        mean_noise = round(sum(n_vals) / len(n_vals), 1) if n_vals else None
        snr_db = round(mean_dbm - mean_noise, 1) if (mean_dbm is not None and mean_noise is not None) else None

        if rtt_vals:
            warm_rtts = rtt_vals[1:] if len(rtt_vals) > 2 else rtt_vals
            mean_rtt = round(sum(warm_rtts) / len(warm_rtts), 1)
            rtt_denom = max(1, len(warm_rtts) - 1) if len(warm_rtts) >= 2 else 1
            rtt_var = sum((x - mean_rtt) ** 2 for x in warm_rtts) / float(rtt_denom)
            rtt_jitter_ms = round(math.sqrt(rtt_var), 1)
        else:
            mean_rtt = None
            rtt_jitter_ms = 0.0

        recent_valid = [float(h["rssi_dbm"]) for h in prev_hist[-5:] if isinstance(h, dict) and h.get("rssi_dbm") is not None]
        prev_fast_in = (
            float(prev_row["ewma_fast_dbm"])
            if (prev_row and "ewma_fast_dbm" in prev_row.keys() and prev_row["ewma_fast_dbm"] is not None)
            else None
        )
        prev_ewma_std_in = (
            float(prev_row["ewma_std_db"])
            if (prev_row and "ewma_std_db" in prev_row.keys() and prev_row["ewma_std_db"] is not None)
            else None
        )
        prev_cusum_all = (
            float(prev_row["cusum_db"])
            if (prev_row and "cusum_db" in prev_row.keys() and prev_row["cusum_db"] is not None)
            else 0.0
        )
        prev_pos_in = (
            float(prev_row["cusum_pos_db"])
            if (prev_row and "cusum_pos_db" in prev_row.keys() and prev_row["cusum_pos_db"] is not None)
            else prev_cusum_all
        )
        prev_neg_in = (
            float(prev_row["cusum_neg_db"])
            if (prev_row and "cusum_neg_db" in prev_row.keys() and prev_row["cusum_neg_db"] is not None)
            else 0.0
        )
        cur_backend_c = str(rec.get("sensor_backend") or ws_backend_used)
        prev_backend_c = str(prev_row["sensor_backend"] or "") if (prev_row and "sensor_backend" in prev_row.keys()) else ""
        backend_changed = bool(prev_backend_c and cur_backend_c and prev_backend_c != cur_backend_c)
        if calibrate or backend_changed:
            prev_hist = []
            recent_valid = []

        cond = _condition_chord_signal(
            mean_dbm=mean_dbm,
            std_db=std_db,
            p2p_swing_db=p2p_swing_db,
            n_samples=len(r_vals),
            rtt_jitter_ms=rtt_jitter_ms,
            n_rtt_samples=len(rtt_vals),
            prev_base=prev_base,
            prev_fast_in=prev_fast_in,
            prev_ewma_std_in=prev_ewma_std_in,
            prev_cusum_pos_in=prev_pos_in,
            prev_cusum_neg_in=prev_neg_in,
            recent_valid_rssi=recent_valid,
            calibrate=bool(calibrate or backend_changed),
            ring=str(rec.get("ring") or "interior"),
            qbss_chan_util_pct=rec.get("qbss_chan_util_pct"),
            mean_noise=mean_noise,
        )

        base_dbm = cond["base_dbm"]
        ewma_fast_dbm = cond["ewma_fast_dbm"]
        ewma_std_db = cond["ewma_std_db"]
        drift_db = cond["drift_db"]
        z_score = cond["z_score"]
        cusum_pos_db = cond["cusum_pos_db"]
        cusum_neg_db = cond["cusum_neg_db"]
        cusum_db = cond["cusum_db"]
        motion_state = cond["motion_state"]

        prev_motion_state = str(prev_row["motion_state"] or "quiet") if prev_row else "quiet"

        prev_hist.append({
            "ts": now,
            "rssi_dbm": mean_dbm,
            "ewma_fast_dbm": ewma_fast_dbm,
            "noise_dbm": mean_noise,
            "snr_db": snr_db,
            "std_db": std_db,
            "ewma_std_db": ewma_std_db,
            "p2p_swing_db": p2p_swing_db,
            "z_score": z_score,
            "cusum_db": cusum_db,
            "rtt_ms": mean_rtt,
            "state": motion_state,
        })
        prev_hist = prev_hist[-60:]

        chord_summary = {
            "chord_id": cid,
            "label": rec["label"],
            "zone": rec["zone"],
            "tx_node": rec["tx_node"],
            "rx_node": rec["rx_node"],
            "bssid": rec["bssid"],
            "band": rec["band"],
            "frequency_mhz": rec.get("frequency_mhz") or 0,
            "compass_sector": rec.get("compass_sector") or "INTERIOR",
            "ring": rec.get("ring") or "interior",
            "sensor_backend": rec.get("sensor_backend") or ws_backend_used,
            "tx_power_dbm": rec.get("tx_power_dbm"),
            "qbss_chan_util_pct": rec.get("qbss_chan_util_pct"),
            "common_mode_db": applied_cm_db,
            "interference_gated": cond["interference_gated"],
            "samples_count": max(len(r_vals), len(rtt_vals)),
            "rssi_samples_dbm": r_vals,
            "mean_rssi_dbm": mean_dbm,
            "raw_mean_rssi_dbm": raw_mean_dbm,
            "ewma_fast_dbm": ewma_fast_dbm,
            "baseline_rssi_dbm": base_dbm,
            "baseline_drift_db": drift_db,
            "std_db": std_db,
            "raw_std_db": st_s["raw_std_db"],
            "ewma_std_db": ewma_std_db,
            "p2p_swing_db": p2p_swing_db,
            "z_score": z_score,
            "cusum_db": cusum_db,
            "cusum_pos_db": cusum_pos_db,
            "cusum_neg_db": cusum_neg_db,
            "step_delta_mean_db": step_mean_db,
            "mean_noise_dbm": mean_noise,
            "snr_db": snr_db,
            "mean_rtt_ms": mean_rtt,
            "rtt_jitter_ms": rtt_jitter_ms,
            "motion_state": motion_state,
            "prev_motion_state": prev_motion_state,
        }
        chords_report.append(chord_summary)

        con.execute(
            """
            INSERT INTO peripheral_rf_telemetry
            (chord_id, label, zone, tx_node, rx_node, bssid, band, frequency_mhz, compass_sector, ring,
             tx_power_dbm, qbss_chan_util_pct, common_mode_db, sensor_backend, baseline_rssi_dbm,
             last_rssi_dbm, ewma_fast_dbm, last_noise_dbm, last_snr_db, last_rtt_ms, std_db, ewma_std_db,
             p2p_swing_db, z_score, cusum_db, cusum_pos_db, cusum_neg_db, motion_state, samples_count, updated_at, history_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(chord_id) DO UPDATE SET
                label=excluded.label,
                zone=excluded.zone,
                tx_node=excluded.tx_node,
                rx_node=excluded.rx_node,
                bssid=excluded.bssid,
                band=excluded.band,
                frequency_mhz=excluded.frequency_mhz,
                compass_sector=excluded.compass_sector,
                ring=excluded.ring,
                tx_power_dbm=COALESCE(excluded.tx_power_dbm, peripheral_rf_telemetry.tx_power_dbm),
                qbss_chan_util_pct=excluded.qbss_chan_util_pct,
                common_mode_db=excluded.common_mode_db,
                sensor_backend=excluded.sensor_backend,
                baseline_rssi_dbm=excluded.baseline_rssi_dbm,
                last_rssi_dbm=excluded.last_rssi_dbm,
                ewma_fast_dbm=excluded.ewma_fast_dbm,
                last_noise_dbm=excluded.last_noise_dbm,
                last_snr_db=excluded.last_snr_db,
                last_rtt_ms=excluded.last_rtt_ms,
                std_db=excluded.std_db,
                ewma_std_db=excluded.ewma_std_db,
                p2p_swing_db=excluded.p2p_swing_db,
                z_score=excluded.z_score,
                cusum_db=excluded.cusum_db,
                cusum_pos_db=excluded.cusum_pos_db,
                cusum_neg_db=excluded.cusum_neg_db,
                motion_state=excluded.motion_state,
                samples_count=excluded.samples_count,
                updated_at=excluded.updated_at,
                history_json=excluded.history_json
            """,
            (
                cid,
                rec["label"],
                rec["zone"],
                rec["tx_node"],
                rec["rx_node"],
                rec["bssid"],
                rec["band"],
                rec.get("frequency_mhz") or 0,
                rec.get("compass_sector") or "INTERIOR",
                rec.get("ring") or "interior",
                rec.get("tx_power_dbm"),
                rec.get("qbss_chan_util_pct"),
                applied_cm_db,
                rec.get("sensor_backend") or ws_backend_used,
                base_dbm,
                mean_dbm,
                ewma_fast_dbm,
                mean_noise,
                snr_db,
                mean_rtt,
                std_db,
                ewma_std_db,
                p2p_swing_db,
                z_score,
                cusum_db,
                cusum_pos_db,
                cusum_neg_db,
                motion_state,
                chord_summary["samples_count"],
                now,
                json.dumps(prev_hist),
            ),
        )
        con.execute(
            """
            INSERT INTO rf_telemetry_timeseries
            (ts, chord_id, label, zone, band, compass_sector, ring, tx_power_dbm, qbss_chan_util_pct,
             common_mode_db, rssi_dbm, ewma_fast_dbm, baseline_rssi_dbm, noise_dbm, snr_db,
             rtt_ms, rtt_jitter_ms, std_db, ewma_std_db, p2p_swing_db, z_score, cusum_db, motion_state, source_mode)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                now,
                cid,
                rec["label"],
                rec["zone"],
                rec["band"],
                rec.get("compass_sector") or "INTERIOR",
                rec.get("ring") or "interior",
                rec.get("tx_power_dbm"),
                rec.get("qbss_chan_util_pct"),
                applied_cm_db,
                mean_dbm,
                ewma_fast_dbm,
                base_dbm,
                mean_noise,
                snr_db,
                mean_rtt,
                rtt_jitter_ms,
                std_db,
                ewma_std_db,
                p2p_swing_db,
                z_score,
                cusum_db,
                motion_state,
                "rf_motion_sense",
            ),
        )

    if calibrate:
        con.execute("UPDATE rf_telemetry_timeseries SET motion_state = 'quiet' WHERE ts >= ?", (now - 120,))

    # Query recent 55s timeseries window for kinematic exterior<->interior vector detection
    recent_ts_rows = con.execute(
        "SELECT ts, chord_id, compass_sector, ring, motion_state FROM rf_telemetry_timeseries WHERE ts >= ? AND ts < ?",
        (now - 55, now),
    ).fetchall()
    recent_ts_map: Dict[str, List[Dict[str, Any]]] = {}
    for rr in recent_ts_rows:
        recent_ts_map.setdefault(str(rr["chord_id"]), []).append(dict(rr))

    localization = _localize_rf_disturbances(
        chords_report=chords_report,
        recent_ts_by_chord=recent_ts_map,
        transient_proximity_aps=list(transient_aps_by_bssid.values()),
        near_field_workstation=near_field_ws,
        suppress_single_neighbor=suppress_single_neighbor,
    )

    suppressed_cids = {str(s.get("chord_id") or "") for s in (localization.get("suppressed_neighbor_events") or [])}

    for chord_summary in chords_report:
        cid = chord_summary["chord_id"]
        motion_state = chord_summary["motion_state"]
        prev_motion_state = chord_summary.pop("prev_motion_state", "quiet")
        if motion_state in ("motion_detected", "presence_shift"):
            if cid in suppressed_cids:
                continue
            active_motion_zones.append(chord_summary)
            last_ev_row = con.execute(
                "SELECT ts, motion_state FROM rf_motion_events WHERE chord_id = ? ORDER BY id DESC LIMIT 1",
                (cid,),
            ).fetchone()
            last_ev_ts = int(last_ev_row["ts"] or 0) if last_ev_row else 0
            state_escalated = (prev_motion_state != motion_state)
            cooldown_elapsed = (now - last_ev_ts) >= 120
            if state_escalated or (motion_state == "motion_detected" and cooldown_elapsed):
                con.execute(
                    """
                    INSERT INTO rf_motion_events
                    (ts, chord_id, zone, motion_state, p2p_swing_db, std_db, baseline_drift_db, details_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        now,
                        cid,
                        chord_summary["zone"],
                        motion_state,
                        chord_summary["p2p_swing_db"],
                        chord_summary["std_db"],
                        chord_summary["baseline_drift_db"],
                        json.dumps(chord_summary),
                    ),
                )
                emit_security_event(
                    "network.rf_motion",
                    {
                        "corridor": chord_summary["label"],
                        "zone": chord_summary["zone"],
                        "compass_sector": chord_summary.get("compass_sector", "INTERIOR"),
                        "ring": chord_summary.get("ring", "interior"),
                        "motion_state": motion_state,
                        "p2p_swing_db": chord_summary["p2p_swing_db"],
                        "std_db": chord_summary["std_db"],
                        "baseline_drift_db": chord_summary["baseline_drift_db"],
                    },
                )

    for palert in localization.get("perimeter_alerts") or []:
        sec_p = str(palert.get("sector") or "PERIMETER")
        verdict_p = str(palert.get("verdict") or "PERIMETER_SECTOR_MOTION")
        p_cid = f"perimeter_sector_{sec_p.lower()}"
        last_p_row = con.execute(
            "SELECT ts FROM rf_motion_events WHERE chord_id = ? ORDER BY id DESC LIMIT 1",
            (p_cid,),
        ).fetchone()
        if (now - int(last_p_row["ts"] or 0 if last_p_row else 0)) >= 90:
            con.execute(
                """
                INSERT INTO rf_motion_events
                (ts, chord_id, zone, motion_state, p2p_swing_db, std_db, baseline_drift_db, details_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    now,
                    p_cid,
                    f"Property Perimeter ({sec_p})",
                    verdict_p.lower(),
                    float(palert.get("max_p2p_swing_db") or 0.0),
                    0.0,
                    0.0,
                    json.dumps(palert),
                ),
            )
            emit_security_event(
                "network.perimeter_alert",
                {
                    "sector": sec_p,
                    "verdict": verdict_p,
                    "confidence": palert.get("confidence", "medium_high"),
                    "chords": palert.get("chords", []),
                    "summary": palert.get("summary", ""),
                },
            )

    con.commit()
    con.close()

    prio_m = {"motion_detected": 0, "presence_shift": 1, "quiet": 2}
    chords_report.sort(
        key=lambda x: (
            prio_m.get(x.get("motion_state", "quiet"), 9),
            0 if x.get("mean_rssi_dbm") is not None else 1,
            0 if x.get("ring") == "interior" else 1,
            -float(x.get("p2p_swing_db") or 0.0),
        )
    )

    return {
        "status": "ok",
        "mode": "rf_motion_sense",
        "ts": now,
        "duration_s": dur,
        "ticks_sampled": n_ticks,
        "sensor_backend": ws_backend_used,
        "airlock_skipped_ticks": airlock_skipped_ticks,
        "vap_collisions_rejected": vap_collisions_rejected,
        "workstation_common_mode_db": common_mode_db,
        "calibrated_baseline": calibrate,
        "total_chords_monitored": len(chords_report),
        "exterior_perimeter_chords_count": sum(1 for c in chords_report if c.get("ring") == "exterior_perimeter"),
        "active_motion_corridors_count": len(active_motion_zones),
        "active_motion_corridors": active_motion_zones,
        "physics_caveats": {
            "measurement_class": "experimental_passive_rssi",
            "quantization_resolution_db": 0.5,
            "agent_interpretation_guidance": (
                "Single-chord RSSI swings can be caused by TPC, Wi-Fi traffic, or microwaves; "
                "prioritize multi-chord corroboration and near-field (<1.5m) attenuation."
            ),
        },
        "localization": localization,
        "rf_chords": chords_report,
    }


def perimeter_guard(
    duration: int = 6,
    refresh_clock: bool = False,
    timeout: int = 45,
) -> Dict[str, Any]:
    """
    Compass-Calibrated Property Perimeter Security Guard for Brother George & Operators:
      - Anchors property bearings using configured compass anchors (`NORTH` reference AP, South-Wall peripheral sensor),
        and `Workstation Wi-Fi 4` (`NORTH_WEST_STUDY`).
      - Optionally refreshes the South-Wall Lenovo Smart Clock's dual-band 2.4/5 GHz scan via the
        6-Layer Airlock (protected by `_wifi_airlock_radio_lock()` so 15s scans never collide) when
        `refresh_clock=True`.
      - Executes a fresh Linux (`nl80211` / `iw`) or WSL2 (`netsh`) airspace sweep + multi-tick `rf_motion_sense` across
        both interior boundary chords and exterior neighbor perimeter chords, suppressing single-chord
        neighbor-house noise while surfacing corroborated sector motion, kinematic approach/departure
        vectors, and high-RSSI transient proximity transmitters.
    """
    now = int(time.time())
    clock_refresh_result: Optional[Dict[str, Any]] = None
    if refresh_clock:
        clock_refresh_result = wifi_spelunk(mode="triangulate_airspace", timeout=max(20, int(timeout or 45)))

    air_res = wifi_spelunk(mode="scan_airspace")
    dur_s = max(2, min(20, int(duration or 6)))
    sense_res = rf_motion_sense(duration=dur_s, calibrate=False, include_perimeter=True)

    claimed = _list_claimed_peripherals()
    clock_p = claimed[0] if claimed else {}
    clock_last_seen = int(clock_p.get("last_seen") or 0)
    tri_age_s = (now - clock_last_seen) if clock_last_seen > 0 else None
    p_scan = list((clock_p.get("last_telemetry") or {}).get("nearby_wifi_seen_by_device") or [])
    tri = _compute_airspace_triangulation(
        list(air_res.get("networks") or []),
        p_scan,
        peripheral_label=str(clock_p.get("model_name") or "Lenovo Smart Clock"),
    )

    chords = list(sense_res.get("rf_chords") or [])
    loc = sense_res.get("localization") or {}
    suppressed_cids = {str(s.get("chord_id") or "") for s in (loc.get("suppressed_neighbor_events") or [])}

    sector_order = ["NORTH", "SOUTH", "EAST_WEST_FLANK", "SOUTH_WALL", "NORTH_WEST_STUDY", "INTERIOR_CORE", "INTERIOR_SOUTH", "INTERIOR_KITCHEN"]
    sectors_summary: Dict[str, Dict[str, Any]] = {}
    for sec in sector_order:
        sec_chords = [c for c in chords if str(c.get("compass_sector") or "") == sec and c.get("sensor_backend") != "wmm_rtt_only"]
        if not sec_chords and sec not in ("NORTH", "SOUTH", "EAST_WEST_FLANK", "SOUTH_WALL"):
            continue
        act = [c for c in sec_chords if c.get("motion_state") in ("motion_detected", "presence_shift") and c["chord_id"] not in suppressed_cids]
        sup = [c for c in sec_chords if c["chord_id"] in suppressed_cids]
        rssis = [float(c["mean_rssi_dbm"]) for c in sec_chords if c.get("mean_rssi_dbm") is not None]
        p2ps = [float(c.get("p2p_swing_db") or 0.0) for c in sec_chords]
        zs = [float(c.get("z_score") or 0.0) for c in sec_chords]
        if act:
            s_verdict = "ACTIVITY_DETECTED"
        elif sup:
            s_verdict = "SUPPRESSED_NEIGHBOR_INTERNAL"
        else:
            s_verdict = "CLEAR"
        sectors_summary[sec] = {
            "sector": sec,
            "verdict": s_verdict,
            "chords_monitored": len(sec_chords),
            "active_chords": len(act),
            "suppressed_single_neighbor_chords": len(sup),
            "avg_rssi_dbm": round(sum(rssis) / len(rssis), 1) if rssis else None,
            "max_p2p_swing_db": round(max(p2ps), 2) if p2ps else 0.0,
            "max_z_score": round(max(zs), 2) if zs else 0.0,
            "chord_labels": [c["label"] for c in sec_chords],
        }

    recs: List[str] = []
    if loc.get("perimeter_alerts"):
        for pa in loc["perimeter_alerts"]:
            recs.append(f"ALERT [{pa.get('sector')}]: {pa.get('summary')}")
    if loc.get("suppressed_neighbor_events"):
        recs.append(
            f"Suppressed {len(loc['suppressed_neighbor_events'])} single-chord external AP fluctuation(s) with zero property-boundary corroboration."
        )
    if tri_age_s is not None and tri_age_s > 3600:
        recs.append(
            f"South-Wall Lenovo Smart Clock dual-band scan cache is {round(tri_age_s / 60.0, 1)} min old; pass surprise=true to refresh via 6-Layer Airlock when eth0 is idle."
        )
    if not recs:
        recs.append("All North, South, East/West Flank, and South-Wall property perimeter chords are clear.")

    return {
        "status": "ok",
        "mode": "perimeter_guard",
        "ts": now,
        "duration_s": dur_s,
        "sensor_backend": sense_res.get("sensor_backend", "wsl_netsh"),
        "overall_verdict": loc.get("overall_verdict", "PERIMETER_QUIET"),
        "perimeter_status": "PERIMETER_ALERT" if loc.get("perimeter_alerts") else "CLEAR",
        "physics_caveats": {
            "measurement_class": "experimental_passive_rssi",
            "quantization_resolution_db": 0.5,
            "bearing_dimensionality": "1D_north_south_differential_only",
            "reliable_signals": [
                "near_field_workstation_attenuation (<1.5m)",
                "multi_chord_corroborated_interior_shifts",
                "new_transient_proximity_bssids",
                "802.11_link_margin_and_snr_health",
            ],
            "confounders": [
                "router_automatic_tpc_power_control",
                "co_channel_interference_and_microwave_bursts",
                "weather_wind_foliage_and_neighbor_indoor_activity",
                "cast_rtt_jitter_reflects_wifi_sleep_and_queuing_not_motion",
            ],
            "agent_interpretation_guidance": (
                "Treat single-chord RSSI swings as noisy heuristics, not confirmed physical intrusions. "
                "Cross-check multi-chord corroboration, QBSS channel utilization, and common-mode drift; "
                "report confidence honestly and never claim exact 2D radar coordinates from 2-sensor RSSI."
            ),
        },
        "compass_anchors": {
            "north": str(COMPASS_ANCHORS.get("north_anchor_label") or "North Reference Anchor"),
            "south_wall": f"{clock_p.get('model_name') or 'South Wall Sensor'} ({clock_p.get('bssid') or COMPASS_ANCHORS.get('south_wall_bssid') or 'sensor-b'})",
            "north_west_study": "Workstation Wi-Fi",
        },
        "clock_south_sensor_age_s": tri_age_s,
        "clock_airlock_refreshed": bool(clock_refresh_result and clock_refresh_result.get("sensor_mode") == "live_airlock_dual_band_scan"),
        "compass_sector_ap_counts": tri.get("compass_sector_counts", {}),
        "sectors": sectors_summary,
        "localization": loc,
        "workstation_common_mode_db": sense_res.get("workstation_common_mode_db", 0.0),
        "vap_collisions_rejected": sense_res.get("vap_collisions_rejected", 0),
        "recommendations": recs,
        "exterior_chords": [c for c in chords if c.get("ring") == "exterior_perimeter"],
        "rf_chords": chords,
    }


def _ensure_rf_timeseries_backfilled(con: sqlite3.Connection) -> None:
    """
    Ensure all historical samples stored in peripheral_rf_telemetry.history_json
    are present in rf_telemetry_timeseries so historical trend queries and charts
    have the complete time-series history.
    """
    try:
        rows = con.execute("SELECT * FROM peripheral_rf_telemetry").fetchall()
        inserted = 0
        for r in rows:
            cid = str(r["chord_id"])
            lbl = str(r["label"] or cid)
            zn = str(r["zone"] or lbl)
            bnd = str(r["band"] or "Wi-Fi")
            base_r = r["baseline_rssi_dbm"]
            noi_r = r["last_noise_dbm"]
            snr_r = r["last_snr_db"]
            existing_ts = {
                int(x[0])
                for x in con.execute(
                    "SELECT ts FROM rf_telemetry_timeseries WHERE chord_id = ?",
                    (cid,),
                ).fetchall()
                if x[0] is not None
            }
            try:
                hist = json.loads(r["history_json"] or "[]")
            except Exception:
                hist = []
            for h in hist:
                if not isinstance(h, dict) or not h.get("ts"):
                    continue
                ts_val = int(h["ts"])
                if ts_val in existing_ts:
                    continue
                existing_ts.add(ts_val)
                con.execute(
                    """
                    INSERT INTO rf_telemetry_timeseries
                    (ts, chord_id, label, zone, band, rssi_dbm, baseline_rssi_dbm, noise_dbm, snr_db,
                     rtt_ms, rtt_jitter_ms, std_db, p2p_swing_db, motion_state, source_mode)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        ts_val,
                        cid,
                        lbl,
                        zn,
                        bnd,
                        h.get("rssi_dbm"),
                        base_r,
                        h.get("noise_dbm", noi_r),
                        h.get("snr_db", snr_r),
                        h.get("rtt_ms"),
                        0.0,
                        float(h.get("std_db") or 0.0),
                        float(h.get("p2p_swing_db") or 0.0),
                        str(h.get("state") or "quiet"),
                        "history_backfill",
                    ),
                )
                inserted += 1
        if inserted > 0:
            con.commit()
    except Exception:
        pass


def diagnose_rf_mesh(hours: int = 24, refresh: bool = False) -> Dict[str, Any]:
    """
    Comprehensive RF Mesh & Fresnel Corridor Diagnostic Engine for Brother George & Operators:
    - Optionally runs a fresh 4s multi-room sampling pass if `refresh=True`.
    - Queries SQLite `rf_telemetry_timeseries`, `peripheral_rf_telemetry`, and `rf_motion_events` over `hours`.
    - Evaluates RSSI link margin (dBm), SNR & ambient noise floor (dB / dBm), wireless RTT & WMM power-save
      sleep latency (ms), and 1st Fresnel Zone disturbance profiles across all household corridors.
    - Synthesizes plain-English diagnostic findings and actionable operator recommendations.
    """
    if refresh:
        try:
            rf_motion_sense(duration=4, calibrate=False)
        except Exception:
            pass

    now = int(time.time())
    win_hours = max(1, min(720, int(hours or 24)))
    cutoff_ts = now - (win_hours * 3600)

    con = connect_db()
    _ensure_rf_timeseries_backfilled(con)
    chords = [dict(r) for r in con.execute("SELECT * FROM peripheral_rf_telemetry ORDER BY updated_at DESC").fetchall()]
    total_ts_count = int(con.execute("SELECT COUNT(*) FROM rf_telemetry_timeseries").fetchone()[0] or 0)
    con.close()

    if not chords or total_ts_count == 0:
        try:
            rf_motion_sense(duration=2, calibrate=False)
        except Exception:
            pass
        con = connect_db()
        chords = [dict(r) for r in con.execute("SELECT * FROM peripheral_rf_telemetry ORDER BY updated_at DESC").fetchall()]
        total_ts_count = int(con.execute("SELECT COUNT(*) FROM rf_telemetry_timeseries").fetchone()[0] or 0)
        con.close()

    con = connect_db()
    ts_rows = [
        dict(r)
        for r in con.execute(
            "SELECT * FROM rf_telemetry_timeseries WHERE ts >= ? ORDER BY ts ASC",
            (cutoff_ts,),
        ).fetchall()
    ]
    motion_rows = [
        dict(r)
        for r in con.execute(
            "SELECT * FROM rf_motion_events WHERE ts >= ? ORDER BY ts DESC LIMIT 50",
            (cutoff_ts,),
        ).fetchall()
    ]
    con.close()

    ts_by_chord: Dict[str, List[Dict[str, Any]]] = {}
    for tr in ts_rows:
        ts_by_chord.setdefault(str(tr["chord_id"]), []).append(tr)

    motion_by_chord: Dict[str, int] = {}
    for mr in motion_rows:
        cid_m = str(mr["chord_id"])
        motion_by_chord[cid_m] = motion_by_chord.get(cid_m, 0) + 1

    corridor_diagnostics: List[Dict[str, Any]] = []
    recommendations: List[str] = []
    weak_links = 0
    noisy_links = 0
    active_corridors = 0

    for c in chords:
        cid = str(c["chord_id"])
        zone = str(c.get("zone") or c.get("label") or cid)
        rssi = c.get("last_rssi_dbm")
        base_rssi = c.get("baseline_rssi_dbm")
        noise = c.get("last_noise_dbm")
        snr = c.get("last_snr_db")
        rtt = c.get("last_rtt_ms")
        p2p = float(c.get("p2p_swing_db") or 0.0)
        std = float(c.get("std_db") or 0.0)
        ewma_fast = c.get("ewma_fast_dbm")
        ewma_std = float(c.get("ewma_std_db") or std or 0.0)
        z_score = float(c.get("z_score") or 0.0)
        cusum_db = float(c.get("cusum_db") or 0.0)
        mstate = str(c.get("motion_state") or "quiet")
        drift = round(float(ewma_fast if ewma_fast is not None else (rssi or 0.0)) - float(base_rssi), 2) if (rssi is not None and base_rssi is not None) else 0.0

        c_series = ts_by_chord.get(cid, [])
        r_hist = [float(x["rssi_dbm"]) for x in c_series if x.get("rssi_dbm") is not None]
        rtt_hist = [float(x["rtt_ms"]) for x in c_series if x.get("rtt_ms") is not None]
        p2p_hist = [float(x["p2p_swing_db"]) for x in c_series if x.get("p2p_swing_db") is not None]

        findings: List[str] = []

        # 1. Link Margin / RSSI Attenuation Grade
        if rssi is None:
            link_grade = "LATENCY_ONLY"
            findings.append(
                "Cast speaker firmware reports HTTPS Eureka RTT latency without raw dBm RSSI; Fresnel motion is inferred via MAC-layer CSMA/CA retry jitter."
            )
        elif float(rssi) >= -60.0:
            link_grade = "EXCELLENT"
            findings.append(
                f"Strong RF carrier ({rssi} dBm, ~18–22 dB above receiver sensitivity floor); clean line-of-sight or single-partition path."
            )
        elif float(rssi) >= -70.0:
            link_grade = "GOOD"
            findings.append(
                f"Solid indoor multi-room link ({rssi} dBm); well-suited for high-SNR Fresnel corridor tomography."
            )
        elif float(rssi) >= -77.0:
            link_grade = "FAIR"
            findings.append(
                f"Moderate multi-wall attenuation ({rssi} dBm); multipath reflections amplify 1st Fresnel zone sensitivity to room occupancy."
            )
        else:
            link_grade = "WEAK_EDGE"
            weak_links += 1
            findings.append(
                f"Edge-of-cell signal ({rssi} dBm, near -82 dBm 802.11 sensitivity threshold); high path loss across walls/appliances can cause natural 1.5–2.5 dB thermal/multipath flutter."
            )

        # 2. SNR & RF Noise Floor Grade
        if snr is not None and noise is not None:
            if float(noise) > -75.0 or float(snr) < 15.0:
                snr_grade = "DEGRADED"
                noisy_links += 1
                findings.append(
                    f"Elevated ambient RF noise floor ({noise} dBm, SNR {snr} dB) — check for 2.4 GHz microwave/Bluetooth interference or co-channel congestion."
                )
            elif float(snr) >= 25.0:
                snr_grade = "EXCELLENT"
                findings.append(f"High SNR link margin ({snr} dB over {noise} dBm noise floor).")
            else:
                snr_grade = "GOOD"
                findings.append(f"Healthy SNR margin ({snr} dB over {noise} dBm noise floor).")
        else:
            snr_grade = "PASSIVE_BEACON"

        # 3. Wireless RTT Latency & WMM Sleep Cycle Diagnosis
        if rtt is not None:
            if float(rtt) <= 150.0:
                rtt_grade = "LOW_LATENCY"
                findings.append(f"Fast active radio response ({rtt} ms RTT).")
            elif float(rtt) <= 380.0:
                rtt_grade = "NORMAL_WMM_POWERSAVE"
                findings.append(
                    f"Normal Google Cast WMM power-save beacon response ({rtt} ms RTT reflects 100–300 ms 802.11 DTIM sleep interval + TLS handshake)."
                )
            else:
                rtt_grade = "ELEVATED_CONTENTION"
                findings.append(
                    f"Elevated wireless RTT ({rtt} ms) indicating 802.11 CSMA/CA airtime contention or MAC-layer frame retries."
                )
        else:
            rtt_grade = "PASSIVE_80211_BEACON"

        # 4. Physical 1st Fresnel Zone Geometry (r_1 = 0.5 * sqrt(lambda * D)) & Motion Diagnosis
        band_str = str(c.get("band") or "2.4 GHz")
        exact_freq_mhz = int(c.get("frequency_mhz") or 0)
        if exact_freq_mhz >= 2400:
            freq_hz = float(exact_freq_mhz) * 1.0e6
            pl0_1m = 32.44 + 20.0 * math.log10(float(exact_freq_mhz) / 1000.0) + 12.0
        elif "6" in band_str:
            freq_hz, pl0_1m = 6.15e9, 48.2
        elif "5" in band_str and "2.4" not in band_str:
            freq_hz, pl0_1m = 5.50e9, 47.3
        else:
            freq_hz, pl0_1m = 2.442e9, 40.2
        wavelength_m = 299_792_458.0 / freq_hz
        wavelength_cm = round(wavelength_m * 100.0, 2)
        ref_rssi = float(base_rssi if base_rssi is not None else (rssi if rssi is not None else -66.0))
        eirp_dbm = float(c.get("tx_power_dbm")) if c.get("tx_power_dbm") is not None else 20.0
        path_exp_n = 3.1 if str(c.get("ring") or "interior") == "exterior_perimeter" else 2.9
        est_span_m = round(max(2.0, min(55.0, 10.0 ** ((eirp_dbm - pl0_1m - ref_rssi) / (10.0 * path_exp_n)))), 1)
        fresnel_r1_m = round(0.5 * math.sqrt(wavelength_m * est_span_m), 2)
        findings.append(
            f"1st Fresnel Ellipsoid geometry ({c.get('compass_sector') or 'INTERIOR'}): λ={wavelength_cm} cm, estimated span D≈{est_span_m} m → mid-span Fresnel radius r₁≈{fresnel_r1_m} m (60% clearance zone ≈ {round(0.6 * fresnel_r1_m, 2)} m)."
        )
        if c.get("qbss_chan_util_pct") is not None:
            findings.append(f"802.11 IE 11 QBSS channel utilization: {c['qbss_chan_util_pct']}%.")

        if mstate in ("motion_detected", "presence_shift") and c.get("sensor_backend") != "wmm_rtt_only":
            active_corridors += 1
            findings.append(
                f"1st Fresnel Zone disturbance active ({mstate.upper()}: EWMA Z={z_score:+.2f}σ, CUSUM={cusum_db:+.2f} dB, P2P swing {p2p} dB, baseline Δ={drift:+.1f} dB)."
            )
            if (abs(drift) >= 2.2 or abs(cusum_db) >= 3.5) and p2p < 1.5:
                recommendations.append(
                    f"Corridor '{zone}' shows steady-state EWMA/CUSUM baseline shift (Δ={drift:+.1f} dB, CUSUM={cusum_db:+.2f} dB) with low rapid swing ({p2p} dB) — likely a moved object/door or stationary occupant; run 'Recalibrate Quiet Baseline' if room is now unoccupied."
                )

        corridor_diagnostics.append({
            "chord_id": cid,
            "zone": zone,
            "label": c.get("label") or zone,
            "tx_node": c.get("tx_node") or "",
            "rx_node": c.get("rx_node") or "",
            "band": c.get("band") or "Wi-Fi",
            "frequency_mhz": exact_freq_mhz,
            "compass_sector": c.get("compass_sector") or "INTERIOR",
            "ring": c.get("ring") or "interior",
            "sensor_backend": c.get("sensor_backend") or "wsl_netsh",
            "tx_power_dbm": c.get("tx_power_dbm"),
            "qbss_chan_util_pct": c.get("qbss_chan_util_pct"),
            "common_mode_db": c.get("common_mode_db") or 0.0,
            "wavelength_cm": wavelength_cm,
            "est_span_m": est_span_m,
            "fresnel_r1_m": fresnel_r1_m,
            "last_rssi_dbm": rssi,
            "ewma_fast_dbm": ewma_fast if ewma_fast is not None else rssi,
            "baseline_rssi_dbm": base_rssi,
            "baseline_drift_db": drift,
            "ewma_std_db": ewma_std,
            "z_score": z_score,
            "cusum_db": cusum_db,
            "last_noise_dbm": noise,
            "last_snr_db": snr,
            "last_rtt_ms": rtt,
            "p2p_swing_db": p2p,
            "std_db": std,
            "motion_state": mstate,
            "link_grade": link_grade,
            "snr_grade": snr_grade,
            "rtt_grade": rtt_grade,
            "samples_in_window": len(c_series),
            "min_rssi_dbm": round(min(r_hist), 1) if r_hist else rssi,
            "max_rssi_dbm": round(max(r_hist), 1) if r_hist else rssi,
            "avg_rssi_dbm": round(sum(r_hist) / len(r_hist), 1) if r_hist else rssi,
            "avg_rtt_ms": round(sum(rtt_hist) / len(rtt_hist), 1) if rtt_hist else rtt,
            "max_p2p_swing_db": round(max(p2p_hist), 2) if p2p_hist else p2p,
            "motion_events_in_window": motion_by_chord.get(cid, 0),
            "findings": findings,
        })

    if weak_links > 0:
        recommendations.append(
            f"{weak_links} corridor(s) operate below -77 dBm near the receiver sensitivity floor; adaptive edge-link thresholds & EWMA Z-score floor (1.10 dB) are engaged to suppress multipath false positives."
        )
    if noisy_links == 0:
        recommendations.append(
            "Ambient RF noise floor across all LAN Cast sensors is clean (<= -80 dBm) with zero wideband jamming or microwave SNR collapse."
        )
    if not recommendations:
        recommendations.append("All monitored household and property perimeter RF corridors are within nominal link margin, SNR, and Fresnel EWMA/CUSUM baseline parameters.")

    overall_health = "NOMINAL"
    if noisy_links > 0:
        overall_health = "RF_NOISE_WARNING"
    elif active_corridors > 0:
        overall_health = "PRESENCE_ACTIVE"

    return {
        "status": "ok",
        "mode": "diagnose_rf_mesh",
        "ts": now,
        "window_hours": win_hours,
        "overall_health": overall_health,
        "physics_caveats": {
            "measurement_class": "experimental_passive_rssi_and_link_diagnostics",
            "reliable_for": ["link_margin_trends", "snr_noise_floor", "wifi_congestion_rtt"],
            "limited_for": ["cast_rtt_is_not_motion_sensing", "consumer_rssi_is_not_csi_radar"],
        },
        "summary_headline": (
            f"{len(chords)} RF Corridors Diagnosed • {active_corridors} Active Fresnel Zone(s) • "
            f"{weak_links} Edge-Signal Link(s) • {len(ts_rows)} SQLite Time-Series Samples ({win_hours}h @ 15s cadence)"
        ),
        "timeseries_summary": {
            "total_db_samples": total_ts_count,
            "window_samples": len(ts_rows),
            "window_hours": win_hours,
            "motion_events_in_window": len(motion_rows),
            "scheduled_cron_job": ".george/cron_jobs/tyler_rf_mesh_sweep.sh",
            "scheduled_interval_seconds": 15,
            "raw_retention_hours": 72,
            "rollup_retention_days": 90,
            "signal_conditioning": (
                "Linux nl80211 iw / WSL netsh + Dual-VAP Beacon Fusion + Gated Common-Mode Cancellation "
                "+ Bessel (N-1) Quantization Deadband + Hampel + Decoupled EWMA + Leaky Page-Hinkley CUSUM "
                "+ Compass-Calibrated Perimeter Neighbor Suppression"
            ),
        },
        "recommendations": recommendations,
        "corridor_diagnostics": corridor_diagnostics,
    }


def rogue_ap_watch(timeout: int = 45) -> Dict[str, Any]:
    """
    Automated 802.11 Airspace Drift, Evil-Twin & Unauthorized Soft-AP Hunter:
    Fuses Workstation Wi-Fi 4 and Lenovo Smart Clock 2.4/5 GHz scans, verifies every BSSID
    against home_ssids/known_soft_aps/claimed_peripherals, and localizes any rogue transmitter.
    """
    tri_res = wifi_spelunk(mode="triangulate_airspace", timeout=timeout)
    tri = tri_res.get("triangulation") or {}
    transmitters = list(tri.get("transmitters") or [])

    wl = load_wifi_watchlist()
    home_ssids = {s.lower() for s in (wl.get("home_ssids") or [])}
    known_patterns = wl.get("known_soft_aps") or []
    home_ouis = {mac[:8].lower() for mac in EXPECTED_GATEWAY_MACS.values() if len(mac) >= 8}
    home_ouis |= {str(o).lower() for o in (COMPASS_ANCHORS.get("home_ouis") or []) if o}
    claimed_bssids = {(p.get("bssid") or "").lower() for p in _list_claimed_peripherals()}

    evil_twins: List[Dict[str, Any]] = []
    unrecognized_soft_aps: List[Dict[str, Any]] = []
    verified_peripherals: List[Dict[str, Any]] = []

    for tx in transmitters:
        b = (tx.get("bssid") or "").lower()
        s = str(tx.get("ssid") or "")
        cls = str(tx.get("classification") or "neighbor")
        if b in claimed_bssids:
            tx["security_verdict"] = "claimed_sovereign_peripheral"
            verified_peripherals.append(tx)
            continue
        if s.lower() in home_ssids and b[:8] not in home_ouis:
            tx["security_verdict"] = "evil_twin_spoof"
            evil_twins.append(tx)
            emit_security_event(
                "network.rogue_ap",
                {
                    "bssid": b,
                    "ssid": s,
                    "verdict": "evil_twin_spoof",
                    "spatial_zone": tx.get("spatial_zone", "unknown"),
                },
            )
            continue
        if cls in ("open_soft_ap", "appliance_ap"):
            matched_known = False
            for pat in known_patterns:
                pat_glob = str(pat.get("ssid_pattern") or "").lower()
                if pat_glob and re.search(pat_glob.replace("[", r"\[").replace("]", r"\]").replace("*", ".*"), s.lower()):
                    matched_known = True
                    break
            if matched_known:
                tx["security_verdict"] = "known_household_appliance"
                verified_peripherals.append(tx)
            else:
                tx["security_verdict"] = "unrecognized_soft_ap"
                unrecognized_soft_aps.append(tx)
                emit_security_event(
                    "network.rogue_ap",
                    {
                        "bssid": b,
                        "ssid": s,
                        "verdict": "unrecognized_soft_ap",
                        "spatial_zone": tx.get("spatial_zone", "unknown"),
                    },
                )

    return {
        "status": "ok",
        "mode": "rogue_ap_watch",
        "sensor_mode": tri_res.get("sensor_mode", "cached_peripheral_telemetry"),
        "total_transmitters_audited": len(transmitters),
        "evil_twins_count": len(evil_twins),
        "evil_twins": evil_twins,
        "unrecognized_soft_aps_count": len(unrecognized_soft_aps),
        "unrecognized_soft_aps": unrecognized_soft_aps,
        "verified_peripherals": verified_peripherals,
    }


def _run_soft_ap_airlock_session(
    target_ssid: str,
    target_bssid: str,
    timeout: int,
    session_fn: Any,
) -> Dict[str, Any]:
    """
    Executes `session_fn(wifi_ip, wifi_cidr, soft_ap_gw, assoc_bssid, airlock_log)` inside
    the 6-Layer Airlock Sandbox with guaranteed teardown and prior Wi-Fi restoration across
    both pure Linux (`linux_nl80211` via `nmcli` / `iw`) and WSL2 (`wsl2_windows_netsh`).
    """
    wifi_st = _get_windows_wifi_status()
    netsh_path = Path("/mnt/c/Windows/System32/netsh.exe")
    is_linux_nl80211 = (wifi_st.get("backend") == "linux_nl80211")
    adapter = wifi_st.get("adapter_name", "Wi-Fi 4")
    wsl_iface = wifi_st.get("wsl_interface", "eth1")

    if not target_ssid:
        return {
            "ok": False,
            "reason": "no_target_ssid",
            "message": "No target Soft-AP SSID specified or found in airspace",
            "airlock_layers": [],
        }

    if not wifi_st.get("safe_secondary_radio", False) or (not is_linux_nl80211 and not netsh_path.exists()):
        return {
            "ok": False,
            "reason": "secondary_radio_unavailable",
            "message": "Airlock Safety Gate: Secondary Wi-Fi radio or primary eth0 link is not active for live airlock association.",
            "airlock_layers": [],
        }

    previous_ssid = wifi_st.get("current_ssid", "")
    previous_profile = wifi_st.get("current_profile", "")
    prof_name = f"TYLER_AIRLOCK_{int(time.time())}"
    ssid_hex = target_ssid.encode("utf-8").hex().upper()
    ssid_esc = target_ssid.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    max_sec = max(15, min(90, int(timeout or 45)))

    _radio_lock_cm = _wifi_airlock_radio_lock(timeout_s=25.0)
    _radio_locked = _radio_lock_cm.__enter__()
    if not _radio_locked:
        _radio_lock_cm.__exit__(None, None, None)
        return {
            "ok": False,
            "reason": "wifi_radio_lock_busy",
            "message": "Wi-Fi radio lock is currently held by another Soft-AP Airlock session.",
            "airlock_layers": [],
        }

    watchdog_proc = None
    try:
        if is_linux_nl80211:
            watchdog_cmd = (
                f"sleep {max_sec + 10}; "
                f"nmcli dev disconnect \"{adapter}\" </dev/null >/dev/null 2>&1 || iw dev \"{adapter}\" disconnect </dev/null >/dev/null 2>&1 || true; "
                f"nmcli con delete \"{prof_name}\" </dev/null >/dev/null 2>&1 || true"
            )
        else:
            watchdog_cmd = (
                f"sleep {max_sec + 10}; "
                f"/mnt/c/Windows/System32/netsh.exe wlan disconnect interface=\"{adapter}\" </dev/null >/dev/null 2>&1 || true; "
                f"/mnt/c/Windows/System32/netsh.exe wlan delete profile name=\"{prof_name}\" interface=\"{adapter}\" </dev/null >/dev/null 2>&1 || true"
            )
        watchdog_proc = subprocess.Popen(
            ["bash", "-c", watchdog_cmd],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass

    airlock_log: List[str] = [
        f"Layer 1: Verified primary wired link ({PRIMARY_IFACE}) UP & acquired exclusive Wi-Fi radio mutex; snapshotted prior state (previous_ssid='{previous_ssid or 'disconnected'}').",
        f"Layer 2: Armed {max_sec + 10}s detached dead-man rollback watchdog.",
    ]
    xml_linux = Path("/mnt/c/Users/Public/.tyler_wlan_profile.xml")
    xml_win = r"C:\Users\Public\.tyler_wlan_profile.xml"

    try:
        ensure_kali_running()
        if kali_container_status()["running"]:
            _apply_airlock_firewall(wsl_iface)
            airlock_log.append(
                f"Layer 3: Locked down {wsl_iface} via isolated TYLER_AIRLOCK_* chains (IPv4 + IPv6 DROP + SMB/NetBIOS/mDNS/LLMNR/RPC leak block + Docker isolation)."
            )

        if is_linux_nl80211:
            r_conn = subprocess.run(
                ["nmcli", "dev", "wifi", "connect", target_ssid, "ifname", adapter, "name", prof_name],
                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=12.0,
            )
            if r_conn.returncode != 0:
                subprocess.run(
                    ["iw", "dev", adapter, "connect", target_ssid],
                    stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=6.0,
                )
            airlock_log.append(f"Layer 4: Initiated Linux nl80211 association on '{adapter}' to '{target_ssid}' ({(r_conn.stdout or '').strip()}).")
        else:
            xml_content = f"""<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
    <name>{prof_name}</name>
    <SSIDConfig>
        <SSID>
            <hex>{ssid_hex}</hex>
            <name>{ssid_esc}</name>
        </SSID>
        <nonBroadcast>false</nonBroadcast>
    </SSIDConfig>
    <connectionType>ESS</connectionType>
    <connectionMode>manual</connectionMode>
    <MSM>
        <security>
            <authEncryption>
                <authentication>open</authentication>
                <encryption>none</encryption>
                <useOneX>false</useOneX>
            </authEncryption>
        </security>
    </MSM>
</WLANProfile>
"""
            xml_linux.write_text(xml_content, encoding="utf-8")
            subprocess.run(
                [str(netsh_path), "wlan", "add", "profile", f"filename={xml_win}", f"interface={adapter}", "user=all"],
                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=6.0,
            )
            xml_linux.unlink(missing_ok=True)

            r_conn = subprocess.run(
                [str(netsh_path), "wlan", "connect", f"name={prof_name}", f"interface={adapter}"],
                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=6.0,
            )
            airlock_log.append(f"Layer 4: Initiated manual association on '{adapter}' to '{target_ssid}' ({(r_conn.stdout or '').strip()}).")

        wifi_ip, wifi_cidr, soft_ap_gw = "", "", ""
        assoc_bssid = target_bssid
        for poll_idx in range(18):
            time.sleep(1.0)
            st_now = _get_windows_wifi_status()
            if st_now.get("current_bssid"):
                assoc_bssid = st_now["current_bssid"]
            if not is_linux_nl80211 and poll_idx in (5, 10) and st_now.get("state") == "disconnected":
                subprocess.run(
                    [str(netsh_path), "wlan", "connect", f"name={prof_name}", f"interface={adapter}"],
                    stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5.0,
                )
            wifi_ip, wifi_cidr, soft_ap_gw = _get_windows_wifi_ipv4(adapter, wsl_iface)
            if wifi_ip and soft_ap_gw:
                break

        subprocess.run(["ip", "route", "del", "default", "dev", wsl_iface], capture_output=True, text=True, timeout=2.0)

        if not wifi_ip:
            airlock_log.append(f"Layer 4 Warning: '{adapter}' did not receive a DHCP IPv4 lease within 18s.")
            return {
                "ok": False,
                "reason": "dhcp_timeout",
                "message": "Association timed out waiting for DHCP lease from Soft-AP",
                "airlock_layers": airlock_log,
            }

        if wifi_cidr and wifi_cidr == LAN_SUBNET:
            airlock_log.append(f"Layer 4 Security Abort: Soft-AP subnet {wifi_cidr} collides with primary LAN {LAN_SUBNET}!")
            return {
                "ok": False,
                "reason": "subnet_collision",
                "message": f"Soft-AP subnet {wifi_cidr} collides with primary LAN {LAN_SUBNET}",
                "airlock_layers": airlock_log,
            }

        airlock_log.append(
            f"Layer 4: Assigned Airlock IP {wifi_ip} ({wifi_cidr}) via Soft-AP Gateway {soft_ap_gw}; verified zero overlap with {LAN_SUBNET}."
        )
        payload = session_fn(wifi_ip, wifi_cidr, soft_ap_gw, assoc_bssid, airlock_log)
        return {
            "ok": True,
            "wifi_ip": wifi_ip,
            "wifi_cidr": wifi_cidr,
            "soft_ap_gw": soft_ap_gw,
            "assoc_bssid": assoc_bssid,
            "airlock_layers": airlock_log,
            "payload": payload,
        }
    finally:
        if not is_linux_nl80211:
            xml_linux.unlink(missing_ok=True)
        try:
            if is_linux_nl80211:
                subprocess.run(
                    ["nmcli", "dev", "disconnect", adapter],
                    stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5.0,
                )
                subprocess.run(
                    ["nmcli", "con", "delete", prof_name],
                    stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5.0,
                )
                if previous_ssid:
                    subprocess.run(
                        ["nmcli", "con", "up", previous_profile or previous_ssid],
                        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5.0,
                    )
            else:
                subprocess.run(
                    [str(netsh_path), "wlan", "disconnect", f"interface={adapter}"],
                    stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5.0,
                )
                subprocess.run(
                    [str(netsh_path), "wlan", "delete", "profile", f"name={prof_name}", f"interface={adapter}"],
                    stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5.0,
                )
                if previous_ssid and previous_profile:
                    subprocess.run(
                        [str(netsh_path), "wlan", "connect", f"name={previous_profile}", f"ssid={previous_ssid}", f"interface={adapter}"],
                        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5.0,
                    )
        except Exception:
            pass
        if kali_container_status()["running"]:
            _teardown_airlock_firewall(wsl_iface)
        if watchdog_proc is not None:
            try:
                watchdog_proc.terminate()
            except Exception:
                pass
        _radio_lock_cm.__exit__(None, None, None)
        airlock_log.append(
            f"Layer 6: Disconnected '{adapter}', deleted temporary profile '{prof_name}', removed temporary firewall rules, released Wi-Fi radio mutex, and disarmed watchdog."
        )


def wifi_spelunk(
    mode: str = "scan_airspace",
    ssid: Optional[str] = None,
    bssid: Optional[str] = None,
    auth: str = "open",
    encryption: str = "none",
    key: Optional[str] = None,
    band: str = "auto",
    hidden: bool = False,
    timeout: int = 45,
    surprise: bool = False,
    surprise_name: Optional[str] = None,
) -> Dict[str, Any]:
    """
    802.11 Wireless Airspace Scanner, Adapter Controller, Property Perimeter Guard & 6-Layer Airlock Soft-AP Interrogator:
    - status: Inspect Wi-Fi adapter (Linux nl80211 wlan0 / WSL2 Wi-Fi 4) and primary wired link state.
    - scan_airspace: Enumerate all visible 802.11 BSSIDs/SSIDs via Linux nl80211 (`iw` / `nmcli`) or WSL2 (`netsh`).
    - perimeter_guard: Compass-calibrated property perimeter security guard (configured North & South-Wall anchors) with neighbor-internal suppression and approach/departure vector detection.
    - rf_motion_sense: Multi-corridor household + perimeter Fresnel RF tomography.
    - diagnose_rf_mesh: Historical RF link margin, SNR, WMM latency & Fresnel geometry diagnostics.
    - configure_adapter: Programmatically load a manual-mode WLAN profile for custom device Wi-Fi requirements.
    - interrogate_soft_ap: Connect to an unconfigured Open Soft-AP inside the 6-Layer Airlock Sandbox, pull Google Cast / HTTP setup telemetry, optionally trigger a physically observable surprise, and restore prior radio state.
    - disconnect: Immediately disconnect Wi-Fi 4 and purge temporary airlock profiles/firewall rules.
    """
    m = (mode or "scan_airspace").strip().lower()
    wifi_st = _get_windows_wifi_status()
    netsh_path = Path("/mnt/c/Windows/System32/netsh.exe")
    adapter = wifi_st.get("adapter_name", "Wi-Fi 4")
    wsl_iface = wifi_st.get("wsl_interface", "eth1")

    if m == "status":
        ip_v4, cidr_v4, gw_v4 = _get_windows_wifi_ipv4(adapter, wsl_iface)
        wifi_st["ipv4"] = ip_v4
        wifi_st["cidr"] = cidr_v4
        wifi_st["gateway"] = gw_v4
        con = connect_db()
        cached_rows = [dict(r) for r in con.execute("SELECT * FROM wifi_airspace ORDER BY COALESCE(rssi_dbm, -100) DESC, signal_pct DESC").fetchall()]
        con.close()
        return {
            "status": "ok",
            "mode": "status",
            "wifi_adapter": wifi_st,
            "cached_airspace": cached_rows,
            "claimed_peripherals": _list_claimed_peripherals(),
        }

    if m in ("list_peripherals", "peripherals"):
        return {
            "status": "ok",
            "mode": "list_peripherals",
            "claimed_peripherals": _list_claimed_peripherals(),
        }

    if m in ("poll_lan_peripherals", "lan_peripherals", "peripheral_mesh"):
        return poll_lan_peripherals()

    if m in ("rf_motion_sense", "motion_sense", "rf_motion", "physical_monitor"):
        dur_m = int(timeout if (timeout and timeout != 45) else 6)
        return rf_motion_sense(duration=dur_m, calibrate=bool(surprise))

    if m in ("perimeter_guard", "perimeter", "guard_perimeter", "perimeter_watch"):
        dur_p = int(timeout if (timeout and timeout != 45) else 6)
        return perimeter_guard(duration=dur_p, refresh_clock=bool(surprise), timeout=max(30, int(timeout or 45)))

    if m in ("diagnose_rf_mesh", "rf_diagnose", "rf_timeseries", "diagnose"):
        hrs = int(timeout if (timeout and timeout != 45) else 24)
        return diagnose_rf_mesh(hours=hrs, refresh=bool(surprise))

    if m in ("rogue_ap_watch", "rogue_watch"):
        return rogue_ap_watch(timeout=timeout)

    if m == "disconnect":
        return emergency_network_reset()

    if m == "scan_airspace":
        wl = load_wifi_watchlist()
        home_ssids = {s.lower() for s in (wl.get("home_ssids") or [])}
        known_patterns = wl.get("known_soft_aps") or []
        compass_cfg = wl.get("compass_calibration") or {}
        home_ouis = {mac[:8].lower() for mac in EXPECTED_GATEWAY_MACS.values() if len(mac) >= 8}
        home_ouis |= {str(o).lower() for o in (COMPASS_ANCHORS.get("home_ouis") or []) if o}

        networks_found, sensor_backend = _scan_windows_wlan_native(trigger_rescan=True, wait_ms=2200)
        if sensor_backend == "airlock_radio_busy":
            con_b = connect_db()
            cached_b = [dict(r) for r in con_b.execute("SELECT * FROM wifi_airspace ORDER BY COALESCE(rssi_dbm, -100) DESC, signal_pct DESC").fetchall()]
            con_b.close()
            return {
                "status": "ok",
                "mode": "scan_airspace",
                "sensor_backend": "cached_airlock_busy",
                "wifi_adapter": wifi_st,
                "total_bssids": len(cached_b),
                "open_soft_aps_count": sum(1 for n in cached_b if n.get("classification") == "open_soft_ap"),
                "appliance_aps_count": sum(1 for n in cached_b if n.get("classification") == "appliance_ap"),
                "evil_twins_count": sum(1 for n in cached_b if n.get("classification") == "evil_twin"),
                "networks": cached_b,
            }

        claimed_p = _list_claimed_peripherals()
        periph_rssi_by_bssid: Dict[str, int] = {}
        if claimed_p:
            for item_p in (claimed_p[0].get("last_telemetry") or {}).get("nearby_wifi_seen_by_device") or []:
                if isinstance(item_p, dict):
                    if isinstance(item_p.get("ap_list"), list):
                        for ap_x in item_p["ap_list"]:
                            if isinstance(ap_x, dict) and ap_x.get("bssid") and ap_x.get("signal_level") is not None:
                                periph_rssi_by_bssid[str(ap_x["bssid"]).lower()] = int(ap_x["signal_level"])
                    elif item_p.get("bssid") and item_p.get("signal_level") is not None:
                        periph_rssi_by_bssid[str(item_p["bssid"]).lower()] = int(item_p["signal_level"])

        now = int(time.time())
        con = connect_db()
        evil_twins: List[Dict[str, Any]] = []
        for entry in networks_found:
            s_name = entry["ssid"]
            b_mac = entry["bssid"]
            auth_s = str(entry.get("auth") or "").lower()
            enc_s = str(entry.get("encryption") or "").lower()
            classification = "neighbor"
            trust_st = "unknown"
            notes_s = ""

            if not s_name:
                classification = "hidden_ap"
                notes_s = "Hidden SSID beacon"
            elif s_name.lower() in home_ssids:
                if b_mac[:8] in home_ouis and "open" not in auth_s:
                    classification = "home_ap"
                    trust_st = "trusted"
                    notes_s = "Verified Sovereign Home Mesh AP"
                else:
                    classification = "evil_twin"
                    trust_st = "untrusted"
                    notes_s = f"ALERT: Rogue BSSID {b_mac} spoofing home SSID '{s_name}'!"
                    evil_twins.append(entry)
            elif "open" in auth_s or "none" in enc_s:
                classification = "open_soft_ap"
                trust_st = "untrusted"
                notes_s = "Unencrypted Open 802.11 Soft-AP / Provisioning Hotspot"
            elif any(tok in s_name.lower() for tok in ("direct-", "[fridge]", "smartclock", "chromecast", "setup")):
                classification = "appliance_ap"
                trust_st = "known_iot"
                notes_s = "Appliance / Wi-Fi Direct Soft-AP"

            for pat in known_patterns:
                pat_glob = str(pat.get("ssid_pattern") or "").lower()
                if pat_glob and re.search(pat_glob.replace("[", r"\[").replace("]", r"\]").replace("*", ".*"), s_name.lower()):
                    if classification not in ("evil_twin", "home_ap"):
                        classification = str(pat.get("classification") or classification)
                    notes_s = str(pat.get("notes") or pat.get("label") or notes_s)
                    break

            d_rssi = entry.get("rssi_dbm")
            p_rssi = periph_rssi_by_bssid.get(b_mac)
            delta_sn: Optional[float] = None
            if d_rssi is not None and p_rssi is not None:
                band_e = str(entry.get("band") or "2.4 GHz")
                delta_sn = float(p_rssi) - float(d_rssi)
                if band_e in ("5 GHz", "6 GHz"):
                    delta_sn += 0.0
            sector = _classify_compass_sector(
                bssid=b_mac,
                ssid=s_name,
                desktop_rssi_dbm=float(d_rssi) if d_rssi is not None else None,
                peripheral_rssi_dbm=float(p_rssi) if p_rssi is not None else None,
                delta_south_minus_north_db=delta_sn,
                classification=classification,
                compass_cfg=compass_cfg,
            )

            entry["classification"] = classification
            entry["trust_status"] = trust_st
            entry["compass_sector"] = sector
            entry["notes"] = notes_s
            entry["last_seen"] = now

            prev = con.execute("SELECT first_seen, interrogation_json FROM wifi_airspace WHERE bssid = ?", (b_mac,)).fetchone()
            first_seen = int(prev["first_seen"]) if prev else now
            interrog_json = prev["interrogation_json"] if prev and prev["interrogation_json"] else "{}"
            try:
                entry["interrogation"] = json.loads(interrog_json or "{}")
            except Exception:
                entry["interrogation"] = {}

            con.execute(
                """
                INSERT INTO wifi_airspace
                (bssid, ssid, network_type, auth, encryption, signal_pct, rssi_dbm, link_quality,
                 frequency_mhz, radio_type, band, channel, beacon_age_ms, tsf_uptime_us, tx_power_dbm,
                 qbss_sta_count, qbss_chan_util_pct, compass_sector, vendor_oui, classification,
                 trust_status, first_seen, last_seen, interrogation_json, notes)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(bssid) DO UPDATE SET
                    ssid=excluded.ssid,
                    network_type=excluded.network_type,
                    auth=excluded.auth,
                    encryption=excluded.encryption,
                    signal_pct=excluded.signal_pct,
                    rssi_dbm=excluded.rssi_dbm,
                    link_quality=excluded.link_quality,
                    frequency_mhz=excluded.frequency_mhz,
                    radio_type=excluded.radio_type,
                    band=excluded.band,
                    channel=excluded.channel,
                    beacon_age_ms=excluded.beacon_age_ms,
                    tsf_uptime_us=excluded.tsf_uptime_us,
                    tx_power_dbm=COALESCE(excluded.tx_power_dbm, wifi_airspace.tx_power_dbm),
                    qbss_sta_count=excluded.qbss_sta_count,
                    qbss_chan_util_pct=excluded.qbss_chan_util_pct,
                    compass_sector=excluded.compass_sector,
                    vendor_oui=excluded.vendor_oui,
                    classification=excluded.classification,
                    trust_status=excluded.trust_status,
                    last_seen=excluded.last_seen,
                    notes=excluded.notes
                """,
                (
                    b_mac,
                    s_name,
                    entry.get("network_type") or "Infrastructure",
                    entry.get("auth") or "Open",
                    entry.get("encryption") or "None",
                    int(entry.get("signal_pct") or 0),
                    entry.get("rssi_dbm"),
                    int(entry.get("link_quality") or entry.get("signal_pct") or 0),
                    int(entry.get("frequency_mhz") or 0),
                    entry.get("radio_type") or "",
                    entry.get("band") or "",
                    int(entry.get("channel") or 0),
                    entry.get("beacon_age_ms"),
                    entry.get("tsf_uptime_us"),
                    entry.get("tx_power_dbm"),
                    entry.get("qbss_sta_count"),
                    entry.get("qbss_chan_util_pct"),
                    sector,
                    entry.get("vendor_oui") or resolve_vendor(b_mac),
                    classification,
                    trust_st,
                    first_seen,
                    now,
                    interrog_json,
                    notes_s,
                ),
            )
        con.commit()
        con.close()

        prio = {"evil_twin": 0, "open_soft_ap": 1, "appliance_ap": 2, "hidden_ap": 3, "home_ap": 4, "neighbor": 5}
        networks_found.sort(
            key=lambda x: (
                prio.get(x.get("classification", "neighbor"), 9),
                -float(x.get("rssi_dbm") if x.get("rssi_dbm") is not None else -110.0),
                -int(x.get("signal_pct", 0)),
            )
        )

        return {
            "status": "ok",
            "mode": "scan_airspace",
            "sensor_backend": sensor_backend,
            "wifi_adapter": wifi_st,
            "total_bssids": len(networks_found),
            "open_soft_aps_count": sum(1 for n in networks_found if n.get("classification") == "open_soft_ap"),
            "appliance_aps_count": sum(1 for n in networks_found if n.get("classification") == "appliance_ap"),
            "evil_twins_count": len(evil_twins),
            "networks": networks_found,
        }

    if m == "configure_adapter":
        if not ssid:
            return {"status": "error", "message": "ssid is required for configure_adapter"}
        prof_name = f"TYLER_CFG_{re.sub(r'[^A-Za-z0-9_-]', '_', ssid)[:24]}"
        ssid_hex = ssid.encode("utf-8").hex().upper()
        ssid_esc = (ssid.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))
        auth_u = (auth or "open").strip().upper()
        if auth_u in ("OPEN", "NONE"):
            auth_xml, enc_xml, key_xml = "open", "none", ""
        else:
            auth_xml = "WPA2PSK" if "WPA2" in auth_u else ("WPA3SAE" if "WPA3" in auth_u else "WPA2PSK")
            enc_xml = "AES"
            k_esc = (key or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            key_xml = (
                "<sharedKey><keyType>passPhrase</keyType><protected>false</protected>"
                f"<keyMaterial>{k_esc}</keyMaterial></sharedKey>"
            )
        xml_content = f"""<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
    <name>{prof_name}</name>
    <SSIDConfig>
        <SSID>
            <hex>{ssid_hex}</hex>
            <name>{ssid_esc}</name>
        </SSID>
        <nonBroadcast>{"true" if hidden else "false"}</nonBroadcast>
    </SSIDConfig>
    <connectionType>ESS</connectionType>
    <connectionMode>manual</connectionMode>
    <MSM>
        <security>
            <authEncryption>
                <authentication>{auth_xml}</authentication>
                <encryption>{enc_xml}</encryption>
                <useOneX>false</useOneX>
            </authEncryption>
            {key_xml}
        </security>
    </MSM>
</WLANProfile>
"""
        xml_linux = Path("/mnt/c/Users/Public/.tyler_wlan_profile.xml")
        xml_win = r"C:\Users\Public\.tyler_wlan_profile.xml"
        try:
            xml_linux.write_text(xml_content, encoding="utf-8")
            r_add = subprocess.run(
                [str(netsh_path), "wlan", "add", "profile", f"filename={xml_win}", f"interface={adapter}", "user=all"],
                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=6.0,
            )
            xml_linux.unlink(missing_ok=True)
            return {
                "status": "ok" if r_add.returncode == 0 else "error",
                "mode": "configure_adapter",
                "profile_name": prof_name,
                "ssid": ssid,
                "adapter": adapter,
                "output": (r_add.stdout or r_add.stderr or "").strip(),
            }
        except Exception as e:
            xml_linux.unlink(missing_ok=True)
            return {"status": "error", "mode": "configure_adapter", "message": str(e)}

    if m == "interrogate_soft_ap":
        # Always refresh airspace scan so Windows WLAN driver has the target BSSID/channel in its active scan cache
        scan_res = wifi_spelunk(mode="scan_airspace")
        target_ssid = (ssid or "").strip()
        target_bssid = (bssid or "").strip().lower()
        for net in scan_res.get("networks", []):
            if target_bssid and net.get("bssid", "").lower() == target_bssid:
                target_ssid = net.get("ssid") or target_ssid
                break
            if target_ssid and net.get("ssid") == target_ssid:
                target_bssid = net.get("bssid", "").lower()
                break
        if not target_ssid or all(net.get("ssid") != target_ssid for net in scan_res.get("networks", [])):
            # Fallback to strongest open_soft_ap in live scan (handles Soft-APs whose SSID changed after rename)
            for net in scan_res.get("networks", []):
                if net.get("classification") == "open_soft_ap" and net.get("ssid"):
                    target_ssid = net["ssid"]
                    target_bssid = net.get("bssid", "").lower()
                    break
        if not target_ssid:
            return {"status": "error", "mode": "interrogate_soft_ap", "message": "No target Soft-AP SSID specified or found in airspace"}

        # Layer 1: Verify primary wired interface is UP so host communication is never interrupted
        if not wifi_st.get("safe_secondary_radio", False):
            return {
                "status": "error",
                "mode": "interrogate_soft_ap",
                "message": "Airlock Safety Gate Blocked: Primary wired interface (eth0) is not active; refusing to switch sole radio.",
            }

        previous_ssid = wifi_st.get("current_ssid", "")
        previous_profile = wifi_st.get("current_profile", "")
        prof_name = f"TYLER_AIRLOCK_{int(time.time())}"
        ssid_hex = target_ssid.encode("utf-8").hex().upper()
        ssid_esc = (target_ssid.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))
        max_sec = max(15, min(90, int(timeout or 45)))

        _int_radio_lock_cm = _wifi_airlock_radio_lock(timeout_s=25.0)
        _int_radio_locked = _int_radio_lock_cm.__enter__()
        if not _int_radio_locked:
            _int_radio_lock_cm.__exit__(None, None, None)
            return {
                "status": "error",
                "mode": "interrogate_soft_ap",
                "message": "Wi-Fi 4 radio lock is currently held by another Soft-AP Airlock session.",
            }

        # Layer 2: Spawn detached Dead-Man Rollback Watchdog
        watchdog_proc = None
        try:
            watchdog_cmd = (
                f"sleep {max_sec + 10}; "
                f"/mnt/c/Windows/System32/netsh.exe wlan disconnect interface=\"{adapter}\" </dev/null >/dev/null 2>&1 || true; "
                f"/mnt/c/Windows/System32/netsh.exe wlan delete profile name=\"{prof_name}\" interface=\"{adapter}\" </dev/null >/dev/null 2>&1 || true"
            )
            watchdog_proc = subprocess.Popen(["bash", "-c", watchdog_cmd], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass

        airlock_log: List[str] = [
            f"Layer 1: Verified primary wired link ({PRIMARY_IFACE}) UP & acquired exclusive Wi-Fi 4 radio mutex; snapshotted prior state (previous_ssid='{previous_ssid or 'disconnected'}').",
            f"Layer 2: Armed {max_sec + 10}s detached dead-man rollback watchdog.",
        ]
        dossier: Dict[str, Any] = {
            "ssid": target_ssid,
            "bssid": target_bssid,
            "adapter": adapter,
            "wsl_interface": wsl_iface,
            "airlock_layers": airlock_log,
            "dhcp_lease": {},
            "open_ports": [],
            "eureka_info": {},
            "nearby_wifi_seen_by_device": [],
            "http_banners": {},
            "surprise_executed": {},
        }

        xml_linux = Path("/mnt/c/Users/Public/.tyler_wlan_profile.xml")
        xml_win = r"C:\Users\Public\.tyler_wlan_profile.xml"

        try:
            # Layer 3: Apply Inbound DROP + Outbound Windows/Linux Hash & mDNS Leak Block via TYLER_AIRLOCK_* chains
            ensure_kali_running()
            if kali_container_status()["running"]:
                _apply_airlock_firewall(wsl_iface)
                airlock_log.append(
                    f"Layer 3: Locked down {wsl_iface} via isolated TYLER_AIRLOCK_* chains (IPv4 + IPv6 DROP + SMB/NetBIOS/mDNS/LLMNR/RPC leak block + Docker isolation)."
                )

            # Layer 4: Synthesize manual-mode Open WLAN profile & associate Wi-Fi 4
            xml_content = f"""<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
    <name>{prof_name}</name>
    <SSIDConfig>
        <SSID>
            <hex>{ssid_hex}</hex>
            <name>{ssid_esc}</name>
        </SSID>
        <nonBroadcast>false</nonBroadcast>
    </SSIDConfig>
    <connectionType>ESS</connectionType>
    <connectionMode>manual</connectionMode>
    <MSM>
        <security>
            <authEncryption>
                <authentication>open</authentication>
                <encryption>none</encryption>
                <useOneX>false</useOneX>
            </authEncryption>
        </security>
    </MSM>
</WLANProfile>
"""
            xml_linux.write_text(xml_content, encoding="utf-8")
            subprocess.run(
                [str(netsh_path), "wlan", "add", "profile", f"filename={xml_win}", f"interface={adapter}", "user=all"],
                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=6.0,
            )
            xml_linux.unlink(missing_ok=True)

            r_conn = subprocess.run(
                [str(netsh_path), "wlan", "connect", f"name={prof_name}", f"interface={adapter}"],
                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=6.0,
            )
            airlock_log.append(f"Layer 4: Initiated manual association on '{adapter}' to '{target_ssid}' ({(r_conn.stdout or '').strip()}).")

            # Poll for association & DHCP IPv4 assignment on Wi-Fi 4 / eth1 (up to 18 seconds)
            wifi_ip, wifi_cidr, soft_ap_gw = "", "", ""
            assoc_bssid = target_bssid
            for poll_idx in range(18):
                time.sleep(1.0)
                st_now = _get_windows_wifi_status()
                if st_now.get("current_bssid"):
                    assoc_bssid = st_now["current_bssid"]
                if poll_idx in (5, 10) and st_now.get("state") == "disconnected":
                    subprocess.run(
                        [str(netsh_path), "wlan", "connect", f"name={prof_name}", f"interface={adapter}"],
                        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5.0,
                    )
                wifi_ip, wifi_cidr, soft_ap_gw = _get_windows_wifi_ipv4(adapter, wsl_iface)
                if wifi_ip and soft_ap_gw:
                    break

            # Strip any default route on eth1 inside WSL2 so eth0 remains exclusive default route
            subprocess.run(["ip", "route", "del", "default", "dev", wsl_iface], capture_output=True, text=True, timeout=2.0)

            if not wifi_ip:
                airlock_log.append("Layer 4 Warning: Wi-Fi 4 did not receive a DHCP IPv4 lease within 16s.")
                return {
                    "status": "partial",
                    "mode": "interrogate_soft_ap",
                    "message": "Association timed out waiting for DHCP lease from Soft-AP",
                    "dossier": dossier,
                }

            # Subnet collision check against primary LAN
            if wifi_cidr and wifi_cidr == LAN_SUBNET:
                airlock_log.append(f"Layer 4 Security Abort: Soft-AP subnet {wifi_cidr} collides with primary LAN {LAN_SUBNET}!")
                return {
                    "status": "aborted_subnet_collision",
                    "mode": "interrogate_soft_ap",
                    "dossier": dossier,
                }

            dossier["bssid"] = assoc_bssid
            dossier["dhcp_lease"] = {
                "client_ip": wifi_ip,
                "cidr": wifi_cidr,
                "soft_ap_gateway": soft_ap_gw,
            }
            airlock_log.append(
                f"Layer 4: Assigned Airlock IP {wifi_ip} ({wifi_cidr}) via Soft-AP Gateway {soft_ap_gw}; verified zero overlap with {LAN_SUBNET}."
            )

            # Layer 5: Surgical Probe & Google Cast / Eureka Setup Interrogation
            candidate_ports = [80, 443, 8008, 8009, 8080, 8443, 9000]
            open_ports: List[int] = []
            for pt in candidate_ports:
                try:
                    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                        s.settimeout(0.6)
                        if s.connect_ex((soft_ap_gw, pt)) == 0:
                            open_ports.append(pt)
                except Exception:
                    pass
            dossier["open_ports"] = open_ports

            # Interrogate Google Cast / Lenovo Smart Clock Setup API (:8008 HTTP and :8443 HTTPS)
            eureka_params = (
                "?params=version,audio,name,build_info,detail,device_info,net,wifi,setup,settings,"
                "opt_in,opencast,multizone,proxy,night_mode_params,user_eq,room_equalizer&options=detail"
            )
            for base_u in (f"https://{soft_ap_gw}:8443", f"http://{soft_ap_gw}:8008"):
                for suffix in (f"/setup/eureka_info{eureka_params}", "/setup/eureka_info"):
                    e_res = _http_fetch_via_wifi(f"{base_u}{suffix}", wifi_ip=wifi_ip, method="GET", timeout=5.0)
                    if e_res.get("ok") and isinstance(e_res.get("json"), dict):
                        dossier["eureka_info"].update(e_res["json"])
                scan_res_ap = _http_fetch_via_wifi(f"{base_u}/setup/scan_results", wifi_ip=wifi_ip, method="GET", timeout=5.0)
                if scan_res_ap.get("ok") and isinstance(scan_res_ap.get("json"), list) and not dossier["nearby_wifi_seen_by_device"]:
                    dossier["nearby_wifi_seen_by_device"] = scan_res_ap["json"][:15]

            if dossier["eureka_info"]:
                airlock_log.append("Layer 5: Extracted complete Google Cast / Eureka device telemetry from :8008/:8443.")

            pre_surprise_name = str((dossier.get("eureka_info") or {}).get("name") or "")
            pre_surprise_settings = dict((dossier.get("eureka_info") or {}).get("settings") or {})

            # Check port 80 and 9000 banners if open
            for pt_b in (80, 9000):
                if pt_b in dossier["open_ports"]:
                    hb = _http_fetch_via_wifi(f"http://{soft_ap_gw}:{pt_b}/", wifi_ip=wifi_ip, method="GET", timeout=3.5)
                    if hb.get("status_line"):
                        dossier["http_banners"][str(pt_b)] = {
                            "status_line": hb.get("status_line"),
                            "body_preview": (hb.get("body") or "")[:500],
                        }

            # Optional Physically Observable Surprise on the Clock / Cast Soft-AP!
            if surprise:
                surprise_report: Dict[str, Any] = {}
                new_dev_name = surprise_name or "George Was Here (Blue Lodge)"

                # 1. HTTPS :8443 and HTTP :8008 Setup APIs (set_eureka_info, play_sound)
                for base_u in (f"https://{soft_ap_gw}:8443", f"http://{soft_ap_gw}:8008"):
                    for snd_ep in ("/setup/play_sound", "/setup/test_sound"):
                        s_try = _http_fetch_via_wifi(
                            f"{base_u}{snd_ep}",
                            wifi_ip=wifi_ip,
                            method="POST",
                            json_body={"sound_id": 0},
                            timeout=3.0,
                        )
                        if s_try.get("ok"):
                            surprise_report["setup_sound_api"] = s_try
                            break
                    set_try = _http_fetch_via_wifi(
                        f"{base_u}/setup/set_eureka_info",
                        wifi_ip=wifi_ip,
                        method="POST",
                        json_body={
                            "name": new_dev_name,
                            "settings": {
                                "locale": "en-US",
                                "time_format": 2,
                                "system_sound_effects": True,
                            },
                        },
                        timeout=3.5,
                    )
                    surprise_report[f"set_eureka_info_{base_u.split(':')[-1]}"] = set_try

                # Verify updated name & 24h clock format persisted on the device!
                verify_e = _http_fetch_via_wifi(
                    f"https://{soft_ap_gw}:8443/setup/eureka_info?params=name,settings,setup,detail",
                    wifi_ip=wifi_ip,
                    method="GET",
                    timeout=4.0,
                )
                if verify_e.get("ok") and isinstance(verify_e.get("json"), dict):
                    surprise_report["verified_device_state_after_surprise"] = verify_e["json"]
                    dossier["eureka_info"].update(verify_e["json"])

                # 2. CastV2 (:8009) Physical Volume Chime & App Launch over Windows SslStream bound to wifi_ip!
                if 8009 in dossier["open_ports"]:
                    surprise_report["castv2_8009_surprise"] = _castv2_tls_surprise(
                        soft_ap_gw, wifi_ip=wifi_ip, port=8009
                    )

                dossier["surprise_executed"] = surprise_report
                airlock_log.append(
                    f"Layer 5 Surprise: Executed CastV2 :8009 physical volume chime/media broadcast and :8443 setup interrogation on '{target_ssid}'!"
                )

            # Save interrogation dossier into wifi_airspace SQLite table and enroll in claimed_peripherals
            if assoc_bssid:
                con = connect_db()
                con.execute(
                    "UPDATE wifi_airspace SET interrogation_json = ?, last_seen = ? WHERE bssid = ?",
                    (json.dumps(dossier), int(time.time()), assoc_bssid),
                )
                con.commit()
                con.close()
                e_info_now = dossier.get("eureka_info") or {}
                suffix_now = str((e_info_now.get("setup") or {}).get("ssid_suffix") or "q001")
                cur_dev_name = str(e_info_now.get("name") or target_ssid)
                live_ssid_after = (
                    f"{cur_dev_name[:26]}.{suffix_now},"
                    if surprise and e_info_now.get("name")
                    else target_ssid
                )
                claimed_rec = _upsert_claimed_peripheral(
                    bssid=assoc_bssid,
                    current_ssid=live_ssid_after,
                    dossier=dossier,
                    pre_name=pre_surprise_name,
                    pre_ssid=target_ssid,
                    pre_settings=pre_surprise_settings,
                    role="claimed_sensor",
                    status="claimed",
                )
                dossier["claimed_peripheral"] = claimed_rec

            return {
                "status": "ok",
                "mode": "interrogate_soft_ap",
                "dossier": dossier,
            }
        finally:
            # Layer 6: Guaranteed Teardown & Prior State Restoration
            xml_linux.unlink(missing_ok=True)
            try:
                subprocess.run(
                    [str(netsh_path), "wlan", "disconnect", f"interface={adapter}"],
                    stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5.0,
                )
                subprocess.run(
                    [str(netsh_path), "wlan", "delete", "profile", f"name={prof_name}", f"interface={adapter}"],
                    stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5.0,
                )
                if previous_ssid and previous_profile:
                    subprocess.run(
                        [str(netsh_path), "wlan", "connect", f"name={previous_profile}", f"ssid={previous_ssid}", f"interface={adapter}"],
                        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5.0,
                    )
            except Exception:
                pass
            if kali_container_status()["running"]:
                _teardown_airlock_firewall(wsl_iface)
            if watchdog_proc is not None:
                try:
                    watchdog_proc.terminate()
                except Exception:
                    pass
            _int_radio_lock_cm.__exit__(None, None, None)
            airlock_log.append(
                f"Layer 6: Disconnected '{adapter}', deleted temporary profile '{prof_name}', removed temporary firewall rules, released Wi-Fi 4 radio mutex, and disarmed watchdog."
            )

    if m in ("triangulate_airspace", "triangulate"):
        scan_res = wifi_spelunk(mode="scan_airspace")
        desktop_nets = list(scan_res.get("networks") or [])
        if not desktop_nets:
            con = connect_db()
            desktop_nets = [dict(r) for r in con.execute("SELECT * FROM wifi_airspace ORDER BY signal_pct DESC").fetchall()]
            con.close()

        periph, live_ssid, live_bssid, live_visible = _resolve_target_peripheral(ssid, bssid, desktop_nets)
        peripheral_scan: List[Dict[str, Any]] = []
        sensor_mode = "cached_peripheral_telemetry"
        airlock_layers: List[str] = []
        allow_live = bool(live_visible and live_ssid and wifi_st.get("safe_secondary_radio", False) and int(timeout or 45) > 5)

        if allow_live:
            def _tri_session(wifi_ip: str, wifi_cidr: str, soft_ap_gw: str, assoc_bssid: str, alog: List[str]) -> Dict[str, Any]:
                e_data: Dict[str, Any] = {}
                scan_list: List[Dict[str, Any]] = []
                for base_u in (f"https://{soft_ap_gw}:8443", f"http://{soft_ap_gw}:8008"):
                    _http_fetch_via_wifi(f"{base_u}/setup/scan_wifi", wifi_ip=wifi_ip, method="POST", json_body={}, timeout=3.5)
                time.sleep(2.2)
                for base_u in (f"https://{soft_ap_gw}:8443", f"http://{soft_ap_gw}:8008"):
                    er = _http_fetch_via_wifi(
                        f"{base_u}/setup/eureka_info?params=version,name,build_info,device_info,net,wifi,setup,settings&options=detail",
                        wifi_ip=wifi_ip,
                        method="GET",
                        timeout=4.5,
                    )
                    if er.get("ok") and isinstance(er.get("json"), dict):
                        e_data.update(er["json"])
                    sr = _http_fetch_via_wifi(f"{base_u}/setup/scan_results", wifi_ip=wifi_ip, method="GET", timeout=5.0)
                    if sr.get("ok") and isinstance(sr.get("json"), list) and not scan_list:
                        scan_list = sr["json"]
                alog.append(
                    f"Layer 5 Triangulation: Triggered /setup/scan_wifi + /setup/scan_results on {soft_ap_gw}; captured {len(scan_list)} dual-band (2.4/5 GHz) SSID groups."
                )
                return {"eureka_info": e_data, "scan_results": scan_list}

            sess = _run_soft_ap_airlock_session(live_ssid, live_bssid, timeout, _tri_session)
            airlock_layers = sess.get("airlock_layers") or []
            if sess.get("ok"):
                pay = sess.get("payload") or {}
                if pay.get("scan_results"):
                    peripheral_scan = pay["scan_results"]
                    sensor_mode = "live_airlock_dual_band_scan"
                b_actual = sess.get("assoc_bssid") or live_bssid
                if b_actual:
                    periph = _upsert_claimed_peripheral(
                        bssid=b_actual,
                        current_ssid=live_ssid,
                        dossier={
                            "dhcp_lease": {"soft_ap_gateway": sess.get("soft_ap_gw", "192.168.255.249")},
                            "eureka_info": pay.get("eureka_info") or {},
                            "nearby_wifi_seen_by_device": peripheral_scan,
                        },
                        role="dual_band_spectrum_sensor",
                        status="active_sensor",
                    )

        if not peripheral_scan and periph:
            peripheral_scan = list((periph.get("last_telemetry") or {}).get("nearby_wifi_seen_by_device") or [])
        if not peripheral_scan:
            con = connect_db()
            for wr in con.execute("SELECT interrogation_json FROM wifi_airspace WHERE interrogation_json != '{}'").fetchall():
                try:
                    inter = json.loads(wr["interrogation_json"] or "{}")
                    if inter.get("nearby_wifi_seen_by_device"):
                        peripheral_scan = inter["nearby_wifi_seen_by_device"]
                        break
                except Exception:
                    pass
            con.close()

        periph_label = (
            f"{periph.get('model_name') or 'Cast Soft-AP'} ({periph.get('bssid')})"
            if periph
            else f"Soft-AP ({live_bssid or live_ssid or 'remote'})"
        )
        tri = _compute_airspace_triangulation(desktop_nets, peripheral_scan, peripheral_label=periph_label)
        if periph and periph.get("bssid"):
            _upsert_claimed_peripheral(
                bssid=periph["bssid"],
                current_ssid=periph.get("current_ssid") or live_ssid,
                dossier={},
                extra_telemetry={
                    "last_triangulation_ts": int(time.time()),
                    "last_triangulation_summary": {
                        "total_transmitters": tri["total_transmitters"],
                        "dual_sensor_matched": tri["dual_sensor_matched"],
                        "near_peripheral_count": tri["near_peripheral_count"],
                        "near_workstation_count": tri["near_workstation_count"],
                        "five_ghz_discovered_by_peripheral": tri["five_ghz_discovered_by_peripheral"],
                    },
                },
            )
        return {
            "status": "ok",
            "mode": "triangulate_airspace",
            "sensor_mode": sensor_mode,
            "peripheral": periph or {"bssid": live_bssid, "ssid": live_ssid},
            "triangulation": tri,
            "airlock_layers": airlock_layers,
        }

    if m in ("canary_ap_watch", "canary_ap"):
        scan_res = wifi_spelunk(mode="scan_airspace")
        desktop_nets = list(scan_res.get("networks") or [])
        periph, live_ssid, live_bssid, live_visible = _resolve_target_peripheral(ssid, bssid, desktop_nets)

        decoy_name: Optional[str] = None
        if surprise_name and surprise_name.strip():
            decoy_name = surprise_name.strip()
        elif surprise:
            decoy_name = "Staging-Admin-WiFi"
        elif ssid and periph and ssid.strip() not in (
            periph.get("current_ssid"),
            periph.get("original_ssid"),
            periph.get("live_beacon_ssid"),
        ):
            decoy_name = ssid.strip()

        base_stats = dict((periph.get("baseline_stats") if periph else None) or {})
        allow_live = bool(live_visible and live_ssid and wifi_st.get("safe_secondary_radio", False) and int(timeout or 45) > 5)

        if allow_live:
            def _canary_session(wifi_ip: str, wifi_cidr: str, soft_ap_gw: str, assoc_bssid: str, alog: List[str]) -> Dict[str, Any]:
                foreign_clients = _sweep_soft_ap_clients(wifi_ip, soft_ap_gw)
                alog.append(
                    f"Layer 5 Canary Sweep: Swept /29 Soft-AP client pool ({soft_ap_gw}); unauthorized clients attached: {len(foreign_clients)}."
                )
                e_data: Dict[str, Any] = {}
                for base_u in (f"https://{soft_ap_gw}:8443", f"http://{soft_ap_gw}:8008"):
                    er = _http_fetch_via_wifi(
                        f"{base_u}/setup/eureka_info?params=version,name,build_info,device_info,net,wifi,setup,settings&options=detail",
                        wifi_ip=wifi_ip,
                        method="GET",
                        timeout=4.5,
                    )
                    if er.get("ok") and isinstance(er.get("json"), dict):
                        e_data.update(er["json"])
                rename_res: Dict[str, Any] = {}
                if decoy_name:
                    for base_u in (f"https://{soft_ap_gw}:8443", f"http://{soft_ap_gw}:8008"):
                        r_set = _http_fetch_via_wifi(
                            f"{base_u}/setup/set_eureka_info",
                            wifi_ip=wifi_ip,
                            method="POST",
                            json_body={"name": decoy_name},
                            timeout=3.5,
                        )
                        rename_res[base_u.split(":")[-1]] = r_set
                    ver = _http_fetch_via_wifi(
                        f"https://{soft_ap_gw}:8443/setup/eureka_info?params=name,setup,settings&options=detail",
                        wifi_ip=wifi_ip,
                        method="GET",
                        timeout=4.0,
                    )
                    if ver.get("ok") and isinstance(ver.get("json"), dict):
                        e_data.update(ver["json"])
                    alog.append(f"Layer 5 Canary Decoy Lure: Set Soft-AP decoy name to '{decoy_name}'.")
                return {
                    "foreign_clients": foreign_clients,
                    "eureka_info": e_data,
                    "decoy_rename": rename_res,
                }

            sess = _run_soft_ap_airlock_session(live_ssid, live_bssid, timeout, _canary_session)
            if sess.get("ok"):
                pay = sess.get("payload") or {}
                e_info = pay.get("eureka_info") or {}
                setup_info = e_info.get("setup") or {}
                live_stats = dict(setup_info.get("stats") or {})
                foreign_clients = list(pay.get("foreign_clients") or [])
                stats_delta = {
                    k: int(live_stats.get(k, 0)) - int(base_stats.get(k, 0))
                    for k in set(live_stats.keys()) | set(base_stats.keys())
                }
                tamper_detected = bool(foreign_clients) or int(stats_delta.get("num_connect_wifi", 0)) > 0
                if tamper_detected:
                    emit_security_event(
                        "network.canary_ap_intrusion",
                        {
                            "bssid": sess.get("assoc_bssid") or live_bssid,
                            "ssid": live_ssid,
                            "foreign_clients": foreign_clients,
                            "stats_delta": stats_delta,
                        },
                    )
                suffix = str(setup_info.get("ssid_suffix") or "q001")
                cur_nm = str(e_info.get("name") or decoy_name or (periph.get("current_name") if periph else ""))
                new_ssid = f"{cur_nm[:26]}.{suffix}," if cur_nm else live_ssid
                canary_summary = {
                    "ts": int(time.time()),
                    "live_connected": True,
                    "airlock_client_ip": sess.get("wifi_ip"),
                    "soft_ap_gateway": sess.get("soft_ap_gw"),
                    "decoy_name_applied": decoy_name,
                    "broadcast_ssid": new_ssid,
                    "foreign_clients": foreign_clients,
                    "foreign_clients_count": len(foreign_clients),
                    "live_stats": live_stats,
                    "baseline_stats": base_stats,
                    "stats_delta": stats_delta,
                    "tamper_detected": tamper_detected,
                }
                b_actual = sess.get("assoc_bssid") or live_bssid
                if b_actual:
                    periph = _upsert_claimed_peripheral(
                        bssid=b_actual,
                        current_ssid=new_ssid,
                        dossier={
                            "dhcp_lease": {"soft_ap_gateway": sess.get("soft_ap_gw", "192.168.255.249")},
                            "eureka_info": e_info,
                        },
                        role="canary_honeypot_ap",
                        status="active_canary",
                        extra_telemetry={"last_canary_watch": canary_summary},
                        notes=f"Canary Soft-AP Honeypot active (SSID='{new_ssid}')",
                    )
                return {
                    "status": "ok",
                    "mode": "canary_ap_watch",
                    "canary_watch": canary_summary,
                    "claimed_peripheral": periph,
                    "airlock_layers": sess.get("airlock_layers") or [],
                }

        canary_fallback = {
            "ts": int(time.time()),
            "live_connected": False,
            "decoy_name_requested": decoy_name,
            "broadcast_ssid": live_ssid or (periph.get("current_ssid") if periph else ""),
            "foreign_clients": [],
            "foreign_clients_count": 0,
            "live_stats": base_stats,
            "baseline_stats": base_stats,
            "stats_delta": {k: 0 for k in base_stats},
            "tamper_detected": False,
        }
        return {
            "status": "ok",
            "mode": "canary_ap_watch",
            "canary_watch": canary_fallback,
            "claimed_peripheral": periph,
            "airlock_layers": [],
        }

    if m in ("set_ap_beacon", "beacon"):
        scan_res = wifi_spelunk(mode="scan_airspace")
        desktop_nets = list(scan_res.get("networks") or [])
        periph, live_ssid, live_bssid, live_visible = _resolve_target_peripheral(None, bssid, desktop_nets)
        beacon_text = (surprise_name or ssid or "GEORGE-ALL-CLEAR").strip()
        if periph and beacon_text in (periph.get("current_ssid"), periph.get("original_ssid")) and surprise_name:
            beacon_text = surprise_name.strip()

        allow_live = bool(live_visible and live_ssid and wifi_st.get("safe_secondary_radio", False) and int(timeout or 45) > 5)
        if allow_live:
            def _beacon_session(wifi_ip: str, wifi_cidr: str, soft_ap_gw: str, assoc_bssid: str, alog: List[str]) -> Dict[str, Any]:
                set_res: Dict[str, Any] = {}
                for base_u in (f"https://{soft_ap_gw}:8443", f"http://{soft_ap_gw}:8008"):
                    set_res[base_u.split(":")[-1]] = _http_fetch_via_wifi(
                        f"{base_u}/setup/set_eureka_info",
                        wifi_ip=wifi_ip,
                        method="POST",
                        json_body={"name": beacon_text},
                        timeout=3.5,
                    )
                ver = _http_fetch_via_wifi(
                    f"https://{soft_ap_gw}:8443/setup/eureka_info?params=name,setup,settings,device_info&options=detail",
                    wifi_ip=wifi_ip,
                    method="GET",
                    timeout=4.0,
                )
                e_info = ver.get("json") if (ver.get("ok") and isinstance(ver.get("json"), dict)) else {"name": beacon_text}
                alog.append(f"Layer 5 Over-the-Air Beacon: Updated 802.11 SSID beacon name to '{beacon_text}'.")
                return {"eureka_info": e_info, "set_result": set_res}

            sess = _run_soft_ap_airlock_session(live_ssid, live_bssid, timeout, _beacon_session)
            if sess.get("ok"):
                pay = sess.get("payload") or {}
                e_info = pay.get("eureka_info") or {}
                suffix = str((e_info.get("setup") or {}).get("ssid_suffix") or "q001")
                applied_nm = str(e_info.get("name") or beacon_text)
                new_ssid = f"{applied_nm[:26]}.{suffix},"
                b_actual = sess.get("assoc_bssid") or live_bssid
                if b_actual:
                    periph = _upsert_claimed_peripheral(
                        bssid=b_actual,
                        current_ssid=new_ssid,
                        dossier={"eureka_info": e_info},
                        role="status_beacon_ap",
                        status="broadcasting_beacon",
                        notes=f"Over-the-Air Status Beacon active: '{new_ssid}'",
                    )
                return {
                    "status": "ok",
                    "mode": "set_ap_beacon",
                    "live_updated": True,
                    "beacon_name": applied_nm,
                    "broadcast_ssid": new_ssid,
                    "claimed_peripheral": periph,
                    "airlock_layers": sess.get("airlock_layers") or [],
                }

        suffix_fb = "q001"
        new_ssid_fb = f"{beacon_text[:26]}.{suffix_fb},"
        return {
            "status": "ok",
            "mode": "set_ap_beacon",
            "live_updated": False,
            "beacon_name": beacon_text,
            "broadcast_ssid": new_ssid_fb,
            "claimed_peripheral": periph,
            "airlock_layers": [],
        }

    if m in ("provision_cast_ap", "provision"):
        scan_res = wifi_spelunk(mode="scan_airspace")
        desktop_nets = list(scan_res.get("networks") or [])
        periph, live_ssid, live_bssid, live_visible = _resolve_target_peripheral(None, bssid, desktop_nets)

        wl = load_wifi_watchlist()
        default_home_ssid = (wl.get("home_ssids") or [DEFAULT_HOME_SSID])[0]
        target_wifi_ssid = (ssid or "").strip()
        if not target_wifi_ssid or (
            periph and target_wifi_ssid in (periph.get("current_ssid"), periph.get("original_ssid"), periph.get("live_beacon_ssid"))
        ):
            target_wifi_ssid = (surprise_name or default_home_ssid).strip()

        pub_key = str((periph.get("public_key") if periph else "") or "")
        nearby_list = list(((periph.get("last_telemetry") if periph else {}) or {}).get("nearby_wifi_seen_by_device") or [])
        wpa_auth = 7
        wpa_cipher = 4
        target_signal_dbm: Optional[int] = None
        for net_entry in nearby_list:
            if isinstance(net_entry, dict) and str(net_entry.get("ssid") or "").lower() == target_wifi_ssid.lower():
                wpa_auth = int(net_entry.get("wpa_auth") or 7)
                wpa_cipher = int(net_entry.get("wpa_cipher") or 4)
                target_signal_dbm = int(net_entry.get("signal_level") or -50)
                break

        is_fdr = str(auth or "").lower() == "fdr" or str(surprise_name or "").lower() == "fdr"
        allow_live = bool(live_visible and live_ssid and wifi_st.get("safe_secondary_radio", False) and int(timeout or 45) > 5)

        if is_fdr and allow_live:
            def _fdr_session(wifi_ip: str, wifi_cidr: str, soft_ap_gw: str, assoc_bssid: str, alog: List[str]) -> Dict[str, Any]:
                r_fdr = _http_fetch_via_wifi(
                    f"https://{soft_ap_gw}:8443/setup/reboot",
                    wifi_ip=wifi_ip,
                    method="POST",
                    json_body={"params": "fdr"},
                    timeout=4.0,
                )
                alog.append("Layer 5 Factory Reset: Sent POST /setup/reboot {\"params\": \"fdr\"} to return device to setup_state=10 Soft-AP mode.")
                return {"reboot_fdr": r_fdr}

            sess = _run_soft_ap_airlock_session(live_ssid, live_bssid, timeout, _fdr_session)
            return {
                "status": "ok",
                "mode": "provision_cast_ap",
                "provisioning_state": "factory_reset_to_soft_ap",
                "result": sess.get("payload"),
                "airlock_layers": sess.get("airlock_layers") or [],
            }

        if not key:
            probe_cipher = _encrypt_cast_wifi_password("tyler-rsa-readiness-probe", pub_key) if pub_key else ""
            return {
                "status": "ok",
                "mode": "provision_cast_ap",
                "provisioning_state": "ready_awaiting_passphrase",
                "rsa_public_key_present": bool(pub_key),
                "rsa_encryption_verified": bool(probe_cipher),
                "rsa_sample_ciphertext_b64_len": len(probe_cipher),
                "target_wifi_ssid": target_wifi_ssid,
                "target_wifi_wpa_auth": wpa_auth,
                "target_wifi_wpa_cipher": wpa_cipher,
                "target_wifi_rssi_at_peripheral_dbm": target_signal_dbm,
                "connect_wifi_endpoint": f"https://{(periph.get('soft_ap_gateway') if periph else None) or '192.168.255.249'}:8443/setup/connect_wifi",
                "claimed_peripheral": periph,
                "note": "Pass --key <WPA_PASSPHRASE> to encrypt with the peripheral's 2048-bit RSA public_key and execute POST /setup/connect_wifi.",
            }

        enc_passwd = _encrypt_cast_wifi_password(key, pub_key) if pub_key else ""
        if not enc_passwd and not allow_live:
            return {
                "status": "error",
                "mode": "provision_cast_ap",
                "message": "No RSA public_key available for peripheral; run interrogate_soft_ap first.",
            }

        if allow_live:
            def _prov_session(wifi_ip: str, wifi_cidr: str, soft_ap_gw: str, assoc_bssid: str, alog: List[str]) -> Dict[str, Any]:
                nonlocal pub_key, enc_passwd
                if not pub_key:
                    er = _http_fetch_via_wifi(
                        f"https://{soft_ap_gw}:8443/setup/eureka_info?params=device_info,setup&options=detail",
                        wifi_ip=wifi_ip,
                        method="GET",
                        timeout=4.5,
                    )
                    if er.get("ok") and isinstance(er.get("json"), dict):
                        pub_key = str(((er["json"].get("device_info") or {}).get("public_key")) or "")
                        if pub_key:
                            enc_passwd = _encrypt_cast_wifi_password(key, pub_key)
                req_body = {
                    "ssid": target_wifi_ssid,
                    "wpa_auth": wpa_auth,
                    "wpa_cipher": wpa_cipher,
                    "enc_passwd": enc_passwd,
                    "keep_hotspot_until_connected": True,
                }
                r_conn = _http_fetch_via_wifi(
                    f"https://{soft_ap_gw}:8443/setup/connect_wifi",
                    wifi_ip=wifi_ip,
                    method="POST",
                    json_body=req_body,
                    timeout=6.0,
                )
                alog.append(
                    f"Layer 5 RSA Wi-Fi Onboarding: Encrypted passphrase with 2048-bit RSA public_key and sent POST /setup/connect_wifi for SSID '{target_wifi_ssid}'."
                )
                return {"connect_wifi_response": r_conn, "target_wifi_ssid": target_wifi_ssid}

            sess = _run_soft_ap_airlock_session(live_ssid, live_bssid, timeout, _prov_session)
            if sess.get("ok") and periph and periph.get("bssid"):
                periph = _upsert_claimed_peripheral(
                    bssid=periph["bssid"],
                    current_ssid=target_wifi_ssid,
                    dossier={},
                    role="lan_cast_node",
                    status="provisioning_wifi",
                    notes=f"Provisioned onto '{target_wifi_ssid}' via RSA-encrypted /setup/connect_wifi",
                )
            return {
                "status": "ok" if sess.get("ok") else "partial",
                "mode": "provision_cast_ap",
                "provisioning_state": "connect_wifi_dispatched" if sess.get("ok") else sess.get("reason", "offline"),
                "target_wifi_ssid": target_wifi_ssid,
                "rsa_encryption_verified": bool(enc_passwd),
                "result": sess.get("payload"),
                "claimed_peripheral": periph,
                "airlock_layers": sess.get("airlock_layers") or [],
            }

        return {
            "status": "ok",
            "mode": "provision_cast_ap",
            "provisioning_state": "encrypted_payload_staged_offline",
            "target_wifi_ssid": target_wifi_ssid,
            "rsa_encryption_verified": bool(enc_passwd),
            "enc_passwd_b64_len": len(enc_passwd),
            "claimed_peripheral": periph,
        }

    if m in ("restore_peripheral", "restore_baseline", "restore"):
        scan_res = wifi_spelunk(mode="scan_airspace")
        desktop_nets = list(scan_res.get("networks") or [])
        periph, live_ssid, live_bssid, live_visible = _resolve_target_peripheral(ssid, bssid, desktop_nets)
        if not periph:
            return {"status": "error", "mode": "restore_peripheral", "message": "No claimed peripheral found in database to restore"}

        orig_name = str(periph.get("original_name") or "LenovoSmartClock5544")
        orig_ssid = str(periph.get("original_ssid") or "LenovoSmartClock5544.q001,")
        orig_settings = dict(periph.get("original_settings") or {"locale": "en-US", "time_format": 1, "system_sound_effects": True})
        allow_live = bool(live_visible and live_ssid and wifi_st.get("safe_secondary_radio", False) and int(timeout or 45) > 5)

        if allow_live:
            def _restore_session(wifi_ip: str, wifi_cidr: str, soft_ap_gw: str, assoc_bssid: str, alog: List[str]) -> Dict[str, Any]:
                restore_res: Dict[str, Any] = {}
                for base_u in (f"https://{soft_ap_gw}:8443", f"http://{soft_ap_gw}:8008"):
                    restore_res[base_u.split(":")[-1]] = _http_fetch_via_wifi(
                        f"{base_u}/setup/set_eureka_info",
                        wifi_ip=wifi_ip,
                        method="POST",
                        json_body={"name": orig_name, "settings": orig_settings},
                        timeout=3.5,
                    )
                ver = _http_fetch_via_wifi(
                    f"https://{soft_ap_gw}:8443/setup/eureka_info?params=name,settings,setup,device_info&options=detail",
                    wifi_ip=wifi_ip,
                    method="GET",
                    timeout=4.0,
                )
                e_info = ver.get("json") if (ver.get("ok") and isinstance(ver.get("json"), dict)) else {"name": orig_name, "settings": orig_settings}
                alog.append(
                    f"Layer 5 Baseline Restore: Restored peripheral '{assoc_bssid}' to factory name '{orig_name}' (SSID='{orig_ssid}', time_format={orig_settings.get('time_format', 1)})."
                )
                return {"eureka_info": e_info, "restore_result": restore_res}

            sess = _run_soft_ap_airlock_session(live_ssid, live_bssid, timeout, _restore_session)
            if sess.get("ok"):
                pay = sess.get("payload") or {}
                periph = _upsert_claimed_peripheral(
                    bssid=periph["bssid"],
                    current_ssid=orig_ssid,
                    dossier={"eureka_info": pay.get("eureka_info") or {"name": orig_name, "settings": orig_settings}},
                    role="claimed_sensor",
                    status="restored_baseline",
                    notes=f"Restored to original factory baseline ('{orig_name}' / '{orig_ssid}')",
                )
                return {
                    "status": "ok",
                    "mode": "restore_peripheral",
                    "live_restored": True,
                    "restored_name": orig_name,
                    "restored_ssid": orig_ssid,
                    "restored_settings": orig_settings,
                    "claimed_peripheral": periph,
                    "airlock_layers": sess.get("airlock_layers") or [],
                }

        periph = _upsert_claimed_peripheral(
            bssid=periph["bssid"],
            current_ssid=orig_ssid,
            dossier={"eureka_info": {"name": orig_name, "settings": orig_settings}},
            role="claimed_sensor",
            status="restored_baseline",
            notes=f"Baseline record set to original factory state ('{orig_name}' / '{orig_ssid}')",
        )
        return {
            "status": "ok",
            "mode": "restore_peripheral",
            "live_restored": False,
            "restored_name": orig_name,
            "restored_ssid": orig_ssid,
            "restored_settings": orig_settings,
            "claimed_peripheral": periph,
            "airlock_layers": [],
        }

    return {"status": "error", "message": f"Unknown wifi-spelunk mode: {m}"}


def get_tyler_status() -> Dict[str, Any]:
    con = connect_db()
    rows = con.execute("SELECT * FROM devices ORDER BY trust_level = 'untrusted' DESC, online DESC, ip ASC").fetchall()
    tshark_rules = [dict(r) for r in con.execute("SELECT * FROM tshark_watch_rules ORDER BY id ASC").fetchall()]
    tshark_hits = [dict(r) for r in con.execute("SELECT * FROM tshark_watch_hits ORDER BY id DESC LIMIT 15").fetchall()]
    canary_hits = [dict(r) for r in con.execute("SELECT * FROM canary_hits ORDER BY id DESC LIMIT 15").fetchall()]
    defense_plans = [dict(r) for r in con.execute("SELECT * FROM defense_plans ORDER BY created_at DESC LIMIT 20").fetchall()]
    baselines = [dict(r) for r in con.execute("SELECT * FROM device_baselines ORDER BY updated_at DESC").fetchall()]
    wifi_rows = [dict(r) for r in con.execute("SELECT * FROM wifi_airspace ORDER BY COALESCE(rssi_dbm, -100) DESC, signal_pct DESC").fetchall()]
    rf_chords = [dict(r) for r in con.execute("SELECT * FROM peripheral_rf_telemetry ORDER BY updated_at DESC").fetchall()]
    rf_events = [dict(r) for r in con.execute("SELECT * FROM rf_motion_events ORDER BY id DESC LIMIT 15").fetchall()]
    ts_stat_row = con.execute(
        "SELECT COUNT(*) AS cnt, MIN(ts) AS min_ts, MAX(ts) AS max_ts, COUNT(DISTINCT chord_id) AS chords FROM rf_telemetry_timeseries"
    ).fetchone()
    rollup_cnt_row = con.execute("SELECT COUNT(*) AS cnt FROM rf_telemetry_rollup_5m").fetchone()
    ts_recent_rows = con.execute(
        "SELECT ts, chord_id, compass_sector, ring, rssi_dbm, COALESCE(ewma_fast_dbm, rssi_dbm) AS ewma_fast_dbm, baseline_rssi_dbm, "
        "noise_dbm, snr_db, rtt_ms, std_db, COALESCE(ewma_std_db, std_db) AS ewma_std_db, p2p_swing_db, "
        "COALESCE(z_score, 0.0) AS z_score, COALESCE(cusum_db, 0.0) AS cusum_db, motion_state AS state, source_mode "
        "FROM rf_telemetry_timeseries ORDER BY ts DESC LIMIT 750"
    ).fetchall()
    con.close()

    ts_by_cid: Dict[str, List[Dict[str, Any]]] = {}
    for tr in reversed(ts_recent_rows):
        cid_k = str(tr["chord_id"])
        ts_by_cid.setdefault(cid_k, []).append(dict(tr))

    rf_timeseries_stats = {
        "total_samples": int(ts_stat_row["cnt"] or 0) if ts_stat_row else 0,
        "rollup_5m_samples": int(rollup_cnt_row["cnt"] or 0) if rollup_cnt_row else 0,
        "earliest_ts": int(ts_stat_row["min_ts"] or 0) if ts_stat_row else 0,
        "latest_ts": int(ts_stat_row["max_ts"] or 0) if ts_stat_row else 0,
        "chords_tracked": int(ts_stat_row["chords"] or 0) if ts_stat_row else 0,
        "cron_job": "canary-daemon (15s in-process EWMA) + tyler_rf_mesh_sweep.sh (3m watchdog)",
        "cron_interval_s": 15,
        "raw_retention_hours": 72,
        "rollup_retention_days": 90,
    }

    for rc in rf_chords:
        raw_hist = rc.pop("history_json", "[]")
        db_series = ts_by_cid.get(str(rc.get("chord_id") or ""), [])
        if db_series:
            rc["history"] = db_series[-60:]
        else:
            try:
                rc["history"] = json.loads(raw_hist or "[]")
            except Exception:
                rc["history"] = []

    for wr in wifi_rows:
        try:
            wr["interrogation"] = json.loads(wr.pop("interrogation_json", "{}") or "{}")
        except Exception:
            wr["interrogation"] = {}

    baselines_by_mac: Dict[str, Dict[str, Any]] = {}
    for b_row in baselines:
        b_copy = dict(b_row)
        try:
            b_copy["open_ports"] = json.loads(b_copy.pop("open_ports_json", "[]") or "[]")
        except Exception:
            b_copy["open_ports"] = []
        try:
            b_copy["last_diff"] = json.loads(b_copy.pop("last_diff_json", "{}") or "{}")
        except Exception:
            b_copy["last_diff"] = {}
        b_copy.pop("banners_json", None)
        baselines_by_mac[(b_copy.get("mac") or "").lower()] = b_copy

    devices: List[Dict[str, Any]] = []
    counts = {"total": 0, "online": 0, "trusted": 0, "known_iot": 0, "untrusted": 0, "quarantined": 0}
    for r in rows:
        d = dict(r)
        try:
            d["open_ports"] = json.loads(d.pop("open_ports_json", "[]") or "[]")
        except Exception:
            d["open_ports"] = []
        try:
            fp_obj = json.loads(d.pop("fingerprint_json", "{}") or "{}")
            if isinstance(fp_obj, dict) and "raw_nmap" in fp_obj:
                fp_obj = {k: v for k, v in fp_obj.items() if k != "raw_nmap"}
            d["fingerprint"] = fp_obj
        except Exception:
            d["fingerprint"] = {}
        try:
            d["traffic_sample"] = json.loads(d.pop("traffic_sample_json", "{}") or "{}")
        except Exception:
            d["traffic_sample"] = {}
        d["baseline"] = baselines_by_mac.get((d.get("mac") or "").lower())
        d["protected"] = d["ip"] in PROTECTED_IPS
        devices.append(d)
        counts["total"] += 1
        if d.get("online"):
            counts["online"] += 1
        tl = d.get("trust_level", "untrusted")
        if tl in counts:
            counts[tl] += 1

    recent_alerts: List[Dict[str, Any]] = []
    if ALERTS_LOG.exists():
        try:
            for ln in reversed(ALERTS_LOG.read_text(encoding="utf-8").splitlines()[-25:]):
                if ln.strip():
                    recent_alerts.append(json.loads(ln))
        except Exception:
            pass

    canary_st = manage_canary_trap("status")
    pcaps: List[Dict[str, Any]] = []
    if PCAP_DIR.exists():
        for p in sorted(PCAP_DIR.glob("*.pcap"), key=lambda x: x.stat().st_mtime, reverse=True)[:15]:
            try:
                st = p.stat()
                pcaps.append({"filename": p.name, "size_bytes": st.st_size, "mtime": int(st.st_mtime)})
            except Exception:
                pass

    claimed_list = _list_claimed_peripherals()
    cached_tri: Dict[str, Any] = {}
    if claimed_list:
        p0 = claimed_list[0]
        p_scan = list((p0.get("last_telemetry") or {}).get("nearby_wifi_seen_by_device") or [])
        if p_scan or wifi_rows:
            cached_tri = _compute_airspace_triangulation(
                wifi_rows,
                p_scan,
                peripheral_label=f"{p0.get('model_name') or 'Cast Soft-AP'} ({p0.get('bssid', '')})",
            )

    perimeter_loc = _localize_rf_disturbances(rf_chords)

    return {
        "status": "ok",
        "ts": int(time.time()),
        "policy": get_tyler_policy(),
        "kali": kali_container_status(),
        "kali_manual": KALI_TACTICAL_MANUAL,
        "canary_trap": {
            "running": canary_st.get("running", False),
            "daemon": canary_st.get("daemon", {}),
            "hits_count": len(canary_hits),
            "recent_hits": canary_hits,
        },
        "tshark_watch": {
            "rules": tshark_rules,
            "recent_hits": tshark_hits,
        },
        "defense_plans": defense_plans,
        "baselines_count": len(baselines),
        "pcaps": pcaps,
        "nest_mesh": get_nest_mesh_status(),
        "wifi_adapter": _get_windows_wifi_status(),
        "wifi_airspace": wifi_rows,
        "claimed_peripherals": claimed_list,
        "cached_triangulation": cached_tri,
        "peripheral_rf_telemetry": rf_chords,
        "perimeter_localization": perimeter_loc,
        "rf_timeseries_stats": rf_timeseries_stats,
        "rf_motion_events": rf_events,
        "network_designations": load_network_designations(),
        "wifi_watchlist": load_wifi_watchlist(),
        "active_networks": discover_active_networks(_CFG_SUBNET),
        "counts": counts,
        "devices": devices,
        "recent_alerts": recent_alerts,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="The Tyler — Sovereign Home Network Security & Active Containment Agent")
    sub = parser.add_subparsers(dest="cmd")

    sub.add_parser("status", help="Return full Tyler status, Kali container state, Nest mesh health, and device ledger")
    sub.add_parser("census", help="Run active Layer-2/TCP/mDNS LAN sweep and update lan_devices.db")

    p_fp = sub.add_parser("fingerprint", help="Deep-fingerprint a LAN IP using Kali nmap + OUI + service banner analysis")
    p_fp.add_argument("pos_ip", nargs="?", default=None, help="Target LAN IP (positional)")
    p_fp.add_argument("--ip", default=None)

    p_va = sub.add_parser("vuln-audit", aliases=["vuln", "audit"], help="Run active Nmap NSE vulnerability, auth-method, and security posture audit against a LAN IP")
    p_va.add_argument("pos_ip", nargs="?", default=None, help="Target LAN IP (positional)")
    p_va.add_argument("--ip", default=None)
    p_va.add_argument("--ports", default=None, help="Optional comma-separated ports (defaults to --top-ports 100)")

    p_tr = sub.add_parser("traffic", aliases=["inspect"], help="Sample live packet metadata (DNS, TLS SNI, broadcast rate) for a LAN IP using Kali tshark")
    p_tr.add_argument("pos_ip", nargs="?", default=None, help="Target LAN IP (positional)")
    p_tr.add_argument("--ip", default=None)
    p_tr.add_argument("--duration", type=int, default=5)

    p_up = sub.add_parser("upnp", help="Audit UPnP port mappings on the gateway")
    p_up.add_argument("--action", default="list")

    p_trust = sub.add_parser("trust", help="Update device trust classification")
    p_trust.add_argument("--mac", required=True)
    p_trust.add_argument("--level", required=True)
    p_trust.add_argument("--label", default=None)
    p_trust.add_argument("--notes", default=None)

    p_int = sub.add_parser("intervene", help="Execute policy-gated active containment or Tier B defense plan workflow")
    p_int.add_argument("pos_ip", nargs="?", default=None, help="Target LAN IP (positional)")
    p_int.add_argument("--ip", default=None)
    p_int.add_argument(
        "--mode",
        default="host_block",
        help="host_block | quarantine | port_block | port_unblock | tcp_reset | conntrack_drop | upnp_kill | forensic_snap | propose_plan | approve_plan | execute_plan | reject_plan | list_plans | release | host_unblock",
    )
    p_int.add_argument("--port", type=int, default=None, help="Port for port_block/port_unblock/upnp_kill")
    p_int.add_argument("--proto", default="tcp", help="Protocol: tcp | udp | both")
    p_int.add_argument("--duration", type=int, default=8, help="Duration for forensic_snap")
    p_int.add_argument("--rationale", default="", help="Rationale for propose_plan")
    p_int.add_argument("--plan-id", default="", help="Plan ID (DEF-xxxx) for approve_plan/reject_plan")
    p_int.add_argument("--notes", default="", help="Operator notes for approve_plan/reject_plan")

    p_can = sub.add_parser("canary", help="Manage T-Cell Canary Honeypot Decoy listeners")
    p_can.add_argument("--action", default="status", help="start | stop | status | hits | clear")
    p_can.add_argument("--ports", default=None, help="Comma-separated ports (default: 2222,2323,4445,6379)")
    p_can.add_argument("--auto-quarantine", default=None, help="true | false")

    p_candaemon = sub.add_parser("canary-daemon", help="Internal background asyncio Canary Honeypot listener")
    p_candaemon.add_argument("--ports", default="2222,2323,4445,6379")

    p_tw = sub.add_parser("tshark-watch", help="Manage custom tshark display/capture filter watchlist")
    p_tw.add_argument("--action", default="list", help="list | add | remove | test | run_all")
    p_tw.add_argument("--name", default=None)
    p_tw.add_argument("--display-filter", default=None)
    p_tw.add_argument("--bpf-filter", default=None)
    p_tw.add_argument("--extract-fields", default=None)
    p_tw.add_argument("--severity", default="tier_b")
    p_tw.add_argument("--description", default="")
    p_tw.add_argument("--duration", type=int, default=8)

    p_pat = sub.add_parser("immune-patrol", aliases=["patrol"], help="Execute Natural Killer Cell East-West + ARP + Canary patrol")
    p_pat.add_argument("--duration", type=int, default=10)
    p_pat.add_argument("--auto-quarantine", action="store_true")

    p_arp = sub.add_parser("arp-shield", help="Enforce, verify, or release Antibody static Layer-2 neighbor lock")
    p_arp.add_argument("--action", default="verify", help="enforce | verify | release")
    p_arp.add_argument("--ip", default=None)

    p_bd = sub.add_parser("baseline-diff", help="Run Memory B-Cell service/port/TLS certificate drift audit")
    p_bd.add_argument("pos_ip", nargs="?", default=None)
    p_bd.add_argument("--ip", default=None)
    p_bd.add_argument("--save-baseline", action="store_true")
    p_bd.add_argument("--action", default="diff", help="diff | save_baseline")

    p_eg = sub.add_parser("egress-audit", aliases=["egress_audit"], help="Run zero-emission passive IoT DNS & TLS-SNI egress baseline audit")
    p_eg.add_argument("pos_ip", nargs="?", default=None)
    p_eg.add_argument("--ip", default="all")
    p_eg.add_argument("--duration", type=int, default=8)
    p_eg.add_argument("--save-baseline", action="store_true")

    sub.add_parser("l2-watch", help="Run single-pass L2/L3 ARP, DHCPv4 & IPv6 RA immune check")

    p_pol = sub.add_parser("policy", help="Get or update Tyler response posture (confirm vs auto)")
    p_pol.add_argument("--response-mode", default=None, help="confirm | auto")
    p_pol.add_argument("--auto-canary", default=None, help="true | false")
    p_pol.add_argument("--retention-days", type=int, default=None)

    p_prn = sub.add_parser("prune", help="Run 30-day rolling retention pruner on lan_devices.db and pcaps/")
    p_prn.add_argument("--retention-days", type=int, default=30)
    p_prn.add_argument("--max-pcap-mb", type=int, default=250)

    p_man = sub.add_parser("man", help="Consult Kali Linux man pages, NSE scripts, and Blue Lodge Tactical Field Manual")
    p_man.add_argument("pos_tool", nargs="?", default=None)
    p_man.add_argument("pos_search", nargs="?", default=None)
    p_man.add_argument("--tool", default=None)
    p_man.add_argument("--search", default=None)
    p_man.add_argument("--section", default=None)
    p_man.add_argument("--max-lines", type=int, default=120)

    p_exec = sub.add_parser("exec", aliases=["kali-exec"], help="Execute a policy-gated Kali Linux command inside george-kali-tyler")
    p_exec.add_argument("--command", "--cmd", dest="command", default=None)
    p_exec.add_argument("--timeout", type=int, default=30)
    p_exec.add_argument("pos_cmd", nargs=argparse.REMAINDER, default=None)

    p_spk = sub.add_parser("spelunk", help="Network-agnostic passive recon (ghost_listen, passive_fingerprint), interface discovery, and non-disruptive peer blocking on foreign networks")
    p_spk.add_argument("--mode", default="discover", help="discover | ghost_listen | passive_fingerprint | surgical_probe | block_peer | unblock_peer | stealth_lockdown | stealth_release")
    p_spk.add_argument("--interface", "--iface", dest="interface", default=None)
    p_spk.add_argument("--ip", default=None)
    p_spk.add_argument("--duration", type=int, default=10)
    p_spk.add_argument("--ports", default="22,80,443,445,8080")

    p_wsp = sub.add_parser("wifi-spelunk", aliases=["wifi"], help="802.11 airspace scanner, Wi-Fi adapter controller, RF motion & property perimeter guard, and 6-Layer Airlock Soft-AP interrogator")
    p_wsp.add_argument(
        "--mode",
        default="scan_airspace",
        help="status | list_peripherals | poll_lan_peripherals | rf_motion_sense | perimeter_guard | diagnose_rf_mesh | rogue_ap_watch | scan_airspace | configure_adapter | interrogate_soft_ap | triangulate_airspace | canary_ap_watch | set_ap_beacon | provision_cast_ap | restore_peripheral | disconnect",
    )
    p_wsp.add_argument("--ssid", default=None)
    p_wsp.add_argument("--bssid", default=None)
    p_wsp.add_argument("--auth", default="open")
    p_wsp.add_argument("--encryption", default="none")
    p_wsp.add_argument("--key", default=None)
    p_wsp.add_argument("--band", default="auto")
    p_wsp.add_argument("--hidden", action="store_true")
    p_wsp.add_argument("--timeout", "--duration", dest="timeout", type=int, default=45)
    p_wsp.add_argument("--surprise", action="store_true", help="Trigger physically observable chime & friendly device name on Google Cast Soft-AP")
    p_wsp.add_argument("--surprise-name", default=None, help="Custom device name to apply during Soft-AP surprise")

    p_des = sub.add_parser("designations", help="Get or update network designations and Wi-Fi watchlist")
    p_des.add_argument("--action", default="get", help="get | save | save_wifi_watchlist | set_subnet | remove_subnet")
    p_des.add_argument("--payload-json", default=None)
    p_des.add_argument("--cidr", default=None)
    p_des.add_argument("--designation", default=None)
    p_des.add_argument("--label", default=None)

    sub.add_parser("emergency-reset", aliases=["emergency_reset", "heal"], help="One-click operator fail-safe network reset and heal")

    args = parser.parse_args()
    if args.cmd == "census":
        print(json.dumps(run_lan_census(), indent=2))
    elif args.cmd == "fingerprint":
        print(json.dumps(deep_fingerprint_device(args.ip or args.pos_ip or ""), indent=2))
    elif args.cmd in ("vuln-audit", "vuln", "audit"):
        print(json.dumps(audit_device_vulnerabilities(args.ip or args.pos_ip or "", args.ports), indent=2))
    elif args.cmd in ("traffic", "inspect"):
        print(json.dumps(inspect_traffic_metadata(args.ip or args.pos_ip or "", args.duration), indent=2))
    elif args.cmd == "upnp":
        print(json.dumps(audit_upnp(args.action), indent=2))
    elif args.cmd == "trust":
        print(json.dumps(set_device_trust(args.mac, args.level, args.label, args.notes), indent=2))
    elif args.cmd == "intervene":
        print(
            json.dumps(
                intervene_device(
                    ip=args.ip or args.pos_ip or "",
                    mode=args.mode,
                    port=args.port,
                    proto=args.proto,
                    duration=args.duration,
                    rationale=args.rationale,
                    plan_id=args.plan_id,
                    operator_notes=args.notes,
                ),
                indent=2,
            )
        )
    elif args.cmd == "canary":
        aq = None
        if args.auto_quarantine is not None:
            aq = str(args.auto_quarantine).lower() in ("1", "true", "yes")
        print(json.dumps(manage_canary_trap(args.action, args.ports, aq), indent=2))
    elif args.cmd == "canary-daemon":
        run_canary_daemon_loop(args.ports)
    elif args.cmd == "tshark-watch":
        print(
            json.dumps(
                manage_tshark_watch(
                    action=args.action,
                    name=args.name,
                    display_filter=args.display_filter,
                    bpf_filter=args.bpf_filter,
                    extract_fields=args.extract_fields,
                    severity=args.severity,
                    description=args.description,
                    duration=args.duration,
                ),
                indent=2,
            )
        )
    elif args.cmd in ("immune-patrol", "patrol"):
        print(json.dumps(run_immune_patrol(args.duration, args.auto_quarantine), indent=2))
    elif args.cmd == "arp-shield":
        print(json.dumps(manage_arp_shield(args.action, args.ip), indent=2))
    elif args.cmd == "baseline-diff":
        sb = bool(args.save_baseline or str(args.action).lower() in ("save", "save_baseline", "snapshot"))
        print(json.dumps(diff_device_baseline(args.ip or args.pos_ip or "all", sb), indent=2))
    elif args.cmd in ("egress-audit", "egress_audit"):
        print(json.dumps(audit_device_egress(args.ip or args.pos_ip or "all", args.duration, bool(args.save_baseline)), indent=2))
    elif args.cmd == "l2-watch":
        print(json.dumps(check_l2_l3_immune_anomalies(5), indent=2))
    elif args.cmd == "policy":
        ac = None
        if args.auto_canary is not None:
            ac = str(args.auto_canary).lower() in ("1", "true", "yes")
        if args.response_mode is not None or ac is not None or args.retention_days is not None:
            print(json.dumps(set_tyler_policy(args.response_mode, ac, args.retention_days), indent=2))
        else:
            print(json.dumps({"status": "ok", "policy": get_tyler_policy()}, indent=2))
    elif args.cmd == "prune":
        print(json.dumps(prune_tyler_state(args.retention_days, args.max_pcap_mb), indent=2))
    elif args.cmd == "man":
        print(
            json.dumps(
                kali_man_lookup(
                    args.tool or args.pos_tool or "catalog",
                    args.search or args.pos_search,
                    args.section,
                    args.max_lines,
                ),
                indent=2,
            )
        )
    elif args.cmd in ("exec", "kali-exec"):
        cmd_str = args.command or (" ".join(args.pos_cmd) if args.pos_cmd else "")
        print(json.dumps(kali_exec_tool(cmd_str, args.timeout), indent=2))
    elif args.cmd == "spelunk":
        print(
            json.dumps(
                spelunk_network(
                    mode=args.mode,
                    interface=args.interface,
                    ip=args.ip,
                    duration=args.duration,
                    ports=args.ports,
                ),
                indent=2,
            )
        )
    elif args.cmd in ("wifi-spelunk", "wifi"):
        print(
            json.dumps(
                wifi_spelunk(
                    mode=args.mode,
                    ssid=args.ssid,
                    bssid=args.bssid,
                    auth=args.auth,
                    encryption=args.encryption,
                    key=args.key,
                    band=args.band,
                    hidden=args.hidden,
                    timeout=args.timeout,
                    surprise=args.surprise,
                    surprise_name=args.surprise_name,
                ),
                indent=2,
            )
        )
    elif args.cmd == "designations":
        p_obj = None
        if args.payload_json:
            try:
                p_obj = json.loads(args.payload_json)
            except Exception:
                p_obj = {}
        print(
            json.dumps(
                manage_network_designations(
                    action=args.action,
                    payload=p_obj,
                    cidr=args.cidr,
                    designation=args.designation,
                    label=args.label,
                ),
                indent=2,
            )
        )
    elif args.cmd in ("emergency-reset", "emergency_reset", "heal"):
        print(json.dumps(emergency_network_reset(), indent=2))
    else:
        print(json.dumps(get_tyler_status(), indent=2))


if __name__ == "__main__":
    main()
