CREATE TABLE IF NOT EXISTS chunks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source TEXT NOT NULL,       -- ref, journal, george, doc:<name>
    section TEXT NOT NULL,      -- section heading
    content TEXT NOT NULL,      -- section body
    filepath TEXT NOT NULL,     -- original file path
    indexed_at TEXT NOT NULL    -- ISO timestamp
);

CREATE INDEX IF NOT EXISTS idx_chunks_source_section ON chunks(source, section);

CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
    source,
    section,
    content,
    content='chunks',
    content_rowid='id',
    tokenize='porter unicode61'
);

-- Triggers to keep FTS in sync
CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
    INSERT INTO chunks_fts(rowid, source, section, content)
    VALUES (new.id, new.source, new.section, new.content);
END;

CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
    INSERT INTO chunks_fts(chunks_fts, rowid, source, section, content)
    VALUES ('delete', old.id, old.source, old.section, old.content);
END;

CREATE TRIGGER IF NOT EXISTS chunks_au AFTER UPDATE ON chunks BEGIN
    INSERT INTO chunks_fts(chunks_fts, rowid, source, section, content)
    VALUES ('delete', old.id, old.source, old.section, old.content);
    INSERT INTO chunks_fts(rowid, source, section, content)
    VALUES (new.id, new.source, new.section, new.content);
END;

-- AST Code Symbols Table
CREATE TABLE IF NOT EXISTS code_symbols (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    symbol_name TEXT NOT NULL,
    file_path TEXT NOT NULL,
    start_line INTEGER NOT NULL,
    end_line INTEGER NOT NULL,
    lang TEXT NOT NULL DEFAULT 'bash',
    mtime INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_code_symbols_name ON code_symbols(symbol_name);
CREATE INDEX IF NOT EXISTS idx_code_symbols_file ON code_symbols(file_path);

-- Routing/evaluation trace (strict allowlist fields)
CREATE TABLE IF NOT EXISTS routing_eval_trace (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_boundary TEXT NOT NULL,
    recorded_at TEXT NOT NULL,
    infeasibility_class TEXT NOT NULL DEFAULT '',
    infeasibility_reason_code TEXT NOT NULL DEFAULT '',
    limitation_action TEXT NOT NULL DEFAULT '',
    tool_exposure_phase TEXT NOT NULL DEFAULT '',
    evaluator_mode TEXT NOT NULL DEFAULT 'normal',
    evaluator_failure_reason TEXT NOT NULL DEFAULT '',
    task_outcome_class TEXT NOT NULL DEFAULT '',
    redacted_diagnostic TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_routing_eval_trace_task
    ON routing_eval_trace(task_boundary, recorded_at);

-- Authoritative write-once terminal outcome per task boundary.
CREATE TABLE IF NOT EXISTS task_terminal_outcomes (
    task_boundary TEXT PRIMARY KEY,
    outcome_class TEXT NOT NULL,
    reason_code TEXT NOT NULL DEFAULT '',
    recorded_at TEXT NOT NULL
);

-- Evaluator diagnostic snapshots (redaction-safe, reproducible).
CREATE TABLE IF NOT EXISTS evaluator_diag_snapshots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_boundary TEXT NOT NULL,
    recorded_at TEXT NOT NULL,
    evaluator_mode TEXT NOT NULL DEFAULT 'normal',
    evaluator_failure_reason TEXT NOT NULL DEFAULT '',
    backend TEXT NOT NULL DEFAULT '',
    scenario TEXT NOT NULL DEFAULT '',
    token_budget INTEGER NOT NULL DEFAULT 0,
    output_length INTEGER NOT NULL DEFAULT 0,
    parse_mode TEXT NOT NULL DEFAULT '',
    grammar_mode TEXT NOT NULL DEFAULT '',
    selected_model TEXT NOT NULL DEFAULT '',
    grammar_schema_name TEXT NOT NULL DEFAULT '',
    prompt_char_count INTEGER NOT NULL DEFAULT 0,
    system_char_count INTEGER NOT NULL DEFAULT 0,
    estimated_token_pressure INTEGER NOT NULL DEFAULT 0,
    http_status INTEGER NOT NULL DEFAULT 0,
    received_sse_data INTEGER NOT NULL DEFAULT 0,
    received_non_sse_json_error INTEGER NOT NULL DEFAULT 0,
    curl_exit_code INTEGER NOT NULL DEFAULT 0,
    envelope_kind TEXT NOT NULL DEFAULT '',
    envelope_error_code TEXT NOT NULL DEFAULT '',
    envelope_error_message TEXT NOT NULL DEFAULT '',
    diagnostic_code TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_eval_diag_snapshots_task
    ON evaluator_diag_snapshots(task_boundary, recorded_at);

-- Grammar schema compatibility map used by runtime loop.
CREATE TABLE IF NOT EXISTS grammar_schema_compatibility (
    schema_name TEXT PRIMARY KEY,
    status TEXT NOT NULL DEFAULT 'unknown',
    stream_true_ok INTEGER NOT NULL DEFAULT 0,
    stream_false_ok INTEGER NOT NULL DEFAULT 0,
    repeated_runs INTEGER NOT NULL DEFAULT 0,
    diagnostic_code TEXT NOT NULL DEFAULT '',
    notes TEXT NOT NULL DEFAULT '',
    checked_at TEXT NOT NULL
);

-- Google Open Knowledge Graph (OKF) Codebase Index & BM25 Full-Text Search
CREATE TABLE IF NOT EXISTS okf_modules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    uri TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    path TEXT NOT NULL,
    subsystem TEXT NOT NULL,
    subsystem_name TEXT NOT NULL,
    language TEXT NOT NULL,
    description TEXT NOT NULL,
    exports TEXT NOT NULL,       -- JSON array of exported symbols
    depends_on TEXT NOT NULL,    -- JSON array of dependencies
    size_bytes INTEGER NOT NULL DEFAULT 0,
    indexed_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_okf_modules_path ON okf_modules(path);
CREATE INDEX IF NOT EXISTS idx_okf_modules_subsystem ON okf_modules(subsystem);

CREATE VIRTUAL TABLE IF NOT EXISTS okf_modules_fts USING fts5(
    name,
    path,
    subsystem_name,
    language,
    description,
    exports,
    depends_on,
    content='okf_modules',
    content_rowid='id',
    tokenize='porter unicode61'
);

CREATE TRIGGER IF NOT EXISTS okf_modules_ai AFTER INSERT ON okf_modules BEGIN
    INSERT INTO okf_modules_fts(rowid, name, path, subsystem_name, language, description, exports, depends_on)
    VALUES (new.id, new.name, new.path, new.subsystem_name, new.language, new.description, new.exports, new.depends_on);
END;

CREATE TRIGGER IF NOT EXISTS okf_modules_ad AFTER DELETE ON okf_modules BEGIN
    INSERT INTO okf_modules_fts(okf_modules_fts, rowid, name, path, subsystem_name, language, description, exports, depends_on)
    VALUES ('delete', old.id, old.name, old.path, old.subsystem_name, old.language, old.description, old.exports, old.depends_on);
END;

CREATE TRIGGER IF NOT EXISTS okf_modules_au AFTER UPDATE ON okf_modules BEGIN
    INSERT INTO okf_modules_fts(okf_modules_fts, rowid, name, path, subsystem_name, language, description, exports, depends_on)
    VALUES ('delete', old.id, old.name, old.path, old.subsystem_name, old.language, old.description, old.exports, old.depends_on);
    INSERT INTO okf_modules_fts(rowid, name, path, subsystem_name, language, description, exports, depends_on)
    VALUES (new.id, new.name, new.path, new.subsystem_name, new.language, new.description, new.exports, new.depends_on);
END;

-- OKF Directed Edge Index for Neighborhood & Personalized PageRank Traversal
CREATE TABLE IF NOT EXISTS okf_edges (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    src_uri TEXT NOT NULL,
    rel_type TEXT NOT NULL,
    dst_uri TEXT NOT NULL,
    weight REAL NOT NULL DEFAULT 1.0,
    UNIQUE(src_uri, rel_type, dst_uri)
);

CREATE INDEX IF NOT EXISTS idx_okf_edges_src ON okf_edges(src_uri);
CREATE INDEX IF NOT EXISTS idx_okf_edges_dst ON okf_edges(dst_uri);
CREATE INDEX IF NOT EXISTS idx_okf_edges_rel ON okf_edges(rel_type);

-- Per-tool empirical execution statistics for MoA / Contextual Bandit routing
CREATE TABLE IF NOT EXISTS tool_telemetry_stats (
    tool_name TEXT PRIMARY KEY,
    call_count INTEGER NOT NULL DEFAULT 0,
    success_count INTEGER NOT NULL DEFAULT 0,
    fail_count INTEGER NOT NULL DEFAULT 0,
    cache_hit_count INTEGER NOT NULL DEFAULT 0,
    ewma_latency_ms REAL NOT NULL DEFAULT 0.0,
    p95_latency_ms REAL NOT NULL DEFAULT 0.0,
    last_error_class TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL
);




-- ============================================================================
-- Layer 1: Persistent Scene Storage (specious-present substrate)
-- Governance: scenes are stored nouns; flow (linkages) is generated per turn
-- and NEVER persisted. 1:1 mapping with chunks via UNIQUE(chunk_id).
-- chunks + chunks_fts are untouched (no backfill, no rebuild, no rewrite).
-- ============================================================================

CREATE TABLE IF NOT EXISTS scenes (
    scene_id INTEGER PRIMARY KEY AUTOINCREMENT,
    chunk_id INTEGER NOT NULL UNIQUE REFERENCES chunks(id),
    ts TEXT NOT NULL,                       -- ISO timestamp (from chunk indexed_at)
    provenance_channel TEXT NOT NULL DEFAULT '',
    provenance_user TEXT NOT NULL DEFAULT '',
    provenance_tool TEXT NOT NULL DEFAULT '',
    provenance_cron TEXT NOT NULL DEFAULT '',
    provenance_session TEXT NOT NULL DEFAULT '',
    tier TEXT NOT NULL DEFAULT 'vivid' CHECK (tier IN ('vivid','fading','sediment')),
    salience REAL NOT NULL DEFAULT 0.5 CHECK (salience >= 0.0 AND salience <= 1.0),
    content TEXT NOT NULL,                  -- materialized snapshot of chunk content
    first_linked_ts TEXT,
    last_linked_ts TEXT,
    link_count INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_scenes_chunk ON scenes(chunk_id);
CREATE INDEX IF NOT EXISTS idx_scenes_tier_salience ON scenes(tier, salience DESC);
CREATE INDEX IF NOT EXISTS idx_scenes_ts ON scenes(ts);

CREATE TABLE IF NOT EXISTS scene_tags (
    scene_id INTEGER NOT NULL REFERENCES scenes(scene_id) ON DELETE CASCADE,
    tag TEXT NOT NULL,
    tag_class TEXT NOT NULL DEFAULT 'topic' CHECK (tag_class IN ('person','place','topic','decision_class','device','emotion')),
    PRIMARY KEY (scene_id, tag)
);

CREATE INDEX IF NOT EXISTS idx_scene_tags_tag ON scene_tags(tag);

CREATE TABLE IF NOT EXISTS scene_emb (
    scene_id INTEGER PRIMARY KEY REFERENCES scenes(scene_id) ON DELETE CASCADE,
    dim INTEGER NOT NULL,
    vec BLOB NOT NULL                       -- little-endian float32 array, dim * 4 bytes
);

-- Dedicated FTS5 index for scenes (external-content, same tokenizer as chunks_fts
-- so ranking behavior is consistent). Existing chunks_fts is never rebuilt.
CREATE VIRTUAL TABLE IF NOT EXISTS scenes_fts USING fts5(
    content,
    tier,
    content='scenes',
    content_rowid='scene_id',
    tokenize='porter unicode61'
);

CREATE TRIGGER IF NOT EXISTS scenes_ai AFTER INSERT ON scenes BEGIN
    INSERT INTO scenes_fts(rowid, content, tier)
    VALUES (new.scene_id, new.content, new.tier);
END;

CREATE TRIGGER IF NOT EXISTS scenes_ad AFTER DELETE ON scenes BEGIN
    INSERT INTO scenes_fts(scenes_fts, rowid, content, tier)
    VALUES ('delete', old.scene_id, old.content, old.tier);
END;

CREATE TRIGGER IF NOT EXISTS scenes_au AFTER UPDATE ON scenes BEGIN
    INSERT INTO scenes_fts(scenes_fts, rowid, content, tier)
    VALUES ('delete', old.scene_id, old.content, old.tier);
    INSERT INTO scenes_fts(rowid, content, tier)
    VALUES (new.scene_id, new.content, new.tier);
END;

-- Scene-layer migration bookkeeping (separate from SQLite user_version,
-- which other tooling may own).
CREATE TABLE IF NOT EXISTS scene_meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

INSERT OR IGNORE INTO scene_meta(key, value) VALUES ('schema_version', '1');
