use axum::{
    extract::{Path, State, Query},
    response::sse::{Event, KeepAlive, Sse},
};
use futures_util::stream::Stream;
use serde::Deserialize;
use serde_json::json;
use std::convert::Infallible;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::fs;
use tokio::io::{AsyncReadExt, AsyncSeekExt};

use crate::helpers::*;
use crate::state::AppState;

#[derive(Deserialize, Debug, Default)]
pub struct StreamTaskQuery {
    pub tail: Option<bool>,
    pub from_pos: Option<u64>,
}

pub async fn stream_events(
    State(state): State<Arc<AppState>>,
) -> Sse<impl Stream<Item = Result<Event, Infallible>>> {
    let stream = async_stream::stream! {
        loop {
            let active = get_active_tasks_count(&state.lodge_dir).await;
            let payload = json!({
                "type": "telemetry",
                "timestamp": chrono_utc_now(),
                "active_tasks": active,
            });
            yield Ok(Event::default().event("telemetry").data(payload.to_string()));
            tokio::time::sleep(Duration::from_millis(2000)).await;
        }
    };

    Sse::new(stream).keep_alive(KeepAlive::default())
}

pub async fn stream_task_trajectory(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Query(query): Query<StreamTaskQuery>,
) -> Sse<impl Stream<Item = Result<Event, Infallible>>> {
    let clean_id = id.replace("..", "").replace('/', "");
    let mut sandbox = crate::helpers::resolve_task_dir(&state.lodge_dir, &state.george_dir, &clean_id).await;
    let telem_file = state.george_dir.join("telemetry").join("active").join(format!("{}.json", clean_id));
    let tail_mode = query.tail.unwrap_or(false);
    let initial_pos = query.from_pos.unwrap_or(0);

    let stream = async_stream::stream! {
        let mut traj_log = if clean_id == "sys_cron_sentinels" || clean_id == "sys_cron" || clean_id == "autonomic_sentinel" || clean_id == "usr_cron_sentinels" || clean_id == "usr_cron" {
            let c_log = state.george_dir.join("cron.log");
            if c_log.exists() { Some(c_log) } else { None }
        } else {
            let mut tl = find_trajectory_log(&sandbox).await;
            if tl.is_none() {
                let run_traj = state.george_dir.join("runs").join(&clean_id).join("trajectory.log");
                if run_traj.exists() {
                    tl = Some(run_traj);
                }
            }
            if tl.is_none() {
                if let Ok(content) = fs::read_to_string(&telem_file).await {
                    if let Ok(val) = serde_json::from_str::<serde_json::Value>(&content) {
                        if let Some(log_str) = val.get("log_file").and_then(|v| v.as_str()) {
                            if !log_str.is_empty() {
                                let p = PathBuf::from(log_str);
                                if p.exists() {
                                    tl = Some(p);
                                }
                            }
                        }
                    }
                }
            }
            tl
        };
        let mut last_pos: u64 = if tail_mode {
            if let Some(ref p) = traj_log {
                fs::metadata(p).await.map(|m| m.len()).unwrap_or(0)
            } else {
                0
            }
        } else {
            initial_pos
        };

        loop {
            if traj_log.is_none() {
                sandbox = crate::helpers::resolve_task_dir(&state.lodge_dir, &state.george_dir, &clean_id).await;
                traj_log = find_trajectory_log(&sandbox).await;
                if traj_log.is_none() {
                    let run_traj = state.george_dir.join("runs").join(&clean_id).join("trajectory.log");
                    if run_traj.exists() {
                        traj_log = Some(run_traj);
                    }
                }
                if traj_log.is_none() {
                    if clean_id.starts_with("sub_") {
                        let sub_out = state.george_dir.join("subagents").join(format!("{}.out", clean_id));
                        if sub_out.exists() {
                            traj_log = Some(sub_out);
                        } else {
                            let sub_log = state.george_dir.join("subagents").join(format!("{}.log", clean_id));
                            if sub_log.exists() {
                                traj_log = Some(sub_log);
                            } else if let Some(stripped) = clean_id.strip_prefix("sub_") {
                                if stripped.starts_with("sub_") {
                                    let s_out = state.george_dir.join("subagents").join(format!("{}.out", stripped));
                                    if s_out.exists() {
                                        traj_log = Some(s_out);
                                    } else {
                                        let s_log = state.george_dir.join("subagents").join(format!("{}.log", stripped));
                                        if s_log.exists() {
                                            traj_log = Some(s_log);
                                        }
                                    }
                                }
                            }
                        }
                    } else if clean_id.starts_with("discord_") {
                        let d_raw = state.george_dir.join("discord_sessions").join(&clean_id).join("raw_react.log");
                        if d_raw.exists() {
                            traj_log = Some(d_raw);
                        } else {
                            let rest = clean_id.strip_prefix("discord_").unwrap_or("");
                            let chan_id = rest.split('_').next().unwrap_or(rest);
                            let d_log = state.george_dir.join("discord_sessions").join(format!("session_{}.log", chan_id));
                            if d_log.exists() {
                                traj_log = Some(d_log);
                            }
                        }
                    } else if clean_id == "autonomic_sentinel" || clean_id == "sys_cron_sentinels" || clean_id == "sys_cron" || clean_id == "usr_cron_sentinels" || clean_id == "usr_cron" {
                        let c_log = state.george_dir.join("cron.log");
                        if c_log.exists() {
                            traj_log = Some(c_log);
                        }
                    }
                }
                if traj_log.is_none() {
                    if let Ok(content) = fs::read_to_string(&telem_file).await {
                        if let Ok(val) = serde_json::from_str::<serde_json::Value>(&content) {
                            if let Some(log_str) = val.get("log_file").and_then(|v| v.as_str()) {
                                if !log_str.is_empty() {
                                    let p = PathBuf::from(log_str);
                                    if p.exists() {
                                        traj_log = Some(p);
                                    }
                                }
                            }
                            if traj_log.is_none() {
                                if let Some(trans) = val.get("transcript_file").and_then(|v| v.as_str()) {
                                    if !trans.is_empty() {
                                        let p = PathBuf::from(trans);
                                        if p.exists() {
                                            traj_log = Some(p);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if traj_log.is_none() {
                    let direct_trans = state.george_dir.join("transcripts").join(format!("{}.md", clean_id));
                    if direct_trans.exists() {
                        traj_log = Some(direct_trans);
                    }
                }
                if traj_log.is_none() {
                    let run_traj = state.george_dir.join("runs").join(&clean_id).join("trajectory.log");
                    if run_traj.exists() {
                        traj_log = Some(run_traj);
                    }
                }

                if tail_mode && traj_log.is_some() && last_pos == 0 {
                    if let Some(ref p) = traj_log {
                        last_pos = fs::metadata(p).await.map(|m| m.len()).unwrap_or(0);
                    }
                }
            }

            if let Some(ref p) = traj_log {
                if let Ok(mut f) = fs::File::open(p).await {
                    if let Ok(meta) = f.metadata().await {
                        let len = meta.len();
                        if len < last_pos {
                            last_pos = 0;
                        }
                        if len > last_pos {
                            if f.seek(std::io::SeekFrom::Start(last_pos)).await.is_ok() {
                                let mut buf = Vec::new();
                                if f.read_to_end(&mut buf).await.is_ok() {
                                    let new_text = String::from_utf8_lossy(&buf);
                                    last_pos = len;
                                    for line in new_text.lines() {
                                        let clean_line = line.replace('\r', "");
                                        let trimmed = clean_line.trim();
                                        if !trimmed.is_empty() {
                                            yield Ok(Event::default().event("log").data(clean_line));
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            let raw_phase = fs::read_to_string(sandbox.join(".phase")).await.unwrap_or_default();
            let phase = raw_phase.replace('\r', "");
            if !phase.is_empty() {
                yield Ok(Event::default().event("phase").data(phase.trim().to_string()));
            } else if let Ok(content) = fs::read_to_string(&telem_file).await {
                if let Ok(val) = serde_json::from_str::<serde_json::Value>(&content) {
                    let turn = val.get("turn").and_then(|v| v.as_i64()).unwrap_or(0);
                    let max_turns = val.get("max_turns").and_then(|v| v.as_i64()).unwrap_or(200);
                    let tool = val.get("last_tool").and_then(|v| v.as_str()).unwrap_or("");
                    let ph = if !tool.is_empty() {
                        format!("Turn {}/{} ({})", turn, max_turns, tool)
                    } else {
                        format!("Turn {}/{}", turn, max_turns)
                    };
                    yield Ok(Event::default().event("phase").data(ph.replace('\r', "")));
                }
            }

            let telem_alive = if telem_file.exists() {
                if let Ok(content) = fs::read_to_string(&telem_file).await {
                    if let Ok(val) = serde_json::from_str::<serde_json::Value>(&content) {
                        let pid = val.get("pid").and_then(|v| v.as_i64()).unwrap_or(0) as u32;
                        if pid > 0 { is_pid_alive(pid) } else { true }
                    } else { false }
                } else { false }
            } else { false };

            if sandbox.join(".done").exists() || (!sandbox.exists() && !telem_alive) {
                yield Ok(Event::default().event("done").data("completed"));
                break;
            }

            tokio::time::sleep(Duration::from_millis(1000)).await;
        }
    };

    Sse::new(stream).keep_alive(KeepAlive::default())
}
