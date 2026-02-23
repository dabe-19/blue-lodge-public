# Phone Integration

George has full phone integration via the Termux API. This gives him
location awareness, SMS access, call logs, WiFi info, and telephony
status — the same sensor data that any Android app can access.

## Prerequisites

1. **Termux:API app** — Install from F-Droid (not Google Play)
2. **termux-api package** — `pkg install termux-api` (inside Termux)
3. Android will prompt for permissions on first use of each feature

### Required Permissions

| Feature         | Android Permission          |
|-----------------|-----------------------------|
| Location        | ACCESS_FINE_LOCATION        |
| SMS             | READ_SMS, RECEIVE_SMS       |
| Call Log         | READ_CALL_LOG               |
| Telephony       | READ_PHONE_STATE            |
| WiFi Scan        | ACCESS_FINE_LOCATION        |

## Slash Commands

### Dashboard

```
/phone              Full phone dashboard (battery, carrier, WiFi, GPS)
/phone status       Same as /phone — shows everything at a glance
```

### Location

```
/phone location     Get current location via WiFi/cell towers (fast)
/phone location gps Get precise GPS fix (slower, better outdoors)
/phone where        One-line location summary for LLM context
```

The `where` subcommand produces a compact string like:
`Location: 38.8977° N, 77.0365° W (±15m)`

George can inject this into his prompts for location-based advice:
nearby restaurants, weather, directions, local services.

### SMS / Text Messages

```
/phone sms                    Last 10 inbox messages
/phone sms inbox [limit]      Read inbox with optional limit
/phone sms sent [limit]       Read sent messages
/phone sms all [limit]        Read all messages
/phone sms send <number> <message>   Send a text message
```

**Sending is permission-gated.** George will confirm before sending
because SMS costs money.

### Call Log

```
/phone calls [limit]     Recent call log (default: 10)
```

Shows caller name/number, duration, type (incoming/outgoing/missed),
and timestamp.

### Telephony / Carrier

```
/phone telephony    Carrier name, SIM info, data/network state
/phone cell         Cell tower info and signal strength
```

### WiFi

```
/phone wifi         Current WiFi connection info (SSID, speed, IP)
/phone wifi scan    Scan nearby WiFi networks
```

### Utility (Original Tools)

```
/phone battery      Battery level and charging status
/phone clip [text]  Get or set clipboard
/phone notify <msg> Send Android notification
/phone open <url>   Open URL in browser
/phone share <file> Share file via Android share sheet
/phone toast <msg>  Show toast popup
/phone vibrate      Vibrate the phone
```

## How It Works

All phone commands call the Termux API through helper functions in
`lib/phone.sh`. Each function:

1. Checks if the required `termux-*` command is available
2. Calls the Termux API with appropriate arguments
3. Parses the JSON response with `jq`
4. Formats output for human readability or LLM injection

### Location Providers

| Provider  | Speed  | Accuracy | Best For           |
|-----------|--------|----------|--------------------|
| network   | Fast   | ~50m     | Indoors, quick fix |
| gps       | Slow   | ~3m      | Outdoors, precise  |
| passive   | Instant| Varies   | Last known location|

The `network` provider is the default — it uses WiFi and cell tower
triangulation and works indoors. GPS is more accurate but can take
30+ seconds and may not work indoors.

### Fallback Behavior

If GPS times out, the location functions automatically fall back to
the network provider. If no provider returns data, George reports
"Location unavailable" rather than guessing.

### proot Limitation

**Important:** Termux API commands must run from the Termux shell,
not from inside proot-distro Ubuntu. If Blue Lodge is running under
proot, phone commands will not work and will display a helpful error.

See [PHONE_SETUP.md](PHONE_SETUP.md) for the full installation guide
including the proot workaround.

## Location-Based Advice

With location awareness, George can provide:

- **Weather context** — "It's likely raining where you are"
- **Local recommendations** — nearby food, services, landmarks
- **Travel awareness** — timezone, local customs
- **Emergency info** — nearest hospital, police station
- **Navigation** — directions between known locations

George injects location context into his prompts automatically when
the `phone_status_context()` function is called during planning.

## Architecture

```
lodge (REPL)
  └── _cmd_phone()          ← command dispatcher
        └── lib/phone.sh    ← Termux API wrappers
              ├── phone_location()
              ├── phone_sms_list()
              ├── phone_telephony_info()
              ├── phone_call_log()
              ├── phone_wifi_info()
              └── phone_dashboard()
                    └── termux-* commands (Termux:API)
```

## Testing

Run phone tests with:
```bash
bash tests/test_phone.sh
```

Tests verify function existence, output formatting, and fallback
behavior. Actual Termux API calls are tested only if running on
Android with the Termux:API app installed.
