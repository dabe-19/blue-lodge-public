use axum::{
    body::Body,
    extract::{Path, State},
    http::{header, HeaderValue, StatusCode},
    response::{IntoResponse, Json, Response},
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::Arc;
use tokio::fs;
use tokio::process::Command;

use crate::state::AppState;

/// Strict allow-list for TTS audio filenames (`tts_<engine>_<voice>_<16hex>.(wav|m4a)`) to prevent CWE-22 path traversal.
pub fn is_valid_audio_filename(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 96
        && name.starts_with("tts_")
        && (name.ends_with(".wav") || name.ends_with(".m4a"))
        && !name.contains("..")
        && !name.contains('/')
        && !name.contains('\\')
        && name
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '.')
}

fn python_bin(state: &AppState) -> String {
    let venv_py = state.lodge_dir.join(".venv/bin/python");
    if venv_py.exists() {
        venv_py.display().to_string()
    } else {
        "python3".to_string()
    }
}

/// GET /api/cast/audio/:filename
/// Serves synthesized WAV files to Google Home / Cast devices on the local LAN.
pub async fn get_cast_audio(
    State(state): State<Arc<AppState>>,
    Path(filename): Path<String>,
) -> Response {
    if !is_valid_audio_filename(&filename) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"status": "error", "message": "invalid audio filename"})),
        )
            .into_response();
    }

    let file_path = state.george_dir.join("state").join("cast_audio").join(&filename);
    match fs::read(&file_path).await {
        Ok(bytes) => {
            let len_str = bytes.len().to_string();
            let mut res = Response::new(Body::from(bytes));
            *res.status_mut() = StatusCode::OK;
            let h = res.headers_mut();
            let ctype = if filename.ends_with(".m4a") {
                "audio/mp4"
            } else {
                "audio/wav"
            };
            h.insert(header::CONTENT_TYPE, HeaderValue::from_static(ctype));
            h.insert(header::ACCEPT_RANGES, HeaderValue::from_static("bytes"));
            h.insert(
                header::ACCESS_CONTROL_ALLOW_ORIGIN,
                HeaderValue::from_static("*"),
            );
            h.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-cache"));
            if let Ok(cl) = HeaderValue::from_str(&len_str) {
                h.insert(header::CONTENT_LENGTH, cl);
            }
            res
        }
        Err(_) => (
            StatusCode::NOT_FOUND,
            Json(json!({"status": "error", "message": "audio clip not found"})),
        )
            .into_response(),
    }
}

/// GET /api/cast/status
pub async fn get_cast_status(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let py = python_bin(&state);
    let script = state.lodge_dir.join("lib/tools/google_home_cast.py");
    let out = Command::new(&py)
        .arg(&script)
        .arg("status")
        .env("LODGE_DIR", &state.lodge_dir)
        .env("GEORGE_DIR", &state.george_dir)
        .output()
        .await;

    match out {
        Ok(o) => {
            let stdout = String::from_utf8_lossy(&o.stdout);
            if let Ok(val) = serde_json::from_str::<Value>(&stdout) {
                Json(val)
            } else {
                Json(json!({
                    "status": "error",
                    "message": String::from_utf8_lossy(&o.stderr).trim().to_string(),
                }))
            }
        }
        Err(e) => Json(json!({"status": "error", "message": e.to_string()})),
    }
}

#[derive(Deserialize)]
pub struct CastSpeakRequest {
    pub text: String,
    #[serde(default)]
    pub target: Option<String>,
    #[serde(default)]
    pub voice: Option<String>,
    #[serde(default)]
    pub engine: Option<String>,
    #[serde(default)]
    pub speed: Option<f32>,
    #[serde(default)]
    pub volume: Option<f32>,
    #[serde(default)]
    pub force: bool,
}

/// POST /api/cast/speak
pub async fn post_cast_speak(
    State(state): State<Arc<AppState>>,
    Json(req): Json<CastSpeakRequest>,
) -> impl IntoResponse {
    let text = req.text.trim();
    if text.is_empty() || text.len() > 2000 {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"status": "error", "message": "text must be 1..2000 characters"})),
        );
    }

    let py = python_bin(&state);
    let script = state.lodge_dir.join("lib/tools/google_home_cast.py");
    let mut cmd = Command::new(&py);
    cmd.arg(&script)
        .arg("speak")
        .arg(text)
        .arg("--target")
        .arg(req.target.as_deref().unwrap_or("default"))
        .env("LODGE_DIR", &state.lodge_dir)
        .env("GEORGE_DIR", &state.george_dir);

    if let Some(ref v) = req.voice {
        if !v.trim().is_empty() {
            cmd.arg("--voice").arg(v.trim());
        }
    }
    if let Some(ref eng) = req.engine {
        if !eng.trim().is_empty() {
            cmd.arg("--engine").arg(eng.trim());
        }
    }
    if let Some(spd) = req.speed {
        if (0.75..=1.30).contains(&spd) {
            cmd.arg("--speed").arg(format!("{:.2}", spd));
        }
    }
    if let Some(vol) = req.volume {
        if (0.0..=1.0).contains(&vol) {
            cmd.arg("--volume").arg(format!("{:.2}", vol));
        }
    }
    if req.force {
        cmd.arg("--force");
    }

    match cmd.output().await {
        Ok(o) => {
            let stdout = String::from_utf8_lossy(&o.stdout);
            if let Ok(val) = serde_json::from_str::<Value>(&stdout) {
                (StatusCode::OK, Json(val))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({
                        "status": "error",
                        "message": String::from_utf8_lossy(&o.stderr).trim().to_string(),
                    })),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

#[derive(Deserialize)]
pub struct CastVolumeRequest {
    pub target: String,
    pub level: f32,
}

/// POST /api/cast/volume
pub async fn post_cast_volume(
    State(state): State<Arc<AppState>>,
    Json(req): Json<CastVolumeRequest>,
) -> impl IntoResponse {
    if !(0.0..=1.0).contains(&req.level) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"status": "error", "message": "volume level must be between 0.0 and 1.0"})),
        );
    }
    let py = python_bin(&state);
    let script = state.lodge_dir.join("lib/tools/google_home_cast.py");
    let out = Command::new(&py)
        .arg(&script)
        .arg("volume")
        .arg("--target")
        .arg(req.target.trim())
        .arg("--level")
        .arg(format!("{:.2}", req.level))
        .env("LODGE_DIR", &state.lodge_dir)
        .env("GEORGE_DIR", &state.george_dir)
        .output()
        .await;

    match out {
        Ok(o) => {
            let stdout = String::from_utf8_lossy(&o.stdout);
            if let Ok(val) = serde_json::from_str::<Value>(&stdout) {
                (StatusCode::OK, Json(val))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({"status": "error", "message": String::from_utf8_lossy(&o.stderr).trim().to_string()})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

#[derive(Deserialize)]
pub struct CastConfigRequest {
    #[serde(default)]
    pub default_engine: Option<String>,
    #[serde(default)]
    pub default_voice: Option<String>,
    #[serde(default)]
    pub default_speakers: Option<String>,
    #[serde(default)]
    pub speech_speed: Option<f32>,
}

/// POST /api/cast/config
pub async fn post_cast_config(
    State(state): State<Arc<AppState>>,
    Json(req): Json<CastConfigRequest>,
) -> impl IntoResponse {
    let py = python_bin(&state);
    let script = state.lodge_dir.join("lib/tools/google_home_cast.py");
    let mut cmd = Command::new(&py);
    cmd.arg(&script)
        .arg("config")
        .env("LODGE_DIR", &state.lodge_dir)
        .env("GEORGE_DIR", &state.george_dir);

    if let Some(ref eng) = req.default_engine {
        if !eng.trim().is_empty() {
            cmd.arg("--default-engine").arg(eng.trim());
        }
    }
    if let Some(ref v) = req.default_voice {
        if !v.trim().is_empty() {
            cmd.arg("--default-voice").arg(v.trim());
        }
    }
    if let Some(ref s) = req.default_speakers {
        if !s.trim().is_empty() {
            cmd.arg("--default-speakers").arg(s.trim());
        }
    }
    if let Some(spd) = req.speech_speed {
        if (0.75..=1.30).contains(&spd) {
            cmd.arg("--speech-speed").arg(format!("{:.2}", spd));
        }
    }

    match cmd.output().await {
        Ok(o) => {
            let stdout = String::from_utf8_lossy(&o.stdout);
            if let Ok(val) = serde_json::from_str::<Value>(&stdout) {
                (StatusCode::OK, Json(val))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({"status": "error", "message": String::from_utf8_lossy(&o.stderr).trim().to_string()})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

/// GET /api/tyler/status
pub async fn get_tyler_status(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let py = python_bin(&state);
    let script = state.lodge_dir.join("lib/tools/tyler_guardian.py");
    let out = Command::new(&py)
        .arg(&script)
        .arg("status")
        .env("LODGE_DIR", &state.lodge_dir)
        .env("GEORGE_DIR", &state.george_dir)
        .output()
        .await;

    match out {
        Ok(o) => {
            let stdout = String::from_utf8_lossy(&o.stdout);
            if let Ok(mut val) = serde_json::from_str::<Value>(&stdout) {
                // Attach node-local room_layout from gitignored .george/config/tyler_household.json if configured
                let hh_path = state.george_dir.join("config").join("tyler_household.json");
                if let Ok(hh_raw) = tokio::fs::read_to_string(&hh_path).await {
                    if let Ok(hh_val) = serde_json::from_str::<Value>(&hh_raw) {
                        if let Some(rl) = hh_val.get("room_layout").filter(|v| v.is_array()) {
                            if let Some(obj) = val.as_object_mut() {
                                obj.insert("room_layout".to_string(), rl.clone());
                            }
                        }
                    }
                }
                Json(val)
            } else {
                Json(json!({
                    "status": "error",
                    "message": String::from_utf8_lossy(&o.stderr).trim().to_string(),
                }))
            }
        }
        Err(e) => Json(json!({"status": "error", "message": e.to_string()})),
    }
}

#[derive(Deserialize)]
pub struct TylerActionRequest {
    pub action: String,
    #[serde(default)]
    pub ip: Option<String>,
    #[serde(default)]
    pub mac: Option<String>,
    #[serde(default)]
    pub level: Option<String>,
    #[serde(default)]
    pub label: Option<String>,
    #[serde(default)]
    pub mode: Option<String>,
    #[serde(default)]
    pub duration: Option<u32>,
    #[serde(default)]
    pub port: Option<u16>,
    #[serde(default)]
    pub proto: Option<String>,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub display_filter: Option<String>,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub plan_id: Option<String>,
    #[serde(default)]
    pub notes: Option<String>,
    #[serde(default)]
    pub response_mode: Option<String>,
    #[serde(default)]
    pub save_baseline: Option<bool>,
    #[serde(default)]
    pub interface: Option<String>,
    #[serde(default)]
    pub ssid: Option<String>,
    #[serde(default)]
    pub bssid: Option<String>,
    #[serde(default)]
    pub auth: Option<String>,
    #[serde(default)]
    pub key: Option<String>,
    #[serde(default)]
    pub surprise: Option<bool>,
    #[serde(default)]
    pub surprise_name: Option<String>,
    #[serde(default)]
    pub cidr: Option<String>,
    #[serde(default)]
    pub designation: Option<String>,
    #[serde(default)]
    pub payload_json: Option<String>,
}

/// POST /api/tyler/action
pub async fn post_tyler_action(
    State(state): State<Arc<AppState>>,
    Json(req): Json<TylerActionRequest>,
) -> impl IntoResponse {
    let py = python_bin(&state);
    let script = state.lodge_dir.join("lib/tools/tyler_guardian.py");
    let mut cmd = Command::new(&py);
    cmd.arg(&script)
        .env("LODGE_DIR", &state.lodge_dir)
        .env("GEORGE_DIR", &state.george_dir);

    match req.action.as_str() {
        "census" => {
            cmd.arg("census");
        }
        "fingerprint" => {
            let Some(ip) = req.ip.as_deref() else {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(json!({"status": "error", "message": "ip required for fingerprint"})),
                );
            };
            cmd.arg("fingerprint").arg("--ip").arg(ip.trim());
        }
        "vuln_audit" => {
            let Some(ip) = req.ip.as_deref() else {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(json!({"status": "error", "message": "ip required for vuln_audit"})),
                );
            };
            cmd.arg("vuln-audit").arg("--ip").arg(ip.trim());
        }
        "traffic" => {
            let Some(ip) = req.ip.as_deref() else {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(json!({"status": "error", "message": "ip required for traffic inspection"})),
                );
            };
            let dur = req.duration.unwrap_or(5).clamp(2, 20);
            cmd.arg("traffic")
                .arg("--ip")
                .arg(ip.trim())
                .arg("--duration")
                .arg(dur.to_string());
        }
        "upnp" => {
            cmd.arg("upnp").arg("--action").arg(req.mode.as_deref().unwrap_or("list"));
        }
        "trust" => {
            let Some(mac) = req.mac.as_deref() else {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(json!({"status": "error", "message": "mac required for trust update"})),
                );
            };
            let level = req.level.as_deref().unwrap_or("trusted");
            cmd.arg("trust")
                .arg("--mac")
                .arg(mac.trim())
                .arg("--level")
                .arg(level.trim());
            if let Some(ref lbl) = req.label {
                if !lbl.trim().is_empty() {
                    cmd.arg("--label").arg(lbl.trim());
                }
            }
        }
        "intervene" => {
            let mode = req.mode.as_deref().unwrap_or("host_block");
            cmd.arg("intervene").arg("--mode").arg(mode.trim());
            if let Some(ip) = req.ip.as_deref() {
                if !ip.trim().is_empty() {
                    cmd.arg("--ip").arg(ip.trim());
                }
            }
            if let Some(p) = req.port {
                cmd.arg("--port").arg(p.to_string());
            }
            if let Some(ref pr) = req.proto {
                cmd.arg("--proto").arg(pr.trim());
            }
            if let Some(ref pid) = req.plan_id {
                cmd.arg("--plan-id").arg(pid.trim());
            }
            if let Some(ref n) = req.notes {
                cmd.arg("--notes").arg(n.trim());
            }
        }
        "canary" => {
            let sub_act = req.mode.as_deref().unwrap_or("status");
            cmd.arg("canary").arg("--action").arg(sub_act.trim());
        }
        "tshark_watch" => {
            let sub_act = req.mode.as_deref().unwrap_or("list");
            cmd.arg("tshark-watch").arg("--action").arg(sub_act.trim());
            if let Some(ref nm) = req.name {
                cmd.arg("--name").arg(nm.trim());
            }
            if let Some(ref df) = req.display_filter {
                cmd.arg("--display-filter").arg(df.trim());
            }
            if let Some(ref desc) = req.description {
                cmd.arg("--description").arg(desc.trim());
            }
        }
        "immune_patrol" => {
            let dur = req.duration.unwrap_or(8).clamp(3, 30);
            cmd.arg("immune-patrol").arg("--duration").arg(dur.to_string());
        }
        "arp_shield" => {
            let sub_act = req.mode.as_deref().unwrap_or("verify");
            cmd.arg("arp-shield").arg("--action").arg(sub_act.trim());
            if let Some(ref ip) = req.ip {
                if !ip.trim().is_empty() {
                    cmd.arg("--ip").arg(ip.trim());
                }
            }
        }
        "baseline_diff" => {
            let ip = req.ip.as_deref().unwrap_or("all").trim();
            if ip.is_empty() || ip.starts_with('-') || ip.len() > 45 || !ip.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | ':' | '_')) {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(json!({"status": "error", "message": "invalid target ip"})),
                );
            }
            cmd.arg("baseline-diff").arg(format!("--ip={ip}"));
            if req.save_baseline.unwrap_or(false) {
                cmd.arg("--save-baseline");
            }
        }
        "egress_audit" => {
            let ip = req.ip.as_deref().unwrap_or("all").trim();
            if ip.is_empty() || ip.starts_with('-') || ip.len() > 45 || !ip.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | ':' | '_')) {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(json!({"status": "error", "message": "invalid target ip"})),
                );
            }
            let dur = req.duration.unwrap_or(8).clamp(3, 30);
            cmd.arg("egress-audit")
                .arg(format!("--ip={ip}"))
                .arg(format!("--duration={dur}"));
            if req.save_baseline.unwrap_or(false) {
                cmd.arg("--save-baseline");
            }
        }
        "l2_watch" => {
            cmd.arg("l2-watch");
        }
        "policy" => {
            cmd.arg("policy");
            if let Some(ref rm) = req.response_mode {
                cmd.arg("--response-mode").arg(rm.trim());
            }
        }
        "prune" => {
            cmd.arg("prune");
        }
        "spelunk" => {
            let mode = req.mode.as_deref().unwrap_or("discover");
            cmd.arg("spelunk").arg("--mode").arg(mode.trim());
            if let Some(ref iface) = req.interface {
                if !iface.trim().is_empty() {
                    cmd.arg("--interface").arg(iface.trim());
                }
            }
            if let Some(ref ip) = req.ip {
                if !ip.trim().is_empty() {
                    cmd.arg("--ip").arg(ip.trim());
                }
            }
            if let Some(dur) = req.duration {
                cmd.arg("--duration").arg(dur.clamp(2, 60).to_string());
            }
        }
        "wifi_spelunk" => {
            let mode = req.mode.as_deref().unwrap_or("scan_airspace");
            cmd.arg("wifi-spelunk").arg("--mode").arg(mode.trim());
            if let Some(ref s) = req.ssid {
                if !s.trim().is_empty() {
                    cmd.arg("--ssid").arg(s.trim());
                }
            }
            if let Some(ref b) = req.bssid {
                if !b.trim().is_empty() {
                    cmd.arg("--bssid").arg(b.trim());
                }
            }
            if let Some(ref a) = req.auth {
                if !a.trim().is_empty() {
                    cmd.arg("--auth").arg(a.trim());
                }
            }
            if let Some(ref k) = req.key {
                if !k.trim().is_empty() {
                    cmd.arg("--key").arg(k.trim());
                }
            }
            if let Some(dur) = req.duration {
                cmd.arg("--timeout").arg(dur.clamp(3, 90).to_string());
            }
            if req.surprise.unwrap_or(false) {
                cmd.arg("--surprise");
            }
            if let Some(ref sn) = req.surprise_name {
                if !sn.trim().is_empty() {
                    cmd.arg("--surprise-name").arg(sn.trim());
                }
            }
        }
        "designations" => {
            let sub_act = req.mode.as_deref().unwrap_or("get");
            cmd.arg("designations").arg("--action").arg(sub_act.trim());
            if let Some(ref c) = req.cidr {
                if !c.trim().is_empty() {
                    cmd.arg("--cidr").arg(c.trim());
                }
            }
            if let Some(ref d) = req.designation {
                if !d.trim().is_empty() {
                    cmd.arg("--designation").arg(d.trim());
                }
            }
            if let Some(ref l) = req.label {
                if !l.trim().is_empty() {
                    cmd.arg("--label").arg(l.trim());
                }
            }
            if let Some(ref pj) = req.payload_json {
                if !pj.trim().is_empty() {
                    cmd.arg("--payload-json").arg(pj.trim());
                }
            }
        }
        "emergency_reset" => {
            cmd.arg("emergency-reset");
        }
        _ => {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({"status": "error", "message": "unsupported tyler action"})),
            );
        }
    }

    match cmd.output().await {
        Ok(o) => {
            let stdout = String::from_utf8_lossy(&o.stdout);
            if let Ok(val) = serde_json::from_str::<Value>(&stdout) {
                (StatusCode::OK, Json(val))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({
                        "status": "error",
                        "message": String::from_utf8_lossy(&o.stderr).trim().to_string(),
                    })),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_is_valid_audio_filename() {
        assert!(is_valid_audio_filename("tts_alan_0123456789abcdef.wav"));
        assert!(is_valid_audio_filename("tts_amy_deadbeef.wav"));
        assert!(!is_valid_audio_filename("../etc/passwd"));
        assert!(!is_valid_audio_filename("tts_../../secret.wav"));
        assert!(!is_valid_audio_filename("other_file.mp3"));
    }
}

