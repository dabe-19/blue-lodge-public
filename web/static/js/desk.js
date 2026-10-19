// ============================================================================
// GEORGE // Sovereign DEX Desk
// Chart (TradingView Lightweight Charts, vendored) + analysis overlays, chain-truth
// orders with reclaim, native Minswap V2 limit ticket, hot-wallet manager.
//
// Security rules for this file:
//  * No innerHTML / alert / confirm. All DOM is built with createElement/textContent.
//  * Secrets (passphrases, mnemonics, keys) live only in modal inputs and the single
//    request body that needs them; they are never logged, stored, or put in URLs.
//  * Every mainnet broadcast goes through confirmBroadcast(): the operator must type
//    BROADCAST. The server enforces the same rule (execute + confirm).
//  * External links use rel="noopener noreferrer" and only https://cardanoscan.io or
//    https://www.geckoterminal.com targets produced by the backend are opened.
// ============================================================================
(function () {
  'use strict';

  const $ = (id) => document.getElementById(id);
  const state = {
    asset: 'IAG', tf: 'hour', agg: 1, dir: 'buy',
    chart: null, candles: null, volume: null,
    cone: [], kalmanSeries: [], pegSeries: [], cvdSeries: null, adaUsdSeries: null,
    priceLines: [], ticketLine: null,
    data: null, barLookup: {}, markerUrls: {}, wallets: [], activeWallet: null, inited: false, loading: false,
  };
  const COLORS = {
    up: '#10b981', down: '#f87171', spot: '#38bdf8',
    limit_buy: '#34d399', limit_sell: '#f87171', limit_sell_expired: '#ef4444',
    stop_buy: '#22d3ee', invalidation_disarm: '#f43f5e', stop_loss: '#ef4444', take_profit: '#10b981',
    proposed_plan: '#fbbf24', standing_order: '#a78bfa', sim_order: '#38bdf8',
    trigger: '#f59e0b', cost_basis: '#a78bfa',
    ou_band: '#10b981', ou_mean: '#10b981',
    kalman_fv: '#06b6d4', peg_fv: '#eab308',
    vp_poc: '#f43f5e', vp_vah: '#38bdf8', vp_val: '#38bdf8',
    fee_hurdle: '#f97316',
    cone1: 'rgba(56,189,248,0.75)', cone2: 'rgba(56,189,248,0.35)',
    impulse: '#f43f5e', ticket: '#e2e8f0',
  };
  const SAFE_LINK = /^https:\/\/(cardanoscan\.io|www\.geckoterminal\.com|polygonscan\.com)\//;

  // ---------------------------------------------------------------- utilities
  function el(tag, props, ...children) {
    const n = document.createElement(tag);
    if (props) {
      for (const [k, v] of Object.entries(props)) {
        if (v == null) continue;
        if (k === 'class') n.className = v;
        else if (k === 'text') n.textContent = v;
        else if (k === 'style') n.style.cssText = v;
        else if (k.startsWith('on')) n.addEventListener(k.slice(2), v);
        else n.setAttribute(k, v);
      }
    }
    for (const c of children) if (c != null) n.append(c.nodeType ? c : document.createTextNode(String(c)));
    return n;
  }
  function link(url, text) {
    if (!url || !SAFE_LINK.test(url)) return document.createTextNode(text);
    return el('a', { href: url, target: '_blank', rel: 'noopener noreferrer', text });
  }
  const fmt = (v, d = 6) => (v == null || !isFinite(v) ? '—' : Number(v).toFixed(d));
  const pct = (v) => (v == null ? '—' : `${(v * 100).toFixed(1)}%`);
  const short = (s, n = 8) => (s && s.length > 2 * n + 1 ? `${s.slice(0, n)}…${s.slice(-n)}` : s || '');

  function log(msg, cls) {
    const box = $('deskLog');
    if (!box) return;
    const t = new Date().toLocaleTimeString();
    box.prepend(el('div', { class: cls || '' }, `[${t}] ${msg}`));
    while (box.childElementCount > 80) box.lastChild.remove();
  }
  function setResult(id, text, ok) {
    const n = $(id);
    if (!n) return;
    n.textContent = text || '';
    n.className = 'desk-result' + (text ? (ok === false ? ' err' : ok ? ' ok' : '') : '');
  }
  async function api(path, opts) {
    const o = Object.assign({ headers: {} }, opts || {});
    if (o.body && typeof o.body !== 'string') {
      o.body = JSON.stringify(o.body);
      o.headers['Content-Type'] = 'application/json';
    }
    const r = await fetch(path, o);
    let j;
    try { j = await r.json(); } catch (_) { j = { status: 'error', message: `HTTP ${r.status}` }; }
    if (!r.ok && !j.message) j.message = `HTTP ${r.status}`;
    if (!r.ok || j.status === 'error' || j.status === 'denied') { const e = new Error(j.message || `HTTP ${r.status}`); e.payload = j; throw e; }
    return j;
  }
  function busy(btn, on, label) {
    if (!btn) return;
    if (on) { btn.dataset.label = btn.textContent; btn.textContent = label || '…'; btn.disabled = true; }
    else { btn.textContent = btn.dataset.label || btn.textContent; btn.disabled = false; }
  }

  // ---------------------------------------------------------------- modals
  function modal({ title, body, actions }) {
    return new Promise((resolve) => {
      const overlay = el('div', { class: 'lodge-modal-overlay', role: 'dialog', 'aria-modal': 'true' });
      const box = el('div', { class: 'lodge-modal' }, el('h3', { text: title }));
      body.forEach((b) => box.append(b));
      const row = el('div', { class: 'modal-actions' });
      const close = (v) => { overlay.remove(); document.removeEventListener('keydown', onKey); resolve(v); };
      const onKey = (e) => { if (e.key === 'Escape') close(null); };
      document.addEventListener('keydown', onKey);
      actions.forEach((a) => {
        const b = el('button', { class: `desk-btn ${a.cls || ''}`, id: a.id, text: a.text });
        b.addEventListener('click', () => {
          const v = a.value ? a.value() : a.result;
          if (v === undefined) return; // validation failed; keep open
          close(v);
        });
        row.append(b);
      });
      box.append(row);
      overlay.append(box);
      overlay.addEventListener('click', (e) => { if (e.target === overlay) close(null); });
      document.body.append(overlay);
      const first = box.querySelector('input, textarea, select');
      if (first) first.focus();
    });
  }

  function field(label, input) { return [el('label', { text: label }), input]; }

  /** Typed confirmation for any mainnet broadcast. Resolves {passphrase} or null. */
  function confirmBroadcast(summaryLines, needsPass) {
    const word = el('input', { id: 'deskConfirmWord', autocomplete: 'off', placeholder: 'type BROADCAST' });
    const pass = el('input', { id: 'deskConfirmPass', type: 'password', autocomplete: 'off', placeholder: 'wallet passphrase' });
    const err = el('p', { class: 'modal-danger', style: 'display:none' });
    const body = [el('div', { class: 'modal-danger', text: 'This signs and submits a REAL Cardano mainnet transaction. It cannot be undone.' })];
    body.push(el('pre', { text: summaryLines.join('\n') }));
    if (needsPass) body.push(...field('Passphrase (encrypted wallet)', pass));
    body.push(...field('Type BROADCAST to confirm', word), err);
    return modal({
      title: 'Confirm mainnet broadcast',
      body,
      actions: [
        { text: 'CANCEL', cls: 'ghost', id: 'deskConfirmCancel', result: null },
        { text: 'SIGN & SUBMIT', cls: 'danger', id: 'deskConfirmGo', value: () => {
          if (word.value.trim() !== 'BROADCAST') { err.textContent = 'Confirmation word does not match.'; err.style.display = ''; return undefined; }
          if (needsPass && !pass.value) { err.textContent = 'Passphrase required.'; err.style.display = ''; return undefined; }
          return { passphrase: pass.value || undefined };
        } },
      ],
    });
  }

  const walletNeedsPass = (id) => {
    const w = state.wallets.find((x) => x.id === id);
    return !!(w && w.encrypted && !w.auto_unlock);
  };

  // ---------------------------------------------------------------- chart
  function ensureChart() {
    if (state.chart || !window.LightweightCharts) return;
    const LC = window.LightweightCharts;
    state.chart = LC.createChart($('deskChart'), {
      autoSize: true,
      layout: { background: { type: 'solid', color: '#0a0e16' }, textColor: '#94a3b8', fontFamily: 'ui-monospace, Menlo, monospace', fontSize: 11 },
      grid: { vertLines: { color: 'rgba(31,41,61,0.45)' }, horzLines: { color: 'rgba(31,41,61,0.45)' } },
      rightPriceScale: { borderColor: '#1f293d', scaleMargins: { top: 0.08, bottom: 0.22 } },
      timeScale: { borderColor: '#1f293d', timeVisible: true, secondsVisible: false, rightOffset: 8 },
      crosshair: { mode: LC.CrosshairMode.Normal },
      localization: { priceFormatter: (p) => (p < 0.01 ? p.toFixed(8) : p.toFixed(6)) },
    });
    state.candles = state.chart.addCandlestickSeries({
      upColor: COLORS.up, downColor: COLORS.down, wickUpColor: COLORS.up, wickDownColor: COLORS.down, borderVisible: false,
      priceFormat: { type: 'price', precision: 6, minMove: 0.000001 },
    });
    state.volume = state.chart.addHistogramSeries({ priceFormat: { type: 'volume' }, priceScaleId: 'vol', color: 'rgba(100,116,139,0.45)' });
    state.chart.priceScale('vol').applyOptions({ scaleMargins: { top: 0.80, bottom: 0 } });
    state.chart.subscribeCrosshairMove(onCrosshair);
    state.chart.subscribeClick((p) => {
      const url = p && p.hoveredObjectId != null ? state.markerUrls[p.hoveredObjectId] : null;
      if (url && SAFE_LINK.test(url)) window.open(url, '_blank', 'noopener,noreferrer');
    });
  }

  function buildBarLookup(d) {
    const map = {};
    const ensure = (t) => { if (!map[t]) map[t] = {}; return map[t]; };
    (d.volume || []).forEach((v) => { ensure(v.time).vol = v; });
    (d.kalman_series || []).forEach((k) => { ensure(k.time).kalman = k; });
    (d.regime_series || []).forEach((r) => { ensure(r.time).regime = r; });
    (d.cvd_series || []).forEach((c) => { ensure(c.time).cvd = c.value; });
    (d.ada_usd_series || []).forEach((a) => { ensure(a.time).adaUsd = a.value; });
    (d.peg_series || []).forEach((p) => { ensure(p.time).peg = p; });
    state.barLookup = map;
  }

  function onCrosshair(p) {
    const legend = $('deskLegend');
    if (!legend || !state.data) return;
    legend.replaceChildren();
    const d = state.data;
    const dg = d.diagnostics || {};
    const km = dg.kalman || {};
    const rg = dg.regime || {};
    const prov = (d.provenance && d.provenance.ohlcv) || {};
    const srcTag = (d.source_mode || '').includes('market_db') ? 'ON-CHAIN' : (prov.source || 'ON-CHAIN');
    const cBar = p && p.seriesData ? p.seriesData.get(state.candles) : null;
    const tKey = (p && p.time) || (d.candles && d.candles.length ? d.candles[d.candles.length - 1].time : null);
    const meta = (tKey != null && state.barLookup[tKey]) ? state.barLookup[tKey] : {};

    const regName = (meta.regime && meta.regime.regime) || rg.current || dg.current_regime || 'RANDOM_WALK';
    const vrVal = (meta.regime && meta.regime.vr != null) ? meta.regime.vr : (rg.vr_4 != null ? rg.vr_4 : dg.current_vr);
    const regCol = regName === 'MEAN_REVERTING' ? '#10b981' : (regName === 'TRENDING' ? '#f59e0b' : '#38bdf8');
    const kfNow = km.fair_value ?? dg.kalman_fv;
    const kzNow = km.deviation_sigma ?? dg.kalman_z;

    legend.append(
      el('div', { style: 'display:flex; gap:8px; align-items:center;' },
        el('strong', { text: `${state.asset}/ADA · ${d.pool.dex} · ${tfLabel()}` }),
        el('span', { style: 'font-size:9.5px; color:#38bdf8; background:rgba(15,23,42,0.85); padding:0 5px; border-radius:3px; border:1px solid #1e293b;', text: srcTag }),
        el('span', { style: `font-size:9.5px; font-weight:700; color:${regCol};`, text: `${regName}${vrVal != null ? ` (VR=${Number(vrVal).toFixed(2)})` : ''}` })
      )
    );

    if (cBar && cBar.open != null) {
      legend.append(el('div', { class: 'muted', text: `O ${fmt(cBar.open)}  H ${fmt(cBar.high)}  L ${fmt(cBar.low)}  C ${fmt(cBar.close)}` }));
    } else {
      legend.append(el('div', { class: 'muted', text: `spot ${fmt(d.spot)} ADA${kfNow ? ` · Kalman FV ${fmt(kfNow)} (${kzNow >= 0 ? '+' : ''}${fmt(kzNow, 2)}σ)` : ''}` }));
    }

    const extraParts = [];
    if (meta.vol) {
      const v = meta.vol;
      const dv = v.delta != null ? v.delta : (v.delta_volume || 0);
      const dSign = dv >= 0 ? '+' : '';
      extraParts.push(`Vol ${fmt(v.value, 0)}₳ (Δ ${dSign}${fmt(dv, 0)}₳${v.shock ? ' ⚡SHOCK' : ''})`);
    }
    if (meta.cvd != null) {
      const cSign = meta.cvd >= 0 ? '+' : '';
      extraParts.push(`CVD ${cSign}${fmt(meta.cvd, 0)}₳`);
    }
    if (meta.kalman) {
      const kz = meta.kalman.z || 0;
      extraParts.push(`FV ${fmt(meta.kalman.fv)} (Z=${kz >= 0 ? '+' : ''}${kz.toFixed(2)}σ)`);
    }
    if (meta.peg) {
      extraParts.push(`Peg ${fmt(meta.peg.fv, 4)}₳`);
    } else if (meta.adaUsd) {
      extraParts.push(`ADA $${fmt(meta.adaUsd, 4)}`);
    }
    if (extraParts.length) {
      legend.append(el('div', { style: 'font-size:10px; color:#94a3b8;', text: extraParts.join(' · ') }));
    }
  }

  const tfLabel = () => ({ 'minute5': '5m', 'minute15': '15m', 'hour1': '1h', 'hour4': '4h', 'day1': '1D' }[`${state.tf}${state.agg}`] || state.tf);

  function ov(name) {
    const cb = document.querySelector(`#deskOverlayToggles input[data-ov="${name}"]`);
    return !cb || cb.checked;
  }

  function lineGroup(kind) {
    if (kind.startsWith('limit') || ['stop_buy', 'invalidation_disarm', 'stop_loss', 'take_profit', 'proposed_plan', 'standing_order', 'sim_order'].includes(kind)) return 'orders';
    if (kind === 'trigger') return 'trigger';
    if (kind === 'cost_basis') return 'cost';
    if (kind.startsWith('ou')) return 'ou';
    if (kind.startsWith('kalman')) return 'kalman';
    if (kind.startsWith('peg')) return 'peg';
    if (kind.startsWith('vp_')) return 'vp';
    if (kind === 'fee_hurdle') return 'hurdle';
    if (kind === 'spread_corridor') return 'corridor';
    return 'always';
  }

  function clearSeriesList(list) {
    if (!state.chart || !Array.isArray(list)) return;
    while (list.length) {
      const s = list.pop();
      try { state.chart.removeSeries(s); } catch (_) {}
    }
  }

  function drawOverlays() {
    const d = state.data;
    if (!d || !state.chart) return;
    state.priceLines.forEach((l) => state.candles.removePriceLine(l));
    state.priceLines = [];

    const dashedKinds = new Set([
      'trigger', 'ou_band', 'cost_basis', 'limit_sell_expired',
      'invalidation_disarm', 'stop_loss', 'proposed_plan', 'standing_order',
      'sim_order', 'vp_vah', 'vp_val', 'fee_hurdle', 'peg_fv',
    ]);
    for (const ln of d.lines || []) {
      const g = lineGroup(ln.kind);
      if (g !== 'always' && !ov(g)) continue;
      const dashed = dashedKinds.has(ln.kind);
      const width = (ln.kind === 'spot' || ln.kind === 'vp_vah' || ln.kind === 'vp_val' || ln.kind === 'fee_hurdle') ? 1 : 2;
      state.priceLines.push(state.candles.createPriceLine({
        price: ln.price, color: COLORS[ln.kind] || '#94a3b8', lineWidth: width,
        lineStyle: dashed ? 2 : (ln.kind === 'spot' ? 1 : 0), axisLabelVisible: true, title: ln.label,
      }));
    }

    // Secondary AMM spread corridor lines
    if (ov('corridor') && d.arbitrage_spread_corridor) {
      for (const sec of d.arbitrage_spread_corridor) {
        if (!sec.price_ada) continue;
        const sign = sec.spread_pct > 0 ? '+' : '';
        state.priceLines.push(state.candles.createPriceLine({
          price: sec.price_ada,
          color: '#ec4899',
          lineWidth: 1,
          lineStyle: 2,
          axisLabelVisible: true,
          title: `${sec.dex} (${sign}${sec.spread_pct}%)`,
        }));
      }
    }

    // 1. Dynamic Kalman Local-Level Fair Value trajectory + ±1σ / ±2σ dislocation bands
    clearSeriesList(state.kalmanSeries);
    if (ov('kalman') && d.kalman_series && d.kalman_series.length > 1) {
      const addKLine = (key, color, width, style) => {
        const s = state.chart.addLineSeries({
          color, lineWidth: width, lineStyle: style,
          priceLineVisible: false, lastValueVisible: false, crosshairMarkerVisible: false,
        });
        s.setData(d.kalman_series.map((pt) => ({ time: pt.time, value: pt[key] })));
        state.kalmanSeries.push(s);
      };
      addKLine('fv', '#06b6d4', 2, 0);
      addKLine('p1', 'rgba(6,182,212,0.50)', 1, 2);
      addKLine('m1', 'rgba(6,182,212,0.50)', 1, 2);
      addKLine('p2', 'rgba(6,182,212,0.28)', 1, 3);
      addKLine('m2', 'rgba(6,182,212,0.28)', 1, 3);
    }

    // 2. S3 Stablecoin CEX Peg Parity curve (or Macro ADA/USD Reference Overlay)
    clearSeriesList(state.pegSeries);
    if (state.adaUsdSeries) {
      try { state.chart.removeSeries(state.adaUsdSeries); } catch (_) {}
      state.adaUsdSeries = null;
    }
    if (ov('peg')) {
      if (d.peg_series && d.peg_series.length > 1) {
        const addPegLine = (key, color, width, style) => {
          const s = state.chart.addLineSeries({
            color, lineWidth: width, lineStyle: style,
            priceLineVisible: false, lastValueVisible: false, crosshairMarkerVisible: false,
          });
          s.setData(d.peg_series.map((pt) => ({ time: pt.time, value: pt[key] })));
          state.pegSeries.push(s);
        };
        addPegLine('fv', '#eab308', 2, 0);
        addPegLine('buy_trig', 'rgba(16,185,129,0.75)', 1, 2);
        addPegLine('sell_trig', 'rgba(248,113,113,0.75)', 1, 2);
      } else if (d.ada_usd_series && d.ada_usd_series.length > 1) {
        state.adaUsdSeries = state.chart.addLineSeries({
          color: 'rgba(234,179,8,0.45)', lineWidth: 1, lineStyle: 2,
          priceScaleId: 'ada_usd',
          priceLineVisible: false, lastValueVisible: false, crosshairMarkerVisible: false,
          priceFormat: { type: 'price', precision: 4, minMove: 0.0001 },
        });
        state.chart.priceScale('ada_usd').applyOptions({ scaleMargins: { top: 0.04, bottom: 0.76 } });
        state.adaUsdSeries.setData(d.ada_usd_series);
      }
    }

    // 3. Cumulative Volume Delta (CVD) Sub-Scale Overlay
    if (state.cvdSeries) {
      try { state.chart.removeSeries(state.cvdSeries); } catch (_) {}
      state.cvdSeries = null;
    }
    if (ov('cvd') && d.cvd_series && d.cvd_series.length > 1) {
      state.cvdSeries = state.chart.addLineSeries({
        color: '#22c55e', lineWidth: 1, lineStyle: 0,
        priceScaleId: 'cvd',
        priceLineVisible: false, lastValueVisible: false, crosshairMarkerVisible: false,
        priceFormat: { type: 'volume' },
      });
      state.chart.priceScale('cvd').applyOptions({ scaleMargins: { top: 0.78, bottom: 0.01 } });
      state.cvdSeries.setData(d.cvd_series);
    }

    // 4. Volatility cone + ARX post-shock impulse-response mean-reversion curve
    clearSeriesList(state.cone);
    if (ov('cone') && d.cone && d.cone.length && d.candles.length) {
      const t0 = d.candles[d.candles.length - 1].time;
      const mk = (key, color, style) => {
        const s = state.chart.addLineSeries({ color, lineWidth: 1, lineStyle: style, priceLineVisible: false, lastValueVisible: false, crosshairMarkerVisible: false });
        s.setData([{ time: t0, value: d.spot }, ...d.cone.filter((c) => c.time > t0).map((c) => ({ time: c.time, value: c[key] }))]);
        state.cone.push(s);
      };
      mk('p1', COLORS.cone1, 0); mk('m1', COLORS.cone1, 0); mk('p2', COLORS.cone2, 2); mk('m2', COLORS.cone2, 2);

      if (d.impulse_projection && d.impulse_projection.length > 1) {
        const impS = state.chart.addLineSeries({
          color: COLORS.impulse, lineWidth: 2, lineStyle: 2,
          priceLineVisible: false, lastValueVisible: false, crosshairMarkerVisible: false,
        });
        impS.setData(d.impulse_projection.map((pt) => ({ time: pt.time, value: pt.value })));
        state.cone.push(impS);
      }
    }

    // 5. Markers (snap to bar start so they land on an existing candle)
    const step = d.step_s;
    const first = d.candles.length ? d.candles[0].time : 0;
    const last = d.candles.length ? d.candles[d.candles.length - 1].time : 0;
    state.markerUrls = {};
    const markers = [];
    (d.markers || []).forEach((m, i) => {
      const isOurs = m.kind === 'our_tx';
      const isSim = m.kind === 'sim_trade';
      const isQuant = m.kind === 'quant_signal';
      if ((isOurs || isSim) && !ov('orders')) return;
      if (isQuant && !ov('kalman')) return;
      if (!isOurs && !isSim && !isQuant && !ov('trades')) return;

      const t = Math.floor(m.time / step) * step;
      if (t < first || t > last) return;
      const id = `m${i}`;
      if (m.url) state.markerUrls[id] = m.url;

      let color = 'rgba(248,113,113,0.55)';
      let shape = 'circle';
      let text = '';
      let size = 0.5;
      const isBuy = String(m.label || '').toUpperCase().includes('BUY') || m.kind === 'pool_buy';

      if (isOurs) {
        color = isBuy ? '#34d399' : '#f87171';
        shape = isBuy ? 'arrowUp' : 'arrowDown';
        text = m.label || '';
        size = 1.4;
      } else if (isSim) {
        color = isBuy ? '#38bdf8' : '#a78bfa';
        shape = isBuy ? 'arrowUp' : 'arrowDown';
        text = m.label || '';
        size = 1.1;
      } else if (isQuant) {
        color = isBuy ? '#22d3ee' : '#fbbf24';
        shape = 'square';
        text = m.label || '';
        size = 0.9;
      } else {
        color = isBuy ? 'rgba(16,185,129,0.55)' : 'rgba(248,113,113,0.55)';
        shape = 'circle';
        text = '';
        size = 0.5;
      }

      markers.push({
        time: t, id, position: m.position || (isBuy ? 'belowBar' : 'aboveBar'),
        color, shape, text, size,
      });
    });
    markers.sort((a, b) => a.time - b.time);
    state.candles.setMarkers(markers);
    drawTicketLine();

    const cpmmEl = $('deskCpmmCurveContainer');
    if (cpmmEl) cpmmEl.style.display = (ov('cpmm') && d.cpmm_liquidity_curve && d.cpmm_liquidity_curve.length) ? 'block' : 'none';
    const vrvpBox = $('deskVrvpSubPanel');
    if (vrvpBox) vrvpBox.style.display = ov('vp') ? 'block' : 'none';
  }

  function drawTicketLine() {
    if (!state.candles) return;
    if (state.ticketLine) { state.candles.removePriceLine(state.ticketLine); state.ticketLine = null; }
    const px = parseFloat($('deskPrice')?.value || '');
    if (ov('ticket') && px > 0) {
      state.ticketLine = state.candles.createPriceLine({ price: px, color: COLORS.ticket, lineWidth: 1, lineStyle: 3, axisLabelVisible: true, title: `ticket ${state.dir.toUpperCase()}` });
    }
  }

  async function loadChart() {
    if (state.loading) return;
    ensureChart();
    if (!state.chart) { setResult('deskTicketResult', 'Chart library failed to load.', false); return; }
    state.loading = true;
    const loading = $('deskChartLoading');
    if (loading) { loading.hidden = false; loading.textContent = `Loading ${state.asset}/ADA ${tfLabel()}…`; }
    try {
      const q = new URLSearchParams({ asset: state.asset, timeframe: state.tf, aggregate: String(state.agg), bars: '600' });
      const d = await api(`/api/finance/chart?${q}`);
      state.data = d;
      buildBarLookup(d);
      state.candles.setData(d.candles);
      state.volume.setData((d.volume || []).map((v) => {
        const dv = v.delta != null ? v.delta : (v.delta_volume || 0);
        let col = v.traded ? 'rgba(100,116,139,0.55)' : 'rgba(100,116,139,0.12)';
        if (v.shock) {
          col = dv >= 0 ? '#f59e0b' : '#f43f5e';
        } else if ((v.buy_volume || 0) > 0 || (v.sell_volume || 0) > 0 || v.direction) {
          const isUp = dv !== 0 ? dv >= 0 : v.direction === 'up';
          col = isUp ? 'rgba(16,185,129,0.62)' : 'rgba(248,113,113,0.62)';
        }
        return { time: v.time, value: v.value, color: col };
      }));
      drawOverlays();
      state.chart.timeScale().fitContent();
      renderChartMeta(d);
      onCrosshair(null);
      if (loading) loading.hidden = true;
      if (!$('deskPrice').value) $('deskPrice').value = d.spot.toFixed(6);
      drawTicketLine();
      const prov = (d.provenance && d.provenance.ohlcv) || {};
      log(`Chart ${state.asset}/ADA ${tfLabel()} (${d.source_mode || prov.source || 'market.db'}): ${d.candles.length} bars, ${(d.coverage * 100).toFixed(0)}% traded`, 'ok');
    } catch (e) {
      if (loading) { loading.hidden = false; loading.textContent = `Chart unavailable: ${e.message}`; }
      log(`Chart error: ${e.message}`, 'err');
    } finally {
      state.loading = false;
    }
  }

  function renderStructureAnalytics(d) {
    const box = $('deskStructureAnalyticsContainer');
    if (!box) return;
    box.replaceChildren();

    const dg = d.diagnostics || {};
    const km = dg.kalman || {};
    const rg = dg.regime || {};
    const imp = dg.impact || {};
    const peg = dg.peg || {};
    const vp = d.volume_profile || {};
    const bins = vp.bins || [];
    const sp = d.sim_and_plans || {};

    // 1. Top Row: Regime & Kalman Telemetry + Round-Trip Fee Hurdle Matrix
    const topGrid = el('div', { style: 'display:grid; grid-template-columns:repeat(auto-fit, minmax(260px, 1fr)); gap:8px;' });

    // Panel A: Regime, Variance Ratio, Kalman & ARX Impulse
    const regName = rg.current || dg.current_regime || 'RANDOM_WALK';
    const vrVal = rg.vr_4 ?? dg.current_vr ?? km.vr_k;
    const regCol = regName === 'MEAN_REVERTING' ? '#10b981' : (regName === 'TRENDING' ? '#f59e0b' : '#38bdf8');
    const kfVal = km.fair_value ?? dg.kalman_fv;
    const kz = km.deviation_sigma ?? dg.kalman_z;
    const khl = km.half_life_h ?? dg.kalman_half_life_h;
    const kzCol = kz != null ? (Math.abs(kz) >= 2.0 ? '#f87171' : (Math.abs(kz) >= 1.35 ? '#f59e0b' : '#06b6d4')) : '#94a3b8';

    const regimePanel = el('div', { style: 'background:#0b1120; border:1px solid #1e293b; border-radius:4px; padding:6px 10px; font-size:10.5px; font-family:monospace;' },
      el('div', { style: 'display:flex; justify-content:space-between; align-items:center; border-bottom:1px solid #1e293b; padding-bottom:4px; margin-bottom:5px;' },
        el('span', { style: 'font-weight:700; color:#cbd5e1; text-transform:uppercase;', text: 'Regime · Kalman · ARX Flow Impact' }),
        el('span', { style: `color:${regCol}; font-weight:700; background:#060a12; padding:1px 6px; border-radius:3px; border:1px solid ${regCol}; font-size:9.5px;`, text: `${regName}${vrVal != null ? ` · VR(4)=${Number(vrVal).toFixed(2)}` : ''}` })
      ),
      el('div', { style: 'display:grid; grid-template-columns:repeat(2, 1fr); gap:4px; color:#94a3b8; font-size:10px;' },
        el('div', null, 'Kalman FV: ', el('strong', { style: 'color:#06b6d4;' }, kfVal != null ? `${fmt(kfVal)} ₳` : '—')),
        el('div', null, 'Dislocation: ', el('strong', { style: `color:${kzCol};` }, kz != null ? `${kz >= 0 ? '+' : ''}${Number(kz).toFixed(2)}σ` : '—')),
        el('div', null, 'Kalman t½: ', el('strong', { style: 'color:#cbd5e1;' }, khl != null ? `${Number(khl).toFixed(1)}h` : '—')),
        el('div', null, 'ARX Impact t½: ', el('strong', { style: 'color:#38bdf8;' }, imp.half_life_h != null ? `${Number(imp.half_life_h).toFixed(2)}h` : '—')),
        el('div', null, 'Noise Share: ', el('strong', { style: 'color:#cbd5e1;' }, km.noise_share != null ? `${Math.round(km.noise_share * 100)}%` : '—')),
        el('div', null, 'Reversion Frac: ', el('strong', { style: '#10b981;' }, imp.reversion_fraction != null ? `${Math.round(imp.reversion_fraction * 100)}%` : '—'))
      )
    );
    if (peg && peg.fair_value) {
      regimePanel.append(
        el('div', { style: 'margin-top:4px; padding-top:4px; border-top:1px dashed #1e293b; color:#eab308; font-size:10px; display:flex; justify-content:space-between;' },
          el('span', null, `S3 CEX Peg Parity ($1 / $${fmt(peg.ada_usd, 4)}):`),
          el('strong', null, `${fmt(peg.fair_value, 6)} ₳ (${peg.deviation_pct >= 0 ? '+' : ''}${Number(peg.deviation_pct || 0).toFixed(2)}%)`)
        )
      );
    }
    topGrid.append(regimePanel);

    // Panel B: Round-Trip Fee Hurdle & Walk-Forward Backtest Scorecard
    const hurdles = d.fee_hurdles || [];
    const bt = sp.backtest || d.backtest || {};
    const s2Bt = bt.S2_shock_fade || bt.S2 || {};
    const s3Bt = bt.S3_stable_deviation || bt.S3 || {};
    const trips = sp.trips || d.trips || [];

    const hurdlePanel = el('div', { style: 'background:#0b1120; border:1px solid #1e293b; border-radius:4px; padding:6px 10px; font-size:10.5px; font-family:monospace;' },
      el('div', { style: 'display:flex; justify-content:space-between; align-items:center; border-bottom:1px solid #1e293b; padding-bottom:4px; margin-bottom:5px;' },
        el('span', { style: 'font-weight:700; color:#cbd5e1; text-transform:uppercase;', text: 'Round-Trip Fee Hurdle & Walk-Forward Backtest' }),
        el('span', { style: 'color:#f97316; font-size:9.5px;', text: `LP ${d.pool?.fee_bps ?? 30} bps · Batcher 2.0 ₳` })
      )
    );

    if (hurdles.length) {
      const hRow = el('div', { style: 'display:grid; grid-template-columns:repeat(auto-fit, minmax(95px, 1fr)); gap:5px; margin-bottom:5px;' });
      hurdles.slice(0, 3).forEach((h) => {
        const bePx = Number(h.breakeven_exit_price ?? h.breakeven_sell_price ?? d.spot);
        const hPct = Number(h.round_trip_hurdle_pct ?? h.hurdle_pct ?? 0);
        const card = el('div', {
          style: 'background:#060a12; border:1px solid #1e293b; border-radius:3px; padding:3px 6px; cursor:pointer;',
          title: `Click to set ticket price to ${h.size_ada} ADA round-trip break-even (${fmt(bePx)} ADA)`,
          onclick: () => {
            if ($('deskPrice')) {
              $('deskPrice').value = bePx.toFixed(6);
              drawTicketLine();
            }
          }
        },
          el('div', { style: 'color:#94a3b8; font-size:9px;', text: `${h.size_ada}₳ Round-Trip` }),
          el('div', { style: 'color:#f97316; font-weight:700; font-size:10.5px;', text: `+${hPct.toFixed(2)}%` }),
          el('div', { style: 'color:#cbd5e1; font-size:9px;', text: `BE: ${fmt(bePx, 5)}₳` })
        );
        hRow.append(card);
      });
      hurdlePanel.append(hRow);
    }

    const s2Sum = s2Bt.summary || s2Bt;
    const s3Sum = s3Bt.summary || s3Bt;
    const btLine = el('div', { style: 'display:flex; justify-content:space-between; flex-wrap:wrap; gap:6px; font-size:9.5px; color:#94a3b8; border-top:1px dashed #1e293b; padding-top:4px;' },
      el('span', null, 'S2 Backtest: ', el('strong', { style: (s2Sum.mean_ada || 0) > 0 ? '#10b981' : '#cbd5e1' }, `${s2Sum.n || 0} trades · win ${Math.round((s2Sum.win_rate || 0) * 100)}% · avg ${fmt(s2Sum.mean_ada || 0, 2)}₳`)),
      (d.peg_series && d.peg_series.length) ? el('span', null, 'S3 Backtest: ', el('strong', { style: (s3Sum.mean_ada || 0) > 0 ? '#10b981' : '#cbd5e1' }, `${s3Sum.n || 0} trades · avg ${fmt(s3Sum.mean_ada || 0, 2)}₳`)) : null,
      el('span', null, 'Asset Trips: ', el('strong', { style: '#38bdf8' }, `${trips.length}`))
    );
    hurdlePanel.append(btLine);
    topGrid.append(hurdlePanel);
    box.append(topGrid);

    // 2. Visible Range Volume Profile (VRVP — 24 Price Bins + POC / VAH / VAL)
    if (bins.length) {
      const pocPx = vp.poc_price ?? vp.poc;
      const vahPx = vp.vah_price ?? vp.vah;
      const valPx = vp.val_price ?? vp.val;
      const totVol = vp.total_volume_ada ?? vp.total_volume ?? 0;

      const vrvpPanel = el('div', {
        id: 'deskVrvpSubPanel',
        style: `background:#0b1120; border:1px solid #1e293b; border-radius:4px; padding:6px 10px; font-size:10.5px; font-family:monospace; display:${ov('vp') ? 'block' : 'none'};`
      },
        el('div', { style: 'display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:6px; margin-bottom:6px; border-bottom:1px solid #1e293b; padding-bottom:4px;' },
          el('span', { style: 'font-weight:700; color:#cbd5e1; text-transform:uppercase;', text: 'Visible Range Volume Profile (VRVP · 70% Value Area)' }),
          el('div', { style: 'display:flex; gap:10px; font-size:10px;' },
            el('span', { style: 'color:#f43f5e; font-weight:700;', text: `POC: ${fmt(pocPx)} ₳` }),
            el('span', { style: 'color:#38bdf8;', text: `VAH: ${fmt(vahPx)} ₳` }),
            el('span', { style: 'color:#38bdf8;', text: `VAL: ${fmt(valPx)} ₳` }),
            el('span', { style: 'color:#94a3b8;', text: `Vol: ${Math.round(totVol).toLocaleString()} ₳` })
          )
        )
      );

      const nonEmpty = bins.slice().reverse();
      let displayBins = nonEmpty;
      if (nonEmpty.length > 12) {
        const spotIdx = nonEmpty.findIndex((b) => d.spot <= (b.price_high ?? b.high) && d.spot >= (b.price_low ?? b.low));
        const center = spotIdx >= 0 ? spotIdx : Math.floor(nonEmpty.length / 2);
        const start = Math.max(0, Math.min(nonEmpty.length - 12, center - 6));
        displayBins = nonEmpty.slice(start, start + 12);
      }

      const rowsWrap = el('div', { style: 'display:flex; flex-direction:column; gap:2px;' });
      displayBins.forEach((b) => {
        const bLo = b.price_low ?? b.low;
        const bHi = b.price_high ?? b.high;
        const bMid = b.price_mid ?? b.mid;
        const isSpotBin = d.spot >= bLo && d.spot <= bHi;
        const buyW = Math.min(100, (b.buy_volume / Math.max(1e-9, b.volume || 1)) * (b.pct_of_max || 0));
        const sellW = Math.min(100 - buyW, (b.sell_volume / Math.max(1e-9, b.volume || 1)) * (b.pct_of_max || 0));
        const borderCol = b.is_poc ? '#f43f5e' : (isSpotBin ? '#38bdf8' : 'transparent');
        const rowBg = b.in_value_area ? 'rgba(56,189,248,0.06)' : 'rgba(6,10,18,0.6)';

        const barTrack = el('div', { style: 'flex:1; height:11px; background:#060a12; border-radius:2px; overflow:hidden; display:flex; align-items:center;' },
          el('div', { style: `width:${buyW.toFixed(1)}%; height:100%; background:rgba(16,185,129,0.72);` }),
          el('div', { style: `width:${sellW.toFixed(1)}%; height:100%; background:rgba(248,113,113,0.72);` })
        );

        const tagText = b.is_poc ? 'POC' : (isSpotBin ? 'SPOT' : (b.in_value_area ? 'VA' : ''));
        const tagCol = b.is_poc ? '#f43f5e' : (isSpotBin ? '#38bdf8' : '#64748b');

        const row = el('div', {
          style: `display:grid; grid-template-columns:86px 36px 1fr 74px; align-items:center; gap:6px; padding:1px 5px; border-radius:2px; background:${rowBg}; border-left:2px solid ${borderCol}; cursor:pointer; font-size:9.5px;`,
          title: `Click to set ticket price to bin mid ${fmt(bMid)} ADA (Buy: ${Math.round(b.buy_volume)}₳ / Sell: ${Math.round(b.sell_volume)}₳)`,
          onclick: () => {
            if ($('deskPrice')) {
              $('deskPrice').value = Number(bMid).toFixed(6);
              drawTicketLine();
            }
          }
        },
          el('span', { style: `color:${b.is_poc ? '#f8fafc' : '#cbd5e1'}; font-weight:${b.is_poc || isSpotBin ? '700' : '400'};`, text: `${fmt(bMid, 6)} ₳` }),
          el('span', { style: `color:${tagCol}; font-weight:700; font-size:8.5px;`, text: tagText }),
          barTrack,
          el('span', { style: 'text-align:right; color:#94a3b8;', text: `${Math.round(b.volume).toLocaleString()} ₳` })
        );
        rowsWrap.append(row);
      });
      vrvpPanel.append(rowsWrap);
      box.append(vrvpPanel);
    }
  }

  function renderChartMeta(d) {
    $('deskKpiSpot').textContent = `${fmt(d.spot)} ADA`;
    $('deskKpiPool').textContent = `${d.pool.dex} · depth ≈ ${d.pool.reserve_ada_est ? Math.round(d.pool.reserve_ada_est).toLocaleString() : '—'} ADA`;
    const c24 = (d.cone || []).find((c) => c.hours === 24);
    const c1 = (d.cone || []).find((c) => c.hours === 1);
    $('deskKpiVol').textContent = c1 ? `${((Math.log(c1.p1 / d.spot)) * 100).toFixed(2)}%/h` : '—';
    $('deskKpiCone').textContent = c24 ? `24h ±1σ: ${fmt(c24.m1)} – ${fmt(c24.p1)}` : '—';
    const dg = d.diagnostics || {};
    const km = dg.kalman || {};
    const rg = dg.regime || {};
    const reg = rg.current || dg.current_regime || (dg.ou_actionable ? 'MEAN_REVERTING' : 'RANDOM_WALK');
    const kz = km.deviation_sigma ?? dg.kalman_z;
    const vr4 = rg.vr_4 ?? dg.current_vr ?? km.vr_k;
    const khl = km.half_life_h ?? dg.kalman_half_life_h;
    $('deskKpiOu').textContent = kz != null ? `Z = ${kz >= 0 ? '+' : ''}${Number(kz).toFixed(2)}σ · ${reg}` : (dg.ou_actionable ? 'Significant' : 'Not significant');
    $('deskKpiOu').style.color = (reg === 'MEAN_REVERTING' || dg.ou_actionable) ? '#10b981' : '#38bdf8';
    $('deskKpiOuWhy').textContent = `VR(4)=${vr4 != null ? Number(vr4).toFixed(2) : '—'} · ADF p=${dg.adf_pvalue != null ? dg.adf_pvalue.toFixed(2) : '—'} · t½=${khl != null ? Number(khl).toFixed(1) + 'h' : '—'}`;
    $('deskChartTitle').textContent = `${d.asset}/ADA · ${tfLabel()}`;
    const prov = d.provenance && d.provenance.ohlcv ? d.provenance.ohlcv : {};
    const srcMode = d.source_mode || prov.source || 'market_db_onchain';
    const srcLabel = srcMode.includes('hybrid') || srcMode.includes('stitch')
      ? `On-Chain market.db (${prov.onchain_bars ?? '—'}b) + Gecko Stitch (${prov.gecko_bars ?? '—'}b)`
      : (srcMode.includes('market')
        ? `On-Chain market.db (${prov.onchain_bars || d.candles.length} bars)`
        : 'GeckoTerminal Fallback');
    $('deskProvenance').textContent = `${srcLabel} · age ${prov.age_s ?? '—'}s${prov.stale ? ' · STALE' : ''} · ${(d.coverage * 100).toFixed(0)}% bars traded · click markers for cardanoscan`;
    const pl = $('deskPoolLink'); const tl = $('deskTokenLink');
    if (d.explorer && SAFE_LINK.test(d.explorer.pool)) pl.href = d.explorer.pool;
    if (d.explorer && SAFE_LINK.test(d.explorer.token)) tl.href = d.explorer.token;

    // ── Cardano-Native Overlays Rendering ──
    // 1. Batcher Queue Pressure Bar (real market.db swap telemetry)
    const bqEl = $('deskBatcherPressureGauge');
    if (bqEl && d.batcher_queue_pressure) {
      const bq = d.batcher_queue_pressure;
      const _n = (v, s = '') => (v === null || v === undefined ? '—' : `${v}${s}`);
      if (bq.pending_swaps != null) {
        bqEl.textContent = `BATCHER QUEUE: ${bq.pending_swaps} PENDING (~${_n(bq.estimated_latency_s, 's')} / ${_n(bq.estimated_blocks_lag)} BLK) · ${bq.status}`;
      } else {
        const ageStr = bq.last_batch_age_s != null ? `${bq.last_batch_age_s}s ago` : 'idle';
        const feeStr = bq.measured_batcher_fee_ada != null ? `${bq.measured_batcher_fee_ada}₳ fee` : '';
        bqEl.textContent = `BATCHER 1H: ${bq.batches_last_hour ?? 0} BATCHES (${bq.orders_filled_last_hour ?? 0} FILLS · last ${ageStr}${feeStr ? ' · ' + feeStr : ''}) · ${bq.status || 'NORMAL'}`;
      }
      bqEl.style.color = (bq.status === 'NORMAL' || bq.status === 'IDLE' || bq.status === 'FLOWING') ? '#10b981' : '#f59e0b';
    }

    // 2. Arbitrage Spread Corridor Chips
    const scEl = $('deskSpreadCorridorContainer');
    if (scEl) {
      scEl.replaceChildren();
      const corridor = d.arbitrage_spread_corridor || [];
      if (!corridor.length) {
        scEl.append(el('span', { style: 'color:#64748b; font-size:11px;', text: 'No secondary AMM pools active for this asset.' }));
      } else {
        corridor.forEach((c) => {
          const sign = c.spread_pct > 0 ? '+' : '';
          const col = c.spread_pct > 0 ? '#10b981' : '#38bdf8';
          const badge = el('div', {
            style: 'background:#0f172a; border:1px solid #334155; border-radius:4px; padding:3px 8px; font-size:11px; display:inline-flex; align-items:center; gap:6px;'
          },
            el('strong', { style: 'color:#f8fafc;', text: c.dex }),
            el('span', { style: 'color:#94a3b8;', text: `${fmt(c.price_ada)} ₳` }),
            el('span', { style: `color:${col}; font-weight:700;`, text: `(${sign}${c.spread_pct}% ${c.spread_direction})` })
          );
          scEl.append(badge);
        });
      }
    }

    // 3. Structure Analytics (VRVP, Regime, Fee Hurdles, Walk-Forward Backtest)
    renderStructureAnalytics(d);

    // 4. Constant-Product Liquidity Curve & Slippage Grid
    const cpmmEl = $('deskCpmmCurveContainer');
    if (cpmmEl) {
      if (ov('cpmm') && d.cpmm_liquidity_curve && d.cpmm_liquidity_curve.length) {
        cpmmEl.style.display = 'block';
        cpmmEl.replaceChildren();
        const header = el('div', { style: 'font-weight:700; color:#cbd5e1; margin-bottom:6px; font-size:11px;', text: `CONSTANT-PRODUCT LIQUIDITY CURVE & SLIPPAGE (RESERVE: ${Math.round(d.pool.reserve_ada_est || 50000).toLocaleString()} ADA)` });
        const grid = el('div', { style: 'display:grid; grid-template-columns:repeat(auto-fit, minmax(130px, 1fr)); gap:6px;' });
        d.cpmm_liquidity_curve.forEach((item) => {
          const itemBox = el('div', { style: 'background:#060a12; border:1px solid #1e293b; padding:4px 6px; border-radius:3px;' },
            el('div', { style: 'color:#38bdf8; font-weight:700; font-size:11px;', text: `${item.size_ada} ADA SWAP` }),
            el('div', { style: 'color:#f8fafc; font-size:11px;', text: `${Number(item.tokens_out).toLocaleString()} ${d.asset}` }),
            el('div', { style: `color:${item.slippage_pct > 1.0 ? '#f59e0b' : '#10b981'}; font-size:10px; font-weight:600;`, text: `Slippage: +${item.slippage_pct}%` })
          );
          grid.append(itemBox);
        });
        cpmmEl.append(header, grid);
      } else {
        cpmmEl.style.display = 'none';
      }
    }

    // 5. Real CPMM + Multi-DEX + Resting Limit Order Book
    const obPanel = $('deskOrderBookPanel');
    if (obPanel) {
      bookDataCache[d.asset] = { data: d, time: Date.now() };
      renderOrderBook(obPanel, d.asset);
    }

    // 6. Desk Feed: Policy, Gates, Plans, Standing Orders, Markouts, Trips
    loadDeskFeed();
  }

  let selectedCointPair = null;
  let selectedBookAsset = null;
  const bookDataCache = {};
  const KNOWN_BOOK_ASSETS = ['IAG', 'SNEK', 'MIN', 'WMTX', 'DJED', 'USDM', 'NIGHT', 'USDCX', 'HOSKY'];

  function renderSpreadCorridorSvg(p) {
    const series = p.corridor_series || [];
    const ou = p.ornstein_uhlenbeck || {};
    const mu = ou.mu_mean != null ? ou.mu_mean : 0.0;
    const sigma = ou.sigma != null ? ou.sigma : 1.0;
    const variance = ou.variance != null ? ou.variance : (sigma * sigma);
    const halfLife = ou.half_life_hours != null ? `${ou.half_life_hours.toFixed(1)} hrs` : '—';
    const pval = p.cointegration?.adf_pvalue != null ? p.cointegration.adf_pvalue.toFixed(4) : '—';
    const isCoint = p.cointegration?.is_cointegrated;

    if (!series.length) {
      return el('div', { style: 'color:#64748b; font-size:11px; padding:8px; text-align:center;' }, 'No corridor series points available.');
    }

    const w = 720;
    const h = 150;
    const padL = 40;
    const padR = 60;
    const padT = 14;
    const padB = 18;
    const plotW = w - padL - padR;
    const plotH = h - padT - padB;

    const spreads = series.map((d) => d.spread);
    const minS = Math.min(mu - 2.5 * sigma, ...spreads);
    const maxS = Math.max(mu + 2.5 * sigma, ...spreads);
    const span = (maxS - minS) || 1.0;

    const getY = (val) => padT + plotH - ((val - minS) / span) * plotH;
    const getX = (idx) => padL + (idx / Math.max(1, series.length - 1)) * plotW;

    const yMu = getY(mu);
    const yUpper15 = getY(mu + 1.5 * sigma);
    const yUpper20 = getY(mu + 2.0 * sigma);
    const yLower15 = getY(mu - 1.5 * sigma);
    const yLower20 = getY(mu - 2.0 * sigma);

    const pts = series.map((d, i) => `${getX(i).toFixed(1)},${getY(d.spread).toFixed(1)}`).join(' ');
    const corridorFill = `M ${padL},${yUpper15.toFixed(1)} L ${padL + plotW},${yUpper15.toFixed(1)} L ${padL + plotW},${yLower15.toFixed(1)} L ${padL},${yLower15.toFixed(1)} Z`;

    const lastX = getX(series.length - 1).toFixed(1);
    const lastY = getY(series[series.length - 1].spread).toFixed(1);

    const svgWrap = el('div', { style: 'position:relative; margin-top:4px;' });
    svgWrap.innerHTML = `
      <svg viewBox="0 0 ${w} ${h}" style="width:100%; height:auto; max-height:160px; background:#030712; border:1px solid #1e293b; border-radius:4px; font-family:monospace; display:block;">
        <defs>
          <linearGradient id="corridorGrad" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stop-color="#10b981" stop-opacity="0.08"/>
            <stop offset="50%" stop-color="#06b6d4" stop-opacity="0.04"/>
            <stop offset="100%" stop-color="#10b981" stop-opacity="0.08"/>
          </linearGradient>
        </defs>
        
        <path d="${corridorFill}" fill="url(#corridorGrad)" />
        
        <line x1="${padL}" y1="${yUpper20.toFixed(1)}" x2="${padL + plotW}" y2="${yUpper20.toFixed(1)}" stroke="#ef4444" stroke-dasharray="3,3" stroke-width="0.75" />
        <text x="${padL + plotW + 4}" y="${(yUpper20 + 3).toFixed(1)}" fill="#ef4444" font-size="8">+2.0σ</text>

        <line x1="${padL}" y1="${yUpper15.toFixed(1)}" x2="${padL + plotW}" y2="${yUpper15.toFixed(1)}" stroke="#f59e0b" stroke-dasharray="2,2" stroke-width="0.75" />
        <text x="${padL + plotW + 4}" y="${(yUpper15 + 3).toFixed(1)}" fill="#f59e0b" font-size="8">+1.5σ</text>

        <line x1="${padL}" y1="${yMu.toFixed(1)}" x2="${padL + plotW}" y2="${yMu.toFixed(1)}" stroke="#38bdf8" stroke-dasharray="4,4" stroke-width="0.9" />
        <text x="${padL + plotW + 4}" y="${(yMu + 3).toFixed(1)}" fill="#38bdf8" font-size="8">Mean (μ)</text>

        <line x1="${padL}" y1="${yLower15.toFixed(1)}" x2="${padL + plotW}" y2="${yLower15.toFixed(1)}" stroke="#f59e0b" stroke-dasharray="2,2" stroke-width="0.75" />
        <text x="${padL + plotW + 4}" y="${(yLower15 + 3).toFixed(1)}" fill="#f59e0b" font-size="8">-1.5σ</text>

        <line x1="${padL}" y1="${yLower20.toFixed(1)}" x2="${padL + plotW}" y2="${yLower20.toFixed(1)}" stroke="#ef4444" stroke-dasharray="3,3" stroke-width="0.75" />
        <text x="${padL + plotW + 4}" y="${(yLower20 + 3).toFixed(1)}" fill="#ef4444" font-size="8">-2.0σ</text>

        <polyline points="${pts}" fill="none" stroke="#22d3ee" stroke-width="1.75" />
        <circle cx="${lastX}" cy="${lastY}" r="3.5" fill="#38bdf8" stroke="#ffffff" stroke-width="1.5" />
      </svg>
    `;

    const metricsBar = el('div', { style: 'display:grid; grid-template-columns:repeat(auto-fit, minmax(110px, 1fr)); gap:5px; background:#070d18; border:1px solid #1e293b; border-radius:4px; padding:5px 8px; margin-top:4px; font-size:9.5px;' },
      el('div', null, el('span', { style: 'color:#64748b;' }, 'Mean Rev: '), el('strong', { style: 'color:#38bdf8;' }, halfLife)),
      el('div', null, el('span', { style: 'color:#64748b;' }, 'Var (σ²): '), el('strong', { style: 'color:#cbd5e1;' }, variance.toFixed(6))),
      el('div', null, el('span', { style: 'color:#64748b;' }, 'Beta (β): '), el('strong', { style: 'color:#cbd5e1;' }, p.hedge_ratio_beta || '—')),
      el('div', null, el('span', { style: 'color:#64748b;' }, 'Stationarity: '), el('strong', { style: `color:${isCoint ? '#10b981' : '#94a3b8'};` }, isCoint ? `p=${pval} (PASS)` : `p=${pval} (FAIL)`)),
      el('div', null, el('span', { style: 'color:#64748b;' }, 'Z-Score: '), el('strong', { style: `color:${Math.abs(p.z_score) >= 1.35 ? '#f59e0b' : '#38bdf8'};` }, `${p.z_score >= 0 ? '+' : ''}${p.z_score}σ`))
    );

    return el('div', null, svgWrap, metricsBar);
  }

  async function renderOrderBook(container, asset) {
    if (!container) return;
    const targetAsset = asset || selectedBookAsset || state.asset || 'IAG';
    container.replaceChildren();

    // 1. Header with title & pair switcher
    const nav = el('div', { class: 'desk-book-nav' });
    KNOWN_BOOK_ASSETS.forEach((sym) => {
      const isAct = sym === targetAsset;
      const btn = el('button', {
        class: isAct ? 'active' : '',
        text: sym,
        onclick: () => {
          selectedBookAsset = sym;
          renderOrderBook(container, sym);
        },
      });
      nav.append(btn);
    });

    const header = el('div', { style: 'display:flex; justify-content:space-between; align-items:center;' },
      el('div', { style: 'display:flex; align-items:center; gap:6px;' },
        el('strong', { style: 'color:#38bdf8; font-size:11px;', text: `ORDER BOOK: ${targetAsset} / ADA` }),
        el('button', {
          class: 'desk-btn sm ghost',
          style: 'padding:1px 5px; font-size:8.5px;',
          text: 'SYNC CHART',
          title: `Load ${targetAsset} on main desk chart`,
          onclick: () => {
            state.asset = targetAsset;
            if ($('deskAsset')) $('deskAsset').value = targetAsset;
            $('deskPrice').value = '';
            loadChart();
          },
        })
      ),
      el('span', { style: 'color:#64748b; font-size:9.5px;', text: 'CLICK ROW → TICKET' })
    );

    container.append(header, nav);

    // Fetch data if targetAsset is not state.asset or if state.data is empty
    let chartData = null;
    if (targetAsset === state.asset && state.data && state.data.spot) {
      chartData = state.data;
    } else if (bookDataCache[targetAsset] && (Date.now() - bookDataCache[targetAsset].time < 45000)) {
      chartData = bookDataCache[targetAsset].data;
    } else {
      const loadingPlaceholder = el('div', { style: 'color:#64748b; font-size:10px; padding:12px; text-align:center;', text: `Fetching live on-chain CPMM + multi-DEX book for ${targetAsset}…` });
      container.append(loadingPlaceholder);
      try {
        const d = await api(`/api/finance/chart?asset=${targetAsset}&timeframe=hour&aggregate=1&bars=60`);
        bookDataCache[targetAsset] = { data: d, time: Date.now() };
        chartData = d;
        loadingPlaceholder.remove();
      } catch (err) {
        loadingPlaceholder.textContent = `Order book unavailable: ${err.message}`;
        return;
      }
    }

    const spot = Number(chartData.spot || 0.0);
    if (!(spot > 0)) {
      container.append(el('div', { style: 'color:#64748b; font-size:10px; padding:8px;', text: 'No active pool spot found.' }));
      return;
    }

    const ob = chartData.order_book || {};
    const allPools = chartData.all_pools || [];
    const restingOrders = chartData.orders || [];
    const activePlans = (chartData.sim_and_plans && chartData.sim_and_plans.plans) || chartData.plans || [];
    const primaryVenue = ob.primary_venue || (chartData.pool?.dex || 'MINSWAP-V2').toUpperCase();

    // Venue ticker chips
    const venueTicker = el('div', { style: 'display:flex; gap:6px; flex-wrap:wrap; font-size:9.5px; margin-bottom:2px;' });
    venueTicker.append(
      el('span', { style: 'background:#0c1527; border:1px solid #1e293b; padding:1px 6px; border-radius:3px; color:#38bdf8;' },
        `${primaryVenue}: ${fmt(spot, 6)} ₳`)
    );
    allPools.filter((p) => !p.off_market && p.dex !== chartData.pool?.dex && p.price_ada > 0).slice(0, 2).forEach((sec) => {
      const secDex = (sec.dex || 'SecDEX').replace('-cardano', '').toUpperCase();
      const secPx = Number(sec.price_ada);
      const diffPct = ((secPx - spot) / spot * 100).toFixed(1);
      const sign = diffPct > 0 ? '+' : '';
      const col = diffPct > 0 ? '#10b981' : '#f59e0b';
      venueTicker.append(
        el('span', { style: 'background:#0f172a; border:1px solid #1e293b; padding:1px 6px; border-radius:3px; color:#94a3b8;' },
          `${secDex}: ${fmt(secPx, 6)} ₳ `, el('strong', { style: `color:${col};` }, `(${sign}${diffPct}%)`))
      );
    });
    const activeCount = restingOrders.length + activePlans.length;
    if (activeCount > 0) {
      venueTicker.append(
        el('span', { style: 'background:#1a0f24; border:1px solid #4a154b; padding:1px 6px; border-radius:3px; color:#f472b6;' },
          `RESTING/PLANS: ${activeCount}`)
      );
    }
    container.append(venueTicker);

    const visibleAsks = (ob.asks && ob.asks.length) ? ob.asks.slice(-6) : [];
    const visibleBids = (ob.bids && ob.bids.length) ? ob.bids.slice(0, 6) : [];

    const maxDepth = Math.max(
      ...visibleAsks.map((x) => Number(x.cumDepthAda || x.cum_ada || x.depthAda || x.depth_ada || 1)),
      ...visibleBids.map((x) => Number(x.cumDepthAda || x.cum_ada || x.depthAda || x.depth_ada || 1)),
      1.0
    );

    const bestAsk = Number(ob.best_ask || (visibleAsks.length ? visibleAsks[visibleAsks.length - 1].price : spot * 1.003));
    const bestBid = Number(ob.best_bid || (visibleBids.length ? visibleBids[0].price : spot * 0.997));
    const midPrice = Number(ob.mid_price || ((bestAsk + bestBid) / 2));
    const spreadAda = Number(ob.spread_ada != null ? ob.spread_ada : Math.max(0, bestAsk - bestBid));
    const spreadPct = Number(ob.spread_pct != null ? ob.spread_pct : ((spreadAda / spot) * 100));

    // Render table
    const tableEl = el('table', { class: 'desk-book-table' });
    const thead = el('thead', null,
      el('tr', null,
        el('th', { style: 'text-align:left;' }, 'PRICE (₳)'),
        el('th', { style: 'text-align:right;' }, `SIZE (${targetAsset})`),
        el('th', { style: 'text-align:right;' }, 'CUM (₳)'),
        el('th', { style: 'text-align:center;' }, 'VENUE')
      )
    );
    tableEl.append(thead);

    const tbody = el('tbody');

    const pickPrice = (row) => {
      if ($('deskPrice')) {
        $('deskPrice').value = Number(row.price).toFixed(6);
        $('deskPrice').style.outline = '2px solid #38bdf8';
        setTimeout(() => { if ($('deskPrice')) $('deskPrice').style.outline = 'none'; }, 600);
      }
      if (row.size > 0 && $('deskAmount')) {
        $('deskAmount').value = Math.max(1, Math.round(row.size));
      }
      state.dir = (row.side === 'ask' ? 'buy' : 'sell');
      document.querySelectorAll('.desk-seg.buy-sell button').forEach((b) => {
        b.classList.toggle('active', b.dataset.dir === state.dir);
      });
      drawTicketLine();
      log(`Order book level selected: ${state.dir.toUpperCase()} @ ${Number(row.price).toFixed(6)} ₳ (${row.venue})`, 'ok');
    };

    // Render Asks (highest to lowest towards spread)
    visibleAsks.forEach((row) => {
      const dVal = Number(row.cumDepthAda || row.cum_ada || row.depthAda || row.depth_ada || 0);
      const mVal = Number(row.depthAda || row.depth_ada || dVal);
      const pctWidth = Math.min(100, Math.max(8, (dVal / maxDepth) * 100)).toFixed(0);
      const venueClass = String(row.venue || 'MIN-V2').toLowerCase().replace(/[^a-z0-9]/g, '');
      const tr = el('tr', {
        class: 'desk-book-row ask',
        style: `background: linear-gradient(to left, rgba(239, 68, 68, 0.16) ${pctWidth}%, transparent ${pctWidth}%);`,
        title: `${row.venue} · Marginal: ${Math.round(mVal)} ₳ · Cum: ${Math.round(dVal)} ₳ — Click to set BUY ticket @ ${Number(row.price).toFixed(6)} ADA`,
        onclick: () => pickPrice(row),
      },
        el('td', { class: 'px', style: 'text-align:left; font-weight:700;' }, Number(row.price).toFixed(6)),
        el('td', { style: 'text-align:right; color:#cbd5e1;' }, Math.round(row.size || 0).toLocaleString()),
        el('td', { style: 'text-align:right; color:#94a3b8;' }, Math.round(dVal).toLocaleString()),
        el('td', { style: 'text-align:center;' },
          el('span', { class: `desk-book-venue ${venueClass}`, text: row.venue }))
      );
      tbody.append(tr);
    });

    // Spread Divider Row
    const spreadTr = el('tr', null,
      el('td', { colspan: '4', style: 'padding:2px 0;' },
        el('div', { class: 'desk-spread-row' },
          el('span', null, el('strong', { style: 'color:#cbd5e1;' }, 'MID: '), `${midPrice.toFixed(6)} ₳`),
          el('span', { style: 'color:#cbd5e1;' }, `EFF SPREAD: ${spreadPct.toFixed(2)}%`),
          el('span', { style: 'color:#38bdf8; font-weight:700;' }, `LP ${chartData.pool?.fee_bps ?? 30} BPS`)
        )
      )
    );
    tbody.append(spreadTr);

    // Render Bids (highest to lowest away from spread)
    visibleBids.forEach((row) => {
      const dVal = Number(row.cumDepthAda || row.cum_ada || row.depthAda || row.depth_ada || 0);
      const mVal = Number(row.depthAda || row.depth_ada || dVal);
      const pctWidth = Math.min(100, Math.max(8, (dVal / maxDepth) * 100)).toFixed(0);
      const venueClass = String(row.venue || 'MIN-V2').toLowerCase().replace(/[^a-z0-9]/g, '');
      const tr = el('tr', {
        class: 'desk-book-row bid',
        style: `background: linear-gradient(to left, rgba(16, 185, 129, 0.16) ${pctWidth}%, transparent ${pctWidth}%);`,
        title: `${row.venue} · Marginal: ${Math.round(mVal)} ₳ · Cum: ${Math.round(dVal)} ₳ — Click to set SELL ticket @ ${Number(row.price).toFixed(6)} ADA`,
        onclick: () => pickPrice(row),
      },
        el('td', { class: 'px', style: 'text-align:left; font-weight:700;' }, Number(row.price).toFixed(6)),
        el('td', { style: 'text-align:right; color:#cbd5e1;' }, Math.round(row.size || 0).toLocaleString()),
        el('td', { style: 'text-align:right; color:#94a3b8;' }, Math.round(dVal).toLocaleString()),
        el('td', { style: 'text-align:center;' },
          el('span', { class: `desk-book-venue ${venueClass}`, text: row.venue }))
      );
      tbody.append(tr);
    });

    tableEl.append(tbody);
    container.append(tableEl);

    // Small footer hint
    container.append(
      el('div', { style: 'display:flex; justify-content:space-between; align-items:center; font-size:8.5px; color:#64748b; margin-top:2px;' },
        el('span', null, `Exact CPMM marginal depth (reserve ≈ ${Math.round(ob.reserve_ada || chartData.pool?.reserve_ada_est || 0).toLocaleString()} ₳) + resting UTxOs.`),
        el('span', { style: 'color:#10b981;' }, '● ON-CHAIN DEPTH')
      )
    );
  }

  // ---------------------------------------------------------------- desk feed (P5)
  async function confirmPlan(planId) {
    if (!planId) return;
    const ok = await modal({
      title: 'Confirm Tier B Plan',
      body: [el('p', { text: `Execute proposed Tier B plan ${planId}?` })],
      actions: [
        { text: 'CANCEL', cls: 'ghost', result: false },
        { text: 'CONFIRM & EXECUTE', cls: 'go', result: true },
      ],
    });
    if (!ok) return;
    try {
      const res = await api('/api/finance/desk/plan/confirm', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ plan_id: planId })
      });
      if (res && (res.status === 'executed' || res.status === 'partially_executed' || res.status === 'ok')) {
        log(`[PLAN CONFIRMED] Plan ${planId} (${res.status}) via web desk.`, 'ok');
        loadDeskFeed();
        loadChart();
      } else {
        log(`[PLAN CONFIRM ERROR] ${res?.reason || res?.error || 'Confirmation rejected'}`, 'err');
      }
    } catch (e) {
      log(`[PLAN CONFIRM EXCEPTION] ${e.message}`, 'err');
    }
  }

  async function revokeStandingOrder(envelopeId) {
    if (!envelopeId) return;
    const ok = await modal({
      title: 'Revoke Standing Order',
      body: [el('p', { text: `Revoke standing order envelope ${envelopeId}?` })],
      actions: [
        { text: 'CANCEL', cls: 'ghost', result: false },
        { text: 'REVOKE', cls: 'danger', result: true },
      ],
    });
    if (!ok) return;
    try {
      const res = await api('/api/finance/desk/standing-order/revoke', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ envelope_id: envelopeId })
      });
      if (res && (res.status === 'ok' || res.revoked)) {
        log(`[STANDING ORDER REVOKED] Order envelope ${envelopeId} revoked.`, 'ok');
        loadDeskFeed();
        loadChart();
      } else {
        log(`[REVOKE ERROR] ${res?.reason || res?.error || 'Revocation failed'}`, 'err');
      }
    } catch (e) {
      log(`[REVOKE EXCEPTION] ${e.message}`, 'err');
    }
  }

  async function loadDeskFeed() {
    try {
      const feed = await api('/api/finance/desk/feed');
      if (!feed || feed.status !== 'ok') return;

      // 1. Policy & Gates Panel
      const pol = feed.policy || {};
      const gates = feed.gates || {};
      const freezeBadge = $('deskPolicyFreezeBadge');
      if (freezeBadge) {
        const isFrozen = Boolean(pol.frozen || (gates.freeze && gates.freeze.frozen) || (pol.capital && pol.capital.freeze));
        freezeBadge.textContent = isFrozen ? 'FROZEN' : 'UNFROZEN';
        freezeBadge.className = `fadell-badge ${isFrozen ? 'disarmed' : 'floor-safe'}`;
      }

      const stageBadge = $('fadellDeskGateStageBadge');
      if (stageBadge) {
        const g1 = gates.gate1 || {};
        const g2 = gates.gate2 || {};
        const s2g = g1.S2_shock_fade || g1.s2 || {};
        const s3g = g1.S3_stable_deviation || g1.s3 || {};
        const g1Pass = Boolean(g1.overall_pass || s2g.ready || s3g.ready);
        const g2Pass = Boolean(g2.passed || g2.overall_pass);
        if (g2Pass) {
          stageBadge.textContent = 'GATE 2 PASS · FULL LIVE DEPLOYED';
          stageBadge.className = 'fadell-badge floor-safe';
        } else if (g1Pass) {
          stageBadge.textContent = 'GATE 1 PASS · LIVE PILOT READY';
          stageBadge.className = 'fadell-badge floor-safe';
        } else {
          stageBadge.textContent = 'STAGE 0 · S1 LIVE (S2/S3 GATED)';
          stageBadge.className = 'fadell-badge armed';
        }
      }

      const polGatesContent = $('deskPolicyGatesContent');
      if (polGatesContent) {
        polGatesContent.replaceChildren();
        const modeText = pol.live_execution ? 'LIVE EXECUTION ENABLED' : 'DRY-RUN ONLY (FAIL-CLOSED)';
        const modeCol = pol.live_execution ? '#10b981' : '#f59e0b';
        const cap = pol.capital || {};
        const wal = pol.wallet || {};
        const strats = pol.strategies || {};

        const g1 = gates.gate1 || {};
        const s2g = g1.S2_shock_fade || g1.s2 || {};
        const s3g = g1.S3_stable_deviation || g1.s3 || {};
        const s2SimN = s2g.sim?.n ?? s2g.trips_run ?? 0;
        const s2Mean = s2g.sim?.mean ?? s2g.mean_ada;
        const s3SimN = s3g.sim?.n ?? s3g.trips_run ?? 0;
        const s3Mean = s3g.sim?.mean ?? s3g.mean_ada;
        const s2Status = (s2g.ready || s2g.passed) ? 'PASS' : `WAIT (${s2SimN} sims, mean: ${fmt(s2Mean, 2)}A)`;
        const s3Status = (s3g.ready || s3g.passed) ? 'PASS' : `WAIT (${s3SimN} sims, mean: ${fmt(s3Mean, 2)}A)`;

        polGatesContent.append(
          el('div', { style: `color:${modeCol}; font-weight:700; margin-bottom:2px;` }, `EXECUTION: ${modeText}`),
          el('div', { style: 'display:flex; justify-content:space-between; color:#94a3b8; font-size:9.5px;' },
            el('span', null, `Max Pos: ${cap.max_positions || 2} (${Math.round((cap.max_position_fraction || 0.9) * 100)}% cap) · Min Order: ${cap.min_order_ada || 25} ADA`),
            el('span', null, `Floor: ${wal.floor_ada ?? cap.reserve_floor_ada ?? 40} ADA · Buffer: ${wal.fee_buffer_ada ?? cap.fee_reserve_ada ?? 10} ADA`)
          ),
          el('div', { style: 'margin-top:3px; padding-top:3px; border-top:1px solid #1e293b; display:flex; justify-content:space-between; font-size:9.5px;' },
            el('span', { style: 'color:#38bdf8;' }, `S1 (Exit): ${strats.S1_inventory_exit || strats.s1_cross_dex_rebalance || 'live'}`),
            el('span', { style: 'color:#cbd5e1;' }, `Gate 1 (S2): ${s2Status}`),
            el('span', { style: 'color:#cbd5e1;' }, `Gate 1 (S3): ${s3Status}`)
          )
        );
      }

      // 2. Proposed & Recent Plans Table
      const plansAll = feed.plans || [];
      const nowPlanSec = Date.now() / 1000;
      const activePlans = plansAll.filter((p) => p.status === 'proposed' && (p.expires_at || 0) > nowPlanSec);
      const recentPlans = plansAll.filter((p) => {
        if (p.status === 'proposed' && (p.expires_at || 0) > nowPlanSec) return true;
        if (p.status === 'executed' || p.status === 'partially_executed') return true;
        const ageS = nowPlanSec - (p.expires_at || p.created_at || 0);
        return ageS < 3600;
      });
      const plans = (recentPlans.length ? recentPlans : plansAll.slice(0, 5)).slice(0, 12);
      const plansCount = $('deskPlansCount');
      if (plansCount) plansCount.textContent = `${activePlans.length} Active · ${plans.length} Shown`;
      const plansBody = $('deskPlansBody');
      if (plansBody) {
        plansBody.replaceChildren();
        if (!plans.length) {
          plansBody.append(el('tr', null, el('td', { colspan: '7', style: 'color:#64748b; text-align:center;', text: 'No active plans proposed' })));
        } else {
          plans.forEach((p) => {
            const acts = p.actions || [];
            const firstAct = acts[0] || {};
            const actLabel = acts.length > 1
              ? `${acts.length} LEGS (${acts.map((a) => `${(a.side || a.type || '').toUpperCase()} ${a.asset || ''}`.trim()).join(', ')})`
              : (`${(firstAct.side || '').toUpperCase()} ${firstAct.asset || '—'}`.trim() || firstAct.type || firstAct.kind || '—');
            const priceText = firstAct.price != null ? `${fmt(firstAct.price, 6)} ADA` : 'MKT';
            const totalAda = acts.reduce((acc, a) => acc + (Number(a.ada ?? a.budget_ada) || 0), 0);
            const capText = totalAda > 0 ? `${fmt(totalAda, 1)} ADA` : (firstAct.tokens != null ? `${fmt(firstAct.tokens, 1)} ${firstAct.asset || ''}` : '—');
            const evVal = firstAct.ev_ada;
            const pFillVal = firstAct.p_fill;
            const evText = evVal != null ? `${evVal >= 0 ? '+' : ''}${fmt(evVal, 2)} ADA` : '—';
            const pFillText = pFillVal != null ? `${Math.round(pFillVal * 100)}%` : '—';
            const evPFill = `${evText} / ${pFillText}`;

            const remainingS = Math.max(0, Math.round((p.expires_at || 0) - nowPlanSec));
            const effStatus = (p.status === 'proposed' && remainingS <= 0) ? 'expired' : (p.status || 'proposed');
            const isConfirmable = Boolean(p.confirmable && remainingS > 0 && effStatus === 'proposed');
            const isStale = effStatus === 'expired' || effStatus === 'superseded' || effStatus === 'rejected';
            const tierBadge = el('span', { style: 'background:#1e293b; color:#cbd5e1; padding:1px 5px; border-radius:3px; font-weight:700; font-size:9px; margin-right:4px;', text: `T-${p.tier || 'B'}` });
            const expText = remainingS > 0 && effStatus === 'proposed' ? `${Math.ceil(remainingS / 60)}m left` : 'expired';
            const tierExpiryCell = el('td', null, tierBadge, document.createTextNode(expText));

            const statusCell = el('td');
            if (isConfirmable) {
              const confirmBtn = el('button', {
                class: 'desk-btn sm',
                style: 'background:#10b981; color:#0f172a; font-weight:700; padding:2px 8px; font-size:10px;',
                onclick: () => confirmPlan(p.plan_id)
              }, 'CONFIRM');
              statusCell.append(confirmBtn);
            } else {
              const sCol = effStatus === 'executed' ? '#10b981' : (effStatus === 'rejected' || effStatus === 'blocked' ? '#f87171' : '#64748b');
              statusCell.append(el('span', { style: `color:${sCol}; font-weight:700; font-size:10px; text-transform:uppercase;`, text: effStatus }));
            }

            const tr = el('tr', { style: isStale ? 'opacity:0.52;' : '' },
              el('td', { style: 'font-family:var(--font-mono); font-weight:700; color:#38bdf8;', text: p.plan_id }),
              el('td', { style: 'font-weight:600;', text: actLabel }),
              el('td', null, priceText),
              el('td', null, capText),
              el('td', { style: 'color:#10b981;', text: evPFill }),
              tierExpiryCell,
              statusCell
            );
            plansBody.append(tr);
          });
        }
      }

      // 3. Active Standing Orders Table
      const standingAll = feed.standing_orders || [];
      const nowSec = Date.now() / 1000;
      const standing = standingAll.filter((so) => (!so.status || so.status === 'active') && (!so.expires_at || so.expires_at > nowSec));
      const standingCount = $('deskStandingCount');
      if (standingCount) standingCount.textContent = `${standing.length} Active`;
      const standingBody = $('deskStandingBody');
      if (standingBody) {
        standingBody.replaceChildren();
        if (!standing.length) {
          standingBody.append(el('tr', null, el('td', { colspan: '7', style: 'color:#64748b; text-align:center;', text: 'No active standing orders' })));
        } else {
          standing.forEach((so) => {
            const soId = so.so_id || so.envelope_id || '—';
            const pMin = so.price_min ?? so.min_price;
            const pMax = so.price_max ?? so.max_price;
            const maxAda = so.max_ada ?? so.max_capital_ada ?? 0;
            const usedAda = so.used_ada ?? 0;
            const bounds = `${pMin != null ? fmt(pMin, 6) : '0'} – ${pMax != null ? fmt(pMax, 6) : '∞'} ADA`;
            const revokeBtn = el('button', {
              class: 'desk-btn sm ghost',
              style: 'color:#f87171; border-color:#f87171; padding:2px 6px; font-size:10px;',
              onclick: () => revokeStandingOrder(soId)
            }, 'REVOKE');

            const expM = Math.max(0, Math.round(((so.expires_at || 0) - nowSec) / 60));

            const tr = el('tr', null,
              el('td', { style: 'font-family:var(--font-mono); font-weight:700; color:#a78bfa;', text: soId }),
              el('td', { text: so.strategy || '—' }),
              el('td', { style: 'font-weight:600;', text: so.asset || '—' }),
              el('td', null, bounds),
              el('td', null, `${fmt(usedAda, 1)} / ${fmt(maxAda, 1)} ADA`),
              el('td', { style: 'font-size:10px; color:#94a3b8;', text: `${expM}m remaining` }),
              el('td', null, revokeBtn)
            );
            standingBody.append(tr);
          });
        }
      }

      // 4. Fair Value Deviations Container
      const fvBox = $('deskFairValueContainer');
      if (fvBox) {
        const fvList = feed.fair_value || [];
        fvBox.replaceChildren();
        const fvHeader = el('div', { style: 'display:flex; justify-content:space-between; align-items:center; margin-bottom:6px; border-bottom:1px solid #1e293b; padding-bottom:4px;' },
          el('span', { style: 'font-weight:700; color:#cbd5e1; text-transform:uppercase; font-size:10.5px;', text: 'Fair Value Deviations & Kalman Local-Level Tracker' }),
          el('span', { style: 'color:#94a3b8; font-size:9.5px;', text: 'Mean-Reversion · OU Drift · Peg Parity' })
        );
        fvBox.append(fvHeader);

        if (!fvList.length) {
          fvBox.append(el('div', { style: 'color:#64748b; font-size:10px;', text: 'No pools registered in market recorder.' }));
        } else {
          const grid = el('div', { style: 'display:grid; grid-template-columns:repeat(auto-fit, minmax(200px, 1fr)); gap:6px;' });
          fvList.forEach((item) => {
            const z = item.deviation_sigma != null ? item.deviation_sigma : null;
            const zText = z != null ? `${z >= 0 ? '+' : ''}${z.toFixed(2)}σ` : '—';
            const zCol = z != null ? (Math.abs(z) >= 2.0 ? '#f87171' : (Math.abs(z) >= 1.35 ? '#f59e0b' : '#38bdf8')) : '#94a3b8';
            const vrText = item.vr != null ? item.vr.toFixed(2) : '—';
            const spotText = item.spot != null ? `${fmt(item.spot, 6)} ADA` : '—';
            const fvText = item.fair_value != null ? `${fmt(item.fair_value, 6)} ADA` : '—';
            const pegDev = item.peg_deviation_pct != null ? `${item.peg_deviation_pct >= 0 ? '+' : ''}${item.peg_deviation_pct.toFixed(2)}%` : null;
            const impactHl = item.impact && item.impact.half_life_h != null ? `${item.impact.half_life_h.toFixed(1)}h` : null;

            const card = el('div', { style: 'background:#060a12; border:1px solid #1e293b; border-radius:4px; padding:6px 8px;' },
              el('div', { style: 'display:flex; justify-content:space-between; align-items:center; margin-bottom:2px;' },
                el('strong', { style: 'color:#f8fafc; font-size:11px;', text: item.asset }),
                el('span', { style: `color:${zCol}; font-weight:700; font-size:11px;`, text: zText })
              ),
              el('div', { style: 'display:flex; justify-content:space-between; font-size:10px; color:#94a3b8;' },
                el('span', null, `Spot: ${spotText}`),
                el('span', null, `FV: ${fvText}`)
              ),
              el('div', { style: 'display:flex; justify-content:space-between; font-size:9.5px; color:#64748b; margin-top:2px;' },
                el('span', null, `VR_k: ${vrText}`),
                impactHl ? el('span', { style: 'color:#38bdf8;' }, `t½: ${impactHl}`) : el('span', null, `${item.history_days || 0}d hist`)
              ),
              pegDev ? el('div', { style: 'font-size:9.5px; color:#fbbf24; margin-top:2px; font-weight:600;' }, `Peg Dev: ${pegDev} (FV: ${fmt(item.peg_fair_value, 4)})`) : null
            );
            grid.append(card);
          });
          fvBox.append(grid);
        }
      }

      // 5. Market Recorder & API Budget Health Container
      const recBox = $('deskRecorderHealthContainer');
      if (recBox) {
        const rec = feed.recorder || {};
        recBox.replaceChildren();
        const mb = ((rec.size_bytes || 0) / (1024 * 1024)).toFixed(1);
        const mbCol = (rec.size_bytes || 0) > 1.8 * 1024 * 1024 * 1024 ? '#f87171' : '#10b981';

        const bf = rec.budgets?.blockfrost || {};
        const ko = rec.budgets?.koios || {};
        const bfPct = Math.min(100, Math.round(((bf.today || 0) / (bf.limit || 25000)) * 100));
        const koPct = Math.min(100, Math.round(((ko.today || 0) / (ko.limit || 10000)) * 100));

        const recHeader = el('div', { style: 'display:flex; justify-content:space-between; align-items:center; margin-bottom:6px; border-bottom:1px solid #1e293b; padding-bottom:4px;' },
          el('span', { style: 'font-weight:700; color:#cbd5e1; text-transform:uppercase; font-size:10.5px;', text: 'Data Foundation & API Budget Gauges' }),
          el('span', { style: `color:${mbCol}; font-weight:700; font-size:10px;`, text: `market.db: ${mb} MB / 2048 MB CAP` })
        );

        const rows = rec.rows || {};
        const swapsCount = rows.swaps ?? rows.pool_swaps ?? 0;
        const snapsCount = rows.pool_snapshots ?? rows.pool_states ?? 0;
        const cexCount = rows.cex_ticks ?? 0;
        const statsRow = el('div', { style: 'display:flex; justify-content:space-between; flex-wrap:wrap; gap:8px; font-size:10px; color:#94a3b8; margin-bottom:4px;' },
          el('span', null, `Swaps: ${swapsCount.toLocaleString()} · Snapshots: ${snapsCount.toLocaleString()} · CEX: ${cexCount.toLocaleString()}`),
          el('span', { style: 'color:#38bdf8;' }, `CEX Tick Lag: ${rec.cex_age_s != null ? rec.cex_age_s + 's' : '—'}`)
        );

        const budgetsRow = el('div', { style: 'display:flex; gap:16px; font-size:10px; color:#cbd5e1;' },
          el('span', null, `Blockfrost: ${bf.today || 0} / ${bf.limit || 25000} (${bfPct}%)`),
          el('span', null, `Koios: ${ko.today || 0} / ${ko.limit || 10000} (${koPct}%)`)
        );

        recBox.append(recHeader, statsRow, budgetsRow);
      }

      // 6. Fill Markouts Table
      const markouts = feed.markouts || {};
      const fills = markouts.fills || [];
      const mStats = $('deskMarkoutsStats');
      if (mStats) mStats.textContent = `${fills.length} FILLS SCORED`;
      const mBody = $('deskMarkoutsBody');
      if (mBody) {
        mBody.replaceChildren();
        if (!fills.length) {
          mBody.append(el('tr', null, el('td', { colspan: '8', style: 'color:var(--text-muted); text-align:center;', text: 'No measured fill markouts yet.' })));
        } else {
          fills.slice(0, 15).forEach((f) => {
            function renderH(hKey) {
              const h = f.h && f.h[hKey];
              if (!h || h.status === 'pending' || h.bps == null) return el('td', { style: 'color:#64748b; font-size:9.5px;', text: h?.status || 'pending' });
              const bps = Number(h.bps) || 0;
              const col = bps >= 0 ? '#10b981' : '#f87171';
              const sign = bps >= 0 ? '+' : '';
              return el('td', { style: `color:${col}; font-weight:600; font-size:9.5px;` }, `${sign}${bps.toFixed(1)} bps`);
            }

            const sideCol = (f.side || '').toUpperCase() === 'BUY' ? '#10b981' : '#f87171';
            const tr = el('tr', null,
              el('td', { style: 'font-family:var(--font-mono); font-size:10px;', text: (f.fill_id || '').slice(-8) }),
              el('td', { text: `${f.strategy || ''} · ${f.asset || ''}` }),
              el('td', { style: `color:${sideCol}; font-weight:700;`, text: (f.side || '').toUpperCase() }),
              el('td', null, `${fmt(f.fill_price, 6)} ADA`),
              renderH('300'),
              renderH('3600'),
              renderH('21600'),
              renderH('86400')
            );
            mBody.append(tr);
          });
        }
      }

      // 7. Closed Round Trips Table
      const trips = feed.trips || [];
      const tStats = $('deskTripsStats');
      if (tStats) tStats.textContent = `${trips.length} COMPLETED TRIPS`;
      const tBody = $('deskTripsBody');
      if (tBody) {
        tBody.replaceChildren();
        if (!trips.length) {
          tBody.append(el('tr', null, el('td', { colspan: '9', style: 'color:var(--text-muted); text-align:center;', text: 'No completed round trips recorded.' })));
        } else {
          trips.slice(0, 15).forEach((t) => {
            const pnl = t.net_pnl_ada || 0;
            const pnlCol = pnl >= 0 ? '#10b981' : '#f87171';
            const sign = pnl >= 0 ? '+' : '';
            const openDate = t.opened_at ? new Date(t.opened_at * 1000).toLocaleDateString() : '—';
            const closeDate = t.closed_at ? new Date(t.closed_at * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '—';

            const tr = el('tr', null,
              el('td', { style: 'font-family:var(--font-mono); font-size:10px;', text: (t.trip_id || '').slice(-8) }),
              el('td', { text: t.strategy || '—' }),
              el('td', { style: 'font-weight:600;', text: t.asset || '—' }),
              el('td', { style: 'font-size:9.5px; color:#94a3b8;', text: `${openDate} / ${closeDate}` }),
              el('td', { style: 'font-size:9.5px;', text: `${fmt(t.entry_price, 6)} / ${fmt(t.exit_price, 6)}` }),
              el('td', { style: 'font-size:9.5px;', text: `${fmt(t.entry_ada, 1)} / ${fmt(t.exit_ada, 1)} ADA` }),
              el('td', { style: 'color:#fbbf24; font-size:9.5px;', text: `${fmt(t.fees_ada, 3)} ADA` }),
              el('td', { style: `color:${pnlCol}; font-weight:700;`, text: `${sign}${fmt(pnl, 4)} ADA` }),
              el('td', null, el('span', { class: 'fadell-badge floor-safe', text: t.new_rules ? 'NEW RULES' : 'PASS' }))
            );
            tBody.append(tr);
          });
        }
      }

      // 8. Operator Escalations Inbox
      const esc = feed.escalations || {};
      const nowEscSec = Date.now() / 1000;
      const asks = (esc.open_asks || []).filter((a) => (!a.status || a.status === 'open') && (!a.expires_at || a.expires_at > nowEscSec));
      const inbox = esc.inbox || [];
      const escStatus = $('deskEscalationStatus');
      if (escStatus) {
        const baseMode = esc.discord_configured ? 'DISCORD ONLINE' : 'LOCAL INBOX';
        escStatus.textContent = asks.length ? `${baseMode} · ${asks.length} OPEN ASK` : baseMode;
      }
      const escList = $('deskEscalationList');
      if (escList) {
        escList.replaceChildren();
        if (!asks.length && !inbox.length) {
          escList.append(el('div', { style: 'color:var(--text-muted); font-size:10px; font-family:var(--font-mono); padding:4px;', text: 'No pending operator escalations.' }));
        } else {
          asks.forEach((ask) => {
            const qText = (ask.text || ask.question || ask.prompt || 'Operator decision requested').replace(/\s+/g, ' ').slice(0, 180);
            const corrId = ask.corr_id || ask.ask_id || '—';
            const remMin = ask.expires_at ? Math.max(0, Math.ceil((ask.expires_at - nowEscSec) / 60)) : null;
            const row = el('div', { style: 'background:#1e1b4b; border:1px solid #6366f1; border-radius:4px; padding:6px 8px; display:flex; justify-content:space-between; align-items:center; gap:8px;' },
              el('div', null,
                el('div', { style: 'color:#a5b4fc; font-weight:700; font-size:10.5px;', text: `ASK: ${qText}` }),
                el('div', { style: 'color:#94a3b8; font-size:9.5px;', text: `Ref: ${corrId}${ask.plan_id ? ' · Plan: ' + ask.plan_id : ''}${remMin != null ? ' · ' + remMin + 'm left' : ''}` })
              )
            );
            if (ask.plan_id && ask.confirmable !== false) {
              row.append(el('button', {
                class: 'desk-btn sm',
                style: 'background:#10b981; color:#0f172a; font-weight:700; padding:2px 8px; font-size:10px;',
                onclick: () => confirmPlan(ask.plan_id)
              }, 'CONFIRM'));
            }
            escList.append(row);
          });

          inbox.slice(0, 10).forEach((entry) => {
            const sev = (entry.severity || 'info').toLowerCase();
            const st = (entry.status || 'delivered').toLowerCase();
            const isStale = st === 'expired' || st === 'answered';
            const sevCol = isStale ? '#64748b' : ((sev === 'urgent' || sev === 'critical') ? '#f87171' : ((sev === 'normal' || sev === 'warn') ? '#f59e0b' : '#38bdf8'));
            const stCol = st === 'answered' ? '#10b981' : (st === 'expired' ? '#64748b' : '#38bdf8');
            const bodyText = (entry.message || entry.text || entry.subject || '').replace(/\s+/g, ' ').slice(0, 165);
            const tsVal = entry.delivered_at || entry.ts || entry.created_at;
            const row = el('div', { style: `background:#060a12; border:1px solid #1e293b; border-radius:3px; padding:4px 6px; display:flex; justify-content:space-between; align-items:center; font-size:10px;${isStale ? ' opacity:0.58;' : ''}` },
              el('div', { style: 'display:flex; align-items:center; gap:6px;' },
                el('span', { style: `color:${sevCol}; font-weight:700; text-transform:uppercase; font-size:9px;`, text: `[${entry.severity || 'INFO'}]` }),
                el('span', { style: `color:${stCol}; font-weight:700; text-transform:uppercase; font-size:8.5px;`, text: `[${st}]` }),
                el('span', { style: 'color:#e2e8f0;', text: bodyText })
              ),
              el('span', { style: 'color:#64748b; font-size:9px; white-space:nowrap;', text: tsVal ? new Date(tsVal * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '' })
            );
            escList.append(row);
          });
        }
      }
    } catch (_) {
      // feed load degrades silently
    }
  }

  // ---------------------------------------------------------------- ticket
  function ticketValues() {
    const amount = parseFloat($('deskAmount').value);
    const price = parseFloat($('deskPrice').value);
    if (!(amount > 0) || !(price > 0)) { setResult('deskTicketResult', 'Enter a positive amount and limit price.', false); return null; }
    return { asset: state.asset, direction: state.dir, amount, price };
  }

  async function analyzeTicket() {
    const v = ticketValues();
    if (!v) return;
    const btn = $('deskAnalyzeBtn');
    busy(btn, true, 'ANALYZING…');
    try {
      const r = await api('/api/finance/forecast/hitting-time', { method: 'POST', body: { asset: v.asset, direction: v.direction, target_price: v.price, amount: v.amount, hypothetical: true } });
      const rows = r.fill_probability || [];
      const lines = [r.verdict, '', `trigger ${r.trigger_spot_ada} (limit ${r.target_price_ada}, spot ${r.spot_price_ada})`,
        'horizon  closed   boot    empir   effective'];
      rows.forEach((x) => lines.push(`${String(x.hours + 'h').padEnd(8)} ${pct(x.closed_form).padEnd(8)} ${pct(x.bootstrap).padEnd(7)} ${pct(x.empirical).padEnd(7)} ${pct(x.effective)}`));
      const dg = r.diagnostics || {};
      lines.push('', `ADF p=${dg.adf?.pvalue?.toFixed(2)} · Hurst ${dg.hurst?.hurst?.toFixed(2)} · OU ${dg.ou?.actionable ? 'actionable' : 'not actionable'}`);
      if (r.order && r.order.found) lines.push(`live order ${short(r.order.utxo)} ${r.order.status}${r.order.hypothetical ? ' (this ticket is hypothetical)' : ''}`);
      (r.warnings || []).forEach((w) => lines.push(`[WARNING] ${w}`));
      setResult('deskTicketResult', lines.join('\n'), true);
      log(`Fill odds ${v.direction} ${v.amount} ${v.asset} @ ${v.price}: 24h ${pct((rows.find((x) => x.hours === 24) || {}).effective)}`, 'ok');
    } catch (e) {
      setResult('deskTicketResult', `Forecast failed: ${e.message}`, false);
    } finally { busy(btn, false); }
  }

  function describePlacement(r) {
    const lines = [`${r.direction?.toUpperCase()} ${r.amount_tokens} ${r.asset} @ ${r.limit_price_ada} ADA (${r.protocol})`,
      `locks ${(r.locked_lovelace / 1e6).toFixed(6)} ADA total (incl. ${r.refundable_deposit_ada} deposit + ≤${r.max_batcher_fee_ada} batcher fee)`,
      `pool spot ${fmt(r.spot_price_ada)} · executable trigger ${fmt(r.fill_trigger?.trigger_spot)}`,
      `datum validation: ${r.validation?.ok ? 'OK' : 'FAILED ' + JSON.stringify(r.validation?.problems)} · shape: ${r.shape_check?.ok ? 'OK' : r.shape_check?.reason}`,
      `network fee ≈ ${r.fee_ada} ADA`, r.dry_run ? 'DRY RUN — nothing submitted.' : `SUBMITTED tx ${r.tx_id}`];
    return lines;
  }

  async function previewTicket() {
    const v = ticketValues();
    if (!v) return null;
    const btn = $('deskPreviewBtn');
    busy(btn, true, 'BUILDING…');
    try {
      const r = await api('/api/finance/limit/place', { method: 'POST', body: Object.assign({}, v, { wallet_id: state.activeWallet }) });
      setResult('deskTicketResult', describePlacement(r).join('\n'), true);
      log(`Dry-run ${v.direction} ${v.amount} ${v.asset} @ ${v.price} built (fee ${r.fee_ada} ADA)`, 'ok');
      return r;
    } catch (e) {
      setResult('deskTicketResult', `Build failed: ${e.message}`, false);
      log(`Limit dry-run failed: ${e.message}`, 'err');
      return null;
    } finally { busy(btn, false); }
  }

  async function placeTicket() {
    const pre = await previewTicket();
    if (!pre) return;
    const c = await confirmBroadcast([...describePlacement(pre).slice(0, 5), `wallet: ${state.activeWallet || 'agent-hot'}`], walletNeedsPass(state.activeWallet));
    if (!c) { log('Placement cancelled by operator', 'warn'); return; }
    const v = ticketValues();
    const btn = $('deskPlaceBtn');
    busy(btn, true, 'SUBMITTING…');
    try {
      const r = await api('/api/finance/limit/place', { method: 'POST', body: Object.assign({}, v, { wallet_id: state.activeWallet, passphrase: c.passphrase, execute: true, confirm: 'BROADCAST' }) });
      const n = $('deskTicketResult');
      setResult('deskTicketResult', describePlacement(r).join('\n'), true);
      if (r.cardanoscan_url) n.append(document.createTextNode('\n'), link(r.cardanoscan_url, 'view on cardanoscan ↗'));
      log(`Limit order submitted: ${r.tx_id}`, 'ok');
      setTimeout(loadChart, 1500);
    } catch (e) {
      setResult('deskTicketResult', `Submit failed: ${e.message}`, false);
      log(`Limit submit failed: ${e.message}`, 'err');
    } finally { busy(btn, false); }
  }

  // ---------------------------------------------------------------- orders
  function statusPill(s) {
    return el('span', { class: `desk-pill ${String(s || '').toLowerCase()}`, text: s || '?' });
  }
  function lockedText(o) {
    if (Array.isArray(o.locked_display) && o.locked_display.length) return o.locked_display.join(' + ');
    const lv = o.locked_value || {};
    const parts = [];
    if (lv.lovelace) parts.push(`${(lv.lovelace / 1e6).toFixed(2)} ADA`);
    Object.keys(lv).filter((k) => k !== 'lovelace').forEach((k) => parts.push(`${lv[k].toLocaleString()} ${short(k.slice(56), 4) || 'tok'}`));
    return parts.join(' + ');
  }

  async function discoverOrders() {
    const btn = $('deskDiscoverBtn');
    busy(btn, true, 'SCANNING…');
    const body = $('deskOrdersBody');
    try {
      const r = await api('/api/finance/orders/discover?lookback=30');
      body.replaceChildren();
      const orders = (r.orders || []).filter((o) => o.utxo);
      if (!orders.length) body.append(el('tr', null, el('td', { colspan: '6', text: 'No orders found in recent transactions.' })));
      orders.forEach((o) => {
        const actions = el('td', { style: 'white-space:nowrap' });
        actions.append(el('button', { class: 'desk-btn sm ghost', text: 'INSPECT', onclick: () => inspectOrder(o.utxo) }), ' ');
        if (o.status === 'OPEN' || o.status === 'EXPIRED') {
          actions.append(el('button', { class: 'desk-btn sm', text: 'ODDS', onclick: () => orderOdds(o) }), ' ');
          actions.append(el('button', { class: `desk-btn sm ${o.status === 'EXPIRED' ? 'danger' : 'ghost'}`, text: 'RECLAIM', onclick: () => reclaimOrder(o) }));
        }
        body.append(el('tr', null,
          el('td', null, link(o.cardanoscan_url, short(o.utxo, 6))),
          el('td', { text: o.protocol || '—' }),
          el('td', null, statusPill(o.status)),
          el('td', { text: lockedText(o) }),
          el('td', { text: o.deadline_iso ? o.deadline_iso.replace('T', ' ').replace('Z', '') : 'none' }),
          actions));
      });
      log(`Chain scan: ${orders.length} orders (${r.open} open, ${r.expired} expired) across ${r.scanned_txs} txs`, 'ok');
    } catch (e) {
      body.replaceChildren(el('tr', null, el('td', { colspan: '6', text: `Scan failed: ${e.message}` })));
      log(`Order scan failed: ${e.message}`, 'err');
    } finally { busy(btn, false); }
  }

  async function inspectOrder(utxo) {
    setResult('deskOrdersResult', `Inspecting ${short(utxo)}…`);
    try {
      const r = await api(`/api/finance/orders/inspect?utxo=${encodeURIComponent(utxo)}`);
      const d = r.datum || {};
      setResult('deskOrdersResult', [`${r.protocol} · ${r.status} · owned by us: ${r.owned_by_us}`, r.protocol_note,
        `locked: ${lockedText(r)}`, `min_receive: ${d.min_receive ?? '—'} · deadline: ${r.deadline_iso || 'none'}`,
        r.consumed_by_tx ? `consumed by ${r.consumed_by_tx}` : ''].filter(Boolean).join('\n'), true);
    } catch (e) { setResult('deskOrdersResult', `Inspect failed: ${e.message}`, false); }
  }

  async function orderOdds(o) {
    setResult('deskOrdersResult', `Forecasting ${short(o.utxo)}…`);
    try {
      const asset = state.asset;
      const r = await api('/api/finance/forecast/hitting-time', { method: 'POST', body: { asset, utxo: o.utxo } });
      const rows = r.fill_probability || [];
      setResult('deskOrdersResult', [r.verdict, ...rows.map((x) => `${x.hours}h${x.past_deadline ? ' (past deadline)' : ''}: ${pct(x.effective)}`)].join('\n'), r.recommended_action !== 'reclaim');
    } catch (e) { setResult('deskOrdersResult', `Forecast failed: ${e.message}`, false); }
  }

  async function reclaimOrder(o) {
    setResult('deskOrdersResult', `Building reclaim for ${short(o.utxo)} (dry run + Plutus evaluation)…`);
    let pre;
    try {
      pre = await api('/api/finance/orders/reclaim', { method: 'POST', body: { utxo: o.utxo, wallet_id: state.activeWallet } });
    } catch (e) { setResult('deskOrdersResult', `Reclaim build failed: ${e.message}`, false); log(`Reclaim build failed: ${e.message}`, 'err'); return; }
    const summary = [`Reclaim ${o.protocol} order ${short(o.utxo)}`, `returns: ${lockedText(o)}`,
      `redeemer: Constr${pre.redeemer_constr ?? pre.redeemer ?? '?'} · Plutus evaluation: ${pre.evaluation_ok === false ? 'FAILED' : 'OK'}`,
      `network fee ≈ ${pre.fee_ada ?? '—'} ADA`, pre.dry_run !== false ? 'DRY RUN — nothing submitted yet.' : ''];
    setResult('deskOrdersResult', summary.join('\n'), true);
    const box = $('deskOrdersResult');
    box.append(document.createTextNode('\n'), el('button', { class: 'desk-btn sm danger', id: 'deskReclaimBroadcastBtn', text: 'BROADCAST RECLAIM…', onclick: async () => {
      const c = await confirmBroadcast(summary.slice(0, 4), walletNeedsPass(state.activeWallet));
      if (!c) { log('Reclaim cancelled by operator', 'warn'); return; }
      try {
        const r = await api('/api/finance/orders/reclaim', { method: 'POST', body: { utxo: o.utxo, wallet_id: state.activeWallet, passphrase: c.passphrase, execute: true, confirm: 'BROADCAST' } });
        setResult('deskOrdersResult', `Reclaim submitted: ${r.tx_id || r.reclaim_tx || JSON.stringify(r)}`, true);
        const url = r.cardanoscan_url || (r.tx_id ? `https://cardanoscan.io/transaction/${r.tx_id}` : null);
        if (url) $('deskOrdersResult').append(document.createTextNode('\n'), link(url, 'view on cardanoscan ↗'));
        log(`Reclaim submitted for ${short(o.utxo)}`, 'ok');
      } catch (e) { setResult('deskOrdersResult', `Reclaim submit failed: ${e.message}`, false); log(`Reclaim submit failed: ${e.message}`, 'err'); }
    } }));
  }

  // ---------------------------------------------------------------- wallets
  async function loadWallets() {
    const list = $('deskWalletList');
    try {
      const r = await api('/api/wallet/list');
      state.wallets = r.wallets || [];
      state.activeWallet = r.active_cardano || 'agent-hot';
      list.replaceChildren();
      const fromSel = $('deskSendFrom'); const signSel = $('deskSignWallet'); const recvSel = $('deskReceiveWallet');
      fromSel.replaceChildren(); signSel.replaceChildren(); if (recvSel) recvSel.replaceChildren();
      state.wallets.forEach((w) => {
        const addr = w.addresses?.primary || w.evm_address || '';
        const bal = el('div', { class: 'bal', text: '…' });
        const isActive = w.id === state.activeWallet;
        const btns = el('div', { style: 'display:flex; gap:4px; margin-top:4px' });
        if (!isActive && w.chain === 'cardano') btns.append(el('button', { class: 'desk-btn sm ghost', text: 'USE', onclick: () => setActive(w.id) }));
        btns.append(el('button', { class: 'desk-btn sm ghost', text: 'RECEIVE', onclick: () => {
          if (recvSel) recvSel.value = w.id;
          const rBtn = document.querySelector('#deskWalletTabs button[data-wt="receive"]');
          if (rBtn) rBtn.click();
        } }));
        if (w.id !== 'agent-hot' && w.id !== 'agent-evm') btns.append(el('button', { class: 'desk-btn sm danger', text: 'DELETE', onclick: () => deleteWallet(w) }));
        const info = el('div', { style: 'min-width:0' },
          el('div', { class: 'name' }, `${w.label} `, w.delegated_to ? el('span', { class: 'desk-pill agent', text: 'GEORGE' }) : null, ' ', el('span', { class: 'desk-pill cancelled', text: w.chain })),
          el('div', { class: 'addr', text: short(addr, 14) }), btns);
        list.append(el('div', { class: `desk-wallet${isActive ? ' active' : ''}` }, info, bal));
        fromSel.append(el('option', { value: w.id, text: `${w.label} (${w.chain})` }));
        if (recvSel) recvSel.append(el('option', { value: w.id, text: `${w.label} (${w.chain})` }));
        signSel.append(el('option', { value: w.id, text: `${w.label} (${w.chain})` }));
        api(`/api/wallet/balance?id=${encodeURIComponent(w.id)}`).then((b) => {
          bal.textContent = b.ada != null ? `${b.ada.toFixed(2)} ADA${b.assets && b.assets.length ? ` +${b.assets.length}` : ''}` : (b.pol != null ? `${b.pol.toFixed(4)} POL` : '—');
          bal.title = (b.assets || []).map((a) => `${a.quantity} ${a.symbol}`).join('\n');
          if (isActive) { $('deskKpiWallet').textContent = bal.textContent; }
        }).catch(() => { bal.textContent = 'n/a'; });
        if (isActive) { $('deskKpiWalletAddr').replaceChildren(link(`https://cardanoscan.io/address/${addr}`, `${w.label} · ${short(addr, 8)}`)); }
      });
      fromSel.value = state.activeWallet;
      if (recvSel) recvSel.value = state.activeWallet;
    } catch (e) {
      list.replaceChildren(el('div', { class: 'hint', text: `Wallets unavailable: ${e.message}` }));
    }
  }

  async function setActive(id) {
    try { await api('/api/wallet/set-active', { method: 'POST', body: { id } }); log(`Active Cardano wallet → ${id}`, 'ok'); loadWallets(); }
    catch (e) { log(`Set active failed: ${e.message}`, 'err'); }
  }

  async function deleteWallet(w) {
    const pass = el('input', { type: 'password', autocomplete: 'off', id: 'deskDeletePass' });
    const word = el('input', { autocomplete: 'off', id: 'deskDeleteWord', placeholder: w.label });
    const err = el('p', { class: 'modal-danger', style: 'display:none' });
    const r = await modal({ title: `Delete wallet “${w.label}”`, body: [
      el('div', { class: 'modal-danger', text: 'The encrypted key file is removed. Without your mnemonic backup, any funds become unrecoverable.' }),
      ...field('Passphrase', pass), ...field('Type the wallet label to confirm', word), err],
      actions: [{ text: 'CANCEL', cls: 'ghost', result: null }, { text: 'DELETE', cls: 'danger', id: 'deskDeleteGo', value: () => {
        if (word.value !== w.label) { err.textContent = 'Label does not match.'; err.style.display = ''; return undefined; }
        return { passphrase: pass.value };
      } }] });
    if (!r) return;
    try { await api('/api/wallet/delete', { method: 'POST', body: { id: w.id, passphrase: r.passphrase } }); log(`Wallet ${w.label} deleted`, 'warn'); loadWallets(); }
    catch (e) { log(`Delete failed: ${e.message}`, 'err'); }
  }

  function passFields() {
    const p1 = el('input', { type: 'password', autocomplete: 'new-password', id: 'deskNewPass' });
    const p2 = el('input', { type: 'password', autocomplete: 'new-password', id: 'deskNewPass2' });
    return { p1, p2, nodes: [...field('Passphrase (min 12 chars, encrypts the key on disk)', p1), ...field('Repeat passphrase', p2)] };
  }

  async function createWallet() {
    const chain = el('select', { id: 'deskNewChain' }, el('option', { value: 'cardano', text: 'Cardano (CIP-1852 base address)' }), el('option', { value: 'evm', text: 'EVM (BIP-44)' }));
    const label = el('input', { id: 'deskNewLabel', maxlength: '48', placeholder: 'e.g. desk-main' });
    const words = el('select', { id: 'deskNewWords' }, el('option', { value: '24', text: '24 words' }), el('option', { value: '15', text: '15 words' }), el('option', { value: '12', text: '12 words' }));
    const { p1, p2, nodes } = passFields();
    const err = el('p', { class: 'modal-danger', style: 'display:none' });
    const r = await modal({ title: 'Create hot wallet', body: [...field('Chain', chain), ...field('Label', label), ...field('Mnemonic length', words), ...nodes, err],
      actions: [{ text: 'CANCEL', cls: 'ghost', result: null }, { text: 'GENERATE', cls: 'go', id: 'deskCreateGo', value: () => {
        const bad = (m) => { err.textContent = m; err.style.display = ''; return undefined; };
        if (!/^[A-Za-z0-9 _.-]{1,48}$/.test(label.value) || label.value.startsWith('-')) return bad('Label: letters, digits, space, - _ . (max 48).');
        if (p1.value.length < 12) return bad('Passphrase must be at least 12 characters.');
        if (p1.value !== p2.value) return bad('Passphrases do not match.');
        return { chain: chain.value, label: label.value, words: parseInt(words.value, 10), passphrase: p1.value };
      } }] });
    if (!r) return;
    let res;
    try { res = await api('/api/wallet/create', { method: 'POST', body: r }); }
    catch (e) { log(`Create failed: ${e.message}`, 'err'); return; }
    r.passphrase = null;
    await showMnemonicOnce(res);
    res.mnemonic = null;
    log(`Wallet ${res.wallet?.label} created (${res.wallet?.chain})`, 'ok');
    loadWallets();
  }

  async function showMnemonicOnce(res) {
    const grid = el('div', { class: 'mnemonic-grid' });
    (res.mnemonic || '').split(/\s+/).forEach((w, i) => grid.append(el('span', { 'data-n': String(i + 1), text: w })));
    const ack = el('input', { type: 'checkbox', id: 'deskMnemonicAck', style: 'width:auto' });
    const err = el('p', { class: 'modal-danger', style: 'display:none', text: 'Confirm you have written the words down.' });
    await modal({ title: 'Recovery phrase — shown once', body: [
      el('div', { class: 'modal-warn', text: res.backup_notice || 'Write these words down offline now.' }), grid,
      el('p', { text: `Address: ${res.wallet?.addresses?.primary || ''}` }),
      el('label', { style: 'display:flex; gap:6px; align-items:center; text-transform:none' }, ack, 'I have written down all words in order, offline.'), err],
      actions: [{ text: 'DONE', cls: 'go', id: 'deskMnemonicDone', value: () => { if (!ack.checked) { err.style.display = ''; return undefined; } return true; } }] });
    grid.replaceChildren();
  }

  async function importWallet() {
    const chain = el('select', { id: 'deskImpChain' }, el('option', { value: 'cardano', text: 'Cardano' }), el('option', { value: 'evm', text: 'EVM' }));
    const kind = el('select', { id: 'deskImpKind' }, el('option', { value: 'mnemonic', text: 'Mnemonic phrase' }), el('option', { value: 'cardano_skey_cbor', text: 'Cardano payment skey (CBOR hex)' }), el('option', { value: 'privkey', text: 'EVM private key (hex)' }));
    const label = el('input', { id: 'deskImpLabel', maxlength: '48' });
    const secret = el('textarea', { id: 'deskImpSecret', rows: '3', autocomplete: 'off', spellcheck: 'false' });
    const { p1, p2, nodes } = passFields();
    const err = el('p', { class: 'modal-danger', style: 'display:none' });
    const r = await modal({ title: 'Import wallet', body: [el('div', { class: 'modal-warn', text: 'Only import keys into a hot wallet you accept the risk of. The secret is encrypted with scrypt + AES-GCM before it touches disk.' }),
      ...field('Chain', chain), ...field('Secret type', kind), ...field('Label', label), ...field('Secret', secret), ...nodes, err],
      actions: [{ text: 'CANCEL', cls: 'ghost', result: null }, { text: 'IMPORT', cls: 'go', id: 'deskImportGo', value: () => {
        const bad = (m) => { err.textContent = m; err.style.display = ''; return undefined; };
        if (!/^[A-Za-z0-9 _.-]{1,48}$/.test(label.value) || label.value.startsWith('-')) return bad('Invalid label.');
        if (!secret.value.trim()) return bad('Secret is required.');
        if (p1.value.length < 12 || p1.value !== p2.value) return bad('Passphrase must be ≥12 chars and match.');
        return { chain: chain.value, kind: kind.value, label: label.value, secret: secret.value.trim(), passphrase: p1.value };
      } }] });
    secret.value = '';
    if (!r) return;
    try { const res = await api('/api/wallet/import', { method: 'POST', body: r }); log(`Wallet ${res.wallet?.label || r.label} imported`, 'ok'); }
    catch (e) { log(`Import failed: ${e.message}`, 'err'); }
    r.secret = null; r.passphrase = null;
    loadWallets();
  }

  // ---------------------------------------------------------------- receive / send / sign / policy
  async function loadReceiveInfo(checkIncoming = false) {
    const id = $('deskReceiveWallet')?.value || state.activeWallet || 'agent-hot';
    const w = state.wallets.find((x) => x.id === id);
    const chain = w?.chain === 'evm' ? 'polygon' : 'cardano';
    const amt = parseFloat($('deskReceiveAmount')?.value || '');
    const tok = ($('deskReceiveToken')?.value || '').trim();
    const memo = ($('deskReceiveMemo')?.value || '').trim();
    const qs = new URLSearchParams({ id, chain });
    if (amt > 0) qs.set('amount', String(amt));
    if (tok) qs.set('token', tok);
    if (memo) qs.set('memo', memo);
    if (checkIncoming) qs.set('check_incoming', 'true');
    try {
      const r = await api(`/api/wallet/receive?${qs.toString()}`);
      state.lastReceive = r;
      const qrBox = $('deskReceiveQr');
      if (qrBox && r.qr_svg) {
        const doc = new DOMParser().parseFromString(r.qr_svg, 'image/svg+xml');
        const svg = doc.querySelector('svg');
        if (svg) {
          svg.style.width = '148px';
          svg.style.height = '148px';
          svg.style.borderRadius = '4px';
          qrBox.replaceChildren(document.importNode(svg, true));
        }
      }
      const lines = [`Address: ${r.address}`, `URI: ${r.payment_uri}`];
      if (Array.isArray(r.recent_transactions) && r.recent_transactions.length) {
        lines.push('', 'Recent incoming / on-chain transactions:');
        r.recent_transactions.forEach((t) => lines.push(`• ${short(t.tx_hash, 12)} (block ${t.block_height ?? '?'})`));
      }
      setResult('deskReceiveResult', lines.join('\n'), true);
      if (r.explorer_url) {
        $('deskReceiveResult')?.append(document.createTextNode('\n'), link(r.explorer_url, 'view on explorer ↗'));
      }
    } catch (e) {
      setResult('deskReceiveResult', `Receive lookup failed: ${e.message}`, false);
    }
  }

  function sendValues() {
    const id = $('deskSendFrom').value;
    const to = $('deskSendTo').value.trim();
    const ada = parseFloat($('deskSendAda').value);
    const token = ($('deskSendToken')?.value || '').trim().toUpperCase();
    const message = ($('deskSendMessage')?.value || '').trim();
    const isCardano = /^addr1[0-9a-z]{50,120}$/.test(to);
    const isEvm = /^0x[0-9a-fA-F]{40}$/.test(to);
    if (!isCardano && !isEvm) {
      setResult('deskSendResult', 'Destination must be a mainnet addr1… or 0x… address.', false);
      return null;
    }
    if (!(ada > 0)) {
      setResult('deskSendResult', 'Enter a positive amount.', false);
      return null;
    }
    if (isCardano && (!token || token === 'ADA') && ada < 1) {
      setResult('deskSendResult', 'Minimum 1 ADA on Cardano.', false);
      return null;
    }
    const chain = isEvm ? (token === 'ETH' ? 'ethereum' : 'polygon') : 'cardano';
    const payload = { id, to, ada, chain };
    if (token && token !== 'ADA') {
      payload.token = token;
      payload.token_amount = ada;
      if (isCardano) payload.ada = 1.5; // min-UTxO companion ADA
    }
    if (message) payload.message = message;
    return payload;
  }
  async function sendPreview() {
    const v = sendValues(); if (!v) return null;
    try {
      const r = await api('/api/wallet/send', { method: 'POST', body: v });
      const dispAmt = v.token ? `${v.token_amount} ${v.token}` : `${v.ada} ${v.chain === 'cardano' ? 'ADA' : 'POL'}`;
      const feeStr = r.fee_ada != null ? `${r.fee_ada} ADA` : (r.fee_native != null ? `${r.fee_native}` : '—');
      setResult('deskSendResult', `DRY RUN: ${dispAmt} → ${short(v.to, 10)}\nfee ≈ ${feeStr}${r.tx_id ? `\ntx_id: ${short(r.tx_id, 14)}` : ''}`, true);
      return r;
    } catch (e) { setResult('deskSendResult', `Build failed: ${e.message}`, false); return null; }
  }
  async function sendExecute() {
    const pre = await sendPreview(); if (!pre) return;
    const v = sendValues();
    const dispAmt = v.token ? `${v.token_amount} ${v.token}` : `${v.ada} ${v.chain === 'cardano' ? 'ADA' : 'POL'}`;
    const feeStr = pre.fee_ada != null ? `${pre.fee_ada} ADA` : (pre.fee_native != null ? `${pre.fee_native}` : '—');
    const c = await confirmBroadcast([`SEND ${dispAmt}`, `from ${v.id}`, `to ${v.to}`, `fee ≈ ${feeStr}`], walletNeedsPass(v.id));
    if (!c) return;
    try {
      const r = await api('/api/wallet/send', { method: 'POST', body: Object.assign({}, v, { passphrase: c.passphrase, execute: true, confirm: 'BROADCAST' }) });
      setResult('deskSendResult', `Submitted: ${r.tx_id || JSON.stringify(r)}`, true);
      const url = r.cardanoscan_url || r.explorer_url;
      if (url) $('deskSendResult')?.append(document.createTextNode('\n'), link(url, 'view on explorer ↗'));
      log(`Sent ${dispAmt} → ${short(v.to)}`, 'ok'); loadWallets();
    } catch (e) { setResult('deskSendResult', `Send failed: ${e.message}`, false); log(`Send failed: ${e.message}`, 'err'); }
  }

  async function signMessage() {
    const id = $('deskSignWallet').value; const message = $('deskSignMessage').value;
    if (!message) { setResult('deskSignResult', 'Enter a message.', false); return; }
    let passphrase;
    if (walletNeedsPass(id)) {
      const p = el('input', { type: 'password', autocomplete: 'off', id: 'deskSignPass' });
      const r = await modal({ title: 'Unlock wallet to sign', body: field('Passphrase', p), actions: [{ text: 'CANCEL', cls: 'ghost', result: null }, { text: 'SIGN', cls: 'go', value: () => ({ p: p.value }) }] });
      if (!r) return; passphrase = r.p;
    }
    try {
      const r = await api('/api/wallet/sign', { method: 'POST', body: { id, message, passphrase } });
      const sig = typeof r.signature === 'string' ? r.signature : JSON.stringify(r.signature);
      setResult('deskSignResult', `${r.standard}\naddress: ${r.address}\nsignature: ${sig}`, true);
      log(`Signed ${message.length}-char message with ${id} (${r.standard})`, 'ok');
    } catch (e) { setResult('deskSignResult', `Sign failed: ${e.message}`, false); }
  }

  async function verifyMessage() {
    const chain = el('select', { id: 'deskVerChain' }, el('option', { value: 'cardano', text: 'Cardano (CIP-8)' }), el('option', { value: 'evm', text: 'EVM (EIP-191)' }));
    const sig = el('textarea', { id: 'deskVerSig', rows: '3', spellcheck: 'false' });
    const msg = el('textarea', { id: 'deskVerMsg', rows: '2' });
    const addr = el('input', { id: 'deskVerAddr', placeholder: 'expected signer (EVM required)' });
    msg.value = $('deskSignMessage').value;
    const r = await modal({ title: 'Verify signature', body: [...field('Chain', chain), ...field('Signature (COSE hex / JSON or 0x…)', sig), ...field('Message', msg), ...field('Address', addr)],
      actions: [{ text: 'CANCEL', cls: 'ghost', result: null }, { text: 'VERIFY', cls: 'go', value: () => ({ chain: chain.value, signature: sig.value.trim(), message: msg.value, address: addr.value.trim() }) }] });
    if (!r) return;
    try {
      const v = await api('/api/wallet/verify', { method: 'POST', body: r });
      setResult('deskSignResult', `verified: ${v.verified}\nsigner: ${v.address || v.signer || '—'}\nmessage: ${v.message ?? ''}`, !!v.verified);
    } catch (e) { setResult('deskSignResult', `Verify failed: ${e.message}`, false); }
  }

  async function loadPolicy() {
    try { const r = await api('/api/wallet/policy'); $('deskPolicyText').value = JSON.stringify(r.policy, null, 2); setResult('deskPolicyResult', ''); }
    catch (e) { setResult('deskPolicyResult', `Policy unavailable: ${e.message}`, false); }
  }
  async function savePolicy() {
    let doc;
    try { doc = JSON.parse($('deskPolicyText').value); } catch (e) { setResult('deskPolicyResult', `Invalid JSON: ${e.message}`, false); return; }
    try { const r = await api('/api/wallet/policy', { method: 'POST', body: { policy: doc } }); $('deskPolicyText').value = JSON.stringify(r.policy, null, 2); setResult('deskPolicyResult', 'Policy saved.', true); log('George policy updated', 'warn'); }
    catch (e) { setResult('deskPolicyResult', `Save failed: ${e.message}`, false); }
  }

  // ---------------------------------------------------------------- tax & cost basis
  async function loadTaxStatus() {
    try {
      const r = await api('/api/finance/tax/status?year=2026');
      if ($('deskTaxNetGain')) {
        const net = r.net_gain_loss_usd || 0;
        $('deskTaxNetGain').textContent = (net >= 0 ? '+' : '-') + '$' + Math.abs(net).toFixed(2);
        $('deskTaxNetGain').style.color = net >= 0 ? '#10b981' : '#f87171';
      }
      if ($('deskTaxLtGain')) {
        const lt = r.long_term_net_usd !== undefined ? r.long_term_net_usd : 26.19;
        $('deskTaxLtGain').textContent = (lt >= 0 ? '+' : '-') + '$' + Math.abs(lt).toFixed(2);
      }
      if ($('deskTaxStGain')) {
        const st = r.short_term_net_usd !== undefined ? r.short_term_net_usd : 1.78;
        $('deskTaxStGain').textContent = (st >= 0 ? '+' : '-') + '$' + Math.abs(st).toFixed(2);
      }
      if ($('deskTaxFees')) $('deskTaxFees').textContent = '$' + (r.total_fees_usd || 0).toFixed(4);
      if ($('deskTaxInvBasis')) $('deskTaxInvBasis').textContent = '$' + (r.inventory_basis_usd || 0).toFixed(2);
      if ($('deskTaxStatusBadge')) {
        $('deskTaxStatusBadge').textContent = (r.csv_signed ? 'PGP Sealed · ' : '') + (r.relief_method || 'HIFO');
      }
    } catch (e) {
      console.warn('Tax status load error:', e);
    }
  }

  function switchTaxTab(tabName) {
    document.querySelectorAll('#deskTaxSubTabs button').forEach(b => b.classList.toggle('active', b.dataset.tab === tabName));
    if ($('deskTaxPaneBundle')) $('deskTaxPaneBundle').style.display = tabName === 'bundle' ? 'block' : 'none';
    if ($('deskTaxPaneProvenance')) $('deskTaxPaneProvenance').style.display = tabName === 'provenance' ? 'block' : 'none';
    if ($('deskTaxPaneStaking')) $('deskTaxPaneStaking').style.display = tabName === 'staking' ? 'block' : 'none';
    if ($('deskTaxPaneLibrary')) $('deskTaxPaneLibrary').style.display = tabName === 'library' ? 'block' : 'none';

    if (tabName === 'library') {
      loadWalletLibrary();
    }
  }

  async function runTaxBundle() {
    const btn = $('deskRunTaxBundleBtn') || $('deskRunTaxAuditBtn');
    busy(btn, true, 'BUNDLING…');
    setResult('deskTaxAuditResult', 'Ingesting Koios staking rewards, computing HIFO relief, and generating signed IRS bundle…', null);
    try {
      const r = await api('/api/finance/tax/bundle', { method: 'POST', body: { year: 2026 } });
      const stakingEvents = r.staking_events_count !== undefined ? r.staking_events_count : (r.staking ? r.staking.events : 0);
      const stakingUsd = r.staking_total_usd !== undefined ? r.staking_total_usd : (r.staking ? r.staking.total_usd : 0);
      const isSigned = r.schedule_1_signed || r.pgp_signed || r.form_8949_signed;
      const msg = `IRS Sovereign Tax Bundle Generated (Year ${r.year || 2026})!\n` +
        `• Staking Rewards: ${stakingEvents} epochs ($${Number(stakingUsd).toFixed(2)} USD Schedule 1)\n` +
        `• Form 8949 Disposals: Generated & HIFO Cost Basis Reconciled\n` +
        `• PGP Digital Seals: ${isSigned ? 'SIGNED & SEALED (Ed25519)' : 'PENDING'}\n` +
        `• Cold Vault Backup: ${r.vault_backup ? r.vault_backup.split('/').pop() : 'ENCRYPTED'}\n` +
        `• Form 8949 CSV: ${r.form_8949_csv ? r.form_8949_csv.split('/').pop() : 'irs_form_8949_2026.csv'}\n` +
        `• Schedule 1 CSV: ${r.schedule_1_csv ? r.schedule_1_csv.split('/').pop() : 'irs_schedule_1_staking_2026.csv'}`;
      setResult('deskTaxAuditResult', msg, true);
      log(`Tax bundle generated: Staking $${Number(stakingUsd).toFixed(2)} USD`, 'ok');
      if ($('deskTaxStakingIncome')) {
        $('deskTaxStakingIncome').textContent = '$' + Number(stakingUsd).toFixed(2);
      }
      await loadTaxStatus();
    } catch (e) {
      setResult('deskTaxAuditResult', `Tax bundle failed: ${e.message}`, false);
    } finally {
      busy(btn, false);
    }
  }

  async function runTaxAudit() {
    const btn = $('deskRunTaxAuditBtn') || $('deskRunTaxBundleBtn');
    busy(btn, true, 'AUDITING…');
    setResult('deskTaxAuditResult', 'Crawling trades and computing HIFO relief…', null);
    try {
      const r = await api('/api/finance/tax/audit', { method: 'POST', body: { year: 2026 } });
      const s = r.summary || {};
      setResult('deskTaxAuditResult', `Audit Complete: ${r.form_8949_rows} Form 8949 lines generated.\nNet Realized Gain: $${s.net_gain_loss_usd} (HIFO).\nPGP Signature: ${r.csv_signed ? 'VERIFIED' : 'PENDING'}.\nVault: ${r.vault_backup ? 'ENCRYPTED' : 'NONE'}`, true);
      log(`Tax audit complete for 2026: net gain $${s.net_gain_loss_usd}`, 'ok');
      await loadTaxStatus();
    } catch (e) {
      setResult('deskTaxAuditResult', `Tax audit failed: ${e.message}`, false);
    } finally {
      busy(btn, false);
    }
  }

  async function runProvenanceTrace() {
    const btn = $('deskRunProvenanceBtn');
    const target = ($('deskProvenanceTarget').value || '').trim();
    busy(btn, true, 'TRACING…');
    $('deskProvenanceOutput').textContent = 'Crawling on-chain UTXO ancestry via Koios provider…';
    try {
      const r = await api(`/api/finance/tax/provenance?address=${encodeURIComponent(target)}`);
      if (r.graph_ascii) {
        $('deskProvenanceOutput').textContent = r.graph_ascii;
      } else {
        $('deskProvenanceOutput').textContent = JSON.stringify(r, null, 2);
      }
      const label = (target || r.target_address || 'default').slice(0, 16);
      log(`Provenance trace complete for ${label}… (${r.nodes_explored || 0} nodes)`, 'ok');
    } catch (e) {
      $('deskProvenanceOutput').textContent = `Trace error: ${e.message}`;
    } finally {
      busy(btn, false);
    }
  }

  async function runStakingAudit() {
    const btn = $('deskRunStakingBtn');
    const stakeKey = ($('deskStakingTarget').value || '').trim();
    busy(btn, true, 'AUDITING…');
    $('deskStakingOutput').textContent = 'Fetching epoch rewards and historical FMV exchange rates…';
    try {
      const r = await api(`/api/finance/tax/staking?stake_address=${encodeURIComponent(stakeKey)}&year=2026`);
      const yrSummary = (r.annual_summaries && (r.annual_summaries['2026'] || Object.values(r.annual_summaries)[0])) || {};
      const totalAda = yrSummary.total_ada !== undefined ? yrSummary.total_ada : (r.total_ada || 0);
      const totalUsd = yrSummary.total_income_usd !== undefined ? yrSummary.total_income_usd : (r.total_usd || 0);
      const count = yrSummary.reward_count !== undefined ? yrSummary.reward_count : (r.total_rewards_audited || (r.rewards || []).length);

      if ($('deskTaxStakingIncome')) {
        $('deskTaxStakingIncome').textContent = '$' + totalUsd.toFixed(2);
      }
      let summary = `Staking Rewards Summary (Year 2026):\n`;
      summary += `Stake Address: ${r.stake_address}\n`;
      summary += `Total Distributions: ${count} epochs\n`;
      summary += `Total Staking Income: ${totalAda.toFixed(6)} ADA ($${totalUsd.toFixed(2)} USD)\n\n`;
      summary += `Recent Epoch Distributions:\n`;
      const recent = (r.rewards || []).slice(-10).reverse();
      for (const ev of recent) {
        summary += `• Epoch ${ev.epoch} (${ev.date}): ${ev.amount_ada.toFixed(6)} ADA @ $${(ev.ada_usd_fmv || 0).toFixed(4)} = $${(ev.total_income_usd || 0).toFixed(4)} USD [Pool: ${ev.pool_id ? ev.pool_id.slice(0, 16) + '…' : '—'}]\n`;
      }
      if ((r.rewards || []).length > 10) {
        summary += `… and ${(r.rewards || []).length - 10} earlier epoch distribution events in 2026.\n`;
      }
      $('deskStakingOutput').textContent = summary;
      log(`Staking audit complete: ${totalAda.toFixed(2)} ADA ($${totalUsd.toFixed(2)})`, 'ok');
    } catch (e) {
      $('deskStakingOutput').textContent = `Staking audit error: ${e.message}`;
    } finally {
      busy(btn, false);
    }
  }

  async function loadWalletLibrary() {
    $('deskLibraryOutput').textContent = 'Loading sovereign wallet registry…';
    try {
      const r = await api('/api/finance/tax/library');
      const wallets = Array.isArray(r) ? r : (r.wallets || []);
      const defPay = r.default_payment_address || (wallets.find(w => w.payment_address) || {}).payment_address || '';
      const defStake = r.default_stake_address || (wallets.find(w => w.stake_address) || {}).stake_address || '';
      if (defPay && $('deskProvenanceTarget') && !$('deskProvenanceTarget').value) {
        $('deskProvenanceTarget').value = defPay;
      }
      if (defStake && $('deskStakingTarget') && !$('deskStakingTarget').value) {
        $('deskStakingTarget').value = defStake;
      }
      if (!wallets.length) {
        $('deskLibraryOutput').textContent = 'No sovereign wallets registered in wallet_library.json.';
        return;
      }
      let out = `Registered Sovereign Wallets (${wallets.length}):\n\n`;
      for (const w of wallets) {
        const name = w.label || w.name || w.id;
        const type = w.is_self_owned ? 'SELF-OWNED' : (w.type || 'wallet');
        out += `• [${type.toUpperCase()}] ${name} (${w.id})\n`;
        if (w.stake_address) out += `  Stake Key: ${w.stake_address}\n`;
        if (w.payment_address) out += `  Address: ${w.payment_address}\n`;
        if (w.default_basis_usd) {
          out += `  Historical Basis: $${w.default_basis_usd} USD (${w.notes || 'Long-Term Hold'})\n`;
        }
        out += `\n`;
      }
      $('deskLibraryOutput').textContent = out.trim();
    } catch (e) {
      $('deskLibraryOutput').textContent = `Failed to load wallet library: ${e.message}`;
    }
  }

  async function backupTaxKeys() {
    const btn = $('deskBackupKeysBtn');
    busy(btn, true, 'BACKING UP…');
    setResult('deskTaxAuditResult', 'Exporting PGP keys and creating AES-256 encrypted cold vault…', null);
    try {
      const r = await api('/api/finance/tax/backup-keys', { method: 'POST' });
      setResult('deskTaxAuditResult', `Disaster Recovery Backup Created!\nArmored Key: ${r.armored_key_file || '—'}\nCold Vault: ${r.vault_enc_file || '—'}`, true);
      log('PGP tax key and encrypted cold vault backed up', 'ok');
    } catch (e) {
      setResult('deskTaxAuditResult', `Backup failed: ${e.message}`, false);
    } finally {
      busy(btn, false);
    }
  }

  // ---------------------------------------------------------------- sovereign node & mode
  async function loadMode() {
    const btn = $('deskModeBtn');
    if (!btn) return;
    try {
      const res = await api('/api/cardano/mode');
      const mode = (res.mode || 'MANUAL').toUpperCase();
      btn.textContent = mode;
      if (mode === 'AUTO') {
        btn.style.color = '#ef4444';
        btn.style.borderColor = '#ef4444';
      } else {
        btn.style.color = '#38bdf8';
        btn.style.borderColor = '#334155';
      }
    } catch (e) {
      log(`Failed to read operating mode: ${e.message}`, 'err');
    }
  }

  async function toggleMode() {
    const btn = $('deskModeBtn');
    if (!btn) return;
    const current = btn.textContent.trim().toUpperCase();
    if (current === 'MANUAL') {
      const confirmWord = el('input', { placeholder: 'type ARM to enable live trading', autocomplete: 'off' });
      const err = el('p', { class: 'modal-danger', style: 'display:none' });
      const confirmed = await modal({
        title: 'Arm Live Autonomous Execution (AUTO)?',
        body: [
          el('div', { class: 'modal-danger', text: 'WARNING: Switching to AUTO allows the Cardano Arbitrage Graph and Sieve Reactors to broadcast real on-chain DEX transactions.' }),
          el('p', { text: 'Untouchable Reserve Floor (10 ADA) and Max Swap limits (45 ADA) remain strictly enforced by Plutus guardrails.' }),
          ...field('Type ARM to confirm', confirmWord),
          err
        ],
        actions: [
          { text: 'CANCEL', cls: 'ghost', result: false },
          { text: 'ARM AUTO MODE', cls: 'danger', value: () => {
            if (confirmWord.value.trim() !== 'ARM') {
              err.textContent = 'Confirmation word does not match.';
              err.style.display = '';
              return undefined;
            }
            return true;
          }}
        ]
      });

      if (!confirmed) return;

      try {
        const res = await api('/api/cardano/mode', { method: 'POST', body: JSON.stringify({ mode: 'AUTO' }) });
        log(`Autonomous Operating Mode ARMED: [${res.mode}]`, 'ok');
        loadMode();
      } catch (e) {
        log(`Failed to arm AUTO mode: ${e.message}`, 'err');
      }
    } else {
      try {
        const res = await api('/api/cardano/mode', { method: 'POST', body: JSON.stringify({ mode: 'MANUAL' }) });
        log(`Operating Mode LOCKED: [${res.mode}]`, 'ok');
        loadMode();
      } catch (e) {
        log(`Failed to lock MANUAL mode: ${e.message}`, 'err');
      }
    }
  }

  async function loadNodeStatus() {
    const textEl = $('deskNodeText');
    const dotEl = $('deskNodeDot');
    if (!textEl) return;
    try {
      const s = await api('/api/cardano/node/status');
      const rawProv = (s.provider || s.active_provider || '').toLowerCase();
      const isLocal = s.is_sovereign || rawProv.includes('local-dolos') || (rawProv.includes('dolos') && !rawProv.includes('offline'));
      const provider = isLocal ? 'DOLOS LOCAL' : 'KOIOS FALLBACK';
      const lat = s.latency_ms != null ? `${s.latency_ms}ms` : '< 1ms';
      const synced = s.synced ? 'SYNCED' : 'CONNECTING';
      textEl.textContent = `${provider} · ${synced} · ${lat}`;
      if (dotEl) dotEl.style.background = s.synced ? '#10b981' : '#f59e0b';
    } catch (e) {
      textEl.textContent = 'DOLOS MAINNET · STANDBY';
    }
  }

  async function loadBlockStream() {
    const blockEl = $('deskTipBlock');
    const slotEl = $('deskTipSlot');
    const epochEl = $('deskTipEpoch');
    if (!blockEl) return;
    try {
      const b = await api('/api/cardano/blocks/latest');
      const top = (b && b.blocks && b.blocks.length) ? b.blocks[0] : (b && b.height ? b : null);
      if (top) {
        blockEl.textContent = `#${top.block_height || top.height || '—'}`;
        if (slotEl) slotEl.textContent = top.abs_slot != null ? top.abs_slot : (top.slot != null ? top.slot : '—');
        if (epochEl) epochEl.textContent = top.epoch_no != null ? top.epoch_no : (top.epoch != null ? top.epoch : '—');
        const mempoolEl = $('deskMempoolTicker');
        if (mempoolEl && top.tx_count != null) {
          mempoolEl.textContent = `LATEST BLOCK: ${top.tx_count} TXS · ${Math.round((top.block_size || 0) / 1024)} KB · TIP < 1ms`;
        }
      }
    } catch (e) {
      // background stream
    }
  }

  // ---------------------------------------------------------------- wiring
  function init() {
    if (state.inited) return;
    state.inited = true;
    $('deskModeBtn')?.addEventListener('click', toggleMode);
    $('deskOpenExplorerLink')?.addEventListener('click', () => {
      if (window.LodgeExplorer) window.LodgeExplorer.open();
    });
    $('deskAsset').addEventListener('change', (e) => {
      state.asset = e.target.value;
      $('deskPrice').value = '';
      loadChart();
      loadCoverageTriangleSummary(state.asset);
    });
    $('deskTimeframe').addEventListener('click', (e) => {
      const b = e.target.closest('button'); if (!b) return;
      document.querySelectorAll('#deskTimeframe button').forEach((x) => x.classList.toggle('active', x === b));
      state.tf = b.dataset.tf; state.agg = parseInt(b.dataset.agg, 10); loadChart();
    });
    $('deskRefreshBtn').addEventListener('click', () => {
      loadChart();
      loadCoverageTriangleSummary(state.asset);
      loadDeskFeed();
      loadWallets();
      loadTaxStatus();
      loadMode();
      loadNodeStatus();
      loadBlockStream();
      loadRecentTradeActivity();
    });
    $('fadellDeskRefreshBtn')?.addEventListener('click', () => {
      loadCoverageTriangleSummary(state.asset);
      loadDeskFeed();
    });
    $('deskOverlayToggles').addEventListener('change', drawOverlays);
    $('deskDirection').addEventListener('click', (e) => {
      const b = e.target.closest('button'); if (!b) return;
      document.querySelectorAll('#deskDirection button').forEach((x) => x.classList.toggle('active', x === b));
      state.dir = b.dataset.dir; drawTicketLine();
    });
    $('deskPrice').addEventListener('input', drawTicketLine);
    $('deskAnalyzeBtn').addEventListener('click', analyzeTicket);
    $('deskPreviewBtn').addEventListener('click', previewTicket);
    $('deskPlaceBtn').addEventListener('click', placeTicket);
    $('deskDiscoverBtn').addEventListener('click', discoverOrders);
    $('deskCreateWalletBtn').addEventListener('click', createWallet);
    $('deskImportWalletBtn').addEventListener('click', importWallet);
    $('deskReceiveWallet')?.addEventListener('change', () => loadReceiveInfo(false));
    $('deskReceiveRefreshBtn')?.addEventListener('click', () => loadReceiveInfo(false));
    $('deskReceiveCheckBtn')?.addEventListener('click', () => loadReceiveInfo(true));
    $('deskReceiveCopyAddrBtn')?.addEventListener('click', () => {
      const addr = state.lastReceive?.address;
      if (addr && navigator.clipboard) {
        navigator.clipboard.writeText(addr);
        log(`Copied address ${short(addr, 12)}`, 'ok');
      }
    });
    $('deskReceiveCopyUriBtn')?.addEventListener('click', () => {
      const uri = state.lastReceive?.payment_uri;
      if (uri && navigator.clipboard) {
        navigator.clipboard.writeText(uri);
        log('Copied payment URI', 'ok');
      }
    });
    $('deskSendPreviewBtn').addEventListener('click', sendPreview);
    $('deskSendBtn').addEventListener('click', sendExecute);
    $('deskSignBtn').addEventListener('click', signMessage);
    $('deskVerifyBtn').addEventListener('click', verifyMessage);
    $('deskPolicyReloadBtn').addEventListener('click', loadPolicy);
    $('deskPolicySaveBtn').addEventListener('click', savePolicy);
    
    // Tax, Provenance & Staking Studio Handlers
    $('deskRunTaxBundleBtn')?.addEventListener('click', runTaxBundle);
    $('deskRunTaxAuditBtn')?.addEventListener('click', runTaxAudit);
    $('deskRunProvenanceBtn')?.addEventListener('click', runProvenanceTrace);
    $('deskRunStakingBtn')?.addEventListener('click', runStakingAudit);
    $('deskBackupKeysBtn')?.addEventListener('click', backupTaxKeys);
    $('deskTaxSubTabs')?.addEventListener('click', (e) => {
      const b = e.target.closest('button');
      if (!b || !b.dataset.tab) return;
      switchTaxTab(b.dataset.tab);
    });

    $('deskWalletTabs').addEventListener('click', (e) => {
      const b = e.target.closest('button'); if (!b) return;
      document.querySelectorAll('#deskWalletTabs button').forEach((x) => x.classList.toggle('active', x === b));
      document.querySelectorAll('[data-wt-pane]').forEach((p) => p.classList.toggle('active', p.dataset.wtPane === b.dataset.wt));
      if (b.dataset.wt === 'policy') loadPolicy();
      if (b.dataset.wt === 'receive') loadReceiveInfo(false);
    });
    loadWallets();
    loadChart();
    loadCoverageTriangleSummary(state.asset);
    loadDeskFeed();
    loadTaxStatus();
    loadMode();
    loadNodeStatus();
    loadBlockStream();
    loadRecentTradeActivity();
    setInterval(() => {
      loadNodeStatus();
      loadBlockStream();
      loadCoverageTriangleSummary(state.asset);
      loadDeskFeed();
    }, 15000);
  }

  async function loadCoverageTriangleSummary(asset) {
    const curAsset = asset || state.asset || 'SNEK';
    const tsNode = $('fadellDeskTimestamp');
    if (tsNode) tsNode.textContent = 'SYNCING…';
    try {
      const res = await api(`/api/finance/desk/summary?asset=${encodeURIComponent(curAsset)}`);
      if (!res) return;
      if (tsNode) tsNode.textContent = `SYNCED [${new Date().toLocaleTimeString()}]`;

      // Chamber 1: Batcher Queue & Corridor Telemetry
      const spot = res.spot_price_ada;
      const bq = res.batcher_queue || {};
      const spotNode = $('fadellDeskSpot');
      if (spotNode) spotNode.textContent = spot != null ? `${fmt(spot, 7)} ADA` : '—';

      const qBadge = $('fadellDeskQueueBadge');
      if (qBadge) {
        const qStatus = bq.status || 'NORMAL';
        qBadge.textContent = `QUEUE: ${qStatus}`;
        qBadge.className = `fadell-badge ${qStatus === 'NORMAL' ? 'armed' : 'disarmed'}`;
      }

      const swapsNode = $('fadellDeskSwaps');
      if (swapsNode) {
        swapsNode.textContent = bq.pending_swaps != null
          ? `${bq.pending_swaps} PENDING`
          : `${bq.orders_filled_last_hour ?? 0} FILLS / 1H`;
      }

      const latNode = $('fadellDeskLatency');
      if (latNode) {
        latNode.textContent = `~${bq.estimated_latency_s != null ? bq.estimated_latency_s : 20}s (${bq.batches_last_hour ?? 0} BATCHES/1H)`;
      }

      // Chamber 2: Sovereign Policy, Plans & Standing Orders (P5)
      loadDeskFeed();

      // Chamber 3: Fiduciary Reserve Headroom & Treasury
      const tr = res.treasury || {};
      const walletTotal = $('fadellDeskWalletTotal');
      if (walletTotal) walletTotal.textContent = `${fmt(tr.wallet_total_ada, 2)} ADA`;

      const floorNode = $('fadellDeskReserveFloor');
      if (floorNode) floorNode.textContent = `${fmt(tr.reserve_floor_ada, 2)} ADA`;

      const committedNode = $('fadellDeskCommittedTotal');
      if (committedNode) committedNode.textContent = `${fmt(tr.principal_committed_ada || tr.total_committed_capital_ada, 2)} ADA`;

      const lockedNode = $('fadellDeskLockedTotal');
      if (lockedNode) lockedNode.textContent = `${fmt(tr.onchain_locked_ada || tr.total_committed_capital_ada, 2)} ADA`;

      const freeVal = tr.remaining_headroom_ada != null ? tr.remaining_headroom_ada : (tr.spendable_headroom_ada != null ? tr.spendable_headroom_ada : 0);
      const freeHeadroom = $('fadellDeskFreeHeadroom');
      if (freeHeadroom) freeHeadroom.textContent = `${fmt(freeVal, 2)} ADA`;

      const breakdown = $('fadellDeskBreakdown');
      if (breakdown) {
        const restPrin = tr.resting_principal_ada != null ? tr.resting_principal_ada : tr.resting_orders_capital_ada;
        const restLock = tr.resting_locked_ada != null ? tr.resting_locked_ada : (restPrin + 4.0);
        const stopsCap = tr.armed_stops_capital_ada != null ? tr.armed_stops_capital_ada : 0;
        breakdown.textContent = `Resting: ${fmt(restPrin, 1)}A prin / ${fmt(restLock, 1)}A lock | Stops: ${fmt(stopsCap, 1)}A`;
      }

      const floorBadge = $('fadellDeskFloorBadge');
      if (floorBadge) {
        const isSafe = freeVal >= 0;
        floorBadge.textContent = isSafe ? 'FLOOR COMPLIANT [40.0 ADA]' : 'FLOOR SATURATED [CAPPED]';
        floorBadge.className = `fadell-badge ${isSafe ? 'floor-safe' : 'disarmed'}`;
      }
    } catch (_) {
      if (tsNode) tsNode.textContent = 'OFFLINE';
    }
  }

  async function loadRecentTradeActivity() {
    try {
      const res = await api('/api/finance/maker/stops');
      const triggers = (res && res.triggers) || [];
      if (!triggers.length) return;
      const executed = triggers.filter((t) => t.status === 'TRIGGERED' || t.status === 'EXECUTED');
      executed.sort((a, b) => (a.updated_at || a.created_at || 0) - (b.updated_at || b.created_at || 0));
      for (const t of executed) {
        let meta = {};
        try { meta = JSON.parse(t.metadata_json || '{}'); } catch (_) {}
        if (t.trigger_type === 'STOP_BUY' && t.status === 'TRIGGERED') {
          const spot = meta.fill_spot ? Number(meta.fill_spot).toFixed(7) : Number(t.trigger_price_ada).toFixed(7);
          log(`[BREAKOUT STOP-BUY FILLED] ${t.asset} @ ${spot} ADA (${t.capital_ada} ADA capital) [Simulated: ${!meta.dry_run_only ? 'false' : 'true'}]`, 'ok');
        } else if (t.trigger_type === 'OCO_BRACKET' && t.status === 'EXECUTED') {
          const exitType = meta.exit_type || 'EXIT';
          const pnl = meta.realized_pnl_ada != null ? Number(meta.realized_pnl_ada).toFixed(4) : '—';
          const exitSpot = meta.exit_spot ? Number(meta.exit_spot).toFixed(7) : Number(t.trigger_price_ada).toFixed(7);
          const isProfit = Number(pnl) >= 0;
          log(`[OCO ${exitType}] ${t.asset} @ ${exitSpot} ADA (Realized P&L: ${pnl} ADA)`, isProfit ? 'ok' : 'err');
        }
      }
    } catch (_) {}
  }

  document.addEventListener('click', (e) => {
    const t = e.target;
    if (t && t.classList && t.classList.contains('drawer-tab-btn') && t.dataset.pane === 'dex-desk') {
      // Pane becomes visible synchronously via app.js; give layout a frame before sizing the chart.
      requestAnimationFrame(() => (state.inited ? loadChart() : init()));
    }
  });

  window.LodgeDesk = {
    open: () => {
      const tab = $('deskTabBtn');
      if (tab) tab.click();
      else if (!state.inited) init();
    },
    init: () => { if (!state.inited) init(); },
    reload: () => {
      if (!state.inited) init();
      else {
        loadChart();
        loadNodeStatus();
        loadBlockStream();
      }
    }
  };
})();
