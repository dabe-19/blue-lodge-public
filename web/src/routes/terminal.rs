use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        Query, State,
    },
    response::IntoResponse,
};
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::state::AppState;

#[derive(Deserialize)]
pub struct TerminalWsQuery {
    pub file: Option<String>,
    pub cols: Option<u16>,
    pub rows: Option<u16>,
}

pub async fn terminal_ws_handler(
    ws: WebSocketUpgrade,
    State(state): State<Arc<AppState>>,
    Query(q): Query<TerminalWsQuery>,
) -> impl IntoResponse {
    let lodge_dir = state.lodge_dir.clone();
    let docked = state.docked_workspace.read().await.clone();
    let file_arg = if let Some(f) = q.file {
        if f.starts_with('/') {
            f
        } else {
            docked.path.join(f).to_string_lossy().to_string()
        }
    } else {
        String::new()
    };
    let cols = q.cols.unwrap_or(100);
    let rows = q.rows.unwrap_or(30);

    ws.on_upgrade(move |socket| handle_terminal_socket(socket, lodge_dir, file_arg, cols, rows))
}

pub async fn handle_terminal_socket(socket: WebSocket, lodge_dir: PathBuf, file_arg: String, cols: u16, rows: u16) {
    let (mut sender, mut receiver) = socket.split();
    let pty_script = if lodge_dir.join("lib").join("tools").join("nvim_pty.py").exists() {
        lodge_dir.join("lib").join("tools").join("nvim_pty.py")
    } else {
        lodge_dir.join("lib").join("nvim_pty.py")
    };

    let mut cmd = tokio::process::Command::new("python3");
    cmd.arg(&pty_script)
       .arg(&file_arg)
       .arg(cols.to_string())
       .arg(rows.to_string())
       .current_dir(&lodge_dir)
       .stdin(std::process::Stdio::piped())
       .stdout(std::process::Stdio::piped())
       .stderr(std::process::Stdio::inherit());

    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            let _ = sender.send(Message::Text(format!("Failed to spawn nvim: {}", e))).await;
            return;
        }
    };

    let mut stdin = child.stdin.take().expect("Child stdin unavailable");
    let mut stdout = child.stdout.take().expect("Child stdout unavailable");

    let send_task = tokio::spawn(async move {
        let mut buf = [0u8; 4096];
        loop {
            match stdout.read(&mut buf).await {
                Ok(0) => break,
                Ok(n) => {
                    if sender.send(Message::Binary(buf[..n].to_vec())).await.is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    let recv_task = tokio::spawn(async move {
        while let Some(Ok(msg)) = receiver.next().await {
            match msg {
                Message::Text(text) => {
                    if text.contains("\"resize\"") {
                        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) {
                            if v.get("type").and_then(|t| t.as_str()) == Some("resize") {
                                if let (Some(c), Some(r)) = (v["cols"].as_u64(), v["rows"].as_u64()) {
                                    let resize_pkt = format!("\x1b]RESIZE:{}:{}\x07", c, r);
                                    let _ = stdin.write_all(resize_pkt.as_bytes()).await;
                                    let _ = stdin.flush().await;
                                    continue;
                                }
                            }
                        }
                    }
                    if stdin.write_all(text.as_bytes()).await.is_err() {
                        break;
                    }
                    let _ = stdin.flush().await;
                }
                Message::Binary(bin) => {
                    if stdin.write_all(&bin).await.is_err() {
                        break;
                    }
                    let _ = stdin.flush().await;
                }
                Message::Close(_) => break,
                _ => {}
            }
        }
    });

    tokio::select! {
        _ = send_task => {},
        _ = recv_task => {},
    }

    let _ = child.kill().await;
}
