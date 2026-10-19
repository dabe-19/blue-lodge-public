// ============================================================================
// GEORGE // Dolos Sovereign Block Explorer & L1 Crawler
// Real-time block stream, local node status, transaction and UTxO inspection.
//
// Security rules for this file:
//  * No innerHTML / alert / confirm. All DOM is built with createElement/textContent.
//  * External links use rel="noopener noreferrer" and allow-listed explorers.
//  * Clean text descriptors only, no sloppy emojis or superfluous badges.
// ============================================================================
(function () {
  'use strict';

  const $ = (id) => document.getElementById(id);
  const state = {
    inited: false,
    timer: null,
    loading: false,
  };

  const SAFE_LINK = /^https:\/\/(cardanoscan\.io|cexplorer\.io)\//;

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
    for (const c of children) {
      if (c != null) n.append(c.nodeType ? c : document.createTextNode(String(c)));
    }
    return n;
  }

  function link(url, text) {
    if (!url || !SAFE_LINK.test(url)) return document.createTextNode(text);
    return el('a', { href: url, target: '_blank', rel: 'noopener noreferrer', text, style: 'color:#38bdf8; text-decoration:none;' });
  }

  const short = (s, n = 8) => (s && s.length > 2 * n + 1 ? `${s.slice(0, n)}…${s.slice(-n)}` : s || '');
  const fmt = (v) => (v == null || !isFinite(v) ? '—' : Number(v).toLocaleString());

  async function api(path, opts) {
    const o = Object.assign({ headers: {} }, opts || {});
    if (o.body && typeof o.body !== 'string') {
      o.body = JSON.stringify(o.body);
      o.headers['Content-Type'] = 'application/json';
    }
    const r = await fetch(path, o);
    let j;
    try { j = await r.json(); } catch (_) { j = { status: 'error', message: `HTTP ${r.status}` }; }
    if (!r.ok || j.status === 'error') {
      const e = new Error(j.message || `HTTP ${r.status}`);
      e.payload = j;
      throw e;
    }
    return j;
  }

  async function loadNodeStatus() {
    const badgeText = $('explorerNodeText');
    const badgeDot = $('explorerNodeDot');
    const kpiLat = $('expKpiLatency');
    const pill = $('dolosSyncStatusPill');
    const gwBadge = $('dolosGatewayBadge');
    const slotProg = $('dolosSlotProgressText');
    const pctText = $('dolosSyncPercentText');
    const syncBar = $('dolosSyncBar');
    const subtext = $('dolosSyncSubtext');

    try {
      const s = await api('/api/cardano/node/status');
      const d = s.dolos || {};
      const net = s.network_tip || {};
      const router = s.router || {};

      const isSynced = s.synced || d.synced;
      const isOnline = d.online !== false && (s.status === 'ok');
      const lat = s.latency_ms != null ? `${s.latency_ms}ms` : '< 1ms';
      const pct = d.sync_percent != null ? Number(d.sync_percent) : (isSynced ? 100 : 0);

      // Header Badge
      if (badgeText) {
        if (isSynced) {
          badgeText.textContent = `DOLOS MAINNET · SYNCED · ${lat}`;
        } else if (isOnline) {
          badgeText.textContent = `DOLOS SYNCING (${pct.toFixed(2)}%) · KOIOS ROUTED`;
        } else {
          badgeText.textContent = 'DOLOS OFFLINE · KOIOS FALLBACK';
        }
      }
      if (badgeDot) {
        badgeDot.style.background = isSynced ? '#10b981' : (isOnline ? '#f59e0b' : '#ef4444');
      }

      // Sync Status Pill
      if (pill) {
        if (isSynced) {
          pill.style.background = '#064e3b';
          pill.style.color = '#10b981';
          pill.style.border = '1px solid #047857';
          pill.textContent = 'SYNCED (< 20s)';
        } else if (isOnline) {
          pill.style.background = '#451a03';
          pill.style.color = '#f59e0b';
          pill.style.border = '1px solid #78350f';
          pill.textContent = `SYNCING (${pct.toFixed(2)}%)`;
        } else {
          pill.style.background = '#450a0a';
          pill.style.color = '#ef4444';
          pill.style.border = '1px solid #7f1d1d';
          pill.textContent = 'OFFLINE';
        }
      }

      // Router Gateway Badge
      if (gwBadge) {
        gwBadge.textContent = `ROUTER: ${router.active_gateway || (isSynced ? 'DOLOS (LOCAL)' : 'KOIOS (FALLBACK)')}`;
        gwBadge.style.color = isSynced ? '#38bdf8' : '#cbd5e1';
      }

      // Slot Progress & Percentage
      if (slotProg) {
        slotProg.textContent = `Local Slot #${fmt(d.local_slot)} / Network Tip #${fmt(net.slot)} (Lag: ${fmt(d.slot_lag)} slots)`;
      }
      if (pctText) {
        pctText.textContent = `${pct.toFixed(2)}%`;
      }
      if (syncBar) {
        syncBar.style.width = `${Math.max(isSynced ? 100 : 0.8, pct)}%`;
        syncBar.style.background = isSynced
          ? '#10b981'
          : 'linear-gradient(90deg, #f59e0b, #38bdf8)';
      }

      // Subtext
      if (subtext) {
        if (isSynced) {
          subtext.textContent = 'Synchronized with Cardano Mainnet L1 · Zero external dependencies · Sub-millisecond local execution';
          subtext.style.color = '#10b981';
        } else if (isOnline) {
          subtext.textContent = `Catching up: ${fmt(d.block_lag)} blocks remaining (${d.time_lag_human || ''}) · Queries seamlessly protected via Koios until synced`;
          subtext.style.color = '#94a3b8';
        } else {
          subtext.textContent = 'Dolos node daemon offline. Start with: cd deploy/dolos && docker compose up -d';
          subtext.style.color = '#f87171';
        }
      }

      // KPIs
      if ($('expKpiTip')) $('expKpiTip').textContent = `#${fmt(d.local_height || 0)}`;
      if ($('expKpiTipTime')) $('expKpiTipTime').textContent = `Network Tip: #${fmt(net.block_height || 0)}`;
      if ($('expKpiEpochSlot')) $('expKpiEpochSlot').textContent = `E${d.local_epoch || 0} : S${fmt(d.local_slot || 0)}`;
      if ($('expKpiEpochSlotSub')) $('expKpiEpochSlotSub').textContent = `Tip: E${net.epoch || 0} : S${fmt(net.slot || 0)}`;
      if (kpiLat) kpiLat.textContent = lat;
      if ($('expKpiMem')) $('expKpiMem').textContent = d.time_lag_human || '—';
      if ($('expKpiMemSub')) $('expKpiMemSub').textContent = isSynced ? 'At Chain Tip' : `Lag: ${fmt(d.block_lag)} blocks`;

    } catch (e) {
      if (badgeText) badgeText.textContent = 'DOLOS MAINNET · STANDBY';
      if (pill) {
        pill.textContent = 'CHECK FAILED';
        pill.style.color = '#f87171';
      }
    }
  }

  async function loadBlocks() {
    const body = $('explorerBlocksBody');
    if (!body) return;
    try {
      const res = await api('/api/cardano/blocks/latest');
      const blocks = res.blocks || [];
      if (!blocks.length) {
        body.replaceChildren(el('tr', null, el('td', { colspan: '7', style: 'text-align:center; padding:16px;', text: 'No recent blocks received from node.' })));
        return;
      }

      body.replaceChildren();

      // Top block KPIs
      const top = blocks[0];
      if (top) {
        if ($('expKpiTip')) $('expKpiTip').textContent = `#${fmt(top.block_height)}`;
        if ($('expKpiTipTime')) $('expKpiTipTime').textContent = top.block_time ? new Date(top.block_time * 1000).toUTCString() : '—';
        if ($('expKpiEpochSlot')) $('expKpiEpochSlot').textContent = `Epoch ${top.epoch_no || '—'}`;
        if ($('expKpiEpochSlotSub')) $('expKpiEpochSlotSub').textContent = `Slot ${top.abs_slot || '—'} (Epoch slot: ${top.epoch_slot || '—'})`;
      }

      blocks.forEach((b) => {
        const timeStr = b.block_time ? new Date(b.block_time * 1000).toISOString().replace('T', ' ').replace('.000Z', ' UTC') : '—';
        const sizeKb = b.block_size ? `${Math.round(b.block_size / 1024)} KB` : '—';
        const cardanoUrl = b.hash ? `https://cardanoscan.io/block/${b.hash}` : '#';

        const row = el('tr', null,
          el('td', null, el('strong', { style: 'color:#38bdf8;', text: `#${b.block_height}` })),
          el('td', { text: `E${b.epoch_no || '—'} : S${b.abs_slot || '—'}` }),
          el('td', null, el('span', { style: 'color:#10b981; font-weight:700;', text: String(b.tx_count || 0) })),
          el('td', { text: sizeKb }),
          el('td', { style: 'font-size:10px; color:#94a3b8;', text: timeStr }),
          el('td', { style: 'font-size:10px;', text: short(b.pool || '—', 8) }),
          el('td', null, link(cardanoUrl, short(b.hash, 8)))
        );
        body.append(row);
      });

      const statusEl = $('explorerStreamStatus');
      if (statusEl) {
        statusEl.textContent = `LAST TIP: #${blocks[0].block_height} · ${blocks.length} BLOCKS IN BUFFER`;
      }
    } catch (e) {
      body.replaceChildren(el('tr', null, el('td', { colspan: '7', style: 'color:#ef4444; text-align:center; padding:16px;', text: `Failed to load blocks: ${e.message}` })));
    }
  }

  async function searchTransaction() {
    const input = $('explorerSearchInput');
    const resultBox = $('explorerSearchResult');
    const btn = $('explorerSearchBtn');
    if (!input || !resultBox) return;

    const query = input.value.trim();
    if (!query) {
      resultBox.style.display = 'block';
      resultBox.replaceChildren(el('span', { style: 'color:#f59e0b;', text: 'Please enter a transaction hash or block hash to inspect.' }));
      return;
    }

    resultBox.style.display = 'block';
    resultBox.replaceChildren(el('span', { style: 'color:#38bdf8;', text: `Querying local node for: ${query}…` }));
    if (btn) btn.disabled = true;

    try {
      const res = await api(`/api/cardano/tx/${encodeURIComponent(query)}`);
      resultBox.replaceChildren();

      const txCard = el('div', { style: 'display:flex; flex-direction:column; gap:8px;' });
      const headerRow = el('div', { style: 'display:flex; justify-content:space-between; align-items:center; border-bottom:1px solid #1e293b; padding-bottom:6px;' },
        el('strong', { style: 'color:#f8fafc; font-size:12px;', text: `TRANSACTION INSPECT: ${short(res.tx_hash, 12)}` }),
        link(res.cardanoscan_url || `https://cardanoscan.io/transaction/${res.tx_hash}`, 'Cardanoscan ↗')
      );

      const fee = res.fee_ada != null ? `${res.fee_ada} ADA` : (res.fees ? `${res.fees / 1000000} ADA` : '—');
      const metaRow = el('div', { style: 'display:flex; gap:16px; color:#94a3b8; font-size:11px;' },
        el('span', null, 'Block: ', el('strong', { style: 'color:#38bdf8;', text: `#${res.block_height || 'pending'}` })),
        el('span', null, 'L1 Fee: ', el('strong', { style: 'color:#f8fafc;', text: fee })),
        el('span', null, 'Outputs: ', el('strong', { style: 'color:#10b981;', text: String((res.outputs || []).length) })),
        el('span', null, 'Inputs: ', el('strong', { style: 'color:#f59e0b;', text: String((res.inputs || []).length) }))
      );

      // Outputs list
      const outBox = el('div', { style: 'margin-top:6px;' });
      outBox.append(el('div', { style: 'color:#cbd5e1; font-weight:700; margin-bottom:4px;', text: 'OUTPUTS (UTxOs CREATED):' }));
      (res.outputs || []).forEach((out, idx) => {
        const lovelace = (out.amount || []).find((a) => a.unit === 'lovelace');
        const adaAmt = lovelace ? (Number(lovelace.quantity) / 1000000).toFixed(4) : '—';
        const nativeAssets = (out.amount || []).filter((a) => a.unit !== 'lovelace');
        const datum = out.data_hash || out.inline_datum ? ` [DATUM: ${short(out.data_hash || out.inline_datum, 6)}]` : '';

        const item = el('div', { style: 'background:#0a0f1d; padding:4px 8px; border:1px solid #1e293b; border-radius:3px; margin-bottom:4px;' },
          el('div', null,
            el('span', { style: 'color:#38bdf8; font-weight:700;', text: `#${idx} ` }),
            el('span', { style: 'color:#94a3b8;', text: `${short(out.address, 12)} ` }),
            el('strong', { style: 'color:#10b981;', text: `${adaAmt} ADA` }),
            el('span', { style: 'color:#f59e0b; font-size:10px;', text: datum })
          )
        );

        if (nativeAssets.length) {
          const naList = el('div', { style: 'font-size:10px; color:#cbd5e1; margin-top:2px; padding-left:14px;' });
          nativeAssets.forEach((na) => {
            naList.append(el('div', { text: `• ${short(na.unit, 10)}: ${Number(na.quantity).toLocaleString()}` }));
          });
          item.append(naList);
        }
        outBox.append(item);
      });

      txCard.append(headerRow, metaRow, outBox);
      resultBox.append(txCard);
    } catch (e) {
      resultBox.replaceChildren(el('span', { style: 'color:#ef4444;', text: `Inspection failed: ${e.message}` }));
    } finally {
      if (btn) btn.disabled = false;
    }
  }

  function init() {
    if (state.inited) return;
    state.inited = true;

    $('explorerRefreshBtn')?.addEventListener('click', () => {
      loadNodeStatus();
      loadBlocks();
    });

    $('dolosRefreshHealthBtn')?.addEventListener('click', () => {
      loadNodeStatus();
    });

    $('dolosLogsBtn')?.addEventListener('click', async () => {
      const drawer = $('dolosLogsDrawer');
      const btn = $('dolosLogsBtn');
      if (!drawer) return;
      if (drawer.style.display === 'block') {
        drawer.style.display = 'none';
        if (btn) btn.textContent = 'VIEW LOGS';
      } else {
        drawer.style.display = 'block';
        drawer.textContent = 'Streaming latest container logs from lodge-dolos…';
        if (btn) btn.textContent = 'HIDE LOGS';
        try {
          const res = await api('/api/cardano/node/logs');
          // Strip ANSI escape codes for clean text rendering
          const cleanLogs = (res.logs || 'No log output.').replace(/\x1B\[[0-9;]*[a-zA-Z]/g, '');
          drawer.textContent = cleanLogs;
          drawer.scrollTop = drawer.scrollHeight;
        } catch (e) {
          drawer.textContent = `Failed to fetch logs: ${e.message}`;
        }
      }
    });

    $('dolosRestartBtn')?.addEventListener('click', async () => {
      const btn = $('dolosRestartBtn');
      if (!btn || btn.disabled) return;
      btn.disabled = true;
      btn.textContent = 'RESTARTING…';
      try {
        await api('/api/cardano/node/restart', { method: 'POST' });
        setTimeout(() => {
          loadNodeStatus();
          btn.disabled = false;
          btn.textContent = 'RESTART';
        }, 2000);
      } catch (e) {
        btn.textContent = 'RESTART ERROR';
        setTimeout(() => {
          btn.disabled = false;
          btn.textContent = 'RESTART';
        }, 3000);
      }
    });

    $('explorerSearchBtn')?.addEventListener('click', searchTransaction);
    $('explorerSearchInput')?.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') searchTransaction();
    });

    loadNodeStatus();
    loadBlocks();

    // Auto-refresh blocks and node sync every 10s if pane is active
    if (!state.timer) {
      state.timer = setInterval(() => {
        const pane = $('pane-dolos-explorer');
        if (pane && pane.classList.contains('active')) {
          loadNodeStatus();
          loadBlocks();
        }
      }, 10000);
    }
  }

  document.addEventListener('click', (e) => {
    const t = e.target;
    if (t && t.classList && t.classList.contains('drawer-tab-btn') && t.dataset.pane === 'dolos-explorer') {
      requestAnimationFrame(() => {
        if (!state.inited) init();
        else {
          loadNodeStatus();
          loadBlocks();
        }
      });
    }
  });

  window.LodgeExplorer = {
    open: () => $('explorerTabBtn')?.click(),
    reload: () => { loadNodeStatus(); loadBlocks(); },
  };
})();
