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

  // --- Auto-Scroll Helper (Latest text center-facing) ---
  function scrollToLatest(preElement = null) {
    if (streamEl) {
      streamEl.scrollTop = streamEl.scrollHeight;
    }
    if (preElement) {
      preElement.scrollTop = preElement.scrollHeight;
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

          data.messages.forEach(msg => {
            if (msg.role === 'user') {
              renderUserBubble(msg.content, false);
            } else if (msg.type === 'command_blueprint') {
              renderBlueprintCard(msg.command, msg.content, msg.id, false);
            } else {
              renderAssistantBubble(msg.content, false);
            }
          });
          scrollToLatest();
        }
      }
    } catch (e) {
      console.warn('Session hydration failed:', e);
    }
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
    bubble.textContent = text;
    row.appendChild(bubble);
    streamEl.appendChild(row);
    if (scroll) scrollToLatest();
    return bubble;
  }

  // Typewriter token streaming pacer
  function streamTextIntoBubble(bubble, fullText, pacingRate, onDone = null) {
    if (pacingRate <= 0) {
      bubble.textContent = fullText;
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
    pre.textContent = output || '(Execution complete with zero output)';
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
          <button class="tactile-btn warn pause-btn" title="Pause execution loop">⏸ PAUSE</button>
          <button class="tactile-btn resume-btn" style="display:none;" title="Resume execution loop">▶ RESUME</button>
          <button class="tactile-btn danger terminate-btn" data-state="initial" title="Terminate process and clean up sandbox">✕ TERMINATE</button>
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

    // Dynamic helpers
    card.updateDial = (text) => {
      const dial = header.querySelector('.blueprint-dial');
      if (dial) dial.textContent = text;
    };
    card.appendLog = (line) => {
      if (pre.textContent.endsWith('\n') || line.startsWith('\n')) {
        pre.textContent += line;
      } else {
        pre.textContent += '\n' + line;
      }
      if (scroll) scrollToLatest(pre);
    };
    card.setLog = (text) => {
      pre.textContent = text;
      if (scroll) scrollToLatest(pre);
    };
    card.getLog = () => pre.textContent;

    return card;
  }

  function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
  }

  // --- Dispatch Prompt / Command ---
  async function dispatchPrompt() {
    const text = promptInput.value.trim();
    if (!text) return;

    promptInput.value = '';
    promptInput.style.height = 'auto';

    renderUserBubble(text, true);

    const isCommand = text.startsWith('/');
    let liveBubble = null;
    if (!isCommand) {
      liveBubble = renderAssistantBubble('George is reflecting...', true);
    }

    try {
      const resp = await fetch('/api/chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ prompt: text, mode: activeChatMode })
      });

      if (resp.ok) {
        const data = await resp.json();
        if (data.type === 'command_blueprint') {
          renderBlueprintCard(text, data.reply, data.session_id, true);
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
        if (liveBubble) liveBubble.textContent = `Error: ${errText}`;
      }
    } catch (err) {
      if (liveBubble) liveBubble.textContent = `Network error: ${err.message}`;
    }
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
                  <span class="bay-badge">${g.index === 0 ? 'TIER 1 PRIMARY' : `TIER 1 ACCELERATOR ${g.index}`}</span>
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
      }

      // 2. Autonomic Task Bay & Swarm Telemetry
      const tasksResp = await fetch('/api/tasks');
      if (tasksResp.ok) {
        const tasks = await tasksResp.json();
        renderAutonomicTaskBay(tasks);
      }

      // 3. SSH Tunnel Telemetry
      if (!window._lastTunnelPoll || Date.now() - window._lastTunnelPoll > 6000) {
        window._lastTunnelPoll = Date.now();
        fetchTunnelStatus();
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
      const statusClass = n.active ? 'success' : (n.enabled ? 'failed' : 'idle');
      const statusText = n.active ? 'ONLINE' : (n.enabled ? 'OFFLINE' : 'STANDBY');
      const isRemote5700 = (n.name === 'legacy-5700xt' || (n.url && n.url.includes('18080')));
      return `
        <div class="node-row ${statusClass}">
          <div class="node-meta">
            <div style="display: flex; align-items: center; gap: 6px;">
              <span class="bay-badge">${escapeHtml(n.tier || 'TIER')}</span>
              <span class="node-name">${escapeHtml(n.name)}</span>
              ${isRemote5700 ? `<span class="bay-badge" style="font-size: 8px; border-color: var(--accent); color: var(--accent);">PROXYJUMP TUNNEL</span>` : ''}
            </div>
            <div class="node-url">${escapeHtml(n.hardware || '')} · <span style="color: var(--accent); font-weight: 600;">${escapeHtml(n.model || '')}</span></div>
            <div class="node-url" style="font-family: var(--font-mono); opacity: 0.85;">${escapeHtml(n.url)} [ctx ${n.context || 4096}]</div>
          </div>
          <div style="display: flex; flex-direction: column; align-items: flex-end; gap: 4px;">
            <span class="cron-status-pill ${statusClass}">${statusText}</span>
            <div style="display: flex; gap: 4px;">
              ${isRemote5700 ? `<button class="mini-action re-tunnel-btn" title="Re-establish SSH ProxyJump tunnel">TUNNEL</button>` : ''}
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
        if (data.connected) {
          banner.classList.remove('disconnected');
          if (dot) dot.classList.remove('disconnected');
          desc.textContent = `ONLINE (port 18080 active · ${data.jump_host ? `via ${data.jump_host}` : 'direct'})`;
        } else {
          banner.classList.add('disconnected');
          if (dot) dot.classList.add('disconnected');
          desc.textContent = `DISCONNECTED (port 18080 unreachable · target: ${data.target || '5700xt'})`;
        }
      }
    } catch (e) {
      console.warn('Failed to fetch tunnel status:', e);
    }
  }

  // --- Autonomic Task Bay Renderer (Mutual-Exclusion Accordion) ---
  function renderAutonomicTaskBay(tasks) {
    if (!autonomicTaskBay || !autonomicBayRail) return;
    cachedTasks = tasks || [];

    // Filter up to 3 live/recent tasks for collapsed display
    const liveTasks = cachedTasks.slice(0, 3);

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
      bayActiveCount.textContent = `${liveTasks.length} Live`;
    }

    // Render collapsed pills in rail (update in place if same tasks to prevent jitter)
    const currentPillIds = Array.from(autonomicBayRail.children).map(c => c.dataset.taskId).join(',');
    const newPillIds = liveTasks.map(t => t.id).join(',');

    if (currentPillIds === newPillIds && currentPillIds !== '') {
      Array.from(autonomicBayRail.children).forEach((pill, idx) => {
        const t = liveTasks[idx];
        const isExpanded = expandedTaskId === t.id;
        const isCopilot = t.type === 'copilot';
        pill.className = `bay-pill${isExpanded ? ' expanded' : ''}${isCopilot ? ' copilot-pill' : ''}`;
        const phaseSpan = pill.querySelector('.bay-pill-phase');
        if (phaseSpan) phaseSpan.textContent = `[${t.phase || 'Active'}]`;
        const indSpan = pill.querySelector('.bay-pill-indicator');
        if (indSpan) indSpan.textContent = isExpanded ? '▲' : '▼';
      });
    } else {
      autonomicBayRail.innerHTML = '';
      liveTasks.forEach(t => {
        const isExpanded = expandedTaskId === t.id;
        const isCopilot = t.type === 'copilot';
        const pill = document.createElement('div');
        pill.dataset.taskId = t.id;
        pill.className = `bay-pill${isExpanded ? ' expanded' : ''}${isCopilot ? ' copilot-pill' : ''}`;
        pill.innerHTML = `
          <span class="bay-pill-type ${escapeHtml(t.type || 'task')}">${escapeHtml((t.type || 'TASK').toUpperCase())}</span>
          <span class="bay-pill-summary" title="${escapeHtml(t.summary || t.id)}">${escapeHtml(t.summary || t.id)}</span>
          <span class="bay-pill-phase">[${escapeHtml(t.phase || 'Active')}]</span>
          <span class="bay-pill-indicator">${isExpanded ? '▲' : '▼'}</span>
        `;

        pill.addEventListener('click', () => {
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
        const logs = (activeTask.log_tail || []).join('\n') || 'Autonomous task active. Monitoring stream...';

        // Check if stage is ALREADY rendered for this activeTask
        if (autonomicExpandedStage.dataset.activeTaskId === activeTask.id) {
          const phaseText = autonomicExpandedStage.querySelector('.task-phase-text');
          if (phaseText) phaseText.textContent = `[${activeTask.phase || 'Active'}]`;
          const stream = autonomicExpandedStage.querySelector('.expanded-log-stream');
          if (stream && stream.dataset.lastLogs !== logs) {
            const isAtBottom = stream.scrollHeight - stream.scrollTop <= stream.clientHeight + 40;
            stream.textContent = logs;
            stream.dataset.lastLogs = logs;
            if (isAtBottom) stream.scrollTop = stream.scrollHeight;
          }
          return;
        }

        autonomicExpandedStage.dataset.activeTaskId = activeTask.id;
        autonomicExpandedStage.innerHTML = `
          <div class="expanded-card-header">
            <div class="expanded-card-title">
              <span class="expanded-card-badge">▲</span>
              <span>${escapeHtml(activeTask.summary || activeTask.id)}</span>
              <span class="task-phase-text" style="font-size: 11px; color: var(--text-muted);">[${escapeHtml(activeTask.phase || 'Active')}]</span>
            </div>
            <button class="tactile-btn mini-collapse-btn">▲ COLLAPSE</button>
          </div>
          <pre class="expanded-log-stream">${escapeHtml(logs)}</pre>
          <div class="expanded-controls">
            <div class="expanded-steer-group">
              <input type="text" class="expanded-steer-input" placeholder="Inject steer direction to this auto-task...">
              <button class="tactile-btn steer-btn">INJECT</button>
            </div>
            <div class="action-buttons">
              <button class="tactile-btn warn pause-btn">PAUSE</button>
              <button class="tactile-btn resume-btn" style="display:none;">RESUME</button>
              <button class="tactile-btn danger terminate-btn" data-state="initial">TERMINATE</button>
            </div>
          </div>
        `;

        if (window._autonomicEventSource) {
          window._autonomicEventSource.close();
          window._autonomicEventSource = null;
        }
        try {
          const aes = new EventSource(`/api/stream/task/${activeTask.id}`);
          window._autonomicEventSource = aes;
          aes.addEventListener('log', (e) => {
            const stream = autonomicExpandedStage.querySelector('.expanded-log-stream');
            if (stream && e.data) {
              const isAtBottom = stream.scrollHeight - stream.scrollTop <= stream.clientHeight + 40;
              stream.textContent += '\n' + e.data;
              stream.dataset.lastLogs = stream.textContent;
              if (isAtBottom) stream.scrollTop = stream.scrollHeight;
            }
          });
          aes.addEventListener('phase', (e) => {
            const phaseText = autonomicExpandedStage.querySelector('.task-phase-text');
            if (phaseText && e.data) phaseText.textContent = `[${e.data}]`;
          });
          aes.addEventListener('done', () => {
            if (aes) aes.close();
            if (window._autonomicEventSource === aes) window._autonomicEventSource = null;
          });
        } catch (e) {}

        autonomicExpandedStage.querySelector('.mini-collapse-btn').addEventListener('click', () => {
          if (window._autonomicEventSource) {
            window._autonomicEventSource.close();
            window._autonomicEventSource = null;
          }
          expandedTaskId = null;
          autonomicExpandedStage.dataset.activeTaskId = '';
          renderAutonomicTaskBay(cachedTasks);
        });

        const steerInput = autonomicExpandedStage.querySelector('.expanded-steer-input');
        const steerBtn = autonomicExpandedStage.querySelector('.steer-btn');
        const pauseBtn = autonomicExpandedStage.querySelector('.pause-btn');
        const resumeBtn = autonomicExpandedStage.querySelector('.resume-btn');
        const terminateBtn = autonomicExpandedStage.querySelector('.terminate-btn');

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
              body: JSON.stringify({ guidance })
            });
            const stream = autonomicExpandedStage.querySelector('.expanded-log-stream');
            if (stream) stream.textContent += `\n[Steer Injected]: ${guidance}`;
          } catch (e) {}
        });

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

  // Start continuous 2s heartbeat
  setInterval(pollHeartbeat, 2000);
  pollHeartbeat();

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
        bayCullBtn.textContent = `[CULLED ${data.culled_count || 0}]`;
        setTimeout(() => {
          bayCullBtn.textContent = origText;
          bayCullBtn.disabled = false;
        }, 2000);
        const tasksResp = await fetch('/api/tasks');
        if (tasksResp.ok) {
          renderAutonomicTaskBay(await tasksResp.json());
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
        const paneId = `pane-${e.target.getAttribute('data-pane')}`;
        const targetPane = document.getElementById(paneId);
        if (targetPane) targetPane.classList.add('active');
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
  }

  // 1. Time-Machine with Pruning / Deletion
  async function loadTranscripts() {
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

      saveGaugeBtn.textContent = '✔ CALIBRATED';
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

      await fetch('/api/config', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
      });
      saveRawBtn.textContent = '✔ COMMITTED';
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
      saveGeorgeMdBtn.textContent = '✔ SPECIFICATION SAVED';
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

    try {
      const payload = searchTerm ? { search: searchTerm } : { query: sqlQuery };
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
          if (d.props && d.props.default_generation_settings) {
            const s = d.props.default_generation_settings;
            details = ` [n_ctx: ${s.n_ctx || 'default'}, temp: ${s.temperature || '0.2'}]`;
          } else if (d.models && Array.isArray(d.models.data) && d.models.data.length > 0) {
            details = ` [Model: ${d.models.data[0].id}]`;
          }
          feedback.innerHTML = `<strong>✔ Online [${escapeHtml(d.provider)}]</strong>: Endpoint responding nominally${escapeHtml(details)}`;
          const provSelect = document.getElementById('newNodeProvider');
          if (provSelect && d.provider) {
            if (d.provider === 'llama.cpp') provSelect.value = 'llama.cpp';
            else if (d.provider === 'ollama') provSelect.value = 'ollama';
          }
        } else {
          feedback.className = 'node-probe-result offline';
          feedback.innerHTML = `<strong>✕ Unreachable</strong>: ${escapeHtml(d.message)}`;
        }
      } catch (e) {
        feedback.className = 'node-probe-result offline';
        feedback.innerHTML = `<strong>✕ Network error</strong>: ${escapeHtml(e.message)}`;
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
        copyStagedCmdBtn.textContent = '✔ COPIED!';
        setTimeout(() => { copyStagedCmdBtn.textContent = '📋 COPY COMMAND'; }, 2000);
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
          status.textContent = '✔ Dispatched via sovereign session';
          status.style.color = 'var(--status-online)';
        }
      } catch (e) {
        if (status) {
          status.textContent = `✕ Dispatch failed: ${e.message}`;
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
      const context = parseInt(document.getElementById('newNodeContext').value, 10) || 8192;
      const hardware = document.getElementById('newNodeHardware').value.trim();
      const jump = document.getElementById('newNodeJump').value.trim();
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
            enabled
          })
        });

        if (resp.ok) {
          saveNodeBtn.textContent = '✔ DOCKED & SAVED';
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
      openFile('.george/endpoints.conf');
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
      btnRestartDaemon.textContent = '🔄 RESTART';
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
      btnStopDaemon.textContent = '⏹ STOP';
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
  async function loadResearchConfig() {
    const phasesDisp = document.getElementById('researchPhasesDisplay');
    const topicsArea = document.getElementById('researchCandidateTopics');
    const directivesArea = document.getElementById('researchDirectives');
    const tempInput = document.getElementById('researchTemperature');
    const tokensInput = document.getElementById('researchMaxTokens');
    const socialCheck = document.getElementById('researchPublishSocial');
    if (!topicsArea) return;

    try {
      const resp = await fetch('/api/research/config');
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
        if (directivesArea) directivesArea.value = data.directives || '';
        if (tempInput) tempInput.value = data.temperature !== undefined ? data.temperature : 0.30;
        if (tokensInput) tokensInput.value = data.max_tokens !== undefined ? data.max_tokens : 4500;
        if (socialCheck) socialCheck.checked = data.publish_social !== false;
      }
    } catch (e) {
      console.warn('Failed to load research config:', e);
    }
  }

  const btnSaveResearchConfig = document.getElementById('btnSaveResearchConfig');
  if (btnSaveResearchConfig) {
    btnSaveResearchConfig.addEventListener('click', async () => {
      const topicsArea = document.getElementById('researchCandidateTopics');
      const directivesArea = document.getElementById('researchDirectives');
      const tempInput = document.getElementById('researchTemperature');
      const tokensInput = document.getElementById('researchMaxTokens');
      const socialCheck = document.getElementById('researchPublishSocial');
      const statusSpan = document.getElementById('researchSaveStatus');

      const topics = topicsArea.value.split('\n').map(s => s.trim()).filter(Boolean);
      const directives = directivesArea.value.trim();
      const temperature = parseFloat(tempInput.value) || 0.30;
      const max_tokens = parseInt(tokensInput.value, 10) || 4500;
      const publish_social = socialCheck.checked;

      btnSaveResearchConfig.disabled = true;
      try {
        const resp = await fetch('/api/research/config', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            candidate_topics: topics,
            directives,
            temperature,
            max_tokens,
            publish_social
          })
        });
        if (resp.ok) {
          if (statusSpan) {
            statusSpan.textContent = '✓ DIRECTIVES SAVED';
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

  // --- Craftsman In-Browser Multi-Tab Script & File Workbench (with Vim Mode) ---
  let editorTabs = [];
  let activeTabId = null;
  let tabCounter = 1;
  let vimMode = 'insert'; // 'insert' | 'normal'
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
        setVimMode(vimMode === 'insert' ? 'normal' : 'insert');
      });
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
            statusMsg.textContent = `⚠ ${data.message}`;
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
            statusMsg.textContent = '✓ Saved & syntax validated by bash -n';
            statusMsg.className = 'script-status-msg success';
            setTimeout(() => {
              if (statusMsg && statusMsg.textContent.includes('Saved')) {
                statusMsg.textContent = vimMode === 'normal' ? '-- NORMAL --' : '-- INSERT --';
              }
            }, 3000);
          }
          loadCronJobs();
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
      textarea.addEventListener(ev, updateCursor);
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
      // Global Save: Ctrl+S / Cmd+S
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') {
        e.preventDefault();
        saveActiveTab();
        return;
      }

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
      } else if (vimMode === 'normal') {
        if (e.key === 'i' || e.key === 'a') {
          e.preventDefault();
          setVimMode('insert');
        } else if (e.key === 'Escape') {
          if (vimLegendDropdown && vimLegendDropdown.style.display !== 'none') {
            toggleVimLegend(false);
          }
          normalBuffer = '';
          if (statusMsg) {
            statusMsg.className = 'script-status-msg';
            statusMsg.textContent = '-- NORMAL --';
          }
        } else if (e.key === '?') {
          e.preventDefault();
          toggleVimLegend();
        } else if (e.key === 'G') {
          e.preventDefault();
          normalBuffer = '';
          textarea.setSelectionRange(textarea.value.length, textarea.value.length);
          textarea.scrollTop = textarea.scrollHeight;
          updateCursor();
        } else if (e.key === ':') {
          e.preventDefault();
          normalBuffer = ':';
          if (statusMsg) {
            statusMsg.className = 'script-status-msg';
            statusMsg.textContent = ':';
          }
        } else if (normalBuffer.startsWith(':')) {
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
        } else if (e.key === 'g') {
          if (normalBuffer === 'g') {
            normalBuffer = '';
            textarea.setSelectionRange(0, 0);
            textarea.scrollTop = 0;
            updateCursor();
          } else {
            normalBuffer = 'g';
          }
        } else if (e.key === 'f' && normalBuffer === 'g') {
          // Vim 'gf' -> GO TO FILE UNDER CURSOR!
          e.preventDefault();
          normalBuffer = '';
          jumpToFileUnderCursor();
        } else if (e.key === 't' && normalBuffer === 'g') {
          // Vim 'gt' -> NEXT TAB
          e.preventDefault();
          normalBuffer = '';
          cycleTab(1);
        } else if (e.key === 'T' && normalBuffer === 'g') {
          // Vim 'gT' -> PREV TAB
          e.preventDefault();
          normalBuffer = '';
          cycleTab(-1);
        } else if (normalBuffer === 'ds') {
          e.preventDefault();
          deleteSurround(e.key);
          normalBuffer = '';
        } else if (normalBuffer.startsWith('cs')) {
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
        } else if (normalBuffer.startsWith('ys')) {
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
        } else if (e.key === 's' && normalBuffer === 'd') {
          e.preventDefault();
          normalBuffer = 'ds';
          if (statusMsg) statusMsg.textContent = 'ds -> target delimiter:';
        } else if (e.key === 'c') {
          normalBuffer = 'c';
        } else if (e.key === 's' && normalBuffer === 'c') {
          e.preventDefault();
          normalBuffer = 'cs';
          if (statusMsg) statusMsg.textContent = 'cs -> target delimiter:';
        } else if (e.key === 's' && normalBuffer === 'y') {
          e.preventDefault();
          normalBuffer = 'ys';
        } else if (e.key === 'd') {
          if (normalBuffer === 'd') {
            e.preventDefault();
            normalBuffer = '';
            deleteCurrentLine();
          } else {
            normalBuffer = 'd';
          }
        } else if (e.key === 'y') {
          if (normalBuffer === 'y') {
            e.preventDefault();
            normalBuffer = '';
            yankCurrentLine();
          } else {
            normalBuffer = 'y';
          }
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
          window.appendCopilotMessage('george', '✓ All proposed edits have been merged into the active buffer.');
        }
      } else {
        if (statusMsg) {
          statusMsg.className = 'script-status-msg';
          statusMsg.textContent = 'Proposed diff discarded. Buffer unchanged.';
        }
        if (window.appendCopilotMessage) {
          window.appendCopilotMessage('george', '✗ Proposed edits discarded. Active buffer unchanged.');
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

    // George Co-Pilot Pair Programming Drawer
    function initCopilotPanel() {
      const btnToggleCopilot = document.getElementById('btnToggleCopilot');
      const copilotPanel = document.getElementById('scriptCopilotPanel');
      const btnCopilotClose = document.getElementById('btnCopilotClose');
      const copilotMessages = document.getElementById('copilotMessages');
      const copilotPromptInput = document.getElementById('copilotPromptInput');
      const btnSendCopilotPrompt = document.getElementById('btnSendCopilotPrompt');
      const copilotActiveFile = document.getElementById('copilotActiveFile');
      const copilotDiffBay = document.getElementById('copilotDiffBay');
      const btnAcceptCopilotDiff = document.getElementById('btnAcceptCopilotDiff');
      const btnRejectCopilotDiff = document.getElementById('btnRejectCopilotDiff');

      let isGenerating = false;
      let timerInterval = null;

      function setGeneratingState(generating) {
        isGenerating = generating;
        if (btnSendCopilotPrompt) {
          btnSendCopilotPrompt.disabled = generating;
          btnSendCopilotPrompt.textContent = generating ? '⟳ CRAFTING...' : 'SEND';
        }
        if (copilotPromptInput) {
          copilotPromptInput.disabled = generating;
        }
        const chips = document.querySelectorAll('.copilot-quick-chips .quick-chip');
        chips.forEach(c => {
          c.disabled = generating;
          c.style.opacity = generating ? '0.4' : '1';
          c.style.pointerEvents = generating ? 'none' : 'auto';
        });
      }

      function updateCopilotContext() {
        const tab = getActiveTab();
        if (copilotActiveFile) {
          copilotActiveFile.textContent = tab ? (tab.path || 'untitled.sh') : 'untitled.sh';
        }
      }

      function toggleCopilot() {
        if (!copilotPanel) return;
        const isVisible = copilotPanel.style.display !== 'none';
        copilotPanel.style.display = isVisible ? 'none' : 'flex';
        if (btnToggleCopilot) {
          btnToggleCopilot.classList.toggle('active', !isVisible);
        }
        recalculateWorkbenchGeometry();
        if (!isVisible) {
          updateCopilotContext();
          if (copilotPromptInput) copilotPromptInput.focus();
        }
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
      }

      if (btnToggleCopilot) {
        btnToggleCopilot.addEventListener('click', toggleCopilot);
      }
      if (btnCopilotClose) {
        btnCopilotClose.addEventListener('click', toggleCopilot);
      }

      function appendCopilotMessage(role, text) {
        if (!copilotMessages) return null;
        const msgEl = document.createElement('div');
        msgEl.className = `copilot-msg ${role}`;

        const authorEl = document.createElement('div');
        authorEl.className = 'copilot-msg-author';
        authorEl.textContent = role === 'george' ? 'GEORGE' : 'OPERATOR';

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

      async function submitPrompt(promptText) {
        if (isGenerating) return;
        const text = (promptText || (copilotPromptInput ? copilotPromptInput.value : '')).trim();
        if (!text) return;

        if (copilotPromptInput) {
          copilotPromptInput.value = '';
          copilotPromptInput.style.height = '38px';
          copilotPromptInput.style.minHeight = '38px';
        }
        appendCopilotMessage('user', text);

        const tab = getActiveTab();
        const filePath = tab ? tab.path : 'untitled.sh';
        const fileContent = tab ? (tab.content !== undefined ? tab.content : textarea.value) : textarea.value;
        const selection = textarea ? textarea.value.substring(textarea.selectionStart, textarea.selectionEnd) : '';

        setGeneratingState(true);

        const fName = filePath.split('/').pop() || 'file';
        const fileStem = fName.replace(/[^a-zA-Z0-9_-]/g, '_');
        const taskId = `copilot_${fileStem}_${Math.floor(Date.now() / 1000)}`;

        // Render the collapsible George Task Blueprint Card right into the Co-Pilot message stream!
        const taskCard = renderBlueprintCard(
          `Refactor ${fName}`,
          `[TASK INITIALIZED]: ${text}\n[FILE]: ${filePath}\n[STATUS]: Generating reasoning & internal monologue...\n`,
          taskId,
          true,
          copilotMessages,
          'GEORGE TASK',
          'REASONING'
        );

        // Immediately trigger Autonomic Bay poll so the task pill pops into the Autonomic Task Bay rail!
        setTimeout(pollHeartbeat, 250);

        // Connect live SSE trajectory stream to the task
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
        } catch (e) {
          console.warn('Task stream error:', e);
        }

        try {
          const resp = await fetch('/api/copilot/chat', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              task_id: taskId,
              file_path: filePath,
              file_content: fileContent,
              selection: selection || null,
              instruction: text,
              session_id: 'workbench'
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

          if (data.status === 'aborted') {
            if (taskCard) {
              taskCard.updateDial('ABORTED');
              taskCard.appendLog('\n[ABORTED]: Task terminated by operator.');
            }
            appendCopilotMessage('george', 'Coding task was aborted by the operator.');
            return;
          }

          if (taskCard) {
            taskCard.updateDial('COMPLETED');
            if (data.reasoning && (!taskCard.getLog() || taskCard.getLog().length < 60)) {
              taskCard.setLog(data.reasoning);
            }
          }

          const explanation = data.explanation || (data.has_edit ? 'Here are the proposed edits staged in the Diff Viewer.' : data.reply);
          appendCopilotMessage('george', explanation);

          if (data.has_edit && data.proposed_code) {
            currentProposedCode = data.proposed_code;
            // Launch the full-width Diff Review Viewport in the Workbench!
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

        copilotPromptInput.addEventListener('focus', () => {
          copilotPromptInput.style.minHeight = '84px';
        });

        copilotPromptInput.addEventListener('blur', () => {
          if (!copilotPromptInput.value.trim()) {
            copilotPromptInput.style.minHeight = '38px';
            copilotPromptInput.style.height = '38px';
          }
        });

        copilotPromptInput.addEventListener('keydown', (e) => {
          if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            submitPrompt();
          }
        });
      }

      const chips = document.querySelectorAll('.copilot-quick-chips .quick-chip');
      chips.forEach(chip => {
        chip.addEventListener('click', () => {
          const prompt = chip.getAttribute('data-prompt');
          if (prompt) submitPrompt(prompt);
        });
      });

      if (btnAcceptCopilotDiff) {
        btnAcceptCopilotDiff.addEventListener('click', () => closeDiffReview(true));
      }

      if (btnRejectCopilotDiff) {
        btnRejectCopilotDiff.addEventListener('click', () => closeDiffReview(false));
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
    async function loadWorkspaceFiles(rootPath) {
      if (!filesListEl) return;
      try {
        const url = rootPath ? `/api/files/list?root=${encodeURIComponent(rootPath)}` : '/api/files/list';
        const resp = await fetch(url);
        if (resp.ok) {
          const data = await resp.json();
          workspaceFilesCache = data.files || [];
          renderWorkspaceFiles(workspaceFilesCache);
        }
      } catch (e) {
        filesListEl.innerHTML = '<div class="deps-none" style="padding: 10px;">Failed to load files</div>';
      }
    }
    window.refreshEditorWorkspaceFiles = loadWorkspaceFiles;

    function renderWorkspaceFiles(files) {
      if (!filesListEl) return;
      if (files.length === 0) {
        filesListEl.innerHTML = '<div class="deps-none" style="padding: 10px;">No matching files</div>';
        return;
      }

      const groups = {};
      files.forEach(f => {
        const cat = f.category || 'Other';
        if (!groups[cat]) groups[cat] = [];
        groups[cat].push(f);
      });

      filesListEl.innerHTML = Object.keys(groups).map(cat => `
        <div class="sidebar-cat-group">
          <div class="sidebar-cat-title">${escapeHtml(cat)}</div>
          ${groups[cat].map(f => {
            const isTabOpen = editorTabs.some(t => t.path === f.path);
            return `
              <div class="sidebar-file-item${isTabOpen ? ' active' : ''}" data-file-path="${escapeHtml(f.path)}">
                <span>${escapeHtml(f.name)}</span>
                <span style="font-size: 9px; opacity: 0.6;">${escapeHtml(f.ext)}</span>
              </div>
            `;
          }).join('')}
        </div>
      `).join('');

      filesListEl.querySelectorAll('.sidebar-file-item').forEach(el => {
        el.addEventListener('click', () => {
          const path = el.getAttribute('data-file-path');
          if (path) openFile(path);
        });
      });
    }

    if (fileSearchInput) {
      fileSearchInput.addEventListener('input', () => {
        const query = fileSearchInput.value.toLowerCase().trim();
        if (!query) {
          renderWorkspaceFiles(workspaceFilesCache);
        } else {
          const filtered = workspaceFilesCache.filter(f => f.path.toLowerCase().includes(query) || f.name.toLowerCase().includes(query));
          renderWorkspaceFiles(filtered);
        }
      });
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

    // Export to global window
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
            <button class="tactile-btn danger btn-mcp-stop" data-name="${srv.name}">⏹ STOP</button>
            <button class="tactile-btn btn-mcp-remove" data-name="${srv.name}">✕</button>
          `;
        } else {
          actionBtns = `
            <button class="tactile-btn accent btn-mcp-start" data-name="${srv.name}">▶ START</button>
            <button class="tactile-btn btn-mcp-remove" data-name="${srv.name}">✕</button>
          `;
        }

        let toolsSection = '';
        if (toolList.length > 0) {
          const chips = toolList.map(t => `
            <div class="mcp-tool-chip" title="${escapeHtml(t.description || '')}">
              <span>${escapeHtml(t.name)}</span>
              <button class="btn-tool-test" data-server="${escapeHtml(srv.name)}" data-tool="${escapeHtml(t.name)}" data-schema='${escapeHtml(JSON.stringify(t.inputSchema || {}))}'>TEST ↗</button>
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

  // Initial Hydration
  hydrateSession();
  initScriptEditor();
  initMcpModule();
  initWorkspaceDock();

})();

