---
title: "The Tyler — Operator Quick-Start, Safety Guide & RF Physics Reference"
description: "User-friendly guide to enabling, safely operating, and honestly interpreting The Tyler core security module (disabled by default)."
subsystem: "security"
tags:
  - tyler
  - security
  - kali
  - rf-mesh
  - guide
---

# The Tyler — Operator Quick-Start & Safety Guide

**The Tyler** is a built-in Blue Lodge core security module that is **disabled by default** on fresh installations because it requires an isolated Docker container (`george-kali-tyler`) and host-network inspection privileges.

> [!IMPORTANT]
> When disabled, `george-web` does **not** pull or start the Kali container, does **not** bind Canary Honeypot ports, and does **not** seed `rx_tyler_immune` or Tyler cron sweeps.

---

## 1. Enabling The Tyler Safely

1. Verify Docker is running (`docker info`).
2. Enable the core module via the **App Store & Workshop** UI or CLI:
   ```bash
   ./lodge /app enable the-tyler
   ```
3. Optional: create `.george/config/tyler_household.json` (gitignored) to pin your own gateway IP/MAC, operator workstation IP, and custom floorplan layout.

---

## 2. Tool Safety Tiers (Start Here Without Breaking Anything)

Every action in The Tyler is classified into one of four safety tiers:

| Tier Badge | What It Does | Safe Starter Tools to Try First |
| :--- | :--- | :--- |
| **`PASSIVE / READ-ONLY`** | Zero transmitted probe packets; reads kernel ARP/routing tables, passive beacons, or local SQLite history. | `tyler_spelunk(mode="discover")`, `tyler_wifi_spelunk(mode="scan_airspace")`, `tyler_baseline_diff`, `tyler_kali_man(tool="catalog")` |
| **`ACTIVE LAN PROBE`** | Sends targeted Nmap/UPnP/ARP packets strictly inside RFC 1918 private LAN space. | `tyler_lan_census`, `tyler_upnp_audit`, `tyler_deep_fingerprint(ip="...")`, `tyler_vuln_audit(ip="...")` |
| **`EXPERIMENTAL RF LAB`** | Passive 802.11 RSSI link-margin tomography & 1D dual-sensor bearing heuristics. | `tyler_wifi_spelunk(mode="diagnose_rf_mesh")`, `rf_motion_sense`, `perimeter_guard`, `triangulate_airspace` |
| **`FIREWALL / TIER B`** | Modifies `iptables` / `conntrack` / static ARP entries. **Protected-IP Policy Gate** permanently blocks targeting your gateway, host, or workstation. | `tyler_arp_shield`, `tyler_intervene(action="propose_plan")` |

---

## 3. Honest RF Physics Reference (What the Wi-Fi Tripwire Can & Cannot Do)

The futuristic **Experimental RF Tripwire** schematic visualizes real 802.11 RSSI dBm telemetry across your household routers and visible APs. Both operators and George should keep its physical boundaries in mind:

- **What IS Reliable:**
  - **LAN & Wi-Fi Security Hygiene**: Rogue/Evil-Twin AP hunting (`rogue_ap_watch`), new close-proximity mobile hotspots (`TRANSIENT_PROXIMITY_TX`), and historical link-margin/SNR degradation (`diagnose_rf_mesh`).
  - **Near-Field Attenuation (`<1.5 m`) & Corroborated Multi-Chord Shifts**: Walking directly across the line-of-sight Fresnel zone near the workstation antenna produces a measurable `3–10 dB` RSSI drop.
- **What Is Physically Limited on Stock Consumer Wi-Fi:**
  - **Quantization & Sample Rate**: WSL2 `netsh` reports `Signal %` quantized to `0.5 dB` steps at ~0.3–1 Hz without OFDM subcarrier CSI phase. Single-chord swings can come from router automatic transmit power control (TPC), neighbor traffic, microwaves, wind, or rain — **not** necessarily human movement.
  - **1D Bearing vs. 2D Triangulation**: Two sensors (Workstation + 1 South-Wall peripheral) physically provide a **1D North-vs-South bearing differential (`Δ dB`)**, not true 2D `(x, y)` triangulation (which requires ≥3 non-collinear receivers).
  - **Cast `:8443` RTT Jitter**: Useful for Wi-Fi link-health and congestion diagnostics, **not** reliable physical motion sensing (power-save sleep and router queuing dominate RTT).
  - **Soft-AP Airlock Interrogation**: Temporarily disconnects the host Wi-Fi adapter (~14s) to query a peripheral's setup AP; keep this for intentional lab testing.

For hardware upgrades that deliver true 50–100 Hz CSI phase and through-glass 24 GHz `(x, y)` mmWave radar, see [PERIMETER_RF_SECURITY_BOM_AND_ARCHITECTURE.md](PERIMETER_RF_SECURITY_BOM_AND_ARCHITECTURE.md).
