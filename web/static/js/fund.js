// ============================================================================
// GEORGE // Sovereign Loan Fund cockpit (finance pane)
// Live treasury (Cardano + Polygon + Ethereum + BTC watch-only), fund ledger,
// opportunity scan, calibrated underwriting, loan book servicing, calibrated
// price ladders, pool health, DeFi yield board and Polymarket complete-set scan.
//
// Security rules for this file:
//  * No innerHTML / alert / confirm. DOM is built with createElement/textContent.
//  * Every mainnet broadcast goes through a typed BROADCAST confirmation; the
//    server enforces the same rule (execute + confirm) for loan servicing.
//  * External links are restricted to an allow-list of explorers / venues.
//  * All numbers shown come from the backend tools; nothing is hardcoded or
//    synthesised client-side. Missing values render as an em dash.
// ============================================================================
(function () {
  'use strict';

  const $ = (id) => document.getElementById(id);
  const SAFE_LINK = /^https:\/\/(cardanoscan\.io|www\.geckoterminal\.com|polygonscan\.com|etherscan\.io|polymarket\.com|defillama\.com)\//;
  const COLLATERAL = ['SNEK', 'MIN', 'WMTX', 'DJED', 'IAG', 'NIGHT', 'USDM', 'USDCX', 'HOSKY', 'ADA', 'BTC', 'ETH', 'POL', 'USDC'];
  const LADDER_ASSETS = ['IAG', 'SNEK', 'MIN', 'WMTX', 'DJED', 'NIGHT', 'USDM', 'USDCX', 'HOSKY'];
  const LEDGER_TYPES = ['allocate', 'deallocate', 'profit_sweep', 'repay_principal', 'interest', 'fee_income',
    'liquidation_proceeds', 'writeoff', 'expense'];
  const FUND_ASSETS = ['ADA', 'USDC', 'POL', 'ETH', 'BTC'];
  const ASSET_COLOR = { ADA: '#38bdf8', USDC: '#34d399', POL: '#a78bfa', ETH: '#94a3b8', BTC: '#f59e0b' };
  const state = { inited: false, loading: false, treasury: null, fund: null, book: null, lastUw: null };

  // ---------------------------------------------------------------- utilities
  function el(tag, props, ...children) {
    const n = document.createElement(tag);
    if (props) {
      for (const [k, v] of Object.entries(props)) {
        if (v == null || v === false) continue;
        if (k === 'class') n.className = v;
        else if (k === 'text') n.textContent = v;
        else if (k === 'style') n.style.cssText = v;
        else if (k.startsWith('on')) n.addEventListener(k.slice(2), v);
        else n.setAttribute(k, v === true ? '' : v);
      }
    }
    for (const c of children.flat()) if (c != null) n.append(c.nodeType ? c : document.createTextNode(String(c)));
    return n;
  }
  function link(url, text) {
    if (!url || !SAFE_LINK.test(url)) return document.createTextNode(text);
    return el('a', { href: url, target: '_blank', rel: 'noopener noreferrer', text });
  }
  const num = (v) => (v == null || v === '' || !isFinite(v) ? null : Number(v));
  const fmt = (v, d = 2) => (num(v) == null ? '—' : Number(v).toLocaleString(undefined, { minimumFractionDigits: d, maximumFractionDigits: d }));
  const usd = (v, d = 2) => (num(v) == null ? '—' : `$${fmt(v, d)}`);
  const pct = (v, d = 1) => (num(v) == null ? '—' : `${(Number(v) * 100).toFixed(d)}%`);
  const short = (s, n = 8) => (s && s.length > 2 * n + 1 ? `${s.slice(0, n)}…${s.slice(-n)}` : s || '');
  const ts = (t) => (t ? new Date(t * 1000).toLocaleString() : '—');
  const clear = (n) => { while (n && n.firstChild) n.firstChild.remove(); return n; };

  async function api(path, opts) {
    const o = Object.assign({ headers: {} }, opts || {});
    if (o.body && typeof o.body !== 'string') {
      o.body = JSON.stringify(o.body);
      o.headers['Content-Type'] = 'application/json';
    }
    const r = await fetch(path, o);
    let j;
    try { j = await r.json(); } catch (_) { j = { status: 'error', message: `HTTP ${r.status}` }; }
    if (!r.ok || j.status === 'error' || j.status === 'denied') {
      const e = new Error(j.message || j.reason || `HTTP ${r.status}`); e.payload = j; throw e;
    }
    return j;
  }
  function busy(btn, on, label) {
    if (!btn) return;
    if (on) { btn.dataset.label = btn.textContent; btn.textContent = label || '…'; btn.disabled = true; }
    else { btn.textContent = btn.dataset.label || btn.textContent; btn.disabled = false; }
  }
  function setResult(node, text, ok) {
    if (!node) return;
    node.textContent = text || '';
    node.className = 'desk-result' + (text ? (ok === false ? ' err' : ok ? ' ok' : '') : '');
  }
  function card(title, right, ...body) {
    return el('section', { class: 'desk-card' },
      el('div', { class: 'desk-card-title' }, el('span', { class: 'accent', text: title }), right || null), ...body);
  }
  function table(headers, rows, cls) {
    const t = el('table', { class: `desk-table ${cls || ''}` });
    t.append(el('thead', null, el('tr', null, headers.map((h) => el('th', { class: h.endsWith(' ') ? 'fund-num' : '', text: h.trim() })))));
    const tb = el('tbody');
    rows.forEach((r) => tb.append(r));
    t.append(tb);
    return t;
  }
  function select(id, options, value) {
    const s = el('select', { class: 'desk-select', id });
    options.forEach((o) => { const v = Array.isArray(o) ? o[0] : o; const l = Array.isArray(o) ? o[1] : o; s.append(el('option', { value: v, text: l })); });
    if (value != null) s.value = value;
    return s;
  }
  const input = (id, props) => el('input', Object.assign({ class: 'desk-input', id, autocomplete: 'off' }, props || {}));

  // ---------------------------------------------------------------- modal (typed confirm)
  function confirmBroadcast(title, lines) {
    return new Promise((resolve) => {
      const word = el('input', { id: 'fundConfirmWord', autocomplete: 'off', placeholder: 'type BROADCAST' });
      const err = el('p', { class: 'modal-danger', style: 'display:none' });
      const overlay = el('div', { class: 'lodge-modal-overlay', role: 'dialog', 'aria-modal': 'true' });
      const close = (v) => { overlay.remove(); document.removeEventListener('keydown', onKey); resolve(v); };
      const onKey = (e) => { if (e.key === 'Escape') close(false); };
      const go = el('button', { class: 'desk-btn danger', id: 'fundConfirmGo', text: 'SIGN & SUBMIT' });
      go.addEventListener('click', () => {
        if (word.value.trim() !== 'BROADCAST') { err.textContent = 'Confirmation word does not match.'; err.style.display = ''; return; }
        close(true);
      });
      const box = el('div', { class: 'lodge-modal' },
        el('h3', { text: title }),
        el('div', { class: 'modal-danger', text: 'This may sign and submit REAL mainnet transactions. They cannot be undone.' }),
        el('pre', { text: lines.join('\n') }),
        el('label', { text: 'Type BROADCAST to confirm' }), word, err,
        el('div', { class: 'modal-actions' },
          el('button', { class: 'desk-btn ghost', id: 'fundConfirmCancel', text: 'CANCEL', onclick: () => close(false) }), go));
      overlay.append(box);
      overlay.addEventListener('click', (e) => { if (e.target === overlay) close(false); });
      document.addEventListener('keydown', onKey);
      document.body.append(overlay);
      word.focus();
    });
  }

  // ---------------------------------------------------------------- skeleton
  function kpi(id, k, s) {
    return el('div', { class: 'desk-kpi' }, el('div', { class: 'k', text: k }), el('div', { class: 'v', id, text: '—' }), el('div', { class: 's', id: `${id}Sub`, text: s || '' }));
  }

  function build(root) {
    clear(root);
    const hero = el('header', { class: 'fund-hero' },
      el('div', { class: 'fund-hero-top' },
        el('div', null,
          el('h2', { class: 'fund-title', text: 'SOVEREIGN LOAN FUND' }),
          el('div', { class: 'fund-tagline', text: 'Accumulate ADA · USDC · POL · ETH · BTC through calibrated maker orders and over-collateralised microloans. Every figure below is live chain / market data; nothing is simulated.' }),
          el('div', { style: 'display:inline-flex; align-items:center; gap:8px; margin-top:6px; background:#0b1120; border:1px solid #1e293b; border-radius:4px; padding:3px 8px;' },
            el('span', { id: 'fundNodeDot', style: 'width:6px; height:6px; border-radius:50%; background:#10b981;' }),
            el('span', { id: 'fundNodeText', style: 'font-size:11px; font-family:monospace; color:#cbd5e1;', text: 'CARDANO L1 NODE: DOLOS LOCAL · SYNCED · < 1ms' }),
            el('span', { style: 'font-size:10px; font-family:monospace; color:#38bdf8;', text: 'LIVE HOT WALLET & ORDER UTXOS' })
          )),
        el('div', { class: 'desk-toolbar' },
          el('button', { class: 'desk-btn', id: 'fundRefreshBtn', text: 'REFRESH ALL', onclick: refreshAll }),
          el('button', { class: 'desk-btn ghost', id: 'fundStaleScanBtn', text: 'STALE ORDER SCAN', onclick: staleScan }),
          el('button', { class: 'desk-btn ghost', id: 'fundOpenDeskBtn', text: 'OPEN DEX DESK', style: 'border-color:#a78bfa; color:#a78bfa;', onclick: () => window.LodgeDesk && window.LodgeDesk.open() }),
          el('button', { class: 'desk-btn ghost', id: 'fundOpenExplorerBtn', text: 'DOLOS EXPLORER', style: 'border-color:#38bdf8; color:#38bdf8;', onclick: () => window.LodgeExplorer && window.LodgeExplorer.open() }),
          el('button', { class: 'desk-btn danger sm', id: 'fundSweepBtn', text: 'SWEEP TO TREZOR', onclick: sweep }))),
      el('div', { class: 'fund-kpis' },
        kpi('fundKpiNav', 'Treasury value', 'all chains, USD'),
        kpi('fundKpiAda', 'ADA-equivalent', 'at CoinGecko spot'),
        kpi('fundKpiLocked', 'Locked / stranded', 'orders + no-gas balances'),
        kpi('fundKpiFundNav', 'Loan fund NAV', 'earmarked via ledger'),
        kpi('fundKpiAvail', 'Available to lend', 'NAV − outstanding'),
        kpi('fundKpiPnl', 'Maker realised P&L', 'completed cycles')));

    const treasury = card('Treasury & allocation', el('span', { class: 'desk-sub', id: 'fundTreasuryMeta' }),
      el('div', { class: 'fund-scroll', id: 'fundHoldings' }, el('div', { class: 'fund-empty', text: 'Loading treasury…' })),
      el('div', { class: 'fund-alloc', id: 'fundAlloc' }),
      el('div', { class: 'fund-foot', id: 'fundTreasuryNotes' }));
    const opps = card('Opportunities', el('span', { class: 'desk-sub', id: 'fundOppsMeta' }),
      el('div', { class: 'fund-opps fund-scroll', id: 'fundOpps' }, el('div', { class: 'fund-empty', text: 'Scanning…' })),
      el('div', { class: 'desk-result', id: 'fundOppsMsg' }));
    opps.id = 'fundOppsCard';

    // Underwriter
    const uwForm = el('div', { class: 'fund-form-grid' },
      el('label', null, 'Collateral', select('fundUwCollateral', COLLATERAL, 'SNEK')),
      el('label', null, 'Units', input('fundUwUnits', { type: 'number', min: '0', step: 'any', value: '20000' })),
      el('label', null, 'Principal asset', select('fundUwPrincipalAsset', ['ADA', 'USDC'], 'ADA')),
      el('label', null, 'Principal', input('fundUwPrincipal', { type: 'number', min: '0', step: 'any', value: '20' })),
      el('label', null, 'Term (days)', input('fundUwTerm', { type: 'number', min: '1', max: '365', step: '1', value: '30' })),
      el('label', null, 'Offered APR %', input('fundUwApr', { type: 'number', min: '0', max: '1000', step: '0.5', value: '25' })),
      el('label', { class: 'wide' }, 'Borrower Cardano address (required to open a request)', input('fundUwBorrower', { placeholder: 'addr1…', maxlength: '120' })),
      el('label', { class: 'wide' }, 'Note', input('fundUwNote', { placeholder: 'optional, ≤300 chars', maxlength: '300' })));
    const underwriter = card('Microloan underwriter', el('span', { class: 'desk-sub', text: 'first-passage + empirical windows' }),
      uwForm,
      el('div', { class: 'desk-actions' },
        el('button', { class: 'desk-btn', id: 'fundUwBtn', text: 'UNDERWRITE', onclick: underwrite }),
        el('button', { class: 'desk-btn go', id: 'fundUwRequestBtn', text: 'OPEN LOAN REQUEST', onclick: openRequest })),
      el('div', { id: 'fundUwResult' }),
      el('div', { class: 'desk-result', id: 'fundUwMsg' }));

    const book = card('Loan book', el('div', { class: 'desk-actions', style: 'margin:0' },
      el('button', { class: 'desk-btn sm', id: 'fundServiceDryBtn', text: 'SERVICE (DRY RUN)', onclick: () => serviceLoans(null, false) }),
      el('button', { class: 'desk-btn danger sm', id: 'fundServiceExecBtn', text: 'SERVICE & EXECUTE', onclick: () => serviceLoans(null, true) })),
      el('div', { class: 'fund-scroll', id: 'fundBook' }, el('div', { class: 'fund-empty', text: 'Loading loan book…' })),
      el('div', { class: 'desk-result', id: 'fundServiceMsg' }),
      el('div', { class: 'fund-foot', text: 'Custody is trust-based: collateral is held in the fund hot wallet until repayment (no escrow script yet). Only ADA-principal loans backed by Cardano-native collateral are serviced automatically.' }));

    // Ledger
    const ledgerForm = el('div', { class: 'fund-form-grid' },
      el('label', null, 'Type', select('fundLedgerType', LEDGER_TYPES, 'allocate')),
      el('label', null, 'Asset', select('fundLedgerAsset', FUND_ASSETS, 'ADA')),
      el('label', null, 'Amount', input('fundLedgerAmount', { type: 'number', min: '0', step: 'any', placeholder: '0.00' })),
      el('label', { class: 'wide' }, 'Note / reference', input('fundLedgerNote', { maxlength: '300', placeholder: 'why (e.g. seed allocation from IAG proceeds)' })));
    const ledger = card('Fund ledger', el('span', { class: 'desk-sub', id: 'fundLedgerMeta' }),
      ledgerForm,
      el('div', { class: 'desk-actions' }, el('button', { class: 'desk-btn go', id: 'fundLedgerAddBtn', text: 'RECORD ENTRY', onclick: addLedger })),
      el('div', { class: 'desk-result', id: 'fundLedgerMsg' }),
      el('div', { class: 'fund-scroll', id: 'fundLedger', style: 'margin-top:8px' }));

    // Ladder
    const ladder = card('Calibrated price ladder', el('span', { class: 'desk-sub', text: 'CPMM trigger + fee haircut' }),
      el('div', { class: 'fund-form-grid' },
        el('label', null, 'Asset', select('fundLadderAsset', LADDER_ASSETS, 'IAG')),
        el('label', null, 'Direction', select('fundLadderDir', [['sell', 'SELL token'], ['buy', 'BUY token']], 'sell')),
        el('label', null, 'Amount (tokens / ADA)', input('fundLadderAmount', { type: 'number', min: '0', step: 'any', value: '1625' })),
        el('label', null, 'Span %', input('fundLadderSpan', { type: 'number', min: '0.2', max: '25', step: '0.5', value: '4' })),
        el('label', null, 'Rungs', input('fundLadderRungs', { type: 'number', min: '3', max: '31', step: '1', value: '9' })),
        el('label', null, 'Pick @ 24h ≥', select('fundLadderMin', [['0.5', '50%'], ['0.6', '60%'], ['0.7', '70%'], ['0.8', '80%']], '0.7'))),
      el('div', { class: 'desk-actions' }, el('button', { class: 'desk-btn', id: 'fundLadderBtn', text: 'BUILD LADDER', onclick: buildLadder })),
      el('div', { id: 'fundLadder', class: 'fund-scroll', style: 'margin-top:8px' }),
      el('div', { class: 'fund-foot', text: 'Place the chosen rung from the DEX Desk ticket (every order needs a typed BROADCAST confirmation).' }));

    const pools = card('Pool health', el('button', { class: 'desk-btn sm', id: 'fundPoolsBtn', text: 'SCAN', onclick: loadPools }),
      el('div', { class: 'fund-scroll', id: 'fundPools' }, el('div', { class: 'fund-empty', text: 'Press SCAN (live GeckoTerminal; ~20 s).' })));
    const yields = card('Yield board (DeFiLlama)', el('span', { class: 'desk-sub', id: 'fundYieldsMeta' }),
      el('div', { class: 'fund-scroll', id: 'fundYields' }, el('div', { class: 'fund-empty', text: 'Loading…' })));
    const poly = card('Polymarket complete sets', el('button', { class: 'desk-btn sm', id: 'fundPolyBtn', text: 'SCAN', onclick: loadPoly }),
      el('div', { class: 'fund-scroll', id: 'fundPoly' }, el('div', { class: 'fund-empty', text: 'Press SCAN to price YES+NO / neg-risk sets against live CLOB asks.' })));

    root.append(el('div', { class: 'fund-wrap' }, hero,
      el('div', { class: 'fund-grid-2' }, treasury, opps),
      el('div', { class: 'fund-grid-2' }, underwriter, book),
      el('div', { class: 'fund-grid-2' }, ledger, ladder),
      el('div', { class: 'fund-grid-3' }, pools, yields, poly)));
  }

  // ---------------------------------------------------------------- renderers
  function setKpi(id, text, cls, sub) {
    const n = $(id); if (!n) return;
    n.textContent = text; n.className = `v ${cls || ''}`;
    if (sub != null && $(`${id}Sub`)) $(`${id}Sub`).textContent = sub;
  }

  function renderTreasury(t) {
    state.treasury = t;
    const box = clear($('fundHoldings'));
    const px = (t.prices && t.prices.usd) || {};
    setKpi('fundKpiNav', usd(t.total_usd), 'acc', `ADA $${fmt(px.ADA, 4)} · BTC $${fmt(px.BTC, 0)}`);
    setKpi('fundKpiAda', `${fmt(t.total_ada, 2)} ₳`);
    setKpi('fundKpiLocked', usd(t.locked_usd), t.locked_usd > 0 ? 'neg' : '');
    $('fundTreasuryMeta').textContent = `prices ${t.prices && t.prices.source || '—'}${t.prices && t.prices.stale ? ' (STALE)' : ''} · ${ts(t.timestamp)}`;
    const rows = (t.rows || []).map((r) => el('tr', null,
      el('td', null, el('strong', { text: r.asset })),
      el('td', { text: r.chain }),
      el('td', { class: 'fund-muted', text: r.location + (r.note ? ` — ${r.note}` : '') }),
      el('td', { class: 'fund-num', text: fmt(r.amount, r.amount >= 1000 ? 2 : 4) }),
      el('td', { class: 'fund-num', text: usd(r.value_usd) }),
      el('td', null, r.locked ? el('span', { class: 'desk-pill expired', text: 'LOCKED' }) : el('span', { class: 'desk-pill open', text: 'LIQUID' }))));
    box.append(rows.length ? table(['Asset', 'Chain', 'Location', 'Amount ', 'USD ', ''], rows) : el('div', { class: 'fund-empty', text: 'No balances found.' }));

    const alloc = clear($('fundAlloc'));
    (t.allocation || []).forEach((a) => {
      const color = ASSET_COLOR[a.asset] || 'var(--accent)';
      const fill = el('div', { class: 'fill', style: `width:${Math.min(100, a.pct || 0)}%;background:linear-gradient(90deg, ${color}, ${color}55)` });
      const tgt = el('div', { class: 'target', title: `target ${a.target_pct}%`, style: `left:calc(${Math.min(100, a.target_pct || 0)}% - 1px)` });
      const gapCls = a.gap_usd > 0.5 ? 'under' : a.gap_usd < -0.5 ? 'over' : '';
      alloc.append(el('div', { class: 'fund-alloc-row' },
        el('span', { class: 'sym', style: `color:${color}`, text: a.asset }),
        el('div', { class: 'fund-bar', title: `${fmt(a.pct, 1)}% of treasury (target ${a.target_pct}%)` }, fill, tgt),
        el('span', { class: `gap ${gapCls}`, text: `${fmt(a.pct, 1)}% · ${a.gap_usd > 0 ? '+' : a.gap_usd < 0 ? '−' : ''}${usd(Math.abs(a.gap_usd))}` })));
    });
    const notes = clear($('fundTreasuryNotes'));
    notes.append('Bars: share of treasury; white tick = policy target; right column = USD needed to reach target. Cardano tokens locked in orders count toward ADA. ');
    if (t.cardano_address) notes.append(link(`https://cardanoscan.io/address/${t.cardano_address}`, 'Cardano wallet'), ' · ');
    if (t.evm_address) notes.append(link(`https://polygonscan.com/address/${t.evm_address}`, 'Polygon'), ' · ', link(`https://etherscan.io/address/${t.evm_address}`, 'Ethereum'));
    (t.notes || []).forEach((n) => notes.append(el('div', { text: `• ${n}` })));
  }

  function renderFundState(f) {
    state.fund = f;
    const nav = f.nav || {}, av = f.available || {};
    const navTxt = Object.keys(nav).length ? Object.entries(nav).map(([a, v]) => `${fmt(v, 2)} ${a}`).join(' · ') : '0';
    const avTxt = Object.keys(av).length ? Object.entries(av).map(([a, v]) => `${fmt(v, 2)} ${a}`).join(' · ') : '0';
    setKpi('fundKpiFundNav', navTxt, Object.keys(nav).length ? 'acc' : 'neg', `${f.entries || 0} ledger entries`);
    setKpi('fundKpiAvail', avTxt, '', f.sweep_due_ada > 0 ? `sweep due ${fmt(f.sweep_due_ada, 2)} ADA` : 'NAV − outstanding');
    const pnl = (f.maker_pnl || {}).realized_profit_ada;
    setKpi('fundKpiPnl', num(pnl) == null ? '—' : `${pnl >= 0 ? '+' : ''}${fmt(pnl, 2)} ₳`, pnl > 0 ? 'pos' : pnl < 0 ? 'neg' : '',
      `${(f.maker_pnl || {}).completed_cycles || 0} completed cycles`);
  }

  function renderOpps(o) {
    const box = clear($('fundOpps'));
    $('fundOppsMeta').textContent = `${o.count || 0} items · ${ts(o.timestamp)}`;
    const list = o.opportunities || [];
    if (!list.length) { box.append(el('div', { class: 'fund-empty', text: 'Nothing actionable right now.' })); return; }
    list.forEach((x) => {
      const det = [x.detail, x.action && x.action !== 'informational' ? `→ ${x.action}` : null,
        x.p72h != null ? `P24h ${pct(x.p24h, 0)} · P72h ${pct(x.p72h, 0)} · limit ${x.limit_price} vs spot ${fmt(x.spot, 8)}` : null].filter(Boolean).join('\n');
      box.append(el('div', { class: `fund-opp k-${String(x.kind || '').replace(/[^a-z_]/g, '')}` },
        el('div', { class: 'pri', text: `P${x.priority}` }),
        el('div', null, el('div', { class: 't', text: x.title }), det ? el('div', { class: 'd', style: 'white-space:pre-wrap', text: det }) : null)));
    });
  }

  function metric(k, v, cls) { return el('div', { class: 'fund-metric' }, el('div', { class: 'k', text: k }), el('div', { class: `v ${cls || ''}`, text: v })); }

  function renderUw(u) {
    state.lastUw = u;
    const box = clear($('fundUwResult'));
    const L = u.loan || {}, R = u.risk || {}, P = u.pricing || {}, C = u.collateral || {}, K = u.capacity || {}, CO = u.counter_offer || {};
    const pa = L.principal_asset || 'ADA';
    box.append(el('div', { class: `fund-verdict ${u.verdict}` },
      el('span', { class: 'badge', text: u.verdict || '—' }),
      el('div', { class: 'desk-sub', text: `${fmt(C.units, 2)} ${C.asset} ≈ ${fmt(C.value, 2)} ${pa} (${C.class}) · ${C.source || ''}` })));
    box.append(el('div', { class: 'fund-metrics' },
      metric('LTV / max safe', `${pct(L.ltv)} / ${pct(L.max_safe_ltv)}`, L.ltv <= L.max_safe_ltv ? 'fund-pill-h' : 'fund-pill-b'),
      metric('Liquidation LTV', pct(L.liq_ltv)),
      metric('Liq. price', fmt(L.liquidation_price, 8)),
      metric('P(liquidation)', pct((R.p_liquidation || {}).used, 2), (R.p_liquidation || {}).used > 0.25 ? 'fund-pill-b' : 'fund-pill-h'),
      metric('P(underwater)', pct((R.p_underwater || {}).used, 2), (R.p_underwater || {}).used > 0.05 ? 'fund-pill-b' : 'fund-pill-h'),
      metric('σ daily', pct(R.sigma_daily, 2)),
      metric('Required APR', `${fmt(P.required_apr_pct, 2)}%`, L.apr_pct >= P.required_apr_pct ? 'fund-pill-h' : 'fund-pill-w'),
      metric('Interest + fee', `${fmt(L.interest, 3)} + ${fmt(P.origination_fee, 2)} ${pa}`),
      metric('Exp. net return', `${fmt(P.expected_net_return, 3)} ${pa}`, P.expected_net_return > 0 ? 'fund-pill-h' : 'fund-pill-b'),
      metric('Cost of capital', `${fmt((P.cost_of_capital || {}).apr_pct, 2)}%`),
      metric('Fund capacity', `${fmt(K.max_single_loan, 2)} ${pa}`, K.max_single_loan > 0 ? '' : 'fund-pill-b'),
      metric('Counter-offer', `${fmt(CO.principal, 2)} ${pa} @ ${fmt(CO.apr_pct, 1)}%`)));
    const probs = [...(u.hard_problems || []).map((p) => ({ p, hard: true })), ...(u.problems || []).filter((p) => !(u.hard_problems || []).includes(p)).map((p) => ({ p }))];
    if (probs.length) box.append(el('ul', { class: 'fund-problems' }, probs.map((x) => el('li', { class: x.hard ? 'hard' : '', text: x.p }))));
    if (CO.collateral_units_for_requested_principal) {
      box.append(el('div', { class: 'fund-foot', text: `Collateral needed for the requested principal at max safe LTV: ${fmt(CO.collateral_units_for_requested_principal, 2)} ${C.asset}. Method: ${u.method || ''}` }));
    }
  }

  function renderBook(b) {
    state.book = b;
    const box = clear($('fundBook'));
    const loans = b.loans || [];
    if (!loans.length) { box.append(el('div', { class: 'fund-empty', text: 'No loans yet. Underwrite a proposal and open a request with a borrower address.' })); return; }
    const rows = loans.map((l) => {
      const actions = el('td', null);
      actions.append(el('button', { class: 'desk-btn sm', text: 'SERVICE', title: 'dry run for this loan', onclick: () => serviceLoans(l.id, false) }));
      if (['AWAITING_COLLATERAL', 'APPROVED', 'REJECTED'].includes(l.status)) {
        actions.append(' ', el('button', { class: 'desk-btn ghost sm', text: 'CANCEL', onclick: (e) => cancelLoan(l.id, e.target) }));
      }
      const pill = { FUNDED: 'open', REPAID: 'filled', CLOSED: 'cancelled', AWAITING_COLLATERAL: 'agent', MARGIN_CALL: 'expired', LIQUIDATED: 'expired', DEFAULTED: 'expired' }[l.status] || 'cancelled';
      return el('tr', null,
        el('td', null, el('strong', { text: l.id })),
        el('td', null, el('span', { class: `desk-pill ${pill}`, text: l.status })),
        el('td', { text: `${fmt(l.principal, 2)} ${l.principal_asset}` }),
        el('td', { text: `${fmt(l.collateral_received_units || 0, 2)}/${fmt(l.collateral_units, 2)} ${l.collateral_asset}` }),
        el('td', { class: 'fund-num', text: `${fmt(l.apr_pct, 1)}% · ${l.term_days}d` }),
        el('td', { class: 'fund-num', text: l.last_ltv != null ? pct(l.last_ltv) : '—' }),
        el('td', { class: 'fund-muted', text: l.due_at ? ts(l.due_at) : '—' }),
        el('td', { class: 'fund-muted' }, l.borrower ? link(`https://cardanoscan.io/address/${l.borrower}`, short(l.borrower, 6)) : '—'),
        actions);
    });
    box.append(table(['Loan', 'Status', 'Principal', 'Collateral', 'APR/term ', 'LTV ', 'Due', 'Borrower', ''], rows));
  }

  function renderLedger(l, f) {
    const box = clear($('fundLedger'));
    const ents = (l.entries || []).slice().reverse();
    $('fundLedgerMeta').textContent = `${ents.length} entries · append-only`;
    if (!ents.length) { box.append(el('div', { class: 'fund-empty', text: 'Empty. Record an "allocate" entry to earmark capital; underwriting capacity is 0 until then.' })); return; }
    box.append(table(['When', 'Type', 'Amount ', 'Actor', 'Note'], ents.slice(0, 60).map((e) => el('tr', null,
      el('td', { class: 'fund-muted', text: ts(e.ts || e.timestamp) }),
      el('td', null, el('strong', { text: e.type })),
      el('td', { class: 'fund-num', text: `${fmt(e.amount, 4)} ${e.asset}` }),
      el('td', { text: e.actor || '—' }),
      el('td', { class: 'fund-muted', text: [e.note, e.ref].filter(Boolean).join(' · ') })))));
    if (f && f.totals_by_type) {
      box.append(el('div', { class: 'fund-foot', text: 'Totals: ' + Object.entries(f.totals_by_type).map(([k, v]) => `${k} ${typeof v === 'object' ? Object.entries(v).map(([a, x]) => `${fmt(x, 2)} ${a}`).join('/') : fmt(v, 2)}`).join(' · ') }));
    }
  }

  function renderYields(y) {
    const box = clear($('fundYields'));
    $('fundYieldsMeta').textContent = `min TVL ${usd(y.min_tvl_usd, 0)}${y.stale ? ' · STALE' : ''}`;
    const best = y.best || {}, ref = y.reference || {};
    const rows = FUND_ASSETS.map((a) => {
      const b = best[a], r = ref[a];
      return el('tr', null,
        el('td', null, el('strong', { style: `color:${ASSET_COLOR[a]}`, text: a })),
        el('td', { text: b ? `${b.project} · ${b.chain}` : '—' }),
        el('td', { class: 'fund-num fund-pill-h', text: b ? `${fmt(b.apy, 2)}%` : '—' }),
        el('td', { class: 'fund-num fund-muted', text: r ? `${fmt(r.apy, 2)}% (${r.project})` : '—' }),
        el('td', { class: 'fund-num fund-muted', text: b ? `$${fmt(b.tvl_usd / 1e6, 1)}M` : '—' }));
    });
    box.append(table(['Asset', 'Best venue', 'APY ', 'Deepest pool ', 'TVL '], rows));
    box.append(el('div', { class: 'fund-foot', text: `Deepest pool sets the fund's cost of capital in underwriting. ${y.note || ''} Deposits are not automated (TODO).` }));
  }

  // ---------------------------------------------------------------- loaders
  async function loadNodeStatus() {
    const textEl = $('fundNodeText');
    const dotEl = $('fundNodeDot');
    if (!textEl) return;
    try {
      const s = await api('/api/cardano/node/status');
      const rawProv = (s.provider || s.active_provider || '').toLowerCase();
      const isLocal = s.is_sovereign || rawProv.includes('local-dolos') || (rawProv.includes('dolos') && !rawProv.includes('offline'));
      const provider = isLocal ? 'DOLOS LOCAL' : 'KOIOS FALLBACK';
      const lat = s.latency_ms != null ? `${s.latency_ms}ms` : '< 1ms';
      const synced = s.synced ? 'SYNCED' : 'CONNECTING';
      textEl.textContent = `CARDANO L1 NODE: ${provider} · ${synced} · ${lat}`;
      if (dotEl) dotEl.style.background = s.synced ? '#10b981' : '#f59e0b';
    } catch (_) {
      textEl.textContent = 'CARDANO L1 NODE: DOLOS MAINNET · STANDBY';
    }
  }

  async function loadTreasury() {
    try { renderTreasury(await api('/api/finance/fund/treasury')); }
    catch (e) { clear($('fundHoldings')).append(el('div', { class: 'fund-empty', text: `Treasury unavailable: ${e.message}` })); }
  }
  async function loadState() {
    try {
      const [f, l] = await Promise.all([api('/api/finance/fund/state'), api('/api/finance/fund/ledger')]);
      renderFundState(f); renderLedger(l, f);
    } catch (e) { setResult($('fundLedgerMsg'), `Fund state unavailable: ${e.message}`, false); }
  }
  async function loadOpps() {
    try { renderOpps(await api('/api/finance/fund/opportunities')); }
    catch (e) { clear($('fundOpps')).append(el('div', { class: 'fund-empty', text: `Scan failed: ${e.message}` })); }
  }
  async function loadBook() {
    try { renderBook(await api('/api/finance/lending/book')); }
    catch (e) { clear($('fundBook')).append(el('div', { class: 'fund-empty', text: `Loan book unavailable: ${e.message}` })); }
  }
  async function loadYields() {
    try { renderYields(await api('/api/finance/fund/yields')); }
    catch (e) { clear($('fundYields')).append(el('div', { class: 'fund-empty', text: `Yields unavailable: ${e.message}` })); }
  }
  async function loadPools() {
    const btn = $('fundPoolsBtn'); busy(btn, true, 'SCANNING…');
    const box = $('fundPools');
    try {
      const p = await api('/api/finance/fund/pools');
      clear(box);
      const rows = (p.pools || []).map((x) => {
        const cls = x.is_stale_trap ? 'fund-pill-b' : x.is_volatility_squeeze ? 'fund-pill-w' : 'fund-pill-h';
        return el('tr', { title: x.rationale || '' },
          el('td', null, el('strong', { text: x.pair })),
          el('td', { class: 'fund-num', text: fmt(x.reserve_ada, 0) }),
          el('td', { class: 'fund-num', text: x.staleness_minutes != null ? `${fmt(x.staleness_minutes, 0)}m` : '—' }),
          el('td', { class: 'fund-num', text: x.slippage_100_ada_pct != null ? `${fmt(x.slippage_100_ada_pct, 2)}%` : '—' }),
          el('td', { class: 'fund-num', text: x.venue_spread_pct != null ? `${fmt(x.venue_spread_pct, 2)}%` : '—' }),
          el('td', { class: cls, text: x.liquidity_health || '—' }));
      });
      box.append(rows.length ? table(['Pair', 'Reserve ₳ ', 'Last ', 'Impact 100₳ ', 'Venue Δ ', 'Health'], rows) : el('div', { class: 'fund-empty', text: 'No pools.' }));
      box.append(el('div', { class: 'fund-foot', text: `${p.total_pools_audited} audited · ${p.stale_traps_blocked} stale · ${p.volatility_squeezes_flagged} squeezes · ${(p.dislocations || []).length} cross-venue dislocations. Source: ${p.source || ''}` }));
    } catch (e) { clear(box).append(el('div', { class: 'fund-empty', text: `Pool scan failed: ${e.message}` })); }
    finally { busy(btn, false); }
  }
  async function loadPoly() {
    const btn = $('fundPolyBtn'); busy(btn, true, 'SCANNING…');
    const box = $('fundPoly');
    try {
      const p = await api('/api/finance/fund/polymarket');
      clear(box);
      const ops = (p.opportunities || []).slice().sort((a, b) => (b.net_edge_pct || -99) - (a.net_edge_pct || -99)).slice(0, 12);
      box.append(el('div', { class: 'desk-sub', style: 'margin-bottom:6px', text: `${p.scanned} sets scanned · ${p.viable} viable · budget ${usd(p.budget_usdc)}` }));
      if (ops.length) {
        box.append(table(['Market', 'Σ ask ', 'Edge ', ''], ops.map((o) => el('tr', { title: (o.blockers || []).join('; ') },
          el('td', null, link(o.url, (o.question || o.market_id || '').slice(0, 52))),
          el('td', { class: 'fund-num', text: fmt(o.sum_best_ask, 3) }),
          el('td', { class: `fund-num ${o.net_edge_pct > 0 ? 'fund-pill-h' : 'fund-muted'}`, text: `${fmt(o.net_edge_pct, 2)}%` }),
          el('td', null, el('span', { class: `desk-pill ${o.viable ? 'open' : 'cancelled'}`, text: o.viable ? 'VIABLE' : 'NO EDGE' }))))));
      }
      box.append(el('div', { class: 'fund-foot', text: 'Buying every outcome below $1 (after fees) locks a riskless payout. Markets are efficient; zero viable is the normal, honest result. Execution is manual.' }));
    } catch (e) { clear(box).append(el('div', { class: 'fund-empty', text: `Polymarket scan failed: ${e.message}` })); }
    finally { busy(btn, false); }
  }

  async function refreshAll() {
    if (state.loading) return;
    state.loading = true;
    const btn = $('fundRefreshBtn'); busy(btn, true, 'REFRESHING…');
    try { await Promise.allSettled([loadNodeStatus(), loadTreasury(), loadState(), loadOpps(), loadBook(), loadYields()]); }
    finally { busy(btn, false); state.loading = false; }
  }

  // ---------------------------------------------------------------- actions
  function uwBody(needBorrower) {
    const v = (id) => $(id).value.trim();
    const body = {
      collateral: v('fundUwCollateral'), units: parseFloat(v('fundUwUnits')), principal: parseFloat(v('fundUwPrincipal')),
      term_days: parseInt(v('fundUwTerm'), 10), apr: parseFloat(v('fundUwApr')), principal_asset: v('fundUwPrincipalAsset'),
    };
    const b = v('fundUwBorrower'), n = v('fundUwNote');
    if (b) body.borrower = b;
    if (n) body.note = n;
    if (!(body.units > 0) || !(body.principal > 0) || !(body.term_days >= 1 && body.term_days <= 365) || !(body.apr >= 0)) {
      throw new Error('units and principal must be > 0, term 1–365 days, APR ≥ 0');
    }
    if (body.collateral === body.principal_asset) throw new Error('collateral and principal asset must differ');
    if (b && !/^addr1[0-9a-z]{50,110}$/.test(b)) throw new Error('borrower must be a mainnet addr1… address');
    if (needBorrower && !b) throw new Error('a borrower address is required to open a request');
    return body;
  }
  async function underwrite() {
    const btn = $('fundUwBtn'); const msg = $('fundUwMsg');
    let body; try { body = uwBody(false); } catch (e) { setResult(msg, e.message, false); return; }
    busy(btn, true, 'UNDERWRITING…'); setResult(msg, '');
    try { renderUw(await api('/api/finance/lending/underwrite', { method: 'POST', body })); }
    catch (e) { setResult(msg, `Underwriting failed: ${e.message}`, false); }
    finally { busy(btn, false); }
  }
  async function openRequest() {
    const btn = $('fundUwRequestBtn'); const msg = $('fundUwMsg');
    let body; try { body = uwBody(true); } catch (e) { setResult(msg, e.message, false); return; }
    busy(btn, true, 'OPENING…'); setResult(msg, '');
    try {
      const r = await api('/api/finance/lending/request', { method: 'POST', body });
      if (r.underwriting) renderUw(r.underwriting);
      const ln = r.loan || {};
      setResult(msg, `${ln.id}: ${ln.status}${r.instructions ? `\n${r.instructions}` : '\nNot approved; the request is recorded as REJECTED for audit.'}`, ln.status === 'AWAITING_COLLATERAL');
      loadBook();
    } catch (e) { setResult(msg, `Request failed: ${e.message}`, false); }
    finally { busy(btn, false); }
  }
  async function serviceLoans(loanId, execute) {
    const msg = $('fundServiceMsg');
    const btn = execute ? $('fundServiceExecBtn') : $('fundServiceDryBtn');
    const body = { loan_id: loanId || undefined };
    if (execute) {
      const ok = await confirmBroadcast('Service loans & execute', [
        loanId ? `Loan: ${loanId}` : 'All loans in the book',
        'May disburse principal, return collateral, or list a liquidation order',
        'Wallet policy caps and loan-destination checks still apply.']);
      if (!ok) return;
      body.execute = true; body.confirm = 'BROADCAST';
    }
    busy(btn, true, 'SERVICING…'); setResult(msg, '');
    try {
      const r = await api('/api/finance/lending/service', { method: 'POST', body });
      const lines = (r.results || []).map((x) => `${x.loan_id}: ${x.before} → ${x.after}${x.error ? `  ERROR ${x.error}` : ''}\n  ${(x.actions || []).join('\n  ')}`);
      setResult(msg, `${r.execute ? 'EXECUTED' : 'DRY RUN'} · ${lines.length} loan(s)\n${lines.join('\n') || 'nothing to service'}`, true);
      loadBook(); loadState();
    } catch (e) { setResult(msg, `Servicing failed: ${e.message}`, false); }
    finally { busy(btn, false); }
  }
  async function cancelLoan(id, btn) {
    busy(btn, true, '…');
    try { await api('/api/finance/lending/cancel', { method: 'POST', body: { loan_id: id } }); setResult($('fundServiceMsg'), `${id} cancelled`, true); loadBook(); }
    catch (e) { setResult($('fundServiceMsg'), `Cancel failed: ${e.message}`, false); busy(btn, false); }
  }
  async function addLedger() {
    const btn = $('fundLedgerAddBtn'); const msg = $('fundLedgerMsg');
    const amount = parseFloat($('fundLedgerAmount').value);
    if (!(amount > 0)) { setResult(msg, 'amount must be > 0', false); return; }
    const body = { type: $('fundLedgerType').value, asset: $('fundLedgerAsset').value, amount, note: $('fundLedgerNote').value.trim() };
    if (body.note.startsWith('-')) { setResult(msg, 'note may not start with "-"', false); return; }
    busy(btn, true, 'RECORDING…');
    try {
      await api('/api/finance/fund/ledger', { method: 'POST', body });
      setResult(msg, `Recorded ${body.type} ${amount} ${body.asset}`, true);
      $('fundLedgerAmount').value = ''; $('fundLedgerNote').value = '';
      loadState(); loadOpps();
    } catch (e) { setResult(msg, `Ledger entry rejected: ${e.message}`, false); }
    finally { busy(btn, false); }
  }
  async function buildLadder() {
    const btn = $('fundLadderBtn'); const box = clear($('fundLadder'));
    const body = {
      asset: $('fundLadderAsset').value, direction: $('fundLadderDir').value, amount: parseFloat($('fundLadderAmount').value),
      span_pct: parseFloat($('fundLadderSpan').value), rungs: parseInt($('fundLadderRungs').value, 10),
    };
    const minP = parseFloat($('fundLadderMin').value);
    if (!(body.amount > 0)) { box.append(el('div', { class: 'fund-empty', text: 'amount must be > 0' })); return; }
    busy(btn, true, 'CALIBRATING…');
    try {
      const L = await api('/api/finance/fund/ladder', { method: 'POST', body });
      const sell = L.direction === 'SELL';
      const rungs = L.rungs || [];
      // Best price whose 24h fill probability clears the threshold.
      let pick = -1;
      rungs.forEach((r, i) => { if ((r.fill_probability || {})['24h'] >= minP) pick = i; });
      box.append(el('div', { class: 'desk-sub', style: 'margin-bottom:6px', text: `${L.asset} ${L.direction} · spot ${fmt(L.spot_price_ada, 8)} ₳ · σh ${pct(L.sigma_hourly, 2)} · coverage ${pct(L.coverage, 0)}` }));
      const probCell = (p) => el('td', { class: 'fund-num prob' }, el('span', { class: 'pbar', style: `width:${Math.round((p || 0) * 100)}%` }), el('span', { class: 'ptxt', text: pct(p, 0) }));
      box.append(table(['Limit ₳ ', sell ? 'Premium ' : 'Discount ', sell ? 'Gross ₳ ' : 'Tokens ', '6h ', '24h ', '72h ', '7d '], rungs.map((r, i) => {
        const fp = r.fill_probability || {};
        return el('tr', { class: i === pick ? 'pick' : '' },
          el('td', { class: 'fund-num', text: fmt(r.price, 8) }),
          el('td', { class: 'fund-num', text: `${fmt(r.premium_pct != null ? r.premium_pct : r.discount_pct, 1)}%` }),
          el('td', { class: 'fund-num', text: fmt(r.gross_ada != null ? r.gross_ada : r.tokens, 2) }),
          probCell(fp['6h']), probCell(fp['24h']), probCell(fp['72h']), probCell(fp['168h']));
      }), 'fund-ladder'));
      box.append(el('div', { class: 'fund-foot', text: pick >= 0 ? `Highlighted: best price with ≥${Math.round(minP * 100)}% calibrated 24h fill odds (${fmt(rungs[pick].price, 8)} ₳).` : `No rung reaches ${Math.round(minP * 100)}% at 24h; widen the span or lower the threshold.` }));
    } catch (e) { box.append(el('div', { class: 'fund-empty', text: `Ladder failed: ${e.message}` })); }
    finally { busy(btn, false); }
  }
  async function staleScan() {
    const btn = $('fundStaleScanBtn'); busy(btn, true, 'SCANNING…');
    try {
      const r = await api('/api/finance/reactors/stale-scan', { method: 'POST' });
      const out = (r.output || '').trim();
      setResult($('fundOppsMsg'), `Stale order reactor:\n${out.slice(0, 1500) || 'No stale orders detected.'}`, true);
      await loadOpps();
    } catch (e) { setResult($('fundOppsMsg'), `Stale scan failed: ${e.message}`, false); }
    finally { busy(btn, false); }
  }
  async function sweep() {
    const ok = await confirmBroadcast('Sweep Cardano hot wallet to Trezor', [
      'Sends all spendable ADA above the 10 ADA reserve floor to the configured Trezor address.',
      'This REDUCES the capital available to the loan fund and maker orders.']);
    if (!ok) return;
    const btn = $('fundSweepBtn'); busy(btn, true, 'SWEEPING…');
    try {
      const r = await api('/api/finance/sweep', { method: 'POST' });
      setResult($('fundServiceMsg'), r.tx_id ? `Sweep submitted: ${r.tx_id}` : (r.message || r.raw_output || JSON.stringify(r)).slice(0, 800), true);
      loadTreasury();
    } catch (e) { setResult($('fundServiceMsg'), `Sweep failed: ${e.message}`, false); }
    finally { busy(btn, false); }
  }

  // ---------------------------------------------------------------- boot
  function init() {
    const root = $('fundCockpit');
    if (!root) return;
    if (!state.inited) { state.inited = true; build(root); }
    refreshAll();
  }
  document.addEventListener('click', (e) => {
    const t = e.target;
    if (t && t.classList && t.classList.contains('drawer-tab-btn') && t.dataset.pane === 'finance') requestAnimationFrame(init);
  });
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => { if ($('fundCockpit')) init(); });
  } else {
    requestAnimationFrame(() => { if ($('fundCockpit')) init(); });
  }
  window.LodgeFund = {
    refresh: () => (state.inited ? refreshAll() : init()),
    refreshTreasury: () => { if (state.inited) { loadTreasury(); loadState(); } },
    init,
  };
})();
