// ============================================================================
// GEORGE // Model Workbench
// The operator's own GGUF library first: every card is a file on disk, read from
// its GGUF metadata. Nothing here is curated or hardcoded: no suggested models,
// no assumed context sizes. Discover → fit → approve → download (sha256-verified)
// lands files in the library; Serve turns any library file into a pinned profile.
// All dynamic content is built with DOM APIs + textContent (no innerHTML).
// Mutating calls are token-gated server-side; session.js attaches the token.
// ============================================================================
(function () {
  'use strict';

  const $ = (id) => document.getElementById(id);
  const modal = $('modelsModal');
  if (!modal || !$('hubSection')) return;

  const NAME_RE = /^[a-z0-9][a-z0-9._-]{1,63}$/;
  const state = {
    lib: null, profiles: [], server: null, reviewing: null, polls: {}, askTimer: null,
    jobsTimer: null, loaded: false, kind: 'all', q: '', sort: 'name', open: false,
  };

  // ── DOM helpers ───────────────────────────────────────────────────────────
  function el(tag, opts, children) {
    const n = document.createElement(tag);
    if (opts) {
      if (opts.text != null) n.textContent = String(opts.text);
      if (opts.cls) n.className = opts.cls;
      if (opts.id) n.id = opts.id;
      if (opts.title) n.title = opts.title;
      if (opts.type) n.type = opts.type;
      if (opts.value != null) n.value = String(opts.value);
      if (opts.attrs) Object.entries(opts.attrs).forEach(([k, v]) => n.setAttribute(k, String(v)));
      if (opts.onclick) n.addEventListener('click', opts.onclick);
    }
    (children || []).forEach((c) => { if (c != null) n.append(c); });
    return n;
  }
  function btn(text, onclick, cls, title) {
    return el('button', { cls: `tactile-btn ${cls || ''}`.trim(), type: 'button', text, onclick, title });
  }
  function clear(node) { while (node && node.firstChild) node.removeChild(node.firstChild); }
  function option(value, text, selected) {
    const o = el('option', { value, text });
    if (selected) o.selected = true;
    return o;
  }
  function field(label, input) { return el('label', { cls: 'wb-field' }, [label, input]); }
  function log(msg) {
    const area = $('hubLog');
    const ts = new Date().toLocaleTimeString();
    area.textContent = `[${ts}] ${msg}\n` + area.textContent.split('\n').slice(0, 60).join('\n');
  }
  function mb(n) {
    if (n == null) return '—';
    return n >= 1024 ? `${(n / 1024).toFixed(1)} GB` : `${n} MB`;
  }
  function bytes(n) {
    if (!n) return '0 B';
    if (n < 1048576) return `${Math.max(1, Math.round(n / 1024))} KB`;
    return mb(Math.round(n / 1048576));
  }
  function ctxLabel(n) {
    if (!n) return '?';
    return n >= 1024 ? `${Math.round(n / 1024)}K` : String(n);
  }
  function slug(file) {
    let s = String(file || '').replace(/\.gguf$/i, '').replace(/-0+1-of-\d+$/i, '').toLowerCase()
      .replace(/[^a-z0-9._-]+/g, '-').replace(/^[-._]+|[-._]+$/g, '').slice(0, 60);
    if (s.length < 2) s = `local-${s || 'model'}`;
    if (!/^[a-z0-9]/.test(s)) s = `m${s}`.slice(0, 64);
    return s;
  }
  /** Two-click confirm: first click arms (label changes), second within 5 s runs. */
  function confirmBtn(text, confirmText, run, cls) {
    let armed = null;
    const b = btn(text, async () => {
      if (!armed) {
        b.textContent = confirmText; b.classList.add('danger');
        armed = setTimeout(() => { armed = null; b.textContent = text; b.classList.remove('danger'); }, 5000);
        return;
      }
      clearTimeout(armed); armed = null; b.textContent = text; b.classList.remove('danger');
      b.disabled = true;
      try { await run(); } finally { b.disabled = false; }
    }, cls);
    return b;
  }

  async function api(method, url, body) {
    const opts = { method, headers: {} };
    if (body !== undefined) {
      opts.headers['Content-Type'] = 'application/json';
      opts.body = JSON.stringify(body);
    }
    let res;
    try { res = await fetch(url, opts); } catch (e) { throw new Error(`network: ${e.message}`); }
    let data = null;
    try { data = await res.json(); } catch (_) { /* empty body */ }
    if (!res.ok || (data && (data.error || data.status === 'error'))) {
      throw new Error((data && (data.error || data.message)) || `HTTP ${res.status}`);
    }
    return data;
  }

  // ── Modal + tabs ──────────────────────────────────────────────────────────
  function openModal() {
    modal.style.display = 'flex';
    modal.classList.add('open');
    state.open = true;
    if (!state.loaded) { state.loaded = true; refreshAll(); } else { loadServer(); loadJobs(); }
  }
  function closeModal() {
    modal.classList.remove('open');
    modal.style.display = 'none';
    state.open = false;
  }
  function showTab(panelId) {
    document.querySelectorAll('.wb-tab').forEach((t) => {
      const on = t.dataset.panel === panelId;
      t.classList.toggle('active', on);
      t.setAttribute('aria-selected', on ? 'true' : 'false');
    });
    document.querySelectorAll('.wb-panel').forEach((p) => { p.hidden = p.id !== panelId; });
    if (panelId === 'wbPanelTrain') loadTrain();
  }

  // ── Hardware ──────────────────────────────────────────────────────────────
  async function loadHw() {
    try {
      const hw = await api('GET', '/api/hub/hw');
      const gpus = (hw.gpus || []).map((g) => `${g.name} ${mb(g.vram_total_mb)}`).join(' + ') || 'no GPU detected';
      $('hubHwLine').textContent = `${(hw.gpu_backend || 'cpu').toUpperCase()} · ${gpus} · RAM ${mb(hw.ram_total_mb)} · disk free ${mb(hw.disk && hw.disk.free_mb)}`;
    } catch (e) { $('hubHwLine').textContent = `hardware probe failed: ${e.message}`; }
  }

  // ── Now serving (live from llama-server) ──────────────────────────────────
  function libByRel(rel) {
    return ((state.lib && state.lib.entries) || []).find((e) => e.rel === rel || (e.aliases || []).includes(rel));
  }
  async function loadServer() {
    try {
      state.server = await api('GET', '/api/hub/server');
      renderServer();
    } catch (e) {
      const body = $('wbServingBody');
      const badge = $('wbServingBadge');
      clear(body);
      badge.textContent = 'UNKNOWN'; badge.className = 'status-chip chip-custom';
      body.append(el('div', { cls: 'wb-muted', text: `server status unavailable: ${e.message}` }));
    }
  }
  function renderServer() {
    const body = $('wbServingBody');
    const badge = $('wbServingBadge');
    const s = state.server;
    if (!s) return;
    {
      clear(body);
      const eps = (s.endpoints || []).slice().sort((a, b) => (b.ok ? 1 : 0) - (a.ok ? 1 : 0));
      const anyOk = eps.some((e) => e.ok);
      badge.textContent = !eps.length ? 'NOT CONFIGURED' : (anyOk ? 'ONLINE' : 'OFFLINE');
      badge.className = `status-chip ${anyOk ? 'chip-sovereign' : 'chip-custom'}`;
      if (!eps.length) {
        body.append(el('div', { cls: 'wb-muted', text: 'No inference endpoints in .george/endpoints.conf yet. Pick a model in My Library and press SERVE, or run ./install.sh.' }));
      }
      eps.forEach((e) => {
        const lib = e.model_rel ? libByRel(e.model_rel) : null;
        const name = lib ? displayName(lib) : (e.model_path ? String(e.model_path).split('/').pop() : (e.configured_model || 'unknown model'));
        const tags = [
          el('span', { cls: 'meta-tag', text: e.tier }),
          el('span', { cls: `meta-tag ${e.ok ? 'wb-ok' : 'wb-bad'}`, text: e.ok ? `● ${e.health || 'ok'}` : `○ ${e.error || 'unreachable'}` }),
        ];
        if (e.n_ctx) tags.push(el('span', { cls: 'meta-tag', text: `context ${Number(e.n_ctx).toLocaleString()} tokens`, title: 'reported live by llama-server' }));
        if (e.n_ctx_train) tags.push(el('span', { cls: 'meta-tag', text: `trained ${ctxLabel(e.n_ctx_train)}` }));
        if (e.modalities && e.modalities.vision) tags.push(el('span', { cls: 'meta-tag', text: 'vision' }));
        if (e.slots) tags.push(el('span', { cls: 'meta-tag', text: `${e.slots} slot${e.slots > 1 ? 's' : ''}` }));
        tags.push(el('span', { cls: 'meta-tag', text: e.url }));
        body.append(el('div', { cls: 'wb-serving-row' }, [
          el('div', { cls: 'wb-serving-model', text: e.ok ? name : `${name} (not responding)` }),
          el('div', { cls: 'model-card-meta' }, tags),
          e.model_rel ? el('div', { cls: 'wb-muted', text: `file: ${e.model_rel}` }) : null,
        ]));
      });
      if (s.active_profile && s.active_profile.name) {
        body.append(el('div', { cls: 'wb-muted', text: `last activated profile: ${s.active_profile.name}` }));
      }
      $('btnWbRollback').disabled = !s.can_rollback;
    }
  }
  async function loadPresets() {
    const wrap = $('wbPresets');
    const list = $('wbPresetList');
    try {
      const p = await api('GET', '/api/hub/presets');
      (p.errors || []).forEach((m) => log(`preset config: ${m}`));
      clear(list);
      wrap.hidden = !(p.presets || []).length;
      (p.presets || []).forEach((pr) => {
        const acts = [confirmBtn('RUN', 'CONFIRM RUN', () => runPreset(pr.id, false), 'primary')];
        if ((pr.status_args || []).length) acts.push(btn('STATUS', () => runPreset(pr.id, true)));
        list.append(el('div', { cls: 'wb-preset' }, [
          el('div', { cls: 'wb-preset-main' }, [
            el('div', { cls: 'model-name', text: pr.label }),
            pr.description ? el('div', { cls: 'wb-muted', text: pr.description }) : null,
          ]),
          el('div', { cls: 'hub-actions' }, acts),
        ]));
      });
    } catch (e) { wrap.hidden = true; log(`presets: ${e.message}`); }
  }
  async function runPreset(id, status) {
    log(`${status ? 'checking' : 'running'} preset "${id}"…${status ? '' : ' (model load can take minutes)'}`);
    try {
      const r = await api('POST', `/api/hub/presets/${encodeURIComponent(id)}/run`, { status });
      log(`preset "${id}" ${r.ok ? 'ok' : `exit ${r.exit_code}`}\n${[r.output, r.stderr].filter(Boolean).join('\n').trim()}`);
    } catch (e) { log(`preset "${id}": ${e.message}`); }
    loadServer();
  }
  async function rollback() {
    log('rolling back to the previous serving configuration…');
    try {
      const r = await fetch('/api/hub/rollback', { method: 'POST' }).then((x) => x.json());
      log(`${r.status || 'error'}: ${(r.output || '').trim()}${r.stderr ? `\n${r.stderr.trim()}` : ''}${r.error || ''}`);
    } catch (e) { log(`rollback failed: ${e.message}`); }
    loadServer();
  }

  // ── Library ───────────────────────────────────────────────────────────────
  const KIND = {
    model: { label: 'MODEL', cls: 'wb-kind-model' },
    adapter: { label: 'ADAPTER', cls: 'wb-kind-adapter' },
    mmproj: { label: 'PROJECTOR', cls: 'wb-kind-mmproj' },
    draft: { label: 'DRAFT', cls: 'wb-kind-draft' },
    unknown: { label: 'UNREADABLE', cls: 'wb-kind-unknown' },
  };
  function hasIssue(e) { return !!e.error || e.complete === false || e.inside === false || (e.kind || 'unknown') === 'unknown'; }
  /** File stem is what the operator recognises; GGUF general.name is often a converter default ("Hf", "Model"). */
  function displayName(e) { return String(e.file || e.rel || '').replace(/\.gguf$/i, '').replace(/-0+1-of-\d+$/i, ''); }
  function metaTitle(e) {
    const t = String(e.title || '').trim();
    return t.length >= 4 && !/^(hf|model|models?|base|unknown)$/i.test(t) && t.toLowerCase() !== displayName(e).toLowerCase() ? t : '';
  }
  function servingRels() {
    const set = new Set();
    ((state.server && state.server.endpoints) || []).forEach((ep) => { if (ep.ok && ep.model_rel) set.add(ep.model_rel); });
    return set;
  }

  async function loadLibrary() {
    const grid = $('wbLibraryGrid');
    if (!state.lib) { clear(grid); grid.append(el('div', { cls: 'models-empty-state', text: 'Scanning your models folder (first scan reads every GGUF header; later scans are cached)…' })); }
    try {
      state.lib = await api('GET', '/api/hub/library');
      renderLibrary();
      renderServer();
    } catch (e) {
      clear(grid);
      grid.append(el('div', { cls: 'models-empty-state', text: `library scan failed: ${e.message}` }));
    }
  }

  function renderLibrary() {
    const lib = state.lib || { entries: [] };
    const grid = $('wbLibraryGrid');
    const entries = lib.entries || [];
    const t = lib.totals || {};
    const k = t.by_kind || {};
    $('wbLibCount').textContent = String(k.model || 0);
    $('wbLibSummary').textContent = lib.exists === false
      ? `models folder ${lib.models_dir} does not exist yet; it is created on your first download.`
      : `${lib.models_dir} · ${k.model || 0} model${k.model === 1 ? '' : 's'}, ${k.adapter || 0} adapter(s), ${k.mmproj || 0} projector(s), ${k.draft || 0} draft(s) · ${bytes(t.bytes)} total${lib.truncated ? ' · scan truncated (very large folder)' : ''}`;

    const q = state.q.toLowerCase();
    let rows = entries.filter((e) => {
      const kind = e.kind || 'unknown';
      if (state.kind === 'issues' ? !hasIssue(e) : (state.kind !== 'all' && kind !== state.kind)) return false;
      if (!q) return true;
      return [e.rel, e.title, e.arch, e.quant, e.size_label, e.base_model, e.finetune].some((v) => v && String(v).toLowerCase().includes(q));
    });
    const by = {
      name: (a, b) => displayName(a).localeCompare(displayName(b)),
      size: (a, b) => (b.size || 0) - (a.size || 0),
      recent: (a, b) => (b.mtime || 0) - (a.mtime || 0),
      folder: (a, b) => String(a.rel).localeCompare(String(b.rel)),
    }[state.sort];
    rows = rows.slice().sort((a, b) => {
      const ka = a.kind === 'model' ? 0 : 1;
      const kb = b.kind === 'model' ? 0 : 1;
      return state.sort === 'name' && ka !== kb ? ka - kb : by(a, b);
    });

    clear(grid);
    if (!entries.length) { grid.append(emptyLibrary(lib)); return; }
    if (!rows.length) { grid.append(el('div', { cls: 'models-empty-state', text: 'Nothing matches this filter.' })); return; }
    const live = servingRels();
    rows.forEach((e) => grid.append(card(e, live)));
  }

  function emptyLibrary(lib) {
    return el('div', { cls: 'wb-empty' }, [
      el('div', { cls: 'wb-empty-title', text: 'Your library is empty' }),
      el('p', { text: `Blue Lodge looks for .gguf files under ${lib.models_dir || 'your models folder'} (set MODELS_DIR to change it). Two ways to fill it:` }),
      el('ol', {}, [
        el('li', { text: 'Already have GGUF files? Move or symlink them into that folder, then press ↻ REFRESH.' }),
        el('li', { text: 'Want something new? Use DISCOVER & DOWNLOAD to search Hugging Face / ModelScope, check what fits your hardware, and download a verified copy.' }),
      ]),
      el('div', { cls: 'hub-row' }, [
        btn('OPEN DISCOVER', () => showTab('wbPanelDiscover'), 'primary'),
        btn('ASK GEORGE WHAT FITS', () => { $('hubAskInput').value = 'What can this machine run comfortably, and at what context size?'; autoGrow(); $('hubAskInput').focus(); }),
      ]),
    ]);
  }

  function card(e, live) {
    const kind = e.kind || 'unknown';
    const kd = KIND[kind] || KIND.unknown;
    const isLive = live.has(e.rel);
    let pill;
    if (isLive) pill = el('span', { cls: 'model-status-pill status-installed', text: '● SERVING' });
    else if (e.installed_profile) pill = el('span', { cls: 'model-status-pill status-available', text: `● PROFILE ${e.installed_profile}` });
    else if (kind === 'model') pill = el('span', { cls: 'model-status-pill wb-pill-idle', text: '○ NOT SET UP' });

    const tags = [];
    const tag = (text, title) => tags.push(el('span', { cls: 'meta-tag', text, title }));
    if (e.arch) tag(e.arch);
    if (e.quant) tag(e.quant);
    if (e.size_label) tag(e.size_label);
    tag(bytes(e.size));
    if (kind === 'model' || kind === 'draft') {
      if (e.ctx_train) tag(`trained ctx ${ctxLabel(e.ctx_train)}`, 'maximum context the model was trained for (from GGUF metadata)');
      if (e.n_layer) tag(`${e.n_layer} layers`);
      if (e.experts) tag(`MoE ${e.experts_used || '?'}/${e.experts}`);
      if (kind === 'model' && e.chat_template === false) tag('no chat template', 'llama-server will fall back to a generic template');
    }
    if (kind === 'adapter') {
      if (e.adapter_type) tag(e.adapter_type);
      if (e.adapter_alpha) tag(`alpha ${e.adapter_alpha}`);
    }
    if (e.shards) tag(`${e.shards_present}/${e.shards} parts`);

    const notes = [];
    if (e.error) notes.push(`[ERROR] ${e.error}`);
    if (e.complete === false) notes.push('[MISSING PARTS] some parts of this split model are missing');
    if (metaTitle(e)) notes.push(`name: ${metaTitle(e)}`);
    if (e.inside === false) notes.push('[SYMLINK OUTSIDE] symlink points outside the models folder; move the file inside to use it');
    if (e.base_model) notes.push(`base: ${e.base_model}`);
    if (e.cv_model_hint) notes.push(`for: ${e.cv_model_hint}`);
    if (e.finetune) notes.push(`finetune: ${e.finetune}`);
    if (e.license) notes.push(`license: ${e.license}`);
    if (kind === 'mmproj') notes.push('Vision/audio projector: pick it in SERVE on a matching model.');
    if (kind === 'draft') notes.push('Speculative-decoding draft: pick it in SERVE on a model of the same family.');

    const details = el('div', { cls: 'model-card-details' }, [
      el('div', {}, ['PATH: ', el('code', { text: e.rel })]),
      (e.aliases || []).length ? el('div', { text: `ALSO AT: ${e.aliases.join(', ')}` }) : null,
      (e.profiles || []).length ? el('div', { text: `PROFILES: ${e.profiles.map((p) => `${p.name} (${p.status})`).join(', ')}` }) : null,
    ]);

    const acts = [];
    if (kind === 'model' && !hasIssue(e)) {
      if (e.installed_profile) {
        acts.push(confirmBtn(isLive ? 'RELOAD' : 'ACTIVATE', 'CONFIRM: SWAP MODEL', () => activate(e.installed_profile, false), 'accent'));
        acts.push(btn('TUNE', () => { showTab('wbPanelServe'); review(e.installed_profile); }));
      } else {
        acts.push(btn('SERVE…', () => serveSheet(e), 'accent'));
      }
    }
    if (kind === 'adapter') acts.push(btn('ATTACH…', () => attachSheet(e), 'accent'));
    acts.push(btn('DETAILS', () => detailsSheet(e)));
    acts.push(confirmBtn('DELETE', 'CONFIRM DELETE', () => deleteFile(e, false)));

    return el('article', { cls: `model-card ${isLive || e.installed_profile ? 'is-installed' : ''} ${hasIssue(e) ? 'wb-has-issue' : ''}`.trim() }, [
      el('div', { cls: 'model-card-header' }, [
        el('div', { cls: 'model-title-wrap' }, [
          el('div', { cls: 'model-name', text: displayName(e), title: e.rel }),
          el('span', { cls: `model-family-badge ${kd.cls}`, text: kd.label }),
        ]),
        pill,
      ]),
      el('div', { cls: 'model-card-meta' }, tags),
      notes.length ? el('div', { cls: 'model-card-notes', text: notes.join(' · ') }) : null,
      details,
      el('div', { cls: 'model-card-actions' }, acts),
    ]);
  }

  // ── Sheet (inline dialog above the grid) ──────────────────────────────────
  function sheet(title, children) {
    const s = $('wbSheet');
    clear(s);
    s.append(el('div', { cls: 'wb-sheet-head' }, [
      el('div', { cls: 'wb-kicker', text: title }),
      btn('CLOSE', closeSheet),
    ]), ...children);
    s.hidden = false;
    showTab('wbPanelLibrary');
    s.scrollIntoView({ behavior: 'smooth', block: 'start' });
    return s;
  }
  function closeSheet() { const s = $('wbSheet'); clear(s); s.hidden = true; }

  function detailsSheet(e) {
    const lines = Object.entries(e).filter(([, v]) => v != null && v !== '' && !(Array.isArray(v) && !v.length))
      .map(([k, v]) => `${k.padEnd(16)}: ${typeof v === 'object' ? JSON.stringify(v) : v}`);
    sheet(`DETAILS · ${e.file}`, [el('pre', { cls: 'hub-pre', text: lines.join('\n') })]);
  }

  const VERDICT = { fits_gpu: '[FITS GPU] fits in GPU memory', partial_offload: '[PARTIAL] partial offload (some layers on CPU, slower)', cpu_only: '[CPU ONLY] CPU only (slow)', does_not_fit: '[EXCEEDS VRAM] does not fit' };

  function serveSheet(e) {
    const entries = (state.lib && state.lib.entries) || [];
    const name = el('input', { cls: 'form-input', value: slug(e.file), attrs: { maxlength: 64 } });
    const ctx = el('input', { cls: 'form-input', type: 'number', value: Math.min(e.ctx_train || 32768, 32768), attrs: { min: 512, step: 1024 } });
    const kv = el('select', { cls: 'form-input' }, [option('f16', 'f16 (best quality)', true), option('q8_0', 'q8_0 (half the memory)'), option('q4_0', 'q4_0 (quarter)')]);
    const sameDir = (x) => x.dir === e.dir;
    const mm = el('select', { cls: 'form-input' }, [option('', '(none)')]);
    entries.filter((x) => x.kind === 'mmproj').sort((a, b) => sameDir(b) - sameDir(a))
      .forEach((x, i) => mm.append(option(x.rel, `${x.rel} · ${bytes(x.size)}`, i === 0 && sameDir(x))));
    const dr = el('select', { cls: 'form-input' }, [option('', '(none)')]);
    entries.filter((x) => x.kind === 'draft').sort((a, b) => sameDir(b) - sameDir(a))
      .forEach((x) => dr.append(option(x.rel, `${x.rel} · ${bytes(x.size)}`)));
    const approve = el('input', { type: 'checkbox' }); approve.checked = true;
    const out = el('div', { cls: 'wb-fit-out', attrs: { 'aria-live': 'polite' } });
    const status = el('div', { cls: 'wb-muted' });

    async function check() {
      clear(out); out.append(el('div', { cls: 'wb-muted', text: 'estimating memory…' }));
      const qs = new URLSearchParams({ file: e.rel, ctx: ctx.value || '8192', kv: kv.value });
      if (mm.value) qs.set('mmproj', mm.value);
      if (dr.value) qs.set('draft', dr.value);
      try {
        const r = await api('GET', `/api/hub/fit-local?${qs}`);
        clear(out);
        out.append(el('div', { cls: `wb-verdict wb-v-${r.verdict}`, text: `${VERDICT[r.verdict] || r.verdict} at ${Number(ctx.value).toLocaleString()} tokens` }));
        const layers = r.n_gpu_layers == null ? '?' : (r.n_gpu_layers >= (e.n_layer || 999) ? 'all' : String(r.n_gpu_layers));
        out.append(el('div', { cls: 'wb-muted', text: `needs ≈ ${mb(r.need_mb)} of ${mb(r.gpu_usable_mb)} usable GPU memory · ${layers} layers on GPU${r.tensor_split ? ` · split ${r.tensor_split.join(':')}` : ''}${r.max_ctx ? ` · max context on GPU ≈ ${Number(r.max_ctx).toLocaleString()}` : ''}` }));
        (r.notes || []).forEach((n) => out.append(el('div', { cls: 'wb-muted', text: `· ${n}` })));
        const tb = el('tbody');
        (r.kv_options || []).forEach((o) => {
          const tr = el('tr', { cls: `hub-v-${o.verdict}` }, [
            el('td', { text: o.kv }),
            el('td', { text: o.max_gpu_ctx ? Number(o.max_gpu_ctx).toLocaleString() : '—' }),
            el('td', { text: o.max_single_gpu_ctx ? Number(o.max_single_gpu_ctx).toLocaleString() : '—' }),
          ]);
          const td = el('td');
          if (o.max_gpu_ctx) {
            td.append(btn('USE', () => {
              kv.value = o.kv;
              ctx.value = Math.max(512, Math.min(Math.floor(o.max_gpu_ctx / 1024) * 1024, e.ctx_train || o.max_gpu_ctx));
              check();
            }));
          }
          tr.append(td); tb.append(tr);
        });
        out.append(el('div', { cls: 'hub-label', text: 'LARGEST CONTEXT THAT STAYS ON GPU, BY KV CACHE TYPE' }));
        out.append(el('div', { cls: 'hub-table-wrap' }, [el('table', { cls: 'hub-table' }, [
          el('thead', {}, [el('tr', {}, [el('th', { text: 'KV' }), el('th', { text: 'ALL GPUS' }), el('th', { text: 'ONE GPU' }), el('th')])]), tb,
        ])]));
      } catch (err) { clear(out); out.append(el('div', { cls: 'wb-bad', text: err.message })); }
    }

    async function create() {
      const n = name.value.trim();
      if (!NAME_RE.test(n)) { status.textContent = 'Profile name: lowercase letters, digits, . _ - (2-64 chars).'; return; }
      const body = { file: e.rel, name: n, ctx: parseInt(ctx.value, 10) || undefined, kv: kv.value, approve: approve.checked };
      if (mm.value) body.mmproj = mm.value;
      if (dr.value) body.draft = dr.value;
      status.textContent = 'checking fit, then hashing files (large models take a few minutes; cached afterwards)…';
      try {
        await api('POST', '/api/hub/import-local', body);
        log(`creating profile "${n}" from ${e.rel}${approve.checked ? ' (approved by you)' : ' (draft: approve it in Serve & Tune)'}`);
        pollProgress(n, (pr) => {
          status.textContent = pr.state === 'running'
            ? `hashing ${pr.file || ''} · ${pr.total ? Math.floor((pr.done || 0) * 100 / pr.total) : 0}%`
            : `${pr.state}${pr.error ? `: ${pr.error}` : ''}`;
          if (pr.state === 'done') {
            clear(status);
            status.append(el('span', { text: `Profile "${n}" is ready. ` }));
            if (approve.checked) {
              status.append(confirmBtn('ACTIVATE NOW', 'CONFIRM: SWAP MODEL', () => activate(n, false), 'accent'), ' ', btn('DRY RUN', () => activate(n, true)));
            }
            status.append(' ', btn('OPEN IN SERVE & TUNE', () => { showTab('wbPanelServe'); review(n); }));
            refreshLibraryAndProfiles();
          }
        });
      } catch (err) { status.textContent = err.message; }
    }

    [ctx, kv, mm, dr].forEach((x) => x.addEventListener('change', check));
    sheet(`SERVE · ${displayName(e)}`, [
      el('p', { cls: 'wb-lede', text: 'Turn this file into a profile: Blue Lodge pins its sha256, sizes llama-server settings for your hardware, and remembers them so you can switch back any time. Your file stays where it is.' }),
      el('div', { cls: 'wb-form-grid' }, [
        field('Profile name', name), field('Context (tokens)', ctx), field('KV cache', kv),
        field('Vision projector', mm), field('Draft model (speculative decoding)', dr),
      ]),
      out,
      el('label', { cls: 'hub-check' }, [approve, 'I reviewed these settings: approve the profile now']),
      el('div', { cls: 'hub-row hub-end' }, [btn('RE-CHECK FIT', check), btn('CREATE PROFILE', create, 'accent')]),
      status,
    ]);
    check();
  }

  function attachSheet(e) {
    const profs = state.profiles || [];
    const status = el('div', { cls: 'wb-muted' });
    if (!profs.length) {
      sheet(`ATTACH · ${e.file}`, [el('p', { cls: 'wb-lede', text: 'Adapters attach to a profile. Serve a base model first (SERVE… on a model card), then come back here.' })]);
      return;
    }
    const prof = el('select', { cls: 'form-input' }, profs.map((p) => option(p.name, `${p.name} (${p.status})`)));
    const isCv = e.adapter_type === 'control_vector' || e.arch === 'controlvector';
    const role = el('select', { cls: 'form-input' }, [option('lora', 'LoRA', !isCv), option('control_vector', 'control vector', isCv)]);
    const scale = el('input', { cls: 'form-input', type: 'number', value: '1.0', attrs: { min: -4, max: 4, step: 0.05 } });
    sheet(`ATTACH · ${e.file}`, [
      el('p', { cls: 'wb-lede', text: `A copy goes to adapters/ and is sha256-pinned in the profile. The profile returns to draft so you re-approve exactly what will be served.${e.base_model ? ` This adapter was trained on ${e.base_model}; attach it to a profile serving that base.` : ''}` }),
      el('div', { cls: 'wb-form-grid' }, [field('Profile', prof), field('Type', role), field('Scale', scale)]),
      el('div', { cls: 'hub-row hub-end' }, [btn('ATTACH', async () => {
        try {
          await api('POST', `/api/hub/profile/${encodeURIComponent(prof.value)}/attach`, { role: role.value, file: e.rel, scale: parseFloat(scale.value) });
          log(`attached ${e.file} to "${prof.value}" (scale ${scale.value}); re-approve it in Serve & Tune`);
          status.textContent = 'Attached. Re-approve the profile, then activate it.';
          refreshLibraryAndProfiles();
        } catch (err) { status.textContent = err.message; }
      }, 'accent')]),
      status,
    ]);
  }

  async function deleteFile(e, force) {
    try {
      const r = await api('DELETE', `/api/hub/library/file?file=${encodeURIComponent(e.rel)}${force ? '&force=true' : ''}`);
      log(`deleted ${(r.deleted || []).join(', ') || e.rel}${r.note ? ` (${r.note})` : ''}`);
      refreshLibraryAndProfiles();
    } catch (err) {
      log(`delete ${e.rel}: ${err.message}`);
      if (/in use by profile/.test(err.message)) {
        sheet(`DELETE · ${e.file}`, [
          el('p', { cls: 'wb-lede', text: `${err.message} Deleting anyway breaks those profiles until you remove or re-point them.` }),
          el('div', { cls: 'hub-row hub-end' }, [btn('KEEP IT', closeSheet), confirmBtn('DELETE ANYWAY', 'CONFIRM FORCE DELETE', () => deleteFile(e, true).then(closeSheet))]),
        ]);
      }
    }
  }

  // ── Discover (search → quants → draft) ────────────────────────────────────
  function resultRow(r) {
    const dl = r.downloads != null ? ` · ⬇ ${Number(r.downloads).toLocaleString()}` : '';
    const meta = r.error ? `error: ${r.error}` :
      `${r.provider}${dl}${r.likes != null ? ` · ♥ ${r.likes}` : ''}${r.gated ? ' · gated (log in below)' : ''}${r.updated ? ` · updated ${String(r.updated).slice(0, 10)}` : ''}`;
    const row = el('div', { cls: 'hub-item' }, [
      el('div', { cls: 'hub-item-main' }, [
        el('span', { cls: 'hub-item-title', text: r.title ? `${r.title} · ${r.repo}` : (r.repo || r.provider) }),
        el('span', { cls: 'hub-item-meta', text: meta }),
      ]),
    ]);
    if (!r.error && r.repo) row.append(btn('CHECK FIT', () => loadQuants(r.provider, r.repo), 'primary'));
    return row;
  }

  async function search(qOverride) {
    const input = $('hubSearchInput');
    if (qOverride) input.value = qOverride;
    const q = input.value.trim();
    if (!q) { log('type a model name or keyword to search'); input.focus(); return; }
    const box = $('hubSearchResults');
    clear(box); box.append(el('div', { cls: 'hub-item-meta', text: `searching for “${q}”…` }));
    $('hubQuantPanel').hidden = true;
    try {
      const prov = $('hubProviderSelect').value;
      const rows = await api('GET', `/api/hub/search?q=${encodeURIComponent(q)}&provider=${encodeURIComponent(prov)}&limit=20`);
      clear(box);
      if (!rows.length) box.append(el('div', { cls: 'hub-item-meta', text: 'No GGUF repos found. Try a shorter keyword, or the other provider.' }));
      else box.append(el('div', { cls: 'wb-muted', text: `${rows.length} repos with GGUF files. Press CHECK FIT to size every quant against your hardware.` }));
      rows.forEach((r) => box.append(resultRow(r)));
    } catch (e) { clear(box); log(`search failed: ${e.message}`); }
  }

  async function loadQuants(provider, repo) {
    const panel = $('hubQuantPanel');
    const tbody = $('hubQuantTable').querySelector('tbody');
    panel.hidden = false; clear(tbody);
    $('hubQuantTitle').textContent = `${repo}: estimating fit…`;
    panel.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    const ctx = parseInt($('hubCtxInput').value, 10) || 32768;
    const kv = $('hubKvSelect').value;
    try {
      const d = await api('GET', `/api/hub/quants?provider=${encodeURIComponent(provider)}&repo=${encodeURIComponent(repo)}&ctx=${ctx}&kv=${encodeURIComponent(kv)}`);
      const dims = d.dims || {};
      $('hubQuantTitle').textContent = `${d.repo} @ ${String(d.revision || '').slice(0, 10)} · ${dims.arch || '?'} · ${dims.n_layer || '?'} layers · trained ctx ${ctxLabel(dims.ctx_train)} · planning ${Number(d.ctx).toLocaleString()} tokens, KV ${d.kv_type}` +
        (d.best_gpu_fit ? ` · best GPU fit: ${d.best_gpu_fit}` : ' · no quant fits fully in GPU memory at this context');
      (d.quants || []).forEach((q) => {
        const tr = el('tr', { cls: `hub-v-${q.verdict}${q.quant === d.best_gpu_fit ? ' wb-best' : ''}` }, [
          el('td', { text: q.quant + (q.quant === d.best_gpu_fit ? '  ★' : '') }),
          el('td', { text: mb(q.size_mb) + (q.files > 1 ? ` (${q.files} parts)` : '') }),
          el('td', { text: VERDICT[q.verdict] || q.verdict }),
          el('td', { text: q.n_gpu_layers != null ? String(q.n_gpu_layers) : '—' }),
          el('td', { text: q.max_ctx ? Number(q.max_ctx).toLocaleString() : '—' }),
        ]);
        const td = el('td');
        if (q.verdict !== 'does_not_fit') td.append(btn('DRAFT', () => draft(provider, d.repo, q.quant, ctx, kv), 'primary'));
        tr.append(td);
        tbody.append(tr);
      });
    } catch (e) { $('hubQuantTitle').textContent = `${repo}: ${e.message}`; }
  }

  async function draft(provider, repo, quant, ctx, kv) {
    try {
      const r = await api('POST', '/api/hub/draft', { provider, repo, quant, ctx, kv, with_mmproj: $('hubWithMmproj').checked });
      const p = r.profile || r;
      log(`drafted "${p.name}": review it, approve, then DOWNLOAD`);
      await loadProfiles();
      showTab('wbPanelServe');
      review(p.name);
    } catch (e) { log(`draft failed: ${e.message}`); }
  }

  // ── Profiles (Serve & Tune) ───────────────────────────────────────────────
  async function loadProfiles() {
    const box = $('hubProfileList');
    try {
      state.profiles = await api('GET', '/api/hub/profiles');
      $('wbProfCount').textContent = String(state.profiles.length);
      clear(box);
      if (!state.profiles.length) {
        box.append(el('div', { cls: 'wb-empty' }, [
          el('div', { cls: 'wb-empty-title', text: 'No profiles yet' }),
          el('p', { text: 'Press SERVE… on a model in My Library, or DRAFT a quant in Discover & Download.' }),
        ]));
      }
      state.profiles.forEach((p) => box.append(profileRow(p)));
    } catch (e) { log(`profiles failed: ${e.message}`); }
  }

  function profileRow(p) {
    const local = p.provider === 'local';
    const status = p.status === 'draft' ? 'DRAFT' : (p.approved ? p.status.toUpperCase() : `${p.status.toUpperCase()} (edited: re-approve)`);
    const src = local ? `local file ${p.model_file || ''}` : `${p.provider}:${p.repo} · ${p.model_file || ''}`;
    const meta = el('span', { cls: 'hub-item-meta', id: `hubProg-${p.name}`, text: `${status} · ${src} · ${bytes(p.size)} · ctx ${p.ctx ? Number(p.ctx).toLocaleString() : '?'} · KV ${p.kv || 'f16'}${(p.adapters || []).length ? ` · ${p.adapters.length} adapter(s)` : ''}${p.roles && p.roles.length ? ` · +${p.roles.join('+')}` : ''}` });
    const acts = el('div', { cls: 'hub-actions' }, [btn('REVIEW / EDIT', () => review(p.name))]);
    if (p.approved && p.status !== 'installed') acts.append(btn(local ? 'VERIFY' : 'DOWNLOAD', () => install(p.name), 'primary'));
    if (p.status === 'installed' && p.approved) {
      acts.append(btn('DRY RUN', () => activate(p.name, true)));
      acts.append(confirmBtn('ACTIVATE', 'CONFIRM: SWAP MODEL', () => activate(p.name, false), 'accent'));
    }
    acts.append(confirmBtn('REMOVE', 'CONFIRM REMOVE', () => removeProfile(p.name, false)));
    if (p.status === 'installed' && !local) acts.append(confirmBtn('REMOVE + FILES', 'CONFIRM: DELETE FILES', () => removeProfile(p.name, true)));
    return el('div', { cls: `hub-item hub-st-${p.status}` }, [
      el('div', { cls: 'hub-item-main' }, [el('span', { cls: 'hub-item-title', text: p.name }), meta]), acts,
    ]);
  }

  const TUNE_FIELDS = [
    ['server', 'ctx', 'Context (tokens)', 'int'], ['server', 'n_gpu_layers', 'GPU layers', 'int'],
    ['server', 'cache_type_k', 'KV cache K', ['f16', 'bf16', 'q8_0', 'q5_1', 'q5_0', 'q4_1', 'q4_0', 'iq4_nl']],
    ['server', 'cache_type_v', 'KV cache V', ['f16', 'bf16', 'q8_0', 'q5_1', 'q5_0', 'q4_1', 'q4_0', 'iq4_nl']],
    ['server', 'flash_attn', 'Flash attention', 'bool'], ['server', 'parallel', 'Parallel slots', 'int'],
    ['server', 'threads', 'CPU threads', 'int'], ['server', 'draft_max', 'Draft tokens (max)', 'int'],
    ['server', 'reasoning_budget', 'Reasoning budget (-1 = unlimited)', 'int'],
    ['sampling', 'temperature', 'Temperature', 'float'], ['sampling', 'top_p', 'Top-p', 'float'],
    ['sampling', 'top_k', 'Top-k', 'int'], ['sampling', 'min_p', 'Min-p', 'float'],
    ['sampling', 'repeat_penalty', 'Repeat penalty', 'float'], ['sampling', 'presence_penalty', 'Presence penalty', 'float'],
  ];

  function tuneForm(p) {
    const box = $('wbTuneForm');
    clear(box);
    const inputs = [];
    const grid = el('div', { cls: 'wb-form-grid' });
    TUNE_FIELDS.forEach(([sec, key, label, type]) => {
      const cur = (p[sec] || {})[key];
      let input;
      if (Array.isArray(type) || type === 'bool') {
        const opts = type === 'bool' ? ['true', 'false'] : type;
        input = el('select', { cls: 'form-input' }, [option('', '(default)'), ...opts.map((o) => option(o, o, String(cur) === o))]);
      } else {
        input = el('input', { cls: 'form-input', type: 'number', value: cur != null ? cur : '', attrs: { step: type === 'float' ? 'any' : '1', placeholder: 'default' } });
      }
      inputs.push({ sec, key, type, input, cur });
      grid.append(field(label, input));
    });
    const status = el('div', { cls: 'wb-muted' });
    box.append(el('div', { cls: 'hub-label', text: 'TUNE (saving returns the profile to draft so you re-approve exactly what will run)' }), grid,
      el('div', { cls: 'hub-row hub-end' }, [btn('SAVE CHANGES', async () => {
        const patch = { server: {}, sampling: {} };
        let n = 0;
        inputs.forEach(({ sec, key, type, input, cur }) => {
          const raw = input.value.trim();
          let v = null;
          if (raw !== '') v = type === 'bool' ? raw === 'true' : (type === 'int' ? parseInt(raw, 10) : (type === 'float' ? parseFloat(raw) : raw));
          if (raw === '' && cur == null) return;
          if (v !== null && String(v) === String(cur)) return;
          patch[sec][key] = v; n += 1;
        });
        if (!n) { status.textContent = 'No changes.'; return; }
        try {
          await api('POST', `/api/hub/profile/${encodeURIComponent(p.name)}/tune`, patch);
          log(`saved ${n} change(s) to "${p.name}"; approve it to serve`);
          await loadProfiles();
          review(p.name);
        } catch (e) { status.textContent = e.message; }
      }, 'primary')]), status);
  }

  function adaptersBox(p) {
    const box = $('wbAdapters');
    clear(box);
    box.append(el('div', { cls: 'hub-label', text: 'ADAPTERS (LoRA / control vectors)' }));
    (p.adapters || []).forEach((a) => {
      box.append(el('div', { cls: 'hub-item' }, [
        el('div', { cls: 'hub-item-main' }, [el('span', { cls: 'hub-item-title', text: a.path }), el('span', { cls: 'hub-item-meta', text: `${a.role} · scale ${a.scale}` })]),
        btn('DETACH', async () => {
          try {
            await api('POST', `/api/hub/profile/${encodeURIComponent(p.name)}/detach`, { file: a.path });
            log(`detached ${a.path} from "${p.name}"`); await loadProfiles(); review(p.name);
          } catch (e) { log(`detach failed: ${e.message}`); }
        }),
      ]));
    });
    const libAdapters = ((state.lib && state.lib.entries) || []).filter((x) => x.kind === 'adapter');
    if (!libAdapters.length) {
      box.append(el('div', { cls: 'wb-muted', text: 'No adapter GGUFs in your library yet. Train one in FINE-TUNE, or drop a LoRA .gguf into your models folder.' }));
      return;
    }
    const sel = el('select', { cls: 'form-input' }, libAdapters.map((x) => option(x.rel, `${x.rel}${x.base_model ? ` (base ${x.base_model})` : ''}`)));
    const role = el('select', { cls: 'form-input hub-narrow' }, [option('lora', 'LoRA', true), option('control_vector', 'control vector')]);
    const scale = el('input', { cls: 'form-input hub-narrow', type: 'number', value: '1.0', attrs: { min: -4, max: 4, step: 0.05, 'aria-label': 'scale' } });
    box.append(el('div', { cls: 'hub-row' }, [sel, role, scale, btn('ATTACH', async () => {
      try {
        await api('POST', `/api/hub/profile/${encodeURIComponent(p.name)}/attach`, { role: role.value, file: sel.value, scale: parseFloat(scale.value) });
        log(`attached ${sel.value} to "${p.name}"`); await loadProfiles(); review(p.name);
      } catch (e) { log(`attach failed: ${e.message}`); }
    }, 'primary')]));
  }

  async function review(name) {
    try {
      const p = await api('GET', `/api/hub/profile/${encodeURIComponent(name)}`);
      state.reviewing = name;
      $('hubReview').hidden = false;
      $('hubReviewTitle').textContent = `PROFILE "${name}" · ${p.status}${p.approved_valid ? ' · approval valid' : ' · needs your approval'}`;
      const src = p.source || {};
      const fit = p.fit || {};
      const lines = [
        `source   : ${src.provider === 'local' ? 'your library (local files)' : `${src.provider}:${src.repo} @ ${src.revision}`}${src.provider === 'local' && src.repo ? ` · base ${src.repo}` : ''}`,
        `created  : by ${p.created_by} · fit ${fit.verdict || '?'} · est. GPU need ${mb(fit.need_mb)} of ${mb(fit.gpu_usable_mb)} usable`,
        'files    :',
        ...(p.files || []).map((f) => `  - [${f.role}] ${f.path}  ${bytes(f.size)}  sha256 ${String(f.sha256 || '').slice(0, 16)}…`),
        ...((p.adapters || []).length ? ['adapters :', ...p.adapters.map((a) => `  - [${a.role}] ${a.path} × ${a.scale}`)] : []),
        `server   : ${JSON.stringify(p.server)}`,
        `sampling : ${JSON.stringify(p.sampling || {})}`,
      ];
      if (p.notes) lines.push(`notes    : ${p.notes}`);
      $('hubReviewBody').textContent = lines.join('\n');
      $('btnHubApprove').hidden = !!p.approved_valid;
      tuneForm(p);
      adaptersBox(p);
      $('hubReview').scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    } catch (e) { log(`review failed: ${e.message}`); }
  }

  async function approve() {
    const name = state.reviewing;
    if (!name) return;
    try {
      await api('POST', `/api/hub/profile/${encodeURIComponent(name)}/approve`);
      log(`approved "${name}" (bound to its current content hash; any edit voids approval)`);
      await loadProfiles();
      const p = state.profiles.find((x) => x.name === name);
      if (p && p.status !== 'installed') install(name);
      review(name);
    } catch (e) { log(`approve failed: ${e.message}`); }
  }

  async function install(name) {
    try {
      await api('POST', `/api/hub/profile/${encodeURIComponent(name)}/install`);
      log(`"${name}": downloading / verifying (resumable, sha256-checked)`);
      pollProgress(name);
      loadJobs();
    } catch (e) { log(`install failed: ${e.message}`); }
  }

  function pollProgress(name, onUpdate) {
    clearInterval(state.polls[name]);
    state.polls[name] = setInterval(async () => {
      try {
        const pr = await api('GET', `/api/hub/profile/${encodeURIComponent(name)}/progress`);
        const node = $(`hubProg-${name}`);
        const pct = pr.total ? Math.floor((pr.done || 0) * 100 / pr.total) : 0;
        if (node) node.textContent = `${pr.kind || 'job'} ${pr.state} ${pct}% · ${bytes(pr.done)} / ${bytes(pr.total)}${pr.file ? ` · ${pr.file}` : ''}${pr.error ? ` · ${pr.error}` : ''}`;
        if (onUpdate) onUpdate(pr);
        if (pr.state === 'done' || pr.state === 'failed' || pr.state === 'none') {
          clearInterval(state.polls[name]);
          log(`"${name}" ${pr.kind || 'job'}: ${pr.state}${pr.error ? ` (${pr.error})` : ''}`);
          refreshLibraryAndProfiles();
          loadJobs();
        }
      } catch (e) { clearInterval(state.polls[name]); log(`progress failed: ${e.message}`); }
    }, 2000);
  }

  async function activate(name, dry) {
    log(`${dry ? 'dry-run' : 'activating'} "${name}"…${dry ? '' : ' (loading a model can take minutes)'}`);
    try {
      const r = await fetch(`/api/hub/profile/${encodeURIComponent(name)}/activate`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ dry_run: dry }),
      }).then((x) => x.json());
      log(`${r.status || 'error'}: ${(r.output || '').trim()}${r.stderr ? `\n${r.stderr.trim()}` : ''}${r.error || ''}`);
    } catch (e) { log(`activate failed: ${e.message}`); }
    if (!dry) { await loadServer(); renderLibrary(); }
  }

  async function removeProfile(name, delFiles) {
    try {
      await api('DELETE', `/api/hub/profile/${encodeURIComponent(name)}${delFiles ? '?delete_files=true' : ''}`);
      log(`removed profile "${name}"${delFiles ? ' and its downloaded files' : ' (files kept)'}`);
      if (state.reviewing === name) { $('hubReview').hidden = true; state.reviewing = null; }
      refreshLibraryAndProfiles();
    } catch (e) { log(`remove failed: ${e.message}`); }
  }

  // ── Jobs tray ─────────────────────────────────────────────────────────────
  async function loadJobs() {
    try {
      const jobs = await api('GET', '/api/hub/jobs');
      const now = Date.now() / 1000;
      const shown = jobs.filter((j) => j.state !== 'done' || now - (j.ts || 0) < 900);
      const list = $('wbJobList');
      clear(list);
      $('wbJobs').hidden = !shown.length;
      shown.forEach((j) => {
        const pct = j.total ? Math.floor((j.done || 0) * 100 / j.total) : 0;
        const fill = el('div', { cls: `wb-bar-fill wb-st-${j.state}` });
        fill.style.width = `${pct}%`;
        const bar = el('div', { cls: 'wb-bar' }, [fill]);
        const acts = el('div', { cls: 'hub-actions' });
        if (j.state === 'running' || j.state === 'stalled') {
          acts.append(btn('CANCEL', async () => {
            try { await api('POST', `/api/hub/profile/${encodeURIComponent(j.name)}/cancel`); log(`cancel requested for ${j.name}`); } catch (e) { log(e.message); }
          }));
        } else {
          acts.append(btn('CLEAR', async () => {
            try { await api('POST', `/api/hub/jobs/${encodeURIComponent(j.name)}/clear`); loadJobs(); } catch (e) { log(e.message); }
          }));
        }
        list.append(el('div', { cls: 'wb-job' }, [
          el('div', { cls: 'hub-item-main' }, [
            el('span', { cls: 'hub-item-title', text: `${j.name} · ${j.kind}` }),
            el('span', { cls: 'hub-item-meta', text: `${j.state} ${pct}% · ${bytes(j.done)} / ${bytes(j.total)}${j.file ? ` · ${j.file}` : ''}${j.error ? ` · ${j.error}` : ''}` }),
            bar,
          ]), acts,
        ]));
      });
      const running = jobs.some((j) => j.state === 'running');
      clearTimeout(state.jobsTimer);
      if (running && state.open) state.jobsTimer = setTimeout(loadJobs, 3000);
    } catch (e) { log(`jobs: ${e.message}`); }
  }

  // ── Accounts ──────────────────────────────────────────────────────────────
  async function loadAccounts() {
    try {
      const a = await api('GET', '/api/hub/accounts');
      $('hubAccountsLine').textContent = a.filter((x) => x.provider !== 'ipfs')
        .map((x) => `${x.provider}: ${x.logged_in ? `[AUTHENTICATED] ${x.user || 'logged in'}` : 'anonymous'}`).join('  ·  ');
    } catch (e) { $('hubAccountsLine').textContent = `accounts unavailable: ${e.message}`; }
  }
  async function login() {
    const input = $('hubTokenInput');
    const token = input.value.trim();
    input.value = '';
    if (!token) { log('paste a read-only token first'); return; }
    try {
      const r = await api('POST', '/api/hub/login', { provider: $('hubLoginProvider').value, token });
      const who = (r.logged_in && r.logged_in.user) || '';
      log(`logged in to ${$('hubLoginProvider').value}${who ? ` as ${who}` : ''} (token validated, saved to .george keys.conf with 0600 permissions)`);
      loadAccounts();
    } catch (e) { log(`login failed: ${e.message}`); }
  }
  async function logout() {
    try {
      await api('POST', '/api/hub/logout', { provider: $('hubLoginProvider').value });
      log(`logged out of ${$('hubLoginProvider').value}`);
      loadAccounts();
    } catch (e) { log(`logout failed: ${e.message}`); }
  }

  // ── Fine-tune ─────────────────────────────────────────────────────────────
  async function loadTrain() {
    const list = $('wbDatasetList');
    try {
      const d = await api('GET', '/api/hub/datasets');
      const ds = d.datasets || [];
      clear(list);
      if (!ds.length) list.append(el('div', { cls: 'wb-muted', text: `No datasets yet. Export your runs or pull one from Hugging Face. (Looked in ${Object.values(d.roots || {}).join(' and ')})` }));
      ds.forEach((x) => list.append(el('div', { cls: 'dataset-item-row' }, [
        el('div', { cls: 'dataset-info' }, [
          el('span', { cls: 'dataset-name', text: x.id }),
          el('span', { cls: 'dataset-path', text: `${x.rows != null ? `${x.rows.toLocaleString()} rows` : '? rows'} · ${x.format || 'unknown format'} · ${bytes(x.size)}` }),
        ]),
      ])));
      const fill = (sel, allowNone) => {
        const cur = sel.value;
        clear(sel);
        if (allowNone) sel.append(option('', '(none)'));
        ds.forEach((x) => sel.append(option(x.id, `${x.id} (${x.rows ?? '?'} rows)`, x.id === cur)));
      };
      fill($('wbKitTrain'), false);
      fill($('wbKitVal'), true);
      const tr = ds.find((x) => /train\.jsonl$/.test(x.id));
      if (tr && !$('wbKitTrain').dataset.touched) $('wbKitTrain').value = tr.id;
      const va = ds.find((x) => /val\.jsonl$/.test(x.id));
      if (va && !$('wbKitVal').dataset.touched) $('wbKitVal').value = va.id;
    } catch (e) { clear(list); list.append(el('div', { cls: 'wb-bad', text: e.message })); }
    loadKits();
    loadForge();
  }
  // ── Dataset Forge ─────────────────────────────────────────────────────────
  const forge = { recipes: null, pantry: null, timer: null };
  async function loadForge() {
    const box = $('wbForgeRecipes');
    try {
      if (!forge.recipes) forge.recipes = await api('GET', '/api/hub/forge/recipes');
    } catch (e) { clear(box); box.append(el('div', { cls: 'wb-bad', text: `forge unavailable: ${e.message}` })); return; }
    const checked = new Set([...box.querySelectorAll('input:checked')].map((i) => i.value));
    if (!checked.size) ['error-recovery', 'failure-modes'].forEach((x) => checked.add(x));
    clear(box);
    Object.entries(forge.recipes).forEach(([name, r]) => {
      const avail = forge.pantry ? (forge.pantry.recipes_available || {})[name] : null;
      const cur = forge.pantry ? (forge.pantry.curricula_available || {})[name] : null;
      const cb = el('input', { attrs: { type: 'checkbox', value: name, id: `forge_${name}` } });
      cb.checked = checked.has(name);
      const meter = el('div', { cls: 'forge-meter' });
      const fill = el('div', { cls: 'forge-meter-fill' });
      if (avail != null) fill.style.width = `${Math.min(100, Math.round(100 * Math.log10(1 + avail) / 4))}%`;
      meter.append(fill);
      box.append(el('label', { cls: 'forge-card', attrs: { for: `forge_${name}`, title: r.lesson } }, [
        cb,
        el('div', { cls: 'forge-card-body' }, [
          el('div', { cls: 'forge-card-top' }, [
            el('span', { cls: 'forge-card-name', text: name }),
            el('span', { cls: `forge-tag ${r.dpo ? 'dpo' : ''}`, text: r.dpo ? 'SFT+DPO' : 'SFT' }),
          ]),
          el('div', { cls: 'forge-card-title', text: r.title }),
          el('div', { cls: 'forge-card-lesson', text: r.lesson }),
          meter,
          el('div', { cls: 'forge-card-avail', text: avail == null ? 'check pantry to see supply'
            : `${avail.toLocaleString()} from transcripts${cur ? ` · +${cur.toLocaleString()} curricula` : ''}` }),
        ]),
      ]));
    });
  }
  async function forgePantry() {
    const b = $('btnForgePantry');
    b.disabled = true; b.textContent = 'SCANNING…';
    log('forge: scanning transcripts, run ledger, step log and data/training…');
    try {
      forge.pantry = await api('GET', '/api/hub/forge/pantry');
      const p = forge.pantry;
      log(`forge pantry: ${p.episodes} episodes, ${p.steps} step records, ${p.tools_seen} tools` +
        ((p.curricula_skipped_eval_only || []).length ? ` · eval-only (never trained on): ${p.curricula_skipped_eval_only.join(', ')}` : ''));
      loadForge();
    } catch (e) { log(`pantry failed: ${e.message}`); }
    b.disabled = false; b.textContent = 'CHECK PANTRY';
  }
  function forgeShow(j) {
    const box = $('wbForgeResult');
    box.hidden = false;
    clear(box);
    if (j.state === 'running') {
      box.append(el('div', { cls: 'forge-status running', text: `Forging… ${j.phase || ''}` }));
      return;
    }
    if (j.state === 'error') { box.append(el('div', { cls: 'wb-bad', text: `forge failed: ${j.error || 'unknown error'}` })); return; }
    box.append(el('div', { cls: 'forge-status done', text: `[COMPLETED] ${j.done ?? '?'} / ${j.total ?? '?'} samples → ${j.out || ''}` }));
    if (j.shortfall) box.append(el('div', { cls: 'wb-muted', text: `Short by ${j.shortfall}: not enough unique material for that focus. The forge never pads with duplicates — widen the focus, add curricula, or enable the local LLM.` }));
    box.append(el('div', { cls: 'wb-muted', text: 'Open preview.md in that folder and read a few samples before training. The new files are now in YOUR DATASETS and the kit dropdowns.' }));
  }
  async function forgePoll() {
    try {
      const jobs = await api('GET', '/api/hub/jobs');
      const j = jobs.find((x) => x.name === 'forge');
      if (!j) return;
      forgeShow(j);
      if (j.state !== 'running') {
        clearInterval(forge.timer); forge.timer = null;
        $('btnForgeBuild').disabled = false;
        if (j.state === 'done') { log(`forge: ${j.done} samples written to ${j.out}`); loadTrain(); }
      }
    } catch (e) { /* transient */ }
  }
  async function forgeBuild() {
    const focus = [...$('wbForgeRecipes').querySelectorAll('input:checked')].map((i) => i.value);
    const count = parseInt($('wbForgeCount').value, 10);
    if (!focus.length) { log('forge: pick at least one recipe'); return; }
    if (!(count >= 1 && count <= 200000)) { log('forge: sample count must be 1-200000'); return; }
    const body = { focus: focus.length === Object.keys(forge.recipes || {}).length ? 'mix' : focus.join(','),
      count, format: $('wbForgeFormat').value, augment_llm: $('wbForgeLlm').checked,
      include_curricula: $('wbForgeCurricula').checked };
    $('btnForgeBuild').disabled = true;
    try {
      await api('POST', '/api/hub/forge/build', body);
      log(`forge: building ${count} samples (${body.focus})${body.augment_llm ? ' with local-LLM augmentation' : ''}…`);
      forgeShow({ state: 'running', phase: 'starting' });
      clearInterval(forge.timer);
      forge.timer = setInterval(forgePoll, 2500);
    } catch (e) { log(`forge failed: ${e.message}`); $('btnForgeBuild').disabled = false; }
  }

  async function loadKits() {
    const box = $('wbKitList');
    try {
      const kits = await api('GET', '/api/hub/train/kits');
      clear(box);
      if (!kits.length) box.append(el('div', { cls: 'wb-muted', text: 'No kits yet.' }));
      kits.forEach((k) => box.append(el('div', { cls: 'hub-item' }, [el('div', { cls: 'hub-item-main' }, [
        el('span', { cls: 'hub-item-title', text: `${k.name} · base ${k.base_model}` }),
        el('span', { cls: 'hub-item-meta', text: `${k.dir} · train ${k.train_file}` }),
      ])])));
    } catch (e) { clear(box); box.append(el('div', { cls: 'wb-bad', text: e.message })); }
  }
  async function exportRuns() {
    const since = $('wbExportSince').value;
    log('exporting successful runs as chat-format training data…');
    try {
      const r = await api('POST', '/api/hub/datasets/export-runs', since ? { since } : {});
      log(`export: ${r.train ?? r.train_rows ?? '?'} train / ${r.val ?? r.val_rows ?? '?'} val examples → ${r.out || ''}`);
      loadTrain();
    } catch (e) { log(`export failed: ${e.message}`); }
  }
  async function dsFiles() {
    const repo = $('wbDsRepo').value.trim();
    const box = $('wbDsFiles');
    clear(box);
    if (!/^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/.test(repo)) { box.append(el('div', { cls: 'wb-bad', text: 'enter a dataset repo id like org/name' })); return; }
    box.append(el('div', { cls: 'wb-muted', text: 'listing…' }));
    try {
      const r = await api('GET', `/api/hub/datasets/files?repo=${encodeURIComponent(repo)}`);
      clear(box);
      if (!(r.files || []).length) box.append(el('div', { cls: 'wb-muted', text: 'no .jsonl / .json / .parquet / .csv files found' }));
      (r.files || []).forEach((f) => box.append(el('div', { cls: 'hub-item' }, [
        el('div', { cls: 'hub-item-main' }, [el('span', { cls: 'hub-item-title', text: f.path }), el('span', { cls: 'hub-item-meta', text: `${bytes(f.size)}${f.sha256 ? ' · sha256-verified download' : ' · no checksum published'}` })]),
        btn('PULL', async () => {
          try { await api('POST', '/api/hub/datasets/pull', { repo, path: f.path }); log(`pulling ${repo}/${f.path} into data/training/active/`); setTimeout(loadJobs, 800); setTimeout(loadTrain, 4000); } catch (e) { log(`pull failed: ${e.message}`); }
        }, 'primary'),
      ])));
    } catch (e) { clear(box); box.append(el('div', { cls: 'wb-bad', text: e.message })); }
  }
  async function makeKit() {
    const cfg = {
      name: $('wbKitName').value.trim(), base_model: $('wbKitBase').value.trim(), train: $('wbKitTrain').value,
      epochs: parseFloat($('wbKitEpochs').value), learning_rate: parseFloat($('wbKitLr').value),
      lora_r: parseInt($('wbKitR').value, 10), lora_alpha: parseInt($('wbKitAlpha').value, 10),
      max_seq_len: parseInt($('wbKitSeq').value, 10), load_in_4bit: $('wbKit4bit').checked,
      mode: $('wbKitMode').value,
    };
    if (cfg.mode === 'dpo' && !/dpo_/.test(cfg.train)) log('note: DPO needs a preference set (dpo_train.jsonl from the forge)');
    if ($('wbKitVal').value) cfg.val = $('wbKitVal').value;
    if (!cfg.train) { log('pick a training set first (export runs or pull a dataset)'); return; }
    try {
      const r = await api('POST', '/api/hub/train/kit', cfg);
      log(`kit "${r.kit}" written to ${r.dir}\nnext: ${r.next}`);
      loadKits();
    } catch (e) { log(`kit failed: ${e.message}`); }
  }

  // ── Model Copilot ─────────────────────────────────────────────────────────
  function autoGrow() {
    const t = $('hubAskInput');
    t.style.height = 'auto';
    t.style.height = `${Math.min(t.scrollHeight + 2, 320)}px`;
    $('wbAskCount').textContent = `${t.value.length} / 4000 · Ctrl+Enter to send`;
  }
  async function ask() {
    const q = $('hubAskInput').value.trim();
    if (!q) { $('hubAskInput').focus(); return; }
    const out = $('hubAskOutput');
    out.hidden = false;
    out.textContent = 'George is reading your hardware, library and the hubs… (read-only tools; it can draft profiles, never install or serve them)';
    $('btnHubAsk').disabled = true;
    try {
      const r = await api('POST', '/api/hub/ask', { question: q });
      clearInterval(state.askTimer);
      const started = Date.now();
      state.askTimer = setInterval(async () => {
        try {
          const s = await api('GET', `/api/hub/ask/${encodeURIComponent(r.run_id)}`);
          const secs = Math.round((Date.now() - started) / 1000);
          if (s.reply) {
            out.textContent = s.reply;
            clearInterval(state.askTimer); $('btnHubAsk').disabled = false;
            loadProfiles();
          } else if (s.status && s.status !== 'RUNNING' && s.status !== 'STARTING') {
            out.textContent = `Run ${r.run_id} ended (${s.outcome || s.status}) without a reply. Check Runs for details.`;
            clearInterval(state.askTimer); $('btnHubAsk').disabled = false;
          } else {
            out.textContent = `George is working… ${secs}s (run ${r.run_id})`;
          }
          if (secs > 1800) { clearInterval(state.askTimer); $('btnHubAsk').disabled = false; }
        } catch (e) { clearInterval(state.askTimer); $('btnHubAsk').disabled = false; out.textContent = `status failed: ${e.message}`; }
      }, 3000);
    } catch (e) { out.textContent = `ask failed: ${e.message}`; $('btnHubAsk').disabled = false; }
  }

  // ── Wiring ────────────────────────────────────────────────────────────────
  async function refreshLibraryAndProfiles() {
    await Promise.all([loadProfiles(), loadLibrary()]);
  }
  async function refreshAll() {
    loadHw(); loadAccounts(); loadPresets(); loadJobs();
    await loadServer();
    await refreshLibraryAndProfiles();
    renderLibrary();
    if (!$('wbPanelTrain').hidden) loadTrain();
  }

  const openBtn = $('headerModelsBtn');
  if (openBtn) openBtn.addEventListener('click', openModal);
  $('modelsModalClose').addEventListener('click', closeModal);
  $('modelsModalDismiss').addEventListener('click', closeModal);
  modal.addEventListener('click', (e) => { if (e.target === modal) closeModal(); });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && state.open) closeModal(); });
  $('btnModelsRefresh').addEventListener('click', refreshAll);
  $('btnWbRollback').addEventListener('click', rollback);
  document.querySelectorAll('.wb-tab').forEach((t) => t.addEventListener('click', () => showTab(t.dataset.panel)));

  $('wbLibFilters').addEventListener('click', (e) => {
    const b = e.target.closest('.model-filter-btn');
    if (!b) return;
    state.kind = b.dataset.kind;
    $('wbLibFilters').querySelectorAll('.model-filter-btn').forEach((x) => x.classList.toggle('active', x === b));
    renderLibrary();
  });
  $('wbLibSearch').addEventListener('input', (e) => { state.q = e.target.value.trim(); renderLibrary(); });
  $('wbLibSort').addEventListener('change', (e) => { state.sort = e.target.value; renderLibrary(); });

  $('btnHubSearch').addEventListener('click', () => search());
  $('btnForgePantry').addEventListener('click', forgePantry);
  $('btnForgeBuild').addEventListener('click', forgeBuild);
  $('wbForgeCountRange').addEventListener('input', (e) => { $('wbForgeCount').value = e.target.value; });
  $('wbForgeCount').addEventListener('input', (e) => {
    const v = parseInt(e.target.value, 10);
    if (v >= 50 && v <= 5000) $('wbForgeCountRange').value = String(v);
  });
  $('hubSearchInput').addEventListener('keydown', (e) => { if (e.key === 'Enter') search(); });
  document.querySelectorAll('#wbPanelDiscover .wb-chip[data-q]').forEach((c) => c.addEventListener('click', () => search(c.dataset.q)));
  $('btnHubApprove').addEventListener('click', approve);
  $('btnHubReviewClose').addEventListener('click', () => { $('hubReview').hidden = true; state.reviewing = null; });
  $('btnHubLogin').addEventListener('click', login);
  $('btnHubLogout').addEventListener('click', logout);

  $('btnWbExport').addEventListener('click', exportRuns);
  $('btnWbDsFiles').addEventListener('click', dsFiles);
  $('wbDsRepo').addEventListener('keydown', (e) => { if (e.key === 'Enter') dsFiles(); });
  $('btnWbKit').addEventListener('click', makeKit);
  ['wbKitTrain', 'wbKitVal'].forEach((id) => $(id).addEventListener('change', () => { $(id).dataset.touched = '1'; }));

  $('btnHubAsk').addEventListener('click', ask);
  $('hubAskInput').addEventListener('input', autoGrow);
  $('hubAskInput').addEventListener('keydown', (e) => { if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) { e.preventDefault(); ask(); } });
  document.querySelectorAll('#wbAskChips .wb-chip').forEach((c) => c.addEventListener('click', () => {
    $('hubAskInput').value = c.dataset.ask; autoGrow(); $('hubAskInput').focus();
  }));

  // Opened by other code paths (e.g. command palette) that only toggle style.display.
  new MutationObserver(() => {
    const visible = modal.style.display !== 'none';
    if (visible && !state.open) openModal();
    if (!visible) state.open = false;
  }).observe(modal, { attributes: true, attributeFilter: ['style'] });
})();
