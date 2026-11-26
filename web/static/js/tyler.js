/**
 * THE TYLER // HOME NETWORK DEFENSE, KALI FORTRESS & WI-FI RF MESH COCKPIT
 * Sovereign Security & Spatial RF Tomography Interface
 *
 * Security Compliance:
 * - Zero innerHTML / outerHTML / insertAdjacentHTML / document.write
 * - All DOM & SVG elements built with createElement / createElementNS + textContent
 */
(function () {
  'use strict';

  const SVG_NS = 'http://www.w3.org/2000/svg';

  const LIVE_SYNC_INTERVAL_MS = 15000;

  const state = {
    lastStatus: null,
    lastActionReport: null,
    lastActionLabel: '',
    lastActionPayload: null,
    activeTab: 'mesh',
    deviceFilter: 'all',
    selectedDeviceIp: '',
    selectedCorridorKey: '',
    rawConsoleVisible: false,
    guideOpen: false,
    liveSyncEnabled: true,
    liveSyncNextAt: 0,
    liveSyncFetching: false,
    actionInFlight: false,
    liveSyncTimerId: null,
    initialized: false
  };

  // --- Safe DOM & SVG Builders ---
  function el(tag, className, text, attrs) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = String(text);
    if (attrs) {
      Object.entries(attrs).forEach(([k, v]) => {
        if (v !== undefined && v !== null) node.setAttribute(k, String(v));
      });
    }
    return node;
  }

  function svgEl(tag, attrs, text) {
    const node = document.createElementNS(SVG_NS, tag);
    if (attrs) {
      Object.entries(attrs).forEach(([k, v]) => {
        if (v !== undefined && v !== null) node.setAttribute(k, String(v));
      });
    }
    if (text !== undefined && text !== null) node.textContent = String(text);
    return node;
  }

  function clearNode(node) {
    if (node) node.replaceChildren();
  }

  function fmtTime(isoStr) {
    if (!isoStr) return '—';
    try {
      const num = Number(isoStr);
      const d = !Number.isNaN(num) && num > 1000000000 && num < 100000000000
        ? new Date(num * 1000)
        : new Date(isoStr);
      if (Number.isNaN(d.getTime())) return String(isoStr);
      return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
    } catch (_e) {
      return String(isoStr);
    }
  }

  function fmtSignedDb(val) {
    if (val === undefined || val === null || Number.isNaN(Number(val))) return '0.0 dB';
    const n = Number(val);
    return `${n >= 0 ? '+' : ''}${n.toFixed(1)} dB`;
  }

  function getChordKey(rc) {
    if (!rc) return '';
    return String(rc.chord_id || rc.corridor_key || rc.zone || rc.label || '');
  }

  function getChordDriftDb(rc) {
    if (!rc) return null;
    if (rc.baseline_drift_db !== undefined && rc.baseline_drift_db !== null) {
      return Number(rc.baseline_drift_db);
    }
    if (rc.last_rssi_dbm !== undefined && rc.last_rssi_dbm !== null &&
        rc.baseline_rssi_dbm !== undefined && rc.baseline_rssi_dbm !== null) {
      return Number((Number(rc.last_rssi_dbm) - Number(rc.baseline_rssi_dbm)).toFixed(1));
    }
    return null;
  }

  // --- Workspace Navigation & Toggles ---
  function switchTylerTab(tabId) {
    state.activeTab = tabId || 'mesh';
    const tabs = document.querySelectorAll('[data-tyler-tab]');
    tabs.forEach((btn) => {
      const t = btn.getAttribute('data-tyler-tab');
      btn.classList.toggle('active', t === state.activeTab);
    });

    const workspaces = document.querySelectorAll('.tyler-workspace-pane');
    workspaces.forEach((pane) => {
      const paneId = pane.getAttribute('data-tyler-workspace');
      if (state.activeTab === 'all') {
        pane.classList.add('active');
      } else {
        pane.classList.toggle('active', paneId === state.activeTab);
      }
    });
    if (state.activeTab === 'reputation' || state.activeTab === 'all') {
      loadReputationData(state.repFilterUid || '');
    }
  }

  function toggleGuideDrawer() {
    state.guideOpen = !state.guideOpen;
    const drawer = document.getElementById('tylerOperatorGuideDrawer');
    const btn = document.getElementById('btnTylerGuideToggle');
    if (drawer) drawer.classList.toggle('open', state.guideOpen);
    if (btn) btn.classList.toggle('active', state.guideOpen);
  }

  function toggleRawConsole(forceState) {
    state.rawConsoleVisible = typeof forceState === 'boolean' ? forceState : !state.rawConsoleVisible;
    const pre = document.getElementById('tylerConsoleOutput');
    const btn = document.getElementById('btnTylerToggleRawJson');
    if (pre) {
      pre.style.display = state.rawConsoleVisible ? 'block' : 'none';
    }
    if (btn) {
      btn.textContent = state.rawConsoleVisible ? '◈ HIDE RAW JSON' : '{ } VIEW RAW JSON';
      btn.classList.toggle('active', state.rawConsoleVisible);
    }
  }

  // --- Compass-Calibrated Spatial Mapping (generic defaults; overridden by .george/config/tyler_household.json room_layout) ---
  let ROOM_LAYOUT = [
    {
      id: 'hub_workstation',
      label: 'Workstation Hub',
      sub: 'NW Study • Primary Host',
      wing: 'NORTH-WEST STUDY',
      x: 205,
      y: 175,
      isHub: true,
      hubColor: '#38bdf8'
    },
    {
      id: 'zone_study',
      label: 'Study Peripheral',
      matchKeys: ['Study Span', 'Printer'],
      wing: 'NORTH-WEST STUDY',
      x: 205,
      y: 268,
      pillT: 0.52,
      hubId: 'hub_workstation'
    },
    {
      id: 'zone_kitchen_appliance',
      label: 'Kitchen Appliance',
      matchKeys: ['Kitchen / Appliance Span', '[fridge]'],
      wing: 'CENTRAL CORE',
      x: 345,
      y: 305,
      pillT: 0.52,
      hubId: 'hub_workstation'
    },
    {
      id: 'zone_kitchen_display',
      label: 'Kitchen Display',
      matchKeys: ['Kitchen Display', '192.168.1.34'],
      wing: 'CENTRAL CORE',
      x: 350,
      y: 382,
      pillT: 0.56,
      pillDy: -8,
      hubId: 'hub_root'
    },
    {
      id: 'hub_root',
      label: 'Mesh Root Router',
      sub: 'Gateway • 2.4+5GHz Core',
      matchKeys: ['Root Router Corridor'],
      wing: 'CENTRAL CORE',
      x: 490,
      y: 215,
      pillT: 0.48,
      pillDy: 12,
      isHub: true,
      hubColor: '#10b981',
      hubId: 'hub_workstation'
    },
    {
      id: 'zone_living',
      label: 'Living Room Speaker',
      matchKeys: ['Living Room', '192.168.1.37'],
      wing: 'CENTRAL CORE',
      x: 490,
      y: 138,
      pillT: 0.46,
      hubId: 'hub_root'
    },
    {
      id: 'zone_media',
      label: 'Media Display',
      matchKeys: ['Media Display', '192.168.1.40'],
      wing: 'CENTRAL CORE',
      x: 495,
      y: 382,
      pillT: 0.52,
      hubId: 'hub_root'
    },
    {
      id: 'hub_leaf',
      label: 'Mesh Leaf Node',
      sub: 'Mesh Backhaul Node',
      matchKeys: ['Leaf Router Corridor'],
      wing: 'SOUTH-EAST WING',
      x: 655,
      y: 265,
      pillT: 0.62,
      pillDy: -14,
      isHub: true,
      hubColor: '#38bdf8',
      hubId: 'hub_workstation'
    },
    {
      id: 'zone_south_sensor',
      label: 'South Wall Sensor',
      sub: 'SOUTH WALL [Sensor B]',
      matchKeys: ['South Wall'],
      wing: 'SOUTH WALL',
      x: 645,
      y: 386,
      pillT: 0.68,
      pillDy: 12,
      isSensorB: true,
      hubId: 'hub_workstation'
    },
    {
      id: 'zone_east_room',
      label: 'East Wing Node',
      matchKeys: ['East Wing', '192.168.1.32'],
      wing: 'SOUTH-EAST WING',
      x: 790,
      y: 215,
      pillT: 0.50,
      hubId: 'hub_leaf'
    },
    {
      id: 'zone_south_room',
      label: 'South Wing Node',
      matchKeys: ['South Wing', '192.168.1.36'],
      wing: 'SOUTH WALL',
      x: 795,
      y: 365,
      pillT: 0.52,
      hubId: 'hub_leaf'
    }
  ];

  function isExteriorPerimeterChord(rc) {
    if (!rc) return false;
    return String(rc.ring || '') === 'exterior_perimeter' || String(rc.chord_id || '').startsWith('perim_wifi_');
  }

  function matchCorridorToNode(rc) {
    if (!rc || isExteriorPerimeterChord(rc)) return null;
    const z = String(rc.zone || '').toLowerCase();
    const lbl = String(rc.label || '').toLowerCase();
    const key = getChordKey(rc).toLowerCase();
    for (const node of ROOM_LAYOUT) {
      if (!node.matchKeys) continue;
      for (const mk of node.matchKeys) {
        const mkl = mk.toLowerCase();
        if (z.includes(mkl) || lbl.includes(mkl) || key.includes(mkl)) {
          return node;
        }
      }
    }
    return null;
  }

  function buildExteriorPerimeterNodes(telemetry) {
    const extChords = (Array.isArray(telemetry) ? telemetry : []).filter(isExteriorPerimeterChord);
    const northList = [];
    const southList = [];
    const flankList = [];
    extChords.forEach((rc) => {
      const sec = String(rc.compass_sector || 'EAST_WEST_FLANK').toUpperCase();
      if (sec === 'NORTH') northList.push(rc);
      else if (sec === 'SOUTH' || sec === 'SOUTH_WALL') southList.push(rc);
      else flankList.push(rc);
    });

    const placed = [];
    const makeNode = (rc, sec, x, y, curveSign) => {
      const rawName = String(rc.tx_node || rc.zone || rc.chord_id || 'Perimeter AP')
        .replace(/^Perimeter\s+\w+\s+\(/i, '')
        .replace(/\)$/, '');
      return {
        id: `ext_${getChordKey(rc)}`,
        label: rawName.slice(0, 18),
        sub: `${sec.replace(/_/g, ' ')} • ${rc.band || '2.4 GHz'}`,
        wing: sec,
        x: Math.round(x),
        y: Math.round(y),
        pillT: 0.44,
        curveSign,
        hubId: sec === 'SOUTH' ? 'zone_south_sensor' : 'hub_workstation',
        isPerimeter: true,
        compassSector: sec,
        rc
      };
    };

    // Evenly space exterior anchors dynamically across the perimeter band so nodes never overlap
    northList.forEach((rc, i) => {
      const span = 720;
      const x = 130 + ((i + 1) * span) / (northList.length + 1);
      const y = 54 + (i % 2 === 0 ? -4 : 8);
      placed.push(makeNode(rc, 'NORTH', x, y, i % 2 === 0 ? -1 : 1));
    });
    southList.forEach((rc, i) => {
      const span = 680;
      const x = 150 + ((i + 1) * span) / (southList.length + 1);
      const y = 492 + (i % 2 === 0 ? 4 : -6);
      placed.push(makeNode(rc, 'SOUTH', x, y, i % 2 === 0 ? 1 : -1));
    });
    flankList.forEach((rc, i) => {
      const leftSide = i % 2 === 0;
      const sideIdx = Math.floor(i / 2);
      const sideCount = Math.max(1, Math.ceil(flankList.length / 2));
      const x = leftSide ? 76 : 904;
      const y = 148 + ((sideIdx + 1) * 265) / (sideCount + 1);
      placed.push(makeNode(rc, String(rc.compass_sector || 'EAST_WEST_FLANK').toUpperCase(), x, y, leftSide ? -1 : 1));
    });
    return placed;
  }

  // --- Interactive 2D Spatial RF Mesh & Compass Perimeter Radar ---
  function renderMeshRadarSvg(data) {
    const container = document.getElementById('tylerMeshRadarContainer');
    if (!container) return;
    clearNode(container);

    const telemetry = Array.isArray(data.peripheral_rf_telemetry) ? data.peripheral_rf_telemetry : [];
    const motionEvents = Array.isArray(data.rf_motion_events) ? data.rf_motion_events : [];

    // Update Situational Movement Banner
    renderMeshSituationBanner(telemetry, motionEvents, data);

    const svg = svgEl('svg', {
      viewBox: '0 0 980 540',
      class: 'tyler-radar-svg',
      role: 'img',
      'aria-label': 'Compass-Calibrated Property Perimeter and Household Fresnel RF Radar'
    });

    // Definitions for gradients and glow filters
    const defs = svgEl('defs');
    const glowFilter = svgEl('filter', { id: 'tylerGlow', x: '-30%', y: '-30%', width: '160%', height: '160%' });
    glowFilter.appendChild(svgEl('feGaussianBlur', { stdDeviation: '4', result: 'blur' }));
    const feMerge = svgEl('feMerge');
    feMerge.appendChild(svgEl('feMergeNode', { in: 'blur' }));
    feMerge.appendChild(svgEl('feMergeNode', { in: 'SourceGraphic' }));
    glowFilter.appendChild(feMerge);
    defs.appendChild(glowFilter);

    // Arrowhead marker for movement trail
    const marker = svgEl('marker', {
      id: 'tylerTrailArrow',
      viewBox: '0 0 10 10',
      refX: '7',
      refY: '5',
      markerWidth: '6',
      markerHeight: '6',
      orient: 'auto-start-reverse'
    });
    marker.appendChild(svgEl('path', { d: 'M 0 1 L 10 5 L 0 9 z', fill: '#f59e0b' }));
    defs.appendChild(marker);
    svg.appendChild(defs);

    // Outer Compass Perimeter Ring + Interior Household Envelope
    const zones = [
      { title: '▲ NORTH EXTERIOR PERIMETER // NORTH REFERENCE & YARD CHORDS', x: 18, y: 12, w: 944, h: 78, stroke: 'rgba(168, 85, 247, 0.28)', fill: 'rgba(30, 17, 54, 0.22)' },
      { title: 'HOUSEHOLD INTERIOR // NW STUDY (WORKSTATION) • CENTRAL CORE (NEST ROOT) • SOUTH WALL (LENOVO SMART CLOCK)', x: 120, y: 98, w: 740, h: 334, stroke: 'rgba(56, 189, 248, 0.22)', fill: 'rgba(15, 23, 42, 0.50)' },
      { title: '▼ SOUTH WALL & SOUTH EXTERIOR PERIMETER // LENOVO CLOCK SENSOR B & SOUTH FLANK', x: 18, y: 440, w: 944, h: 88, stroke: 'rgba(16, 185, 129, 0.25)', fill: 'rgba(6, 38, 32, 0.20)' }
    ];
    zones.forEach((w) => {
      svg.appendChild(svgEl('rect', {
        x: w.x,
        y: w.y,
        width: w.w,
        height: w.h,
        rx: '8',
        fill: w.fill,
        stroke: w.stroke,
        'stroke-dasharray': '4 4'
      }));
      svg.appendChild(svgEl('text', {
        x: w.x + 12,
        y: w.y + 16,
        fill: '#94a3b8',
        'font-size': '9.2',
        'font-weight': '700',
        'font-family': 'monospace',
        'letter-spacing': '0.07em'
      }, w.title));
    });

    // Map node lookup (Interior + Dynamic Exterior Perimeter Nodes)
    const extNodes = buildExteriorPerimeterNodes(telemetry);
    const allNodes = ROOM_LAYOUT.concat(extNodes);
    const nodeById = {};
    allNodes.forEach((n) => { nodeById[n.id] = n; });

    // 6 GHz Nest Wifi Pro Backhaul Link (Root <-> Leaf)
    const rootNode = nodeById.hub_root;
    const leafNode = nodeById.hub_leaf;
    if (rootNode && leafNode) {
      svg.appendChild(svgEl('line', {
        x1: rootNode.x,
        y1: rootNode.y,
        x2: leafNode.x,
        y2: leafNode.y,
        stroke: 'rgba(16, 185, 129, 0.35)',
        'stroke-width': '3',
        'stroke-dasharray': '8 4'
      }));
      svg.appendChild(svgEl('text', {
        x: (rootNode.x + leafNode.x) / 2,
        y: rootNode.y - 10,
        fill: '#6ee7b7',
        'font-size': '9',
        'font-family': 'monospace',
        'text-anchor': 'middle'
      }, '6 GHz MESH BACKHAUL (Ch.197)'));
    }

    // Bind telemetry chords to room layout nodes (prefer disturbed or 5GHz/highest swing when concentric)
    const nodeTelemetryMap = {};
    const statusRank = { motion_detected: 3, presence_shift: 2, quiet: 1 };
    telemetry.forEach((rc) => {
      if (isExteriorPerimeterChord(rc)) return;
      const matched = matchCorridorToNode(rc);
      if (matched) {
        const cur = nodeTelemetryMap[matched.id];
        if (!cur || (statusRank[rc.motion_state] || 0) > (statusRank[cur.motion_state] || 0) ||
            Number(rc.p2p_swing_db || 0) > Number(cur.p2p_swing_db || 0)) {
          nodeTelemetryMap[matched.id] = rc;
        }
      }
    });
    extNodes.forEach((en) => {
      nodeTelemetryMap[en.id] = en.rc;
    });

    // Determine single-chord neighbor suppression state per exterior sector
    const disturbedExtBySector = {};
    const anyInteriorDisturbed = telemetry.some((c) => !isExteriorPerimeterChord(c) && (c.motion_state === 'motion_detected' || c.motion_state === 'presence_shift'));
    extNodes.forEach((en) => {
      const st = String(en.rc.motion_state || 'quiet');
      if (st === 'motion_detected' || st === 'presence_shift') {
        const sec = en.compassSector || 'EAST_WEST_FLANK';
        disturbedExtBySector[sec] = (disturbedExtBySector[sec] || 0) + 1;
      }
    });

    // Draw Fresnel Sensing Corridors with curved Bezier separation + pill collision avoidance
    const disturbedNodes = [];
    const placedPills = [];
    const nodeObstacles = allNodes.map((n) => ({ x: n.x, y: n.y, r: n.isHub ? 36 : 28 }));

    function resolvePillPosition(cx, cy, pillW, pillH) {
      const candidates = [
        [0, 0], [0, -22], [0, 22], [28, -16], [-28, -16],
        [28, 16], [-28, 16], [0, -40], [0, 40], [46, 0], [-46, 0]
      ];
      for (const [ox, oy] of candidates) {
        const px = Math.max(46, Math.min(934, cx + ox));
        const py = Math.max(24, Math.min(516, cy + oy));
        const box = { x1: px - pillW / 2 - 4, y1: py - pillH / 2 - 3, x2: px + pillW / 2 + 4, y2: py + pillH / 2 + 3 };
        const hitsPill = placedPills.some((p) => !(box.x2 < p.x1 || box.x1 > p.x2 || box.y2 < p.y1 || box.y1 > p.y2));
        const hitsNode = nodeObstacles.some((n) => Math.hypot(px - n.x, py - n.y) < n.r);
        if (!hitsPill && !hitsNode) {
          placedPills.push(box);
          return { x: px, y: py };
        }
      }
      const fallback = { x: Math.max(46, Math.min(934, cx)), y: Math.max(24, Math.min(516, cy)) };
      placedPills.push({ x1: fallback.x - pillW / 2, y1: fallback.y - pillH / 2, x2: fallback.x + pillW / 2, y2: fallback.y + pillH / 2 });
      return fallback;
    }

    let chordIdx = 0;
    allNodes.forEach((node) => {
      const rc = nodeTelemetryMap[node.id];
      if (!rc) return;
      chordIdx += 1;

      const sourceHub = nodeById[node.hubId || 'hub_workstation'] || nodeById.zone_clock || nodeById.hub_workstation;
      const x1 = sourceHub.x;
      const y1 = sourceHub.y;
      const x2 = node.x;
      const y2 = node.y;
      const dx = x2 - x1;
      const dy = y2 - y1;
      const dist = Math.max(1, Math.hypot(dx, dy));
      const angleDeg = (Math.atan2(dy, dx) * 180) / Math.PI;

      // Subtle perpendicular Bezier bow prevents overlapping straight beams
      const nx = -dy / dist;
      const ny = dx / dist;
      const sign = node.curveSign || (chordIdx % 2 === 0 ? 1 : -1);
      const bow = Math.min(34, Math.max(12, dist * 0.085)) * sign;
      const ctrlX = (x1 + x2) / 2 + nx * bow;
      const ctrlY = (y1 + y2) / 2 + ny * bow;

      const t = node.pillT || 0.50;
      const mt = 1 - t;
      const rawMx = mt * mt * x1 + 2 * mt * t * ctrlX + t * t * x2;
      const rawMy = mt * mt * y1 + 2 * mt * t * ctrlY + t * t * y2 + (node.pillDy || 0);

      const mState = String(rc.motion_state || 'quiet');
      const isMotion = mState === 'motion_detected';
      const isShift = mState === 'presence_shift';
      const isSuppressedNeighbor = Boolean(
        node.isPerimeter && (isMotion || isShift) &&
        (disturbedExtBySector[node.compassSector] || 0) < 2 && !anyInteriorDisturbed
      );
      const cKey = getChordKey(rc);
      const driftDb = getChordDriftDb(rc);

      const chordGroup = svgEl('g', {
        class: 'tyler-radar-node',
        'data-corridor-key': cKey
      });

      // Physical wavelength-scaled Fresnel Zone Ellipse (only on disturbed or selected chords to minimize clutter)
      const is5Ghz = String(rc.band || '').includes('5');
      const baseRy = is5Ghz ? 13 : 19;
      const isSelected = Boolean(state.selectedCorridorKey && state.selectedCorridorKey === cKey);
      if (isMotion || isShift || isSelected) {
        const ellFill = isSuppressedNeighbor
          ? 'rgba(167, 139, 250, 0.10)'
          : isMotion
            ? 'rgba(239, 68, 68, 0.16)'
            : isShift
              ? 'rgba(245, 158, 11, 0.13)'
              : 'rgba(56, 189, 248, 0.11)';
        const ellStroke = isSuppressedNeighbor
          ? 'rgba(167, 139, 250, 0.50)'
          : isMotion
            ? 'rgba(239, 68, 68, 0.55)'
            : isShift
              ? 'rgba(245, 158, 11, 0.45)'
              : 'rgba(56, 189, 248, 0.4)';

        chordGroup.appendChild(svgEl('ellipse', {
          cx: (x1 + x2) / 2,
          cy: (y1 + y2) / 2,
          rx: Math.max(36, dist * 0.40),
          ry: isMotion ? baseRy + 4 : baseRy,
          transform: `rotate(${angleDeg} ${(x1 + x2) / 2} ${(y1 + y2) / 2})`,
          fill: ellFill,
          stroke: ellStroke,
          'stroke-width': isSelected ? '1.8' : '1.1',
          'stroke-dasharray': isSuppressedNeighbor ? '2 4' : (isMotion ? '5 3' : '3 3')
        }));
      }

      // Main Curved Fresnel Chord Path
      let strokeCol = node.isPerimeter ? 'rgba(168, 85, 247, 0.34)' : 'rgba(56, 189, 248, 0.36)';
      let lineClass = 'tyler-chord-quiet';
      if (isSuppressedNeighbor) {
        strokeCol = '#a78bfa';
        lineClass = 'tyler-chord-shift';
      } else if (isMotion) {
        strokeCol = '#ef4444';
        lineClass = 'tyler-chord-motion';
      } else if (isShift) {
        strokeCol = '#f59e0b';
        lineClass = 'tyler-chord-shift';
      }

      chordGroup.appendChild(svgEl('path', {
        d: `M ${x1} ${y1} Q ${ctrlX.toFixed(1)} ${ctrlY.toFixed(1)} ${x2} ${y2}`,
        fill: 'none',
        stroke: strokeCol,
        class: lineClass
      }));

      // Collision-free Telemetry Pill along the curved chord
      const metricText = rc.last_rssi_dbm != null
        ? `${rc.last_rssi_dbm} dBm${driftDb ? ` (${fmtSignedDb(driftDb)})` : ''}`
        : rc.last_rtt_ms != null
          ? `RTT ${rc.last_rtt_ms} ms`
          : 'Quiet';

      const pillW = Math.max(72, metricText.length * 5.6 + 12);
      const pillPos = resolvePillPosition(rawMx, rawMy, pillW, 18);
      const mx = pillPos.x;
      const my = pillPos.y;

      if ((isMotion || isShift) && !isSuppressedNeighbor) {
        disturbedNodes.push({ node, rc, mx, my });
      }

      // Concentric Pulse Rings at corridor midpoint on corroborated active motion
      if (isMotion && !isSuppressedNeighbor) {
        chordGroup.appendChild(svgEl('circle', {
          cx: mx,
          cy: my,
          r: '14',
          fill: 'none',
          stroke: '#ef4444',
          'stroke-width': '2',
          class: 'tyler-motion-pulse-ring'
        }));
      }

      chordGroup.appendChild(svgEl('rect', {
        x: mx - pillW / 2,
        y: my - 9,
        width: pillW,
        height: '18',
        rx: '9',
        fill: 'rgba(9, 13, 22, 0.94)',
        stroke: strokeCol,
        'stroke-width': '1'
      }));
      chordGroup.appendChild(svgEl('text', {
        x: mx,
        y: my + 3.5,
        fill: isSuppressedNeighbor ? '#ddd6fe' : isMotion ? '#fca5a5' : isShift ? '#fde68a' : '#bae6fd',
        'font-size': '8.8',
        'font-family': 'monospace',
        'font-weight': '700',
        'text-anchor': 'middle'
      }, metricText));

      chordGroup.addEventListener('click', () => {
        selectCorridor(rc);
      });

      svg.appendChild(chordGroup);
    });

    // Plot Chronological Movement Trail (① -> ② -> ③) across disturbed zones or recent motion events
    const trailNodes = buildMovementSequence(disturbedNodes, motionEvents);
    if (trailNodes.length >= 2) {
      for (let i = 0; i < trailNodes.length - 1; i++) {
        const a = trailNodes[i];
        const b = trailNodes[i + 1];
        const cpx = (a.x + b.x) / 2;
        const cpy = Math.min(a.y, b.y) - 32;
        svg.appendChild(svgEl('path', {
          d: `M ${a.x} ${a.y} Q ${cpx} ${cpy} ${b.x} ${b.y}`,
          fill: 'none',
          stroke: '#f59e0b',
          'stroke-width': '2',
          'stroke-dasharray': '6 4',
          'marker-end': 'url(#tylerTrailArrow)',
          opacity: '0.85'
        }));
      }
    }

    // Draw Room, Hub & Exterior Perimeter Nodes on top of chords
    allNodes.forEach((node) => {
      const rc = nodeTelemetryMap[node.id];
      const mState = rc ? String(rc.motion_state || 'quiet') : 'quiet';
      const isMotion = mState === 'motion_detected';
      const isShift = mState === 'presence_shift';
      const isSuppressedNeighbor = Boolean(
        node.isPerimeter && (isMotion || isShift) &&
        (disturbedExtBySector[node.compassSector] || 0) < 2 && !anyInteriorDisturbed
      );
      const isSelected = Boolean(rc && state.selectedCorridorKey === getChordKey(rc));
      const driftDb = getChordDriftDb(rc);

      const g = svgEl('g', { class: 'tyler-radar-node' });

      let borderCol = node.isHub
        ? (node.hubColor || '#38bdf8')
        : node.isPerimeter
          ? 'rgba(168, 85, 247, 0.55)'
          : 'rgba(148, 163, 184, 0.45)';
      let fillCol = node.isHub ? 'rgba(15, 23, 42, 0.96)' : 'rgba(15, 23, 42, 0.9)';
      if (isSuppressedNeighbor) {
        borderCol = '#a78bfa';
        fillCol = 'rgba(46, 16, 101, 0.88)';
      } else if (isMotion) {
        borderCol = '#ef4444';
        fillCol = 'rgba(69, 10, 10, 0.92)';
      } else if (isShift) {
        borderCol = '#f59e0b';
        fillCol = 'rgba(69, 26, 3, 0.9)';
      } else if (node.isSensorB) {
        borderCol = '#10b981';
      }

      const boxW = node.isHub || node.isSensorB ? 166 : 148;
      const boxH = node.sub ? 42 : 34;

      g.appendChild(svgEl('rect', {
        x: node.x - boxW / 2,
        y: node.y - boxH / 2,
        width: boxW,
        height: boxH,
        rx: '7',
        fill: fillCol,
        stroke: borderCol,
        'stroke-width': isSelected || node.isHub ? '2' : '1.3',
        filter: ((isMotion || isShift) && !isSuppressedNeighbor) || isSelected ? 'url(#tylerGlow)' : null
      }));

      // Status Dot inside node
      const dotCol = isSuppressedNeighbor
        ? '#a78bfa'
        : isMotion
          ? '#ef4444'
          : isShift
            ? '#f59e0b'
            : node.isHub
              ? '#10b981'
              : node.isPerimeter
                ? '#c084fc'
                : '#38bdf8';
      g.appendChild(svgEl('circle', {
        cx: node.x - boxW / 2 + 12,
        cy: node.y - (node.sub ? 6 : 0),
        r: '4.5',
        fill: dotCol
      }));

      // Node Primary Title
      g.appendChild(svgEl('text', {
        x: node.x - boxW / 2 + 23,
        y: node.y - (node.sub ? 2 : -4),
        fill: '#f8fafc',
        'font-size': '10.2',
        'font-weight': '700',
        'font-family': 'sans-serif'
      }, node.label));

      // Node Subtitle or Live State
      const subStr = isSuppressedNeighbor
        ? `1-CHORD SUPPRESSED (${fmtSignedDb(driftDb)})`
        : node.sub
          ? node.sub
          : rc
            ? `${mState.replace('_', ' ').toUpperCase()}${driftDb ? ` • Δ ${fmtSignedDb(driftDb)}` : ''}`
            : 'STANDBY';
      g.appendChild(svgEl('text', {
        x: node.x - boxW / 2 + 23,
        y: node.y + 11,
        fill: isSuppressedNeighbor ? '#ddd6fe' : isMotion ? '#fca5a5' : isShift ? '#fde68a' : '#94a3b8',
        'font-size': '8.5',
        'font-family': 'monospace'
      }, subStr));

      g.addEventListener('click', () => {
        if (rc) {
          selectCorridor(rc);
        }
      });

      svg.appendChild(g);
    });

    // Draw Movement Sequence Step Badges (①, ②, ③)
    trailNodes.forEach((tn, idx) => {
      const badgeG = svgEl('g');
      badgeG.appendChild(svgEl('circle', {
        cx: tn.x + 68,
        cy: tn.y - 18,
        r: '10',
        fill: '#f59e0b',
        stroke: '#090d16',
        'stroke-width': '2'
      }));
      badgeG.appendChild(svgEl('text', {
        x: tn.x + 68,
        y: tn.y - 14.5,
        fill: '#090d16',
        'font-size': '10',
        'font-weight': '800',
        'font-family': 'monospace',
        'text-anchor': 'middle'
      }, String(idx + 1)));
      svg.appendChild(badgeG);
    });

    container.appendChild(svg);
  }

  function buildMovementSequence(disturbedNodes, motionEvents) {
    const seq = [];
    const seenIds = new Set();

    // First look at chronological motion events if available
    if (Array.isArray(motionEvents) && motionEvents.length > 0) {
      const recent = motionEvents.slice(0, 5).reverse();
      recent.forEach((ev) => {
        const matched = matchCorridorToNode(ev);
        if (matched && !seenIds.has(matched.id)) {
          seenIds.add(matched.id);
          seq.push(matched);
        }
      });
    }

    // Also include currently disturbed corridors ordered by magnitude of drift
    const sortedDisturbed = disturbedNodes
      .slice()
      .sort((a, b) => Math.abs(Number(a.rc.baseline_drift_db || 0)) - Math.abs(Number(b.rc.baseline_drift_db || 0)));
    sortedDisturbed.forEach((d) => {
      if (!seenIds.has(d.node.id)) {
        seenIds.add(d.node.id);
        seq.push(d.node);
      }
    });

    return seq;
  }

  function renderMeshSituationBanner(telemetry, motionEvents, data) {
    const banner = document.getElementById('tylerMeshSituationText');
    const subBanner = document.getElementById('tylerMeshSituationSub');
    const dot = document.getElementById('tylerMeshSituationDot');
    if (!banner) return;

    const motionZones = telemetry.filter((c) => c.motion_state === 'motion_detected');
    const shiftZones = telemetry.filter((c) => c.motion_state === 'presence_shift');

    if (motionZones.length > 0 || shiftZones.length > 0) {
      const parts = [];
      if (motionZones.length > 0) {
        const mNames = motionZones.map((z) => {
          const metric = z.p2p_swing_db ? `Δ${z.p2p_swing_db}dB` : (z.last_rtt_ms != null ? `RTT ${z.last_rtt_ms}ms` : 'active');
          return `${z.zone} [MOTION: ${metric}]`;
        }).join(', ');
        parts.push(mNames);
      }
      if (shiftZones.length > 0) {
        const sNames = shiftZones.map((z) => {
          const dDb = getChordDriftDb(z);
          const metric = dDb != null ? `${fmtSignedDb(dDb)} drift` : (z.last_rtt_ms != null ? `RTT ${z.last_rtt_ms}ms` : 'shift');
          return `${z.zone} [SHIFT: ${metric}]`;
        }).join(' → ');
        parts.push(sNames);
      }
      banner.textContent = `ACTIVE RF DISTURBANCES (${motionZones.length + shiftZones.length} CORRIDORS): ${parts.join(' • ')}`;
      if (dot) dot.className = motionZones.length > 0 ? 'tyler-pulse-dot danger' : 'tyler-pulse-dot warn';
    } else if (telemetry.length > 0) {
      banner.textContent = `ALL ${telemetry.length} RF MESH CORRIDORS NOMINAL (QUIET FRESNEL BASELINE)`;
      if (dot) dot.className = 'tyler-pulse-dot';
    } else {
      banner.textContent = 'RF Mesh telemetry standing by — click "Sense RF Motion (6s)" or "Poll LAN Cast Mesh" to sample corridors.';
      if (dot) dot.className = 'tyler-pulse-dot';
    }

    if (subBanner) {
      const periphCount = Array.isArray(data.claimed_peripherals) ? data.claimed_peripherals.length : 0;
      const triCount = data.cached_triangulation ? (data.cached_triangulation.total_transmitters || 0) : 0;
      const evCount = motionEvents.length;
      subBanner.textContent = `Monitored Chords: ${telemetry.length} • Claimed Sensor B Peripherals: ${periphCount} • 2-Point Triangulated Transmitters: ${triCount} • Logged Motion Events: ${evCount}. Click any room node or corridor beam below to inspect its 20-sample waveform.`;
    }
  }

  // --- Multi-Room RF Corridor Telemetry Cards & SVG Sparklines ---
  function renderCorridorCards(telemetry) {
    const grid = document.getElementById('tylerCorridorGrid');
    if (!grid) return;
    clearNode(grid);

    if (!Array.isArray(telemetry) || telemetry.length === 0) {
      grid.appendChild(el('div', 'tyler-card-sub', 'No RF corridor telemetry recorded yet. Click "Sense RF Motion (6s)" or "Poll LAN Cast Mesh" above.'));
      return;
    }

    // Sort so active motion and presence shifts appear first
    const rank = { motion_detected: 0, presence_shift: 1, quiet: 2 };
    const sorted = telemetry.slice().sort((a, b) => {
      const ra = rank[a.motion_state] ?? 3;
      const rb = rank[b.motion_state] ?? 3;
      if (ra !== rb) return ra - rb;
      return Math.abs(Number(getChordDriftDb(b) || 0)) - Math.abs(Number(getChordDriftDb(a) || 0));
    });

    sorted.forEach((rc) => {
      const mState = String(rc.motion_state || 'quiet');
      const cKey = getChordKey(rc);
      const driftDb = getChordDriftDb(rc);
      const card = el('div', `tyler-corridor-card state-${mState}`);
      if (state.selectedCorridorKey && state.selectedCorridorKey === cKey) {
        card.style.outline = '2px solid #38bdf8';
      }

      // Header row
      const head = el('div', 'tyler-corridor-head');
      const leftWrap = el('div');
      leftWrap.appendChild(el('div', 'tyler-corridor-zone', rc.zone || rc.label || 'RF Chord'));
      const endpointsStr = rc.tx_node && rc.rx_node
        ? `${rc.tx_node} ↔ ${rc.rx_node}`
        : (rc.label || '');
      leftWrap.appendChild(el('div', 'tyler-corridor-meta', `${endpointsStr} (${rc.band || '2.4 GHz'})`));

      let badgeCls = 'tyler-badge-safe';
      let badgeTxt = 'QUIET';
      if (mState === 'motion_detected') {
        badgeCls = 'tyler-badge-danger';
        badgeTxt = 'MOTION DETECTED';
      } else if (mState === 'presence_shift') {
        badgeCls = 'tyler-badge-warn';
        badgeTxt = 'PRESENCE SHIFT';
      }
      const badge = el('span', `tyler-badge ${badgeCls}`, badgeTxt);
      head.appendChild(leftWrap);
      head.appendChild(badge);
      card.appendChild(head);

      // Metrics row
      const metrics = el('div', 'tyler-corridor-metrics');
      const m1 = el('div', 'tyler-corridor-metric');
      m1.appendChild(el('div', 'tyler-corridor-metric-lbl', rc.last_rssi_dbm != null ? 'LIVE RSSI' : 'PING RTT'));
      const primaryVal = rc.last_rssi_dbm != null
        ? `${rc.last_rssi_dbm} dBm`
        : rc.last_rtt_ms != null
          ? `${rc.last_rtt_ms} ms`
          : '—';
      m1.appendChild(el('div', 'tyler-corridor-metric-val', primaryVal));

      const m2 = el('div', 'tyler-corridor-metric');
      m2.appendChild(el('div', 'tyler-corridor-metric-lbl', driftDb != null ? 'BASELINE DRIFT' : 'SNR / BAND'));
      const driftVal = driftDb != null
        ? fmtSignedDb(driftDb)
        : rc.last_snr_db != null
          ? `SNR ${rc.last_snr_db} dB`
          : (rc.band || '2.4 GHz');
      const m2Val = el('div', 'tyler-corridor-metric-val', driftVal);
      if (Math.abs(Number(driftDb || 0)) >= 2.5) {
        m2Val.style.color = '#fbbf24';
      }
      m2.appendChild(m2Val);

      const m3 = el('div', 'tyler-corridor-metric');
      m3.appendChild(el('div', 'tyler-corridor-metric-lbl', 'P2P SWING / SAMPLES'));
      const swingVal = `${rc.p2p_swing_db != null ? `${rc.p2p_swing_db} dB` : '0 dB'} (${rc.samples_count || (rc.history || []).length} pts)`;
      m3.appendChild(el('div', 'tyler-corridor-metric-val', swingVal));

      metrics.appendChild(m1);
      metrics.appendChild(m2);
      metrics.appendChild(m3);
      card.appendChild(metrics);

      // Historical Sparkline SVG
      const spark = buildSparklineSvg(rc);
      card.appendChild(spark);

      card.addEventListener('click', () => {
        selectCorridor(rc);
      });

      grid.appendChild(card);
    });
  }

  function buildSparklineSvg(rc, heightPx) {
    const h = heightPx || 36;
    const w = 260;
    const svg = svgEl('svg', {
      viewBox: `0 0 ${w} ${h}`,
      class: 'tyler-sparkline-svg'
    });

    const hist = Array.isArray(rc.history) ? rc.history : [];
    const values = hist
      .map((pt) => (pt.rssi_dbm != null ? Number(pt.rssi_dbm) : pt.rtt_ms != null ? Number(pt.rtt_ms) : null))
      .filter((v) => v !== null && !Number.isNaN(v));

    if (values.length === 0) {
      svg.appendChild(svgEl('line', {
        x1: 0,
        y1: h / 2,
        x2: w,
        y2: h / 2,
        stroke: 'rgba(148, 163, 184, 0.25)',
        'stroke-dasharray': '3 3'
      }));
      return svg;
    }

    const baseVal = rc.baseline_rssi_dbm != null ? Number(rc.baseline_rssi_dbm) : values[0];
    const allVals = values.concat([baseVal]);
    let minV = Math.min(...allVals) - 2;
    let maxV = Math.max(...allVals) + 2;
    if (maxV - minV < 6) {
      const mid = (maxV + minV) / 2;
      minV = mid - 3;
      maxV = mid + 3;
    }

    const scaleY = (v) => h - 5 - ((v - minV) / (maxV - minV)) * (h - 10);

    // Baseline reference dashed line
    if (baseVal != null && !Number.isNaN(baseVal)) {
      const by = scaleY(baseVal);
      svg.appendChild(svgEl('line', {
        x1: 0,
        y1: by,
        x2: w,
        y2: by,
        stroke: 'rgba(148, 163, 184, 0.35)',
        'stroke-width': '1',
        'stroke-dasharray': '3 3'
      }));
    }

    const mState = String(rc.motion_state || 'quiet');
    const lineCol = mState === 'motion_detected' ? '#ef4444' : mState === 'presence_shift' ? '#f59e0b' : '#38bdf8';

    const pts = values.map((v, idx) => {
      const x = values.length === 1 ? w / 2 : 6 + (idx / (values.length - 1)) * (w - 12);
      const y = scaleY(v);
      return `${x.toFixed(1)},${y.toFixed(1)}`;
    });

    if (pts.length > 1) {
      svg.appendChild(svgEl('polyline', {
        fill: 'none',
        stroke: lineCol,
        'stroke-width': '1.8',
        points: pts.join(' ')
      }));
    }

    // Draw sample dots
    values.forEach((v, idx) => {
      const x = values.length === 1 ? w / 2 : 6 + (idx / (values.length - 1)) * (w - 12);
      const y = scaleY(v);
      svg.appendChild(svgEl('circle', {
        cx: x.toFixed(1),
        cy: y.toFixed(1),
        r: idx === values.length - 1 ? '3' : '2',
        fill: lineCol
      }));
    });

    return svg;
  }

  function selectCorridor(rc) {
    if (!rc) return;
    state.selectedCorridorKey = getChordKey(rc);
    state.lastActionReport = null;
    if (state.lastStatus) {
      renderMeshRadarSvg(state.lastStatus);
      renderCorridorCards(state.lastStatus.peripheral_rf_telemetry || []);
    }
    renderCorridorDossier(rc);
  }

  // --- 2-Point Spatial Triangulation Visualizer (Workstation vs. Claimed Peripheral) ---
  function renderTriangulationVisualizer(triData) {
    const container = document.getElementById('tylerTriangulationGrid');
    const summaryEl = document.getElementById('tylerTriangulationSummaryBadge');
    if (!container) return;
    clearNode(container);

    if (!triData || !Array.isArray(triData.transmitters) || triData.transmitters.length === 0) {
      container.appendChild(el('div', 'tyler-card-sub', 'No 2-point triangulation matrix cached. Click "Triangulate Airspace (2.4+5GHz)" to compare Workstation (Sensor A) vs. Claimed Peripheral (Sensor B).'));
      return;
    }

    if (summaryEl) {
      const dualCount = triData.dual_sensor_matched ?? triData.dual_point_matched ?? 0;
      const fiveGhzCount = triData.five_ghz_discovered_by_peripheral ?? triData.five_ghz_discovered ?? 0;
      summaryEl.textContent = `${triData.total_transmitters || triData.transmitters.length} TRANSMITTERS • ${dualCount} DUAL-POINT • ${fiveGhzCount} ON 5GHz`;
    }

    const buckets = [
      {
        key: 'near_workstation',
        title: '◉ NORTH / NEAR WORKSTATION (SENSOR A)',
        subtitle: 'Stronger at NW Study Workstation Wi-Fi 4 (Δ ≥ +8 dB)',
        badgeCls: 'tyler-badge-info',
        items: []
      },
      {
        key: 'mid_span',
        title: '◈ EAST-WEST FLANK / MID-SPAN CORRIDOR',
        subtitle: 'Balanced RSSI between Workstation & South-Wall Clock (|Δ| < 8 dB)',
        badgeCls: 'tyler-badge-safe',
        items: []
      },
      {
        key: 'near_remote_peripheral',
        title: '◆ SOUTH / NEAR SMART CLOCK (SENSOR B)',
        subtitle: 'Stronger at South-Wall Lenovo Smart Clock or 5 GHz (Δ ≤ -8 dB)',
        badgeCls: 'tyler-badge-warn',
        items: []
      }
    ];

    triData.transmitters.forEach((tx) => {
      const zStr = String(tx.spatial_zone || tx.proximity_zone || '').toLowerCase();
      if (zStr.includes('workstation')) {
        buckets[0].items.push(tx);
      } else if (zStr.includes('mid')) {
        buckets[1].items.push(tx);
      } else {
        buckets[2].items.push(tx);
      }
    });

    buckets.forEach((b) => {
      const col = el('div', 'tyler-tri-col');
      const hdr = el('div', 'tyler-tri-col-header');
      const titleWrap = el('div');
      titleWrap.appendChild(el('div', 'tyler-tri-col-title', b.title));
      titleWrap.appendChild(el('div', 'tyler-card-sub', b.subtitle));
      hdr.appendChild(titleWrap);
      hdr.appendChild(el('span', `tyler-badge ${b.badgeCls}`, `${b.items.length} APs`));
      col.appendChild(hdr);

      const list = el('div');
      list.style.cssText = 'max-height: 230px; overflow-y: auto; padding-right: 4px;';

      if (b.items.length === 0) {
        list.appendChild(el('div', 'tyler-card-sub', 'No transmitters in this proximity zone.'));
      } else {
        b.items.slice(0, 14).forEach((tx) => {
          const wsRssi = tx.desktop_rssi_dbm ?? tx.workstation_rssi_dbm ?? null;
          const pfRssi = tx.peripheral_rssi_dbm ?? null;
          const deltaVal = tx.delta_db ?? tx.rssi_delta_ws_minus_periph_db ?? null;

          const item = el('div', 'tyler-tri-item');
          const top = el('div', 'tyler-tri-item-top');
          top.appendChild(el('span', 'tyler-tri-ssid', tx.ssid || '<Hidden SSID>'));
          const bandBadge = el('span', `tyler-badge ${tx.band === '5 GHz' ? 'tyler-badge-sandbox' : 'tyler-badge-neutral'}`, `${tx.band || '2.4 GHz'}${tx.channel ? ` Ch.${tx.channel}` : ''}`);
          top.appendChild(bandBadge);
          item.appendChild(top);

          const meta = el('div', 'tyler-Corridor-meta');
          meta.style.cssText = 'font-size: 10px; color: var(--tyler-text-dim); font-family: var(--font-mono);';
          const wsStr = wsRssi != null ? `WS: ${wsRssi} dBm` : 'WS: —';
          const pfStr = pfRssi != null ? `Clock: ${pfRssi} dBm` : 'Clock: —';
          const diffStr = deltaVal != null ? ` • Δ ${fmtSignedDb(deltaVal)}` : '';
          const compStr = tx.compass_sector ? ` • [${tx.compass_sector}]` : '';
          meta.textContent = `${tx.bssid} • ${wsStr} | ${pfStr}${diffStr}${compStr}`;
          item.appendChild(meta);

          // Dual signal comparison bar
          const barRow = el('div', 'tyler-tri-bars');
          const wsPct = wsRssi != null ? Math.max(8, Math.min(100, (Number(wsRssi) + 95) * 1.8)) : 0;
          const pfPct = pfRssi != null ? Math.max(8, Math.min(100, (Number(pfRssi) + 95) * 1.8)) : 0;

          const bWrap1 = el('div', 'tyler-tri-bar-wrap');
          const fill1 = el('div', 'tyler-tri-bar-fill ws');
          fill1.style.width = `${wsPct}%`;
          bWrap1.appendChild(fill1);

          const bWrap2 = el('div', 'tyler-tri-bar-wrap');
          const fill2 = el('div', 'tyler-tri-bar-fill periph');
          fill2.style.width = `${pfPct}%`;
          bWrap2.appendChild(fill2);

          barRow.appendChild(bWrap1);
          barRow.appendChild(bWrap2);
          item.appendChild(barRow);

          list.appendChild(item);
        });
      }

      col.appendChild(list);
      container.appendChild(col);
    });
  }

  // --- Chronological RF Motion & Presence Event Feed ---
  function renderMotionTimeline(events) {
    const list = document.getElementById('tylerMotionTimelineList');
    if (!list) return;
    clearNode(list);

    if (!Array.isArray(events) || events.length === 0) {
      list.appendChild(el('div', 'tyler-card-sub', 'No RF motion or presence shift events logged yet.'));
      return;
    }

    events.slice(0, 12).forEach((ev, idx) => {
      let detObj = {};
      if (ev.details_json && typeof ev.details_json === 'string') {
        try { detObj = JSON.parse(ev.details_json); } catch (_e) { detObj = {}; }
      }
      const row = el('div', 'tyler-timeline-item');
      const mState = String(ev.motion_state || detObj.motion_state || 'presence_shift');
      const isMotion = mState === 'motion_detected';

      const stepBadge = el('span', `tyler-badge ${isMotion ? 'tyler-badge-danger' : 'tyler-badge-warn'}`, `#${idx + 1} ${isMotion ? 'MOTION' : 'SHIFT'}`);
      const body = el('div');
      body.style.flex = '1';
      const title = el('div');
      title.style.cssText = 'font-weight: 700; color: var(--tyler-text-strong);';
      const lblStr = ev.label || detObj.label || `${detObj.tx_node || ''} ↔ ${detObj.rx_node || ''}`;
      title.textContent = `${ev.zone || detObj.zone || 'Corridor'} — ${lblStr}`;

      const rssiVal = ev.rssi_dbm ?? detObj.mean_rssi_dbm;
      const baseVal = ev.baseline_rssi_dbm ?? detObj.baseline_rssi_dbm;
      const rttVal = detObj.mean_rtt_ms;
      const det = el('div', 'tyler-card-sub');
      if (rssiVal != null) {
        det.textContent = `Signal: ${rssiVal} dBm (Quiet Baseline: ${baseVal ?? '—'} dBm • Drift: ${fmtSignedDb(ev.baseline_drift_db ?? detObj.baseline_drift_db)} • Swing: ${ev.p2p_swing_db ?? 0} dB)`;
      } else if (rttVal != null) {
        det.textContent = `Ping RTT: ${rttVal} ms (Jitter: ${detObj.rtt_jitter_ms ?? 0} ms • Link: ${detObj.tx_node || 'Mesh'} → ${detObj.rx_node || 'Cast'})`;
      } else {
        det.textContent = `Baseline Drift: ${fmtSignedDb(ev.baseline_drift_db)} • Swing: ${ev.p2p_swing_db ?? 0} dB`;
      }

      body.appendChild(title);
      body.appendChild(det);

      const timeEl = el('div', 'tyler-timeline-time', fmtTime(ev.ts || ev.timestamp));
      row.appendChild(stepBadge);
      row.appendChild(body);
      row.appendChild(timeEl);
      list.appendChild(row);
    });
  }

  // --- Structured Diagnostic Report & Dossier Inspector ---
  function renderCorridorDossier(rc) {
    const view = document.getElementById('tylerDiagnosticReportView');
    const titleEl = document.getElementById('tylerInspectorTitle');
    const badgeEl = document.getElementById('tylerInspectorModeBadge');
    if (!view) return;
    clearNode(view);

    if (titleEl) titleEl.textContent = `RF CORRIDOR DOSSIER // ${rc.zone || rc.label}`;
    if (badgeEl) {
      badgeEl.className = 'tyler-badge tyler-badge-info';
      badgeEl.textContent = 'RF TOMOGRAPHY CHORD';
    }

    const cKey = getChordKey(rc);
    const driftDb = getChordDriftDb(rc);
    const wrap = el('div', 'tyler-report-card');
    const hdr = el('div', 'tyler-report-header');
    const left = el('div');
    left.appendChild(el('div', 'tyler-report-title', `◉ ${rc.zone || 'RF Corridor'} — ${rc.label || ''}`));
    left.appendChild(el('div', 'tyler-report-meta', `Chord ID: ${cKey || 'N/A'} • Link: ${rc.tx_node || 'Hub'} → ${rc.rx_node || rc.zone || 'Node'} • Updated: ${fmtTime(rc.updated_at)}`));
    const mState = String(rc.motion_state || 'quiet');
    const stBadge = el('span', `tyler-badge ${mState === 'motion_detected' ? 'tyler-badge-danger' : mState === 'presence_shift' ? 'tyler-badge-warn' : 'tyler-badge-safe'}`, mState.toUpperCase());
    hdr.appendChild(left);
    hdr.appendChild(stBadge);
    wrap.appendChild(hdr);

    const kpiGrid = el('div', 'tyler-report-kpi-grid');
    const kpis = [
      { lbl: 'Live / Fast EWMA', val: rc.last_rssi_dbm != null ? `${rc.last_rssi_dbm} dBm (EWMA: ${rc.ewma_fast_dbm ?? rc.last_rssi_dbm} dBm)` : `RTT ${rc.last_rtt_ms ?? '—'} ms` },
      { lbl: 'Quiet Baseline (Slow EWMA)', val: rc.baseline_rssi_dbm != null ? `${rc.baseline_rssi_dbm} dBm` : 'Auto-Calibrated' },
      { lbl: 'Baseline Drift & Z-Score', val: driftDb != null ? `${fmtSignedDb(driftDb)} (${Number(rc.z_score || 0).toFixed(2)}σ)` : '0.0 dB (RTT Link)' },
      { lbl: 'CUSUM / P2P Swing', val: `CUSUM ${Number(rc.cusum_db || 0).toFixed(2)} dB • P2P ${rc.p2p_swing_db ?? 0} dB` },
      { lbl: 'SNR / Band', val: rc.last_snr_db != null ? `${rc.last_snr_db} dB SNR (${rc.band || '2.4 GHz'})` : `${rc.band || '2.4 GHz'}${rc.bssid ? ` • ${rc.bssid}` : ''}` },
      { lbl: 'Sample Window', val: `${(rc.history || []).length} / 60 samples (15s cadence)` }
    ];
    kpis.forEach((k) => {
      const box = el('div', 'tyler-report-kpi');
      box.appendChild(el('div', 'tyler-report-kpi-lbl', k.lbl));
      box.appendChild(el('div', 'tyler-report-kpi-val', k.val));
      kpiGrid.appendChild(box);
    });
    wrap.appendChild(kpiGrid);

    // Physical Fresnel Interpretation Box
    const interp = el('div', 'tyler-report-section');
    interp.appendChild(el('div', 'tyler-report-section-title', 'PHYSICAL FRESNEL ZONE INTERPRETATION'));
    let explanation = 'Signal propagation along this corridor matches its quiet baseline. No significant human body absorption or multipath scattering is currently perturbing the 1st Fresnel zone.';
    if (mState === 'motion_detected') {
      explanation = `Active fluctuation (${rc.p2p_swing_db ? `${rc.p2p_swing_db} dB swing` : `RTT ${rc.last_rtt_ms} ms`}, σ=${rc.std_db ?? rc.stddev_db ?? 0}) indicates a moving body or active traffic perturbing the line-of-sight Fresnel ellipse between ${rc.tx_node || 'transmitter'} and ${rc.rx_node || 'receiver'}.`;
    } else if (mState === 'presence_shift') {
      explanation = `Sustained baseline shift of ${fmtSignedDb(driftDb)} relative to the quiet reference (${rc.baseline_rssi_dbm} dBm) indicates changed occupancy, a stationary person in the room, or an altered door/appliance state along the ${rc.zone} span.`;
    }
    interp.appendChild(el('div', 'tyler-card-sub', explanation));
    wrap.appendChild(interp);

    // Larger Waveform Chart
    const chartSec = el('div', 'tyler-report-section');
    chartSec.appendChild(el('div', 'tyler-report-section-title', 'RECENT 60-SAMPLE SIGNAL WAVEFORM (DASHED LINE = QUIET BASELINE)'));
    const bigSpark = buildSparklineSvg(rc, 68);
    bigSpark.style.height = '68px';
    chartSec.appendChild(bigSpark);
    wrap.appendChild(chartSec);

    view.appendChild(wrap);
  }

  // --- SQLite Historical RF Time-Series Trend Explorer ---
  const TREND_PALETTE = [
    '#38bdf8', '#10b981', '#f59e0b', '#a78bfa', '#f472b6',
    '#34d399', '#fb923c', '#60a5fa', '#e879f9', '#facc15'
  ];

  function renderRfTrendChart(rfChords, tsStats) {
    const wrap = document.getElementById('tylerRfTrendChartWrap');
    const badge = document.getElementById('tylerRfTimeseriesBadge');
    const metricSel = document.getElementById('tylerRfTrendMetricSelect');
    const chordSel = document.getElementById('tylerRfTrendChordSelect');
    if (!wrap) return;
    clearNode(wrap);

    const totalSamples = (tsStats && tsStats.total_samples) ? tsStats.total_samples : 0;
    const rollupSamples = (tsStats && tsStats.rollup_5m_samples) ? tsStats.rollup_5m_samples : 0;
    const totalChords = (tsStats && tsStats.chords_tracked) ? tsStats.chords_tracked : (Array.isArray(rfChords) ? rfChords.length : 0);
    const cronSec = (tsStats && tsStats.cron_interval_s) ? tsStats.cron_interval_s : 15;
    if (badge) {
      badge.textContent = `${totalSamples} RAW (${rollupSamples} 5M ROLLUP) • ${totalChords} CHORDS • ${cronSec}S DAEMON`;
    }

    const chords = Array.isArray(rfChords) ? rfChords : [];
    const metric = metricSel ? metricSel.value : 'rssi_dbm';
    const prevChordVal = chordSel ? chordSel.value : 'all';

    if (chordSel) {
      clearNode(chordSel);
      chordSel.appendChild(el('option', '', 'Corridors: All Active Chords', { value: 'all' }));
      chords.forEach((c) => {
        const cid = String(c.chord_id || c.zone || '');
        const z = String(c.zone || c.label || cid);
        chordSel.appendChild(el('option', '', z, { value: cid }));
      });
      if (Array.from(chordSel.options).some((o) => o.value === prevChordVal)) {
        chordSel.value = prevChordVal;
      }
    }
    const selectedChord = chordSel ? chordSel.value : 'all';

    // Filter chords that have valid samples for the chosen metric
    const seriesList = [];
    chords.forEach((c, idx) => {
      const cid = String(c.chord_id || c.zone || '');
      if (selectedChord !== 'all' && cid !== selectedChord) return;
      const hist = Array.isArray(c.history) ? c.history : [];
      const pts = [];
      hist.forEach((h, hIdx) => {
        let v = null;
        if (metric === 'rssi_dbm' && h.rssi_dbm !== null && h.rssi_dbm !== undefined) v = Number(h.rssi_dbm);
        else if (metric === 'ewma_fast_dbm') {
          const ev = (h.ewma_fast_dbm !== null && h.ewma_fast_dbm !== undefined) ? h.ewma_fast_dbm : h.rssi_dbm;
          if (ev !== null && ev !== undefined) v = Number(ev);
        }
        else if (metric === 'z_score' && h.z_score !== null && h.z_score !== undefined) v = Number(h.z_score);
        else if (metric === 'cusum_db' && h.cusum_db !== null && h.cusum_db !== undefined) v = Number(h.cusum_db);
        else if (metric === 'rtt_ms' && h.rtt_ms !== null && h.rtt_ms !== undefined) v = Number(h.rtt_ms);
        else if (metric === 'p2p_swing_db' && h.p2p_swing_db !== null && h.p2p_swing_db !== undefined) v = Number(h.p2p_swing_db);
        if (v !== null && Number.isFinite(v)) {
          pts.push({ idx: hIdx, ts: Number(h.ts || 0), val: v, state: h.state || 'quiet' });
        }
      });
      if (pts.length > 0) {
        seriesList.push({
          chord: c,
          cid,
          zone: String(c.zone || c.label || cid),
          color: TREND_PALETTE[idx % TREND_PALETTE.length],
          pts
        });
      }
    });

    if (seriesList.length === 0) {
      const emptyMsg = el('div', 'tyler-card-sub', 'No historical SQLite samples available for the selected metric/corridor. Click "Sense RF Motion (6s)" to record samples.');
      emptyMsg.style.padding = '12px';
      wrap.appendChild(emptyMsg);
      return;
    }

    const W = 760;
    const H = 165;
    const padL = 48;
    const padR = 18;
    const padT = 14;
    const padB = 24;
    const plotW = W - padL - padR;
    const plotH = H - padT - padB;

    let minV = Infinity;
    let maxV = -Infinity;
    let maxLen = 1;
    let earliestTs = Infinity;
    let latestTs = 0;

    seriesList.forEach((s) => {
      if (s.pts.length > maxLen) maxLen = s.pts.length;
      s.pts.forEach((p) => {
        if (p.val < minV) minV = p.val;
        if (p.val > maxV) maxV = p.val;
        if (p.ts > 0 && p.ts < earliestTs) earliestTs = p.ts;
        if (p.ts > latestTs) latestTs = p.ts;
      });
    });

    if (metric === 'rssi_dbm' || metric === 'ewma_fast_dbm') {
      minV = Math.min(minV - 3, -84);
      maxV = Math.max(maxV + 3, -50);
    } else if (metric === 'rtt_ms') {
      minV = Math.max(0, minV - 25);
      maxV = Math.max(maxV + 30, 360);
    } else if (metric === 'z_score') {
      minV = Math.min(minV - 0.8, -3.5);
      maxV = Math.max(maxV + 0.8, 3.5);
    } else if (metric === 'cusum_db') {
      minV = Math.min(minV - 1.0, -5.0);
      maxV = Math.max(maxV + 1.0, 5.0);
    } else {
      minV = 0;
      maxV = Math.max(maxV + 1.0, 5.0);
    }
    const spanV = Math.max(1e-3, maxV - minV);

    const svgBox = el('div', 'tyler-rf-trend-svg-box');
    const svg = svgEl('svg', {
      viewBox: `0 0 ${W} ${H}`,
      width: '100%',
      height: '165',
      style: 'display:block;overflow:visible;'
    });

    // Horizontal Y-axis grid lines (4 steps)
    const unitSuffix = (metric === 'rssi_dbm' || metric === 'ewma_fast_dbm')
      ? ' dBm'
      : metric === 'rtt_ms'
        ? ' ms'
        : metric === 'z_score'
          ? 'σ'
          : ' dB';
    const decimals = (metric === 'p2p_swing_db' || metric === 'z_score' || metric === 'cusum_db') ? 1 : 0;
    for (let i = 0; i <= 3; i += 1) {
      const frac = i / 3;
      const y = padT + frac * plotH;
      const valAtY = maxV - frac * spanV;
      svg.appendChild(svgEl('line', {
        x1: String(padL),
        y1: y.toFixed(1),
        x2: String(W - padR),
        y2: y.toFixed(1),
        stroke: 'rgba(148,163,184,0.16)',
        'stroke-dasharray': i === 3 ? 'none' : '3 3',
        'stroke-width': '1'
      }));
      const lbl = svgEl('text', {
        x: String(padL - 6),
        y: (y + 3).toFixed(1),
        'text-anchor': 'end',
        fill: '#94a3b8',
        'font-size': '9.5',
        'font-family': 'monospace'
      });
      lbl.textContent = `${valAtY.toFixed(decimals)}${unitSuffix}`;
      svg.appendChild(lbl);
    }

    // Draw threshold reference lines for Fresnel P2P swing, Adaptive Z-Score (±2.3σ), or Page-Hinkley CUSUM (±3.5 dB)
    if (metric === 'p2p_swing_db' && maxV >= 3.0) {
      const yShift = padT + ((maxV - 2.0) / spanV) * plotH;
      svg.appendChild(svgEl('line', {
        x1: String(padL),
        y1: yShift.toFixed(1),
        x2: String(W - padR),
        y2: yShift.toFixed(1),
        stroke: 'rgba(245,158,11,0.55)',
        'stroke-dasharray': '4 3',
        'stroke-width': '1'
      }));
    } else if (metric === 'z_score' || metric === 'cusum_db') {
      const thr = metric === 'z_score' ? 2.3 : 3.5;
      [thr, -thr].forEach((tv) => {
        if (tv >= minV && tv <= maxV) {
          const yT = padT + ((maxV - tv) / spanV) * plotH;
          svg.appendChild(svgEl('line', {
            x1: String(padL),
            y1: yT.toFixed(1),
            x2: String(W - padR),
            y2: yT.toFixed(1),
            stroke: 'rgba(245,158,11,0.55)',
            'stroke-dasharray': '4 3',
            'stroke-width': '1'
          }));
        }
      });
    }

    // Plot each corridor's polyline and sample dots
    seriesList.forEach((s) => {
      const n = s.pts.length;
      const coords = s.pts.map((p, idx) => {
        const x = padL + (n === 1 ? plotW / 2 : (idx / (n - 1)) * plotW);
        const y = padT + ((maxV - p.val) / spanV) * plotH;
        return { x, y, p };
      });

      if (coords.length > 1) {
        const dStr = coords.map((c, idx) => `${idx === 0 ? 'M' : 'L'}${c.x.toFixed(1)},${c.y.toFixed(1)}`).join(' ');
        svg.appendChild(svgEl('path', {
          d: dStr,
          fill: 'none',
          stroke: s.color,
          'stroke-width': selectedChord === 'all' ? '1.8' : '2.5',
          'stroke-linecap': 'round',
          'stroke-linejoin': 'round'
        }));
      }

      coords.forEach((c, idx) => {
        if (selectedChord !== 'all' || idx === coords.length - 1 || c.p.state !== 'quiet') {
          const dotColor = c.p.state === 'motion_detected' ? '#ef4444' : (c.p.state === 'presence_shift' ? '#f59e0b' : s.color);
          const circle = svgEl('circle', {
            cx: c.x.toFixed(1),
            cy: c.y.toFixed(1),
            r: idx === coords.length - 1 ? '3.5' : '2.4',
            fill: dotColor,
            stroke: '#0f172a',
            'stroke-width': '1'
          });
          svg.appendChild(circle);
        }
      });
    });

    // Bottom X-axis time span labels
    const tLeft = svgEl('text', {
      x: String(padL),
      y: String(H - 6),
      fill: '#64748b',
      'font-size': '9.5',
      'font-family': 'monospace'
    });
    tLeft.textContent = earliestTs < Infinity ? `Start: ${fmtTime(earliestTs)}` : 'Oldest Sample';
    svg.appendChild(tLeft);

    const tRight = svgEl('text', {
      x: String(W - padR),
      y: String(H - 6),
      'text-anchor': 'end',
      fill: '#94a3b8',
      'font-size': '9.5',
      'font-family': 'monospace'
    });
    tRight.textContent = latestTs > 0 ? `Latest: ${fmtTime(latestTs)} (${maxLen} ticks/chord)` : 'Latest Sample';
    svg.appendChild(tRight);

    svgBox.appendChild(svg);
    wrap.appendChild(svgBox);

    // Interactive Legend Chips
    const legend = el('div', 'tyler-rf-trend-legend');
    seriesList.forEach((s) => {
      const lastPt = s.pts[s.pts.length - 1];
      const chip = el('button', 'tyler-rf-trend-chip');
      chip.type = 'button';
      const swatch = el('span');
      swatch.style.cssText = `width:8px;height:8px;border-radius:50%;display:inline-block;background:${s.color};`;
      const txt = el('span', '', `${s.zone}: ${lastPt.val}${unitSuffix}`);
      chip.appendChild(swatch);
      chip.appendChild(txt);
      chip.addEventListener('click', () => {
        state.selectedCorridorId = s.cid;
        renderCorridorDossier(s.chord);
      });
      legend.appendChild(chip);
    });
    wrap.appendChild(legend);
  }

  function renderDeviceDossier(device) {
    const view = document.getElementById('tylerDiagnosticReportView');
    const titleEl = document.getElementById('tylerInspectorTitle');
    const badgeEl = document.getElementById('tylerInspectorModeBadge');
    if (!view || !device) return;
    clearNode(view);

    const ip = String(device.ip || '');
    const host = String(device.label || device.hostname || 'Unidentified Host');
    const trust = String(device.trust_level || 'unknown');

    if (titleEl) titleEl.textContent = `DEVICE DOSSIER // ${ip} (${host})`;
    if (badgeEl) {
      badgeEl.className = `tyler-badge ${trust === 'trusted' ? 'tyler-badge-safe' : trust === 'untrusted' ? 'tyler-badge-danger' : 'tyler-badge-info'}`;
      badgeEl.textContent = trust.toUpperCase();
    }

    const wrap = el('div', 'tyler-report-card');
    const hdr = el('div', 'tyler-report-header');
    const left = el('div');
    left.appendChild(el('div', 'tyler-report-title', `◈ ${ip} — ${host}`));
    left.appendChild(el('div', 'tyler-report-meta', `MAC: ${device.mac || 'Unknown'} • Vendor OUI: ${device.vendor || device.vendor_oui || 'Unknown'} • Last Seen: ${fmtTime(device.last_seen)}`));
    const pBadge = el('span', `tyler-badge ${device.protected ? 'tyler-badge-safe' : 'tyler-badge-neutral'}`, device.protected ? 'PROTECTED INFRASTRUCTURE' : 'STANDARD ENDPOINT');
    hdr.appendChild(left);
    hdr.appendChild(pBadge);
    wrap.appendChild(hdr);

    // Quick Tactical Probe Action Bar inside Dossier
    const actRow = el('div', 'tyler-btn-row');
    actRow.style.marginBottom = '10px';
    const probes = [
      { lbl: '⌖ Deep Nmap Fingerprint', act: 'fingerprint', cls: 'tyler-badge-info' },
      { lbl: '⚡ NSE Vuln Audit', act: 'vuln_audit', cls: 'tyler-badge-warn' },
      { lbl: '◈ B-Cell Drift Diff', act: 'baseline_diff', cls: 'tyler-badge-safe' },
      { lbl: '◉ Tshark Sniff (8s)', act: 'traffic', cls: 'tyler-badge-sandbox' },
      { lbl: '◈ IoT Egress Audit', act: 'egress_audit', cls: 'tyler-badge-info' }
    ];
    probes.forEach((p) => {
      const b = el('button', 'tactile-btn', p.lbl);
      b.style.cssText = 'font-size: 10px; padding: 4px 8px;';
      b.addEventListener('click', () => {
        runTylerAction({ action: p.act, ip, duration: 8 }, `${p.lbl} (${ip})`);
      });
      actRow.appendChild(b);
    });
    wrap.appendChild(actRow);

    const fp = device.fingerprint || {};
    const base = device.baseline || {};
    const openPorts = Array.isArray(fp.open_ports) && fp.open_ports.length > 0
      ? fp.open_ports
      : Array.isArray(base.baseline_ports)
        ? base.baseline_ports
        : [];

    const kpiGrid = el('div', 'tyler-report-kpi-grid');
    [
      { lbl: 'Online Status', val: device.online ? 'ONLINE (ARP/Ping)' : 'OFFLINE' },
      { lbl: 'Trust Classification', val: trust.toUpperCase() },
      { lbl: 'Open TCP Ports', val: openPorts.length > 0 ? `${openPorts.length} Ports` : '0 Open (Stealth/Closed)' },
      { lbl: 'B-Cell Baseline', val: base.updated_at ? `Locked (${fmtTime(base.updated_at)})` : 'Not Yet Snapshot' }
    ].forEach((k) => {
      const box = el('div', 'tyler-report-kpi');
      box.appendChild(el('div', 'tyler-report-kpi-lbl', k.lbl));
      box.appendChild(el('div', 'tyler-report-kpi-val', k.val));
      kpiGrid.appendChild(box);
    });
    wrap.appendChild(kpiGrid);

    // Forensic Clues & OS Guess
    if (fp.forensic_clue || fp.os_guess || base.os_guess) {
      const sec = el('div', 'tyler-report-section');
      sec.appendChild(el('div', 'tyler-report-section-title', 'FORENSIC IDENTITY & OS FINGERPRINT'));
      if (fp.os_guess || base.os_guess) {
        const osLine = el('div');
        osLine.style.cssText = 'font-size: 11px; font-weight: 700; color: var(--tyler-text-strong); margin-bottom: 4px;';
        osLine.textContent = `OS / Stack: ${fp.os_guess || base.os_guess}`;
        sec.appendChild(osLine);
      }
      if (fp.forensic_clue) {
        sec.appendChild(el('div', 'tyler-card-sub', fp.forensic_clue));
      }
      wrap.appendChild(sec);
    }

    // Open Ports & Service Banners
    const portSec = el('div', 'tyler-report-section');
    portSec.appendChild(el('div', 'tyler-report-section-title', `DISCOVERED PORTS & SERVICES (${openPorts.length})`));
    const services = Array.isArray(fp.services) ? fp.services : [];
    if (services.length > 0) {
      const pillWrap = el('div', 'tyler-port-list');
      services.forEach((s) => {
        pillWrap.appendChild(el('span', 'tyler-port-pill', s));
      });
      portSec.appendChild(pillWrap);
    } else if (openPorts.length > 0) {
      const pillWrap = el('div', 'tyler-port-list');
      openPorts.forEach((p) => {
        pillWrap.appendChild(el('span', 'tyler-port-pill', `TCP/${p}`));
      });
      portSec.appendChild(pillWrap);
    } else {
      portSec.appendChild(el('div', 'tyler-card-sub', 'No open TCP listeners detected in cached scan (typical for mobile phones with private MACs or client-only IoT nodes).'));
    }
    wrap.appendChild(portSec);

    // Last Traffic Capture Summary if present
    const tc = fp.last_traffic_capture;
    if (tc && typeof tc === 'object') {
      const tSec = el('div', 'tyler-report-section');
      tSec.appendChild(el('div', 'tyler-report-section-title', `CACHED TSHARK TRAFFIC SNAPSHOT (${tc.total_packets ?? 0} PACKETS)`));
      const dns = Array.isArray(tc.dns_queries) && tc.dns_queries.length > 0 ? tc.dns_queries.join(', ') : 'None';
      const sni = Array.isArray(tc.tls_sni) && tc.tls_sni.length > 0 ? tc.tls_sni.join(', ') : 'None';
      tSec.appendChild(el('div', 'tyler-card-sub', `DNS Queries: ${dns} • TLS SNI: ${sni}`));
      wrap.appendChild(tSec);
    }

    view.appendChild(wrap);
  }

  // --- Rich Formatter for All Tyler Tool Action Outputs ---
  function renderStructuredActionReport(data, label, payload) {
    const view = document.getElementById('tylerDiagnosticReportView');
    const titleEl = document.getElementById('tylerInspectorTitle');
    const badgeEl = document.getElementById('tylerInspectorModeBadge');
    if (!view) return;
    clearNode(view);

    const act = (payload && payload.action) || data.action || 'diagnostic';
    const mode = (payload && payload.mode) || data.mode || '';
    const isOk = data.ok !== false && !data.error;

    if (titleEl) titleEl.textContent = `DIAGNOSTIC REPORT // ${label || act.toUpperCase()}`;
    if (badgeEl) {
      badgeEl.className = `tyler-badge ${isOk ? 'tyler-badge-safe' : 'tyler-badge-danger'}`;
      badgeEl.textContent = isOk ? 'COMPLETED OK' : 'ACTION ALERT / ERROR';
    }

    const wrap = el('div', 'tyler-report-card');
    const hdr = el('div', 'tyler-report-header');
    const left = el('div');
    left.appendChild(el('div', 'tyler-report-title', label || `Action: ${act}`));
    left.appendChild(el('div', 'tyler-report-meta', `Action: ${act}${mode ? ` (${mode})` : ''} • Executed at ${fmtTime(data.timestamp || new Date().toISOString())}`));
    hdr.appendChild(left);
    hdr.appendChild(el('span', `tyler-badge ${isOk ? 'tyler-badge-safe' : 'tyler-badge-danger'}`, isOk ? 'SUCCESS' : 'ATTENTION'));
    wrap.appendChild(hdr);

    if (data.error || data.reason) {
      const errSec = el('div', 'tyler-report-section');
      errSec.style.borderColor = 'rgba(239, 68, 68, 0.45)';
      errSec.appendChild(el('div', 'tyler-report-section-title', 'DIAGNOSTIC MESSAGE / POLICY GATE REASON'));
      errSec.appendChild(el('div', 'tyler-card-sub', String(data.error || data.reason)));
      wrap.appendChild(errSec);
    }

    // Specialized visual sections by action/mode
    if (act === 'fingerprint' || data.open_ports || data.services) {
      const kpiGrid = el('div', 'tyler-report-kpi-grid');
      [
        { lbl: 'Target Host', val: data.ip || (payload && payload.ip) || '—' },
        { lbl: 'Open Ports', val: `${(data.open_ports || []).length} Ports` },
        { lbl: 'OS Detection', val: data.os_guess || 'Unclassified' }
      ].forEach((k) => {
        const box = el('div', 'tyler-report-kpi');
        box.appendChild(el('div', 'tyler-report-kpi-lbl', k.lbl));
        box.appendChild(el('div', 'tyler-report-kpi-val', k.val));
        kpiGrid.appendChild(box);
      });
      wrap.appendChild(kpiGrid);

      if (Array.isArray(data.services) && data.services.length > 0) {
        const sSec = el('div', 'tyler-report-section');
        sSec.appendChild(el('div', 'tyler-report-section-title', 'DISCOVERED SERVICES & VERSION BANNERS'));
        const pList = el('div', 'tyler-port-list');
        data.services.forEach((s) => pList.appendChild(el('span', 'tyler-port-pill', s)));
        sSec.appendChild(pList);
        wrap.appendChild(sSec);
      }
    }

    if (act === 'vuln_audit' || data.findings !== undefined) {
      const findings = Array.isArray(data.findings) ? data.findings : [];
      const vSec = el('div', 'tyler-report-section');
      vSec.appendChild(el('div', 'tyler-report-section-title', `NSE VULNERABILITY AUDIT FINDINGS (${findings.length})`));
      if (findings.length === 0) {
        vSec.appendChild(el('div', 'tyler-card-sub', '✅ Zero high-confidence CVE or NSE vulnerability triggers found on open services.'));
      } else {
        findings.forEach((f) => {
          const item = el('div', 'tyler-timeline-item');
          item.appendChild(el('span', 'tyler-badge tyler-badge-danger', 'VULN'));
          item.appendChild(el('span', '', typeof f === 'string' ? f : JSON.stringify(f)));
          vSec.appendChild(item);
        });
      }
      wrap.appendChild(vSec);
    }

    if (act === 'traffic' || data.protocol_hierarchy || data.dns_queries) {
      const kpiGrid = el('div', 'tyler-report-kpi-grid');
      [
        { lbl: 'Target IP', val: data.ip || 'LAN' },
        { lbl: 'Captured Packets', val: String(data.total_packets ?? 0) },
        { lbl: 'DNS Queries', val: String((data.dns_queries || []).length) },
        { lbl: 'TLS SNI Hosts', val: String((data.tls_sni || []).length) }
      ].forEach((k) => {
        const box = el('div', 'tyler-report-kpi');
        box.appendChild(el('div', 'tyler-report-kpi-lbl', k.lbl));
        box.appendChild(el('div', 'tyler-report-kpi-val', k.val));
        kpiGrid.appendChild(box);
      });
      wrap.appendChild(kpiGrid);

      if (Array.isArray(data.dns_queries) && data.dns_queries.length > 0) {
        const dSec = el('div', 'tyler-report-section');
        dSec.appendChild(el('div', 'tyler-report-section-title', 'OBSERVED DNS QUERIES'));
        dSec.appendChild(el('div', 'tyler-card-sub', data.dns_queries.join(', ')));
        wrap.appendChild(dSec);
      }
      if (Array.isArray(data.tls_sni) && data.tls_sni.length > 0) {
        const tSec = el('div', 'tyler-report-section');
        tSec.appendChild(el('div', 'tyler-report-section-title', 'OBSERVED TLS SNI HOSTNAMES'));
        tSec.appendChild(el('div', 'tyler-card-sub', data.tls_sni.join(', ')));
        wrap.appendChild(tSec);
      }
    }

    if (act === 'baseline_diff' && Array.isArray(data.diffs)) {
      const bSec = el('div', 'tyler-report-section');
      bSec.appendChild(el('div', 'tyler-report-section-title', `MEMORY B-CELL DRIFT DIFF (${data.drifted_count || 0} DRIFTED OF ${data.diffs.length} AUDITED)`));
      data.diffs.slice(0, 12).forEach((df) => {
        const row = el('div', 'tyler-timeline-item');
        const st = String(df.status || 'clean');
        row.appendChild(el('span', `tyler-badge ${st === 'clean' ? 'tyler-badge-safe' : 'tyler-badge-warn'}`, st.toUpperCase()));
        row.appendChild(el('span', '', `${df.ip} (${df.label || df.hostname || ''}) — New Ports: ${(df.new_ports || []).join(',') || 'None'}`));
        bSec.appendChild(row);
      });
      wrap.appendChild(bSec);
    }

    if (act === 'egress_audit' || data.action === 'egress_audit') {
      const eSec = el('div', 'tyler-report-section');
      const entries = Array.isArray(data.results) ? data.results : [data];
      eSec.appendChild(
        el(
          'div',
          'tyler-report-section-title',
          `IOT DNS / TLS-SNI EGRESS BASELINE AUDIT (${entries.length} HOST${entries.length === 1 ? '' : 'S'} · 0 PACKETS EMITTED)`
        )
      );
      entries.forEach((eg) => {
        if (!eg || !eg.ip) return;
        const row = el('div', 'tyler-timeline-item');
        const hasAnom = Boolean(eg.anomaly_detected);
        const badgeCls = hasAnom ? 'tyler-badge-danger' : (eg.baseline_saved ? 'tyler-badge-info' : 'tyler-badge-safe');
        const badgeTxt = hasAnom ? 'EGRESS ANOMALY' : (eg.baseline_saved ? 'BASELINE SAVED' : 'CLEAN EGRESS');
        row.appendChild(el('span', `tyler-badge ${badgeCls}`, badgeTxt));
        const newDoms = (eg.new_egress_domains || []).join(', ') || 'None';
        const rawIps = (eg.raw_ip_egress || []).join(', ');
        const baseCnt = (eg.baseline_domains || []).length;
        const obsTxt = (eg.observed_domains || []).slice(0, 6).join(', ') || 'idle';
        row.appendChild(
          el(
            'span',
            '',
            `${eg.ip} (${eg.label || eg.mac || ''}) — Observed: [${obsTxt}] · Baseline(${baseCnt}) · New Domains: ${newDoms}${rawIps ? ' · Raw-IP Egress: ' + rawIps : ''}`
          )
        );
        eSec.appendChild(row);
      });
      wrap.appendChild(eSec);
    }

    // 6-Layer Airlock Checklist & Cast Dossier (interrogate_soft_ap)
    if (Array.isArray(data.airlock_layers)) {
      const aSec = el('div', 'tyler-report-section');
      aSec.appendChild(el('div', 'tyler-report-section-title', '6-LAYER AIRLOCK SANDBOX VERIFICATION'));
      data.airlock_layers.forEach((layer) => {
        const row = el('div', 'tyler-timeline-item');
        row.appendChild(el('span', 'tyler-badge tyler-badge-safe', 'ENFORCED'));
        row.appendChild(el('span', '', String(layer)));
        aSec.appendChild(row);
      });
      wrap.appendChild(aSec);
    }

    // RF Mesh & Fresnel Time-Series Diagnostic Report (diagnose_rf_mesh)
    if (mode === 'diagnose_rf_mesh' && Array.isArray(data.corridor_diagnostics)) {
      if (data.summary_headline) {
        const hBanner = el('div', 'tyler-report-section');
        hBanner.style.cssText = 'border-color:rgba(56,189,248,0.45);background:rgba(56,189,248,0.08);';
        hBanner.appendChild(el('div', 'tyler-report-section-title', `OVERALL RF MESH HEALTH: ${data.overall_health || 'NOMINAL'}`));
        const hTxt = el('div', '', String(data.summary_headline));
        hTxt.style.cssText = 'font-weight:700;color:var(--tyler-text-strong);font-size:11.5px;';
        hBanner.appendChild(hTxt);
        wrap.appendChild(hBanner);
      }

      if (data.timeseries_summary) {
        const tsSum = data.timeseries_summary;
        const tsKpi = el('div', 'tyler-report-kpi-grid');
        [
          { lbl: 'SQLite Samples', val: String(tsSum.total_db_samples || 0) },
          { lbl: 'Window (Hours)', val: `${tsSum.window_hours || 24}h (${tsSum.window_samples || 0} pts)` },
          { lbl: 'Motion Events', val: String(tsSum.motion_events_in_window || 0) },
          { lbl: 'Cron Cadence', val: `Every ${tsSum.scheduled_interval_seconds || 180}s` }
        ].forEach((k) => {
          const box = el('div', 'tyler-report-kpi');
          box.appendChild(el('div', 'tyler-report-kpi-lbl', k.lbl));
          box.appendChild(el('div', 'tyler-report-kpi-val', k.val));
          tsKpi.appendChild(box);
        });
        wrap.appendChild(tsKpi);
      }

      if (Array.isArray(data.recommendations) && data.recommendations.length > 0) {
        const rSec = el('div', 'tyler-report-section');
        rSec.appendChild(el('div', 'tyler-report-section-title', 'GEORGE RF TOMOGRAPHY & BASELINE RECOMMENDATIONS'));
        data.recommendations.forEach((recText) => {
          const row = el('div', 'tyler-timeline-item');
          row.appendChild(el('span', 'tyler-badge tyler-badge-info', 'ADVISORY'));
          const s = el('span', '', String(recText));
          s.style.flex = '1';
          row.appendChild(s);
          rSec.appendChild(row);
        });
        wrap.appendChild(rSec);
      }

      const cSec = el('div', 'tyler-report-section');
      cSec.appendChild(el('div', 'tyler-report-section-title', `PER-CORRIDOR LINK MARGIN, WMM RTT & FRESNEL DIAGNOSTICS (${data.corridor_diagnostics.length})`));
      data.corridor_diagnostics.forEach((cd) => {
        const item = el('div', 'tyler-timeline-item');
        item.style.cssText = 'flex-direction:column;align-items:stretch;gap:4px;padding:8px;';
        const topRow = el('div');
        topRow.style.cssText = 'display:flex;justify-content:space-between;align-items:center;gap:6px;flex-wrap:wrap;';
        const title = el('span', '', `${cd.zone} (${cd.band || 'Wi-Fi'})`);
        title.style.cssText = 'font-weight:700;color:var(--tyler-text-strong);';
        topRow.appendChild(title);

        const badgeWrap = el('div');
        badgeWrap.style.cssText = 'display:flex;gap:4px;flex-wrap:wrap;';
        const lgCls = cd.link_grade === 'WEAK_EDGE' ? 'tyler-badge-warn' : (cd.link_grade === 'EXCELLENT' || cd.link_grade === 'GOOD' ? 'tyler-badge-safe' : 'tyler-badge-neutral');
        badgeWrap.appendChild(el('span', `tyler-badge ${lgCls}`, `LINK: ${cd.link_grade}`));
        const msCls = cd.motion_state === 'motion_detected' ? 'tyler-badge-danger' : (cd.motion_state === 'presence_shift' ? 'tyler-badge-warn' : 'tyler-badge-safe');
        badgeWrap.appendChild(el('span', `tyler-badge ${msCls}`, String(cd.motion_state || 'quiet').toUpperCase()));
        topRow.appendChild(badgeWrap);
        item.appendChild(topRow);

        const metricsTxt = [
          cd.last_rssi_dbm !== null && cd.last_rssi_dbm !== undefined ? `RSSI: ${cd.last_rssi_dbm} dBm (Base: ${cd.baseline_rssi_dbm ?? 'N/A'} dBm, Δ${cd.baseline_drift_db >= 0 ? '+' : ''}${cd.baseline_drift_db} dB)` : 'RSSI: Passive / WMM RTT Only',
          cd.fresnel_r1_m !== undefined ? `r₁≈${cd.fresnel_r1_m}m (D≈${cd.est_span_m}m, λ=${cd.wavelength_cm}cm)` : null,
          cd.last_snr_db !== null && cd.last_snr_db !== undefined ? `SNR: ${cd.last_snr_db} dB (Noise: ${cd.last_noise_dbm} dBm)` : null,
          cd.last_rtt_ms !== null && cd.last_rtt_ms !== undefined ? `RTT: ${cd.last_rtt_ms} ms (Avg: ${cd.avg_rtt_ms ?? cd.last_rtt_ms} ms)` : null,
          `Fresnel P2P: ${cd.p2p_swing_db} dB (σ=${cd.std_db} dB, CUSUM=${cd.cusum_db ?? 0} dB) • ${cd.samples_in_window || 0} SQLite pts`
        ].filter(Boolean).join(' • ');
        const mLine = el('div', 'tyler-card-sub', metricsTxt);
        mLine.style.fontFamily = 'var(--font-mono)';
        item.appendChild(mLine);

        if (Array.isArray(cd.findings) && cd.findings.length > 0) {
          cd.findings.forEach((fStr) => {
            const fEl = el('div', 'tyler-card-sub', `• ${fStr}`);
            fEl.style.color = 'var(--tyler-text)';
            item.appendChild(fEl);
          });
        }
        cSec.appendChild(item);
      });
      wrap.appendChild(cSec);
    }

    // Compass-Calibrated Property Perimeter Guard Report (perimeter_guard)
    if (mode === 'perimeter_guard' || data.perimeter_status) {
      const isAlert = data.perimeter_status === 'PERIMETER_ALERT';
      const pBanner = el('div', 'tyler-report-section');
      pBanner.style.cssText = isAlert
        ? 'border-color:rgba(239,68,68,0.55);background:rgba(239,68,68,0.10);'
        : 'border-color:rgba(16,185,129,0.45);background:rgba(16,185,129,0.08);';
      pBanner.appendChild(el('div', 'tyler-report-section-title', `PROPERTY PERIMETER STATUS: ${data.perimeter_status || 'CLEAR'}`));
      pBanner.appendChild(el('div', 'tyler-card-sub', `Sensor Backend: ${data.sensor_backend || 'linux_nl80211 / wsl_netsh'} • Common-Mode Shift: ${fmtSignedDb(data.common_mode_db || 0)} • South-Wall Clock Triangulation Age: ${data.clock_triangulation_age_s ?? '—'}s`));
      wrap.appendChild(pBanner);

      const alerts = Array.isArray(data.perimeter_alerts) ? data.perimeter_alerts : [];
      const aSec = el('div', 'tyler-report-section');
      aSec.appendChild(el('div', 'tyler-report-section-title', `CORROBORATED PERIMETER ALERTS (${alerts.length})`));
      if (alerts.length === 0) {
        aSec.appendChild(el('div', 'tyler-card-sub', '✅ Zero corroborated exterior perimeter breaches, approach vectors, or close-proximity transient APs detected.'));
      } else {
        alerts.forEach((al) => {
          const row = el('div', 'tyler-timeline-item');
          row.appendChild(el('span', 'tyler-badge tyler-badge-danger', String(al.verdict || 'ALERT')));
          row.appendChild(el('span', '', `[${al.sector || 'PERIMETER'}] ${al.interpretation || al.ssid || ''}`));
          aSec.appendChild(row);
        });
      }
      wrap.appendChild(aSec);

      const suppressed = Array.isArray(data.suppressed_neighbor_events) ? data.suppressed_neighbor_events : [];
      if (suppressed.length > 0) {
        const sSec = el('div', 'tyler-report-section');
        sSec.appendChild(el('div', 'tyler-report-section-title', `SUPPRESSED SINGLE-CHORD NEIGHBOR EVENTS (${suppressed.length})`));
        suppressed.forEach((sp) => {
          const row = el('div', 'tyler-timeline-item');
          row.appendChild(el('span', 'tyler-badge tyler-badge-sandbox', 'SUPPRESSED'));
          row.appendChild(el('span', '', `[${sp.sector || 'NEIGHBOR'}] ${sp.zone || ''}: ${sp.interpretation || 'Single-chord internal neighbor motion suppressed.'}`));
          sSec.appendChild(row);
        });
        wrap.appendChild(sSec);
      }

      if (Array.isArray(data.exterior_chords) && data.exterior_chords.length > 0) {
        const eSec = el('div', 'tyler-report-section');
        eSec.appendChild(el('div', 'tyler-report-section-title', `MONITORED EXTERIOR PERIMETER CHORDS (${data.exterior_chords.length})`));
        data.exterior_chords.forEach((ec) => {
          const row = el('div', 'tyler-timeline-item');
          const st = String(ec.motion_state || 'quiet');
          const bCls = st === 'motion_detected' ? 'tyler-badge-danger' : st === 'presence_shift' ? 'tyler-badge-warn' : 'tyler-badge-safe';
          row.appendChild(el('span', `tyler-badge ${bCls}`, `${ec.compass_sector || 'PERIM'} • ${st.toUpperCase()}`));
          row.appendChild(el('span', '', `${ec.zone} (${ec.band || '2.4 GHz'}) — Live: ${ec.last_rssi_dbm ?? '—'} dBm (Base: ${ec.baseline_rssi_dbm ?? '—'} dBm, Δ ${fmtSignedDb(ec.baseline_drift_db || 0)}, P2P: ${ec.p2p_swing_db ?? 0} dB, CUSUM: ${ec.cusum_db ?? 0} dB)`));
          eSec.appendChild(row);
        });
        wrap.appendChild(eSec);
      }
    }

    // Generic summary fallback so every action has clear human-readable key-values
    const summaryKeys = Object.entries(data).filter(([k, v]) => (
      !['ok', 'action', 'mode', 'timestamp', 'raw_output', 'airlock_layers', 'diffs', 'findings', 'corridors', 'transmitters'].includes(k) &&
      (typeof v === 'string' || typeof v === 'number' || typeof v === 'boolean')
    ));
    if (summaryKeys.length > 0) {
      const kpiGrid = el('div', 'tyler-report-kpi-grid');
      summaryKeys.slice(0, 8).forEach(([k, v]) => {
        const box = el('div', 'tyler-report-kpi');
        box.appendChild(el('div', 'tyler-report-kpi-lbl', k.replace(/_/g, ' ').toUpperCase()));
        box.appendChild(el('div', 'tyler-report-kpi-val', String(v)));
        kpiGrid.appendChild(box);
      });
      wrap.appendChild(kpiGrid);
    }

    view.appendChild(wrap);
  }

  // --- LAN Device Registry & Trust Matrix ---
  function renderDeviceRegistry(devices) {
    const tbody = document.getElementById('tylerDeviceTableBody');
    if (!tbody) return;
    clearNode(tbody);

    if (!Array.isArray(devices) || devices.length === 0) {
      const tr = el('tr');
      const td = el('td', '', 'No LAN devices found. Click "Run LAN Census Sweep" to discover endpoints.', { colspan: '6' });
      td.style.padding = '12px';
      tr.appendChild(td);
      tbody.appendChild(tr);
      return;
    }

    const filtered = devices.filter((d) => {
      const trust = String(d.trust_level || 'unknown');
      if (state.deviceFilter === 'untrusted') return trust === 'untrusted' || trust === 'unknown';
      if (state.deviceFilter === 'trusted') return trust === 'trusted';
      if (state.deviceFilter === 'known_iot') return trust === 'known_iot';
      if (state.deviceFilter === 'online') return Boolean(d.online);
      return true;
    });

    filtered.forEach((d) => {
      const ip = String(d.ip || '');
      const host = String(d.label || d.hostname || 'Unknown');
      const mac = String(d.mac || '');
      const vendor = String(d.vendor_oui || d.vendor || 'Unknown Vendor');
      const trust = String(d.trust_level || 'unknown');
      const fp = d.fingerprint || {};
      const base = d.baseline || {};
      const openPorts = Array.isArray(fp.open_ports) && fp.open_ports.length > 0
        ? fp.open_ports
        : Array.isArray(base.baseline_ports)
          ? base.baseline_ports
          : [];

      const tr = el('tr');
      if (state.selectedDeviceIp === ip) {
        tr.classList.add('selected-row');
      }

      // Col 1: IP + Online Dot + Protected Badge
      const tdIp = el('td');
      const ipWrap = el('div');
      ipWrap.style.cssText = 'display:flex;align-items:center;gap:6px;';
      const dot = el('span');
      dot.style.cssText = `width:7px;height:7px;border-radius:50%;display:inline-block;background:${d.online ? '#10b981' : '#64748b'};`;
      const ipTxt = el('span', '', ip);
      ipTxt.style.cssText = 'font-weight:700;color:var(--tyler-text-strong);';
      ipWrap.appendChild(dot);
      ipWrap.appendChild(ipTxt);
      if (d.protected) {
        ipWrap.appendChild(el('span', 'tyler-badge tyler-badge-safe', 'PROTECTED'));
      }
      tdIp.appendChild(ipWrap);

      // Col 2: Hostname / Label + Forensic Clue subtitle
      const tdHost = el('td');
      const hostMain = el('div', '', host);
      hostMain.style.cssText = 'font-weight:600;color:var(--tyler-text-strong);';
      tdHost.appendChild(hostMain);
      if (fp.os_guess || fp.forensic_clue) {
        const clueSub = el('div', 'tyler-card-sub', fp.os_guess || String(fp.forensic_clue).slice(0, 72));
        clueSub.style.fontSize = '10px';
        tdHost.appendChild(clueSub);
      }

      // Col 3: MAC / Vendor OUI
      const tdMac = el('td');
      tdMac.appendChild(el('div', '', mac));
      const vSub = el('div', 'tyler-card-sub', vendor);
      vSub.style.fontSize = '10px';
      tdMac.appendChild(vSub);

      // Col 4: Open Ports & B-Cell Baseline
      const tdPorts = el('td');
      if (openPorts.length > 0) {
        const pWrap = el('div', 'tyler-port-list');
        openPorts.slice(0, 5).forEach((p) => pWrap.appendChild(el('span', 'tyler-port-pill', String(p))));
        if (openPorts.length > 5) pWrap.appendChild(el('span', 'tyler-port-pill', `+${openPorts.length - 5}`));
        tdPorts.appendChild(pWrap);
      } else {
        tdPorts.appendChild(el('span', 'tyler-card-sub', '0 Open Ports'));
      }

      // Col 5: Trust Tier Badge
      const tdTrust = el('td');
      let tBadgeCls = 'tyler-badge-neutral';
      if (trust === 'trusted') tBadgeCls = 'tyler-badge-safe';
      else if (trust === 'known_iot') tBadgeCls = 'tyler-badge-info';
      else if (trust === 'untrusted') tBadgeCls = 'tyler-badge-danger';
      else if (trust === 'quarantined') tBadgeCls = 'tyler-badge-sandbox';
      tdTrust.appendChild(el('span', `tyler-badge ${tBadgeCls}`, trust.toUpperCase()));

      // Col 6: Actions (Inspect + Probe + Trust)
      const tdAct = el('td');
      const actWrap = el('div');
      actWrap.style.cssText = 'display:flex;gap:4px;flex-wrap:wrap;';

      const mkProbeBtn = (lbl, act, title) => {
        const b = el('button', 'tactile-btn tyler-row-probe', lbl, {
          'data-ip': ip,
          'data-act': act,
          title: title || lbl
        });
        b.style.cssText = 'font-size: 9.5px; padding: 2px 6px;';
        return b;
      };
      const mkTrustBtn = (lbl, lvl, col) => {
        const b = el('button', 'tactile-btn tyler-row-trust', lbl, {
          'data-mac': mac,
          'data-trust': lvl
        });
        b.style.cssText = `font-size: 9.5px; padding: 2px 6px; color: ${col};`;
        return b;
      };

      const btnInspect = el('button', 'tactile-btn', 'DOSSIER');
      btnInspect.style.cssText = 'font-size: 9.5px; padding: 2px 6px; border-color: rgba(56,189,248,0.45); color: #7dd3fc;';
      btnInspect.addEventListener('click', (ev) => {
        ev.stopPropagation();
        selectDeviceRow(d);
      });

      actWrap.appendChild(btnInspect);
      actWrap.appendChild(mkProbeBtn('NMAP', 'fingerprint', 'Deep Nmap Service & OS Fingerprint'));
      actWrap.appendChild(mkProbeBtn('VULN', 'vuln_audit', 'Active Nmap NSE Vulnerability Audit'));
      actWrap.appendChild(mkProbeBtn('TSHARK', 'traffic', '8-Second Tshark Packet Capture'));
      if (trust !== 'trusted') {
        actWrap.appendChild(mkTrustBtn('TRUST', 'trusted', '#6ee7b7'));
      }
      if (trust !== 'known_iot') {
        actWrap.appendChild(mkTrustBtn('IOT', 'known_iot', '#7dd3fc'));
      }
      if (trust !== 'untrusted' && !d.protected) {
        actWrap.appendChild(mkTrustBtn('FLAG', 'untrusted', '#fca5a5'));
      }

      tdAct.appendChild(actWrap);

      tr.appendChild(tdIp);
      tr.appendChild(tdHost);
      tr.appendChild(tdMac);
      tr.appendChild(tdPorts);
      tr.appendChild(tdTrust);
      tr.appendChild(tdAct);

      tr.addEventListener('click', (ev) => {
        if (ev.target.closest('button')) return;
        selectDeviceRow(d);
      });

      tbody.appendChild(tr);
    });
  }

  function selectDeviceRow(device) {
    if (!device) return;
    state.selectedDeviceIp = String(device.ip || '');
    state.selectedCorridorKey = '';
    const ipInput = document.getElementById('tylerTargetIpInput');
    if (ipInput) ipInput.value = state.selectedDeviceIp;
    if (state.lastStatus && Array.isArray(state.lastStatus.devices)) {
      renderDeviceRegistry(state.lastStatus.devices);
    }
    renderDeviceDossier(device);
  }

  // --- Main Status Loader (Hydrates All Legacy IDs + New Visual Components) ---
  function updateLiveSyncButtonUi() {
    const btn = document.getElementById('btnTylerLiveSyncToggle');
    if (!btn) return;
    if (!state.liveSyncEnabled) {
      btn.classList.remove('active');
      btn.style.borderColor = 'var(--tyler-border)';
      btn.style.color = 'var(--tyler-text-dim)';
      btn.textContent = '○ LIVE 15s: PAUSED';
      return;
    }
    btn.classList.add('active');
    btn.style.borderColor = 'var(--tyler-safe-border)';
    btn.style.color = 'var(--tyler-safe-text)';
    if (state.liveSyncFetching) {
      btn.textContent = '◉ SYNCING RF...';
    } else {
      const remSec = state.liveSyncNextAt > 0
        ? Math.max(0, Math.ceil((state.liveSyncNextAt - Date.now()) / 1000))
        : 15;
      btn.textContent = `● LIVE 15s (${remSec}s)`;
    }
  }

  async function loadTylerData(opts) {
    const silent = Boolean(opts && opts.silent);
    if (state.liveSyncFetching && silent) return;
    state.liveSyncFetching = true;
    state.liveSyncNextAt = Date.now() + LIVE_SYNC_INTERVAL_MS;
    updateLiveSyncButtonUi();

    const kaliEl = document.getElementById('tylerKaliStatus');
    const countsEl = document.getElementById('tylerDeviceCounts');
    const untrustedEl = document.getElementById('tylerUntrustedCount');
    const blockedEl = document.getElementById('tylerBlockedCount');
    const meshKpiEl = document.getElementById('tylerMeshStatusKpi');
    const meshSubEl = document.getElementById('tylerMeshSubLabel');
    const canaryBadge = document.getElementById('tylerCanaryBadge');
    const policySelect = document.getElementById('tylerResponseModeSelect');
    const plansList = document.getElementById('tylerDefensePlansList');
    const rulesList = document.getElementById('tylerTsharkRulesList');

    try {
      const res = await fetch('/api/tyler/status');
      const data = await res.json();
      state.lastStatus = data;
      if (Array.isArray(data.room_layout) && data.room_layout.length > 0) {
        ROOM_LAYOUT = data.room_layout;
      }

      // 1. Top KPI Strip
      if (kaliEl) {
        const kObj = data.kali || data.kali_container || {};
        const running = Boolean(kObj.running);
        kaliEl.textContent = running ? 'ONLINE (george-kali-tyler)' : 'OFFLINE';
        kaliEl.style.color = running ? '#10b981' : '#ef4444';
      }
      const counts = data.counts || data.counts_by_trust || {};
      const total = counts.total || data.total_devices || 0;
      const trusted = (counts.trusted || 0) + (counts.known_iot || 0);
      const untrusted = counts.untrusted || 0;
      if (countsEl) countsEl.textContent = `${trusted} TRUSTED / ${total} TOTAL`;
      if (untrustedEl) {
        untrustedEl.textContent = `${untrusted} FLAGGED`;
        untrustedEl.style.color = untrusted > 0 ? '#f59e0b' : '#10b981';
      }
      const activeBlocks = counts.quarantined || (data.active_interventions || []).length;
      if (blockedEl) blockedEl.textContent = `${activeBlocks} BLOCKED`;

      const rfChords = Array.isArray(data.peripheral_rf_telemetry) ? data.peripheral_rf_telemetry : [];
      const activeShifts = rfChords.filter((c) => c.motion_state && c.motion_state !== 'quiet').length;
      if (meshKpiEl) {
        meshKpiEl.textContent = `${rfChords.length} CHORDS (${activeShifts} ACTIVE)`;
        meshKpiEl.style.color = activeShifts > 0 ? '#f59e0b' : '#10b981';
      }
      if (meshSubEl) {
        const triTotal = data.cached_triangulation ? (data.cached_triangulation.total_transmitters || 0) : 0;
        meshSubEl.textContent = `2-Pt Triangulation: ${triTotal} APs`;
      }

      // 2. Canary & Immune Policy
      if (canaryBadge && data.canary_trap) {
        const cRun = Boolean(data.canary_trap.running);
        const cHits = data.canary_trap.hits_count || 0;
        canaryBadge.textContent = cRun ? `CANARY ARMED (${cHits} HITS)` : `CANARY STANDBY (${cHits} HITS)`;
        canaryBadge.style.color = cRun ? '#10b981' : '#f59e0b';
      }
      if (policySelect && data.policy && data.policy.response_mode) {
        policySelect.value = data.policy.response_mode;
      }

      // 3. Tier B Defense Plans Queue
      if (plansList) {
        clearNode(plansList);
        const plans = Array.isArray(data.defense_plans) ? data.defense_plans : [];
        if (plans.length === 0) {
          plansList.textContent = 'No Tier B defense plans staged.';
        } else {
          plans.forEach((p) => {
            const row = el('div', 'tyler-timeline-item');
            const isPend = p.status === 'pending_approval';
            const badge = el('span', `tyler-badge ${isPend ? 'tyler-badge-warn' : 'tyler-badge-neutral'}`, p.status || 'staged');
            const info = el('span', '', `[${p.plan_id}] ${p.target_ip} → ${p.proposed_mode}`);
            info.style.flex = '1';
            row.appendChild(badge);
            row.appendChild(info);
            if (isPend) {
              const btnWrap = el('div');
              btnWrap.style.cssText = 'display:flex;gap:4px;';
              const bApp = el('button', 'tactile-btn', 'APPROVE');
              bApp.style.cssText = 'font-size:9px;padding:2px 6px;border-color:#10b981;color:#6ee7b7;';
              bApp.addEventListener('click', () => runTylerAction({ action: 'intervene', mode: 'approve_plan', plan_id: p.plan_id }, `Approve Plan ${p.plan_id}`));
              const bRej = el('button', 'tactile-btn', 'REJECT');
              bRej.style.cssText = 'font-size:9px;padding:2px 6px;border-color:#ef4444;color:#fca5a5;';
              bRej.addEventListener('click', () => runTylerAction({ action: 'intervene', mode: 'reject_plan', plan_id: p.plan_id }, `Reject Plan ${p.plan_id}`));
              btnWrap.appendChild(bApp);
              btnWrap.appendChild(bRej);
              row.appendChild(btnWrap);
            }
            plansList.appendChild(row);
          });
        }
      }

      // 4. Collaborative tshark Watchlist Rules
      if (rulesList && data.tshark_watch && Array.isArray(data.tshark_watch.rules)) {
        clearNode(rulesList);
        data.tshark_watch.rules.forEach((r) => {
          const item = el('div', 'tyler-timeline-item');
          const hitBadge = el('span', `tyler-badge ${(r.hit_count || 0) > 0 ? 'tyler-badge-warn' : 'tyler-badge-safe'}`, `HITS: ${r.hit_count || 0}`);
          const left = el('div');
          left.style.flex = '1';
          const rName = el('div', '', r.name);
          rName.style.cssText = 'font-weight:700;color:var(--tyler-text-strong);';
          const rFilter = el('div', 'tyler-card-sub', r.display_filter);
          rFilter.style.fontFamily = 'var(--font-mono)';
          left.appendChild(rName);
          left.appendChild(rFilter);

          const bDel = el('button', 'tactile-btn', 'REMOVE');
          bDel.style.cssText = 'font-size:9px;padding:2px 6px;border-color:#ef4444;color:#fca5a5;';
          bDel.addEventListener('click', () => runTylerAction({ action: 'tshark_watch', mode: 'remove', name: r.name }, `Remove Rule ${r.name}`));
          item.appendChild(hitBadge);
          item.appendChild(left);
          item.appendChild(bDel);
          rulesList.appendChild(item);
        });
      }

      // 5. Wi-Fi Secondary Radio Badge & Claimed Peripherals
      const wifiBadge = document.getElementById('tylerWifiAdapterBadge');
      if (wifiBadge && data.wifi_adapter) {
        const wa = data.wifi_adapter;
        const safeTag = wa.safe_secondary_radio ? 'SAFE SECONDARY RADIO (eth0 PRIMARY)' : 'SINGLE RADIO';
        wifiBadge.textContent = `${wa.adapter_name || 'wlan0'} (${wa.wsl_interface || 'eth1'}) • ${String(wa.state || 'disconnected').toUpperCase()} • ${safeTag}`;
        wifiBadge.style.color = wa.safe_secondary_radio ? '#10b981' : '#f59e0b';
      }

      const periphBox = document.getElementById('tylerClaimedPeripheralsList');
      if (periphBox) {
        clearNode(periphBox);
        if (Array.isArray(data.claimed_peripherals) && data.claimed_peripherals.length > 0) {
          data.claimed_peripherals.forEach((p) => {
            const card = el('div', 'tyler-report-section');
            card.style.cssText = 'margin-top:0;margin-bottom:8px;border-color:rgba(16,185,129,0.35);background:rgba(16,185,129,0.06);display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:8px;';
            const left = el('div');
            const triSum = (p.last_telemetry && p.last_telemetry.last_triangulation_summary) ? p.last_telemetry.last_triangulation_summary : null;
            const triText = triSum ? ` • Dual-Band 2-Pt Triangulation: ${triSum.total_transmitters} APs (${triSum.five_ghz_discovered_by_peripheral} on 5GHz)` : '';
            const title = el('div', '', `◉ Claimed Sensor B: ${p.model_name || 'Cast Soft-AP'} [${p.bssid}]`);
            title.style.cssText = 'font-weight:700;color:#6ee7b7;font-size:12px;';
            const sub = el('div', 'tyler-card-sub', `Active OTA Beacon SSID: "${p.live_beacon_ssid || p.current_ssid}" • Factory Baseline: "${p.original_ssid}" • Role: ${p.current_role}${triText}`);
            left.appendChild(title);
            left.appendChild(sub);
            card.appendChild(left);
            card.appendChild(el('span', 'tyler-badge tyler-badge-safe', 'CLAIMED SENSOR B'));
            periphBox.appendChild(card);
          });
        }
      }

      // 6. Render Interactive 2D RF Mesh Radar, Corridor Cards, SQLite Trend Chart, Triangulation & Motion Timeline
      renderMeshRadarSvg(data);
      renderCorridorCards(rfChords);
      renderRfTrendChart(rfChords, data.rf_timeseries_stats || {});
      renderTriangulationVisualizer(data.cached_triangulation);
      renderMotionTimeline(data.rf_motion_events || []);

      // 7. Render 802.11 Wireless Airspace Table
      const wifiBody = document.getElementById('tylerWifiAirspaceBody');
      if (wifiBody && Array.isArray(data.wifi_airspace) && data.wifi_airspace.length > 0) {
        clearNode(wifiBody);
        data.wifi_airspace.forEach((w) => {
          const tr = el('tr');
          const tdSsid = el('td', '', w.ssid || '<Hidden SSID>');
          tdSsid.style.cssText = 'font-weight:700;color:var(--tyler-text-strong);';
          const tdBssid = el('td', '', `${w.bssid || ''} (${w.vendor_oui || ''})`);
          tdBssid.style.color = 'var(--tyler-text-dim)';
          const rssiLabel = w.rssi_dbm != null ? `${w.rssi_dbm} dBm (${w.signal_pct || 0}%)` : `${w.signal_pct || 0}%`;
          const compLabel = w.compass_sector ? ` • ${w.compass_sector}` : '';
          const tdCh = el('td', '', `${w.band || ''} Ch.${w.channel || 0} • ${rssiLabel}${compLabel}`);

          const tdCls = el('td');
          const cls = String(w.classification || 'neighbor');
          let bCls = 'tyler-badge-neutral';
          if (cls === 'open_soft_ap' || cls === 'evil_twin') bCls = 'tyler-badge-danger';
          else if (cls === 'appliance_ap') bCls = 'tyler-badge-warn';
          else if (cls === 'home_ap') bCls = 'tyler-badge-safe';
          tdCls.appendChild(el('span', `tyler-badge ${bCls}`, `${w.auth || 'OPEN'} • ${cls.toUpperCase()}`));

          const tdAct = el('td');
          tdAct.style.cssText = 'display:flex;gap:4px;flex-wrap:wrap;';
          if (w.ssid) {
            const bInt = el('button', 'tactile-btn', '◈ AIRLOCK PROBE');
            bInt.style.cssText = 'font-size:9.5px;padding:2px 6px;border-color:#10b981;color:#6ee7b7;';
            bInt.addEventListener('click', () => {
              const sIn = document.getElementById('tylerWifiSsidInput');
              if (sIn) sIn.value = w.ssid;
              runTylerAction({ action: 'wifi_spelunk', mode: 'interrogate_soft_ap', ssid: w.ssid, bssid: w.bssid }, `6-Layer Airlock Soft-AP Interrogation (${w.ssid})`);
            });
            tdAct.appendChild(bInt);
            if (cls === 'open_soft_ap') {
              const bSurp = el('button', 'tactile-btn', '⚡ SURPRISE');
              bSurp.style.cssText = 'font-size:9.5px;padding:2px 6px;border-color:#f59e0b;color:#fde68a;';
              bSurp.addEventListener('click', () => {
                const sIn = document.getElementById('tylerWifiSsidInput');
                if (sIn) sIn.value = w.ssid;
                runTylerAction({ action: 'wifi_spelunk', mode: 'interrogate_soft_ap', ssid: w.ssid, bssid: w.bssid, surprise: true }, `Airlock Interrogation + Surprise (${w.ssid})`);
              });
              tdAct.appendChild(bSurp);
            }
          }
          tr.appendChild(tdSsid);
          tr.appendChild(tdBssid);
          tr.appendChild(tdCh);
          tr.appendChild(tdCls);
          tr.appendChild(tdAct);
          wifiBody.appendChild(tr);
        });
      }

      // 8. Network Designations
      const desList = document.getElementById('tylerDesignationsList');
      if (data.network_designations) {
        const nd = data.network_designations;
        const cAuto = document.getElementById('tylerDesAutoSwitch');
        const cWifi = document.getElementById('tylerDesWifiDefense');
        const cLock = document.getElementById('tylerDesLockRoles');
        if (cAuto) cAuto.checked = Boolean(nd.auto_switch_posture !== false);
        if (cWifi) cWifi.checked = Boolean(nd.wifi_defense_enabled !== false);
        if (cLock) cLock.checked = Boolean(nd.lock_endpoint_roles !== false);
        if (desList && nd.subnets) {
          clearNode(desList);
          Object.entries(nd.subnets).forEach(([cidr, meta]) => {
            const row = el('div', 'tyler-timeline-item');
            const isHome = meta.designation === 'home_trusted';
            row.appendChild(el('span', `tyler-badge ${isHome ? 'tyler-badge-safe' : 'tyler-badge-warn'}`, String(meta.designation || 'foreign_cautious').toUpperCase()));
            row.appendChild(el('span', '', `${cidr} — ${meta.label || cidr} (ARP Shield: ${meta.arp_shield ? 'ON' : 'OFF'})`));
            desList.appendChild(row);
          });
        }
      }

      // 9. LAN Device Registry
      if (Array.isArray(data.devices)) {
        renderDeviceRegistry(data.devices);
      }

      // 10. Default Initial Inspector View if empty, or live-refresh active corridor dossier
      const view = document.getElementById('tylerDiagnosticReportView');
      if (view && view.children.length === 0) {
        const defaultChord = rfChords.find((c) => c.motion_state !== 'quiet') || rfChords[0];
        if (defaultChord) {
          state.selectedCorridorKey = getChordKey(defaultChord);
          renderCorridorDossier(defaultChord);
        } else if (Array.isArray(data.devices) && data.devices.length > 0) {
          const flagged = data.devices.find((d) => d.trust_level === 'untrusted') || data.devices[0];
          renderDeviceDossier(flagged);
        }
      } else if (silent && state.selectedCorridorKey && !state.lastActionReport) {
        const liveChord = rfChords.find((c) => getChordKey(c) === state.selectedCorridorKey);
        if (liveChord) {
          renderCorridorDossier(liveChord);
        }
      }
    } catch (_err) {
      if (!silent && kaliEl) kaliEl.textContent = 'ERROR LOADING';
    } finally {
      state.liveSyncFetching = false;
      state.liveSyncNextAt = Date.now() + LIVE_SYNC_INTERVAL_MS;
      updateLiveSyncButtonUi();
    }
  }

  // --- Action Executor (Updates Both Structured Inspector & Raw JSON Console) ---
  async function runTylerAction(payload, label) {
    state.actionInFlight = true;
    const out = document.getElementById('tylerConsoleOutput');
    const view = document.getElementById('tylerDiagnosticReportView');
    const titleEl = document.getElementById('tylerInspectorTitle');
    const badgeEl = document.getElementById('tylerInspectorModeBadge');

    if (out) out.textContent = `[KALI // TYLER] Running ${label}...`;
    if (titleEl) titleEl.textContent = `EXECUTING // ${label}`;
    if (badgeEl) {
      badgeEl.className = 'tyler-badge tyler-badge-warn';
      badgeEl.textContent = 'RUNNING...';
    }
    if (view) {
      clearNode(view);
      const loadingCard = el('div', 'tyler-report-card');
      loadingCard.appendChild(el('div', 'tyler-report-title', `⏳ Executing ${label}...`));
      loadingCard.appendChild(el('div', 'tyler-card-sub', `Dispatching command payload (${JSON.stringify(payload)}) to george-kali-tyler...`));
      view.appendChild(loadingCard);
    }

    try {
      const res = await fetch('/api/tyler/action', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
      });
      const data = await res.json();
      state.lastActionReport = data;
      state.lastActionLabel = label;
      state.lastActionPayload = payload;

      if (out) out.textContent = JSON.stringify(data, null, 2);
      renderStructuredActionReport(data, label, payload);
      await loadTylerData();
    } catch (err) {
      if (out) out.textContent = `Error executing ${label}: ${err.message}`;
      if (view) {
        clearNode(view);
        const errCard = el('div', 'tyler-report-card');
        errCard.appendChild(el('div', 'tyler-report-title', `❌ Error Executing ${label}`));
        errCard.appendChild(el('div', 'tyler-card-sub', String(err.message)));
        view.appendChild(errCard);
      }
    } finally {
      state.actionInFlight = false;
    }
  }

  // --- Event Listener Initialization ---
  function isTylerPaneVisible() {
    if (document.hidden) return false;
    const pane = document.getElementById('pane-tyler');
    const drawer = document.getElementById('toolCribDrawer');
    if (!pane || !pane.classList.contains('active')) return false;
    if (drawer && !drawer.classList.contains('open')) return false;
    return true;
  }

  function startTylerLiveSyncLoop() {
    if (state.liveSyncTimerId) return;
    state.liveSyncNextAt = Date.now() + LIVE_SYNC_INTERVAL_MS;
    state.liveSyncTimerId = window.setInterval(() => {
      if (!isTylerPaneVisible()) return;
      updateLiveSyncButtonUi();
      if (!state.liveSyncEnabled || state.actionInFlight || state.liveSyncFetching) return;
      if (Date.now() >= state.liveSyncNextAt) {
        loadTylerData({ silent: true });
      }
    }, 1000);
  }

  function initTylerModule() {
    if (state.initialized) return;
    state.initialized = true;
    startTylerLiveSyncLoop();

    const btnLiveSync = document.getElementById('btnTylerLiveSyncToggle');
    if (btnLiveSync) {
      btnLiveSync.addEventListener('click', () => {
        state.liveSyncEnabled = !state.liveSyncEnabled;
        if (state.liveSyncEnabled) {
          state.liveSyncNextAt = Date.now() + LIVE_SYNC_INTERVAL_MS;
          loadTylerData({ silent: true });
        } else {
          updateLiveSyncButtonUi();
        }
      });
    }

    // Workspace Tabs
    document.querySelectorAll('[data-tyler-tab]').forEach((btn) => {
      btn.addEventListener('click', () => {
        switchTylerTab(btn.getAttribute('data-tyler-tab'));
      });
    });

    // Operator Field Guide Drawer Toggle
    const btnGuide = document.getElementById('btnTylerGuideToggle');
    if (btnGuide) btnGuide.addEventListener('click', toggleGuideDrawer);

    // Raw JSON Toggle
    const btnRaw = document.getElementById('btnTylerToggleRawJson');
    if (btnRaw) btnRaw.addEventListener('click', () => toggleRawConsole());

    // Device Filter Pills
    document.querySelectorAll('[data-tyler-dev-filter]').forEach((btn) => {
      btn.addEventListener('click', () => {
        state.deviceFilter = btn.getAttribute('data-tyler-dev-filter') || 'all';
        document.querySelectorAll('[data-tyler-dev-filter]').forEach((b) => {
          b.classList.toggle('active', b === btn);
        });
        if (state.lastStatus && Array.isArray(state.lastStatus.devices)) {
          renderDeviceRegistry(state.lastStatus.devices);
        }
      });
    });

    // Top Command Bar
    const btnRefresh = document.getElementById('btnTylerRefresh');
    if (btnRefresh) btnRefresh.addEventListener('click', loadTylerData);
    const btnCensus = document.getElementById('btnTylerCensus');
    if (btnCensus) btnCensus.addEventListener('click', () => runTylerAction({ action: 'census' }, 'LAN ARP/Nmap Census Sweep'));
    const btnUpnp = document.getElementById('btnTylerUpnpAudit');
    if (btnUpnp) btnUpnp.addEventListener('click', () => runTylerAction({ action: 'upnp' }, 'UPnP IGD Port-Forward Audit'));
    const btnWifiScanTop = document.getElementById('btnTylerWifiScanTop');
    if (btnWifiScanTop) btnWifiScanTop.addEventListener('click', () => runTylerAction({ action: 'wifi_spelunk', mode: 'scan_airspace' }, '802.11 Wireless Airspace BSSID/SSID Scan'));
    const btnEmergReset = document.getElementById('btnTylerEmergencyReset');
    if (btnEmergReset) {
      btnEmergReset.addEventListener('click', () => {
        runTylerAction({ action: 'emergency_reset' }, 'EMERGENCY NETWORK RESET & FAIL-SAFE HEAL');
      });
    }

    // Tactical Probes & Host Interventions
    const ipInput = document.getElementById('tylerTargetIpInput');
    const getTargetIp = () => (ipInput ? ipInput.value.trim() : '');

    const btnFp = document.getElementById('btnTylerFingerprint');
    if (btnFp) {
      btnFp.addEventListener('click', () => {
        const ip = getTargetIp();
        if (ip) runTylerAction({ action: 'fingerprint', ip }, `Deep Nmap Fingerprint (${ip})`);
      });
    }
    const btnVuln = document.getElementById('btnTylerVulnAudit');
    if (btnVuln) {
      btnVuln.addEventListener('click', () => {
        const ip = getTargetIp();
        if (ip) runTylerAction({ action: 'vuln_audit', ip }, `Active Nmap NSE Vulnerability Audit (${ip})`);
      });
    }
    const btnDiff = document.getElementById('btnTylerBaselineDiff');
    if (btnDiff) {
      btnDiff.addEventListener('click', () => {
        const ip = getTargetIp() || 'all';
        runTylerAction({ action: 'baseline_diff', ip }, `Memory B-Cell Baseline Drift Audit (${ip})`);
      });
    }
    const btnTraffic = document.getElementById('btnTylerTraffic');
    if (btnTraffic) {
      btnTraffic.addEventListener('click', () => {
        const ip = getTargetIp();
        if (ip) runTylerAction({ action: 'traffic', ip, duration: 8 }, `Tshark DNS/SNI Capture (${ip})`);
      });
    }
    const btnEgress = document.getElementById('btnTylerEgressAudit');
    if (btnEgress) {
      btnEgress.addEventListener('click', () => {
        const ip = document.getElementById('tylerTargetIpInput')?.value?.trim() || 'all';
        runTylerAction({ action: 'egress_audit', ip, duration: 8 }, `IoT DNS/SNI Egress Baseline Audit (${ip})`);
      });
    }
    const btnSnap = document.getElementById('btnTylerForensicSnap');
    if (btnSnap) {
      btnSnap.addEventListener('click', () => {
        const ip = getTargetIp();
        if (ip) runTylerAction({ action: 'intervene', ip, mode: 'forensic_snap', duration: 6 }, `Forensic PCAP Snapshot (${ip})`);
      });
    }
    const btnBlock = document.getElementById('btnTylerBlockHost');
    if (btnBlock) {
      btnBlock.addEventListener('click', () => {
        const ip = getTargetIp();
        if (ip) runTylerAction({ action: 'intervene', ip, mode: 'quarantine' }, `Host Quarantine (${ip})`);
      });
    }
    const btnUnblock = document.getElementById('btnTylerUnblockHost');
    if (btnUnblock) {
      btnUnblock.addEventListener('click', () => {
        const ip = getTargetIp();
        if (ip) runTylerAction({ action: 'intervene', ip, mode: 'release' }, `Release Quarantine (${ip})`);
      });
    }

    // Standing Guards & Immune Posture
    const btnSavePol = document.getElementById('btnTylerSavePolicy');
    if (btnSavePol) {
      btnSavePol.addEventListener('click', () => {
        const sel = document.getElementById('tylerResponseModeSelect');
        const response_mode = sel ? sel.value : 'confirm';
        runTylerAction({ action: 'policy', response_mode }, `Update Tier B Posture -> ${response_mode.toUpperCase()}`);
      });
    }
    const btnCanStart = document.getElementById('btnTylerCanaryStart');
    if (btnCanStart) btnCanStart.addEventListener('click', () => runTylerAction({ action: 'canary', mode: 'start' }, 'Arm Canary Honeypot Listeners'));
    const btnCanStop = document.getElementById('btnTylerCanaryStop');
    if (btnCanStop) btnCanStop.addEventListener('click', () => runTylerAction({ action: 'canary', mode: 'stop' }, 'Disarm Canary Honeypot Listeners'));
    const btnArpEnf = document.getElementById('btnTylerArpEnforce');
    if (btnArpEnf) btnArpEnf.addEventListener('click', () => runTylerAction({ action: 'arp_shield', mode: 'enforce' }, 'Enforce Static Layer-2 ARP Shield'));
    const btnPatrol = document.getElementById('btnTylerImmunePatrol');
    if (btnPatrol) btnPatrol.addEventListener('click', () => runTylerAction({ action: 'immune_patrol', duration: 8 }, 'Natural Killer (NK) Cell Active LAN Patrol'));

    // Collaborative tshark Watchlist
    const btnTwTest = document.getElementById('btnTylerTsharkTest');
    if (btnTwTest) {
      btnTwTest.addEventListener('click', () => {
        const dfEl = document.getElementById('tylerTsharkFilterInput');
        const display_filter = dfEl ? dfEl.value.trim() : '';
        if (display_filter) runTylerAction({ action: 'tshark_watch', mode: 'test', display_filter }, `Validate tshark Filter (${display_filter})`);
      });
    }
    const btnTwAdd = document.getElementById('btnTylerTsharkAdd');
    if (btnTwAdd) {
      btnTwAdd.addEventListener('click', () => {
        const nmEl = document.getElementById('tylerTsharkNameInput');
        const dfEl = document.getElementById('tylerTsharkFilterInput');
        const name = nmEl ? nmEl.value.trim() : '';
        const display_filter = dfEl ? dfEl.value.trim() : '';
        if (name && display_filter) {
          runTylerAction({ action: 'tshark_watch', mode: 'add', name, display_filter }, `Add tshark Watch Filter (${name})`);
        }
      });
    }

    // 802.11 Wireless Airspace, Airlock & RF Mesh Operations
    const btnWifiScan = document.getElementById('btnTylerWifiScan');
    if (btnWifiScan) btnWifiScan.addEventListener('click', () => runTylerAction({ action: 'wifi_spelunk', mode: 'scan_airspace' }, '802.11 Wireless Airspace BSSID/SSID Scan'));
    const wifiSsidIn = document.getElementById('tylerWifiSsidInput');
    const getWifiSsid = () => (wifiSsidIn ? wifiSsidIn.value.trim() : '');

    const btnWifiInt = document.getElementById('btnTylerWifiInterrogate');
    if (btnWifiInt) {
      btnWifiInt.addEventListener('click', () => {
        const ssid = getWifiSsid();
        runTylerAction({ action: 'wifi_spelunk', mode: 'interrogate_soft_ap', ssid }, `6-Layer Airlock Soft-AP Interrogation (${ssid || 'Auto'})`);
      });
    }
    const btnWifiSurp = document.getElementById('btnTylerWifiSurprise');
    if (btnWifiSurp) {
      btnWifiSurp.addEventListener('click', () => {
        const ssid = getWifiSsid();
        runTylerAction({ action: 'wifi_spelunk', mode: 'interrogate_soft_ap', ssid, surprise: true }, `Airlock Interrogation + Surprise (${ssid || 'Auto'})`);
      });
    }
    const btnWifiDisc = document.getElementById('btnTylerWifiDisconnect');
    if (btnWifiDisc) btnWifiDisc.addEventListener('click', () => runTylerAction({ action: 'wifi_spelunk', mode: 'disconnect' }, 'Disconnect Wi-Fi 4 Radio & Purge Airlock'));

    const btnWifiPerim = document.getElementById('btnTylerWifiPerimeter');
    if (btnWifiPerim) {
      btnWifiPerim.addEventListener('click', () => {
        runTylerAction({ action: 'wifi_spelunk', mode: 'perimeter_guard', duration: 6 }, 'Compass-Calibrated Property Perimeter Guard (6s)');
      });
    }
    const btnRadarPerimQuick = document.getElementById('btnTylerRadarPerimeterQuick');
    if (btnRadarPerimQuick) {
      btnRadarPerimQuick.addEventListener('click', () => {
        runTylerAction({ action: 'wifi_spelunk', mode: 'perimeter_guard', duration: 6 }, 'Compass-Calibrated Property Perimeter Guard (6s)');
      });
    }

    const btnWifiMotion = document.getElementById('btnTylerWifiMotionSense');
    if (btnWifiMotion) {
      btnWifiMotion.addEventListener('click', () => {
        runTylerAction({ action: 'wifi_spelunk', mode: 'rf_motion_sense', duration: 6 }, 'Device-Free Wi-Fi RF Tomographic Motion & Presence Sensing (6s)');
      });
    }
    const btnRadarMotionQuick = document.getElementById('btnTylerRadarMotionQuick');
    if (btnRadarMotionQuick) {
      btnRadarMotionQuick.addEventListener('click', () => {
        runTylerAction({ action: 'wifi_spelunk', mode: 'rf_motion_sense', duration: 6 }, 'Device-Free Wi-Fi RF Tomographic Motion & Presence Sensing (6s)');
      });
    }
    const btnWifiPollMesh = document.getElementById('btnTylerWifiPollMesh');
    if (btnWifiPollMesh) {
      btnWifiPollMesh.addEventListener('click', () => {
        runTylerAction({ action: 'wifi_spelunk', mode: 'poll_lan_peripherals' }, 'Zero-Airlock Multi-Room LAN Cast & Nest 6GHz RF Mesh Poll');
      });
    }
    const btnRadarPollQuick = document.getElementById('btnTylerRadarPollQuick');
    if (btnRadarPollQuick) {
      btnRadarPollQuick.addEventListener('click', () => {
        runTylerAction({ action: 'wifi_spelunk', mode: 'poll_lan_peripherals' }, 'Zero-Airlock Multi-Room LAN Cast & Nest 6GHz RF Mesh Poll');
      });
    }
    const btnWifiTri = document.getElementById('btnTylerWifiTriangulate');
    if (btnWifiTri) {
      btnWifiTri.addEventListener('click', () => {
        const ssid = getWifiSsid();
        runTylerAction({ action: 'wifi_spelunk', mode: 'triangulate_airspace', ssid }, 'Dual-Band (2.4+5GHz) 2-Point Spatial Airspace Triangulation');
      });
    }
    const btnRadarTriQuick = document.getElementById('btnTylerRadarTriQuick');
    if (btnRadarTriQuick) {
      btnRadarTriQuick.addEventListener('click', () => {
        const ssid = getWifiSsid();
        runTylerAction({ action: 'wifi_spelunk', mode: 'triangulate_airspace', ssid }, 'Dual-Band (2.4+5GHz) 2-Point Spatial Airspace Triangulation');
      });
    }
    const btnRadarDiagQuick = document.getElementById('btnTylerRadarDiagnoseQuick');
    if (btnRadarDiagQuick) {
      btnRadarDiagQuick.addEventListener('click', () => {
        runTylerAction({ action: 'wifi_spelunk', mode: 'diagnose_rf_mesh', duration: 24 }, 'George RF Mesh Link-Margin, WMM RTT & Fresnel Time-Series Diagnosis (24h)');
      });
    }
    const trendMetricSel = document.getElementById('tylerRfTrendMetricSelect');
    if (trendMetricSel) {
      trendMetricSel.addEventListener('change', () => {
        if (state.lastStatus) {
          renderRfTrendChart(state.lastStatus.peripheral_rf_telemetry || [], state.lastStatus.rf_timeseries_stats || {});
        }
      });
    }
    const trendChordSel = document.getElementById('tylerRfTrendChordSelect');
    if (trendChordSel) {
      trendChordSel.addEventListener('change', () => {
        if (state.lastStatus) {
          renderRfTrendChart(state.lastStatus.peripheral_rf_telemetry || [], state.lastStatus.rf_timeseries_stats || {});
        }
      });
    }
    const btnWifiRogue = document.getElementById('btnTylerWifiRogueWatch');
    if (btnWifiRogue) {
      btnWifiRogue.addEventListener('click', () => {
        runTylerAction({ action: 'wifi_spelunk', mode: 'rogue_ap_watch' }, 'Automated 802.11 Rogue Soft-AP & Evil-Twin Watch');
      });
    }
    const btnWifiCanaryAp = document.getElementById('btnTylerWifiCanaryAp');
    if (btnWifiCanaryAp) {
      btnWifiCanaryAp.addEventListener('click', () => {
        const surprise_name = getWifiSsid();
        runTylerAction({ action: 'wifi_spelunk', mode: 'canary_ap_watch', surprise_name }, `Canary Soft-AP /29 Client Sweep & Tamper Watch (${surprise_name || 'Current SSID'})`);
      });
    }
    const btnWifiBeacon = document.getElementById('btnTylerWifiBeacon');
    if (btnWifiBeacon) {
      btnWifiBeacon.addEventListener('click', () => {
        const surprise_name = getWifiSsid() || 'GEORGE-ALL-CLEAR';
        runTylerAction({ action: 'wifi_spelunk', mode: 'set_ap_beacon', surprise_name }, `Set Over-the-Air 802.11 Beacon SSID (${surprise_name})`);
      });
    }
    const btnWifiProv = document.getElementById('btnTylerWifiProvision');
    if (btnWifiProv) {
      btnWifiProv.addEventListener('click', () => {
        const ssid = getWifiSsid();
        runTylerAction({ action: 'wifi_spelunk', mode: 'provision_cast_ap', ssid }, `RSA-2048 Wi-Fi Onboarding Readiness (${ssid || 'Home Wi-Fi'})`);
      });
    }
    const btnWifiRest = document.getElementById('btnTylerWifiRestore');
    if (btnWifiRest) {
      btnWifiRest.addEventListener('click', () => {
        runTylerAction({ action: 'wifi_spelunk', mode: 'restore_peripheral' }, 'Restore Claimed Peripheral to Original Factory Baseline');
      });
    }
    const btnPassiveFp = document.getElementById('btnTylerPassiveFp');
    if (btnPassiveFp) {
      btnPassiveFp.addEventListener('click', () => {
        runTylerAction({ action: 'spelunk', mode: 'passive_fingerprint', duration: 8 }, 'Zero-Emission Passive OS/DHCP/TLS Fingerprinting (8s)');
      });
    }

    // Network Designations
    const btnSaveDesToggles = document.getElementById('btnTylerSaveDesToggles');
    if (btnSaveDesToggles) {
      btnSaveDesToggles.addEventListener('click', () => {
        const cAuto = document.getElementById('tylerDesAutoSwitch');
        const cWifi = document.getElementById('tylerDesWifiDefense');
        const cLock = document.getElementById('tylerDesLockRoles');
        const payload = {
          auto_switch_posture: cAuto ? cAuto.checked : true,
          wifi_defense_enabled: cWifi ? cWifi.checked : true,
          lock_endpoint_roles: cLock ? cLock.checked : true
        };
        runTylerAction({ action: 'designations', mode: 'save', payload_json: JSON.stringify(payload) }, 'Save Network Designation Toggles');
      });
    }
    const btnSaveSubnetDes = document.getElementById('btnTylerSaveSubnetDes');
    if (btnSaveSubnetDes) {
      btnSaveSubnetDes.addEventListener('click', () => {
        const cIn = document.getElementById('tylerDesCidrInput');
        const lIn = document.getElementById('tylerDesLabelInput');
        const pSel = document.getElementById('tylerDesPostureSelect');
        const cidr = cIn ? cIn.value.trim() : '';
        const label = lIn ? lIn.value.trim() : '';
        const designation = pSel ? pSel.value : 'foreign_cautious';
        if (cidr) {
          runTylerAction({ action: 'designations', mode: 'set_subnet', cidr, label, designation }, `Set Subnet Designation (${cidr} -> ${designation})`);
        }
      });
    }

    // Delegated Row Probe & Trust Clicks in LAN Device Registry
    const tbody = document.getElementById('tylerDeviceTableBody');
    if (tbody) {
      tbody.addEventListener('click', (e) => {
        const probeBtn = e.target.closest('.tyler-row-probe');
        if (probeBtn) {
          const ip = probeBtn.getAttribute('data-ip');
          const act = probeBtn.getAttribute('data-act');
          if (ipInput) ipInput.value = ip;
          runTylerAction({ action: act, ip, duration: 8 }, `${act.toUpperCase()} (${ip})`);
          return;
        }
        const trustBtn = e.target.closest('.tyler-row-trust');
        if (trustBtn) {
          const mac = trustBtn.getAttribute('data-mac');
          const level = trustBtn.getAttribute('data-trust');
          runTylerAction({ action: 'trust', mac, level }, `Set Trust (${mac} -> ${level})`);
        }
      });
    }
    // Reputation & Trust Workspace Controls
    const btnRepRefresh = document.getElementById('btnTylerRepRefresh');
    if (btnRepRefresh) {
      btnRepRefresh.addEventListener('click', () => loadReputationData(state.repFilterUid || ''));
    }
    const btnRepApplyPreset = document.getElementById('btnTylerRepApplyPreset');
    if (btnRepApplyPreset) {
      btnRepApplyPreset.addEventListener('click', () => {
        const sel = document.getElementById('tylerRepPresetSelect');
        if (sel && sel.value) submitReputationPolicy({ preset: sel.value });
      });
    }
    const btnRepSavePolicy = document.getElementById('btnTylerRepSavePolicy');
    if (btnRepSavePolicy) {
      btnRepSavePolicy.addEventListener('click', () => {
        const titleEl = document.getElementById('tylerRepLedgerTitle');
        const t0El = document.getElementById('tylerRepTier0Name');
        const t1El = document.getElementById('tylerRepTier1Name');
        const t1Min = document.getElementById('tylerRepTier1Min');
        const t2El = document.getElementById('tylerRepTier2Name');
        const t2Min = document.getElementById('tylerRepTier2Min');
        const t3El = document.getElementById('tylerRepTier3Name');
        const t3Min = document.getElementById('tylerRepTier3Min');
        const modEl = document.getElementById('tylerRepModFloor');
        const capEl = document.getElementById('tylerRepDailyCap');
        const cdEl = document.getElementById('tylerRepCooldown');
        submitReputationPolicy({
          ledger_title: titleEl ? titleEl.value.trim() : undefined,
          default_moderator_floor: modEl ? modEl.value : 'tier_1',
          passive_daily_cap: capEl ? Number(capEl.value) : 3,
          passive_cooldown_secs: cdEl ? Number(cdEl.value) : 600,
          tiers: {
            tier_0: { name: t0El ? t0El.value.trim() : 'Cowan' },
            tier_1: { name: t1El ? t1El.value.trim() : 'Stranger', min_score: t1Min ? Number(t1Min.value) : 0 },
            tier_2: { name: t2El ? t2El.value.trim() : 'Brother', min_score: t2Min ? Number(t2Min.value) : 25 },
            tier_3: { name: t3El ? t3El.value.trim() : 'Master Mason', min_score: t3Min ? Number(t3Min.value) : 50 }
          }
        });
      });
    }
    const btnManualGrant = document.getElementById('btnTylerRepManualGrant');
    if (btnManualGrant) {
      btnManualGrant.addEventListener('click', () => runManualRepAdjust('grant'));
    }
    const btnManualPenalize = document.getElementById('btnTylerRepManualPenalize');
    if (btnManualPenalize) {
      btnManualPenalize.addEventListener('click', () => runManualRepAdjust('penalize'));
    }
    const btnClearFilter = document.getElementById('btnTylerRepClearFilter');
    if (btnClearFilter) {
      btnClearFilter.addEventListener('click', () => {
        state.repFilterUid = '';
        loadReputationData('');
      });
    }
  }

  // --- Workspace 5: Reputation & Trust Ledger (Zero innerHTML / Zero confirm) ---
  function setRepPolicyStatus(msg, isError) {
    const node = document.getElementById('tylerRepPolicyStatus');
    if (!node) return;
    node.textContent = msg || '';
    node.style.color = isError ? '#f87171' : '#34d399';
  }

  function runManualRepAdjust(action) {
    const uidEl = document.getElementById('tylerRepManualUid');
    const nameEl = document.getElementById('tylerRepManualName');
    const deltaEl = document.getElementById('tylerRepManualDelta');
    const reasonEl = document.getElementById('tylerRepManualReason');
    const user_id = uidEl ? uidEl.value.trim() : '';
    if (!user_id) {
      setRepPolicyStatus('Enter a user ID first.', true);
      return;
    }
    const username = nameEl ? nameEl.value.trim() : '';
    const delta = deltaEl ? Math.max(1, Number(deltaEl.value) || 5) : 5;
    const reason = (reasonEl && reasonEl.value.trim()) ? reasonEl.value.trim() : `web_ui_${action}`;
    submitReputationAdjust({ action, user_id, username, delta, reason });
  }

  async function loadReputationData(filterUid) {
    try {
      const qs = filterUid ? `?user_id=${encodeURIComponent(filterUid)}` : '';
      const res = await fetch(`/api/reputation${qs}`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      if (data.status !== 'ok') {
        setRepPolicyStatus(data.message || 'Failed to load reputation data', true);
        return;
      }
      state.repData = data;
      renderReputationPanel(data);
    } catch (err) {
      setRepPolicyStatus(`Load error: ${err.message}`, true);
    }
  }

  async function submitReputationAdjust(payload) {
    try {
      setRepPolicyStatus(`Applying ${payload.action} to ${payload.user_id}...`, false);
      const res = await fetch('/api/reputation/adjust', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
      });
      const data = await res.json();
      if (data.status !== 'ok') {
        setRepPolicyStatus(data.message || 'Adjustment failed', true);
        return;
      }
      setRepPolicyStatus(`Updated ${payload.user_id} (${payload.action})`, false);
      await loadReputationData(state.repFilterUid || '');
    } catch (err) {
      setRepPolicyStatus(`Error: ${err.message}`, true);
    }
  }

  async function submitReputationPolicy(payload) {
    try {
      setRepPolicyStatus('Saving trust policy...', false);
      const res = await fetch('/api/reputation/policy', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
      });
      const data = await res.json();
      if (data.status !== 'ok') {
        setRepPolicyStatus(data.message || 'Policy save failed', true);
        return;
      }
      setRepPolicyStatus('Policy saved & ledger labels synced.', false);
      await loadReputationData(state.repFilterUid || '');
    } catch (err) {
      setRepPolicyStatus(`Error: ${err.message}`, true);
    }
  }

  function makeTwoClickConfirmBtn(label, armedLabel, cls, onConfirm) {
    const btn = el('button', cls, label, { type: 'button' });
    btn.style.fontSize = '9.5px';
    btn.style.padding = '2px 6px';
    let armedTimer = null;
    btn.addEventListener('click', () => {
      if (btn.dataset.armed === '1') {
        if (armedTimer) clearTimeout(armedTimer);
        btn.dataset.armed = '0';
        btn.textContent = label;
        onConfirm();
      } else {
        btn.dataset.armed = '1';
        btn.textContent = armedLabel;
        btn.style.borderColor = '#ef4444';
        btn.style.color = '#fca5a5';
        armedTimer = setTimeout(() => {
          btn.dataset.armed = '0';
          btn.textContent = label;
          btn.style.borderColor = '';
          btn.style.color = '';
        }, 4000);
      }
    });
    return btn;
  }

  function renderReputationPanel(data) {
    const policy = data.policy || {};
    const tiers = policy.tiers || {};
    const passive = policy.passive_reward || {};
    const themeBadge = document.getElementById('tylerRepThemeBadge');
    if (themeBadge) {
      themeBadge.textContent = `THEME: ${String(policy.theme || 'masonic').toUpperCase()}`;
    }
    const presetSel = document.getElementById('tylerRepPresetSelect');
    if (presetSel && ['masonic', 'standard', 'guild', 'cyber'].includes(policy.theme)) {
      presetSel.value = policy.theme;
    }
    const setVal = (id, val) => {
      const n = document.getElementById(id);
      if (n && val !== undefined && val !== null) n.value = String(val);
    };
    setVal('tylerRepLedgerTitle', policy.ledger_title || '');
    setVal('tylerRepTier0Name', (tiers.tier_0 && tiers.tier_0.name) || 'Cowan');
    setVal('tylerRepTier1Name', (tiers.tier_1 && tiers.tier_1.name) || 'Stranger');
    setVal('tylerRepTier1Min', tiers.tier_1 && tiers.tier_1.min_score !== undefined ? tiers.tier_1.min_score : 0);
    setVal('tylerRepTier2Name', (tiers.tier_2 && tiers.tier_2.name) || 'Brother');
    setVal('tylerRepTier2Min', tiers.tier_2 && tiers.tier_2.min_score !== undefined ? tiers.tier_2.min_score : 25);
    setVal('tylerRepTier3Name', (tiers.tier_3 && tiers.tier_3.name) || 'Master Mason');
    setVal('tylerRepTier3Min', tiers.tier_3 && tiers.tier_3.min_score !== undefined ? tiers.tier_3.min_score : 50);
    setVal('tylerRepModFloor', policy.default_moderator_floor || 'tier_1');
    setVal('tylerRepDailyCap', passive.daily_cap !== undefined ? passive.daily_cap : 3);
    setVal('tylerRepCooldown', passive.cooldown_secs !== undefined ? passive.cooldown_secs : 600);

    // Users table
    const users = Array.isArray(data.users) ? data.users : [];
    const cntBadge = document.getElementById('tylerRepUserCountBadge');
    if (cntBadge) cntBadge.textContent = `${users.length} USER${users.length === 1 ? '' : 'S'}`;

    const usersBody = document.getElementById('tylerRepUsersBody');
    if (usersBody) {
      clearNode(usersBody);
      if (users.length === 0) {
        const tr = el('tr');
        const td = el('td', '', 'No participants recorded in reputation.db yet.', { colspan: '5' });
        td.style.padding = '10px';
        td.style.color = 'var(--tyler-text-dim)';
        tr.appendChild(td);
        usersBody.appendChild(tr);
      } else {
        users.forEach((u) => {
          const tr = el('tr');
          const tdUser = el('td');
          tdUser.appendChild(el('div', '', u.username || u.user_id));
          const sub = el('div', '', `${u.user_id} · ${u.platform || 'discord'}`);
          sub.style.fontSize = '10px';
          sub.style.color = 'var(--tyler-text-dim)';
          tdUser.appendChild(sub);

          const tdScore = el('td', '', String(u.score));
          tdScore.style.fontWeight = '700';
          tdScore.style.color = Number(u.score) < 0 ? '#f87171' : (Number(u.score) >= 50 ? '#10b981' : '#e2e8f0');

          const tdTier = el('td');
          const tCls = u.tier_id === 'tier_0' ? 'tyler-badge tyler-badge-danger'
            : (u.tier_id === 'tier_3' ? 'tyler-badge tyler-badge-safe'
            : (u.tier_id === 'tier_2' ? 'tyler-badge tyler-badge-info' : 'tyler-badge tyler-badge-neutral'));
          tdTier.appendChild(el('span', tCls, u.tier || u.tier_id || 'tier_1'));

          const tdSeen = el('td', '', u.last_seen ? fmtTime(u.last_seen) : '—');

          const tdAct = el('td');
          const wrap = el('div');
          wrap.style.display = 'flex';
          wrap.style.gap = '4px';
          wrap.style.flexWrap = 'wrap';

          const bPlus = el('button', 'tactile-btn', '+5', { type: 'button' });
          bPlus.style.fontSize = '9.5px';
          bPlus.style.padding = '2px 6px';
          bPlus.addEventListener('click', () => submitReputationAdjust({
            action: 'grant', user_id: u.user_id, username: u.username, delta: 5, reason: 'web_ui_quick_grant'
          }));

          const bMinus = el('button', 'tactile-btn', '-5', { type: 'button' });
          bMinus.style.fontSize = '9.5px';
          bMinus.style.padding = '2px 6px';
          bMinus.addEventListener('click', () => submitReputationAdjust({
            action: 'penalize', user_id: u.user_id, username: u.username, delta: 5, reason: 'web_ui_quick_penalize'
          }));

          const bHist = el('button', 'tactile-btn', 'HISTORY', { type: 'button' });
          bHist.style.fontSize = '9.5px';
          bHist.style.padding = '2px 6px';
          bHist.addEventListener('click', () => {
            state.repFilterUid = u.user_id;
            loadReputationData(u.user_id);
          });

          const bQuar = makeTwoClickConfirmBtn('QUARANTINE', 'CONFIRM?', 'tactile-btn', () => submitReputationAdjust({
            action: 'quarantine', user_id: u.user_id, username: u.username, reason: 'web_ui_quarantine'
          }));
          const bReset = makeTwoClickConfirmBtn('RESET', 'CONFIRM?', 'tactile-btn', () => submitReputationAdjust({
            action: 'reset', user_id: u.user_id, username: u.username, reason: 'web_ui_reset'
          }));

          wrap.appendChild(bPlus);
          wrap.appendChild(bMinus);
          wrap.appendChild(bHist);
          wrap.appendChild(bQuar);
          wrap.appendChild(bReset);
          tdAct.appendChild(wrap);

          tr.appendChild(tdUser);
          tr.appendChild(tdScore);
          tr.appendChild(tdTier);
          tr.appendChild(tdSeen);
          tr.appendChild(tdAct);
          usersBody.appendChild(tr);
        });
      }
    }

    // Events audit table
    const fBadge = document.getElementById('tylerRepFilterBadge');
    const bClear = document.getElementById('btnTylerRepClearFilter');
    const fUid = data.filter_user_id || '';
    if (fBadge) fBadge.textContent = fUid ? `FILTER: ${fUid}` : 'ALL USERS';
    if (bClear) bClear.style.display = fUid ? 'inline-block' : 'none';

    const evBody = document.getElementById('tylerRepEventsBody');
    const events = Array.isArray(data.events) ? data.events : [];
    if (evBody) {
      clearNode(evBody);
      if (events.length === 0) {
        const tr = el('tr');
        const td = el('td', '', 'No audit events recorded yet.', { colspan: '6' });
        td.style.padding = '10px';
        td.style.color = 'var(--tyler-text-dim)';
        tr.appendChild(td);
        evBody.appendChild(tr);
      } else {
        events.forEach((ev) => {
          const tr = el('tr');
          tr.appendChild(el('td', '', fmtTime(ev.ts)));
          tr.appendChild(el('td', '', ev.user_id));
          const dNum = Number(ev.delta || 0);
          const tdDelta = el('td', '', `${dNum >= 0 ? '+' : ''}${dNum}`);
          tdDelta.style.color = dNum > 0 ? '#34d399' : (dNum < 0 ? '#f87171' : '#cbd5e1');
          tdDelta.style.fontWeight = '700';
          tr.appendChild(tdDelta);
          tr.appendChild(el('td', '', `${ev.score_before}→${ev.score_after} (${ev.tier_after || ''})`));
          tr.appendChild(el('td', '', ev.reason || ''));
          tr.appendChild(el('td', '', ev.actor || 'system'));
          evBody.appendChild(tr);
        });
      }
    }
  }

  window.TylerCockpit = {
    loadTylerData,
    loadReputationData,
    runTylerAction,
    initTylerModule,
    switchTylerTab,
    toggleGuideDrawer,
    toggleRawConsole
  };
})();
