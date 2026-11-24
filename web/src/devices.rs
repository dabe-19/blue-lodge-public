//! Paired remote devices for george-web.
//!
//! A browser that is not on localhost (e.g. a phone on the headscale tailnet) pairs
//! once, either with a short one-time code minted on the desktop or with the master
//! token from `.george/web_token`. It then receives:
//!   * an HttpOnly, SameSite=Strict device cookie (`lodge_device`, or
//!     `__Host-lodge_device` when served over HTTPS), and
//!   * a per-device request token, handed to the page via GET /api/session/token
//!     and sent back in `X-Lodge-Token` (synchronizer CSRF token).
//! Guarded routes require BOTH: the cookie proves the device, the header proves the
//! request came from our own page. Revoking the device kills both.
//!
//! Devices stay paired until revoked (operator decision, 2026-10-04). The cookie is
//! refreshed on every page load, so it never lapses while in use.
//! TODO(security): sessions have no absolute expiry by explicit operator choice; set
//! `max_idle_days` handling here if an inactivity timeout is ever wanted.
//! TODO(security): device secrets are stored in plaintext in a 0600 file, matching
//! how `.george/web_token` is stored; hash them at rest if a hashing crate is added.

use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::security::constant_time_eq;

pub const COOKIE_NAME: &str = "lodge_device";
pub const COOKIE_NAME_SECURE: &str = "__Host-lodge_device";
/// 400 days: the maximum cookie lifetime Chromium honours. Refreshed on every load.
pub const COOKIE_MAX_AGE_SECS: u64 = 400 * 24 * 3600;
pub const CODE_TTL_SECS: u64 = 600;
const CODE_ALPHABET: &[u8] = b"ABCDEFGHJKMNPQRSTUVWXYZ23456789"; // no 0/O/1/I/L
pub const CODE_LEN: usize = 8;
const MAX_OUTSTANDING_CODES: usize = 3;
const FAIL_WINDOW_SECS: u64 = 600;
const MAX_FAILS_PER_WINDOW: usize = 10;
const MAX_DEVICES: usize = 32;
const LAST_SEEN_PERSIST_SECS: u64 = 600;

#[derive(Clone, Serialize, Deserialize)]
pub struct Device {
    pub id: String,
    pub label: String,
    pub secret: String,
    pub request_token: String,
    pub created_at: u64,
    pub last_seen_at: u64,
    pub last_ip: String,
    /// "code" or "token": how the device was paired.
    pub via: String,
}

#[derive(Serialize)]
pub struct DevicePublic {
    pub id: String,
    pub label: String,
    pub created_at: u64,
    pub last_seen_at: u64,
    pub last_ip: String,
    pub via: String,
}

struct PairCode {
    code: String,
    expires_at: u64,
}

struct Inner {
    devices: Vec<Device>,
    codes: Vec<PairCode>,
    failures: VecDeque<u64>,
    last_persist: u64,
}

pub struct DeviceStore {
    path: PathBuf,
    inner: Mutex<Inner>,
}

pub fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn random_bytes(n: usize) -> Vec<u8> {
    let mut buf = vec![0u8; n];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut buf))
        .expect("CSPRNG (/dev/urandom) unavailable");
    buf
}

pub fn random_hex(bytes: usize) -> String {
    random_bytes(bytes).iter().map(|b| format!("{:02x}", b)).collect()
}

fn random_code() -> String {
    // Rejection sampling keeps the distribution uniform over the 31-symbol alphabet.
    let limit = (256 / CODE_ALPHABET.len() * CODE_ALPHABET.len()) as u8;
    let mut out = String::with_capacity(CODE_LEN);
    while out.len() < CODE_LEN {
        for b in random_bytes(16) {
            if b < limit && out.len() < CODE_LEN {
                out.push(CODE_ALPHABET[(b as usize) % CODE_ALPHABET.len()] as char);
            }
        }
    }
    out
}

/// Normalises user-typed codes: upper-case, strips spaces and dashes. Returns None
/// unless the result is exactly CODE_LEN symbols from the alphabet.
pub fn normalise_code(raw: &str) -> Option<String> {
    let c: String = raw
        .chars()
        .filter(|ch| !ch.is_whitespace() && *ch != '-')
        .map(|ch| ch.to_ascii_uppercase())
        .collect();
    if c.len() == CODE_LEN && c.bytes().all(|b| CODE_ALPHABET.contains(&b)) {
        Some(c)
    } else {
        None
    }
}

/// Allow-list for device labels; anything else falls back to "device".
pub fn sanitise_label(raw: &str) -> String {
    let t = raw.trim();
    if !t.is_empty()
        && t.len() <= 40
        && t.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, ' ' | '-' | '_' | '.'))
    {
        t.to_string()
    } else {
        "device".to_string()
    }
}

pub fn is_hex_secret(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit())
}

impl DeviceStore {
    pub fn load(george_dir: &Path) -> Self {
        let path = george_dir.join("web_devices.json");
        let devices: Vec<Device> = std::fs::read_to_string(&path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        let devices = devices.into_iter().filter(|d| is_hex_secret(&d.secret)).collect();
        DeviceStore {
            path,
            inner: Mutex::new(Inner { devices, codes: Vec::new(), failures: VecDeque::new(), last_persist: 0 }),
        }
    }

    fn persist(&self, inner: &mut Inner) {
        let tmp = self.path.with_extension("json.tmp");
        if let Ok(body) = serde_json::to_string_pretty(&inner.devices) {
            if std::fs::write(&tmp, body).is_ok() {
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
                }
                let _ = std::fs::rename(&tmp, &self.path);
            }
        }
        inner.last_persist = now();
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// Mints a single-use pairing code. Oldest outstanding code is dropped beyond 3.
    pub fn issue_code(&self) -> (String, u64) {
        let t = now();
        let mut g = self.lock();
        g.codes.retain(|c| c.expires_at > t);
        while g.codes.len() >= MAX_OUTSTANDING_CODES {
            g.codes.remove(0);
        }
        let code = random_code();
        g.codes.push(PairCode { code: code.clone(), expires_at: t + CODE_TTL_SECS });
        (code, CODE_TTL_SECS)
    }

    pub fn rate_limited(&self) -> bool {
        let t = now();
        let mut g = self.lock();
        while g.failures.front().map_or(false, |f| *f + FAIL_WINDOW_SECS <= t) {
            g.failures.pop_front();
        }
        g.failures.len() >= MAX_FAILS_PER_WINDOW
    }

    pub fn record_failure(&self) {
        let t = now();
        self.lock().failures.push_back(t);
    }

    /// Consumes the code if valid. Compares against every outstanding code in
    /// constant time per comparison.
    pub fn redeem_code(&self, code: &str) -> bool {
        let t = now();
        let mut g = self.lock();
        g.codes.retain(|c| c.expires_at > t);
        let mut hit: Option<usize> = None;
        for (i, c) in g.codes.iter().enumerate() {
            if constant_time_eq(c.code.as_bytes(), code.as_bytes()) {
                hit = Some(i);
            }
        }
        if let Some(i) = hit {
            g.codes.remove(i);
            true
        } else {
            false
        }
    }

    pub fn create_device(&self, label: &str, ip: &str, via: &str) -> Result<Device, &'static str> {
        let t = now();
        let mut g = self.lock();
        if g.devices.len() >= MAX_DEVICES {
            return Err("device limit reached; revoke unused devices first");
        }
        let dev = Device {
            id: random_hex(6),
            label: sanitise_label(label),
            secret: random_hex(32),
            request_token: random_hex(32),
            created_at: t,
            last_seen_at: t,
            last_ip: ip.to_string(),
            via: via.to_string(),
        };
        g.devices.push(dev.clone());
        self.persist(&mut g);
        Ok(dev)
    }

    pub fn find_by_secret(&self, secret: &str) -> Option<Device> {
        if !is_hex_secret(secret) {
            return None;
        }
        let g = self.lock();
        let mut found = None;
        for d in g.devices.iter() {
            if constant_time_eq(d.secret.as_bytes(), secret.as_bytes()) {
                found = Some(d.clone());
            }
        }
        found
    }

    /// Updates last-seen; writes to disk at most every 10 minutes.
    pub fn touch(&self, id: &str, ip: &str) {
        let t = now();
        let mut g = self.lock();
        if let Some(d) = g.devices.iter_mut().find(|d| d.id == id) {
            d.last_seen_at = t;
            d.last_ip = ip.to_string();
        }
        if t.saturating_sub(g.last_persist) >= LAST_SEEN_PERSIST_SECS {
            self.persist(&mut g);
        }
    }

    pub fn list(&self) -> Vec<DevicePublic> {
        self.lock()
            .devices
            .iter()
            .map(|d| DevicePublic {
                id: d.id.clone(),
                label: d.label.clone(),
                created_at: d.created_at,
                last_seen_at: d.last_seen_at,
                last_ip: d.last_ip.clone(),
                via: d.via.clone(),
            })
            .collect()
    }

    pub fn revoke(&self, id: &str) -> bool {
        let mut g = self.lock();
        let before = g.devices.len();
        g.devices.retain(|d| d.id != id);
        let changed = g.devices.len() != before;
        if changed {
            self.persist(&mut g);
        }
        changed
    }

    pub fn revoke_all(&self) -> usize {
        let mut g = self.lock();
        let n = g.devices.len();
        g.devices.clear();
        g.codes.clear();
        self.persist(&mut g);
        n
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> DeviceStore {
        let dir = std::env::temp_dir().join(format!("lodge-devtest-{}", random_hex(4)));
        std::fs::create_dir_all(&dir).unwrap();
        DeviceStore::load(&dir)
    }

    #[test]
    fn code_shape_and_single_use() {
        let s = store();
        let (code, ttl) = s.issue_code();
        assert_eq!(ttl, CODE_TTL_SECS);
        assert!(normalise_code(&code).is_some());
        assert!(s.redeem_code(&code));
        assert!(!s.redeem_code(&code), "codes are single-use");
    }

    #[test]
    fn normalise() {
        assert_eq!(normalise_code("abcd-efgh").as_deref(), Some("ABCDEFGH"));
        assert!(normalise_code("ABCD0FGH").is_none(), "0 is not in the alphabet");
        assert!(normalise_code("ABC").is_none());
    }

    #[test]
    fn labels() {
        assert_eq!(sanitise_label(" Pixel 8 "), "Pixel 8");
        assert_eq!(sanitise_label("<script>"), "device");
        assert_eq!(sanitise_label(""), "device");
    }

    #[test]
    fn device_lifecycle() {
        let s = store();
        let d = s.create_device("phone", "100.64.0.5", "code").unwrap();
        assert!(s.find_by_secret(&d.secret).is_some());
        assert!(s.find_by_secret(&random_hex(32)).is_none());
        assert!(s.revoke(&d.id));
        assert!(s.find_by_secret(&d.secret).is_none());
    }

    #[test]
    fn rate_limit() {
        let s = store();
        for _ in 0..MAX_FAILS_PER_WINDOW {
            assert!(!s.rate_limited());
            s.record_failure();
        }
        assert!(s.rate_limited());
    }
}
