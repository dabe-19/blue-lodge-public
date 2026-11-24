//! Dynamic Module Host, Lodge Guild App Store API, Safe Asset Server,
//! Offline Map Tile Cache Proxy, and Mobile GPS Telemetry Bridge.

use axum::{
    body::Bytes,
    extract::{Path, Query, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Arc;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

use crate::security::{constant_time_eq, TOKEN_HEADER};
use crate::state::AppState;

fn valid_id(s: &str) -> bool {
    let b = s.as_bytes();
    if b.len() < 2 || b.len() > 49 {
        return false;
    }
    if !b[0].is_ascii_lowercase() && !b[0].is_ascii_digit() {
        return false;
    }
    b.iter()
        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'_' || *c == b'-')
}

fn valid_action(s: &str) -> bool {
    let b = s.as_bytes();
    if b.is_empty() || b.len() > 48 {
        return false;
    }
    b.iter()
        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'_')
}

async fn run_modules_sh(state: &AppState, subcmd: &str, args: &[String]) -> Result<String, String> {
    let script = state.lodge_dir.join("commands").join("app.sh");
    let mut cmd = Command::new("bash");
    cmd.arg(&script)
        .arg(subcmd)
        .args(args)
        .env("LODGE_DIR", &state.lodge_dir)
        .env("GEORGE_DIR", &state.george_dir)
        .current_dir(&state.lodge_dir)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let out = cmd
        .output()
        .await
        .map_err(|e| format!("failed to spawn app.sh: {}", e))?;

    let stdout = String::from_utf8_lossy(&out.stdout).to_string();
    let stderr = String::from_utf8_lossy(&out.stderr).to_string();
    if out.status.success() {
        Ok(stdout)
    } else {
        Err(if !stderr.trim().is_empty() {
            stderr
        } else {
            stdout
        })
    }
}

/// GET /api/modules — returns unified list of built-in, catalog, and installed modules.
pub async fn list_modules(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    match run_modules_sh(&state, "list", &["--json".to_string()]).await {
        Ok(raw) => match serde_json::from_str::<Value>(&raw) {
            Ok(v) => (StatusCode::OK, Json(v)),
            Err(_) => (
                StatusCode::OK,
                Json(json!({"status": "ok", "modules": [], "raw": raw})),
            ),
        },
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e})),
        ),
    }
}

/// POST /api/modules/catalog/sync — syncs Lodge Guild catalog from Gitea/remote.
pub async fn sync_catalog(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    match run_modules_sh(&state, "catalog", &[]).await {
        Ok(_) => match run_modules_sh(&state, "list", &["--json".to_string()]).await {
            Ok(raw) => match serde_json::from_str::<Value>(&raw) {
                Ok(v) => (StatusCode::OK, Json(v)),
                Err(_) => (StatusCode::OK, Json(json!({"status": "ok"}))),
            },
            Err(e) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({"status": "error", "message": e})),
            ),
        },
        Err(e) => (
            StatusCode::BAD_GATEWAY,
            Json(json!({"status": "error", "message": e})),
        ),
    }
}

#[derive(Deserialize, Default)]
pub struct InstallReq {
    pub repo_url: Option<String>,
    pub git_ref: Option<String>,
    pub approve: Option<bool>,
}

/// POST /api/modules/:id/install
pub async fn install_module(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    body: Option<Json<InstallReq>>,
) -> impl IntoResponse {
    if !valid_id(&id) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"status": "error", "message": "invalid module id"})),
        );
    }
    let req = body.map(|b| b.0).unwrap_or_default();
    let target = req.repo_url.filter(|u| !u.trim().is_empty()).unwrap_or(id.clone());
    // Reject obvious flag injection in repo_url
    if target.starts_with('-') || target.contains('\n') || target.contains('\r') {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"status": "error", "message": "invalid repository target"})),
        );
    }
    let mut args = vec![target];
    if let Some(r) = req.git_ref.filter(|s| !s.trim().is_empty() && !s.starts_with('-')) {
        args.push("--ref".to_string());
        args.push(r);
    }
    if req.approve.unwrap_or(false) {
        args.push("--approve".to_string());
    }
    match run_modules_sh(&state, "install", &args).await {
        Ok(msg) => (
            StatusCode::OK,
            Json(json!({"status": "ok", "module": id, "output": msg})),
        ),
        Err(e) => (
            StatusCode::BAD_REQUEST,
            Json(json!({"status": "error", "module": id, "message": e})),
        ),
    }
}

/// POST /api/modules/:id/update — safely upgrade an installed module to the latest Guild catalog SHA
pub async fn update_module(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    if !valid_id(&id) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"status": "error", "message": "invalid module id"})),
        );
    }
    match run_modules_sh(&state, "update", &[id.clone(), "--approve".to_string()]).await {
        Ok(msg) => (
            StatusCode::OK,
            Json(json!({"status": "ok", "module": id, "output": msg})),
        ),
        Err(e) => (
            StatusCode::BAD_REQUEST,
            Json(json!({"status": "error", "module": id, "message": e})),
        ),
    }
}

/// POST /api/modules/update-all — upgrade all installed modules that have updates available
pub async fn update_all_modules(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    match run_modules_sh(&state, "update", &["--all".to_string(), "--approve".to_string()]).await {
        Ok(msg) => (
            StatusCode::OK,
            Json(json!({"status": "ok", "output": msg})),
        ),
        Err(e) => (
            StatusCode::BAD_REQUEST,
            Json(json!({"status": "error", "message": e})),
        ),
    }
}

/// POST /api/modules/:id/enable
pub async fn enable_module(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    if !valid_id(&id) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"status": "error", "message": "invalid module id"})),
        );
    }
    match run_modules_sh(&state, "enable", &[id.clone()]).await {
        Ok(msg) => (
            StatusCode::OK,
            Json(json!({"status": "ok", "module": id, "enabled": true, "output": msg})),
        ),
        Err(e) => (
            StatusCode::BAD_REQUEST,
            Json(json!({"status": "error", "module": id, "message": e})),
        ),
    }
}

/// POST /api/modules/:id/disable
pub async fn disable_module(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    if !valid_id(&id) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"status": "error", "message": "invalid module id"})),
        );
    }
    match run_modules_sh(&state, "disable", &[id.clone()]).await {
        Ok(msg) => (
            StatusCode::OK,
            Json(json!({"status": "ok", "module": id, "enabled": false, "output": msg})),
        ),
        Err(e) => (
            StatusCode::BAD_REQUEST,
            Json(json!({"status": "error", "module": id, "message": e})),
        ),
    }
}

/// POST /api/modules/:id/uninstall
pub async fn uninstall_module(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    if !valid_id(&id) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"status": "error", "message": "invalid module id"})),
        );
    }
    match run_modules_sh(&state, "uninstall", &[id.clone()]).await {
        Ok(msg) => (
            StatusCode::OK,
            Json(json!({"status": "ok", "module": id, "output": msg})),
        ),
        Err(e) => (
            StatusCode::BAD_REQUEST,
            Json(json!({"status": "error", "module": id, "message": e})),
        ),
    }
}

/// GET /api/modules/:id/health
pub async fn module_health(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    if !valid_id(&id) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"status": "error", "message": "invalid module id"})),
        );
    }
    match run_modules_sh(&state, "health", &[id]).await {
        Ok(raw) => match serde_json::from_str::<Value>(&raw) {
            Ok(v) => (StatusCode::OK, Json(v)),
            Err(_) => (StatusCode::OK, Json(json!({"status": "ok", "output": raw}))),
        },
        Err(e) => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({"status": "unhealthy", "message": e})),
        ),
    }
}

/// GET /api/modules/:id/assets/*path — serves UI assets strictly from .george/modules/<id>/ui/
pub async fn serve_module_asset(
    State(state): State<Arc<AppState>>,
    Path((id, rel_path)): Path<(String, String)>,
) -> Response {
    if !valid_id(&id) || rel_path.contains("..") || rel_path.contains('\\') {
        return (StatusCode::BAD_REQUEST, "invalid module asset path").into_response();
    }
    let ui_root = state.george_dir.join("modules").join(&id).join("ui");
    let Ok(canon_root) = std::fs::canonicalize(&ui_root) else {
        return (StatusCode::NOT_FOUND, "module ui directory not found").into_response();
    };
    let clean_rel = rel_path.trim_start_matches('/');
    let candidate = canon_root.join(clean_rel);
    let Ok(canon_file) = std::fs::canonicalize(&candidate) else {
        return (StatusCode::NOT_FOUND, "asset not found").into_response();
    };
    if !canon_file.starts_with(&canon_root) || !canon_file.is_file() {
        return (StatusCode::FORBIDDEN, "asset path outside module ui sandbox").into_response();
    }
    let Ok(bytes) = tokio::fs::read(&canon_file).await else {
        return (StatusCode::INTERNAL_SERVER_ERROR, "failed to read asset").into_response();
    };
    let ctype = match canon_file.extension().and_then(|e| e.to_str()).unwrap_or("") {
        "js" | "mjs" => "application/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "json" => "application/json; charset=utf-8",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "html" => "text/html; charset=utf-8",
        _ => "application/octet-stream",
    };
    (
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, ctype),
            (header::CACHE_CONTROL, "no-cache"),
        ],
        bytes,
    )
        .into_response()
}

/// POST /api/modules/:id/action/:action — executes .george/modules/<id>/tools/web_action.sh <action>
pub async fn invoke_module_action(
    State(state): State<Arc<AppState>>,
    Path((id, action)): Path<(String, String)>,
    body: Bytes,
) -> impl IntoResponse {
    if !valid_id(&id) || !valid_action(&action) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"status": "error", "message": "invalid module id or action name"})),
        );
    }
    let mod_dir = state.george_dir.join("modules").join(&id);
    let script = mod_dir.join("tools").join("web_action.sh");
    if !script.is_file() {
        return (
            StatusCode::NOT_FOUND,
            Json(json!({"status": "error", "message": "module action handler not found"})),
        );
    }
    let data_dir = state.george_dir.join("module_data").join(&id);
    let _ = std::fs::create_dir_all(&data_dir);

    let mut cmd = Command::new("bash");
    cmd.arg(&script)
        .arg(&action)
        .env("LODGE_DIR", &state.lodge_dir)
        .env("GEORGE_DIR", &state.george_dir)
        .env("MODULE_ID", &id)
        .env("MODULE_DIR", &mod_dir)
        .env("MODULE_DATA_DIR", &data_dir)
        .current_dir(&mod_dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let Ok(mut child) = cmd.spawn() else {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": "failed to spawn module action"})),
        );
    };
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(&body).await;
    }
    let Ok(out) = child.wait_with_output().await else {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": "module action execution failed"})),
        );
    };
    let stdout = String::from_utf8_lossy(&out.stdout).to_string();
    let stderr = String::from_utf8_lossy(&out.stderr).to_string();
    if out.status.success() {
        match serde_json::from_str::<Value>(&stdout) {
            Ok(v) => (StatusCode::OK, Json(v)),
            Err(_) => (StatusCode::OK, Json(json!({"status": "ok", "output": stdout}))),
        }
    } else {
        match serde_json::from_str::<Value>(&stdout) {
            Ok(v) => (StatusCode::BAD_REQUEST, Json(v)),
            Err(_) => (
                StatusCode::BAD_REQUEST,
                Json(json!({"status": "error", "message": if !stderr.trim().is_empty() { stderr } else { stdout }})),
            ),
        }
    }
}

/// POST /api/modules/hunting-buddy/mobile/beacon
/// Dedicated mobile GPS & compass heading ingest for Android app / mobile browser PWA.
/// Authenticates via EITHER X-Lodge-Token OR a module-scoped X-Beacon-Token verified inside hunt_mobile.py.
pub async fn hunting_mobile_beacon(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    body: Bytes,
) -> impl IntoResponse {
    let lodge_tok = headers
        .get(TOKEN_HEADER)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    let beacon_tok = headers
        .get("x-beacon-token")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    let lodge_authed = constant_time_eq(lodge_tok.as_bytes(), state.api_token.as_bytes());
    if !lodge_authed && beacon_tok.is_empty() {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"status": "error", "message": "missing X-Lodge-Token or X-Beacon-Token"})),
        );
    }

    let mod_dir = state.george_dir.join("modules").join("hunting-buddy");
    let script = mod_dir.join("tools").join("web_action.sh");
    if !script.is_file() {
        return (
            StatusCode::NOT_FOUND,
            Json(json!({"status": "error", "message": "hunting-buddy module not installed"})),
        );
    }
    let data_dir = state.george_dir.join("module_data").join("hunting-buddy");
    let _ = std::fs::create_dir_all(&data_dir);

    let mut cmd = Command::new("bash");
    cmd.arg(&script)
        .arg("mobile_beacon")
        .env("LODGE_DIR", &state.lodge_dir)
        .env("GEORGE_DIR", &state.george_dir)
        .env("MODULE_ID", "hunting-buddy")
        .env("MODULE_DIR", &mod_dir)
        .env("MODULE_DATA_DIR", &data_dir)
        .env("BEACON_LODGE_AUTHED", if lodge_authed { "1" } else { "0" })
        .env("BEACON_TOKEN", beacon_tok)
        .current_dir(&mod_dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let Ok(mut child) = cmd.spawn() else {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": "failed to invoke mobile_beacon"})),
        );
    };
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(&body).await;
    }
    let Ok(out) = child.wait_with_output().await else {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": "mobile_beacon failed"})),
        );
    };
    let stdout = String::from_utf8_lossy(&out.stdout).to_string();
    let code = if out.status.success() {
        StatusCode::OK
    } else if stdout.contains("unauthorized") || stdout.contains("UNAUTHORIZED") {
        StatusCode::UNAUTHORIZED
    } else {
        StatusCode::BAD_REQUEST
    };
    match serde_json::from_str::<Value>(&stdout) {
        Ok(v) => (code, Json(v)),
        Err(_) => (code, Json(json!({"status": if out.status.success() { "ok" } else { "error" }, "output": stdout}))),
    }
}

/// GET /api/modules/:id/tiles/:layer/:z/:x/:y — Offline-first USGS/OSM basemap tile cache
/// Strict allowlist of public basemap layers & integer tile bounds (zero SSRF).
pub async fn cached_map_tile(
    State(state): State<Arc<AppState>>,
    Path((id, layer, z, x, y)): Path<(String, String, u32, u32, u32)>,
) -> Response {
    if !valid_id(&id) || z > 19 {
        return (StatusCode::BAD_REQUEST, "invalid tile request").into_response();
    }
    let upstream = match layer.as_str() {
        "usgs_aerial" => format!(
            "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/{}/{}/{}",
            z, y, x
        ),
        "usgs_topo" => format!(
            "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{}/{}/{}",
            z, y, x
        ),
        "esri_imagery" | "usgs_hybrid" => format!(
            "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{}/{}/{}",
            z, y, x
        ),
        "esri_labels" => format!(
            "https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{}/{}/{}",
            z, y, x
        ),
        "osm" => format!("https://tile.openstreetmap.org/{}/{}/{}.png", z, x, y),
        _ => return (StatusCode::BAD_REQUEST, "unsupported basemap layer").into_response(),
    };

    let tile_path: PathBuf = state
        .george_dir
        .join("module_data")
        .join(&id)
        .join("tile_cache")
        .join(&layer)
        .join(z.to_string())
        .join(x.to_string())
        .join(format!("{}.tile", y));

    if let Ok(cached) = tokio::fs::read(&tile_path).await {
        if !cached.is_empty() {
            let ctype = if cached.starts_with(b"\x89PNG") {
                "image/png"
            } else {
                "image/jpeg"
            };
            return (
                StatusCode::OK,
                [
                    (header::CONTENT_TYPE, ctype),
                    (header::CACHE_CONTROL, "public, max-age=2592000"),
                ],
                cached,
            )
                .into_response();
        }
    }

    // Fetch via curl (zero extra Rust HTTP client crate) and cache locally for offline deer-camp use
    if let Some(parent) = tile_path.parent() {
        let _ = tokio::fs::create_dir_all(parent).await;
    }
    let out = Command::new("curl")
        .args([
            "-fsSL",
            "--max-time",
            "10",
            "-A",
            "BlueLodge-HuntingBuddy/1.0 (Sovereign Offline Tile Cache)",
            &upstream,
        ])
        .output()
        .await;

    match out {
        Ok(res) if res.status.success() && !res.stdout.is_empty() => {
            let _ = tokio::fs::write(&tile_path, &res.stdout).await;
            let ctype = if res.stdout.starts_with(b"\x89PNG") {
                "image/png"
            } else {
                "image/jpeg"
            };
            (
                StatusCode::OK,
                [
                    (header::CONTENT_TYPE, ctype),
                    (header::CACHE_CONTROL, "public, max-age=2592000"),
                ],
                res.stdout,
            )
                .into_response()
        }
        _ => (StatusCode::BAD_GATEWAY, "tile unavailable offline").into_response(),
    }
}

#[derive(Deserialize, Default)]
pub struct ProxyQuery {
    pub qs: Option<String>,
}

/// Strict localhost-only sidecar proxy for docker_sidecar modules (e.g. PoshTracker FastAPI :8765).
pub async fn proxy_sidecar_get(
    State(state): State<Arc<AppState>>,
    Path((id, subpath)): Path<(String, String)>,
    Query(q): Query<ProxyQuery>,
    headers: HeaderMap,
) -> Response {
    proxy_sidecar_impl(&state, &id, "GET", &subpath, q.qs.as_deref(), &headers, &[]).await
}

pub async fn proxy_sidecar_post(
    State(state): State<Arc<AppState>>,
    Path((id, subpath)): Path<(String, String)>,
    Query(q): Query<ProxyQuery>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    proxy_sidecar_impl(&state, &id, "POST", &subpath, q.qs.as_deref(), &headers, &body).await
}

async fn proxy_sidecar_impl(
    state: &AppState,
    id: &str,
    method: &str,
    subpath: &str,
    qs: Option<&str>,
    headers: &HeaderMap,
    body: &[u8],
) -> Response {
    if !valid_id(id) || subpath.contains("..") || subpath.contains('@') {
        return (StatusCode::BAD_REQUEST, "invalid sidecar proxy path").into_response();
    }
    let mj_path = state.george_dir.join("modules").join(id).join("module.json");
    let Ok(raw) = std::fs::read_to_string(&mj_path) else {
        return (StatusCode::NOT_FOUND, "module not installed").into_response();
    };
    let Ok(mj) = serde_json::from_str::<Value>(&raw) else {
        return (StatusCode::INTERNAL_SERVER_ERROR, "invalid module.json").into_response();
    };
    let port = mj
        .pointer("/runtime/sidecar_port")
        .and_then(|v| v.as_u64())
        .unwrap_or(0);
    if port < 1024 || port > 65535 {
        return (StatusCode::FORBIDDEN, "module has no declared localhost sidecar_port").into_response();
    }
    let clean_sub = subpath.trim_start_matches('/');
    let mut url = format!("http://127.0.0.1:{}/{}", port, clean_sub);
    if let Some(query) = qs {
        if !query.is_empty() && !query.contains('\r') && !query.contains('\n') {
            url.push('?');
            url.push_str(query);
        }
    }
    let req_ct = headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("application/json");
    let mut cmd = Command::new("curl");
    cmd.args(["-sS", "--max-time", "120", "-X", method, "-H", &format!("Content-Type: {}", req_ct)]);
    if let Some(auth) = headers.get(header::AUTHORIZATION).and_then(|v| v.to_str().ok()) {
        cmd.args(["-H", &format!("Authorization: {}", auth)]);
    }
    if !body.is_empty() {
        cmd.args(["--data-binary", "@-"]);
    }
    cmd.arg(&url)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let Ok(mut child) = cmd.spawn() else {
        return (StatusCode::BAD_GATEWAY, "failed to reach module sidecar").into_response();
    };
    if !body.is_empty() {
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(body).await;
        }
    }
    match child.wait_with_output().await {
        Ok(out) if out.status.success() => (
            StatusCode::OK,
            [(header::CONTENT_TYPE, "application/json; charset=utf-8")],
            out.stdout,
        )
            .into_response(),
        Ok(out) => (
            StatusCode::BAD_GATEWAY,
            Json(json!({
                "status": "sidecar_offline",
                "port": port,
                "message": String::from_utf8_lossy(&out.stderr).trim().to_string()
            })),
        )
            .into_response(),
        Err(_) => (StatusCode::BAD_GATEWAY, "sidecar error").into_response(),
    }
}

// ============================================================================
// Universal Monitored Module Task Launcher (Native Blue Lodge ReAct Runtime)
// ============================================================================

#[derive(Deserialize)]
pub struct ModuleTaskImage {
    pub filename: Option<String>,
    pub data_uri: String,
}

#[derive(Deserialize, Default)]
pub struct ModuleTaskLaunchReq {
    pub workflow: String,
    pub params: Option<Value>,
    pub images: Option<Vec<ModuleTaskImage>>,
    pub max_turns: Option<u32>,
}

fn valid_workflow_name(s: &str) -> bool {
    let b = s.as_bytes();
    if b.len() < 2 || b.len() > 48 {
        return false;
    }
    b.iter()
        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'_' || *c == b'-')
}

fn decode_base64_std(input: &str) -> Result<Vec<u8>, String> {
    let mut out = Vec::with_capacity((input.len() * 3) / 4);
    let mut buf: u32 = 0;
    let mut bits: u32 = 0;
    for b in input.bytes() {
        let val = match b {
            b'A'..=b'Z' => (b - b'A') as u32,
            b'a'..=b'z' => (b - b'a' + 26) as u32,
            b'0'..=b'9' => (b - b'0' + 52) as u32,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            b'=' | b'\n' | b'\r' | b' ' | b'\t' => continue,
            _ => return Err("invalid base64 byte".into()),
        };
        buf = (buf << 6) | val;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push(((buf >> bits) & 0xFF) as u8);
        }
    }
    Ok(out)
}

fn detect_image_ext(bytes: &[u8]) -> Option<&'static str> {
    if bytes.len() >= 8 && bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some("png")
    } else if bytes.len() >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
        Some("jpg")
    } else if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Some("webp")
    } else if bytes.len() >= 6 && (bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a")) {
        Some("gif")
    } else {
        None
    }
}

/// POST /api/modules/:id/task/launch
/// Spawns a monitored Blue Lodge ReAct task (`lodge`) in `.sandboxes/mod_<id>_<workflow>_<epoch>/`
/// so the run streams live in BOTH the module's inline TranscriptConsole AND the main Autonomic Task Bay.
pub async fn launch_module_task(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<ModuleTaskLaunchReq>,
) -> impl IntoResponse {
    if !valid_id(&id) || !valid_workflow_name(&req.workflow) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"status": "error", "message": "invalid module id or workflow name"})),
        );
    }

    let mod_dir = state.george_dir.join("modules").join(&id);
    let prompt_script = mod_dir.join("tools").join("workflow_prompt.sh");
    let loop_schema_script = state.lodge_dir.join("lib").join("core").join("loop_schema.py");

    // Check if module provides a declarative ALP v1 loop definition (override > source)
    let resolved_loop_json: Option<Value> = Command::new("python3")
        .arg(&loop_schema_script)
        .args(["resolve", &id, &req.workflow])
        .env("LODGE_DIR", &state.lodge_dir)
        .env("GEORGE_DIR", &state.george_dir)
        .output()
        .await
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| serde_json::from_slice::<Value>(&o.stdout).ok());

    let use_loop_engine = resolved_loop_json.is_some();
    if !use_loop_engine && !prompt_script.is_file() {
        return (
            StatusCode::NOT_FOUND,
            Json(json!({
                "status": "error",
                "message": format!("module '{}' has no declarative workflow '{}.loop.json' or tools/workflow_prompt.sh handler", id, req.workflow)
            })),
        );
    }

    let epoch = crate::helpers::chrono_epoch_secs();
    let task_id = format!("mod_{}_{}_{}", id.replace('-', "_"), req.workflow.replace('-', "_"), epoch);
    let sandbox_dir = state.lodge_dir.join(".sandboxes").join(&task_id);
    let inputs_dir = sandbox_dir.join("inputs");
    if let Err(e) = tokio::fs::create_dir_all(&inputs_dir).await {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": format!("failed to create sandbox: {}", e)})),
        );
    }

    // Decode & persist any attached images safely (max 6 images, 15 MB each, strict magic-byte check)
    let mut saved_images: Vec<String> = Vec::new();
    if let Some(imgs) = req.images.as_ref() {
        if imgs.len() > 6 {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({"status": "error", "message": "maximum 6 images allowed per task"})),
            );
        }
        for (idx, img) in imgs.iter().enumerate() {
            let raw_b64 = match img.data_uri.find(',') {
                Some(pos) => &img.data_uri[pos + 1..],
                None => img.data_uri.as_str(),
            };
            let decoded = match decode_base64_std(raw_b64) {
                Ok(b) if !b.is_empty() && b.len() <= 15 * 1024 * 1024 => b,
                Ok(b) if b.is_empty() => {
                    return (
                        StatusCode::BAD_REQUEST,
                        Json(json!({"status": "error", "message": "empty image payload"})),
                    );
                }
                Ok(_) => {
                    return (
                        StatusCode::PAYLOAD_TOO_LARGE,
                        Json(json!({"status": "error", "message": "image exceeds 15 MB limit"})),
                    );
                }
                Err(e) => {
                    return (
                        StatusCode::BAD_REQUEST,
                        Json(json!({"status": "error", "message": format!("invalid image encoding: {}", e)})),
                    );
                }
            };
            let Some(ext) = detect_image_ext(&decoded) else {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(json!({"status": "error", "message": "unsupported image format (PNG/JPEG/WebP/GIF only)"})),
                );
            };
            let stem = img
                .filename
                .as_deref()
                .unwrap_or("photo")
                .chars()
                .filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-')
                .take(32)
                .collect::<String>();
            let safe_name = format!("{:02}_{}.{}", idx + 1, if stem.is_empty() { "photo" } else { &stem }, ext);
            let dst = inputs_dir.join(&safe_name);
            if let Err(e) = tokio::fs::write(&dst, &decoded).await {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({"status": "error", "message": format!("failed to write image: {}", e)})),
                );
            }
            saved_images.push(dst.to_string_lossy().to_string());
        }
    }

    // Merge saved_images into params JSON and write inputs/params.json for workflow_prompt.sh
    let mut params_val = req.params.unwrap_or_else(|| json!({}));
    if !params_val.is_object() {
        params_val = json!({"value": params_val});
    }
    if let Some(obj) = params_val.as_object_mut() {
        obj.insert("images".to_string(), json!(saved_images));
        obj.insert("sandbox_dir".to_string(), json!(sandbox_dir.to_string_lossy().to_string()));
        obj.insert("task_id".to_string(), json!(task_id.clone()));
    }
    let params_path = inputs_dir.join("params.json");
    let params_str = serde_json::to_string_pretty(&params_val).unwrap_or_else(|_| "{}".into());
    let _ = tokio::fs::write(&params_path, &params_str).await;

    let data_dir = state.george_dir.join("module_data").join(&id);
    let _ = std::fs::create_dir_all(&data_dir);

    // If running legacy workflow_prompt.sh (no declarative .loop.json), render prompt now
    let mut prompt_text = String::new();
    if !use_loop_engine {
        let prompt_out = Command::new("bash")
            .arg(&prompt_script)
            .arg(&req.workflow)
            .arg(&sandbox_dir)
            .arg(&params_path)
            .env("LODGE_DIR", &state.lodge_dir)
            .env("GEORGE_DIR", &state.george_dir)
            .env("MODULE_ID", &id)
            .env("MODULE_DIR", &mod_dir)
            .env("MODULE_DATA_DIR", &data_dir)
            .current_dir(&mod_dir)
            .output()
            .await;

        prompt_text = match prompt_out {
            Ok(out) if out.status.success() => {
                let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
                if s.is_empty() {
                    return (
                        StatusCode::BAD_REQUEST,
                        Json(json!({"status": "error", "message": "workflow_prompt.sh returned an empty prompt"})),
                    );
                }
                s
            }
            Ok(out) => {
                let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
                let msg = if err.is_empty() {
                    String::from_utf8_lossy(&out.stdout).trim().to_string()
                } else {
                    err
                };
                return (
                    StatusCode::BAD_REQUEST,
                    Json(json!({"status": "error", "message": format!("workflow_prompt.sh failed: {}", msg)})),
                );
            }
            Err(e) => {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({"status": "error", "message": format!("failed to run workflow_prompt.sh: {}", e)})),
                );
            }
        };
    }

    // Default to 200 turns (or loop's configured defaults.max_turns) instead of arbitrary 20/28 caps
    let loop_default_turns = resolved_loop_json
        .as_ref()
        .and_then(|v| v.pointer("/loop/defaults/max_turns"))
        .and_then(|v| v.as_u64())
        .unwrap_or(200) as u32;
    let max_turns = req.max_turns.unwrap_or(loop_default_turns).clamp(1, 500);

    let display_cmd = format!("[{}/{}] {}", id, req.workflow, params_val.get("title").or_else(|| params_val.get("brand")).or_else(|| params_val.get("camp")).and_then(|v| v.as_str()).unwrap_or("Monitored Module Workflow"));
    let meta = json!({
        "id": task_id.clone(),
        "type": "module_workflow",
        "module_id": id.clone(),
        "workflow": req.workflow.clone(),
        "engine": if use_loop_engine { "alp_v1_loop_engine" } else { "legacy_workflow_prompt" },
        "max_turns": max_turns,
        "command": display_cmd.clone(),
        "started_at": crate::helpers::chrono_utc_now(),
        "images": saved_images,
    });
    let _ = tokio::fs::write(
        sandbox_dir.join("task_meta.json"),
        serde_json::to_string_pretty(&meta).unwrap_or_default(),
    )
    .await;
    let _ = tokio::fs::write(
        sandbox_dir.join(".phase"),
        format!("Initializing {}/{}", id, req.workflow),
    )
    .await;
    let init_traj = format!(
        "── [MODULE TASK INITIALIZED: {}] ──\n[MODULE]: {} / {}\n[ENGINE]: {} (max_turns={})\n[SANDBOX]: {}\n",
        task_id,
        id,
        req.workflow,
        if use_loop_engine { "ALP v1 Loop Engine + FIFO IPC" } else { "Legacy workflow_prompt.sh" },
        max_turns,
        sandbox_dir.display()
    );
    let traj_file = sandbox_dir.join("trajectory.log");
    let _ = tokio::fs::write(&traj_file, &init_traj).await;

    let lodge_bin = state.lodge_dir.join("lodge");
    let loop_engine_bin = state.lodge_dir.join("lib").join("core").join("loop_engine.sh");
    let lodge_dir_bg = state.lodge_dir.clone();
    let george_dir_bg = state.george_dir.clone();
    let sandbox_bg = sandbox_dir.clone();
    let params_bg = params_path.clone();
    let id_bg = id.clone();
    let wf_bg = req.workflow.clone();
    let task_id_bg = task_id.clone();

    tokio::spawn(async move {
        let traj_path = sandbox_bg.join("trajectory.log");
        let phase_path = sandbox_bg.join(".phase");
        let pid_path = sandbox_bg.join(".pid");
        let done_path = sandbox_bg.join(".done");

        let mut cmd = if use_loop_engine {
            let mut c = Command::new("bash");
            c.arg(&loop_engine_bin)
                .arg("run")
                .arg(&id_bg)
                .arg(&wf_bg)
                .arg(&sandbox_bg)
                .arg(&params_bg)
                .arg(max_turns.to_string());
            c
        } else {
            let mut c = Command::new(&lodge_bin);
            c.args(["--turns", &max_turns.to_string(), &prompt_text]);
            c
        };
        #[cfg(unix)]
        cmd.process_group(0);

        // Redirect stdout/stderr directly to trajectory.log instead of Stdio::piped()
        // so active module workflows survive george-web restarts without SIGPIPE.
        let (out_stdio, err_stdio) = match std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&traj_path)
        {
            Ok(f) => match f.try_clone() {
                Ok(f2) => (Stdio::from(f), Stdio::from(f2)),
                Err(_) => (Stdio::from(f), Stdio::null()),
            },
            Err(_) => (Stdio::null(), Stdio::null()),
        };

        cmd.current_dir(&lodge_dir_bg)
            .env("LODGE_DIR", &lodge_dir_bg)
            .env("GEORGE_DIR", &george_dir_bg)
            .env("GEORGE_WEB_INTERACTIVE", "1")
            .env("AGENT_IPC_PRIORITY", "100")
            .env("LODGE_NO_LOCK", "1")
            .env("LODGE_SKIP_MCP_AUTOSTART", "1")
            .env("LODGE_ACTIVE_MODULE", &id_bg)
            .env("LODGE_ACTIVE_WORKFLOW", &wf_bg)
            .env("LODGE_SANDBOX_DIR", &sandbox_bg)
            .env("GEORGE_TASK_ID", &task_id_bg)
            .stdin(Stdio::null())
            .stdout(out_stdio)
            .stderr(err_stdio);

        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => {
                let _ = crate::helpers::append_to_file(&traj_path, &format!("\n[ERROR]: Failed to spawn lodge: {}\n", e)).await;
                let _ = tokio::fs::write(&phase_path, "Failed").await;
                let _ = tokio::fs::write(&done_path, "1").await;
                return;
            }
        };

        if let Some(pid) = child.id() {
            let _ = tokio::fs::write(&pid_path, pid.to_string()).await;
        }
        let _ = tokio::fs::write(&phase_path, format!("Running {}/{}", id_bg, wf_bg)).await;

        let wait_res = child.wait().await;
        let _ = tokio::fs::remove_file(&pid_path).await;

        if let Ok(raw_traj) = tokio::fs::read_to_string(&traj_path).await {
            let clean_out = crate::helpers::strip_ansi(&raw_traj);
            let _ = tokio::fs::write(sandbox_bg.join("output.txt"), &clean_out).await;
        }

        let final_phase = match wait_res {
            Ok(st) if st.success() => "Completed".to_string(),
            Ok(st) => format!("Failed (exit {})", st.code().unwrap_or(-1)),
            Err(_) => "Failed".to_string(),
        };
        let _ = tokio::fs::write(&phase_path, &final_phase).await;
        let _ = tokio::fs::write(&done_path, "1").await;
    });

    (
        StatusCode::OK,
        Json(json!({
            "status": "ok",
            "task_id": task_id,
            "module_id": id,
            "workflow": req.workflow,
            "sandbox_dir": sandbox_dir.to_string_lossy().to_string(),
            "images_saved": saved_images.len()
        })),
    )
}

/// GET /api/modules/:id/task/:task_id/result
/// Returns completion status, current phase, parsed `result.json` (if written by George), and fallback prose.
pub async fn get_module_task_result(
    State(state): State<Arc<AppState>>,
    Path((id, task_id)): Path<(String, String)>,
) -> impl IntoResponse {
    if !valid_id(&id) || task_id.contains("..") || task_id.contains('/') || task_id.contains('\\') {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"status": "error", "message": "invalid module or task id"})),
        );
    }
    let expected_prefix = format!("mod_{}_", id.replace('-', "_"));
    if !task_id.starts_with(&expected_prefix) {
        return (
            StatusCode::FORBIDDEN,
            Json(json!({"status": "error", "message": "task does not belong to module"})),
        );
    }
    let sandbox_dir = state.lodge_dir.join(".sandboxes").join(&task_id);
    if !sandbox_dir.is_dir() {
        return (
            StatusCode::NOT_FOUND,
            Json(json!({"status": "error", "message": "task sandbox not found"})),
        );
    }
    let mut done = sandbox_dir.join(".done").exists();
    let mut phase = tokio::fs::read_to_string(sandbox_dir.join(".phase"))
        .await
        .unwrap_or_else(|_| if done { "Completed".into() } else { "Running".into() })
        .trim()
        .to_string();
    if !done {
        // Detect stale/crashed task whose PID is no longer alive (e.g. server restart)
        let pid_alive = match tokio::fs::read_to_string(sandbox_dir.join(".pid")).await {
            Ok(pstr) => {
                let p = pstr.trim();
                !p.is_empty() && std::path::Path::new(&format!("/proc/{}", p)).exists()
            }
            Err(_) => false,
        };
        if !pid_alive {
            if let Ok(meta) = tokio::fs::metadata(&sandbox_dir).await {
                if let Ok(mtime) = meta.modified() {
                    if mtime.elapsed().map(|d| d.as_secs() > 8).unwrap_or(false) {
                        done = true;
                        phase = "Interrupted".to_string();
                    }
                }
            }
        }
    }
    let result_val: Option<Value> = match tokio::fs::read_to_string(sandbox_dir.join("result.json")).await {
        Ok(raw) => serde_json::from_str::<Value>(&raw).ok(),
        Err(_) => None,
    };
    let output_text = tokio::fs::read_to_string(sandbox_dir.join("output.txt"))
        .await
        .unwrap_or_default();

    let mut input_images: Vec<String> = Vec::new();
    let inputs_dir = sandbox_dir.join("inputs");
    if let Ok(mut rd) = tokio::fs::read_dir(&inputs_dir).await {
        let mut fnames: Vec<String> = Vec::new();
        while let Ok(Some(ent)) = rd.next_entry().await {
            if let Some(name) = ent.file_name().to_str() {
                let low = name.to_ascii_lowercase();
                if low.ends_with(".jpg") || low.ends_with(".jpeg") || low.ends_with(".png") || low.ends_with(".webp") || low.ends_with(".gif") {
                    fnames.push(name.to_string());
                }
            }
        }
        fnames.sort();
        for fnm in fnames {
            input_images.push(format!("/api/modules/{}/task/{}/input/{}", id, task_id, fnm));
        }
    }

    (
        StatusCode::OK,
        Json(json!({
            "status": "ok",
            "task_id": task_id,
            "module_id": id,
            "done": done,
            "phase": phase,
            "result": result_val,
            "output_text": output_text,
            "input_images": input_images
        })),
    )
}

/// GET /api/modules/:id/tasks
/// Lists recent monitored tasks for module `:id` (newest first) so module UIs can
/// browse past visual searches / briefings and reload their structured `result.json`.
pub async fn list_module_tasks(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    if !valid_id(&id) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"status": "error", "message": "invalid module id"})),
        );
    }
    let expected_prefix = format!("mod_{}_", id.replace('-', "_"));
    let sb_root = state.lodge_dir.join(".sandboxes");
    let mut rows: Vec<(u64, Value)> = Vec::new();

    if let Ok(mut entries) = tokio::fs::read_dir(&sb_root).await {
        while let Ok(Some(ent)) = entries.next_entry().await {
            let fname = ent.file_name().to_string_lossy().to_string();
            if !fname.starts_with(&expected_prefix) {
                continue;
            }
            let p = ent.path();
            if !p.is_dir() {
                continue;
            }
            let meta: Value = tokio::fs::read_to_string(p.join("task_meta.json"))
                .await
                .ok()
                .and_then(|s| serde_json::from_str(&s).ok())
                .unwrap_or_else(|| json!({}));
            let started_at: u64 = meta
                .get("started_at")
                .and_then(|v| v.as_str().and_then(|s| s.parse::<u64>().ok()).or_else(|| v.as_u64()))
                .unwrap_or(0);
            let done = p.join(".done").exists();
            let has_result = p.join("result.json").is_file();
            let phase = tokio::fs::read_to_string(p.join(".phase"))
                .await
                .unwrap_or_else(|_| if done { "Completed".into() } else { "Running".into() })
                .trim()
                .to_string();
            let workflow = meta.get("workflow").and_then(|v| v.as_str()).unwrap_or("").to_string();
            let mut label = meta.get("command").and_then(|v| v.as_str()).unwrap_or(&fname).to_string();
            if has_result {
                if let Ok(rraw) = tokio::fs::read_to_string(p.join("result.json")).await {
                    if let Ok(rv) = serde_json::from_str::<Value>(&rraw) {
                        let b = rv.pointer("/proposed_item/brand").or_else(|| rv.pointer("/forensics/brand")).and_then(|v| v.as_str()).unwrap_or("");
                        let s = rv.pointer("/proposed_item/style_name").or_else(|| rv.pointer("/forensics/style_name")).and_then(|v| v.as_str()).unwrap_or("");
                        if !b.is_empty() || !s.is_empty() {
                            label = format!("{} {}", b, s).trim().to_string();
                        }
                    }
                }
            }
            rows.push((
                started_at,
                json!({
                    "task_id": fname,
                    "workflow": workflow,
                    "label": label,
                    "phase": phase,
                    "done": done,
                    "has_result": has_result,
                    "started_at": started_at,
                }),
            ));
        }
    }
    rows.sort_by(|a, b| b.0.cmp(&a.0));
    let tasks: Vec<Value> = rows.into_iter().take(25).map(|(_, v)| v).collect();
    (StatusCode::OK, Json(json!({"status": "ok", "module_id": id, "tasks": tasks})))
}

/// GET /api/modules/:id/task/:task_id/input/:filename
/// Serves uploaded input images strictly from `.sandboxes/<task_id>/inputs/<filename>`.
pub async fn serve_module_task_input(
    State(state): State<Arc<AppState>>,
    Path((id, task_id, filename)): Path<(String, String, String)>,
) -> Response {
    if !valid_id(&id)
        || task_id.contains("..")
        || task_id.contains('/')
        || task_id.contains('\\')
        || filename.contains("..")
        || filename.contains('/')
        || filename.contains('\\')
    {
        return (StatusCode::BAD_REQUEST, "invalid input path").into_response();
    }
    let expected_prefix = format!("mod_{}_", id.replace('-', "_"));
    if !task_id.starts_with(&expected_prefix) {
        return (StatusCode::FORBIDDEN, "task does not belong to module").into_response();
    }
    let inputs_root = state.lodge_dir.join(".sandboxes").join(&task_id).join("inputs");
    let Ok(canon_root) = std::fs::canonicalize(&inputs_root) else {
        return (StatusCode::NOT_FOUND, "inputs directory not found").into_response();
    };
    let Ok(canon_file) = std::fs::canonicalize(canon_root.join(&filename)) else {
        return (StatusCode::NOT_FOUND, "input file not found").into_response();
    };
    if !canon_file.starts_with(&canon_root) || !canon_file.is_file() {
        return (StatusCode::FORBIDDEN, "path outside task inputs").into_response();
    }
    let Ok(bytes) = tokio::fs::read(&canon_file).await else {
        return (StatusCode::INTERNAL_SERVER_ERROR, "failed to read input file").into_response();
    };
    let ctype = match canon_file.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase().as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "webp" => "image/webp",
        "gif" => "image/gif",
        _ => "application/octet-stream",
    };
    (
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, ctype),
            (header::CACHE_CONTROL, "private, max-age=86400"),
        ],
        bytes,
    )
        .into_response()
}
