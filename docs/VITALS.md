# System Vitals

George monitors the physical resources of his host device — disk space,
RAM, battery, WiFi signal, and cell signal — so he can make intelligent
decisions about what operations are safe to attempt. This is his
"stateful awareness of living arrangements."

> **How vitals fit the dual-loop architecture:** The macro strategist checks `vitals_preflight()` before
> committing to a plan. Between execution steps, the inner loop calls `vitals_guard_disk` and
> `vitals_guard_ram` to bail early if resources drop. In `/ask` mode (quick questions), only
> warnings are injected — zero overhead when everything is healthy.

## Why It Matters

George runs on a mobile device with finite resources. Before attempting
disk-heavy operations, network calls, or long-running tasks, he checks
his vitals. If disk is critically low, he won't write files. If the
network is unreachable, he won't attempt API calls. If battery is dying,
he'll keep tasks short. This happens automatically — vitals are injected
into his system prompt and guard functions protect every agent step.

## Slash Commands

```
/vitals              Full color-coded system dashboard
/vitals context      Compact one-line vitals for LLM prompt
/vitals disk         Disk space details (free / total / % / status)
/vitals ram          RAM / memory details (available / total / used)
/vitals battery      Battery level and charging status
/vitals wifi         WiFi SSID, RSSI, speed, status
/vitals cell         Cell tower type and signal strength
/vitals network      Quick reachability check (1.1.1.1:53)
/vitals refresh      Force cache refresh + show dashboard
/vitals check        Run pre-flight resource check
/vitals help         Show all subcommands
```

## Thresholds

All thresholds are configurable via environment variables:

| Resource | Warning | Critical | Env Var (Warn) | Env Var (Crit) |
|----------|---------|----------|----------------|----------------|
| Disk | <500 MB free | <100 MB free | `VITALS_DISK_WARN_MB` | `VITALS_DISK_CRIT_MB` |
| RAM | <200 MB avail | <100 MB avail | `VITALS_RAM_WARN_MB` | `VITALS_RAM_CRIT_MB` |
| Battery | <15% | <5% | `VITALS_BATTERY_WARN` | `VITALS_BATTERY_CRIT` |
| WiFi | RSSI < -75 dBm | Disconnected | (hardcoded) | (hardcoded) |

Set thresholds in your shell (e.g. `~/.bashrc`) or before launching lodge:

```bash
export VITALS_DISK_WARN_MB=1000
export VITALS_DISK_CRIT_MB=200
```

## Status Levels

Each resource reports one of three states:

- **ok** — Resource is healthy, no action needed
- **warn** — Resource is getting low, George will mention it
- **critical** — Resource is dangerously low, George may block operations

Battery has a special case: if charging (`CHARGING` or `FULL`), the
status is always `ok` regardless of percentage.

## How It Works

### Prompt Injection

Vitals are automatically injected into George's system prompt via
`memory_build_system_prompt`:

- **Ask mode** (quick questions): Only warnings are injected. If
  everything is healthy, zero tokens are used
- **Plan/Task mode** (complex work): Full vitals context is always
  included (~30-50 tokens), e.g.:
  `[Vitals: Disk 2.1GB/24GB | RAM 1.8GB/12GB | Bat 72% | WiFi -52dBm]`

This means George always knows his resource state and can factor it
into planning decisions.

### Guard Functions

Guard functions are called automatically at key points:

| Guard | Where Called | Effect |
|-------|-------------|--------|
| `vitals_preflight("strict")` | `agent_run()` start | Aborts entire task if any resource is critical |
| `vitals_guard_disk` | `agent_run()` between steps | Aborts remaining steps if disk goes critical |
| `vitals_guard_ram` | `agent_run()` between steps | Warns but continues if RAM is low |
| `vitals_guard_disk` | `tools_exec_bash()` | Blocks bash execution if disk is critically low |

### Caching

Sensor reads (especially Termux API calls) are cached for 30 seconds
to avoid hammering the system. The cache refreshes automatically when
stale. Use `/vitals refresh` to force an immediate refresh.

## API Reference

### Raw Sensors

| Function | Returns | Source |
|----------|---------|--------|
| `vitals_disk_free_mb` | Free disk MB | `df -m` |
| `vitals_disk_total_mb` | Total disk MB | `df -m` |
| `vitals_disk_pct` | Disk usage % | `df -m` |
| `vitals_ram_free_mb` | Available RAM MB | `free -m` |
| `vitals_ram_total_mb` | Total RAM MB | `free -m` |
| `vitals_ram_used_mb` | Used RAM MB | `free -m` |
| `vitals_battery_pct` | Battery 0-100 | Termux API / sysfs |
| `vitals_battery_status` | CHARGING / DISCHARGING / FULL | Termux API / sysfs |
| `vitals_wifi_rssi` | RSSI in dBm | Termux API / /proc |
| `vitals_wifi_ssid` | WiFi network name | Termux API / iwgetid |
| `vitals_wifi_speed` | Link speed Mbps | Termux API |
| `vitals_cell_signal` | Signal dBm/ASU | Termux API |
| `vitals_cell_type` | LTE / NR / etc | Termux API |
| `vitals_net_reachable` | exit 0 or 1 | TCP to 1.1.1.1:53 |

### Status Functions

| Function | Returns |
|----------|---------|
| `vitals_disk_status` | ok / warn / critical |
| `vitals_ram_status` | ok / warn / critical |
| `vitals_battery_status_level` | ok / warn / critical |
| `vitals_wifi_status` | ok / warn / critical / none |

### Guard Functions

| Function | Blocks On | Returns |
|----------|-----------|---------|
| `vitals_guard_disk` | critical | 0 ok, 1 blocked |
| `vitals_guard_ram` | critical | 0 ok, 1 blocked |
| `vitals_guard_battery` | critical | 0 ok, 1 blocked |
| `vitals_guard_network` | unreachable | 0 ok, 1 blocked |
| `vitals_preflight(severity)` | any critical (if strict) | 0 ok, 1+ issues |

### Context Strings

| Function | Output |
|----------|--------|
| `vitals_context` | `[Vitals: Disk 2.1GB/24GB \| RAM 1.8GB/12GB \| Bat 72%]` |
| `vitals_context_warnings` | `[WARNING: RAM 150MB free, Battery 12%]` or empty |
| `vitals_dashboard` | Full color-coded terminal display |

## Hardware Notes

George runs on a Galaxy Fold 7 with Snapdragon 8 Elite and 12GB RAM:

- **Ollama + model** consumes ~4-5GB RAM, leaving ~6-7GB for everything else
- **Battery** drain is significant during LLM inference — vitals help
  George decide whether to use the fast (ask) or thorough (task) tier
- **Termux:API** is required for battery, WiFi, and cell readings
  (disk and RAM work on any Linux system via `df` and `free`)
- **WiFi vs Cell** — George tracks both and uses whichever is available;
  the guard function checks actual TCP reachability as the final word

> **Important:** Termux-API sensors (battery, WiFi, cell) are **disabled by
> default** because they hang inside proot environments. To enable them,
> set `export LODGE_TERMUX_API=1` in your shell. Only do this from
> **native Termux** — never from proot-distro.
>
> When disabled, disk and RAM vitals still work normally via standard
> Linux tools (`df`, `free`). Battery/WiFi/cell will simply report empty.

## Troubleshooting

**Battery/WiFi/Cell show "(not available)":**
Termux-API sensors are disabled by default. Enable with:
```bash
export LODGE_TERMUX_API=1
```
Also install Termux:API from F-Droid and run `pkg install termux-api`.
Only enable this from **native Termux** — these commands hang inside proot.

**Thresholds too sensitive:**
Raise them: `export VITALS_DISK_WARN_MB=200 VITALS_RAM_WARN_MB=100`

**Vitals stale:**
Run `/vitals refresh` to force a fresh sensor read.

**Guard blocking operations:**
If you know what you're doing, the guard functions respect severity
levels. The pre-flight check in `agent_run()` uses "strict" mode, which
aborts on any critical. Between steps, disk is strict and RAM is warn-only.
