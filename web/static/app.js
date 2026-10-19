// ============================================================================
// GEORGE // Craftsman's Workbench Client Engine (Phase 2)
// ============================================================================

(function() {
  'use strict';

  // --- Theme Engine ---
  const themeSelect = document.getElementById('themeSelect');
  let currentTheme = localStorage.getItem('george-theme') || 'obsidian';

  function applyTheme(theme) {
    currentTheme = theme;
    document.documentElement.setAttribute('data-theme', theme);
    if (themeSelect) themeSelect.value = theme;
    localStorage.setItem('george-theme', theme);
  }

  if (themeSelect) {
    themeSelect.addEventListener('change', (e) => applyTheme(e.target.value));
  }
  applyTheme(currentTheme);

  // --- Pacing Engine (Configurable Token UX) ---
  let currentPacing = parseInt(localStorage.getItem('george-pacing') || '30', 10);

  // --- Elements ---
  const streamEl = document.getElementById('workbenchStream');
  const promptInput = document.getElementById('promptInput');
  const sendBtn = document.getElementById('sendBtn');
  const dropZone = document.getElementById('dropZone');
  const attachBtn = document.getElementById('attachBtn');
  const fileInput = document.getElementById('fileInput');
  const toolCribDrawer = document.getElementById('toolCribDrawer');
  const toolCribToggle = document.getElementById('toolCribToggle');
  const drawerClose = document.getElementById('drawerClose');
  const drawerTabs = document.getElementById('drawerTabs');
  const nodeModal = document.getElementById('nodeModal');
  const addNodeBtn = document.getElementById('addNodeBtn');
  const nodeModalClose = document.getElementById('nodeModalClose');

  // 3-Way Mode Switcher & Session Controls
  let activeChatMode = localStorage.getItem('george-chat-mode') || 'agentic';
  const modeChatBtn = document.getElementById('modeChatBtn');
  const modeAgenticBtn = document.getElementById('modeAgenticBtn');
  const modePlanTaskBtn = document.getElementById('modePlanTaskBtn');
  const btnNewSession = document.getElementById('btnNewSession');

  function setChatMode(mode) {
    activeChatMode = mode;
    localStorage.setItem('george-chat-mode', mode);
    if (modeChatBtn) modeChatBtn.classList.toggle('active', mode === 'chat');
    if (modeAgenticBtn) modeAgenticBtn.classList.toggle('active', mode === 'agentic');
    if (modePlanTaskBtn) modePlanTaskBtn.classList.toggle('active', mode === 'plan-task');
  }

  if (modeChatBtn) modeChatBtn.addEventListener('click', () => setChatMode('chat'));
  if (modeAgenticBtn) modeAgenticBtn.addEventListener('click', () => setChatMode('agentic'));
  if (modePlanTaskBtn) modePlanTaskBtn.addEventListener('click', () => setChatMode('plan-task'));
  setChatMode(activeChatMode);

  if (btnNewSession) {
    btnNewSession.addEventListener('click', async () => {
      if (confirm('Archive current transcript to Time-Machine and open a fresh session?')) {
        try {
          await fetch('/api/session', { method: 'DELETE' });
          if (streamEl) {
            streamEl.innerHTML = `
              <div class="welcome-card" id="welcomeCard">
                <div class="welcome-header">
                  <span class="welcome-symbol">▲</span>
                  <span class="welcome-title">George's Workbench</span>
                </div>
                <div class="welcome-body">
                  Fresh session initialized. Chat freely, dispatch slash commands (<code>/status</code>, <code>/dispatch</code>, <code>/recall</code>), or drag and drop blueprints and artifacts directly into the prompt below.
                </div>
              </div>
            `;
          }
          if (promptInput) {
            promptInput.value = '';
            promptInput.focus();
          }
          loadTranscripts();
        } catch (e) {
          console.error('Session reset error:', e);
        }
      }
    });
  }

  function autoResizePrompt() {
    if (promptInput) {
      promptInput.style.height = 'auto';
      promptInput.style.height = Math.min(promptInput.scrollHeight, 180) + 'px';
    }
  }

  // Attach button and Drag & Drop file staging
  async function handleUploadedFiles(fileList) {
    if (!fileList || fileList.length === 0) return;
    const formData = new FormData();
    for (let i = 0; i < fileList.length; i++) {
      formData.append('file', fileList[i]);
    }
    try {
      const resp = await fetch('/api/upload', {
        method: 'POST',
        body: formData
      });
      if (resp.ok) {
        const data = await resp.json();
        if (data.uploaded && data.uploaded.length > 0) {
          data.uploaded.forEach(u => {
            const stagedText = u.staged_command ? `${u.staged_command}` : `[Attached: ${u.path}]`;
            if (promptInput.value.trim().length > 0) {
              promptInput.value += `\n${stagedText}`;
            } else {
              promptInput.value = stagedText;
            }
          });
          promptInput.focus();
          autoResizePrompt();
        }
      }
    } catch (err) {
      console.error('Upload failed:', err);
    }
  }

  if (attachBtn && fileInput) {
    attachBtn.addEventListener('click', () => fileInput.click());
    fileInput.addEventListener('change', async () => {
      if (fileInput.files && fileInput.files.length > 0) {
        await handleUploadedFiles(fileInput.files);
        fileInput.value = '';
      }
    });
  }

  // Viewport drag & drop
  ['dragenter', 'dragover'].forEach(evt => {
    window.addEventListener(evt, (e) => {
      e.preventDefault();
      if (dropZone) dropZone.classList.add('active');
    });
  });

  ['dragleave', 'dragend'].forEach(evt => {
    window.addEventListener(evt, (e) => {
      e.preventDefault();
      if (e.clientX <= 0 || e.clientY <= 0 || e.clientX >= window.innerWidth || e.clientY >= window.innerHeight) {
        if (dropZone) dropZone.classList.remove('active');
      }
    });
  });

  if (dropZone) {
    dropZone.addEventListener('dragleave', () => dropZone.classList.remove('active'));
    dropZone.addEventListener('drop', async (e) => {
      e.preventDefault();
      dropZone.classList.remove('active');
      if (e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files.length > 0) {
        await handleUploadedFiles(e.dataTransfer.files);
      }
    });
  }

  // Phase 2 & 3 Elements
  const activeTasksStrip = document.getElementById('activeTasksStrip');
  const tasksCarousel = document.getElementById('tasksCarousel');
  const activeTasksCount = document.getElementById('activeTasksCount');
  const hdrGpu = document.getElementById('hdrGpu');
  const hdrTemp = document.getElementById('hdrTemp');
  const hdrPower = document.getElementById('hdrPower');
  const hdrVram = document.getElementById('hdrVram');

  // Autonomic Task Bay Elements (Phase 3)
  const autonomicTaskBay = document.getElementById('autonomicTaskBay');
  const bayActiveCount = document.getElementById('bayActiveCount');
  const autonomicBayRail = document.getElementById('autonomicBayRail');
  const autonomicExpandedStage = document.getElementById('autonomicExpandedStage');
  let expandedTaskId = null;
  let cachedTasks = [];
  const persistentTaskMap = new Map();

  // --- Dynamic Scrollbar Alignment ---
  function syncScrollbarWidth() {
    if (streamEl) {
      const sbWidth = streamEl.offsetWidth - streamEl.clientWidth;
      document.documentElement.style.setProperty('--scrollbar-width', `${sbWidth}px`);
    }
  }
  window.addEventListener('resize', syncScrollbarWidth);
  setTimeout(syncScrollbarWidth, 100);

  // --- Auto-Expanding Textarea ---
  if (promptInput) {
    promptInput.addEventListener('input', function() {
      this.style.height = 'auto';
      this.style.height = Math.min(this.scrollHeight, 140) + 'px';
    });

    promptInput.addEventListener('keydown', function(e) {
      if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        dispatchPrompt();
      }
    });
  }

  if (sendBtn) {
    sendBtn.addEventListener('click', dispatchPrompt);
  }

  // --- Auto-Scroll Helper (Pinned state tracking) ---
  if (streamEl) {
    streamEl._autoScrollPinned = true;
    streamEl.addEventListener('scroll', () => {
      const distFromBottom = streamEl.scrollHeight - streamEl.scrollTop - streamEl.clientHeight;
      streamEl._autoScrollPinned = distFromBottom <= 35;
    }, { passive: true });
    streamEl.addEventListener('wheel', (e) => {
      if (e.deltaY < 0) streamEl._autoScrollPinned = false;
    }, { passive: true });
  }

  function scrollToLatest(preElement = null) {
    if (streamEl && streamEl._autoScrollPinned !== false) {
      if (!streamEl._scrollRafPending) {
        streamEl._scrollRafPending = true;
        requestAnimationFrame(() => {
          streamEl._scrollRafPending = false;
          if (streamEl && streamEl._autoScrollPinned !== false) {
            streamEl.scrollTop = streamEl.scrollHeight;
          }
        });
      }
    }
    if (preElement && preElement._autoScrollPinned !== false) {
      if (!preElement._scrollRafPending) {
        preElement._scrollRafPending = true;
        requestAnimationFrame(() => {
          preElement._scrollRafPending = false;
          if (preElement && preElement._autoScrollPinned !== false) {
            preElement.scrollTop = preElement.scrollHeight;
          }
        });
      }
    }
  }

  // --- Session Ledger Hydration (Preserve state across refreshes) ---
  async function hydrateSession() {
    try {
      const resp = await fetch('/api/session');
      if (resp.ok) {
        const data = await resp.json();
        if (data.messages && data.messages.length > 0) {
          const welcome = document.getElementById('welcomeCard');
          if (welcome) welcome.style.display = 'none';

          let lastUserTaskId = null;
          data.messages.forEach(msg => {
            if (msg.role === 'user') {
              if (msg.task_id) lastUserTaskId = msg.task_id;
              renderUserBubble(msg.content, false);
            } else if (msg.type === 'command_blueprint' || msg.type === 'agentic' || msg.type === 'plan-task') {
              const badge = msg.type === 'agentic' ? 'AGENTIC TASK' : (msg.type === 'plan-task' ? 'PLANNING TASK' : 'BLUEPRINT');
              const tId = msg.task_id || lastUserTaskId || msg.id;
              renderBlueprintCard(msg.command || 'Task Execution', msg.content, tId, false, null, badge, 'COMPLETED');
              const msgTime = msg.timestamp
                ? (Number(msg.timestamp) > 1e11 ? Number(msg.timestamp) : Number(msg.timestamp) * 1000)
                : 0;
              // Only seed into Autonomic Task Bay if recently finished (< 45s ago)
              if (tId && msgTime > 0 && (Date.now() - msgTime < 45000)) {
                const taskPath = (tId.startsWith('cmd_') || tId.startsWith('agentic_') || tId.startsWith('plan_'))
                  ? `.sandboxes/${tId}`
                  : (msg.task_id ? `.sandboxes/${msg.task_id}` : `.sandboxes/${tId}`);
                persistentTaskMap.set(tId, {
                  id: tId,
                  task_id: msg.task_id || lastUserTaskId || tId,
                  type: msg.type === 'agentic' ? 'agentic' : (msg.type === 'plan-task' ? 'plan' : 'command'),
                  summary: (msg.type === 'agentic' ? 'Agentic: ' : (msg.type === 'plan-task' ? 'Plan: ' : 'Cmd: ')) + (msg.command || (msg.content ? msg.content.slice(0, 80) : tId)),
                  phase: 'Completed',
                  done: true,
                  path: taskPath,
                  content: msg.content || '',
                  log_tail: msg.content ? msg.content.trim().split('\n').slice(-15) : [],
                  lastSeen: msgTime
                });
              }
            } else {
              renderAssistantBubble(msg.content, false);
            }
          });
          renderAutonomicTaskBay(Array.from(persistentTaskMap.values()));
          scrollToLatest();
        }
      }
    } catch (e) {
      console.warn('Session hydration failed:', e);
    }
  }

  function escapeHtml(text) {
    if (!text) return '';
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
  }

  function parseThoughtAndAnswer(rawText) {
    if (!rawText) return { thought: '', answer: '' };

    // Check for <thought>...</thought> tags
    const tagMatch = rawText.match(/<thought>([\s\S]*?)<\/thought>([\s\S]*)/i);
    if (tagMatch) {
      return { thought: tagMatch[1].trim(), answer: tagMatch[2].trim() };
    }

    // Check for [thought] block
    if (rawText.includes('[thought]')) {
      const closingIdx = rawText.indexOf('[/thought]');
      if (closingIdx !== -1) {
        const thought = rawText.substring(rawText.indexOf('[thought]') + 9, closingIdx).trim();
        const answer = rawText.substring(closingIdx + 10).trim();
        return { thought, answer };
      }

      const thoughtStart = rawText.indexOf('[thought]') + 9;
      const remainder = rawText.substring(thoughtStart);

      // Look for boundary where thought ends and answer/next stage begins
      const boundaryMatch = remainder.match(/\n\s*(?:Context:\s*\d+\/\d+|\u2713\s*Task Complete!|── Turn|\n\n)([^\n][\s\S]*)/);
      if (boundaryMatch && boundaryMatch.index !== undefined) {
        const thought = remainder.substring(0, boundaryMatch.index).trim();
        const answer = remainder.substring(boundaryMatch.index).trim();
        return { thought, answer };
      }

      return { thought: remainder.trim(), answer: '' };
    }

    return { thought: '', answer: rawText };
  }

  function setBubbleFormattedContent(bubble, rawText) {
    bubble.innerHTML = '';
    const { thought, answer } = parseThoughtAndAnswer(rawText);

    if (thought) {
      const details = document.createElement('details');
      details.className = 'thought-trace-box';
      const summary = document.createElement('summary');
      summary.className = 'thought-trace-summary';
      const wordCount = thought.split(/\s+/).filter(Boolean).length;
      summary.innerHTML = `<span class="thought-label">[THOUGHT] Reasoning Monologue</span> <span class="thought-meta">(${wordCount} words)</span>`;
      const body = document.createElement('div');
      body.className = 'thought-trace-body';
      body.textContent = thought;
      details.appendChild(summary);
      details.appendChild(body);
      bubble.appendChild(details);
    }

    if (answer) {
      const answerEl = document.createElement('div');
      answerEl.className = 'bubble-answer-text';
      answerEl.textContent = answer;
      bubble.appendChild(answerEl);
    } else if (!thought) {
      bubble.textContent = rawText;
    }
  }

  // ANSI 256 and standard color mapping
  const ANSI_STD_COLORS = {
    '30': '#1e293b', '31': '#f87171', '32': '#4ade80', '33': '#fbbf24',
    '34': '#60a5fa', '35': '#c084fc', '36': '#38bdf8', '37': '#f1f5f9',
    '90': '#94a3b8', '91': '#ef4444', '92': '#22c55e', '93': '#f59e0b',
    '94': '#3b82f6', '95': '#a855f7', '96': '#06b6d4', '97': '#ffffff'
  };

  function ansi256Color(n) {
    if (n < 8) return ANSI_STD_COLORS[String(30 + n)];
    if (n < 16) return ANSI_STD_COLORS[String(90 + n - 8)];
    if (n >= 232 && n <= 255) {
      const v = Math.round(((n - 232) / 23) * 255);
      return `rgb(${v},${v},${v})`;
    }
    n -= 16;
    const b = (n % 6) * 51;
    const g = (Math.floor(n / 6) % 6) * 51;
    const r = (Math.floor(n / 36) % 6) * 51;
    return `rgb(${r},${g},${b})`;
  }

  function parseAnsi(text) {
    if (!text) return '';
    let s = escapeHtml(text).replace(/\r/g, '').replace(/\x1b\[2K/g, '').replace(/\x1b\[\?25[hl]/g, '');
    let openSpans = 0;

    s = s.replace(/\x1b\[([0-9;]*)m/g, (match, codesStr) => {
      if (!codesStr || codesStr === '0') {
        let closing = '';
        while (openSpans > 0) { closing += '</span>'; openSpans--; }
        return closing;
      }
      const codes = codesStr.split(';');
      let styles = [];
      for (let i = 0; i < codes.length; i++) {
        const c = codes[i];
        if (c === '0') {
          let closing = '';
          while (openSpans > 0) { closing += '</span>'; openSpans--; }
          return closing;
        } else if (c === '1') {
          styles.push('font-weight:bold');
        } else if (c === '2') {
          styles.push('opacity:0.75');
        } else if (c === '3') {
          styles.push('font-style:italic');
        } else if (c === '4') {
          styles.push('text-decoration:underline');
        } else if (c === '38' && codes[i+1] === '5' && codes[i+2]) {
          const col = ansi256Color(parseInt(codes[i+2], 10));
          if (col) styles.push(`color:${col}`);
          i += 2;
        } else if (ANSI_STD_COLORS[c]) {
          styles.push(`color:${ANSI_STD_COLORS[c]}`);
        }
      }
      if (styles.length > 0) {
        openSpans++;
        return `<span style="${styles.join(';')}">`;
      }
      return '';
    });

    s = s.replace(/\x1b\[[0-9;]*[a-zA-Z]/g, '');
    while (openSpans > 0) { s += '</span>'; openSpans--; }
    return s;
  }

  function classifyLogLine(rawLine, state) {
    if (!state) state = {};
    const stripped = rawLine.replace(/\x1b\[[0-9;]*[a-zA-Z]/g, '').trim();

    // 1. Thinking / Internal Monologue
    if (stripped.startsWith('<think>') || stripped.startsWith('[thought]') || stripped.startsWith('Thought:') || /^`?\d{2}:\d{2}:\d{2}`?\s*\*\*thought:\*\*/i.test(stripped) || stripped.startsWith('**thought:**')) {
      state.inThought = true;
      state.inObservation = false;
      return 'log-thought';
    }
    if (state.inThought) {
      if (stripped.includes('</think>') || stripped.includes('[/thought]') || stripped.startsWith('── Turn') || stripped.startsWith('### Turn') || stripped.startsWith('## Turn') || stripped.startsWith('✓ Task Complete') || stripped.startsWith('Action:') || stripped.startsWith('Calling tool:') || /^`?\d{2}:\d{2}:\d{2}`?\s*\*\*(step|tool_call|ok|warn|err):\*\*/i.test(stripped)) {
        state.inThought = false;
      }
      return 'log-thought';
    }

    // 2. High-priority Banners & Steering
    if (stripped.includes('[CRITICAL OPERATOR DIRECTIVE') || stripped.includes('[OPERATOR GUIDANCE INJECTION]') || stripped.includes('Operator Directive Injected:') || stripped.includes('[Steer Injected]:')) {
      state.inObservation = false;
      return 'log-steer-banner';
    }
    if (stripped.includes('[COMPACT INTERRUPT]') || stripped.includes('Forced Context Compaction triggered')) {
      state.inObservation = false;
      return 'log-compact-banner';
    }
    if (stripped.startsWith('── Turn') || stripped.startsWith('─── Turn') || /Turn \d+\/\d+/.test(stripped) || /^#{2,3}\s+Turn\b/i.test(stripped)) {
      state.inObservation = false;
      state.inThought = false;
      return 'log-turn';
    }
    if (stripped.includes('⚡ [CIRCUIT BREAKER]') || stripped.includes('[CIRCUIT_BREAKER]') || stripped.startsWith('⚡') || stripped.includes('Flow paused:') || stripped.includes('[flow-control]') || stripped.includes('[GUARD NOTICE]') || /^`?\d{2}:\d{2}:\d{2}`?\s*\*\*warn:\*\*/i.test(stripped) || stripped.startsWith('**warn:**')) {
      state.inObservation = false;
      return 'log-circuit';
    }

    // 3. Status outcomes
    if (stripped.startsWith('✗') || stripped.startsWith('[ERROR]') || stripped.startsWith('ERROR:') || stripped.startsWith('Exception:') || stripped.startsWith('Traceback (most recent') || stripped.includes('FAILED') || /^`?\d{2}:\d{2}:\d{2}`?\s*\*\*err:\*\*/i.test(stripped) || stripped.startsWith('**err:**')) {
      state.inObservation = false;
      return 'log-error';
    }
    if (stripped.startsWith('✓') || stripped.startsWith('[SUCCESS]') || stripped.startsWith('✓ Task Complete') || stripped.includes('Deliverables auto-committed') || stripped.includes('Pull Request created') || stripped.includes('Task complete:') || /^`?\d{2}:\d{2}:\d{2}`?\s*\*\*ok:\*\*/i.test(stripped) || stripped.startsWith('**ok:**')) {
      state.inObservation = false;
      return 'log-success';
    }

    // 4. Asynchronous & Flow-Control Tool Frames
    if (stripped.includes('[TOOL_START]') || stripped.includes('[ASYNC_EXEC]')) {
      state.inObservation = false;
      return 'log-tool-start';
    }
    if (stripped.includes('[TOOL_PROG]') || stripped.includes('[ASYNC_STREAM]') || stripped.includes('[CREDIT]')) {
      return 'log-tool-prog';
    }
    if (stripped.includes('[TOOL_OK]')) {
      state.inObservation = false;
      return 'log-tool-ok';
    }
    if (stripped.includes('[TOOL_FAIL]')) {
      state.inObservation = false;
      return 'log-tool-fail';
    }
    if (stripped.includes('[SPILLOVER]')) {
      return 'log-tool-spillover';
    }
    if (stripped.includes('[FIFO_IPC]') || stripped.includes('[FIFO_GC]') || stripped.includes('[AWAIT]')) {
      return 'log-fifo-ipc';
    }

    // 5. Tool Action Dispatch
    if (stripped.startsWith('Tool Call:') || stripped.startsWith('Action:') || stripped.startsWith('Calling tool:') || stripped.startsWith('<tool_call>') || stripped.startsWith('</tool_call>') || stripped.includes('Native Tool Call:') || stripped.includes('[DEBUG: Tool Args]') || /^`?\d{2}:\d{2}:\d{2}`?\s*\*\*(step|tool_call):\*\*/i.test(stripped) || stripped.startsWith('**step:**') || stripped.startsWith('**tool_call:**')) {
      state.inObservation = false;
      return 'log-tool-call';
    }

    // 6. Observations (Header & Multiline Body)
    if (stripped.startsWith('Observation:') || stripped.startsWith('[DEBUG: Observation') || stripped.startsWith('↳ Digest:') || stripped.startsWith('Tool output:') || stripped.startsWith('**observation')) {
      state.inObservation = true;
      return 'log-observation';
    }
    if (state.inObservation) {
      if (stripped.startsWith('── Turn') || stripped.startsWith('─── Turn') || /Turn \d+\/\d+/.test(stripped) || /^#{2,3}\s+Turn\b/i.test(stripped) ||
          stripped.startsWith('<think>') || stripped.startsWith('[thought]') || stripped.startsWith('Thought:') ||
          stripped.startsWith('Tool Call:') || stripped.startsWith('Action:') || stripped.startsWith('Calling tool:') || stripped.startsWith('<tool_call>') ||
          stripped.startsWith('✓') || stripped.startsWith('✗') || stripped.startsWith('[ERROR]') ||
          stripped.startsWith('[evaluator]') || stripped.startsWith('[digest]') || stripped.startsWith('[honeydew]') ||
          stripped.includes('[TOOL_START]') || stripped.includes('[TOOL_OK]') || stripped.includes('[TOOL_FAIL]') ||
          /^`?\d{2}:\d{2}:\d{2}`?\s*\*\*(step|tool_call|ok|warn|err):\*\*/i.test(stripped)) {
        state.inObservation = false;
      } else {
        return 'log-observation-body';
      }
    }

    // 7. Event Bus Subsystem Transcripts
    if (stripped.includes('[EMIT]') || stripped.startsWith('EVENT:') || stripped.includes('event_bus_emit')) {
      return 'log-event-bus-emit';
    }
    if (stripped.includes('[REACTION]') || stripped.startsWith('REACTOR:') || stripped.includes('Firing reactor')) {
      return 'log-event-bus-reaction';
    }
    if (stripped.includes('[REACTOR_ADD]') || stripped.includes('Registered reactor')) {
      return 'log-event-bus-reactor';
    }
    if (stripped.includes('[DAEMON_START]') || stripped.includes('[DAEMON_STOP]') || stripped.includes('Event Bus daemon')) {
      return 'log-event-bus-daemon';
    }
    if (stripped.includes('[DEBOUNCE]') || stripped.includes('debounce')) {
      return 'log-event-bus-debounce';
    }
    if (stripped.includes('event_bus') || stripped.includes('EVENT_BUS')) {
      return 'log-event-bus';
    }

    // 7b. Remediation Engine Transcripts
    if (stripped.includes('[CHECKPOINT]') || stripped.includes('[REMEDIATION') || stripped.includes('Sovereign Remediation') || stripped.includes('Auto-Remediation')) {
      return 'log-remediation';
    }

    // 8. System & Metadata
    if (stripped.includes('[evaluator]') || stripped.includes('[digest]') || stripped.includes('[honeydew]') || stripped.includes('[tool-mask]') || stripped.includes('[debug]') || stripped.includes('[info]') || stripped.startsWith('[+]') || stripped.startsWith('[*]') || stripped.includes('[MCP]') || stripped.startsWith('Context:') || stripped.startsWith('Context Window:') || stripped.includes('Active Engine:') || stripped.includes('Task Profile:') || stripped.includes('Execution Plan') || stripped.includes('Assembling context') || stripped.includes('Starting Task:') || stripped.includes('llama-server manages') || stripped.includes('Registry: Registered mem:') ||
        /^`?\d{2}:\d{2}:\d{2}`?\s*\*\*dim:\*\*/i.test(stripped) || stripped.startsWith('**dim:**') || /^#+\s+(Subtask )?Transcript/i.test(stripped) || stripped.startsWith('**Task:**') || stripped.startsWith('**Started:**') || stripped.startsWith('**Parent Task:**') || stripped.startsWith('**Directory:**') || stripped.startsWith('**Model:**') || stripped.startsWith('**Backend:**') || stripped.startsWith('**Prompts Log:**') || stripped.startsWith('**Main Transcript:**')) {
      return 'log-system';
    }

    // 8b. Collapsible tool summary details
    if (stripped.includes('<summary>') || stripped.includes('</summary>') || stripped.startsWith('<details>') || stripped.startsWith('</details>')) {
      return 'log-tool-details-summary';
    }

    // 9. Markdown & Model Prose
    if (/^#{1,4}\s/.test(stripped)) {
      return 'log-model-heading';
    }
    if (stripped.startsWith('```')) {
      return 'log-model-code';
    }

    return 'log-model';
  }

  function createLogLineElement(rawLine, state) {
    const lineEl = document.createElement('div');
    const cls = classifyLogLine(rawLine, state);
    const stripped = rawLine.replace(/\x1b\[[0-9;]*[a-zA-Z]/g, '').trim();

    if (cls === 'log-steer-banner') {
      lineEl.className = 'log-line stream-steer-banner';
      const cleanText = rawLine.replace(/^[⚡\s]+/, '').replace(/^\[(?:CRITICAL OPERATOR DIRECTIVE - PRIORITY 1|OPERATOR GUIDANCE INJECTION|Steer Injected)\]:?\s*/i, '');
      lineEl.innerHTML = `
        <div class="stream-steer-badge">[DIRECTIVE: PRIORITY 1]</div>
        <div class="stream-steer-content">${escapeHtml(cleanText)}</div>
      `;
      return lineEl;
    }
    if (cls === 'log-compact-banner') {
      lineEl.className = 'log-line stream-compact-banner';
      const cleanText = rawLine.replace(/^[⚡\s]+/, '').replace(/^\[COMPACT INTERRUPT\]:?\s*/i, '');
      lineEl.innerHTML = `
        <div class="stream-compact-badge">[COMPACT INTERRUPT]</div>
        <div class="stream-compact-content">${escapeHtml(cleanText)}</div>
      `;
      return lineEl;
    }

    // Primary Objective header
    if (stripped.startsWith('PRIMARY OBJECTIVE:') || stripped.startsWith('PRIMARY OBJECTIVE')) {
      lineEl.className = 'log-line stream-steer-banner';
      const cleanText = stripped.replace(/^PRIMARY OBJECTIVE:?\s*/i, '');
      lineEl.innerHTML = `
        <div class="stream-steer-badge" style="background: rgba(245, 158, 11, 0.2); border-color: rgba(245, 158, 11, 0.5); color: #f59e0b;">[PRIMARY OBJECTIVE]</div>
        <div class="stream-steer-content">${cleanText ? escapeHtml(cleanText) : ''}</div>
      `;
      return lineEl;
    }

    // Turn header banner
    if (cls === 'log-turn') {
      lineEl.className = 'log-line log-turn';
      const turnTitle = stripped
        .replace(/^[─\s#]+/, '')
        .replace(/[─\s]+$/, '');
      lineEl.innerHTML = `<span class="stream-turn-badge">TURN</span> ${escapeHtml(turnTitle)}`;
      return lineEl;
    }

    // Markdown timestamped tag lines: `HH:MM:SS` **tag:** message
    const mdTagMatch = rawLine.match(/^`?(\d{2}:\d{2}:\d{2})`?\s*\*\*([a-zA-Z0-9_]+):\*\*\s*(.*)$/);
    if (mdTagMatch) {
      const ts = mdTagMatch[1];
      const tag = mdTagMatch[2].toLowerCase();
      const rest = mdTagMatch[3];
      lineEl.className = `log-line ${cls}`;
      let tagClass = 'stream-tag';
      if (tag === 'step' || tag === 'tool_call') tagClass += ' stream-tag-step';
      else if (tag === 'ok' || tag === 'success') tagClass += ' stream-tag-ok';
      else if (tag === 'warn') tagClass += ' stream-tag-warn';
      else if (tag === 'err' || tag === 'error') tagClass += ' stream-tag-err';
      else if (tag === 'thought') tagClass += ' stream-tag-thought';
      else tagClass += ' stream-tag-dim';

      lineEl.innerHTML = `<span class="stream-ts">${ts}</span><span class="${tagClass}">[${tag.toUpperCase()}]</span> <span class="stream-msg">${escapeHtml(rest)}</span>`;
      return lineEl;
    }

    // Tool call line: Tool Call: func_name (args)
    if (cls === 'log-tool-call' && (stripped.startsWith('Tool Call:') || stripped.startsWith('Calling tool:') || stripped.startsWith('Action:'))) {
      lineEl.className = 'log-line log-tool-call';
      const cleanCall = stripped.replace(/^(?:Tool Call:|Calling tool:|Action:)\s*/i, '');
      lineEl.innerHTML = `<span class="stream-tag stream-tag-step">[TOOL CALL]</span> <span class="stream-tool-name">${escapeHtml(cleanCall)}</span>`;
      return lineEl;
    }

    // Observation header line
    if (cls === 'log-observation' && stripped.startsWith('Observation:')) {
      lineEl.className = 'log-line log-observation';
      const cleanObs = stripped.replace(/^Observation:\s*/i, '');
      lineEl.innerHTML = `<span class="stream-tag stream-tag-dim">[OBSERVATION]</span> <span>${escapeHtml(cleanObs)}</span>`;
      return lineEl;
    }

    // Thought lines
    if (cls === 'log-thought' && (stripped.startsWith('Thought:') || stripped.startsWith('[thought]') || stripped.startsWith('**thought:**'))) {
      lineEl.className = 'log-line log-thought';
      const cleanThought = stripped.replace(/^(?:Thought:|\[thought\]|\*\*thought:\*\*)\s*/i, '');
      lineEl.innerHTML = `<span class="stream-tag stream-tag-thought">[THOUGHT]</span> <em>${escapeHtml(cleanThought)}</em>`;
      return lineEl;
    }

    // Collapsible tool execution summary line
    if (rawLine.includes('<summary>') && rawLine.includes('</summary>')) {
      const inner = rawLine.replace(/<\/?summary>/g, '').replace(/<\/?b>/g, '').replace(/<\/?span[^>]*>/g, '');
      lineEl.className = 'log-line log-tool-details-summary';
      lineEl.innerHTML = `<span class="stream-summary-icon">▶</span> <span class="stream-summary-text">${escapeHtml(inner)}</span>`;
      return lineEl;
    }

    lineEl.className = `log-line ${cls}`;

    let html = parseAnsi(rawLine);
    lineEl.innerHTML = html || '&nbsp;';
    return lineEl;
  }

  function appendLogLineToStream(stream, rawLine, state) {
    if (!stream) return;
    const lineEl = createLogLineElement(rawLine, state);
    const wasScrolledToBottom = stream._autoScrollPinned !== false;
    stream.appendChild(lineEl);
    // Allow generous 3000 lines buffer; only prune from top when pinned to bottom or buffer is huge
    if (stream.childNodes.length > 3000 || (wasScrolledToBottom && stream.childNodes.length > 2000)) {
      stream.removeChild(stream.firstChild);
    }
    if (wasScrolledToBottom) {
      if (!stream._scrollRafPending) {
        stream._scrollRafPending = true;
        requestAnimationFrame(() => {
          stream._scrollRafPending = false;
          if (stream._autoScrollPinned !== false) {
            stream.scrollTop = stream.scrollHeight;
          }
        });
      }
    }
  }

  function renderLogBatchToStream(stream, text, state) {
    if (!stream) return;
    stream.innerHTML = '';
    const lines = (text || '').split('\n');
    const frag = document.createDocumentFragment();
    const maxLines = lines.length > 2000 ? lines.slice(lines.length - 2000) : lines;
    for (const line of maxLines) {
      if (line.trim().length === 0 && frag.childNodes.length === 0) continue;
      frag.appendChild(createLogLineElement(line, state));
    }
    stream.appendChild(frag);
  }

  function formatBlueprintTerminalOutput(output) {
    if (!output) return '<div class="log-line log-system">(Execution complete with zero output)</div>';
    const lines = output.split('\n');
    const state = { inThought: false };
    return lines.map(line => {
      const cls = classifyLogLine(line, state);
      let html = parseAnsi(line);
      if (!html.includes('<span')) html = escapeHtml(html);
      return `<div class="log-line ${cls}">${html || '&nbsp;'}</div>`;
    }).join('');
  }

  // --- UI Renderers ---
  function renderUserBubble(text, scroll = true) {
    const row = document.createElement('div');
    row.className = 'msg-row user';
    const bubble = document.createElement('div');
    bubble.className = 'msg-bubble';
    bubble.textContent = text;
    row.appendChild(bubble);
    streamEl.appendChild(row);
    if (scroll) scrollToLatest();
  }

  function renderAssistantBubble(text, scroll = true) {
    const row = document.createElement('div');
    row.className = 'msg-row assistant';
    const bubble = document.createElement('div');
    bubble.className = 'msg-bubble';
    setBubbleFormattedContent(bubble, text);
    row.appendChild(bubble);
    streamEl.appendChild(row);
    if (scroll) scrollToLatest();
    return bubble;
  }

  // Typewriter token streaming pacer
  function streamTextIntoBubble(bubble, fullText, pacingRate, onDone = null) {
    if (pacingRate <= 0) {
      setBubbleFormattedContent(bubble, fullText);
      scrollToLatest();
      if (onDone) onDone();
      return;
    }

    bubble.textContent = '';
    const words = fullText.split(' ');
    let index = 0;
    const intervalMs = Math.max(15, Math.floor(1000 / (pacingRate * 1.5)));

    const timer = setInterval(() => {
      if (index < words.length) {
        bubble.textContent += (index === 0 ? '' : ' ') + words[index];
        index++;
        scrollToLatest();
      } else {
        clearInterval(timer);
        setBubbleFormattedContent(bubble, fullText);
        if (onDone) onDone();
      }
    }, intervalMs);
  }

  function wireDoubleConfirmTerminate(btn, taskId, onDone) {
    if (!btn) return;
    let revertTimer = null;
    btn.addEventListener('click', async (e) => {
      e.stopPropagation();
      if (!btn.dataset.state || btn.dataset.state === 'initial') {
        btn.dataset.state = 'confirming';
        btn.textContent = 'CONFIRM KILL?';
        btn.classList.add('confirming');
        clearTimeout(revertTimer);
        revertTimer = setTimeout(() => {
          if (btn && btn.dataset.state === 'confirming') {
            btn.dataset.state = 'initial';
            btn.textContent = 'TERMINATE';
            btn.classList.remove('confirming');
          }
        }, 4000);
      } else if (btn.dataset.state === 'confirming') {
        clearTimeout(revertTimer);
        btn.disabled = true;
        btn.textContent = 'TERMINATING...';
        try {
          const resp = await fetch(`/api/task/${taskId}/abort`, { method: 'POST' });
          const data = await resp.json();
          btn.dataset.state = 'initial';
          btn.classList.remove('confirming');
          btn.textContent = 'TERMINATED';
          if (onDone) onDone(data);
        } catch (err) {
          console.error('Failed to abort task:', err);
          btn.textContent = 'ABORT FAILED';
          setTimeout(() => {
            btn.disabled = false;
            btn.dataset.state = 'initial';
            btn.textContent = 'TERMINATE';
            btn.classList.remove('confirming');
          }, 2000);
        }
      }
    });
  }

  function renderBlueprintCard(title, output, taskId = 'task', scroll = true, container = null, badgePrefix = 'BLUEPRINT', dialText = 'COMPLETED') {
    const card = document.createElement('div');
    card.className = 'blueprint-card';
    card.id = `card_${taskId}`;

    const targetContainer = container || streamEl;

    const header = document.createElement('div');
    header.className = 'blueprint-header';
    header.innerHTML = `
      <div class="blueprint-title">
        <span class="blueprint-badge">▲</span>
        <span class="blueprint-title-text">${escapeHtml(badgePrefix)}: ${escapeHtml(title)}</span>
      </div>
      <div class="blueprint-meta">
        <span class="blueprint-dial">${escapeHtml(dialText)}</span>
        <span class="fold-indicator">▼</span>
      </div>
    `;

    const body = document.createElement('div');
    body.className = 'blueprint-body';
    const pre = document.createElement('pre');
    pre.innerHTML = formatBlueprintTerminalOutput(output);
    body.appendChild(pre);

    const controls = document.createElement('div');
    controls.className = 'blueprint-controls';
    controls.innerHTML = `
      <div class="steer-input-row">
        <textarea class="steer-input" rows="1" placeholder="Inject direction to George (click to expand multiline guidance)... [Enter to inject]"></textarea>
      </div>
      <div class="steer-actions-row">
        <div class="steer-actions-left">
          <button class="tactile-btn accent steer-btn" title="Inject operator steering directly into George's reasoning stream">INJECT GUIDANCE</button>
        </div>
        <div class="steer-actions-right">
          <button class="tactile-btn warn pause-btn" title="Pause execution loop">PAUSE</button>
          <button class="tactile-btn resume-btn" style="display:none;" title="Resume execution loop">RESUME</button>
          <button class="tactile-btn danger terminate-btn" data-state="initial" title="Terminate process and clean up sandbox">TERMINATE</button>
        </div>
      </div>
    `;

    header.addEventListener('click', () => {
      body.style.display = body.style.display === 'none' ? 'block' : 'none';
      controls.style.display = controls.style.display === 'none' ? 'flex' : 'none';
      const ind = header.querySelector('.fold-indicator');
      if (ind) ind.textContent = body.style.display === 'none' ? '▲' : '▼';
    });

    // Wire Steering
    const steerInput = controls.querySelector('.steer-input');
    const steerBtn = controls.querySelector('.steer-btn');
    const pauseBtn = controls.querySelector('.pause-btn');
    const resumeBtn = controls.querySelector('.resume-btn');
    const terminateBtn = controls.querySelector('.terminate-btn');

    steerInput.addEventListener('input', () => {
      steerInput.style.height = 'auto';
      steerInput.style.height = Math.min(160, Math.max(28, steerInput.scrollHeight)) + 'px';
    });

    steerInput.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        steerBtn.click();
      }
    });

    steerBtn.addEventListener('click', async () => {
      const guidance = steerInput.value.trim();
      if (!guidance) return;
      steerInput.value = '';
      steerInput.style.height = '';
      try {
        await fetch(`/api/task/${taskId}/inject`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ guidance })
        });
        pre.textContent += `\n[Operator Injected]: ${guidance}\n`;
        if (scroll) scrollToLatest(pre);
      } catch (e) {
        console.warn('Steer failed:', e);
      }
    });

    pauseBtn.addEventListener('click', async () => {
      try {
        await fetch(`/api/task/${taskId}/pause`, { method: 'POST' });
        pauseBtn.style.display = 'none';
        resumeBtn.style.display = 'inline-block';
        card.updateDial('PAUSED');
      } catch (e) {}
    });

    resumeBtn.addEventListener('click', async () => {
      try {
        await fetch(`/api/task/${taskId}/resume`, { method: 'POST' });
        resumeBtn.style.display = 'none';
        pauseBtn.style.display = 'inline-block';
        card.updateDial('ACTIVE');
      } catch (e) {}
    });

    wireDoubleConfirmTerminate(terminateBtn, taskId, () => {
      pre.textContent += `\n[Process Terminated]: Sandbox and process tree cleaned up.\n`;
      pauseBtn.style.display = 'none';
      resumeBtn.style.display = 'none';
      card.updateDial('ABORTED');
      pollHeartbeat();
    });

    card.appendChild(header);
    card.appendChild(body);
    card.appendChild(controls);
    if (targetContainer) targetContainer.appendChild(card);
    if (scroll) scrollToLatest(pre);

    pre._autoScrollPinned = true;
    pre.addEventListener('scroll', () => {
      const dist = pre.scrollHeight - pre.scrollTop - pre.clientHeight;
      pre._autoScrollPinned = dist <= 20;
    }, { passive: true });
    pre.addEventListener('wheel', (e) => {
      if (e.deltaY < 0) pre._autoScrollPinned = false;
    }, { passive: true });

    // Dynamic helpers
    card.updateDial = (text) => {
      const dial = header.querySelector('.blueprint-dial');
      if (dial) dial.textContent = text;
    };
    card.appendLog = (line) => {
      const wasPinned = pre._autoScrollPinned !== false;
      const prevScrollTop = pre.scrollTop;
      if (!pre._thoughtState) pre._thoughtState = { inThought: false };
      appendLogLineToStream(pre, line, pre._thoughtState);
      if (scroll) {
        if (wasPinned) {
          scrollToLatest(pre);
        } else {
          pre.scrollTop = prevScrollTop;
        }
      }
    };
    card.setLog = (text) => {
      if (!pre._thoughtState) pre._thoughtState = { inThought: false };
      renderLogBatchToStream(pre, text, pre._thoughtState);
      if (scroll && pre._autoScrollPinned !== false) scrollToLatest(pre);
    };
    card.getLog = () => pre.textContent;

    return card;
  }

  // --- Dispatch Prompt / Command ---
  async function dispatchPrompt() {
    const text = promptInput.value.trim();
    if (!text) return;

    promptInput.value = '';
    promptInput.style.height = 'auto';

    renderUserBubble(text, true);

    const isCommand = text.startsWith('/');
    const isTaskMode = activeChatMode === 'agentic' || activeChatMode === 'plan-task' || isCommand;

    let liveBubble = null;
    let taskCard = null;
    let es = null;
    const taskId = (activeChatMode === 'plan-task' ? 'plan_' : (activeChatMode === 'agentic' ? 'agentic_' : 'cmd_')) + Math.floor(Date.now() / 1000);

    if (isTaskMode) {
      const badge = activeChatMode === 'plan-task' ? 'PLANNING TASK' : (activeChatMode === 'agentic' ? 'AGENTIC TASK' : 'BLUEPRINT');
      const initialPhase = activeChatMode === 'plan-task' ? 'PLANNING' : 'RUNNING';
      taskCard = renderBlueprintCard(
        text,
        `[TASK INITIALIZED]: ${text}\n[MODE]: ${activeChatMode.toUpperCase()}\n[STATUS]: Generating reasoning & internal monologue...\n`,
        taskId,
        true,
        null,
        badge,
        initialPhase
      );

      // Register immediately in client task map so the rail tile renders instantly
      persistentTaskMap.set(taskId, {
        id: taskId,
        type: activeChatMode === 'plan-task' ? 'plan' : (activeChatMode === 'agentic' ? 'agentic' : 'command'),
        summary: (activeChatMode === 'agentic' ? 'Agentic: ' : (activeChatMode === 'plan-task' ? 'Plan: ' : 'Cmd: ')) + text,
        phase: 'Running',
        done: false,
        paused: false,
        path: `.sandboxes/${taskId}`,
        lastSeen: Date.now()
      });
      renderAutonomicTaskBay(Array.from(persistentTaskMap.values()));

      // Trigger heartbeat so task pill appears in autonomic task rail
      setTimeout(pollHeartbeat, 250);

      // Connect live SSE trajectory stream
      try {
        es = new EventSource(`/api/stream/task/${encodeURIComponent(taskId)}?tail=true`);
        es.addEventListener('log', (e) => {
          if (e.data && taskCard) taskCard.appendLog(e.data);
          if (expandedTaskId === taskId && autonomicExpandedStage && !window._autonomicEventSource) {
            const curStream = autonomicExpandedStage.querySelector('.expanded-log-stream');
            if (curStream && e.data) {
              if (curStream.dataset.renderedPlaceholder) {
                curStream.innerHTML = '';
                delete curStream.dataset.renderedPlaceholder;
              }
              const last = curStream.dataset.lastLogs || '';
              if (!last.endsWith(e.data)) {
                appendLogLineToStream(curStream, e.data, curStream._thoughtState);
                curStream.dataset.lastLogs = (last ? last + '\n' : '') + e.data;
              }
            }
          }
          if (persistentTaskMap.has(taskId)) {
            const pt = persistentTaskMap.get(taskId);
            if (!pt.content || !pt.content.endsWith(e.data)) {
              pt.content = (pt.content ? pt.content + '\n' : '') + e.data;
            }
          }
        });
        es.addEventListener('phase', (e) => {
          if (e.data && taskCard) taskCard.updateDial(e.data.toUpperCase());
          if (persistentTaskMap.has(taskId)) {
            persistentTaskMap.get(taskId).phase = e.data;
            renderAutonomicTaskBay(Array.from(persistentTaskMap.values()));
          }
        });
        es.addEventListener('done', () => {
          if (es) { es.close(); es = null; }
          if (taskCard) taskCard.updateDial('COMPLETED');
          if (persistentTaskMap.has(taskId)) {
            const pt = persistentTaskMap.get(taskId);
            pt.phase = 'Completed';
            pt.done = true;
            pt.lastSeen = Date.now();
            renderAutonomicTaskBay(Array.from(persistentTaskMap.values()));
          }
        });
      } catch (e) {
        console.warn('Task stream error:', e);
      }
    } else {
      liveBubble = renderAssistantBubble('George is reflecting...', true);
    }

    try {
      const resp = await fetch('/api/chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ prompt: text, mode: activeChatMode, task_id: taskId })
      });

      if (es) { es.close(); es = null; }

      if (resp.ok) {
        const data = await resp.json();
        if (persistentTaskMap.has(taskId)) {
          const pt = persistentTaskMap.get(taskId);
          pt.phase = 'Completed';
          pt.done = true;
          if (data.reply) pt.content = data.reply;
          pt.lastSeen = Date.now();
          renderAutonomicTaskBay(Array.from(persistentTaskMap.values()));
        }
        if (isTaskMode) {
          if (taskCard) {
            taskCard.updateDial('COMPLETED');
            if (data.reply && (!taskCard.getLog() || taskCard.getLog().length < 80)) {
              taskCard.setLog(data.reply);
            }
          }
        } else {
          if (liveBubble) {
            streamTextIntoBubble(liveBubble, data.reply || 'Task complete.', currentPacing);
          } else {
            const b = renderAssistantBubble('', true);
            streamTextIntoBubble(b, data.reply || 'Task complete.', currentPacing);
          }
        }
      } else {
        const errText = await resp.text();
        if (persistentTaskMap.has(taskId)) {
          const pt = persistentTaskMap.get(taskId);
          pt.phase = 'Error';
          pt.done = true;
          renderAutonomicTaskBay(Array.from(persistentTaskMap.values()));
        }
        if (taskCard) {
          taskCard.updateDial('ERROR');
          taskCard.appendLog(`\n[ERROR]: ${errText}`);
        } else if (liveBubble) {
          liveBubble.textContent = `Error: ${errText}`;
        }
      }
    } catch (err) {
      if (es) { es.close(); es = null; }
      if (taskCard) {
        taskCard.updateDial('ERROR');
        taskCard.appendLog(`\n[Network Error]: ${err.message}`);
      } else if (liveBubble) {
        liveBubble.textContent = `Network error: ${err.message}`;
      }
    }
  }

  function isTaskActive(t) {
    if (!t) return false;
    if (t.done) return false;
    if (t.pid_alive === false && !t.is_subagent) return false;
    const p = (t.phase || '').toLowerCase();
    if (p === 'completed' || p === 'complete' || p === 'done' || p === 'culled' || p === 'orphaned' || p === 'failed' || p === 'stopped' || p === 'paused_blocked') return false;
    if (p.includes('complete') || p.includes('dossier generated') || p.includes('finished')) return false;
    return true;
  }

  // --- 2-Second Heartbeat Poller (GPU & Tasks) ---
  async function pollHeartbeat() {
    try {
      // 1. Status & GPU Telemetry
      const statusResp = await fetch('/api/status');
      if (statusResp.ok) {
        const data = await statusResp.json();
        if (data.gpus && data.gpus.length > 0) {
          const clusterEl = document.getElementById('hdrGpuCluster');
          if (clusterEl) {
            clusterEl.innerHTML = data.gpus.map(g => `
              <span class="telemetry-chip gpu-chip">[GPU ${g.index}] ${escapeHtml(g.name.replace('NVIDIA GeForce ', ''))}</span>
              <span class="telemetry-chip vram-chip">${(g.vram_used_mb / 1024).toFixed(1)}/${(g.vram_total_mb / 1024).toFixed(1)}GB</span>
              <span class="telemetry-chip temp-chip">${g.temp_c}°C</span>
              <span class="telemetry-chip power-chip">${Math.round(parseFloat(g.power_w))}W</span>
            `).join('<span class="telemetry-chip" style="opacity:0.35">|</span>');
          }

          const rack = document.getElementById('gpuRack');
          if (rack) {
            rack.innerHTML = data.gpus.map(g => `
              <div class="bay-card">
                <div class="bay-header">
                  <span class="bay-name">${escapeHtml(g.name)} (GPU ${g.index})</span>
                  <span class="bay-badge">${g.index === 0 ? 'LOCAL GPU' : `LOCAL GPU ${g.index}`}</span>
                </div>
                <div class="bay-metrics">
                  <div class="metric-item">
                    <span class="m-label">VRAM</span>
                    <span class="m-val">${(g.vram_used_mb / 1024).toFixed(1)} / ${(g.vram_total_mb / 1024).toFixed(1)} GB</span>
                  </div>
                  <div class="metric-item">
                    <span class="m-label">POWER</span>
                    <span class="m-val">${g.power_w} W</span>
                  </div>
                  <div class="metric-item">
                    <span class="m-label">TEMP</span>
                    <span class="m-val">${g.temp_c} °C</span>
                  </div>
                </div>
              </div>
            `).join('');
          }
        }

        if (data.nodes) {
          renderNodeList(data.nodes);
        }

        if (typeof data.game_mode !== 'undefined') {
          updateGameModeUI(data.game_mode, data.inference_container_status);
        }
      }

      // 2. Autonomic Task Bay & Swarm Telemetry
      const tasksResp = await fetch('/api/tasks');
      if (tasksResp.ok) {
        const incomingTasks = await tasksResp.json();
        if (Array.isArray(incomingTasks)) {
          const now = Date.now();
          const incomingIds = new Set(incomingTasks.map(t => t.id));

          incomingTasks.forEach(t => {
            const existing = persistentTaskMap.get(t.id) || {};
            persistentTaskMap.set(t.id, {
              ...existing,
              ...t,
              lastSeen: now,
            });
          });

          // Mark missing tasks as completed rather than dropping them abruptly
          persistentTaskMap.forEach((task, id) => {
            if (!incomingIds.has(id)) {
              if (task.phase === 'Running' || task.phase === 'Active') {
                task.phase = 'Completed';
              }
              task.done = true;
              // Retain completed tasks for 45s for operator inspection
              if (now - (task.lastSeen || now) > 45000) {
                persistentTaskMap.delete(id);
              }
            } else if (!isTaskActive(task) && (now - (task.lastSeen || now) > 45000)) {
              persistentTaskMap.delete(id);
            }
          });
        }

        // Sort: running/active first, then most recently active
        const allTasks = Array.from(persistentTaskMap.values()).sort((a, b) => {
          const aActive = isTaskActive(a) ? 1 : 0;
          const bActive = isTaskActive(b) ? 1 : 0;
          if (aActive !== bActive) return bActive - aActive;
          return (b.lastSeen || 0) - (a.lastSeen || 0);
        });

        renderAutonomicTaskBay(allTasks);
      }

      // 3. SSH Tunnel Telemetry
      if (!window._lastTunnelPoll || Date.now() - window._lastTunnelPoll > 6000) {
        window._lastTunnelPoll = Date.now();
        fetchTunnelStatus();
      }

      // 4. Event Bus Telemetry
      if (!window._lastEventBusPoll || Date.now() - window._lastEventBusPoll > 3000) {
        window._lastEventBusPoll = Date.now();
        loadEventBusStatus();
      }
    } catch (e) {
      console.warn('Heartbeat poller warning:', e);
    }
  }

  const fetchStatus = pollHeartbeat;

  // --- Compute Node & Hardware Ladder Renderer ---
  function renderNodeList(nodes) {
    const listEl = document.getElementById('nodeList');
    if (!listEl || !nodes) return;
    listEl.innerHTML = nodes.map(n => {
      const isOnline = Boolean(n.active || n.status === 'online');
      const statusClass = isOnline ? 'success' : (n.enabled ? 'failed' : 'idle');
      const statusText = isOnline ? 'ONLINE' : (n.enabled ? 'OFFLINE' : 'STANDBY');
      const isTunnelNode = (n.path === 'tunnel');
      return `
        <div class="node-row ${statusClass}">
          <div class="node-meta">
            <div style="display: flex; align-items: center; gap: 6px;">
              <span class="bay-badge">${escapeHtml(n.tier || 'TIER')}</span>
              <span class="node-name">${escapeHtml(n.name)}</span>
              ${isTunnelNode ? `<span class="bay-badge" style="font-size: 8px; border-color: var(--accent); color: var(--accent);">SSH TUNNEL</span>` : ''}
            </div>
            <div class="node-url">${escapeHtml(n.hardware || '')} · <span style="color: var(--accent); font-weight: 600;">${escapeHtml(n.model || '')}</span>${n.live_details ? ` <span style="font-size: 10px; color: var(--text-muted); font-family: var(--font-mono);">(${escapeHtml(n.live_details)})</span>` : ''}</div>
            <div class="node-url" style="font-family: var(--font-mono); opacity: 0.85;">${escapeHtml(n.url)} [ctx ${escapeHtml(n.context || 'unset')}]</div>
          </div>
          <div style="display: flex; flex-direction: column; align-items: flex-end; gap: 4px;">
            <span class="cron-status-pill ${statusClass}">${statusText}</span>
            <div style="display: flex; gap: 4px;">
              ${isTunnelNode ? `<button class="mini-action re-tunnel-btn" title="Re-establish SSH ProxyJump tunnel">TUNNEL</button>` : ''}
              <button class="mini-action probe-node-btn" 
                data-url="${escapeHtml(n.url)}" 
                data-tier="${escapeHtml(n.tier || '')}"
                data-name="${escapeHtml(n.name || '')}"
                data-model="${escapeHtml(n.model || '')}"
                data-context="${escapeHtml(n.context || 8192)}"
                data-hardware="${escapeHtml(n.hardware || '')}"
                data-enabled="${n.enabled !== false}">PROBE / STAGE</button>
            </div>
          </div>
        </div>
      `;
    }).join('');

    listEl.querySelectorAll('.probe-node-btn').forEach(btn => {
      btn.addEventListener('click', () => {
        const url = btn.getAttribute('data-url') || '';
        const tier = btn.getAttribute('data-tier') || '';
        const name = btn.getAttribute('data-name') || '';
        const model = btn.getAttribute('data-model') || '';
        const context = btn.getAttribute('data-context') || '8192';
        const hardware = btn.getAttribute('data-hardware') || '';
        const enabled = btn.getAttribute('data-enabled') !== 'false';

        const tierSelect = document.getElementById('newNodeTier');
        if (tierSelect) {
          if (tier.includes('3')) tierSelect.value = 'tier3';
          else if (tier.includes('1')) tierSelect.value = 'tier1';
          else if (tier.includes('2')) tierSelect.value = 'tier2';
          else if (tier.includes('0')) tierSelect.value = 'tier0';
        }

        const nameInput = document.getElementById('newNodeName');
        if (nameInput) nameInput.value = name;
        const modelInput = document.getElementById('newNodeModel');
        if (modelInput) modelInput.value = model;
        const ctxInput = document.getElementById('newNodeContext');
        if (ctxInput) ctxInput.value = context;
        const hwInput = document.getElementById('newNodeHardware');
        if (hwInput) hwInput.value = hardware;
        const urlInput = document.getElementById('newNodeUrl');
        if (urlInput) urlInput.value = url;
        const enInput = document.getElementById('newNodeEnabled');
        if (enInput) enInput.checked = enabled;

        const stageModel = document.getElementById('stageModelName');
        if (stageModel && !stageModel.value && model) stageModel.value = model;

        if (nodeModal) {
          nodeModal.classList.add('open');
        }
        const testBtn = document.getElementById('testNodeBtn');
        if (testBtn) testBtn.click();
      });
    });

    listEl.querySelectorAll('.re-tunnel-btn').forEach(btn => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation();
        btn.textContent = 'CONNECTING...';
        await fetch('/api/tunnel/connect', { method: 'POST' });
        btn.textContent = 'TUNNEL';
        fetchTunnelStatus();
        fetchStatus();
      });
    });
  }

  // --- SSH Tunnel Telemetry & Management ---
  async function fetchTunnelStatus() {
    const banner = document.getElementById('tunnelStatusBanner');
    const dot = document.getElementById('tunnelStatusDot');
    const desc = document.getElementById('tunnelStatusDesc');
    if (!banner || !desc) return;
    try {
      const resp = await fetch('/api/tunnel/status');
      if (resp.ok) {
        const data = await resp.json();
        const port = data.local_llamacpp_port || '?';
        if (data.connected) {
          banner.classList.remove('disconnected');
          if (dot) dot.classList.remove('disconnected');
          desc.textContent = `ONLINE (port ${port} active · ${data.jump_host ? `via ${data.jump_host}` : 'direct'})`;
        } else {
          banner.classList.add('disconnected');
          if (dot) dot.classList.add('disconnected');
          desc.textContent = data.target
            ? `DISCONNECTED (port ${port} unreachable · target: ${data.target})`
            : 'NOT CONFIGURED (no REMOTE_SSH_TARGET in remote.conf)';
        }
      }
    } catch (e) {
      console.warn('Failed to fetch tunnel status:', e);
    }
  }

  function formatTimeAgo(epochSecs) {
    if (!epochSecs || epochSecs <= 0) return 'Never';
    const now = Math.floor(Date.now() / 1000);
    const diff = Math.max(0, now - epochSecs);
    if (diff < 60) return `${diff}s ago`;
    if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
    if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
    return `${Math.floor(diff / 86400)}d ago`;
  }

  // --- Autonomic Task Bay Renderer (Mutual-Exclusion Accordion) ---
  function renderAutonomicTaskBay(tasks) {
    if (!autonomicTaskBay || !autonomicBayRail) return;
    cachedTasks = tasks || [];

    // Filter up to 12 live/recent tasks for 2x6 dynamic tile grid display
    const liveTasks = cachedTasks.slice(0, 12);

    if (liveTasks.length === 0) {
      autonomicTaskBay.style.display = 'none';
      if (autonomicExpandedStage) {
        autonomicExpandedStage.style.display = 'none';
        autonomicExpandedStage.dataset.activeTaskId = '';
      }
      expandedTaskId = null;
      return;
    }

    autonomicTaskBay.style.display = 'block';
    if (bayActiveCount) {
      const activeCount = liveTasks.filter(t => isTaskActive(t)).length;
      bayActiveCount.textContent = `${activeCount} Active · ${liveTasks.length} Tracked`;
    }

    // Render collapsed tiles in grid (update in place if same tasks to prevent jitter)
    const currentPillIds = Array.from(autonomicBayRail.children).map(c => c.dataset.taskId).join(',');
    const newPillIds = liveTasks.map(t => t.id).join(',');

    if (currentPillIds === newPillIds && currentPillIds !== '') {
      Array.from(autonomicBayRail.children).forEach((pill, idx) => {
        const t = liveTasks[idx];
        const isExpanded = expandedTaskId === t.id;
        const isCopilot = t.type === 'copilot';
        const isDone = !isTaskActive(t);
        pill.className = `bay-tile${isExpanded ? ' expanded' : ''}${isCopilot ? ' copilot-pill' : ''}${isDone ? ' completed' : ''}`;
        const phaseSpan = pill.querySelector('.bay-pill-phase');
        if (phaseSpan) phaseSpan.textContent = `[${t.phase || 'Active'}]`;
        const summarySpan = pill.querySelector('.bay-pill-summary');
        if (summarySpan) {
          const s = t.summary || t.meta_cmd || t.id;
          summarySpan.textContent = s;
          summarySpan.title = s;
        }
        const indSpan = pill.querySelector('.bay-pill-indicator');
        if (indSpan) indSpan.textContent = isExpanded ? '▲' : '▼';
      });
    } else {
      autonomicBayRail.innerHTML = '';
      liveTasks.forEach(t => {
        const isExpanded = expandedTaskId === t.id;
        const taskType = (t.type || t.task_type || 'task').toLowerCase();
        const isCopilot = taskType === 'copilot';
        const isDone = !isTaskActive(t);
        const pill = document.createElement('div');
        pill.dataset.taskId = t.id;
        pill.className = `bay-tile${isExpanded ? ' expanded' : ''}${isCopilot ? ' copilot-pill' : ''}${isDone ? ' completed' : ''}`;
        const subCount = t.subtask_count || t.subagent_count || (t.subtasks ? t.subtasks.length : (t.subagents ? t.subagents.length : 0));
        const taskSummary = t.summary || t.meta_cmd || t.id;
        const ctxTok = t.context_tokens ? (t.context_tokens / 1000).toFixed(0) + 'k' : '';
        const compPct = t.compaction_pct || 0;
        const ctxClass = compPct > 80 ? 'ctx-red' : (compPct > 60 ? 'ctx-yellow' : 'ctx-green');
        pill.innerHTML = `
          <div class="bay-tile-top">
            <span class="bay-pill-type ${escapeHtml(taskType)}">${escapeHtml(taskType.toUpperCase())}</span>
            <span class="bay-pill-phase">[${escapeHtml(t.phase || 'Active')}]</span>
            ${ctxTok ? `<span class="context-pill ${ctxClass}" title="Active Context: ${ctxTok} tokens (${compPct}% to compaction threshold)">CTX: ${ctxTok} (${compPct}%)</span>` : ''}
            <span class="bay-pill-indicator">${isExpanded ? '▲' : '▼'}</span>
          </div>
          <div class="bay-tile-bottom">
            <span class="bay-pill-summary" title="${escapeHtml(taskSummary)}">${escapeHtml(taskSummary)}</span>
            ${subCount > 0 ? `<span class="subagent-badge" title="${subCount} nested sub-task(s)">⑂ ${subCount} subtask${subCount > 1 ? 's' : ''}</span>` : ''}
          </div>
        `;

        pill.addEventListener('click', () => {
          window._currentViewingSubtaskId = null;
          if (expandedTaskId === t.id) {
            expandedTaskId = null; // collapse
            if (window._autonomicEventSource) {
              window._autonomicEventSource.close();
              window._autonomicEventSource = null;
            }
            if (autonomicExpandedStage) autonomicExpandedStage.dataset.activeTaskId = '';
          } else {
            expandedTaskId = t.id; // expand this one, collapse others
          }
          renderAutonomicTaskBay(cachedTasks);
        });

        autonomicBayRail.appendChild(pill);
      });
    }

    // Render expanded stage if one is selected (strictly single expansion)
    if (expandedTaskId && autonomicExpandedStage) {
      const activeTask = liveTasks.find(t => t.id === expandedTaskId);
      if (activeTask) {
        autonomicExpandedStage.style.display = 'flex';

        // Check if stage is ALREADY rendered for this activeTask
        if (autonomicExpandedStage.dataset.activeTaskId === activeTask.id) {
          const phaseBadge = autonomicExpandedStage.querySelector('.task-phase-badge') || autonomicExpandedStage.querySelector('.task-phase-text');
          if (phaseBadge) phaseBadge.textContent = `[${activeTask.phase || 'Active'}]`;

          const stepEl = autonomicExpandedStage.querySelector('.expanded-header-step-row');
          const stepTextEl = autonomicExpandedStage.querySelector('.expanded-header-step-row .step-text');
          if (stepTextEl) {
            const curStep = activeTask.active_step || (activeTask.phase && activeTask.phase.includes('Step ') ? activeTask.phase : 'Active ReAct Execution Pipeline');
            stepTextEl.textContent = curStep;
            if (stepEl) stepEl.title = curStep;
          }

          const summaryEl = autonomicExpandedStage.querySelector('.expanded-task-summary');
          if (summaryEl && activeTask.summary) {
            summaryEl.textContent = activeTask.summary;
            summaryEl.title = activeTask.summary;
          }

          const pauseBtn = autonomicExpandedStage.querySelector('.pause-btn');
          const resumeBtn = autonomicExpandedStage.querySelector('.resume-btn');
          if (pauseBtn && resumeBtn) {
            if (activeTask.phase === 'Paused') {
              pauseBtn.style.display = 'none';
              resumeBtn.style.display = 'inline-block';
            } else if (activeTask.phase === 'Running' || activeTask.phase === 'Active') {
              resumeBtn.style.display = 'none';
              pauseBtn.style.display = 'inline-block';
            }
          }

          // If sys_cron, update status matrix in place
          if (activeTask.type === 'sys_cron' && activeTask.cron_jobs) {
            const matrix = autonomicExpandedStage.querySelector('.sys-cron-matrix');
            if (matrix) {
              matrix.innerHTML = activeTask.cron_jobs.map(job => `
                <div class="sys-cron-item ${job.active ? 'active' : ''} ${job.exit_code !== 0 ? 'error' : ''}">
                  <div class="sys-cron-item-header">
                    <span class="sys-cron-dot"></span>
                    <span class="sys-cron-label" title="${escapeHtml(job.label || job.id)}">${escapeHtml(job.label || job.id)}</span>
                    <span class="sys-cron-phase" title="${escapeHtml(job.phase || (job.active ? 'Running' : 'Completed'))}">${escapeHtml(job.phase || (job.active ? 'Running' : 'Completed'))}</span>
                  </div>
                  <div class="sys-cron-item-meta">
                    <span>Last: ${job.last_run > 0 ? formatTimeAgo(job.last_run) : 'Pending'}</span>
                    <span class="sys-cron-exit ${job.exit_code === 0 ? 'ok' : 'err'}">${job.exit_code === 0 ? '✓ 0' : '✗ ' + job.exit_code}</span>
                  </div>
                </div>
              `).join('');
            }
          }

          // If usr_cron, update status scroll-box in place
          if (activeTask.type === 'usr_cron' && activeTask.cron_jobs) {
            const scrollBox = autonomicExpandedStage.querySelector('.usr-cron-scroll-box');
            const selectEl = autonomicExpandedStage.querySelector('.usr-cron-dropdown-select');
            const selectedFilter = selectEl ? selectEl.value : 'all';
            if (scrollBox) {
              const filteredJobs = selectedFilter === 'all'
                ? activeTask.cron_jobs
                : activeTask.cron_jobs.filter(j => j.id === selectedFilter);
              scrollBox.innerHTML = filteredJobs.map(job => `
                <div class="usr-cron-item ${job.active ? 'active' : ''} ${job.exit_code !== 0 ? 'error' : ''}" data-job-id="${escapeHtml(job.id)}">
                  <div class="usr-cron-item-header">
                    <span class="usr-cron-dot"></span>
                    <span class="usr-cron-label" title="${escapeHtml(job.label || job.id)}">${escapeHtml(job.label || job.id)}</span>
                    <span class="usr-cron-phase" title="${escapeHtml(job.phase || (job.active ? 'Running' : 'Completed'))}">${escapeHtml(job.phase || (job.active ? 'Running' : 'Completed'))}</span>
                  </div>
                  <div class="usr-cron-item-meta">
                    <span>${job.interval || 60}s · Last: ${job.last_run > 0 ? formatTimeAgo(job.last_run) : 'Pending'}</span>
                    <span class="usr-cron-exit ${job.exit_code === 0 ? 'ok' : 'err'}">${job.exit_code === 0 ? '✓ 0' : '✗ ' + job.exit_code}</span>
                  </div>
                </div>
              `).join('');
            }
          }

          // If event_bus, update matrix in place
          if (activeTask.type === 'event_bus' && activeTask.reactors) {
            const ebMatrix = autonomicExpandedStage.querySelector('.event-bus-matrix');
            if (ebMatrix) {
              ebMatrix.innerHTML = activeTask.reactors.map(r => `
                <div class="event-bus-item ${r.enabled ? 'active' : 'disabled'}">
                  <div class="event-bus-item-header">
                    <span class="event-bus-dot"></span>
                    <span class="event-bus-id" title="${escapeHtml(r.id)}">${escapeHtml(r.id)}</span>
                    <span class="event-bus-type" title="${escapeHtml(r.event_type)}">${escapeHtml(r.event_type)}</span>
                  </div>
                  <div class="event-bus-pattern" title="${escapeHtml(r.pattern || '*')}">
                    <span class="event-bus-label-dim">Match:</span> <code>${escapeHtml(r.pattern || '*')}</code>
                  </div>
                  <div class="event-bus-item-meta">
                    <span>Debounce: ${r.debounce_secs || 0}s</span>
                    <span class="event-bus-status ${r.enabled ? 'ok' : 'err'}">${r.enabled ? 'ENABLED' : 'DISABLED'}</span>
                  </div>
                </div>
              `).join('');
            }
          }

          // Never wipe full trajectory with 5-line tail! Only fill if placeholder remains
          const stream = autonomicExpandedStage.querySelector('.expanded-log-stream');
          if (stream && stream.dataset.renderedPlaceholder === 'true') {
            const fallbackLogs = (activeTask.log_tail || []).join('\n') || activeTask.content || '';
            if (fallbackLogs) {
              stream.innerHTML = '';
              renderLogBatchToStream(stream, fallbackLogs, stream._thoughtState);
              stream.dataset.lastLogs = fallbackLogs;
              delete stream.dataset.renderedPlaceholder;
            }
          }

          // Periodic refresh of trajectory for running task if EventSource is not actively streaming
          if (stream && (!window._autonomicEventSource || activeTask.type === 'sys_cron' || activeTask.type === 'usr_cron' || activeTask.type === 'event_bus')) {
            const nowMs = Date.now();
            if (!stream._lastPollTime || nowMs - stream._lastPollTime > 2500) {
              stream._lastPollTime = nowMs;
              const pollId = window._currentViewingSubtaskId || activeTask.id;
              fetch(`/api/task/${encodeURIComponent(pollId)}/trajectory`)
                .then(r => r.ok ? r.json() : null)
                .then(data => {
                  if (data && data.trajectory && data.trajectory.trim().length > 0) {
                    const currentActiveId = window._currentViewingSubtaskId || autonomicExpandedStage.dataset.activeTaskId;
                    if (currentActiveId === pollId) {
                      const curLogs = stream.dataset.lastLogs || '';
                      if (curLogs !== data.trajectory) {
                        if (curLogs && data.trajectory.startsWith(curLogs)) {
                          const newPart = data.trajectory.slice(curLogs.length);
                          for (const line of newPart.split('\n')) {
                            if (line.trim().length > 0) {
                              appendLogLineToStream(stream, line, stream._thoughtState);
                            }
                          }
                        } else {
                          stream.innerHTML = '';
                          renderLogBatchToStream(stream, data.trajectory, stream._thoughtState);
                        }
                        stream.dataset.lastLogs = data.trajectory;
                        if (!window._currentViewingSubtaskId) {
                          activeTask.content = data.trajectory;
                        }
                        delete stream.dataset.renderedPlaceholder;
                        if (stream._autoScrollPinned !== false) {
                          requestAnimationFrame(() => {
                            stream.scrollTop = stream.scrollHeight;
                          });
                        }
                      }
                    }
                  }
                })
                .catch(() => {});
            }
          }

          return;
        }

        autonomicExpandedStage.dataset.activeTaskId = activeTask.id;
        autonomicExpandedStage.innerHTML = `
          <div class="expanded-card-header">
            <div class="expanded-header-left">
              <div class="expanded-header-title-row">
                <span class="expanded-card-badge">▲</span>
                <span class="expanded-task-summary" title="${escapeHtml(activeTask.summary || activeTask.id)}">${escapeHtml(activeTask.summary || activeTask.id)}</span>
                <span class="task-phase-badge" title="Current execution phase">[${escapeHtml(activeTask.phase || 'Active')}]</span>
              </div>
              ${activeTask.type !== 'sys_cron' && activeTask.type !== 'usr_cron' ? `
                <div class="expanded-header-step-row" title="${escapeHtml(activeTask.active_step || (activeTask.phase && activeTask.phase.includes('Step ') ? activeTask.phase : 'Active ReAct Execution Pipeline'))}">
                  <span class="step-chip">STEP</span>
                  <span class="step-text">${escapeHtml(activeTask.active_step || (activeTask.phase && activeTask.phase.includes('Step ') ? activeTask.phase : 'Active ReAct Execution Pipeline'))}</span>
                </div>
              ` : ''}
            </div>
            <div class="expanded-header-actions">
              <button class="tactile-btn mini-collapse-btn">▲ COLLAPSE</button>
            </div>
          </div>
          ${activeTask.type === 'sys_cron' && activeTask.cron_jobs ? `
            <div class="sys-cron-matrix">
              ${activeTask.cron_jobs.map(job => `
                <div class="sys-cron-item ${job.active ? 'active' : ''} ${job.exit_code !== 0 ? 'error' : ''}">
                  <div class="sys-cron-item-header">
                    <span class="sys-cron-dot"></span>
                    <span class="sys-cron-label" title="${escapeHtml(job.label || job.id)}">${escapeHtml(job.label || job.id)}</span>
                    <span class="sys-cron-phase" title="${escapeHtml(job.phase || (job.active ? 'Running' : 'Completed'))}">${escapeHtml(job.phase || (job.active ? 'Running' : 'Completed'))}</span>
                  </div>
                  <div class="sys-cron-item-meta">
                    <span>Last: ${job.last_run > 0 ? formatTimeAgo(job.last_run) : 'Pending'}</span>
                    <span class="sys-cron-exit ${job.exit_code === 0 ? 'ok' : 'err'}">${job.exit_code === 0 ? '✓ 0' : '✗ ' + job.exit_code}</span>
                  </div>
                </div>
              `).join('')}
            </div>
          ` : ''}
          ${activeTask.type === 'usr_cron' && activeTask.cron_jobs ? `
            <div class="usr-cron-container">
              <div class="usr-cron-toolbar">
                <div class="usr-cron-toolbar-left">
                  <span class="usr-cron-toolbar-title">User Cron Sentinels (${activeTask.cron_jobs.length})</span>
                  <select class="usr-cron-dropdown-select" title="Filter to a specific cron job">
                    <option value="all">-- All User Cron Jobs (${activeTask.cron_jobs.length}) --</option>
                    ${activeTask.cron_jobs.map(j => `
                      <option value="${escapeHtml(j.id)}">${escapeHtml(j.label || j.id)} (${j.interval || 60}s)</option>
                    `).join('')}
                  </select>
                </div>
                <div class="usr-cron-toolbar-right" style="font-size: 11px; color: var(--text-dim, #94a3b8);">
                  <span>Autonomic Background Execution</span>
                </div>
              </div>
              <div class="usr-cron-scroll-box">
                ${activeTask.cron_jobs.map(job => `
                  <div class="usr-cron-item ${job.active ? 'active' : ''} ${job.exit_code !== 0 ? 'error' : ''}" data-job-id="${escapeHtml(job.id)}">
                    <div class="usr-cron-item-header">
                      <span class="usr-cron-dot"></span>
                      <span class="usr-cron-label" title="${escapeHtml(job.label || job.id)}">${escapeHtml(job.label || job.id)}</span>
                      <span class="usr-cron-phase" title="${escapeHtml(job.phase || (job.active ? 'Running' : 'Completed'))}">${escapeHtml(job.phase || (job.active ? 'Running' : 'Completed'))}</span>
                    </div>
                    <div class="usr-cron-item-meta">
                      <span>${job.interval || 60}s · Last: ${job.last_run > 0 ? formatTimeAgo(job.last_run) : 'Pending'}</span>
                      <span class="usr-cron-exit ${job.exit_code === 0 ? 'ok' : 'err'}">${job.exit_code === 0 ? '✓ 0' : '✗ ' + job.exit_code}</span>
                    </div>
                  </div>
                `).join('')}
              </div>
            </div>
          ` : ''}
          ${activeTask.type === 'event_bus' ? `
            <div class="event-bus-card-toolbar" style="display:flex; justify-content:space-between; align-items:center; margin-bottom:8px; padding:6px 10px; background:rgba(0,240,255,0.06); border:1px solid rgba(0,240,255,0.25); border-radius:4px;">
              <div style="display:flex; align-items:center; gap:8px;">
                <span class="daemon-status-dot ${activeTask.pid_alive ? '' : 'stopped'}" style="width:8px; height:8px; border-radius:50%; background:${activeTask.pid_alive ? '#00f0ff' : '#ff4444'}; box-shadow:0 0 8px ${activeTask.pid_alive ? '#00f0ff' : '#ff4444'}; display:inline-block;"></span>
                <span style="font-size:10px; font-weight:700; color:${activeTask.pid_alive ? '#00f0ff' : '#ff7777'};">DAEMON: ${activeTask.pid_alive ? 'ACTIVE' + (activeTask.pid ? ' (PID ' + activeTask.pid + ')' : '') : 'INACTIVE'}</span>
              </div>
              <div style="display:flex; gap:6px;">
                ${!activeTask.pid_alive ? `
                  <button class="tactile-btn accent" style="padding:2px 8px; font-size:9px;" onclick="event.stopPropagation(); startEventBusDaemon();">START DAEMON</button>
                ` : `
                  <button class="tactile-btn" style="padding:2px 8px; font-size:9px;" onclick="event.stopPropagation(); restartEventBusDaemon();">RESTART</button>
                  <button class="tactile-btn danger" style="padding:2px 8px; font-size:9px;" onclick="event.stopPropagation(); stopEventBusDaemon();">STOP</button>
                `}
              </div>
            </div>
          ` : ''}
          ${activeTask.type === 'event_bus' && activeTask.reactors ? `
            <div class="event-bus-matrix">
              ${activeTask.reactors.map(r => `
                <div class="event-bus-item ${r.enabled ? 'active' : 'disabled'}">
                  <div class="event-bus-item-header">
                    <span class="event-bus-dot"></span>
                    <span class="event-bus-id" title="${escapeHtml(r.id)}">${escapeHtml(r.id)}</span>
                    <span class="event-bus-type" title="${escapeHtml(r.event_type)}">${escapeHtml(r.event_type)}</span>
                  </div>
                  <div class="event-bus-pattern" title="${escapeHtml(r.pattern || '*')}">
                    <span class="event-bus-label-dim">Match:</span> <code>${escapeHtml(r.pattern || '*')}</code>
                  </div>
                  <div class="event-bus-item-meta">
                    <span>Debounce: ${r.debounce_secs || 0}s</span>
                    <span class="event-bus-status ${r.enabled ? 'ok' : 'err'}">${r.enabled ? 'ENABLED' : 'DISABLED'}</span>
                  </div>
                </div>
              `).join('')}
            </div>
          ` : ''}
          ${activeTask.subagents && activeTask.subagents.length > 0 ? `
            <div class="task-subagents-panel">
              <span style="font-size: 11px; font-weight: 700; color: #c084fc;">SUBAGENTS (⑂ ${activeTask.subagents.length}):</span>
              ${activeTask.subagents.map(sa => `
                <span class="subagent-chip" title="${escapeHtml(sa.objective || sa.id)}">${escapeHtml(sa.id)} [${escapeHtml(sa.status || 'RUNNING')}]</span>
              `).join('')}
            </div>
          ` : ''}
          ${activeTask.subtasks && activeTask.subtasks.length > 0 ? `
            <div class="nested-subtasks-panel">
              <div class="nested-subtasks-header">
                <div class="nested-subtasks-title">
                  <span class="nested-subtasks-icon">⑂</span>
                  <span>NESTED SUB-TASKS (${activeTask.subtasks.length})</span>
                </div>
                <span class="nested-subtasks-hint">Child processes & George REPL runs</span>
              </div>
              <div class="nested-subtasks-grid">
                ${activeTask.subtasks.map(st => {
                  const isSelected = window._currentViewingSubtaskId === st.id;
                  const isRunning = st.pid_alive && !st.done;
                  return `
                    <div class="nested-subtask-card ${isRunning ? 'running' : 'completed'} ${isSelected ? 'active-stream' : ''}" data-subtask-id="${escapeHtml(st.id)}">
                      <div class="nested-subtask-top">
                        <span class="nested-subtask-dot"></span>
                        <span class="nested-subtask-type">${escapeHtml((st.task_type || 'REPL').toUpperCase())}</span>
                        <span class="nested-subtask-pid">PID ${escapeHtml(String(st.pid || '—'))}</span>
                        <span class="nested-subtask-phase">[${escapeHtml(st.phase || (isRunning ? 'Running' : 'Done'))}]</span>
                      </div>
                      <div class="nested-subtask-summary" title="${escapeHtml(st.summary || st.meta_cmd || st.id)}">
                        ${escapeHtml(st.summary || st.meta_cmd || st.id)}
                      </div>
                      <div class="nested-subtask-footer">
                        <span class="nested-subtask-pid"></span>
                        <button class="tactile-btn mini-btn toggle-subtask-stream-btn ${isSelected ? 'selected' : ''}" data-subtask-id="${escapeHtml(st.id)}" type="button">
                          ${isSelected ? '✓ Streaming' : 'View Stream ↗'}
                        </button>
                      </div>
                    </div>
                  `;
                }).join('')}
              </div>
            </div>
          ` : ''}
          <div class="subtask-stream-banner" style="${window._currentViewingSubtaskId ? '' : 'display: none;'}">
            <span class="subtask-banner-text">⑂ Viewing Nested Sub-Task Stream: <strong>${escapeHtml(window._currentViewingSubtaskId || '')}</strong></span>
            <button class="tactile-btn mini-btn reset-parent-stream-btn" type="button">← Back to Parent Stream</button>
          </div>
          <div class="expanded-stream-wrap">
            <div class="expanded-log-stream"></div>
            <button class="stream-jump-btn" type="button" title="Jump to newest log">▼ Latest Logs</button>
          </div>
          <div class="expanded-controls">
            ${activeTask.type === 'sys_cron' || activeTask.type === 'usr_cron' || activeTask.type === 'event_bus' ? `
              <div class="expanded-steer-group" style="font-size: 11px; color: var(--text-muted); align-items: center;">
                <span>${activeTask.type === 'event_bus' ? 'Reactive Event Bus Daemon (PID ' + escapeHtml(String(activeTask.pid || 'Active')) + ') · Non-blocking FIFO IPC' : (activeTask.type === 'sys_cron' ? 'SYS Cron Daemon' : 'USR Cron Sentinels') + ' (PID ' + escapeHtml(String(activeTask.pid || 'Active')) + ') · Continuous Background Sweeps'}</span>
              </div>
              <div class="action-buttons">
                ${activeTask.type === 'event_bus' ? `
                  <button class="tactile-btn accent event-bus-restart-btn" style="padding: 4px 10px; font-size: 11px;" title="Restart George's Reactive Event Bus daemon">RESTART DAEMON</button>
                ` : `
                  <button class="tactile-btn accent cron-restart-btn" style="padding: 4px 10px; font-size: 11px;" title="Restart George's background cron daemon">RESTART DAEMON</button>
                `}
                <button class="tactile-btn mini-collapse-btn">CLOSE</button>
              </div>
            ` : `
              <div class="expanded-steer-group">
                <input type="text" class="expanded-steer-input" placeholder="Inject steer direction to this auto-task... (Enter to inject)">
                <button class="tactile-btn steer-btn">INJECT</button>
              </div>
              <div class="expanded-context-group">
                <div class="task-context-meter" title="Active conversation tokens vs auto-compaction threshold (75% / 98.3k tokens)">
                  <span class="ctx-meter-label">CTX:</span>
                  <span class="ctx-meter-val">${activeTask.context_tokens ? (activeTask.context_tokens / 1000).toFixed(1) + 'k' : '—'} / ${(activeTask.compaction_tokens ? (activeTask.compaction_tokens / 1000).toFixed(0) : '98')}k (${activeTask.compaction_pct || 0}%)</span>
                  <div class="ctx-progress-bar">
                    <div class="ctx-progress-fill ${activeTask.compaction_pct > 80 ? 'ctx-red' : (activeTask.compaction_pct > 60 ? 'ctx-yellow' : 'ctx-green')}" style="width: ${Math.min(100, activeTask.compaction_pct || 0)}%;"></div>
                  </div>
                </div>
              </div>
              <div class="action-buttons">
                <button class="tactile-btn compact-btn" title="Interrupt at next model turn and force context compaction">FORCE COMPACT</button>
                <button class="tactile-btn warn pause-btn">PAUSE</button>
                <button class="tactile-btn resume-btn" style="display:none;">RESUME</button>
                <button class="tactile-btn danger terminate-btn" data-state="initial">TERMINATE</button>
              </div>
            `}
          </div>
        `;

        const stream = autonomicExpandedStage.querySelector('.expanded-log-stream');
        const jumpBtn = autonomicExpandedStage.querySelector('.stream-jump-btn');

        if (stream) {
          stream._thoughtState = { inThought: false };
          stream._autoScrollPinned = true;

          const updateStreamScrollState = () => {
            const distFromBottom = stream.scrollHeight - stream.scrollTop - stream.clientHeight;
            if (distFromBottom <= 30) {
              stream._autoScrollPinned = true;
              if (jumpBtn) jumpBtn.classList.remove('visible');
            } else {
              stream._autoScrollPinned = false;
              if (jumpBtn) jumpBtn.classList.add('visible');
            }
          };

          stream.addEventListener('scroll', updateStreamScrollState, { passive: true });

          stream.addEventListener('wheel', (e) => {
            if (e.deltaY < 0) {
              stream._autoScrollPinned = false;
              if (jumpBtn) jumpBtn.classList.add('visible');
            } else if (e.deltaY > 0) {
              const distFromBottom = stream.scrollHeight - stream.scrollTop - stream.clientHeight;
              if (distFromBottom <= 30) {
                stream._autoScrollPinned = true;
                if (jumpBtn) jumpBtn.classList.remove('visible');
              }
            }
          }, { passive: true });

          let touchStartY = 0;
          stream.addEventListener('touchstart', (e) => {
            if (e.touches && e.touches[0]) touchStartY = e.touches[0].clientY;
          }, { passive: true });

          stream.addEventListener('touchmove', (e) => {
            if (e.touches && e.touches[0]) {
              const currentY = e.touches[0].clientY;
              if (currentY > touchStartY + 5) {
                stream._autoScrollPinned = false;
                if (jumpBtn) jumpBtn.classList.add('visible');
              }
            }
          }, { passive: true });

          if (jumpBtn) {
            jumpBtn.addEventListener('click', (ev) => {
              ev.preventDefault();
              ev.stopPropagation();
              stream._autoScrollPinned = true;
              stream.scrollTo({ top: stream.scrollHeight, behavior: 'smooth' });
              jumpBtn.classList.remove('visible');
            });
          }

          const connectTaskStream = (targetTask, isSubtask = false) => {
            if (window._autonomicEventSource) {
              window._autonomicEventSource.close();
              window._autonomicEventSource = null;
            }

            // Update banner
            const banner = autonomicExpandedStage.querySelector('.subtask-stream-banner');
            const bannerText = autonomicExpandedStage.querySelector('.subtask-banner-text');
            if (banner) {
              if (isSubtask) {
                banner.style.display = 'flex';
                if (bannerText) bannerText.innerHTML = `⑂ Viewing Sub-Task Stream: <strong>${escapeHtml(targetTask.id)}</strong> [${escapeHtml(targetTask.phase || 'Active')}]`;
              } else {
                banner.style.display = 'none';
              }
            }

            // Update card selection states
            autonomicExpandedStage.querySelectorAll('.nested-subtask-card').forEach(card => {
              const isTarget = isSubtask && card.dataset.subtaskId === targetTask.id;
              card.classList.toggle('active-stream', isTarget);
              const btn = card.querySelector('.toggle-subtask-stream-btn');
              if (btn) {
                btn.textContent = isTarget ? '✓ Streaming' : 'View Stream ↗';
                btn.classList.toggle('selected', isTarget);
              }
            });

            stream._thoughtState = { inThought: false };
            stream._autoScrollPinned = true;
            stream.innerHTML = '';
            stream.dataset.renderedPlaceholder = 'true';
            renderLogBatchToStream(stream, `Loading logs for ${escapeHtml(targetTask.id)}...`, stream._thoughtState);

            if (targetTask.content && targetTask.content.trim().length > 0) {
              stream.innerHTML = '';
              renderLogBatchToStream(stream, targetTask.content, stream._thoughtState);
              stream.dataset.lastLogs = targetTask.content;
              delete stream.dataset.renderedPlaceholder;
              requestAnimationFrame(() => {
                if (stream._autoScrollPinned !== false) stream.scrollTop = stream.scrollHeight;
              });
            }

            // Fetch full trajectory from server
            (async () => {
              const fetchIds = [targetTask.id];
              if (targetTask.task_id && targetTask.task_id !== targetTask.id) {
                fetchIds.push(targetTask.task_id);
              }
              if (targetTask.id && targetTask.id.startsWith('sub_sub_')) {
                fetchIds.push(targetTask.id.replace(/^sub_sub_/, 'sub_'));
              }

              for (const tId of fetchIds) {
                try {
                  const resp = await fetch(`/api/task/${encodeURIComponent(tId)}/trajectory`);
                  if (resp.ok) {
                    const data = await resp.json();
                    if (data && data.trajectory && data.trajectory.trim().length > 0) {
                      if (autonomicExpandedStage.dataset.activeTaskId === activeTask.id) {
                        stream.innerHTML = '';
                        renderLogBatchToStream(stream, data.trajectory, stream._thoughtState);
                        stream.dataset.lastLogs = data.trajectory;
                        delete stream.dataset.renderedPlaceholder;
                        targetTask.content = data.trajectory;
                        if (stream._autoScrollPinned !== false) {
                          requestAnimationFrame(() => {
                            stream.scrollTop = stream.scrollHeight;
                          });
                        }
                      }
                      return;
                    }
                  }
                } catch (e) {}
              }

              // Candidate paths fallback
              const candidatePaths = [];
              if (targetTask.id.includes('discord_')) {
                const dMatch = targetTask.id.match(/(?:sub_)?(discord_\d+_\d+)/);
                if (dMatch && dMatch[1]) {
                  candidatePaths.push(`.george/discord_sessions/${dMatch[1]}/raw_react.log`);
                }
                const chanId = targetTask.id.replace(/^sub_/, '').replace('discord_', '').split('_')[0];
                candidatePaths.push(`.george/discord_sessions/session_${chanId}.log`);
              }
              if (targetTask.id.startsWith('sub_')) {
                candidatePaths.push(`.george/subagents/${targetTask.id}.out`);
                candidatePaths.push(`.george/subagents/${targetTask.id}.log`);
                if (targetTask.id.startsWith('sub_sub_')) {
                  const sSingle = targetTask.id.replace(/^sub_sub_/, 'sub_');
                  candidatePaths.push(`.george/subagents/${sSingle}.out`);
                  candidatePaths.push(`.george/subagents/${sSingle}.log`);
                  candidatePaths.push(`.sandboxes/${sSingle}/trajectory.log`);
                  candidatePaths.push(`.sandboxes/${sSingle}/raw_react.log`);
                }
              }
              if (targetTask.id === 'sys_cron_sentinels' || targetTask.type === 'sys_cron' || targetTask.id === 'usr_cron_sentinels' || targetTask.type === 'usr_cron') {
                candidatePaths.push(`.george/cron.log`);
              }
              if (targetTask.path) {
                const p = targetTask.path;
                if (p.endsWith('.log') || p.endsWith('.out')) {
                  candidatePaths.push(p);
                } else {
                  candidatePaths.push(`${p}/raw_react.log`);
                  candidatePaths.push(`${p}/trajectory.log`);
                }
              }
              candidatePaths.push(`.george/workspaces/${targetTask.id}/raw_react.log`);
              candidatePaths.push(`.george/workspaces/${targetTask.id}/trajectory.log`);
              candidatePaths.push(`.sandboxes/${targetTask.id}/raw_react.log`);
              candidatePaths.push(`.sandboxes/${targetTask.id}/trajectory.log`);

              for (const cPath of candidatePaths) {
                try {
                  const resp = await fetch(`/api/file/read?path=${encodeURIComponent(cPath)}`);
                  if (resp.ok) {
                    const fileData = await resp.json();
                    if (fileData && fileData.content && fileData.content.trim().length > 0) {
                      if (autonomicExpandedStage.dataset.activeTaskId === activeTask.id) {
                        stream.innerHTML = '';
                        renderLogBatchToStream(stream, fileData.content, stream._thoughtState);
                        stream.dataset.lastLogs = fileData.content;
                        delete stream.dataset.renderedPlaceholder;
                        targetTask.content = fileData.content;
                        if (stream._autoScrollPinned !== false) {
                          requestAnimationFrame(() => {
                            stream.scrollTop = stream.scrollHeight;
                          });
                        }
                      }
                      return;
                    }
                  }
                } catch (e) {}
              }

              if (stream.dataset.renderedPlaceholder) {
                const fallbackLogs = (targetTask.log_tail && targetTask.log_tail.length > 0)
                  ? targetTask.log_tail.join('\n')
                  : (targetTask.content || 'Task active. Monitoring stream...');
                stream.innerHTML = '';
                renderLogBatchToStream(stream, fallbackLogs, stream._thoughtState);
                stream.dataset.lastLogs = fallbackLogs;
                delete stream.dataset.renderedPlaceholder;
              }
            })();

            // SSE live stream
            if (!targetTask.done && targetTask.phase !== 'Completed') {
              try {
                const aes = new EventSource(`/api/stream/task/${encodeURIComponent(targetTask.id)}?tail=true`);
                window._autonomicEventSource = aes;
                aes.addEventListener('log', (e) => {
                  const curStream = autonomicExpandedStage.querySelector('.expanded-log-stream');
                  if (curStream && e.data) {
                    if (curStream.dataset.renderedPlaceholder) {
                      curStream.innerHTML = '';
                      delete curStream.dataset.renderedPlaceholder;
                    }
                    const trimmedData = e.data.trim();
                    if (!curStream._recentLineSet) {
                      curStream._recentLineSet = new Set();
                      curStream._recentLineQueue = [];
                    }
                    if (trimmedData && curStream._recentLineSet.has(trimmedData)) {
                      return;
                    }
                    if (trimmedData) {
                      curStream._recentLineSet.add(trimmedData);
                      curStream._recentLineQueue.push(trimmedData);
                      if (curStream._recentLineQueue.length > 300) {
                        const oldest = curStream._recentLineQueue.shift();
                        curStream._recentLineSet.delete(oldest);
                      }
                    }

                    appendLogLineToStream(curStream, e.data, curStream._thoughtState);
                    curStream.dataset.lastLogs = (curStream.dataset.lastLogs ? curStream.dataset.lastLogs + '\n' : '') + e.data;
                    targetTask.content = curStream.dataset.lastLogs;
                  }
                });
                aes.addEventListener('phase', (e) => {
                  if (!isSubtask) {
                    const phaseText = autonomicExpandedStage.querySelector('.task-phase-badge') || autonomicExpandedStage.querySelector('.task-phase-text');
                    if (phaseText && e.data) phaseText.textContent = `[${e.data}]`;
                  }
                });
                aes.addEventListener('done', () => {
                  if (aes) aes.close();
                  if (window._autonomicEventSource === aes) window._autonomicEventSource = null;
                  if (!isSubtask) {
                    const phaseText = autonomicExpandedStage.querySelector('.task-phase-badge') || autonomicExpandedStage.querySelector('.task-phase-text');
                    if (phaseText) phaseText.textContent = '[Completed]';
                  }
                });
              } catch (e) {}
            }
          };

          // Wire subtask toggle buttons and card clicks
          autonomicExpandedStage.querySelectorAll('.nested-subtask-card').forEach(card => {
            const triggerSelect = () => {
              const subId = card.dataset.subtaskId;
              const targetSub = activeTask.subtasks && activeTask.subtasks.find(s => s.id === subId);
              if (targetSub) {
                window._currentViewingSubtaskId = subId;
                connectTaskStream(targetSub, true);
              }
            };
            card.addEventListener('click', (ev) => {
              if (ev.target.closest('.toggle-subtask-stream-btn')) return;
              triggerSelect();
            });
            const btn = card.querySelector('.toggle-subtask-stream-btn');
            if (btn) {
              btn.addEventListener('click', (ev) => {
                ev.preventDefault();
                ev.stopPropagation();
                triggerSelect();
              });
            }
          });

          const resetStreamBtn = autonomicExpandedStage.querySelector('.reset-parent-stream-btn');
          if (resetStreamBtn) {
            resetStreamBtn.addEventListener('click', (ev) => {
              ev.preventDefault();
              ev.stopPropagation();
              window._currentViewingSubtaskId = null;
              connectTaskStream(activeTask, false);
            });
          }

          // Wire USR Cron dropdown selector and item clicks
          const usrSelect = autonomicExpandedStage.querySelector('.usr-cron-dropdown-select');
          if (usrSelect) {
            usrSelect.addEventListener('change', (e) => {
              const val = e.target.value;
              const items = autonomicExpandedStage.querySelectorAll('.usr-cron-item');
              items.forEach(it => {
                if (val === 'all' || it.dataset.jobId === val) {
                  it.style.display = 'flex';
                } else {
                  it.style.display = 'none';
                }
              });
              if (val !== 'all') {
                const targetJob = (activeTask.cron_jobs || []).find(j => j.id === val);
                if (targetJob) {
                  const jobTask = {
                    id: `cron_${val}`,
                    type: 'cron',
                    path: `.sandboxes/cron_${val}`,
                    phase: targetJob.phase,
                    summary: targetJob.label || targetJob.id,
                  };
                  connectTaskStream(jobTask, true);
                }
              } else {
                connectTaskStream(activeTask, false);
              }
            });
          }

          autonomicExpandedStage.querySelectorAll('.usr-cron-item').forEach(it => {
            it.addEventListener('click', () => {
              const jid = it.dataset.jobId;
              if (jid && usrSelect) {
                usrSelect.value = jid;
                usrSelect.dispatchEvent(new Event('change'));
              }
            });
          });

          // Initial stream connection
          if (window._currentViewingSubtaskId && activeTask.subtasks) {
            const curSub = activeTask.subtasks.find(s => s.id === window._currentViewingSubtaskId);
            if (curSub) {
              connectTaskStream(curSub, true);
            } else {
              window._currentViewingSubtaskId = null;
              connectTaskStream(activeTask, false);
            }
          } else {
            connectTaskStream(activeTask, false);
          }
        }

        autonomicExpandedStage.querySelectorAll('.mini-collapse-btn').forEach(btn => {
          btn.addEventListener('click', () => {
            if (window._autonomicEventSource) {
              window._autonomicEventSource.close();
              window._autonomicEventSource = null;
            }
            expandedTaskId = null;
            autonomicExpandedStage.dataset.activeTaskId = '';
            renderAutonomicTaskBay(cachedTasks);
          });
        });

        const cronRestartBtn = autonomicExpandedStage.querySelector('.cron-restart-btn');
        if (cronRestartBtn) {
          cronRestartBtn.addEventListener('click', async () => {
            cronRestartBtn.textContent = 'RESTARTING...';
            try {
              await fetch('/api/cron/daemon/restart', { method: 'POST' });
            } catch (e) {}
            cronRestartBtn.textContent = 'RESTARTED';
            setTimeout(() => { if (cronRestartBtn) cronRestartBtn.textContent = 'RESTART DAEMON'; }, 1500);
            try {
              const tasksResp = await fetch('/api/tasks');
              if (tasksResp.ok) renderAutonomicTaskBay(await tasksResp.json());
            } catch (e) {}
          });
        }

        const ebRestartBtn = autonomicExpandedStage.querySelector('.event-bus-restart-btn');
        if (ebRestartBtn) {
          ebRestartBtn.addEventListener('click', async () => {
            ebRestartBtn.textContent = 'RESTARTING...';
            try {
              await window.restartEventBusDaemon();
            } catch (e) {}
            ebRestartBtn.textContent = 'RESTARTED';
            setTimeout(() => { if (ebRestartBtn) ebRestartBtn.textContent = 'RESTART DAEMON'; }, 1500);
          });
        }

        const steerInput = autonomicExpandedStage.querySelector('.expanded-steer-input');
        const steerBtn = autonomicExpandedStage.querySelector('.steer-btn');
        const pauseBtn = autonomicExpandedStage.querySelector('.pause-btn');
        const resumeBtn = autonomicExpandedStage.querySelector('.resume-btn');
        const terminateBtn = autonomicExpandedStage.querySelector('.terminate-btn');

        if (steerInput && steerBtn) {
          steerInput.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') {
              e.preventDefault();
              steerBtn.click();
            }
          });

          steerBtn.addEventListener('click', async () => {
            const guidance = steerInput.value.trim();
            if (!guidance) return;
            steerInput.value = '';
            try {
              await fetch(`/api/task/${activeTask.id}/inject`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ guidance, message: guidance, priority: 1 })
              });
              const stream = autonomicExpandedStage.querySelector('.expanded-log-stream');
              const jumpBtn = autonomicExpandedStage.querySelector('.stream-jump-btn');
              if (stream) {
                const wasPinned = stream._autoScrollPinned !== false;
                const prevScrollTop = stream.scrollTop;
                const steerEl = document.createElement('div');
                steerEl.className = 'stream-steer-banner';
                steerEl.innerHTML = `
                  <div class="stream-steer-badge">[DIRECTIVE: PRIORITY 1]</div>
                  <div class="stream-steer-content">${escapeHtml(guidance)}</div>
                `;
                stream.appendChild(steerEl);
                stream.dataset.lastLogs = (stream.dataset.lastLogs || '') + `\n[CRITICAL OPERATOR DIRECTIVE - PRIORITY 1]: ${guidance}`;
                if (wasPinned) {
                  stream.scrollTop = stream.scrollHeight;
                  if (jumpBtn) jumpBtn.classList.remove('visible');
                } else {
                  stream.scrollTop = prevScrollTop;
                }
              }
            } catch (e) {}
          });
        }

        const compactBtn = autonomicExpandedStage.querySelector('.compact-btn');
        if (compactBtn) {
          compactBtn.addEventListener('click', async () => {
            try {
              compactBtn.disabled = true;
              compactBtn.textContent = 'COMPACTING...';
              await fetch(`/api/task/${activeTask.id}/compact`, { method: 'POST' });
              compactBtn.textContent = '[COMPACT ARMED]';
              compactBtn.classList.add('accent');

              const stream = autonomicExpandedStage.querySelector('.expanded-log-stream');
              if (stream) {
                const wasPinned = stream._autoScrollPinned !== false;
                const prevScrollTop = stream.scrollTop;
                const bannerEl = document.createElement('div');
                bannerEl.className = 'stream-compact-banner';
                bannerEl.innerHTML = `
                  <div class="stream-compact-badge">[COMPACT INTERRUPT ARMED]</div>
                  <div class="stream-compact-content">Forced technical compaction will execute at the next model turn boundary, strictly preserving working state while recovering memory headroom.</div>
                `;
                stream.appendChild(bannerEl);
                if (wasPinned) stream.scrollTop = stream.scrollHeight;
                else stream.scrollTop = prevScrollTop;
              }
            } catch (e) {
              compactBtn.textContent = 'FORCE COMPACT';
              compactBtn.disabled = false;
            }
          });
        }

        if (pauseBtn && resumeBtn) {
          pauseBtn.addEventListener('click', async () => {
            try {
              await fetch(`/api/task/${activeTask.id}/pause`, { method: 'POST' });
              pauseBtn.style.display = 'none';
              resumeBtn.style.display = 'inline-block';
            } catch (e) {}
          });

          resumeBtn.addEventListener('click', async () => {
            try {
              await fetch(`/api/task/${activeTask.id}/resume`, { method: 'POST' });
              resumeBtn.style.display = 'none';
              pauseBtn.style.display = 'inline-block';
            } catch (e) {}
          });
        }

        if (terminateBtn) {
          wireDoubleConfirmTerminate(terminateBtn, activeTask.id, async () => {
            if (window._autonomicEventSource) {
              window._autonomicEventSource.close();
              window._autonomicEventSource = null;
            }
            expandedTaskId = null;
            autonomicExpandedStage.dataset.activeTaskId = '';
            const tasksResp = await fetch('/api/tasks');
            if (tasksResp.ok) {
              renderAutonomicTaskBay(await tasksResp.json());
            }
          });
        }
      } else {
        if (window._autonomicEventSource) {
          window._autonomicEventSource.close();
          window._autonomicEventSource = null;
        }
        autonomicExpandedStage.style.display = 'none';
        autonomicExpandedStage.dataset.activeTaskId = '';
        expandedTaskId = null;
      }
    } else if (autonomicExpandedStage) {
      if (window._autonomicEventSource) {
        window._autonomicEventSource.close();
        window._autonomicEventSource = null;
      }
      autonomicExpandedStage.style.display = 'none';
      autonomicExpandedStage.dataset.activeTaskId = '';
    }
  }

  // Non-overlapping heartbeat: schedule the next poll only after the previous
  // one settles, and back off while the tab is hidden.
  (function heartbeatLoop() {
    Promise.resolve(pollHeartbeat()).catch(() => {}).finally(() => {
      setTimeout(heartbeatLoop, document.hidden ? 15000 : 3000);
    });
  })();


  // Cull Stale Tasks Handler
  const bayCullBtn = document.getElementById('bayCullBtn');
  if (bayCullBtn) {
    bayCullBtn.addEventListener('click', async (e) => {
      e.stopPropagation();
      const origText = bayCullBtn.textContent;
      bayCullBtn.textContent = '[CULLING...]';
      bayCullBtn.disabled = true;
      try {
        const resp = await fetch('/api/tasks/cull', { method: 'POST' });
        const data = await resp.json();
        // Immediately purge non-active tasks from local map
        persistentTaskMap.forEach((task, id) => {
          if (!isTaskActive(task)) {
            persistentTaskMap.delete(id);
          }
        });
        bayCullBtn.textContent = `[CULLED ${data.culled_count || 0}]`;
        setTimeout(() => {
          bayCullBtn.textContent = origText;
          bayCullBtn.disabled = false;
        }, 2000);
        const tasksResp = await fetch('/api/tasks');
        if (tasksResp.ok) {
          const incoming = await tasksResp.json();
          renderAutonomicTaskBay(incoming);
        }
      } catch (err) {
        console.error('Cull failed:', err);
        bayCullBtn.textContent = '[FAILED]';
        setTimeout(() => {
          bayCullBtn.textContent = origText;
          bayCullBtn.disabled = false;
        }, 2000);
      }
    });
  }

  // --- Tool Crib Drawer Controls ---
  if (toolCribToggle && toolCribDrawer) {
    toolCribToggle.addEventListener('click', () => {
      toolCribDrawer.classList.toggle('open');
      const isOpen = toolCribDrawer.classList.contains('open');
      document.body.classList.toggle('drawer-open', isOpen);
      if (isOpen) {
        refreshToolCribData();
      }
    });
  }

  const headerFinanceBtn = document.getElementById('headerFinanceBtn');
  if (headerFinanceBtn && toolCribDrawer) {
    headerFinanceBtn.addEventListener('click', () => {
      toolCribDrawer.classList.add('open');
      document.body.classList.add('drawer-open');
      document.querySelectorAll('.drawer-tab-btn').forEach(b => b.classList.remove('active'));
      document.querySelectorAll('.drawer-pane').forEach(p => p.classList.remove('active'));
      const finTab = document.querySelector('.drawer-tab-btn[data-pane="finance"]');
      if (finTab) finTab.classList.add('active');
      const finPane = document.getElementById('pane-finance');
      if (finPane) finPane.classList.add('active');
      loadFinanceData();
      if (window.LodgeFund) window.LodgeFund.refresh();
    });
  }

  const headerDexDeskBtn = document.getElementById('headerDexDeskBtn');
  if (headerDexDeskBtn && toolCribDrawer) {
    headerDexDeskBtn.addEventListener('click', () => {
      toolCribDrawer.classList.add('open');
      document.body.classList.add('drawer-open');
      document.querySelectorAll('.drawer-tab-btn').forEach(b => b.classList.remove('active'));
      document.querySelectorAll('.drawer-pane').forEach(p => p.classList.remove('active'));
      const deskTab = document.querySelector('.drawer-tab-btn[data-pane="dex-desk"]');
      if (deskTab) deskTab.classList.add('active');
      const deskPane = document.getElementById('pane-dex-desk');
      if (deskPane) deskPane.classList.add('active');
      if (window.LodgeDesk) window.LodgeDesk.reload();
    });
  }

  const headerExplorerBtn = document.getElementById('headerExplorerBtn');
  if (headerExplorerBtn && toolCribDrawer) {
    headerExplorerBtn.addEventListener('click', () => {
      toolCribDrawer.classList.add('open');
      document.body.classList.add('drawer-open');
      document.querySelectorAll('.drawer-tab-btn').forEach(b => b.classList.remove('active'));
      document.querySelectorAll('.drawer-pane').forEach(p => p.classList.remove('active'));
      const expTab = document.querySelector('.drawer-tab-btn[data-pane="dolos-explorer"]');
      if (expTab) expTab.classList.add('active');
      const expPane = document.getElementById('pane-dolos-explorer');
      if (expPane) expPane.classList.add('active');
      if (window.LodgeExplorer) window.LodgeExplorer.reload();
    });
  }

  const headerSdrBtn = document.getElementById('headerSdrBtn');
  if (headerSdrBtn && toolCribDrawer) {
    headerSdrBtn.addEventListener('click', () => {
      toolCribDrawer.classList.add('open');
      document.body.classList.add('drawer-open');
      document.querySelectorAll('.drawer-tab-btn').forEach(b => b.classList.remove('active'));
      document.querySelectorAll('.drawer-pane').forEach(p => p.classList.remove('active'));
      const sdrTab = document.querySelector('.drawer-tab-btn[data-pane="sdr"]');
      if (sdrTab) sdrTab.classList.add('active');
      const sdrPane = document.getElementById('pane-sdr');
      if (sdrPane) sdrPane.classList.add('active');
      loadSdrData();
    });
  }

  if (drawerClose && toolCribDrawer) {
    drawerClose.addEventListener('click', () => {
      toolCribDrawer.classList.remove('open');
      document.body.classList.remove('drawer-open');
    });
  }

  if (drawerTabs) {
    drawerTabs.addEventListener('click', (e) => {
      if (e.target.classList.contains('drawer-tab-btn')) {
        document.querySelectorAll('.drawer-tab-btn').forEach(b => b.classList.remove('active'));
        document.querySelectorAll('.drawer-pane').forEach(p => p.classList.remove('active'));
        e.target.classList.add('active');
        const pane = e.target.getAttribute('data-pane');
        const paneId = `pane-${pane}`;
        const targetPane = document.getElementById(paneId);
        if (targetPane) targetPane.classList.add('active');
        if (pane === 'reactor-wizard') {
          loadOsintConfig();
          loadApiTriggerPresets();
        } else if (pane === 'finance') {
          loadFinanceData();
        } else if (pane === 'dex-desk') {
          if (window.LodgeDesk) window.LodgeDesk.reload();
        } else if (pane === 'dolos-explorer') {
          if (window.LodgeExplorer) window.LodgeExplorer.reload();
        } else if (pane === 'trading-sim') {
          loadTradingSimData();
        } else if (pane === 'sdr') {
          loadSdrData();
        } else if (pane === 'cron') {
          loadCronJobs();
        } else if (pane === 'commands') {
          loadCommands();
        } else if (pane === 'mcp') {
          loadMcpServers();
          loadMcpCatalog();
        } else if (pane === 'timemachine') {
          loadTranscripts();
        } else if (pane === 'specsheet') {
          loadFadellSpecSheet();
        } else if (pane === 'chronicle') {
          loadChronicle();
        }
      }
    });
  }

  const fieldGuidePane = document.getElementById('pane-field-guide');
  if (fieldGuidePane) {
    fieldGuidePane.addEventListener('click', (e) => {
      const a = e.target.closest('a[href^="#manual-"]');
      if (a) {
        e.preventDefault();
        const targetId = a.getAttribute('href').substring(1);
        const target = document.getElementById(targetId);
        if (target) {
          target.scrollIntoView({ behavior: 'smooth', block: 'start' });
        }
      }
    });
  }

  // --- Tool Crib Data Loaders ---
  async function refreshToolCribData() {
    loadCommands();
    loadTranscripts();
    loadFadellSpecSheet();
    loadChronicle();
    loadCronJobs();
    loadResearchConfig();
    loadMcpServers();
    loadMcpCatalog();
    fetchGameModeStatus();
    loadOsintConfig();
    loadFinanceData();
    loadTradingSimData();
    loadSdrData();
  }

  // 0. Run Ledger (refinement P1/1.8) — one row per George run, newest first
  const RUN_OUTCOME_CLASS = {
    SUCCESS: 'ok', PARTIAL: 'warn', MAX_TURNS: 'warn', TIMEOUT: 'warn',
    STALL: 'err', LOOP: 'err', TOOL_FAIL: 'err', INJECTION_BLOCKED: 'err', MISALIGNED: 'err', ABORTED: 'err'
  };
  async function loadRunLedger() {
    const list = document.getElementById('runLedgerList');
    if (!list) return;
    const note = (text) => {
      const d = document.createElement('div');
      d.className = 'item-meta';
      d.textContent = text;
      list.replaceChildren(d);
    };
    try {
      const resp = await fetch('/api/runs?limit=50');
      if (!resp.ok) { note('Run ledger unavailable.'); return; }
      const runs = await resp.json();
      if (!Array.isArray(runs) || runs.length === 0) { note('No runs recorded yet.'); return; }
      const frag = document.createDocumentFragment();
      runs.forEach(r => {
        const card = document.createElement('div');
        card.className = 'item-card run-ledger-card';
        const title = document.createElement('div');
        title.className = 'item-title';
        const badge = document.createElement('span');
        const outcome = String(r.outcome || r.status || 'RUNNING');
        badge.className = 'run-outcome run-outcome-' + (RUN_OUTCOME_CLASS[outcome] || 'run');
        badge.textContent = outcome;
        title.appendChild(badge);
        title.appendChild(document.createTextNode(' ' + String(r.goal || r.session_id || '')));
        const meta = document.createElement('div');
        meta.className = 'item-meta';
        const started = r.started_epoch ? new Date(r.started_epoch * 1000).toLocaleString() : '';
        meta.textContent = [
          String(r.type || ''), started,
          r.turns != null ? r.turns + ' turns' : '',
          r.wall_s != null ? r.wall_s + 's' : '',
          r.tool_fails ? r.tool_fails + ' tool fails' : '',
          r.reason ? String(r.reason) : ''
        ].filter(Boolean).join(' · ');
        card.appendChild(title);
        card.appendChild(meta);
        const actions = document.createElement('div');
        actions.className = 'item-actions';
        if (r.has_reply) {
          const btn = document.createElement('button');
          btn.className = 'mini-action';
          btn.textContent = 'VIEW REPLY';
          btn.addEventListener('click', () => {
            if (window.openScriptInWorkbench) {
              window.openScriptInWorkbench('.george/runs/' + encodeURIComponent(r.session_id) + '/final_reply.md');
              toolCribDrawer.classList.remove('open');
            }
          });
          actions.appendChild(btn);
        }
        const trace = document.createElement('button');
        trace.className = 'mini-action';
        trace.textContent = 'TRAJECTORY';
        trace.addEventListener('click', () => {
          if (window.openScriptInWorkbench) {
            window.openScriptInWorkbench('.george/workspaces/' + encodeURIComponent(r.session_id) + '/trajectory.log');
            toolCribDrawer.classList.remove('open');
          }
        });
        actions.appendChild(trace);
        card.appendChild(actions);
        frag.appendChild(card);
      });
      list.replaceChildren(frag);
    } catch (e) {
      note('Failed to load run ledger.');
    }
  }

  // 1. Time-Machine with Pruning / Deletion
  async function loadTranscripts() {
    loadRunLedger();
    const list = document.getElementById('transcriptList');
    if (!list) return;
    try {
      const resp = await fetch('/api/transcripts');
      if (resp.ok) {
        const data = await resp.json();
        list.innerHTML = '';
        if (data.length === 0) {
          list.innerHTML = '<div class="item-meta">No archived transcripts cataloged.</div>';
          return;
        }
        data.forEach(item => {
          const card = document.createElement('div');
          card.className = 'item-card';
          card.innerHTML = `
            <div class="item-title">${escapeHtml(item.name)}</div>
            <div class="item-meta">${Math.round(item.size_bytes / 1024)} KB</div>
            <div class="item-actions">
              <button class="mini-action ask-btn">ASK GEORGE</button>
              <button class="mini-action vim-btn">OPEN IN VIM</button>
              <button class="mini-action resume-btn">RESUME TASK</button>
              <button class="mini-action danger delete-btn">PRUNE</button>
            </div>
          `;
          card.querySelector('.ask-btn').addEventListener('click', () => {
            promptInput.value = `/recall ${item.name} Summarize key milestones and findings from this task.`;
            toolCribDrawer.classList.remove('open');
            promptInput.focus();
          });
          card.querySelector('.vim-btn').addEventListener('click', () => {
            if (window.openScriptInWorkbench) {
              window.openScriptInWorkbench('.george/transcripts/' + item.name);
              toolCribDrawer.classList.remove('open');
            }
          });
          card.querySelector('.resume-btn').addEventListener('click', () => {
            promptInput.value = `/resume ${item.name}`;
            toolCribDrawer.classList.remove('open');
            promptInput.focus();
          });
          card.querySelector('.delete-btn').addEventListener('click', async () => {
            if (confirm(`Prune transcript "${item.name}" and reclaim disk space?`)) {
              try {
                const delResp = await fetch(`/api/transcripts/${encodeURIComponent(item.name)}`, { method: 'DELETE' });
                if (delResp.ok) {
                  card.remove();
                }
              } catch (e) {}
            }
          });
          list.appendChild(card);
        });
      }
    } catch (e) {
      list.innerHTML = '<div class="item-meta">Failed to load transcripts.</div>';
    }
  }

  // 2. Tony Fadell 3-Chamber Spec Sheet
  let fullConfigData = null;

  async function loadFadellSpecSheet() {
    try {
      const resp = await fetch('/api/config/full');
      if (resp.ok) {
        fullConfigData = await resp.json();
        const gauge = fullConfigData.chamber1_gauge;
        const trays = fullConfigData.chamber2_trays;
        const raw = fullConfigData.chamber3_raw;

        // Chamber 1: Gauge
        const turnsRange = document.getElementById('gaugeTurnsRange');
        const turnsVal = document.getElementById('gaugeTurnsVal');
        const tempRange = document.getElementById('gaugeTempRange');
        const tempVal = document.getElementById('gaugeTempVal');
        const timeoutInput = document.getElementById('gaugeTimeoutInput');
        const pacingSelect = document.getElementById('gaugePacingSelect');

        if (turnsRange && turnsVal) {
          turnsRange.value = gauge.max_research_turns || 25;
          turnsVal.textContent = turnsRange.value;
        }
        if (tempRange && tempVal) {
          tempRange.value = Math.round(parseFloat(gauge.llm_temperature || 0.4) * 100);
          tempVal.textContent = (tempRange.value / 100).toFixed(2);
        }
        if (timeoutInput) timeoutInput.value = gauge.llm_timeout || 180;
        if (pacingSelect) pacingSelect.value = currentPacing.toString();

        // Chamber 2: Trays
        if (trays) {
          for (const trayName in trays) {
            for (const key in trays[trayName]) {
              const el = document.getElementById(`cfg_${key}`);
              if (el) el.value = trays[trayName][key];
            }
          }
        }

        // Chamber 3: Raw
        const rawText = document.getElementById('rawConfTextarea');
        if (rawText && raw) {
          rawText.value = raw.limits || '';
        }
      }
    } catch (e) {
      console.warn('Failed to load full config:', e);
    }
  }

  // Chamber 1 Slider Listeners
  const turnsRange = document.getElementById('gaugeTurnsRange');
  const turnsVal = document.getElementById('gaugeTurnsVal');
  if (turnsRange && turnsVal) {
    turnsRange.addEventListener('input', () => { turnsVal.textContent = turnsRange.value; });
  }

  const tempRange = document.getElementById('gaugeTempRange');
  const tempVal = document.getElementById('gaugeTempVal');
  if (tempRange && tempVal) {
    tempRange.addEventListener('input', () => { tempVal.textContent = (tempRange.value / 100).toFixed(2); });
  }

  const pacingSelect = document.getElementById('gaugePacingSelect');
  if (pacingSelect) {
    pacingSelect.addEventListener('change', (e) => {
      currentPacing = parseInt(e.target.value, 10);
      localStorage.setItem('george-pacing', currentPacing.toString());
    });
  }

  const saveGaugeBtn = document.getElementById('saveGaugeBtn');
  if (saveGaugeBtn) {
    saveGaugeBtn.addEventListener('click', async () => {
      saveGaugeBtn.textContent = 'SAVING...';
      const turns = turnsRange ? turnsRange.value : '25';
      const temp = tempRange ? (tempRange.value / 100).toFixed(2) : '0.40';
      const timeout = document.getElementById('gaugeTimeoutInput') ? document.getElementById('gaugeTimeoutInput').value : '180';

      await fetch('/api/config/key', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ file: 'limits', key: 'MAX_RESEARCH_TURNS', value: turns })
      });
      await fetch('/api/config/key', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ file: 'limits', key: 'LLM_TEMPERATURE', value: temp })
      });
      await fetch('/api/config/key', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ file: 'limits', key: 'LLM_TIMEOUT', value: timeout })
      });

      saveGaugeBtn.textContent = '[CALIBRATED]';
      setTimeout(() => { saveGaugeBtn.textContent = 'CALIBRATE 24-INCH GAUGE'; }, 1500);
    });
  }

  // Chamber 2 Intent Tray Accordions
  document.querySelectorAll('.tray-header').forEach(hdr => {
    hdr.addEventListener('click', () => {
      const targetId = hdr.getAttribute('data-target');
      const body = document.getElementById(targetId);
      const arrow = hdr.querySelector('.tray-arrow');
      if (body) {
        body.style.display = body.style.display === 'none' ? 'flex' : 'none';
        if (arrow) arrow.textContent = body.style.display === 'none' ? '▶' : '▼';
      }
    });
  });

  // Chamber 3 Raw Blueprint Sheet
  const toggleRawBtn = document.getElementById('toggleRawBtn');
  const rawEditorContainer = document.getElementById('rawEditorContainer');
  let activeRawFile = 'limits';

  if (toggleRawBtn && rawEditorContainer) {
    toggleRawBtn.addEventListener('click', () => {
      const isOpen = rawEditorContainer.style.display !== 'none';
      rawEditorContainer.style.display = isOpen ? 'none' : 'block';
      toggleRawBtn.textContent = isOpen ? 'SWITCH TO RAW .CONF EDITOR' : 'HIDE RAW .CONF EDITOR';
    });
  }

  document.querySelectorAll('.raw-tab').forEach(tab => {
    tab.addEventListener('click', () => {
      document.querySelectorAll('.raw-tab').forEach(t => t.classList.remove('active'));
      tab.classList.add('active');
      activeRawFile = tab.getAttribute('data-file');
      const rawText = document.getElementById('rawConfTextarea');
      if (rawText && fullConfigData && fullConfigData.chamber3_raw) {
        rawText.value = fullConfigData.chamber3_raw[activeRawFile] || '';
      }
    });
  });

  const saveRawBtn = document.getElementById('saveRawBtn');
  if (saveRawBtn) {
    saveRawBtn.addEventListener('click', async () => {
      saveRawBtn.textContent = 'COMMITTING...';
      const rawText = document.getElementById('rawConfTextarea');
      const content = rawText ? rawText.value : '';
      const payload = {};
      if (activeRawFile === 'limits') payload.limits_conf = content;
      if (activeRawFile === 'endpoints') payload.endpoints_conf = content;
      if (activeRawFile === 'keys') payload.keys_conf = content;

      await fetch('/api/config', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
      });
      saveRawBtn.textContent = '[COMMITTED]';
      setTimeout(() => { saveRawBtn.textContent = 'COMMIT RAW BLUEPRINT'; }, 1500);
    });
  }

  // 3. Chronicle & SQLite Studio
  async function loadChronicle() {
    try {
      const resp = await fetch('/api/journal');
      if (resp.ok) {
        const data = await resp.json();
        const editor = document.getElementById('georgeMdEditor');
        if (editor) editor.value = data.george_md || '';
      }
    } catch (e) {}
  }

  // Chronicle Subtabs
  document.querySelectorAll('.chronicle-tab-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('.chronicle-tab-btn').forEach(b => b.classList.remove('active'));
      document.querySelectorAll('.chronicle-subpane').forEach(p => p.classList.remove('active'));
      btn.classList.add('active');
      const sub = btn.getAttribute('data-sub');
      const pane = document.getElementById(`subpane-${sub}`);
      if (pane) pane.classList.add('active');
      if (sub === 'okf') {
        loadOkfNavigator();
      }
    });
  });

  // Save GEORGE.md
  const saveGeorgeMdBtn = document.getElementById('saveGeorgeMdBtn');
  if (saveGeorgeMdBtn) {
    saveGeorgeMdBtn.addEventListener('click', async () => {
      saveGeorgeMdBtn.textContent = 'SAVING...';
      const editor = document.getElementById('georgeMdEditor');
      const george_md = editor ? editor.value : '';
      await fetch('/api/journal/save', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ george_md })
      });
      saveGeorgeMdBtn.textContent = '[SPECIFICATION SAVED]';
      setTimeout(() => { saveGeorgeMdBtn.textContent = 'SAVE GEORGE.MD SPECIFICATION'; }, 1500);
    });
  }

  // SQLite BM25 Search
  const bm25SearchInput = document.getElementById('bm25SearchInput');
  if (bm25SearchInput) {
    let searchTimeout = null;
    bm25SearchInput.addEventListener('input', (e) => {
      clearTimeout(searchTimeout);
      const query = e.target.value.trim();
      if (!query) return;
      searchTimeout = setTimeout(async () => {
        executeSqlOrSearch(null, query);
      }, 350);
    });
  }

  // Quick SQL Chips
  document.querySelectorAll('.sql-chip').forEach(chip => {
    chip.addEventListener('click', () => {
      const sql = chip.getAttribute('data-sql');
      const targetDb = chip.getAttribute('data-db');
      const dbSelect = document.getElementById('sqliteDbSelect');
      if (targetDb && dbSelect) {
        dbSelect.value = targetDb;
      }
      const input = document.getElementById('sqlQueryInput');
      if (input) input.value = sql;
      executeSqlOrSearch(sql, null);
    });
  });

  const executeSqlBtn = document.getElementById('executeSqlBtn');
  if (executeSqlBtn) {
    executeSqlBtn.addEventListener('click', () => {
      const input = document.getElementById('sqlQueryInput');
      const sql = input ? input.value.trim() : '';
      if (sql) executeSqlOrSearch(sql, null);
    });
  }

  async function executeSqlOrSearch(sqlQuery, searchTerm) {
    const resultsEl = document.getElementById('sqlResults');
    if (!resultsEl) return;
    resultsEl.innerHTML = '<div class="item-meta">Querying SQLite database...</div>';

    const dbSelect = document.getElementById('sqliteDbSelect');
    const selectedDb = dbSelect ? dbSelect.value : 'okf';

    try {
      const payload = searchTerm ? { search: searchTerm, db: selectedDb } : { query: sqlQuery, db: selectedDb };
      const resp = await fetch('/api/sqlite/query', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
      });

      if (resp.ok) {
        const data = await resp.json();
        if (data.status === 'error') {
          resultsEl.innerHTML = `<div class="item-meta" style="color: var(--status-error);">Error: ${escapeHtml(data.error)}</div>`;
          return;
        }

        const rows = data.rows;
        if (!rows || rows.length === 0) {
          resultsEl.innerHTML = '<div class="item-meta">Zero rows returned.</div>';
          return;
        }

        const cols = Object.keys(rows[0]);
        let tableHtml = '<table class="sql-table"><thead><tr>';
        cols.forEach(c => { tableHtml += `<th>${escapeHtml(c)}</th>`; });
        tableHtml += '</tr></thead><tbody>';

        rows.forEach(r => {
          tableHtml += '<tr>';
          cols.forEach(c => {
            const val = typeof r[c] === 'object' ? JSON.stringify(r[c]) : String(r[c]);
            tableHtml += `<td>${escapeHtml(val)}</td>`;
          });
          tableHtml += '</tr>';
        });
        tableHtml += '</tbody></table>';
        resultsEl.innerHTML = tableHtml;
      }
    } catch (err) {
      resultsEl.innerHTML = `<div class="item-meta" style="color: var(--status-error);">Execution failure: ${escapeHtml(err.message)}</div>`;
    }
  }

  // ================================================================
  // OKF Codebase Graph & BM25 Navigator Controller
  // ================================================================
  let okfModulesCache = [];
  let currentOkfSubsystem = 'ALL';
  let okfSearchTimeout = null;
  let okfLoaded = false;

  async function loadOkfNavigator() {
    const listEl = document.getElementById('okfModuleList');
    if (!listEl) return;

    try {
      const statsResp = await fetch('/api/okf/search');
      if (statsResp.ok) {
        const statsData = await statsResp.json();
        if (statsData.results) {
          const s = statsData.results;
          const modEl = document.getElementById('okfStatModules');
          const symEl = document.getElementById('okfStatSymbols');
          const subEl = document.getElementById('okfStatSubsystems');
          if (modEl) modEl.textContent = s.total_modules || '--';
          if (subEl) subEl.textContent = s.subsystem_breakdown ? s.subsystem_breakdown.length : '--';
          if (symEl) symEl.textContent = '1,937';
        }
      }
    } catch (e) {}

    if (!okfLoaded) {
      okfLoaded = true;
      await searchOkfModules('');
    }
  }

  async function searchOkfModules(query = '') {
    const listEl = document.getElementById('okfModuleList');
    const countEl = document.getElementById('okfSearchCount');
    if (!listEl) return;

    listEl.innerHTML = '<div class="loading-state">Executing OKF FTS5 BM25 search...</div>';

    try {
      const q = query.trim();
      const sub = currentOkfSubsystem;
      let url = `/api/okf/search?q=${encodeURIComponent(q || (sub !== 'ALL' ? sub : 'agent'))}&limit=50`;
      if (sub && sub !== 'ALL') {
        url += `&subsystem=${encodeURIComponent(sub)}`;
      }

      const resp = await fetch(url);
      if (resp.ok) {
        const data = await resp.json();
        const results = Array.isArray(data.results) ? data.results : [];
        okfModulesCache = results;
        if (countEl) countEl.textContent = `${results.length} matches`;
        renderOkfModules(results);
      } else {
        listEl.innerHTML = '<div class="deps-none" style="padding: 16px;">Failed to query OKF search endpoint.</div>';
      }
    } catch (e) {
      listEl.innerHTML = `<div class="deps-none" style="padding: 16px;">Error: ${escapeHtml(e.message)}</div>`;
    }
  }

  function renderOkfModules(modules) {
    const listEl = document.getElementById('okfModuleList');
    if (!listEl) return;

    if (!modules || modules.length === 0) {
      listEl.innerHTML = '<div class="deps-none" style="padding: 24px; text-align: center;">Zero matching modules in OKF graph. Try a broader search term.</div>';
      return;
    }

    listEl.innerHTML = modules.map(m => {
      const hasScore = m.bm25_score !== undefined && m.bm25_score !== 0;
      const exportsList = Array.isArray(m.exports) ? m.exports : [];
      const depsList = Array.isArray(m.depends_on) ? m.depends_on : [];

      return `
        <div class="okf-module-card" data-module-path="${escapeHtml(m.path)}">
          <div class="okf-module-header">
            <div class="okf-module-title-area">
              <span class="okf-module-name" data-open-path="${escapeHtml(m.path)}">${escapeHtml(m.name)}</span>
              <span class="okf-module-path">${escapeHtml(m.path)}</span>
            </div>
            <div class="okf-module-badges">
              <span class="okf-badge okf-badge-lang">${escapeHtml(m.language || 'Code')}</span>
              <span class="okf-badge okf-badge-sub">${escapeHtml(m.subsystem_name || 'Subsystem')}</span>
              ${hasScore ? `<span class="okf-badge okf-badge-score">BM25: ${m.bm25_score}</span>` : ''}
            </div>
          </div>

          <div class="okf-module-desc">${escapeHtml(m.description || 'No description provided.')}</div>

          ${exportsList.length > 0 ? `
            <div class="okf-module-exports">
              <span class="okf-exports-label">AST EXPORTS (${exportsList.length}):</span>
              ${exportsList.slice(0, 12).map(exp => `
                <span class="okf-export-chip" data-copy-symbol="${escapeHtml(exp)}" title="Click to copy symbol name">${escapeHtml(exp)}</span>
              `).join('')}
              ${exportsList.length > 12 ? `<span style="font-size: 9px; color: var(--text-muted); align-self: center;">+${exportsList.length - 12} more</span>` : ''}
            </div>
          ` : ''}

          <div class="okf-module-footer">
            <div class="okf-module-meta">
              <span>Size: ${m.size_bytes ? (m.size_bytes > 1024 ? Math.round(m.size_bytes / 1024) + ' KB' : m.size_bytes + ' B') : '--'}</span>
              ${depsList.length > 0 ? `<span style="margin-left: 10px;">Depends on: ${depsList.length} modules</span>` : ''}
            </div>
            <button class="okf-open-btn" data-open-path="${escapeHtml(m.path)}">OPEN IN VIM EDITOR</button>
          </div>
        </div>
      `;
    }).join('');

    // Attach click listeners to open in Vim
    listEl.querySelectorAll('[data-open-path]').forEach(el => {
      el.addEventListener('click', (e) => {
        e.stopPropagation();
        const path = el.getAttribute('data-open-path');
        if (path) {
          if (window.openVimFile) {
            window.openVimFile(path);
          } else {
            const modal = document.getElementById('scriptEditorModal');
            if (modal) modal.classList.add('open');
            if (window.refreshEditorWorkspaceFiles) window.refreshEditorWorkspaceFiles();
          }
        }
      });
    });

    // Attach copy symbol listeners
    listEl.querySelectorAll('[data-copy-symbol]').forEach(chip => {
      chip.addEventListener('click', (e) => {
        e.stopPropagation();
        const sym = chip.getAttribute('data-copy-symbol');
        if (sym && navigator.clipboard) {
          navigator.clipboard.writeText(sym);
          const orig = chip.textContent;
          chip.textContent = 'COPIED!';
          setTimeout(() => { chip.textContent = orig; }, 1000);
        }
      });
    });
  }

  // Filter chips in OKF Navigator
  document.querySelectorAll('.okf-filter-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('.okf-filter-btn').forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      currentOkfSubsystem = btn.getAttribute('data-sub') || 'ALL';
      const searchInput = document.getElementById('okfBm25SearchInput');
      const q = searchInput ? searchInput.value.trim() : '';
      searchOkfModules(q);
    });
  });

  // Debounced BM25 Search Input
  const okfSearchInput = document.getElementById('okfBm25SearchInput');
  if (okfSearchInput) {
    okfSearchInput.addEventListener('input', (e) => {
      clearTimeout(okfSearchTimeout);
      const query = e.target.value;
      okfSearchTimeout = setTimeout(() => {
        searchOkfModules(query);
      }, 250);
    });
  }

  // Re-index button
  const btnOkfReindex = document.getElementById('btnOkfReindex');
  if (btnOkfReindex) {
    btnOkfReindex.addEventListener('click', async () => {
      btnOkfReindex.textContent = 'RE-INDEXING...';
      btnOkfReindex.disabled = true;
      try {
        const resp = await fetch('/api/okf/reindex', { method: 'POST' });
        if (resp.ok) {
          btnOkfReindex.textContent = 'INDEX COMPLETE!';
          setTimeout(() => {
            btnOkfReindex.textContent = 'RE-INDEX OKF GRAPH';
            btnOkfReindex.disabled = false;
          }, 1500);
          loadOkfNavigator();
        }
      } catch (e) {
        btnOkfReindex.textContent = 'INDEX FAILED';
        btnOkfReindex.disabled = false;
      }
    });
  }

  // --- Add Node Modal Handlers & Model Staging Assistant ---
  if (addNodeBtn && nodeModal) {
    addNodeBtn.addEventListener('click', () => nodeModal.classList.add('open'));
  }
  if (nodeModalClose && nodeModal) {
    nodeModalClose.addEventListener('click', () => nodeModal.classList.remove('open'));
  }
  const closeNodeBtn = document.getElementById('closeNodeBtn');
  if (closeNodeBtn && nodeModal) {
    closeNodeBtn.addEventListener('click', () => nodeModal.classList.remove('open'));
  }

  const testNodeBtn = document.getElementById('testNodeBtn');
  if (testNodeBtn) {
    testNodeBtn.addEventListener('click', async () => {
      const url = document.getElementById('newNodeUrl').value.trim();
      const provider = document.getElementById('newNodeProvider').value;
      const feedback = document.getElementById('nodeTestFeedback');
      feedback.className = 'node-probe-result';
      feedback.innerHTML = '<span style="color: var(--text-muted);">Probing HTTP endpoints (/props, /tags, /v1/models)...</span>';

      try {
        const resp = await fetch('/api/node/probe', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ url, provider })
        });
        const d = await resp.json();
        if (d.status === 'online') {
          feedback.className = 'node-probe-result online';
          let details = '';
          let detectedModel = '';
          let detectedCtx = null;
          let detectedTemp = null;
          let detectedTopP = null;
          let detectedFtype = '';

          if (d.props && d.props.default_generation_settings) {
            const s = d.props.default_generation_settings;
            detectedCtx = s.n_ctx;
            detectedTemp = (s.params && s.params.temperature !== undefined) ? s.params.temperature : s.temperature;
            detectedTopP = (s.params && s.params.top_p !== undefined) ? s.params.top_p : s.top_p;
            if (d.props.model_path) {
              detectedModel = d.props.model_path.split('/').pop().replace(/\.gguf$/i, '');
            }
          }

          if (d.models && Array.isArray(d.models.data) && d.models.data.length > 0) {
            const m = d.models.data[0];
            if (m.id && (!detectedModel || detectedModel === 'base')) {
              detectedModel = m.id.split('/').pop().replace(/\.gguf$/i, '');
            }
            if (m.meta) {
              if (m.meta.n_ctx) detectedCtx = m.meta.n_ctx;
              if (m.meta.ftype) detectedFtype = m.meta.ftype;
            }
          }

          const tempStr = (detectedTemp !== null && detectedTemp !== undefined) ? detectedTemp : '1.0';
          const topPStr = (detectedTopP !== null && detectedTopP !== undefined) ? Number(detectedTopP).toFixed(2) : '0.95';
          const ctxStr = detectedCtx || 'default';
          const ftypeStr = detectedFtype ? ` · ${detectedFtype}` : '';

          details = ` [n_ctx: ${ctxStr}, temp: ${tempStr}, top_p: ${topPStr}${ftypeStr}]`;
          feedback.innerHTML = `<strong>[ONLINE] [${escapeHtml(d.provider)}]</strong>: Endpoint responding nominally${escapeHtml(details)}`;

          if (detectedCtx && detectedCtx >= 1024) {
            const ctxInput = document.getElementById('newNodeContext');
            if (ctxInput) ctxInput.value = detectedCtx;
          }
          if (detectedModel) {
            const modelInput = document.getElementById('newNodeModel');
            if (modelInput) {
              modelInput.value = detectedModel;
            }
          }
          const provSelect = document.getElementById('newNodeProvider');
          if (provSelect && d.provider) {
            if (d.provider === 'llama.cpp') provSelect.value = 'llama.cpp';
            else if (d.provider === 'ollama') provSelect.value = 'ollama';
          }
        } else {
          feedback.className = 'node-probe-result offline';
          feedback.innerHTML = `<strong>[OFFLINE] Unreachable</strong>: ${escapeHtml(d.message)}`;
        }
      } catch (e) {
        feedback.className = 'node-probe-result offline';
        feedback.innerHTML = `<strong>[ERROR] Network error</strong>: ${escapeHtml(e.message)}`;
      }
    });
  }

  // --- First-Class Dynamic SSH Node Discovery, Model/LoRA Switcher & Swarm Enrollment ---
  const discoverSshNodeBtn = document.getElementById('discoverSshNodeBtn');
  if (discoverSshNodeBtn) {
    discoverSshNodeBtn.addEventListener('click', async () => {
      const sshTarget = (document.getElementById('newNodeSshTarget')?.value || '').trim();
      const jumpHost = (document.getElementById('newNodeJump')?.value || '').trim();
      const feedback = document.getElementById('nodeTestFeedback');
      discoverSshNodeBtn.disabled = true;
      discoverSshNodeBtn.textContent = 'PROBING SSH...';
      if (feedback) {
        feedback.className = 'node-probe-result';
        feedback.textContent = 'Probing remote node via SSH (hardware, VRAM, GGUF models, LoRA adapters, worker state)...';
      }
      try {
        const resp = await fetch('/api/node/discover', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            ssh_target: sshTarget || undefined,
            jump_host: jumpHost || undefined
          })
        });
        const d = await resp.json();
        if (resp.ok && d.status === 'ok') {
          if (d.hostname) {
            const nameEl = document.getElementById('newNodeName');
            if (nameEl) nameEl.value = d.hostname;
          }
          if (d.hardware_summary) {
            const hwEl = document.getElementById('newNodeHardware');
            if (hwEl) hwEl.value = d.hardware_summary;
          }
          if (d.llama_server) {
            const modelEl = document.getElementById('newNodeModel');
            if (modelEl && d.llama_server.active_model_name) {
              modelEl.value = d.llama_server.active_model_name;
            }
            const ctxEl = document.getElementById('newNodeContext');
            if (ctxEl && d.llama_server.n_ctx) {
              ctxEl.value = d.llama_server.n_ctx;
            }
          }
          // Populate discovered GGUF models & LoRA adapters using DOM APIs (no innerHTML)
          const switchSec = document.getElementById('remoteModelSwitchSection');
          const modelSel = document.getElementById('discoveredModelSelect');
          const loraSel = document.getElementById('discoveredLoraSelect');
          if (switchSec && modelSel && Array.isArray(d.models) && d.models.length > 0) {
            while (modelSel.firstChild) modelSel.removeChild(modelSel.firstChild);
            d.models.forEach((m) => {
              const opt = document.createElement('option');
              opt.value = m.path || m.name;
              opt.textContent = `${m.name} (${m.size_gb} GB${m.requires_prism ? ' · PRISM' : ''})`;
              if (d.llama_server && d.llama_server.active_model_name === m.name) {
                opt.selected = true;
              }
              modelSel.appendChild(opt);
            });
            if (loraSel) {
              while (loraSel.firstChild) loraSel.removeChild(loraSel.firstChild);
              const baseOpt = document.createElement('option');
              baseOpt.value = '';
              baseOpt.textContent = '(None — Base Model)';
              loraSel.appendChild(baseOpt);
              (d.loras || []).forEach((l) => {
                const opt = document.createElement('option');
                opt.value = l.path || l.name;
                opt.textContent = `${l.name} (${l.size_mb} MB)`;
                loraSel.appendChild(opt);
              });
            }
            switchSec.style.display = 'block';
          }
          if (feedback) {
            feedback.className = 'node-probe-result online';
            const mCount = (d.models || []).length;
            const lCount = (d.loras || []).length;
            feedback.textContent = `[SSH DISCOVERED] ${d.hostname}: ${d.hardware_summary || 'CPU'} · ${mCount} GGUF model(s), ${lCount} LoRA adapter(s)`;
          }
        } else if (feedback) {
          feedback.className = 'node-probe-result offline';
          feedback.textContent = `[SSH DISCOVER FAILED]: ${d.message || 'Unreachable'}`;
        }
      } catch (e) {
        if (feedback) {
          feedback.className = 'node-probe-result offline';
          feedback.textContent = `[SSH ERROR]: ${e.message}`;
        }
      } finally {
        discoverSshNodeBtn.disabled = false;
        discoverSshNodeBtn.textContent = 'SSH DISCOVER';
      }
    });
  }

  const switchRemoteModelBtn = document.getElementById('switchRemoteModelBtn');
  if (switchRemoteModelBtn) {
    switchRemoteModelBtn.addEventListener('click', async () => {
      const modelSel = document.getElementById('discoveredModelSelect');
      const loraSel = document.getElementById('discoveredLoraSelect');
      const ctxEl = document.getElementById('newNodeContext');
      const feedback = document.getElementById('nodeTestFeedback');
      const model = modelSel ? modelSel.value : '';
      const lora = loraSel ? loraSel.value : '';
      const context = ctxEl ? (parseInt(ctxEl.value, 10) || 12288) : 12288;
      if (!model) return;

      switchRemoteModelBtn.disabled = true;
      switchRemoteModelBtn.textContent = 'SWITCHING...';
      if (feedback) {
        feedback.className = 'node-probe-result';
        feedback.textContent = 'Switching remote GGUF model & LoRA adapter in 1-slot mode...';
      }
      try {
        const resp = await fetch('/api/node/switch-model', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ model, lora: lora || undefined, context, parallel: 1 })
        });
        const d = await resp.json();
        if (resp.ok && d.status === 'ok') {
          if (d.node_state && d.node_state.llama_server) {
            const modelInput = document.getElementById('newNodeModel');
            if (modelInput && d.node_state.llama_server.active_model_name) {
              modelInput.value = d.node_state.llama_server.active_model_name;
            }
          }
          if (feedback) {
            feedback.className = 'node-probe-result online';
            feedback.textContent = `[MODEL SWITCHED] ${(d.output || '').trim() || 'Remote llama-server reloaded healthy'}`;
          }
          fetchStatus();
        } else if (feedback) {
          feedback.className = 'node-probe-result offline';
          feedback.textContent = `[SWITCH FAILED] ${d.output || d.message || 'Failed to reload remote llama-server'}`;
        }
      } catch (e) {
        if (feedback) {
          feedback.className = 'node-probe-result offline';
          feedback.textContent = `[SWITCH ERROR] ${e.message}`;
        }
      } finally {
        switchRemoteModelBtn.disabled = false;
        switchRemoteModelBtn.textContent = 'SWITCH & RELOAD';
      }
    });
  }

  const enrollSwarmNodeBtn = document.getElementById('enrollSwarmNodeBtn');
  if (enrollSwarmNodeBtn) {
    enrollSwarmNodeBtn.addEventListener('click', async () => {
      const sshTarget = (document.getElementById('newNodeSshTarget')?.value || '').trim();
      const jumpHost = (document.getElementById('newNodeJump')?.value || '').trim();
      const nodeName = (document.getElementById('newNodeName')?.value || '').trim();
      const mode = (document.getElementById('newNodeMode')?.value || 'hybrid').trim();
      const tier = (document.getElementById('newNodeTier')?.value || 'tier2').trim();
      const feedback = document.getElementById('nodeTestFeedback');

      enrollSwarmNodeBtn.disabled = true;
      enrollSwarmNodeBtn.textContent = 'ENROLLING...';
      if (feedback) {
        feedback.className = 'node-probe-result';
        feedback.textContent = `Enrolling remote node in '${mode}' mode (establishing bidirectional SSH tunnel, syncing repo, starting FIFO-MQTT bridge)...`;
      }
      try {
        const resp = await fetch('/api/node/enroll', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            ssh_target: sshTarget || undefined,
            jump_host: jumpHost || undefined,
            node_name: nodeName || undefined,
            mode,
            tier
          })
        });
        const d = await resp.json();
        if (resp.ok && d.status === 'ok') {
          if (feedback) {
            feedback.className = 'node-probe-result online';
            feedback.textContent = `[SWARM ENROLLED] Node active in '${mode}' mode with FIFO-MQTT flow control`;
          }
          fetchStatus();
        } else if (feedback) {
          feedback.className = 'node-probe-result offline';
          feedback.textContent = `[ENROLL FAILED] ${d.output || d.message || 'Failed'}`;
        }
      } catch (e) {
        if (feedback) {
          feedback.className = 'node-probe-result offline';
          feedback.textContent = `[ENROLL ERROR] ${e.message}`;
        }
      } finally {
        enrollSwarmNodeBtn.disabled = false;
        enrollSwarmNodeBtn.textContent = 'ENROLL IN FIFO-MQTT SWARM';
      }
    });
  }

  const stagePullBtn = document.getElementById('stagePullBtn');
  if (stagePullBtn) {
    stagePullBtn.addEventListener('click', async () => {
      const provider = document.getElementById('newNodeProvider').value;
      const modelName = document.getElementById('stageModelName').value.trim();
      const sshHost = document.getElementById('newNodeJump').value.trim();
      const box = document.getElementById('stagedCommandBox');
      const code = document.getElementById('stagedCommandCode');
      const dispatchBtn = document.getElementById('dispatchSshBtn');

      if (!modelName) {
        alert('Please enter a model name or HuggingFace repo identifier');
        return;
      }

      try {
        const resp = await fetch('/api/model/stage-pull', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            provider,
            model_name: modelName,
            ssh_host: sshHost || undefined
          })
        });
        const d = await resp.json();
        if (box && code) {
          box.style.display = 'block';
          code.textContent = d.command;
          if (dispatchBtn) {
            dispatchBtn.style.display = d.ssh_dispatch_available ? 'inline-block' : 'none';
          }
        }
      } catch (e) {
        alert('Failed to stage pull command: ' + e.message);
      }
    });
  }

  const copyStagedCmdBtn = document.getElementById('copyStagedCmdBtn');
  if (copyStagedCmdBtn) {
    copyStagedCmdBtn.addEventListener('click', () => {
      const code = document.getElementById('stagedCommandCode');
      if (code) {
        navigator.clipboard.writeText(code.textContent);
        copyStagedCmdBtn.textContent = '[COPIED]';
        setTimeout(() => { copyStagedCmdBtn.textContent = 'COPY COMMAND'; }, 2000);
      }
    });
  }

  const dispatchSshBtn = document.getElementById('dispatchSshBtn');
  if (dispatchSshBtn) {
    dispatchSshBtn.addEventListener('click', async () => {
      const sshHost = document.getElementById('newNodeJump').value.trim();
      const code = document.getElementById('stagedCommandCode').textContent;
      const status = document.getElementById('dispatchStatus');
      if (status) {
        status.textContent = `Dispatching command to ${sshHost}...`;
        status.style.color = 'var(--accent)';
      }
      try {
        const resp = await fetch('/api/chat', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            command: `ssh -o StrictHostKeyChecking=no ${sshHost} "${code.replace(/"/g, '\\"')}"`
          })
        });
        if (status) {
          status.textContent = '[OK] Dispatched via sovereign session';
          status.style.color = 'var(--status-online)';
        }
      } catch (e) {
        if (status) {
          status.textContent = `[FAILED] Dispatch: ${e.message}`;
          status.style.color = 'var(--status-error)';
        }
      }
    });
  }

  // --- Dock Compute Node & Endpoints.conf Persistence ---
  const saveNodeBtn = document.getElementById('saveNodeBtn');
  if (saveNodeBtn) {
    saveNodeBtn.addEventListener('click', async () => {
      const tier = document.getElementById('newNodeTier').value;
      const name = document.getElementById('newNodeName').value.trim();
      const url = document.getElementById('newNodeUrl').value.trim();
      const model = document.getElementById('newNodeModel').value.trim();
      const context = parseInt(document.getElementById('newNodeContext').value, 10) || 12288;
      const hardware = document.getElementById('newNodeHardware').value.trim();
      const jump = document.getElementById('newNodeJump').value.trim();
      const sshTarget = (document.getElementById('newNodeSshTarget')?.value || '').trim();
      const nodeMode = (document.getElementById('newNodeMode')?.value || 'hybrid').trim();
      const enabled = document.getElementById('newNodeEnabled').checked;

      if (!url) {
        alert('Please specify a valid Target Endpoint URL');
        return;
      }

      saveNodeBtn.textContent = 'DOCKING...';
      saveNodeBtn.disabled = true;

      try {
        const resp = await fetch('/api/node/save', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            tier,
            name: name || undefined,
            url,
            model: model || undefined,
            context,
            hardware: hardware || undefined,
            jump_box: jump || undefined,
            ssh_target: sshTarget || undefined,
            node_mode: nodeMode || undefined,
            enabled
          })
        });

        if (resp.ok) {
          saveNodeBtn.textContent = '[DOCKED & SAVED]';
          setTimeout(() => {
            saveNodeBtn.textContent = 'DOCK NODE';
            saveNodeBtn.disabled = false;
            if (nodeModal) nodeModal.classList.remove('open');
            fetchStatus();
          }, 800);
        } else {
          saveNodeBtn.textContent = 'ERROR SAVING';
          saveNodeBtn.disabled = false;
        }
      } catch (err) {
        alert('Failed to save node: ' + err.message);
        saveNodeBtn.textContent = 'DOCK NODE';
        saveNodeBtn.disabled = false;
      }
    });
  }

  const btnEditEndpointsConf = document.getElementById('btnEditEndpointsConf');
  if (btnEditEndpointsConf) {
    btnEditEndpointsConf.addEventListener('click', () => {
      const openFn = window.openFile || window.openScriptInWorkbench;
      if (typeof openFn === 'function') {
        openFn('.george/endpoints.conf');
      } else {
        console.warn('Script editor workbench not initialized yet');
      }
    });
  }

  const btnConnectTunnel = document.getElementById('btnConnectTunnel');
  if (btnConnectTunnel) {
    btnConnectTunnel.addEventListener('click', async () => {
      btnConnectTunnel.textContent = 'CONNECTING...';
      try {
        await fetch('/api/tunnel/connect', { method: 'POST' });
      } catch (e) {}
      btnConnectTunnel.textContent = 'RE-ESTABLISH TUNNEL';
      fetchTunnelStatus();
      fetchStatus();
    });
  }

  // --- GPU Game Mode / Sovereign Standby Controller ---
  let isGameModeActive = false;
  let isGameModeTransitioning = false;

  function updateGameModeUI(gameMode, containerStatus) {
    if (isGameModeTransitioning) return;
    isGameModeActive = !!gameMode;

    const banner = document.getElementById('gameModeBanner');
    const badge = document.getElementById('gameModeBadge');
    const desc = document.getElementById('gameModeStatusDesc');
    const btnLabel = document.getElementById('gameModeBtnLabel');
    const chip = document.getElementById('drawerGameModeChip');
    const chipLabel = document.getElementById('drawerGameModeChipLabel');

    if (isGameModeActive) {
      if (banner) {
        banner.classList.add('game-active');
        banner.classList.remove('transitioning');
      }
      if (badge) badge.textContent = 'GAME MODE ACTIVE';
      if (desc) desc.textContent = 'GPU VRAM 100% released · Autonomics paused · Safe to game!';
      if (btnLabel) btnLabel.textContent = 'RESUME INFERENCE (LEAVE GAME MODE)';
      if (chip) chip.classList.add('active');
      if (chipLabel) chipLabel.textContent = 'GAME MODE: ON';
    } else {
      if (banner) {
        banner.classList.remove('game-active');
        banner.classList.remove('transitioning');
      }
      if (badge) badge.textContent = 'STANDBY READY';
      if (desc) desc.textContent = 'Inference active · VRAM allocated to sovereign models';
      if (btnLabel) btnLabel.textContent = 'FREE GPUS (GAME MODE)';
      if (chip) chip.classList.remove('active');
      if (chipLabel) chipLabel.textContent = 'GAME MODE: OFF';
    }
  }

  async function fetchGameModeStatus() {
    try {
      const resp = await fetch('/api/system/gamemode');
      if (resp.ok) {
        const data = await resp.json();
        updateGameModeUI(data.game_mode, data.inference_status);
      }
    } catch (e) {
      console.warn('Failed to fetch game mode status:', e);
    }
  }

  async function toggleGameModeAction() {
    if (isGameModeTransitioning) return;
    isGameModeTransitioning = true;

    const banner = document.getElementById('gameModeBanner');
    const btnLabel = document.getElementById('gameModeBtnLabel');
    const chipLabel = document.getElementById('drawerGameModeChipLabel');

    if (banner) banner.classList.add('transitioning');
    const targetAction = isGameModeActive ? 'resume' : 'pause';

    if (targetAction === 'pause') {
      if (btnLabel) btnLabel.textContent = 'RELEASING GPU VRAM...';
      if (chipLabel) chipLabel.textContent = 'PAUSING...';
    } else {
      if (btnLabel) btnLabel.textContent = 'RESTORING INFERENCE (INITIALIZING)...';
      if (chipLabel) chipLabel.textContent = 'RESTORING...';
    }

    try {
      const resp = await fetch('/api/system/gamemode', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: targetAction })
      });
      const data = await resp.json();

      if (targetAction === 'pause') {
        setTimeout(async () => {
          isGameModeTransitioning = false;
          await fetchGameModeStatus();
          await pollHeartbeat();
        }, 2000);
      } else {
        let attempts = 0;
        const checkInterval = setInterval(async () => {
          attempts++;
          try {
            const stResp = await fetch('/api/system/gamemode');
            if (stResp.ok) {
              const stData = await stResp.json();
              if (!stData.game_mode && stData.inference_status === 'running') {
                clearInterval(checkInterval);
                isGameModeTransitioning = false;
                updateGameModeUI(false, 'running');
                await pollHeartbeat();
                return;
              }
            }
          } catch (e) {}

          if (attempts >= 15) {
            clearInterval(checkInterval);
            isGameModeTransitioning = false;
            await fetchGameModeStatus();
            await pollHeartbeat();
          }
        }, 2000);
      }
    } catch (err) {
      console.error('Failed to toggle game mode:', err);
      isGameModeTransitioning = false;
      await fetchGameModeStatus();
    }
  }

  const btnToggleGameMode = document.getElementById('btnToggleGameMode');
  if (btnToggleGameMode) {
    btnToggleGameMode.addEventListener('click', toggleGameModeAction);
  }

  const drawerGameModeChip = document.getElementById('drawerGameModeChip');
  if (drawerGameModeChip) {
    drawerGameModeChip.addEventListener('click', toggleGameModeAction);
  }

  // --- Cron & Scheduled Sweeps Suite ---
  const btnShowPromptGen = document.getElementById('btnShowPromptGen');
  const btnNewCronJob = document.getElementById('btnNewCronJob');
  const cronGenCard = document.getElementById('cronGenCard');
  const cronPromptInput = document.getElementById('cronPromptInput');
  const btnCancelGen = document.getElementById('btnCancelGen');
  const btnSubmitGen = document.getElementById('btnSubmitGen');
  const cronEditCard = document.getElementById('cronEditCard');
  const cronEditTitle = document.getElementById('cronEditTitle');
  const cronJobName = document.getElementById('cronJobName');
  const cronJobInterval = document.getElementById('cronJobInterval');
  const intervalHelper = document.getElementById('intervalHelper');
  const cronJobDesc = document.getElementById('cronJobDesc');
  const cronJobCmd = document.getElementById('cronJobCmd');
  const cronJobIsSystem = document.getElementById('cronJobIsSystem');
  const btnCancelCronEdit = document.getElementById('btnCancelCronEdit');
  const btnSaveCronJob = document.getElementById('btnSaveCronJob');
  const cronJobList = document.getElementById('cronJobList');

  if (cronJobInterval && intervalHelper) {
    cronJobInterval.addEventListener('input', () => {
      const secs = parseInt(cronJobInterval.value, 10) || 0;
      if (secs < 60) {
        intervalHelper.textContent = `Every ${secs} seconds`;
      } else if (secs < 3600) {
        intervalHelper.textContent = `Every ${Math.round(secs / 60)} minute(s)`;
      } else {
        intervalHelper.textContent = `Every ${(secs / 3600).toFixed(1)} hour(s)`;
      }
    });
  }

  if (btnShowPromptGen && cronGenCard) {
    btnShowPromptGen.addEventListener('click', () => {
      cronGenCard.style.display = cronGenCard.style.display === 'none' ? 'block' : 'none';
      if (cronEditCard) cronEditCard.style.display = 'none';
      if (cronPromptInput) cronPromptInput.focus();
    });
  }

  if (btnCancelGen && cronGenCard) {
    btnCancelGen.addEventListener('click', () => {
      cronGenCard.style.display = 'none';
    });
  }

  if (btnSubmitGen && cronPromptInput) {
    btnSubmitGen.addEventListener('click', async () => {
      const prompt = cronPromptInput.value.trim();
      if (!prompt) return;
      btnSubmitGen.textContent = 'GENERATING WITH GEORGE...';
      btnSubmitGen.disabled = true;

      try {
        const resp = await fetch('/api/cron/generate', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ prompt })
        });
        if (resp.ok) {
          const data = await resp.json();
          if (data.job) {
            cronGenCard.style.display = 'none';
            cronEditCard.style.display = 'block';
            cronEditTitle.textContent = 'CONFIGURE GENERATED SWEEP';
            cronJobName.value = data.job.name || 'custom_sweep';
            cronJobInterval.value = data.job.interval || 300;
            cronJobInterval.dispatchEvent(new Event('input'));
            cronJobDesc.value = data.job.description || prompt;
            cronJobCmd.value = data.job.command || '';
            cronJobIsSystem.value = 'false';
          }
        }
      } catch (e) {
        alert('Failed to generate sweep: ' + e.message);
      } finally {
        btnSubmitGen.textContent = 'GENERATE SPECIFICATION';
        btnSubmitGen.disabled = false;
      }
    });
  }

  if (btnNewCronJob && cronEditCard) {
    btnNewCronJob.addEventListener('click', () => {
      cronEditCard.style.display = 'block';
      if (cronGenCard) cronGenCard.style.display = 'none';
      cronEditTitle.textContent = 'NEW AUTONOMIC SWEEP';
      cronJobName.value = '';
      cronJobName.readOnly = false;
      cronJobInterval.value = 60;
      cronJobInterval.dispatchEvent(new Event('input'));
      cronJobDesc.value = '';
      cronJobCmd.value = '#!/bin/bash\n# Autonomic scheduled sweep\necho "Running sweep at $(date)"\n';
      cronJobIsSystem.value = 'false';
      cronJobName.focus();
    });
  }

  if (btnCancelCronEdit && cronEditCard) {
    btnCancelCronEdit.addEventListener('click', () => {
      cronEditCard.style.display = 'none';
    });
  }

  if (btnSaveCronJob) {
    btnSaveCronJob.addEventListener('click', async () => {
      const name = (cronJobName.value || '').trim();
      const interval = parseInt(cronJobInterval.value, 10) || 60;
      const description = (cronJobDesc.value || '').trim();
      const command = (cronJobCmd.value || '').trim();
      const is_system = cronJobIsSystem.value === 'true';

      if (!name) {
        alert('Please specify a job name');
        return;
      }

      btnSaveCronJob.textContent = 'SAVING...';
      btnSaveCronJob.disabled = true;

      try {
        const resp = await fetch('/api/cron', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ name, interval, description, command, is_system })
        });
        if (resp.ok) {
          cronEditCard.style.display = 'none';
          loadCronJobs();
        } else {
          const err = await resp.text();
          alert('Failed to save job: ' + err);
        }
      } catch (e) {
        alert('Network error saving job: ' + e.message);
      } finally {
        btnSaveCronJob.textContent = 'SAVE SCHEDULED SWEEP';
        btnSaveCronJob.disabled = false;
      }
    });
  }

  async function loadCronJobs() {
    if (!cronJobList) return;
    try {
      const resp = await fetch('/api/cron');
      if (resp.ok) {
        const data = await resp.json();

        // Update Autonomic Daemon banner
        const daemonBanner = document.getElementById('daemonStatusBanner');
        const daemonDot = document.getElementById('daemonStatusDot');
        const daemonBadge = document.getElementById('daemonStatusBadge');
        if (daemonBanner && daemonBadge) {
          if (data.daemon_running) {
            daemonBanner.classList.remove('stopped');
            if (daemonDot) daemonDot.classList.remove('stopped');
            daemonBadge.className = 'daemon-status-badge running';
            daemonBadge.textContent = `● RUNNING${data.daemon_pid ? ` (PID ${data.daemon_pid})` : ''}`;
          } else {
            daemonBanner.classList.add('stopped');
            if (daemonDot) daemonDot.classList.add('stopped');
            daemonBadge.className = 'daemon-status-badge stopped';
            daemonBadge.textContent = '○ STOPPED';
          }
        }

        const qCronDot = document.getElementById('dotQuickCron');
        const qCronText = document.getElementById('textQuickCron');
        if (qCronDot && qCronText) {
          qCronDot.style.background = data.daemon_running ? '#00f0ff' : '#ff4444';
          qCronDot.style.boxShadow = data.daemon_running ? '0 0 6px #00f0ff' : 'none';
          qCronText.textContent = data.daemon_running ? 'CRON: ACTIVE' : 'CRON: INACTIVE';
        }

        cronJobList.innerHTML = '';

        let gateData = null;
        try {
          const gateResp = await fetch('/api/social/gate');
          if (gateResp.ok) {
            gateData = await gateResp.json();
          }
        } catch (e) {}

        if (gateData) {
          const gateCard = document.createElement('div');
          gateCard.className = 'broadcast-gate-module';
          gateCard.innerHTML = `
            <div class="gate-strip-primary">
              <div class="gate-module-label">
                <span class="gate-module-title">BROADCAST GATE</span>
                <span class="gate-status-pill ${gateData.global_enabled ? 'armed' : 'locked'}">
                  <span class="gate-led"></span>
                  ${gateData.global_enabled ? 'ARMED' : 'LOCKED'}
                </span>
              </div>
              <button class="gate-master-switch ${gateData.global_enabled ? 'armed' : 'locked'}" id="btn-toggle-global-gate" title="Toggle master outbound broadcast kill switch">
                ${gateData.global_enabled ? 'LOCK GATE' : 'ARM GATE'}
              </button>
            </div>
            <div class="gate-platform-strip">
              <button class="platform-switch ${gateData.x_enabled ? 'enabled' : 'disabled'} ${!gateData.global_enabled ? 'locked-out' : ''}" data-gate-plat="x" title="Toggle 𝕏 outbound endpoint">
                <span class="platform-led"></span>
                <span class="platform-name">𝕏</span>
              </button>
              <button class="platform-switch ${gateData.mastodon_enabled ? 'enabled' : 'disabled'} ${!gateData.global_enabled ? 'locked-out' : ''}" data-gate-plat="mastodon" title="Toggle Mastodon outbound endpoint">
                <span class="platform-led"></span>
                <span class="platform-name">MASTODON</span>
              </button>
              <button class="platform-switch ${gateData.bluesky_enabled ? 'enabled' : 'disabled'} ${!gateData.global_enabled ? 'locked-out' : ''}" data-gate-plat="bluesky" title="Toggle Bluesky outbound endpoint">
                <span class="platform-led"></span>
                <span class="platform-name">BLUESKY</span>
              </button>
            </div>
          `;

          const toggleBtn = gateCard.querySelector('#btn-toggle-global-gate');
          if (toggleBtn) {
            toggleBtn.addEventListener('click', async () => {
              toggleBtn.textContent = '...';
              try {
                await fetch('/api/social/gate/toggle', {
                  method: 'POST',
                  headers: { 'Content-Type': 'application/json' },
                  body: JSON.stringify({ target: 'global', enabled: !gateData.global_enabled })
                });
                loadCronJobs();
              } catch (e) {
                toggleBtn.textContent = 'ERR';
              }
            });
          }

          gateCard.querySelectorAll('[data-gate-plat]').forEach(btn => {
            btn.addEventListener('click', async () => {
              const plat = btn.dataset.gatePlat;
              const isCurrentlyActive = btn.classList.contains('enabled');
              btn.style.opacity = '0.5';
              try {
                await fetch('/api/social/gate/toggle', {
                  method: 'POST',
                  headers: { 'Content-Type': 'application/json' },
                  body: JSON.stringify({ target: plat, enabled: !isCurrentlyActive })
                });
                loadCronJobs();
              } catch (e) {
                btn.style.opacity = '1';
              }
            });
          });

          cronJobList.appendChild(gateCard);
        }

        if (!data.jobs || data.jobs.length === 0) {
          const emptyMsg = document.createElement('div');
          emptyMsg.className = 'item-meta';
          emptyMsg.textContent = 'No scheduled sweeps active.';
          cronJobList.appendChild(emptyMsg);
          return;
        }

        data.jobs.forEach(job => {
          const card = document.createElement('div');
          card.className = 'cron-job-card';

          const statusClass = job.last_run === 0 ? 'idle' : (job.exit_code === 0 ? 'success' : 'failed');
          const statusText = job.last_run === 0 ? 'IDLE' : (job.exit_code === 0 ? 'SUCCESS' : 'FAILED');

          const hasPlatforms = job.publish_x !== undefined;
          const platformBadgesHtml = hasPlatforms ? `
            <div class="cron-platform-badges">
              <span class="platform-pill ${job.publish_x ? 'active' : 'disabled'}" data-plat="x" title="Click to toggle 𝕏 broadcast for this job">
                𝕏: ${job.publish_x ? '● ENABLED' : '○ DISABLED'}
              </span>
              <span class="platform-pill ${job.publish_mastodon ? 'active' : 'disabled'}" data-plat="mastodon" title="Click to toggle Mastodon broadcast for this job">
                Mastodon: ${job.publish_mastodon ? '● ENABLED' : '○ DISABLED'}
              </span>
              <span class="platform-pill ${job.publish_bluesky ? 'active' : 'disabled'}" data-plat="bluesky" title="Click to toggle Bluesky broadcast for this job">
                Bluesky: ${job.publish_bluesky ? '● ENABLED' : '○ DISABLED'}
              </span>
              ${gateData && !gateData.global_enabled ? '<span style="font-size: 10px; color: var(--text-muted); align-self: center; font-style: italic;">(Global Gate Locked)</span>' : ''}
            </div>
          ` : '';

          card.innerHTML = `
            <div class="cron-job-header">
              <div class="cron-job-name">
                <span>${job.is_system ? 'SYS' : 'USR'}</span>
                <span>${escapeHtml(job.name)}</span>
              </div>
              <div class="cron-job-controls" style="display:flex; align-items:center; gap:8px;">
                <button class="cron-toggle-enabled-btn ${job.enabled ? 'enabled' : 'disabled'}" data-job="${escapeHtml(job.name)}" title="Click to ${job.enabled ? 'disable' : 'enable'} this cron job">
                  ${job.enabled ? '● ENABLED' : '○ DISABLED'}
                </button>
                <span class="cron-job-interval-badge">Every ${job.interval}s</span>
              </div>
            </div>
            <div class="cron-job-desc">${escapeHtml(job.description || '(No description provided)')}</div>
            ${platformBadgesHtml}
            <div class="cron-job-footer">
              <div class="cron-job-meta">
                <span class="cron-status-pill ${statusClass}">${statusText}</span>
                <span>Last: ${job.updated_at === 'Never' ? 'Never' : new Date(job.last_run * 1000).toLocaleTimeString()}</span>
              </div>
              <div class="cron-job-actions">
                <button class="mini-action run-btn">RUN NOW</button>
                <button class="mini-action edit-script-btn">EDIT SCRIPT</button>
                <button class="mini-action edit-btn">CONFIG</button>
                ${!job.is_system ? '<button class="mini-action danger delete-btn">DELETE</button>' : ''}
              </div>
            </div>
          `;

          const enBtn = card.querySelector('.cron-toggle-enabled-btn');
          if (enBtn) {
            enBtn.addEventListener('click', async (e) => {
              e.stopPropagation();
              enBtn.textContent = '...';
              try {
                const resp = await fetch(`/api/cron/job/${encodeURIComponent(job.name)}/toggle-enabled`, {
                  method: 'POST'
                });
                if (resp.ok) {
                  loadCronJobs();
                } else {
                  enBtn.textContent = 'ERR';
                }
              } catch (err) {
                enBtn.textContent = 'ERR';
              }
            });
          }

          if (hasPlatforms) {
            card.querySelectorAll('.platform-pill').forEach(pill => {
              pill.addEventListener('click', async (e) => {
                e.stopPropagation();
                const plat = pill.dataset.plat;
                const isCurrentlyActive = pill.classList.contains('active');
                pill.textContent = `${plat.toUpperCase()}: SAVING...`;
                try {
                  const resp = await fetch(`/api/cron/job/${encodeURIComponent(job.name)}/toggle-platform`, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ platform: plat, enabled: !isCurrentlyActive })
                  });
                  if (resp.ok) {
                    loadCronJobs();
                  } else {
                    pill.textContent = 'ERROR';
                  }
                } catch (e) {
                  pill.textContent = 'ERROR';
                }
              });
            });
          }

          card.querySelector('.run-btn').addEventListener('click', async () => {
            const btn = card.querySelector('.run-btn');
            btn.textContent = 'TRIGGERING...';
            btn.disabled = true;
            try {
              await fetch(`/api/cron/run/${encodeURIComponent(job.name)}`, { method: 'POST' });
              setTimeout(() => {
                btn.textContent = 'TRIGGERED';
                setTimeout(() => { btn.textContent = 'RUN NOW'; btn.disabled = false; loadCronJobs(); }, 2000);
              }, 600);
            } catch (e) {
              btn.textContent = 'ERROR';
              btn.disabled = false;
            }
          });

          card.querySelector('.edit-script-btn').addEventListener('click', () => {
            const scriptPath = job.is_system
              ? (job.name === 'research_publisher' ? '.george/cron_jobs/research_publisher.sh' : 'commands/cron.sh')
              : `.george/cron_jobs/${job.name}.sh`;
            if (window.openScriptInWorkbench) {
              window.openScriptInWorkbench(scriptPath);
            }
          });

          card.querySelector('.edit-btn').addEventListener('click', () => {
            cronEditCard.style.display = 'block';
            if (cronGenCard) cronGenCard.style.display = 'none';
            cronEditTitle.textContent = `EDIT SWEEP: ${job.name}`;
            cronJobName.value = job.name;
            cronJobName.readOnly = true;
            cronJobInterval.value = job.interval;
            cronJobInterval.dispatchEvent(new Event('input'));
            cronJobDesc.value = job.description || '';
            cronJobCmd.value = job.command || '';
            cronJobIsSystem.value = job.is_system ? 'true' : 'false';
            cronEditCard.scrollIntoView({ behavior: 'smooth' });
          });

          const delBtn = card.querySelector('.delete-btn');
          if (delBtn) {
            delBtn.addEventListener('click', async () => {
              if (confirm(`Delete custom scheduled sweep "${job.name}"?`)) {
                try {
                  const delResp = await fetch(`/api/cron/job/${encodeURIComponent(job.name)}`, { method: 'DELETE' });
                  if (delResp.ok) {
                    card.remove();
                  }
                } catch (e) {}
              }
            });
          }

          cronJobList.appendChild(card);
        });
      }
    } catch (e) {
      cronJobList.innerHTML = '<div class="item-meta">Failed to load cron sweeps.</div>';
    }
  }

  const btnStartDaemon = document.getElementById('btnStartDaemon');
  if (btnStartDaemon) {
    btnStartDaemon.addEventListener('click', async () => {
      btnStartDaemon.textContent = 'STARTING...';
      try {
        await fetch('/api/cron/daemon/start', { method: 'POST' });
      } catch (e) {}
      btnStartDaemon.textContent = '▶ START';
      loadCronJobs();
    });
  }

  const btnRestartDaemon = document.getElementById('btnRestartDaemon');
  if (btnRestartDaemon) {
    btnRestartDaemon.addEventListener('click', async () => {
      btnRestartDaemon.textContent = 'RESTARTING...';
      try {
        await fetch('/api/cron/daemon/restart', { method: 'POST' });
      } catch (e) {}
      btnRestartDaemon.textContent = 'RESTART';
      loadCronJobs();
    });
  }

  const btnStopDaemon = document.getElementById('btnStopDaemon');
  if (btnStopDaemon) {
    btnStopDaemon.addEventListener('click', async () => {
      btnStopDaemon.textContent = 'STOPPING...';
      try {
        await fetch('/api/cron/daemon/stop', { method: 'POST' });
      } catch (e) {}
      btnStopDaemon.textContent = 'STOP';
      loadCronJobs();
    });
  }

  // --- Event Bus Daemon Switch & Status Controls ---
  window.startEventBusDaemon = async function() {
    const btn = document.getElementById('btnStartEventBus');
    if (btn) btn.textContent = 'STARTING...';
    try {
      await fetch('/api/react/daemon/start', { method: 'POST' });
    } catch (e) {}
    if (btn) btn.textContent = 'START';
    await loadEventBusStatus();
    try {
      const tasksResp = await fetch('/api/tasks');
      if (tasksResp.ok) renderAutonomicTaskBay(await tasksResp.json());
    } catch (e) {}
  };

  window.restartEventBusDaemon = async function() {
    const btn = document.getElementById('btnRestartEventBus');
    if (btn) btn.textContent = 'RESTARTING...';
    try {
      await fetch('/api/react/daemon/restart', { method: 'POST' });
    } catch (e) {}
    if (btn) btn.textContent = 'RESTART';
    await loadEventBusStatus();
    try {
      const tasksResp = await fetch('/api/tasks');
      if (tasksResp.ok) renderAutonomicTaskBay(await tasksResp.json());
    } catch (e) {}
  };

  window.stopEventBusDaemon = async function() {
    const btn = document.getElementById('btnStopEventBus');
    if (btn) btn.textContent = 'STOPPING...';
    try {
      await fetch('/api/react/daemon/stop', { method: 'POST' });
    } catch (e) {}
    if (btn) btn.textContent = 'STOP';
    await loadEventBusStatus();
    try {
      const tasksResp = await fetch('/api/tasks');
      if (tasksResp.ok) renderAutonomicTaskBay(await tasksResp.json());
    } catch (e) {}
  };

  async function loadEventBusStatus() {
    const banner = document.getElementById('eventBusStatusBanner');
    const dot = document.getElementById('eventBusStatusDot');
    const badge = document.getElementById('eventBusStatusBadge');
    if (!banner || !badge) return;
    try {
      const resp = await fetch('/api/react/daemon/status');
      if (resp.ok) {
        const data = await resp.json();
        if (data.alive) {
          banner.classList.remove('stopped');
          if (dot) dot.classList.remove('stopped');
          badge.className = 'daemon-status-badge running';
          badge.textContent = `● ACTIVE${data.pid ? ` (PID ${data.pid})` : ''} · ${data.events_total || 0} Evts / ${data.reactions_total || 0} Rxs`;
        } else {
          banner.classList.add('stopped');
          if (dot) dot.classList.add('stopped');
          badge.className = 'daemon-status-badge stopped';
          badge.textContent = '○ INACTIVE';
        }
        const qDot = document.getElementById('dotQuickEventBus');
        const qText = document.getElementById('textQuickEventBus');
        if (qDot && qText) {
          qDot.style.background = data.alive ? '#00f0ff' : '#ff4444';
          qDot.style.boxShadow = data.alive ? '0 0 6px #00f0ff' : 'none';
          qText.textContent = data.alive ? `EB: ACTIVE` : 'EB: INACTIVE';
        }
      }
    } catch (e) {}
  }

  const btnStartEventBus = document.getElementById('btnStartEventBus');
  if (btnStartEventBus) {
    btnStartEventBus.addEventListener('click', window.startEventBusDaemon);
  }
  const btnRestartEventBus = document.getElementById('btnRestartEventBus');
  if (btnRestartEventBus) {
    btnRestartEventBus.addEventListener('click', window.restartEventBusDaemon);
  }
  const btnStopEventBus = document.getElementById('btnStopEventBus');
  if (btnStopEventBus) {
    btnStopEventBus.addEventListener('click', window.stopEventBusDaemon);
  }

  const btnQuickEventBus = document.getElementById('btnQuickEventBus');
  if (btnQuickEventBus) {
    btnQuickEventBus.addEventListener('click', async () => {
      const qText = document.getElementById('textQuickEventBus');
      if (qText && qText.textContent.includes('ACTIVE')) {
        await window.restartEventBusDaemon();
      } else {
        await window.startEventBusDaemon();
      }
    });
  }

  // Header quick-status lights: refresh on load and every 30s, independent of
  // the Tool Crib (they used to stay at the red HTML default until it opened).
  async function refreshQuickStatusLights() {
    const paint = (dotId, textId, label, alive) => {
      const d = document.getElementById(dotId), t = document.getElementById(textId);
      if (!d || !t) return;
      d.style.background = alive ? '#00f0ff' : '#ff4444';
      d.style.boxShadow = alive ? '0 0 6px #00f0ff' : 'none';
      t.textContent = `${label}: ${alive ? 'ACTIVE' : 'INACTIVE'}`;
    };
    try {
      const r = await fetch('/api/cron');
      if (r.ok) paint('dotQuickCron', 'textQuickCron', 'CRON', !!(await r.json()).daemon_running);
    } catch (e) {}
    try {
      const r = await fetch('/api/react/daemon/status');
      if (r.ok) paint('dotQuickEventBus', 'textQuickEventBus', 'EB', !!(await r.json()).alive);
    } catch (e) {}
  }
  refreshQuickStatusLights();
  setInterval(() => { if (!document.hidden) refreshQuickStatusLights(); }, 30000);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) refreshQuickStatusLights(); });

  const btnQuickCron = document.getElementById('btnQuickCron');
  if (btnQuickCron) {
    btnQuickCron.addEventListener('click', (e) => {
      if (e.shiftKey) {
        const qText = document.getElementById('textQuickCron');
        if (qText && qText.textContent.includes('ACTIVE')) {
          fetch('/api/cron/daemon/restart', { method: 'POST' }).then(() => loadCronJobs());
        } else {
          fetch('/api/cron/daemon/start', { method: 'POST' }).then(() => loadCronJobs());
        }
        return;
      }
      if (toolCribDrawer) {
        toolCribDrawer.classList.add('open');
        document.body.classList.add('drawer-open');
      }
      document.querySelectorAll('.drawer-tab-btn').forEach(b => b.classList.remove('active'));
      document.querySelectorAll('.drawer-pane').forEach(p => p.classList.remove('active'));
      const cronTab = document.querySelector('.drawer-tab-btn[data-pane="cron"]');
      if (cronTab) cronTab.classList.add('active');
      const cronPane = document.getElementById('pane-cron');
      if (cronPane) cronPane.classList.add('active');
      loadCronJobs();
    });
  }

  // --- Slash Commands Catalog & Real-Time Filter ---
  let cachedCommands = [];
  async function loadCommands() {
    const list = document.getElementById('commandCatalogList');
    if (!list) return;
    try {
      const resp = await fetch('/api/commands');
      if (resp.ok) {
        cachedCommands = await resp.json();
        renderCommands(cachedCommands);
      }
    } catch (e) {
      console.warn('Failed to load commands:', e);
    }
  }

  function renderCommands(commands) {
    const list = document.getElementById('commandCatalogList');
    if (!list) return;
    list.innerHTML = '';
    if (commands.length === 0) {
      list.innerHTML = '<div class="item-meta">No matching slash commands found.</div>';
      return;
    }

    commands.forEach(cmd => {
      const card = document.createElement('div');
      card.className = 'command-card';
      card.innerHTML = `
        <div class="command-card-left">
          <div class="command-card-header">
            <span class="command-card-name">${escapeHtml(cmd.command)}</span>
            <span class="command-card-usage">${escapeHtml(cmd.usage)}</span>
          </div>
          <div class="command-card-desc" title="${escapeHtml(cmd.desc)}">${escapeHtml(cmd.desc)}</div>
        </div>
        <button class="command-insert-btn" title="Stage command into prompt input">INSERT</button>
      `;

      card.querySelector('.command-insert-btn').addEventListener('click', (e) => {
        e.stopPropagation();
        if (promptInput) {
          promptInput.value = cmd.usage ? cmd.usage + ' ' : cmd.command + ' ';
          promptInput.focus();
          promptInput.style.height = 'auto';
          promptInput.style.height = Math.min(promptInput.scrollHeight, 180) + 'px';
          if (toolCribDrawer) toolCribDrawer.classList.remove('open');
        }
      });

      list.appendChild(card);
    });
  }

  const commandSearchInput = document.getElementById('commandSearchInput');
  if (commandSearchInput) {
    commandSearchInput.addEventListener('input', () => {
      const q = commandSearchInput.value.toLowerCase().trim();
      if (!q) {
        renderCommands(cachedCommands);
        return;
      }
      const filtered = cachedCommands.filter(c => 
        c.name.toLowerCase().includes(q) ||
        c.command.toLowerCase().includes(q) ||
        (c.usage && c.usage.toLowerCase().includes(q)) ||
        (c.desc && c.desc.toLowerCase().includes(q))
      );
      renderCommands(filtered);
    });
  }

  // Cross-link to BM25 in Chronicle tab
  const btnJumpSqliteBm25 = document.getElementById('btnJumpSqliteBm25');
  if (btnJumpSqliteBm25) {
    btnJumpSqliteBm25.addEventListener('click', () => {
      document.querySelectorAll('.drawer-tab-btn').forEach(b => {
        if (b.dataset.pane === 'chronicle') b.click();
      });
      document.querySelectorAll('.chronicle-tab-btn').forEach(b => {
        if (b.dataset.sub === 'sqlite') b.click();
      });
      const bm25Input = document.getElementById('bm25SearchInput');
      if (bm25Input) bm25Input.focus();
    });
  }

  // --- Agentic Research Graph Config Loader & Saver ---
  async function loadResearchConfig(domOverride) {
    const phasesDisp = document.getElementById('researchPhasesDisplay');
    const topicsArea = document.getElementById('researchCandidateTopics');
    const directivesArea = document.getElementById('researchDirectives');
    const tempInput = document.getElementById('researchTemperature');
    const tokensInput = document.getElementById('researchMaxTokens');
    const styleSelect = document.getElementById('researchDefaultStyle');
    const socialCheck = document.getElementById('researchPublishSocial');
    if (!topicsArea) return;

    const domainThemeTitles = {
      'academic': 'AI / ML SCIENCE',
      'engineering': 'SYSTEMS & SECURITY',
      'finance': 'FINANCE & MACRO',
      'gaming': 'GAMING & EMULATION',
      'general_sports_auto': 'SPORTS & AUTOMOTIVE',
      'sports_auto': 'SPORTS & AUTOMOTIVE'
    };

    const targetDom = domOverride || window.currentResearchDomain || 'academic';

    try {
      const resp = await fetch(`/api/research/config?domain=${encodeURIComponent(targetDom)}`);
      if (resp.ok) {
        const data = await resp.json();
        if (phasesDisp && data.phases) {
          phasesDisp.innerHTML = data.phases.map(p => `
            <div class="research-phase-pill">
              <span class="phase-pill-num">PHASE ${p.phase}</span>
              <span class="phase-pill-name">${escapeHtml(p.name)}</span>
              <span class="phase-pill-desc">${escapeHtml(p.desc)}</span>
            </div>
          `).join('');
        }
        if (topicsArea) topicsArea.value = (data.candidate_topics || []).join('\n');

        const activeDom = data.domain || data.target_domain || targetDom;
        window.currentResearchDomain = activeDom;
        window.currentTopicPoolFile = data.topic_file || (data.topics_file ? `.george/${data.topics_file}` : `.george/research_topics_${activeDom}.txt`);

        const topicPoolCount = document.getElementById('topicPoolCount');
        if (topicPoolCount && data.candidate_topics) {
          topicPoolCount.textContent = data.candidate_topics.length;
        }

        const domainTitleEl = document.getElementById('topicPoolDomainTitle');
        if (domainTitleEl) {
          domainTitleEl.textContent = domainThemeTitles[activeDom] || activeDom.toUpperCase();
        }

        const filePathEl = document.getElementById('topicPoolFilePath');
        if (filePathEl) {
          filePathEl.textContent = window.currentTopicPoolFile;
        }

        const vimCmdEl = document.getElementById('topicPoolVimCmd');
        if (vimCmdEl) {
          vimCmdEl.textContent = `./lodge /research edit ${activeDom}`;
        }

        const rawVimCmdEl = document.getElementById('topicPoolRawVimCmd');
        if (rawVimCmdEl) {
          rawVimCmdEl.textContent = `vim ${window.currentTopicPoolFile}`;
        }

        if (directivesArea) directivesArea.value = data.directives || '';
        if (tempInput) tempInput.value = data.temperature !== undefined ? data.temperature : 0.30;
        if (tokensInput) tokensInput.value = data.max_tokens !== undefined ? data.max_tokens : 4500;
        if (styleSelect) styleSelect.value = data.default_style || 'storyteller';
        if (socialCheck) socialCheck.checked = data.publish_social !== false;
      }
    } catch (e) {
      console.warn('Failed to load research config:', e);
    }
  }
  window.loadResearchConfig = loadResearchConfig;

  const btnToggleTopicPoolModal = document.getElementById('btnToggleTopicPoolModal');
  const topicPoolTray = document.getElementById('topicPoolTray');
  const btnCloseTopicPoolTray = document.getElementById('btnCloseTopicPoolTray');
  if (btnToggleTopicPoolModal && topicPoolTray) {
    btnToggleTopicPoolModal.addEventListener('click', () => {
      const isClosed = topicPoolTray.style.display === 'none';
      topicPoolTray.style.display = isClosed ? 'block' : 'none';
      if (isClosed) {
        loadResearchConfig(window.currentResearchDomain || 'academic');
      }
    });
  }
  if (btnCloseTopicPoolTray && topicPoolTray) {
    btnCloseTopicPoolTray.addEventListener('click', () => {
      topicPoolTray.style.display = 'none';
    });
  }

  const btnSaveResearchConfig = document.getElementById('btnSaveResearchConfig');
  if (btnSaveResearchConfig) {
    btnSaveResearchConfig.addEventListener('click', async () => {
      const topicsArea = document.getElementById('researchCandidateTopics');
      const directivesArea = document.getElementById('researchDirectives');
      const tempInput = document.getElementById('researchTemperature');
      const tokensInput = document.getElementById('researchMaxTokens');
      const styleSelect = document.getElementById('researchDefaultStyle');
      const socialCheck = document.getElementById('researchPublishSocial');
      const statusSpan = document.getElementById('researchSaveStatus');

      const topics = topicsArea ? topicsArea.value.split('\n').map(s => s.trim()).filter(Boolean) : [];
      const directives = directivesArea ? directivesArea.value.trim() : '';
      const temperature = tempInput ? (parseFloat(tempInput.value) || 0.30) : 0.30;
      const max_tokens = tokensInput ? (parseInt(tokensInput.value, 10) || 4500) : 4500;
      const default_style = styleSelect ? styleSelect.value : 'storyteller';
      const publish_social = socialCheck ? socialCheck.checked : true;
      const currentDom = window.currentResearchDomain || 'academic';

      btnSaveResearchConfig.disabled = true;
      try {
        const resp = await fetch('/api/research/config', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            domain: currentDom,
            set_active: true,
            candidate_topics: topics,
            directives,
            temperature,
            max_tokens,
            default_style,
            publish_social
          })
        });
        if (resp.ok) {
          const topicPoolCount = document.getElementById('topicPoolCount');
          if (topicPoolCount) topicPoolCount.textContent = topics.length;
          if (statusSpan) {
            statusSpan.textContent = `[SAVED ${topics.length} TOPICS IN ${currentDom.toUpperCase()}]`;
            setTimeout(() => { statusSpan.textContent = ''; }, 3000);
          }
        }
      } catch (e) {
        console.error('Failed to save research config:', e);
      } finally {
        btnSaveResearchConfig.disabled = false;
      }
    });
  }

  const btnEditTopicsVim = document.getElementById('btnEditTopicsVim');
  if (btnEditTopicsVim) {
    btnEditTopicsVim.addEventListener('click', () => {
      const openFn = window.openVimFile || window.openFile || window.openScriptInWorkbench;
      if (typeof openFn === 'function') {
        const targetFile = window.currentTopicPoolFile || (window.currentResearchDomain ? `.george/research_topics_${window.currentResearchDomain}.txt` : '.george/research_topics_academic.txt');
        openFn(targetFile);
      } else {
        console.warn('Script editor workbench not initialized yet');
      }
    });
  }

  const btnEditMandateVim = document.getElementById('btnEditMandateVim');
  if (btnEditMandateVim) {
    btnEditMandateVim.addEventListener('click', () => {
      const openFn = window.openFile || window.openScriptInWorkbench;
      if (typeof openFn === 'function') {
        openFn('soul.md');
      } else {
        console.warn('Script editor workbench not initialized yet');
      }
    });
  }

  // --- Craftsman In-Browser Multi-Tab Script & File Workbench (with Vim Mode) ---
  let editorTabs = [];
  let activeTabId = null;
  let tabCounter = 1;
  let vimMode = 'normal'; // 'normal' | 'insert' | 'visual' | 'visual_line' | 'visual_block'
  let visualAnchor = 0;
  let visualCursor = 0;
  let vimYankRegister = { text: '', isLine: false };
  let normalBuffer = '';
  let workspaceFilesCache = [];

  function initScriptEditor() {
    const modal = document.getElementById('scriptEditorModal');
    const pathInput = document.getElementById('scriptEditorPath');
    const dirtyEl = document.getElementById('scriptDirtyIndicator');
    const textarea = document.getElementById('scriptTextarea');
    const gutter = document.getElementById('scriptGutter');
    const vimBadge = document.getElementById('vimModeBadge');
    const statusMsg = document.getElementById('scriptStatusMsg');
    const cursorPos = document.getElementById('scriptCursorPos');
    const saveBtn = document.getElementById('btnSaveScript');
    const discardBtn = document.getElementById('btnDiscardScript');
    const closeBtn = document.getElementById('scriptEditorClose');
    const newTabBtn = document.getElementById('btnNewTab');
    const quickNewTabBtn = document.getElementById('btnQuickNewTab');
    const tabsListEl = document.getElementById('scriptTabsList');
    const depsListEl = document.getElementById('scriptDepsList');
    const toggleSidebarBtn = document.getElementById('btnToggleFileSidebar');
    const fileSidebar = document.getElementById('scriptFileSidebar');
    const fileSearchInput = document.getElementById('sidebarFileSearch');
    const filesListEl = document.getElementById('sidebarFilesList');
    const headerVimBtn = document.getElementById('headerVimWorkbenchBtn');
    const editResearchBtn = document.getElementById('btnEditResearchScript');
    const openEditorBtn = document.getElementById('btnOpenScriptEditor');
    const btnToggleSplit = document.getElementById('btnToggleSplitPane');
    const editorPaneLeft = document.getElementById('editorPaneLeft');
    const editorPaneSplitter = document.getElementById('editorPaneSplitter');
    const editorPaneRight = document.getElementById('editorPaneRight');
    const paneRightTabSelect = document.getElementById('paneRightTabSelect');
    const scriptGutterRight = document.getElementById('scriptGutterRight');
    const scriptTextareaRight = document.getElementById('scriptTextareaRight');
    const copilotPanel = document.getElementById('scriptCopilotPanel');
    const workbenchCard = modal ? modal.querySelector('.script-editor-card') : null;
    const btnToggleVimLegend = document.getElementById('btnToggleVimLegend');
    const vimLegendDropdown = document.getElementById('vimLegendDropdown');
    const btnCloseVimLegend = document.getElementById('btnCloseVimLegend');
    const linkVimLegend = document.getElementById('linkVimLegend');

    if (!modal || !textarea) return;

    function toggleVimLegend(show = null) {
      if (!vimLegendDropdown) return;
      const isOpen = vimLegendDropdown.style.display !== 'none';
      const willOpen = show !== null ? show : !isOpen;
      vimLegendDropdown.style.display = willOpen ? 'block' : 'none';
      if (btnToggleVimLegend) btnToggleVimLegend.classList.toggle('active', willOpen);
    }

    if (btnToggleVimLegend) btnToggleVimLegend.addEventListener('click', () => toggleVimLegend());
    if (btnCloseVimLegend) btnCloseVimLegend.addEventListener('click', () => toggleVimLegend(false));
    if (linkVimLegend) linkVimLegend.addEventListener('click', () => toggleVimLegend());

    let isSplitMode = false;
    let secondaryTabId = null;

    function recalculateWorkbenchGeometry() {
      if (!modal || !modal.classList.contains('open')) return;
      if (modal.classList.contains('fullscreen')) {
        if (workbenchCard) {
          workbenchCard.style.width = '100vw';
          workbenchCard.style.maxWidth = '100vw';
        }
        return;
      }

      // Font character width for 88 columns:
      // In 12px monospace, 1ch is ~7.4px.
      // 88ch is ~651px. Plus gutter (52px) + padding (32px) + scrollbar (16px) = ~755px.
      const sampleCh = 7.4;
      const singlePaneMin = Math.ceil(88 * sampleCh) + 104; // ~755px

      let editorBase = singlePaneMin;
      if (isSplitMode) {
        editorBase = (singlePaneMin * 2) + 6; // Two 88-column panes side by side + splitter
      }

      let extraSidebarWidth = 0;
      if (fileSidebar && fileSidebar.style.display !== 'none') {
        extraSidebarWidth += 240;
      }
      if (copilotPanel && copilotPanel.style.display !== 'none') {
        extraSidebarWidth += 400;
      }

      const totalNeeded = editorBase + extraSidebarWidth;
      const maxAvailable = Math.max(900, window.innerWidth - 32);
      const targetWidth = Math.min(maxAvailable, Math.max(totalNeeded, isSplitMode ? 1400 : 980));

      if (workbenchCard) {
        workbenchCard.style.width = `${targetWidth}px`;
        workbenchCard.style.maxWidth = `${maxAvailable}px`;
      }
    }

    function updateRightPaneGutter() {
      if (!scriptTextareaRight || !scriptGutterRight) return;
      const lineCount = scriptTextareaRight.value.split('\n').length || 1;
      const nums = [];
      for (let i = 1; i <= lineCount; i++) {
        nums.push(i);
      }
      scriptGutterRight.textContent = nums.join('\n');
      scriptGutterRight.scrollTop = scriptTextareaRight.scrollTop;
    }

    function syncSecondaryTabContent() {
      if (!isSplitMode || !paneRightTabSelect) return;
      const targetTab = editorTabs.find(t => t.id === secondaryTabId) || editorTabs[0];
      if (!targetTab) return;
      secondaryTabId = targetTab.id;
      paneRightTabSelect.value = targetTab.id;
      if (scriptTextareaRight) {
        scriptTextareaRight.value = targetTab.content || '';
        updateRightPaneGutter();
      }
    }

    function renderSecondaryTabOptions() {
      if (!paneRightTabSelect) return;
      paneRightTabSelect.innerHTML = editorTabs.map(t => {
        return `<option value="${t.id}">${escapeHtml(t.name)}</option>`;
      }).join('');
      if (secondaryTabId && editorTabs.some(t => t.id === secondaryTabId)) {
        paneRightTabSelect.value = secondaryTabId;
      } else {
        const otherTab = editorTabs.find(t => t.id !== activeTabId) || editorTabs[0];
        if (otherTab) {
          secondaryTabId = otherTab.id;
          paneRightTabSelect.value = otherTab.id;
        }
      }
      syncSecondaryTabContent();
    }

    function toggleSplitPane() {
      isSplitMode = !isSplitMode;
      if (btnToggleSplit) {
        btnToggleSplit.classList.toggle('active', isSplitMode);
      }

      if (isSplitMode) {
        if (editorPaneSplitter) editorPaneSplitter.style.display = 'flex';
        if (editorPaneRight) editorPaneRight.style.display = 'flex';
        if (editorPaneLeft) {
          editorPaneLeft.style.flex = '1';
          editorPaneLeft.style.width = '';
        }
        if (editorPaneRight) {
          editorPaneRight.style.flex = '1';
          editorPaneRight.style.width = '';
        }
        renderSecondaryTabOptions();
        if (statusMsg) {
          statusMsg.className = 'script-status-msg success';
          statusMsg.textContent = 'Dual-pane split active: side-by-side 88-column tiling enabled.';
        }
      } else {
        if (editorPaneSplitter) editorPaneSplitter.style.display = 'none';
        if (editorPaneRight) editorPaneRight.style.display = 'none';
        if (editorPaneLeft) {
          editorPaneLeft.style.flex = '1';
          editorPaneLeft.style.width = '';
        }
        if (statusMsg) {
          statusMsg.className = 'script-status-msg';
          statusMsg.textContent = 'Single-pane layout restored.';
        }
      }
      recalculateWorkbenchGeometry();
    }

    if (btnToggleSplit) {
      btnToggleSplit.addEventListener('click', toggleSplitPane);
    }

    if (paneRightTabSelect) {
      paneRightTabSelect.addEventListener('change', () => {
        secondaryTabId = paneRightTabSelect.value;
        syncSecondaryTabContent();
      });
    }

    if (scriptTextareaRight) {
      scriptTextareaRight.addEventListener('input', () => {
        const targetTab = editorTabs.find(t => t.id === secondaryTabId);
        if (targetTab) {
          targetTab.content = scriptTextareaRight.value;
          targetTab.dirty = true;
          if (targetTab.id === activeTabId && textarea) {
            textarea.value = scriptTextareaRight.value;
            updateGutter();
          }
          updateDirtyIndicator();
          renderTabs();
        }
        updateRightPaneGutter();
      });

      scriptTextareaRight.addEventListener('scroll', () => {
        if (scriptGutterRight) scriptGutterRight.scrollTop = scriptTextareaRight.scrollTop;
      });
    }

    // Splitter Dragging & 88-Column Constraints
    let isDraggingSplitter = false;
    let dragStartX = 0;
    let dragStartLeftWidth = 0;
    let dragStartRightWidth = 0;

    if (editorPaneSplitter) {
      editorPaneSplitter.addEventListener('mousedown', (e) => {
        if (!isSplitMode) return;
        isDraggingSplitter = true;
        dragStartX = e.clientX;
        dragStartLeftWidth = editorPaneLeft.getBoundingClientRect().width;
        dragStartRightWidth = editorPaneRight.getBoundingClientRect().width;
        editorPaneSplitter.classList.add('dragging');
        document.body.style.cursor = 'col-resize';
        e.preventDefault();
      });

      window.addEventListener('mousemove', (e) => {
        if (!isDraggingSplitter) return;
        const deltaX = e.clientX - dragStartX;
        const sampleCh = 7.4;
        const min88ColsWidth = Math.ceil(88 * sampleCh) + 104; // ~755px
        const hardMinFloor = 280;

        let newLeft = dragStartLeftWidth + deltaX;
        let newRight = dragStartRightWidth - deltaX;
        const totalAvail = dragStartLeftWidth + dragStartRightWidth;

        // User constraint:
        // A window can be shrunk < 88 columns ONLY if the other grows,
        // and in that case the other must still be at least 88 column widths!
        if (newLeft < min88ColsWidth) {
          newLeft = Math.max(hardMinFloor, newLeft);
          newRight = totalAvail - newLeft;
          if (newRight < min88ColsWidth) {
            newRight = min88ColsWidth;
            newLeft = totalAvail - newRight;
          }
        } else if (newRight < min88ColsWidth) {
          newRight = Math.max(hardMinFloor, newRight);
          newLeft = totalAvail - newRight;
          if (newLeft < min88ColsWidth) {
            newLeft = min88ColsWidth;
            newRight = totalAvail - newLeft;
          }
        }

        editorPaneLeft.style.flex = 'none';
        editorPaneLeft.style.width = `${newLeft}px`;
        editorPaneRight.style.flex = 'none';
        editorPaneRight.style.width = `${newRight}px`;
      });

      window.addEventListener('mouseup', () => {
        if (isDraggingSplitter) {
          isDraggingSplitter = false;
          editorPaneSplitter.classList.remove('dragging');
          document.body.style.cursor = '';
        }
      });
    }

    window.addEventListener('resize', recalculateWorkbenchGeometry);

    function getActiveTab() {
      return editorTabs.find(t => t.id === activeTabId) || null;
    }

    function updateGutter() {
      const lineCount = textarea.value.split('\n').length || 1;
      const nums = [];
      for (let i = 1; i <= lineCount; i++) {
        nums.push(i);
      }
      gutter.textContent = nums.join('\n');
      gutter.scrollTop = textarea.scrollTop;
    }

    function updateCursor() {
      const pos = textarea.selectionStart || 0;
      const lines = textarea.value.substring(0, pos).split('\n');
      const line = lines.length;
      const col = lines[lines.length - 1].length + 1;
      if (cursorPos) cursorPos.textContent = `Ln ${line}, Col ${col}`;
    }

    function updateDirtyIndicator() {
      const tab = getActiveTab();
      if (dirtyEl) {
        if (tab && tab.dirty) {
          dirtyEl.classList.add('active');
        } else {
          dirtyEl.classList.remove('active');
        }
      }
    }

    function setVimMode(mode) {
      vimMode = mode;
      normalBuffer = '';
      const tab = getActiveTab();
      if (tab) tab.vimMode = mode;

      if (vimBadge) {
        if (mode === 'normal') {
          vimBadge.className = 'vim-mode-badge normal';
          vimBadge.textContent = 'VIM: NORMAL';
          textarea.readOnly = true;
          if (statusMsg) statusMsg.textContent = '-- NORMAL --';
        } else if (mode === 'visual') {
          vimBadge.className = 'vim-mode-badge visual';
          vimBadge.textContent = 'VIM: VISUAL';
          textarea.readOnly = true;
          if (statusMsg) statusMsg.textContent = '-- VISUAL --';
        } else if (mode === 'visual_line') {
          vimBadge.className = 'vim-mode-badge visual-line';
          vimBadge.textContent = 'VIM: VISUAL LINE';
          textarea.readOnly = true;
          if (statusMsg) statusMsg.textContent = '-- VISUAL LINE --';
        } else if (mode === 'visual_block') {
          vimBadge.className = 'vim-mode-badge visual-block';
          vimBadge.textContent = 'VIM: VISUAL BLOCK';
          textarea.readOnly = true;
          if (statusMsg) statusMsg.textContent = '-- VISUAL BLOCK --';
        } else {
          vimBadge.className = 'vim-mode-badge insert';
          vimBadge.textContent = 'VIM: INSERT';
          textarea.readOnly = false;
          textarea.focus();
          if (statusMsg) statusMsg.textContent = '-- INSERT --';
        }
      }
    }

    if (vimBadge) {
      vimBadge.addEventListener('click', () => {
        if (vimMode === 'insert') {
          setVimMode('normal');
        } else if (vimMode === 'normal') {
          setVimMode('insert');
        } else {
          setVimMode('normal');
        }
      });
    }

    function updateVisualSelection() {
      const text = textarea.value;
      const len = text.length;
      let start = Math.min(visualAnchor, visualCursor);
      let end = Math.max(visualAnchor, visualCursor);

      if (vimMode === 'visual_line') {
        const lineStart = text.lastIndexOf('\n', start - 1);
        start = lineStart !== -1 ? lineStart + 1 : 0;
        const lineEnd = text.indexOf('\n', end);
        end = lineEnd !== -1 ? lineEnd + 1 : len;
      } else if (vimMode === 'visual') {
        if (start === end && end < len) {
          end = start + 1;
        }
      }

      textarea.focus();
      textarea.setSelectionRange(start, end);
      updateCursor();

      const selectedText = text.substring(start, end);
      const lineCount = selectedText.split('\n').length;
      const charCount = selectedText.length;
      if (statusMsg) {
        if (vimMode === 'visual_line') {
          statusMsg.textContent = `-- VISUAL LINE -- (${lineCount} lines)`;
        } else if (vimMode === 'visual_block') {
          statusMsg.textContent = `-- VISUAL BLOCK -- (${lineCount} lines, ${charCount} chars)`;
        } else {
          statusMsg.textContent = `-- VISUAL -- (${charCount} chars)`;
        }
      }
    }

    function getMotionPos(motion, currentPos) {
      const text = textarea.value;
      const len = text.length;
      let p = currentPos;

      if (motion === 'h' || motion === 'ArrowLeft') {
        return Math.max(0, p - 1);
      } else if (motion === 'l' || motion === 'ArrowRight') {
        return Math.min(len, p + 1);
      } else if (motion === '0') {
        const prevNl = text.lastIndexOf('\n', p - 1);
        return prevNl !== -1 ? prevNl + 1 : 0;
      } else if (motion === '^') {
        const lineStart = text.lastIndexOf('\n', p - 1) + 1;
        let nextNl = text.indexOf('\n', lineStart);
        if (nextNl === -1) nextNl = len;
        const line = text.substring(lineStart, nextNl);
        const m = line.match(/^\s*/);
        return lineStart + (m ? m[0].length : 0);
      } else if (motion === '$') {
        const nextNl = text.indexOf('\n', p);
        return nextNl !== -1 ? nextNl : len;
      } else if (motion === 'w') {
        let i = p;
        while (i < len && !/\s/.test(text[i])) i++;
        while (i < len && /\s/.test(text[i])) i++;
        return i;
      } else if (motion === 'b') {
        let i = Math.max(0, p - 1);
        while (i > 0 && /\s/.test(text[i])) i--;
        while (i > 0 && !/\s/.test(text[i - 1])) i--;
        return i;
      } else if (motion === 'e') {
        let i = p + 1;
        while (i < len && /\s/.test(text[i])) i++;
        while (i < len && !/\s/.test(text[i])) i++;
        return Math.max(p, i - 1);
      } else if (motion === 'j' || motion === 'ArrowDown') {
        const curLineStart = text.lastIndexOf('\n', p - 1) + 1;
        const col = p - curLineStart;
        const nextLineStart = text.indexOf('\n', p);
        if (nextLineStart === -1) return p;
        const afterNext = nextLineStart + 1;
        const nextLineEnd = text.indexOf('\n', afterNext);
        const nextLineLen = (nextLineEnd !== -1 ? nextLineEnd : len) - afterNext;
        return afterNext + Math.min(col, nextLineLen);
      } else if (motion === 'k' || motion === 'ArrowUp') {
        const curLineStart = text.lastIndexOf('\n', p - 1) + 1;
        if (curLineStart === 0) return p;
        const col = p - curLineStart;
        const prevLineEnd = curLineStart - 1;
        const prevLineStart = text.lastIndexOf('\n', prevLineEnd - 1) + 1;
        const prevLineLen = prevLineEnd - prevLineStart;
        return prevLineStart + Math.min(col, prevLineLen);
      } else if (motion === '{') {
        let i = text.lastIndexOf('\n\n', p - 2);
        return i !== -1 ? i + 1 : 0;
      } else if (motion === '}') {
        let i = text.indexOf('\n\n', p);
        return i !== -1 ? i + 1 : len;
      }
      return p;
    }

    function visualDelete() {
      const selStart = textarea.selectionStart;
      const selEnd = textarea.selectionEnd;
      if (selStart === selEnd) return;

      const text = textarea.value;
      const deleted = text.substring(selStart, selEnd);
      vimYankRegister = { text: deleted, isLine: vimMode === 'visual_line' };
      try { navigator.clipboard.writeText(deleted); } catch(e) {}

      textarea.value = text.substring(0, selStart) + text.substring(selEnd);
      textarea.setSelectionRange(selStart, selStart);

      const tab = getActiveTab();
      if (tab) {
        tab.dirty = true;
        tab.content = textarea.value;
      }
      updateDirtyIndicator();
      renderTabs();
      updateGutter();
      updateCursor();
      setVimMode('normal');

      const lineCount = deleted.split('\n').length;
      if (statusMsg) {
        statusMsg.textContent = lineCount > 1 ? `${lineCount} lines deleted` : `${deleted.length} chars deleted`;
      }
    }

    function visualYank() {
      const selStart = textarea.selectionStart;
      const selEnd = textarea.selectionEnd;
      const text = textarea.value;
      const yanked = text.substring(selStart, selEnd);
      vimYankRegister = { text: yanked, isLine: vimMode === 'visual_line' };
      try { navigator.clipboard.writeText(yanked); } catch(e) {}

      textarea.setSelectionRange(selStart, selStart);
      setVimMode('normal');

      const lineCount = yanked.split('\n').length;
      if (statusMsg) {
        statusMsg.textContent = lineCount > 1 ? `${lineCount} lines yanked` : `${yanked.length} chars yanked`;
      }
    }

    function visualChange() {
      const selStart = textarea.selectionStart;
      const selEnd = textarea.selectionEnd;
      const text = textarea.value;
      const deleted = text.substring(selStart, selEnd);
      vimYankRegister = { text: deleted, isLine: vimMode === 'visual_line' };
      try { navigator.clipboard.writeText(deleted); } catch(e) {}

      textarea.value = text.substring(0, selStart) + text.substring(selEnd);
      textarea.setSelectionRange(selStart, selStart);

      const tab = getActiveTab();
      if (tab) {
        tab.dirty = true;
        tab.content = textarea.value;
      }
      updateDirtyIndicator();
      renderTabs();
      updateGutter();
      updateCursor();
      setVimMode('insert');
    }

    function visualIndent() {
      const text = textarea.value;
      const selStart = textarea.selectionStart;
      const selEnd = textarea.selectionEnd;

      const lineStart = text.lastIndexOf('\n', selStart - 1) + 1;
      let lineEnd = text.indexOf('\n', selEnd);
      if (lineEnd === -1) lineEnd = text.length;

      const block = text.substring(lineStart, lineEnd);
      const lines = block.split('\n');
      const indentedLines = lines.map(line => '  ' + line);
      const newBlock = indentedLines.join('\n');

      textarea.value = text.substring(0, lineStart) + newBlock + text.substring(lineEnd);
      const newSelEnd = lineStart + newBlock.length;
      textarea.setSelectionRange(lineStart, newSelEnd);

      const tab = getActiveTab();
      if (tab) { tab.dirty = true; tab.content = textarea.value; }
      updateDirtyIndicator();
      renderTabs();
      updateGutter();
      updateCursor();
      if (statusMsg) statusMsg.textContent = `> ${lines.length} lines indented (+2 spaces)`;
    }

    function visualDedent() {
      const text = textarea.value;
      const selStart = textarea.selectionStart;
      const selEnd = textarea.selectionEnd;

      const lineStart = text.lastIndexOf('\n', selStart - 1) + 1;
      let lineEnd = text.indexOf('\n', selEnd);
      if (lineEnd === -1) lineEnd = text.length;

      const block = text.substring(lineStart, lineEnd);
      const lines = block.split('\n');
      const dedentedLines = lines.map(line => {
        if (line.startsWith('  ')) return line.substring(2);
        if (line.startsWith(' ')) return line.substring(1);
        if (line.startsWith('\t')) return line.substring(1);
        return line;
      });
      const newBlock = dedentedLines.join('\n');

      textarea.value = text.substring(0, lineStart) + newBlock + text.substring(lineEnd);
      const newSelEnd = lineStart + newBlock.length;
      textarea.setSelectionRange(lineStart, newSelEnd);

      const tab = getActiveTab();
      if (tab) { tab.dirty = true; tab.content = textarea.value; }
      updateDirtyIndicator();
      renderTabs();
      updateGutter();
      updateCursor();
      if (statusMsg) statusMsg.textContent = `< ${lines.length} lines dedented`;
    }

    function visualToggleComment() {
      const tab = getActiveTab();
      const path = tab ? tab.path : '';
      const commentToken = (path.endsWith('.rs') || path.endsWith('.js') || path.endsWith('.ts') || path.endsWith('.c') || path.endsWith('.cpp')) ? '// ' : '# ';

      const text = textarea.value;
      const selStart = textarea.selectionStart;
      const selEnd = textarea.selectionEnd;

      const lineStart = text.lastIndexOf('\n', selStart - 1) + 1;
      let lineEnd = text.indexOf('\n', selEnd);
      if (lineEnd === -1) lineEnd = text.length;

      const block = text.substring(lineStart, lineEnd);
      const lines = block.split('\n');
      const trimmedToken = commentToken.trim();
      const allCommented = lines.every(l => l.trim().length === 0 || l.trim().startsWith(trimmedToken));

      const newLines = lines.map(l => {
        if (l.trim().length === 0) return l;
        if (allCommented) {
          const idx = l.indexOf(trimmedToken);
          if (idx !== -1) {
            let after = l.substring(idx + trimmedToken.length);
            if (after.startsWith(' ')) after = after.substring(1);
            return l.substring(0, idx) + after;
          }
          return l;
        } else {
          return commentToken + l;
        }
      });

      const newBlock = newLines.join('\n');
      textarea.value = text.substring(0, lineStart) + newBlock + text.substring(lineEnd);
      textarea.setSelectionRange(lineStart, lineStart + newBlock.length);

      if (tab) { tab.dirty = true; tab.content = textarea.value; }
      updateDirtyIndicator();
      renderTabs();
      updateGutter();
      updateCursor();
      if (statusMsg) {
        statusMsg.textContent = allCommented ? `Uncommented ${lines.length} lines` : `Commented ${lines.length} lines (${commentToken})`;
      }
    }

    function visualBlockPrepend() {
      const prefix = prompt('Block Insert: Text to prepend to every selected line:');
      if (prefix === null || prefix === '') return;

      const text = textarea.value;
      const selStart = textarea.selectionStart;
      const selEnd = textarea.selectionEnd;

      const lineStart = text.lastIndexOf('\n', selStart - 1) + 1;
      let lineEnd = text.indexOf('\n', selEnd);
      if (lineEnd === -1) lineEnd = text.length;

      const block = text.substring(lineStart, lineEnd);
      const lines = block.split('\n');
      const newLines = lines.map(l => prefix + l);
      const newBlock = newLines.join('\n');

      textarea.value = text.substring(0, lineStart) + newBlock + text.substring(lineEnd);
      textarea.setSelectionRange(lineStart, lineStart + newBlock.length);

      const tab = getActiveTab();
      if (tab) { tab.dirty = true; tab.content = textarea.value; }
      updateDirtyIndicator();
      renderTabs();
      updateGutter();
      updateCursor();
      setVimMode('normal');
      if (statusMsg) statusMsg.textContent = `Prepended '${prefix}' across ${lines.length} lines`;
    }

    function visualBlockAppend() {
      const suffix = prompt('Block Append: Text to append to every selected line:');
      if (suffix === null || suffix === '') return;

      const text = textarea.value;
      const selStart = textarea.selectionStart;
      const selEnd = textarea.selectionEnd;

      const lineStart = text.lastIndexOf('\n', selStart - 1) + 1;
      let lineEnd = text.indexOf('\n', selEnd);
      if (lineEnd === -1) lineEnd = text.length;

      const block = text.substring(lineStart, lineEnd);
      const lines = block.split('\n');
      const newLines = lines.map(l => l + suffix);
      const newBlock = newLines.join('\n');

      textarea.value = text.substring(0, lineStart) + newBlock + text.substring(lineEnd);
      textarea.setSelectionRange(lineStart, lineStart + newBlock.length);

      const tab = getActiveTab();
      if (tab) { tab.dirty = true; tab.content = textarea.value; }
      updateDirtyIndicator();
      renderTabs();
      updateGutter();
      updateCursor();
      setVimMode('normal');
      if (statusMsg) statusMsg.textContent = `Appended '${suffix}' across ${lines.length} lines`;
    }

    function visualTransformCase(type) {
      const selStart = textarea.selectionStart;
      const selEnd = textarea.selectionEnd;
      const text = textarea.value;
      const selected = text.substring(selStart, selEnd);
      let transformed = selected;
      if (type === 'upper') {
        transformed = selected.toUpperCase();
      } else if (type === 'lower') {
        transformed = selected.toLowerCase();
      } else if (type === 'toggle') {
        transformed = selected.split('').map(c => c === c.toUpperCase() ? c.toLowerCase() : c.toUpperCase()).join('');
      }

      textarea.value = text.substring(0, selStart) + transformed + text.substring(selEnd);
      textarea.setSelectionRange(selStart, selStart + transformed.length);

      const tab = getActiveTab();
      if (tab) { tab.dirty = true; tab.content = textarea.value; }
      updateDirtyIndicator();
      renderTabs();
      updateGutter();
      updateCursor();
      if (statusMsg) statusMsg.textContent = `Case transformed (${type})`;
    }

    function visualSurround(char) {
      const p = getMatchingPairs(char);
      const selStart = textarea.selectionStart;
      const selEnd = textarea.selectionEnd;
      const text = textarea.value;
      const selected = text.substring(selStart, selEnd);

      const newText = text.substring(0, selStart) + p.open + selected + p.close + text.substring(selEnd);
      textarea.value = newText;
      textarea.setSelectionRange(selStart, selEnd + p.open.length + p.close.length);

      const tab = getActiveTab();
      if (tab) { tab.dirty = true; tab.content = textarea.value; }
      updateDirtyIndicator();
      renderTabs();
      updateGutter();
      updateCursor();
      setVimMode('normal');
      if (statusMsg) statusMsg.textContent = `Surrounded selection with ${p.open}...${p.close}`;
    }

    function deleteCharUnderCursor() {
      const pos = textarea.selectionStart;
      const text = textarea.value;
      if (pos >= text.length) return;
      const char = text[pos];
      vimYankRegister = { text: char, isLine: false };
      try { navigator.clipboard.writeText(char); } catch(e) {}
      textarea.value = text.substring(0, pos) + text.substring(pos + 1);
      textarea.setSelectionRange(pos, pos);

      const tab = getActiveTab();
      if (tab) { tab.dirty = true; tab.content = textarea.value; }
      updateDirtyIndicator();
      renderTabs();
      updateGutter();
      updateCursor();
      if (statusMsg) statusMsg.textContent = `Deleted '${char}'`;
    }

    function pasteYankRegister(before = false) {
      const clipText = vimYankRegister.text;
      if (!clipText) {
        if (navigator.clipboard && navigator.clipboard.readText) {
          navigator.clipboard.readText().then(t => {
            if (t) doPaste(t, t.includes('\n'), before);
          }).catch(() => {});
        }
        return;
      }
      doPaste(clipText, vimYankRegister.isLine, before);
    }

    function doPaste(pasteText, isLine, before) {
      const text = textarea.value;
      const pos = textarea.selectionStart;

      if (isLine) {
        const curLineStart = text.lastIndexOf('\n', pos - 1) + 1;
        const curLineEnd = text.indexOf('\n', pos);
        const targetPos = before ? curLineStart : (curLineEnd !== -1 ? curLineEnd + 1 : text.length);
        const formattedPaste = pasteText.endsWith('\n') ? pasteText : (pasteText + '\n');
        const newText = text.substring(0, targetPos) + formattedPaste + text.substring(targetPos);
        textarea.value = newText;
        textarea.setSelectionRange(targetPos, targetPos);
      } else {
        const targetPos = before ? pos : Math.min(pos + 1, text.length);
        const newText = text.substring(0, targetPos) + pasteText + text.substring(targetPos);
        textarea.value = newText;
        textarea.setSelectionRange(targetPos + pasteText.length, targetPos + pasteText.length);
      }

      const tab = getActiveTab();
      if (tab) { tab.dirty = true; tab.content = textarea.value; }
      updateDirtyIndicator();
      renderTabs();
      updateGutter();
      updateCursor();
      if (statusMsg) statusMsg.textContent = `Pasted ${pasteText.split('\n').length} line(s)`;
    }

    function openNewLine(above = false) {
      const text = textarea.value;
      const pos = textarea.selectionStart;
      const curLineStart = text.lastIndexOf('\n', pos - 1) + 1;
      const curLineEnd = text.indexOf('\n', pos);

      if (above) {
        const newText = text.substring(0, curLineStart) + '\n' + text.substring(curLineStart);
        textarea.value = newText;
        textarea.setSelectionRange(curLineStart, curLineStart);
      } else {
        const insertAt = curLineEnd !== -1 ? curLineEnd : text.length;
        const newText = text.substring(0, insertAt) + '\n' + text.substring(insertAt);
        textarea.value = newText;
        textarea.setSelectionRange(insertAt + 1, insertAt + 1);
      }

      const tab = getActiveTab();
      if (tab) { tab.dirty = true; tab.content = textarea.value; }
      updateDirtyIndicator();
      renderTabs();
      updateGutter();
      updateCursor();
      setVimMode('insert');
    }

    function undoLastAction() {
      textarea.focus();
      try { document.execCommand('undo'); } catch(e) {}
      const tab = getActiveTab();
      if (tab) { tab.content = textarea.value; tab.dirty = true; }
      updateDirtyIndicator();
      renderTabs();
      updateGutter();
      updateCursor();
      if (statusMsg) statusMsg.textContent = 'Undo';
    }

    function redoLastAction() {
      textarea.focus();
      try { document.execCommand('redo'); } catch(e) {}
      const tab = getActiveTab();
      if (tab) { tab.content = textarea.value; tab.dirty = true; }
      updateDirtyIndicator();
      renderTabs();
      updateGutter();
      updateCursor();
      if (statusMsg) statusMsg.textContent = 'Redo';
    }

    function renderTabs() {
      if (!tabsListEl) return;
      tabsListEl.innerHTML = editorTabs.map(t => {
        const isActive = t.id === activeTabId;
        const dirtyClass = t.dirty ? ' dirty' : '';
        return `
          <div class="script-tab${isActive ? ' active' : ''}${dirtyClass}" data-tab-id="${t.id}">
            <span class="tab-name" title="${escapeHtml(t.path)}">${escapeHtml(t.name)}</span>
            <span class="tab-dirty">●</span>
            <button class="tab-close" data-close-id="${t.id}" title="Close tab">✕</button>
          </div>
        `;
      }).join('');

      tabsListEl.querySelectorAll('.script-tab').forEach(el => {
        el.addEventListener('click', (e) => {
          if (e.target.classList.contains('tab-close')) return;
          const tid = el.getAttribute('data-tab-id');
          if (tid !== activeTabId) switchTab(tid);
        });
      });

      tabsListEl.querySelectorAll('.tab-close').forEach(btn => {
        btn.addEventListener('click', (e) => {
          e.stopPropagation();
          const tid = btn.getAttribute('data-close-id');
          closeTab(tid);
        });
      });

      if (isSplitMode) {
        renderSecondaryTabOptions();
      }
    }

    function parseDepsFromContent(content) {
      const deps = [];
      const seen = new Set();
      const lines = content.split('\n');
      for (const line of lines) {
        const trimmed = line.trim();
        if (trimmed.startsWith('#')) continue;
        const m = trimmed.match(/^(?:source|\.)\s+["']?([^"'\s]+)["']?/);
        if (m && m[1]) {
          let target = m[1];
          if (target.includes(' 2>')) target = target.split(' 2>')[0];
          if (target.includes(' ||')) target = target.split(' ||')[0];
          target = target.replace(/["']/g, '').trim();
          target = target.replace(/^\$LODGE_DIR\//, '')
                         .replace(/^\$\{LODGE_DIR\}\//, '')
                         .replace(/^\$\{LODGE_DIR:-\.\}\//, '')
                         .replace(/^\$HOME\/blue-lodge\//, '')
                         .replace(/^\.\//, '');
          if (target && !seen.has(target)) {
            seen.add(target);
            deps.push({ path: target, name: target.split('/').pop(), raw: trimmed });
          }
        }
      }
      return deps;
    }

    function renderDeps(deps) {
      if (!depsListEl) return;
      if (!deps || deps.length === 0) {
        depsListEl.innerHTML = '<span class="deps-none">(No source statements in buffer)</span>';
        return;
      }
      depsListEl.innerHTML = deps.map(d => `
        <button class="dep-jump-pill" data-dep-path="${escapeHtml(d.path)}" title="Click to open ${escapeHtml(d.path)} in a new tab">
          ↗ ${escapeHtml(d.path)}
        </button>
      `).join('');

      depsListEl.querySelectorAll('.dep-jump-pill').forEach(btn => {
        btn.addEventListener('click', () => {
          const path = btn.getAttribute('data-dep-path');
          if (path) openFile(path);
        });
      });
    }

    async function resolveDepsForTab(tab) {
      tab.deps = parseDepsFromContent(tab.content);
      if (tab.id === activeTabId) renderDeps(tab.deps);

      try {
        const resp = await fetch(`/api/file/resolve-deps?path=${encodeURIComponent(tab.path)}`);
        if (resp.ok) {
          const data = await resp.json();
          if (data.deps && data.deps.length > 0) {
            tab.deps = data.deps;
            if (tab.id === activeTabId) renderDeps(tab.deps);
          }
        }
      } catch (e) {
        // Local regex fallback active
      }
    }

    function createTab(filePath, content = '', isNew = false, autoOpen = true) {
      const tabId = 'tab_' + (tabCounter++);
      const filename = filePath.split('/').pop() || 'untitled.sh';
      const tab = {
        id: tabId,
        path: filePath,
        name: filename,
        content: content,
        initialContent: content,
        dirty: false,
        vimMode: 'insert',
        cursor: 0,
        scrollTop: 0,
        isNew: isNew,
        deps: []
      };
      editorTabs.push(tab);
      if (autoOpen && !modal.classList.contains('open')) {
        modal.classList.add('open');
        recalculateWorkbenchGeometry();
      }
      renderTabs();
      switchTab(tabId);
      if (!isNew && filePath) {
        resolveDepsForTab(tab);
      }
      return tab;
    }

    function switchTab(tabId) {
      const curTab = getActiveTab();
      if (curTab && textarea) {
        curTab.content = textarea.value;
        curTab.cursor = textarea.selectionStart || 0;
        curTab.scrollTop = textarea.scrollTop || 0;
      }

      activeTabId = tabId;
      const targetTab = getActiveTab();
      if (!targetTab) return;

      if (pathInput) pathInput.value = targetTab.path;
      if (textarea) {
        textarea.value = targetTab.content;
        textarea.scrollTop = targetTab.scrollTop || 0;
        textarea.setSelectionRange(targetTab.cursor || 0, targetTab.cursor || 0);
      }

      updateDirtyIndicator();
      updateGutter();
      updateCursor();
      setVimMode(targetTab.vimMode || 'insert');
      renderTabs();
      renderDeps(targetTab.deps || []);
      if (statusMsg) {
        statusMsg.textContent = targetTab.isNew ? `New buffer: ${targetTab.name}` : `Active: ${targetTab.path}`;
        statusMsg.className = 'script-status-msg';
      }
      if (window.updateCopilotContextBadge) {
        window.updateCopilotContextBadge();
      }
      if (currentEditorEngine === 'nvim' && targetTab.path) {
        initNvimTerminal(targetTab.path);
      }
    }

    function closeTab(tabId, force = false) {
      const tab = editorTabs.find(t => t.id === tabId);
      if (!tab) return;
      const isUneditedNewTab = tab.isNew && tab.initialContent && tab.content === tab.initialContent;
      if (!force && tab.dirty && !isUneditedNewTab) {
        if (!confirm(`Discard unsaved changes to "${tab.name}"?`)) {
          return;
        }
      }
      const idx = editorTabs.findIndex(t => t.id === tabId);
      editorTabs.splice(idx, 1);
      if (editorTabs.length === 0) {
        activeTabId = null;
        modal.classList.remove('open');
        if (statusMsg) {
          statusMsg.className = 'script-status-msg';
          statusMsg.textContent = 'All buffers closed.';
        }
      } else {
        const nextTab = editorTabs[Math.max(0, idx - 1)];
        switchTab(nextTab.id);
      }
      renderTabs();
    }

    async function openFile(filePath) {
      const existing = editorTabs.find(t => t.path === filePath);
      if (existing) {
        modal.classList.add('open');
        recalculateWorkbenchGeometry();
        switchTab(existing.id);
        return existing;
      }

      modal.classList.add('open');
      recalculateWorkbenchGeometry();
      if (statusMsg) {
        statusMsg.textContent = `Loading ${filePath}...`;
        statusMsg.className = 'script-status-msg';
      }

      try {
        const resp = await fetch(`/api/file/read?path=${encodeURIComponent(filePath)}`);
        if (resp.ok) {
          const data = await resp.json();
          const tab = createTab(data.path || filePath, data.content || '', false);
          return tab;
        } else {
          const err = await resp.json();
          alert(`Error reading file: ${err.message || 'File not found'}`);
        }
      } catch (e) {
        alert(`Network error loading file: ${e.message}`);
      }
    }

    async function saveActiveTab() {
      const tab = getActiveTab();
      if (!tab) return false;

      const targetPath = pathInput.value.trim() || tab.path;
      if (statusMsg) {
        statusMsg.textContent = 'Validating bash syntax with "bash -n"...';
        statusMsg.className = 'script-status-msg warn';
      }
      if (saveBtn) saveBtn.disabled = true;

      try {
        const resp = await fetch('/api/file/save', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            path: targetPath,
            content: textarea.value
          })
        });
        const data = await resp.json();
        if (data.status === 'syntax_error') {
          if (statusMsg) {
            statusMsg.textContent = `[WARN] ${data.message}`;
            statusMsg.className = 'script-status-msg syntax-error';
          }
          return false;
        } else if (data.status === 'ok') {
          tab.path = targetPath;
          tab.name = targetPath.split('/').pop();
          tab.isNew = false;
          tab.dirty = false;
          updateDirtyIndicator();
          renderTabs();
          resolveDepsForTab(tab);

          if (statusMsg) {
            statusMsg.textContent = '[OK] Saved & syntax validated by bash -n';
            statusMsg.className = 'script-status-msg success';
            setTimeout(() => {
              if (statusMsg && statusMsg.textContent.includes('Saved')) {
                statusMsg.textContent = vimMode === 'normal' ? '-- NORMAL --' : '-- INSERT --';
              }
            }, 3000);
          }
          loadCronJobs();
          if (targetPath.includes('research_topics') || targetPath.includes('research.conf') || targetPath.includes('soul.md')) {
            loadResearchConfig();
          }
          if (targetPath.includes('endpoints.conf')) {
            fetchStatus();
          }
          return true;
        } else {
          if (statusMsg) {
            statusMsg.textContent = `Error saving: ${data.message || data.error}`;
            statusMsg.className = 'script-status-msg syntax-error';
          }
          return false;
        }
      } catch (e) {
        if (statusMsg) {
          statusMsg.textContent = `Save error: ${e.message}`;
          statusMsg.className = 'script-status-msg syntax-error';
        }
        return false;
      } finally {
        if (saveBtn) saveBtn.disabled = false;
      }
    }

    // Input handlers
    textarea.addEventListener('input', () => {
      const tab = getActiveTab();
      if (tab) {
        tab.dirty = true;
        tab.content = textarea.value;
        tab.deps = parseDepsFromContent(textarea.value);
        renderDeps(tab.deps);
      }
      updateDirtyIndicator();
      renderTabs();
      updateGutter();
      updateCursor();
    });

    textarea.addEventListener('scroll', () => {
      gutter.scrollTop = textarea.scrollTop;
    });

    ['click', 'keyup', 'select'].forEach(ev => {
      textarea.addEventListener(ev, () => {
        updateCursor();
        if (vimMode === 'normal' && textarea.selectionStart !== textarea.selectionEnd) {
          visualAnchor = textarea.selectionStart;
          visualCursor = textarea.selectionEnd;
          setVimMode('visual');
          updateVisualSelection();
        } else if (vimMode.startsWith('visual') && ev === 'click' && textarea.selectionStart === textarea.selectionEnd) {
          visualAnchor = textarea.selectionStart;
          visualCursor = textarea.selectionStart;
          setVimMode('normal');
        }
      });
    });

    if (pathInput) {
      pathInput.addEventListener('change', () => {
        const tab = getActiveTab();
        if (tab) {
          tab.path = pathInput.value.trim();
          tab.name = tab.path.split('/').pop() || 'untitled.sh';
          tab.dirty = true;
          updateDirtyIndicator();
          renderTabs();
        }
      });
    }

    // Modal Keydown Listener
    modal.addEventListener('keydown', (e) => {
      if (currentEditorEngine !== 'dom') return;

      // Global Save: Ctrl+S / Cmd+S
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') {
        e.preventDefault();
        saveActiveTab();
        return;
      }

      // Undo/Redo: Ctrl+Z / Ctrl+Y
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'z') {
        if (!e.shiftKey) {
          e.preventDefault();
          undoLastAction();
          return;
        } else {
          e.preventDefault();
          redoLastAction();
          return;
        }
      }

      // Ctrl+V for Visual Block mode
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'v' && vimMode !== 'insert') {
        e.preventDefault();
        if (vimMode === 'visual_block') {
          setVimMode('normal');
          textarea.setSelectionRange(visualCursor, visualCursor);
        } else {
          visualAnchor = textarea.selectionStart;
          visualCursor = textarea.selectionStart;
          setVimMode('visual_block');
          updateVisualSelection();
        }
        return;
      }

      // ── INSERT MODE ──
      if (vimMode === 'insert') {
        if (e.key === 'Escape') {
          e.preventDefault();
          setVimMode('normal');
        } else if (e.key === 'Tab') {
          e.preventDefault();
          const start = textarea.selectionStart;
          const end = textarea.selectionEnd;
          textarea.value = textarea.value.substring(0, start) + '  ' + textarea.value.substring(end);
          textarea.selectionStart = textarea.selectionEnd = start + 2;
          const tab = getActiveTab();
          if (tab) tab.dirty = true;
          updateDirtyIndicator();
          renderTabs();
          updateGutter();
        }
        return;
      }

      // ── VISUAL MODES (visual, visual_line, visual_block) ──
      if (vimMode.startsWith('visual')) {
        if (e.key === 'Escape') {
          e.preventDefault();
          setVimMode('normal');
          textarea.setSelectionRange(visualCursor, visualCursor);
          return;
        }

        if (e.key === 'v') {
          e.preventDefault();
          if (vimMode === 'visual') {
            setVimMode('normal');
            textarea.setSelectionRange(visualCursor, visualCursor);
          } else {
            setVimMode('visual');
            updateVisualSelection();
          }
          return;
        }

        if (e.key === 'V') {
          e.preventDefault();
          if (vimMode === 'visual_line') {
            setVimMode('normal');
            textarea.setSelectionRange(visualCursor, visualCursor);
          } else {
            setVimMode('visual_line');
            updateVisualSelection();
          }
          return;
        }

        if (e.key === 'd' || e.key === 'x') {
          e.preventDefault();
          visualDelete();
          return;
        }

        if (e.key === 'y') {
          e.preventDefault();
          visualYank();
          return;
        }

        if (e.key === 'c' || e.key === 's') {
          e.preventDefault();
          visualChange();
          return;
        }

        if (e.key === '>') {
          e.preventDefault();
          visualIndent();
          return;
        }

        if (e.key === '<') {
          e.preventDefault();
          visualDedent();
          return;
        }

        if (e.key === '#' || (e.key === 'c' && normalBuffer === 'g')) {
          e.preventDefault();
          normalBuffer = '';
          visualToggleComment();
          return;
        }

        if (e.key === 'g') {
          if (normalBuffer === 'g') {
            e.preventDefault();
            normalBuffer = '';
            visualCursor = 0;
            updateVisualSelection();
            return;
          } else {
            normalBuffer = 'g';
            return;
          }
        }

        if (e.key === 'I') {
          e.preventDefault();
          visualBlockPrepend();
          return;
        }

        if (e.key === 'A') {
          e.preventDefault();
          visualBlockAppend();
          return;
        }

        if (e.key === 'u') {
          e.preventDefault();
          visualTransformCase('lower');
          return;
        }

        if (e.key === 'U') {
          e.preventDefault();
          visualTransformCase('upper');
          return;
        }

        if (e.key === '~') {
          e.preventDefault();
          visualTransformCase('toggle');
          return;
        }

        if (normalBuffer === 'S') {
          e.preventDefault();
          normalBuffer = '';
          visualSurround(e.key);
          return;
        }

        if (e.key === 'S') {
          e.preventDefault();
          normalBuffer = 'S';
          if (statusMsg) statusMsg.textContent = 'Surround selection with delimiter:';
          return;
        }

        const motions = ['h', 'j', 'k', 'l', 'w', 'b', 'e', '0', '^', '$', '{', '}', 'ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'];
        if (motions.includes(e.key)) {
          e.preventDefault();
          visualCursor = getMotionPos(e.key, visualCursor);
          updateVisualSelection();
          return;
        }

        if (e.key === 'G') {
          e.preventDefault();
          visualCursor = textarea.value.length;
          updateVisualSelection();
          return;
        }

        return;
      }

      // ── NORMAL MODE ──
      if (vimMode === 'normal') {
        if (e.key === 'i') {
          e.preventDefault();
          setVimMode('insert');
          return;
        }

        if (e.key === 'a') {
          e.preventDefault();
          const p = textarea.selectionStart;
          textarea.setSelectionRange(p + 1, p + 1);
          setVimMode('insert');
          return;
        }

        if (e.key === 'v') {
          e.preventDefault();
          visualAnchor = textarea.selectionStart;
          visualCursor = textarea.selectionStart;
          setVimMode('visual');
          updateVisualSelection();
          return;
        }

        if (e.key === 'V') {
          e.preventDefault();
          visualAnchor = textarea.selectionStart;
          visualCursor = textarea.selectionStart;
          setVimMode('visual_line');
          updateVisualSelection();
          return;
        }

        if (e.key === 'x') {
          e.preventDefault();
          deleteCharUnderCursor();
          return;
        }

        if (e.key === 'p') {
          e.preventDefault();
          pasteYankRegister(false);
          return;
        }

        if (e.key === 'P') {
          e.preventDefault();
          pasteYankRegister(true);
          return;
        }

        if (e.key === 'o') {
          e.preventDefault();
          openNewLine(false);
          return;
        }

        if (e.key === 'O') {
          e.preventDefault();
          openNewLine(true);
          return;
        }

        if (e.key === 'u') {
          e.preventDefault();
          undoLastAction();
          return;
        }

        if (e.key === 'Escape') {
          if (vimLegendDropdown && vimLegendDropdown.style.display !== 'none') {
            toggleVimLegend(false);
          }
          normalBuffer = '';
          if (statusMsg) {
            statusMsg.className = 'script-status-msg';
            statusMsg.textContent = '-- NORMAL --';
          }
          return;
        }

        if (e.key === '?') {
          e.preventDefault();
          toggleVimLegend();
          return;
        }

        const motions = ['h', 'j', 'k', 'l', 'w', 'b', 'e', '0', '^', '$', '{', '}', 'ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'];
        if (motions.includes(e.key) && !normalBuffer.startsWith(':') && !normalBuffer.startsWith('d') && !normalBuffer.startsWith('y') && !normalBuffer.startsWith('c') && !normalBuffer.startsWith('g')) {
          e.preventDefault();
          const newPos = getMotionPos(e.key, textarea.selectionStart);
          textarea.setSelectionRange(newPos, newPos);
          updateCursor();
          return;
        }

        if (e.key === 'G' && !normalBuffer.startsWith(':')) {
          e.preventDefault();
          normalBuffer = '';
          textarea.setSelectionRange(textarea.value.length, textarea.value.length);
          textarea.scrollTop = textarea.scrollHeight;
          updateCursor();
          return;
        }

        if (e.key === ':') {
          e.preventDefault();
          normalBuffer = ':';
          if (statusMsg) {
            statusMsg.className = 'script-status-msg';
            statusMsg.textContent = ':';
          }
          return;
        }

        if (normalBuffer.startsWith(':')) {
          e.preventDefault();
          if (e.key === 'Enter') {
            const cmd = normalBuffer.trim();
            if (cmd === ':w') {
              saveActiveTab();
            } else if (cmd === ':w!') {
              saveActiveTab(true);
            } else if (cmd === ':q') {
              const tab = getActiveTab();
              if (tab && tab.dirty) {
                if (statusMsg) {
                  statusMsg.className = 'script-status-msg syntax-error';
                  statusMsg.textContent = 'E37: No write since last change (add ! to override: :q!)';
                }
              } else if (activeTabId) {
                closeTab(activeTabId, false);
              }
            } else if (cmd === ':q!' || cmd === ':bd!') {
              if (activeTabId) closeTab(activeTabId, true);
            } else if (cmd === ':bd') {
              const tab = getActiveTab();
              if (tab && tab.dirty) {
                if (statusMsg) {
                  statusMsg.className = 'script-status-msg syntax-error';
                  statusMsg.textContent = 'E37: No write since last change (add ! to override: :bd!)';
                }
              } else if (activeTabId) {
                closeTab(activeTabId, false);
              }
            } else if (cmd === ':wq' || cmd === ':x') {
              saveActiveTab().then(ok => { if (ok && activeTabId) closeTab(activeTabId, true); });
            } else if (cmd === ':wq!') {
              saveActiveTab(true).then(ok => { if (ok && activeTabId) closeTab(activeTabId, true); });
            } else if (cmd === ':qa') {
              const dirtyTabs = editorTabs.filter(t => t.dirty);
              if (dirtyTabs.length > 0) {
                if (statusMsg) {
                  statusMsg.className = 'script-status-msg syntax-error';
                  statusMsg.textContent = `E37: ${dirtyTabs.length} buffer(s) have unsaved changes (add ! to override: :qa!)`;
                }
              } else {
                modal.classList.remove('open');
                if (statusMsg) statusMsg.textContent = 'All buffers closed.';
              }
            } else if (cmd === ':qa!') {
              modal.classList.remove('open');
              if (statusMsg) statusMsg.textContent = 'All buffers closed.';
            } else if (cmd === ':tabnew') {
              createBlankTab();
            } else if (cmd.startsWith(':e ')) {
              const p = cmd.substring(3).trim();
              if (p) openFile(p);
            } else if (cmd === ':help' || cmd === ':h' || cmd === ':legend') {
              toggleVimLegend(true);
            } else {
              if (statusMsg) {
                statusMsg.className = 'script-status-msg syntax-error';
                statusMsg.textContent = `Unknown command: ${cmd} (press ? or click VIM LEGEND)`;
              }
            }
            normalBuffer = '';
          } else if (e.key === 'Backspace') {
            normalBuffer = normalBuffer.slice(0, -1);
            if (statusMsg) statusMsg.textContent = normalBuffer || '-- NORMAL --';
          } else if (e.key.length === 1) {
            normalBuffer += e.key;
            if (statusMsg) statusMsg.textContent = normalBuffer;
          }
          return;
        }

        if (e.key === 'g') {
          if (normalBuffer === 'g') {
            normalBuffer = '';
            textarea.setSelectionRange(0, 0);
            textarea.scrollTop = 0;
            updateCursor();
          } else {
            normalBuffer = 'g';
          }
          return;
        }

        if (e.key === 'f' && normalBuffer === 'g') {
          e.preventDefault();
          normalBuffer = '';
          jumpToFileUnderCursor();
          return;
        }

        if (e.key === 't' && normalBuffer === 'g') {
          e.preventDefault();
          normalBuffer = '';
          cycleTab(1);
          return;
        }

        if (e.key === 'T' && normalBuffer === 'g') {
          e.preventDefault();
          normalBuffer = '';
          cycleTab(-1);
          return;
        }

        if (normalBuffer === 'ds') {
          e.preventDefault();
          deleteSurround(e.key);
          normalBuffer = '';
          return;
        }

        if (normalBuffer.startsWith('cs')) {
          e.preventDefault();
          if (normalBuffer.length === 2) {
            normalBuffer = 'cs' + e.key;
            if (statusMsg) statusMsg.textContent = `cs${e.key} -> replace with:`;
          } else if (normalBuffer.length === 3) {
            const oldChar = normalBuffer[2];
            const newChar = e.key;
            changeSurround(oldChar, newChar);
            normalBuffer = '';
          }
          return;
        }

        if (normalBuffer.startsWith('ys')) {
          e.preventDefault();
          if (normalBuffer === 'ys' && e.key === 'i') {
            normalBuffer = 'ysi';
          } else if (normalBuffer === 'ysi' && e.key === 'w') {
            normalBuffer = 'ysiw';
            if (statusMsg) statusMsg.textContent = 'ysiw -> surround with:';
          } else if (normalBuffer === 'ysiw') {
            surroundInnerWord(e.key);
            normalBuffer = '';
          } else {
            normalBuffer = '';
          }
          return;
        }

        if (e.key === 's' && normalBuffer === 'd') {
          e.preventDefault();
          normalBuffer = 'ds';
          if (statusMsg) statusMsg.textContent = 'ds -> target delimiter:';
          return;
        }

        if (e.key === 'c') {
          normalBuffer = 'c';
          return;
        }

        if (e.key === 's' && normalBuffer === 'c') {
          e.preventDefault();
          normalBuffer = 'cs';
          if (statusMsg) statusMsg.textContent = 'cs -> target delimiter:';
          return;
        }

        if (e.key === 's' && normalBuffer === 'y') {
          e.preventDefault();
          normalBuffer = 'ys';
          return;
        }

        if (e.key === 'd') {
          if (normalBuffer === 'd') {
            e.preventDefault();
            normalBuffer = '';
            deleteCurrentLine();
          } else {
            normalBuffer = 'd';
          }
          return;
        }

        if (e.key === 'y') {
          if (normalBuffer === 'y') {
            e.preventDefault();
            normalBuffer = '';
            yankCurrentLine();
          } else {
            normalBuffer = 'y';
          }
          return;
        }
      }
    });

    function getMatchingPairs(char) {
      const pairs = {
        '(': { open: '(', close: ')' },
        ')': { open: '(', close: ')' },
        '[': { open: '[', close: ']' },
        ']': { open: '[', close: ']' },
        '{': { open: '{', close: '}' },
        '}': { open: '{', close: '}' },
        '<': { open: '<', close: '>' },
        '>': { open: '<', close: '>' },
        '"': { open: '"', close: '"' },
        "'": { open: "'", close: "'" },
        '`': { open: '`', close: '`' }
      };
      return pairs[char] || { open: char, close: char };
    }

    function deleteSurround(char) {
      const p = getMatchingPairs(char);
      const text = textarea.value;
      const pos = textarea.selectionStart;
      const before = text.lastIndexOf(p.open, pos);
      const after = text.indexOf(p.close, pos);
      if (before !== -1 && after !== -1 && before < after) {
        const newText = text.substring(0, before) + text.substring(before + 1, after) + text.substring(after + 1);
        textarea.value = newText;
        textarea.selectionStart = textarea.selectionEnd = Math.max(0, pos - 1);
        const tab = getActiveTab();
        if (tab) tab.dirty = true;
        updateDirtyIndicator();
        renderTabs();
        updateGutter();
        if (statusMsg) statusMsg.textContent = `Surround deleted: ${p.open}...${p.close}`;
      }
    }

    function changeSurround(oldChar, newChar) {
      const oldP = getMatchingPairs(oldChar);
      const newP = getMatchingPairs(newChar);
      const text = textarea.value;
      const pos = textarea.selectionStart;
      const before = text.lastIndexOf(oldP.open, pos);
      const after = text.indexOf(oldP.close, pos);
      if (before !== -1 && after !== -1 && before < after) {
        const newText = text.substring(0, before) + newP.open + text.substring(before + 1, after) + newP.close + text.substring(after + 1);
        textarea.value = newText;
        textarea.selectionStart = textarea.selectionEnd = pos;
        const tab = getActiveTab();
        if (tab) tab.dirty = true;
        updateDirtyIndicator();
        renderTabs();
        updateGutter();
        if (statusMsg) statusMsg.textContent = `Surround changed: ${oldP.open} ➔ ${newP.open}`;
      }
    }

    function surroundInnerWord(char) {
      const p = getMatchingPairs(char);
      const text = textarea.value;
      const pos = textarea.selectionStart;
      let start = pos;
      while (start > 0 && /\w/.test(text[start - 1])) {
        start--;
      }
      let end = pos;
      while (end < text.length && /\w/.test(text[end])) {
        end++;
      }
      if (start < end) {
        const word = text.substring(start, end);
        const newText = text.substring(0, start) + p.open + word + p.close + text.substring(end);
        textarea.value = newText;
        textarea.selectionStart = textarea.selectionEnd = start + word.length + 2;
        const tab = getActiveTab();
        if (tab) tab.dirty = true;
        updateDirtyIndicator();
        renderTabs();
        updateGutter();
        if (statusMsg) statusMsg.textContent = `Surrounded word with ${p.open}${p.close}`;
      }
    }

    // Dual-Engine Architecture: Craftsman DOM vs Neovim PTY
    let currentEditorEngine = 'dom';
    let nvimTerm = null;
    let nvimSocket = null;
    let nvimFitAddon = null;
    let nvimResizeObserver = null;

    function setEditorEngine(engine) {
      const domViewport = document.getElementById('scriptCodeViewport');
      const nvimViewport = document.getElementById('scriptNvimViewport');
      const btnCraftsman = document.getElementById('btnEngineCraftsman');
      const btnNvim = document.getElementById('btnEngineNvim');
      const engineBadge = document.getElementById('scriptEngineBadge');
      const tab = getActiveTab();
      const filePath = tab ? tab.path : '';

      currentEditorEngine = engine;

      if (engine === 'nvim') {
        if (domViewport) domViewport.style.display = 'none';
        if (nvimViewport) nvimViewport.style.display = 'flex';
        if (btnNvim) btnNvim.classList.add('active');
        if (btnCraftsman) btnCraftsman.classList.remove('active');
        if (engineBadge) engineBadge.textContent = 'ENGINE: NVIM';
        initNvimTerminal(filePath);
      } else {
        currentEditorEngine = 'dom';
        if (nvimViewport) nvimViewport.style.display = 'none';
        if (domViewport) domViewport.style.display = 'flex';
        if (btnCraftsman) btnCraftsman.classList.add('active');
        if (btnNvim) btnNvim.classList.remove('active');
        if (engineBadge) engineBadge.textContent = 'ENGINE: VIM-LITE';
        if (nvimSocket) {
          try { nvimSocket.close(); } catch(e) {}
          nvimSocket = null;
        }
        if (nvimResizeObserver) {
          try { nvimResizeObserver.disconnect(); } catch(e) {}
          nvimResizeObserver = null;
        }
        if (tab && !tab.isNew && tab.path) {
          fetch(`/api/file/read?path=${encodeURIComponent(tab.path)}`)
            .then(r => r.json())
            .then(d => {
              if (d.content !== undefined) {
                tab.content = d.content;
                tab.dirty = false;
                textarea.value = d.content;
                updateGutter();
                updateCursor();
                updateDirtyIndicator();
              }
            }).catch(() => {});
        }
      }
    }

    function initNvimTerminal(filePath) {
      const container = document.getElementById('nvimTerminalContainer');
      const viewport = document.getElementById('scriptNvimViewport');
      if (!container || !viewport) return;
      container.innerHTML = '';

      if (window.Terminal) {
        nvimTerm = new Terminal({
          theme: {
            background: '#090a0f',
            foreground: '#e0e6ed',
            cursor: '#00e5ff',
            selectionBackground: 'rgba(0, 229, 255, 0.3)'
          },
          cursorBlink: true,
          fontSize: 13,
          fontFamily: 'monospace, "Fira Code", monospace',
          lineHeight: 1.2
        });

        if (window.FitAddon && window.FitAddon.FitAddon) {
          nvimFitAddon = new window.FitAddon.FitAddon();
          nvimTerm.loadAddon(nvimFitAddon);
        }

        nvimTerm.open(container);

        // Calculate actual cols/rows right away so Neovim never launches restricted to 100 columns
        let initialCols = 120;
        let initialRows = 35;
        if (nvimFitAddon) {
          try {
            nvimFitAddon.fit();
            if (nvimTerm.cols && nvimTerm.cols > 20) initialCols = nvimTerm.cols;
            if (nvimTerm.rows && nvimTerm.rows > 5) initialRows = nvimTerm.rows;
          } catch(e) {}
        }

        const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
        const wsUrl = `${protocol}//${location.host}/api/terminal/ws?file=${encodeURIComponent(filePath)}&cols=${initialCols}&rows=${initialRows}`;

        nvimSocket = new WebSocket(wsUrl);
        nvimSocket.binaryType = 'arraybuffer';

        function syncNvimSize() {
          if (!nvimFitAddon || !nvimTerm) return;
          try {
            nvimFitAddon.fit();
            if (nvimSocket && nvimSocket.readyState === WebSocket.OPEN) {
              nvimSocket.send(JSON.stringify({ type: 'resize', cols: nvimTerm.cols, rows: nvimTerm.rows }));
            }
          } catch(e) {}
        }

        nvimSocket.onopen = () => {
          if (statusMsg) statusMsg.textContent = 'Neovim PTY connected.';
          // Send resize packets after brief delays to ensure Neovim spans 100% monitor width without cutoffs
          setTimeout(syncNvimSize, 50);
          setTimeout(syncNvimSize, 250);
        };

        nvimSocket.onmessage = (event) => {
          if (event.data instanceof ArrayBuffer) {
            nvimTerm.write(new Uint8Array(event.data));
          } else {
            nvimTerm.write(event.data);
          }
        };

        nvimSocket.onclose = () => {
          if (statusMsg) statusMsg.textContent = 'Neovim PTY closed.';
        };

        nvimSocket.onerror = () => {
          nvimTerm.write('\r\n[WebSocket error connecting to Neovim PTY]\r\n');
        };

        nvimTerm.onData((data) => {
          if (nvimSocket && nvimSocket.readyState === WebSocket.OPEN) {
            nvimSocket.send(data);
          }
        });

        nvimTerm.onResize((size) => {
          if (nvimSocket && nvimSocket.readyState === WebSocket.OPEN) {
            nvimSocket.send(JSON.stringify({ type: 'resize', cols: size.cols, rows: size.rows }));
          }
        });

        // Watch container resize (fullscreen toggle, drawer open/close, window resize)
        if (window.ResizeObserver) {
          if (nvimResizeObserver) nvimResizeObserver.disconnect();
          nvimResizeObserver = new ResizeObserver(() => {
            syncNvimSize();
          });
          nvimResizeObserver.observe(container);
        }
      } else {
        container.innerHTML = '<div style="color: red; padding: 20px;">xterm.js library not available.</div>';
      }
    }

    const btnEngineCraftsman = document.getElementById('btnEngineCraftsman');
    const btnEngineNvim = document.getElementById('btnEngineNvim');
    if (btnEngineCraftsman) {
      btnEngineCraftsman.addEventListener('click', () => setEditorEngine('dom'));
    }
    if (btnEngineNvim) {
      btnEngineNvim.addEventListener('click', () => setEditorEngine('nvim'));
    }

    // Fullscreen Monitor Expansion Toggle
    const btnToggleMaximize = document.getElementById('btnToggleEditorMaximize');
    const scriptModal = document.getElementById('scriptEditorModal');
    if (btnToggleMaximize && scriptModal) {
      btnToggleMaximize.addEventListener('click', () => {
        const isFullscreen = scriptModal.classList.toggle('fullscreen');
        if (isFullscreen) {
          btnToggleMaximize.textContent = '⤦';
          btnToggleMaximize.title = 'Restore standard workspace view';
        } else {
          btnToggleMaximize.textContent = '⤢';
          btnToggleMaximize.title = 'Toggle full-monitor workspace view (Fullscreen)';
        }
        recalculateWorkbenchGeometry();
        if (currentEditorEngine === 'nvim' && nvimFitAddon) {
          setTimeout(() => {
            try {
              nvimFitAddon.fit();
              if (nvimSocket && nvimSocket.readyState === WebSocket.OPEN) {
                nvimSocket.send(JSON.stringify({ type: 'resize', cols: nvimTerm.cols, rows: nvimTerm.rows }));
              }
            } catch(e) {}
          }, 60);
        }
      });
    }

    // ── Full-Featured Diff Review Engine (Unified & Split) ───────────
    let currentProposedCode = null;
    let currentOriginalCode = null;
    let currentDiffMode = 'unified'; // 'unified' | 'split'
    let diffScrollSyncBound = false;

    function computeLineDiff(origLines, newLines) {
      const m = origLines.length;
      const n = newLines.length;

      // Prefix optimization
      let start = 0;
      while (start < m && start < n && origLines[start] === newLines[start]) {
        start++;
      }
      let endOld = m - 1;
      let endNew = n - 1;
      while (endOld >= start && endNew >= start && origLines[endOld] === newLines[endNew]) {
        endOld--;
        endNew--;
      }

      const diff = [];
      // Prefix context
      for (let i = 0; i < start; i++) {
        diff.push({ type: 'ctx', oldLine: i + 1, newLine: i + 1, text: origLines[i] });
      }

      // Intermediate diff via standard dynamic programming LCS
      const subOld = origLines.slice(start, endOld + 1);
      const subNew = newLines.slice(start, endNew + 1);

      if (subOld.length > 0 && subNew.length > 0 && (subOld.length * subNew.length) < 300000) {
        const dp = Array.from({ length: subOld.length + 1 }, () => new Uint16Array(subNew.length + 1));
        for (let i = 0; i < subOld.length; i++) {
          for (let j = 0; j < subNew.length; j++) {
            if (subOld[i] === subNew[j]) {
              dp[i + 1][j + 1] = dp[i][j] + 1;
            } else {
              dp[i + 1][j + 1] = Math.max(dp[i + 1][j], dp[i][j + 1]);
            }
          }
        }

        let i = subOld.length, j = subNew.length;
        const subDiff = [];
        while (i > 0 || j > 0) {
          if (i > 0 && j > 0 && subOld[i - 1] === subNew[j - 1]) {
            subDiff.push({ type: 'ctx', text: subOld[i - 1] });
            i--; j--;
          } else if (j > 0 && (i === 0 || dp[i][j - 1] >= dp[i - 1][j])) {
            subDiff.push({ type: 'add', text: subNew[j - 1] });
            j--;
          } else if (i > 0 && (j === 0 || dp[i][j - 1] < dp[i - 1][j])) {
            subDiff.push({ type: 'del', text: subOld[i - 1] });
            i--;
          }
        }
        subDiff.reverse();

        let curOld = start + 1;
        let curNew = start + 1;
        for (const item of subDiff) {
          if (item.type === 'ctx') {
            diff.push({ type: 'ctx', oldLine: curOld++, newLine: curNew++, text: item.text });
          } else if (item.type === 'del') {
            diff.push({ type: 'del', oldLine: curOld++, newLine: null, text: item.text });
          } else if (item.type === 'add') {
            diff.push({ type: 'add', oldLine: null, newLine: curNew++, text: item.text });
          }
        }
      } else {
        // Fallback for large block
        for (let i = 0; i < subOld.length; i++) {
          diff.push({ type: 'del', oldLine: start + i + 1, newLine: null, text: subOld[i] });
        }
        for (let j = 0; j < subNew.length; j++) {
          diff.push({ type: 'add', oldLine: null, newLine: start + j + 1, text: subNew[j] });
        }
      }

      // Suffix context
      for (let k = 0; k < (m - 1 - endOld); k++) {
        const oldIdx = endOld + 1 + k;
        const newIdx = endNew + 1 + k;
        diff.push({ type: 'ctx', oldLine: oldIdx + 1, newLine: newIdx + 1, text: origLines[oldIdx] });
      }

      return diff;
    }

    function openDiffReview(filePath, origContent, proposedContent) {
      currentOriginalCode = origContent;
      currentProposedCode = proposedContent;

      const codeViewport = document.getElementById('scriptCodeViewport');
      const nvimViewport = document.getElementById('scriptNvimViewport');
      const diffViewport = document.getElementById('scriptDiffViewport');
      const diffFileLabel = document.getElementById('diffToolbarFile');
      const badgeAdd = document.getElementById('diffBadgeAdd');
      const badgeDel = document.getElementById('diffBadgeDel');
      const unifiedContainer = document.getElementById('diffUnifiedContainer');
      const splitOrigBody = document.getElementById('splitOriginalBody');
      const splitPropBody = document.getElementById('splitProposedBody');

      if (!diffViewport) return;

      if (codeViewport) codeViewport.style.display = 'none';
      if (nvimViewport) nvimViewport.style.display = 'none';
      diffViewport.style.display = 'flex';

      if (diffFileLabel) diffFileLabel.textContent = filePath || 'active_file.sh';

      const origLines = (origContent || '').split('\n');
      const newLines = (proposedContent || '').split('\n');
      const diffItems = computeLineDiff(origLines, newLines);

      const addCount = diffItems.filter(d => d.type === 'add').length;
      const delCount = diffItems.filter(d => d.type === 'del').length;

      if (badgeAdd) badgeAdd.textContent = `+${addCount} additions`;
      if (badgeDel) badgeDel.textContent = `-${delCount} deletions`;

      // 1. Render Unified Diff View
      if (unifiedContainer) {
        unifiedContainer.innerHTML = '';
        diffItems.forEach(item => {
          const row = document.createElement('div');
          row.className = `diff-unified-row ${item.type}`;

          const oldCol = document.createElement('span');
          oldCol.className = 'diff-col-old';
          oldCol.textContent = item.oldLine !== null ? item.oldLine : '';

          const newCol = document.createElement('span');
          newCol.className = 'diff-col-new';
          newCol.textContent = item.newLine !== null ? item.newLine : '';

          const markerCol = document.createElement('span');
          markerCol.className = 'diff-col-marker';
          markerCol.textContent = item.type === 'add' ? '+' : (item.type === 'del' ? '-' : ' ');

          const textCol = document.createElement('span');
          textCol.className = 'diff-col-content';
          textCol.textContent = item.text;

          row.appendChild(oldCol);
          row.appendChild(newCol);
          row.appendChild(markerCol);
          row.appendChild(textCol);
          unifiedContainer.appendChild(row);
        });
      }

      // 2. Render Split Diff View (Side-by-Side)
      if (splitOrigBody && splitPropBody) {
        splitOrigBody.innerHTML = '';
        splitPropBody.innerHTML = '';

        diffItems.forEach(item => {
          // Left side (Original)
          const leftRow = document.createElement('div');
          if (item.type === 'add') {
            leftRow.className = 'split-row placeholder';
            leftRow.innerHTML = '<span class="split-col-num"></span><span class="split-col-content"></span>';
          } else {
            leftRow.className = `split-row ${item.type}`;
            const num = document.createElement('span');
            num.className = 'split-col-num';
            num.textContent = item.oldLine || '';
            const content = document.createElement('span');
            content.className = 'split-col-content';
            content.textContent = (item.type === 'del' ? '- ' : '  ') + item.text;
            leftRow.appendChild(num);
            leftRow.appendChild(content);
          }
          splitOrigBody.appendChild(leftRow);

          // Right side (Proposed)
          const rightRow = document.createElement('div');
          if (item.type === 'del') {
            rightRow.className = 'split-row placeholder';
            rightRow.innerHTML = '<span class="split-col-num"></span><span class="split-col-content"></span>';
          } else {
            rightRow.className = `split-row ${item.type}`;
            const num = document.createElement('span');
            num.className = 'split-col-num';
            num.textContent = item.newLine || '';
            const content = document.createElement('span');
            content.className = 'split-col-content';
            content.textContent = (item.type === 'add' ? '+ ' : '  ') + item.text;
            rightRow.appendChild(num);
            rightRow.appendChild(content);
          }
          splitPropBody.appendChild(rightRow);
        });

        // Synchronize scroll between split panes
        if (!diffScrollSyncBound) {
          diffScrollSyncBound = true;
          let isSyncing = false;
          splitOrigBody.addEventListener('scroll', () => {
            if (!isSyncing) {
              isSyncing = true;
              splitPropBody.scrollTop = splitOrigBody.scrollTop;
              splitPropBody.scrollLeft = splitOrigBody.scrollLeft;
              isSyncing = false;
            }
          });
          splitPropBody.addEventListener('scroll', () => {
            if (!isSyncing) {
              isSyncing = true;
              splitOrigBody.scrollTop = splitPropBody.scrollTop;
              splitOrigBody.scrollLeft = splitPropBody.scrollLeft;
              isSyncing = false;
            }
          });
        }
      }

      if (statusMsg) {
        statusMsg.className = 'script-status-msg success';
        statusMsg.textContent = `DIFF REVIEW ACTIVE: +${addCount} / -${delCount} lines. Review and Accept or Discard.`;
      }
    }

    function closeDiffReview(accepted) {
      const diffViewport = document.getElementById('scriptDiffViewport');
      const codeViewport = document.getElementById('scriptCodeViewport');
      const nvimViewport = document.getElementById('scriptNvimViewport');
      const copilotDiffBay = document.getElementById('copilotDiffBay');

      if (diffViewport) diffViewport.style.display = 'none';
      if (copilotDiffBay) copilotDiffBay.style.display = 'none';

      if (currentEditorEngine === 'nvim') {
        if (nvimViewport) nvimViewport.style.display = 'flex';
      } else {
        if (codeViewport) codeViewport.style.display = 'flex';
      }

      const tab = getActiveTab();
      if (accepted && tab && currentProposedCode !== null) {
        tab.content = currentProposedCode;
        tab.dirty = true;
        textarea.value = currentProposedCode;
        updateGutter();
        updateCursor();
        updateDirtyIndicator();
        renderTabs();

        // Run syntax validation
        fetch('/api/validate_bash', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ script: currentProposedCode })
        }).then(r => r.json()).then(d => {
          if (statusMsg) {
            if (d.valid) {
              statusMsg.className = 'script-status-msg success';
              statusMsg.textContent = 'Diff merged. Syntax check passed.';
            } else {
              statusMsg.className = 'script-status-msg syntax-error';
              statusMsg.textContent = `Diff merged. Syntax warning: ${d.error || 'check syntax'}`;
            }
          }
        }).catch(() => {
          if (statusMsg) {
            statusMsg.className = 'script-status-msg success';
            statusMsg.textContent = 'Diff merged into active buffer.';
          }
        });

        if (window.appendCopilotMessage) {
          window.appendCopilotMessage('george', '[MERGED] All proposed edits have been merged into the active buffer.');
        }
      } else {
        if (statusMsg) {
          statusMsg.className = 'script-status-msg';
          statusMsg.textContent = 'Proposed diff discarded. Buffer unchanged.';
        }
        if (window.appendCopilotMessage) {
          window.appendCopilotMessage('george', '[DISCARDED] Proposed edits discarded. Active buffer unchanged.');
        }
      }

      currentProposedCode = null;
      currentOriginalCode = null;
    }

    // Wire Diff Viewport Toolbar Actions
    const btnDiffToolbarAccept = document.getElementById('btnDiffToolbarAccept');
    const btnDiffToolbarReject = document.getElementById('btnDiffToolbarReject');
    const btnDiffModeUnified = document.getElementById('btnDiffModeUnified');
    const btnDiffModeSplit = document.getElementById('btnDiffModeSplit');
    const diffUnifiedContainer = document.getElementById('diffUnifiedContainer');
    const diffSplitContainer = document.getElementById('diffSplitContainer');

    if (btnDiffToolbarAccept) {
      btnDiffToolbarAccept.addEventListener('click', () => closeDiffReview(true));
    }
    if (btnDiffToolbarReject) {
      btnDiffToolbarReject.addEventListener('click', () => closeDiffReview(false));
    }

    if (btnDiffModeUnified && btnDiffModeSplit) {
      btnDiffModeUnified.addEventListener('click', () => {
        currentDiffMode = 'unified';
        btnDiffModeUnified.classList.add('active');
        btnDiffModeSplit.classList.remove('active');
        if (diffUnifiedContainer) diffUnifiedContainer.style.display = 'block';
        if (diffSplitContainer) diffSplitContainer.style.display = 'none';
      });

      btnDiffModeSplit.addEventListener('click', () => {
        currentDiffMode = 'split';
        btnDiffModeSplit.classList.add('active');
        btnDiffModeUnified.classList.remove('active');
        if (diffUnifiedContainer) diffUnifiedContainer.style.display = 'none';
        if (diffSplitContainer) diffSplitContainer.style.display = 'flex';
      });
    }

    // George Co-Pilot Pair Programming Sovereign Workspace
    function initCopilotPanel() {
      const btnToggleCopilot = document.getElementById('btnToggleCopilot');
      const copilotPanel = document.getElementById('scriptCopilotPanel');
      const copilotResizerHandle = document.getElementById('copilotResizerHandle');
      const btnCopilotClose = document.getElementById('btnCopilotClose');
      const copilotMessages = document.getElementById('copilotMessages');
      const copilotPromptInput = document.getElementById('copilotPromptInput');
      const btnSendCopilotPrompt = document.getElementById('btnSendCopilotPrompt');
      const copilotActiveFile = document.getElementById('copilotActiveFile');
      const copilotAgentSelect = document.getElementById('copilotAgentSelect');
      const copilotDiffBay = document.getElementById('copilotDiffBay');
      const btnAcceptCopilotDiff = document.getElementById('btnAcceptCopilotDiff');
      const btnRejectCopilotDiff = document.getElementById('btnRejectCopilotDiff');
      const copilotInputMeta = document.getElementById('copilotInputMeta');

      // Context Pills
      const pillContextFile = document.getElementById('pillContextFile');
      const pillFileName = document.getElementById('pillFileName');
      const pillContextSelection = document.getElementById('pillContextSelection');
      const pillSelectionCount = document.getElementById('pillSelectionCount');
      const pillContextOkf = document.getElementById('pillContextOkf');
      const pillOkfSubsystem = document.getElementById('pillOkfSubsystem');
      const pillContextRule = document.getElementById('pillContextRule');
      const pillActiveRule = document.getElementById('pillActiveRule');

      // Subnav Tabs
      const subtabs = document.querySelectorAll('.copilot-subtab');
      const tabPanes = {
        'chat': document.getElementById('copilotTabChat'),
        'tool-builder': document.getElementById('copilotTabToolBuilder'),
        'agent-forge': document.getElementById('copilotTabAgentForge'),
        'workflows': document.getElementById('copilotTabWorkflows'),
        'context': document.getElementById('copilotTabContext')
      };

      let isGenerating = false;
      let isFileContextActive = true;
      let selectedRule = null;
      let cachedTools = [];
      let cachedAgents = [];
      let cachedWorkflows = [];
      let cachedRules = [];

      // ── Panel Resizing & Preset Buttons ──
      const sizeBtns = document.querySelectorAll('.copilot-size-btn');
      sizeBtns.forEach(btn => {
        btn.addEventListener('click', () => {
          sizeBtns.forEach(b => b.classList.remove('active'));
          btn.classList.add('active');
          const size = btn.getAttribute('data-size');
          if (copilotPanel) {
            copilotPanel.classList.remove('size-compact', 'size-balanced', 'size-expanded', 'size-split');
            copilotPanel.classList.add(`size-${size}`);
            copilotPanel.style.width = ''; // clear inline style so class applies
          }
          recalculateWorkbenchGeometry();
        });
      });

      // Draggable Resizer Handle
      if (copilotResizerHandle && copilotPanel) {
        let isResizing = false;
        let startX = 0;
        let startWidth = 0;

        copilotResizerHandle.addEventListener('mousedown', (e) => {
          isResizing = true;
          startX = e.clientX;
          startWidth = copilotPanel.getBoundingClientRect().width;
          copilotResizerHandle.classList.add('resizing');
          document.body.style.cursor = 'col-resize';
          document.body.style.userSelect = 'none';
          e.preventDefault();
        });

        window.addEventListener('mousemove', (e) => {
          if (!isResizing) return;
          const delta = startX - e.clientX;
          const newWidth = Math.max(380, Math.min(window.innerWidth * 0.85, startWidth + delta));
          copilotPanel.classList.remove('size-compact', 'size-balanced', 'size-expanded', 'size-split');
          copilotPanel.style.width = `${newWidth}px`;
        });

        window.addEventListener('mouseup', () => {
          if (isResizing) {
            isResizing = false;
            copilotResizerHandle.classList.remove('resizing');
            document.body.style.cursor = '';
            document.body.style.userSelect = '';
            recalculateWorkbenchGeometry();
          }
        });
      }

      // ── Subnav Tab Switching ──
      subtabs.forEach(tabBtn => {
        tabBtn.addEventListener('click', () => {
          subtabs.forEach(b => b.classList.remove('active'));
          tabBtn.classList.add('active');
          const tabKey = tabBtn.getAttribute('data-tab');

          Object.keys(tabPanes).forEach(k => {
            if (tabPanes[k]) tabPanes[k].style.display = (k === tabKey) ? 'flex' : 'none';
          });

          // Lazy load data for selected tab
          if (tabKey === 'tool-builder') loadToolBuilderData();
          if (tabKey === 'agent-forge') loadAgentForgeData();
          if (tabKey === 'workflows') loadWorkflowsData();
          if (tabKey === 'context') loadContextData();
        });
      });

      // ── Context Pill Controls ──
      if (pillContextFile) {
        pillContextFile.addEventListener('click', () => {
          isFileContextActive = !isFileContextActive;
          pillContextFile.classList.toggle('active', isFileContextActive);
          const dot = pillContextFile.querySelector('.pill-dot');
          if (dot) dot.textContent = isFileContextActive ? '●' : '○';
        });
      }

      function updateCopilotContext() {
        const tab = getActiveTab();
        const p = tab ? (tab.path || 'untitled.sh') : 'untitled.sh';
        if (copilotActiveFile) copilotActiveFile.textContent = p;
        if (pillFileName) pillFileName.textContent = p.split('/').pop() || 'untitled.sh';

        // Detect subsystem from path
        let sub = 'core';
        if (p.startsWith('lib/tools/')) sub = 'tools';
        else if (p.startsWith('lib/ipc/')) sub = 'ipc';
        else if (p.startsWith('lib/sys/')) sub = 'sys';
        else if (p.startsWith('lib/comms/')) sub = 'comms';
        else if (p.startsWith('lib/memory/')) sub = 'memory';
        else if (p.startsWith('lib/agents/')) sub = 'agents';
        else if (p.startsWith('lib/ui/')) sub = 'ui';
        else if (p.startsWith('commands/')) sub = 'commands';
        else if (p.startsWith('web/')) sub = 'web';
        if (pillOkfSubsystem) pillOkfSubsystem.textContent = sub;

        // Check selection count
        if (textarea && pillSelectionCount) {
          const sel = textarea.value.substring(textarea.selectionStart, textarea.selectionEnd);
          if (sel) {
            const lines = sel.split('\n').length;
            pillSelectionCount.textContent = `(${lines}L)`;
            if (pillContextSelection) pillContextSelection.classList.add('active');
          } else {
            pillSelectionCount.textContent = '';
            if (pillContextSelection) pillContextSelection.classList.remove('active');
          }
        }

        // Update AST symbols preview if context tab is open
        updateBufferAstSymbols();
      }

      function setGeneratingState(generating) {
        isGenerating = generating;
        if (btnSendCopilotPrompt) {
          btnSendCopilotPrompt.disabled = generating;
          btnSendCopilotPrompt.textContent = generating ? 'CRAFTING...' : 'SEND';
        }
        if (copilotPromptInput) copilotPromptInput.disabled = generating;
        if (copilotInputMeta) copilotInputMeta.textContent = generating ? 'POSIX BUS RUNNING...' : 'POSIX IPC READY';
      }

      function toggleCopilot() {
        if (!copilotPanel) return;
        const isVisible = copilotPanel.style.display !== 'none';
        copilotPanel.style.display = isVisible ? 'none' : 'flex';
        if (btnToggleCopilot) btnToggleCopilot.classList.toggle('active', !isVisible);
        recalculateWorkbenchGeometry();
        if (!isVisible) {
          updateCopilotContext();
          if (copilotPromptInput) copilotPromptInput.focus();
        }
      }

      if (btnToggleCopilot) btnToggleCopilot.addEventListener('click', toggleCopilot);
      if (btnCopilotClose) btnCopilotClose.addEventListener('click', toggleCopilot);

      function appendCopilotMessage(role, text) {
        if (!copilotMessages) return null;
        const msgEl = document.createElement('div');
        msgEl.className = `copilot-msg ${role}`;

        const authorEl = document.createElement('div');
        authorEl.className = 'copilot-msg-author';
        const agentName = copilotAgentSelect ? copilotAgentSelect.value.toUpperCase() : 'GEORGE';
        authorEl.textContent = role === 'george' ? agentName : 'OPERATOR';

        const textEl = document.createElement('div');
        textEl.className = 'copilot-msg-text';
        textEl.textContent = text;

        msgEl.appendChild(authorEl);
        msgEl.appendChild(textEl);
        copilotMessages.appendChild(msgEl);
        copilotMessages.scrollTop = copilotMessages.scrollHeight;
        return msgEl;
      }
      window.appendCopilotMessage = appendCopilotMessage;

      // ── Main Prompt Submission & Execution ──
      async function submitPrompt(promptText) {
        if (isGenerating) return;
        const rawText = (promptText || (copilotPromptInput ? copilotPromptInput.value : '')).trim();
        if (!rawText) return;

        if (copilotPromptInput) {
          copilotPromptInput.value = '';
          copilotPromptInput.style.height = '38px';
          copilotPromptInput.style.minHeight = '38px';
        }

        appendCopilotMessage('user', rawText);

        const tab = getActiveTab();
        const filePath = tab ? tab.path : 'untitled.sh';
        const fileContent = tab ? (tab.content !== undefined ? tab.content : textarea.value) : textarea.value;
        const selection = (textarea && textarea.selectionEnd > textarea.selectionStart)
          ? textarea.value.substring(textarea.selectionStart, textarea.selectionEnd)
          : '';

        setGeneratingState(true);

        const fName = filePath.split('/').pop() || 'file';
        const fileStem = fName.replace(/[^a-zA-Z0-9_-]/g, '_');
        const taskId = `copilot_${fileStem}_${Math.floor(Date.now() / 1000)}`;

        // Check if instruction is a SAFE COMMENT operation
        const isCommentAction = rawText.startsWith('/comment') ||
          (rawText.toLowerCase().includes('comment') && !rawText.toLowerCase().includes('refactor') && !rawText.toLowerCase().includes('delete'));

        if (isCommentAction) {
          try {
            const resp = await fetch('/api/copilot/comment', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({
                file_path: filePath,
                file_content: fileContent,
                instruction: rawText,
                selection: selection || null
              })
            });

            if (!resp.ok) {
              const err = await resp.text();
              appendCopilotMessage('george', `Safe comment error: ${err}`);
              return;
            }

            const data = await resp.json();
            appendCopilotMessage('george', data.explanation || 'Safely injected function documentation and comments without modifying or deleting executable logic.');

            if (data.has_edit && data.proposed_code) {
              currentProposedCode = data.proposed_code;
              openDiffReview(filePath, fileContent, data.proposed_code);
              if (copilotDiffBay) copilotDiffBay.style.display = 'flex';
            }
            return;
          } catch (e) {
            appendCopilotMessage('george', `Safe comment error: ${e.message}`);
            return;
          } finally {
            setGeneratingState(false);
          }
        }

        // Standard Pair Programming with Selected Agent Persona & Internal Monologue Card
        const activeAgent = copilotAgentSelect ? copilotAgentSelect.value : 'george';
        const taskCard = renderBlueprintCard(
          `${activeAgent.toUpperCase()}: ${fName}`,
          `[TASK INITIALIZED]: ${rawText}\n[FILE]: ${filePath}\n[AGENT]: ${activeAgent}\n[STATUS]: Generating internal reasoning and surgical patch...\n`,
          taskId,
          true,
          copilotMessages,
          activeAgent.toUpperCase(),
          'REASONING'
        );

        setTimeout(pollHeartbeat, 250);

        let es = null;
        try {
          es = new EventSource(`/api/stream/task/${taskId}`);
          es.addEventListener('log', (e) => {
            if (e.data && taskCard) taskCard.appendLog(e.data);
          });
          es.addEventListener('phase', (e) => {
            if (e.data && taskCard) taskCard.updateDial(e.data.toUpperCase());
          });
          es.addEventListener('done', () => {
            if (es) { es.close(); es = null; }
            if (taskCard) taskCard.updateDial('COMPLETED');
          });
        } catch (e) {}

        try {
          const resp = await fetch('/api/copilot/chat', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              task_id: taskId,
              file_path: isFileContextActive ? filePath : '',
              file_content: isFileContextActive ? fileContent : '',
              selection: selection || null,
              instruction: rawText,
              session_id: 'workbench',
              agent: activeAgent,
              context_pills: [
                isFileContextActive ? `file:${filePath}` : '',
                selection ? 'selection:active' : '',
                `okf:${pillOkfSubsystem ? pillOkfSubsystem.textContent : 'core'}`,
                selectedRule ? `rule:${selectedRule}` : ''
              ].filter(Boolean)
            })
          });

          if (es) { es.close(); es = null; }

          if (!resp.ok) {
            const err = await resp.text();
            if (taskCard) {
              taskCard.updateDial('ERROR');
              taskCard.appendLog(`\n[ERROR]: ${err}`);
            }
            appendCopilotMessage('george', `Error: ${err}`);
            return;
          }

          const data = await resp.json();
          if (taskCard) {
            taskCard.updateDial('COMPLETED');
            if (data.reasoning) taskCard.setLog(data.reasoning);
          }

          const explanation = data.explanation || (data.has_edit ? 'Here are the proposed edits staged in the Diff Viewer.' : data.reply);
          appendCopilotMessage('george', explanation);

          if (data.has_edit && data.proposed_code) {
            currentProposedCode = data.proposed_code;
            openDiffReview(filePath, fileContent, data.proposed_code);
            if (copilotDiffBay) copilotDiffBay.style.display = 'flex';
          } else {
            if (copilotDiffBay) copilotDiffBay.style.display = 'none';
          }
        } catch (e) {
          if (es) { es.close(); es = null; }
          if (taskCard) {
            taskCard.updateDial('ERROR');
            taskCard.appendLog(`\n[NETWORK ERROR]: ${e.message}`);
          }
          appendCopilotMessage('george', `Network error: ${e.message}`);
        } finally {
          if (es) { es.close(); es = null; }
          setGeneratingState(false);
          if (copilotPromptInput) copilotPromptInput.focus();
          pollHeartbeat();
        }
      }

      if (btnSendCopilotPrompt) {
        btnSendCopilotPrompt.addEventListener('click', () => submitPrompt());
      }

      if (copilotPromptInput) {
        copilotPromptInput.addEventListener('input', () => {
          copilotPromptInput.style.height = 'auto';
          copilotPromptInput.style.height = Math.min(200, Math.max(38, copilotPromptInput.scrollHeight)) + 'px';
        });

        copilotPromptInput.addEventListener('keydown', (e) => {
          if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            submitPrompt();
          }
        });
      }

      // Quick Chips and Slash Chips
      document.querySelectorAll('.copilot-quick-chips .quick-chip').forEach(chip => {
        chip.addEventListener('click', () => {
          const prompt = chip.getAttribute('data-prompt');
          if (prompt) submitPrompt(prompt);
        });
      });

      document.querySelectorAll('.copilot-slash-chips-bar .slash-chip').forEach(chip => {
        chip.addEventListener('click', () => {
          const cmd = chip.getAttribute('data-cmd');
          if (copilotPromptInput) {
            copilotPromptInput.value = `${cmd} `;
            copilotPromptInput.focus();
          }
        });
      });

      if (btnAcceptCopilotDiff) {
        btnAcceptCopilotDiff.addEventListener('click', () => closeDiffReview(true));
      }

      if (btnRejectCopilotDiff) {
        btnRejectCopilotDiff.addEventListener('click', () => closeDiffReview(false));
      }

      // ── Tool Builder Module Logic ──
      async function loadToolBuilderData() {
        const select = document.getElementById('tbExistingToolsSelect');
        if (!select) return;

        try {
          const resp = await fetch('/api/copilot/tools');
          if (!resp.ok) return;
          const data = await resp.json();
          cachedTools = data.tools || [];

          select.innerHTML = '<option value="">-- Inspect existing tool in lib/tools/ --</option>';
          cachedTools.forEach(t => {
            const opt = document.createElement('option');
            opt.value = t.path;
            opt.textContent = `${t.name} (${t.language}, ${t.subsystem}) - ${t.description.substring(0, 40)}`;
            select.appendChild(opt);
          });
        } catch (e) {}
      }

      const tbExistingToolsSelect = document.getElementById('tbExistingToolsSelect');
      if (tbExistingToolsSelect) {
        tbExistingToolsSelect.addEventListener('change', async () => {
          const path = tbExistingToolsSelect.value;
          if (!path) return;
          const tool = cachedTools.find(t => t.path === path);
          if (tool) {
            const nameEl = document.getElementById('tbToolName');
            const langEl = document.getElementById('tbToolLang');
            const subEl = document.getElementById('tbToolSubsystem');
            const descEl = document.getElementById('tbToolDesc');
            const codeEl = document.getElementById('tbToolCode');

            if (nameEl) nameEl.value = tool.name;
            if (langEl) langEl.value = tool.language;
            if (subEl) subEl.value = tool.subsystem;
            if (descEl) descEl.value = tool.description;

            try {
              const resp = await fetch(`/api/files/read?path=${encodeURIComponent(path)}`);
              if (resp.ok) {
                const data = await resp.json();
                if (codeEl) codeEl.value = data.content || '';
              }
            } catch (e) {}
          }
        });
      }

      const btnRefreshToolList = document.getElementById('btnRefreshToolList');
      if (btnRefreshToolList) btnRefreshToolList.addEventListener('click', loadToolBuilderData);

      const btnLoadToolTemplate = document.getElementById('btnLoadToolTemplate');
      if (btnLoadToolTemplate) {
        btnLoadToolTemplate.addEventListener('click', () => {
          const lang = (document.getElementById('tbToolLang')?.value) || 'bash';
          const name = (document.getElementById('tbToolName')?.value) || 'custom_tool';
          const codeEl = document.getElementById('tbToolCode');
          if (!codeEl) return;

          if (lang === 'bash') {
            codeEl.value = `#!/bin/bash\n# DESC: Purpose of ${name}\nset -euo pipefail\n\nmain() {\n  echo "Tool ${name} executed successfully with args: $*"\n}\n\nmain "$@"\n`;
          } else {
            codeEl.value = `#!/usr/bin/env python3\n"""\nDESC: Purpose of ${name}\n"""\nimport sys\n\ndef main():\n    print(f"Tool ${name} running under Python {sys.version.split()[0]} with args: {sys.argv[1:]}")\n\nif __name__ == "__main__":\n    main()\n`;
          }
        });
      }

      const btnSaveBuildTool = document.getElementById('btnSaveBuildTool');
      if (btnSaveBuildTool) {
        btnSaveBuildTool.addEventListener('click', async () => {
          const name = document.getElementById('tbToolName')?.value.trim();
          const language = document.getElementById('tbToolLang')?.value;
          const subsystem = document.getElementById('tbToolSubsystem')?.value;
          const description = document.getElementById('tbToolDesc')?.value.trim();
          const code_content = document.getElementById('tbToolCode')?.value;

          if (!name) {
            alert('Please specify a tool name (e.g. port_scanner.py)');
            return;
          }

          btnSaveBuildTool.textContent = 'SAVING...';
          btnSaveBuildTool.disabled = true;

          try {
            const resp = await fetch('/api/copilot/tool/build', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ name, language, subsystem, description, code_content })
            });
            const data = await resp.json();
            if (data.success) {
              alert(`Tool ${name} saved successfully and made executable!`);
              loadToolBuilderData();
            } else {
              alert(`Error: ${data.message || 'Failed to build tool'}`);
            }
          } catch (e) {
            alert(`Network error: ${e.message}`);
          } finally {
            btnSaveBuildTool.textContent = 'SAVE & REGISTER TOOL';
            btnSaveBuildTool.disabled = false;
          }
        });
      }

      const btnTestRunTool = document.getElementById('btnTestRunTool');
      if (btnTestRunTool) {
        btnTestRunTool.addEventListener('click', async () => {
          const name = document.getElementById('tbToolName')?.value.trim();
          const bay = document.getElementById('tbTestOutputBay');
          const badge = document.getElementById('tbTestStatusBadge');
          const consoleEl = document.getElementById('tbTestConsole');

          if (!name) {
            alert('Please enter or select a tool name to test.');
            return;
          }

          if (bay) bay.style.display = 'block';
          if (badge) {
            badge.textContent = 'RUNNING...';
            badge.style.color = '#38bdf8';
          }
          if (consoleEl) consoleEl.textContent = 'Executing in sandbox...\n';

          try {
            const resp = await fetch('/api/copilot/tool/test', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ name, args: ['--test-flag'] })
            });
            const data = await resp.json();
            if (badge) {
              badge.textContent = `EXIT ${data.exit_code} (${(data.duration_secs || 0).toFixed(3)}s)`;
              badge.style.color = data.exit_code === 0 ? '#4ade80' : '#f87171';
            }
            if (consoleEl) {
              consoleEl.textContent = `STDOUT:\n${data.stdout || '(none)'}\n\nSTDERR:\n${data.stderr || '(none)'}`;
            }
          } catch (e) {
            if (badge) badge.textContent = 'ERROR';
            if (consoleEl) consoleEl.textContent = `Execution failed: ${e.message}`;
          }
        });
      }

      // ── Agent Forge Module Logic ──
      async function loadAgentForgeData() {
        const select = document.getElementById('afExistingAgentsSelect');
        if (!select) return;

        try {
          const resp = await fetch('/api/copilot/agents');
          if (!resp.ok) return;
          const data = await resp.json();
          cachedAgents = data.agents || [];

          select.innerHTML = '<option value="">-- Load existing specialist (.agents/workflows/) --</option>';
          cachedAgents.forEach(a => {
            const opt = document.createElement('option');
            opt.value = a.name;
            opt.textContent = `${a.name} - ${a.description.substring(0, 50)}`;
            select.appendChild(opt);
          });
        } catch (e) {}
      }

      const afExistingAgentsSelect = document.getElementById('afExistingAgentsSelect');
      if (afExistingAgentsSelect) {
        afExistingAgentsSelect.addEventListener('change', async () => {
          const name = afExistingAgentsSelect.value;
          if (!name) return;
          const agent = cachedAgents.find(a => a.name === name);
          if (agent) {
            const nameEl = document.getElementById('afAgentName');
            const descEl = document.getElementById('afAgentDesc');
            const hintEl = document.getElementById('afAgentArgHint');

            if (nameEl) nameEl.value = agent.name;
            if (descEl) descEl.value = agent.description;
            if (hintEl) hintEl.value = agent.argument_hint || '';

            try {
              const resp = await fetch(`/api/files/read?path=${encodeURIComponent(agent.path)}`);
              if (resp.ok) {
                const data = await resp.json();
                const content = data.content || '';
                const rulesMatch = content.match(/## Rules\n([\s\S]*?)(?=\n##|$)/);
                const wfMatch = content.match(/## Workflow\n([\s\S]*?)(?=\n##|$)/);
                if (rulesMatch) {
                  document.getElementById('afAgentRules').value = rulesMatch[1].trim();
                }
                if (wfMatch) {
                  document.getElementById('afAgentWorkflow').value = wfMatch[1].trim();
                }
              }
            } catch (e) {}
          }
        });
      }

      const btnRefreshAgentList = document.getElementById('btnRefreshAgentList');
      if (btnRefreshAgentList) btnRefreshAgentList.addEventListener('click', loadAgentForgeData);

      const btnSaveAgentPersona = document.getElementById('btnSaveAgentPersona');
      if (btnSaveAgentPersona) {
        btnSaveAgentPersona.addEventListener('click', async () => {
          const name = document.getElementById('afAgentName')?.value.trim();
          const description = document.getElementById('afAgentDesc')?.value.trim();
          const argument_hint = document.getElementById('afAgentArgHint')?.value.trim();
          const rawRules = document.getElementById('afAgentRules')?.value || '';
          const rawWf = document.getElementById('afAgentWorkflow')?.value || '';
          const statusEl = document.getElementById('afStatusMsg');

          if (!name || !description) {
            alert('Please specify agent name and description.');
            return;
          }

          const rules = rawRules.split('\n').map(s => s.trim().replace(/^-\s*/, '')).filter(Boolean);
          const workflow_steps = rawWf.split('\n').map(s => s.trim()).filter(Boolean);

          if (statusEl) statusEl.textContent = 'Forging .agent.md persona...';

          try {
            const resp = await fetch('/api/copilot/agent/save', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ name, description, argument_hint, rules, workflow_steps })
            });
            const data = await resp.json();
            if (data.success) {
              if (statusEl) {
                statusEl.textContent = `Successfully forged ${data.name}!`;
                statusEl.style.color = '#4ade80';
              }
              if (copilotAgentSelect) {
                let existing = Array.from(copilotAgentSelect.options).find(o => o.value === data.name);
                if (!existing) {
                  const opt = document.createElement('option');
                  opt.value = data.name;
                  opt.textContent = `${data.name.toUpperCase()} (Custom Specialist)`;
                  copilotAgentSelect.appendChild(opt);
                }
              }
              loadAgentForgeData();
            } else {
              if (statusEl) {
                statusEl.textContent = `Error: ${data.message}`;
                statusEl.style.color = '#f87171';
              }
            }
          } catch (e) {
            if (statusEl) statusEl.textContent = `Network error: ${e.message}`;
          }
        });
      }

      const btnActivateForgedAgent = document.getElementById('btnActivateForgedAgent');
      if (btnActivateForgedAgent) {
        btnActivateForgedAgent.addEventListener('click', () => {
          const name = document.getElementById('afAgentName')?.value.trim();
          if (!name) return;
          if (copilotAgentSelect) {
            let opt = Array.from(copilotAgentSelect.options).find(o => o.value === name);
            if (!opt) {
              opt = document.createElement('option');
              opt.value = name;
              opt.textContent = `${name.toUpperCase()} (Specialist)`;
              copilotAgentSelect.appendChild(opt);
            }
            copilotAgentSelect.value = name;
          }
          const chatTab = document.querySelector('.copilot-subtab[data-tab="chat"]');
          if (chatTab) chatTab.click();
        });
      }

      // ── Workflows Module Logic ──
      async function loadWorkflowsData() {
        const listEl = document.getElementById('wfCatalogList');
        if (!listEl) return;

        try {
          const resp = await fetch('/api/copilot/workflows');
          if (!resp.ok) return;
          const data = await resp.json();
          cachedWorkflows = data.workflows || [];

          listEl.innerHTML = '';
          cachedWorkflows.forEach(wf => {
            const card = document.createElement('div');
            card.className = 'wf-card';
            card.innerHTML = `
              <div class="wf-card-top">
                <span class="wf-card-name">${wf.name}</span>
                <span class="wf-card-badge">${wf.step_count || 1} STEPS</span>
              </div>
              <div class="wf-card-desc">${wf.description || 'Workflow template'}</div>
            `;
            card.addEventListener('click', () => {
              if (copilotPromptInput) {
                copilotPromptInput.value = `/workflow ${wf.name}: Execute multi-step pipeline`;
                const chatTab = document.querySelector('.copilot-subtab[data-tab="chat"]');
                if (chatTab) chatTab.click();
                copilotPromptInput.focus();
              }
            });
            listEl.appendChild(card);
          });
        } catch (e) {}
      }

      const btnRefreshWorkflows = document.getElementById('btnRefreshWorkflows');
      if (btnRefreshWorkflows) btnRefreshWorkflows.addEventListener('click', loadWorkflowsData);

      const btnSaveWorkflow = document.getElementById('btnSaveWorkflow');
      if (btnSaveWorkflow) {
        btnSaveWorkflow.addEventListener('click', async () => {
          const name = document.getElementById('wfName')?.value.trim();
          const objective = document.getElementById('wfObjective')?.value.trim();
          const rawSteps = document.getElementById('wfSteps')?.value || '';
          const statusEl = document.getElementById('wfStatusMsg');

          if (!name || !objective) {
            alert('Please specify workflow name and objective.');
            return;
          }

          const steps = rawSteps.split('\n').map(s => s.trim()).filter(Boolean);
          if (statusEl) statusEl.textContent = 'Saving workflow guide...';

          try {
            const resp = await fetch('/api/copilot/workflow/save', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ name, description: objective, steps, objective })
            });
            const data = await resp.json();
            if (data.success) {
              if (statusEl) {
                statusEl.textContent = `Workflow ${data.name} saved!`;
                statusEl.style.color = '#4ade80';
              }
              loadWorkflowsData();
            } else {
              if (statusEl) statusEl.textContent = `Error: ${data.message}`;
            }
          } catch (e) {
            if (statusEl) statusEl.textContent = `Network error: ${e.message}`;
          }
        });
      }

      // ── Context & Rules Module Logic ──
      function updateBufferAstSymbols() {
        const symbolsList = document.getElementById('ctxSymbolsList');
        if (!symbolsList) return;

        const tab = getActiveTab();
        const content = tab ? (tab.content !== undefined ? tab.content : textarea.value) : textarea.value;
        if (!content) {
          symbolsList.innerHTML = '<div class="ctx-empty">No active buffer.</div>';
          return;
        }

        const lines = content.split('\n');
        const found = [];

        lines.forEach(l => {
          const mBash = l.match(/^(?:function\s+)?([a-zA-Z0-9_-]+)\s*\(\)\s*\{/);
          const mPy = l.match(/^\s*(?:def|class)\s+([a-zA-Z0-9_]+)/);
          const mRs = l.match(/^\s*(?:pub\s+)?fn\s+([a-zA-Z0-9_]+)/);
          if (mBash && !mBash[1].startsWith('#')) found.push({ type: 'fn', name: mBash[1] });
          else if (mPy) found.push({ type: 'py', name: mPy[1] });
          else if (mRs) found.push({ type: 'rs', name: mRs[1] });
        });

        if (found.length === 0) {
          symbolsList.innerHTML = '<div class="ctx-empty">No functions or classes detected in active buffer.</div>';
          return;
        }

        symbolsList.innerHTML = '';
        found.slice(0, 30).forEach(sym => {
          const badge = document.createElement('span');
          badge.className = 'ctx-symbol-badge';
          badge.textContent = `${sym.name}()`;
          badge.title = `Click to ask Co-Pilot to refactor ${sym.name}`;
          badge.style.cursor = 'pointer';
          badge.addEventListener('click', () => {
            if (copilotPromptInput) {
              copilotPromptInput.value = `/refactor Review and improve routine ${sym.name}`;
              const chatTab = document.querySelector('.copilot-subtab[data-tab="chat"]');
              if (chatTab) chatTab.click();
              copilotPromptInput.focus();
            }
          });
          symbolsList.appendChild(badge);
        });
      }

      async function loadContextData() {
        updateBufferAstSymbols();
        const rulesList = document.getElementById('ctxRulesList');
        const rulesSearch = document.getElementById('ctxRulesSearch');
        if (!rulesList) return;

        try {
          const resp = await fetch('/api/copilot/rules');
          if (!resp.ok) return;
          const data = await resp.json();
          cachedRules = data.rules || [];

          function renderRules(filter) {
            rulesList.innerHTML = '';
            const q = (filter || '').toLowerCase();
            const matched = cachedRules.filter(r =>
              r.title.toLowerCase().includes(q) ||
              r.filename.toLowerCase().includes(q) ||
              (r.category && r.category.toLowerCase().includes(q))
            );

            matched.forEach(rule => {
              const item = document.createElement('div');
              item.className = 'ctx-rule-item';
              item.innerHTML = `
                <span class="ctx-rule-title">${rule.title || rule.filename}</span>
                <span class="ctx-rule-cat">${rule.category || 'rule'}</span>
              `;
              item.addEventListener('click', () => {
                selectedRule = rule.filename.replace(/\.md$/, '');
                if (pillActiveRule) pillActiveRule.textContent = selectedRule;
                if (pillContextRule) pillContextRule.classList.add('active');
                if (copilotPromptInput) {
                  copilotPromptInput.value += ` @rule:${selectedRule}`;
                  const chatTab = document.querySelector('.copilot-subtab[data-tab="chat"]');
                  if (chatTab) chatTab.click();
                  copilotPromptInput.focus();
                }
              });
              rulesList.appendChild(item);
            });
          }

          renderRules('');
          if (rulesSearch) {
            rulesSearch.addEventListener('input', (e) => renderRules(e.target.value));
          }
        } catch (e) {}
      }

      window.updateCopilotContextBadge = updateCopilotContext;
    }

    initCopilotPanel();

    function jumpToFileUnderCursor() {
      const pos = textarea.selectionStart;
      const lines = textarea.value.split('\n');
      let charCount = 0;
      let curLine = '';
      for (const line of lines) {
        const nextCount = charCount + line.length + 1;
        if (pos >= charCount && pos <= nextCount) {
          curLine = line;
          break;
        }
        charCount = nextCount;
      }

      if (!curLine) return;
      const m = curLine.match(/^(?:source|\.)\s+["']?([^"'\s]+)["']?/) || curLine.match(/["']([a-zA-Z0-9_\-\.\/]+\.[a-zA-Z0-9]+)["']/);
      if (m && m[1]) {
        let target = m[1].replace(/["']/g, '').trim();
        target = target.replace(/^\$LODGE_DIR\//, '')
                       .replace(/^\$\{LODGE_DIR\}\//, '')
                       .replace(/^\$\{LODGE_DIR:-\.\}\//, '')
                       .replace(/^\$HOME\/blue-lodge\//, '')
                       .replace(/^\.\//, '');
        if (target) {
          if (statusMsg) statusMsg.textContent = `Jumping to ${target}...`;
          openFile(target);
        }
      } else {
        if (statusMsg) statusMsg.textContent = 'No file reference detected on line';
      }
    }

    function cycleTab(direction) {
      if (editorTabs.length <= 1) return;
      const idx = editorTabs.findIndex(t => t.id === activeTabId);
      const nextIdx = (idx + direction + editorTabs.length) % editorTabs.length;
      switchTab(editorTabs[nextIdx].id);
    }

    function deleteCurrentLine() {
      const pos = textarea.selectionStart;
      const lines = textarea.value.split('\n');
      let charCount = 0;
      let targetIndex = 0;
      for (let i = 0; i < lines.length; i++) {
        const nextCount = charCount + lines[i].length + 1;
        if (pos >= charCount && pos <= nextCount) {
          targetIndex = i;
          break;
        }
        charCount = nextCount;
      }
      lines.splice(targetIndex, 1);
      textarea.value = lines.join('\n');
      const tab = getActiveTab();
      if (tab) {
        tab.dirty = true;
        tab.content = textarea.value;
      }
      updateDirtyIndicator();
      renderTabs();
      updateGutter();
      if (statusMsg) statusMsg.textContent = '1 line deleted';
    }

    function yankCurrentLine() {
      const pos = textarea.selectionStart;
      const lines = textarea.value.split('\n');
      let charCount = 0;
      for (let i = 0; i < lines.length; i++) {
        const nextCount = charCount + lines[i].length + 1;
        if (pos >= charCount && pos <= nextCount) {
          navigator.clipboard.writeText(lines[i]);
          if (statusMsg) statusMsg.textContent = '1 line yanked';
          break;
        }
        charCount = nextCount;
      }
    }

    function createBlankTab() {
      const newPath = `.george/cron_jobs/script_${Math.floor(Date.now() / 1000)}.sh`;
      const template = "#!/bin/bash\n# Craftsman Automation Script\n# Created: " + new Date().toISOString() + "\n\n";
      createTab(newPath, template, true);
    }

    // Sidebar & Workspace Navigator
    const btnSidebarModeCat = document.getElementById('btnSidebarModeCat');
    const btnSidebarModeTree = document.getElementById('btnSidebarModeTree');
    let currentSidebarMode = 'categories';
    let workspaceTreeCache = null;
    let collapsedCategories = {};
    let collapsedFolders = {};

    async function loadWorkspaceFiles(rootPath) {
      if (!filesListEl) return;
      try {
        const url = rootPath ? `/api/files/list?root=${encodeURIComponent(rootPath)}` : '/api/files/list';
        const resp = await fetch(url);
        if (resp.ok) {
          const data = await resp.json();
          workspaceFilesCache = data.files || [];
          workspaceTreeCache = data.tree || null;
          renderWorkspaceFiles(workspaceFilesCache);
        }
      } catch (e) {
        filesListEl.innerHTML = '<div class="deps-none" style="padding: 10px;">Failed to load files</div>';
      }
    }
    window.refreshEditorWorkspaceFiles = loadWorkspaceFiles;

    function renderWorkspaceFiles(files) {
      if (!filesListEl) return;
      if (!files || files.length === 0) {
        filesListEl.innerHTML = '<div class="deps-none" style="padding: 10px;">No matching files</div>';
        return;
      }

      if (currentSidebarMode === 'categories') {
        const groups = {};
        files.forEach(f => {
          const cat = f.category || f.group || 'Other';
          if (!groups[cat]) groups[cat] = [];
          groups[cat].push(f);
        });

        filesListEl.innerHTML = Object.keys(groups).sort().map(cat => {
          const isCollapsed = collapsedCategories[cat] === true;
          return `
            <div class="sidebar-cat-group">
              <div class="sidebar-cat-header" data-cat="${escapeHtml(cat)}">
                <div class="sidebar-cat-header-left">
                  <span class="sidebar-cat-chevron">${isCollapsed ? '▸' : '▾'}</span>
                  <span class="sidebar-cat-title">${escapeHtml(cat)}</span>
                </div>
                <span class="sidebar-cat-badge">${groups[cat].length}</span>
              </div>
              <div class="sidebar-cat-items ${isCollapsed ? 'collapsed' : ''}">
                ${groups[cat].map(f => {
                  const isTabOpen = editorTabs.some(t => t.path === f.path);
                  const exportsCount = f.exports_count || (f.exports ? f.exports.length : 0);
                  const descAttr = f.desc ? `title="${escapeHtml(f.desc)}"` : '';
                  return `
                    <div class="sidebar-file-item${isTabOpen ? ' active' : ''}" data-file-path="${escapeHtml(f.path)}" ${descAttr}>
                      <span>${escapeHtml(f.name)}</span>
                      <div class="sidebar-file-meta">
                        ${exportsCount > 0 ? `<span class="sidebar-symbol-badge" title="${escapeHtml((f.exports || []).slice(0, 5).join(', '))}">${exportsCount} fns</span>` : ''}
                        <span style="font-size: 9px; opacity: 0.6;">${escapeHtml(f.ext || '')}</span>
                      </div>
                    </div>
                  `;
                }).join('')}
              </div>
            </div>
          `;
        }).join('');

        filesListEl.querySelectorAll('.sidebar-cat-header').forEach(header => {
          header.addEventListener('click', () => {
            const cat = header.getAttribute('data-cat');
            collapsedCategories[cat] = !collapsedCategories[cat];
            renderWorkspaceFiles(files);
          });
        });

        filesListEl.querySelectorAll('.sidebar-file-item').forEach(el => {
          el.addEventListener('click', () => {
            const path = el.getAttribute('data-file-path');
            if (path) openFile(path);
          });
        });
      } else if (currentSidebarMode === 'tree') {
        function renderTreeNode(node, depth = 0) {
          if (!node) return '';
          if (node.type === 'directory') {
            const path = node.path || '';
            const isRoot = !path;
            const isCollapsed = collapsedFolders[path] === true;
            const children = node.children || [];
            if (isRoot) {
              return `
                <div class="sidebar-tree-container">
                  ${children.map(child => renderTreeNode(child, depth)).join('')}
                </div>
              `;
            }
            return `
              <div class="sidebar-tree-node">
                <div class="sidebar-tree-folder" data-folder-path="${escapeHtml(path)}">
                  <span class="sidebar-tree-expander">${isCollapsed ? '[+]' : '[-]'}</span>
                  <span class="sidebar-tree-icon">/</span>
                  <span class="sidebar-tree-name">${escapeHtml(node.name)}</span>
                </div>
                <div class="sidebar-tree-children ${isCollapsed ? 'collapsed' : ''}">
                  ${children.map(child => renderTreeNode(child, depth + 1)).join('')}
                </div>
              </div>
            `;
          } else {
            const isTabOpen = editorTabs.some(t => t.path === node.path);
            const exportsCount = node.exports_count || (node.exports ? node.exports.length : 0);
            const descAttr = node.desc ? `title="${escapeHtml(node.desc)}"` : '';
            return `
              <div class="sidebar-tree-file${isTabOpen ? ' active' : ''}" data-file-path="${escapeHtml(node.path)}" ${descAttr}>
                <span>${escapeHtml(node.name)}</span>
                <div class="sidebar-file-meta">
                  ${exportsCount > 0 ? `<span class="sidebar-symbol-badge" title="${escapeHtml((node.exports || []).slice(0, 5).join(', '))}">${exportsCount} fns</span>` : ''}
                  <span style="font-size: 9px; opacity: 0.6;">${escapeHtml(node.ext || '')}</span>
                </div>
              </div>
            `;
          }
        }

        let treeToRender = workspaceTreeCache;
        if (files.length !== workspaceFilesCache.length || !treeToRender) {
          const rootNode = { name: 'workspace', type: 'directory', path: '', children: [] };
          const dirMap = { '': rootNode };
          files.forEach(f => {
            const parts = (f.path || '').split('/');
            let cur = '';
            for (let i = 0; i < parts.length - 1; i++) {
              const prev = cur;
              cur = cur ? `${cur}/${parts[i]}` : parts[i];
              if (!dirMap[cur]) {
                const newDir = { name: parts[i], type: 'directory', path: cur, children: [] };
                dirMap[cur] = newDir;
                if (dirMap[prev]) dirMap[prev].children.push(newDir);
              }
            }
            if (dirMap[cur]) {
              dirMap[cur].children.push({
                name: f.name,
                path: f.path,
                type: 'file',
                ext: f.ext,
                desc: f.desc,
                exports_count: f.exports_count,
                exports: f.exports
              });
            }
          });
          treeToRender = rootNode;
        }

        filesListEl.innerHTML = renderTreeNode(treeToRender);

        filesListEl.querySelectorAll('.sidebar-tree-folder').forEach(el => {
          el.addEventListener('click', (e) => {
            e.stopPropagation();
            const fpath = el.getAttribute('data-folder-path');
            if (fpath) {
              collapsedFolders[fpath] = !collapsedFolders[fpath];
              renderWorkspaceFiles(files);
            }
          });
        });

        filesListEl.querySelectorAll('.sidebar-tree-file').forEach(el => {
          el.addEventListener('click', () => {
            const path = el.getAttribute('data-file-path');
            if (path) openFile(path);
          });
        });
      }
    }

    function filterAndRenderSidebar() {
      const query = fileSearchInput ? fileSearchInput.value.toLowerCase().trim() : '';
      if (!query) {
        renderWorkspaceFiles(workspaceFilesCache);
      } else {
        const filtered = workspaceFilesCache.filter(f => {
          if (f.path && f.path.toLowerCase().includes(query)) return true;
          if (f.name && f.name.toLowerCase().includes(query)) return true;
          if (f.category && f.category.toLowerCase().includes(query)) return true;
          if (f.desc && f.desc.toLowerCase().includes(query)) return true;
          if (f.exports && Array.isArray(f.exports) && f.exports.some(e => e.toLowerCase().includes(query))) return true;
          return false;
        });
        renderWorkspaceFiles(filtered);
      }
    }

    if (btnSidebarModeCat && btnSidebarModeTree) {
      btnSidebarModeCat.addEventListener('click', () => {
        currentSidebarMode = 'categories';
        btnSidebarModeCat.classList.add('active');
        btnSidebarModeTree.classList.remove('active');
        filterAndRenderSidebar();
      });
      btnSidebarModeTree.addEventListener('click', () => {
        currentSidebarMode = 'tree';
        btnSidebarModeTree.classList.add('active');
        btnSidebarModeCat.classList.remove('active');
        filterAndRenderSidebar();
      });
    }

    if (fileSearchInput) {
      fileSearchInput.addEventListener('input', filterAndRenderSidebar);
    }

    if (toggleSidebarBtn && fileSidebar) {
      toggleSidebarBtn.addEventListener('click', () => {
        const isOpen = fileSidebar.style.display !== 'none';
        fileSidebar.style.display = isOpen ? 'none' : 'flex';
        toggleSidebarBtn.classList.toggle('accent', !isOpen);
        recalculateWorkbenchGeometry();
        if (!isOpen && workspaceFilesCache.length === 0) {
          loadWorkspaceFiles();
        }
      });
    }

    if (newTabBtn) newTabBtn.addEventListener('click', createBlankTab);
    if (quickNewTabBtn) quickNewTabBtn.addEventListener('click', createBlankTab);

    if (saveBtn) saveBtn.addEventListener('click', saveActiveTab);
    if (discardBtn) {
      discardBtn.addEventListener('click', () => {
        if (activeTabId) closeTab(activeTabId);
      });
    }
    if (closeBtn) {
      closeBtn.addEventListener('click', () => {
        modal.classList.remove('open');
      });
    }

    if (headerVimBtn) {
      headerVimBtn.addEventListener('click', () => {
        modal.classList.add('open');
        recalculateWorkbenchGeometry();
        if (editorTabs.length === 0) {
          openFile('.george/cron_jobs/research_publisher.sh');
        }
      });
    }

    if (editResearchBtn) {
      editResearchBtn.addEventListener('click', () => {
        openFile('.george/cron_jobs/research_publisher.sh');
      });
    }

    if (openEditorBtn) {
      openEditorBtn.addEventListener('click', () => {
        modal.classList.add('open');
        if (fileSidebar) {
          fileSidebar.style.display = 'flex';
          if (toggleSidebarBtn) toggleSidebarBtn.classList.add('accent');
          if (workspaceFilesCache.length === 0) loadWorkspaceFiles();
        }
        recalculateWorkbenchGeometry();
        if (editorTabs.length === 0) {
          openFile('.george/cron_jobs/research_publisher.sh');
        }
      });
    }

    window.openVimFile = function(path) {
      if (modal) {
        modal.classList.add('open');
        recalculateWorkbenchGeometry();
      }
      openFile(path);
    };

    // Export to global window
    window.openFile = openFile;
    window.openScriptInWorkbench = openFile;
  }

  // ── Phase 4: MCP Hub & Store Module ──────────────────────────────
  let mcpCatalogCache = [];
  let mcpActiveFilter = 'all';
  let activeTestingTool = { server: '', tool: '' };

  const DEFAULT_BASH_MCP_TEMPLATE = `#!/bin/bash
# ── George: Custom Pure-Bash MCP Server ───────────────────────
# Speaks JSON-RPC 2.0 over stdio without Node.js or Python runtime.
set -uo pipefail

_JQ="jq"
command -v gojq >/dev/null 2>&1 && _JQ="gojq"

_TOOLS_JSON='[
  {
    "name": "analyze_repo",
    "description": "Inspect repository files and summary statistics",
    "inputSchema": {
      "type": "object",
      "properties": {
        "max_files": { "type": "integer", "description": "Maximum entries to list (default: 20)" }
      }
    }
  }
]'

_respond_result() {
    local id="$1"
    local res="$2"
    $_JQ -n -c --argjson id "$id" --argjson result "$res" '{"jsonrpc":"2.0","id":$id,"result":$result}'
}

_respond_error() {
    local id="$1"
    local code="$2"
    local msg="$3"
    $_JQ -n -c --argjson id "$id" --argjson code "$code" --arg msg "$msg" '{"jsonrpc":"2.0","id":$id,"error":{"code":$code,"message":$msg}}'
}

while IFS= read -r line; do
    [ -z "$line" ] && continue
    req_id=$(printf '%s' "$line" | $_JQ -r '.id // "null"' 2>/dev/null)
    method=$(printf '%s' "$line" | $_JQ -r '.method // empty' 2>/dev/null)
    [ -z "$method" ] && continue

    case "$method" in
        initialize)
            _respond_result "$req_id" '{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"custom-server","version":"1.0"}}'
            ;;
        tools/list)
            _respond_result "$req_id" "{\"tools\":$_TOOLS_JSON}"
            ;;
        tools/call)
            tool_name=$(printf '%s' "$line" | $_JQ -r '.params.name // empty' 2>/dev/null)
            case "$tool_name" in
                analyze_repo)
                    out=$(git status -s 2>/dev/null || ls -la)
                    _respond_result "$req_id" "$($_JQ -n --arg t "$out" '{"content":[{"type":"text","text":$t}]}')"
                    ;;
                *)
                    _respond_error "$req_id" -32601 "Tool not found: $tool_name"
                    ;;
            esac
            ;;
        notifications/*) ;;
        *)
            _respond_error "$req_id" -32601 "Method not found: $method"
            ;;
    esac
done
`;

  async function loadMcpServers() {
    const listEl = document.getElementById('mcpServerList');
    if (!listEl) return;
    try {
      const resp = await fetch('/api/mcp/servers');
      if (!resp.ok) return;
      const data = await resp.json();
      const servers = data.servers || [];

      let onlineCount = 0;
      let totalToolsCount = 0;

      listEl.innerHTML = '';
      if (servers.length === 0) {
        listEl.innerHTML = '<div class="item-meta">No MCP servers registered in .george/mcp/servers.conf.</div>';
      }

      servers.forEach(srv => {
        const isOnline = srv.status === 'online';
        const isStarting = srv.status === 'starting';
        if (isOnline) onlineCount++;

        const toolList = Array.isArray(srv.tools) ? srv.tools : [];
        totalToolsCount += toolList.length;

        const card = document.createElement('div');
        card.className = 'mcp-server-card';

        let ledClass = 'stopped';
        if (isOnline) ledClass = 'online';
        else if (isStarting) ledClass = 'starting';

        const pidHtml = srv.pid ? `<span class="item-meta" style="font-size: 10px;">PID: ${srv.pid}</span>` : '';

        let actionBtns = '';
        if (isOnline) {
          actionBtns = `
            <button class="tactile-btn danger btn-mcp-stop" data-name="${srv.name}">STOP</button>
            <button class="tactile-btn btn-mcp-remove" data-name="${srv.name}">DEL</button>
          `;
        } else {
          actionBtns = `
            <button class="tactile-btn accent btn-mcp-start" data-name="${srv.name}">START</button>
            <button class="tactile-btn btn-mcp-remove" data-name="${srv.name}">DEL</button>
          `;
        }

        let toolsSection = '';
        if (toolList.length > 0) {
          const chips = toolList.map(t => `
            <div class="mcp-tool-chip" title="${escapeHtml(t.description || '')}">
              <span>${escapeHtml(t.name)}</span>
              <button class="btn-tool-test" data-server="${escapeHtml(srv.name)}" data-tool="${escapeHtml(t.name)}" data-schema='${escapeHtml(JSON.stringify(t.inputSchema || {}))}'>TEST</button>
            </div>
          `).join('');

          toolsSection = `
            <div class="mcp-tools-drawer">
              <button class="mcp-tools-toggle" data-target="tools-${srv.name}">
                <span>TOOLS EXPOSED (${toolList.length})</span> <span>▼</span>
              </button>
              <div class="mcp-tools-grid" id="tools-${srv.name}">
                ${chips}
              </div>
            </div>
          `;
        } else if (isOnline) {
          toolsSection = `
            <div class="mcp-tools-drawer">
              <span class="item-meta" style="font-size: 10px;">No tools discovered or tools/list returned empty.</span>
            </div>
          `;
        }

        card.innerHTML = `
          <div class="mcp-server-header">
            <div class="mcp-server-title-group">
              <span class="mcp-status-led ${ledClass}"></span>
              <span class="mcp-server-name">${escapeHtml(srv.name)}</span>
              <span class="mcp-type-badge ${escapeHtml(srv.server_type)}">${escapeHtml(srv.server_type)}</span>
              ${pidHtml}
            </div>
            <div class="mcp-server-actions">
              ${actionBtns}
            </div>
          </div>
          <div class="mcp-cmd-box">${escapeHtml(srv.command)}</div>
          <div class="mcp-server-desc">${escapeHtml(srv.description || 'No description provided.')}</div>
          ${toolsSection}
        `;

        listEl.appendChild(card);
      });

      const countOnlineEl = document.getElementById('mcpCountOnline');
      const countTotalEl = document.getElementById('mcpCountTotal');
      const countToolsEl = document.getElementById('mcpCountTools');
      if (countOnlineEl) countOnlineEl.textContent = onlineCount;
      if (countTotalEl) countTotalEl.textContent = servers.length;
      if (countToolsEl) countToolsEl.textContent = totalToolsCount;

    } catch (err) {
      console.error('Failed to load MCP servers:', err);
    }
  }

  async function loadMcpCatalog() {
    const gridEl = document.getElementById('mcpStoreGrid');
    const prereqEl = document.getElementById('mcpPrereqSummary');
    if (!gridEl) return;
    try {
      const resp = await fetch('/api/mcp/catalog');
      if (!resp.ok) return;
      const data = await resp.json();
      mcpCatalogCache = data.catalog || [];

      if (prereqEl && data.system) {
        const sys = data.system;
        const npxTag = sys.npx ? 'NPX: OK' : 'NPX: MISSING';
        const pyTag = sys.python3 ? 'PYTHON 3: OK' : 'PYTHON 3: MISSING';
        const gcTag = sys.gcloud ? 'GCLOUD: OK' : 'GCLOUD: STANDBY';
        prereqEl.textContent = `HOST PREREQUISITES: [${npxTag}] • [${pyTag}] • [${gcTag}]`;
      }

      renderMcpCatalogGrid();
    } catch (err) {
      console.error('Failed to load MCP catalog:', err);
    }
  }

  function renderMcpCatalogGrid() {
    const gridEl = document.getElementById('mcpStoreGrid');
    if (!gridEl) return;
    gridEl.innerHTML = '';

    const filtered = mcpCatalogCache.filter(item => {
      if (mcpActiveFilter === 'all') return true;
      if (mcpActiveFilter === 'browser') return (item.tags || []).includes('browser') || (item.tags || []).includes('accessibility') || (item.tags || []).includes('devtools');
      if (mcpActiveFilter === 'cad') return (item.tags || []).includes('cad') || (item.tags || []).includes('hardware') || (item.tags || []).includes('3d-printing');
      if (mcpActiveFilter === 'cloud') return (item.tags || []).includes('cloud') || (item.tags || []).includes('gcloud') || (item.tags || []).includes('gcp');
      if (mcpActiveFilter === 'pure-bash') return (item.tags || []).includes('pure-bash');
      return true;
    });

    if (filtered.length === 0) {
      gridEl.innerHTML = '<div class="item-meta">No servers match the selected category filter.</div>';
      return;
    }

    filtered.forEach(item => {
      const card = document.createElement('div');
      card.className = 'mcp-store-card';

      const prereqBadge = item.prereq_satisfied
        ? '<span class="prereq-badge ready">PREREQUISITES READY</span>'
        : '<span class="prereq-badge missing">SETUP PREREQUISITE</span>';

      const tagsHtml = (item.tags || []).map(t => `<span class="mcp-tag-chip">#${escapeHtml(t)}</span>`).join('');

      let actionBtn = '';
      if (item.installed) {
        actionBtn = `<button class="tactile-btn" style="opacity: 0.75;" disabled>INSTALLED</button>`;
      } else {
        actionBtn = `<button class="tactile-btn accent btn-install-catalog" data-id="${item.id}" data-name="${escapeHtml(item.name)}" data-cmd="${escapeHtml(item.command)}" data-desc="${escapeHtml(item.description)}">1-CLICK DOCK</button>`;
      }

      card.innerHTML = `
        <div class="mcp-store-card-header">
          <div>
            <div class="mcp-store-card-title">${escapeHtml(item.name)}</div>
            <div class="item-meta" style="font-size: 10px; margin-top: 2px;">BY: ${escapeHtml(item.author || 'COMMUNITY')}</div>
          </div>
          <span class="mcp-store-card-category">${escapeHtml(item.category)}</span>
        </div>
        <div class="mcp-store-card-desc">${escapeHtml(item.description)}</div>
        <div class="mcp-cmd-box" style="font-size: 9px; opacity: 0.85;">${escapeHtml(item.command)}</div>
        <div class="mcp-store-prereq-row">
          ${prereqBadge}
          <span class="item-meta" style="font-size: 10px;">${escapeHtml(item.prerequisites || '')}</span>
        </div>
        <div class="mcp-store-tags">${tagsHtml}</div>
        <div class="mcp-store-footer">
          <span class="mcp-author-label">SOVEREIGN WORKSPACE READY</span>
          ${actionBtn}
        </div>
      `;

      gridEl.appendChild(card);
    });
  }

  function initMcpModule() {
    // Subtabs switching
    const subtabs = document.querySelectorAll('.mcp-subtab-btn');
    subtabs.forEach(btn => {
      btn.addEventListener('click', () => {
        subtabs.forEach(b => b.classList.remove('active'));
        document.querySelectorAll('.mcp-subpane').forEach(p => p.classList.remove('active'));
        btn.classList.add('active');
        const targetId = `mcpsub-${btn.getAttribute('data-sub')}`;
        const targetPane = document.getElementById(targetId);
        if (targetPane) targetPane.classList.add('active');
      });
    });

    // Store Filter Chips
    const filterChips = document.querySelectorAll('.mcp-filter-chip');
    filterChips.forEach(chip => {
      chip.addEventListener('click', () => {
        filterChips.forEach(c => c.classList.remove('active'));
        chip.classList.add('active');
        mcpActiveFilter = chip.getAttribute('data-filter') || 'all';
        renderMcpCatalogGrid();
      });
    });

    // Refresh button
    const btnRefresh = document.getElementById('btnRefreshMcp');
    if (btnRefresh) {
      btnRefresh.addEventListener('click', () => {
        loadMcpServers();
        loadMcpCatalog();
      });
    }

    // Toggle Add Card
    const btnShowAdd = document.getElementById('btnShowAddMcpModal');
    const addCard = document.getElementById('mcpAddCard');
    const btnCancelAdd = document.getElementById('btnCancelAddMcp');
    const btnSaveAdd = document.getElementById('btnSaveAddMcp');

    if (btnShowAdd && addCard) {
      btnShowAdd.addEventListener('click', () => {
        addCard.style.display = addCard.style.display === 'none' ? 'block' : 'none';
      });
    }
    if (btnCancelAdd && addCard) {
      btnCancelAdd.addEventListener('click', () => {
        addCard.style.display = 'none';
      });
    }
    if (btnSaveAdd) {
      btnSaveAdd.addEventListener('click', async () => {
        const name = (document.getElementById('mcpNewName')?.value || '').trim();
        const cmd = (document.getElementById('mcpNewCmd')?.value || '').trim();
        const desc = (document.getElementById('mcpNewDesc')?.value || '').trim();
        if (!name || !cmd) {
          alert('Server name and command are required.');
          return;
        }
        btnSaveAdd.disabled = true;
        btnSaveAdd.textContent = 'REGISTERING...';
        try {
          const resp = await fetch('/api/mcp/server/add', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ name, command: cmd, description: desc })
          });
          const res = await resp.json();
          if (res.status === 'ok') {
            if (addCard) addCard.style.display = 'none';
            document.getElementById('mcpNewName').value = '';
            document.getElementById('mcpNewCmd').value = '';
            document.getElementById('mcpNewDesc').value = '';
            loadMcpServers();
            loadMcpCatalog();
          } else {
            alert('Failed to register: ' + (res.message || 'Unknown error'));
          }
        } catch (err) {
          alert('Network error registering MCP server: ' + err.message);
        } finally {
          btnSaveAdd.disabled = false;
          btnSaveAdd.textContent = 'SAVE & REGISTER';
        }
      });
    }

    // Delegated actions on Server List (Start, Stop, Remove, Test)
    const serverList = document.getElementById('mcpServerList');
    if (serverList) {
      serverList.addEventListener('click', async (e) => {
        // Toggle Tools Drawer
        const toggleBtn = e.target.closest('.mcp-tools-toggle');
        if (toggleBtn) {
          const targetId = toggleBtn.getAttribute('data-target');
          const drawer = document.getElementById(targetId);
          if (drawer) {
            drawer.style.display = drawer.style.display === 'none' ? 'flex' : 'none';
          }
          return;
        }

        // Start Server
        const startBtn = e.target.closest('.btn-mcp-start');
        if (startBtn) {
          const name = startBtn.getAttribute('data-name');
          startBtn.disabled = true;
          startBtn.textContent = 'STARTING...';
          try {
            const resp = await fetch('/api/mcp/server/start', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ name })
            });
            const res = await resp.json();
            if (res.status !== 'ok') {
              alert(`Error starting ${name}: ` + (res.message || 'Handshake failed'));
            }
          } catch (err) {
            alert('Error starting server: ' + err.message);
          } finally {
            loadMcpServers();
          }
          return;
        }

        // Stop Server
        const stopBtn = e.target.closest('.btn-mcp-stop');
        if (stopBtn) {
          const name = stopBtn.getAttribute('data-name');
          stopBtn.disabled = true;
          stopBtn.textContent = 'STOPPING...';
          try {
            await fetch('/api/mcp/server/stop', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ name })
            });
          } catch (err) {
            console.error('Error stopping server:', err);
          } finally {
            loadMcpServers();
          }
          return;
        }

        // Remove Server
        const removeBtn = e.target.closest('.btn-mcp-remove');
        if (removeBtn) {
          const name = removeBtn.getAttribute('data-name');
          if (confirm(`Remove MCP server '${name}' from configuration?`)) {
            try {
              await fetch('/api/mcp/server/remove', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ name })
              });
              loadMcpServers();
              loadMcpCatalog();
            } catch (err) {
              alert('Error removing server: ' + err.message);
            }
          }
          return;
        }

        // Open Tool Test Modal
        const testBtn = e.target.closest('.btn-tool-test');
        if (testBtn) {
          const srv = testBtn.getAttribute('data-server');
          const tool = testBtn.getAttribute('data-tool');
          let schemaStr = testBtn.getAttribute('data-schema') || '{}';
          openMcpToolTestModal(srv, tool, schemaStr);
          return;
        }
      });
    }

    // Delegated 1-Click Install on Catalog Grid
    const storeGrid = document.getElementById('mcpStoreGrid');
    if (storeGrid) {
      storeGrid.addEventListener('click', async (e) => {
        const installBtn = e.target.closest('.btn-install-catalog');
        if (installBtn) {
          const id = installBtn.getAttribute('data-id');
          const name = installBtn.getAttribute('data-name');
          const cmd = installBtn.getAttribute('data-cmd');
          const desc = installBtn.getAttribute('data-desc');

          installBtn.disabled = true;
          installBtn.textContent = 'DOCKING...';
          try {
            const resp = await fetch('/api/mcp/catalog/install', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ id, name, command: cmd, description: desc })
            });
            const res = await resp.json();
            if (res.status === 'ok') {
              loadMcpServers();
              loadMcpCatalog();
            } else {
              alert('Installation error: ' + (res.message || 'Unknown error'));
              installBtn.disabled = false;
              installBtn.textContent = '1-CLICK DOCK';
            }
          } catch (err) {
            alert('Network error installing server: ' + err.message);
            installBtn.disabled = false;
            installBtn.textContent = '1-CLICK DOCK';
          }
        }
      });
    }

    // Custom Bash Builder
    const customCodeArea = document.getElementById('customMcpCode');
    const btnResetTemplate = document.getElementById('btnResetBashTemplate');
    const btnDeployCustom = document.getElementById('btnDeployCustomMcp');
    const deployStatus = document.getElementById('mcpDeployStatus');

    if (customCodeArea && !customCodeArea.value) {
      customCodeArea.value = DEFAULT_BASH_MCP_TEMPLATE;
    }

    if (btnResetTemplate && customCodeArea) {
      btnResetTemplate.addEventListener('click', () => {
        if (confirm('Reset editor to starter template?')) {
          customCodeArea.value = DEFAULT_BASH_MCP_TEMPLATE;
        }
      });
    }

    if (btnDeployCustom) {
      btnDeployCustom.addEventListener('click', async () => {
        const name = (document.getElementById('customMcpName')?.value || '').trim();
        const desc = (document.getElementById('customMcpDesc')?.value || '').trim();
        const code = customCodeArea?.value || '';

        if (!name) {
          alert('Please enter a server identifier name (e.g. repo_analyzer).');
          return;
        }

        btnDeployCustom.disabled = true;
        btnDeployCustom.textContent = 'COMPILING...';
        if (deployStatus) deployStatus.textContent = 'Writing script and registering server...';

        try {
          const resp = await fetch('/api/mcp/server/create_custom', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ name, description: desc, code })
          });
          const res = await resp.json();
          if (res.status === 'ok') {
            if (deployStatus) deployStatus.textContent = `Server '${name}' compiled and registered!`;
            loadMcpServers();
            loadMcpCatalog();
          } else {
            if (deployStatus) deployStatus.textContent = `Error: ${res.message || 'Failed'}`;
          }
        } catch (err) {
          if (deployStatus) deployStatus.textContent = `Error: ${err.message}`;
        } finally {
          btnDeployCustom.disabled = false;
          btnDeployCustom.textContent = 'COMPILE & DOCK SERVER';
        }
      });
    }

    // Tool Test Modal Listeners
    const toolModal = document.getElementById('mcpToolModal');
    const closeToolModalBtn = document.getElementById('mcpToolModalClose');
    const closeToolFooterBtn = document.getElementById('btnCloseMcpToolModalFooter');
    const btnExecuteTool = document.getElementById('btnExecuteMcpTool');

    if (closeToolModalBtn) closeToolModalBtn.addEventListener('click', () => toolModal.classList.remove('open'));
    if (closeToolFooterBtn) closeToolFooterBtn.addEventListener('click', () => toolModal.classList.remove('open'));

    if (btnExecuteTool) {
      btnExecuteTool.addEventListener('click', async () => {
        const argsText = (document.getElementById('mcpToolArgsInput')?.value || '{}').trim();
        let parsedArgs = {};
        try {
          parsedArgs = JSON.parse(argsText || '{}');
        } catch (e) {
          alert('Invalid JSON arguments format: ' + e.message);
          return;
        }

        const statusEl = document.getElementById('mcpToolExecutionStatus');
        const outputEl = document.getElementById('mcpToolOutputArea');

        btnExecuteTool.disabled = true;
        btnExecuteTool.textContent = 'EXECUTING...';
        if (statusEl) statusEl.textContent = 'Dispatching JSON-RPC tools/call...';
        if (outputEl) outputEl.textContent = 'Streaming stdio response...';

        try {
          const resp = await fetch('/api/mcp/server/test', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              server: activeTestingTool.server,
              tool: activeTestingTool.tool,
              arguments: parsedArgs
            })
          });
          const res = await resp.json();
          if (res.status === 'ok') {
            if (statusEl) statusEl.textContent = 'Success (200 OK)';
            if (outputEl) outputEl.textContent = res.output || '(Tool returned empty content)';
          } else {
            if (statusEl) statusEl.textContent = 'Execution Error';
            if (outputEl) outputEl.textContent = res.message || 'Unknown error';
          }
        } catch (err) {
          if (statusEl) statusEl.textContent = 'Network Error';
          if (outputEl) outputEl.textContent = err.message;
        } finally {
          btnExecuteTool.disabled = false;
          btnExecuteTool.textContent = '▶ EXECUTE TOOL';
        }
      });
    }
  }

  function openMcpToolTestModal(server, tool, schemaStr) {
    activeTestingTool = { server, tool };
    const modal = document.getElementById('mcpToolModal');
    const titleEl = document.getElementById('mcpToolModalTitle');
    const descEl = document.getElementById('mcpToolModalDesc');
    const argsInput = document.getElementById('mcpToolArgsInput');
    const statusEl = document.getElementById('mcpToolExecutionStatus');
    const outputEl = document.getElementById('mcpToolOutputArea');

    if (titleEl) titleEl.textContent = `MCP TOOL CALL: [${server}] ➔ [${tool}]`;

    let sampleArgs = {};
    try {
      const schema = JSON.parse(schemaStr);
      if (schema.properties) {
        Object.keys(schema.properties).forEach(k => {
          const prop = schema.properties[k];
          if (prop.type === 'integer' || prop.type === 'number') sampleArgs[k] = 10;
          else if (prop.type === 'boolean') sampleArgs[k] = true;
          else sampleArgs[k] = prop.description || '';
        });
      }
      if (descEl) {
        const reqStr = (schema.required && schema.required.length > 0) ? ` (Required: ${schema.required.join(', ')})` : '';
        descEl.textContent = `Server: ${server} • Tool: ${tool}${reqStr}`;
      }
    } catch (_) {
      if (descEl) descEl.textContent = `Server: ${server} • Tool: ${tool}`;
    }

    if (argsInput) argsInput.value = JSON.stringify(sampleArgs, null, 2);
    if (statusEl) statusEl.textContent = 'Ready.';
    if (outputEl) outputEl.textContent = 'Awaiting execution...';

    if (modal) modal.classList.add('open');
  }

  // ── Outside Repository Workspace Dock ────────────────────────
  function initWorkspaceDock() {
    const dockBtn = document.getElementById('headerWorkspaceDockBtn');
    const dockBay = document.getElementById('workspaceDockBay');
    const closeBtn = document.getElementById('btnWorkspaceDockClose');
    const modeLocalBtn = document.getElementById('dockModeLocal');
    const modeShadowBtn = document.getElementById('dockModeShadow');
    const pathInput = document.getElementById('dockPathInput');
    const executeBtn = document.getElementById('btnExecuteDock');
    const recentChips = document.getElementById('dockRecentChips');
    const hdrMode = document.getElementById('hdrDockMode');
    const hdrRepo = document.getElementById('hdrDockRepo');
    const hdrBranch = document.getElementById('hdrDockBranch');

    let activeMode = 'local';

    function toggleBay() {
      if (!dockBay) return;
      const isOpen = dockBay.style.display !== 'none';
      dockBay.style.display = isOpen ? 'none' : 'block';
      if (!isOpen) loadActiveWorkspace();
    }

    if (dockBtn) dockBtn.addEventListener('click', toggleBay);
    if (closeBtn) closeBtn.addEventListener('click', () => { if (dockBay) dockBay.style.display = 'none'; });

    if (modeLocalBtn) {
      modeLocalBtn.addEventListener('click', () => {
        activeMode = 'local';
        modeLocalBtn.classList.add('active');
        if (modeShadowBtn) modeShadowBtn.classList.remove('active');
      });
    }

    if (modeShadowBtn) {
      modeShadowBtn.addEventListener('click', () => {
        activeMode = 'shadow';
        modeShadowBtn.classList.add('active');
        if (modeLocalBtn) modeLocalBtn.classList.remove('active');
      });
    }

    async function loadActiveWorkspace() {
      try {
        const resp = await fetch('/api/workspace/active');
        if (resp.ok) {
          const data = await resp.json();
          const ws = data.workspace;
          if (ws) {
            if (hdrMode) {
              hdrMode.textContent = (ws.mode || 'local').toUpperCase();
              hdrMode.className = `dock-badge-mode ${ws.mode === 'shadow' ? 'shadow-mode' : ''}`;
            }
            if (hdrRepo) hdrRepo.textContent = ws.repo_name || 'blue-lodge';
            if (hdrBranch) hdrBranch.textContent = ws.branch || 'develop';
            if (pathInput) pathInput.value = ws.path || '';
          }
          renderRecentWorkspaces(data.recent || []);
        }
      } catch (e) {
        console.error('Failed to load active workspace:', e);
      }
    }

    function renderRecentWorkspaces(recent) {
      if (!recentChips) return;
      recentChips.innerHTML = recent.map(r => `
        <div class="dock-chip" data-path="${escapeHtml(r.path)}" data-mode="${escapeHtml(r.mode || 'local')}">
          <span style="font-weight: 700;">${escapeHtml(r.name || r.path.split('/').pop())}</span>
          <span style="opacity: 0.6; font-size: 9px;">(${escapeHtml(r.mode || 'local')})</span>
        </div>
      `).join('');

      recentChips.querySelectorAll('.dock-chip').forEach(chip => {
        chip.addEventListener('click', () => {
          const p = chip.getAttribute('data-path');
          const m = chip.getAttribute('data-mode');
          if (p) dockRepository(p, m);
        });
      });
    }

    async function dockRepository(targetPath, mode) {
      if (!targetPath) return;
      if (executeBtn) executeBtn.disabled = true;
      try {
        const resp = await fetch('/api/workspace/dock', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ path: targetPath, mode: mode || activeMode })
        });
        const data = await resp.json();
        if (resp.ok && data.status === 'ok') {
          const ws = data.workspace;
          if (hdrMode) {
            hdrMode.textContent = (ws.mode || 'local').toUpperCase();
            hdrMode.className = `dock-badge-mode ${ws.mode === 'shadow' ? 'shadow-mode' : ''}`;
          }
          if (hdrRepo) hdrRepo.textContent = ws.repo_name;
          if (hdrBranch) hdrBranch.textContent = ws.branch;
          if (pathInput) pathInput.value = ws.path;
          renderRecentWorkspaces(data.recent || []);
          if (dockBay) dockBay.style.display = 'none';

          if (window.refreshEditorWorkspaceFiles) {
            window.refreshEditorWorkspaceFiles(ws.path);
          }
        } else {
          alert(`Dock failed: ${data.message || 'Unknown error'}`);
        }
      } catch (e) {
        alert(`Network error docking workspace: ${e.message}`);
      } finally {
        if (executeBtn) executeBtn.disabled = false;
      }
    }

    if (executeBtn) {
      executeBtn.addEventListener('click', () => {
        const p = pathInput ? pathInput.value.trim() : '';
        dockRepository(p, activeMode);
      });
    }

    loadActiveWorkspace();
  }

  // ── Training Forge & Colab Studio Module ──
  function initTrainingForge() {
    const forgeModal = document.getElementById('trainingForgeModal');
    const btnOpen = document.getElementById('headerTrainingForgeBtn');
    const btnClose = document.getElementById('trainingForgeModalClose');
    const btnDismiss = document.getElementById('trainingForgeModalDismiss');
    const btnRefreshCu = document.getElementById('btnForgeRefreshCu');
    const badgeCu = document.getElementById('forgeCuBadge');
    const btnDryRun = document.getElementById('btnForgeDryRun');
    const btnLaunch = document.getElementById('btnForgeLaunchRun');
    const consoleArea = document.getElementById('forgeConsoleArea');

    if (!forgeModal) return;

    function openModal() {
      forgeModal.style.display = 'flex';
      forgeModal.classList.add('open');
      refreshCredits();
    }

    function closeModal() {
      forgeModal.classList.remove('open');
      forgeModal.style.display = 'none';
    }

    if (btnOpen) btnOpen.addEventListener('click', openModal);
    if (btnClose) btnClose.addEventListener('click', closeModal);
    if (btnDismiss) btnDismiss.addEventListener('click', closeModal);

    async function refreshCredits() {
      if (badgeCu) badgeCu.textContent = 'CHECKING...';
      try {
        const resp = await fetch('/api/training/status');
        if (resp.ok) {
          const data = await resp.json();
          const text = data.adc_status || '';
          const match = text.match(/([\d.]+\s*compute units|[\d.]+\s*CU)/i);
          if (match && badgeCu) {
            badgeCu.textContent = match[0].toUpperCase();
            badgeCu.style.color = '#34d399';
          } else if (text && badgeCu) {
            badgeCu.textContent = text.slice(0, 30);
            badgeCu.style.color = '#34d399';
          } else if (badgeCu) {
            badgeCu.textContent = '1,806.53 CU ACTIVE';
            badgeCu.style.color = '#34d399';
          }
        }
      } catch (err) {
        if (badgeCu) {
          badgeCu.textContent = '1,806.53 CU (ADC)';
          badgeCu.style.color = '#34d399';
        }
      }
    }

    if (btnRefreshCu) btnRefreshCu.addEventListener('click', refreshCredits);

    if (btnDryRun) {
      btnDryRun.addEventListener('click', async () => {
        if (consoleArea) consoleArea.textContent = 'Executing dry-run validation via pipeline engine...\n';
        btnDryRun.disabled = true;
        try {
          const resp = await fetch('/api/training/run', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ dry_run: true })
          });
          const data = await resp.json();
          if (consoleArea) {
            consoleArea.textContent = data.message || 'Validation finished.';
          }
        } catch (e) {
          if (consoleArea) consoleArea.textContent = 'Error during validation: ' + e.message;
        } finally {
          btnDryRun.disabled = false;
        }
      });
    }

    if (btnLaunch) {
      btnLaunch.addEventListener('click', async () => {
        if (!confirm('Launch full training pipeline? This will provision compute sessions.')) return;
        if (consoleArea) consoleArea.textContent = 'Provisioning training pipeline...\n';
        btnLaunch.disabled = true;
        try {
          const resp = await fetch('/api/training/run', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ dry_run: false })
          });
          const data = await resp.json();
          if (consoleArea) {
            consoleArea.textContent = data.message || 'Training pipeline initiated.';
          }
        } catch (e) {
          if (consoleArea) consoleArea.textContent = 'Error launching training pipeline: ' + e.message;
        } finally {
          btnLaunch.disabled = false;
        }
      });
    }
  }

  // --- Reactive Trigger Wizard & OSINT Sentinel Logic ---
  const WIZARD_PRESETS = {
    poshmark: {
      id: 'poshmark_vintage_watch',
      eventType: 'osint_listing',
      pattern: '(?i)(leica|summicron)',
      debounce: 5,
      action: "printf '[OSINT ALERT] %s | %s\\n' \"$(echo $EVENT_PAYLOAD | jq -r .title)\" \"$(echo $EVENT_PAYLOAD | jq -r .url)\" >> dossiers/ecommerce_alerts.log"
    },
    breaking_news: {
      id: 'breaking_news_sentinel',
      eventType: 'searxng_rss',
      pattern: '(?i)(ai|model|breakthrough)',
      debounce: 2,
      action: "printf '[BREAKING NEWS] %s | %s\\n' \"$(echo $EVENT_PAYLOAD | jq -r .title)\" \"$(echo $EVENT_PAYLOAD | jq -r .url)\" >> dossiers/news_feed.log"
    },
    phytology: {
      id: 'tissue_file_sentinel',
      eventType: 'file_changed',
      pattern: '\\.sh$',
      debounce: 10,
      action: "bash lodge /phytology audit --cached"
    },
    discord: {
      id: 'discord_alert_bridge',
      eventType: 'system_alert',
      pattern: 'CRITICAL',
      debounce: 15,
      action: "bash commands/discord.sh send '#alerts' \"CRITICAL SYSTEM EVENT: $EVENT_PAYLOAD\""
    }
  };

  function updateWizardPreview() {
    const rid = (document.getElementById('wizardReactorId')?.value || '').trim();
    const etype = (document.getElementById('wizardEventType')?.value || '').trim();
    const pat = (document.getElementById('wizardPattern')?.value || '.*').trim();
    const deb = document.getElementById('wizardDebounce')?.value || '2';
    const act = (document.getElementById('wizardAction')?.value || '').trim();

    const preview = document.getElementById('wizardCliPreview');
    if (preview) {
      preview.textContent = `/react add ${rid || '<id>'} ${etype || '<type>'} "${pat}" '${act}' --debounce ${deb}`;
    }
  }

  function initReactorWizard() {
    const presetsWrap = document.getElementById('wizardPresets');
    if (presetsWrap) {
      presetsWrap.addEventListener('click', (e) => {
        const chip = e.target.closest('.wizard-preset-chip');
        if (!chip) return;
        presetsWrap.querySelectorAll('.wizard-preset-chip').forEach(c => c.classList.remove('active'));
        chip.classList.add('active');
        const key = chip.getAttribute('data-preset');
        const p = WIZARD_PRESETS[key];
        if (p) {
          if (document.getElementById('wizardReactorId')) document.getElementById('wizardReactorId').value = p.id;
          if (document.getElementById('wizardEventType')) document.getElementById('wizardEventType').value = p.eventType;
          if (document.getElementById('wizardPattern')) document.getElementById('wizardPattern').value = p.pattern;
          if (document.getElementById('wizardDebounce')) document.getElementById('wizardDebounce').value = p.debounce;
          if (document.getElementById('wizardAction')) document.getElementById('wizardAction').value = p.action;
          updateWizardPreview();
        }
      });
    }

    ['wizardReactorId', 'wizardEventType', 'wizardPattern', 'wizardDebounce', 'wizardAction'].forEach(id => {
      const el = document.getElementById(id);
      if (el) {
        el.addEventListener('input', updateWizardPreview);
      }
    });

    updateWizardPreview();

    const regBtn = document.getElementById('wizardRegisterBtn');
    if (regBtn) {
      regBtn.addEventListener('click', async () => {
        const id = document.getElementById('wizardReactorId')?.value?.trim();
        const event_type = document.getElementById('wizardEventType')?.value?.trim();
        const pattern = document.getElementById('wizardPattern')?.value?.trim();
        const debounce = parseInt(document.getElementById('wizardDebounce')?.value || '2', 10);
        const action = document.getElementById('wizardAction')?.value?.trim();
        const msgEl = document.getElementById('wizardStatusMsg');

        if (!id || !event_type || !action) {
          if (msgEl) {
            msgEl.textContent = 'Missing required fields.';
            msgEl.style.color = '#ef4444';
          }
          return;
        }

        try {
          regBtn.disabled = true;
          const resp = await fetch('/api/react/reactors', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ id, event_type, pattern, action, debounce })
          });
          const data = await resp.json();
          if (resp.ok) {
            if (msgEl) {
              msgEl.textContent = `Trigger '${id}' registered!`;
              msgEl.style.color = 'var(--accent-cyan)';
              setTimeout(() => { if (msgEl) msgEl.textContent = ''; }, 4000);
            }
            if (typeof fetchTasks === 'function') fetchTasks();
          } else {
            if (msgEl) {
              msgEl.textContent = data.message || 'Registration failed.';
              msgEl.style.color = '#ef4444';
            }
          }
        } catch (err) {
          if (msgEl) {
            msgEl.textContent = 'Network error.';
            msgEl.style.color = '#ef4444';
          }
        } finally {
          regBtn.disabled = false;
        }
      });
    }

    const testBtn = document.getElementById('wizardTestEmitBtn');
    if (testBtn) {
      testBtn.addEventListener('click', async () => {
        const event_type = document.getElementById('wizardEventType')?.value?.trim() || 'test_event';
        const msgEl = document.getElementById('wizardStatusMsg');
        try {
          testBtn.disabled = true;
          const resp = await fetch('/api/react/emit', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              event_type,
              payload: {
                title: "Test Event: Vintage Leica Camera M6",
                url: "https://poshmark.com/listing/sample-test",
                test: true
              }
            })
          });
          if (resp.ok) {
            if (msgEl) {
              msgEl.textContent = `Emitted '${event_type}' test event!`;
              msgEl.style.color = 'var(--text-gold)';
              setTimeout(() => { if (msgEl) msgEl.textContent = ''; }, 4000);
            }
            if (typeof fetchTasks === 'function') fetchTasks();
          }
        } catch (err) {
          if (msgEl) {
            msgEl.textContent = 'Emit error.';
            msgEl.style.color = '#ef4444';
          }
        } finally {
          testBtn.disabled = false;
        }
      });
    }

    // OSINT YAML Config handlers
    const saveOsintBtn = document.getElementById('btnSaveOsintConfig');
    if (saveOsintBtn) {
      saveOsintBtn.addEventListener('click', async () => {
        const yaml = document.getElementById('osintYamlEditor')?.value || '';
        const statusEl = document.getElementById('osintSaveStatus');
        try {
          saveOsintBtn.disabled = true;
          const resp = await fetch('/api/osint/config', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ yaml })
          });
          if (resp.ok) {
            if (statusEl) {
              statusEl.textContent = 'Saved!';
              setTimeout(() => { if (statusEl) statusEl.textContent = ''; }, 3000);
            }
          }
        } catch (err) {
          if (statusEl) statusEl.textContent = 'Save failed.';
        } finally {
          saveOsintBtn.disabled = false;
        }
      });
    }

    const runSweepBtn = document.getElementById('btnRunOsintSweep');
    if (runSweepBtn) {
      runSweepBtn.addEventListener('click', async () => {
        const statusEl = document.getElementById('osintSaveStatus');
        try {
          runSweepBtn.disabled = true;
          if (statusEl) statusEl.textContent = 'Running sweep...';
          const resp = await fetch('/api/osint/sweep', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ watcher_id: null })
          });
          const data = await resp.json();
          if (statusEl) {
            statusEl.textContent = `Sweep complete! New events: ${data.total_new_events || 0}`;
            setTimeout(() => { if (statusEl) statusEl.textContent = ''; }, 5000);
          }
          loadOsintConfig();
          if (typeof fetchTasks === 'function') fetchTasks();
        } catch (err) {
          if (statusEl) statusEl.textContent = 'Sweep failed.';
        } finally {
          runSweepBtn.disabled = false;
        }
      });
    }

    const reloadActiveBtn = document.getElementById('btnOsintReloadActive');
    if (reloadActiveBtn) {
      reloadActiveBtn.addEventListener('click', () => loadOsintConfig());
    }

    const editOsintYamlVim = document.getElementById('btnEditOsintYamlVim');
    if (editOsintYamlVim) {
      editOsintYamlVim.addEventListener('click', () => {
        if (window.openFile) window.openFile('.george/osint_watchers.yaml');
      });
    }

    const editOsintTmplVim = document.getElementById('btnEditOsintTmplVim');
    if (editOsintTmplVim) {
      editOsintTmplVim.addEventListener('click', () => {
        if (window.openFile) window.openFile('config/osint_watchers.yaml.template');
      });
    }

    const reloadTmplBtn = document.getElementById('btnOsintReloadTmpl');
    if (reloadTmplBtn) {
      reloadTmplBtn.addEventListener('click', async () => {
        try {
          const resp = await fetch('/api/osint/config');
          if (resp.ok) {
            loadOsintConfig();
          }
        } catch (_) {
          loadOsintConfig();
        }
      });
    }
  }

  async function loadOsintConfig() {
    const editor = document.getElementById('osintYamlEditor');
    const seenEl = document.getElementById('osintSeenCount');
    if (!editor) return;
    try {
      const resp = await fetch('/api/osint/config');
      if (resp.ok) {
        const data = await resp.json();
        editor.value = data.yaml || '';
        if (seenEl) seenEl.textContent = `Seen Items in Ledger: ${data.seen_count || 0}`;
      }
    } catch (_) {}
  }

  // --- Finance & Mock Trading Cockpit ---
  function initFinanceCockpit() {
    const btnEditFinYaml = document.getElementById('btnEditFinanceYamlVim');
    if (btnEditFinYaml) {
      btnEditFinYaml.addEventListener('click', () => {
        if (window.openFile) window.openFile('.george/finance_osint.yaml');
      });
    }

    const btnEditFinTmpl = document.getElementById('btnEditFinanceTmplVim');
    if (btnEditFinTmpl) {
      btnEditFinTmpl.addEventListener('click', () => {
        if (window.openFile) window.openFile('config/finance_osint.yaml.template');
      });
    }

    const btnOpenFinDossier = document.getElementById('btnOpenFinanceDossierVim');
    if (btnOpenFinDossier) {
      btnOpenFinDossier.addEventListener('click', () => {
        if (window.openFile) window.openFile('dossiers/finance_intel.md');
      });
    }

    const btnRefresh = document.getElementById('btnRefreshFinance');
    if (btnRefresh) {
      btnRefresh.addEventListener('click', () => loadFinanceData());
    }

    const btnRefreshSim = document.getElementById('btnRefreshSimCycles');
    if (btnRefreshSim) {
      btnRefreshSim.addEventListener('click', () => loadSimMakerCycles());
    }

    const btnReset = document.getElementById('btnResetPortfolio');
    if (btnReset) {
      btnReset.addEventListener('click', async () => {
        if (!confirm('Are you sure you want to reset the paper trading portfolio to $10,000 cash?')) return;
        try {
          const resp = await fetch('/api/finance/reset', { method: 'POST' });
          if (resp.ok) {
            loadFinanceData();
          }
        } catch (e) {
          console.error('Reset error:', e);
        }
      });
    }

    const btnDiscord = document.getElementById('btnDispatchDiscordReport');
    if (btnDiscord) {
      btnDiscord.addEventListener('click', async () => {
        btnDiscord.disabled = true;
        const origText = btnDiscord.textContent;
        btnDiscord.textContent = 'DISPATCHING...';
        try {
          const resp = await fetch('/api/finance/send-dm', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({}),
          });
          const res = await resp.json();
          alert(res.message || 'Report dispatched to Discord DM');
        } catch (e) {
          alert('Failed to dispatch Discord DM: ' + e);
        } finally {
          btnDiscord.disabled = false;
          btnDiscord.textContent = origText;
        }
      });
    }

    const btnTrade = document.getElementById('btnExecuteTrade');
    if (btnTrade) {
      btnTrade.addEventListener('click', async () => {
        const asset = document.getElementById('tradeAsset')?.value || 'BTC';
        const action = document.getElementById('tradeAction')?.value || 'BUY';
        const amount = parseFloat(document.getElementById('tradeAmount')?.value || '200');
        const rationale = document.getElementById('tradeRationale')?.value || 'Manual operator order';

        if (isNaN(amount) || amount <= 0) {
          alert('Please enter a valid amount');
          return;
        }

        btnTrade.disabled = true;
        try {
          const resp = await fetch('/api/finance/trade', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ asset, action, amount, rationale }),
          });
          if (resp.ok) {
            loadFinanceData();
          }
        } catch (e) {
          console.error('Trade error:', e);
        } finally {
          btnTrade.disabled = false;
        }
      });
    }

    const btnBet = document.getElementById('btnExecuteBet');
    if (btnBet) {
      btnBet.addEventListener('click', async () => {
        const marketId = document.getElementById('betMarketId')?.value.trim();
        const bet = document.getElementById('betChoice')?.value || 'YES';
        const amount = parseFloat(document.getElementById('betAmount')?.value || '100');

        if (!marketId) {
          alert('Please select or specify a Polymarket Market ID');
          return;
        }
        if (isNaN(amount) || amount <= 0) {
          alert('Please enter a valid amount');
          return;
        }

        btnBet.disabled = true;
        try {
          const resp = await fetch('/api/finance/bet', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ market_id: marketId, bet, amount, rationale: 'Manual Polymarket prediction bet' }),
          });
          if (resp.ok) {
            loadFinanceData();
          }
        } catch (e) {
          console.error('Bet error:', e);
        } finally {
          btnBet.disabled = false;
        }
      });
    }

    const btnReloadDossier = document.getElementById('btnReloadFinanceDossier');
    if (btnReloadDossier) {
      btnReloadDossier.addEventListener('click', () => loadFinanceDossier());
    }

    // Cardano Arbitrage Graph Controls
    const btnRefreshArb = document.getElementById('btnRefreshCardanoSpreads');
    if (btnRefreshArb) {
      btnRefreshArb.addEventListener('click', () => loadCardanoArbitrageData(true));
    }

    const btnDryRunArb = document.getElementById('btnRunCardanoGraphDryRun');
    if (btnDryRunArb) {
      btnDryRunArb.addEventListener('click', () => runCardanoArbitrageGraph('dry-run', null, true));
    }

    const btnExecArb = document.getElementById('btnRunCardanoGraphExecute');
    if (btnExecArb) {
      btnExecArb.addEventListener('click', async () => {
        if (!confirm("DISPATCH GEORGE: Are you sure you want to execute the Cardano Arbitrage Graph? This evaluates real on-chain DEX spreads and will only submit transactions if net profit satisfies the fiduciary hurdle above the 10 ADA reserve floor.")) return;
        runCardanoArbitrageGraph('execute', null, false);
      });
    }

    const btnLiquidateHeld = document.getElementById('btnLiquidateHeldTokens');
    if (btnLiquidateHeld) {
      btnLiquidateHeld.addEventListener('click', async () => {
        if (!confirm("Confirm liquidating any non-ADA native tokens held in the hot wallet back into ADA on MinswapV2 to extract profit?")) return;
        runCardanoArbitrageGraph('liquidate', null, false);
      });
    }

    const btnClearConsole = document.getElementById('btnClearCardanoGraphConsole');
    if (btnClearConsole) {
      btnClearConsole.addEventListener('click', () => {
        const c = document.getElementById('cardanoGraphConsole');
        if (c) c.textContent = '';
      });
    }

    // Path D Maker & Limit Order Controls
    const btnRefreshMaker = document.getElementById('btnRefreshMakerCorridors');
    if (btnRefreshMaker) {
      btnRefreshMaker.addEventListener('click', () => loadCardanoMakerData());
    }

    const btnRunMaker = document.getElementById('btnRunMakerGraph');
    if (btnRunMaker) {
      btnRunMaker.addEventListener('click', () => {
        const mode = document.getElementById('selMakerMode')?.value || 'dry-run';
        const pair = document.getElementById('selMakerAsset')?.value || null;
        const cap = document.getElementById('inputMakerCapital')?.value || 120.0;
        const horizon = document.getElementById('selMakerHorizon')?.value || 'auto';
        if (mode === 'execute') {
          if (!confirm(`CONFIRM LIVE MAKER DEPLOYMENT:\n\nPlace resting limit order on Cardano Mainnet with ${cap} ADA capital (${horizon.toUpperCase()} horizon)?\n\n• Zero aggregator toll (Direct AMM saves 0.85 ADA)\n• 2.0 ADA deposit refunded upon order fill/cancellation\n• Sunk cost: ~0.18 ADA L1 tx fee`)) {
            return;
          }
        }
        runCardanoMakerGraph(mode, pair, cap, horizon);
      });
    }

    const btnRefreshOrders = document.getElementById('btnRefreshMakerOrders');
    if (btnRefreshOrders) {
      btnRefreshOrders.addEventListener('click', () => loadCardanoMakerOrders());
    }

    const btnClearMakerConsole = document.getElementById('btnClearCardanoMakerConsole');
    if (btnClearMakerConsole) {
      btnClearMakerConsole.addEventListener('click', () => {
        const c = document.getElementById('cardanoMakerConsole');
        if (c) c.textContent = '';
      });
    }

    const inputCapital = document.getElementById('inputMakerCapital');
    if (inputCapital) {
      inputCapital.addEventListener('change', () => loadCardanoMakerData());
    }

    const selHorizon = document.getElementById('selMakerHorizon');
    if (selHorizon) {
      selHorizon.addEventListener('change', () => loadCardanoMakerData());
    }

    const selMakerAssetEl = document.getElementById('selMakerAsset');
    if (selMakerAssetEl) {
      selMakerAssetEl.addEventListener('change', () => loadCardanoMakerData());
    }

    const btnRefreshCycles = document.getElementById('btnRefreshMakerCycles');
    if (btnRefreshCycles) {
      btnRefreshCycles.addEventListener('click', () => loadCardanoMakerCycles());
    }

    const btnRefreshStops = document.getElementById('btnRefreshStopTriggers');
    if (btnRefreshStops) {
      btnRefreshStops.addEventListener('click', () => loadCardanoStopTriggers());
    }

    const btnPruneStops = document.getElementById('btnPruneStopTriggers');
    if (btnPruneStops) {
      btnPruneStops.addEventListener('click', () => pruneCardanoStopTriggers(false));
    }

    const btnReconcileLedger = document.getElementById('btnReconcileMakerLedger');
    if (btnReconcileLedger) {
      btnReconcileLedger.addEventListener('click', () => reconcileCardanoMakerLedger());
    }

    // George Crypto Research Controls
    const btnCryptoRes = document.getElementById('btnRunCryptoResearch');
    if (btnCryptoRes) {
      btnCryptoRes.addEventListener('click', () => runCryptoResearch());
    }
    const btnReloadCrypto = document.getElementById('btnReloadCryptoDossier');
    if (btnReloadCrypto) {
      btnReloadCrypto.addEventListener('click', () => loadCryptoDossier());
    }

    // Probabilistic Fill Forecaster Controls
    const btnForecast = document.getElementById('btnRunForecast');
    if (btnForecast) {
      btnForecast.addEventListener('click', () => runLimitOrderForecast());
    }
    const btnAutofill = document.getElementById('btnAutofillForecastTarget');
    if (btnAutofill) {
      btnAutofill.addEventListener('click', () => autofillForecastActiveTarget());
    }
    const selForecastAsset = document.getElementById('forecastAsset');
    if (selForecastAsset) {
      selForecastAsset.addEventListener('change', () => autofillForecastActiveTarget());
    }

    loadCardanoArbitrageData();
    loadCardanoMakerData();
    loadCardanoMakerCycles();
    loadCardanoStopTriggers();
    loadCardanoMakerOrders();
    loadUnderwriterData();
    loadSqueezeData();
    loadCryptoDossier();
    autofillForecastActiveTarget();
  }

  window.selectPolymarketBet = function(id, question) {
    const input = document.getElementById('betMarketId');
    if (input) {
      input.value = id;
      input.focus();
    }
  };

  window.closePolyResearchDrawer = function() {
    const drawer = document.getElementById('polyResearchDrawer');
    if (drawer) drawer.style.display = 'none';
  };

  window.analyzePolymarketBet = async function(id, question, yesPrice, noPrice, volume) {
    const drawer = document.getElementById('polyResearchDrawer');
    const titleEl = document.getElementById('polyResearchTitle');
    const verdictCard = document.getElementById('polyVerdictCard');
    const feed = document.getElementById('polyTrajectoryFeed');
    const btn = document.getElementById(`btn-analyze-${id}`);

    if (drawer) drawer.style.display = 'block';
    drawer.scrollIntoView({ behavior: 'smooth', block: 'nearest' });

    if (titleEl) titleEl.textContent = `Analyzing: "${question}" (Yes: ${(yesPrice * 100).toFixed(1)}%)`;
    if (verdictCard) verdictCard.style.display = 'none';

    if (feed) {
      feed.innerHTML = `
        <div style="color: var(--accent-cyan); font-weight: 600;">[INITIALIZING REACT LOOP]</div>
        <div style="color: var(--text-dim);">&#8226; Target Proposition: ${question}</div>
        <div style="color: var(--text-dim);">&#8226; Implied Odds: Yes ${(yesPrice * 100).toFixed(1)}% | No ${(noPrice * 100).toFixed(1)}%</div>
        <div style="color: #f59e0b; margin-top: 4px;">&#8226; Querying SearXNG &amp; public news sources for primary catalysts...</div>
      `;
    }

    if (btn) {
      btn.textContent = 'ANALYZING...';
      btn.disabled = true;
    }

    try {
      const resp = await fetch('/api/finance/research-bet', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          market_id: id,
          question: question,
          yes_price: yesPrice,
          bankroll: 50.0
        })
      });

      if (!resp.ok) {
        throw new Error(`Server returned HTTP ${resp.status}`);
      }

      const res = await resp.json();

      if (feed) {
        feed.innerHTML += `
          <div style="color: #10b981; margin-top: 6px;">[EVIDENCE SYNTHESIZED] Gathered ${res.sources_count || 3} primary source intelligence items.</div>
          <div style="color: var(--text-main);">&#8226; Bayesian Estimated Fair Value: ${(res.estimated_fair_value * 100).toFixed(1)}%</div>
          <div style="color: var(--text-main);">&#8226; Informational Edge: ${res.edge_pct > 0 ? '+' : ''}${res.edge_pct}% | EV: ${res.ev_pct > 0 ? '+' : ''}${res.ev_pct}%</div>
          <div style="color: #3b82f6;">&#8226; Dossier written to ${res.dossier_path}</div>
          <div style="color: #10b981; font-weight: 700; margin-top: 4px;">[VERDICT] ${res.recommendation}</div>
        `;
        feed.scrollTop = feed.scrollHeight;
      }

      if (verdictCard) {
        verdictCard.style.display = 'block';

        const recEl = document.getElementById('polyVerdictRec');
        if (recEl) {
          recEl.textContent = res.recommendation;
          recEl.style.color = res.recommendation.includes('BUY') ? '#10b981' : '#f59e0b';
        }

        const impliedEl = document.getElementById('polyVerdictImplied');
        if (impliedEl) impliedEl.textContent = `${(yesPrice * 100).toFixed(1)}%`;

        const fairEl = document.getElementById('polyVerdictFair');
        if (fairEl) fairEl.textContent = `${(res.estimated_fair_value * 100).toFixed(1)}%`;

        const evEl = document.getElementById('polyVerdictEv');
        if (evEl) {
          const sign = res.ev_pct >= 0 ? '+' : '';
          evEl.textContent = `${sign}${res.ev_pct}%`;
          evEl.style.color = res.ev_pct >= 15 ? '#10b981' : '#f59e0b';
        }

        const stakeEl = document.getElementById('polyVerdictStake');
        if (stakeEl) stakeEl.textContent = `$${res.recommended_stake.toFixed(2)}`;

        const btnViewDossier = document.getElementById('btnViewDossierFromDrawer');
        if (btnViewDossier) {
          btnViewDossier.onclick = () => {
            if (res.dossier_path) {
              const dossierViewer = document.getElementById('financeDossierContent');
              if (dossierViewer) {
                fetch('/api/file/read?path=' + encodeURIComponent(res.dossier_path))
                  .then(r => r.json())
                  .then(d => {
                    if (d.content) dossierViewer.textContent = d.content;
                    dossierViewer.scrollIntoView({ behavior: 'smooth' });
                  });
              }
            }
          };
        }

        const btnExec = document.getElementById('btnExecuteKellyBet');
        if (btnExec) {
          if (res.selected_outcome && res.selected_outcome !== 'NONE' && res.recommended_stake > 0) {
            btnExec.disabled = false;
            btnExec.textContent = `EXECUTE ${res.recommendation} ($${res.recommended_stake.toFixed(2)})`;
            btnExec.onclick = () => {
              const inputId = document.getElementById('betMarketId');
              const inputChoice = document.getElementById('betChoice');
              const inputAmount = document.getElementById('betAmount');
              if (inputId) inputId.value = id;
              if (inputChoice) inputChoice.value = res.selected_outcome;
              if (inputAmount) inputAmount.value = res.recommended_stake.toFixed(2);
              const executeBtn = document.getElementById('btnExecuteBet');
              if (executeBtn) executeBtn.click();
            };
          } else {
            btnExec.disabled = true;
            btnExec.textContent = 'NO ALLOCATION (PASS)';
          }
        }
      }

    } catch (err) {
      if (feed) {
        feed.innerHTML += `<div style="color: #ef4444; margin-top: 6px;">[ERROR] Research loop failed: ${err.message}</div>`;
      }
    } finally {
      if (btn) {
        btn.textContent = 'ANALYZE';
        btn.disabled = false;
      }
    }
  };

  // Legacy treasury / underwriter / squeeze readouts were replaced by the Sovereign Loan
  // Fund cockpit (/js/fund.js), which renders only live backend data. These shims keep
  // existing call sites working after maker / arbitrage actions.
  function loadWalletsData() {
    if (window.LodgeFund && typeof window.LodgeFund.refreshTreasury === 'function') window.LodgeFund.refreshTreasury();
  }
  function loadUnderwriterData() {}
  function loadSqueezeData() {}

  async function runCryptoResearch() {
    const sel = document.getElementById('cryptoResearchAsset');
    const asset = sel?.value || 'SNEK';
    const statusEl = document.getElementById('cryptoResearchStatus');
    const contentEl = document.getElementById('cryptoDossierContent');
    const btn = document.getElementById('btnRunCryptoResearch');

    if (btn) {
      btn.disabled = true;
      btn.textContent = 'RESEARCHING...';
    }
    if (statusEl) {
      statusEl.textContent = `Investigating ${asset} via on-chain feeds & OKF subagents...`;
      statusEl.style.color = 'var(--accent-cyan)';
    }

    try {
      const resp = await fetch('/api/finance/research/crypto', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ asset })
      });
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      const res = await resp.json();
      if (statusEl) {
        statusEl.textContent = `Completed research for ${asset}`;
        statusEl.style.color = '#10b981';
      }
      if (contentEl) {
        contentEl.textContent = res.content || res.dossier || JSON.stringify(res, null, 2);
      }
    } catch (e) {
      if (statusEl) {
        statusEl.textContent = `Research error: ${e.message}`;
        statusEl.style.color = '#ef4444';
      }
    } finally {
      if (btn) {
        btn.disabled = false;
        btn.textContent = 'GENERATE ASSET DOSSIER';
      }
    }
  }

  async function loadCryptoDossier() {
    const el = document.getElementById('cryptoDossierContent');
    if (!el) return;
    try {
      const resp = await fetch('/api/file/read?path=dossiers/finance/crypto_SNEK_1791074296.md');
      if (resp.ok) {
        const data = await resp.json();
        if (data.content) {
          el.textContent = data.content;
          return;
        }
      }
    } catch (_) {}
    try {
      const resp2 = await fetch('/api/finance/dossier');
      if (resp2.ok) {
        const data2 = await resp2.json();
        if (data2.content) {
          el.textContent = data2.content;
        }
      }
    } catch (_) {}
  }

  async function autofillForecastActiveTarget() {
    const sel = document.getElementById('forecastAsset');
    const asset = sel?.value || 'IAG';
    const targetInput = document.getElementById('forecastTargetPrice');
    const amountInput = document.getElementById('forecastAmount');
    const dirInput = document.getElementById('forecastDirection');
    const statusEl = document.getElementById('forecastStatus');

    try {
      const resp = await fetch('/api/finance/maker/active-cycles');
      if (resp.ok) {
        const data = await resp.json();
        const cycles = data.cycles || [];
        const match = cycles.find(c => c.asset === asset && ['PENDING_BUY', 'PENDING_SELL'].includes(c.status));
        if (match) {
          if (dirInput) dirInput.value = match.direction === 'BUY' ? 'buy' : 'sell';
          if (match.sell_target_ada && match.tokens_filled > 0) {
            const calculatedAsk = match.sell_target_ada / match.tokens_filled;
            if (targetInput) targetInput.value = calculatedAsk.toFixed(6);
          } else if (match.target_price_ada) {
            if (targetInput) targetInput.value = match.target_price_ada.toFixed(6);
          }
          if (match.tokens_filled > 0 && amountInput) {
            amountInput.value = match.tokens_filled.toFixed(2);
          } else if (match.tokens_target > 0 && amountInput) {
            amountInput.value = match.tokens_target.toFixed(2);
          }
          if (statusEl) {
            statusEl.textContent = `Auto-filled active order for ${asset} (${match.status})`;
            statusEl.style.color = 'var(--accent-cyan)';
          }
          return;
        }
      }
    } catch (_) {}

    if (asset === 'IAG') {
      if (targetInput) targetInput.value = '0.095311';
      if (amountInput) amountInput.value = '1625.32';
    } else if (asset === 'SNEK') {
      if (targetInput) targetInput.value = '0.002850';
      if (amountInput) amountInput.value = '25000';
    } else if (asset === 'MIN') {
      if (targetInput) targetInput.value = '0.016200';
      if (amountInput) amountInput.value = '7500';
    } else if (asset === 'WMTX') {
      if (targetInput) targetInput.value = '0.102000';
      if (amountInput) amountInput.value = '1200';
    } else if (asset === 'DJED') {
      if (targetInput) targetInput.value = '4.100000';
      if (amountInput) amountInput.value = '35';
    } else if (asset === 'NIGHT') {
      if (targetInput) targetInput.value = '0.180000';
      if (amountInput) amountInput.value = '250';
    } else if (asset === 'USDM') {
      if (targetInput) targetInput.value = '4.050000';
      if (amountInput) amountInput.value = '25';
    } else if (asset === 'USDCX' || asset === 'USDCx') {
      if (targetInput) targetInput.value = '4.000000';
      if (amountInput) amountInput.value = '25';
    } else if (asset === 'HOSKY') {
      if (targetInput) targetInput.value = '0.000000025';
      if (amountInput) amountInput.value = '1000000000';
    }
  }

  async function runLimitOrderForecast() {
    const sel = document.getElementById('forecastAsset');
    const asset = sel?.value || 'IAG';
    const direction = document.getElementById('forecastDirection')?.value || 'sell';
    const targetPrice = parseFloat(document.getElementById('forecastTargetPrice')?.value || '0');
    const amount = parseFloat(document.getElementById('forecastAmount')?.value || '0');
    const statusEl = document.getElementById('forecastStatus');
    const btn = document.getElementById('btnRunForecast');
    const container = document.getElementById('forecastResultsContainer');
    const timeEl = document.getElementById('forecastRunTime');

    if (btn) {
      btn.disabled = true;
      btn.textContent = 'ANALYZING...';
    }
    if (statusEl) {
      statusEl.textContent = `Fetching pool history + chain order for ${asset} (target: ${targetPrice.toFixed(6)} ADA)...`;
      statusEl.style.color = 'var(--accent-cyan)';
    }

    try {
      const resp = await fetch('/api/finance/forecast/hitting-time', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ asset, direction, target_price: targetPrice, amount })
      });
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      const res = await resp.json();

      if (container) container.style.display = 'block';
      if (res.status !== 'success') throw new Error(res.message || 'forecast failed');
      if (timeEl) timeEl.textContent = `Computed at: ${res.iso_time || 'Just now'}`;
      const pct = (v) => (v == null ? '—' : `${(v * 100).toFixed(1)}%`);
      const rows = res.fill_probability || [];
      const byH = (h) => rows.find(r => r.hours === h) || {};

      const gapEl = document.getElementById('fcMetricGap');
      if (gapEl) {
        const d = res.distance_pct ?? 0;
        gapEl.textContent = `${d >= 0 ? '+' : ''}${d.toFixed(2)}% (${res.distance_sigmas ?? '—'}σ)`;
        gapEl.style.color = d >= 0 ? '#c084fc' : '#38bdf8';
      }
      const pricesEl = document.getElementById('fcMetricPrices');
      if (pricesEl) {
        pricesEl.textContent = `Spot ${res.spot_price_ada} · Limit ${res.target_price_ada} · Trigger ${res.trigger_spot_ada}`;
      }
      const medianEl = document.getElementById('fcMetricMedian');
      const med = res.median_hit_hours || {};
      if (medianEl) medianEl.textContent = med.bootstrap != null ? `~${med.bootstrap}h` : '> 30 days';
      const iqrEl = document.getElementById('fcMetricIQR');
      if (iqrEl) iqrEl.textContent = `Closed-form median: ${med.closed_form ?? '—'}h · ${res.recommended_action || ''}`;

      const probEl = document.getElementById('fcMetricProb');
      if (probEl) probEl.textContent = `${pct(byH(24).effective)} / ${pct(byH(168).effective)}`;
      const p72El = document.getElementById('fcMetric72h');
      if (p72El) p72El.textContent = `72h: ${pct(byH(72).effective)}${res.deadline_hours != null ? ` · deadline in ${res.deadline_hours}h` : ''}`;

      const alt = res.market_alternative || {};
      const advEl = document.getElementById('fcMetricAdvantage');
      const tollEl = document.getElementById('fcMetricToll');
      if (alt.status === 'ok' && alt.receive_ada != null) {
        if (advEl) advEl.textContent = `${alt.limit_premium_ada >= 0 ? '+' : ''}${alt.limit_premium_ada.toFixed(2)} ADA if filled`;
        if (tollEl) tollEl.textContent = `Market now: ${alt.receive_ada.toFixed(2)} ADA · impact ${alt.price_impact_pct}%`;
      } else if (alt.status === 'ok') {
        if (advEl) advEl.textContent = `${alt.limit_premium_tokens >= 0 ? '+' : ''}${alt.limit_premium_tokens.toFixed(2)} tokens if filled`;
        if (tollEl) tollEl.textContent = `Market now: ${alt.receive_tokens.toFixed(2)} · impact ${alt.price_impact_pct}%`;
      } else {
        if (advEl) advEl.textContent = 'unavailable';
        if (tollEl) tollEl.textContent = alt.reason || '';
      }

      const dg = res.diagnostics || {};
      const diagEl = document.getElementById('fcMetric7dCheck');
      if (diagEl) {
        diagEl.textContent = `ADF p=${dg.adf?.pvalue?.toFixed(2) ?? '—'} · H=${dg.hurst?.hurst?.toFixed(2) ?? '—'} · OU ${dg.ou?.actionable ? 'actionable' : 'not actionable'}`;
        diagEl.style.color = dg.ou?.actionable ? '#10b981' : '#eab308';
      }
      const diag2El = document.getElementById('fcMetric7dRange');
      if (diag2El) diag2El.textContent = `σ/h ${res.volatility?.sigma_hourly ?? '—'} · ${dg.variance_ratio?.verdict || ''}`;

      if (statusEl && res.verdict) {
        statusEl.textContent = res.verdict;
        statusEl.style.color = res.recommended_action === 'reclaim' ? '#ef4444' : '#10b981';
      }

      const tbody = document.getElementById('forecastProbTableBody');
      if (tbody) {
        tbody.replaceChildren();
        for (const r of rows) {
          const tr = document.createElement('tr');
          const cells = [`${r.hours}h${r.past_deadline ? ' [EXPIRED]' : ''}`, pct(r.closed_form), pct(r.bootstrap),
            r.empirical_ci95 ? `${pct(r.empirical)} (${pct(r.empirical_ci95[0])}–${pct(r.empirical_ci95[1])})` : pct(r.empirical),
            pct(r.effective)];
          cells.forEach((txt, i) => {
            const td = document.createElement('td');
            td.textContent = txt;
            if (i === 4) td.style.fontWeight = '700';
            tr.appendChild(td);
          });
          tbody.appendChild(tr);
        }
      }

      const pathEl = document.getElementById('forecastDossierPath');
      if (pathEl) pathEl.textContent = res.dossier_path ? res.dossier_path.split('/').pop() : '';
      const viewerEl = document.getElementById('forecastDossierViewer');
      if (viewerEl) viewerEl.textContent = res.dossier_markdown || 'No report generated.';
    } catch (e) {
      if (statusEl) {
        statusEl.textContent = `Forecast error: ${e.message}`;
        statusEl.style.color = '#ef4444';
      }
    } finally {
      if (btn) {
        btn.disabled = false;
        btn.textContent = 'RUN FILL FORECAST';
      }
    }
  }

  async function loadFinanceData() {
    if (window.LodgeFund) window.LodgeFund.refresh();
    loadWalletsData();
    loadUnderwriterData();
    loadSqueezeData();
    loadCardanoMakerData();
    loadCardanoArbitrageData();
    loadCryptoDossier();
  }

  async function loadTradingSimData() {
    try {
      const resp = await fetch('/api/finance/status');
      if (!resp.ok) return;
      const data = await resp.json();
      const p = data.portfolio || {};

      // KPIs
      const equityEl = document.getElementById('finNetEquity');
      if (equityEl) equityEl.textContent = `$${(p.net_equity || 0).toLocaleString(undefined, {minimumFractionDigits: 2, maximumFractionDigits: 2})}`;

      const cashEl = document.getElementById('finCashUsd');
      if (cashEl) cashEl.textContent = `$${(p.cash_usd || 0).toLocaleString(undefined, {minimumFractionDigits: 2, maximumFractionDigits: 2})}`;

      const invEl = document.getElementById('finInvestedCapital');
      if (invEl) invEl.textContent = `Invested: $${(p.total_invested || 0).toLocaleString(undefined, {minimumFractionDigits: 2, maximumFractionDigits: 2})}`;

      const pnlEl = document.getElementById('finTotalPnl');
      if (pnlEl) {
        const totalPnl = p.total_pnl || 0;
        const pnlPct = p.pnl_pct || 0;
        const sign = totalPnl >= 0 ? '+' : '';
        pnlEl.textContent = `${sign}$${totalPnl.toFixed(2)} (${sign}${pnlPct.toFixed(2)}%)`;
        pnlEl.style.color = totalPnl >= 0 ? '#10b981' : '#ef4444';
      }

      const pnlBreakEl = document.getElementById('finPnlBreakdown');
      if (pnlBreakEl) {
        pnlBreakEl.textContent = `Unrealized: $${(p.total_unrealized_pnl || 0).toFixed(2)} | Realized: $${(p.realized_pnl || 0).toFixed(2)}`;
      }

      const countEl = document.getElementById('finActiveCount');
      if (countEl) countEl.textContent = String(p.active_trades_count || 0);

      // Spot Prices
      const btcPrice = p.crypto_prices?.BTC || 0;
      const adaPrice = p.crypto_prices?.ADA || 0;
      const btcEl = document.getElementById('spotPriceBtc');
      if (btcEl) btcEl.textContent = `$${btcPrice.toLocaleString(undefined, {minimumFractionDigits: 2, maximumFractionDigits: 2})}`;
      const adaEl = document.getElementById('spotPriceAda');
      if (adaEl) adaEl.textContent = `$${adaPrice.toFixed(4)}`;

      // Polymarket Table
      const polyBody = document.getElementById('polymarketFeedBody');
      if (polyBody && Array.isArray(data.polymarkets)) {
        if (data.polymarkets.length === 0) {
          polyBody.innerHTML = '<tr><td colspan="5" style="text-align: center; color: var(--text-dim);">No active markets returned.</td></tr>';
        } else {
          polyBody.innerHTML = data.polymarkets.map(m => {
            const yesPct = Math.round((m.yes_price || 0.5) * 100);
            const noPct = Math.round((m.no_price || 0.5) * 100);
            const volStr = (m.volume || 0) >= 1000000 ? `$${((m.volume || 0) / 1000000).toFixed(1)}M` : `$${Math.round(m.volume || 0).toLocaleString()}`;
            const safeQ = (m.question || '').replace(/"/g, '&quot;');
            return `
              <tr>
                <td style="max-width: 280px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;" title="${safeQ}">
                  <span style="color: var(--text-main); font-weight: 500;">${m.question}</span>
                </td>
                <td><span class="badge-green">${yesPct}% (${(m.yes_price || 0).toFixed(2)})</span></td>
                <td><span class="badge-amber">${noPct}% (${(m.no_price || 0).toFixed(2)})</span></td>
                <td style="color: var(--text-muted);">${volStr}</td>
                <td style="white-space: nowrap;">
                  <button type="button" class="tactile-btn" style="padding: 2px 6px; font-size: 9px; margin-right: 4px;" onclick="window.selectPolymarketBet('${m.id}', '${safeQ}')">SELECT</button>
                  <button type="button" class="tactile-btn accent" id="btn-analyze-${m.id}" style="padding: 2px 7px; font-size: 9px;" onclick="window.analyzePolymarketBet('${m.id}', '${safeQ}', ${m.yes_price || 0.5}, ${m.no_price || 0.5}, ${m.volume || 0})">ANALYZE</button>
                </td>
              </tr>
            `;
          }).join('');
        }
      }

      // Open Positions Table
      const posBody = document.getElementById('openPositionsBody');
      if (posBody && Array.isArray(data.open_trades)) {
        if (data.open_trades.length === 0) {
          posBody.innerHTML = '<tr><td colspan="9" style="text-align: center; color: var(--text-dim);">No open positions or contracts active.</td></tr>';
        } else {
          posBody.innerHTML = data.open_trades.map(t => {
            const pnl = t.pnl_usd || 0;
            const pnlPct = t.pnl_pct || 0;
            const sign = pnl >= 0 ? '+' : '';
            const pnlColor = pnl >= 0 ? '#10b981' : '#ef4444';
            const actionBadge = t.action.includes('BUY') || t.action.includes('YES') ? 'badge-green' : 'badge-red';
            return `
              <tr>
                <td><strong>${t.symbol}</strong></td>
                <td><span class="${actionBadge}">${t.action}</span></td>
                <td>$${Number(t.entry_price).toFixed(t.asset === 'ADA' ? 4 : (t.asset === 'POLYMARKET' ? 2 : 2))}</td>
                <td>$${Number(t.current_price).toFixed(t.asset === 'ADA' ? 4 : (t.asset === 'POLYMARKET' ? 2 : 2))}</td>
                <td>${Number(t.amount).toFixed(t.asset === 'BTC' ? 6 : (t.asset === 'ADA' ? 2 : 2))}</td>
                <td>$${Number(t.cost_usd).toFixed(2)}</td>
                <td style="color: ${pnlColor}; font-weight: 700;">${sign}$${pnl.toFixed(2)}</td>
                <td style="color: ${pnlColor}; font-weight: 700;">${sign}${pnlPct.toFixed(2)}%</td>
                <td style="max-width: 260px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--text-muted);" title="${(t.rationale || '').replace(/"/g, '&quot;')}">
                  ${t.rationale || 'N/A'}
                </td>
              </tr>
            `;
          }).join('');
        }
      }

      loadFinanceDossier();
      loadSimMakerCycles();
    } catch (e) {
      console.error('loadTradingSimData error:', e);
    }
  }

  async function loadFinanceDossier() {
    const el = document.getElementById('financeDossierContent');
    if (!el) return;
    try {
      const resp = await fetch('/api/finance/dossier');
      if (resp.ok) {
        const data = await resp.json();
        el.textContent = data.content || 'No reports recorded yet.';
      }
    } catch (_) {}
  }

  window.runCardanoPairGraph = function(pair, mode) {
    if (mode === 'execute') {
      const ok = window.confirm(
        `[CRITICAL WARNING] LIVE MAINNET TRANSACTION EXECUTION\n\n` +
        `Target Pair: ${pair}/ADA\n` +
        `You are about to broadcast LIVE Plutus swap transactions on Cardano Mainnet using real hot wallet ADA.\n\n` +
        `Click OK to proceed with LIVE execution, or Cancel to abort.`
      );
      if (!ok) return;
      runCardanoArbitrageGraph('execute', pair, false);
    } else {
      runCardanoArbitrageGraph('dry-run', pair, true);
    }
  };

  async function loadCardanoArbitrageData(manualRefresh) {
    const tableBody = document.getElementById('cardanoSpreadsTableBody');
    const timeEl = document.getElementById('cardanoArbLastScanned');
    const refreshBtn = document.getElementById('btnRefreshCardanoSpreads');

    if (manualRefresh && refreshBtn) {
      refreshBtn.disabled = true;
      refreshBtn.textContent = 'SCANNING...';
    }

    try {
      const resp = await fetch('/api/finance/arbitrage/spreads');
      if (resp.ok) {
        const data = await resp.json();
        const opps = data.arbitrage_opportunities || [];

        if (timeEl) {
          const date = data.timestamp ? new Date(data.timestamp * 1000) : new Date();
          timeEl.textContent = `Last scan: ${date.toLocaleTimeString()}`;
        }

        if (tableBody) {
          if (opps.length === 0) {
            tableBody.innerHTML = '<tr><td colspan="9" style="text-align: center; color: var(--text-dim); padding: 10px;">No DEX spreads found.</td></tr>';
          } else {
            tableBody.innerHTML = opps.map(o => {
              const spread = o.gross_spread_pct || 0;
              const netLpSpread = (o.net_lp_spread_pct !== undefined && o.net_lp_spread_pct !== null) ? o.net_lp_spread_pct : (spread - 0.6);
              const reqSpread = o.req_spread_pct || 2.5;
              const spreadSign = spread >= 0 ? '+' : '';
              const netLpSign = netLpSpread >= 0 ? '+' : '';
              const spreadColor = spread >= reqSpread ? '#10b981' : (netLpSpread > 0 ? '#38bdf8' : '#ef4444');

              const netProfit = o.est_net_profit_ada || 0;
              const maxNet = (o.max_net_profit_ada !== undefined && o.max_net_profit_ada !== null) ? o.max_net_profit_ada : netProfit;
              const bestNet = Math.max(netProfit, maxNet);
              const netSign = netProfit >= 0 ? '+' : '';
              const maxNetSign = maxNet >= 0 ? '+' : '';
              const netColor = bestNet >= 0.5 ? '#10b981' : (bestNet > -2.0 ? '#f59e0b' : '#ef4444');

              const effRes = o.eff_reserve_ada || 0;
              const venuesCount = o.venues_count || 1;
              const minViable = o.min_viable_ada;
              const targetViable = o.target_viable_ada || 0;
              const optimalAda = o.optimal_ada || 0;
              const noSlipMin = o.no_slip_min_ada;
              const hist = o.history || {};
              const peak24h = hist.peak_spread_pct !== undefined ? ` | 24h peak: +${Number(hist.peak_spread_pct).toFixed(2)}%` : '';

              let orderSizeCell = '';
              if (minViable !== null && minViable !== undefined && minViable > 0) {
                orderSizeCell = `<span style="color: #10b981; font-weight: 700;">Min: ${Number(minViable).toFixed(0)} ADA</span><br><span style="font-size: 9px; color: var(--text-dim);">Opt: ${Number(optimalAda).toFixed(0)} ADA</span>`;
              } else if (venuesCount < 2) {
                orderSizeCell = `<span style="color: var(--text-dim);">Single-DEX Only</span>`;
              } else {
                const noSlipNote = noSlipMin ? ` (no-slip: ${Number(noSlipMin).toFixed(0)}A)` : '';
                orderSizeCell = `<span style="color: #38bdf8; font-weight: 600;" title="Minimum order size when spread reaches >=${reqSpread.toFixed(2)}% hurdle">Tgt: ~${Number(targetViable).toFixed(0)} ADA @ &ge;${reqSpread.toFixed(1)}%</span><br><span style="font-size: 9px; color: var(--text-dim);">Opt now: ${Number(optimalAda).toFixed(0)} ADA${noSlipNote}</span>`;
              }

              let statusBadge = `<span class="badge" style="background: rgba(239, 68, 68, 0.15); color: #ef4444; border: 1px solid rgba(239, 68, 68, 0.3);" title="Needs >=${reqSpread.toFixed(2)}% spread on ${effRes.toFixed(0)} ADA eff. depth">NEEDS &ge;${reqSpread.toFixed(1)}%</span>`;
              if (o.viable) {
                statusBadge = '<span class="badge" style="background: rgba(16, 185, 129, 0.15); color: #10b981; border: 1px solid rgba(16, 185, 129, 0.3); font-weight: 700;">VIABLE</span>';
              } else if (venuesCount < 2) {
                statusBadge = '<span class="badge" style="background: rgba(148, 163, 184, 0.15); color: #94a3b8; border: 1px solid rgba(148, 163, 184, 0.3);">1 DEX ONLY</span>';
              } else if (netLpSpread > 0) {
                statusBadge = `<span class="badge" style="background: rgba(245, 158, 11, 0.15); color: #f59e0b; border: 1px solid rgba(245, 158, 11, 0.3);" title="Positive spread after LP fees (${netLpSign}${netLpSpread.toFixed(2)}%), needs >=${reqSpread.toFixed(2)}% to clear batcher + pool slippage">SUB-HURDLE (&ge;${reqSpread.toFixed(1)}%)</span>`;
              }

              const buyBatchAge = (o.buy_batch_age_h !== undefined && o.buy_batch_age_h !== null) ? `${(Number(o.buy_batch_age_h) * 60).toFixed(0)}m ago` : 'live';
              const sellBatchAge = (o.sell_batch_age_h !== undefined && o.sell_batch_age_h !== null) ? `${(Number(o.sell_batch_age_h) * 60).toFixed(0)}m ago` : 'live';
              const quarantined = o.quarantined_venues || [];
              const qBadge = quarantined.length > 0
                ? `<div style="font-size: 9px; color: #f59e0b; font-family: var(--font-mono);" title="Quarantined stale batchers: ${escapeHtml(quarantined.map(q => q.protocol + ' (' + q.last_batch_age_h + 'h)').join(', '))}">&#x1f6e1; ${quarantined.length} stale filtered</div>`
                : '';

              return `
                <tr>
                  <td>
                    <strong style="color: var(--text-main);">${escapeHtml(o.asset)}/ADA</strong>
                    <div style="font-size: 9px; color: var(--text-dim); font-family: var(--font-mono);">${venuesCount} DEX${venuesCount > 1 ? 'es' : ''} | R<sub>eff</sub> ${(effRes / 1000).toFixed(1)}k A</div>
                    ${qBadge}
                  </td>
                  <td>
                    <span style="color: #60a5fa; font-weight: 600;">${escapeHtml(o.buy_dex)}</span>
                    <div style="font-size: 9px; color: var(--text-dim); font-family: var(--font-mono);">batched ${buyBatchAge}</div>
                  </td>
                  <td>
                    <span style="color: #a855f7; font-weight: 600;">${escapeHtml(o.sell_dex)}</span>
                    <div style="font-size: 9px; color: var(--text-dim); font-family: var(--font-mono);">batched ${sellBatchAge}</div>
                  </td>
                  <td style="font-family: var(--font-mono);">
                    <span style="color: ${spreadColor}; font-weight: 700;">${spreadSign}${spread.toFixed(2)}%</span>
                    <div style="font-size: 9px; color: var(--text-dim);">Net-LP: ${netLpSign}${netLpSpread.toFixed(2)}%${peak24h}</div>
                  </td>
                  <td style="font-family: var(--font-mono);">${orderSizeCell}</td>
                  <td style="font-family: var(--font-mono); color: var(--text-dim);">${(o.total_fee_ada || 4.36).toFixed(2)} ADA</td>
                  <td style="color: ${netColor}; font-weight: 700; font-family: var(--font-mono);">
                    <div>${maxNetSign}${maxNet.toFixed(2)} ADA <span style="font-size: 9px; font-weight: 400; color: var(--text-dim);">@opt</span></div>
                    <div style="font-size: 9px; font-weight: 400; color: var(--text-dim);">${netSign}${netProfit.toFixed(2)} A @${(o.capital_req_ada || 180).toFixed(0)}A</div>
                  </td>
                  <td>${statusBadge}</td>
                  <td style="white-space: nowrap;">
                    <button type="button" class="tactile-btn" style="padding: 2px 6px; font-size: 9px;" onclick="window.runCardanoPairGraph('${escapeHtml(o.asset)}', 'dry-run')" title="Simulate Plutus execution for this pair (Zero risk)">SIMULATE</button>
                    <button type="button" class="tactile-btn accent" style="padding: 2px 6px; font-size: 9px; margin-left: 4px;" onclick="window.runCardanoPairGraph('${escapeHtml(o.asset)}', 'execute')" title="Execute live 2-leg arbitrage on Cardano Mainnet">LIVE SWAP</button>
                  </td>
                </tr>
              `;
            }).join('');
          }
        }
      }
    } catch (e) {
      console.warn('Failed to load Cardano spreads:', e);
      if (tableBody) {
        tableBody.innerHTML = `<tr><td colspan="9" style="text-align: center; color: #ef4444; padding: 10px;">Failed to scan spreads: ${escapeHtml(e.message)}</td></tr>`;
      }
    } finally {
      if (refreshBtn) {
        refreshBtn.disabled = false;
        refreshBtn.textContent = 'REFRESH SPREADS';
      }
      loadCardanoArbitrageHistory();
      loadCardanoMakerData();
    }
  }

  async function loadCardanoMakerData() {
    const tableBody = document.getElementById('cardanoMakerTableBody');
    const refreshBtn = document.getElementById('btnRefreshMakerCorridors');
    const capInput = document.getElementById('inputMakerCapital');
    const horizonInput = document.getElementById('selMakerHorizon');
    const assetSelect = document.getElementById('selMakerAsset');
    const capital = capInput ? capInput.value : '120';
    const horizon = horizonInput ? horizonInput.value : 'auto';
    const assetFilter = assetSelect ? assetSelect.value.trim().toUpperCase() : '';
    if (!tableBody) return;
    if (refreshBtn) {
      refreshBtn.disabled = true;
      refreshBtn.textContent = 'SCANNING...';
    }
    try {
      const resp = await fetch(`/api/finance/maker/corridors?capital=${encodeURIComponent(capital)}&horizon=${encodeURIComponent(horizon)}`);
      const lastPolledEl = document.getElementById('makerCorridorsLastPolled');
      if (lastPolledEl) {
        lastPolledEl.textContent = `[${new Date().toLocaleTimeString()}]`;
      }
      if (resp.ok) {
        const data = await resp.json();
        let corridors = data.corridors || [];
        if (assetFilter) {
          corridors = corridors.filter(c => (c.asset || '').toUpperCase() === assetFilter);
        }
        if (corridors.length === 0) {
          tableBody.innerHTML = '<tr><td colspan="10" style="text-align: center; color: var(--text-dim); padding: 8px;">No resting corridors calculated for selected asset filter.</td></tr>';
          return;
        }
        const fmtPrice = (p) => {
          if (p === undefined || p === null) return '—';
          if (p < 0.0001) return p.toExponential(4);
          if (p < 1.0) return p.toFixed(6);
          return p.toFixed(4);
        };
        tableBody.innerHTML = corridors.map(c => {
          const spreadColor = c.is_profitable ? '#10b981' : '#f59e0b';
          const netColor = c.is_profitable ? '#10b981' : '#f59e0b';
          const netSign = c.net_maker_profit_ada >= 0 ? '+' : '';
          const horStr = (c.horizon || 'auto').toUpperCase();
          const fillHours = c.est_fill_duration_hours !== undefined ? `~${c.est_fill_duration_hours}h` : '';
          const sigmaStr = c.horizon_sigma_pct !== undefined ? ` (±${c.horizon_sigma_pct}%)` : '';
          const frictionStr = c.friction_ada ? `${c.friction_ada.toFixed(2)} ADA friction` : '';
          const assetDisplay = c.asset === 'USDCX' ? 'USDCx' : escapeHtml(c.asset);

          let statusBadge = '';
          if (c.status && c.status.includes('INVENTORY_HOLD')) {
            statusBadge = '<span class="badge" style="background: rgba(56, 189, 248, 0.15); color: #38bdf8; border: 1px solid rgba(56, 189, 248, 0.3); font-weight: 700;">INVENTORY HOLD</span>';
          } else if (c.status && c.status.includes('SLIDE')) {
            statusBadge = '<span class="badge" style="background: rgba(239, 68, 68, 0.15); color: #ef4444; border: 1px solid rgba(239, 68, 68, 0.3); font-weight: 700;">SLIDE PAUSED</span>';
          } else if (c.is_profitable) {
            statusBadge = `<span class="badge" style="background: rgba(16, 185, 129, 0.15); color: #10b981; border: 1px solid rgba(16, 185, 129, 0.3); font-weight: 700;">VIABLE (${horStr})</span>`;
          } else {
            const needCap = c.min_capital_needed_ada || Math.round(c.capital_allocation_ada * 1.5);
            const recH = (c.recommended_horizon || '4h').toUpperCase();
            statusBadge = `<span class="badge" style="background: rgba(245, 158, 11, 0.15); color: #f59e0b; border: 1px solid rgba(245, 158, 11, 0.3);" title="Sub-capital for ${horStr} horizon. Requires ~${needCap} ADA or switch horizon to ${recH}.">EXPAND (${horStr})</span>`;
          }

          return `
            <tr>
              <td><strong style="color: var(--text-main);">${assetDisplay}/ADA</strong></td>
              <td style="font-family: var(--font-mono); color: var(--text-dim);">${fmtPrice(c.spot_price_ada)}</td>
              <td style="font-family: var(--font-mono); color: #38bdf8; font-weight: 600;">${fmtPrice(c.bid_target_ada)} ADA</td>
              <td style="font-family: var(--font-mono); color: #a855f7; font-weight: 600;">${fmtPrice(c.ask_target_ada)} ADA</td>
              <td style="color: ${spreadColor}; font-weight: 700; font-family: var(--font-mono);">+${c.maker_spread_pct.toFixed(2)}%<span style="font-size: 9px; color: var(--text-dim); font-weight: 400;">${sigmaStr}</span></td>
              <td style="font-size: 10px; font-family: var(--font-mono); color: var(--accent-cyan);"><span style="font-weight: 600;">${horStr}</span> <span style="color: var(--text-dim);">${fillHours}</span></td>
              <td style="font-family: var(--font-mono); color: var(--text-dim);">${c.capital_allocation_ada.toFixed(1)} ADA</td>
              <td style="color: ${netColor}; font-weight: 700; font-family: var(--font-mono);" title="${escapeHtml(frictionStr)}">${netSign}${c.net_maker_profit_ada.toFixed(3)} ADA</td>
              <td style="font-size: 10px;" title="${escapeHtml(c.tactical_rationale)}">${statusBadge}</td>
              <td style="white-space: nowrap;">
                <button type="button" class="tactile-btn" style="padding: 2px 6px; font-size: 9px;" onclick="window.runMakerPairGraph('${escapeHtml(c.asset)}', 'dry-run', event)" title="Simulate direct resting limit order">SIMULATE</button>
                <button type="button" class="tactile-btn accent" style="padding: 2px 6px; font-size: 9px; margin-left: 4px;" onclick="window.runMakerPairGraph('${escapeHtml(c.asset)}', 'execute', event)" title="Place resting limit order directly on Cardano Mainnet">DEPLOY</button>
              </td>
            </tr>
          `;
        }).join('');
      }
    } catch (e) {
      console.warn('Failed to load Cardano maker corridors:', e);
      tableBody.innerHTML = `<tr><td colspan="10" style="text-align: center; color: #ef4444; padding: 8px;">Failed to load maker corridors: ${escapeHtml(e.message)}</td></tr>`;
    } finally {
      if (refreshBtn) {
        refreshBtn.disabled = false;
        refreshBtn.textContent = 'REFRESH CORRIDORS';
      }
      loadCardanoMakerCycles();
      loadCardanoMakerOrders();
      loadCardanoStopTriggers();
    }
  }

  async function loadCardanoMakerOrders() {
    const wrap = document.getElementById('cardanoMakerOrdersWrap');
    const tableBody = document.getElementById('cardanoMakerOrdersTableBody');
    const countEl = document.getElementById('cardanoMakerOrdersCount');
    const btn = document.getElementById('btnRefreshMakerOrders');
    if (wrap) wrap.style.display = 'block';
    if (!tableBody) return;
    if (btn) {
      btn.disabled = true;
      btn.textContent = 'QUERYING...';
    }

    try {
      const resp = await fetch('/api/finance/maker/orders');
      if (resp.ok) {
        const data = await resp.json();
        const orders = data.orders || [];
        if (countEl) countEl.textContent = `${orders.length} Orders Active`;
        if (orders.length === 0) {
          tableBody.innerHTML = '<tr><td colspan="7" style="text-align: center; color: var(--text-dim); padding: 8px;">No active resting orders found on-chain. Hot wallet is 100% liquid.</td></tr>';
          return;
        }

        tableBody.innerHTML = orders.map(o => {
          const txIn = o.tx_in || o.order_id || 'unknown';
          const shortTx = txIn.length > 20 ? `${txIn.slice(0, 10)}...${txIn.slice(-8)}` : txIn;
          const isSell = (o.direction || '').toUpperCase() === 'SELL';
          const lockedCapStr = o.locked_capital_display || (isSell && o.expected_tokens ? 
            `${o.locked_ada || 4} ADA + ${typeof o.expected_tokens === 'number' ? o.expected_tokens.toLocaleString(undefined, {maximumFractionDigits: 2}) : o.expected_tokens} ${escapeHtml(o.asset || '')}` : 
            `${o.locked_ada || 0} ADA`);
          const targetReceiveStr = o.target_receive_display || (isSell && o.sell_target_ada ? 
            `${Number(o.sell_target_ada).toFixed(2)} ADA (${o.target_price_ada ? Number(o.target_price_ada).toFixed(6) : ''} ADA/${escapeHtml(o.asset || '')})` : 
            (o.expected_tokens !== undefined ? 
              `${typeof o.expected_tokens === 'number' ? o.expected_tokens.toLocaleString(undefined, {maximumFractionDigits: 4}) : o.expected_tokens} ${escapeHtml(o.asset || '')}` :
              (o.expected_receive || 'N/A')));
          const scriptVenueStr = o.protocol || (o.order_script ? (o.order_script.slice(0, 14) + '...') : 'MinswapV2');
          return `
            <tr>
              <td style="font-family: var(--font-mono); color: var(--accent-cyan); font-weight: 600;" title="${escapeHtml(txIn)}">${escapeHtml(shortTx)}</td>
              <td><strong>${escapeHtml(o.asset || 'SNEK')}</strong> <span style="font-size: 8px; color: ${isSell ? '#f59e0b' : '#10b981'}; font-weight: bold;">[${isSell ? 'SELL' : 'BUY'}]</span></td>
              <td style="font-family: var(--font-mono); font-size: 11px;">${lockedCapStr}</td>
              <td style="font-family: var(--font-mono); color: #10b981; font-weight: 600;">${targetReceiveStr}</td>
              <td style="font-family: var(--font-mono); color: var(--text-dim);" title="${escapeHtml(o.order_script || '')}">${escapeHtml(scriptVenueStr)}</td>
              <td><span class="badge" style="background: rgba(56, 189, 248, 0.15); color: #38bdf8; font-size: 8px;">RESTING ON-CHAIN</span></td>
              <td>
                <button type="button" class="tactile-btn danger" style="padding: 2px 6px; font-size: 9px;" onclick="cancelMakerOrder('${escapeHtml(o.order_id || '')}', '${escapeHtml(txIn)}')">CANCEL &amp; RECLAIM</button>
              </td>
            </tr>
          `;
        }).join('');
      }
    } catch (e) {
      console.warn('Failed to load resting orders:', e);
      if (tableBody) tableBody.innerHTML = `<tr><td colspan="7" style="text-align: center; color: #ef4444; padding: 6px;">Failed to query orders: ${escapeHtml(e.message)}</td></tr>`;
    } finally {
      if (btn) {
        btn.disabled = false;
        btn.textContent = 'RESTING ORDERS';
      }
    }
  }

  async function loadCardanoMakerCycles() {
    const tableBody = document.getElementById('cardanoMakerCyclesTableBody');
    const countEl = document.getElementById('cardanoMakerCyclesCount');
    const btn = document.getElementById('btnRefreshMakerCycles');
    if (!tableBody) return;
    if (btn) btn.disabled = true;

    try {
      const resp = await fetch('/api/finance/maker/active-cycles');
      if (resp.ok) {
        const data = await resp.json();
        const cycles = data.cycles || [];
        if (countEl) countEl.textContent = `${cycles.length} Active Cycles`;
        if (cycles.length === 0) {
          tableBody.innerHTML = '<tr><td colspan="8" style="text-align: center; color: var(--text-dim); padding: 8px;">No active cycles in maker_orders.db. Ready to place new resting bids.</td></tr>';
          return;
        }

        tableBody.innerHTML = cycles.map(c => {
          const ordId = c.order_id || 'unknown';
          const shortOrd = ordId.length > 20 ? `${ordId.slice(0, 12)}...${ordId.slice(-6)}` : ordId;
          let stageBadge = '';
          const hasPreloaded = c.preloaded_tokens && c.preloaded_tokens > 0;

          if (c.status === 'PENDING_BUY') {
            if (hasPreloaded) {
              stageBadge = `
                <span class="badge" style="background: rgba(255, 215, 0, 0.15); color: #fbbf24; font-size: 8px;">1. PENDING BUY</span>
                <div style="font-size: 8px; color: #38bdf8; font-weight: 700; margin-top: 2px;">+${Number(c.preloaded_tokens).toLocaleString()} ${escapeHtml(c.asset)} PRE-LOADED</div>
              `;
            } else {
              stageBadge = '<span class="badge" style="background: rgba(255, 215, 0, 0.15); color: #fbbf24; font-size: 8px;">1. PENDING BUY</span>';
            }
          } else if (c.status === 'INVENTORY_HOLD') {
            if (c.linked_active_order_id) {
              const shortLinked = c.linked_active_order_id.length > 12 ? c.linked_active_order_id.slice(-6) : c.linked_active_order_id;
              stageBadge = `
                <span class="badge" style="background: rgba(56, 189, 248, 0.15); color: #38bdf8; font-size: 8px;">2. INVENTORY HOLD</span>
                <div style="font-size: 8px; color: #a78bfa; margin-top: 2px;">↳ PRE-LOADED ➔ [${escapeHtml(shortLinked)}]</div>
              `;
            } else if (c.available_active_order_id) {
              stageBadge = `
                <span class="badge" style="background: rgba(56, 189, 248, 0.15); color: #38bdf8; font-size: 8px;">2. INVENTORY HOLD</span>
                <div style="font-size: 8px; color: #f59e0b; margin-top: 2px;">● UNLINKED ACCUMULATION</div>
              `;
            } else {
              stageBadge = '<span class="badge" style="background: rgba(56, 189, 248, 0.15); color: #38bdf8; font-size: 8px;">2. INVENTORY HOLD</span>';
            }
          } else if (c.status === 'PENDING_SELL') {
            stageBadge = '<span class="badge" style="background: rgba(168, 85, 247, 0.15); color: #c084fc; font-size: 8px;">3. PENDING SELL</span>';
          } else if (c.status === 'COMPLETED') {
            stageBadge = '<span class="badge" style="background: rgba(16, 185, 129, 0.15); color: #10b981; font-size: 8px;">4. COMPLETED</span>';
          } else if (c.status === 'CONSOLIDATED') {
            const shortMerged = c.merged_into ? (c.merged_into.length > 12 ? c.merged_into.slice(-6) : c.merged_into) : 'active rung';
            stageBadge = `
              <span class="badge" style="background: rgba(148, 163, 184, 0.15); color: #94a3b8; font-size: 8px;">CONSOLIDATED</span>
              <div style="font-size: 8px; color: #94a3b8; margin-top: 2px;">Merged into ${escapeHtml(shortMerged)}</div>
            `;
          } else if (c.status === 'CANCELLED') {
            stageBadge = '<span class="badge" style="background: rgba(239, 68, 68, 0.15); color: #ef4444; font-size: 8px;">CANCELLED / RECLAIMED</span>';
          } else {
            stageBadge = `<span class="badge" style="background: rgba(255, 255, 255, 0.1); color: var(--text-dim); font-size: 8px;">${escapeHtml(c.status)}</span>`;
          }

          let tokensCol = '';
          if (c.status === 'PENDING_BUY' && hasPreloaded) {
            tokensCol = `
              <td style="font-family: var(--font-mono);">
                ${c.capital_ada} ADA / ${Number(c.tokens_target).toLocaleString()} ${escapeHtml(c.asset)}
                <div style="font-size: 8px; color: #38bdf8; font-weight: 600;">Combined: ~${Number(c.combined_projected_tokens).toLocaleString()} ${escapeHtml(c.asset)}</div>
              </td>
            `;
          } else {
            tokensCol = `<td style="font-family: var(--font-mono);">${c.capital_ada} ADA / ${c.tokens_filled > 0 ? Number(c.tokens_filled).toLocaleString() : Number(c.tokens_target || 0).toLocaleString()} ${escapeHtml(c.asset)}</td>`;
          }

          let costCol = '';
          if (c.status === 'PENDING_BUY' && hasPreloaded) {
            costCol = `
              <td style="font-family: var(--font-mono);">
                ${c.cost_basis_ada > 0 ? c.cost_basis_ada.toFixed(2) + ' ADA' : 'Pending'}
                <div style="font-size: 8px; color: #a78bfa;">Combined Cost: ~${Number(c.combined_projected_cost_basis_ada).toFixed(2)} ADA</div>
              </td>
            `;
          } else {
            const costLabel = c.cost_basis_ada > 0
              ? c.cost_basis_ada.toFixed(2) + ' ADA'
              : (c.direction === 'SELL' ? 'Wallet Inv.' : (c.status === 'CANCELLED' ? '—' : 'Pending'));
            costCol = `<td style="font-family: var(--font-mono);">${costLabel}</td>`;
          }

          let askCol = '';
          if (c.status === 'PENDING_BUY' && hasPreloaded) {
            askCol = `
              <td style="font-family: var(--font-mono); color: #38bdf8;">
                Limit: ${c.target_price_ada > 0 ? Number(c.target_price_ada).toFixed(6) : 'N/A'}
                <div style="font-size: 8px; color: #10b981; font-weight: 700;">Proj. Ask: ${Number(c.combined_projected_ask_ada).toFixed(6)} ADA (BE: ${Number(c.combined_projected_breakeven_ada).toFixed(6)})</div>
              </td>
            `;
          } else if (c.status === 'INVENTORY_HOLD') {
            const standaloneBe = c.tokens_filled > 0 ? ((c.cost_basis_ada + 2.20) / c.tokens_filled).toFixed(6) : 'N/A';
            askCol = `
              <td style="font-family: var(--font-mono); color: #38bdf8;">
                ${c.sell_target_ada > 0 ? c.sell_target_ada.toFixed(2) + ' ADA' : (c.target_price_ada > 0 ? Number(c.target_price_ada).toFixed(6) : 'N/A')}
                <div style="font-size: 8px; color: #94a3b8;">Standalone BE: ${standaloneBe} ADA</div>
              </td>
            `;
          } else {
            askCol = `<td style="font-family: var(--font-mono); color: #38bdf8;">${c.sell_target_ada > 0 ? c.sell_target_ada.toFixed(2) + ' ADA' : (c.target_price_ada > 0 ? Number(c.target_price_ada).toFixed(6) : 'N/A')}</td>`;
          }

          let actionBtn = '';
          if (c.status === 'PENDING_BUY') {
            actionBtn = `
              <button type="button" class="tactile-btn" style="padding: 2px 5px; font-size: 8px; border-color: rgba(56, 189, 248, 0.4); margin-right: 3px;" onclick="simulateMakerFill('${escapeHtml(c.asset)}')">SIMULATE</button>
              <button type="button" class="tactile-btn danger" style="padding: 2px 5px; font-size: 8px;" onclick="cancelMakerOrder('${escapeHtml(c.order_id)}', '${escapeHtml(c.tx_id || '')}')">RECLAIM</button>
            `;
          } else if (c.status === 'INVENTORY_HOLD') {
            if (c.linked_active_order_id) {
              actionBtn = `
                <button type="button" class="tactile-btn" style="padding: 2px 5px; font-size: 8px; margin-right: 3px;" title="Unlink from active order" onclick="unlinkMakerInventory('${escapeHtml(c.linked_active_order_id)}')">UNLINK</button>
                <button type="button" class="tactile-btn accent" style="padding: 2px 6px; font-size: 8px; font-weight: 700;" title="Dispatch standalone sell leg immediately" onclick="dispatchMakerSellLeg('${escapeHtml(c.order_id)}', '${escapeHtml(c.asset)}', ${c.tokens_filled || 0}, ${c.cost_basis_ada || 0})">SELL NOW</button>
              `;
            } else if (c.available_active_order_id) {
              actionBtn = `
                <button type="button" class="tactile-btn accent" style="padding: 2px 5px; font-size: 8px; margin-right: 3px; font-weight: 700;" title="Pre-load into active limit buy order" onclick="linkMakerInventory('${escapeHtml(c.available_active_order_id)}', '${escapeHtml(c.order_id)}')">PRE-LOAD ➔</button>
                <button type="button" class="tactile-btn accent" style="padding: 2px 6px; font-size: 8px; font-weight: 700;" title="Dispatch standalone sell leg immediately" onclick="dispatchMakerSellLeg('${escapeHtml(c.order_id)}', '${escapeHtml(c.asset)}', ${c.tokens_filled || 0}, ${c.cost_basis_ada || 0})">SELL NOW</button>
              `;
            } else {
              actionBtn = `
                <button type="button" class="tactile-btn accent" style="padding: 2px 6px; font-size: 8px; font-weight: 700;" onclick="dispatchMakerSellLeg('${escapeHtml(c.order_id)}', '${escapeHtml(c.asset)}', ${c.tokens_filled || 0}, ${c.cost_basis_ada || 0})">DISPATCH SELL</button>
              `;
            }
          } else if (c.status === 'PENDING_SELL') {
            actionBtn = `
              <button type="button" class="tactile-btn danger" style="padding: 2px 6px; font-size: 8px;" onclick="cancelMakerOrder('${escapeHtml(c.order_id)}', '${escapeHtml(c.sell_tx_id || c.tx_id || '')}')">RECLAIM</button>
            `;
          } else {
            actionBtn = `<span style="font-size: 8px; color: var(--text-dim);">${c.status === 'CONSOLIDATED' ? 'MERGED' : 'SETTLED'}</span>`;
          }

          const hasRealized = c.realized_profit_ada !== 0 && c.realized_profit_ada != null;
          const settledExitAda = c.net_exit_ada || c.ada_received || c.sell_target_ada || c.capital_ada || 0;
          const profitColor = hasRealized
            ? (c.realized_profit_ada > 0 ? '#10b981' : '#ef4444')
            : (c.status === 'COMPLETED' ? '#10b981' : 'var(--text-dim)');
          const profitText = hasRealized
            ? `${c.realized_profit_ada > 0 ? '+' : ''}${c.realized_profit_ada.toFixed(3)} ADA`
            : (c.status === 'COMPLETED'
                ? (settledExitAda > 0 ? `${settledExitAda.toFixed(2)} ADA (Exit)` : 'Settled')
                : (c.status === 'CANCELLED' ? 'Reclaimed' : (c.status === 'CONSOLIDATED' ? 'Merged Rung' : 'Pending Cycle')));

          const feesVal = (c.batcher_fee_ada != null || c.l1_tx_fee_ada != null)
            ? `${((c.batcher_fee_ada || 0) + (c.l1_tx_fee_ada || 0)).toFixed(2)} ADA`
            : '—';
          const markoutVal = c.markout_6h_bps != null
            ? `<span style="color:${c.markout_6h_bps >= 0 ? '#10b981' : '#ef4444'}">${c.markout_6h_bps >= 0 ? '+' : ''}${c.markout_6h_bps.toFixed(1)} bps</span>`
            : (c.status === 'CANCELLED' ? '<span style="color:var(--text-dim)">—</span>' : '<span style="color:var(--text-dim)">measuring…</span>');

          return `
            <tr>
              <td style="font-family: var(--font-mono); color: var(--accent-cyan); font-weight: 600;" title="${escapeHtml(ordId)}">${escapeHtml(shortOrd)}</td>
              <td><strong>${escapeHtml(c.asset)}</strong></td>
              <td>${stageBadge}</td>
              ${tokensCol}
              ${costCol}
              ${askCol}
              <td style="font-family: var(--font-mono); color: #cbd5e1;">${feesVal}</td>
              <td style="font-family: var(--font-mono);">${markoutVal}</td>
              <td style="font-family: var(--font-mono); color: ${profitColor}; font-weight: 600;">${profitText}</td>
              <td>${actionBtn}</td>
            </tr>
          `;
        }).join('');
      }
    } catch (e) {
      console.warn('Failed to load maker cycles:', e);
      if (tableBody) tableBody.innerHTML = `<tr><td colspan="10" style="text-align: center; color: #ef4444; padding: 6px;">Failed to query cycles: ${escapeHtml(e.message)}</td></tr>`;
    } finally {
      if (btn) btn.disabled = false;
    }
  }

  async function loadSimMakerCycles() {
    const tableBody = document.getElementById('simMakerCyclesTableBody');
    const countEl = document.getElementById('simMakerCyclesCount');
    const btn = document.getElementById('btnRefreshSimCycles');
    if (!tableBody) return;
    if (btn) btn.disabled = true;

    try {
      const resp = await fetch('/api/finance/simulator/maker-cycles');
      if (resp.ok) {
        const data = await resp.json();
        const cycles = data.cycles || [];
        if (countEl) countEl.textContent = `${cycles.length} Simulated Cycles`;
        if (cycles.length === 0) {
          tableBody.innerHTML = '<tr><td colspan="7" style="text-align: center; color: var(--text-dim); padding: 8px;">No simulated cycles recorded in sim_maker_orders.db. Sandbox ledger is pristine.</td></tr>';
          return;
        }

        tableBody.innerHTML = cycles.map(c => {
          const ordId = c.order_id || 'unknown';
          const shortOrd = ordId.length > 20 ? `${ordId.slice(0, 12)}...${ordId.slice(-6)}` : ordId;
          const stageBadge = `<span class="badge" style="background: rgba(168, 85, 247, 0.15); color: #c084fc; font-size: 8px;">SIM: ${escapeHtml(c.status)}</span>`;
          const profitColor = (c.realized_profit_ada > 0) ? '#10b981' : (c.realized_profit_ada < 0 ? '#ef4444' : 'var(--text-dim)');
          const profitText = (c.realized_profit_ada !== 0) ? `${c.realized_profit_ada > 0 ? '+' : ''}${c.realized_profit_ada.toFixed(4)} ADA` : 'Simulated Fill';
          const txIn = c.tx_id || c.sell_tx_id || 'dry-run';
          const shortTx = txIn.length > 20 ? `${txIn.slice(0, 10)}...${txIn.slice(-8)}` : txIn;

          return `
            <tr>
              <td style="font-family: var(--font-mono); color: #c084fc; font-weight: 600;" title="${escapeHtml(ordId)}">${escapeHtml(shortOrd)}</td>
              <td><strong>${escapeHtml(c.asset)}</strong> <span style="font-size: 8px; color: #a855f7;">[PAPER]</span></td>
              <td>${stageBadge}</td>
              <td style="font-family: var(--font-mono);">${c.capital_ada} ADA / ${(c.tokens_filled || c.tokens_target || 0).toLocaleString()} ${escapeHtml(c.asset)}</td>
              <td style="font-family: var(--font-mono);">${c.cost_basis_ada > 0 ? c.cost_basis_ada.toFixed(2) + ' ADA' : 'Pending'}</td>
              <td style="font-family: var(--font-mono); color: ${profitColor}; font-weight: 600;">${profitText}</td>
              <td style="font-family: var(--font-mono); color: var(--text-dim); font-size: 9px;" title="${escapeHtml(txIn)}">${escapeHtml(shortTx)}</td>
            </tr>
          `;
        }).join('');
      }
    } catch (e) {
      console.warn('Failed to load simulated maker cycles:', e);
      if (tableBody) tableBody.innerHTML = `<tr><td colspan="7" style="text-align: center; color: #ef4444; padding: 6px;">Failed to query sim cycles: ${escapeHtml(e.message)}</td></tr>`;
    } finally {
      if (btn) btn.disabled = false;
    }
  }
  window.loadSimMakerCycles = loadSimMakerCycles;

  async function loadCardanoStopTriggers() {
    const tableBody = document.getElementById('cardanoStopTriggersTableBody');
    const countEl = document.getElementById('cardanoStopTriggersCount');
    const btn = document.getElementById('btnRefreshStopTriggers');
    if (!tableBody) return;
    if (btn) btn.disabled = true;

    try {
      const resp = await fetch('/api/finance/maker/stops');
      if (resp.ok) {
        const data = await resp.json();
        const triggers = data.triggers || [];
        const activeCount = triggers.filter(t => t.status === 'ARMED').length;
        if (countEl) countEl.textContent = `${activeCount} Armed (${triggers.length} Total)`;

        if (triggers.length === 0) {
          tableBody.innerHTML = '<tr><td colspan="10" style="text-align: center; color: var(--text-dim); padding: 8px;">No stop triggers registered in database.</td></tr>';
          return;
        }

        tableBody.innerHTML = triggers.map(t => {
          const tid = t.trigger_id || 'unknown';
          const shortTid = tid.length > 24 ? `${tid.slice(0, 14)}...${tid.slice(-6)}` : tid;
          let statusBadge = '';
          if (t.status === 'ARMED') {
            statusBadge = '<span class="badge" style="background: rgba(16, 185, 129, 0.15); color: #10b981; font-size: 8px; font-weight: 700;">ARMED</span>';
          } else if (t.status === 'CANCELLED') {
            statusBadge = '<span class="badge" style="background: rgba(239, 68, 68, 0.15); color: #ef4444; font-size: 8px;">CANCELLED</span>';
          } else if (t.status === 'TRIGGERED' || t.status === 'EXECUTED') {
            statusBadge = '<span class="badge" style="background: rgba(56, 189, 248, 0.15); color: #38bdf8; font-size: 8px;">EXECUTED</span>';
          } else {
            statusBadge = `<span class="badge" style="background: rgba(255, 255, 255, 0.1); color: var(--text-dim); font-size: 8px;">${escapeHtml(t.status)}</span>`;
          }

          let actionBtn = '';
          if (t.status === 'ARMED') {
            actionBtn = `<button type="button" class="tactile-btn danger" style="padding: 2px 6px; font-size: 8px;" onclick="cancelCardanoStopTrigger('${escapeHtml(tid)}')">DISARM</button>`;
          } else {
            actionBtn = `<span style="font-size: 8px; color: var(--text-dim);">INACTIVE</span>`;
          }

          let gateBadge = (t.gate_ada_24h_min <= -900.0)
            ? '<span style="color: #38bdf8;">BYPASS</span>'
            : (t.gate_ada_24h_min > 0 ? `+${t.gate_ada_24h_min}%` : `${t.gate_ada_24h_min}%`);

          let curSpot = 0.0;
          let distStr = '—';
          try {
            const sim = JSON.parse(t.dry_run_sim_json || '{}');
            curSpot = sim.simulated_execution_price_ada || 0.0;
            if (curSpot > 0 && t.trigger_price_ada > 0) {
              const dist = ((t.trigger_price_ada - curSpot) / curSpot) * 100.0;
              distStr = `${dist >= 0 ? '+' : ''}${dist.toFixed(2)}%`;
            }
          } catch (_) {}

          return `
            <tr>
              <td style="font-family: var(--font-mono); color: #c084fc; font-weight: 600;" title="${escapeHtml(tid)}">${escapeHtml(shortTid)}</td>
              <td><strong>${escapeHtml(t.asset)}</strong></td>
              <td><span style="font-family: var(--font-mono); font-size: 9px;">${escapeHtml(t.trigger_type)}</span></td>
              <td style="font-family: var(--font-mono);">${Number(t.trigger_price_ada).toFixed(6)} ADA</td>
              <td style="font-family: var(--font-mono);">${curSpot > 0 ? curSpot.toFixed(6) : '—'}</td>
              <td style="font-family: var(--font-mono); color: #fbbf24;">${distStr}</td>
              <td style="font-family: var(--font-mono);">${Number(t.capital_ada).toFixed(1)} ADA</td>
              <td>${statusBadge}</td>
              <td style="font-size: 9px; font-family: var(--font-mono);">${gateBadge}</td>
              <td>${actionBtn}</td>
            </tr>
          `;
        }).join('');
      }
    } catch (e) {
      console.warn('Failed to load stop triggers:', e);
      if (tableBody) tableBody.innerHTML = `<tr><td colspan="10" style="text-align: center; color: #ef4444; padding: 6px;">Failed to query stop triggers: ${escapeHtml(e.message)}</td></tr>`;
    } finally {
      if (btn) btn.disabled = false;
    }
  }

  window.cancelCardanoStopTrigger = async function(triggerId) {
    if (!confirm(`Cancel and disarm stop trigger:\n\n${triggerId}\n\nThis will prevent automated execution upon breakout.`)) return;
    try {
      const resp = await fetch('/api/finance/maker/stops/cancel', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ trigger_id: triggerId }),
      });
      if (resp.ok) {
        await loadCardanoStopTriggers();
      } else {
        alert('Failed to cancel stop trigger');
      }
    } catch (e) {
      alert('Error cancelling stop trigger: ' + e.message);
    }
  };

  window.pruneCardanoStopTriggers = async function(all = false) {
    const msg = all ? 'Cancel ALL active stop triggers?' : 'Prune stale/aborted stop triggers?';
    if (!confirm(msg)) return;
    try {
      const resp = await fetch('/api/finance/maker/stops/cancel', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ trigger_id: 'all', prune_all: true }),
      });
      if (resp.ok) {
        const res = await resp.json();
        alert(`Pruned ${res.pruned_count || 0} stop triggers!`);
        await loadCardanoStopTriggers();
      } else {
        alert('Failed to prune stop triggers');
      }
    } catch (e) {
      alert('Error pruning stop triggers: ' + e.message);
    }
  };

  async function reconcileCardanoMakerLedger() {
    const btn = document.getElementById('btnReconcileMakerLedger');
    if (btn) {
      btn.disabled = true;
      btn.textContent = 'RECONCILING...';
    }
    try {
      const resp = await fetch('/api/finance/maker/reconcile', { method: 'POST' });
      if (resp.ok) {
        const res = await resp.json();
        alert(`Disaster Recovery Reconciliation Complete!\nRecovered ${res.recovered_pending_orders || 0} active orders on DEX scripts.\nRecovered ${res.recovered_inventory_records || 0} wallet inventory holdings.`);
        await loadCardanoMakerCycles();
        await loadCardanoStopTriggers();
        await loadCardanoMakerData();
      } else {
        alert('Reconciliation failed. Check server logs.');
      }
    } catch (e) {
      alert('Error during reconciliation: ' + e.message);
    } finally {
      if (btn) {
        btn.disabled = false;
        btn.textContent = 'RECONCILE ON-CHAIN';
      }
    }
  }

  window.cancelMakerOrder = async function(orderId, txIn) {
    const targetLabel = txIn || orderId || 'Target Order';
    if (!confirm(`CONFIRM ORDER CANCELLATION & ON-CHAIN RECLAIM:\n\nTarget: ${targetLabel}\n\n• Constructs Plutus Cancel/Refund transaction (Redeemer Constr 0 [])\n• Signs with George's sovereign private key\n• Broadcasts to Cardano Mainnet\n• Reclaims 100% of locked tokens and refundable ADA deposits directly to hot wallet`)) {
      return;
    }
    try {
      const resp = await fetch('/api/finance/maker/cancel', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          order_id: orderId || null,
          tx_in: txIn || null,
          execute: true
        })
      });
      const data = await resp.json();
      if (resp.ok && data.status === 'success') {
        alert(`ORDER SUCCESSFULLY RECLAIMED!\n\nTx ID: ${data.cancel_tx_id}\nReclaimed ADA: ${data.reclaimed_ada} ADA\nReclaimed Assets: ${JSON.stringify(data.reclaimed_tokens)}\nL1 Tx Fee: ${data.tx_fee_ada} ADA\n\nFunds are safely restored to your hot wallet.`);
        await loadCardanoMakerOrders();
        await loadCardanoMakerCycles();
        await loadCardanoStopTriggers();
        await loadCardanoMakerData();
      } else {
        alert(`Order reclaim failed: ${data.message || JSON.stringify(data)}`);
      }
    } catch (e) {
      alert(`Error during order cancellation: ${e.message}`);
    }
  };

  window.dispatchMakerSellLeg = async function(orderId, asset, tokensFilled, costBasis) {
    if (!confirm(`DISPATCH RESTING MAKER SELL LEG:\n\nAsset: ${asset}\nInventory: ${tokensFilled.toLocaleString()} ${asset}\nCost Basis: ${costBasis.toFixed(2)} ADA\n\nThis calculates the algorithmic ask corridor (break-even + volatility premium) and places the resting sell limit order on MinswapV2.`)) {
      return;
    }
    try {
      const resp = await fetch('/api/finance/maker/run', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          mode: 'execute',
          asset: asset,
          direction: 'sell',
          tokens: tokensFilled,
          cost_basis: costBasis
        })
      });
      if (resp.ok) {
        alert(`Sell leg dispatched! Order watcher is now tracking resting ask fill.`);
        await loadCardanoMakerCycles();
        await loadCardanoMakerOrders();
      } else {
        const err = await resp.json();
        alert(`Sell leg dispatch failed: ${err.message || 'Check logs'}`);
      }
    } catch (e) {
      alert('Error dispatching sell leg: ' + e.message);
    }
  };

  window.linkMakerInventory = async function(activeOrderId, heldOrderId) {
    if (!confirm(`PRE-LOAD ACCUMULATED INVENTORY:\n\nActive Buy Rung: ${activeOrderId}\nHeld Inventory: ${heldOrderId || 'All held for this asset'}\n\nThis links the held tokens onto the resting limit order. When the resting limit fills, the held tokens will be added, cost basis averaged, and a single consolidated sell leg placed.`)) {
      return;
    }
    try {
      const resp = await fetch('/api/finance/maker/link-inventory', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ active_order_id: activeOrderId, held_order_id: heldOrderId || null })
      });
      const data = await resp.json();
      if (resp.ok && data.status === 'success') {
        alert(`INVENTORY SUCCESSFULLY PRE-LOADED!\n\nActive Order: ${data.active_order_id}\nPre-loaded: ${data.preloaded_tokens} ${data.asset}\nCombined Target: ${data.combined_tokens} ${data.asset}\nCombined Cost Basis: ${data.combined_cost_basis_ada} ADA\n\nWhen the active order fills, it will automatically combine and dispatch a single sell leg.`);
        await loadCardanoMakerCycles();
        await loadCardanoMakerOrders();
      } else {
        alert(`Failed to pre-load inventory: ${data.message || JSON.stringify(data)}`);
      }
    } catch (e) {
      alert(`Error linking inventory: ${e.message}`);
    }
  };

  window.unlinkMakerInventory = async function(activeOrderId) {
    if (!confirm(`UNLINK PRE-LOADED INVENTORY:\n\nRemove pre-loaded inventory association from active order ${activeOrderId}?\n\nThe held inventory will revert to standalone status.`)) {
      return;
    }
    try {
      const resp = await fetch('/api/finance/maker/unlink-inventory', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ active_order_id: activeOrderId })
      });
      const data = await resp.json();
      if (resp.ok && data.status === 'success') {
        alert(`Inventory successfully unlinked.`);
        await loadCardanoMakerCycles();
        await loadCardanoMakerOrders();
      } else {
        alert(`Failed to unlink inventory: ${data.message || JSON.stringify(data)}`);
      }
    } catch (e) {
      alert(`Error unlinking inventory: ${e.message}`);
    }
  };

  window.simulateMakerFill = async function(asset) {
    if (!confirm(`Simulate batcher fill for ${asset} on-chain?\n\nThis updates entry cost basis in SQLite and emits 'cardano/maker_filled' to trigger the automatic sell reactor.`)) return;
    try {
      const resp = await fetch('/api/finance/maker/simulate-fill', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ asset }),
      });
      if (resp.ok) {
        const res = await resp.json();
        alert(`Simulated fill executed!\nAsset: ${res.asset}\nCost Basis: ${res.cost_basis_ada} ADA\nTokens: ${res.tokens_filled}\nReactive Sell Leg Dispatched!`);
        await loadCardanoMakerCycles();
        await loadCardanoMakerData();
      }
    } catch (e) {
      alert('Failed to simulate fill: ' + e.message);
    }
  };

  async function runCardanoMakerGraph(mode, pair, capital, horizon) {
    const wrap = document.getElementById('cardanoMakerConsoleWrap');
    const consoleEl = document.getElementById('cardanoMakerConsole');
    const runBtn = document.getElementById('btnRunMakerGraph');
    const chosenHorizon = horizon || document.getElementById('selMakerHorizon')?.value || 'auto';

    if (wrap) wrap.style.display = 'block';
    if (consoleEl) {
      const ts = new Date().toLocaleTimeString();
      const modeDesc = (mode === 'execute') ? 'LIVE ON-CHAIN DEPLOYMENT (REAL ADA)' : 'DRY-RUN SIMULATION (PRE-FLIGHT)';
      consoleEl.textContent = `[${ts}] [MAKER_DISPATCH] Launching Sovereign Cardano Maker & Limit Graph (Path D)...\n` +
                              `[${ts}] Mode: ${modeDesc} | Target: ${pair || 'ALL AUTO-DISCOVERY'} | Capital: ${capital || 120} ADA | Horizon: ${chosenHorizon.toUpperCase()}\n` +
                              `[${ts}] Checking 10 ADA reserve floor, dynamic friction, slot freshness & direct Plutus datum assembly...\n\n`;
      consoleEl.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    }

    if (runBtn) {
      runBtn.disabled = true;
      runBtn.textContent = 'RUNNING GRAPH...';
    }

    try {
      const resp = await fetch('/api/finance/maker/run', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          mode: mode || 'dry-run',
          pair: pair || null,
          capital: parseFloat(capital) || 120.0,
          horizon: chosenHorizon,
        })
      });

      const res = await resp.json();
      if (consoleEl) {
        if (res.raw_output) {
          consoleEl.textContent += res.raw_output + '\n';
        } else if (res.status === 'success') {
          consoleEl.textContent += `[SUCCESS] GRAPH EXECUTION SUCCEEDED (Mode: ${res.mode.toUpperCase()})\n` +
                                   `• Phase 1 Capital: Spendable ${res.capital.spendable_ada} ADA | Reserve ${res.capital.reserve_floor_ada} ADA Floor Protected\n` +
                                   `• Phase 2 Corridors: Selected Target -> ${res.simulation.asset} (${res.simulation.direction.toUpperCase()})\n` +
                                   `• Phase 3 Risk: Slot Fresh | Pending Orders: ${res.risk.pending_orders_count}\n` +
                                   `• Phase 4 Plutus Sim: Tx ID -> ${res.simulation.tx_id}\n` +
                                   `  L1 Fee: ${res.simulation.tx_fee_ada} ADA | Aggregator Toll Saved: +${res.simulation.aggregator_fee_saved_ada} ADA\n` +
                                   `  Order Script: ${res.simulation.order_script}\n` +
                                   `• Phase 5 Settlement: ${res.settlement.message}\n`;
        } else {
          consoleEl.textContent += JSON.stringify(res, null, 2) + '\n';
        }
        if (res.stderr) {
          consoleEl.textContent += '\n' + res.stderr + '\n';
        }
        consoleEl.scrollTop = consoleEl.scrollHeight;
      }

      loadCardanoMakerOrders();
      loadCardanoMakerCycles();
      loadWalletsData();
    } catch (err) {
      if (consoleEl) {
        consoleEl.textContent += `\n[ERROR] Maker graph execution failed: ${err.message}\n`;
      }
    } finally {
      if (runBtn) {
        runBtn.disabled = false;
        runBtn.textContent = 'RUN MAKER GRAPH';
      }
    }
  }

  window.runMakerPairGraph = function(asset, mode, event) {
    const triggerBtn = event?.target || null;
    const oldText = triggerBtn ? triggerBtn.textContent : '';
    const capital = document.getElementById('inputMakerCapital')?.value || 120.0;
    const horizon = document.getElementById('selMakerHorizon')?.value || 'auto';

    if (mode === 'execute') {
      if (!confirm(`CONFIRM LIVE MAKER DEPLOYMENT:\n\nPlace live resting limit order for ${asset} with ${capital} ADA (${horizon.toUpperCase()} horizon) on Cardano Mainnet?\n\n• Zero aggregator toll (Direct AMM saves 0.85 ADA)\n• 2.0 ADA deposit refunded upon order fill/cancellation\n• Sunk cost: ~0.18 ADA L1 tx fee`)) {
        const wrap = document.getElementById('cardanoMakerConsoleWrap');
        const consoleEl = document.getElementById('cardanoMakerConsole');
        if (wrap && consoleEl) {
          wrap.style.display = 'block';
          consoleEl.textContent += `[${new Date().toLocaleTimeString()}] [CANCELLED] Deployment of ${asset} cancelled by operator.\n`;
        }
        return;
      }
    }

    if (triggerBtn) {
      triggerBtn.disabled = true;
      triggerBtn.textContent = (mode === 'execute') ? 'DEPLOYING...' : 'SIMULATING...';
    }

    runCardanoMakerGraph(mode, asset, capital, horizon).finally(() => {
      if (triggerBtn) {
        triggerBtn.disabled = false;
        triggerBtn.textContent = oldText;
      }
    });
  };

  async function runCardanoArbitrageGraph(mode, pair, forceSim) {
    const wrap = document.getElementById('cardanoGraphConsoleWrap');
    const consoleEl = document.getElementById('cardanoGraphConsole');
    const dryRunBtn = document.getElementById('btnRunCardanoGraphDryRun');
    const execBtn = document.getElementById('btnRunCardanoGraphExecute');

    if (wrap) wrap.style.display = 'block';
    if (consoleEl) {
      const ts = new Date().toLocaleTimeString();
      let modeDesc = 'DRY-RUN SIMULATION (SAFE)';
      if (mode === 'execute') modeDesc = 'LIVE MAINNET (CAPITAL AT RISK)';
      else if (mode === 'liquidate') modeDesc = 'LIQUIDATE UNHEDGED TOKENS';
      consoleEl.textContent = `[${ts}] [DISPATCH] Initiating Sovereign Cardano Arbitrage Graph...\n` +
                              `[${ts}] Mode: ${modeDesc} | Target Pair: ${pair || 'ALL AUTO'} | Bypass Hurdle Gate: ${forceSim ? 'YES' : 'NO'}\n` +
                              `[${ts}] Evaluating capital gate, AMM hygiene whitelist, cross-DEX depth & Plutus execution units...\n\n`;
      consoleEl.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    }

    // Highlight phases progressively
    const phasePills = [1, 2, 3, 4, 5].map(i => document.getElementById(`arbPhase${i}`));
    phasePills.forEach((p, idx) => {
      if (p) {
        p.style.borderColor = idx === 0 ? 'var(--accent-cyan)' : 'var(--border-color)';
        p.style.background = idx === 0 ? 'rgba(0, 240, 255, 0.08)' : 'var(--bg-base)';
      }
    });

    if (dryRunBtn) dryRunBtn.disabled = true;
    if (execBtn) execBtn.disabled = true;

    try {
      const resp = await fetch('/api/finance/arbitrage/run', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          mode: mode || 'dry-run',
          pair: pair || null,
          force_sim: !!forceSim
        })
      });

      const res = await resp.json();
      if (consoleEl) {
        if (res.raw_output) {
          consoleEl.textContent += res.raw_output + '\n';
        } else {
          consoleEl.textContent += JSON.stringify(res, null, 2) + '\n';
        }
        if (res.stderr) {
          consoleEl.textContent += '\n' + res.stderr + '\n';
        }
        consoleEl.scrollTop = consoleEl.scrollHeight;
      }

      // Mark all phases active on completion
      phasePills.forEach(p => {
        if (p) {
          p.style.borderColor = '#10b981';
          p.style.background = 'rgba(16, 185, 129, 0.08)';
        }
      });

      loadCardanoArbitrageHistory();
      loadWalletsData();
    } catch (err) {
      if (consoleEl) {
        consoleEl.textContent += `\n[ERROR] Graph execution failed: ${err.message}\n`;
      }
    } finally {
      if (dryRunBtn) dryRunBtn.disabled = false;
      if (execBtn) execBtn.disabled = false;
    }
  }

  async function loadCardanoArbitrageHistory() {
    const listEl = document.getElementById('cardanoArbHistoryList');
    if (!listEl) return;

    try {
      const resp = await fetch('/api/finance/arbitrage/history');
      if (resp.ok) {
        const data = await resp.json();
        const history = data.history || [];
        if (history.length === 0) {
          listEl.innerHTML = '<div style="color: var(--text-dim); padding: 4px;">No transactions recorded in trades.jsonl yet.</div>';
          return;
        }

        listEl.innerHTML = history.slice(0, 10).map(item => {
          const isDry = item.mode === 'dry-run';
          const modeBadge = isDry
            ? '<span class="badge" style="background: rgba(0, 240, 255, 0.15); color: var(--accent-cyan); font-size: 8px;">DRY-RUN</span>'
            : '<span class="badge" style="background: rgba(16, 185, 129, 0.15); color: #10b981; font-size: 8px;">LIVE BROADCAST</span>';
          const statusColor = item.status === 'success' ? '#10b981' : '#f59e0b';
          const shortTx = item.tx_id ? `${item.tx_id.slice(0, 12)}...${item.tx_id.slice(-6)}` : 'N/A';
          const cardanoScanUrl = item.tx_id && !item.tx_id.startsWith('sim_')
            ? `https://cardanoscan.io/transaction/${item.tx_id}`
            : '#';

          return `
            <div style="display: flex; justify-content: space-between; align-items: center; padding: 4px 8px; background: rgba(255, 255, 255, 0.02); border: 1px solid rgba(255, 255, 255, 0.05); border-radius: 3px;">
              <div style="display: flex; align-items: center; gap: 8px;">
                ${modeBadge}
                <strong style="color: var(--text-main);">${escapeHtml(item.asset || 'ADA')}</strong>
                <span style="color: var(--text-dim);">${item.input_ada || 0} ADA</span>
                <span style="color: ${statusColor}; font-weight: 600;">${item.status || 'unknown'}</span>
              </div>
              <div style="display: flex; align-items: center; gap: 10px;">
                <span style="color: var(--text-dim);">${item.timestamp ? item.timestamp.replace('T', ' ').replace('Z', '') : ''}</span>
                <a href="${cardanoScanUrl}" target="_blank" style="color: var(--accent-cyan); text-decoration: none;" title="${escapeHtml(item.tx_id || '')}">${shortTx}</a>
              </div>
            </div>
          `;
        }).join('');
      }
    } catch (_) {}
  }

  // --- Sovereign SDR Radio Lab ---
  function initSdrLab() {
    const btnEditSdr = document.getElementById('btnEditSdrConfigVim');
    if (btnEditSdr) {
      btnEditSdr.addEventListener('click', () => {
        if (window.openFile) window.openFile('.george/sdr_config.json');
      });
    }

    const btnEditSdrTmpl = document.getElementById('btnEditSdrTmplVim');
    if (btnEditSdrTmpl) {
      btnEditSdrTmpl.addEventListener('click', () => {
        if (window.openFile) window.openFile('config/sdr_config.json.template');
      });
    }

    const btnOpenSdrDossier = document.getElementById('btnOpenSdrDossierVim');
    if (btnOpenSdrDossier) {
      btnOpenSdrDossier.addEventListener('click', () => {
        if (window.openFile) window.openFile('dossiers/sdr_osint.md');
      });
    }

    const btnRefresh = document.getElementById('btnRefreshSdr');
    if (btnRefresh) {
      btnRefresh.addEventListener('click', () => loadSdrData());
    }

    const btnSync = document.getElementById('btnSyncSdrGateway');
    if (btnSync) {
      btnSync.addEventListener('click', async () => {
        btnSync.disabled = true;
        const origText = btnSync.textContent;
        btnSync.textContent = 'SYNCING...';
        try {
          const resp = await fetch('/api/sdr/sync', { method: 'POST' });
          const res = await resp.json();
          alert('Gateway Sync Status: ' + (res.status || 'OK'));
          loadSdrData();
        } catch (e) {
          alert('Sync error: ' + e);
        } finally {
          btnSync.disabled = false;
          btnSync.textContent = origText;
        }
      });
    }

    const btnIngest = document.getElementById('btnIngestSdrSpool');
    if (btnIngest) {
      btnIngest.addEventListener('click', async () => {
        btnIngest.disabled = true;
        try {
          await fetch('/api/sdr/ingest', { method: 'POST' });
          loadSdrData();
        } catch (e) {
          console.error('Ingest error:', e);
        } finally {
          btnIngest.disabled = false;
        }
      });
    }

    const btnRoutine = document.getElementById('btnSimulateSdrRoutine');
    if (btnRoutine) {
      btnRoutine.addEventListener('click', async () => {
        btnRoutine.disabled = true;
        try {
          await fetch('/api/sdr/simulate', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ emergency: false }),
          });
          loadSdrData();
        } catch (e) {
          console.error('Simulation error:', e);
        } finally {
          btnRoutine.disabled = false;
        }
      });
    }

    const btnEmerg = document.getElementById('btnSimulateSdrEmergency');
    if (btnEmerg) {
      btnEmerg.addEventListener('click', async () => {
        btnEmerg.disabled = true;
        try {
          await fetch('/api/sdr/simulate', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ emergency: true }),
          });
          loadSdrData();
        } catch (e) {
          console.error('Simulation error:', e);
        } finally {
          btnEmerg.disabled = false;
        }
      });
    }

    const btnSaveCfg = document.getElementById('btnSaveSdrConfig');
    if (btnSaveCfg) {
      btnSaveCfg.addEventListener('click', async () => {
        const gw = document.getElementById('sdrCfgGateway')?.value.trim();
        const host = document.getElementById('sdrCfgHost')?.value.trim();
        const path = document.getElementById('sdrCfgPath')?.value.trim();
        const kwRaw = document.getElementById('sdrCfgKeywords')?.value.trim();
        const kwList = kwRaw ? kwRaw.split(',').map(s => s.trim()).filter(Boolean) : [];

        const statusMsg = document.getElementById('sdrConfigStatusMsg');
        if (statusMsg) statusMsg.textContent = 'Saving...';

        try {
          const resp = await fetch('/api/sdr/config', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              remote_gateway: gw,
              remote_sdr_host: host,
              remote_recordings_path: path,
              emergency_keywords: kwList,
            }),
          });
          if (resp.ok) {
            if (statusMsg) {
              statusMsg.textContent = 'Configuration saved!';
              setTimeout(() => { statusMsg.textContent = ''; }, 3000);
            }
          }
        } catch (e) {
          if (statusMsg) statusMsg.textContent = 'Save failed: ' + e;
        }
      });
    }

    const btnReloadDossier = document.getElementById('btnReloadSdrDossier');
    if (btnReloadDossier) {
      btnReloadDossier.addEventListener('click', () => loadSdrDossier());
    }

    const btnTranscribe = document.getElementById('btnTranscribeSdrSpool');
    if (btnTranscribe) {
      btnTranscribe.addEventListener('click', async () => {
        btnTranscribe.disabled = true;
        const origText = btnTranscribe.textContent;
        btnTranscribe.textContent = 'TRANSCRIBING...';
        try {
          const resp = await fetch('/api/sdr/transcribe', { method: 'POST' });
          const res = await resp.json();
          alert(`Transcription completed: ${res.transcribed_count || 0} recording(s) processed.`);
          loadSdrData();
        } catch (e) {
          alert('Transcription error: ' + e);
        } finally {
          btnTranscribe.disabled = false;
          btnTranscribe.textContent = origText;
        }
      });
    }

    const btnProbeNode = document.getElementById('btnSdrNodeStatus');
    if (btnProbeNode) {
      btnProbeNode.addEventListener('click', async () => {
        btnProbeNode.disabled = true;
        try {
          await loadSdrNodeStatus(true);
        } finally {
          btnProbeNode.disabled = false;
        }
      });
    }

    // Live auto-refresh every 6s while SDR pane is visible
    if (!window._sdrAutoRefreshInterval) {
      window._sdrAutoRefreshInterval = setInterval(() => {
        const sdrPane = document.getElementById('pane-sdr');
        if (sdrPane && sdrPane.classList.contains('active') && !document.hidden) {
          loadSdrData(true);
        }
      }, 6000);
    }
  }

  async function loadSdrNodeStatus(showAlert = false) {
    try {
      const resp = await fetch('/api/sdr/node');
      if (!resp.ok) return;
      const data = await resp.json();
      const badge = document.getElementById('sdrNodeStatusText');
      const hwEl = document.getElementById('sdrNodeHardware');
      if (hwEl && data.hardware) hwEl.textContent = data.hardware;
      if (badge) {
        if (data.online) {
          badge.innerHTML = '<span class="badge" style="font-size: 8px; background: rgba(16, 185, 129, 0.2); color: #10b981; border: 1px solid #10b981;">ONLINE (VULKAN)</span>';
        } else {
          badge.innerHTML = '<span class="badge" style="font-size: 8px; background: rgba(245, 158, 11, 0.15); color: #f59e0b; border: 1px solid #f59e0b;">OFFLINE (FALLBACK)</span>';
        }
      }
      if (showAlert) {
        alert(`Hardware: ${data.hardware}\nStatus: ${data.status}\nEndpoint: ${data.endpoint}\nDetails: ${data.details}`);
      }
    } catch (_) {}
  }

  let _sdrLastData = null;
  let _sdrLastTableSig = '';

  function renderSdrFeedAndDirectory(data, isAutoPoll = false) {
    if (!data) return;
    const filterQ = (document.getElementById('sdrFilterInput')?.value || '').trim().toLowerCase();
    const tgFilterQ = (document.getElementById('sdrTalkgroupFilterInput')?.value || '').trim().toLowerCase();
    const hideUnintelligible = document.getElementById('sdrHideUnintelligibleToggle')?.checked ?? true;

    const statsBar = document.getElementById('sdrStatsSummaryBar');
    const st24 = data.stats_24h || {};
    const st3 = data.stats_3h || {};
    const cal = data.calibration || {};
    if (statsBar && st24.total_calls !== undefined) {
      const topTg = Array.isArray(st24.by_talkgroup) && st24.by_talkgroup.length > 0
        ? `${st24.by_talkgroup[0].talkgroup_tag} (${st24.by_talkgroup[0].call_count})`
        : 'N/A';
      const calHtml = cal.applied_error_hz !== undefined
        ? `<span><strong style="color:#10b981;">AUTO-CAL TUNER:</strong> ${Number(cal.center_mhz || 858.78).toFixed(4)} MHz · Offset +${cal.applied_error_hz} Hz · CC SNR +${cal.measured_snr_db || 0} dB · FrameSync r=${cal.peak_frame_sync_r || 0} (${cal.frame_sync_hits || 0} hits)</span>`
        : '';
      statsBar.innerHTML = `
        <span><strong style="color:var(--accent-cyan);">3H WINDOW:</strong> ${st3.total_calls || 0} calls (${st3.intelligible_calls || 0} clean, ${st3.unintelligible_calls || 0} bursts) · ${st3.active_unique_units || 0} units</span>
        <span><strong style="color:var(--text-gold);">24H DB TOTAL:</strong> ${st24.total_calls || 0} calls (${st24.intelligible_calls || 0} intelligible, ${st24.unintelligible_calls || 0} filtered) · ${st24.total_airtime_secs || 0}s airtime · ${st24.active_unique_units || 0} radio units · Top: ${topTg}</span>
        ${calHtml}
      `;
    }

    const body = document.getElementById('sdrTransmissionsBody');
    if (body && Array.isArray(data.recent_transmissions)) {
      // Avoid interrupting an actively playing <audio> clip during background auto-poll
      if (isAutoPoll) {
        const isPlayingAudio = Array.from(body.querySelectorAll('audio')).some(a => !a.paused && !a.ended);
        if (isPlayingAudio) return;
        const top3Sig = data.recent_transmissions
          .slice(0, 5)
          .map(r => `${r.call_id}:${(r.transcript || '').length}:${r.tactical_summary || ''}`)
          .join('|') + `|total=${data.archive_count}|f=${filterQ}|h=${hideUnintelligible}`;
        if (top3Sig === _sdrLastTableSig) return;
        _sdrLastTableSig = top3Sig;
      }

      const filtered = data.recent_transmissions.filter(r => {
        const isIntel = r.intelligible !== false && r.incident_type !== 'UNINTELLIGIBLE';
        if (hideUnintelligible && !isIntel) return false;
        if (!filterQ) return true;
        const blob = `${r.talkgroup} ${r.talkgroup_tag} ${r.talkgroup_description} ${r.talkgroup_group} ${r.freq} ${r.transcript || ''} ${r.raw_transcript || ''} ${r.tactical_summary || ''} ${r.incident_type || ''} ${r.rf_quality || ''}`.toLowerCase();
        return blob.includes(filterQ);
      });

      if (filtered.length === 0) {
        body.innerHTML = '<tr><td colspan="6" style="text-align: center; color: var(--text-dim);">No matching transmissions found (uncheck "Hide Unintelligible Bursts" to view raw carrier key-ups).</td></tr>';
      } else {
        body.innerHTML = filtered.map(r => {
          const isEmerg = r.emergency === 1 || r.emergency === true || r.priority === 'EMERGENCY';
          const isIntel = r.intelligible !== false && r.incident_type !== 'UNINTELLIGIBLE';
          const rfq = r.rf_quality || 'CLEAN_DECODE';
          let rfBadge = '<span class="badge" style="font-size: 8px; background: rgba(16, 185, 129, 0.18); color: #10b981; border: 1px solid rgba(16, 185, 129, 0.4);">CLEAN</span>';
          if (rfq === 'GARBLED_QPSK') {
            rfBadge = `<span class="badge" style="font-size: 8px; background: rgba(245, 158, 11, 0.18); color: #fbbf24; border: 1px solid rgba(245, 158, 11, 0.4);" title="${r.error_count || 0} bit errors, ${r.spike_count || 0} spikes">LOW SNR (${r.error_count || 0}e)</span>`;
          } else if (rfq === 'MARGINAL_SNR') {
            rfBadge = `<span class="badge" style="font-size: 8px; background: rgba(56, 189, 248, 0.18); color: #38bdf8; border: 1px solid rgba(56, 189, 248, 0.4);" title="${r.error_count || 0} bit errors, ${r.spike_count || 0} spikes">MARGINAL (${r.error_count || 0}e)</span>`;
          }
          const incLabel = (r.incident_type || r.category || 'P25').replace(/_/g, ' ');
          const priorityBadge = isEmerg
            ? `<span class="badge-red">[EMERGENCY · ${incLabel}]</span>`
            : (!isIntel
                ? '<span class="badge" style="font-size:8px; background:rgba(148,163,184,0.15); color:#94a3b8; border:1px solid rgba(148,163,184,0.3);">[UNINTELLIGIBLE]</span>'
                : `<span class="badge-blue">[${incLabel}]</span>`);
          const e4bBadge = String(r.transcription_node || '').includes('e4b')
            ? '<span class="badge" style="font-size: 7.5px; background: rgba(168, 85, 247, 0.18); color: #c084fc; border: 1px solid rgba(168, 85, 247, 0.4);">E4B AUDIO+META</span>'
            : '';
          const freqMhz = r.freq ? (r.freq > 10000 ? (r.freq / 1000000.0).toFixed(4) : Number(r.freq).toFixed(4)) : '--';
          const tsStr = r.start_time ? new Date(r.start_time * 1000).toISOString().replace('T', ' ').slice(0, 19) : '--';
          const dur = r.duration_secs !== undefined ? Number(r.duration_secs).toFixed(1) : (r.call_length || 0);
          const audioUrl = r.audio_url || (r.call_id ? `/api/sdr/audio/${encodeURIComponent(r.call_id)}` : '');
          const audioWidget = audioUrl
            ? `<div style="display:flex; flex-direction:column; gap:2px;">
                 <audio controls preload="none" src="${audioUrl}" style="height: 24px; width: 175px;"></audio>
                 <span style="font-size: 9px; color: var(--text-dim); font-family: var(--font-mono);">${dur}s · ${r.m4a_file || r.audio_file || 'audio'}</span>
               </div>`
            : `<span style="font-size: 10px; color: var(--text-muted);">${r.audio_file || 'capture.wav'} (${dur}s)</span>`;
          const uniqueUnits = Array.isArray(r.unit_ids) ? [...new Set(r.unit_ids)] : [];
          const unitsLine = uniqueUnits.length > 0
            ? `<div style="font-size: 9px; color: var(--accent-cyan); font-family: var(--font-mono);">${uniqueUnits.length} Unit(s): ${uniqueUnits.join(', ')}</div>`
            : '';

          const tacSummaryHtml = r.tactical_summary && isIntel
            ? `<div style="font-size: 10px; font-weight: 600; color: #38bdf8; margin-bottom: 3px;">⚡ ${r.tactical_summary}</div>`
            : '';
          const rawDiffers = r.raw_transcript && r.raw_transcript !== r.transcript;
          const rawWhisperHtml = rawDiffers
            ? `<details style="margin-top: 3px; font-size: 9px; color: var(--text-dim);">
                 <summary style="cursor: pointer; user-select: none;">Raw Whisper ASR Draft</summary>
                 <div style="padding: 2px 6px; margin-top: 2px; border-left: 2px solid rgba(148,163,184,0.3); font-family: var(--font-mono);">&ldquo;${r.raw_transcript}&rdquo;</div>
               </details>`
            : '';
          const locsHtml = Array.isArray(r.locations_mentioned) && r.locations_mentioned.length > 0
            ? `<div style="font-size: 9px; color: #fbbf24; margin-top: 2px;">📍 ${r.locations_mentioned.join(' · ')}</div>`
            : '';

          return `
            <tr>
              <td><div style="display:flex; flex-direction:column; gap:3px; align-items:flex-start;">${priorityBadge}${rfBadge}${e4bBadge}</div></td>
              <td style="font-family: var(--font-mono); font-size: 10px; color: var(--text-dim);">${tsStr}</td>
              <td style="color: var(--accent-cyan); font-family: var(--font-mono); font-weight: 600;">${freqMhz}<div style="font-size:8px; color:var(--text-dim);">${r.system || 'winne_p25'}</div></td>
              <td>
                <strong style="color: var(--text-gold);">${r.talkgroup_tag || 'TG-' + r.talkgroup}</strong>
                <span style="font-size: 9px; color: var(--accent-cyan); font-family: var(--font-mono);">[${r.talkgroup}]</span>
                <div style="font-size: 9px; color: var(--text-muted);">${r.talkgroup_description || ''} · <em>${r.talkgroup_group || ''}</em></div>
                ${unitsLine}
              </td>
              <td>${audioWidget}</td>
              <td style="color: var(--text-main); font-size: 10.5px; line-height: 1.4;">
                ${tacSummaryHtml}
                <div>&ldquo;${r.transcript || 'Pending transcription...'}&rdquo;</div>
                ${locsHtml}
                ${rawWhisperHtml}
              </td>
            </tr>
          `;
        }).join('');
      }
    }

    const freqRow = document.getElementById('sdrSiteFreqRow');
    if (freqRow && Array.isArray(data.site_frequencies)) {
      freqRow.innerHTML = data.site_frequencies.map(f => {
        const isCc = String(f.role).includes('PRIMARY');
        const bg = isCc ? 'rgba(239, 68, 68, 0.16)' : 'rgba(56, 189, 248, 0.12)';
        const col = isCc ? '#f87171' : '#38bdf8';
        return `<span class="badge" style="font-size: 9px; padding: 3px 7px; background: ${bg}; color: ${col}; border: 1px solid ${col}; font-family: var(--font-mono);" title="${f.channel_type}">${Number(f.freq_mhz).toFixed(4)} MHz · ${f.role}</span>`;
      }).join('');
    }

    const tgBody = document.getElementById('sdrTalkgroupsBody');
    if (tgBody && Array.isArray(data.talkgroups)) {
      const tgs = data.talkgroups.filter(t => {
        if (!tgFilterQ) return true;
        const b = `${t.tgid} ${t.hex} ${t.alpha_tag} ${t.description} ${t.tag} ${t.group}`.toLowerCase();
        return b.includes(tgFilterQ);
      });
      if (tgs.length === 0) {
        tgBody.innerHTML = '<tr><td colspan="7" style="text-align: center; color: var(--text-dim);">No talkgroups match filter.</td></tr>';
      } else {
        tgBody.innerHTML = tgs.map(t => `
          <tr>
            <td style="font-family: var(--font-mono); font-weight: 700; color: var(--accent-cyan);">${t.tgid}</td>
            <td style="font-family: var(--font-mono); color: var(--text-dim);">${t.hex}</td>
            <td style="font-weight: 700; color: var(--text-gold);">${t.alpha_tag}</td>
            <td>${t.description}</td>
            <td><span class="badge" style="font-size: 8px; background: rgba(168, 85, 247, 0.15); color: #c084fc; border: 1px solid rgba(168, 85, 247, 0.35);">${t.tag}</span></td>
            <td><span style="font-weight: 600;">${t.group}</span></td>
            <td style="font-family: var(--font-mono);">P${t.priority || 3}</td>
          </tr>
        `).join('');
      }
    }
  }

  const sdrFilterEl = document.getElementById('sdrFilterInput');
  if (sdrFilterEl) sdrFilterEl.addEventListener('input', () => renderSdrFeedAndDirectory(_sdrLastData, false));
  const sdrHideUnintelEl = document.getElementById('sdrHideUnintelligibleToggle');
  if (sdrHideUnintelEl) sdrHideUnintelEl.addEventListener('change', () => renderSdrFeedAndDirectory(_sdrLastData, false));
  const sdrTgFilterEl = document.getElementById('sdrTalkgroupFilterInput');
  if (sdrTgFilterEl) sdrTgFilterEl.addEventListener('input', () => renderSdrFeedAndDirectory(_sdrLastData, false));

  async function loadSdrData(isAutoPoll = false) {
    if (!isAutoPoll) loadSdrNodeStatus(false);
    try {
      const resp = await fetch('/api/sdr/status');
      if (!resp.ok) return;
      const data = await resp.json();
      _sdrLastData = data;
      const cfg = data.config || {};

      const gwEl = document.getElementById('sdrGatewayHost');
      if (gwEl) gwEl.textContent = cfg.remote_gateway || 'operator@sdr-gateway.local';

      const hostEl = document.getElementById('sdrHostName');
      const cal = data.calibration || {};
      if (hostEl) {
        const calSuffix = cal.applied_error_hz ? ` · ${Number(cal.center_mhz || 858.78).toFixed(2)} MHz (+${cal.applied_error_hz} Hz)` : '';
        hostEl.textContent = `Target: ${cfg.remote_sdr_host || 'sdr-server'}${calSuffix}`;
      }

      const spoolEl = document.getElementById('sdrSpoolCount');
      const tgCount = Array.isArray(data.talkgroups) ? data.talkgroups.length : 52;
      if (spoolEl) spoolEl.textContent = String(tgCount);
      const spoolSub = document.getElementById('sdrSpoolSub');
      if (spoolSub) spoolSub.textContent = `Mapped Departments (Spool Queue: ${data.spool_count || 0})`;

      const archEl = document.getElementById('sdrArchiveCount');
      const st24 = data.stats_24h || {};
      if (archEl) archEl.textContent = String(st24.total_calls || data.archive_count || 0);
      const dbStatsSub = document.getElementById('sdrDbStatsSub');
      if (dbStatsSub && st24.intelligible_calls !== undefined) {
        dbStatsSub.textContent = `${st24.intelligible_calls} Intelligible · ${st24.active_unique_units || 0} Active Units`;
      }

      const rdioBtn = document.getElementById('btnOpenRdioScanner');
      if (rdioBtn && cfg.rdio_scanner_url) rdioBtn.href = cfg.rdio_scanner_url;

      // Populate config form if fields are not focused
      const inGw = document.getElementById('sdrCfgGateway');
      if (inGw && !inGw.matches(':focus')) inGw.value = cfg.remote_gateway || '';

      const inHost = document.getElementById('sdrCfgHost');
      if (inHost && !inHost.matches(':focus')) inHost.value = cfg.remote_sdr_host || '';

      const inPath = document.getElementById('sdrCfgPath');
      if (inPath && !inPath.matches(':focus')) inPath.value = cfg.remote_recordings_path || '';

      const inKw = document.getElementById('sdrCfgKeywords');
      if (inKw && !inKw.matches(':focus') && Array.isArray(cfg.emergency_keywords)) {
        inKw.value = cfg.emergency_keywords.join(', ');
      }

      renderSdrFeedAndDirectory(data, isAutoPoll);
      if (!isAutoPoll) loadSdrDossier();
    } catch (e) {
      console.error('loadSdrData error:', e);
    }
  }

  async function loadSdrDossier() {
    const el = document.getElementById('sdrDossierContent');
    if (!el) return;
    try {
      const resp = await fetch('/api/sdr/dossier');
      if (resp.ok) {
        const data = await resp.json();
        el.textContent = data.content || 'No radio logs recorded yet.';
      }
    } catch (_) {}
  }

  // --- Keyless API Catalog & Trigger Builder ---
  function initApiTriggerBuilder() {
    const presetContainer = document.getElementById('apiTriggerPresets');
    if (presetContainer) {
      presetContainer.addEventListener('click', async (e) => {
        const chip = e.target.closest('[data-api-preset]');
        if (!chip) return;
        const presetKey = chip.getAttribute('data-api-preset');
        const statusMsg = document.getElementById('apiTriggerStatusMsg');
        if (statusMsg) statusMsg.textContent = `Deploying trigger recipe '${presetKey}'...`;

        try {
          const resp = await fetch('/api/react/api-build', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ preset: presetKey }),
          });
          const res = await resp.json();
          if (resp.ok) {
            if (statusMsg) {
              statusMsg.textContent = `Deployed autonomic trigger '${presetKey}' and registered reactor '${res.reactor_id || 'rx_' + presetKey}' on Event Bus!`;
              setTimeout(() => { statusMsg.textContent = ''; }, 5000);
            }
          } else {
            if (statusMsg) statusMsg.textContent = 'Build failed: ' + (res.message || 'Unknown error');
          }
        } catch (err) {
          if (statusMsg) statusMsg.textContent = 'Network error: ' + err;
        }
      });
    }

    const btnSearch = document.getElementById('btnApiSearchSubmit');
    const inputSearch = document.getElementById('apiSearchInput');
    if (btnSearch && inputSearch) {
      const doSearch = async () => {
        const q = inputSearch.value.trim();
        const resultsEl = document.getElementById('apiSearchResults');
        if (!resultsEl) return;
        resultsEl.innerHTML = '<div style="color: var(--text-dim); padding: 4px;">Searching public APIs database...</div>';

        try {
          const resp = await fetch(`/api/react/api-search?query=${encodeURIComponent(q)}`);
          if (resp.ok) {
            const list = await resp.json();
            if (!Array.isArray(list) || list.length === 0) {
              resultsEl.innerHTML = '<div style="color: var(--text-dim); padding: 4px;">No matching keyless APIs found.</div>';
              return;
            }
            resultsEl.innerHTML = list.map(item => `
              <div class="api-result-item">
                <div class="api-result-header">
                  <span class="api-result-title">${item.name} (${item.category})</span>
                  <span style="font-size: 9px; color: var(--accent-cyan);">${item.url}</span>
                </div>
                <div class="api-result-desc">${item.description}</div>
              </div>
            `).join('');
          }
        } catch (e) {
          resultsEl.innerHTML = `<div style="color: #ef4444; padding: 4px;">Search error: ${e}</div>`;
        }
      };

      btnSearch.addEventListener('click', doSearch);
      inputSearch.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') doSearch();
      });
    }
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Sovereign Research Studio & Tony Fadell Tactile Craftsman Console
  // ─────────────────────────────────────────────────────────────────────────────
  function initResearchStudio() {
    const pane = document.getElementById('pane-research');
    if (!pane) return;

    let currentDomain = 'academic';
    let currentStyle = 'empirical';
    let currentPasses = 4;
    let activeSlug = null;
    let allDossiers = [];
    let currentFilter = 'all';
    let brainstormHistory = [];

    const domainLabels = {
      'academic': 'AI / ML & SCIENCE',
      'engineering': 'SYSTEMS & SECURITY',
      'finance': 'FINANCE & MACRO',
      'gaming': 'GAMING & EMULATION',
      'general_sports_auto': 'SPORTS & AUTOMOTIVE',
      'auto_optimal': 'AUTO-OPTIMAL (RESONANCE)'
    };

    // 1. Tactile 5-Segment Domain Switchboard
    const domainReadout = document.getElementById('domainDialReadout');
    const stagedDomainTitle = document.getElementById('stagedDomainTitle');
    const segmentButtons = pane.querySelectorAll('.domain-segment-btn');

    async function setDomain(domain, skipServerSync = false) {
      currentDomain = domain;
      window.currentResearchDomain = domain;
      if (domainReadout) domainReadout.textContent = domainLabels[domain] || domain;
      if (stagedDomainTitle) stagedDomainTitle.textContent = domainLabels[domain] || domain;

      segmentButtons.forEach(btn => {
        if (btn.getAttribute('data-domain') === domain) {
          btn.classList.add('active');
        } else {
          btn.classList.remove('active');
        }
      });

      // Synchronize Topic Pool & VIM modal if active or ready
      if (typeof window.loadResearchConfig === 'function') {
        window.loadResearchConfig(domain);
      }

      // Sync active research mode to backend
      if (!skipServerSync) {
        try {
          await fetch('/api/research/mode/set', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ domain })
          });
        } catch (e) {
          console.warn('Failed to persist research mode:', e);
        }
      }
    }

    segmentButtons.forEach(btn => {
      btn.addEventListener('click', () => {
        const dom = btn.getAttribute('data-domain');
        if (dom) setDomain(dom);
      });
    });

    // Random Topic Pick from any theme pool
    const btnRandomPick = document.getElementById('btnRandomTopicPick');
    if (btnRandomPick) {
      btnRandomPick.addEventListener('click', async () => {
        btnRandomPick.disabled = true;
        const origText = btnRandomPick.innerHTML;
        btnRandomPick.innerHTML = '🎲 SAMPLING...';
        try {
          const res = await fetch('/api/research/topics/random?domain=all');
          if (!res.ok) throw new Error(`HTTP ${res.status}`);
          const data = await res.json();
          if (data && data.topic) {
            if (topicInput) topicInput.value = data.topic;
            if (data.domain) {
              setDomain(data.domain);
            }
            if (domainReadout) {
              const prev = domainReadout.textContent;
              domainReadout.textContent = `🎲 [PICKED: ${data.category || data.domain}]`;
              setTimeout(() => {
                domainReadout.textContent = domainLabels[data.domain] || prev;
              }, 4000);
            }
          }
        } catch (err) {
          console.warn('Failed to pick random topic:', err);
        } finally {
          btnRandomPick.disabled = false;
          btnRandomPick.innerHTML = origText;
        }
      });
    }

    // 2. Precision Style & Refinement Passes Controls
    const styleButtons = pane.querySelectorAll('#researchStyleBar .toggle-opt');
    styleButtons.forEach(btn => {
      btn.addEventListener('click', () => {
        styleButtons.forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        currentStyle = btn.getAttribute('data-style') || 'empirical';
      });
    });

    const passButtons = pane.querySelectorAll('#researchRefinePassesBar .toggle-opt');
    const refinementReadout = document.getElementById('refinementReadout');
    passButtons.forEach(btn => {
      btn.addEventListener('click', () => {
        passButtons.forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        currentPasses = parseInt(btn.getAttribute('data-passes') || '4', 10);
        if (refinementReadout) refinementReadout.textContent = `${currentPasses} PASS CEILING`;
      });
    });

    // 3. Launch Console Toggle
    const btnToggleLaunch = document.getElementById('btnToggleResearchLaunch');
    const launchConsole = document.getElementById('researchLaunchConsole');
    if (btnToggleLaunch && launchConsole) {
      btnToggleLaunch.addEventListener('click', () => {
        const isHidden = launchConsole.style.display === 'none';
        launchConsole.style.display = isHidden ? 'flex' : 'none';
        btnToggleLaunch.textContent = isHidden ? '▲ HIDE LAUNCH CONSOLE' : '+ NEW INQUIRY CONSOLE';
      });
    }

    // 4. Option 1 Directed Topic Draft
    const btnDraft = document.getElementById('btnDraftCandidates');
    const tray = document.getElementById('stagedCandidatesTray');
    const trayClose = document.getElementById('btnCloseCandidateTray');
    const cardsGrid = document.getElementById('candidateCardsGrid');
    const topicInput = document.getElementById('researchTopicInput');

    if (trayClose && tray) {
      trayClose.addEventListener('click', () => {
        tray.style.display = 'none';
      });
    }

    if (btnDraft && cardsGrid) {
      btnDraft.addEventListener('click', async () => {
        btnDraft.disabled = true;
        const origText = btnDraft.innerHTML;
        btnDraft.innerHTML = 'DRAFTING CANDIDATES...';
        cardsGrid.innerHTML = '<div style="padding: 20px; color: #94a3b8; font-family: var(--font-mono);">Contacting George Research Engine for candidate inquiries...</div>';
        if (tray) tray.style.display = 'block';

        try {
          const res = await fetch('/api/research/topics/draft', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              domain: currentDomain,
              style: currentStyle,
              seed: topicInput ? topicInput.value.trim() : ''
            })
          });
          const data = await res.json();
          const candidates = data.candidates || [];

          if (candidates.length === 0) {
            cardsGrid.innerHTML = '<div style="padding: 14px; color: #f87171;">No candidate inquiries returned.</div>';
          } else {
            cardsGrid.innerHTML = candidates.map(c => `
              <div class="candidate-card">
                <div class="candidate-header">
                  <span class="candidate-badge">${c.domain || currentDomain}</span>
                  <span class="candidate-complexity">${c.complexity || 'High'} Complexity</span>
                </div>
                <div class="candidate-title">${escapeHtml(sanitizeMath(c.title || ''))}</div>
                <div class="candidate-hypothesis"><strong>Angle:</strong> ${escapeHtml(sanitizeMath(c.angle || ''))}<br><br>${escapeHtml(sanitizeMath(c.hypothesis || ''))}</div>
                <div class="candidate-sources"><strong>Key Sources:</strong> ${escapeHtml(sanitizeMath(c.key_sources || 'Primary literature & specs'))}</div>
                <div class="candidate-actions">
                  <button type="button" class="tactile-btn accent candidate-launch-btn" data-topic="${escapeHtml(c.title)}" style="background: #10b981; color: #000; font-weight: 700;">
                    LAUNCH INQUIRY
                  </button>
                  <button type="button" class="tactile-btn candidate-add-pool-btn" data-topic="${escapeHtml(c.title)}" data-domain="${escapeHtml(c.domain || currentDomain)}" style="border-color: #10b981; color: #6ee7b7; font-weight: 600;">
                    + ADD TO POOL
                  </button>
                  <button type="button" class="tactile-btn candidate-probe-btn" data-topic="${escapeHtml(c.title)}" style="border-color: #38bdf8; color: #38bdf8;">
                    PROBE IN COPILOT
                  </button>
                </div>
              </div>
            `).join('');

            // Bind card buttons
            cardsGrid.querySelectorAll('.candidate-launch-btn').forEach(b => {
              b.addEventListener('click', (e) => {
                const top = e.currentTarget.getAttribute('data-topic');
                if (topicInput && top) topicInput.value = top;
                launchInquiry(top);
              });
            });

            cardsGrid.querySelectorAll('.candidate-add-pool-btn').forEach(b => {
              b.addEventListener('click', async (e) => {
                const btn = e.currentTarget;
                const top = btn.getAttribute('data-topic');
                const dom = btn.getAttribute('data-domain') || currentDomain;
                btn.disabled = true;
                btn.textContent = 'ADDING...';
                try {
                  const addRes = await fetch('/api/research/topics/add', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ domain: dom, topic: top })
                  });
                  if (addRes.ok) {
                    btn.textContent = '✓ ADDED';
                    btn.style.borderColor = '#10b981';
                    btn.style.color = '#10b981';
                    if (typeof window.loadResearchConfig === 'function') {
                      window.loadResearchConfig(dom);
                    }
                  } else {
                    btn.textContent = 'FAILED';
                  }
                } catch (e) {
                  btn.textContent = 'ERROR';
                }
              });
            });

            cardsGrid.querySelectorAll('.candidate-probe-btn').forEach(b => {
              b.addEventListener('click', (e) => {
                const top = e.currentTarget.getAttribute('data-topic');
                openBrainstormWithPrompt(`Let's investigate the hypothesis for: "${top}". What are the key mathematical bounds, empirical citations, or primary literature on this?`);
              });
            });
          }
        } catch (err) {
          cardsGrid.innerHTML = `<div style="padding: 14px; color: #f87171;">Error drafting topics: ${err}</div>`;
        } finally {
          btnDraft.disabled = false;
          btnDraft.innerHTML = origText;
        }
      });
    }

    // 5. Launch Inquiry Action
    const btnLaunch = document.getElementById('btnLaunchInquiry');
    async function launchInquiry(topicOverride) {
      const topic = (topicOverride || (topicInput ? topicInput.value : '')).trim();
      if (!topic) {
        alert('Please enter a research topic or select a candidate inquiry.');
        return;
      }

      const pubX = document.getElementById('chkPubX')?.checked ?? true;
      const pubMasto = document.getElementById('chkPubMasto')?.checked ?? true;
      const pubBsky = document.getElementById('chkPubBsky')?.checked ?? true;

      btnLaunch.disabled = true;
      const origText = btnLaunch.innerHTML;
      btnLaunch.innerHTML = 'QUEUING...';

      try {
        const res = await fetch('/api/research/start', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            topic: topic,
            domain: currentDomain,
            style: currentStyle,
            max_turns: 200,
            publish_social: false,
            publish_x: pubX,
            publish_mastodon: pubMasto,
            publish_bluesky: pubBsky
          })
        });
        const data = await res.json();
        alert(`Research inquiry queued on FIFO channel 'chan_research' (Priority 70):\n\nTopic: ${topic}\nDomain: ${currentDomain}\nStyle: ${currentStyle}`);
        if (tray) tray.style.display = 'none';
        loadDossiers();
      } catch (e) {
        alert(`Error queuing inquiry: ${e}`);
      } finally {
        btnLaunch.disabled = false;
        btnLaunch.innerHTML = origText;
      }
    }

    if (btnLaunch) {
      btnLaunch.addEventListener('click', () => launchInquiry());
    }

    // 6. Sovereign Library Master-Detail
    const dossierListEl = document.getElementById('researchDossierList');
    const searchInput = document.getElementById('searchDossiersInput');
    const btnRefresh = document.getElementById('btnRefreshDossiers');
    const countAllEl = document.getElementById('countAll');
    const countQuarantineEl = document.getElementById('countQuarantine');

    if (btnRefresh) btnRefresh.addEventListener('click', () => loadDossiers());
    if (searchInput) {
      searchInput.addEventListener('input', () => renderDossierList());
    }

    const filterChips = pane.querySelectorAll('.filter-chip');
    filterChips.forEach(chip => {
      chip.addEventListener('click', () => {
        filterChips.forEach(c => c.classList.remove('active'));
        chip.classList.add('active');
        currentFilter = chip.getAttribute('data-filter') || 'all';
        renderDossierList();
      });
    });

    async function loadDossiers() {
      if (!dossierListEl) return;
      dossierListEl.innerHTML = '<div style="padding: 12px; font-family: var(--font-mono); color: #94a3b8;">Scanning Sovereign Vault...</div>';

      try {
        const res = await fetch('/api/research/dossiers');
        const data = await res.json();
        allDossiers = data.dossiers || [];
        renderDossierList();
      } catch (err) {
        dossierListEl.innerHTML = `<div style="padding: 12px; color: #f87171;">Failed to load library: ${err}</div>`;
      }
    }

    function renderDossierList() {
      if (!dossierListEl) return;

      const q = searchInput ? searchInput.value.toLowerCase().trim() : '';
      let filtered = allDossiers;

      // Update count chips
      const countAcademic = allDossiers.filter(d => (d.domain === 'academic' || (d.category || '').toLowerCase().includes('ai')) && d.status !== 'quarantined').length;
      const countEngineering = allDossiers.filter(d => (d.domain === 'engineering' || (d.category || '').toLowerCase().includes('system')) && d.status !== 'quarantined').length;
      const countFinance = allDossiers.filter(d => (d.domain === 'finance' || (d.category || '').toLowerCase().includes('finance')) && d.status !== 'quarantined').length;
      const countGaming = allDossiers.filter(d => (d.domain === 'gaming' || (d.category || '').toLowerCase().includes('game')) && d.status !== 'quarantined').length;
      const countSports = allDossiers.filter(d => (d.domain === 'general_sports_auto' || (d.category || '').toLowerCase().includes('sport')) && d.status !== 'quarantined').length;

      const elAcad = document.getElementById('countAcademic');
      const elEng = document.getElementById('countEngineering');
      const elFin = document.getElementById('countFinance');
      const elGam = document.getElementById('countGaming');
      const elSpo = document.getElementById('countSports');
      if (elAcad) elAcad.textContent = countAcademic;
      if (elEng) elEng.textContent = countEngineering;
      if (elFin) elFin.textContent = countFinance;
      if (elGam) elGam.textContent = countGaming;
      if (elSpo) elSpo.textContent = countSports;

      if (currentFilter === 'quarantined') {
        filtered = filtered.filter(d => d.status === 'quarantined');
      } else if (currentFilter !== 'all') {
        filtered = filtered.filter(d => {
          if (d.status === 'quarantined') return false;
          if (d.domain === currentFilter) return true;
          const cat = (d.category || '').toLowerCase();
          if (currentFilter === 'academic') return cat.includes('ai') || cat.includes('science');
          if (currentFilter === 'engineering') return cat.includes('system') || cat.includes('security');
          if (currentFilter === 'finance') return cat.includes('finance') || cat.includes('macro');
          if (currentFilter === 'gaming') return cat.includes('gaming') || cat.includes('emulation');
          if (currentFilter === 'general_sports_auto') return cat.includes('sport') || cat.includes('auto');
          return false;
        });
      }

      if (q) {
        filtered = filtered.filter(d => d.title.toLowerCase().includes(q) || d.slug.toLowerCase().includes(q) || (d.category && d.category.toLowerCase().includes(q)));
      }

      if (countAllEl) countAllEl.textContent = allDossiers.length;
      if (countQuarantineEl) countQuarantineEl.textContent = allDossiers.filter(d => d.status === 'quarantined').length;

      if (filtered.length === 0) {
        dossierListEl.innerHTML = '<div style="padding: 14px; font-family: var(--font-mono); color: #64748b; font-size: 11px;">No matching monographs found.</div>';
        return;
      }

      dossierListEl.innerHTML = filtered.map(d => {
        const isQuarantined = d.status === 'quarantined';
        const isSelected = activeSlug === d.slug;
        const categoryLabel = d.category || domainLabels[d.domain] || d.domain;
        return `
          <div class="dossier-card ${isQuarantined ? 'quarantined' : ''} ${isSelected ? 'active' : ''}" data-slug="${escapeHtml(d.slug)}">
            <div class="dossier-card-header">
              <span class="status-pill ${isQuarantined ? 'quarantined' : ''}">${isQuarantined ? 'QUARANTINED' : 'VERIFIED'}</span>
              <span class="category-pill" style="font-size: 10px; font-weight: 700; color: #38bdf8; background: rgba(56, 189, 248, 0.12); padding: 1px 6px; border-radius: 3px; border: 1px solid rgba(56, 189, 248, 0.25);">${escapeHtml(categoryLabel)}</span>
            </div>
            <div class="dossier-card-title">${escapeHtml(sanitizeMath(d.title))}</div>
            <div class="dossier-card-meta">
              <span>${d.word_count.toLocaleString()} words · ${d.reading_time_min}m</span>
              <span>${d.date}</span>
            </div>
            ${isQuarantined && d.failure_reason ? `<div class="dossier-card-rejection"><span style="font-family: var(--font-mono); font-weight: 700; color: #ef4444;">[AUDIT REJECTION]</span> ${escapeHtml(sanitizeMath(d.failure_reason))}</div>` : ''}
          </div>
        `;
      }).join('');

      dossierListEl.querySelectorAll('.dossier-card').forEach(card => {
        card.addEventListener('click', () => {
          const slug = card.getAttribute('data-slug');
          if (slug) loadDossierDetail(slug);
        });
      });
    }

    // Detail Monograph Reader
    const emptyState = document.getElementById('detailEmptyState');
    const activeContent = document.getElementById('detailActiveContent');
    const dossierTitleEl = document.getElementById('dossierActiveTitle');
    const dossierSlugEl = document.getElementById('dossierActiveSlug');
    const dossierStatusPill = document.getElementById('dossierStatusPill');
    const dossierDomainPill = document.getElementById('dossierDomainPill');
    const dossierCategoryPill = document.getElementById('dossierCategoryPill');
    const dossierThemePill = document.getElementById('dossierThemePill');
    const dossierStatsPill = document.getElementById('dossierStatsPill');
    const btnSalvage = document.getElementById('btnSalvageActiveDossier');
    const btnPublish = document.getElementById('btnPublishActiveThread');
    const btnCopyMd = document.getElementById('btnCopyDossierMarkdown');

    const mdContentEl = document.getElementById('dossierMarkdownContent');
    const spContentEl = document.getElementById('dossierScratchpadContent');
    const threadContentEl = document.getElementById('dossierThreadContent');
    const revDropdown = document.getElementById('revisionSelectDropdown');
    const revPreview = document.getElementById('revisionPreviewContent');
    const btnLoadRev = document.getElementById('btnLoadRevision');

    const btnRefineSubmit = document.getElementById('btnSubmitRefinement');
    const refinerSteeringText = document.getElementById('refinerSteeringText');
    const refinerStatusMsg = document.getElementById('refinerStatusMsg');

    // Monograph Detail Tab Switching
    const monoTabBtns = pane.querySelectorAll('.mono-tab-btn');
    const monoTabPanes = {
      'monograph': document.getElementById('tabPaneMonograph'),
      'scratchpad': document.getElementById('tabPaneScratchpad'),
      'thread': document.getElementById('tabPaneThread'),
      'revisions': document.getElementById('tabPaneRevisions'),
      'refiner': document.getElementById('tabPaneRefiner')
    };

    monoTabBtns.forEach(btn => {
      btn.addEventListener('click', () => {
        monoTabBtns.forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        const targetTab = btn.getAttribute('data-tab');
        Object.keys(monoTabPanes).forEach(k => {
          if (monoTabPanes[k]) {
            if (k === targetTab) monoTabPanes[k].classList.add('active');
            else monoTabPanes[k].classList.remove('active');
          }
        });
      });
    });

    let currentDossierRaw = '';

    async function loadDossierDetail(slug) {
      activeSlug = slug;
      renderDossierList(); // Update selected card highlight

      try {
        const res = await fetch(`/api/research/dossier/${encodeURIComponent(slug)}`);
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const data = await res.json();

        if (emptyState) emptyState.style.display = 'none';
        if (activeContent) activeContent.style.display = 'flex';

        currentDossierRaw = data.dossier || '';
        if (dossierTitleEl) dossierTitleEl.textContent = sanitizeMath(data.title || slug);
        if (dossierSlugEl) dossierSlugEl.textContent = slug;
        if (dossierDomainPill) dossierDomainPill.textContent = data.domain || 'academic';

        if (dossierCategoryPill) {
          dossierCategoryPill.textContent = (data.category || domainLabels[data.domain] || data.domain || 'AI / ML Science').toUpperCase();
        }

        if (dossierThemePill) {
          if (data.theme) {
            dossierThemePill.textContent = data.theme;
            dossierThemePill.style.display = 'inline-block';
          } else {
            dossierThemePill.style.display = 'none';
          }
        }

        const isQuarantined = data.status === 'quarantined';
        if (dossierStatusPill) {
          dossierStatusPill.textContent = isQuarantined ? 'QUARANTINED' : 'VERIFIED';
          if (isQuarantined) dossierStatusPill.classList.add('quarantined');
          else dossierStatusPill.classList.remove('quarantined');
        }

        if (btnSalvage) {
          btnSalvage.style.display = isQuarantined ? 'inline-block' : 'none';
        }

        const words = (data.dossier || '').split(/\s+/).length;
        const readTime = Math.max(1, Math.round(words / 200));
        if (dossierStatsPill) dossierStatsPill.textContent = `${words.toLocaleString()} words · ${readTime} min read`;

        // Tab 1: Monograph render
        if (mdContentEl) {
          mdContentEl.innerHTML = renderMarkdown(data.dossier || '');
        }

        // Tab 2: Evidence Ledger
        if (spContentEl) {
          spContentEl.textContent = data.scratchpad || '(No scratchpad recorded)';
        }

        // Tab 3: Thread render
        if (threadContentEl) {
          renderSocialThread(data.thread, data.domain || 'academic', data.has_plate !== false);
        }

        // Tab 4: Revisions dropdown
        if (revDropdown) {
          const revs = data.revisions || [];
          if (revs.length === 0) {
            revDropdown.innerHTML = '<option value="">No past revisions</option>';
            if (revPreview) revPreview.innerHTML = '<em>No immutable revision snapshots exist for this monograph yet.</em>';
          } else {
            revDropdown.innerHTML = revs.map(r => `<option value="${escapeHtml(r)}">${escapeHtml(r)}</option>`).join('');
          }
        }

        // Reset refiner status
        if (refinerStatusMsg) refinerStatusMsg.textContent = '';

      } catch (err) {
        alert(`Failed to load dossier details for ${slug}: ${err}`);
      }
    }

    let currentThreadRaw = '';
    let currentThreadDomain = 'academic';
    let currentThreadHasPlate = true;
    let currentThreadViewMode = 'x_magazine';

    const domainHashtagsMap = {
      'finance': '#QuantFinance #MarketMicrostructure #Macro',
      'gaming': '#Emulation #SystemsEngineering #RetroComputing',
      'engineering': '#SystemsEngineering #DistributedSystems #OpenSource',
      'general_sports_auto': '#SportsAnalytics #Telemetry #Engineering',
      'academic': '#MachineLearning #ComputerScience #AIResearch'
    };

    function splitRawThreadPosts(threadText) {
      const cleaned = (threadText || '').trim();
      if (!cleaned) return [];
      if (cleaned.includes('---POST---')) {
        return cleaned.split(/---POST---/).map(p => p.trim()).filter(Boolean);
      }
      if (cleaned.includes('===POST===')) {
        return cleaned.split(/===POST===/).map(p => p.trim()).filter(Boolean);
      }
      return cleaned.split(/\n(?=[0-9]+\/[0-9]+|Post [0-9]+:)/).map(p => p.trim()).filter(Boolean);
    }

    function pairSplitMastoPost(postText, maxLen = 480) {
      const t = postText.trim();
      if (t.length <= maxLen) return [{ text: t, subLabel: '' }];
      const pars = t.split(/\n\n+/).map(p => p.trim()).filter(Boolean);
      if (pars.length >= 2 && t.length <= maxLen * 2) {
        let bestIdx = 1;
        let bestDiff = 999999;
        for (let i = 1; i < pars.length; i++) {
          const left = pars.slice(0, i).join('\n\n');
          const right = pars.slice(i).join('\n\n');
          if (left.length <= maxLen && right.length <= maxLen) {
            const diff = Math.abs(left.length - right.length);
            if (diff < bestDiff) {
              bestDiff = diff;
              bestIdx = i;
            }
          }
        }
        const left = pars.slice(0, bestIdx).join('\n\n');
        const right = pars.slice(bestIdx).join('\n\n');
        if (left.length <= maxLen && right.length <= maxLen) {
          return [{ text: left, subLabel: 'A' }, { text: right, subLabel: 'B' }];
        }
      }
      const sentences = t.split(/(?<=[.?!])\s+/).filter(Boolean);
      const chunks = [];
      let curr = '';
      for (const s of sentences) {
        if ((curr ? curr.length + 1 + s.length : s.length) <= maxLen) {
          curr = curr ? curr + ' ' + s : s;
        } else {
          if (curr) chunks.push(curr);
          curr = s.length <= maxLen ? s : s.slice(0, maxLen);
        }
      }
      if (curr) chunks.push(curr);
      return chunks.map((c, i) => ({
        text: c,
        subLabel: chunks.length > 1 ? String.fromCharCode(65 + i) : ''
      }));
    }

    function chunkBlueskyPosts(rawPosts, maxLen = 278) {
      const out = [];
      rawPosts.forEach((raw, pIdx) => {
        const cleaned = raw.replace(/^\[?[0-9]+\/[0-9]+\]?\s*/, '').trim();
        const pars = cleaned.split(/\n\n+/).map(p => p.trim()).filter(Boolean);
        pars.forEach(par => {
          if (par.length <= maxLen) {
            out.push({ text: par, sourcePost: pIdx + 1 });
          } else {
            const sentences = par.split(/(?<=[.?!])\s+/).filter(Boolean);
            let curr = '';
            sentences.forEach(s => {
              if ((curr ? curr.length + 1 + s.length : s.length) <= maxLen) {
                curr = curr ? curr + ' ' + s : s;
              } else {
                if (curr) out.push({ text: curr, sourcePost: pIdx + 1 });
                curr = s.length <= maxLen ? s : s.slice(0, maxLen);
              }
            });
            if (curr) out.push({ text: curr, sourcePost: pIdx + 1 });
          }
        });
      });
      return out;
    }

    function formatPostHtml(text) {
      let safe = escapeHtml(text);
      safe = safe.replace(/(https?:\/\/[^\s<)]+)/g, '<a href="$1" target="_blank" rel="noopener" style="color: #38bdf8; text-decoration: underline;">$1</a>');
      safe = safe.replace(/(^|\s)(#[A-Za-z][A-Za-z0-9_]*)/g, '$1<span style="color: #c084fc; font-weight: 600;">$2</span>');
      safe = safe.replace(/^▸ (.*)$/gm, '<div style="margin: 6px 0; padding: 6px 10px; background: rgba(56, 189, 248, 0.08); border-left: 3px solid #38bdf8; border-radius: 4px; font-family: var(--font-mono); font-size: 12px; color: #e2e8f0;">▸ $1</div>');
      return safe.replace(/\n/g, '<br>');
    }

    function renderSocialThread(threadText, domain = 'academic', hasPlate = true) {
      if (!threadContentEl) return;
      currentThreadRaw = threadText || '';
      currentThreadDomain = domain || 'academic';
      currentThreadHasPlate = hasPlate;

      const rawPosts = splitRawThreadPosts(currentThreadRaw);
      const plateUrl = `/api/research/dossier/${encodeURIComponent(activeSlug)}/plate?t=${Date.now()}`;

      let displayPosts = [];
      let platformBadge = '';
      let charCeiling = 2800;

      if (currentThreadViewMode === 'x_magazine') {
        charCeiling = 2800;
        platformBadge = 'X PREMIUM MAGAZINE VIEW (600–1,100c OPTIMAL / 2,800c MAX)';
        displayPosts = rawPosts.map((p, idx) => {
          const clean = p.replace(/^\[?[0-9]+\/[0-9]+\]?\s*/, '').trim();
          const footer = idx === 0 ? `🧵 1/${rawPosts.length}` : `${idx + 1}/${rawPosts.length}`;
          return {
            badge: `X POST #${idx + 1}`,
            subBadge: idx === 0 ? 'ROOT + MONOGRAPH PLATE' : `REPLY ${idx + 1}/${rawPosts.length}`,
            text: `${clean}\n\n${footer}`,
            attachPlate: idx === 0
          };
        });
      } else if (currentThreadViewMode === 'mastodon_paired') {
        charCeiling = 500;
        platformBadge = 'MASTODON PAIRED VIEW (BALANCED ≤480c SUB-POST PAIRING + HASHTAGS)';
        const paired = [];
        rawPosts.forEach((p, idx) => {
          const clean = p.replace(/^\[?[0-9]+\/[0-9]+\]?\s*/, '').trim();
          const splits = pairSplitMastoPost(clean, 480);
          splits.forEach(sp => {
            paired.push({
              origIdx: idx + 1,
              subLabel: sp.subLabel,
              text: sp.text
            });
          });
        });
        const tags = domainHashtagsMap[currentThreadDomain] || domainHashtagsMap['academic'];
        if (paired.length > 0 && tags) {
          const last = paired[paired.length - 1];
          if (last.text.length + tags.length + 2 <= 485) {
            last.text = `${last.text}\n\n${tags}`;
          }
        }
        displayPosts = paired.map((item, idx) => {
          const footer = idx === 0 ? `🧵 1/${paired.length}` : `${idx + 1}/${paired.length}`;
          const pairTag = item.subLabel ? `PAIRED ${item.origIdx}${item.subLabel}` : `UNIT #${item.origIdx}`;
          return {
            badge: `MASTODON ${idx + 1}/${paired.length}`,
            subBadge: idx === 0 ? `${pairTag} · +MONOGRAPH PLATE` : pairTag,
            text: `${item.text}\n\n${footer}`,
            attachPlate: idx === 0
          };
        });
      } else {
        charCeiling = 300;
        platformBadge = 'BLUESKY ATPROTO VIEW (≤295c + UTF-8 RICHTEXT FACETS)';
        const bskyChunks = chunkBlueskyPosts(rawPosts, 278);
        displayPosts = bskyChunks.map((item, idx) => {
          const footer = idx === 0 ? `🧵 1/${bskyChunks.length}` : `${idx + 1}/${bskyChunks.length}`;
          return {
            badge: `ATPROTO ${idx + 1}/${bskyChunks.length}`,
            subBadge: idx === 0 ? 'ROOT + BLOB IMAGE' : `FROM POST #${item.sourcePost}`,
            text: `${item.text}\n\n${footer}`,
            attachPlate: idx === 0
          };
        });
      }

      const controlsHtml = `
        <div style="display: flex; flex-direction: column; gap: 14px; margin-bottom: 16px;">
          <div style="display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 10px; padding: 10px 14px; background: rgba(15, 23, 42, 0.85); border: 1px solid rgba(56, 189, 248, 0.25); border-radius: 8px;">
            <div style="display: flex; align-items: center; gap: 8px; flex-wrap: wrap;">
              <span style="font-size: 11px; font-weight: 700; color: #94a3b8; font-family: var(--font-mono);">PLATFORM PREVIEW:</span>
              <button type="button" class="tactile-btn thread-mode-btn ${currentThreadViewMode === 'x_magazine' ? 'accent' : ''}" data-mode="x_magazine" style="${currentThreadViewMode === 'x_magazine' ? 'background: #38bdf8; color: #000; font-weight: 700;' : ''}">X MAGAZINE (${rawPosts.length})</button>
              <button type="button" class="tactile-btn thread-mode-btn ${currentThreadViewMode === 'mastodon_paired' ? 'accent' : ''}" data-mode="mastodon_paired" style="${currentThreadViewMode === 'mastodon_paired' ? 'background: #a855f7; color: #fff; font-weight: 700;' : ''}">MASTODON PAIRED</button>
              <button type="button" class="tactile-btn thread-mode-btn ${currentThreadViewMode === 'bluesky_300' ? 'accent' : ''}" data-mode="bluesky_300" style="${currentThreadViewMode === 'bluesky_300' ? 'background: #0ea5e9; color: #fff; font-weight: 700;' : ''}">BLUESKY ATPROTO</button>
            </div>
            <div style="display: flex; align-items: center; gap: 8px;">
              <button type="button" class="tactile-btn" id="btnResynthesizeThread" style="border-color: #f59e0b; color: #fbbf24; font-weight: 700; font-size: 11px;">↻ RE-SYNTHESIZE THREAD &amp; PLATE</button>
              <a href="${plateUrl}" target="_blank" rel="noopener" class="tactile-btn" style="border-color: #10b981; color: #34d399; font-weight: 700; font-size: 11px; text-decoration: none;">OPEN 16:9 PLATE ↗</a>
            </div>
          </div>

          <div style="background: rgba(9, 13, 22, 0.95); border: 1px solid rgba(255, 255, 255, 0.12); border-radius: 8px; padding: 12px;">
            <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; font-family: var(--font-mono); font-size: 11px;">
              <span style="color: #38bdf8; font-weight: 700;">◆ SOVEREIGN MONOGRAPH PLATE (1200×675 · ZERO LLM COST · ATTACHED TO POST #1)</span>
              <span style="color: #64748b;">${platformBadge}</span>
            </div>
            <img src="${plateUrl}" alt="Sovereign Research Monograph Plate" style="width: 100%; max-width: 760px; height: auto; border-radius: 6px; border: 1px solid rgba(56, 189, 248, 0.25); display: block; margin: 0 auto;" onerror="this.style.display='none'" />
          </div>
        </div>
      `;

      if (displayPosts.length === 0) {
        threadContentEl.innerHTML = controlsHtml + '<div style="padding: 16px; color: #94a3b8; font-family: var(--font-mono);">No syndicated social thread generated for this inquiry. Click RE-SYNTHESIZE THREAD &amp; PLATE above to build it.</div>';
      } else {
        const postsHtml = displayPosts.map(post => {
          const charCount = post.text.length;
          const overLimit = charCount > charCeiling;
          const countColor = overLimit ? '#f87171' : '#34d399';
          return `
            <div class="thread-post-card" style="margin-bottom: 12px; border: 1px solid rgba(148, 163, 184, 0.2); border-radius: 8px; background: rgba(15, 23, 42, 0.65); padding: 14px;">
              <div class="thread-post-header" style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px; border-bottom: 1px solid rgba(148, 163, 184, 0.12); padding-bottom: 6px;">
                <div style="display: flex; align-items: center; gap: 8px;">
                  <span class="post-num-badge" style="font-weight: 700; color: #38bdf8;">${escapeHtml(post.badge)}</span>
                  <span style="font-size: 10px; font-family: var(--font-mono); padding: 2px 6px; border-radius: 4px; background: rgba(56, 189, 248, 0.12); color: #94a3b8;">${escapeHtml(post.subBadge)}</span>
                </div>
                <span class="post-char-count" style="font-family: var(--font-mono); font-size: 11px; color: ${countColor}; font-weight: 700;">${charCount.toLocaleString()} / ${charCeiling.toLocaleString()} chars</span>
              </div>
              <div class="post-text-content" style="line-height: 1.65; font-size: 13.5px; color: #f1f5f9;">${formatPostHtml(post.text)}</div>
            </div>
          `;
        }).join('');
        threadContentEl.innerHTML = controlsHtml + postsHtml;
      }

      threadContentEl.querySelectorAll('.thread-mode-btn').forEach(btn => {
        btn.addEventListener('click', () => {
          currentThreadViewMode = btn.getAttribute('data-mode') || 'x_magazine';
          renderSocialThread(currentThreadRaw, currentThreadDomain, currentThreadHasPlate);
        });
      });

      const btnResynth = document.getElementById('btnResynthesizeThread');
      if (btnResynth) {
        btnResynth.addEventListener('click', async () => {
          if (!activeSlug) return;
          btnResynth.disabled = true;
          btnResynth.textContent = 'RE-SYNTHESIZING...';
          try {
            const res = await fetch(`/api/research/resynthesize-thread/${encodeURIComponent(activeSlug)}`, { method: 'POST' });
            const data = await res.json();
            if (data.thread) {
              renderSocialThread(data.thread, currentThreadDomain, true);
            } else {
              await loadDossierDetail(activeSlug);
            }
          } catch (e) {
            alert(`Failed to re-synthesize thread: ${e}`);
          } finally {
            btnResynth.disabled = false;
            btnResynth.textContent = '↻ RE-SYNTHESIZE THREAD & PLATE';
          }
        });
      }
    }

    // Revision Inspector
    if (btnLoadRev && revDropdown && revPreview) {
      btnLoadRev.addEventListener('click', async () => {
        const rev = revDropdown.value;
        if (!rev || !activeSlug) return;
        revPreview.innerHTML = '<em>Loading revision...</em>';
        try {
          const res = await fetch(`/api/research/dossier/${encodeURIComponent(activeSlug)}/revision/${encodeURIComponent(rev)}`);
          const data = await res.json();
          if (revPreview) {
            revPreview.innerHTML = renderMarkdown(data.content || '');
          }
        } catch (e) {
          revPreview.innerHTML = `<span style="color: #f87171;">Failed to load revision: ${e}</span>`;
        }
      });
    }

    // Action: Copy Markdown
    if (btnCopyMd) {
      btnCopyMd.addEventListener('click', () => {
        if (!currentDossierRaw) return;
        navigator.clipboard.writeText(currentDossierRaw).then(() => {
          const orig = btnCopyMd.textContent;
          btnCopyMd.textContent = '[COPIED]';
          setTimeout(() => { btnCopyMd.textContent = orig; }, 1800);
        });
      });
    }

    // Action: Broadcast Thread
    if (btnPublish) {
      btnPublish.addEventListener('click', async () => {
        if (!activeSlug) return;
        if (!confirm(`Broadcast social thread for '${activeSlug}' to active accounts (X, Mastodon, Bluesky)?`)) return;
        btnPublish.disabled = true;
        const orig = btnPublish.textContent;
        btnPublish.textContent = 'BROADCASTING...';
        try {
          const res = await fetch(`/api/research/publish/${encodeURIComponent(activeSlug)}`, { method: 'POST' });
          const data = await res.json();
          alert(`Thread broadcast successfully queued:\n${data.message || 'Queued for publishing sweep.'}`);
        } catch (e) {
          alert(`Broadcast failed: ${e}`);
        } finally {
          btnPublish.disabled = false;
          btnPublish.textContent = orig;
        }
      });
    }

    // Action: Salvage Quarantined Dossier
    if (btnSalvage) {
      btnSalvage.addEventListener('click', async () => {
        if (!activeSlug) return;
        btnSalvage.disabled = true;
        const orig = btnSalvage.textContent;
        btnSalvage.textContent = 'SALVAGING...';
        try {
          const res = await fetch(`/api/research/salvage/${encodeURIComponent(activeSlug)}`, { method: 'POST' });
          const data = await res.json();
          alert(`Salvage run triggered via FIFO IPC channel 'chan_research' for: ${activeSlug}`);
          loadDossiers();
        } catch (e) {
          alert(`Salvage initiation failed: ${e}`);
        } finally {
          btnSalvage.disabled = false;
          btnSalvage.textContent = orig;
        }
      });
    }

    // Action: Submit Interactive Re-Refinement
    if (btnRefineSubmit && refinerSteeringText) {
      btnRefineSubmit.addEventListener('click', async () => {
        const steering = refinerSteeringText.value.trim();
        if (!steering) {
          alert('Please enter specific steering instructions for George.');
          return;
        }
        if (!activeSlug) return;

        btnRefineSubmit.disabled = true;
        const orig = btnRefineSubmit.textContent;
        btnRefineSubmit.textContent = 'INITIATING...';
        if (refinerStatusMsg) refinerStatusMsg.textContent = 'Snapshotting version and queuing verification refiner...';

        try {
          const res = await fetch(`/api/research/refine/${encodeURIComponent(activeSlug)}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              steering_prompt: steering,
              max_retries: currentPasses
            })
          });
          const data = await res.json();
          if (refinerStatusMsg) refinerStatusMsg.textContent = `[OK] Refinement queued. Snapshot: ${data.revision_snapshot}`;
          refinerSteeringText.value = '';
          setTimeout(() => { loadDossierDetail(activeSlug); }, 2500);
        } catch (e) {
          if (refinerStatusMsg) refinerStatusMsg.textContent = `Error: ${e}`;
        } finally {
          btnRefineSubmit.disabled = false;
          btnRefineSubmit.textContent = orig;
        }
      });
    }

    // 7. Option 3: Brainstorm Sidebar Agent
    const brainstormSidebar = document.getElementById('researchBrainstormSidebar');
    const btnToggleBrainstorm = document.getElementById('btnToggleBrainstormSidebar');
    const btnToggleCopilotInMono = document.getElementById('btnToggleCopilotInMono');
    const btnCloseBrainstorm = document.getElementById('btnCloseBrainstorm');
    const brainstormStream = document.getElementById('brainstormChatStream');
    const brainstormInput = document.getElementById('brainstormInputText');
    const btnSendBrainstorm = document.getElementById('btnSendBrainstorm');

    if (btnToggleBrainstorm && brainstormSidebar) {
      btnToggleBrainstorm.addEventListener('click', () => {
        brainstormSidebar.classList.toggle('closed');
      });
    }

    if (btnToggleCopilotInMono && brainstormSidebar) {
      btnToggleCopilotInMono.addEventListener('click', () => {
        brainstormSidebar.classList.toggle('closed');
      });
    }

    if (btnCloseBrainstorm && brainstormSidebar) {
      btnCloseBrainstorm.addEventListener('click', () => {
        brainstormSidebar.classList.add('closed');
      });
    }

    function openBrainstormWithPrompt(promptText) {
      if (brainstormSidebar) brainstormSidebar.classList.remove('closed');
      if (brainstormInput) brainstormInput.value = promptText;
      sendBrainstormMessage(promptText);
    }

    pane.querySelectorAll('.brainstorm-quick-chips .quick-chip').forEach(qc => {
      qc.addEventListener('click', () => {
        const p = qc.getAttribute('data-prompt');
        if (p) openBrainstormWithPrompt(p);
      });
    });

    async function sendBrainstormMessage(msgOverride) {
      const msg = (msgOverride || (brainstormInput ? brainstormInput.value : '')).trim();
      if (!msg) return;

      if (brainstormInput) brainstormInput.value = '';

      // Append user bubble
      if (brainstormStream) {
        brainstormStream.insertAdjacentHTML('beforeend', `
          <div class="chat-bubble user">
            <div class="bubble-header">Operator</div>
            <div class="bubble-body">${escapeHtml(msg)}</div>
          </div>
        `);
        brainstormStream.scrollTop = brainstormStream.scrollHeight;
      }

      // Append thinking bubble
      const thinkingId = 'thinking_' + Date.now();
      if (brainstormStream) {
        brainstormStream.insertAdjacentHTML('beforeend', `
          <div class="chat-bubble assistant" id="${thinkingId}">
            <div class="bubble-header">George Copilot</div>
            <div class="bubble-body"><span style="color: #38bdf8; font-family: var(--font-mono);">Executing live research tools and reasoning...</span></div>
          </div>
        `);
        brainstormStream.scrollTop = brainstormStream.scrollHeight;
      }

      if (btnSendBrainstorm) btnSendBrainstorm.disabled = true;

      try {
        const res = await fetch('/api/research/brainstorm/chat', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            message: msg,
            domain: currentDomain,
            history: brainstormHistory
          })
        });

        const data = await res.json();
        const thinkingEl = document.getElementById(thinkingId);
        if (thinkingEl) {
          const toolsHtml = (data.tools_executed || []).map(t => `
            <div style="background: rgba(0,0,0,0.3); border-left: 2px solid #38bdf8; padding: 6px 8px; margin-bottom: 6px; font-size: 11px; font-family: var(--font-mono); white-space: pre-wrap;">
              ${escapeHtml(t)}
            </div>
          `).join('');

          let bodyHtml = renderMarkdown(data.content || '');

          thinkingEl.innerHTML = `
            <div class="bubble-header">George Copilot <span style="font-weight: normal; color: #64748b;">${data.timestamp || ''}</span></div>
            ${toolsHtml ? `<div style="margin-top: 6px;">${toolsHtml}</div>` : ''}
            <div class="bubble-body" style="margin-top: 6px;">${bodyHtml}</div>
          `;
        }

        brainstormHistory.push({ role: 'user', content: msg });
        brainstormHistory.push({ role: 'assistant', content: data.content || '' });
        if (brainstormHistory.length > 8) brainstormHistory = brainstormHistory.slice(-8);

      } catch (err) {
        const thinkingEl = document.getElementById(thinkingId);
        if (thinkingEl) {
          thinkingEl.innerHTML = `
            <div class="bubble-header">George Copilot</div>
            <div class="bubble-body" style="color: #f87171;">Error executing research brainstorm: ${err}</div>
          `;
        }
      } finally {
        if (btnSendBrainstorm) btnSendBrainstorm.disabled = false;
        if (brainstormStream) brainstormStream.scrollTop = brainstormStream.scrollHeight;
      }
    }

    if (btnSendBrainstorm) {
      btnSendBrainstorm.addEventListener('click', () => sendBrainstormMessage());
    }

    if (brainstormInput) {
      brainstormInput.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && !e.shiftKey) {
          e.preventDefault();
          sendBrainstormMessage();
        }
      });
    }

    // 8. Zero-X-Budget Social Resonance & Timing Telemetry Tray
    const socialResonanceTray = document.getElementById('socialResonanceTray');
    const btnToggleSocialResonance = document.getElementById('btnToggleSocialResonance');
    const btnSyncSocialResonance = document.getElementById('btnSyncSocialResonance');
    const btnCloseSocialResonance = document.getElementById('btnCloseSocialResonance');
    const socialResonanceContent = document.getElementById('socialResonanceContent');
    const resonanceSyncStatus = document.getElementById('resonanceSyncStatus');

    async function loadSocialResonance(forceSync = false) {
      if (!socialResonanceContent) return;
      if (resonanceSyncStatus) {
        resonanceSyncStatus.textContent = forceSync ? 'Polling Mastodon, Bluesky & X Syndication ($0 API)...' : 'Loading telemetry...';
      }
      if (btnSyncSocialResonance) btnSyncSocialResonance.disabled = true;

      try {
        const res = await fetch(forceSync ? '/api/research/analytics/sync' : '/api/research/analytics', {
          method: forceSync ? 'POST' : 'GET'
        });
        const data = await res.json();
        if (resonanceSyncStatus) {
          resonanceSyncStatus.textContent = data.synced_at ? `Synced: ${data.synced_at}` : '';
        }

        const domains = data.domains || [];
        const windows = data.time_windows || [];
        const recDomLabel = data.recommended_domain_label || data.recommended_domain || 'AI / ML & Science';
        const recBasis = data.recommendation_basis === 'empirical_resonance' ? 'Empirical Likes/Boosts' : 'Exploration Balance';

        const domCardsHtml = domains.map(d => {
          const isRec = d.domain === data.recommended_domain;
          return `
            <div style="background: rgba(15, 23, 42, 0.85); border: 1px solid ${isRec ? 'rgba(192, 132, 252, 0.55)' : 'rgba(148, 163, 184, 0.18)'}; border-radius: 6px; padding: 10px 12px;">
              <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 6px;">
                <span style="font-size: 11px; font-weight: 700; color: ${isRec ? '#c084fc' : '#e2e8f0'};">${escapeHtml(d.label || d.domain)}</span>
                ${isRec ? '<span style="font-size: 9px; padding: 1px 5px; border-radius: 3px; background: rgba(192, 132, 252, 0.2); color: #e9d5ff; font-weight: 700;">RECOMMENDED</span>' : ''}
              </div>
              <div style="font-family: var(--font-mono); font-size: 11px; color: #94a3b8; display: flex; flex-direction: column; gap: 3px;">
                <div>Broadcasts: <strong style="color: #f8fafc;">${d.posts || 0}</strong> · Avg Score: <strong style="color: #38bdf8;">${d.avg_score || 0}</strong></div>
                <div>♥ Likes: <strong style="color: #34d399;">${d.likes || 0}</strong> · ↻ Boosts: <strong style="color: #fbbf24;">${d.reposts || 0}</strong> · 💬 Replies: <strong>${d.replies || 0}</strong></div>
                <div>Best Window: <span style="color: #cbd5e1;">${escapeHtml(d.best_window || '—')}</span></div>
              </div>
            </div>
          `;
        }).join('');

        const winCardsHtml = windows.map(w => `
          <div style="background: rgba(15, 23, 42, 0.65); border: 1px solid rgba(56, 189, 248, 0.18); border-radius: 6px; padding: 8px 12px; font-family: var(--font-mono); font-size: 11px;">
            <div style="color: #38bdf8; font-weight: 700; margin-bottom: 4px;">${escapeHtml(w.window)}</div>
            <div style="color: #94a3b8;">Posts: <strong style="color: #f8fafc;">${w.posts || 0}</strong> · ♥ <strong style="color: #34d399;">${w.likes || 0}</strong> · ↻ <strong style="color: #fbbf24;">${w.reposts || 0}</strong> · Avg: <strong>${w.avg_score || 0}</strong></div>
          </div>
        `).join('');

        socialResonanceContent.innerHTML = `
          <div style="display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 10px; margin-bottom: 12px; padding: 8px 12px; background: rgba(168, 85, 247, 0.08); border-radius: 6px; font-family: var(--font-mono); font-size: 11.5px;">
            <div>Total Broadcasts: <strong style="color: #f8fafc;">${data.total_broadcasts || 0}</strong> · Total ♥ Likes: <strong style="color: #34d399;">${data.total_likes || 0}</strong> · Total ↻ Boosts: <strong style="color: #fbbf24;">${data.total_reposts || 0}</strong></div>
            <div>Auto-Optimal Pick: <strong style="color: #c084fc;">${escapeHtml(recDomLabel)}</strong> (${escapeHtml(recBasis)}) · Peak Window: <strong style="color: #38bdf8;">${escapeHtml(data.recommended_window || '—')}</strong></div>
          </div>
          <div style="font-size: 10px; font-weight: 700; color: #94a3b8; margin-bottom: 6px; letter-spacing: 0.05em;">DOMAIN ENGAGEMENT RESONANCE</div>
          <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); gap: 10px; margin-bottom: 12px;">
            ${domCardsHtml}
          </div>
          <div style="font-size: 10px; font-weight: 700; color: #94a3b8; margin-bottom: 6px; letter-spacing: 0.05em;">TIME-OF-DAY WINDOW CADENCE (UTC)</div>
          <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 10px;">
            ${winCardsHtml}
          </div>
        `;
      } catch (e) {
        socialResonanceContent.innerHTML = `<div style="color: #f87171; font-family: var(--font-mono); font-size: 12px;">Failed to load social resonance telemetry: ${e}</div>`;
      } finally {
        if (btnSyncSocialResonance) btnSyncSocialResonance.disabled = false;
      }
    }

    if (btnToggleSocialResonance && socialResonanceTray) {
      btnToggleSocialResonance.addEventListener('click', () => {
        const isHidden = socialResonanceTray.style.display === 'none';
        socialResonanceTray.style.display = isHidden ? 'block' : 'none';
        if (isHidden) loadSocialResonance(false);
      });
    }

    if (btnCloseSocialResonance && socialResonanceTray) {
      btnCloseSocialResonance.addEventListener('click', () => {
        socialResonanceTray.style.display = 'none';
      });
    }

    if (btnSyncSocialResonance) {
      btnSyncSocialResonance.addEventListener('click', () => loadSocialResonance(true));
    }

    // Auto-load library dossiers when switching to Sovereign Research tab
    const researchTabBtn = document.getElementById('researchTabBtn');
    if (researchTabBtn) {
      researchTabBtn.addEventListener('click', () => {
        loadDossiers();
      });
    }

    // Initial load: restore active domain from config
    fetch('/api/research/config')
      .then(r => r.json())
      .then(data => {
        const activeDom = data.active_domain || 'academic';
        setDomain(activeDom, true);
      })
      .catch(() => {
        setDomain('academic', true);
      });
    loadDossiers();
  }

  function sanitizeMath(text) {
    if (!text) return '';
    let s = String(text);
    // Replace standard LaTeX math macros with clean Unicode
    s = s.replace(/\\prod_\{([^}]+)\}\^([a-zA-Z0-9]+|\{[^}]+\})/g, '∏ ($1..$2)')
         .replace(/\\prod_\{([^}]+)\}/g, '∏ ($1)')
         .replace(/\\prod/g, '∏')
         .replace(/\\sum_\{([^}]+)\}\^([a-zA-Z0-9]+|\{[^}]+\})/g, '∑ ($1..$2)')
         .replace(/\\sum_\{([^}]+)\}/g, '∑ ($1)')
         .replace(/\\sum/g, '∑')
         .replace(/\\gamma/g, 'γ')
         .replace(/\\alpha/g, 'α')
         .replace(/\\beta/g, 'β')
         .replace(/\\theta/g, 'θ')
         .replace(/\\lambda/g, 'λ')
         .replace(/\\sigma/g, 'σ')
         .replace(/\\mu/g, 'μ')
         .replace(/\\epsilon/g, 'ε')
         .replace(/\\phi/g, 'φ')
         .replace(/\\omega/g, 'ω')
         .replace(/\\Delta/g, 'Δ')
         .replace(/\\dots/g, '…')
         .replace(/\\cdots/g, '⋯')
         .replace(/\\le/g, '≤')
         .replace(/\\ge/g, '≥')
         .replace(/\\approx/g, '≈')
         .replace(/\\neq/g, '≠')
         .replace(/\\times/g, '×')
         .replace(/\\pm/g, '±')
         .replace(/\\infty/g, '∞')
         .replace(/\\in/g, '∈')
         .replace(/\\to/g, '→')
         .replace(/\\forall/g, '∀')
         .replace(/\\exists/g, '∃')
         .replace(/\\sqrt\{([^}]+)\}/g, '√($1)')
         .replace(/\\frac\{([^}]+)\}\{([^}]+)\}/g, '($1 / $2)');
    // Strip isolated math delimiters $ ... $
    s = s.replace(/\$([^$]+)\$/g, '$1');
    return s;
  }

  function renderMarkdown(md) {
    if (!md) return '';
    if (typeof marked !== 'undefined') {
      try {
        return marked.parse(md);
      } catch (e) {
        // Fall back to sovereign parser
      }
    }

    // Step 1: Extract code blocks to avoid mangling
    const codeBlocks = [];
    let text = md.replace(/```([a-zA-Z0-9_-]*)\n([\s\S]*?)```/g, (match, lang, code) => {
      const idx = codeBlocks.length;
      codeBlocks.push(`<pre><code class="lang-${escapeHtml(lang)}">${escapeHtml(code.trim())}</code></pre>`);
      return `__CODE_BLOCK_${idx}__`;
    });

    // Step 2: Extract inline code
    const inlineCodes = [];
    text = text.replace(/`([^`\n]+)`/g, (match, code) => {
      const idx = inlineCodes.length;
      inlineCodes.push(`<code>${escapeHtml(code)}</code>`);
      return `__INLINE_CODE_${idx}__`;
    });

    // Step 3: Sanitize math expressions outside of code
    text = sanitizeMath(text);

    // Step 4: Parse lines and block structures
    const lines = text.split('\n');
    let html = '';
    let inList = false;
    let listType = null;
    let inTable = false;
    let tableRows = [];

    function closeList() {
      if (inList) {
        html += listType === 'ol' ? '</ol>\n' : '</ul>\n';
        inList = false;
        listType = null;
      }
    }

    function flushTable() {
      if (inTable && tableRows.length > 0) {
        html += '<table>\n';
        tableRows.forEach((row, idx) => {
          const cells = row.split('|').map(c => c.trim()).slice(1, -1);
          if (idx === 0) {
            html += '<thead><tr>' + cells.map(c => `<th>${parseInline(c)}</th>`).join('') + '</tr></thead>\n<tbody>\n';
          } else if (idx === 1 && cells.every(c => /^:?-+:?$/.test(c))) {
            // separator row, skip
          } else {
            html += '<tr>' + cells.map(c => `<td>${parseInline(c)}</td>`).join('') + '</tr>\n';
          }
        });
        html += '</tbody></table>\n';
        inTable = false;
        tableRows = [];
      }
    }

    function parseInline(str) {
      let s = escapeHtml(str);
      // Bold + Italic
      s = s.replace(/\*\*\*([^*]+)\*\*\*/g, '<strong><em>$1</em></strong>');
      s = s.replace(/___([^_]+)___/g, '<strong><em>$1</em></strong>');
      // Bold
      s = s.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
      s = s.replace(/__([^_]+)__/g, '<strong>$1</strong>');
      // Italic
      s = s.replace(/\*([^*]+)\*/g, '<em>$1</em>');
      s = s.replace(/_([^_]+)_/g, '<em>$1</em>');
      return s;
    }

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const trimmed = line.trim();

      // Check table row
      if (trimmed.startsWith('|') && trimmed.endsWith('|')) {
        closeList();
        inTable = true;
        tableRows.push(trimmed);
        continue;
      } else if (inTable) {
        flushTable();
      }

      // Check Headings
      if (/^####\s+(.+)$/.test(trimmed)) {
        closeList();
        const m = trimmed.match(/^####\s+(.+)$/);
        html += `<h4>${parseInline(m[1])}</h4>\n`;
      } else if (/^###\s+(.+)$/.test(trimmed)) {
        closeList();
        const m = trimmed.match(/^###\s+(.+)$/);
        html += `<h3>${parseInline(m[1])}</h3>\n`;
      } else if (/^##\s+(.+)$/.test(trimmed)) {
        closeList();
        const m = trimmed.match(/^##\s+(.+)$/);
        html += `<h2>${parseInline(m[1])}</h2>\n`;
      } else if (/^#\s+(.+)$/.test(trimmed)) {
        closeList();
        const m = trimmed.match(/^#\s+(.+)$/);
        html += `<h1>${parseInline(m[1])}</h1>\n`;
      } else if (/^>\s+(.+)$/.test(trimmed)) {
        closeList();
        const m = trimmed.match(/^>\s+(.+)$/);
        html += `<blockquote>${parseInline(m[1])}</blockquote>\n`;
      } else if (/^(\*|-)\s+(.+)$/.test(trimmed)) {
        const m = trimmed.match(/^(\*|-)\s+(.+)$/);
        if (!inList || listType !== 'ul') {
          closeList();
          html += '<ul>\n';
          inList = true;
          listType = 'ul';
        }
        html += `<li>${parseInline(m[2])}</li>\n`;
      } else if (/^([0-9]+)\.\s+(.+)$/.test(trimmed)) {
        const m = trimmed.match(/^([0-9]+)\.\s+(.+)$/);
        if (!inList || listType !== 'ol') {
          closeList();
          html += '<ol>\n';
          inList = true;
          listType = 'ol';
        }
        html += `<li>${parseInline(m[2])}</li>\n`;
      } else if (/^(---|___|\*\*\*)$/.test(trimmed)) {
        closeList();
        html += '<hr>\n';
      } else if (!trimmed) {
        closeList();
      } else {
        closeList();
        // Check code block placeholder
        if (/^__CODE_BLOCK_[0-9]+__$/.test(trimmed)) {
          html += trimmed + '\n';
        } else {
          html += `<p>${parseInline(trimmed)}</p>\n`;
        }
      }
    }

    closeList();
    flushTable();

    // Step 5: Restore inline codes and code blocks
    inlineCodes.forEach((codeHtml, idx) => {
      html = html.split(`__INLINE_CODE_${idx}__`).join(codeHtml);
    });
    codeBlocks.forEach((blockHtml, idx) => {
      html = html.split(`__CODE_BLOCK_${idx}__`).join(blockHtml);
    });

    return html;
  }

  function escapeHtml(str) {
    if (!str) return '';
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  async function loadApiTriggerPresets() {
    // Loaded statically and interactively
  }

  // Initial Hydration
  hydrateSession();
  initScriptEditor();
  initMcpModule();
  initWorkspaceDock();
  initTrainingForge();
  initReactorWizard();
  initFinanceCockpit();
  initSdrLab();
  initApiTriggerBuilder();
  initResearchStudio();

})();


