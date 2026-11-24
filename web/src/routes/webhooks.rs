//! Sovereign Webhook Ingress Gateway (`POST /api/webhooks/:source`)
//!
//! Acts as an authenticated PLC-style Interrupt I/O Card at the edge of Blue Lodge:
//!   1. Enforces a strict 64 KB payload ceiling.
//!   2. Validates `source` and `event_type` identifiers against strict ASCII allowlists.
//!   3. Authenticates every request via constant-time HMAC-SHA256 (`X-Hub-Signature-256`,
//!      `X-Gitea-Signature`, `X-George-Signature`) or Bearer/Lodge token (`Authorization: Bearer`,
//!      `X-Lodge-Token`) against `.george/keys.conf` (`WEBHOOK_SECRET_<SOURCE>`) or `state.api_token`.
//!   4. Normalizes payloads from `gitea`/`github`, `tradingview`, `homeassistant`, and generic
//!      JSON sources into canonical Blue Lodge Event Bus envelopes (`webhook.<source>.<event>`).
//!   5. Injects the normalized envelope non-blockingly into `.george/ipc/event_bus.fifo` (with
//!      durable spool fallback) so `lib/ipc/event_bus.sh` applies debounce, trailing-edge
//!      coalescing, and concurrency credits.

use axum::{
    body::{to_bytes, Body},
    extract::{Path, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Json, Response},
};
use serde_json::{json, Value};
use std::io::Write;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::process::Command;

use crate::security::{constant_time_eq, TOKEN_HEADER};
use crate::state::AppState;

pub const MAX_WEBHOOK_BYTES: usize = 65_536;

// ── Self-Contained FIPS 180-4 SHA-256 & RFC 2104 HMAC-SHA256 ───────────────

const SHA256_K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

pub fn sha256(data: &[u8]) -> [u8; 32] {
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ];

    let bit_len = (data.len() as u64).wrapping_mul(8);
    let mut padded = Vec::with_capacity(((data.len() + 9 + 63) / 64) * 64);
    padded.extend_from_slice(data);
    padded.push(0x80);
    while (padded.len() % 64) != 56 {
        padded.push(0x00);
    }
    padded.extend_from_slice(&bit_len.to_be_bytes());

    for chunk in padded.chunks_exact(64) {
        let mut w = [0u32; 64];
        for (i, word) in chunk.chunks_exact(4).enumerate() {
            w[i] = u32::from_be_bytes([word[0], word[1], word[2], word[3]]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }

        let mut a = h[0];
        let mut b = h[1];
        let mut c = h[2];
        let mut d = h[3];
        let mut e = h[4];
        let mut f = h[5];
        let mut g = h[6];
        let mut hh = h[7];

        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let temp1 = hh
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(SHA256_K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = s0.wrapping_add(maj);

            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }

        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
        h[5] = h[5].wrapping_add(f);
        h[6] = h[6].wrapping_add(g);
        h[7] = h[7].wrapping_add(hh);
    }

    let mut out = [0u8; 32];
    for (i, word) in h.iter().enumerate() {
        out[i * 4..(i + 1) * 4].copy_from_slice(&word.to_be_bytes());
    }
    out
}

pub fn hmac_sha256(key: &[u8], message: &[u8]) -> [u8; 32] {
    let mut k_block = [0u8; 64];
    if key.len() > 64 {
        let hashed = sha256(key);
        k_block[..32].copy_from_slice(&hashed);
    } else {
        k_block[..key.len()].copy_from_slice(key);
    }

    let mut o_key_pad = [0x5cu8; 64];
    let mut i_key_pad = [0x36u8; 64];
    for i in 0..64 {
        o_key_pad[i] ^= k_block[i];
        i_key_pad[i] ^= k_block[i];
    }

    let mut inner_input = Vec::with_capacity(64 + message.len());
    inner_input.extend_from_slice(&i_key_pad);
    inner_input.extend_from_slice(message);
    let inner_hash = sha256(&inner_input);

    let mut outer_input = Vec::with_capacity(64 + 32);
    outer_input.extend_from_slice(&o_key_pad);
    outer_input.extend_from_slice(&inner_hash);
    sha256(&outer_input)
}

pub fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{:02x}", b)).collect()
}

// ── Identifier & Secret Helpers ────────────────────────────────────────────

pub fn is_valid_source(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 32
        && s.chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

pub fn sanitize_event_segment(raw: &str, default: &str) -> String {
    let cleaned: String = raw
        .trim()
        .to_ascii_lowercase()
        .chars()
        .map(|c| {
            if c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-' || c == '.' {
                c
            } else {
                '_'
            }
        })
        .take(48)
        .collect();
    let trimmed = cleaned.trim_matches(|c| c == '_' || c == '.');
    if trimmed.is_empty() {
        default.to_string()
    } else {
        trimmed.to_string()
    }
}

fn read_key_from_conf(conf_path: &std::path::Path, key_name: &str) -> Option<String> {
    let content = std::fs::read_to_string(conf_path).ok()?;
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let stripped = trimmed.strip_prefix("export ").unwrap_or(trimmed).trim();
        if let Some((k, v)) = stripped.split_once('=') {
            if k.trim() == key_name {
                let val = v
                    .trim()
                    .trim_matches('"')
                    .trim_matches('\'')
                    .trim()
                    .to_string();
                if !val.is_empty() {
                    return Some(val);
                }
            }
        }
    }
    None
}

pub fn resolve_webhook_secret(state: &AppState, source: &str) -> String {
    let upper = source.to_ascii_uppercase().replace('-', "_");
    let specific_key = format!("WEBHOOK_SECRET_{}", upper);
    let keys_conf = state.george_dir.join("keys.conf");
    let webhooks_json = state.george_dir.join("webhooks.json");

    if let Ok(v) = std::env::var(&specific_key) {
        if !v.trim().is_empty() {
            return v.trim().to_string();
        }
    }
    if let Some(v) = read_key_from_conf(&keys_conf, &specific_key) {
        return v;
    }
    if let Ok(raw) = std::fs::read_to_string(&webhooks_json) {
        if let Ok(val) = serde_json::from_str::<Value>(&raw) {
            if let Some(s) = val
                .get("secrets")
                .and_then(|sec| sec.get(source).or_else(|| sec.get("default")))
                .and_then(|v| v.as_str())
            {
                let trimmed = s.trim();
                if !trimmed.is_empty() {
                    return trimmed.to_string();
                }
            }
        }
    }
    if let Ok(v) = std::env::var("WEBHOOK_SECRET") {
        if !v.trim().is_empty() {
            return v.trim().to_string();
        }
    }
    if let Some(v) = read_key_from_conf(&keys_conf, "WEBHOOK_SECRET") {
        return v;
    }
    state.api_token.clone()
}

pub fn verify_webhook_auth(
    headers: &HeaderMap,
    body: &[u8],
    secret: &str,
    api_token: &str,
) -> Result<&'static str, &'static str> {
    // 1. Check HMAC-SHA256 signature headers
    for hdr_name in [
        "x-hub-signature-256",
        "x-gitea-signature",
        "x-george-signature",
    ] {
        if let Some(raw_sig) = headers.get(hdr_name).and_then(|v| v.to_str().ok()) {
            let provided = raw_sig
                .trim()
                .strip_prefix("sha256=")
                .unwrap_or(raw_sig.trim())
                .to_ascii_lowercase();
            if provided.len() != 64 || !provided.chars().all(|c| c.is_ascii_hexdigit()) {
                return Err("malformed HMAC-SHA256 signature header");
            }
            let expected_primary = hex_encode(&hmac_sha256(secret.as_bytes(), body));
            if constant_time_eq(provided.as_bytes(), expected_primary.as_bytes()) {
                return Ok("hmac-sha256");
            }
            if secret != api_token && !api_token.is_empty() {
                let expected_fallback = hex_encode(&hmac_sha256(api_token.as_bytes(), body));
                if constant_time_eq(provided.as_bytes(), expected_fallback.as_bytes()) {
                    return Ok("hmac-sha256");
                }
            }
            return Err("invalid HMAC-SHA256 signature");
        }
    }

    // 2. Check Authorization: Bearer <token> or X-Lodge-Token
    if let Some(auth_hdr) = headers.get(header::AUTHORIZATION).and_then(|v| v.to_str().ok()) {
        let token = auth_hdr
            .trim()
            .strip_prefix("Bearer ")
            .or_else(|| auth_hdr.trim().strip_prefix("bearer "))
            .unwrap_or("")
            .trim();
        if !token.is_empty() {
            if constant_time_eq(token.as_bytes(), secret.as_bytes())
                || (!api_token.is_empty() && constant_time_eq(token.as_bytes(), api_token.as_bytes()))
            {
                return Ok("bearer-token");
            }
            return Err("invalid Bearer token");
        }
    }

    if let Some(lodge_tok) = headers.get(TOKEN_HEADER).and_then(|v| v.to_str().ok()) {
        let token = lodge_tok.trim();
        if !token.is_empty() {
            if constant_time_eq(token.as_bytes(), secret.as_bytes())
                || (!api_token.is_empty() && constant_time_eq(token.as_bytes(), api_token.as_bytes()))
            {
                return Ok("lodge-token");
            }
            return Err("invalid X-Lodge-Token");
        }
    }

    Err("missing webhook authentication (provide X-Hub-Signature-256, X-Gitea-Signature, X-George-Signature, Authorization: Bearer, or X-Lodge-Token)")
}

// ── Source-Specific Payload Normalization ──────────────────────────────────

pub struct NormalizedWebhook {
    pub event_type: String,
    pub payload: Value,
    pub bridge_event: Option<(String, Value)>,
}

pub fn normalize_webhook_payload(
    source: &str,
    headers: &HeaderMap,
    raw_json: &Value,
) -> NormalizedWebhook {
    match source {
        "gitea" | "github" => {
            let hdr_event = headers
                .get("x-gitea-event")
                .or_else(|| headers.get("x-github-event"))
                .and_then(|v| v.to_str().ok())
                .unwrap_or_else(|| {
                    if raw_json.get("commits").is_some() || raw_json.get("ref").is_some() {
                        "push"
                    } else if raw_json.get("pull_request").is_some() {
                        "pull_request"
                    } else if raw_json.get("workflow_run").is_some() {
                        "workflow_run"
                    } else {
                        "event"
                    }
                });
            let ev_seg = sanitize_event_segment(hdr_event, "push");
            let event_type = format!("webhook.{}.{}", source, ev_seg);

            let repo = raw_json
                .pointer("/repository/full_name")
                .or_else(|| raw_json.pointer("/repository/name"))
                .and_then(|v| v.as_str())
                .unwrap_or("unknown");
            let git_ref = raw_json.get("ref").and_then(|v| v.as_str()).unwrap_or("");
            let branch = git_ref.strip_prefix("refs/heads/").unwrap_or(git_ref);
            let sender = raw_json
                .pointer("/sender/login")
                .or_else(|| raw_json.pointer("/pusher/name"))
                .or_else(|| raw_json.pointer("/pusher/login"))
                .and_then(|v| v.as_str())
                .unwrap_or("unknown");
            let head_sha = raw_json
                .get("after")
                .or_else(|| raw_json.pointer("/head_commit/id"))
                .or_else(|| raw_json.pointer("/pull_request/head/sha"))
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let commit_count = raw_json
                .get("commits")
                .and_then(|v| v.as_array())
                .map(|a| a.len())
                .unwrap_or(0);
            let action = raw_json.get("action").and_then(|v| v.as_str()).unwrap_or("");
            let conclusion = raw_json
                .pointer("/workflow_run/conclusion")
                .and_then(|v| v.as_str())
                .unwrap_or("");

            let norm_payload = json!({
                "source": source,
                "event": ev_seg,
                "repo": repo,
                "ref": git_ref,
                "branch": branch,
                "sender": sender,
                "head_sha": head_sha,
                "commit_count": commit_count,
                "action": action,
                "conclusion": conclusion,
            });

            let bridge_event = if ev_seg == "workflow_run" && conclusion.eq_ignore_ascii_case("failure") {
                Some((
                    "ci.build_failure".to_string(),
                    json!({
                        "repo": repo,
                        "branch": branch,
                        "head_sha": head_sha,
                        "sender": sender,
                        "workflow": raw_json.pointer("/workflow_run/name").and_then(|v| v.as_str()).unwrap_or("ci"),
                    }),
                ))
            } else {
                None
            };

            NormalizedWebhook {
                event_type,
                payload: norm_payload,
                bridge_event,
            }
        }
        "tradingview" => {
            let ticker = raw_json
                .get("ticker")
                .or_else(|| raw_json.get("symbol"))
                .and_then(|v| v.as_str())
                .unwrap_or("UNKNOWN");
            let action = raw_json
                .get("action")
                .or_else(|| raw_json.get("side"))
                .or_else(|| raw_json.pointer("/strategy/order_action"))
                .and_then(|v| v.as_str())
                .unwrap_or("alert");
            let price = raw_json
                .get("price")
                .or_else(|| raw_json.get("close"))
                .cloned()
                .unwrap_or(Value::Null);
            let interval = raw_json
                .get("interval")
                .or_else(|| raw_json.get("timeframe"))
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let message = raw_json
                .get("message")
                .or_else(|| raw_json.get("comment"))
                .and_then(|v| v.as_str())
                .unwrap_or("");

            NormalizedWebhook {
                event_type: "webhook.tradingview.alert".to_string(),
                payload: json!({
                    "source": "tradingview",
                    "ticker": ticker,
                    "action": action,
                    "price": price,
                    "interval": interval,
                    "message": message,
                }),
                bridge_event: None,
            }
        }
        "homeassistant" => {
            let entity_id = raw_json
                .get("entity_id")
                .and_then(|v| v.as_str())
                .unwrap_or("unknown");
            let state_val = raw_json
                .get("state")
                .and_then(|v| v.as_str())
                .unwrap_or("unknown");
            let ha_event = raw_json
                .get("event_type")
                .and_then(|v| v.as_str())
                .unwrap_or("state_changed");

            NormalizedWebhook {
                event_type: "webhook.homeassistant.event".to_string(),
                payload: json!({
                    "source": "homeassistant",
                    "entity_id": entity_id,
                    "state": state_val,
                    "event_type": ha_event,
                    "data": raw_json,
                }),
                bridge_event: None,
            }
        }
        "tyler" => {
            let raw_sub = headers
                .get("x-george-event")
                .and_then(|v| v.to_str().ok())
                .or_else(|| raw_json.get("event_type").and_then(|v| v.as_str()))
                .or_else(|| raw_json.get("event").and_then(|v| v.as_str()))
                .unwrap_or("alert");
            let sub = sanitize_event_segment(raw_sub, "alert");
            let bridge = match sub.as_str() {
                "canary_triggered"
                | "tshark_watch_hit"
                | "lateral_movement"
                | "arp_spoof"
                | "baseline_drift"
                | "rogue_device"
                | "upnp_exposure"
                | "canary_ap_intrusion"
                | "rogue_ap"
                | "rf_anomaly"
                | "rf_motion"
                | "perimeter_alert" => {
                    Some((format!("network.{}", sub), raw_json.clone()))
                }
                _ => None,
            };
            NormalizedWebhook {
                event_type: format!("webhook.tyler.{}", sub),
                payload: json!({
                    "source": "tyler",
                    "event": sub,
                    "data": raw_json,
                }),
                bridge_event: bridge,
            }
        }
        _ => {
            let raw_sub = headers
                .get("x-george-event")
                .and_then(|v| v.to_str().ok())
                .or_else(|| raw_json.get("event_type").and_then(|v| v.as_str()))
                .or_else(|| raw_json.get("event").and_then(|v| v.as_str()))
                .unwrap_or("ingest");
            let sub = sanitize_event_segment(raw_sub, "ingest");
            NormalizedWebhook {
                event_type: format!("webhook.{}.{}", source, sub),
                payload: json!({
                    "source": source,
                    "event": sub,
                    "data": raw_json,
                }),
                bridge_event: None,
            }
        }
    }
}

// ── Route Handlers ─────────────────────────────────────────────────────────

pub async fn post_webhook(
    State(state): State<Arc<AppState>>,
    Path(source): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    let clean_source = source.trim().to_ascii_lowercase();
    if !is_valid_source(&clean_source) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({
                "status": "error",
                "message": "Invalid webhook source identifier (must match ^[a-z0-9_-]{1,32}$)"
            })),
        )
            .into_response();
    }

    let bytes = match to_bytes(body, MAX_WEBHOOK_BYTES + 1).await {
        Ok(b) => b,
        Err(_) => {
            return (
                StatusCode::PAYLOAD_TOO_LARGE,
                Json(json!({
                    "status": "error",
                    "message": format!("Webhook payload exceeds {} byte limit", MAX_WEBHOOK_BYTES)
                })),
            )
                .into_response();
        }
    };

    if bytes.len() > MAX_WEBHOOK_BYTES {
        return (
            StatusCode::PAYLOAD_TOO_LARGE,
            Json(json!({
                "status": "error",
                "message": format!("Webhook payload exceeds {} byte limit", MAX_WEBHOOK_BYTES)
            })),
        )
            .into_response();
    }

    let secret = resolve_webhook_secret(&state, &clean_source);
    let auth_scheme = match verify_webhook_auth(&headers, &bytes, &secret, &state.api_token) {
        Ok(scheme) => scheme,
        Err(reason) => {
            return (
                StatusCode::UNAUTHORIZED,
                Json(json!({
                    "status": "error",
                    "message": reason
                })),
            )
                .into_response();
        }
    };

    let parsed_json: Value = if bytes.is_empty() {
        json!({})
    } else {
        match serde_json::from_slice(&bytes) {
            Ok(v) => v,
            Err(_) => json!({ "raw_text": String::from_utf8_lossy(&bytes).to_string() }),
        }
    };

    let norm = normalize_webhook_payload(&clean_source, &headers, &parsed_json);
    let payload_str = norm.payload.to_string();
    let source_tag = format!("webhook:{}", clean_source);

    // Emit into canonical Event Bus via positional argv (zero shell interpolation)
    let eb_script = state.lodge_dir.join("lib").join("ipc").join("event_bus.sh");
    let emit_res = Command::new("bash")
        .arg("-c")
        .arg("export LODGE_DIR=\"$1\" GEORGE_DIR=\"$2\"; source \"$3\" && event_bus_emit \"$4\" \"$5\" \"$6\"")
        .arg("_")
        .arg(&state.lodge_dir)
        .arg(&state.george_dir)
        .arg(&eb_script)
        .arg(&norm.event_type)
        .arg(&payload_str)
        .arg(&source_tag)
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    if let Some((bridge_type, bridge_pl)) = &norm.bridge_event {
        let _ = Command::new("bash")
            .arg("-c")
            .arg("export LODGE_DIR=\"$1\" GEORGE_DIR=\"$2\"; source \"$3\" && event_bus_emit \"$4\" \"$5\" \"$6\"")
            .arg("_")
            .arg(&state.lodge_dir)
            .arg(&state.george_dir)
            .arg(&eb_script)
            .arg(bridge_type)
            .arg(bridge_pl.to_string())
            .arg(&source_tag)
            .current_dir(&state.lodge_dir)
            .output()
            .await;
    }

    let now_ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    // Record audit entry in .george/state/webhooks_ingested.jsonl
    let state_dir = state.george_dir.join("state");
    let _ = std::fs::create_dir_all(&state_dir);
    let ledger_path = state_dir.join("webhooks_ingested.jsonl");
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ledger_path)
    {
        let entry = json!({
            "ts": now_ts,
            "source": clean_source,
            "event_type": norm.event_type,
            "auth": auth_scheme,
            "bytes": bytes.len(),
        });
        let _ = writeln!(f, "{}", entry);
    }

    match emit_res {
        Ok(out) if out.status.success() => (
            StatusCode::ACCEPTED,
            Json(json!({
                "status": "accepted",
                "source": clean_source,
                "event_type": norm.event_type,
                "auth": auth_scheme,
                "bridged_event": norm.bridge_event.as_ref().map(|(t, _)| t),
            })),
        )
            .into_response(),
        Ok(out) => {
            let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({
                    "status": "error",
                    "message": format!("Event bus rejected webhook: {}", err)
                })),
            )
                .into_response()
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({
                "status": "error",
                "message": e.to_string()
            })),
        )
            .into_response(),
    }
}

pub async fn get_webhooks_status(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let ledger_path = state.george_dir.join("state").join("webhooks_ingested.jsonl");
    let mut recent: Vec<Value> = Vec::new();
    let mut total_ingested: usize = 0;

    if let Ok(content) = std::fs::read_to_string(&ledger_path) {
        let lines: Vec<&str> = content.lines().filter(|l| !l.trim().is_empty()).collect();
        total_ingested = lines.len();
        for line in lines.into_iter().rev().take(25) {
            if let Ok(val) = serde_json::from_str::<Value>(line) {
                recent.push(val);
            }
        }
    }

    Json(json!({
        "status": "ok",
        "gateway": "active",
        "max_payload_bytes": MAX_WEBHOOK_BYTES,
        "supported_adapters": ["gitea", "github", "tradingview", "homeassistant", "generic"],
        "total_ingested": total_ingested,
        "recent": recent,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::HeaderValue;

    #[test]
    fn test_sha256_empty_and_abc() {
        assert_eq!(
            hex_encode(&sha256(b"")),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            hex_encode(&sha256(b"abc")),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn test_hmac_sha256_rfc4231_vectors() {
        // RFC 4231 Test Case 1: key = 20 bytes of 0x0b, data = "Hi There"
        let key1 = [0x0bu8; 20];
        let data1 = b"Hi There";
        assert_eq!(
            hex_encode(&hmac_sha256(&key1, data1)),
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
        );

        // RFC 4231 Test Case 2: key = "Jefe", data = "what do ya want for nothing?"
        assert_eq!(
            hex_encode(&hmac_sha256(b"Jefe", b"what do ya want for nothing?")),
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        );
    }

    #[test]
    fn test_verify_webhook_auth_hmac_and_bearer() {
        let body = br#"{"ref":"refs/heads/develop"}"#;
        let secret = "sovereign_test_secret";
        let sig = hex_encode(&hmac_sha256(secret.as_bytes(), body));

        let mut headers = HeaderMap::new();
        headers.insert(
            "x-hub-signature-256",
            HeaderValue::from_str(&format!("sha256={}", sig)).unwrap(),
        );
        assert_eq!(
            verify_webhook_auth(&headers, body, secret, "fallback_tok"),
            Ok("hmac-sha256")
        );

        // Tampered body must be rejected
        assert!(verify_webhook_auth(&headers, b"{}", secret, "fallback_tok").is_err());

        // Bearer token auth
        let mut bearer_headers = HeaderMap::new();
        bearer_headers.insert(
            header::AUTHORIZATION,
            HeaderValue::from_static("Bearer sovereign_test_secret"),
        );
        assert_eq!(
            verify_webhook_auth(&bearer_headers, body, secret, "fallback_tok"),
            Ok("bearer-token")
        );
    }

    #[test]
    fn test_normalize_gitea_and_tradingview() {
        let mut headers = HeaderMap::new();
        headers.insert("x-gitea-event", HeaderValue::from_static("push"));
        let raw = json!({
            "ref": "refs/heads/develop",
            "after": "abc1234",
            "repository": {"full_name": "george/blue-lodge"},
            "sender": {"login": "operator"},
            "commits": [{"id": "abc1234"}]
        });
        let norm = normalize_webhook_payload("gitea", &headers, &raw);
        assert_eq!(norm.event_type, "webhook.gitea.push");
        assert_eq!(norm.payload["branch"], "develop");
        assert_eq!(norm.payload["commit_count"], 1);

        let tv_raw = json!({"ticker": "ADAUSD", "action": "buy", "price": 0.78});
        let tv_norm = normalize_webhook_payload("tradingview", &HeaderMap::new(), &tv_raw);
        assert_eq!(tv_norm.event_type, "webhook.tradingview.alert");
        assert_eq!(tv_norm.payload["ticker"], "ADAUSD");
    }
}
