# MQTT Integration

George can publish and subscribe to MQTT topics via the `/mqtt` slash command
and the `george-mqtt` MCP server. This enables IoT monitoring, home automation,
and general-purpose message passing.

---

## Dependency: mosquitto-clients

George uses **mosquitto-clients** — two small C binaries (`mosquitto_pub` and
`mosquitto_sub`) from the [Eclipse Mosquitto](https://mosquitto.org/) project.

### What it is

| Detail | Value |
|--------|-------|
| Language | **C** (compiled binary, no interpreter needed) |
| Size | **~200 KB** installed (both binaries combined) |
| Runtime deps | libmosquitto (~80 KB shared lib), openssl (already installed) |
| Total footprint | **< 1 MB** including all shared libraries |
| Build system | CMake / C compiler — but we install pre-built packages |
| Python/Node.js/Java | **None** — pure C, zero scripting language dependencies |

mosquitto-clients is the CLI portion of Eclipse Mosquitto (the full broker is a
separate package). George only needs the clients, not the broker.

### Installation

The installer (`install.sh`) prompts during setup if `mosquitto_pub` is not found:

```
● Optional: mosquitto-clients enables MQTT pub/sub messaging.
  Without it, /mqtt commands will not be available.
  Install mosquitto-clients for MQTT support? [y/N]
```

Manual installation by platform:

| Platform | Command |
|----------|---------|
| Debian / Ubuntu / ChromeOS (Crostini) | `sudo apt install mosquitto-clients` |
| Alpine / iSH | `apk add mosquitto-clients` |
| Termux (Android) | `pkg install mosquitto` |
| macOS (Homebrew) | `brew install mosquitto` |
| Fedora / RHEL | `dnf install mosquitto` |

Verify installation:

```bash
mosquitto_pub --help | head -1
# mosquitto_pub is a simple mqtt client that will publish a message...

mosquitto_sub --help | head -1
# mosquitto_sub is a simple mqtt client that will subscribe to a set of topics...
```

---

## Architecture

```
                                    ┌──────────────────┐
  User / LLM Agent                  │   MQTT Broker    │
     │                              │ (broker.emqx.io) │
     │  /mqtt pub sensors/temp 22   │                  │
     ▼                              └────────┬─────────┘
  ┌─────────┐    ┌──────────┐               │
  │  lodge   │───▶│lib/mqtt.sh│──mosquitto_pub──▶ PUBLISH
  │  (REPL)  │    │          │               │
  │          │    │          │◀─mosquitto_sub──◀ SUBSCRIBE
  └─────────┘    └──────────┘               │
     │                │                      │
     │                ▼                      │
     │          ┌──────────┐                 │
     │          │ mqtt.db  │  SQLite:        │
     │          │ (topics  │  topic tracking  │
     │          │  + msgs) │  message history │
     │          └──────────┘                 │
     │                                       │
     │  MCP path (LLM tool calls):           │
     ▼                                       │
  ┌──────────────────────┐                   │
  │ lib/mcp_server_mqtt.sh│──mqtt_publish()──▶
  │ (JSON-RPC over stdio) │◀─mqtt_subscribe()◀
  └──────────────────────┘
```

### How binary protocol is handled

MQTT is a binary protocol — packets use fixed headers, variable-length encoding,
and binary flags (CONNECT, CONNACK, PUBLISH, SUBSCRIBE, PINGREQ, etc.). George
does **not** implement any binary framing. The `mosquitto_pub` and `mosquitto_sub`
binaries handle all protocol encoding/decoding internally. George passes
human-readable parameters (topic, message, QoS level) and reads human-readable
output.

---

## Slash Command: `/mqtt`

### Subcommands

| Command | Description |
|---------|-------------|
| `/mqtt setup [broker:port]` | Configure broker (interactive or one-shot) |
| `/mqtt pub <topic> <message>` | Publish a message |
| `/mqtt sub <topic> [count] [timeout]` | Subscribe and read messages |
| `/mqtt status` | Test broker connectivity |
| `/mqtt config` | Show current configuration |
| `/mqtt topics` | List tracked topics (from SQLite) |
| `/mqtt history [topic] [count]` | Show message history |

### Examples

```bash
# One-shot setup (public broker, no auth)
/mqtt setup broker.emqx.io:1883

# Interactive setup (prompts for all options)
/mqtt setup

# Publish sensor data
/mqtt pub sensors/temperature "22.5"

# Publish with QoS 2 and retain flag
/mqtt pub home/thermostat/setpoint "21.0" --qos 2 --retain

# Read the last retained message on a topic
/mqtt sub home/thermostat/setpoint

# Wait for 5 messages (max 30 seconds)
/mqtt sub sensors/# 5 30

# Check connectivity
/mqtt status

# See all topics George has used
/mqtt topics

# Show last 20 messages for a topic
/mqtt history sensors/temperature 20
```

---

## MCP Server: george-mqtt

The MCP server exposes MQTT as tools that the LLM can call autonomously.

### Tools

| Tool | Parameters | Description |
|------|-----------|-------------|
| `mqtt_publish` | `topic` (required), `message` (required), `qos` (0-2), `retain` (bool) | Publish to a topic |
| `mqtt_subscribe` | `topic` (required), `count` (default 1), `timeout` (default 10s) | Read messages from a topic |
| `mqtt_status` | (none) | Check broker connectivity |

### Registration

The server is registered automatically. Manual registration:

```bash
/mcp add george-mqtt "bash $LODGE_DIR/lib/mcp_server_mqtt.sh" "MQTT pub/sub"
/mcp start george-mqtt
```

### LLM Usage

When MCP is enabled, George can use MQTT tools autonomously:

> "Check the temperature sensor"
> → George calls `mqtt_subscribe` with topic `sensors/temperature`

> "Set the thermostat to 21 degrees"
> → George calls `mqtt_publish` with topic `home/thermostat/setpoint`, message `21`

---

## Configuration

### Config file: `~/.george/mqtt.conf`

```ini
MQTT_BROKER=broker.emqx.io
MQTT_PORT=1883
MQTT_CLIENT_ID=george-12345
MQTT_PROTOCOL=5
MQTT_KEEPALIVE=60
MQTT_TLS=0
MQTT_CAFILE=
MQTT_CERTFILE=
MQTT_KEYFILE=
```

Non-secret settings stored as KEY=VALUE (same pattern as `lodge.conf`).

### Credentials

Stored in George's encrypted vault (AES-256-CBC):

```bash
/secret set mqtt_username myuser
/secret set mqtt_password mypass
```

Or set via environment variables: `MQTT_USERNAME`, `MQTT_PASSWORD`.

### TLS Configuration

For encrypted connections (port 8883):

```bash
/mqtt setup secure.broker.io:8883
# Select TLS during interactive setup, or set manually:
```

Config values for TLS:
- `MQTT_TLS=1` — enable TLS
- `MQTT_CAFILE=/path/to/ca.pem` — CA certificate (optional, uses system CAs otherwise)
- `MQTT_CERTFILE=/path/to/client.pem` — client certificate (mutual TLS)
- `MQTT_KEYFILE=/path/to/client.key` — client private key (mutual TLS)

### MQTT Protocol Version

- `MQTT_PROTOCOL=5` — MQTT v5.0 (default, recommended)
- `MQTT_PROTOCOL=311` — MQTT v3.1.1 (for older brokers)

---

## Topic Tracking & Message History

George maintains a local SQLite database (`~/.george/mqtt.db`) that tracks:

### Topics table
Every topic George has published to or subscribed from, with:
- First seen / last used timestamps
- Use count
- Direction (publish, subscribe, or both)

### Messages table
Recent messages with:
- Topic, direction (in/out), payload, timestamp
- Indexed by topic and timestamp for fast lookups
- Auto-pruned to 1000 messages per topic

This gives George memory of past MQTT interactions. The LLM can query history
to understand device patterns, track sensor trends, or recall past commands.

---

## Functional Testing

### Option A: Public MQTT Broker

The easiest way to test is with EMQX's free public broker:

```bash
# Setup
/mqtt setup broker.emqx.io:1883

# Round-trip test
/mqtt pub george/test/$(date +%s) "hello from george"
/mqtt sub george/test/+ 1 10
```

### Option B: Local Docker Broker

For isolated testing:

```bash
# Start Eclipse Mosquitto in Docker
docker run -d --name mqtt-test -p 1883:1883 \
  eclipse-mosquitto:2 mosquitto -c /mosquitto-no-auth.conf

# Configure George
/mqtt setup localhost:1883

# Test
/mqtt pub test/docker "round-trip"
/mqtt sub test/docker

# Cleanup
docker rm -f mqtt-test
```

### Option C: Verify with mosquitto CLI directly

```bash
# Terminal 1: Subscribe
mosquitto_sub -h broker.emqx.io -t "george/test/#" -v

# Terminal 2: Publish via George
/mqtt pub george/test/manual "direct test"
# → Terminal 1 should show the message
```

---

## Key Files

| File | Purpose |
|------|---------|
| `lib/mqtt.sh` | MQTT library — config, publish, subscribe, tracking |
| `lib/mcp_server_mqtt.sh` | MCP server — JSON-RPC wrapper around mqtt.sh |
| `tests/test_mqtt.sh` | Unit tests — mocked mosquitto, no real broker needed |
| `tests/test_mcp_server_mqtt.sh` | MCP server tests — protocol compliance + tool calls |
| `docs/MQTT.md` | This document |
| `~/.george/mqtt.conf` | Broker configuration (persisted) |
| `~/.george/mqtt.db` | SQLite — topic tracking + message history |
