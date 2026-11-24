// ============================================================================
// BLUE LODGE // Modular Drawer Shell, Lodge Guild App Store & Plugin Host
// Strictly XSS-safe DOM construction (zero innerHTML / outerHTML).
// ============================================================================
(function () {
  'use strict';

  const registeredPlugins = new Map();
  const loadedScripts = new Set();
  const loadedCss = new Set();
  let currentModules = [];
  let activeScopeFilter = 'all';
  let activeAgentName = 'Agent';

  async function resolveAgentName() {
    try {
      const resp = await fetch('/api/ecotype/status');
      if (resp.ok) {
        const d = await resp.json();
        const raw = String((d && (d.agent_name || d.node)) || '').trim();
        if (raw) {
          activeAgentName = raw.charAt(0).toUpperCase() + raw.slice(1);
        }
      }
    } catch (_) {}
    return activeAgentName;
  }

  const SCOPE_META = {
    all: { label: 'All Sources', badge: '' },
    builtin: { label: 'Built-in', badge: 'CORE BUILT-IN' },
    'public-github': { label: 'Public GitHub', badge: 'PUBLIC GITHUB' },
    'private-github': { label: 'Private GitHub', badge: 'PRIVATE GITHUB' },
    'local-gitea': { label: 'Local Gitea Only', badge: 'LOCAL GITEA' },
  };

  function el(tag, opts, children) {
    const node = document.createElement(tag);
    if (opts) {
      if (opts.id) node.id = opts.id;
      if (opts.className) node.className = opts.className;
      if (opts.text != null) node.textContent = String(opts.text);
      if (opts.type) node.type = opts.type;
      if (opts.placeholder) node.placeholder = opts.placeholder;
      if (opts.value != null) node.value = String(opts.value);
      if (opts.title) node.title = opts.title;
      if (opts.disabled) node.disabled = true;
      if (opts.style) {
        if (typeof opts.style === 'string') {
          node.setAttribute('style', opts.style);
        } else if (typeof opts.style === 'object') {
          Object.assign(node.style, opts.style);
        }
      }
      if (opts.attrs) {
        Object.entries(opts.attrs).forEach(([k, v]) => node.setAttribute(k, String(v)));
      }
      if (opts.on) {
        Object.entries(opts.on).forEach(([ev, fn]) => node.addEventListener(ev, fn));
      }
    }
    (children || []).forEach((c) => {
      if (c != null) node.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
    });
    return node;
  }

  // Core Heartwood Groups (collapses 17 legacy pills into 5 clean core tabs + Dynamic Modules)
  const CORE_GROUPS = [
    {
      id: 'core-rack',
      label: 'RACK & VITALS',
      defaultPane: 'rack',
      subtabs: [{ pane: 'rack', label: 'Instrument Rack' }],
    },
    {
      id: 'core-automation',
      label: 'AUTOMATION',
      defaultPane: 'cron',
      subtabs: [
        { pane: 'cron', label: 'Cron Builder & Sweeps' },
        { pane: 'reactor-wizard', label: 'Event Bus, Reactors & Webhooks' },
        { pane: 'loop-studio', label: 'Agentic Loops & Workflows' },
      ],
    },
    {
      id: 'core-store',
      label: 'APP STORE & WORKSHOP',
      defaultPane: 'guild-store',
      subtabs: [
        { pane: 'guild-store', label: 'Lodge Guild App Store' },
        { pane: 'ecotype-sync', label: 'Heartwood & Ecotype Sync' },
        { pane: 'mcp', label: 'MCP Hub & Servers' },
        { pane: 'api-catalog', label: 'Public API Catalog (1,959)' },
      ],
    },
    {
      id: 'core-chronicle',
      label: 'CHRONICLE & HISTORY',
      defaultPane: 'chronicle',
      subtabs: [
        { pane: 'chronicle', label: 'Chronicle, SQLite & OKF' },
        { pane: 'timemachine', label: 'Time-Machine Backups' },
        { pane: 'specsheet', label: 'Spec Sheet' },
      ],
    },
    {
      id: 'core-manual',
      label: 'MANUAL & COMMANDS',
      defaultPane: 'field-guide',
      subtabs: [
        { pane: 'field-guide', label: 'Field Manual & Guide' },
        { pane: 'commands', label: 'Slash Commands' },
      ],
    },
  ];

  // Built-in module sub-tab consolidations (Cardano DEX absorbs Dolos Explorer cleanly)
  const BUILTIN_SUBTABS = {
    'sovereign-dex': [
      { pane: 'dex-desk', label: 'Live DEX Desk & Backtests' },
      { pane: 'dolos-explorer', label: 'Dolos Chain & Node Ops' },
    ],
  };

  function activatePane(paneId) {
    document.querySelectorAll('.drawer-pane').forEach((p) => {
      p.classList.toggle('active', p.id === `pane-${paneId}`);
    });
    // Trigger existing lazy loaders if present on window
    try {
      if (paneId === 'dex-desk' && window.LodgeDesk && window.LodgeDesk.reload) window.LodgeDesk.reload();
      if (paneId === 'dolos-explorer' && window.LodgeExplorer && window.LodgeExplorer.reload) window.LodgeExplorer.reload();
      if (paneId === 'finance' && typeof window.loadFinanceData === 'function') window.loadFinanceData();
      if (paneId === 'trading-sim' && typeof window.loadTradingSimData === 'function') window.loadTradingSimData();
      if (paneId === 'sdr' && typeof window.loadSdrData === 'function') window.loadSdrData();
      if (paneId === 'tyler' && typeof window.loadTylerData === 'function') window.loadTylerData();
      if (paneId === 'google-cast' && typeof window.loadCastData === 'function') window.loadCastData();
      if (paneId === 'cron' && typeof window.loadCronData === 'function') window.loadCronData();
      if (paneId === 'reactor-wizard' && typeof window.loadReactorsData === 'function') window.loadReactorsData();
      if (paneId === 'mcp' && typeof window.loadMcpData === 'function') window.loadMcpData();
      if (paneId === 'research' && typeof window.loadResearchData === 'function') window.loadResearchData();
      if (paneId === 'guild-store') renderStoreGrid();
      if (paneId === 'ecotype-sync') loadEcotypeSyncPane();
      if (paneId === 'api-catalog') loadApiCatalog('');
      if (paneId === 'loop-studio' && window.LodgeLoopStudio && window.LodgeLoopStudio.reloadGlobal) {
        window.LodgeLoopStudio.reloadGlobal();
      }
    } catch (_) {
      // Non-fatal if a legacy loader is scoped inside app.js; dispatch click on hidden bridge button if present
    }
    const legacyBtn = document.querySelector(`#legacyDrawerTabsHidden button[data-pane="${CSS.escape(paneId)}"]`);
    if (legacyBtn) legacyBtn.click();
    // Re-assert target pane active after legacy handler
    document.querySelectorAll('.drawer-pane').forEach((p) => {
      p.classList.toggle('active', p.id === `pane-${paneId}`);
    });
  }

  function renderSubnav(subtabs, activePane) {
    const bar = document.getElementById('drawerSubnavBar');
    if (!bar) return;
    bar.replaceChildren();
    if (!subtabs || subtabs.length <= 1) {
      bar.classList.remove('visible');
      return;
    }
    bar.classList.add('visible');
    subtabs.forEach((st) => {
      const btn = el('button', {
        className: 'drawer-subtab-btn' + (st.pane === activePane ? ' active' : ''),
        text: st.label,
        on: {
          click: () => {
            bar.querySelectorAll('.drawer-subtab-btn').forEach((b) => b.classList.remove('active'));
            btn.classList.add('active');
            activatePane(st.pane);
          },
        },
      });
      bar.appendChild(btn);
    });
  }

  function clearActiveNav() {
    document.querySelectorAll('#coreNavRow .drawer-tab-btn, #moduleNavRow .mod-pill-btn').forEach((b) => {
      b.classList.remove('active');
    });
  }

  function buildCoreNav() {
    const row = document.getElementById('coreNavRow');
    if (!row) return;
    row.replaceChildren();
    row.appendChild(el('span', { className: 'drawer-nav-label', text: 'HEARTWOOD' }));
    CORE_GROUPS.forEach((g, idx) => {
      const btn = el('button', {
        className: 'drawer-tab-btn' + (idx === 0 ? ' active' : ''),
        text: g.label,
        attrs: { 'data-core-group': g.id },
        on: {
          click: () => {
            clearActiveNav();
            btn.classList.add('active');
            renderSubnav(g.subtabs, g.defaultPane);
            activatePane(g.defaultPane);
          },
        },
      });
      row.appendChild(btn);
    });
  }

  async function mountExternalModulePane(mod) {
    const paneId = `mod-${mod.id}`;
    let pane = document.getElementById(`pane-${paneId}`);
    const anchor = document.getElementById('pane-guild-store');
    if (!pane && anchor && anchor.parentNode) {
      pane = el('div', { id: `pane-${paneId}`, className: 'drawer-pane external-module-pane' });
      const loopsBtn = el('button', {
        className: 'mod-fullscreen-btn',
        text: `⚙ WORKFLOWS${mod.workflows_count ? ` (${mod.workflows_count})` : ''}`,
        title: `Inspect, customize, or create ALP v1 agentic loops for ${mod.name}`,
        on: {
          click: () => {
            if (window.LodgeLoopStudio && window.LodgeLoopStudio.openModal) {
              window.LodgeLoopStudio.openModal({
                owner: mod.id,
                title: `${mod.name} — Workflows & Agentic Loops (ALP v1)`,
              });
            }
          },
        },
      });
      const fsBtn = el('button', {
        className: 'mod-fullscreen-btn',
        text: '⤢ FULLSCREEN',
        on: {
          click: () => {
            const drawer = document.getElementById('toolCribDrawer');
            if (!drawer) return;
            const on = drawer.classList.toggle('module-fullscreen');
            fsBtn.classList.toggle('active', on);
            fsBtn.textContent = on ? '⤡ EXIT FULLSCREEN' : '⤢ FULLSCREEN';
            setTimeout(() => window.dispatchEvent(new Event('resize')), 120);
          },
        },
      });
      const topBar = el('div', { className: 'mod-pane-bar' }, [
        el('div', { className: 'mod-pane-bar-title', text: `${mod.name} · v${mod.version || '1.0'}` }),
        el('div', { style: 'display:flex;gap:8px;align-items:center;' }, [loopsBtn, fsBtn]),
      ]);
      const host = el('div', { id: `mod-host-${mod.id}`, className: 'dynamic-module-host' });
      pane.appendChild(topBar);
      pane.appendChild(host);
      anchor.parentNode.appendChild(pane);
    }
    activatePane(paneId);

    const host = document.getElementById(`mod-host-${mod.id}`);
    if (!host) return;

    const ui = mod.ui || {};
    const verTag = encodeURIComponent(mod.version || '1');
    if (ui.css) {
      const cssHref = `/api/modules/${encodeURIComponent(mod.id)}/assets/${ui.css.replace(/^ui\//, '')}?v=${verTag}`;
      if (!loadedCss.has(cssHref)) {
        const link = el('link', { attrs: { rel: 'stylesheet', href: cssHref } });
        document.head.appendChild(link);
        loadedCss.add(cssHref);
      }
    }

    if (ui.js) {
      const jsSrc = `/api/modules/${encodeURIComponent(mod.id)}/assets/${ui.js.replace(/^ui\//, '')}?v=${verTag}`;
      if (!loadedScripts.has(jsSrc)) {
        host.replaceChildren(el('div', { className: 'guild-card-meta', text: `Loading ${mod.name} module UI...` }));
        await new Promise((resolve) => {
          const s = document.createElement('script');
          s.src = jsSrc;
          s.onload = () => { loadedScripts.add(jsSrc); resolve(); };
          s.onerror = () => resolve();
          document.body.appendChild(s);
        });
      }
      const plugin = registeredPlugins.get(mod.id);
      if (plugin && typeof plugin.mount === 'function') {
        host.replaceChildren();
        plugin.mount(host, {
          module: mod,
          agentName: activeAgentName,
          getAgentName: () => activeAgentName,
          el,
          action: async (actionName, payload) => {
            const resp = await fetch(`/api/modules/${encodeURIComponent(mod.id)}/action/${encodeURIComponent(actionName)}`, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify(payload || {}),
            });
            const txt = await resp.text();
            try { return JSON.parse(txt); } catch (_) {
              return { status: 'error', http_status: resp.status, message: txt || `HTTP ${resp.status}` };
            }
          },
          proxyGet: async (subpath, qs) => {
            const q = qs ? `?qs=${encodeURIComponent(qs)}` : '';
            const resp = await fetch(`/api/modules/${encodeURIComponent(mod.id)}/proxy/${subpath.replace(/^\//, '')}${q}`);
            const txt = await resp.text();
            try { return JSON.parse(txt); } catch (_) {
              return { status: 'error', http_status: resp.status, detail: txt || `HTTP ${resp.status}` };
            }
          },
          proxyPost: async (subpath, payload) => {
            const resp = await fetch(`/api/modules/${encodeURIComponent(mod.id)}/proxy/${subpath.replace(/^\//, '')}`, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify(payload || {}),
            });
            const txt = await resp.text();
            try {
              const parsed = JSON.parse(txt);
              if (!resp.ok && parsed && typeof parsed === 'object' && !parsed.status) {
                parsed.status = 'error';
                parsed.http_status = resp.status;
              }
              return parsed;
            } catch (_) {
              return { status: 'error', http_status: resp.status, detail: txt || `HTTP ${resp.status}` };
            }
          },
          proxyFormData: async (subpath, formData, extraHeaders) => {
            const resp = await fetch(`/api/modules/${encodeURIComponent(mod.id)}/proxy/${subpath.replace(/^\//, '')}`, {
              method: 'POST',
              headers: extraHeaders || {},
              body: formData,
            });
            return resp.json();
          },
          listTasks: async () => {
            const resp = await fetch(`/api/modules/${encodeURIComponent(mod.id)}/tasks`);
            return resp.json();
          },
          getTaskResult: async (taskId) => {
            const resp = await fetch(`/api/modules/${encodeURIComponent(mod.id)}/task/${encodeURIComponent(taskId)}/result`);
            return resp.json();
          },
          listLoops: async () => {
            const resp = await fetch(`/api/loops/${encodeURIComponent(mod.id)}`);
            return resp.json();
          },
          getLoop: async (loopId) => {
            const resp = await fetch(`/api/loops/${encodeURIComponent(mod.id)}/${encodeURIComponent(loopId)}`);
            return resp.json();
          },
          saveLoop: async (loopId, loopDef, target) => {
            const resp = await fetch(`/api/loops/${encodeURIComponent(mod.id)}/${encodeURIComponent(loopId)}`, {
              method: 'PUT',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ target: target || 'override', loop: loopDef }),
            });
            return resp.json();
          },
          openLoopStudio: (loopId) => {
            if (window.LodgeLoopStudio && window.LodgeLoopStudio.openModal) {
              window.LodgeLoopStudio.openModal({
                owner: mod.id,
                loopId: loopId || null,
                title: `${mod.name} — Workflows & Agentic Loops (ALP v1)`,
              });
            }
          },
          launchTask: async (workflow, payload, opts) => {
            const options = opts || {};
            const streamContainer = options.streamContainer || null;
            const onPhase = typeof options.onPhase === 'function' ? options.onPhase : null;
            const onResult = typeof options.onResult === 'function' ? options.onResult : null;
            const onComplete = typeof options.onComplete === 'function' ? options.onComplete : null;
            const onError = typeof options.onError === 'function' ? options.onError : null;

            const explicitTurns = (payload && payload.max_turns) || options.maxTurns || null;
            const body = {
              workflow: String(workflow || ''),
              params: (payload && payload.params) || payload || {},
              images: Array.isArray(payload && payload.images) ? payload.images : [],
            };
            if (explicitTurns) body.max_turns = explicitTurns;

            const resp = await fetch(`/api/modules/${encodeURIComponent(mod.id)}/task/launch`, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify(body),
            });
            const data = await resp.json().catch(() => ({ status: 'error', message: `HTTP ${resp.status}` }));
            if (!resp.ok || data.status !== 'ok' || !data.task_id) {
              const errMsg = data.message || `Failed to launch ${workflow}`;
              if (onError) onError(errMsg);
              throw new Error(errMsg);
            }

            const taskId = data.task_id;
            let es = null;
            let pollTimer = null;
            let finished = false;
            let deliveredPreview = false;
            let phaseBadge = null;

            const cleanup = () => {
              if (es) { try { es.close(); } catch (_) {} es = null; }
              if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
            };

            const fetchFinalResult = async () => {
              if (finished) return;
              try {
                const rr = await fetch(`/api/modules/${encodeURIComponent(mod.id)}/task/${encodeURIComponent(taskId)}/result`);
                const rd = await rr.json();
                if (rd && rd.phase && phaseBadge) {
                  phaseBadge.textContent = rd.phase;
                }
                if (rd && rd.result && !deliveredPreview && !rd.done) {
                  deliveredPreview = true;
                  if (onResult) onResult(rd);
                }
                if (rd && rd.done) {
                  finished = true;
                  cleanup();
                  if (phaseBadge) {
                    phaseBadge.textContent = rd.phase || 'Completed';
                    phaseBadge.classList.remove('running');
                    phaseBadge.classList.add(String(rd.phase || '').toLowerCase().includes('fail') ? 'failed' : 'done');
                  }
                  if (onComplete) onComplete(rd);
                }
              } catch (_) {}
            };

            if (streamContainer) {
              if (streamContainer._activeTaskCleanup) {
                try { streamContainer._activeTaskCleanup(); } catch (_) {}
              }
              streamContainer._activeTaskCleanup = cleanup;
              streamContainer.replaceChildren();

              phaseBadge = el('span', { className: 'mod-task-phase running', text: `Starting ${workflow}...` });
              const pauseBtn = el('button', {
                className: 'guild-btn',
                text: 'PAUSE',
                on: {
                  click: async () => {
                    const paused = pauseBtn.dataset.paused === '1';
                    const verb = paused ? 'resume' : 'pause';
                    await fetch(`/api/task/${encodeURIComponent(taskId)}/${verb}`, { method: 'POST' }).catch(() => {});
                    pauseBtn.dataset.paused = paused ? '0' : '1';
                    pauseBtn.textContent = paused ? 'PAUSE' : 'RESUME';
                  },
                },
              });
              const abortBtn = el('button', {
                className: 'guild-btn danger',
                text: 'ABORT',
                on: {
                  click: async () => {
                    await fetch(`/api/task/${encodeURIComponent(taskId)}/abort`, { method: 'POST' }).catch(() => {});
                    if (phaseBadge) {
                      phaseBadge.textContent = 'Aborted';
                      phaseBadge.classList.remove('running');
                      phaseBadge.classList.add('failed');
                    }
                    cleanup();
                  },
                },
              });
              const bayBtn = el('button', {
                className: 'guild-btn primary',
                text: 'VIEW IN TASK BAY',
                on: {
                  click: () => {
                    if (typeof window.focusAutonomicTask === 'function') {
                      window.focusAutonomicTask(taskId);
                    }
                  },
                },
              });

              const bar = el('div', { className: 'mod-task-bar' }, [
                el('div', { className: 'mod-task-meta' }, [
                  el('span', { className: 'mod-task-id', text: taskId }),
                  phaseBadge,
                ]),
                el('div', { className: 'mod-task-actions' }, [pauseBtn, abortBtn, bayBtn]),
              ]);
              const streamEl = el('div', { className: 'mod-task-stream' });
              const shell = el('div', { className: 'mod-task-shell' }, [bar, streamEl]);
              streamContainer.appendChild(shell);

              if (window.LodgeTranscriptConsole) {
                window.LodgeTranscriptConsole.renderBatch(streamEl, `── [MONITORED TASK: ${taskId}] ──\nWorkflow: ${mod.id}/${workflow}\n`);
              } else {
                streamEl.textContent = `Monitoring task ${taskId}...`;
              }

              try {
                es = new EventSource(`/api/stream/task/${encodeURIComponent(taskId)}`);
                es.addEventListener('log', (ev) => {
                  if (ev.data == null) return;
                  if (window.LodgeTranscriptConsole) {
                    window.LodgeTranscriptConsole.appendChunk(streamEl, ev.data);
                  } else {
                    streamEl.appendChild(el('div', { text: ev.data }));
                  }
                });
                es.addEventListener('phase', (ev) => {
                  if (ev.data) {
                    if (phaseBadge) phaseBadge.textContent = ev.data;
                    if (onPhase) onPhase(ev.data);
                  }
                });
                es.addEventListener('done', () => {
                  fetchFinalResult();
                });
                es.onerror = () => {
                  // Keep fallback polling active if SSE briefly drops
                };
              } catch (_) {}
            }

            pollTimer = setInterval(fetchFinalResult, 2500);
            return { task_id: taskId, sandbox_dir: data.sandbox_dir, stop: cleanup };
          },
        });
        return;
      }
    }

    // Declarative fallback view when no custom JS bundle is registered
    host.replaceChildren(
      el('div', { className: 'guild-card' }, [
        el('div', { className: 'guild-card-title', text: `${mod.name} (${mod.version})` }),
        el('div', { className: 'guild-card-desc', text: mod.tagline || 'Module active.' }),
      ])
    );
  }

  function renderModuleNavBar() {
    const row = document.getElementById('moduleNavRow');
    if (!row) return;
    row.replaceChildren();
    row.appendChild(el('span', { className: 'drawer-nav-label', text: 'MODULES' }));
    const enabled = currentModules.filter((m) => m.enabled);
    if (enabled.length === 0) {
      row.appendChild(el('span', { className: 'guild-card-meta', text: 'No modules enabled — open App Store to install or toggle.' }));
      return;
    }
    enabled.forEach((m) => {
      const isExt = m.source !== 'builtin';
      const btn = el('button', {
        className: 'mod-pill-btn' + (isExt ? ' mod-ext' : ''),
        text: m.name,
        title: m.tagline || m.id,
        attrs: { 'data-mod-id': m.id },
        on: {
          click: () => {
            clearActiveNav();
            btn.classList.add('active');
            if (isExt) {
              renderSubnav([], null);
              mountExternalModulePane(m);
            } else {
              const subs = BUILTIN_SUBTABS[m.id];
              if (subs) {
                renderSubnav(subs, subs[0].pane);
                activatePane(subs[0].pane);
              } else {
                renderSubnav([], null);
                activatePane(m.pane || m.id);
              }
            }
          },
        },
      });
      row.appendChild(btn);
    });
  }

  function setStoreStatus(msg) {
    const s = document.getElementById('guildStoreStatus');
    if (s) s.textContent = msg;
  }

  async function mutateModule(modId, verb, body) {
    setStoreStatus(`Running ${verb} on ${modId}...`);
    try {
      const resp = await fetch(`/api/modules/${encodeURIComponent(modId)}/${verb}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: body ? JSON.stringify(body) : '{}',
      });
      const data = await resp.json();
      if (resp.ok && data.status === 'ok') {
        if (verb === 'update') {
          const paneEl = document.getElementById(`pane-mod-${modId}`);
          if (paneEl) paneEl.remove();
          registeredPlugins.delete(modId);
        }
        setStoreStatus(`${verb.toUpperCase()} succeeded for ${modId}.`);
        await refreshModules();
      } else {
        setStoreStatus(`Error (${verb} ${modId}): ${data.message || JSON.stringify(data)}`);
      }
    } catch (e) {
      setStoreStatus(`Request failed: ${e.message}`);
    }
  }

  function renderScopeFilterBar() {
    const bar = document.getElementById('guildScopeFilterBar');
    if (!bar) return;
    bar.replaceChildren();
    ['all', 'builtin', 'public-github', 'private-github', 'local-gitea'].forEach((scopeKey) => {
      const count = scopeKey === 'all'
        ? currentModules.length
        : currentModules.filter((m) => (m.origin_scope || (m.source === 'builtin' ? 'builtin' : 'public-github')) === scopeKey).length;
      const btn = el('button', {
        className: 'guild-btn' + (activeScopeFilter === scopeKey ? ' primary' : ''),
        text: `${SCOPE_META[scopeKey].label} (${count})`,
        on: {
          click: () => {
            activeScopeFilter = scopeKey;
            renderScopeFilterBar();
            renderStoreGrid();
          },
        },
      });
      bar.appendChild(btn);
    });
    const pendingUpdates = currentModules.filter((m) => m.installed && m.update_available && m.source !== 'builtin');
    if (pendingUpdates.length > 0) {
      bar.appendChild(el('button', {
        className: 'guild-btn primary',
        style: 'margin-left:auto;background:rgba(245,158,11,0.2);border-color:#f59e0b;color:#fde68a;',
        text: `UPDATE ALL (${pendingUpdates.length})`,
        on: {
          click: async () => {
            setStoreStatus(`Updating ${pendingUpdates.length} module(s)...`);
            const resp = await fetch('/api/modules/update-all', { method: 'POST' });
            const d = await resp.json().catch(() => ({}));
            if (resp.ok && d.status === 'ok') {
              pendingUpdates.forEach((u) => {
                const p = document.getElementById(`pane-mod-${u.id}`);
                if (p) p.remove();
                registeredPlugins.delete(u.id);
              });
              setStoreStatus(`Updated ${pendingUpdates.length} module(s) cleanly.`);
              await refreshModules();
            } else {
              setStoreStatus(`Update-all error: ${d.message || 'failed'}`);
            }
          },
        },
      }));
    }
  }

  function renderStoreGrid() {
    const grid = document.getElementById('guildStoreGrid');
    if (!grid) return;
    renderScopeFilterBar();
    grid.replaceChildren();
    const filtered = currentModules.filter((m) => {
      if (activeScopeFilter === 'all') return true;
      const sc = m.origin_scope || (m.source === 'builtin' ? 'builtin' : 'public-github');
      return sc === activeScopeFilter;
    });
    if (!filtered.length) {
      grid.appendChild(el('div', {
        className: 'guild-card-meta',
        text: activeScopeFilter === 'local-gitea'
          ? 'No local-only Gitea mod-* repos detected yet. Create a mod-<name> repo in your local Gitea forge to host personal modules privately.'
          : 'No modules in this scope yet.',
      }));
      return;
    }
    filtered.forEach((m) => {
      const sc = m.origin_scope || (m.source === 'builtin' ? 'builtin' : 'public-github');
      const scLabel = (SCOPE_META[sc] && SCOPE_META[sc].badge) || sc.toUpperCase();
      const badges = [
        el('span', { className: 'guild-badge ' + (m.enabled ? 'on' : 'off'), text: m.enabled ? 'ENABLED' : (m.installed ? 'DISABLED' : 'AVAILABLE') }),
        el('span', { className: 'guild-badge', text: scLabel }),
        el('span', { className: 'guild-badge', text: m.category || 'module' }),
        el('span', { className: 'guild-badge', text: m.venv_mode || m.source }),
      ];
      if (m.update_available && m.catalog_version) {
        badges.unshift(el('span', {
          className: 'guild-badge',
          style: 'background: rgba(245, 158, 11, 0.18); border-color: rgba(245, 158, 11, 0.55); color: #fcd34d;',
          text: `UPDATE v${m.version} → v${m.catalog_version}`,
        }));
      }
      (m.hardware_badges || []).forEach((hb) => {
        badges.push(el('span', { className: 'guild-badge', text: hb }));
      });

      const footer = [];
      if (m.installed && m.update_available && m.source !== 'builtin') {
        footer.push(el('button', {
          className: 'guild-btn primary',
          style: 'background: rgba(245, 158, 11, 0.2); border-color: #f59e0b; color: #fde68a;',
          text: `UPDATE TO v${m.catalog_version || 'latest'}`,
          on: { click: () => mutateModule(m.id, 'update') },
        }));
      }
      if (!m.installed) {
        footer.push(el('button', {
          className: 'guild-btn primary',
          text: 'INSTALL',
          on: { click: () => mutateModule(m.id, 'install', {}) },
        }));
      } else if (m.enabled) {
        footer.push(el('button', {
          className: 'guild-btn',
          text: 'OPEN',
          on: {
            click: () => {
              const targetPill = Array.from(document.querySelectorAll('#moduleNavRow .mod-pill-btn'))
                .find((b) => b.textContent === m.name);
              if (targetPill) targetPill.click();
            },
          },
        }));
        footer.push(el('button', {
          className: 'guild-btn danger',
          text: 'DISABLE',
          on: { click: () => mutateModule(m.id, 'disable') },
        }));
      } else {
        footer.push(el('button', {
          className: 'guild-btn primary',
          text: 'ENABLE',
          on: { click: () => mutateModule(m.id, 'enable') },
        }));
        if (m.source !== 'builtin') {
          footer.push(el('button', {
            className: 'guild-btn danger',
            text: 'UNINSTALL',
            on: { click: () => mutateModule(m.id, 'uninstall') },
          }));
        }
      }

      const card = el('div', { className: 'guild-card' + (m.enabled ? ' enabled' : '') }, [
        el('div', { className: 'guild-card-top' }, [
          el('div', {}, [
            el('div', { className: 'guild-card-title', text: m.name }),
            el('div', { className: 'guild-card-meta', text: `${m.id} · v${m.version} · ${m.source}` }),
          ]),
        ]),
        el('div', { className: 'guild-card-desc', text: m.tagline || '' }),
        el('div', { className: 'guild-badges' }, badges),
        el('div', { className: 'guild-card-footer' }, footer),
      ]);
      grid.appendChild(card);
    });
  }

  async function loadApiCatalog(query) {
    const list = document.getElementById('apiCatalogResults');
    if (!list) return;
    list.replaceChildren(el('div', { className: 'guild-card-meta', text: 'Searching Public API Catalog...' }));
    try {
      const resp = await fetch(`/api/react/api-search?q=${encodeURIComponent(query || 'weather')}&limit=30`);
      const data = await resp.json();
      const rows = data.results || data.apis || [];
      list.replaceChildren();
      if (!rows.length) {
        list.appendChild(el('div', { className: 'guild-card-meta', text: 'No matching APIs found.' }));
        return;
      }
      rows.forEach((r) => {
        const card = el('div', { className: 'guild-card' }, [
          el('div', { className: 'guild-card-title', text: r.name || r.API || 'API' }),
          el('div', { className: 'guild-card-meta', text: `${r.category || ''} · Auth: ${r.auth || 'None'} · HTTPS: ${r.https ? 'Yes' : 'No'}` }),
          el('div', { className: 'guild-card-desc', text: r.description || '' }),
          el('div', { className: 'guild-card-meta', text: r.url || r.link || '' }),
        ]);
        list.appendChild(card);
      });
    } catch (e) {
      list.replaceChildren(el('div', { className: 'guild-card-meta', text: `API catalog query error: ${e.message}` }));
    }
  }

  // ── User-Customizable Header Quick-Pin Bar ─────────────────────────
  const HEADER_PINS_LS_ITEM = 'lodge.headerPins.v1';
  const DEFAULT_HEADER_PINS = ['wb:models', 'mod:sovereign-dex'];
  const MAX_HEADER_PINS = 6;

  function loadHeaderPins() {
    try {
      const raw = window.localStorage.getItem(HEADER_PINS_LS_ITEM);
      if (raw) {
        const arr = JSON.parse(raw);
        if (Array.isArray(arr)) {
          return arr.filter((x) => typeof x === 'string' && x.length > 0).slice(0, MAX_HEADER_PINS);
        }
      }
    } catch (_) {}
    return DEFAULT_HEADER_PINS.slice();
  }

  function saveHeaderPins(pins) {
    try {
      window.localStorage.setItem(HEADER_PINS_LS_ITEM, JSON.stringify(pins.slice(0, MAX_HEADER_PINS)));
    } catch (_) {}
  }

  function openDrawerShell() {
    const drawer = document.getElementById('toolCribDrawer');
    if (drawer) {
      drawer.classList.add('open');
      document.body.classList.add('drawer-open');
    }
  }

  function openCoreGroup(groupId, targetPane) {
    const g = CORE_GROUPS.find((x) => x.id === groupId);
    if (!g) return;
    openDrawerShell();
    clearActiveNav();
    const navBtn = document.querySelector(`#coreNavRow button[data-core-group="${CSS.escape(groupId)}"]`);
    if (navBtn) navBtn.classList.add('active');
    const pane = targetPane || g.defaultPane;
    renderSubnav(g.subtabs, pane);
    activatePane(pane);
  }

  function openModuleById(modId, subPane) {
    const mod = currentModules.find((m) => m.id === modId && m.enabled);
    if (!mod) return false;
    openDrawerShell();
    clearActiveNav();
    const navBtn = document.querySelector(`#moduleNavRow button[data-mod-id="${CSS.escape(modId)}"]`);
    if (navBtn) navBtn.classList.add('active');
    const isExt = mod.source !== 'builtin';
    if (isExt) {
      renderSubnav([], null);
      mountExternalModulePane(mod);
    } else {
      const subs = BUILTIN_SUBTABS[mod.id];
      if (subs) {
        const chosen = subPane && subs.some((s) => s.pane === subPane) ? subPane : subs[0].pane;
        renderSubnav(subs, chosen);
        activatePane(chosen);
      } else {
        renderSubnav([], null);
        activatePane(mod.pane || mod.id);
      }
    }
    return true;
  }

  function getAvailablePinItems() {
    const items = [
      { id: 'wb:models', label: 'Models', group: 'Workbenches', title: 'Open Model Workbench (GGUF library, serving, tuning)' },
      { id: 'wb:forge', label: 'Forge', group: 'Workbenches', title: 'Open Sovereign Training Forge & Colab Studio' },
    ];
    const enabled = currentModules.filter((m) => m.enabled);
    enabled.forEach((m) => {
      items.push({
        id: `mod:${m.id}`,
        label: m.name,
        group: m.source === 'builtin' ? 'Built-in Modules' : 'Installed Modules',
        title: m.tagline || `Open ${m.name}`,
      });
      if (m.id === 'sovereign-dex') {
        items.push({
          id: 'pane:dolos-explorer',
          label: 'Dolos',
          group: 'Built-in Modules',
          title: 'Open Dolos Sovereign Block Explorer & L1 Crawler',
        });
      }
    });
    CORE_GROUPS.forEach((g) => {
      items.push({
        id: `core:${g.id}`,
        label: g.label.split(' ')[0].charAt(0) + g.label.split(' ')[0].slice(1).toLowerCase(),
        group: 'Core Drawer',
        title: `Open ${g.label}`,
      });
    });
    items.push({
      id: 'pane:ecotype-sync',
      label: 'Ecotype Sync',
      group: 'Core Drawer',
      title: 'Open Heartwood & Ecotype Sync, Diff & Promotion',
    });
    return items;
  }

  function launchPinItem(pinId) {
    if (pinId === 'wb:models') {
      if (typeof window.LodgeOpenModels === 'function') window.LodgeOpenModels();
      return;
    }
    if (pinId === 'wb:forge') {
      if (typeof window.LodgeOpenForge === 'function') window.LodgeOpenForge();
      return;
    }
    if (pinId === 'pane:dolos-explorer') {
      openModuleById('sovereign-dex', 'dolos-explorer');
      return;
    }
    if (pinId === 'pane:ecotype-sync') {
      openCoreGroup('core-store', 'ecotype-sync');
      return;
    }
    if (pinId.startsWith('mod:')) {
      openModuleById(pinId.slice(4));
      return;
    }
    if (pinId.startsWith('core:')) {
      openCoreGroup(pinId.slice(5));
    }
  }

  function renderHeaderQuickPins() {
    const host = document.getElementById('headerQuickPins');
    if (!host) return;
    const available = getAvailablePinItems();
    const byId = new Map(available.map((x) => [x.id, x]));
    const pinnedIds = loadHeaderPins().filter((id) => byId.has(id));
    host.replaceChildren();
    pinnedIds.forEach((id) => {
      const item = byId.get(id);
      if (!item) return;
      host.appendChild(el('button', {
        type: 'button',
        className: 'hdr-pill-btn',
        text: item.label,
        title: item.title,
        attrs: { 'data-pin-id': item.id },
        on: { click: () => launchPinItem(item.id) },
      }));
    });
  }

  function renderPinsPopover() {
    const list = document.getElementById('headerPinsList');
    if (!list) return;
    const available = getAvailablePinItems();
    const pinnedSet = new Set(loadHeaderPins());
    list.replaceChildren();

    const groups = [];
    const seen = new Map();
    available.forEach((item) => {
      if (!seen.has(item.group)) {
        const arr = [];
        seen.set(item.group, arr);
        groups.push([item.group, arr]);
      }
      seen.get(item.group).push(item);
    });

    groups.forEach(([groupName, groupItems]) => {
      list.appendChild(el('div', { className: 'hdr-pin-group-title', text: groupName }));
      groupItems.forEach((item) => {
        const isPinned = pinnedSet.has(item.id);
        const row = el('button', {
          type: 'button',
          className: 'hdr-pin-item' + (isPinned ? ' pinned' : ''),
          title: item.title,
          on: {
            click: () => {
              const cur = loadHeaderPins();
              const idx = cur.indexOf(item.id);
              if (idx >= 0) {
                cur.splice(idx, 1);
              } else {
                if (cur.length >= MAX_HEADER_PINS) cur.shift();
                cur.push(item.id);
              }
              saveHeaderPins(cur);
              renderHeaderQuickPins();
              renderPinsPopover();
            },
          },
        }, [
          el('span', { text: item.label }),
          el('span', { className: 'hdr-pin-item-meta', text: isPinned ? 'PINNED ✓' : '+ PIN' }),
        ]);
        list.appendChild(row);
      });
    });
  }

  function initHeaderPinPicker() {
    const toggleBtn = document.getElementById('headerPinsToggleBtn');
    const popover = document.getElementById('headerPinsPopover');
    const resetBtn = document.getElementById('headerPinsResetBtn');
    if (!toggleBtn || !popover || toggleBtn.dataset.boundPins) return;
    toggleBtn.dataset.boundPins = '1';

    function setOpen(open) {
      popover.hidden = !open;
      toggleBtn.setAttribute('aria-expanded', open ? 'true' : 'false');
      if (open) renderPinsPopover();
    }

    toggleBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      const gpuPop = document.getElementById('hdrGpuPopover');
      const gpuBtn = document.getElementById('hdrGpuTrigger');
      if (gpuPop) gpuPop.hidden = true;
      if (gpuBtn) gpuBtn.setAttribute('aria-expanded', 'false');
      setOpen(popover.hidden);
    });
    if (resetBtn) {
      resetBtn.addEventListener('click', () => {
        saveHeaderPins(DEFAULT_HEADER_PINS);
        renderHeaderQuickPins();
        renderPinsPopover();
      });
    }
    document.addEventListener('click', (e) => {
      if (!popover.hidden && !popover.contains(e.target) && !toggleBtn.contains(e.target)) {
        setOpen(false);
      }
    });
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && !popover.hidden) setOpen(false);
    });
  }

  async function refreshModules() {
    try {
      const resp = await fetch('/api/modules');
      const data = await resp.json();
      currentModules = data.modules || [];
      renderModuleNavBar();
      renderHeaderQuickPins();
      renderStoreGrid();
    } catch (e) {
      setStoreStatus(`Could not load modules: ${e.message}`);
    }
  }

  function buildStoreAndCatalogPanes() {
    const rackPane = document.getElementById('pane-rack');
    if (!rackPane || !rackPane.parentNode) return;
    const container = rackPane.parentNode;

    if (!document.getElementById('pane-guild-store')) {
      const urlInput = el('input', {
        id: 'guildInstallUrlInput',
        className: 'guild-input',
        placeholder: 'https://github.com/org/mod-name.git, git@github.com:..., or gitea/mod-name',
      });
      const storePane = el('div', { id: 'pane-guild-store', className: 'drawer-pane' }, [
        el('div', { className: 'guild-store-wrap' }, [
          el('div', { className: 'guild-store-header' }, [
            el('div', {}, [
              el('div', { className: 'guild-card-title', text: 'LODGE GUILD // SOVEREIGN APP STORE & MODULE MANAGER' }),
              el('div', { className: 'guild-card-meta', text: 'Browse Public GitHub, Private GitHub, and Local-Only Gitea modules with AST audit + SHA-256 wheel verification.' }),
            ]),
            el('div', { className: 'guild-store-actions' }, [
              urlInput,
              el('button', {
                className: 'guild-btn primary',
                text: 'INSTALL GIT MODULE',
                on: {
                  click: () => {
                    const u = urlInput.value.trim();
                    if (!u) return;
                    const derived = u.split('/').pop().replace(/\.git$/, '').replace(/^mod-/, '').toLowerCase();
                    mutateModule(derived || 'custom', 'install', { repo_url: u });
                  },
                },
              }),
              el('button', {
                className: 'guild-btn',
                text: 'SYNC GUILD CATALOG',
                on: {
                  click: async () => {
                    setStoreStatus('Syncing Lodge Guild catalog (local Gitea / GitHub)...');
                    const resp = await fetch('/api/modules/catalog/sync', { method: 'POST' });
                    if (resp.ok) {
                      setStoreStatus('Catalog synced.');
                      await refreshModules();
                    } else {
                      setStoreStatus('Catalog sync failed.');
                    }
                  },
                },
              }),
            ]),
          ]),
          el('div', { id: 'guildScopeFilterBar', className: 'guild-store-actions', style: 'margin-bottom:10px;flex-wrap:wrap;' }),
          el('div', { id: 'guildStoreStatus', className: 'guild-status-bar', text: '' }),
          el('div', { id: 'guildStoreGrid', className: 'guild-grid' }),
        ]),
      ]);
      container.appendChild(storePane);
    }

    if (!document.getElementById('pane-ecotype-sync')) {
      const ecoPane = el('div', { id: 'pane-ecotype-sync', className: 'drawer-pane' }, [
        el('div', { className: 'guild-store-wrap' }, [
          el('div', { className: 'guild-store-header' }, [
            el('div', {}, [
              el('div', { className: 'guild-card-title', text: 'HEARTWOOD // ECOTYPE SYNC, DIFF & PROMOTION' }),
              el('div', {
                className: 'guild-card-meta',
                text: 'Inspect divergence between ecotype/<node> and upstream develop, review unified file diffs, pollinate updates, and graft clean Heartwood changes upstream.',
              }),
            ]),
            el('div', { className: 'guild-store-actions' }, [
              el('button', {
                id: 'ecoBtnFetch',
                className: 'guild-btn',
                text: 'CHECK UPSTREAM (FETCH)',
                title: 'Fetch latest refs from origin/gitea without touching your working tree',
                on: { click: () => runEcotypeSyncAction('fetch') },
              }),
              el('button', {
                id: 'ecoBtnSync',
                className: 'guild-btn primary',
                text: 'POLLINATE FROM UPSTREAM',
                title: 'Sandboxed worktree test-merge from upstream develop + AST verification',
                on: { click: () => runEcotypeSyncAction('sync') },
              }),
              el('button', {
                id: 'ecoBtnInit',
                className: 'guild-btn',
                text: 'ENSURE ECOTYPE BRANCH',
                title: 'Ensure active branch is ecotype/<node>',
                on: { click: () => runEcotypeSyncAction('init') },
              }),
              el('button', {
                id: 'ecoBtnBackupLocal',
                className: 'guild-btn',
                text: 'BACKUP LOCAL GITEA',
                title: 'Push ecotype/<node> to local Gitea',
                on: { click: () => runEcotypeSyncAction('backup') },
              }),
              el('button', {
                id: 'ecoBtnBackupCloud',
                className: 'guild-btn',
                text: 'MIRROR GITHUB CLOUD',
                title: 'Push ecotype/<node> to origin/ecotype/<node> without touching develop',
                on: { click: () => runEcotypeSyncAction('backup-cloud') },
              }),
              el('button', {
                id: 'ecoBtnRefresh',
                className: 'guild-btn',
                text: 'REFRESH',
                on: { click: () => loadEcotypeSyncPane() },
              }),
            ]),
          ]),
          el('div', { id: 'ecoSyncStatusBar', className: 'guild-status-bar', text: '' }),
          el('div', { id: 'ecoKpiGrid', className: 'eco-kpi-grid' }),
          el('div', { id: 'ecoCommitsGrid', className: 'eco-split-grid' }),
          el('div', { id: 'ecoTissueGrid', className: 'eco-split-grid' }),
          el('div', { id: 'ecoDiffCard', className: 'eco-diff-card', style: 'display:none;' }),
          el('pre', { id: 'ecoActionConsole', className: 'eco-console', style: 'display:none;' }),
        ]),
      ]);
      container.appendChild(ecoPane);
    }

    if (!document.getElementById('pane-api-catalog')) {
      const qInput = el('input', {
        id: 'apiCatalogQueryInput',
        className: 'guild-input',
        placeholder: 'Search 1,959 public REST APIs (e.g. weather, geocoding, finance)...',
      });
      qInput.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') loadApiCatalog(qInput.value.trim());
      });
      const apiPane = el('div', { id: 'pane-api-catalog', className: 'drawer-pane' }, [
        el('div', { className: 'guild-store-wrap' }, [
          el('div', { className: 'guild-store-header' }, [
            el('div', {}, [
              el('div', { className: 'guild-card-title', text: 'HEARTWOOD // PUBLIC API CATALOG (1,959 REST ENDPOINTS)' }),
              el('div', { className: 'guild-card-meta', text: 'Discover zero-auth REST APIs for modules, forged tools, and automation jobs.' }),
            ]),
            el('div', { className: 'guild-store-actions' }, [
              qInput,
              el('button', {
                className: 'guild-btn primary',
                text: 'SEARCH',
                on: { click: () => loadApiCatalog(qInput.value.trim()) },
              }),
            ]),
          ]),
          el('div', { id: 'apiCatalogResults', className: 'guild-grid' }),
        ]),
      ]);
      container.appendChild(apiPane);
    }

    if (!document.getElementById('pane-loop-studio')) {
      const loopPane = el('div', { id: 'pane-loop-studio', className: 'drawer-pane', style: 'height: 100%; padding: 0;' }, [
        el('div', { id: 'loopStudioGlobalHost', style: 'height: 100%;' }),
      ]);
      container.appendChild(loopPane);
    }

    const resLoopBtn = document.getElementById('btnOpenResearchLoopStudio');
    if (resLoopBtn && !resLoopBtn.dataset.boundLoopStudio) {
      resLoopBtn.dataset.boundLoopStudio = '1';
      resLoopBtn.addEventListener('click', () => {
        if (window.LodgeLoopStudio && window.LodgeLoopStudio.openModal) {
          window.LodgeLoopStudio.openModal({
            owner: 'heartwood',
            loopId: 'deep-research',
            title: 'Sovereign Research Studio — 5-Phase Agentic Loop (ALP v1)',
          });
        }
      });
    }
  }

  const ecoState = {
    data: null,
    selectedPaths: new Set(),
    activeDiffPath: null,
    activeDiffMode: 'ecotype',
    busy: false,
  };

  function setEcoStatus(msg) {
    const bar = document.getElementById('ecoSyncStatusBar');
    if (bar) bar.textContent = msg || '';
  }

  function setEcoConsole(text) {
    const pre = document.getElementById('ecoActionConsole');
    if (!pre) return;
    if (!text) {
      pre.style.display = 'none';
      pre.textContent = '';
    } else {
      pre.style.display = 'block';
      pre.textContent = text;
    }
  }

  function renderEcoDiffViewer(meta, diffText) {
    const card = document.getElementById('ecoDiffCard');
    if (!card) return;
    card.style.display = 'flex';
    card.replaceChildren();

    const titleText = meta.path
      ? `DIFF // ${meta.path} (${meta.mode === 'working' ? 'Working Tree vs HEAD' : meta.mode === 'incoming' ? `Incoming from ${meta.upstream}` : `vs ${meta.upstream}`})`
      : `DIFF SUMMARY // ${meta.mode === 'incoming' ? `Incoming from ${meta.upstream}` : `${meta.upstream}...HEAD`}`;

    const modeBtn = (m, label) => el('button', {
      type: 'button',
      className: 'drawer-subtab-btn' + (meta.mode === m ? ' active' : ''),
      text: label,
      on: { click: () => openEcotypeDiff(meta.path, m) },
    });

    card.appendChild(el('div', { className: 'eco-section-head' }, [
      el('div', { className: 'guild-card-title', text: titleText }),
      el('div', { className: 'guild-store-actions' }, [
        modeBtn('ecotype', `vs ${meta.upstream || 'develop'}`),
        modeBtn('incoming', 'Incoming Upstream'),
        modeBtn('working', 'Working Tree'),
        el('button', {
          type: 'button',
          className: 'guild-btn',
          text: 'CLOSE',
          on: {
            click: () => {
              ecoState.activeDiffPath = null;
              card.style.display = 'none';
              highlightActiveEcoFile();
            },
          },
        }),
      ]),
    ]));

    const body = el('div', { className: 'eco-diff-view' });
    const text = (diffText || '').trimEnd();
    if (!text) {
      body.appendChild(el('div', {
        className: 'eco-diff-line meta',
        text: '(No changes in this diff view)',
      }));
    } else {
      text.split('\n').forEach((line) => {
        let cls = 'eco-diff-line';
        if (line.startsWith('+++') || line.startsWith('---') || line.startsWith('diff --git') || line.startsWith('index ')) {
          cls += ' meta';
        } else if (line.startsWith('@@')) {
          cls += ' hunk';
        } else if (line.startsWith('+')) {
          cls += ' add';
        } else if (line.startsWith('-')) {
          cls += ' del';
        }
        body.appendChild(el('div', { className: cls, text: line }));
      });
    }
    card.appendChild(body);
  }

  function highlightActiveEcoFile() {
    document.querySelectorAll('#pane-ecotype-sync .eco-file-row').forEach((row) => {
      row.classList.toggle('active', Boolean(ecoState.activeDiffPath) && row.dataset.path === ecoState.activeDiffPath);
    });
  }

  async function openEcotypeDiff(filePath, mode) {
    const resolvedMode = mode || 'ecotype';
    ecoState.activeDiffPath = filePath || null;
    ecoState.activeDiffMode = resolvedMode;
    highlightActiveEcoFile();

    const card = document.getElementById('ecoDiffCard');
    if (card) {
      card.style.display = 'flex';
      card.replaceChildren(el('div', { className: 'guild-card-meta', text: `Loading diff${filePath ? ` for ${filePath}` : ''}...` }));
    }

    try {
      const qs = new URLSearchParams();
      if (filePath) qs.set('path', filePath);
      qs.set('mode', resolvedMode);
      const r = await fetch(`/api/ecotype/diff?${qs.toString()}`);
      const d = await r.json();
      if (!r.ok || d.status !== 'ok') {
        renderEcoDiffViewer({ path: filePath, mode: resolvedMode, upstream: 'develop' }, `Error: ${d.message || 'Failed to load diff'}`);
        return;
      }
      renderEcoDiffViewer(d, d.diff || '');
    } catch (e) {
      renderEcoDiffViewer({ path: filePath, mode: resolvedMode, upstream: 'develop' }, `Error: ${e.message}`);
    }
  }

  async function runEcotypeSyncAction(action, extraPayload) {
    if (ecoState.busy) return;
    ecoState.busy = true;
    setEcoStatus(`Running /ecotype ${action}...`);
    setEcoConsole(`Running /ecotype ${action}...`);
    try {
      const r = await fetch('/api/ecotype/action', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(Object.assign({ action }, extraPayload || {})),
      });
      const d = await r.json();
      const out = d.output || d.message || JSON.stringify(d, null, 2);
      setEcoConsole(out);
      setEcoStatus(d.status === 'ok' ? `/ecotype ${action} completed.` : `/ecotype ${action} reported an error.`);
      if (action === 'promote' && d.status === 'ok') {
        ecoState.selectedPaths.clear();
      }
      await loadEcotypeSyncPane();
    } catch (e) {
      setEcoConsole(`Error: ${e.message}`);
      setEcoStatus(`/ecotype ${action} failed: ${e.message}`);
    } finally {
      ecoState.busy = false;
    }
  }

  function renderEcotypeSyncData(d) {
    ecoState.data = d;
    const hwFiles = Array.isArray(d.diverged_heartwood) ? d.diverged_heartwood : [];
    const folFiles = Array.isArray(d.diverged_foliage) ? d.diverged_foliage : [];
    const dirtyFiles = Array.isArray(d.dirty_list) ? d.dirty_list : [];
    const upCommits = Array.isArray(d.upstream_commits) ? d.upstream_commits : [];
    const locCommits = Array.isArray(d.local_commits) ? d.local_commits : [];

    // Keep selectedPaths pruned to currently diverged Heartwood files
    const hwSet = new Set(hwFiles);
    Array.from(ecoState.selectedPaths).forEach((p) => {
      if (!hwSet.has(p)) ecoState.selectedPaths.delete(p);
    });

    // Update primary Pollinate button label with incoming count
    const syncBtn = document.getElementById('ecoBtnSync');
    if (syncBtn) {
      syncBtn.textContent = d.behind > 0
        ? `POLLINATE FROM UPSTREAM (+${d.behind} INCOMING)`
        : 'POLLINATE FROM UPSTREAM';
    }

    // 1. KPI Grid
    const kpi = document.getElementById('ecoKpiGrid');
    if (kpi) {
      kpi.replaceChildren(
        el('div', { className: 'eco-kpi-card ' + (d.on_ecotype ? 'ok' : 'warn') }, [
          el('div', { className: 'eco-kpi-label', text: 'ORGANISM / ACTIVE BRANCH' }),
          el('div', { className: 'eco-kpi-value', text: d.current_branch || 'unknown' }),
          el('div', {
            className: 'eco-kpi-sub',
            text: d.on_ecotype
              ? `Node '${d.node}' aligned on expected ecotype branch`
              : `Expected '${d.expected_branch}' — click Ensure Ecotype Branch`,
          }),
        ]),
        el('div', { className: 'eco-kpi-card ' + (d.behind > 0 ? 'warn' : 'ok') }, [
          el('div', { className: 'eco-kpi-label', text: `VS TRUNK (${d.upstream || 'develop'})` }),
          el('div', { className: 'eco-kpi-value', text: `+${d.ahead || 0} ahead  /  -${d.behind || 0} behind` }),
          el('div', {
            className: 'eco-kpi-sub',
            text: d.behind > 0
              ? `${d.behind} upstream Heartwood commit(s) ready to pollinate`
              : 'Up to date with upstream Heartwood trunk',
          }),
        ]),
        el('div', { className: 'eco-kpi-card' }, [
          el('div', { className: 'eco-kpi-label', text: 'TISSUE SPLIT (VS TRUNK)' }),
          el('div', { className: 'eco-kpi-value', text: `${hwFiles.length} Heartwood · ${folFiles.length} Foliage` }),
          el('div', { className: 'eco-kpi-sub', text: 'Heartwood is promotable; Foliage (.george) is firewalled' }),
        ]),
        el('div', { className: 'eco-kpi-card ' + ((d.dirty_files || 0) > 0 ? 'warn' : 'ok') }, [
          el('div', { className: 'eco-kpi-label', text: 'WORKING TREE' }),
          el('div', { className: 'eco-kpi-value', text: (d.dirty_files || 0) === 0 ? 'Clean' : `${d.dirty_files} uncommitted` }),
          el('div', {
            className: 'eco-kpi-sub',
            text: (d.dirty_files || 0) === 0 ? 'Ready for clean pollination or backup' : 'Click any dirty file below to inspect diff',
          }),
        ]),
      );
    }

    // 2. Upstream Incoming & Local Ecotype Commit Lists
    const commitsGrid = document.getElementById('ecoCommitsGrid');
    if (commitsGrid) {
      commitsGrid.replaceChildren();
      if (upCommits.length > 0 || locCommits.length > 0) {
        const makeCommitCard = (title, badgeText, badgeCls, commits, diffMode) => {
          const list = el('div', { className: 'eco-commit-list' });
          if (commits.length === 0) {
            list.appendChild(el('div', { className: 'guild-card-meta', text: 'None.' }));
          } else {
            commits.forEach((c) => {
              list.appendChild(el('div', { className: 'eco-commit-row' }, [
                el('span', { className: 'eco-commit-sha', text: c.sha }),
                el('span', { className: 'eco-commit-msg', text: c.subject, title: c.subject }),
              ]));
            });
          }
          return el('div', { className: 'eco-section-card' }, [
            el('div', { className: 'eco-section-head' }, [
              el('div', { className: 'guild-card-title', text: title }),
              el('div', { className: 'guild-store-actions' }, [
                el('span', { className: `guild-badge ${badgeCls}`, text: badgeText }),
                el('button', {
                  type: 'button',
                  className: 'guild-btn',
                  text: 'DIFF STAT',
                  on: { click: () => openEcotypeDiff(null, diffMode) },
                }),
              ]),
            ]),
            list,
          ]);
        };

        commitsGrid.appendChild(makeCommitCard(
          `INCOMING HEARTWOOD COMMITS (${d.upstream || 'develop'})`,
          `${upCommits.length} BEHIND`,
          upCommits.length > 0 ? 'on' : 'off',
          upCommits,
          'incoming',
        ));
        commitsGrid.appendChild(makeCommitCard(
          `LOCAL ECOTYPE COMMITS (${d.current_branch || 'HEAD'})`,
          `${locCommits.length} AHEAD`,
          locCommits.length > 0 ? 'on' : 'off',
          locCommits,
          'ecotype',
        ));
      }
    }

    // 3. Tissue Split: Heartwood (Promotable) + Foliage & Working Tree
    const tissueGrid = document.getElementById('ecoTissueGrid');
    if (!tissueGrid) return;
    tissueGrid.replaceChildren();

    // Left Card: Heartwood Files + Promote Controls
    const hwList = el('div', { className: 'eco-file-list' });
    const promoteBtn = el('button', {
      type: 'button',
      className: 'guild-btn primary',
      text: `PROMOTE SELECTED HEARTWOOD (${ecoState.selectedPaths.size})`,
      disabled: ecoState.selectedPaths.size === 0,
    });
    const updatePromoteBtn = () => {
      promoteBtn.textContent = `PROMOTE SELECTED HEARTWOOD (${ecoState.selectedPaths.size})`;
      promoteBtn.disabled = ecoState.selectedPaths.size === 0;
    };

    if (hwFiles.length === 0) {
      hwList.appendChild(el('div', {
        className: 'guild-card-meta',
        text: `No diverged Heartwood files between ${d.upstream || 'develop'} and ${d.current_branch || 'HEAD'}.`,
      }));
    } else {
      hwFiles.forEach((p) => {
        const cb = el('input', { type: 'checkbox' });
        cb.checked = ecoState.selectedPaths.has(p);
        cb.addEventListener('change', () => {
          if (cb.checked) ecoState.selectedPaths.add(p);
          else ecoState.selectedPaths.delete(p);
          updatePromoteBtn();
        });
        const row = el('div', { className: 'eco-file-row', attrs: { 'data-path': p } }, [
          el('div', { className: 'eco-file-left' }, [
            cb,
            el('span', {
              className: 'eco-file-path',
              text: p,
              title: `Click to view diff for ${p}`,
              on: { click: () => openEcotypeDiff(p, 'ecotype') },
            }),
          ]),
          el('button', {
            type: 'button',
            className: 'guild-btn',
            text: 'DIFF',
            on: { click: () => openEcotypeDiff(p, 'ecotype') },
          }),
        ]);
        hwList.appendChild(row);
      });
    }

    const titleInput = el('input', {
      type: 'text',
      className: 'guild-input',
      style: 'flex:1;min-width:200px;',
      placeholder: 'Promotion title (e.g. feat(web): surface ecotype sync console)',
    });
    const pushOriginCb = el('input', { type: 'checkbox' });
    promoteBtn.addEventListener('click', () => {
      const paths = Array.from(ecoState.selectedPaths);
      if (paths.length === 0) return;
      const title = titleInput.value.trim() || `Promote heartwood updates from ${d.node || 'ecotype'}`;
      runEcotypeSyncAction('promote', {
        title,
        paths,
        push_origin: Boolean(pushOriginCb.checked),
      });
    });

    const hwCard = el('div', { className: 'eco-section-card heartwood' }, [
      el('div', { className: 'eco-section-head' }, [
        el('div', {}, [
          el('div', { className: 'guild-card-title', text: `HEARTWOOD / CAMBIUM (${hwFiles.length})` }),
          el('div', { className: 'guild-card-meta', text: 'Shared core files diverged from trunk — safe to review & promote via candidate/* branch.' }),
        ]),
        el('div', { className: 'guild-store-actions' }, [
          el('button', {
            type: 'button',
            className: 'guild-btn',
            text: 'SELECT ALL',
            disabled: hwFiles.length === 0,
            on: {
              click: () => {
                hwFiles.forEach((p) => ecoState.selectedPaths.add(p));
                renderEcotypeSyncData(d);
              },
            },
          }),
          el('button', {
            type: 'button',
            className: 'guild-btn',
            text: 'CLEAR',
            disabled: hwFiles.length === 0,
            on: {
              click: () => {
                ecoState.selectedPaths.clear();
                renderEcotypeSyncData(d);
              },
            },
          }),
        ]),
      ]),
      hwList,
      el('div', { className: 'eco-promote-bar' }, [
        el('div', { className: 'eco-promote-row' }, [titleInput, promoteBtn]),
        el('label', { className: 'eco-check-label' }, [
          pushOriginCb,
          'Also push clean candidate/* branch to GitHub origin',
        ]),
      ]),
    ]);

    // Right Card: Foliage (Firewalled) + Uncommitted Working Tree
    const folList = el('div', { className: 'eco-file-list' });
    if (folFiles.length === 0) {
      folList.appendChild(el('div', { className: 'guild-card-meta', text: 'No tracked Foliage divergence vs trunk.' }));
    } else {
      folFiles.forEach((p) => {
        folList.appendChild(el('div', { className: 'eco-file-row', attrs: { 'data-path': p } }, [
          el('div', { className: 'eco-file-left' }, [
            el('span', { className: 'guild-badge off', text: 'FOLIAGE' }),
            el('span', {
              className: 'eco-file-path',
              text: p,
              title: p,
              on: { click: () => openEcotypeDiff(p, 'ecotype') },
            }),
          ]),
          el('button', {
            type: 'button',
            className: 'guild-btn',
            text: 'DIFF',
            on: { click: () => openEcotypeDiff(p, 'ecotype') },
          }),
        ]));
      });
    }

    const dirtyBlock = [];
    if (dirtyFiles.length > 0) {
      const dirtyList = el('div', { className: 'eco-file-list', style: 'margin-top:6px;' });
      dirtyFiles.forEach((p) => {
        dirtyList.appendChild(el('div', { className: 'eco-file-row', attrs: { 'data-path': p } }, [
          el('div', { className: 'eco-file-left' }, [
            el('span', { className: 'guild-badge', text: 'DIRTY' }),
            el('span', {
              className: 'eco-file-path',
              text: p,
              title: `Inspect uncommitted diff for ${p}`,
              on: { click: () => openEcotypeDiff(p, 'working') },
            }),
          ]),
          el('button', {
            type: 'button',
            className: 'guild-btn',
            text: 'DIFF',
            on: { click: () => openEcotypeDiff(p, 'working') },
          }),
        ]));
      });
      dirtyBlock.push(
        el('div', { className: 'eco-promote-bar' }, [
          el('div', { className: 'guild-card-title', text: `UNCOMMITTED WORKING TREE (${d.dirty_files || dirtyFiles.length})` }),
          dirtyList,
        ]),
      );
    }

    const folCard = el('div', { className: 'eco-section-card foliage' }, [
      el('div', { className: 'eco-section-head' }, [
        el('div', {}, [
          el('div', { className: 'guild-card-title', text: `FOLIAGE / NODE-LOCAL (${folFiles.length})` }),
          el('div', { className: 'guild-card-meta', text: 'Firewalled (.george/, dossiers, keys, local state) — never promoted to develop.' }),
        ]),
        el('span', { className: 'guild-badge off', text: 'FIREWALLED' }),
      ]),
      folList,
      ...dirtyBlock,
    ]);

    tissueGrid.appendChild(hwCard);
    tissueGrid.appendChild(folCard);
    highlightActiveEcoFile();
  }

  async function loadEcotypeSyncPane() {
    setEcoStatus('Reading ecotype branch & Heartwood divergence...');
    try {
      const r = await fetch('/api/ecotype/status');
      const d = await r.json();
      if (!r.ok || d.status !== 'ok') {
        setEcoStatus(`Failed to load ecotype status: ${d.message || r.status}`);
        return;
      }
      renderEcotypeSyncData(d);
      setEcoStatus(`Loaded ${d.current_branch} vs ${d.upstream} (+${d.ahead} ahead / -${d.behind} behind).`);
    } catch (e) {
      setEcoStatus(`Error loading ecotype status: ${e.message}`);
    }
  }

  window.LodgeModules = {
    register(id, impl) {
      registeredPlugins.set(id, impl);
    },
    getAgentName: () => activeAgentName,
    refresh: refreshModules,
    refreshEcotype: loadEcotypeSyncPane,
    activatePane,
    openCoreGroup,
    openModuleById,
  };

  async function initModularDrawer() {
    await resolveAgentName();
    buildCoreNav();
    buildStoreAndCatalogPanes();
    initHeaderPinPicker();
    renderHeaderQuickPins();
    refreshModules();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initModularDrawer);
  } else {
    initModularDrawer();
  }
})();
