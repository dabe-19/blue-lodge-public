// ============================================================================
// BLUE LODGE // Sovereign Training Forge, Sleep-Cycle SVD-32 & Tier B Gate UI
// Strictly XSS-safe DOM construction (zero innerHTML / outerHTML, zero confirm).
// ============================================================================
(function () {
  'use strict';

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
      if (opts.checked) node.checked = true;
      if (opts.min != null) node.min = String(opts.min);
      if (opts.max != null) node.max = String(opts.max);
      if (opts.step != null) node.step = String(opts.step);
      if (opts.style) {
        if (typeof opts.style === 'string') node.setAttribute('style', opts.style);
        else Object.assign(node.style, opts.style);
      }
      if (opts.attrs) Object.entries(opts.attrs).forEach(([k, v]) => node.setAttribute(k, String(v)));
      if (opts.on) Object.entries(opts.on).forEach(([ev, fn]) => node.addEventListener(ev, fn));
    }
    (children || []).forEach((c) => {
      if (c != null) node.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
    });
    return node;
  }

  const state = {
    activeTab: 'gate',
    data: null,
    colabSessions: null,
    colabScanning: false,
    armedCullTarget: null,
    pantry: null,
    lastPreflight: null,
    lastConfigPath: null,
    h2hResult: null,
    armedLaunch: false,
    streamRun: null,
    streamTrack: null,
    streamData: null,
    streamAuto: true,
    streamTimer: null,
    streamBusy: false,
    consoleText: 'Ready. Inspect active Colab/local runs, live Colab GPU assignments, or launch a playbook.',
  };

  function stopStreamTimer() {
    if (state.streamTimer) {
      clearInterval(state.streamTimer);
      state.streamTimer = null;
    }
  }

  async function fetchStreamLogs(runName, trackName) {
    if (!runName || state.streamBusy) return;
    state.streamBusy = true;
    try {
      const qs = new URLSearchParams({ live: '1', lines: '100' });
      if (trackName) qs.set('track', trackName);
      const { data } = await apiJson(`/api/training/runs/${encodeURIComponent(runName)}/logs?${qs.toString()}`);
      if (state.streamRun === runName) {
        state.streamData = data;
        if (!state.streamTrack && data && data.track) state.streamTrack = data.track;
        renderForge();
        const pre = document.getElementById('forgeLiveStreamPre');
        if (pre) pre.scrollTop = pre.scrollHeight;
      }
    } finally {
      state.streamBusy = false;
    }
  }

  function openLiveStream(runName, trackName) {
    stopStreamTimer();
    state.streamRun = runName;
    state.streamTrack = trackName || null;
    state.streamData = { status: 'loading', run: runName, track: trackName || '…', log_tail: 'Connecting to training runtime (Colab / local GPU)...' };
    state.streamAuto = true;
    renderForge();
    fetchStreamLogs(runName, trackName);
    state.streamTimer = setInterval(() => {
      if (state.streamAuto && state.streamRun) {
        fetchStreamLogs(state.streamRun, state.streamTrack);
      }
    }, 12000);
  }

  function setConsole(msg) {
    state.consoleText = typeof msg === 'string' ? msg : JSON.stringify(msg, null, 2);
    const pre = document.getElementById('forgeStudioConsole');
    if (pre) pre.textContent = state.consoleText;
  }

  async function apiJson(url, opts) {
    const r = await fetch(url, opts);
    const d = await r.json().catch(() => ({ status: 'error', message: `HTTP ${r.status}` }));
    return { ok: r.ok, data: d };
  }

  async function loadColabSessions(probe) {
    if (state.colabScanning) return;
    state.colabScanning = true;
    state.armedCullTarget = null;
    if (probe) setConsole('Probing live Colab VMs (nvidia-smi + process check) for stale or orphaned GPUs...');
    renderForge();
    try {
      const { data } = await apiJson(`/api/training/colab/sessions?probe=${probe ? '1' : '0'}`);
      state.colabSessions = data;
      if (probe) {
        if (data && data.status === 'ok') {
          setConsole(`Live Colab GPU scan complete: ${data.total} VM(s) total — ${data.active_count} active, ${data.stale_count} stale/orphaned.`);
        } else {
          setConsole(data);
        }
      }
    } finally {
      state.colabScanning = false;
      renderForge();
    }
  }

  async function cullColabTarget(target, allStale) {
    state.armedCullTarget = null;
    setConsole(allStale ? 'Culling all stale/orphaned Colab VMs...' : `Terminating Colab VM ${target}...`);
    const body = allStale ? { all_stale: true } : { target };
    const { data } = await apiJson('/api/training/colab/cull', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    setConsole(data);
    await refreshAll();
  }

  async function refreshAll() {
    setConsole('Refreshing Forge telemetry, Colab ADC credits, live GPU assignments, prerequisites, runs & SVD lineage...');
    const [statusRes, sessRes] = await Promise.all([
      apiJson('/api/training/status'),
      apiJson('/api/training/colab/sessions?probe=0'),
    ]);
    const data = statusRes.data;
    state.data = data;
    if (sessRes && sessRes.data) state.colabSessions = sessRes.data;
    state.armedCullTarget = null;
    renderForge();
    const pr = (data && data.prerequisites) || {};
    if (data && data.credits && data.credits.status === 'ok') {
      const staleNote = state.colabSessions && state.colabSessions.stale_count > 0
        ? ` · WARNING: ${state.colabSessions.stale_count} stale/orphaned Colab VM(s) detected!`
        : '';
      setConsole(`Connected (${data.credits.auth}): ${data.adc_status}${staleNote}`);
    } else if (pr.issues && pr.issues.length > 0) {
      setConsole('Prerequisites missing:\n' + pr.issues.map((i) => `[${i.severity.toUpperCase()}] ${i.component}: ${i.message}\n  Fix: ${i.fix}`).join('\n'));
    } else {
      setConsole(data && data.adc_status ? data.adc_status : 'Loaded Forge state.');
    }
  }

  function renderPrereqStrip(prereqs) {
    const p = prereqs || {};
    const chip = (label, ok, detail) => el('div', {
      className: 'forge-prereq-chip ' + (ok ? 'ok' : 'bad'),
      title: detail || '',
    }, [
      el('span', { className: 'forge-dot ' + (ok ? 'ok' : 'bad') }),
      el('span', { text: `${label}: ${ok ? 'READY' : 'MISSING'}` }),
    ]);

    const chips = el('div', { className: 'forge-prereq-row' }, [
      chip('Colab CLI', Boolean(p.colab_cli && p.colab_cli.installed), p.colab_cli && (p.colab_cli.version || p.colab_cli.path)),
      chip('gcloud CLI', Boolean(p.gcloud_cli && p.gcloud_cli.installed), p.gcloud_cli && p.gcloud_cli.path),
      chip('Google ADC', Boolean(p.adc_credentials && p.adc_credentials.configured), p.adc_credentials && p.adc_credentials.path),
      chip('Colab OAuth2', Boolean(p.oauth2_credentials && p.oauth2_credentials.configured), p.oauth2_credentials && p.oauth2_credentials.path),
      chip('HF Token', Boolean(p.hf_token && p.hf_token.configured), p.hf_token && p.hf_token.source),
      chip('Local CUDA Train', Boolean(p.local_train_env && p.local_train_env.installed), `${(p.local_train_env && p.local_train_env.gpus || []).length} GPU(s)`),
    ]);

    const issues = Array.isArray(p.issues) ? p.issues : [];
    const wrap = el('div', { className: 'forge-card' }, [
      el('div', { className: 'forge-card-head' }, [
        el('div', { className: 'guild-card-title', text: 'PREREQUISITES & AUTHENTICATION HEALTH' }),
        el('button', { type: 'button', className: 'guild-btn', text: 'RE-CHECK', on: { click: refreshAll } }),
      ]),
      chips,
    ]);

    if (issues.length > 0) {
      const box = el('div', { className: 'forge-issue-list' });
      issues.forEach((iss) => {
        box.appendChild(el('div', { className: 'forge-issue-row ' + (iss.severity || 'warning') }, [
          el('div', { style: 'font-weight:700;font-size:11px;', text: `[${String(iss.severity || 'warn').toUpperCase()}] ${iss.component} — ${iss.message}` }),
          el('code', { className: 'forge-fix-cmd', text: iss.fix || '' }),
        ]));
      });
      wrap.appendChild(box);
    }
    return wrap;
  }

  function renderOverviewTab(d) {
    const credits = d.credits || {};
    const policy = d.policy || {};
    const bkp = d.backup_status || {};
    const pendingCount = ((d.gate_queue && d.gate_queue.pending) || []).length;

    const kpiRow = el('div', { className: 'eco-kpi-grid' }, [
      el('div', { className: 'eco-kpi-card ' + (credits.status === 'ok' ? 'ok' : 'warn') }, [
        el('div', { className: 'eco-kpi-label', text: 'GOOGLE COLAB COMPUTE UNITS' }),
        el('div', { className: 'eco-kpi-value', text: credits.status === 'ok' ? `${credits.balance} CU` : 'UNAVAILABLE' }),
        el('div', { className: 'eco-kpi-sub', text: credits.status === 'ok' ? `Rate: ${credits.rate || '0/hr'} · Active VMs: ${credits.active_assignments || 0}` : (credits.message || 'Configure ADC or OAuth2') }),
      ]),
      el('div', { className: 'eco-kpi-card ' + (policy.autonomy_tier === 'tier_a' ? 'warn' : 'ok') }, [
        el('div', { className: 'eco-kpi-label', text: 'PROMOTION AUTONOMY POSTURE' }),
        el('div', { className: 'eco-kpi-value', text: policy.autonomy_tier === 'tier_a' ? 'TIER A // FULL AUTO' : 'TIER B // HUMAN GATE' }),
        el('div', { className: 'eco-kpi-sub', text: policy.autonomy_tier === 'tier_a' ? `Auto-promotes when Δ >= +${policy.tier_a_min_delta || 3}%` : 'Requires Accept in Forge UI or Discord' }),
      ]),
      el('div', { className: 'eco-kpi-card ' + (pendingCount > 0 ? 'warn' : 'ok') }, [
        el('div', { className: 'eco-kpi-label', text: 'TIER B APPROVAL QUEUE' }),
        el('div', { className: 'eco-kpi-value', text: `${pendingCount} pending` }),
        el('div', { className: 'eco-kpi-sub', text: `${((d.gate_queue && d.gate_queue.history) || []).length} total training run(s) logged` }),
      ]),
      el('div', { className: 'eco-kpi-card' }, [
        el('div', { className: 'eco-kpi-label', text: 'BACKUP TARGETS (DRIVE / HF)' }),
        el('div', { className: 'eco-kpi-value', text: `Drive: ${bkp.drive && bkp.drive.ready ? 'READY' : 'OFF'} · HF: ${bkp.hf && bkp.hf.ready ? 'READY' : 'OFF'}` }),
        el('div', { className: 'eco-kpi-sub', text: (bkp.hf && bkp.hf.repo) ? `HF Repo: ${bkp.hf.repo}` : 'Configure HF repo & Drive folder below' }),
      ]),
    ]);

    // Policy & Sleep-Cycle Controls
    const tierSel = el('select', { className: 'guild-input', style: 'min-width:200px;' }, [
      el('option', { value: 'tier_b', text: 'Tier B — Human Approval (Forge + Discord)' }),
      el('option', { value: 'tier_a', text: 'Tier A — Full Autonomy (Auto-Promote on Gate Pass)' }),
    ]);
    tierSel.value = policy.autonomy_tier || 'tier_b';

    const sleepCb = el('input', { type: 'checkbox', checked: Boolean(policy.sleep_enabled) });
    const startHr = el('input', { type: 'number', className: 'guild-input', style: 'width:70px;min-width:70px;', min: 0, max: 23, value: policy.sleep_start_hour ?? 2 });
    const endHr = el('input', { type: 'number', className: 'guild-input', style: 'width:70px;min-width:70px;', min: 0, max: 23, value: policy.sleep_end_hour ?? 6 });
    const cuFloor = el('input', { type: 'number', className: 'guild-input', style: 'width:90px;min-width:90px;', min: 0, max: 5000, value: policy.min_cu_balance ?? 150 });
    const minDelta = el('input', { type: 'number', className: 'guild-input', style: 'width:80px;min-width:80px;', min: 0, max: 50, step: 0.5, value: policy.tier_a_min_delta ?? 3.0 });
    const hfRepoIn = el('input', { type: 'text', className: 'guild-input', style: 'min-width:220px;', placeholder: 'dabe-19/blue-lodge-adapters', value: policy.hf_backup_repo || '' });
    const driveFolderIn = el('input', { type: 'text', className: 'guild-input', style: 'min-width:220px;', value: policy.drive_backup_folder || 'BlueLodge/models/adapters' });
    const autoDriveCb = el('input', { type: 'checkbox', checked: Boolean(policy.auto_backup_drive) });
    const autoHfCb = el('input', { type: 'checkbox', checked: Boolean(policy.auto_backup_hf) });

    const policyCard = el('div', { className: 'forge-card' }, [
      el('div', { className: 'forge-card-head' }, [
        el('div', {}, [
          el('div', { className: 'guild-card-title', text: 'SLEEP-CYCLE ("DREAM & CONSOLIDATE") & AUTONOMY POLICY' }),
          el('div', { className: 'guild-card-meta', text: 'Controls autonomous overnight memory consolidation, Colab credit safety floor, Tier B/A promotion gate, and cloud backups.' }),
        ]),
        el('button', {
          type: 'button',
          className: 'guild-btn primary',
          text: 'SAVE POLICY',
          on: {
            click: async () => {
              const payload = {
                autonomy_tier: tierSel.value,
                sleep_enabled: Boolean(sleepCb.checked),
                sleep_start_hour: Number(startHr.value || 2),
                sleep_end_hour: Number(endHr.value || 6),
                min_cu_balance: Number(cuFloor.value || 150),
                tier_a_min_delta: Number(minDelta.value || 3.0),
                hf_backup_repo: hfRepoIn.value.trim(),
                drive_backup_folder: driveFolderIn.value.trim() || 'BlueLodge/models/adapters',
                auto_backup_drive: Boolean(autoDriveCb.checked),
                auto_backup_hf: Boolean(autoHfCb.checked),
              };
              const { data } = await apiJson('/api/training/policy', {
                method: 'POST', headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ policy: payload }),
              });
              setConsole(data);
              await refreshAll();
            },
          },
        }),
      ]),
      el('div', { className: 'forge-form-grid' }, [
        el('div', {}, [el('div', { className: 'eco-kpi-label', text: 'AUTONOMY POSTURE' }), tierSel]),
        el('div', {}, [el('div', { className: 'eco-kpi-label', text: 'TIER A MIN Δ (%)' }), minDelta]),
        el('div', {}, [el('div', { className: 'eco-kpi-label', text: 'COLAB CU FLOOR' }), cuFloor]),
        el('div', {}, [
          el('div', { className: 'eco-kpi-label', text: 'SLEEP WINDOW (24H)' }),
          el('div', { style: 'display:flex;gap:6px;align-items:center;' }, [startHr, el('span', { text: 'to' }), endHr]),
        ]),
        el('div', {}, [el('div', { className: 'eco-kpi-label', text: 'PRIVATE HF BACKUP REPO' }), hfRepoIn]),
        el('div', {}, [el('div', { className: 'eco-kpi-label', text: 'GOOGLE DRIVE BACKUP FOLDER' }), driveFolderIn]),
      ]),
      el('div', { style: 'display:flex;flex-wrap:wrap;gap:14px;margin-top:4px;' }, [
        el('label', { className: 'eco-check-label' }, [sleepCb, 'Enable scheduled Sleep-Cycle consolidation']),
        el('label', { className: 'eco-check-label' }, [autoDriveCb, 'Auto-backup promoted SVD-32 to Google Drive']),
        el('label', { className: 'eco-check-label' }, [autoHfCb, 'Auto-backup promoted SVD-32 to Private HF Hub']),
      ]),
    ]);

    return el('div', { style: 'display:flex;flex-direction:column;gap:12px;' }, [
      kpiRow,
      renderPrereqStrip(d.prerequisites),
      policyCard,
    ]);
  }

  function renderGateTab(d) {
    const history = (d.gate_queue && d.gate_queue.history) || [];
    const table = el('table', { className: 'forge-table' }, [
      el('thead', {}, [
        el('tr', {}, [
          el('th', { text: 'RUN / ROLE' }),
          el('th', { text: 'BASE MODEL' }),
          el('th', { text: 'BACKEND / GPU' }),
          el('th', { text: 'RETENTION' }),
          el('th', { text: 'BENCHMARK' }),
          el('th', { text: 'STATE / GATE' }),
          el('th', { text: 'ACTIONS' }),
        ]),
      ]),
    ]);
    const tbody = el('tbody');
    if (history.length === 0) {
      tbody.appendChild(el('tr', {}, [
        el('td', { attrs: { colspan: '7' }, className: 'guild-card-meta', text: 'No training runs recorded yet. Launch a playbook from the Playbook & Launch tab.' }),
      ]));
    } else {
      history.forEach((r) => {
        const gpus = (r.selected_gpus || []).join(', ') || (r.backend === 'local' ? 'local-cuda' : '—');
        const b = r.benchmark;
        const bTxt = b ? `${b.candidate_score ?? b.overall_score ?? '?'}% (Δ ${b.composite_delta ?? 0}%)` : 'Unscored';
        const actions = el('div', { style: 'display:flex;flex-wrap:wrap;gap:4px;' });

        const actBtn = (label, cls, action, extra) => el('button', {
          type: 'button',
          className: `guild-btn ${cls || ''}`,
          style: 'padding:3px 7px;font-size:10px;',
          text: label,
          on: {
            click: async () => {
              setConsole(`Running '${action}' on ${r.name}...`);
              const url = action === 'approve' ? `/api/training/gate/${encodeURIComponent(r.name)}/approve`
                : action === 'deny' ? `/api/training/gate/${encodeURIComponent(r.name)}/deny`
                : '/api/training/action';
              const body = (action === 'approve' || action === 'deny')
                ? (extra || {})
                : Object.assign({ action, run_name: r.name }, extra || {});
              const { data } = await apiJson(url, {
                method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
              });
              setConsole(data);
              await refreshAll();
            },
          },
        });

        if (r.gate_status === 'pending_approval') {
          actions.appendChild(actBtn('ACCEPT', 'primary', 'approve'));
          actions.appendChild(actBtn('DENY', 'danger', 'deny', { reason: 'Rejected in Forge Tier B gate' }));
        }
        if (r.backend === 'colab' && r.state === 'running') {
          actions.appendChild(actBtn('COLLECT', '', 'collect'));
          actions.appendChild(actBtn('RESUME', '', 'resume'));
          actions.appendChild(actBtn('CANCEL', 'danger', 'cancel'));
        }
        if (r.state === 'done' && !r.merged) {
          actions.appendChild(actBtn('MERGE SVD-32', 'primary', 'merge'));
        }
        actions.appendChild(el('button', {
          type: 'button',
          className: 'guild-btn primary',
          style: 'padding:3px 7px;font-size:10px;',
          text: 'LIVE LOGS',
          on: { click: () => openLiveStream(r.name, null) },
        }));
        actions.appendChild(el('button', {
          type: 'button', className: 'guild-btn', style: 'padding:3px 7px;font-size:10px;', text: 'INSPECT',
          on: { click: () => setConsole(r) },
        }));

        tbody.appendChild(el('tr', {}, [
          el('td', {}, [
            el('div', { style: 'font-weight:700;color:#f8fafc;', text: r.name }),
            el('div', { className: 'guild-card-meta', text: `role: ${r.role || 'core-agent'}` }),
          ]),
          el('td', { style: 'font-family:var(--font-mono);font-size:11px;', text: r.base_model || r.model_slug || '—' }),
          el('td', { text: `${r.backend} (${gpus})` }),
          el('td', { text: `${Math.round((r.prior_adapter_weight || 0) * 100)}% prior` }),
          el('td', { text: bTxt }),
          el('td', {}, [
            el('span', { className: 'guild-badge ' + (r.gate_status === 'approved' ? 'on' : r.gate_status === 'pending_approval' ? '' : 'off'), text: `${r.state} · ${r.gate_status}` }),
          ]),
          el('td', {}, [actions]),
        ]));
      });
    }
    table.appendChild(tbody);

    const wrapper = el('div', { style: 'display:flex;flex-direction:column;gap:12px;' });
    wrapper.appendChild(el('div', { className: 'forge-card' }, [
      el('div', { className: 'forge-card-head' }, [
        el('div', {}, [
          el('div', { className: 'guild-card-title', text: 'TIER B APPROVAL QUEUE & TRAINING RUN HISTORY' }),
          el('div', { className: 'guild-card-meta', text: 'Accept promoted SVD-32 candidates to flip active.gguf, Deny to keep current adapter, or click LIVE LOGS to stream real-time Colab/local GPU progress.' }),
        ]),
        el('button', { type: 'button', className: 'guild-btn', text: 'REFRESH RUNS', on: { click: refreshAll } }),
      ]),
      el('div', { style: 'overflow-x:auto;' }, [table]),
    ]));

    // Live Colab GPU Fleet & Stale / Orphaned VM Guard
    const cs = state.colabSessions || {};
    const csRows = Array.isArray(cs.sessions) ? cs.sessions : [];
    const staleCount = Number(cs.stale_count || 0);
    const armAll = state.armedCullTarget === '__ALL_STALE__';

    const vmTable = el('table', { className: 'forge-table' }, [
      el('thead', {}, [
        el('tr', {}, [
          el('th', { text: 'COLAB SESSION / ENDPOINT' }),
          el('th', { text: 'GPU / TELEMETRY' }),
          el('th', { text: 'MAPPED RUN / TRACK' }),
          el('th', { text: 'HEALTH' }),
          el('th', { text: 'ACTIONS' }),
        ]),
      ]),
    ]);
    const vmTbody = el('tbody');
    if (cs.status === 'error') {
      vmTbody.appendChild(el('tr', {}, [
        el('td', { attrs: { colspan: '5' }, className: 'guild-card-meta', text: cs.message || 'Colab API unavailable.' }),
      ]));
    } else if (csRows.length === 0) {
      vmTbody.appendChild(el('tr', {}, [
        el('td', { attrs: { colspan: '5' }, className: 'guild-card-meta', text: state.colabScanning ? 'Scanning Google Colab assignments...' : 'No active Colab GPU VMs provisioned (0 CU/hr burn).' }),
      ]));
    } else {
      csRows.forEach((row) => {
        const ep = row.endpoint || '';
        const isArmed = state.armedCullTarget === ep;
        const gpuCell = row.gpu
          ? `${row.accelerator || 'GPU'} · ${row.gpu.name} (${(row.gpu.used_mb / 1024).toFixed(1)}/${(row.gpu.total_mb / 1024).toFixed(1)} GiB · ${row.gpu.util_pct}%)`
          : (row.accelerator || '—');
        const mapLabel = row.run ? `${row.run} / ${row.track || 'default'}` : 'UNMAPPED / ORPHAN';
        const healthBadgeCls = row.stale ? 'guild-badge off' : 'guild-badge on';
        const healthTxt = row.stale ? String(row.health || 'STALE').toUpperCase() : 'ACTIVE';

        const rowActs = el('div', { style: 'display:flex;flex-wrap:wrap;gap:4px;' });
        if (row.run) {
          rowActs.appendChild(el('button', {
            type: 'button',
            className: 'guild-btn',
            style: 'padding:3px 7px;font-size:10px;',
            text: 'LOGS',
            on: { click: () => openLiveStream(row.run, row.track || null) },
          }));
        }
        rowActs.appendChild(el('button', {
          type: 'button',
          className: isArmed ? 'guild-btn danger' : (row.stale ? 'guild-btn danger' : 'guild-btn'),
          style: 'padding:3px 7px;font-size:10px;',
          text: isArmed ? 'CONFIRM CULL' : 'CULL VM',
          title: isArmed ? `Click again to permanently unassign ${ep}` : `Terminate Colab VM ${ep}`,
          on: {
            click: () => {
              if (!isArmed) {
                state.armedCullTarget = ep;
                setConsole(`Armed to cull Colab VM ${ep} (${row.session || 'untracked'} · ${row.accelerator}). Click CONFIRM CULL to terminate and stop CU burn.`);
                renderForge();
              } else {
                cullColabTarget(ep, false);
              }
            },
          },
        }));

        vmTbody.appendChild(el('tr', {}, [
          el('td', {}, [
            el('div', { style: 'font-weight:700;color:#f8fafc;', text: row.session || 'UNTRACKED ORPHAN [?]' }),
            el('div', { className: 'guild-card-meta', style: 'font-family:var(--font-mono);font-size:10px;', text: ep }),
          ]),
          el('td', { style: 'font-family:var(--font-mono);font-size:11px;', text: gpuCell }),
          el('td', { style: row.run ? 'font-family:var(--font-mono);font-size:11px;' : 'color:#fbbf24;font-weight:700;font-size:11px;', text: mapLabel }),
          el('td', {}, [
            el('span', { className: healthBadgeCls, text: healthTxt }),
            el('div', { className: 'guild-card-meta', style: 'margin-top:2px;', text: row.reason || '' }),
          ]),
          el('td', {}, [rowActs]),
        ]));
      });
    }
    vmTable.appendChild(vmTbody);

    wrapper.appendChild(el('div', {
      className: 'forge-card',
      style: staleCount > 0 ? 'border-color:rgba(248,113,113,0.55);' : undefined,
    }, [
      el('div', { className: 'forge-card-head' }, [
        el('div', {}, [
          el('div', { className: 'guild-card-title', text: `COLAB GPU FLEET & STALE VM GUARD (${csRows.length} VM${csRows.length === 1 ? '' : 's'} · ${staleCount} STALE)` }),
          el('div', { className: 'guild-card-meta', text: 'Each parallel SFT/DPO track uses 1 Colab VM. Click SCAN LIVE GPUs to probe nvidia-smi & training PIDs, or CULL stale/orphaned VMs so idle GPUs never burn Compute Units.' }),
        ]),
        el('div', { style: 'display:flex;gap:6px;flex-wrap:wrap;align-items:center;' }, [
          el('button', {
            type: 'button',
            className: 'guild-btn',
            disabled: state.colabScanning,
            text: state.colabScanning ? 'SCANNING...' : 'SCAN LIVE GPUs',
            on: { click: () => loadColabSessions(true) },
          }),
          el('button', {
            type: 'button',
            className: 'guild-btn danger',
            disabled: staleCount === 0 || state.colabScanning,
            text: armAll ? `CONFIRM CULL ${staleCount} STALE` : `CULL ALL STALE (${staleCount})`,
            on: {
              click: () => {
                if (!armAll) {
                  state.armedCullTarget = '__ALL_STALE__';
                  setConsole(`Armed to cull ${staleCount} stale/orphaned Colab VM(s). Active training VMs will NOT be touched. Click again to confirm.`);
                  renderForge();
                } else {
                  cullColabTarget(null, true);
                }
              },
            },
          }),
        ]),
      ]),
      el('div', { style: 'overflow-x:auto;' }, [vmTable]),
    ]));

    if (state.streamRun) {
      const sd = state.streamData || {};
      const gpu = sd.gpu;
      const prog = sd.progress || {};
      const gpuLabel = gpu
        ? `${gpu.name} · ${(gpu.used_mb / 1024).toFixed(1)} / ${(gpu.total_mb / 1024).toFixed(1)} GiB · ${gpu.util_pct}% GPU`
        : (sd.selected_gpu ? `${sd.selected_gpu} (probing telemetry...)` : 'GPU telemetry unavailable');
      const pct = prog.pct != null ? prog.pct : 0;
      const progText = prog.step != null
        ? `Step ${prog.step} / ${prog.total_steps} (${pct}%) · ${prog.speed || '—'} · ETA ${prog.eta || '—'}${prog.loss != null ? ` · Loss ${prog.loss}` : ''}`
        : `Exit/State: ${sd.exit_code || 'connecting'} · Source: ${sd.source || 'live'}${sd.ts ? ` · Updated ${sd.ts}` : ''}`;

      const trackPills = el('div', { style: 'display:flex;flex-wrap:wrap;gap:6px;align-items:center;' }, (sd.tracks || []).map((tn) => el('button', {
        type: 'button',
        className: 'guild-btn ' + (sd.track === tn ? 'primary' : ''),
        style: 'padding:3px 9px;font-size:11px;',
        text: tn,
        on: {
          click: () => {
            state.streamTrack = tn;
            fetchStreamLogs(state.streamRun, tn);
          },
        },
      })));

      const barFill = el('div', {
        style: `height:100%;width:${Math.max(0, Math.min(100, pct))}%;background:linear-gradient(90deg,#38bdf8,#34d399);transition:width 0.3s;`,
      });

      wrapper.appendChild(el('div', { className: 'forge-card', style: 'border-color:rgba(56,189,248,0.45);' }, [
        el('div', { className: 'forge-card-head' }, [
          el('div', {}, [
            el('div', { className: 'guild-card-title', text: `LIVE TRAINING STREAM // ${state.streamRun} (${sd.track || state.streamTrack || 'default'})` }),
            el('div', { className: 'guild-card-meta', text: `${gpuLabel}  |  ${progText}` }),
          ]),
          el('div', { style: 'display:flex;gap:6px;align-items:center;' }, [
            el('button', {
              type: 'button',
              className: 'guild-btn ' + (state.streamAuto ? 'primary' : ''),
              style: 'padding:4px 9px;font-size:11px;',
              text: state.streamAuto ? 'AUTO-STREAM: ON (12s)' : 'AUTO-STREAM: PAUSED',
              on: { click: () => { state.streamAuto = !state.streamAuto; renderForge(); } },
            }),
            el('button', {
              type: 'button', className: 'guild-btn', style: 'padding:4px 9px;font-size:11px;', text: 'PULL NOW',
              on: { click: () => fetchStreamLogs(state.streamRun, state.streamTrack) },
            }),
            el('button', {
              type: 'button', className: 'guild-btn danger', style: 'padding:4px 9px;font-size:11px;', text: 'CLOSE',
              on: { click: () => { stopStreamTimer(); state.streamRun = null; state.streamData = null; renderForge(); } },
            }),
          ]),
        ]),
        trackPills,
        el('div', { style: 'height:8px;width:100%;background:rgba(15,23,42,0.85);border-radius:4px;overflow:hidden;border:1px solid rgba(148,163,184,0.2);' }, [barFill]),
        sd.live_error ? el('div', { style: 'color:#fbbf24;font-size:11px;font-family:var(--font-mono);', text: `Notice: ${sd.live_error}` }) : null,
        el('pre', {
          id: 'forgeLiveStreamPre',
          className: 'eco-console',
          style: 'max-height:300px;overflow:auto;background:#020617;color:#e2e8f0;font-size:11px;line-height:1.45;white-space:pre-wrap;',
          text: sd.log_tail || '(no log lines emitted yet)',
        }),
      ]));
    }
    return wrapper;
  }

  function renderLaunchTab(d) {
    const playbooks = d.playbooks || [];
    const prereqs = d.prerequisites || {};

    const runNameIn = el('input', { type: 'text', className: 'guild-input', value: 'gemma4-sleep-v1' });
    const roleSel = el('select', { className: 'guild-input' }, [
      el('option', { value: 'core-agent', text: 'core-agent (Primary ReAct Workbench)' }),
      el('option', { value: 'sdr-p25', text: 'sdr-p25 (SDR P25 Trunked Radio Narrative)' }),
      el('option', { value: 'code-ops', text: 'code-ops (Remediation & GitOps)' }),
      el('option', { value: 'research', text: 'research (Deep Research Synthesis)' }),
    ]);
    const baseModelIn = el('input', { type: 'text', className: 'guild-input', value: 'google/gemma-4-31b-it' });
    const baseSourceSel = el('select', { className: 'guild-input' }, [
      el('option', { value: 'hf_direct', text: 'Hugging Face Direct (Fastest on slow upload)' }),
      el('option', { value: 'local_upload', text: 'Upload Local Weights (HF-Independent)' }),
      el('option', { value: 'drive_mirror', text: 'Mount Google Drive Mirror' }),
    ]);
    const backendSel = el('select', { className: 'guild-input' }, [
      el('option', { value: 'colab', text: 'Google Colab Fleet (1-3x GPU w/ H100→G4→A100→L4→T4 fallback)' }),
      el('option', { value: 'local', text: 'Local GPU (Contention-safe auto-pause inference)' }),
    ]);
    const gpuSel = el('select', { className: 'guild-input' }, [
      el('option', { value: 'A100', text: 'A100 (80GB/40GB) → Fallback: H100/G4/L4/T4' }),
      el('option', { value: 'G4', text: 'G4 (96GB RTX PRO 6000 Blackwell)' }),
      el('option', { value: 'H100', text: 'H100 (80GB Hopper)' }),
      el('option', { value: 'L4', text: 'L4 (24GB Ada)' }),
      el('option', { value: 'T4', text: 'T4 (16GB Turing)' }),
    ]);
    const priorRange = el('input', { type: 'range', min: 0, max: 95, step: 5, value: 70 });
    const priorVal = el('span', { style: 'font-family:var(--font-mono);font-size:11px;color:#6ee7b7;', text: '70% prior active.gguf / 30% new tracks' });
    priorRange.addEventListener('input', () => {
      const p = Number(priorRange.value);
      priorVal.textContent = `${p}% prior active.gguf / ${100 - p}% new tracks`;
    });

    const recipes = ['persistence', 'multi-hop', 'error-recovery', 'tool-syntax', 'failure-modes', 'context-discrimination', 'gitops', 'sdr-p25'];
    const recipeCbs = {};
    const recipeRow = el('div', { style: 'display:flex;flex-wrap:wrap;gap:10px;' });
    recipes.forEach((r) => {
      const cb = el('input', { type: 'checkbox', checked: ['persistence', 'multi-hop', 'error-recovery', 'tool-syntax', 'failure-modes'].includes(r) });
      recipeCbs[r] = cb;
      recipeRow.appendChild(el('label', { className: 'eco-check-label' }, [cb, r]));
    });
    const jrnCb = el('input', { type: 'checkbox', checked: true });
    const pauseInfCb = el('input', { type: 'checkbox', checked: true });
    const countIn = el('input', { type: 'number', className: 'guild-input', style: 'width:100px;min-width:100px;', min: 20, max: 20000, value: 500 });

    const presetRow = el('div', { style: 'display:flex;flex-wrap:wrap;gap:6px;' });
    playbooks.forEach((pb) => {
      presetRow.appendChild(el('button', {
        type: 'button',
        className: 'guild-btn',
        text: `LOAD: ${pb.name.replace(/\.json$/, '')}`,
        on: {
          click: () => {
            const sp = pb.spec || {};
            if (sp.name) runNameIn.value = sp.name;
            if (sp.role) roleSel.value = sp.role;
            if (sp.base_model) baseModelIn.value = sp.base_model;
            if (sp.base_source) baseSourceSel.value = sp.base_source;
            if (sp.backend) backendSel.value = sp.backend;
            if (sp.colab && sp.colab.gpu) gpuSel.value = sp.colab.gpu;
            if (sp.merge && sp.merge.prior_adapter_weight != null) {
              priorRange.value = Math.round(sp.merge.prior_adapter_weight * 100);
              priorRange.dispatchEvent(new Event('input'));
            }
            setConsole(`Loaded preset playbook ${pb.path}`);
          },
        },
      }));
    });

    const launchBtn = el('button', { type: 'button', className: 'guild-btn primary', text: 'LAUNCH TRAINING RUN (--execute)' });
    const buildPayload = () => ({
      name: runNameIn.value.trim(),
      role: roleSel.value,
      base_model_path: baseModelIn.value.trim(),
      base_source: baseSourceSel.value,
      compute_target: backendSel.value,
      gpu: gpuSel.value,
      prior_adapter_weight: Number(priorRange.value) / 100.0,
      pause_inference: Boolean(pauseInfCb.checked),
      focus: Object.entries(recipeCbs).filter(([, cb]) => cb.checked).map(([k]) => k).join(','),
      sample_count: Number(countIn.value || 500),
      include_journal: Boolean(jrnCb.checked),
    });

    const preflightBtn = el('button', {
      type: 'button',
      className: 'guild-btn',
      text: 'FORGE DATASET & PREFLIGHT PLAN',
      on: {
        click: async () => {
          state.armedLaunch = false;
          launchBtn.textContent = 'LAUNCH TRAINING RUN (--execute)';
          setConsole('Forging leak-guarded SFT+DPO datasets and running preflight checks...');
          const { data } = await apiJson('/api/training/wizard', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(buildPayload()),
          });
          state.lastConfigPath = data.config_path || null;
          state.lastPreflight = data.preflight || null;
          setConsole(data);
        },
      },
    });

    launchBtn.addEventListener('click', async () => {
      if (!state.lastConfigPath) {
        setConsole('Click "FORGE DATASET & PREFLIGHT PLAN" first to build the leak-guarded dataset and verify prerequisites.');
        return;
      }
      if (!state.armedLaunch) {
        state.armedLaunch = true;
        launchBtn.textContent = 'CLICK AGAIN TO CONFIRM PROVISIONING';
        setConsole(`Armed to launch ${state.lastConfigPath} (backend=${backendSel.value}). Click LAUNCH again to provision.`);
        return;
      }
      state.armedLaunch = false;
      launchBtn.textContent = 'LAUNCHING...';
      launchBtn.disabled = true;
      try {
        const { data } = await apiJson('/api/training/run', {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ config: state.lastConfigPath, dry_run: false, execute: true }),
        });
        setConsole(data);
        await refreshAll();
      } finally {
        launchBtn.disabled = false;
        launchBtn.textContent = 'LAUNCH TRAINING RUN (--execute)';
      }
    });

    const nodes = [];
    if (!prereqs.colab_ready) {
      nodes.push(el('div', { className: 'forge-issue-row error' }, [
        el('div', { style: 'font-weight:700;font-size:11px;', text: 'Colab / Google ADC is not yet configured on this node — Colab launches will fail preflight until ADC or OAuth2 is authenticated (see Overview tab for copyable setup commands).' }),
      ]));
    }

    nodes.push(el('div', { className: 'forge-card' }, [
      el('div', { className: 'guild-card-title', text: 'PRESET PLAYBOOKS' }),
      presetRow,
      el('div', { className: 'forge-form-grid', style: 'margin-top:8px;' }, [
        el('div', {}, [el('div', { className: 'eco-kpi-label', text: 'RUN NAME' }), runNameIn]),
        el('div', {}, [el('div', { className: 'eco-kpi-label', text: 'TARGET ROLE' }), roleSel]),
        el('div', {}, [el('div', { className: 'eco-kpi-label', text: 'BASE MODEL (HF REPO ID)' }), baseModelIn]),
        el('div', {}, [el('div', { className: 'eco-kpi-label', text: 'BASE MODEL SOURCE' }), baseSourceSel]),
        el('div', {}, [el('div', { className: 'eco-kpi-label', text: 'COMPUTE BACKEND' }), backendSel]),
        el('div', {}, [el('div', { className: 'eco-kpi-label', text: 'PREFERRED COLAB GPU' }), gpuSel]),
      ]),
      el('div', { style: 'margin-top:6px;' }, [
        el('div', { className: 'eco-kpi-label', text: 'DATASET FORGE RECIPES (BENCHMARK LEAK-GUARDED)' }),
        recipeRow,
      ]),
      el('div', { style: 'display:flex;flex-wrap:wrap;gap:14px;align-items:center;margin-top:6px;' }, [
        el('div', { style: 'display:flex;align-items:center;gap:6px;' }, [el('span', { className: 'eco-kpi-label', text: 'SAMPLES:' }), countIn]),
        el('label', { className: 'eco-check-label' }, [jrnCb, 'Include Sleep-Cycle Journal / Memories Replay']),
        el('label', { className: 'eco-check-label' }, [pauseInfCb, 'Auto-pause local inference during local GPU training']),
      ]),
      el('div', { style: 'display:flex;flex-wrap:wrap;gap:10px;align-items:center;margin-top:6px;' }, [
        el('span', { className: 'eco-kpi-label', text: 'SVD-32 RETENTION WEIGHT:' }),
        priorRange,
        priorVal,
      ]),
      el('div', { style: 'display:flex;gap:10px;margin-top:10px;' }, [preflightBtn, launchBtn]),
    ]));

    return el('div', { style: 'display:flex;flex-direction:column;gap:10px;' }, nodes);
  }

  function renderAdaptersTab(d) {
    const adapters = Array.isArray(d.adapters) ? d.adapters : [];
    const epIn = el('input', { type: 'text', className: 'guild-input', value: 'http://127.0.0.1:8080' });
    const scalesIn = el('input', { type: 'text', className: 'guild-input', style: 'flex:1;', value: '[{"id":0,"scale":1.0}]' });

    const hotCard = el('div', { className: 'forge-card' }, [
      el('div', { className: 'guild-card-title', text: 'LIVE SVD / LORA HOT-SWAPPER (POST /lora-adapters · 0ms RESTART)' }),
      el('div', { className: 'guild-card-meta', text: 'Dynamically switch or blend preloaded role adapters on stock llama-server without restarting inference.' }),
      el('div', { style: 'display:flex;flex-wrap:wrap;gap:8px;align-items:center;' }, [
        epIn, scalesIn,
        el('button', {
          type: 'button', className: 'guild-btn primary', text: 'APPLY SCALES',
          on: {
            click: async () => {
              let parsed;
              try { parsed = JSON.parse(scalesIn.value); } catch (e) { setConsole('Invalid JSON scales array: ' + e.message); return; }
              const { data } = await apiJson('/api/training/adapters/hotswap', {
                method: 'POST', headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ endpoint: epIn.value.trim(), scales: parsed }),
              });
              setConsole(data);
            },
          },
        }),
      ]),
    ]);

    const bkpCard = el('div', { className: 'forge-card' }, [
      el('div', { className: 'forge-card-head' }, [
        el('div', {}, [
          el('div', { className: 'guild-card-title', text: 'SVD-32 LINEAGE LIBRARY & CLOUD BACKUPS' }),
          el('div', { className: 'guild-card-meta', text: 'Organized as MODELS_DIR/adapters/<model_slug>/<role>/{active.gguf, releases/, lineage.json}' }),
        ]),
        el('div', { style: 'display:flex;gap:6px;flex-wrap:wrap;' }, [
          el('button', {
            type: 'button', className: 'guild-btn', text: 'BACKUP -> GOOGLE DRIVE',
            on: { click: async () => { setConsole('Backing up adapters to Google Drive...'); const { data } = await apiJson('/api/training/backup', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ target: 'drive' }) }); setConsole(data); } },
          }),
          el('button', {
            type: 'button', className: 'guild-btn', text: 'BACKUP -> PRIVATE HF',
            on: { click: async () => { setConsole('Backing up adapters to Private Hugging Face Hub...'); const { data } = await apiJson('/api/training/backup', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ target: 'hf' }) }); setConsole(data); } },
          }),
        ]),
      ]),
    ]);

    if (adapters.length === 0) {
      bkpCard.appendChild(el('div', { className: 'guild-card-meta', text: 'No SVD-32 lineage directories found yet under MODELS_DIR/adapters/.' }));
    } else {
      const list = el('div', { style: 'display:flex;flex-direction:column;gap:8px;' });
      adapters.forEach((a) => {
        const rels = (a.releases || []).map((r) => `${r.version || '?'} (${r.file || ''})`).join(' → ');
        list.appendChild(el('div', { className: 'eco-file-row' }, [
          el('div', {}, [
            el('div', { style: 'font-weight:700;color:#f8fafc;font-size:12px;', text: `${a.model_slug}  //  role: ${a.role}` }),
            el('div', { className: 'guild-card-meta', text: `Active: ${a.active_version || 'none'} · Releases: ${rels || 'none'}` }),
          ]),
          el('span', { className: 'guild-badge ' + (a.active_version ? 'on' : 'off'), text: `${(a.releases || []).length} release(s)` }),
        ]));
      });
      bkpCard.appendChild(list);
    }

    return el('div', { style: 'display:flex;flex-direction:column;gap:12px;' }, [hotCard, bkpCard]);
  }

  function renderBenchTab(d) {
    const scs = d.scorecards || [];
    const selA = el('select', { className: 'guild-input', style: 'flex:1;' });
    const selB = el('select', { className: 'guild-input', style: 'flex:1;' });
    scs.forEach((s) => {
      const lbl = `${s.model_label} (${s.overall_score}%${s.early_quit_rate_pct != null ? `, EQ:${s.early_quit_rate_pct}%` : ''}) — ${s.file}`;
      selA.appendChild(el('option', { value: s.file, text: lbl }));
      selB.appendChild(el('option', { value: s.file, text: lbl }));
    });
    if (scs.length > 1) selB.selectedIndex = 1;

    const lblIn = el('input', { type: 'text', className: 'guild-input', value: 'gemma4-31b-live' });
    const famSel = el('select', { className: 'guild-input' }, [
      el('option', { value: 'auto', text: 'Auto-detect family' }),
      el('option', { value: 'gemma4', text: 'Gemma-4' }),
      el('option', { value: 'qwen', text: 'Qwen 3.8 / 3.5' }),
    ]);

    const card = el('div', { className: 'forge-card' }, [
      el('div', { className: 'guild-card-title', text: '7-PILLAR MULTI-TURN & PERSISTENCE BENCHMARK' }),
      el('div', { style: 'display:flex;flex-wrap:wrap;gap:8px;align-items:center;' }, [
        lblIn, famSel,
        el('button', {
          type: 'button', className: 'guild-btn primary', text: 'RUN LIVE 7-PILLAR BENCHMARK',
          on: {
            click: async () => {
              const { data } = await apiJson('/api/training/benchmark', {
                method: 'POST', headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ mode: 'run', label: lblIn.value.trim(), model_family: famSel.value }),
              });
              setConsole(data);
            },
          },
        }),
      ]),
      el('div', { className: 'guild-card-title', style: 'margin-top:8px;', text: 'HEAD-TO-HEAD COMPARISON (e.g. GEMMA-4 31B vs QWEN 3.8 27B)' }),
      el('div', { style: 'display:flex;flex-wrap:wrap;gap:8px;align-items:center;' }, [
        selA, el('span', { text: 'vs' }), selB,
        el('button', {
          type: 'button', className: 'guild-btn', text: 'COMPARE HEAD-TO-HEAD', disabled: scs.length < 2,
          on: {
            click: async () => {
              const { data } = await apiJson('/api/training/benchmark', {
                method: 'POST', headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ mode: 'head_to_head', file_a: selA.value, file_b: selB.value }),
              });
              state.h2hResult = data;
              setConsole(data);
              renderForge();
            },
          },
        }),
      ]),
    ]);

    if (state.h2hResult && state.h2hResult.pillars) {
      const h = state.h2hResult;
      const tbl = el('table', { className: 'forge-table', style: 'margin-top:8px;' }, [
        el('thead', {}, [el('tr', {}, [
          el('th', { text: 'PILLAR' }),
          el('th', { text: h.baseline_label || 'Model A' }),
          el('th', { text: h.candidate_label || 'Model B' }),
          el('th', { text: 'DELTA' }),
        ])]),
      ]);
      const tb = el('tbody');
      Object.entries(h.pillars).forEach(([p, vals]) => {
        tb.appendChild(el('tr', {}, [
          el('td', { text: p }),
          el('td', { text: `${vals.baseline}%` }),
          el('td', { text: `${vals.candidate}%` }),
          el('td', { style: `font-weight:700;color:${vals.delta >= 0 ? '#34d399' : '#f87171'};`, text: `${vals.delta >= 0 ? '+' : ''}${vals.delta}%` }),
        ]));
      });
      tb.appendChild(el('tr', {}, [
        el('td', { style: 'font-weight:700;', text: 'COMPOSITE SCORE' }),
        el('td', { style: 'font-weight:700;', text: `${h.baseline_score}%` }),
        el('td', { style: 'font-weight:700;', text: `${h.candidate_score}%` }),
        el('td', { style: `font-weight:700;color:${h.composite_delta >= 0 ? '#34d399' : '#f87171'};`, text: `${h.composite_delta >= 0 ? '+' : ''}${h.composite_delta}%` }),
      ]));
      tbl.appendChild(tb);
      card.appendChild(tbl);
    }

    return card;
  }

  function renderManualTab() {
    const cmdBlock = (title, note, cmd) => el('div', {
      style: 'background:rgba(2,6,23,0.75);border:1px solid rgba(148,163,184,0.22);border-radius:8px;padding:10px 12px;display:flex;flex-direction:column;gap:6px;',
    }, [
      el('div', { style: 'display:flex;justify-content:space-between;align-items:center;gap:8px;' }, [
        el('div', { style: 'font-weight:700;color:#e2e8f0;font-size:12px;', text: title }),
        el('button', {
          type: 'button',
          className: 'guild-btn',
          style: 'padding:2px 8px;font-size:10px;',
          text: 'COPY',
          on: {
            click: () => {
              if (navigator.clipboard) navigator.clipboard.writeText(cmd).catch(() => {});
              setConsole(`Copied to clipboard:\n${cmd}`);
            },
          },
        }),
      ]),
      note ? el('div', { className: 'guild-card-meta', text: note }) : null,
      el('pre', {
        style: 'margin:0;padding:8px;background:#020617;color:#7dd3fc;border-radius:6px;font-family:var(--font-mono);font-size:11px;white-space:pre-wrap;overflow-x:auto;',
        text: cmd,
      }),
    ]);

    const section = (heading, subtitle, items) => el('div', { className: 'forge-card' }, [
      el('div', { className: 'forge-card-head' }, [
        el('div', {}, [
          el('div', { className: 'guild-card-title', text: heading }),
          subtitle ? el('div', { className: 'guild-card-meta', text: subtitle }) : null,
        ]),
      ]),
      el('div', { style: 'display:flex;flex-direction:column;gap:10px;' }, items),
    ]);

    const menuRow = (name, desc) => el('div', {
      style: 'display:grid;grid-template-columns:195px 1fr;gap:10px;padding:6px 0;border-bottom:1px solid rgba(148,163,184,0.12);font-size:12px;',
    }, [
      el('div', { style: 'font-weight:700;color:#38bdf8;font-family:var(--font-mono);', text: name }),
      el('div', { style: 'color:#cbd5e1;line-height:1.45;', text: desc }),
    ]);

    const setupCard = section(
      '1. ONE-TIME MANUAL SETUP (HOST MACHINE)',
      'Run these commands once on the node running Blue Lodge. Credentials mount read-only into K8s automatically.',
      [
        cmdBlock(
          'Step A — Install Google Cloud CLI (zero-sudo Linux tarball)',
          'Required only if gcloud is not yet installed on the host.',
          'curl -fsSL https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz | tar -xz -C "$HOME"\n"$HOME/google-cloud-sdk/install.sh" --quiet --path-update true',
        ),
        cmdBlock(
          'Step B — Authenticate Google ADC with Colab + Headless Google Drive Scope',
          'Adding drive.file eliminates Colab interactive Drive popups and lets remote Colab VMs mirror extracted adapter.gguf + safetensors directly to Google Drive/BlueLodge/training/ even if this PC turns off.',
          '~/google-cloud-sdk/bin/gcloud auth application-default login --no-launch-browser \\\n  --scopes="openid,https://www.googleapis.com/auth/userinfo.email,https://www.googleapis.com/auth/cloud-platform,https://www.googleapis.com/auth/drive.file"',
        ),
        cmdBlock(
          'Step C — Set ADC Quota Project (required whenever you re-run Step B)',
          'Replace YOUR_GCP_PROJECT_ID with your active Google Cloud project ID (find it via `gcloud projects list`). Note: re-running ADC login resets the quota project, so run this right after Step B.',
          '~/google-cloud-sdk/bin/gcloud auth application-default set-quota-project YOUR_GCP_PROJECT_ID',
        ),
        cmdBlock(
          'Step D — Add Hugging Face Token (Gated Models & Private Backups)',
          'Required to pull gated HF weights (e.g. google/gemma-4-31b-it) directly inside Colab or push private HF Hub backups.',
          'echo \'HF_TOKEN="hf_your_token_here"\' >> .george/keys.conf',
        ),
        cmdBlock(
          'Step E — Verify Readiness & Colab Compute Units',
          'Confirm colab_ready: true, ADC Drive scope, HF token, and CU balance. All green chips appear in Overview.',
          '.venv/bin/python scripts/training/check_credits.py --json',
        ),
      ],
    );

    const forgeMenusCard = section(
      '2. USING THE TRAINING FORGE TABS',
      'End-to-end workflow from transcript mining to Tier B approval and live zero-restart hot-swapping.',
      [
        menuRow('Overview & Sleep Cycle', 'Shows Colab Compute Unit balance, prerequisite health chips, and Sleep-Cycle policy. Toggle between Tier B (human Accept/Deny gate in Forge + Discord — default) and Tier A (auto-promote only when 7-pillar score improves by >= Min Delta %). Configure Google Drive folder and private HF backup repo here.'),
        menuRow('Tier B Gate & Runs', 'Displays every active and historical run with GPU tier, prior-adapter retention weight, 7-pillar score delta, and Gate status. Click LIVE LOGS on any run to stream real-time Colab or local GPU VRAM/utilization, step progress bar, ETA, and scrolling train.log (auto-refreshes every 12s). Use COLLECT, RESUME, MERGE SVD-32, ACCEPT, or DENY directly from each row.'),
        menuRow('Playbook & Launch', 'Pick a curated JSON playbook (Gemma-4 31B, Qwen 3.8 27B, SDR E4B, or Local QLoRA Sleep) or customize focus recipes (e.g. persistence,tool-syntax,error-recovery,multi-hop,final-answer + journal dream replay). Choose base_source (HF Direct vs. Local Upload vs. Drive Mirror). Click PREFLIGHT to validate before arming and launching.'),
        menuRow('SVD Layers & Backups', 'Inspect every namespaced (model_slug, role) adapter under MODELS_DIR/adapters/<model>/<role>/. Adjust per-adapter scales and click HOT-SWAP to call stock llama-server POST /lora-adapters with ZERO server restart. Trigger on-demand backups to Google Drive and/or private Hugging Face Hub.'),
        menuRow('Head-to-Head Benchmarks', 'Launch the 7-Pillar Multi-Turn Sovereign Benchmark (35 scenarios including Pillar 7 Multi-Step Persistence & Early-Quit Rate) against your live inference server, or compare any two saved scorecards (e.g. Gemma-4 31B vs. Qwen 3.8 27B) side-by-side by pillar.'),
        menuRow('Autonomic Watchdog', 'scripts/cron_system/training_watchdog.sh (# ENABLED: 1, every 600s) keeps Colab VMs alive, auto-resumes 1h disconnects, downloads finished adapters, detects stale/orphaned Colab GPUs (sending a Discord Tier B cull alert), merges SVD-32 with retention weighting, and posts Discord Tier B approval cards.'),
        menuRow('Stale Colab GPU Guard', 'In Runs & Tier B Gate, inspect live Colab VMs mapped 1:1 to parallel SFT/DPO tracks. Click SCAN LIVE GPUs to probe nvidia-smi + training PIDs, or use two-click CULL VM / CULL ALL STALE (or `/train sessions` and `/train cull <endpoint|all-stale>`) so abandoned GPUs stop burning Compute Units.'),
      ],
    );

    const modelSelectorCard = section(
      '3. MODEL SELECTOR, WORKBENCH & MoE / SMALL MODEL SWITCHING',
      'Base GGUF switching and SVD-32 adapter switching are decoupled so dense, small, and MoE models never collide.',
      [
        menuRow('Models Button (/models)', 'Open the Models panel in the header (or run `/models` in CLI) to search Hugging Face/ModelScope, check VRAM fit tables (`/models fit`), SHA-256 download (`/models install`), and switch the active base GGUF (`/models activate <profile>`). Supports smaller dense models and MoE models (such as gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf).'),
        menuRow('Rollback Protection', 'If a newly activated model fails to load or underperforms, click Rollback in the Models panel or run `/models rollback` to instantly restore the previous active GGUF symlink.'),
        menuRow('Symlink & Adapter Layout', 'Active base weights resolve via MODELS_DIR/active/current/base.gguf (or K8s profile env). Fine-tuned SVD-32 layers live in MODELS_DIR/adapters/<model_slug>/<role>/active.gguf (with releases/, candidates/, and lineage.json), so switching base models never overwrites another model\'s adapters.'),
        menuRow('Colab GPU Fallback Order', '27B-31B playbooks lock a 40 GB VRAM floor and automatically cascade H100 (80 GB) -> A100 High-RAM (80 GB) -> A100 Standard (40/80 GB) -> G4 (96 GB Blackwell RTX PRO 6000) with exponential-backoff 503 retries. Smaller/role playbooks (e.g. Gemma-4 E4B SDR) also permit L4 (24 GB) and T4 (16 GB).'),
        menuRow('Local Contention Safety', 'Running a Local QLoRA playbook automatically acquires a cooperative GPU lease that scales down george-inference while training runs and restores it via an EXIT/INT/TERM trap as soon as training finishes or aborts.'),
      ],
    );

    return el('div', { style: 'display:flex;flex-direction:column;gap:12px;' }, [
      setupCard,
      forgeMenusCard,
      modelSelectorCard,
    ]);
  }

  function renderPersistentHeader(d) {
    const credits = d.credits || {};
    const prereqs = d.prerequisites || {};
    const policy = d.policy || {};
    const history = (d.gate_queue && d.gate_queue.history) || [];
    const pending = (d.gate_queue && d.gate_queue.pending) || [];
    const runningRuns = history.filter((r) => r.state === 'running');
    const activeCount = runningRuns.length;
    const activeTracks = runningRuns.reduce((sum, r) => {
      const tObj = r.tracks && typeof r.tracks === 'object' ? Object.values(r.tracks) : [];
      const runningT = tObj.filter((t) => t && t.state === 'running').length;
      if (runningT > 0) return sum + runningT;
      const g = Array.isArray(r.selected_gpus) ? r.selected_gpus.length : 0;
      return sum + (g > 0 ? g : 1);
    }, 0);
    const cs = state.colabSessions || {};
    const staleCount = Number(cs.stale_count || 0);
    const vmCount = cs.total != null ? cs.total : (credits.active_assignments || 0);

    const badge = document.getElementById('wbFleetCount');
    if (badge) {
      const n = activeCount + pending.length + staleCount;
      badge.textContent = String(n);
      badge.hidden = n === 0;
    }

    const cuTxt = credits.balance != null
      ? `${credits.balance} CU (${vmCount} VMs${staleCount > 0 ? ` · ${staleCount} STALE` : ''})`
      : (prereqs.colab_ready ? 'Probing Colab…' : 'ADC Setup Needed');
    const postureTxt = policy.autonomy_tier === 'tier_a'
      ? `TIER A AUTO (>= +${policy.tier_a_min_delta ?? 3}%)`
      : 'TIER B HUMAN GATE';

    return el('div', { className: 'forge-kpi-grid' }, [
      el('div', { className: 'forge-kpi-box' }, [
        el('div', { className: 'hub-label', text: 'COLAB COMPUTE' }),
        el('div', { style: `font-weight:700;font-size:13px;font-family:var(--font-mono);${staleCount > 0 ? 'color:#f87171;' : ''}`, text: cuTxt }),
      ]),
      el('div', { className: 'forge-kpi-box' }, [
        el('div', { className: 'hub-label', text: 'ACTIVE RUNS & TRACKS' }),
        el('div', { style: 'font-weight:700;font-size:13px;font-family:var(--font-mono);', text: `${activeCount} runs (${activeTracks} tracks) · ${history.length} total` }),
      ]),
      el('div', { className: 'forge-kpi-box' }, [
        el('div', { className: 'hub-label', text: 'TIER B QUEUE' }),
        el('div', { style: 'font-weight:700;font-size:13px;font-family:var(--font-mono);', text: `${pending.length} pending approval` }),
      ]),
      el('div', { className: 'forge-kpi-box' }, [
        el('div', { className: 'hub-label', text: 'AUTONOMY POSTURE' }),
        el('div', { style: 'font-weight:700;font-size:13px;font-family:var(--font-mono);', text: postureTxt }),
      ]),
    ]);
  }

  function renderForge() {
    const root = document.getElementById('trainingForgeRoot');
    if (!root) return;
    const d = state.data || {};
    const pending = ((d.gate_queue && d.gate_queue.pending) || []).length;

    const tabs = [
      { id: 'gate', label: `RUNS & TIER B GATE${pending > 0 ? ` (${pending})` : ''}` },
      { id: 'overview', label: 'SLEEP POLICY & PREREQS' },
      { id: 'launch', label: 'PLAYBOOK & LAUNCH' },
      { id: 'adapters', label: 'SVD LAYERS & BACKUPS' },
      { id: 'bench', label: '7-PILLAR BENCHMARKS' },
      { id: 'manual', label: 'MANUAL & SETUP' },
    ];
    const tabBar = el('div', { className: 'models-filter-bar', style: 'margin-bottom:0;' }, [
      el('div', { className: 'model-filter-btns' }, tabs.map((t) => el('button', {
        type: 'button',
        className: 'model-filter-btn' + (state.activeTab === t.id ? ' active' : ''),
        text: t.label,
        on: { click: () => { state.activeTab = t.id; renderForge(); } },
      }))),
      el('button', {
        type: 'button',
        className: 'tactile-btn',
        text: 'REFRESH FLEET',
        on: { click: refreshAll },
      }),
    ]);

    let panel;
    if (state.activeTab === 'gate') panel = renderGateTab(d);
    else if (state.activeTab === 'launch') panel = renderLaunchTab(d);
    else if (state.activeTab === 'adapters') panel = renderAdaptersTab(d);
    else if (state.activeTab === 'bench') panel = renderBenchTab(d);
    else if (state.activeTab === 'manual') panel = renderManualTab();
    else panel = renderOverviewTab(d);

    root.replaceChildren(
      renderPersistentHeader(d),
      tabBar,
      panel,
      el('div', { style: 'margin-top:4px;' }, [
        el('div', { className: 'hub-label', text: 'TRAINING FLEET CONSOLE' }),
        el('pre', { id: 'forgeStudioConsole', className: 'hub-pre', style: 'max-height:140px;overflow:auto;', text: state.consoleText }),
      ]),
    );
  }

  function onShow() {
    renderForge();
    refreshAll();
  }

  function onHide() {
    stopStreamTimer();
  }

  function openForgeModal() {
    const mm = document.getElementById('modelsModal');
    if (mm) {
      mm.style.display = 'flex';
      mm.classList.add('open');
    }
    const tab = document.getElementById('wbTabFleet');
    if (tab) tab.click();
    else onShow();
  }

  function closeForgeModal() {
    onHide();
  }

  function bindModal() {
    // Also refresh fleet badge softly if Models modal opens
    const btnModelsRefresh = document.getElementById('btnModelsRefresh');
    if (btnModelsRefresh) {
      btnModelsRefresh.addEventListener('click', () => {
        const p = document.getElementById('wbPanelFleet');
        if (p && !p.hidden) refreshAll();
      });
    }
  }

  window.LodgeForge = { open: openForgeModal, close: closeForgeModal, refresh: refreshAll, onShow, onHide };
  window.LodgeOpenForge = openForgeModal;

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', bindModal);
  else bindModal();
})();
