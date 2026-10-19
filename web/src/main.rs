mod devices;
mod helpers;
mod routes;
mod security;
mod state;

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::fs;
use tower_http::cors::CorsLayer;

use state::{AppState, DockedWorkspace};

#[tokio::main]
async fn main() {
    let lodge_dir = std::env::var("LODGE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
            PathBuf::from(home).join("blue-lodge")
        });
    let george_dir = lodge_dir.join(".george");

    // Mark web observability active so background scripts suppress terminal popups
    let _ = fs::write(george_dir.join(".web_observability"), "1").await;

    // Load active workspace or default to lodge_dir
    let ws_conf = george_dir.join("workspace.conf");
    let initial_ws = if let Ok(data) = fs::read_to_string(&ws_conf).await {
        serde_json::from_str::<DockedWorkspace>(&data).unwrap_or_else(|_| DockedWorkspace {
            path: lodge_dir.clone(),
            mode: "local".to_string(),
            branch: "develop".to_string(),
            repo_name: "blue-lodge".to_string(),
            gitea_synced: true,
        })
    } else {
        DockedWorkspace {
            path: lodge_dir.clone(),
            mode: "local".to_string(),
            branch: "develop".to_string(),
            repo_name: "blue-lodge".to_string(),
            gitea_synced: true,
        }
    };

    let api_token = security::load_or_create_token(&george_dir);
    let devices = Arc::new(devices::DeviceStore::load(&george_dir));

    let state = Arc::new(AppState {
        lodge_dir: lodge_dir.clone(),
        george_dir: george_dir.clone(),
        docked_workspace: Arc::new(tokio::sync::RwLock::new(initial_ws)),
        api_token,
        devices,
    });

    // Same-origin only: no Access-Control-Allow-Origin is ever granted.
    let cors = CorsLayer::new();

    let app = routes::create_router(state, cors);

    let port: u16 = std::env::var("PORT")
        .or_else(|_| std::env::var("GEORGE_WEB_PORT"))
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(3000);

    // Default 0.0.0.0 so paired tailnet devices can connect; non-loopback peers must present a paired
    // device token (security.rs). Set GEORGE_WEB_BIND=127.0.0.1 to refuse all remote connections.
    let bind_ip: std::net::IpAddr = std::env::var("GEORGE_WEB_BIND")
        .ok()
        .and_then(|b| b.trim().parse().ok())
        .unwrap_or(std::net::IpAddr::from([0, 0, 0, 0]));
    let addr = SocketAddr::new(bind_ip, port);
    println!("[george-web] Sovereign Craftsman Engine listening on http://{}", addr);

    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("Failed to bind web listener");

    // Autonomic self-healing on boot: ensure critical daemons (Event Bus & Cron) are active.
    // GEORGE_WEB_NO_AUTOSTART=1 disables this for preview/test instances so they can never
    // start a duplicate cron runner (which would double-fire trading and broadcast jobs).
    let boot_dir = lodge_dir.clone();
    let autostart = std::env::var("GEORGE_WEB_NO_AUTOSTART").map(|v| v != "1").unwrap_or(true);
    if autostart { tokio::spawn(async move {
        tokio::time::sleep(tokio::time::Duration::from_millis(500)).await;
        let boot_script = format!(
            "source '{}/lib/ipc/event_bus.sh' 2>/dev/null && (event_bus_is_running || event_bus_start >/dev/null 2>&1 || true); \
             source '{}/lib/sys/cron.sh' 2>/dev/null && (cron_is_running || cron_start >/dev/null 2>&1 || true);",
            boot_dir.display(), boot_dir.display()
        );
        let _ = tokio::process::Command::new("bash")
            .arg("-c")
            .arg(boot_script)
            .current_dir(&boot_dir)
            .output()
            .await;
    }); }

    axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>())
        .await
        .expect("Server error");
}
