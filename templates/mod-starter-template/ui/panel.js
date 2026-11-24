// __MOD_NAME__ — Blue Lodge Sovereign Module UI Panel
// Strictly XSS-safe DOM construction (zero innerHTML / outerHTML / native dialogs).
(function () {
  'use strict';

  function mount(host, ctx) {
    const { el } = ctx;
    const agentName = (typeof ctx.getAgentName === 'function' ? ctx.getAgentName() : ctx.agentName) || 'Agent';

    const state = { entries: [], status: '' };

    const wrap = el('div', { className: 'stmod-wrap' });
    const statusEl = el('div', { className: 'stmod-status' });
    const titleIn = el('input', { className: 'stmod-input', placeholder: 'Entry title...' });
    const catSel = el('select', { className: 'stmod-select' }, [
      el('option', { value: 'note', text: 'Note' }),
      el('option', { value: 'briefing', text: 'Briefing' }),
      el('option', { value: 'checklist', text: 'Checklist' }),
    ]);
    const bodyIn = el('textarea', { className: 'stmod-textarea', placeholder: 'Write a local entry (works 100% offline without an LLM)...' });
    const focusIn = el('input', { className: 'stmod-input', placeholder: `Ask ${agentName} to synthesize your ledger entries...` });
    const listHost = el('div', { className: 'stmod-list' });
    const streamHost = el('div', { className: 'stmod-stream' });

    function setStatus(msg) {
      state.status = msg || '';
      statusEl.textContent = state.status;
      statusEl.style.display = state.status ? 'block' : 'none';
    }

    function renderEntries() {
      listHost.replaceChildren();
      if (!state.entries.length) {
        listHost.appendChild(el('div', { className: 'stmod-empty', text: 'No entries yet. Add one on the left or run the agent briefing workflow.' }));
        return;
      }
      state.entries.forEach((item) => {
        const dt = item.created_at ? new Date(item.created_at * 1000).toLocaleString() : '';
        listHost.appendChild(el('article', { className: 'stmod-card' }, [
          el('div', { className: 'stmod-card-head' }, [
            el('div', {}, [
              el('span', { className: 'stmod-badge', text: item.category || 'note' }),
              el('span', { className: 'stmod-card-title', text: item.title }),
            ]),
            el('div', { className: 'stmod-card-actions' }, [
              el('span', { className: 'stmod-meta', text: dt }),
              el('button', {
                className: 'stmod-btn stmod-btn-sm',
                text: 'Delete',
                on: {
                  click: async () => {
                    await ctx.action('delete', { id: item.id });
                    await loadEntries();
                  },
                },
              }),
            ]),
          ]),
          el('div', { className: 'stmod-card-body', text: item.body }),
        ]));
      });
    }

    async function loadEntries() {
      const res = await ctx.action('list', { limit: 30 });
      if (res && res.status === 'ok') {
        state.entries = Array.isArray(res.entries) ? res.entries : [];
        renderEntries();
      } else {
        setStatus((res && res.message) || 'Failed to load entries');
      }
    }

    const saveBtn = el('button', {
      className: 'stmod-btn stmod-btn-primary',
      text: 'Save Entry',
      on: {
        click: async () => {
          const title = titleIn.value.trim();
          const body = bodyIn.value.trim();
          if (!title || !body) {
            setStatus('Title and body are required.');
            return;
          }
          const res = await ctx.action('save', { title, category: catSel.value, body });
          if (res && res.status === 'ok') {
            titleIn.value = '';
            bodyIn.value = '';
            setStatus('Entry saved to local SQLite ledger.');
            await loadEntries();
          } else {
            setStatus((res && res.message) || 'Save failed');
          }
        },
      },
    });

    const runLoopBtn = el('button', {
      className: 'stmod-btn stmod-btn-amber',
      text: `Run ${agentName} Briefing (ALP v1)`,
      on: {
        click: async () => {
          const objective = focusIn.value.trim() || 'Summarize all recent entries and recommend next steps.';
          setStatus(`Launching sample_briefing via ALP v1 Loop Engine...`);
          try {
            await ctx.launchTask('sample_briefing', { params: { objective } }, {
              streamContainer: streamHost,
              onPhase: (ph) => setStatus(`Active phase: ${ph}`),
              onComplete: async () => {
                setStatus('Briefing completed and persisted to SQLite.');
                await loadEntries();
              },
              onError: (err) => setStatus(`Workflow error: ${err}`),
            });
          } catch (e) {
            setStatus(`Launch failed: ${e.message}`);
          }
        },
      },
    });

    const editLoopBtn = el('button', {
      className: 'stmod-btn',
      text: 'Edit Loop in Studio',
      on: {
        click: () => {
          if (typeof ctx.openLoopStudio === 'function') ctx.openLoopStudio('sample_briefing');
        },
      },
    });

    const grid = el('div', { className: 'stmod-grid' }, [
      el('section', { className: 'stmod-panel' }, [
        el('div', { className: 'stmod-panel-title', text: '1. Local Ledger (Standalone)' }),
        titleIn,
        catSel,
        bodyIn,
        el('div', { className: 'stmod-row' }, [saveBtn]),
        el('div', { className: 'stmod-panel-title', style: 'margin-top: 14px;', text: `2. ${agentName} Agent Workflow` }),
        focusIn,
        el('div', { className: 'stmod-row' }, [runLoopBtn, editLoopBtn]),
        streamHost,
      ]),
      el('section', { className: 'stmod-panel' }, [
        el('div', { className: 'stmod-card-head' }, [
          el('div', { className: 'stmod-panel-title', text: 'Saved Entries & Briefings' }),
          el('button', { className: 'stmod-btn stmod-btn-sm', text: 'Refresh', on: { click: loadEntries } }),
        ]),
        listHost,
      ]),
    ]);

    wrap.appendChild(statusEl);
    wrap.appendChild(grid);
    host.replaceChildren(wrap);
    loadEntries();
  }

  if (window.LodgeModules && typeof window.LodgeModules.register === 'function') {
    window.LodgeModules.register('__MOD_ID__', { mount });
  }
})();
