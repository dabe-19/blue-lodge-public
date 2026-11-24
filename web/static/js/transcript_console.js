// ============================================================================
// BLUE LODGE // Structured Active Transcript, CoT & Tool Streaming Console
// Coalesces streamed token chunks into continuous semantic cards (Turn, Thought,
// Tool Call, Observation, Prose, System) with strict layout containment and
// configurable pacing. Strictly XSS-safe DOM construction (zero innerHTML).
// ============================================================================
(function () {
  'use strict';

  const ANSI_RE = /\x1b\[[0-9;]*[a-zA-Z]/g;

  function stripAnsi(s) {
    return String(s || '').replace(ANSI_RE, '');
  }

  function el(tag, opts, children) {
    const node = document.createElement(tag);
    if (opts) {
      if (opts.className) node.className = opts.className;
      if (opts.text != null) node.textContent = String(opts.text);
      if (opts.title) node.title = opts.title;
      if (opts.value != null) node.value = String(opts.value);
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

  function getSpeedMode() {
    const saved = localStorage.getItem('george-pacing');
    if (saved === '0' || saved === 'instant') return 'instant';
    if (saved === '30' || saved === 'reading') return 'reading';
    if (saved === '60' || saved === 'smooth') return 'smooth';
    return 'instant';
  }

  function setSpeedMode(mode) {
    const map = { instant: '0', smooth: '60', reading: '30' };
    localStorage.setItem('george-pacing', map[mode] || '0');
    const specSel = document.getElementById('gaugePacingSelect');
    if (specSel && map[mode]) specSel.value = map[mode];
  }

  function prettyTryJson(text) {
    const t = text.trim();
    if ((t.startsWith('{') && t.endsWith('}')) || (t.startsWith('[') && t.endsWith(']'))) {
      try {
        return JSON.stringify(JSON.parse(t), null, 2);
      } catch (_) {}
    }
    return text;
  }

  // Classify a clean line into a semantic block kind using stateful transitions
  function classifySegment(rawLine, st) {
    const clean = stripAnsi(rawLine);
    const t = clean.trim();
    if (!t) return { kind: st.activeKind || 'prose', text: '\n', cont: true };

    // Turn markers
    if (/^(?:──+|───+|#{2,3})\s*Turn\b/i.test(t) || /^Turn\s+\d+\/\d+/.test(t)) {
      st.inThought = false;
      st.inObs = false;
      st.activeKind = null;
      return { kind: 'turn', text: t, cont: false };
    }

    // Explicit CoT start
    if (
      t.startsWith('<think>') ||
      t.startsWith('[thought]') ||
      t.startsWith('Thought:') ||
      /^`?\d{2}:\d{2}:\d{2}`?\s*\*\*thought:\*\*/i.test(t) ||
      t.startsWith('**thought:**')
    ) {
      st.inThought = !t.includes('</think>') && !t.includes('[/thought]');
      st.inObs = false;
      const body = t
        .replace(/^<think>\s*/i, '')
        .replace(/<\/think>\s*$/i, '')
        .replace(/^\[thought\]\s*/i, '')
        .replace(/\[\/thought\]\s*$/i, '')
        .replace(/^Thought:\s*/i, '')
        .replace(/^`?\d{2}:\d{2}:\d{2}`?\s*\*\*thought:\*\*\s*/i, '')
        .replace(/^\*\*thought:\*\*\s*/i, '');
      const startsNew = st.activeKind !== 'thought';
      st.activeKind = 'thought';
      return { kind: 'thought', text: body, cont: !startsNew };
    }

    if (st.inThought) {
      if (
        t.includes('</think>') ||
        t.includes('[/thought]') ||
        /^(?:Tool Call:|Action:|Calling tool:|<tool_call>|Observation:|✓ Task Complete)/i.test(t)
      ) {
        st.inThought = false;
        const cleaned = t.replace(/<\/think>/gi, '').replace(/\[\/thought\]/gi, '').trim();
        if (!cleaned) {
          st.activeKind = null;
          return { kind: 'noop', text: '', cont: true };
        }
        if (/^(?:Tool Call:|Action:|Calling tool:|<tool_call>|Observation:|✓ Task Complete)/i.test(cleaned)) {
          st.activeKind = null;
          return classifySegment(cleaned, st);
        }
        return { kind: 'thought', text: cleaned, cont: true };
      }
      return { kind: 'thought', text: clean, cont: true };
    }

    // Steering / Compaction / Circuit banners
    if (
      t.includes('[CRITICAL OPERATOR DIRECTIVE') ||
      t.includes('[OPERATOR GUIDANCE INJECTION]') ||
      t.includes('[Steer Injected]') ||
      t.includes('[COMPACT INTERRUPT]') ||
      t.includes('[CIRCUIT BREAKER]') ||
      t.includes('[GUARD NOTICE]') ||
      t.startsWith('PRIMARY OBJECTIVE:')
    ) {
      st.inObs = false;
      st.activeKind = null;
      return { kind: 'banner', text: t, cont: false };
    }

    // Tool call dispatch
    if (
      t.startsWith('Tool Call:') ||
      t.startsWith('Action:') ||
      t.startsWith('Calling tool:') ||
      t.startsWith('<tool_call>') ||
      t.includes('Native Tool Call:') ||
      t.includes('[TOOL_START]') ||
      t.includes('[DEBUG: Tool Args]') ||
      /^`?\d{2}:\d{2}:\d{2}`?\s*\*\*(step|tool_call):\*\*/i.test(t)
    ) {
      st.inObs = false;
      const isArgsCont = (t.includes('[DEBUG: Tool Args]') || t.startsWith('{')) && st.activeKind === 'tool';
      st.activeKind = 'tool';
      return { kind: 'tool', text: t, cont: isArgsCont };
    }

    // Observations / tool results
    if (
      t.startsWith('Observation:') ||
      t.startsWith('[DEBUG: Observation') ||
      t.startsWith('↳ Digest:') ||
      t.startsWith('Tool output:') ||
      t.includes('[TOOL_OK]') ||
      t.includes('[TOOL_FAIL]') ||
      t.includes('[TOOL_PROG]') ||
      t.startsWith('**observation')
    ) {
      const cont = st.inObs && st.activeKind === 'observation' && !t.startsWith('Observation:') && !t.includes('[TOOL_OK]') && !t.includes('[TOOL_FAIL]');
      st.inObs = true;
      st.activeKind = 'observation';
      return { kind: 'observation', text: clean, cont };
    }

    // Errors / Success
    if (
      t.startsWith('✗') ||
      t.startsWith('[ERROR]') ||
      t.startsWith('ERROR:') ||
      t.startsWith('Traceback (most recent') ||
      /^`?\d{2}:\d{2}:\d{2}`?\s*\*\*err:\*\*/i.test(t)
    ) {
      st.inObs = false;
      st.activeKind = null;
      return { kind: 'error', text: t, cont: false };
    }
    if (
      t.startsWith('✓') ||
      t.startsWith('[SUCCESS]') ||
      t.includes('✓ Task Complete') ||
      /^`?\d{2}:\d{2}:\d{2}`?\s*\*\*ok:\*\*/i.test(t)
    ) {
      st.inObs = false;
      st.activeKind = null;
      return { kind: 'success', text: t, cont: false };
    }

    // System metadata lines
    if (
      /^\[(?:evaluator|digest|honeydew|tool-mask|debug|info|MCP|FIFO_IPC|FIFO_GC|EMIT|REACTION|CHECKPOINT|REMEDIATION)/i.test(t) ||
      /^(?:Context Window:|Active Engine:|Task Profile:|Execution Plan|Assembling context|Starting Task:|\*\*(?:Task|Started|Directory|Model|Backend|dim):\*\*)/i.test(t)
    ) {
      st.inObs = false;
      const cont = st.activeKind === 'system';
      st.activeKind = 'system';
      return { kind: 'system', text: t, cont };
    }

    if (st.inObs) {
      return { kind: 'observation', text: clean, cont: true };
    }

    // Default: continuous model prose
    const cont = st.activeKind === 'prose';
    st.activeKind = 'prose';
    return { kind: 'prose', text: clean, cont };
  }

  function extractToolLabel(text) {
    const m =
      text.match(/(?:Tool Call:|Calling tool:|Native Tool Call:|\[TOOL_START\]|Action:)\s*([a-zA-Z0-9_.:-]+)/i) ||
      text.match(/"name"\s*:\s*"([^"]+)"/);
    return m ? m[1] : 'tool';
  }

  function createConsoleState(streamEl) {
    const st = {
      streamEl,
      filter: 'all',
      thoughtsCollapsedDefault: false,
      speedMode: getSpeedMode(),
      rawBuffer: '',
      turnCount: 0,
      thoughtCount: 0,
      toolCount: 0,
      activeTool: 'idle',
      parseState: { inThought: false, inObs: false, activeKind: null },
      currentCard: null,
      cards: [],
      pendingQueue: [],
      flushTimer: null,
      pinned: true,
    };

    streamEl.classList.add('tc-host');
    const shell = el('div', { className: 'tc-shell' });

    const turnPill = el('span', { className: 'tc-stat-pill', text: 'TURN 0' });
    const toolPill = el('span', { className: 'tc-stat-pill tool', text: 'TOOL: idle' });
    const thoughtPill = el('span', { className: 'tc-stat-pill thought', text: 'CoT: 0' });

    const filterBtns = {};
    const makeFilterBtn = (id, label) => {
      const b = el('button', {
        className: 'tc-filter-btn' + (id === 'all' ? ' active' : ''),
        text: label,
        on: {
          click: () => {
            st.filter = id;
            Object.entries(filterBtns).forEach(([k, btn]) => btn.classList.toggle('active', k === id));
            applyFilter(st);
          },
        },
      });
      filterBtns[id] = b;
      return b;
    };

    const speedSel = el('select', {
      className: 'tc-speed-select',
      title: 'Live transcript display pacing',
      on: {
        change: () => {
          st.speedMode = speedSel.value;
          setSpeedMode(st.speedMode);
        },
      },
    }, [
      el('option', { value: 'instant', text: 'Speed: Instant' }),
      el('option', { value: 'smooth', text: 'Speed: Smooth (60fps)' }),
      el('option', { value: 'reading', text: 'Speed: Reading' }),
    ]);
    speedSel.value = st.speedMode;

    const collapseBtn = el('button', {
      className: 'tc-ctrl-btn',
      text: 'FOLD CoT',
      title: 'Collapse or expand all Chain-of-Thought cards',
      on: {
        click: () => {
          st.thoughtsCollapsedDefault = !st.thoughtsCollapsedDefault;
          collapseBtn.textContent = st.thoughtsCollapsedDefault ? 'EXPAND CoT' : 'FOLD CoT';
          st.cards.forEach((c) => {
            if (c.kind === 'thought') c.root.classList.toggle('collapsed', st.thoughtsCollapsedDefault);
          });
        },
      },
    });

    const toolbar = el('div', { className: 'tc-toolbar' }, [
      el('div', { className: 'tc-toolbar-group' }, [turnPill, toolPill, thoughtPill]),
      el('div', { className: 'tc-toolbar-group' }, [
        makeFilterBtn('all', 'ALL'),
        makeFilterBtn('thought', 'THOUGHTS'),
        makeFilterBtn('tool', 'TOOLS'),
        makeFilterBtn('prose', 'OUTPUT'),
        makeFilterBtn('raw', 'RAW'),
        collapseBtn,
        speedSel,
      ]),
    ]);

    const feed = el('div', { className: 'tc-feed' });
    const rawPre = el('pre', { className: 'tc-raw-pre tc-hidden' });
    const jumpBtn = el('button', {
      className: 'tc-jump-btn',
      text: '↓ JUMP TO LIVE',
      on: {
        click: () => {
          st.pinned = true;
          streamEl._autoScrollPinned = true;
          jumpBtn.classList.remove('visible');
          streamEl.scrollTop = streamEl.scrollHeight;
        },
      },
    });

    shell.appendChild(toolbar);
    shell.appendChild(feed);
    shell.appendChild(rawPre);
    shell.appendChild(jumpBtn);
    streamEl.replaceChildren(shell);

    streamEl.addEventListener('scroll', () => {
      const dist = streamEl.scrollHeight - streamEl.scrollTop - streamEl.clientHeight;
      const atBottom = dist < 48;
      st.pinned = atBottom;
      streamEl._autoScrollPinned = atBottom;
      jumpBtn.classList.toggle('visible', !atBottom && st.cards.length > 0);
    }, { passive: true });

    st.els = { shell, feed, rawPre, jumpBtn, turnPill, toolPill, thoughtPill, speedSel };
    streamEl._tcState = st;
    return st;
  }

  function applyFilter(st) {
    const isRaw = st.filter === 'raw';
    st.els.feed.classList.toggle('tc-hidden', isRaw);
    st.els.rawPre.classList.toggle('tc-hidden', !isRaw);
    if (isRaw) {
      st.els.rawPre.textContent = st.rawBuffer || '(No raw output yet)';
      return;
    }
    st.cards.forEach((c) => {
      if (st.filter === 'all') {
        c.root.classList.remove('tc-hidden');
      } else if (st.filter === 'thought') {
        c.root.classList.toggle('tc-hidden', c.kind !== 'thought' && c.kind !== 'turn');
      } else if (st.filter === 'tool') {
        c.root.classList.toggle('tc-hidden', c.kind !== 'tool' && c.kind !== 'observation' && c.kind !== 'turn');
      } else if (st.filter === 'prose') {
        c.root.classList.toggle('tc-hidden', c.kind !== 'prose' && c.kind !== 'success' && c.kind !== 'error' && c.kind !== 'banner');
      }
    });
  }

  function updateHeader(st) {
    st.els.turnPill.textContent = `TURN ${st.turnCount}`;
    st.els.toolPill.textContent = `TOOL: ${st.activeTool}`;
    st.els.thoughtPill.textContent = `CoT: ${st.thoughtCount}`;
  }

  function startCard(st, kind, initialText) {
    if (kind === 'turn') {
      st.turnCount++;
      const m = initialText.match(/Turn\s+(\d+)/i);
      if (m) st.turnCount = Math.max(st.turnCount, parseInt(m[1], 10));
      const div = el('div', { className: 'tc-turn-divider', text: initialText });
      const rec = { kind: 'turn', root: div, body: null, summary: null, meta: null, text: initialText };
      st.cards.push(rec);
      st.els.feed.appendChild(div);
      st.currentCard = null;
      updateHeader(st);
      return rec;
    }

    const badgeLabels = {
      thought: 'CHAIN OF THOUGHT',
      tool: 'TOOL CALL',
      observation: 'OBSERVATION',
      prose: 'GEORGE OUTPUT',
      error: 'ERROR',
      success: 'COMPLETE',
      banner: 'DIRECTIVE',
      system: 'SYSTEM',
    };

    let badgeTxt = badgeLabels[kind] || 'LOG';
    if (kind === 'thought') st.thoughtCount++;
    if (kind === 'tool') {
      st.toolCount++;
      st.activeTool = extractToolLabel(initialText);
      badgeTxt = `TOOL · ${st.activeTool}`;
    }

    const card = el('div', { className: `tc-card ${kind}` });
    if (kind === 'thought' && st.thoughtsCollapsedDefault) card.classList.add('collapsed');
    if (kind === 'system') card.classList.add('collapsed');

    const summary = el('span', { className: 'tc-card-summary', text: initialText.slice(0, 110) });
    const meta = el('span', { className: 'tc-card-meta', text: `${initialText.length} ch` });

    const headRight = el('div', { className: 'tc-toolbar-group' }, [meta]);
    if (kind === 'observation' || kind === 'tool') {
      const expBtn = el('button', {
        className: 'tc-ctrl-btn',
        text: 'FULL',
        on: {
          click: (ev) => {
            ev.stopPropagation();
            const full = card.classList.toggle('expanded-full');
            expBtn.textContent = full ? 'COMPACT' : 'FULL';
          },
        },
      });
      const copyBtn = el('button', {
        className: 'tc-ctrl-btn',
        text: 'COPY',
        on: {
          click: (ev) => {
            ev.stopPropagation();
            if (navigator.clipboard) navigator.clipboard.writeText(rec.text).catch(() => {});
            copyBtn.textContent = 'COPIED';
            setTimeout(() => { copyBtn.textContent = 'COPY'; }, 1200);
          },
        },
      });
      headRight.appendChild(expBtn);
      headRight.appendChild(copyBtn);
    }

    const head = el('div', {
      className: 'tc-card-head',
      on: {
        click: () => card.classList.toggle('collapsed'),
      },
    }, [
      el('div', { className: 'tc-card-head-left' }, [
        el('span', { className: 'tc-card-badge', text: badgeTxt }),
        summary,
      ]),
      headRight,
    ]);

    const bodyText = kind === 'tool' || kind === 'observation' ? prettyTryJson(initialText) : initialText;
    const body = el('div', { className: 'tc-card-body', text: bodyText });

    card.appendChild(head);
    card.appendChild(body);
    st.els.feed.appendChild(card);

    const rec = { kind, root: card, body, summary, meta, text: bodyText };
    st.cards.push(rec);
    st.currentCard = rec;

    // Cap card DOM count cleanly so long 200-step tasks stay 60fps
    if (st.cards.length > 400) {
      const dropped = st.cards.shift();
      if (dropped && dropped.root && dropped.root.parentNode) dropped.root.parentNode.removeChild(dropped.root);
    }
    updateHeader(st);
    applyFilter(st);
    return rec;
  }

  function joinSmart(prev, next, kind) {
    if (!prev) return next;
    if (!next) return prev;
    if (next === '\n') return prev.endsWith('\n\n') ? prev : prev + '\n';
    // Coalesce short streamed token fragments smoothly for thoughts & prose instead of hard line-breaking every 3 tokens
    if ((kind === 'thought' || kind === 'prose') && next.length < 48 && !next.startsWith('#') && !next.startsWith('-') && !next.startsWith('*') && !next.startsWith('```') && !/^\d+\./.test(next)) {
      if (prev.endsWith('\n') || prev.endsWith(' ') || /^[,.;:!?)\]}]/.test(next)) {
        return prev + next;
      }
      return prev + ' ' + next;
    }
    return prev + '\n' + next;
  }

  function ingestLine(st, rawLine) {
    const clean = stripAnsi(rawLine);
    st.rawBuffer = st.rawBuffer ? st.rawBuffer + '\n' + clean : clean;
    if (st.rawBuffer.length > 350000) st.rawBuffer = st.rawBuffer.slice(-300000);
    if (st.filter === 'raw') st.els.rawPre.textContent = st.rawBuffer;

    const seg = classifySegment(rawLine, st.parseState);
    if (seg.kind === 'noop') return;

    if (seg.cont && st.currentCard && st.currentCard.kind === seg.kind && st.currentCard.body) {
      const nextText = joinSmart(st.currentCard.text, seg.text, seg.kind);
      st.currentCard.text = nextText;
      st.currentCard.body.textContent = nextText;
      st.currentCard.meta.textContent = `${nextText.length} ch`;
      if (!st.currentCard.summary.textContent && seg.text.trim()) {
        st.currentCard.summary.textContent = seg.text.trim().slice(0, 110);
      }
    } else {
      startCard(st, seg.kind, seg.text);
    }
  }

  function scrollIfPinned(st) {
    if (!st.pinned) return;
    requestAnimationFrame(() => {
      if (st.pinned) st.streamEl.scrollTop = st.streamEl.scrollHeight;
    });
  }

  function flushQueue(st) {
    st.flushTimer = null;
    if (!st.pendingQueue.length) return;
    const mode = st.speedMode;
    const batchSize = mode === 'reading' ? 1 : mode === 'smooth' ? 4 : st.pendingQueue.length;
    for (let i = 0; i < batchSize && st.pendingQueue.length; i++) {
      ingestLine(st, st.pendingQueue.shift());
    }
    scrollIfPinned(st);
    if (st.pendingQueue.length) {
      const delay = mode === 'reading' ? 45 : 16;
      st.flushTimer = setTimeout(() => flushQueue(st), delay);
    }
  }

  window.LodgeTranscriptConsole = {
    renderBatch(streamEl, text) {
      if (!streamEl) return;
      const st = createConsoleState(streamEl);
      const lines = String(text || '').split('\n');
      const slice = lines.length > 2500 ? lines.slice(lines.length - 2500) : lines;
      for (const ln of slice) {
        if (!ln.trim() && st.cards.length === 0) continue;
        ingestLine(st, ln);
      }
      scrollIfPinned(st);
    },

    appendChunk(streamEl, rawChunk) {
      if (!streamEl || rawChunk == null) return;
      const st = streamEl._tcState || createConsoleState(streamEl);
      st.speedMode = getSpeedMode();
      if (st.els && st.els.speedSel) st.els.speedSel.value = st.speedMode;

      const lines = String(rawChunk).split('\n');
      for (const ln of lines) st.pendingQueue.push(ln);

      if (st.speedMode === 'instant') {
        if (!st.flushTimer) {
          st.flushTimer = requestAnimationFrame(() => flushQueue(st));
        }
      } else if (!st.flushTimer) {
        st.flushTimer = setTimeout(() => flushQueue(st), 16);
      }
    },

    syncSpeedFromPacing(pacingNum) {
      const mode = pacingNum <= 0 ? 'instant' : pacingNum <= 35 ? 'reading' : 'smooth';
      document.querySelectorAll('.tc-host').forEach((host) => {
        if (host._tcState) {
          host._tcState.speedMode = mode;
          if (host._tcState.els && host._tcState.els.speedSel) {
            host._tcState.els.speedSel.value = mode;
          }
        }
      });
    },
  };
})();
