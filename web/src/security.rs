//! Request security for george-web.
//!
//! Threat model: the server binds 0.0.0.0 and exposes endpoints that can sign and
//! broadcast blockchain transactions. Two attacker classes matter:
//!   1. A website open in the operator's browser (cross-site request / WebSocket /
//!      DNS rebinding). Blocked by the Origin guard and the Host check on the token
//!      endpoint.
//!   2. Another host on the LAN/tailnet. Blocked from fund-moving routes by the
//!      per-install token (handed out to loopback peers only) or by a paired-device
//!      cookie + per-device request token (see `devices.rs`).
//!
//! TODO(security): the server has no user authentication for the remaining
//! (non-financial) routes, including chat and the terminal WebSocket; binding to
//! 127.0.0.1 by default would further reduce exposure but changes existing LAN
//! workflows, so it is left configurable. See docs/REMOTE_ACCESS_SECURITY.md.

use axum::{
    body::Body,
    extract::{ConnectInfo, Request, State},
    http::{header, HeaderMap, HeaderValue, Method, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::json;
use std::io::Read;
use std::net::SocketAddr;
use std::path::Path;
use std::sync::Arc;

use crate::devices::{self, Device};
use crate::state::AppState;

pub const TOKEN_HEADER: &str = "x-lodge-token";

/// Loads the per-install API token, creating it (0600) from the OS CSPRNG if absent.
pub fn load_or_create_token(george_dir: &Path) -> String {
    let path = george_dir.join("web_token");
    if let Ok(existing) = std::fs::read_to_string(&path) {
        let t = existing.trim().to_string();
        if t.len() >= 32 && t.chars().all(|c| c.is_ascii_hexdigit()) {
            return t;
        }
    }
    let mut buf = [0u8; 32];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut buf))
        .expect("CSPRNG (/dev/urandom) unavailable; refusing to start without a secure token");
    let token: String = buf.iter().map(|b| format!("{:02x}", b)).collect();
    let _ = std::fs::create_dir_all(george_dir);
    std::fs::write(&path, &token).expect("could not persist web token");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
    token
}

pub(crate) fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b.iter()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn host_of(authority: &str) -> &str {
    // strips scheme, path and port; handles [::1]:3000
    let a = authority
        .trim_start_matches("http://")
        .trim_start_matches("https://")
        .trim_start_matches("ws://")
        .trim_start_matches("wss://");
    let a = a.split('/').next().unwrap_or("");
    if a.starts_with('[') {
        return a.split(']').next().map(|s| s.trim_start_matches('[')).unwrap_or("");
    }
    a.rsplit_once(':').map(|(h, _)| h).unwrap_or(a)
}

fn authority_of(origin: &str) -> &str {
    origin
        .trim_start_matches("http://")
        .trim_start_matches("https://")
        .split('/')
        .next()
        .unwrap_or("")
}

fn is_loopback_host(h: &str) -> bool {
    matches!(h, "localhost" | "127.0.0.1" | "::1")
}

fn forbidden(msg: &str) -> Response {
    (StatusCode::FORBIDDEN, Json(json!({"status": "error", "message": msg}))).into_response()
}

/// Global guard: rejects cross-origin browser requests (including WebSocket upgrades,
/// which browsers do not subject to CORS). Same-origin requests and non-browser
/// clients (no Origin header) pass.
pub async fn origin_guard(req: Request, next: Next) -> Response {
    let headers = req.headers();
    if let Some(site) = headers.get("sec-fetch-site").and_then(|v| v.to_str().ok()) {
        if site.eq_ignore_ascii_case("cross-site") {
            return forbidden("cross-site request rejected");
        }
    }
    if let Some(origin) = headers.get(header::ORIGIN).and_then(|v| v.to_str().ok()) {
        let host_hdr = headers
            .get(header::HOST)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        if origin == "null" {
            return forbidden("opaque origin rejected");
        }
        let same_origin = !host_hdr.is_empty() && authority_of(origin).eq_ignore_ascii_case(host_hdr);
        if !same_origin {
            return forbidden("foreign origin rejected");
        }
    }
    next.run(req).await
}

fn requires_token(method: &Method, path: &str) -> bool {
    if path == "/api/session/token" {
        return false;
    }
    if path.starts_with("/api/wallet/") {
        return true; // all wallet routes, including reads (addresses, keystore listing)
    }
    if path.starts_with("/api/finance/") {
        return method != Method::GET && method != Method::HEAD;
    }
    if path == "/api/hub/accounts" {
        return true; // account identities are private
    }
    if path.starts_with("/api/hub/") {
        return method != Method::GET && method != Method::HEAD; // draft/approve/install/activate/login
    }
    if path.starts_with("/api/models/") || path.starts_with("/api/model/") || path == "/api/system/gamemode"
        || path.starts_with("/api/training/") {
        return method != Method::GET && method != Method::HEAD; // GPU service switches, training launches, file writes
    }
    false
}

/// Token gate for fund-moving and key-handling routes. Accepts the master token, or
/// a paired device's request token presented together with that device's cookie.
pub async fn token_guard(
    State(state): State<Arc<AppState>>,
    req: Request,
    next: Next,
) -> Response {
    if requires_token(req.method(), req.uri().path()) {
        let presented = req
            .headers()
            .get(TOKEN_HEADER)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        let ok = constant_time_eq(presented.as_bytes(), state.api_token.as_bytes())
            || device_from_cookie(&state, req.headers())
                .map(|d| constant_time_eq(presented.as_bytes(), d.request_token.as_bytes()))
                .unwrap_or(false);
        if !ok {
            return (
                StatusCode::UNAUTHORIZED,
                Json(json!({"status": "error", "message": "missing or invalid X-Lodge-Token"})),
            )
                .into_response();
        }
    }
    next.run(req).await
}

/// Adds conservative security headers to every response.
pub async fn security_headers(req: Request, next: Next) -> Response {
    let mut res = next.run(req).await;
    let h = res.headers_mut();
    h.insert("x-content-type-options", HeaderValue::from_static("nosniff"));
    h.insert("x-frame-options", HeaderValue::from_static("SAMEORIGIN"));
    h.insert("referrer-policy", HeaderValue::from_static("no-referrer"));
    h.insert(
        "permissions-policy",
        HeaderValue::from_static("camera=(), microphone=(), geolocation=(), payment=()"),
    );
    // TODO(security): add script-src once the existing inline handlers and CDN xterm
    // assets are vendored; a strict script-src today would break the UI.
    h.insert(
        "content-security-policy",
        HeaderValue::from_static("frame-ancestors 'self'; object-src 'none'; base-uri 'self'"),
    );
    res
}

/// True only for the operator's own browser on this machine: loopback peer, loopback
/// Host header (defeats DNS rebinding) and no proxy forwarding headers (a reverse
/// proxy on this host would otherwise make every remote client look local).
fn is_local_request(peer: &SocketAddr, headers: &HeaderMap) -> bool {
    let host_hdr = headers.get(header::HOST).and_then(|v| v.to_str().ok()).unwrap_or("");
    peer.ip().is_loopback()
        && is_loopback_host(host_of(host_hdr))
        && !headers.contains_key("x-forwarded-for")
        && !headers.contains_key("forwarded")
}

/// HTTPS is only trusted when a reverse proxy on this host says so.
fn is_https(peer: &SocketAddr, headers: &HeaderMap) -> bool {
    peer.ip().is_loopback()
        && headers
            .get("x-forwarded-proto")
            .and_then(|v| v.to_str().ok())
            .map(|v| v.eq_ignore_ascii_case("https"))
            .unwrap_or(false)
}

fn client_ip(peer: &SocketAddr, headers: &HeaderMap) -> String {
    if peer.ip().is_loopback() {
        if let Some(xff) = headers.get("x-forwarded-for").and_then(|v| v.to_str().ok()) {
            if let Some(first) = xff.split(',').next() {
                let ip = first.trim();
                if ip.parse::<std::net::IpAddr>().is_ok() {
                    return ip.to_string();
                }
            }
        }
    }
    peer.ip().to_string()
}

fn cookie_value<'a>(headers: &'a HeaderMap, name: &str) -> Option<&'a str> {
    for hv in headers.get_all(header::COOKIE).iter() {
        let Ok(s) = hv.to_str() else { continue };
        for part in s.split(';') {
            if let Some((k, v)) = part.trim().split_once('=') {
                if k == name {
                    return Some(v.trim());
                }
            }
        }
    }
    None
}

fn device_from_cookie(state: &AppState, headers: &HeaderMap) -> Option<Device> {
    let secret = cookie_value(headers, devices::COOKIE_NAME_SECURE)
        .or_else(|| cookie_value(headers, devices::COOKIE_NAME))?;
    state.devices.find_by_secret(secret)
}

fn device_cookie(secret: &str, https: bool, max_age: u64) -> HeaderValue {
    // TODO(security): over plain HTTP (headscale without TLS) the Secure flag cannot be
    // set or browsers drop the cookie; the tailnet's WireGuard layer encrypts transit.
    let s = if https {
        format!(
            "{}={}; Path=/; Max-Age={}; HttpOnly; SameSite=Strict; Secure",
            devices::COOKIE_NAME_SECURE, secret, max_age
        )
    } else {
        format!(
            "{}={}; Path=/; Max-Age={}; HttpOnly; SameSite=Strict",
            devices::COOKIE_NAME, secret, max_age
        )
    };
    HeaderValue::from_str(&s).unwrap_or_else(|_| HeaderValue::from_static(""))
}

fn clear_cookies(res: &mut Response) {
    for v in [
        format!("{}=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict", devices::COOKIE_NAME),
        format!("{}=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict; Secure", devices::COOKIE_NAME_SECURE),
    ] {
        if let Ok(hv) = HeaderValue::from_str(&v) {
            res.headers_mut().append(header::SET_COOKIE, hv);
        }
    }
}

fn is_master(state: &AppState, headers: &HeaderMap) -> bool {
    let presented = headers.get(TOKEN_HEADER).and_then(|v| v.to_str().ok()).unwrap_or("");
    constant_time_eq(presented.as_bytes(), state.api_token.as_bytes())
}

fn no_store(mut res: Response) -> Response {
    res.headers_mut().insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    res
}

/// Issues the request token to (a) the local browser (master token) or (b) a paired
/// device presenting its cookie (per-device token; the cookie is refreshed so a
/// device in use never lapses). Everyone else gets 403 + `pairing: true`.
pub async fn get_session_token(
    State(state): State<Arc<AppState>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
) -> Response {
    if is_local_request(&peer, &headers) {
        return no_store(
            Json(json!({"status": "ok", "kind": "local", "token": state.api_token})).into_response(),
        );
    }
    if let Some(dev) = device_from_cookie(&state, &headers) {
        state.devices.touch(&dev.id, &client_ip(&peer, &headers));
        let mut res = Json(json!({
            "status": "ok",
            "kind": "device",
            "token": dev.request_token,
            "device": {"id": dev.id, "label": dev.label},
        }))
        .into_response();
        res.headers_mut().append(
            header::SET_COOKIE,
            device_cookie(&dev.secret, is_https(&peer, &headers), devices::COOKIE_MAX_AGE_SECS),
        );
        return no_store(res);
    }
    no_store(
        (
            StatusCode::FORBIDDEN,
            Json(json!({
                "status": "error",
                "pairing": true,
                "message": "this device is not paired; enter a pairing code or the token from .george/web_token",
            })),
        )
            .into_response(),
    )
}

#[derive(serde::Deserialize)]
pub struct PairBody {
    credential: String,
    #[serde(default)]
    label: String,
}

/// Pairs the calling browser using a one-time code or the master token.
/// Rate limited: 10 failures per 10 minutes (global) locks pairing out.
pub async fn post_pair(
    State(state): State<Arc<AppState>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(body): Json<PairBody>,
) -> Response {
    if state.devices.rate_limited() {
        return no_store(
            (
                StatusCode::TOO_MANY_REQUESTS,
                Json(json!({"status": "error", "message": "too many failed pairing attempts; wait 10 minutes"})),
            )
                .into_response(),
        );
    }
    let cred = body.credential.trim();
    let via = if cred.len() >= 32 && cred.bytes().all(|b| b.is_ascii_hexdigit()) {
        constant_time_eq(cred.as_bytes(), state.api_token.as_bytes()).then_some("token")
    } else {
        devices::normalise_code(cred)
            .filter(|c| state.devices.redeem_code(c))
            .map(|_| "code")
    };
    let ip = client_ip(&peer, &headers);
    let Some(via) = via else {
        state.devices.record_failure();
        eprintln!("[george-web] pairing attempt rejected from {}", ip);
        return no_store(
            (
                StatusCode::UNAUTHORIZED,
                Json(json!({"status": "error", "message": "invalid or expired pairing code / token"})),
            )
                .into_response(),
        );
    };
    match state.devices.create_device(&body.label, &ip, via) {
        Ok(dev) => {
            eprintln!("[george-web] paired device {} ({}) from {} via {}", dev.id, dev.label, ip, via);
            let mut res = Json(json!({
                "status": "ok",
                "kind": "device",
                "token": dev.request_token,
                "device": {"id": dev.id, "label": dev.label},
            }))
            .into_response();
            res.headers_mut().append(
                header::SET_COOKIE,
                device_cookie(&dev.secret, is_https(&peer, &headers), devices::COOKIE_MAX_AGE_SECS),
            );
            no_store(res)
        }
        Err(msg) => no_store(
            (StatusCode::CONFLICT, Json(json!({"status": "error", "message": msg}))).into_response(),
        ),
    }
}

/// Master token only: mint a one-time pairing code (8 chars, 10 minutes, single use).
pub async fn post_pair_code(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Response {
    if !is_master(&state, &headers) {
        return forbidden("master token required (desktop browser or .george/web_token)");
    }
    let (code, ttl) = state.devices.issue_code();
    no_store(Json(json!({"status": "ok", "code": code, "expires_in": ttl})).into_response())
}

/// Master token only: list paired devices (secrets are never returned).
pub async fn get_devices(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Response {
    if is_master(&state, &headers) {
        return no_store(Json(json!({"status": "ok", "devices": state.devices.list()})).into_response());
    }
    forbidden("master token required")
}

#[derive(serde::Deserialize)]
pub struct RevokeBody {
    #[serde(default)]
    id: String,
    #[serde(default)]
    all: bool,
}

/// Master token only: revoke one device by id, or all devices.
pub async fn post_revoke(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<RevokeBody>,
) -> Response {
    if !is_master(&state, &headers) {
        return forbidden("master token required");
    }
    if body.all {
        let n = state.devices.revoke_all();
        eprintln!("[george-web] revoked all {} paired devices", n);
        return no_store(Json(json!({"status": "ok", "revoked": n})).into_response());
    }
    if body.id.len() != 12 || !body.id.bytes().all(|b| b.is_ascii_hexdigit()) {
        return no_store(
            (StatusCode::BAD_REQUEST, Json(json!({"status": "error", "message": "invalid device id"})))
                .into_response(),
        );
    }
    let ok = state.devices.revoke(&body.id);
    if ok {
        eprintln!("[george-web] revoked device {}", body.id);
    }
    no_store(Json(json!({"status": if ok { "ok" } else { "not_found" }, "revoked": ok as u8})).into_response())
}

/// A paired device un-pairs itself ("forget this device"). Requires the device's own
/// request token so a cross-site request cannot log the operator out.
pub async fn post_forget(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Response {
    let presented = headers.get(TOKEN_HEADER).and_then(|v| v.to_str().ok()).unwrap_or("");
    let Some(dev) = device_from_cookie(&state, &headers) else {
        let mut res = Json(json!({"status": "ok", "revoked": 0})).into_response();
        clear_cookies(&mut res);
        return no_store(res);
    };
    if !constant_time_eq(presented.as_bytes(), dev.request_token.as_bytes()) {
        return forbidden("device request token required");
    }
    state.devices.revoke(&dev.id);
    eprintln!("[george-web] device {} forgot itself", dev.id);
    let mut res = Json(json!({"status": "ok", "revoked": 1})).into_response();
    clear_cookies(&mut res);
    no_store(res)
}

#[allow(dead_code)]
pub fn empty_body() -> Body {
    Body::empty()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_parsing() {
        assert_eq!(host_of("localhost:3000"), "localhost");
        assert_eq!(host_of("http://127.0.0.1:3000/x"), "127.0.0.1");
        assert_eq!(host_of("[::1]:3000"), "::1");
        assert_eq!(host_of("evil.example.com"), "evil.example.com");
    }

    #[test]
    fn token_scope() {
        assert!(requires_token(&Method::POST, "/api/finance/eth/transfer"));
        assert!(!requires_token(&Method::GET, "/api/finance/multichain"));
        assert!(requires_token(&Method::GET, "/api/wallet/list"));
        assert!(!requires_token(&Method::GET, "/api/session/token"));
        assert!(!requires_token(&Method::POST, "/api/chat"));
        assert!(requires_token(&Method::POST, "/api/hub/profile/x/approve"));
        assert!(requires_token(&Method::POST, "/api/hub/login"));
        assert!(requires_token(&Method::GET, "/api/hub/accounts"));
        assert!(!requires_token(&Method::GET, "/api/hub/quants"));
        assert!(!requires_token(&Method::GET, "/api/hub/library"));
        assert!(requires_token(&Method::POST, "/api/hub/import-local"));
        assert!(requires_token(&Method::DELETE, "/api/hub/library/file"));
        assert!(requires_token(&Method::POST, "/api/hub/presets/x/run"));
        assert!(requires_token(&Method::POST, "/api/hub/train/kit"));
        assert!(requires_token(&Method::POST, "/api/training/run"));
        assert!(!requires_token(&Method::GET, "/api/training/status"));
        assert!(requires_token(&Method::POST, "/api/model/stage-pull"));
        assert!(requires_token(&Method::POST, "/api/system/gamemode"));
        assert!(!requires_token(&Method::GET, "/api/system/gamemode"));
    }

    #[test]
    fn ct_eq() {
        assert!(constant_time_eq(b"abc", b"abc"));
        assert!(!constant_time_eq(b"abc", b"abd"));
        assert!(!constant_time_eq(b"abc", b"ab"));
    }

    #[test]
    fn local_detection() {
        let lo: SocketAddr = "127.0.0.1:5555".parse().unwrap();
        let tail: SocketAddr = "100.64.0.7:5555".parse().unwrap();
        let mut h = HeaderMap::new();
        h.insert(header::HOST, HeaderValue::from_static("localhost:3000"));
        assert!(is_local_request(&lo, &h));
        assert!(!is_local_request(&tail, &h));
        h.insert("x-forwarded-for", HeaderValue::from_static("100.64.0.7"));
        assert!(!is_local_request(&lo, &h), "proxied requests are never local");
        let mut rebind = HeaderMap::new();
        rebind.insert(header::HOST, HeaderValue::from_static("evil.example.com"));
        assert!(!is_local_request(&lo, &rebind));
    }

    #[test]
    fn cookie_parse() {
        let mut h = HeaderMap::new();
        h.insert(header::COOKIE, HeaderValue::from_static("a=1; lodge_device=abc; b=2"));
        assert_eq!(cookie_value(&h, "lodge_device"), Some("abc"));
        assert_eq!(cookie_value(&h, "missing"), None);
    }
}
