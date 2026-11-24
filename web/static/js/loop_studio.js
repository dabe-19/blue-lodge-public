// ============================================================================
// BLUE LODGE // Sovereign Agentic Loop Studio (ALP v1)
// Reusable visual editor, tool-flow composer, and live runner for Heartwood
// (including Sovereign Research Studio) and all Lodge Guild Modules.
// Strictly XSS-safe DOM construction (zero innerHTML / outerHTML / alert).
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
      if (opts.style) {
        if (typeof opts.style === 'string') node.setAttribute('style', opts.style);
        else Object.assign(node.style, opts.style);
      }
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

  function deepClone(obj) {
    return JSON.parse(JSON.stringify(obj));
  }

  function makeStarterLoop(owner, id, name) {
    const isHeartwood = owner === 'heartwood';
    return {
      schema_version: 1,
      id: id,
      name: name || id,
      owner: owner,
      owner_type: isHeartwood ? 'heartwood' : 'module',
      category: isHeartwood ? 'core' : 'module',
      version: '1.0.0',
      description: 'Custom multi-phase agentic loop with FIFO pre-flight and 200-turn ReAct execution.',
      defaults: {
        max_turns: 200,
        ipc_priority: 100,
        fifo_window: 16,
        tool_timeout_sec: 180,
        require_result_json: true,
        output_artifact: 'result.json',
      },
      inputs: [
        { name: 'objective', type: 'text', label: 'Objective / Query', required: true, placeholder: 'Describe what this workflow should analyze or produce...' },
      ],
      tools: {
        bundles: isHeartwood ? [] : [`+${owner}`],
        allow: ['file_read', 'file_write'],
        deny: [],
      },
      phases: [
        {
          id: 'execute_react',
          name: 'Phase 1: ReAct Investigation & Execution',
          kind: 'react',
          enabled: true,
          max_turns: 200,
          tool_filter: 'default',
          tools_allow: [],
          prompt_template: 'Execute the workflow objective:\n\n{{params.objective}}\n\nWrite structured JSON to {{result_path}} with keys: workflow, summary, findings, and deliver a concise markdown report.',
          gate: {
            type: 'json_file',
            path: 'result.json',
            required_keys: ['workflow', 'summary'],
            on_fail: 'retry',
            max_retries: 1,
          },
        },
      ],
    };
  }

  function mountStudio(container, options) {
    const opts = options || {};
    const lockedOwner = opts.owner || null;
    const initialLoopId = opts.loopId || null;

    const state = {
      ownerFilter: lockedOwner || 'all',
      loops: [],
      selectedOwner: lockedOwner || null,
      selectedId: initialLoopId || null,
      detail: null,
      draft: null,
      saveTarget: 'override',
      activeTab: 'pipeline',
      creatingNew: false,
      confirmDelete: false,
      toolSearch: '',
      statusText: '',
      statusWarn: false,
    };

    const root = el('div', { className: 'ls-root' });
    const layout = el('div', { className: 'ls-layout' });
    const sidebar = el('div', { className: 'ls-sidebar' });
    const editor = el('div', { className: 'ls-editor' });
    layout.appendChild(sidebar);
    layout.appendChild(editor);
    root.appendChild(layout);
    container.replaceChildren(root);

    function setStatus(msg, isWarn) {
      state.statusText = msg || '';
      state.statusWarn = !!isWarn;
      const bar = editor.querySelector('.ls-status');
      if (bar) {
        bar.textContent = state.statusText;
        bar.className = 'ls-status' + (state.statusText ? ' visible' : '') + (state.statusWarn ? ' warn' : '');
      }
    }

    async function fetchLoopsList() {
      const url = lockedOwner
        ? `/api/loops/${encodeURIComponent(lockedOwner)}`
        : '/api/loops';
      const r = await fetch(url);
      const d = await r.json().catch(() => ({ loops: [] }));
      state.loops = Array.isArray(d.loops) ? d.loops : [];
      renderSidebar();
      if (state.selectedOwner && state.selectedId) {
        const exists = state.loops.some((l) => l.owner === state.selectedOwner && l.id === state.selectedId);
        if (exists) {
          await loadLoopDetail(state.selectedOwner, state.selectedId);
          return;
        }
      }
      if (state.loops.length > 0) {
        const pick = (initialLoopId && state.loops.find((l) => l.id === initialLoopId)) || state.loops[0];
        await loadLoopDetail(pick.owner, pick.id);
      } else {
        state.detail = null;
        state.draft = null;
        renderEditor();
      }
    }

    async function loadLoopDetail(owner, loopId) {
      state.selectedOwner = owner;
      state.selectedId = loopId;
      state.creatingNew = false;
      state.confirmDelete = false;
      renderSidebar();
      const r = await fetch(`/api/loops/${encodeURIComponent(owner)}/${encodeURIComponent(loopId)}`);
      const d = await r.json().catch(() => null);
      if (!r.ok || !d || !d.loop) {
        setStatus((d && d.message) || `Failed to load ${owner}/${loopId}`, true);
        return;
      }
      state.detail = d;
      state.draft = deepClone(d.loop);
      state.saveTarget = d.has_override || d.is_custom ? 'override' : 'override';
      renderEditor();
    }

    function renderSidebar() {
      sidebar.replaceChildren();
      const top = el('div', { className: 'ls-sidebar-top' });
      const titleRow = el('div', { className: 'ls-sidebar-title-row' }, [
        el('span', { className: 'ls-sidebar-title', text: lockedOwner ? `${lockedOwner} Loops` : 'Agentic Loops (ALP v1)' }),
        el('button', {
          className: 'ls-btn ls-btn-primary ls-btn-sm',
          text: '+ New Loop',
          on: {
            click: () => {
              state.creatingNew = true;
              state.confirmDelete = false;
              renderEditor();
            },
          },
        }),
      ]);
      top.appendChild(titleRow);

      if (!lockedOwner) {
        const owners = ['all', 'heartwood'];
        state.loops.forEach((l) => {
          if (l.owner && !owners.includes(l.owner)) owners.push(l.owner);
        });
        const pills = el('div', { className: 'ls-owner-pills' });
        owners.forEach((ow) => {
          pills.appendChild(el('button', {
            className: 'ls-owner-pill' + (state.ownerFilter === ow ? ' active' : ''),
            text: ow === 'all' ? 'All' : ow,
            on: {
              click: () => {
                state.ownerFilter = ow;
                renderSidebar();
              },
            },
          }));
        });
        top.appendChild(pills);
      }
      sidebar.appendChild(top);

      const listEl = el('div', { className: 'ls-list' });
      const filtered = state.loops.filter((l) => state.ownerFilter === 'all' || l.owner === state.ownerFilter);
      if (filtered.length === 0) {
        listEl.appendChild(el('div', { className: 'ls-item-sub', text: 'No loops found. Click + New Loop to create one.', style: 'padding: 10px;' }));
      }
      filtered.forEach((item) => {
        const isActive = !state.creatingNew && state.selectedOwner === item.owner && state.selectedId === item.id;
        const badges = [
          el('span', { className: 'ls-badge ls-badge-turns', text: `${item.max_turns || 200}t` }),
          el('span', { className: 'ls-badge', text: `${item.enabled_phase_count}/${item.phase_count} phases` }),
        ];
        if (item.fifo_phases > 0) {
          badges.push(el('span', { className: 'ls-badge ls-badge-fifo', text: `FIFO ×${item.fifo_phases}` }));
        }
        if (item.has_override) {
          badges.push(el('span', { className: 'ls-badge ls-badge-ovr', text: item.is_custom ? 'CUSTOM' : 'OVERRIDE' }));
        }
        listEl.appendChild(el('button', {
          className: 'ls-item' + (isActive ? ' active' : ''),
          on: { click: () => loadLoopDetail(item.owner, item.id) },
        }, [
          el('div', { className: 'ls-item-name', text: item.name }),
          el('div', { className: 'ls-item-sub', text: `${item.owner}/${item.id}` }),
          el('div', { className: 'ls-item-badges' }, badges),
        ]));
      });
      sidebar.appendChild(listEl);
    }

    function renderCreateForm() {
      editor.replaceChildren();
      const owners = lockedOwner ? [lockedOwner] : ['heartwood'];
      if (!lockedOwner) {
        state.loops.forEach((l) => { if (l.owner && !owners.includes(l.owner)) owners.push(l.owner); });
      }
      const ownerSel = el('select', { className: 'ls-select' }, owners.map((o) => el('option', { value: o, text: o })));
      if (state.ownerFilter !== 'all' && owners.includes(state.ownerFilter)) ownerSel.value = state.ownerFilter;
      const idInput = el('input', { className: 'ls-input', placeholder: 'e.g. evening_stand_audit (lowercase, digits, _ or -)' });
      const nameInput = el('input', { className: 'ls-input', placeholder: 'e.g. Evening Stand & Wind Audit' });
      const targetSel = el('select', { className: 'ls-select' }, [
        el('option', { value: 'override', text: 'Local Override (upgrade-safe in .george/)' }),
        el('option', { value: 'source', text: 'Repo / Module Source (Git-tracked workflows/)' }),
      ]);
      const statusBar = el('div', { className: 'ls-status' });

      const header = el('div', { className: 'ls-editor-header' }, [
        el('div', { className: 'ls-header-meta' }, [
          el('div', { className: 'ls-header-title', text: 'Create New Agentic Loop (ALP v1)' }),
          el('div', { className: 'ls-header-id', text: 'Defaults to 200 max turns with FIFO IPC support' }),
        ]),
        el('div', { className: 'ls-header-actions' }, [
          el('button', {
            className: 'ls-btn',
            text: 'Cancel',
            on: { click: () => { state.creatingNew = false; renderEditor(); } },
          }),
          el('button', {
            className: 'ls-btn ls-btn-primary',
            text: 'Create Loop',
            on: {
              click: async () => {
                const ow = ownerSel.value;
                const lid = idInput.value.trim().toLowerCase();
                const lname = nameInput.value.trim() || lid;
                if (!/^[a-z0-9][a-z0-9_-]{1,48}$/.test(lid)) {
                  statusBar.textContent = 'Loop ID must be 2–49 chars: lowercase letters, digits, underscore, or hyphen.';
                  statusBar.className = 'ls-status visible warn';
                  return;
                }
                const starter = makeStarterLoop(ow, lid, lname);
                const r = await fetch(`/api/loops/${encodeURIComponent(ow)}`, {
                  method: 'POST',
                  headers: { 'Content-Type': 'application/json' },
                  body: JSON.stringify({ id: lid, target: targetSel.value, loop: starter }),
                });
                const d = await r.json().catch(() => ({}));
                if (!r.ok || d.status !== 'ok') {
                  statusBar.textContent = d.message || 'Failed to create loop';
                  statusBar.className = 'ls-status visible warn';
                  return;
                }
                state.selectedOwner = ow;
                state.selectedId = lid;
                state.creatingNew = false;
                await fetchLoopsList();
                setStatus(`Created ${ow}/${lid} (${targetSel.value}).`, false);
              },
            },
          }),
        ]),
      ]);

      const body = el('div', { className: 'ls-body' }, [
        el('div', { className: 'ls-phase-grid' }, [
          el('div', { className: 'ls-field' }, [el('label', { text: 'Owner (Heartwood or Module)' }), ownerSel]),
          el('div', { className: 'ls-field' }, [el('label', { text: 'Loop ID' }), idInput]),
          el('div', { className: 'ls-field' }, [el('label', { text: 'Display Name' }), nameInput]),
          el('div', { className: 'ls-field' }, [el('label', { text: 'Save Target' }), targetSel]),
        ]),
      ]);

      editor.appendChild(header);
      editor.appendChild(statusBar);
      editor.appendChild(body);
    }

    function renderEditor() {
      if (state.creatingNew) {
        renderCreateForm();
        return;
      }
      editor.replaceChildren();
      if (!state.draft || !state.detail) {
        editor.appendChild(el('div', { className: 'ls-body' }, [
          el('div', { className: 'ls-item-sub', text: 'Select a loop on the left or click + New Loop.' }),
        ]));
        return;
      }

      const loop = state.draft;
      const det = state.detail;

      const targetSel = el('select', {
        className: 'ls-select',
        title: 'Choose where to save edits',
        on: { change: (e) => { state.saveTarget = e.target.value; } },
      }, [
        el('option', { value: 'override', text: 'Save: Local Override' }),
        el('option', { value: 'source', text: 'Save: Module / Repo Source' }),
      ]);
      targetSel.value = state.saveTarget;

      const headerActions = [targetSel];

      if (det.has_override && !det.is_custom) {
        headerActions.push(el('button', {
          className: 'ls-btn ls-btn-amber',
          text: 'Reset to Default',
          on: {
            click: async () => {
              const r = await fetch(`/api/loops/${encodeURIComponent(det.owner)}/${encodeURIComponent(det.id)}?target=override`, { method: 'DELETE' });
              const d = await r.json().catch(() => ({}));
              if (!r.ok) {
                setStatus(d.message || 'Reset failed', true);
                return;
              }
              await fetchLoopsList();
              setStatus(`Reverted ${det.owner}/${det.id} to packaged default.`, false);
            },
          },
        }));
      } else if (det.is_custom) {
        headerActions.push(el('button', {
          className: 'ls-btn ls-btn-amber',
          text: state.confirmDelete ? 'Confirm Delete' : 'Delete Loop',
          on: {
            click: async () => {
              if (!state.confirmDelete) {
                state.confirmDelete = true;
                renderEditor();
                return;
              }
              const r = await fetch(`/api/loops/${encodeURIComponent(det.owner)}/${encodeURIComponent(det.id)}?target=override`, { method: 'DELETE' });
              if (r.ok) {
                state.selectedId = null;
                state.confirmDelete = false;
                await fetchLoopsList();
                setStatus('Deleted custom loop.', false);
              }
            },
          },
        }));
      }

      headerActions.push(el('button', {
        className: 'ls-btn',
        text: 'Run Now',
        on: {
          click: () => {
            state.activeTab = 'runner';
            renderEditor();
          },
        },
      }));

      headerActions.push(el('button', {
        className: 'ls-btn ls-btn-primary',
        text: 'Save Changes',
        on: {
          click: async () => {
            setStatus('Validating & saving loop...', false);
            const r = await fetch(`/api/loops/${encodeURIComponent(det.owner)}/${encodeURIComponent(det.id)}`, {
              method: 'PUT',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ target: state.saveTarget, loop: state.draft }),
            });
            const d = await r.json().catch(() => ({}));
            if (!r.ok || d.status !== 'ok') {
              setStatus(d.message || 'Validation failed', true);
              return;
            }
            await fetchLoopsList();
            setStatus(`Saved ${det.owner}/${det.id} to ${state.saveTarget} (${d.path || ''}).`, false);
          },
        },
      }));

      const header = el('div', { className: 'ls-editor-header' }, [
        el('div', { className: 'ls-header-meta' }, [
          el('div', { className: 'ls-header-title', text: loop.name || loop.id }),
          el('div', {
            className: 'ls-header-id',
            text: `${det.owner}/${det.id} · v${loop.version || '1.0.0'} · ${det.has_override ? (det.is_custom ? 'Custom Loop' : 'Local Override Active') : 'Packaged Source'}`,
          }),
        ]),
        el('div', { className: 'ls-header-actions' }, headerActions),
      ]);

      const tabs = [
        { id: 'pipeline', label: `Pipeline (${(loop.phases || []).length})` },
        { id: 'tools', label: `Tools & Defaults (${((loop.tools && loop.tools.allow) || []).length})` },
        { id: 'json', label: 'Raw JSON' },
        { id: 'runner', label: 'Run & Monitor' },
      ];
      const subtabBar = el('div', { className: 'ls-subtabs' }, tabs.map((t) => el('button', {
        className: 'ls-subtab' + (state.activeTab === t.id ? ' active' : ''),
        text: t.label,
        on: {
          click: () => {
            state.activeTab = t.id;
            renderEditor();
          },
        },
      })));

      const statusBar = el('div', {
        className: 'ls-status' + (state.statusText ? ' visible' : '') + (state.statusWarn ? ' warn' : ''),
        text: state.statusText,
      });

      const body = el('div', { className: 'ls-body' });
      if (state.activeTab === 'pipeline') renderPipelineTab(body, loop, det);
      else if (state.activeTab === 'tools') renderToolsDefaultsTab(body, loop, det);
      else if (state.activeTab === 'json') renderRawJsonTab(body, loop);
      else if (state.activeTab === 'runner') renderRunnerTab(body, loop, det);

      editor.appendChild(header);
      editor.appendChild(subtabBar);
      editor.appendChild(statusBar);
      editor.appendChild(body);
    }

    function renderPipelineTab(body, loop, det) {
      // Top metadata strip (Name + Description)
      const metaGrid = el('div', { className: 'ls-phase-grid' }, [
        el('div', { className: 'ls-field' }, [
          el('label', { text: 'Loop Display Name' }),
          el('input', {
            className: 'ls-input',
            value: loop.name || '',
            on: { input: (e) => { loop.name = e.target.value; } },
          }),
        ]),
        el('div', { className: 'ls-field' }, [
          el('label', { text: 'Description' }),
          el('input', {
            className: 'ls-input',
            value: loop.description || '',
            on: { input: (e) => { loop.description = e.target.value; } },
          }),
        ]),
      ]);
      body.appendChild(metaGrid);

      const allToolNames = [];
      const avail = det.available_tools || {};
      (avail.module_tools || []).forEach((t) => allToolNames.push(t.name));
      (avail.core_tools || []).forEach((t) => { if (!allToolNames.includes(t.name)) allToolNames.push(t.name); });

      const phases = loop.phases || (loop.phases = []);
      phases.forEach((ph, idx) => {
        const card = el('div', {
          className: `ls-phase-card kind-${ph.kind || 'react'}` + (ph.enabled === false ? ' disabled' : ''),
        });

        const enCheck = el('input', {
          type: 'checkbox',
          checked: ph.enabled !== false,
          title: 'Enable or skip this phase',
          on: {
            change: (e) => {
              ph.enabled = e.target.checked;
              card.classList.toggle('disabled', !ph.enabled);
            },
          },
        });
        const nameIn = el('input', {
          className: 'ls-input',
          value: ph.name || ph.id || '',
          style: 'flex: 1; min-width: 180px; font-weight: 600;',
          on: { input: (e) => { ph.name = e.target.value; } },
        });
        const kindSel = el('select', {
          className: 'ls-select',
          on: {
            change: (e) => {
              ph.kind = e.target.value;
              if ((ph.kind === 'fifo_parallel' || ph.kind === 'fifo_pipe') && !Array.isArray(ph.tasks)) ph.tasks = [];
              if (ph.kind === 'react') {
                if (!ph.max_turns) ph.max_turns = (loop.defaults && loop.defaults.max_turns) || 200;
                if (ph.prompt_template == null) ph.prompt_template = '';
              }
              renderEditor();
            },
          },
        }, [
          el('option', { value: 'fifo_parallel', text: 'FIFO Parallel Fan-Out' }),
          el('option', { value: 'fifo_pipe', text: 'FIFO Sequential Pipe' }),
          el('option', { value: 'react', text: 'ReAct Agent Loop' }),
          el('option', { value: 'delegate_script', text: 'Native Script Handler' }),
        ]);
        kindSel.value = ph.kind || 'react';

        const moveUp = el('button', {
          className: 'ls-btn ls-btn-sm',
          text: '↑',
          disabled: idx === 0,
          title: 'Move phase up',
          on: {
            click: () => {
              const tmp = phases[idx - 1];
              phases[idx - 1] = phases[idx];
              phases[idx] = tmp;
              renderEditor();
            },
          },
        });
        const moveDn = el('button', {
          className: 'ls-btn ls-btn-sm',
          text: '↓',
          disabled: idx === phases.length - 1,
          title: 'Move phase down',
          on: {
            click: () => {
              const tmp = phases[idx + 1];
              phases[idx + 1] = phases[idx];
              phases[idx] = tmp;
              renderEditor();
            },
          },
        });
        const delBtn = el('button', {
          className: 'ls-btn ls-btn-sm',
          text: '×',
          disabled: phases.length <= 1,
          title: 'Remove phase',
          on: {
            click: () => {
              phases.splice(idx, 1);
              renderEditor();
            },
          },
        });

        card.appendChild(el('div', { className: 'ls-phase-head' }, [
          el('span', { className: 'ls-phase-num', text: String(idx + 1) }),
          enCheck,
          nameIn,
          kindSel,
          moveUp,
          moveDn,
          delBtn,
        ]));

        if (ph.description) {
          card.appendChild(el('div', { className: 'ls-item-sub', text: ph.description }));
        }

        if (ph.kind === 'react') {
          const rGrid = el('div', { className: 'ls-phase-grid' }, [
            el('div', { className: 'ls-field' }, [
              el('label', { text: 'Max Turns (default 200)' }),
              el('input', {
                className: 'ls-input',
                type: 'number',
                value: String(ph.max_turns || (loop.defaults && loop.defaults.max_turns) || 200),
                attrs: { min: '1', max: '500' },
                on: { input: (e) => { ph.max_turns = Math.max(1, Math.min(500, parseInt(e.target.value, 10) || 200)); } },
              }),
            ]),
            el('div', { className: 'ls-field' }, [
              el('label', { text: 'Tool Profile Filter' }),
              (() => {
                const s = el('select', {
                  className: 'ls-select',
                  on: { change: (e) => { ph.tool_filter = e.target.value; } },
                }, ['default', 'research', 'code', 'all'].map((v) => el('option', { value: v, text: v })));
                s.value = ph.tool_filter || 'default';
                return s;
              })(),
            ]),
          ]);
          card.appendChild(rGrid);

          card.appendChild(el('div', { className: 'ls-field' }, [
            el('label', { text: 'Prompt Template (supports {{params.*}}, {{phase.<id>.<key>}}, {{primary_image}}, {{result_path}})' }),
            el('textarea', {
              className: 'ls-textarea',
              value: ph.prompt_template || '',
              on: { input: (e) => { ph.prompt_template = e.target.value; } },
            }),
          ]));

          card.appendChild(el('div', { className: 'ls-field' }, [
            el('label', { text: 'Operator Steering Override (appended at runtime — ideal for tuning Research Studio or modules)' }),
            el('textarea', {
              className: 'ls-textarea',
              style: 'min-height: 60px;',
              placeholder: 'Optional extra instructions or focus constraints appended to this phase...',
              value: ph.prompt_append || '',
              on: { input: (e) => { ph.prompt_append = e.target.value; } },
            }),
          ]));
        } else if (ph.kind === 'fifo_parallel' || ph.kind === 'fifo_pipe') {
          const tasks = ph.tasks || (ph.tasks = []);
          const fGrid = el('div', { className: 'ls-phase-grid' }, [
            el('div', { className: 'ls-field' }, [
              el('label', { text: 'FIFO Barrier Timeout (sec)' }),
              el('input', {
                className: 'ls-input',
                type: 'number',
                value: String(ph.timeout_sec || 90),
                attrs: { min: '5', max: '3600' },
                on: { input: (e) => { ph.timeout_sec = Math.max(5, parseInt(e.target.value, 10) || 90); } },
              }),
            ]),
            el('div', { className: 'ls-field' }, [
              el('label', { text: 'Continue on Tool Error' }),
              (() => {
                const s = el('select', {
                  className: 'ls-select',
                  on: { change: (e) => { ph.continue_on_error = e.target.value === 'true'; } },
                }, [
                  el('option', { value: 'true', text: 'Yes (best-effort pre-flight)' }),
                  el('option', { value: 'false', text: 'No (halt loop on failure)' }),
                ]);
                s.value = ph.continue_on_error ? 'true' : 'false';
                return s;
              })(),
            ]),
          ]);
          card.appendChild(fGrid);

          tasks.forEach((tk, tidx) => {
            const toolOptions = allToolNames.includes(tk.tool) ? allToolNames : [tk.tool, ...allToolNames].filter(Boolean);
            const toolSel = el('select', {
              className: 'ls-select',
              on: { change: (e) => { tk.tool = e.target.value; } },
            }, toolOptions.map((tn) => el('option', { value: tn, text: tn })));
            toolSel.value = tk.tool || toolOptions[0] || '';

            const argsArea = el('textarea', {
              className: 'ls-textarea',
              style: 'min-height: 54px;',
              value: JSON.stringify(tk.args_template || {}, null, 2),
              on: {
                change: (e) => {
                  try {
                    tk.args_template = JSON.parse(e.target.value || '{}');
                    setStatus('', false);
                  } catch (err) {
                    setStatus(`Invalid JSON in FIFO task '${tk.id}' args_template: ${err.message}`, true);
                  }
                },
              },
            });

            card.appendChild(el('div', { className: 'ls-fifo-task' }, [
              el('div', { className: 'ls-phase-head' }, [
                el('span', { className: 'ls-badge ls-badge-fifo', text: ph.kind === 'fifo_parallel' ? 'ASYNC FIFO' : `PIPE #${tidx + 1}` }),
                toolSel,
                el('input', {
                  className: 'ls-input',
                  placeholder: 'output_key',
                  value: tk.output_key || tk.id || '',
                  style: 'width: 140px;',
                  on: { input: (e) => { tk.output_key = e.target.value.trim(); } },
                }),
                el('input', {
                  className: 'ls-input',
                  placeholder: 'when guard (optional)',
                  value: tk.when || '',
                  style: 'width: 140px;',
                  on: { input: (e) => { tk.when = e.target.value.trim(); } },
                }),
                el('button', {
                  className: 'ls-btn ls-btn-sm',
                  text: '×',
                  on: { click: () => { tasks.splice(tidx, 1); renderEditor(); } },
                }),
              ]),
              argsArea,
            ]));
          });

          card.appendChild(el('div', {}, [
            el('button', {
              className: 'ls-btn ls-btn-amber ls-btn-sm',
              text: '+ Add FIFO Tool Task',
              on: {
                click: () => {
                  const n = tasks.length + 1;
                  tasks.push({
                    id: `task_${n}`,
                    tool: allToolNames[0] || 'file_read',
                    args_template: {},
                    output_key: `out_${n}`,
                  });
                  renderEditor();
                },
              },
            }),
          ]));
        } else if (ph.kind === 'delegate_script') {
          card.appendChild(el('div', { className: 'ls-phase-grid' }, [
            el('div', { className: 'ls-field' }, [
              el('label', { text: 'Native Handler / Module Script' }),
              el('input', {
                className: 'ls-input',
                value: ph.handler || '',
                on: { input: (e) => { ph.handler = e.target.value.trim(); } },
              }),
            ]),
          ]));
          card.appendChild(el('div', { className: 'ls-field' }, [
            el('label', { text: 'Operator Steering Notes (optional)' }),
            el('textarea', {
              className: 'ls-textarea',
              style: 'min-height: 60px;',
              value: ph.prompt_append || '',
              on: { input: (e) => { ph.prompt_append = e.target.value; } },
            }),
          ]));
        }

        // Verification Gate bar
        const gate = ph.gate || { type: 'none', path: 'result.json', required_keys: [], on_fail: 'warn', max_retries: 1 };
        const gTypeSel = el('select', {
          className: 'ls-select',
          on: {
            change: (e) => {
              const gt = e.target.value;
              if (gt === 'none') {
                delete ph.gate;
              } else {
                ph.gate = Object.assign({ path: 'result.json', required_keys: [], on_fail: 'retry', max_retries: 1 }, ph.gate || {}, { type: gt });
              }
              renderEditor();
            },
          },
        }, [
          el('option', { value: 'none', text: 'Gate: None' }),
          el('option', { value: 'json_file', text: 'Gate: Verified JSON Artifact' }),
          el('option', { value: 'markdown_file', text: 'Gate: Verified Markdown Artifact' }),
          el('option', { value: 'research_verifier', text: 'Gate: Sovereign Research Verifier' }),
        ]);
        gTypeSel.value = gate.type || 'none';

        const gateChildren = [
          el('div', { className: 'ls-phase-head' }, [
            el('span', { className: 'ls-badge ls-badge-ovr', text: 'VERIFICATION GATE' }),
            gTypeSel,
          ]),
        ];
        if (ph.gate && ph.gate.type && ph.gate.type !== 'none') {
          const onFailSel = el('select', {
            className: 'ls-select',
            on: { change: (e) => { ph.gate.on_fail = e.target.value; } },
          }, [
            el('option', { value: 'retry', text: 'On Fail: Auto-Retry ReAct' }),
            el('option', { value: 'quarantine', text: 'On Fail: Quarantine' }),
            el('option', { value: 'warn', text: 'On Fail: Warn & Continue' }),
            el('option', { value: 'fail', text: 'On Fail: Halt' }),
          ]);
          onFailSel.value = ph.gate.on_fail || 'retry';

          gateChildren.push(el('div', { className: 'ls-phase-grid' }, [
            el('div', { className: 'ls-field' }, [
              el('label', { text: 'Artifact Path' }),
              el('input', {
                className: 'ls-input',
                value: ph.gate.path || 'result.json',
                on: { input: (e) => { ph.gate.path = e.target.value.trim(); } },
              }),
            ]),
            el('div', { className: 'ls-field' }, [
              el('label', { text: 'Required JSON Keys (comma-separated)' }),
              el('input', {
                className: 'ls-input',
                value: (ph.gate.required_keys || []).join(', '),
                on: {
                  input: (e) => {
                    ph.gate.required_keys = e.target.value.split(',').map((s) => s.trim()).filter(Boolean);
                  },
                },
              }),
            ]),
            el('div', { className: 'ls-field' }, [
              el('label', { text: 'Failure Policy' }),
              onFailSel,
            ]),
          ]));
        }
        card.appendChild(el('div', { className: 'ls-gate-box' }, gateChildren));

        body.appendChild(card);
      });

      // Add Phase bar
      body.appendChild(el('div', { className: 'ls-header-actions' }, [
        el('button', {
          className: 'ls-btn ls-btn-amber',
          text: '+ Add FIFO Parallel Stage',
          on: {
            click: () => {
              phases.push({
                id: `fifo_stage_${phases.length + 1}`,
                name: `Phase ${phases.length + 1}: Parallel FIFO Pre-Flight`,
                kind: 'fifo_parallel',
                enabled: true,
                continue_on_error: true,
                timeout_sec: 90,
                tasks: [],
              });
              renderEditor();
            },
          },
        }),
        el('button', {
          className: 'ls-btn',
          text: '+ Add ReAct Phase (200 turns)',
          on: {
            click: () => {
              phases.push({
                id: `react_phase_${phases.length + 1}`,
                name: `Phase ${phases.length + 1}: ReAct Analysis`,
                kind: 'react',
                enabled: true,
                max_turns: (loop.defaults && loop.defaults.max_turns) || 200,
                tool_filter: 'default',
                tools_allow: [],
                prompt_template: '',
              });
              renderEditor();
            },
          },
        }),
        el('button', {
          className: 'ls-btn',
          text: '+ Add FIFO Pipe Stage',
          on: {
            click: () => {
              phases.push({
                id: `pipe_stage_${phases.length + 1}`,
                name: `Phase ${phases.length + 1}: Sequential FIFO Pipeline`,
                kind: 'fifo_pipe',
                enabled: true,
                continue_on_error: false,
                timeout_sec: 90,
                tasks: [],
              });
              renderEditor();
            },
          },
        }),
      ]));
    }

    function renderToolsDefaultsTab(body, loop, det) {
      const defs = loop.defaults || (loop.defaults = { max_turns: 200, ipc_priority: 100, fifo_window: 16, tool_timeout_sec: 180, output_artifact: 'result.json' });
      const tools = loop.tools || (loop.tools = { bundles: [], allow: [], deny: [] });

      body.appendChild(el('div', { className: 'ls-phase-grid' }, [
        el('div', { className: 'ls-field' }, [
          el('label', { text: 'Default Max Turns (Standard: 200)' }),
          el('input', {
            className: 'ls-input',
            type: 'number',
            value: String(defs.max_turns || 200),
            attrs: { min: '1', max: '500' },
            on: { input: (e) => { defs.max_turns = Math.max(1, Math.min(500, parseInt(e.target.value, 10) || 200)); } },
          }),
        ]),
        el('div', { className: 'ls-field' }, [
          el('label', { text: 'FIFO IPC Priority (10–100)' }),
          (() => {
            const s = el('select', {
              className: 'ls-select',
              on: { change: (e) => { defs.ipc_priority = parseInt(e.target.value, 10) || 100; } },
            }, [
              el('option', { value: '100', text: '100 — Interactive Operator' }),
              el('option', { value: '90', text: '90 — Trade / High Priority' }),
              el('option', { value: '80', text: '80 — Research / System' }),
              el('option', { value: '50', text: '50 — Scheduled Cron' }),
              el('option', { value: '20', text: '20 — Background Remediation' }),
            ]);
            s.value = String(defs.ipc_priority || 100);
            return s;
          })(),
        ]),
        el('div', { className: 'ls-field' }, [
          el('label', { text: 'FIFO Flow Window Credits' }),
          el('input', {
            className: 'ls-input',
            type: 'number',
            value: String(defs.fifo_window || 16),
            attrs: { min: '2', max: '256' },
            on: { input: (e) => { defs.fifo_window = Math.max(2, Math.min(256, parseInt(e.target.value, 10) || 16)); } },
          }),
        ]),
        el('div', { className: 'ls-field' }, [
          el('label', { text: 'Output Artifact Filename' }),
          el('input', {
            className: 'ls-input',
            value: defs.output_artifact || 'result.json',
            on: { input: (e) => { defs.output_artifact = e.target.value.trim() || 'result.json'; } },
          }),
        ]),
      ]));

      const searchIn = el('input', {
        className: 'ls-input',
        placeholder: 'Filter available tools by name...',
        value: state.toolSearch,
        on: {
          input: (e) => {
            state.toolSearch = e.target.value.trim().toLowerCase();
            renderEditor();
          },
        },
      });
      body.appendChild(el('div', { className: 'ls-field' }, [
        el('label', { text: 'Allowed Tools for This Loop (click chips to toggle)' }),
        searchIn,
      ]));

      const avail = det.available_tools || {};
      const renderChipGroup = (title, list) => {
        const filtered = (list || []).filter((t) => !state.toolSearch || t.name.toLowerCase().includes(state.toolSearch));
        if (!filtered.length) return;
        const chips = el('div', { className: 'ls-tool-chips' });
        filtered.forEach((t) => {
          const isSel = (tools.allow || []).includes(t.name);
          chips.appendChild(el('button', {
            className: 'ls-tool-chip' + (isSel ? ' selected' : ''),
            text: (isSel ? '✓ ' : '+ ') + t.name,
            title: t.description || t.name,
            on: {
              click: () => {
                const idx = tools.allow.indexOf(t.name);
                if (idx >= 0) tools.allow.splice(idx, 1);
                else tools.allow.push(t.name);
                renderEditor();
              },
            },
          }));
        });
        body.appendChild(el('div', { className: 'ls-tool-group' }, [
          el('div', { className: 'ls-sidebar-title', text: title }),
          chips,
        ]));
      };

      if ((avail.module_tools || []).length > 0) {
        renderChipGroup(`Module Tools (${det.owner})`, avail.module_tools);
      }
      renderChipGroup('Core Heartwood Tools', avail.core_tools || []);
    }

    function renderRawJsonTab(body, loop) {
      const area = el('textarea', {
        className: 'ls-textarea',
        style: 'min-height: 440px;',
        value: JSON.stringify(loop, null, 2),
      });
      body.appendChild(el('div', { className: 'ls-header-actions' }, [
        el('button', {
          className: 'ls-btn ls-btn-primary',
          text: 'Apply JSON to Visual Editor',
          on: {
            click: () => {
              try {
                state.draft = JSON.parse(area.value);
                setStatus('JSON parsed into draft. Click "Save Changes" to validate and persist.', false);
              } catch (err) {
                setStatus(`JSON syntax error: ${err.message}`, true);
              }
            },
          },
        }),
      ]));
      body.appendChild(area);
    }

    function renderRunnerTab(body, loop, det) {
      const paramInputs = {};
      const formGrid = el('div', { className: 'ls-phase-grid' });
      (loop.inputs || []).forEach((inp) => {
        if (inp.type === 'images') {
          formGrid.appendChild(el('div', { className: 'ls-field' }, [
            el('label', { text: `${inp.label} (use module panel to attach photos)` }),
            el('div', { className: 'ls-item-sub', text: 'Image upload inputs are supplied by the module UI.' }),
          ]));
          return;
        }
        let fieldEl;
        if (inp.type === 'select' && Array.isArray(inp.options)) {
          fieldEl = el('select', { className: 'ls-select' }, inp.options.map((o) => el('option', { value: o, text: o })));
          if (inp.default != null) fieldEl.value = String(inp.default);
        } else if (inp.type === 'text') {
          fieldEl = el('textarea', { className: 'ls-textarea', style: 'min-height: 70px;', placeholder: inp.placeholder || '', value: inp.default != null ? String(inp.default) : '' });
        } else {
          fieldEl = el('input', {
            className: 'ls-input',
            type: inp.type === 'number' ? 'number' : 'text',
            placeholder: inp.placeholder || '',
            value: inp.default != null ? String(inp.default) : '',
          });
        }
        paramInputs[inp.name] = { el: fieldEl, type: inp.type };
        formGrid.appendChild(el('div', { className: 'ls-field' }, [
          el('label', { text: inp.label + (inp.required ? ' *' : '') }),
          fieldEl,
        ]));
      });

      const turnsIn = el('input', {
        className: 'ls-input',
        type: 'number',
        value: String((loop.defaults && loop.defaults.max_turns) || 200),
        attrs: { min: '1', max: '500' },
      });
      formGrid.appendChild(el('div', { className: 'ls-field' }, [
        el('label', { text: 'Max Turns for This Run' }),
        turnsIn,
      ]));

      const streamBox = el('div', { style: 'margin-top: 10px;' });
      const launchBtn = el('button', {
        className: 'ls-btn ls-btn-primary',
        text: `Launch ${det.owner}/${det.id}`,
        on: {
          click: async () => {
            const params = {};
            Object.entries(paramInputs).forEach(([k, info]) => {
              const raw = info.el.value;
              if (raw === '' || raw == null) return;
              params[k] = info.type === 'number' ? Number(raw) : raw;
            });
            const mt = Math.max(1, Math.min(500, parseInt(turnsIn.value, 10) || 200));
            setStatus(`Launching ${det.owner}/${det.id} (max_turns=${mt})...`, false);
            const r = await fetch(`/api/loops/${encodeURIComponent(det.owner)}/${encodeURIComponent(det.id)}/run`, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ params, max_turns: mt }),
            });
            const d = await r.json().catch(() => ({}));
            if (!r.ok || d.status !== 'ok') {
              setStatus(d.message || 'Launch failed', true);
              return;
            }
            setStatus(`Running task ${d.task_id} (max_turns=${d.max_turns}) — streaming live below & in Task Bay.`, false);
            streamBox.replaceChildren();
            const pre = el('pre', {
              className: 'ls-textarea',
              style: 'min-height: 260px; max-height: 420px; overflow-y: auto; white-space: pre-wrap;',
              text: `[Connected to ${d.stream_url}]\n`,
            });
            streamBox.appendChild(pre);
            try {
              const es = new EventSource(d.stream_url);
              es.onmessage = (ev) => {
                pre.textContent += ev.data + '\n';
                pre.scrollTop = pre.scrollHeight;
              };
              es.addEventListener('done', () => {
                pre.textContent += '\n[Loop completed]\n';
                es.close();
              });
              es.onerror = () => { es.close(); };
            } catch (_) {}
          },
        },
      });

      body.appendChild(formGrid);
      body.appendChild(el('div', { className: 'ls-header-actions' }, [launchBtn]));
      body.appendChild(streamBox);
    }

    fetchLoopsList();
    return { reload: fetchLoopsList };
  }

  function openModal(options) {
    const opts = options || {};
    const existing = document.getElementById('lodgeLoopStudioModal');
    if (existing) existing.remove();

    const backdrop = el('div', { id: 'lodgeLoopStudioModal', className: 'ls-modal-backdrop' });
    const dialog = el('div', { className: 'ls-modal-dialog' });
    const closeBtn = el('button', {
      className: 'ls-btn ls-btn-sm',
      text: '✕ Close',
      on: { click: () => backdrop.remove() },
    });
    const bar = el('div', { className: 'ls-modal-bar' }, [
      el('span', { className: 'ls-modal-title', text: opts.title || 'Sovereign Agentic Loop Studio (ALP v1)' }),
      closeBtn,
    ]);
    const content = el('div', { className: 'ls-modal-content' });
    dialog.appendChild(bar);
    dialog.appendChild(content);
    backdrop.appendChild(dialog);
    backdrop.addEventListener('click', (e) => { if (e.target === backdrop) backdrop.remove(); });
    document.body.appendChild(backdrop);

    mountStudio(content, opts);
  }

  window.LodgeLoopStudio = {
    mount: mountStudio,
    openModal: openModal,
    reloadGlobal: function () {
      const host = document.getElementById('loopStudioGlobalHost');
      if (host) mountStudio(host, {});
    },
  };
})();
