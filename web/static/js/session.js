// ============================================================================
// GEORGE // Session token bootstrap + remote device pairing
// Fund-moving (/api/finance POST) and key-handling (/api/wallet/*) routes need
// an X-Lodge-Token. GET /api/session/token returns:
//   * the master token to the browser on localhost (kind: "local"), or
//   * a per-device request token to a paired remote browser (kind: "device"),
//     identified by its HttpOnly device cookie (JS never sees the cookie).
// Tokens are kept in memory only (never localStorage). An unpaired remote browser
// is asked once for a pairing code (or the full token) and then stays paired
// until revoked. See docs/REMOTE_ACCESS_SECURITY.md.
// ============================================================================
(function () {
  'use strict';

  const nativeFetch = window.fetch.bind(window);
  let token = null;
  let kind = null;      // 'local' | 'device' | null
  let device = null;    // { id, label } for paired devices
  let resolveToken;
  const tokenReady = new Promise((r) => { resolveToken = r; });

  function needsToken(url, method) {
    let path;
    try { path = new URL(url, window.location.origin).pathname; } catch (_) { return false; }
    if (path.startsWith('/api/wallet/')) return true;
    if (path.startsWith('/api/finance/')) return method !== 'GET' && method !== 'HEAD';
    if (path === '/api/hub/accounts') return true;
    if (path.startsWith('/api/hub/')) return method !== 'GET' && method !== 'HEAD';
    if (path.startsWith('/api/models/') || path.startsWith('/api/model/') || path === '/api/system/gamemode' ||
        path.startsWith('/api/training/')) {
      return method !== 'GET' && method !== 'HEAD';
    }
    return false;
  }

  function el(tag, opts, children) {
    const n = document.createElement(tag);
    if (opts) {
      if (opts.id) n.id = opts.id;
      if (opts.className) n.className = opts.className;
      if (opts.text != null) n.textContent = opts.text;
      if (opts.type) n.type = opts.type;
      if (opts.placeholder) n.placeholder = opts.placeholder;
      if (opts.attrs) Object.entries(opts.attrs).forEach(([k, v]) => n.setAttribute(k, v));
    }
    (children || []).forEach((c) => n.append(c));
    return n;
  }

  function modal(id, title) {
    const old = document.getElementById(id);
    if (old) old.remove();
    const overlay = el('div', { id, className: 'lodge-modal-overlay' });
    const box = el('div', { className: 'lodge-modal lodge-session-modal' });
    box.append(el('h3', { text: title }));
    overlay.append(box);
    document.body.append(overlay);
    return { overlay, box };
  }

  function guessLabel() {
    const ua = navigator.userAgent || '';
    if (/iPhone/.test(ua)) return 'iPhone';
    if (/iPad/.test(ua)) return 'iPad';
    if (/Android/.test(ua)) return 'Android';
    if (/Mac OS X/.test(ua)) return 'Mac';
    if (/Windows/.test(ua)) return 'Windows';
    return 'Browser';
  }

  async function postJson(url, body, withToken) {
    const headers = { 'Content-Type': 'application/json' };
    if (withToken && token) headers['X-Lodge-Token'] = token;
    const r = await nativeFetch(url, { method: 'POST', headers, body: JSON.stringify(body || {}), cache: 'no-store' });
    let j = {};
    try { j = await r.json(); } catch (_) { /* non-JSON */ }
    return { ok: r.ok, status: r.status, body: j };
  }

  function adopt(j) {
    token = j.token || null;
    kind = j.kind || null;
    device = j.device || null;
    resolveToken(token);
    showDevicesButton();
  }

  // ── Remote browser: pair once ──────────────────────────────────────────────
  function showPairModal() {
    const { overlay, box } = modal('lodgeTokenModal', 'Pair this device');
    box.append(el('p', { text: 'This browser is not on the George host. On the desktop, open DEVICES (top bar) and press GENERATE CODE, then type the 8-character code here. You can also paste the full 64-character token from .george/web_token.' }));
    box.append(el('p', { className: 'modal-warn', text: 'Once paired, this browser stays authorised until you revoke it from the desktop DEVICES panel. Only pair devices you control.' }));
    const credLabel = el('label', { text: 'Pairing code or token', attrs: { for: 'lodgeTokenInput' } });
    const input = el('input', { id: 'lodgeTokenInput', type: 'text', placeholder: 'ABCD-EFGH', attrs: { autocomplete: 'off', autocapitalize: 'characters', spellcheck: 'false', maxlength: '80' } });
    const nameLabel = el('label', { text: 'Device name', attrs: { for: 'lodgeDeviceLabel' } });
    const name = el('input', { id: 'lodgeDeviceLabel', type: 'text', attrs: { maxlength: '40', autocomplete: 'off' } });
    name.value = guessLabel();
    const err = el('p', { id: 'lodgePairError', className: 'modal-danger lodge-hidden' });
    const skip = el('button', { id: 'lodgeTokenSkip', className: 'btn-secondary', text: 'Read-only' });
    const ok = el('button', { id: 'lodgeTokenSubmit', className: 'btn-primary', text: 'Pair' });
    box.append(credLabel, input, nameLabel, name, err, el('div', { className: 'modal-actions lodge-modal-actions' }, [skip, ok]));

    const showErr = (msg) => { err.textContent = msg; err.classList.remove('lodge-hidden'); input.classList.add('invalid'); };
    const submit = async () => {
      const cred = input.value.trim();
      if (!/^[0-9a-fA-F]{32,}$/.test(cred) && !/^[A-Za-z0-9\s-]{8,11}$/.test(cred)) {
        showErr('Enter the 8-character code (e.g. ABCD-EFGH) or the 64-character token.');
        return;
      }
      ok.disabled = true;
      try {
        const res = await postJson('/api/session/pair', { credential: cred, label: name.value.trim() }, false);
        if (res.ok && res.body.token) {
          overlay.remove();
          adopt(res.body);
        } else {
          showErr(res.body.message || ('Pairing failed (HTTP ' + res.status + ').'));
        }
      } catch (_) {
        showErr('Network error while pairing.');
      } finally {
        ok.disabled = false;
      }
    };
    ok.addEventListener('click', submit);
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter') submit(); });
    skip.addEventListener('click', () => { overlay.remove(); resolveToken(null); });
    input.focus();
  }

  // ── Desktop: manage paired devices ─────────────────────────────────────────
  function fmtTime(ts) {
    if (!ts) return '—';
    try { return new Date(ts * 1000).toLocaleString(); } catch (_) { return String(ts); }
  }

  async function openDevicesPanel() {
    const { overlay, box } = modal('lodgeDevicesModal', kind === 'local' ? 'Remote devices' : 'This device');
    const close = el('button', { id: 'lodgeDevicesClose', className: 'btn-secondary', text: 'Close' });
    close.addEventListener('click', () => overlay.remove());

    if (kind === 'device') {
      box.append(el('p', { text: 'Paired as "' + (device && device.label || 'device') + '" (id ' + (device && device.id || '?') + '). This browser stays authorised until revoked.' }));
      const forget = el('button', { id: 'lodgeForgetDevice', className: 'btn-primary', text: 'Forget this device' });
      let armed = false;
      forget.addEventListener('click', async () => {
        if (!armed) { armed = true; forget.textContent = 'Click again to confirm'; return; }
        await postJson('/api/session/forget', {}, true);
        token = null;
        window.location.reload();
      });
      box.append(el('div', { className: 'modal-actions' }, [close, forget]));
      return;
    }

    box.append(el('p', { text: 'Pair a phone or laptop on your tailnet: generate a code here, then type it on the other device within 10 minutes. Codes are single-use.' }));
    const codeOut = el('div', { id: 'lodgePairCode', className: 'lodge-pair-code lodge-hidden' });
    const gen = el('button', { id: 'lodgeGenCode', className: 'btn-primary', text: 'Generate code' });
    let timer = null;
    gen.addEventListener('click', async () => {
      const res = await postJson('/api/session/pair-code', {}, true);
      codeOut.classList.remove('lodge-hidden');
      if (!res.ok) { codeOut.textContent = res.body.message || 'Could not create a code.'; return; }
      const c = String(res.body.code || '');
      let left = Number(res.body.expires_in) || 600;
      const big = el('span', { className: 'code', text: c.slice(0, 4) + '-' + c.slice(4) });
      const ttl = el('span', { className: 'ttl' });
      codeOut.replaceChildren(big, ttl);
      if (timer) clearInterval(timer);
      const tick = () => {
        if (!document.body.contains(codeOut)) { clearInterval(timer); return; }
        ttl.textContent = left > 0 ? 'expires in ' + Math.floor(left / 60) + 'm ' + String(left % 60).padStart(2, '0') + 's' : 'expired';
        if (left <= 0) { clearInterval(timer); big.classList.add('expired'); }
        left -= 1;
      };
      tick();
      timer = setInterval(tick, 1000);
    });
    box.append(el('div', { className: 'modal-actions lodge-left' }, [gen]), codeOut);

    const list = el('div', { id: 'lodgeDeviceList', className: 'lodge-device-list' });
    box.append(el('label', { text: 'Paired devices' }), list);

    const render = async () => {
      list.replaceChildren(el('p', { text: 'Loading…' }));
      let j = {};
      try {
        const r = await nativeFetch('/api/session/devices', { headers: { 'X-Lodge-Token': token || '' }, cache: 'no-store' });
        j = await r.json();
      } catch (_) { /* ignore */ }
      const devs = Array.isArray(j.devices) ? j.devices : [];
      if (!devs.length) { list.replaceChildren(el('p', { text: 'No paired devices.' })); return; }
      const rows = devs.map((d) => {
        const btn = el('button', { className: 'btn-secondary lodge-revoke', text: 'Revoke' });
        let armed = false;
        btn.addEventListener('click', async () => {
          if (!armed) { armed = true; btn.textContent = 'Confirm'; return; }
          await postJson('/api/session/devices/revoke', { id: String(d.id) }, true);
          render();
        });
        return el('div', { className: 'lodge-device-row' }, [
          el('div', { className: 'name', text: String(d.label) + ' · ' + String(d.id) }),
          el('div', { className: 'meta', text: 'paired ' + fmtTime(d.created_at) + ' via ' + String(d.via) + ' · last seen ' + fmtTime(d.last_seen_at) + ' from ' + String(d.last_ip) }),
          btn,
        ]);
      });
      list.replaceChildren(...rows);
    };

    const revokeAll = el('button', { id: 'lodgeRevokeAll', className: 'btn-secondary', text: 'Revoke all' });
    let armedAll = false;
    revokeAll.addEventListener('click', async () => {
      if (!armedAll) { armedAll = true; revokeAll.textContent = 'Confirm revoke all'; return; }
      await postJson('/api/session/devices/revoke', { all: true }, true);
      armedAll = false; revokeAll.textContent = 'Revoke all';
      render();
    });
    box.append(el('div', { className: 'modal-actions' }, [revokeAll, close]));
    render();
  }

  function showDevicesButton() {
    if (!kind || document.getElementById('lodgeDevicesBtn')) return;
    const anchor = document.getElementById('toolCribToggle');
    if (!anchor || !anchor.parentNode) return;
    const b = el('button', { id: 'lodgeDevicesBtn', className: 'tactile-btn header-workbench-btn lodge-devices-btn', text: kind === 'local' ? 'DEVICES' : 'PAIRED', attrs: { title: kind === 'local' ? 'Pair and revoke remote devices' : 'This device is paired' } });
    b.addEventListener('click', openDevicesPanel);
    anchor.parentNode.insertBefore(b, anchor);
  }

  async function bootstrap() {
    try {
      const r = await nativeFetch('/api/session/token', { cache: 'no-store' });
      if (r.ok) {
        const j = await r.json();
        const ready = () => adopt(j);
        if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', ready, { once: true });
        else ready();
        return;
      }
    } catch (_) { /* fall through */ }
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', showPairModal, { once: true });
    } else {
      showPairModal();
    }
  }

  window.fetch = async function (input, init) {
    const url = typeof input === 'string' ? input : (input && input.url) || '';
    const method = ((init && init.method) || (input && input.method) || 'GET').toUpperCase();
    if (needsToken(url, method)) {
      const t = token || await tokenReady;
      if (t) {
        const headers = new Headers((init && init.headers) || (input instanceof Request ? input.headers : undefined));
        headers.set('X-Lodge-Token', t);
        init = Object.assign({}, init || {}, { headers });
      }
    }
    return nativeFetch(input, init);
  };

  window.LodgeSession = {
    hasToken: () => !!token,
    kind: () => kind,
    ready: () => tokenReady,
    openDevices: openDevicesPanel,
  };

  bootstrap();
})();
