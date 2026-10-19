//! Instrument Rack: whole-fabric snapshot (control node + compute nodes).
//!
//! Delegates to the stdlib probe `lib/sys/rack_probe.py` (argv only, no
//! shell) and caches the JSON for a few seconds so several open browsers
//! polling the Rack don't multiply network probes.

use axum::{
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Json},
};
use serde_json::json;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::state::AppState;

const RACK_CACHE_TTL: Duration = Duration::from_secs(5);
const RACK_PROBE_TIMEOUT: Duration = Duration::from_secs(12);

static RACK_CACHE: std::sync::OnceLock<tokio::sync::Mutex<(Option<Instant>, Option<serde_json::Value>)>> =
    std::sync::OnceLock::new();

pub async fn get_rack(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let cell = RACK_CACHE.get_or_init(|| tokio::sync::Mutex::new((None, None)));
    // Holding the lock across the probe serialises callers: one probe at a time.
    let mut guard = cell.lock().await;
    if let (Some(t), Some(v)) = (guard.0, guard.1.as_ref()) {
        if t.elapsed() < RACK_CACHE_TTL {
            return (StatusCode::OK, Json(v.clone()));
        }
    }

    let script = state.lodge_dir.join("lib").join("sys").join("rack_probe.py");
    if !script.is_file() {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": "rack probe not installed" })),
        );
    }
    let fut = tokio::process::Command::new("python3")
        .arg(&script)
        .arg("--george-dir")
        .arg(&state.george_dir)
        .arg("--timeout")
        .arg("2")
        .kill_on_drop(true)
        .output();

    match tokio::time::timeout(RACK_PROBE_TIMEOUT, fut).await {
        Ok(Ok(out)) if out.status.success() => match serde_json::from_slice::<serde_json::Value>(&out.stdout) {
            Ok(v) => {
                guard.0 = Some(Instant::now());
                guard.1 = Some(v.clone());
                (StatusCode::OK, Json(v))
            }
            Err(_) => (
                StatusCode::BAD_GATEWAY,
                Json(json!({ "error": "rack probe returned invalid JSON" })),
            ),
        },
        Ok(Ok(_)) => (StatusCode::BAD_GATEWAY, Json(json!({ "error": "rack probe failed" }))),
        Ok(Err(_)) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": "could not start rack probe" }))),
        Err(_) => {
            // Serve the last good snapshot (marked stale) rather than nothing.
            if let Some(v) = guard.1.as_ref() {
                let mut stale = v.clone();
                stale["stale"] = json!(true);
                return (StatusCode::OK, Json(stale));
            }
            (StatusCode::GATEWAY_TIMEOUT, Json(json!({ "error": "rack probe timed out" })))
        }
    }
}
