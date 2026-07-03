// App shell — nav, topbar, statusline, banner, theme, tweaks protocol,
// and the derived (host-state-aware) views of agents and leads.
window.WB = window.WB || {};
(function (WB) {
  const { el, pulse, dur, rel } = WB.ui;

  WB.state = {
    surface: 'bench',
    focus: null,
    hostState: window.TWEAK_DEFAULTS.hostState,
    level: window.TWEAK_DEFAULTS.level,
    density: window.TWEAK_DEFAULTS.density,
  };

  /* ── derived, host-state-aware ── */
  WB.eff = {
    heat(a) {
      if (WB.state.hostState === 'down') return 'dead';
      if (WB.state.hostState === 'orphaned' && a.isHostSession) return 'stale';
      return a.heat;
    },
    note(a) {
      if (WB.state.hostState === 'orphaned' && a.isHostSession) return 'host session — ended ' + rel(Date.now() - WB.HOST.orphanedSince) + ' ago';
      if (WB.state.hostState === 'down') return 'unreachable';
      return null;
    },
    leads() { return WB.LEADS; },
    hostInfo() {
      const H = WB.HOST;
      if (WB.state.hostState === 'orphaned') return {
        cls: 'orphan', pulse: 'stale',
        label: 'orphaned daemon — lights on, host session gone',
        sub: H.startedBy + '’s session ended ' + rel(Date.now() - H.orphanedSince) + ' ago. The server keeps serving on its own — a real, legitimate state.',
      };
      if (WB.state.hostState === 'down') return {
        cls: 'down', pulse: 'dead',
        label: 'unreachable',
        sub: 'Last contact ' + rel(Date.now() - H.downSince) + ' ago. If ' + H.machine + ' is off, the mesh is off — there is no failover.',
      };
      return {
        cls: 'ok', pulse: 'idle',
        label: 'host session live',
        sub: 'Started by ' + H.startedBy + '. The daemon is a background process — it would survive that session ending.',
      };
    },
    // Fresh engagement signal (reading/typing) — decays after 12s so a
    // stale indicator never lies about liveness.
    activity(a) {
      if (!a.activity || a.activity === 'idle') return null;
      if (Date.now() - (a.activityTs || 0) > 12000) return null;
      return a.activity;
    },
    benchCount() {
      if (WB.state.hostState === 'down') return null;
      return WB.AGENTS.filter((a) => { const h = WB.eff.heat(a); return h === 'hot' || h === 'idle'; }).length;
    },
    needsYou() {
      return WB.DECISIONS.length + WB.eff.leads().filter((l) => l.liveness === 'stale').length;
    },
  };

  function applyHostState() {
    const hostLead = WB.LEADS.find((l) => l.isHost);
    if (hostLead && hostLead.liveness !== 'adopted') {
      if (WB.state.hostState === 'orphaned') { hostLead.liveness = 'stale'; hostLead.staleFor = rel(Date.now() - WB.HOST.orphanedSince); hostLead.purpose = 'Ran the teamlead loop — and started the mesh daemon.'; }
      else { hostLead.liveness = 'live'; }
    }
  }

  /* ── topbar ── */
  const TABS = [
    { id: 'bench', label: 'Bench' },
    { id: 'board', label: 'Board' },
    { id: 'host', label: 'Host' },
    { id: 'ops', label: 'Ops' },
    { id: 'docs', label: 'Docs' },
  ];
  function renderTopbar() {
    const bar = document.getElementById('topbar');
    bar.replaceChildren();
    bar.appendChild(el('div', { class: 'logo', html: 'workbench<span class="dot">·mesh</span>' }));
    bar.appendChild(el('nav', { class: 'tabs' }, TABS.map((t) =>
      el('button', { class: 'tab-btn' + (WB.state.surface === t.id ? ' active' : ''), text: t.label, onclick: () => WB.app.go(t.id) }))));
    const right = el('div', { class: 'topbar-right', id: 'topbar-right' });
    bar.appendChild(right);
    renderTopbarRight();
  }
  function renderTopbarRight() {
    const right = document.getElementById('topbar-right');
    right.replaceChildren();
    const n = WB.eff.benchCount();
    right.appendChild(el('span', {
      class: 'pill' + (n == null ? ' dead' : ''),
      html: svgIcon('users', 12) + (n == null ? ' unreachable' : ' ' + n + ' at the bench'),
      onclick: () => WB.app.go('bench'),
    }));
    const needs = WB.eff.needsYou();
    if (needs > 0 && WB.state.hostState !== 'down') {
      right.appendChild(el('span', { class: 'pill warn', html: svgIcon('shield', 12) + ' ' + needs + ' for you', onclick: () => WB.app.go('bench') }));
    }
    const themeBtn = el('button', { class: 'icon-btn', id: 'theme-btn', onclick: toggleTheme });
    right.appendChild(themeBtn);
    renderThemeIcon();
  }

  /* ── statusline ── */
  function renderStatusline() {
    const sl = document.getElementById('statusline');
    sl.replaceChildren();
    const H = WB.HOST;
    const info = WB.eff.hostInfo();
    const down = WB.state.hostState === 'down';
    sl.appendChild(el('span', { class: 'sl-item' }, [
      pulse(info.pulse),
      el('span', {}, [el('b', { text: H.machine + ':' + H.port }), el('span', { text: ' · ' + H.mode + ' ' + H.lanIp })]),
    ]));
    if (!down) {
      sl.appendChild(el('span', { class: 'sl-item', html: 'daemon up <b id="sl-uptime">' + dur(Date.now() - H.startedAt) + '</b>' }));
      sl.appendChild(el('span', { class: 'sl-item', text: 'started by ' + H.startedBy }));
    }
    if (WB.state.hostState === 'orphaned') {
      sl.appendChild(el('span', { class: 'sl-item sl-note', html: svgIcon('alert', 11) + ' lights on — host session gone; daemon serving independently' }));
    }
    if (down) {
      sl.appendChild(el('span', { class: 'sl-item sl-note dead', html: svgIcon('power', 11) + ' mesh unreachable — restart: /workbench:mesh start' }));
    }
    sl.appendChild(el('span', { class: 'sl-right' }, [
      el('span', { class: 'sl-item', html: 'seq <b id="sl-seq">#' + WB.sim.seq + '</b>' }),
      el('span', { class: 'sl-item', id: 'sl-rtt', text: WB.RTT != null ? WB.RTT + 'ms' : '…' }),
      el('span', { class: 'sl-item', text: 'you: operator · token ok' }),
      el('span', { class: 'sl-item sl-dim', text: 'trusted LAN · plaintext HTTP' }),
    ]));
  }

  function renderBanner() {
    const b = document.getElementById('banner');
    if (WB.state.hostState !== 'down') { b.hidden = true; return; }
    b.hidden = false;
    b.replaceChildren();
    b.appendChild(el('span', { style: 'display:flex;', html: svgIcon('alert', 14) }));
    b.appendChild(el('span', { text: WB.HOST.machine + ':' + WB.HOST.port + ' stopped answering ' + rel(Date.now() - WB.HOST.downSince) + ' ago. Showing the last known state.' }));
    b.appendChild(el('span', { class: 't-mono', style: 'margin-left:auto;', text: 'retrying every 5s' }));
  }

  /* ── theme (product feature, follows system with manual override) ── */
  function isDark() {
    return document.documentElement.getAttribute('data-theme') === 'dark'
      || (!document.documentElement.getAttribute('data-theme') && window.matchMedia('(prefers-color-scheme: dark)').matches);
  }
  function renderThemeIcon() {
    const btn = document.getElementById('theme-btn');
    if (btn) btn.innerHTML = svgIcon(isDark() ? 'sun' : 'moon', 14);
  }
  function toggleTheme() {
    document.documentElement.setAttribute('data-theme', isDark() ? 'light' : 'dark');
    renderThemeIcon();
  }

  /* ── app ── */
  const app = {
    go(surface, focus) {
      WB.state.surface = surface;
      WB.state.focus = focus || null;
      document.querySelectorAll('.tab-btn').forEach((b, i) => b.classList.toggle('active', TABS[i].id === surface));
      app.rerenderSurface();
    },
    rerenderSurface() {
      WB.surfaces[WB.state.surface].render(document.getElementById('surface'));
    },
    refreshChrome() {
      renderTopbarRight();
      renderStatusline();
      renderBanner();
      document.getElementById('app').classList.toggle('is-down', WB.state.hostState === 'down');
    },
  };
  WB.app = app;

  /* ── tweaks (host protocol: listener first, then announce) ── */
  let tweaksPanel = null;
  function applyTweak(key, val) {
    WB.state[key] = val;
    window.parent.postMessage({ type: '__edit_mode_set_keys', edits: { [key]: val } }, '*');
    if (key === 'density') { document.body.setAttribute('data-density', val); }
    else {
      if (key === 'hostState') applyHostState();
      app.refreshChrome();
      app.rerenderSurface();
    }
    if (tweaksPanel) renderTweaksPanel();
  }
  function seg(key, options, labels) {
    const wrap = el('div', { class: 'tw-seg' }, options.map((o, i) =>
      el('button', { class: WB.state[key] === o ? 'on' : '', text: labels ? labels[i] : o, onclick: () => applyTweak(key, o) })));
    return wrap;
  }
  const HOST_NOTES = {
    healthy: 'Session that ran mesh start is alive and holding the lead.',
    orphaned: 'The daemon outlived the session that started it — a real, legitimate state.',
    down: 'Host machine gone. No failover exists; the UI degrades honestly.',
  };
  function renderTweaksPanel() {
    if (!tweaksPanel) return;
    tweaksPanel.replaceChildren();
    tweaksPanel.appendChild(el('h3', {}, [
      el('span', { text: 'Tweaks' }),
      el('span', { class: 'x', html: svgIcon('x', 13), onclick: () => { hideTweaks(); window.parent.postMessage({ type: '__edit_mode_dismissed' }, '*'); } }),
    ]));
    tweaksPanel.appendChild(el('div', { class: 'tw-group' }, [
      el('div', { class: 'tw-label', text: 'Host state' }),
      seg('hostState', ['healthy', 'orphaned', 'down']),
      el('div', { class: 'tw-note', text: HOST_NOTES[WB.state.hostState] }),
    ]));
    tweaksPanel.appendChild(el('div', { class: 'tw-group' }, [
      el('div', { class: 'tw-label', text: 'Maturity level' }),
      seg('level', ['solo', 'pair', 'crew', 'fleet'], ['Solo', 'Pair', 'Crew', 'Fleet']),
      el('div', { class: 'tw-note', text: 'Moves the current rung in Docs and how deep C4 unlocks. The board keeps the project’s real lifecycle either way.' }),
    ]));
    tweaksPanel.appendChild(el('div', { class: 'tw-group' }, [
      el('div', { class: 'tw-label', text: 'Density' }),
      seg('density', ['comfortable', 'compact'], ['Comfortable', 'Compact']),
    ]));
  }
  function showTweaks() {
    if (tweaksPanel) return;
    tweaksPanel = el('div', { class: 'tweaks' });
    renderTweaksPanel();
    document.getElementById('overlay-root').appendChild(tweaksPanel);
  }
  function hideTweaks() {
    if (tweaksPanel) { tweaksPanel.remove(); tweaksPanel = null; }
  }
  window.addEventListener('message', (e) => {
    if (!e.data) return;
    if (e.data.type === '__activate_edit_mode') showTweaks();
    if (e.data.type === '__deactivate_edit_mode') hideTweaks();
  });
  window.parent.postMessage({ type: '__edit_mode_available' }, '*');

  /* ── live chrome updates ── */
  WB.sim.on('rtt', () => {
    const r = document.getElementById('sl-rtt');
    if (r) r.textContent = WB.RTT != null ? WB.RTT + 'ms' : '…';
  });
  WB.sim.on('tick', () => {
    if (WB.state.hostState === 'down') return;
    const up = document.getElementById('sl-uptime');
    if (up) up.textContent = dur(Date.now() - WB.HOST.startedAt);
  });
  WB.sim.on('event', () => {
    const s = document.getElementById('sl-seq');
    if (s) s.textContent = '#' + WB.sim.seq;
  });
  WB.sim.on('decision', () => renderTopbarRight());

  /* ── boot ── */
  document.body.setAttribute('data-density', WB.state.density);
  applyHostState();
  renderTopbar();
  renderStatusline();
  renderBanner();
  document.getElementById('app').classList.toggle('is-down', WB.state.hostState === 'down');
  app.rerenderSurface();
  WB.sim.start();
})(window.WB);
