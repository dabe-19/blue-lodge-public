use axum::{
    extract::State,
    response::{IntoResponse, Json},
};
use serde::Deserialize;
use serde_json::json;
use std::sync::Arc;
use std::time::Duration;
use tokio::fs;

use crate::helpers::{is_pid_alive, read_pid_from_file};
use crate::state::AppState;

#[derive(Deserialize)]
pub struct McpServerOpPayload {
    pub name: String,
}

#[derive(Deserialize)]
pub struct McpServerAddPayload {
    pub name: String,
    pub command: String,
    #[serde(default)]
    pub description: String,
}

#[derive(Deserialize)]
pub struct McpServerTestPayload {
    pub server: String,
    pub tool: String,
    #[serde(default)]
    pub arguments: serde_json::Value,
}

#[derive(Deserialize)]
pub struct McpCatalogInstallPayload {
    pub id: String,
    pub name: Option<String>,
    pub command: Option<String>,
    pub description: Option<String>,
}

#[derive(Deserialize)]
pub struct McpCustomServerPayload {
    pub name: String,
    #[serde(default)]
    pub description: String,
    pub code: String,
}

pub async fn get_mcp_servers(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let servers_conf = state.george_dir.join("mcp").join("servers.conf");
    let content = fs::read_to_string(&servers_conf).await.unwrap_or_default();
    let run_dir = state.george_dir.join("mcp").join("run");

    let mut servers = Vec::new();

    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let parts: Vec<&str> = line.split('|').collect();
        if parts.is_empty() {
            continue;
        }
        let name = parts[0].trim().to_string();
        let command = parts.get(1).unwrap_or(&"").trim().to_string();
        let description = parts.get(2).unwrap_or(&"").trim().to_string();

        let srv_rundir = run_dir.join(&name);
        let pid_file = srv_rundir.join("pid");
        let ready_file = srv_rundir.join("ready");
        let capabilities_file = srv_rundir.join("capabilities.json");

        let pid = read_pid_from_file(&pid_file);
        let is_alive = pid.map(is_pid_alive).unwrap_or(false);
        let is_ready = ready_file.exists();

        let status = if is_alive && is_ready {
            "online"
        } else if is_alive {
            "starting"
        } else {
            "stopped"
        };

        let server_type = if command.contains("python") {
            "python"
        } else if command.contains("npx") || command.contains("node") {
            "node"
        } else if command.contains("bash") || command.contains(".sh") {
            "bash"
        } else {
            "external"
        };

        let mut tools = serde_json::Value::Array(Vec::new());
        if is_alive && is_ready {
            let script = format!(
                "source '{}/lib/tools/mcp.sh' && mcp_tools_list '{}'",
                state.lodge_dir.display(),
                name
            );
            if let Ok(out) = tokio::time::timeout(
                Duration::from_millis(2000),
                tokio::process::Command::new("bash")
                    .arg("-c")
                    .arg(script)
                    .current_dir(&state.lodge_dir)
                    .output(),
            )
            .await
            {
                if let Ok(output) = out {
                    if output.status.success() {
                        if let Ok(parsed) = serde_json::from_slice::<serde_json::Value>(&output.stdout) {
                            tools = parsed;
                        }
                    }
                }
            }
        }

        let capabilities = if capabilities_file.exists() {
            fs::read_to_string(&capabilities_file)
                .await
                .ok()
                .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
        } else {
            None
        };

        servers.push(json!({
            "name": name,
            "command": command,
            "description": description,
            "status": status,
            "pid": pid,
            "ready": is_ready,
            "server_type": server_type,
            "tools": tools,
            "capabilities": capabilities,
        }));
    }

    Json(json!({ "status": "ok", "servers": servers }))
}

pub async fn start_mcp_server(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<McpServerOpPayload>,
) -> impl IntoResponse {
    let script = format!(
        "source '{}/lib/tools/mcp.sh' && mcp_start '{}'",
        state.lodge_dir.display(),
        payload.name
    );
    let out = tokio::time::timeout(
        Duration::from_secs(20),
        tokio::process::Command::new("bash")
            .arg("-c")
            .arg(script)
            .current_dir(&state.lodge_dir)
            .output(),
    )
    .await;

    match out {
        Ok(Ok(o)) => {
            let stdout = String::from_utf8_lossy(&o.stdout).to_string();
            let stderr = String::from_utf8_lossy(&o.stderr).to_string();
            if o.status.success() {
                Json(json!({ "status": "ok", "message": format!("Server '{}' started", payload.name) }))
            } else {
                Json(json!({ "status": "error", "message": format!("{}{}", stderr, stdout) }))
            }
        }
        Ok(Err(e)) => Json(json!({ "status": "error", "message": e.to_string() })),
        Err(_) => Json(json!({ "status": "error", "message": "Timed out waiting for MCP server handshake" })),
    }
}

pub async fn stop_mcp_server(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<McpServerOpPayload>,
) -> impl IntoResponse {
    let script = format!(
        "source '{}/lib/tools/mcp.sh' && mcp_stop '{}'",
        state.lodge_dir.display(),
        payload.name
    );
    let out = tokio::process::Command::new("bash")
        .arg("-c")
        .arg(script)
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match out {
        Ok(o) => {
            if o.status.success() {
                Json(json!({ "status": "ok", "message": format!("Server '{}' stopped", payload.name) }))
            } else {
                let stderr = String::from_utf8_lossy(&o.stderr).to_string();
                Json(json!({ "status": "error", "message": stderr }))
            }
        }
        Err(e) => Json(json!({ "status": "error", "message": e.to_string() })),
    }
}

pub async fn add_mcp_server(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<McpServerAddPayload>,
) -> impl IntoResponse {
    let script = format!(
        "source '{}/lib/tools/mcp.sh' && mcp_server_add '{}' '{}' '{}'",
        state.lodge_dir.display(),
        payload.name.replace('\'', "\\'"),
        payload.command.replace('\'', "\\'"),
        payload.description.replace('\'', "\\'")
    );
    let out = tokio::process::Command::new("bash")
        .arg("-c")
        .arg(script)
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match out {
        Ok(o) => {
            if o.status.success() {
                Json(json!({ "status": "ok", "name": payload.name }))
            } else {
                let stderr = String::from_utf8_lossy(&o.stderr).to_string();
                Json(json!({ "status": "error", "message": stderr }))
            }
        }
        Err(e) => Json(json!({ "status": "error", "message": e.to_string() })),
    }
}

pub async fn remove_mcp_server(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<McpServerOpPayload>,
) -> impl IntoResponse {
    let script = format!(
        "source '{}/lib/tools/mcp.sh' && mcp_server_remove '{}'",
        state.lodge_dir.display(),
        payload.name
    );
    let out = tokio::process::Command::new("bash")
        .arg("-c")
        .arg(script)
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match out {
        Ok(o) => {
            if o.status.success() {
                Json(json!({ "status": "ok", "name": payload.name }))
            } else {
                let stderr = String::from_utf8_lossy(&o.stderr).to_string();
                Json(json!({ "status": "error", "message": stderr }))
            }
        }
        Err(e) => Json(json!({ "status": "error", "message": e.to_string() })),
    }
}

pub async fn test_mcp_server_tool(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<McpServerTestPayload>,
) -> impl IntoResponse {
    let args_str = payload.arguments.to_string();
    let script = format!(
        "source '{}/lib/tools/mcp.sh' && mcp_tool_call '{}' '{}' '{}'",
        state.lodge_dir.display(),
        payload.server.replace('\'', "\\'"),
        payload.tool.replace('\'', "\\'"),
        args_str.replace('\'', "\\'")
    );

    let out = tokio::time::timeout(
        Duration::from_secs(35),
        tokio::process::Command::new("bash")
            .arg("-c")
            .arg(script)
            .current_dir(&state.lodge_dir)
            .output(),
    )
    .await;

    match out {
        Ok(Ok(o)) => {
            let stdout = String::from_utf8_lossy(&o.stdout).to_string();
            let stderr = String::from_utf8_lossy(&o.stderr).to_string();
            if o.status.success() {
                Json(json!({ "status": "ok", "output": stdout }))
            } else {
                Json(json!({ "status": "error", "message": format!("{}{}", stderr, stdout) }))
            }
        }
        Ok(Err(e)) => Json(json!({ "status": "error", "message": e.to_string() })),
        Err(_) => Json(json!({ "status": "error", "message": "Tool execution timed out" })),
    }
}

pub async fn get_mcp_catalog(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let servers_conf = state.george_dir.join("mcp").join("servers.conf");
    let installed_conf = fs::read_to_string(&servers_conf).await.unwrap_or_default();
    let installed_names: Vec<String> = installed_conf
        .lines()
        .filter_map(|l| {
            let l = l.trim();
            if l.is_empty() || l.starts_with('#') {
                None
            } else {
                l.split('|').next().map(|s| s.trim().to_string())
            }
        })
        .collect();

    let has_node = tokio::process::Command::new("node")
        .arg("--version")
        .output()
        .await
        .map(|o| o.status.success())
        .unwrap_or(false);
    let has_npx = tokio::process::Command::new("npx")
        .arg("--version")
        .output()
        .await
        .map(|o| o.status.success())
        .unwrap_or(false);
    let has_python3 = tokio::process::Command::new("python3")
        .arg("--version")
        .output()
        .await
        .map(|o| o.status.success())
        .unwrap_or(false);
    let has_gcloud = tokio::process::Command::new("gcloud")
        .arg("--version")
        .output()
        .await
        .map(|o| o.status.success())
        .unwrap_or(false);

    let lodge_display = state.lodge_dir.display().to_string();

    let catalog_items = vec![
        json!({
            "id": "playwright",
            "name": "Playwright Browser Automation",
            "category": "Browser & Accessibility",
            "command": "npx -y @automata-ai/mcp-playwright",
            "description": "Full Chromium browser automation over MCP. Enables George to navigate pages, capture screenshots, evaluate DOM, perform click/fill accessibility flows, and troubleshoot web apps.",
            "prerequisites": "Node.js & npx. On WSL/Linux, run `npx playwright install chromium` to install browser binaries.",
            "prereq_satisfied": has_npx,
            "installed": installed_names.contains(&"playwright".to_string()),
            "author": "Community / Microsoft",
            "tags": ["browser", "accessibility", "testing", "web"]
        }),
        json!({
            "id": "autodesk-fusion",
            "name": "Autodesk Fusion 360 Bridge",
            "category": "CAD & Physical Fabrication",
            "command": format!("python3 {}/lib/tools/mcp_server_fusion.py", lodge_display),
            "description": "3D parametric modeling bridge connecting George directly to Autodesk Fusion. Generate generative sketches, extrusions, revolves, and export STLs for 3D printing.",
            "prerequisites": "Python 3 and Autodesk Fusion 360 with local API socket bridge active.",
            "prereq_satisfied": has_python3,
            "installed": installed_names.contains(&"autodesk-fusion".to_string()),
            "author": "Autodesk / George Community",
            "tags": ["cad", "3d-printing", "fusion360", "hardware"]
        }),
        json!({
            "id": "chrome-devtools",
            "name": "Chrome DevTools & Puppeteer",
            "category": "Web Debugging & Diagnostics",
            "command": "npx -y @modelcontextprotocol/server-puppeteer",
            "description": "Direct DevTools instrumentation for live web diagnostics. Inspect console logs, network waterfalls, layout trees, and diagnose web interface regressions.",
            "prerequisites": "Node.js & npx.",
            "prereq_satisfied": has_npx,
            "installed": installed_names.contains(&"chrome-devtools".to_string()) || installed_names.contains(&"puppeteer".to_string()),
            "author": "Model Context Protocol",
            "tags": ["devtools", "debugging", "console", "network"]
        }),
        json!({
            "id": "gcloud",
            "name": "Google Cloud Platform (gcloud)",
            "category": "Cloud Infrastructure",
            "command": format!("bash {}/lib/tools/mcp_server_gcloud.sh", lodge_display),
            "description": "Manage Google Cloud instances, Cloud Run services, Storage buckets, and project configurations through pure-bash JSON-RPC wrappers over gcloud CLI.",
            "prerequisites": "gcloud CLI installed on WSL/Linux and authenticated via `gcloud auth login`.",
            "prereq_satisfied": has_gcloud,
            "installed": installed_names.contains(&"gcloud".to_string()),
            "author": "George Craftsman / Google Cloud",
            "tags": ["gcloud", "cloud-run", "compute", "gcp"]
        }),
        json!({
            "id": "filesystem",
            "name": "Filesystem Scope Access",
            "category": "Workspace & Storage",
            "command": format!("npx -y @modelcontextprotocol/server-filesystem {}", lodge_display),
            "description": "Scoped filesystem access for external directories, repositories, and local asset inspection outside the immediate sandbox.",
            "prerequisites": "Node.js & npx.",
            "prereq_satisfied": has_npx,
            "installed": installed_names.contains(&"filesystem".to_string()),
            "author": "Model Context Protocol",
            "tags": ["filesystem", "workspace", "io"]
        }),
        json!({
            "id": "sqlite",
            "name": "SQLite Inspector",
            "category": "Data & Persistence",
            "command": format!("npx -y @modelcontextprotocol/server-sqlite --db {}/.george/george.db", lodge_display),
            "description": "Query database tables, inspect schema definitions, and run analytical queries over the local SQLite database.",
            "prerequisites": "Node.js & npx.",
            "prereq_satisfied": has_npx,
            "installed": installed_names.contains(&"sqlite".to_string()),
            "author": "Model Context Protocol",
            "tags": ["sqlite", "database", "sql"]
        }),
        json!({
            "id": "george-fetch",
            "name": "George Fetch (Pure Bash)",
            "category": "Built-In Bash",
            "command": format!("bash {}/lib/tools/mcp_server_fetch.sh", lodge_display),
            "description": "Zero-dependency semantic web scraper, article extractor, PDF reader, Reddit API parser, and multi-provider search provider.",
            "prerequisites": "curl, jq (installed).",
            "prereq_satisfied": true,
            "installed": installed_names.contains(&"george-fetch".to_string()),
            "author": "George Core Engine",
            "tags": ["fetch", "search", "pdf", "pure-bash"]
        }),
        json!({
            "id": "george-git",
            "name": "George Git & GitHub (Pure Bash)",
            "category": "Built-In Bash",
            "command": format!("bash {}/lib/tools/mcp_server_git.sh", lodge_display),
            "description": "Git operations, status inspections, branch tracking, diff analysis, and GitHub repository integration without Node.js.",
            "prerequisites": "git, jq (installed).",
            "prereq_satisfied": true,
            "installed": installed_names.contains(&"george-git".to_string()),
            "author": "George Core Engine",
            "tags": ["git", "github", "vcs", "pure-bash"]
        }),
        json!({
            "id": "george-inference",
            "name": "George Remote Inference (Pure Bash)",
            "category": "Built-In Bash",
            "command": format!("bash {}/lib/tools/mcp_server_inference.sh", lodge_display),
            "description": "Remote GPU model catalog, active instance ps checks, model pull orchestration, and keep-alive configuration.",
            "prerequisites": "curl, jq (installed).",
            "prereq_satisfied": true,
            "installed": installed_names.contains(&"george-inference".to_string()),
            "author": "George Core Engine",
            "tags": ["gpu", "inference", "llama", "pure-bash"]
        }),
        json!({
            "id": "george-x",
            "name": "George 𝕏 / Twitter (Pure Bash)",
            "category": "Built-In Bash",
            "command": format!("bash {}/lib/tools/mcp_server_x.sh", lodge_display),
            "description": "𝕏 / Twitter API v2 thread publication, status checking, and tweet deletion via OAuth 1.0a.",
            "prerequisites": "curl, jq, OAuth keys configured.",
            "prereq_satisfied": true,
            "installed": installed_names.contains(&"george-x".to_string()),
            "author": "George Core Engine",
            "tags": ["x", "social", "twitter", "pure-bash"]
        }),
    ];

    Json(json!({
        "status": "ok",
        "system": {
            "node": has_node,
            "npx": has_npx,
            "python3": has_python3,
            "gcloud": has_gcloud,
        },
        "catalog": catalog_items,
    }))
}

pub async fn install_mcp_catalog_server(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<McpCatalogInstallPayload>,
) -> impl IntoResponse {
    let name = payload.name.unwrap_or(payload.id.clone());
    let command = payload.command.unwrap_or_else(|| {
        match payload.id.as_str() {
            "playwright" => "npx -y @automata-ai/mcp-playwright".to_string(),
            "chrome-devtools" => "npx -y @modelcontextprotocol/server-puppeteer".to_string(),
            "filesystem" => format!("npx -y @modelcontextprotocol/server-filesystem {}", state.lodge_dir.display()),
            "sqlite" => format!("npx -y @modelcontextprotocol/server-sqlite --db {}/.george/george.db", state.lodge_dir.display()),
            "george-fetch" => format!("bash {}/lib/tools/mcp_server_fetch.sh", state.lodge_dir.display()),
            "george-git" => format!("bash {}/lib/tools/mcp_server_git.sh", state.lodge_dir.display()),
            "george-inference" => format!("bash {}/lib/tools/mcp_server_inference.sh", state.lodge_dir.display()),
            "george-x" => format!("bash {}/lib/tools/mcp_server_x.sh", state.lodge_dir.display()),
            "gcloud" => format!("bash {}/lib/tools/mcp_server_gcloud.sh", state.lodge_dir.display()),
            "autodesk-fusion" => format!("python3 {}/lib/tools/mcp_server_fusion.py", state.lodge_dir.display()),
            _ => "echo 'Custom MCP'".to_string(),
        }
    });
    let description = payload.description.unwrap_or_else(|| format!("MCP Server: {}", name));

    let script = format!(
        "source '{}/lib/tools/mcp.sh' && mcp_server_add '{}' '{}' '{}'",
        state.lodge_dir.display(),
        name.replace('\'', "\\'"),
        command.replace('\'', "\\'"),
        description.replace('\'', "\\'")
    );

    let out = tokio::process::Command::new("bash")
        .arg("-c")
        .arg(script)
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match out {
        Ok(o) => {
            if o.status.success() {
                Json(json!({ "status": "ok", "name": name, "command": command }))
            } else {
                let stderr = String::from_utf8_lossy(&o.stderr).to_string();
                Json(json!({ "status": "error", "message": stderr }))
            }
        }
        Err(e) => Json(json!({ "status": "error", "message": e.to_string() })),
    }
}

pub async fn create_custom_mcp_server(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<McpCustomServerPayload>,
) -> impl IntoResponse {
    let servers_dir = state.george_dir.join("mcp").join("custom");
    let _ = fs::create_dir_all(&servers_dir).await;

    let clean_name = payload.name.trim().replace(|c: char| !c.is_alphanumeric() && c != '-' && c != '_', "");
    if clean_name.is_empty() {
        return Json(json!({ "status": "error", "message": "Server name must be alphanumeric" }));
    }

    let script_path = servers_dir.join(format!("{}.sh", clean_name));
    if let Err(e) = fs::write(&script_path, &payload.code).await {
        return Json(json!({ "status": "error", "message": format!("Failed to write script: {}", e) }));
    }

    let _ = tokio::process::Command::new("chmod")
        .args(["+x", &script_path.display().to_string()])
        .output()
        .await;

    let cmd = format!("bash {}", script_path.display());
    let desc = if payload.description.trim().is_empty() {
        format!("Custom bash MCP server: {}", clean_name)
    } else {
        payload.description.trim().to_string()
    };

    let script = format!(
        "source '{}/lib/tools/mcp.sh' && mcp_server_add '{}' '{}' '{}'",
        state.lodge_dir.display(),
        clean_name,
        cmd.replace('\'', "\\'"),
        desc.replace('\'', "\\'")
    );

    let out = tokio::process::Command::new("bash")
        .arg("-c")
        .arg(script)
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match out {
        Ok(o) => {
            if o.status.success() {
                Json(json!({ "status": "ok", "name": clean_name, "path": script_path.display().to_string() }))
            } else {
                let stderr = String::from_utf8_lossy(&o.stderr).to_string();
                Json(json!({ "status": "error", "message": stderr }))
            }
        }
        Err(e) => Json(json!({ "status": "error", "message": e.to_string() })),
    }
}
