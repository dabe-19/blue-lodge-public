// ── Instrument Rack: fabric view (control node + compute nodes) ─────────
// Renders /api/rack into #rackFabric. The control node (harness, web UI,
// cron, bridges) is shown separately from compute nodes because they are
// often different machines. DOM APIs only: no innerHTML, alert or confirm.
(function () {
  'use strict';

  const POLL_MS = 10000;
  let lastData = null;
  let lastFetch = 0;
  let inflight = false;

  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined && text !== null) e.textContent = String(text);
    return e;
  }

  function clear(node) {
    while (node.firstChild) node.removeChild(node.firstChild);
  }

  function pct(n, d) {
    if (!d || n === null || n === undefined) return null;
    return Math.max(0, Math.min(100, (100 * n) / d));
  }

  function meter(label, value, max, fmt) {
    const wrap = el('div', 'rk-meter');
    const head = el('div', 'rk-meter-head');
    head.appendChild(el('span', 'rk-meter-label', label));
    head.appendChild(el('span', 'rk-meter-val', fmt));
    wrap.appendChild(head);
    const bar = el('div', 'rk-bar');
    const fill = el('div', 'rk-bar-fill');
    const p = pct(value, max);
    fill.style.width = (p === null ? 0 : p).toFixed(1) + '%';
    if (p !== null && p >= 90) fill.classList.add('hot');
    else if (p !== null && p >= 75) fill.classList.add('warm');
    bar.appendChild(fill);
    wrap.appendChild(bar);
    return wrap;
  }

  function chip(text, kind, title) {
    const c = el('span', 'rk-chip' + (kind ? ' ' + kind : ''), text);
    if (title) c.title = title;
    return c;
  }

  function fmtUptime(s) {
    if (!s && s !== 0) return '—';
    const d = Math.floor(s / 86400);
    const h = Math.floor((s % 86400) / 3600);
    const m = Math.floor((s % 3600) / 60);
    return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m`;
  }

  function renderControl(c) {
    const card = el('div', 'rk-card rk-control');
    const head = el('div', 'rk-card-head');
    const title = el('div', 'rk-title-wrap');
    title.appendChild(el('span', 'rk-dot online'));
    title.appendChild(el('span', 'rk-name', c.hostname || 'control node'));
    head.appendChild(title);
    head.appendChild(chip('CONTROL NODE', 'accent', 'Runs the harness, web UI, cron and bridges'));
    card.appendChild(head);

    const sub = el('div', 'rk-sub', `${c.os || ''}${c.wsl ? ' · WSL2' : ''} · ${c.cpus || '?'} CPUs · up ${fmtUptime(c.uptime_s)}`);
    card.appendChild(sub);

    const grid = el('div', 'rk-meters');
    if (c.load && c.cpus) {
      grid.appendChild(meter('LOAD', c.load[0], c.cpus, `${c.load.join(' / ')}`));
    }
    const mem = c.memory_mb || {};
    if (mem.MemTotal) {
      const used = mem.MemTotal - (mem.MemAvailable || 0);
      grid.appendChild(meter('RAM', used, mem.MemTotal, `${(used / 1024).toFixed(1)} / ${(mem.MemTotal / 1024).toFixed(1)} GB`));
    }
    if (c.disk && c.disk.total_gb) {
      const used = c.disk.total_gb - c.disk.free_gb;
      grid.appendChild(meter('DISK', used, c.disk.total_gb, `${c.disk.free_gb} GB free`));
    }
    card.appendChild(grid);

    const gpus = c.gpus || [];
    const gpuBox = el('div', 'rk-gpus');
    if (!gpus.length) {
      gpuBox.appendChild(el('div', 'rk-muted', 'No local GPU detected on the control node.'));
    }
    gpus.forEach((g) => {
      const row = el('div', 'rk-gpu');
      const name = (g.name || 'GPU').replace('NVIDIA GeForce ', '');
      row.appendChild(meter(`GPU ${g.index} · ${name}`, g.vram_used_mb, g.vram_total_mb,
        `${((g.vram_used_mb || 0) / 1024).toFixed(1)}/${((g.vram_total_mb || 0) / 1024).toFixed(1)} GB · ${g.util_pct ?? '—'}% · ${g.temp_c ?? '—'}°C · ${g.power_w !== null && g.power_w !== undefined ? Math.round(g.power_w) : '—'} W`));
      gpuBox.appendChild(row);
    });
    card.appendChild(gpuBox);

    const svc = el('div', 'rk-chips');
    const s = c.services || {};
    const labels = {
      george_web: 'web', cron_loop: 'cron', event_bus: 'event bus', mcp_servers: 'MCP',
      discord_sessions: 'discord sessions', discord_active_runs: 'discord runs',
      llama_server: 'llama-server', ollama: 'ollama',
    };
    Object.keys(labels).forEach((k) => {
      if (!(k in s)) return;
      const n = s[k];
      svc.appendChild(chip(`${labels[k]} ${n}`, n > 0 ? 'ok' : 'off'));
    });
    (c.heartbeats || []).forEach((hb) => {
      svc.appendChild(chip(`♥ ${hb.name} ${hb.age_s < 120 ? hb.age_s + 's' : Math.floor(hb.age_s / 60) + 'm'}`,
        hb.stale ? 'bad' : 'ok', hb.stale ? 'Heartbeat is stale' : 'Heartbeat fresh'));
    });
    (c.containers || []).forEach((ct) => {
      svc.appendChild(chip(`▣ ${ct.name}`, /^Up/.test(ct.status || '') ? 'ok' : 'warn', ct.status));
    });
    card.appendChild(svc);
    return card;
  }

  const PATH_LABEL = { local: 'LOCAL', tunnel: 'SSH TUNNEL', lan: 'LAN', remote: 'REMOTE', invalid: 'INVALID' };

  function renderNode(n, tunnel) {
    const card = el('div', 'rk-card rk-node ' + (n.status || ''));
    const head = el('div', 'rk-card-head');
    const title = el('div', 'rk-title-wrap');
    title.appendChild(el('span', 'rk-dot ' + (n.status || '')));
    title.appendChild(el('span', 'rk-name', n.name || `tier${n.tier}`));
    head.appendChild(title);
    const badges = el('div', 'rk-badges');
    badges.appendChild(chip(`TIER ${n.tier}`, ''));
    if (n.path) badges.appendChild(chip(PATH_LABEL[n.path] || n.path.toUpperCase(), 'path-' + n.path, n.via || ''));
    badges.appendChild(chip((n.status || '').toUpperCase(),
      n.status === 'online' ? 'ok' : n.status === 'disabled' ? 'off' : 'bad'));
    head.appendChild(badges);
    card.appendChild(head);

    card.appendChild(el('div', 'rk-mono', n.url || ''));
    if (n.via && n.path !== 'local') card.appendChild(el('div', 'rk-sub', `via ${n.via}`));

    const facts = el('div', 'rk-facts');
    const fact = (k, v) => {
      if (v === null || v === undefined || v === '') return;
      const f = el('div', 'rk-fact');
      f.appendChild(el('span', 'rk-fact-k', k));
      f.appendChild(el('span', 'rk-fact-v', v));
      facts.appendChild(f);
    };
    fact('provider', n.provider);
    fact('model', n.live_model || n.configured_model || 'unset');
    if (n.live_model && n.configured_model && n.live_model !== n.configured_model) fact('configured', n.configured_model);
    fact('context', n.live_ctx || n.configured_ctx);
    fact('latency', n.latency_ms !== null && n.latency_ms !== undefined && n.online ? `${n.latency_ms} ms` : null);
    fact('hardware', n.hardware);
    if (n.swarm_mode) fact('swarm mode', `${n.swarm_mode} (${n.swarm_status || 'ONLINE'})`);
    if (n.fifo_channel) fact('fifo flow', `${n.fifo_channel}: ${n.fifo_credits ?? '?'}/${n.fifo_window ?? 1} credits${n.fifo_backpressure ? ' [PAUSED]' : ''}`);
    card.appendChild(facts);

    if (n.slots_total) {
      card.appendChild(meter('SLOTS', n.slots_busy || 0, n.slots_total, `${n.slots_busy || 0} / ${n.slots_total} busy`));
    }

    if (n.roles && n.roles.length) {
      const roles = el('div', 'rk-chips');
      n.roles.forEach((r) => roles.appendChild(chip(r, n.online ? 'role-on' : 'role-off')));
      card.appendChild(roles);
    }

    if (n.path === 'tunnel' && n.enabled && !n.online && tunnel) {
      const actions = el('div', 'rk-actions');
      const btn = el('button', 'tactile-btn rk-btn', 'RECONNECT TUNNEL');
      btn.id = `rackTunnelBtnTier${n.tier}`;
      btn.addEventListener('click', async () => {
        btn.disabled = true;
        btn.textContent = 'CONNECTING…';
        try {
          await fetch('/api/tunnel/connect', { method: 'POST' });
        } catch (e) { /* surfaced by the next refresh */ }
        btn.textContent = 'RECONNECT TUNNEL';
        btn.disabled = false;
        refresh(true);
      });
      actions.appendChild(btn);
      card.appendChild(actions);
    }
    return card;
  }

  function renderRoles(roles) {
    const box = el('div', 'rk-roles');
    if (!roles || !roles.length) {
      box.appendChild(el('div', 'rk-muted', 'No TIERn_ROLES configured in endpoints.conf.'));
      return box;
    }
    roles.forEach((r) => {
      const row = el('div', 'rk-role ' + (r.online.length ? 'covered' : 'uncovered'));
      row.appendChild(el('span', 'rk-role-name', r.role));
      row.appendChild(el('span', 'rk-role-nodes', r.online.length ? r.online.join(', ') : `no online node (${r.nodes.join(', ')})`));
      box.appendChild(row);
    });
    return box;
  }

  function renderFindings(findings) {
    const box = el('div', 'rk-findings');
    if (!findings || !findings.length) {
      box.appendChild(el('div', 'rk-finding ok', 'All enabled nodes reachable; no issues detected.'));
      return box;
    }
    const order = { error: 0, warn: 1, info: 2 };
    findings.slice().sort((a, b) => (order[a.level] ?? 3) - (order[b.level] ?? 3)).forEach((f) => {
      const row = el('div', 'rk-finding ' + (f.level || 'info'));
      row.appendChild(el('span', 'rk-finding-level', (f.level || 'info').toUpperCase()));
      row.appendChild(el('span', 'rk-finding-msg', f.msg || ''));
      box.appendChild(row);
    });
    return box;
  }

  function section(title, child, extra) {
    const s = el('div', 'rk-section');
    const h = el('div', 'section-header-row');
    h.appendChild(el('div', 'section-title', title));
    if (extra) h.appendChild(extra);
    s.appendChild(h);
    s.appendChild(child);
    return s;
  }

  function render(data) {
    const root = document.getElementById('rackFabric');
    if (!root) return;
    clear(root);
    if (!data || data.error) {
      root.appendChild(el('div', 'rk-finding error', `Rack probe unavailable: ${(data && data.error) || 'no data'}`));
      return;
    }

    const stamp = el('span', 'rk-stamp', data.stale ? 'stale snapshot' : 'live');
    stamp.id = 'rackStamp';
    const refreshBtn = el('button', 'tactile-btn rk-btn', 'REFRESH');
    refreshBtn.id = 'rackRefreshBtn';
    refreshBtn.addEventListener('click', () => refresh(true));
    const tools = el('div', 'rk-tools');
    tools.appendChild(stamp);
    tools.appendChild(refreshBtn);

    root.appendChild(section('FINDINGS', renderFindings(data.findings), tools));
    root.appendChild(section('CONTROL NODE', renderControl(data.control || {})));

    const grid = el('div', 'rk-grid');
    const nodes = data.nodes || [];
    if (!nodes.length) grid.appendChild(el('div', 'rk-muted', 'No compute nodes configured.'));
    nodes.forEach((n) => grid.appendChild(renderNode(n, data.tunnel)));
    const online = nodes.filter((n) => n.online).length;
    root.appendChild(section(`COMPUTE NODES · ${online}/${nodes.filter((n) => n.enabled).length} ONLINE`, grid));
    root.appendChild(section('ROLE COVERAGE', renderRoles(data.roles)));
  }

  function paneVisible() {
    const pane = document.getElementById('pane-rack');
    return !!pane && pane.classList.contains('active') && document.visibilityState !== 'hidden';
  }

  async function refresh(force) {
    if (inflight) return;
    if (!force && !paneVisible()) return;
    if (!force && Date.now() - lastFetch < POLL_MS - 500) return;
    inflight = true;
    lastFetch = Date.now();
    try {
      const resp = await fetch('/api/rack');
      const data = await resp.json().catch(() => ({ error: `HTTP ${resp.status}` }));
      lastData = resp.ok ? data : { error: data.error || `HTTP ${resp.status}` };
    } catch (e) {
      lastData = { error: 'network error' };
    } finally {
      inflight = false;
    }
    render(lastData);
  }

  function init() {
    if (!document.getElementById('rackFabric')) return;
    refresh(true);
    setInterval(() => refresh(false), 2000);
    document.querySelectorAll('.drawer-tab-btn[data-pane="rack"]').forEach((b) =>
      b.addEventListener('click', () => setTimeout(() => refresh(true), 50)));
    document.addEventListener('visibilitychange', () => refresh(false));
  }

  window.GeorgeRack = { refresh: () => refresh(true) };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
