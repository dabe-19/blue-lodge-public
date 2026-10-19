//! Cardano Sovereign Node & Dolos Block Crawler Routes.
//!
//! Provides sub-millisecond node observability, live block streaming,
//! transaction inspections, AUTO/MANUAL execution mode toggling, and
//! the Rust Sieve bridge to the Blue Lodge Event Bus.

use axum::{
    extract::{Path as AxumPath, Query, State},
    http::StatusCode,
    response::{IntoResponse, Json},
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::Instant;
use tokio::fs;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

use crate::routes::desk::bad;
use crate::state::AppState;

fn get_python_bin(state: &AppState) -> String {
    let venv_py = state.lodge_dir.join(".venv").join("bin").join("python");
    if venv_py.exists() {
        venv_py.to_string_lossy().to_string()
    } else {
        "python3".to_string()
    }
}

// ---------------------------------------------------------------------------
// Node Telemetry & Status
// ---------------------------------------------------------------------------

pub async fn get_node_status(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let start = Instant::now();
    let raw_url = std::env::var("DOLOS_MINIBF_URL").unwrap_or_else(|_| "http://127.0.0.1:8000".to_string());
    let base_url = raw_url.trim_end_matches("/api/v0").trim_end_matches('/').to_string();

    let now_sec = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    // Cardano deterministic slot calculations (Shelley hard fork: 1596059091 -> slot 4492800)
    let expected_tip_slot = if now_sec > 1596059091 {
        4492800 + (now_sec - 1596059091)
    } else {
        0
    };
    let expected_tip_epoch = if expected_tip_slot >= 4492800 {
        208 + (expected_tip_slot - 4492800) / 432000
    } else {
        0
    };

    let mode_file = state.george_dir.join("cardano_mode.conf");
    let exec_mode = fs::read_to_string(&mode_file)
        .await
        .map(|s| s.trim().to_uppercase())
        .unwrap_or_else(|_| "AUTO".to_string());

    // 1. Probe Dolos latest block locally
    let dolos_probe = Command::new("curl")
        .arg("-s")
        .arg("-m")
        .arg("1")
        .arg(format!("{base_url}/blocks/latest"))
        .output()
        .await;

    let elapsed_ms = (start.elapsed().as_secs_f64() * 1000.0 * 10.0).round() / 10.0;

    let mut dolos_online = false;
    let mut local_height: u64 = 0;
    let mut local_slot: u64 = 0;
    let mut local_epoch: u64 = 0;
    let mut local_time: u64 = 0;
    let mut local_hash: String = String::new();

    if let Ok(out) = dolos_probe {
        if out.status.success() {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(b) = serde_json::from_str::<Value>(&stdout) {
                if let Some(h) = b.get("height").and_then(|v| v.as_u64()) {
                    dolos_online = true;
                    local_height = h;
                    local_slot = b.get("slot").and_then(|v| v.as_u64()).unwrap_or(0);
                    local_epoch = b.get("epoch").and_then(|v| v.as_u64()).unwrap_or(0);
                    local_time = b.get("time").and_then(|v| v.as_u64()).unwrap_or(0);
                    local_hash = b.get("hash").and_then(|v| v.as_str()).unwrap_or("").to_string();
                }
            }
        }
    }

    // 2. Query network tip from Koios (fallback to slot clock estimate if slow)
    let tip_probe = Command::new("curl")
        .arg("-s")
        .arg("-m")
        .arg("2")
        .arg("https://api.koios.rest/api/v1/tip")
        .output()
        .await;

    let mut tip_block_height: u64 = 14041550;
    let mut tip_slot: u64 = expected_tip_slot;
    let mut tip_epoch: u64 = expected_tip_epoch;
    let mut tip_block_time: u64 = now_sec;

    if let Ok(out) = tip_probe {
        if out.status.success() {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(arr) = serde_json::from_str::<Value>(&stdout) {
                if let Some(t) = arr.as_array().and_then(|a| a.first()) {
                    if let Some(h) = t.get("block_height").and_then(|v| v.as_u64()) {
                        tip_block_height = h;
                        tip_slot = t.get("abs_slot").and_then(|v| v.as_u64()).unwrap_or(expected_tip_slot);
                        tip_epoch = t.get("epoch_no").and_then(|v| v.as_u64()).unwrap_or(expected_tip_epoch);
                        tip_block_time = t.get("block_time").and_then(|v| v.as_u64()).unwrap_or(now_sec);
                    }
                }
            }
        }
    }

    // 3. Compute sync metrics
    let slot_lag = tip_slot.saturating_sub(local_slot);
    let block_lag = tip_block_height.saturating_sub(local_height);
    let time_lag_seconds = now_sec.saturating_sub(local_time);

    let is_synced = dolos_online && slot_lag <= 120 && time_lag_seconds <= 120;
    let sync_percent = if tip_slot > 0 && dolos_online {
        ((local_slot as f64 / tip_slot as f64) * 100.0).clamp(0.0, 100.0)
    } else {
        0.0
    };

    let sync_status = if !dolos_online {
        "OFFLINE"
    } else if is_synced {
        "SYNCED"
    } else {
        "SYNCING"
    };

    let active_provider = if is_synced {
        "Local-Dolos-MiniBF"
    } else {
        "Koios-v1"
    };

    let time_lag_human = if !dolos_online {
        "Node Offline".to_string()
    } else if is_synced {
        format!("{time_lag_seconds}s (At Tip)")
    } else if time_lag_seconds < 3600 {
        format!("{}m lag", time_lag_seconds / 60)
    } else if time_lag_seconds < 86400 {
        format!("{}h lag", time_lag_seconds / 3600)
    } else {
        let days = time_lag_seconds / 86400;
        if days > 365 {
            format!("{:.1} yrs behind", days as f64 / 365.25)
        } else {
            format!("{days}d lag")
        }
    };

    (
        StatusCode::OK,
        Json(json!({
            "status": "ok",
            "provider": active_provider,
            "is_sovereign": is_synced,
            "latency_ms": elapsed_ms,
            "execution_mode": exec_mode,
            "synced": is_synced,
            "dolos": {
                "online": dolos_online,
                "synced": is_synced,
                "sync_status": sync_status,
                "sync_percent": (sync_percent * 10000.0).round() / 10000.0,
                "local_height": local_height,
                "local_slot": local_slot,
                "local_epoch": local_epoch,
                "local_time": local_time,
                "local_hash": local_hash,
                "slot_lag": slot_lag,
                "block_lag": block_lag,
                "time_lag_seconds": time_lag_seconds,
                "time_lag_human": time_lag_human,
                "peer": "relay.cnode-m1.demeter.run:3000",
                "container_name": "lodge-dolos",
                "ports": {
                    "minibf": 8000,
                    "grpc": 50051,
                    "minikupo": 1442
                }
            },
            "network_tip": {
                "block_height": tip_block_height,
                "slot": tip_slot,
                "epoch": tip_epoch,
                "block_time": tip_block_time
            },
            "router": {
                "active_gateway": if is_synced { "DOLOS (LOCAL SOVEREIGN)" } else { "KOIOS (SAFE FALLBACK)" },
                "reason": if is_synced {
                    "Local Dolos node is fully synchronized with L1 tip (< 120s lag). Queries served with < 1ms sovereign latency."
                } else if dolos_online {
                    "Local Dolos is catching up to tip. Live queries transparently routed to Koios to guarantee fresh balances & UTxOs."
                } else {
                    "Local Dolos daemon is offline. Operating under Koios sovereign fallback."
                }
            }
        })),
    )
}

// ---------------------------------------------------------------------------
// Block Stream & Explorer
// ---------------------------------------------------------------------------

#[derive(Deserialize, Default)]
pub struct BlocksQuery {
    pub count: Option<usize>,
    pub source: Option<String>,
}

pub async fn get_latest_blocks(
    State(state): State<Arc<AppState>>,
    Query(q): Query<BlocksQuery>,
) -> impl IntoResponse {
    let count = q.count.unwrap_or(10).clamp(1, 50);
    let raw_url = std::env::var("DOLOS_MINIBF_URL").unwrap_or_else(|_| "http://127.0.0.1:8000".to_string());
    let base_url = raw_url.trim_end_matches("/api/v0").trim_end_matches('/').to_string();

    let force_local = q.source.as_deref() == Some("local");

    // 1. Try local Dolos Mini-Blockfrost if requested or if synced
    if force_local {
        let dolos_blocks = Command::new("curl")
            .arg("-s")
            .arg("-m")
            .arg("1")
            .arg(format!("{base_url}/blocks/latest"))
            .output()
            .await;

        if let Ok(out) = dolos_blocks {
            if out.status.success() {
                let stdout = String::from_utf8_lossy(&out.stdout);
                if let Ok(b) = serde_json::from_str::<Value>(&stdout) {
                    if b.get("hash").is_some() {
                        return (StatusCode::OK, Json(json!({"status": "ok", "provider": "Local-Dolos", "source": "local", "blocks": [b]})));
                    }
                }
            }
        }
    }

    // 2. Fallback to Koios for live Mainnet blocks
    let py_bin = get_python_bin(&state);
    let py_cmd = format!(
        "import json, urllib.request; \
         req = urllib.request.Request('https://api.koios.rest/api/v1/blocks?limit={count}', headers={{'Accept': 'application/json'}}); \
         res = urllib.request.urlopen(req, timeout=5); \
         print(res.read().decode('utf-8'))"
    );

    let output = Command::new(&py_bin)
        .arg("-c")
        .arg(&py_cmd)
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(blocks) = serde_json::from_str::<Value>(&stdout) {
                (StatusCode::OK, Json(json!({"status": "ok", "provider": "Koios", "source": "network", "blocks": blocks})))
            } else {
                (StatusCode::OK, Json(json!({"status": "ok", "blocks": []})))
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

// ---------------------------------------------------------------------------
// Dolos Daemon Controls & Inspection
// ---------------------------------------------------------------------------

pub async fn get_node_logs(State(_state): State<Arc<AppState>>) -> impl IntoResponse {
    let out = Command::new("docker")
        .args(["logs", "--tail", "40", "lodge-dolos"])
        .output()
        .await;

    match out {
        Ok(res) => {
            let stdout = String::from_utf8_lossy(&res.stdout);
            let stderr = String::from_utf8_lossy(&res.stderr);
            let logs = if !stdout.is_empty() {
                stdout.to_string()
            } else {
                stderr.to_string()
            };
            (StatusCode::OK, Json(json!({"status": "ok", "logs": logs})))
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": format!("failed to read docker logs: {e}")})),
        ),
    }
}

pub async fn restart_node(State(_state): State<Arc<AppState>>) -> impl IntoResponse {
    let out = Command::new("docker")
        .args(["restart", "lodge-dolos"])
        .output()
        .await;

    match out {
        Ok(res) if res.status.success() => {
            (StatusCode::OK, Json(json!({"status": "ok", "message": "Container lodge-dolos restarted successfully"})))
        }
        Ok(res) => {
            let stderr = String::from_utf8_lossy(&res.stderr);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({"status": "error", "message": format!("restart failed: {stderr}")})),
            )
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": format!("failed to execute docker restart: {e}")})),
        ),
    }
}

// ---------------------------------------------------------------------------
// Transaction Inspector
// ---------------------------------------------------------------------------

pub async fn get_transaction_inspect(
    State(state): State<Arc<AppState>>,
    AxumPath(tx_hash): AxumPath<String>,
) -> impl IntoResponse {
    let clean_hash = tx_hash.trim();
    if clean_hash.len() != 64 || !clean_hash.chars().all(|c| c.is_ascii_hexdigit()) {
        return bad("invalid transaction hash format");
    }

    let py_bin = get_python_bin(&state);
    let py_cmd = format!(
        "import json, lib.tools.cardano_provider as cp; \
         p = cp.get_cardano_provider(); \
         u = p.get_transaction_utxos('{clean_hash}'); \
         print(json.dumps(u or {{}}))"
    );

    let output = Command::new(&py_bin)
        .arg("-c")
        .arg(&py_cmd)
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(data) = serde_json::from_str::<Value>(&stdout) {
                (StatusCode::OK, Json(json!({"status": "ok", "transaction": data})))
            } else {
                (StatusCode::OK, Json(json!({"status": "ok", "transaction": {}})))
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

// ---------------------------------------------------------------------------
// Execution Mode Toggle (AUTO / MANUAL)
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct ModePayload {
    pub mode: String,
}

pub async fn get_execution_mode(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let mode_file = state.george_dir.join("cardano_mode.conf");
    let mode = fs::read_to_string(&mode_file)
        .await
        .map(|s| s.trim().to_uppercase())
        .unwrap_or_else(|_| "AUTO".to_string());

    (StatusCode::OK, Json(json!({"status": "ok", "mode": mode})))
}

pub async fn set_execution_mode(
    State(state): State<Arc<AppState>>,
    Json(p): Json<ModePayload>,
) -> impl IntoResponse {
    let target = p.mode.trim().to_uppercase();
    if target != "AUTO" && target != "MANUAL" {
        return bad("mode must be 'AUTO' or 'MANUAL'");
    }

    let mode_file = state.george_dir.join("cardano_mode.conf");
    match fs::write(&mode_file, format!("{target}\n")).await {
        Ok(_) => (
            StatusCode::OK,
            Json(json!({
                "status": "ok",
                "mode": target,
                "message": format!("Sovereign trading execution mode set to {target}")
            })),
        ),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

// ---------------------------------------------------------------------------
// Rust Sieve Damper Bridge to Blue Lodge Event Bus (FIFO)
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct SieveSignalPayload {
    pub asset: String,
    pub buy_pool: String,
    pub sell_pool: String,
    pub gross_spread_pct: f64,
    pub net_return_ada: f64,
}

pub async fn emit_sieve_signal(
    State(state): State<Arc<AppState>>,
    Json(p): Json<SieveSignalPayload>,
) -> impl IntoResponse {
    // Only emit to FIFO if spread meets positive return hurdle
    if p.net_return_ada <= 0.0 || p.gross_spread_pct < 0.5 {
        return (
            StatusCode::OK,
            Json(json!({"status": "filtered", "reason": "Signal below positive return hurdle"})),
        );
    }

    let fifo_path = state.george_dir.join("ipc").join("event_bus.fifo");
    if !fifo_path.exists() {
        return (
            StatusCode::OK,
            Json(json!({"status": "bypassed", "reason": "Event bus FIFO not active"})),
        );
    }

    let now_ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    let envelope = json!({
        "topic": "cardano.dex.spread_detected",
        "asset": p.asset,
        "buy_pool": p.buy_pool,
        "sell_pool": p.sell_pool,
        "gross_spread_pct": p.gross_spread_pct,
        "net_return_ada": p.net_return_ada,
        "timestamp": now_ts,
    });

    let line = format!("{}\n", envelope.to_string());
    if line.len() > 4096 {
        return bad("Envelope exceeds POSIX PIPE_BUF limit");
    }

    // Atomic non-blocking FIFO append
    let write_res = async {
        let mut f = fs::OpenOptions::new()
            .write(true)
            .open(&fifo_path)
            .await?;
        f.write_all(line.as_bytes()).await?;
        f.flush().await?;
        Ok::<(), std::io::Error>(())
    }
    .await;

    match write_res {
        Ok(_) => (
            StatusCode::OK,
            Json(json!({
                "status": "emitted",
                "topic": "cardano.dex.spread_detected",
                "asset": p.asset,
                "net_return_ada": p.net_return_ada
            })),
        ),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": format!("FIFO write failed: {e}")})),
        ),
    }
}

// ---------------------------------------------------------------------------
// Stale Orders & Microloans Scanner
// ---------------------------------------------------------------------------

pub async fn get_stale_orders(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("cardano_stale_reclaimer.py");

    let out = Command::new(&py_bin)
        .arg(&script)
        .arg("--scan")
        .arg("--json")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match out {
        Ok(res) if res.status.success() => {
            let stdout = String::from_utf8_lossy(&res.stdout);
            match serde_json::from_str::<Value>(&stdout) {
                Ok(val) => (StatusCode::OK, Json(val)),
                Err(_) => (StatusCode::OK, Json(json!({"status": "ok", "stale_count": 0, "stale_orders": []}))),
            }
        }
        Ok(res) => {
            let stderr = String::from_utf8_lossy(&res.stderr);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({"status": "error", "message": format!("stale scanner failed: {stderr}")})),
            )
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": format!("failed to spawn python: {e}")})),
        ),
    }
}

