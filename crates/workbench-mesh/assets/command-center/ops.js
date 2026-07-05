// Ops surface — jobs, leads, workers, rooms, and the live event rail.
window.WB = window.WB || {};
(function (WB) {
  const { el, chip, pulse, rel, dur, confirm, toast, empty, leadName } = WB.ui;
  let showHeartbeats = false;

  function panel(icon, title, note, body) {
    return el('section', { class: 'panel' }, [
      el('div', { class: 'panel-head' }, [
        el('h2', { html: svgIcon(icon, 14) + ' ' + title }),
        el('div', { class: 'spacer' }),
        note ? el('span', { class: 't-mono', style: 'font-size:10px; color: var(--ink-4);', text: note }) : null,
      ]),
      body,
    ]);
  }

  /* ── jobs ── */
  function jobsBody() {
    const body = el('div', { style: 'padding: 4px 6px 6px;' });
    if (!WB.JOBS.length) { body.appendChild(empty('zap', 'No jobs observed.', 'dispatch a task to start one')); return body; }
    const table = el('table', { class: 'wb' });
    table.appendChild(el('tr', {}, ['Job', 'Engine', 'Task', 'State', 'Elapsed', ''].map((h) => el('th', { text: h }))));
    for (const j of WB.JOBS) {
      const t = WB.TASKS.find((x) => x.id === j.task);
      table.appendChild(el('tr', {}, [
        el('td', { class: 'mono', text: j.id }),
        el('td', {}, [chip(j.engine, j.engine === 'claude' ? 'amber' : 'ghost')]),
        el('td', {}, [el('span', { style: 'font-size:12px;', text: j.task + ' — ' + (t ? t.title : '') })]),
        el('td', {}, [chip(j.state, j.state === 'running' ? 'green' : undefined), el('div', { class: 't-mono', style: 'font-size:9.5px; color: var(--ink-4); margin-top:3px;', text: j.via })]),
        el('td', { class: 'mono', 'data-job-elapsed': j.id, text: dur(j.startedOff * 60000) }),
        el('td', { style: 'text-align:right; white-space:nowrap;' }, [
          j.state === 'running'
            ? el('button', { class: 'btn quiet danger', style: 'font-size:11px;', text: 'Stop', onclick: () => stopJob(j) })
            : el('button', { class: 'btn quiet', style: 'font-size:11px;', text: 'Retry', onclick: () => { if (WB.api) WB.api.retryJob(j.id, j.task, j.engine); toast('Job ' + j.id + ' requeued', 'dispatch ' + j.task + ' --engine ' + j.engine); } }),
        ]),
      ]));
    }
    body.appendChild(table);
    return body;
  }
  function stopJob(j) {
    confirm({
      title: 'Stop this job?',
      body: 'The lane is released and the task returns to its column. Any uncommitted work in the worktree stays on disk.',
      target: j.id + ' · ' + j.engine + '-engineer · task ' + j.task,
      confirmLabel: 'Stop job',
      danger: true,
      onConfirm: () => { j.state = 'stopped'; if (WB.api) WB.api.stopJob(j.id); toast('Job ' + j.id + ' stopped', 'job stop ' + j.id); WB.app.rerenderSurface(); },
    });
  }

  /* ── leads ── */
  function leadsExplainer() {
    return el('div', { style: 'padding: 12px 16px 2px; font-size: 11.5px; color: var(--ink-3); line-height: 1.55; max-width: 640px;' }, [
      el('span', { text: 'A lead is the terminal session a human spins up — it holds a track’s purpose and fronts its own crew of agents. If the session dies, the purpose goes stale on disk. Adopting it means your session picks that purpose up and carries on; nothing is lost.' }),
    ]);
  }
  function leadsBody() {
    const body = el('div', { style: 'padding: 4px 6px 6px;' });
    const table = el('table', { class: 'wb' });
    table.appendChild(el('tr', {}, ['Actor', 'Mode', 'Crew', 'Liveness', ''].map((h) => el('th', { text: h }))));
    for (const l of WB.eff.leads()) {
      const stale = l.liveness === 'stale';
      const a = WB.AGENTS.find((x) => x.id === l.actor);
      table.appendChild(el('tr', {}, [
        el('td', {}, [el('span', { style: 'display:inline-flex; align-items:center; gap:7px; font-weight:500;' }, [
          pulse(stale ? 'stale' : l.liveness === 'adopted' ? 'idle' : 'hot'),
          leadName(l.actor),
          l.isHost ? chip('host session', 'amber') : null,
        ])]),
        el('td', { class: 'mono', text: l.mode + ':' + l.scope }),
        el('td', { class: 'mono' }, [
          (a && a.crew && a.crew.length)
            ? el('span', { style: 'display:inline-flex; align-items:center; gap:4px; color: var(--ink-3);', html: svgIcon('user', 10) + ' +' + a.crew.length + ' ' + svgIcon('bot', 10) })
            : el('span', { style: 'color: var(--ink-4);', text: '—' }),
        ]),
        el('td', {}, [stale ? chip(l.staleFor + ' stale', 'rust') : chip(l.liveness, 'green')]),
        el('td', { style: 'text-align:right; white-space:nowrap;' }, [
          stale ? el('button', { class: 'btn', style: 'font-size:11px;', text: 'Adopt', onclick: () => adoptLead(l) }) : null,
          el('button', { class: 'btn quiet', style: 'font-size:11px; margin-left:6px;', text: 'Close', onclick: () => closeLead(l) }),
        ]),
      ]));
    }
    body.appendChild(table);
    return body;
  }
  function adoptLead(l) {
    confirm({
      title: 'Adopt this stale lead?',
      body: 'Your session takes over the purpose and scope.',
      target: l.actor + ' · ' + l.mode + ':' + l.scope + ' · stale ' + l.staleFor,
      confirmLabel: 'Adopt',
      onConfirm: () => { l.liveness = 'adopted'; if (WB.api) WB.api.adoptLead(l.actor); toast('Lead adopted', '/workbench:lead adopt --as you'); WB.app.rerenderSurface(); WB.app.refreshChrome(); },
    });
  }
  function closeLead(l) {
    confirm({
      title: 'Close this lead?',
      body: 'The purpose is cleared. The actor stays connected — it just stops holding the track.',
      target: l.actor + ' · ' + l.mode + ':' + l.scope,
      confirmLabel: 'Close lead',
      danger: true,
      onConfirm: () => { WB.LEADS.splice(WB.LEADS.indexOf(l), 1); if (WB.api) WB.api.closeLead(l.actor); toast('Lead closed', 'lead clear --as ' + l.actor); WB.app.rerenderSurface(); WB.app.refreshChrome(); },
    });
  }

  /* ── workers ── */
  const AVAIL_VARIANT = { available: 'green', busy: 'amber', blocked: 'rust', lead: 'ghost', unknown: 'ghost' };
  function workersBody() {
    const body = el('div', { style: 'padding: 4px 6px 6px;' });
    if (!WB.AGENTS.length) { body.appendChild(empty('users', 'No sessions connected.', '--as <actor> joins the roster')); return body; }
    const table = el('table', { class: 'wb' });
    table.appendChild(el('tr', {}, ['Actor', 'Room', 'Availability', 'Last seen'].map((h) => el('th', { text: h }))));
    for (const a of WB.AGENTS) {
      const heat = WB.eff.heat(a);
      table.appendChild(el('tr', {}, [
        el('td', {}, [el('span', { style: 'display:inline-flex; align-items:center; gap:7px; font-weight:500;' }, [pulse(heat), leadName(a.id)])]),
        el('td', { class: 'mono', text: a.room }),
        el('td', {}, [chip(a.availability, AVAIL_VARIANT[a.availability])]),
        el('td', { class: 'mono', 'data-seen': a.id, text: heat === 'stale' || heat === 'dead' ? rel(Date.now() - (a.staleSince || Date.now() - 720000)) + ' ago' : 'now' }),
      ]));
    }
    body.appendChild(table);
    return body;
  }

  /* ── rooms ── */
  function roomsBody() {
    const body = el('div', { style: 'padding: 4px 6px 6px;' });
    if (!WB.ROOMS.length) { body.appendChild(empty('folder', 'No rooms yet.', 'a room is created the first time an actor posts to it')); return body; }
    const table = el('table', { class: 'wb' });
    table.appendChild(el('tr', {}, ['Room', 'Events', 'Kind'].map((h) => el('th', { text: h }))));
    for (const r of WB.ROOMS) {
      table.appendChild(el('tr', {}, [
        el('td', { class: 'mono', text: r.id }),
        el('td', { class: 'mono', 'data-room-count': r.id, text: String(r.events) }),
        el('td', {}, [r.output ? chip('output feed', 'amber') : chip('coordination', 'ghost')]),
      ]));
    }
    body.appendChild(table);
    return body;
  }

  /* ── tasks (reassign) ── */
  function tasksBody() {
    const body = el('div', { style: 'padding: 10px 16px 14px; display:flex; flex-direction:column; gap: 10px;' });
    const idInput = el('input', { id: 'reassign-task-id', name: 'reassign-task-id', type: 'text', placeholder: 'task id', style: 'width:90px;' });
    const agentSel = el('select', {}, [
      el('option', { value: '', text: 'assign to…' }),
      ...WB.AGENTS.map((a) => el('option', { value: a.id, text: a.id })),
    ]);
    const doReassign = () => {
      const id = Number(idInput.value);
      const t = WB.TASKS.find((x) => x.id === id);
      if (!t) { toast('No task #' + idInput.value + ' on the board'); return; }
      const newAgent = agentSel.value;
      if (!newAgent) { toast('Pick who to assign it to'); return; }
      const from = t.agent || t.who || 'unassigned';
      confirm({
        title: 'Reassign task ' + t.id + '?',
        body: 'The new session claims it via wb-coord — the previous assignee is dropped.',
        target: t.id + ' — ' + t.title + ' · ' + from + ' → ' + newAgent,
        confirmLabel: 'Reassign',
        onConfirm: () => {
          t.agent = newAgent; t.who = null;
          if (WB.api) WB.api.reassignTask(t.id, newAgent);
          toast('Task ' + t.id + ' reassigned to ' + newAgent, 'wb-coord claim ' + t.id + ' --as ' + newAgent);
          idInput.value = ''; agentSel.value = '';
          WB.app.rerenderSurface();
        },
      });
    };
    body.appendChild(el('div', { style: 'display:flex; gap:8px; align-items:center; flex-wrap:wrap;' }, [
      idInput, agentSel,
      el('button', { class: 'btn', text: 'Reassign', onclick: doReassign }),
    ]));
    const recent = WB.TASKS.filter((t) => t.agent).slice(0, 6);
    if (recent.length) {
      const list = el('div', { style: 'display:flex; flex-direction:column; gap:6px;' });
      for (const t of recent) {
        list.appendChild(el('div', { style: 'display:flex; align-items:center; gap:10px; font-size:11.5px; color:var(--ink-3);' }, [
          el('span', { class: 'mono', style: 'font-family:var(--font-mono); color:var(--ink-4);', text: '#' + t.id }),
          el('span', { style: 'flex:1; color:var(--ink-2); overflow:hidden; text-overflow:ellipsis; white-space:nowrap;', text: t.title }),
          leadName(t.agent),
        ]));
      }
      body.appendChild(list);
    }
    return body;
  }

  /* ── event rail ── */
  function evNode(ev) {
    return el('div', { class: 'ev' + (ev.hb ? ' hb' : '') }, [
      el('div', { class: 'ev-top' }, [
        el('span', { class: 'ev-seq', text: '#' + ev.seq }),
        el('span', { class: 'ev-type', text: ev.type }),
      ]),
      el('div', { class: 'ev-meta', text: ev.meta }),
    ]);
  }
  function renderRail(scroll) {
    scroll.replaceChildren();
    for (const ev of WB.EVENTS) {
      if (ev.hb && !showHeartbeats) continue;
      scroll.appendChild(evNode(ev));
    }
  }

  WB.surfaces = WB.surfaces || {};
  WB.surfaces.ops = {
    render(container) {
      container.replaceChildren();
      const running = WB.JOBS.filter((j) => j.state === 'running').length;
      const scroll = el('div', { class: 'rail-scroll', id: 'rail-scroll' });
      renderRail(scroll);
      const hbToggle = el('label', {}, [
        (() => { const c = el('input', { type: 'checkbox' }); c.checked = showHeartbeats; c.addEventListener('change', () => { showHeartbeats = c.checked; renderRail(scroll); }); return c; })(),
        el('span', { text: 'heartbeats' }),
      ]);
      container.appendChild(el('div', { class: 'ops-wrap', 'data-screen-label': 'Ops' }, [
        el('div', { class: 'ops-main' }, [
          panel('zap', 'Jobs', running + ' lanes live · claude + codex', jobsBody()),
          panel('users', 'Leads', 'one per terminal session · crew behind each', WB.eff.leads().length ? el('div', {}, [leadsExplainer(), leadsBody()]) : el('div', {}, [empty('users', 'No leads held.', 'teamlead <topic> claims one')])),
          panel('users', 'Workers', 'availability from presence', workersBody()),
          panel('folder', 'Rooms', null, roomsBody()),
          panel('file-code', 'Tasks', 'reassign to another session', tasksBody()),
        ]),
        el('aside', { class: 'event-rail' }, [
          el('div', { class: 'rail-head' }, [
            el('div', { class: 't-eyebrow', text: 'Live rail' }),
            hbToggle,
          ]),
          scroll,
        ]),
      ]));
    },
  };

  WB.sim.on('event', (ev) => {
    const scroll = document.getElementById('rail-scroll');
    if (!scroll) return;
    if (ev.hb && !showHeartbeats) return;
    scroll.insertBefore(evNode(ev), scroll.firstChild);
    while (scroll.children.length > 60) scroll.removeChild(scroll.lastChild);
  });
  WB.sim.on('tick', (t) => {
    if (t % 30 !== 0) return;
    for (const j of WB.JOBS) {
      const cell = document.querySelector('[data-job-elapsed="' + j.id + '"]');
      if (cell && j.state === 'running') cell.textContent = dur(j.startedOff * 60000 + t * 1000);
    }
    for (const r of WB.ROOMS) {
      const cell = document.querySelector('[data-room-count="' + r.id + '"]');
      if (cell) cell.textContent = String(r.events);
    }
  });
})(window.WB);
