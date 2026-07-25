// Host surface — who is hosting, host liveness (including the orphaned-
// daemon state), topology, devices, invites, audit. The single point of
// failure shown honestly.
window.WB = window.WB || {};
(function (WB) {
  const { el, chip, pulse, clock, rel, confirm, toast, empty } = WB.ui;

  function kv(k, v, vClass) {
    return el('div', { class: 'kv' }, [el('span', { class: 'k', text: k }), el('span', { class: 'v' + (vClass ? ' ' + vClass : ''), text: v })]);
  }

  function hostNode() {
    const H = WB.HOST;
    const info = WB.eff.hostInfo();
    const n = el('div', { class: 'host-node', id: 'host-node' }, [
      el('div', { class: 'hn-top' }, [
        el('span', { html: svgIcon('server', 16), style: 'color: var(--amber-deep); display:flex;' }),
        el('span', { class: 'hn-name', text: H.machine }),
        chip('host', 'amber'),
      ]),
      el('div', { class: 'hn-state ' + info.cls }, [pulse(info.pulse), el('span', { class: 'lbl', text: info.label })]),
      el('div', { class: 'hn-sub', text: info.sub }),
      el('div', { class: 'hn-kv' }, [
        kv('serve', 'workbench-mesh serve --' + H.mode),
        kv('bind', H.lanIp + ':' + H.port),
        kv('started by', H.startedBy + ' (--as)'),
        kv('up', WB.ui.dur(Date.now() - H.startedAt), null),
        kv('this machine', 'operator'),
      ]),
      el('div', { style: 'display:flex; gap:7px; margin-top:11px;' }, [
        el('button', { class: 'btn', style: 'font-size:11px;', html: svgIcon('copy', 11) + ' Copy URL', onclick: () => toast('http://' + H.lanIp + ':' + H.port + ' copied') }),
        el('button', { class: 'btn danger', style: 'font-size:11px;', html: svgIcon('power', 11) + ' Stop daemon', onclick: stopDaemon }),
      ]),
    ]);
    return n;
  }
  function stopDaemon() {
    confirm({
      title: 'Stop the mesh daemon?',
      body: 'Coordination stops for every connected device. Sessions keep running, but they stop seeing each other.',
      target: 'workbench-mesh serve · ' + WB.HOST.machine + ':' + WB.HOST.port + ' · pid file ' + WB.HOST.pidFile,
      note: 'Recommend-only from the dashboard — the clean shutdown is a session command.',
      confirmLabel: 'Stop daemon',
      danger: true,
      onConfirm: () => toast('Recommend-only — run it in a session', '/workbench:mesh stop'),
    });
  }

  function devNode(d) {
    const down = WB.state.hostState === 'down';
    const heat = down ? 'dead' : (d.stale ? 'stale' : (d.lastSeenOff < 1 ? 'idle' : 'idle'));
    return el('div', { class: 'dev-node' + (down ? ' ghost' : ''), 'data-dev': d.id }, [
      el('div', { class: 'dn-top' }, [
        pulse(d.stale ? 'stale' : heat),
        el('span', { text: d.id }),
        chip(d.role, d.role === 'observer' ? 'ghost' : undefined),
      ]),
      el('div', { class: 'dn-meta', text: d.transport + ' ' + d.ip + ' · seen ' + rel(d.lastSeenOff * 60000) + ' ago' }),
    ]);
  }

  function drawLines(topo) {
    const svg = topo.querySelector('svg.lines');
    const host = topo.querySelector('#host-node');
    if (!svg || !host) return;
    const tb = topo.getBoundingClientRect();
    const hb = host.getBoundingClientRect();
    let lines = '';
    topo.querySelectorAll('.dev-node').forEach((dn) => {
      const db = dn.getBoundingClientRect();
      const x1 = hb.right - tb.left, y1 = hb.top + hb.height / 2 - tb.top;
      const x2 = db.left - tb.left, y2 = db.top + db.height / 2 - tb.top;
      const mx = (x1 + x2) / 2;
      const dead = WB.state.hostState === 'down' || dn.classList.contains('ghost');
      const stale = (dn.querySelector('.pulse.stale') != null);
      lines += '<path d="M' + x1 + ' ' + y1 + ' C ' + mx + ' ' + y1 + ', ' + mx + ' ' + y2 + ', ' + x2 + ' ' + y2 + '" fill="none" stroke="var(--line-2)" stroke-width="1.2"' + ((dead || stale) ? ' stroke-dasharray="3 4"' : '') + '/>';
    });
    svg.innerHTML = lines;
  }

  function enrollPanel() {
    const body = el('div', { class: 'panel-body', id: 'inv-body' });
    const seg = el('div', { class: 'seg' });
    renderSeg(seg, body);
    renderEnroll(body);
    return el('section', { class: 'panel' }, [
      el('div', { class: 'panel-head' }, [
        el('h2', { html: svgIcon('mail', 14) + ' Enrollment' }),
        el('div', { class: 'spacer' }),
        seg,
      ]),
      body,
    ]);
  }
  function renderSeg(seg, body) {
    seg.replaceChildren(
      el('button', { class: WB.ENROLLMENT.hold ? '' : 'on', text: 'Open', onclick: () => setHold(false, seg, body) }),
      el('button', { class: WB.ENROLLMENT.hold ? 'on' : '', text: 'Hold', onclick: () => setHold(true, seg, body) }),
    );
  }
  function setHold(v, seg, body) {
    if (WB.ENROLLMENT.hold === v) return;
    WB.ENROLLMENT.hold = v;
    WB.AUDIT.unshift({ off: 0, icon: v ? 'lock' : 'check', text: v ? 'enrollment put on hold by you — new joins denied' : 'enrollment reopened by you' });
    WB.sim.pushEvent(v ? 'enrollment.hold' : 'enrollment.open', 'by you');
    toast(v ? 'Enrollment on hold — new joins are denied at the door' : 'Enrollment open');
    renderSeg(seg, body);
    renderEnroll(body);
    const audit = document.getElementById('audit-body');
    if (audit) renderAudit(audit);
  }
  function renderEnroll(body) {
    body.replaceChildren();
    if (WB.ENROLLMENT.hold) {
      body.appendChild(el('div', { class: 'hold-note', html: svgIcon('lock', 12) + '<span>On hold — join attempts are denied at the door. Already-enrolled devices are unaffected.</span>' }));
    }
    const roleSel = el('select', { id: 'invite-role', name: 'invite-role' }, ['worker', 'operator', 'observer'].map((r) => el('option', { text: r })));
    const ttlSel = el('select', { id: 'invite-ttl', name: 'invite-ttl' }, ['30m', '2h'].map((r) => el('option', { text: r })));
    body.appendChild(el('div', { style: 'display:flex; gap:8px; align-items:center; flex-wrap:wrap;' }, [
      roleSel, ttlSel,
      el('button', { class: 'btn primary', html: svgIcon('plus', 12) + ' Create invite', disabled: WB.ENROLLMENT.hold ? 'disabled' : null, title: WB.ENROLLMENT.hold ? 'Enrollment is on hold' : null, onclick: () => createInvite(body, roleSel.value, ttlSel.value) }),
    ]));
    const list = el('div', { style: 'margin-top: 10px;' });
    if (!WB.INVITES.length) list.appendChild(el('div', { style: 'font-size:11px; color:var(--ink-4); padding: 4px 0;', text: 'No active invites.' }));
    for (const inv of WB.INVITES) {
      list.appendChild(el('div', { class: 'inv-row' }, [
        el('span', { text: inv.id }),
        chip(inv.role),
        el('span', { 'data-inv-ttl': inv.id, text: fmtTtl(inv.ttl), style: 'margin-left:auto; color: var(--amber-deep);' }),
        el('button', { class: 'btn quiet danger', style: 'font-size:10.5px;', text: 'Revoke', onclick: () => revokeInvite(inv, body) }),
      ]));
    }
    body.appendChild(list);
  }
  function fmtTtl(s) {
    if (s <= 0) return 'expired';
    const m = Math.floor(s / 60);
    return m + 'm ' + String(s % 60).padStart(2, '0') + 's';
  }
  function createInvite(body, role, ttlLabel) {
    const ttlSeconds = ttlLabel === '2h' ? 7200 : 1800;
    if (!WB.api) return;
    WB.api.createInvite(role, ttlSeconds).then((data) => {
      const token = data.token;
      const id = 'inv-' + token.slice(0, 6);
      WB.INVITES.push({ id: id, role: role, ttl: ttlSeconds, createdBy: 'you', token: token });
      renderEnroll(body); // list is driven off WB.INVITES — refresh now so the new invite shows immediately, not gated on Copy
      const box = el('div', {}, [
        el('div', { class: 'inv-token' }, [
          el('code', { text: token }),
          el('button', { class: 'btn', style: 'font-size:11px; flex-shrink:0;', html: svgIcon('copy', 11) + ' Copy', onclick: () => {
            navigator.clipboard && navigator.clipboard.writeText(token);
            toast('Token copied — it will not be shown again');
            renderEnroll(body);
          } }),
        ]),
        el('div', { class: 'inv-token-note', text: 'Shown exactly once. The server keeps only a one-way hash — copy it now.' }),
      ]);
      body.appendChild(box);
    }).catch((err) => toast('Invite failed: ' + err.message));
  }
  function revokeInvite(inv, body) {
    confirm({
      title: 'Revoke this invite?',
      body: 'Anyone holding the token loses the ability to enroll. This cannot be undone.',
      target: inv.id + ' · ' + inv.role + ' · expires in ' + fmtTtl(inv.ttl),
      confirmLabel: 'Revoke invite',
      danger: true,
      onConfirm: () => {
        const done = () => {
          WB.INVITES.splice(WB.INVITES.indexOf(inv), 1);
          toast('Invite ' + inv.id + ' revoked');
          renderEnroll(body);
        };
        if (WB.api && inv.token) WB.api.revokeInvite(inv.token).then(done).catch((err) => toast('Revoke failed: ' + err.message));
        else done();
      },
    });
  }

  function renderAudit(body) {
    body.replaceChildren();
    for (const a of WB.AUDIT) {
      body.appendChild(el('div', { class: 'audit-line' }, [
        el('span', { class: 'ts', text: clock(Date.now() - a.off * 60000) }),
        el('span', { style: 'color: var(--ink-4); display:flex;', html: svgIcon(a.icon, 11) }),
        el('span', { class: 'txt', text: a.text }),
      ]));
    }
  }

  function devicesPanel() {
    const body = el('div', { class: 'panel-body', id: 'dev-body', style: 'padding: 4px 6px 6px;' });
    renderDevices(body);
    return el('section', { class: 'panel full' }, [
      el('div', { class: 'panel-head' }, [
        el('h2', { html: svgIcon('key', 14) + ' Devices' }),
        el('div', { class: 'spacer' }),
        el('span', { class: 't-mono', style: 'font-size:10px; color: var(--ink-4);', html: svgIcon('lock', 10) + ' credentials held as one-way hashes — never shown, never sent' }),
      ]),
      body,
    ]);
  }
  function renderDevices(body) {
    body.replaceChildren();
    if (!WB.DEVICES.length) { body.appendChild(empty('key', 'No enrolled devices yet.', 'create an invite above to enroll one')); return; }
    const table = el('table', { class: 'wb' });
    table.appendChild(el('tr', {}, ['Device', 'Platform', 'Transport', 'Role', 'Enrolled', 'Last seen', ''].map((h) => el('th', { text: h }))));
    for (const d of WB.DEVICES) {
      const revoked = d.state === 'revoked';
      table.appendChild(el('tr', { style: revoked ? 'opacity: 0.65;' : null }, [
        el('td', {}, [el('span', { style: 'display:inline-flex; align-items:center; gap:7px; font-weight:500;' }, [
          pulse(revoked ? 'dead' : d.stale ? 'stale' : 'idle'), el('span', { text: d.id }), d.host ? chip('host', 'amber') : null, revoked ? chip('revoked', 'rust') : null,
        ])]),
        el('td', { class: 'mono', text: d.platform }),
        el('td', { class: 'mono', text: d.transport + ' · ' + d.ip }),
        el('td', {}, [chip(d.role, d.role === 'observer' ? 'ghost' : undefined)]),
        el('td', { class: 'mono', text: d.enrolled }),
        el('td', { class: 'mono', text: revoked ? '—' : d.lastSeenOff === 0 ? 'now' : rel(d.lastSeenOff * 60000) + ' ago' }),
        el('td', { style: 'text-align:right;' }, [
          d.host ? el('span', { class: 't-mono', style: 'font-size:10px; color: var(--ink-4);', text: 'hosting' })
            : revoked ? el('button', { class: 'btn quiet danger', style: 'font-size:11px;', text: 'Remove', onclick: () => removeDevice(d, body) })
            : el('button', { class: 'btn quiet danger', style: 'font-size:11px;', text: 'Revoke', onclick: () => revokeDevice(d, body) }),
        ]),
      ]));
    }
    body.appendChild(table);
  }
  function revokeDevice(d, body) {
    confirm({
      title: 'Revoke this device?',
      body: 'Its credential hash is deleted server-side. Revocation is one-way — re-enrollment needs a fresh invite. The row stays (revoked) until you remove it.',
      target: d.id + ' · ' + d.role + ' · enrolled ' + d.enrolled,
      confirmLabel: 'Revoke device',
      danger: true,
      onConfirm: () => {
        const done = () => {
          d.state = 'revoked';
          toast('Device ' + d.id + ' revoked');
          renderDevices(body);
          const audit = document.getElementById('audit-body');
          if (audit) renderAudit(audit);
          WB.surfaces.host.redrawTopo();
        };
        if (WB.api) WB.api.revokeDevice(d.id).then(done).catch((err) => toast('Revoke failed: ' + err.message));
        else done();
      },
    });
  }
  function removeDevice(d, body) {
    confirm({
      title: 'Remove this device entirely?',
      body: 'It disappears from the roster. Audit entries about it remain — the trail is append-only.',
      target: d.id + ' · revoked · was ' + d.role,
      confirmLabel: 'Remove device',
      danger: true,
      onConfirm: () => {
        WB.DEVICES.splice(WB.DEVICES.indexOf(d), 1);
        WB.AUDIT.unshift({ off: 0, icon: 'x', text: 'device ' + d.id + ' removed from roster by you' });
        WB.sim.pushEvent('device.removed', d.id);
        toast('Device ' + d.id + ' removed');
        renderDevices(body);
        const audit = document.getElementById('audit-body');
        if (audit) renderAudit(audit);
        WB.surfaces.host.redrawTopo();
      },
    });
  }

  WB.surfaces = WB.surfaces || {};
  WB.surfaces.host = {
    render(container) {
      container.replaceChildren();
      const H = WB.HOST;

      const topo = el('section', { class: 'panel topo', id: 'topo' }, [
        el('div', { html: '<svg class="lines"></svg>' }).firstChild,
      ]);
      const inner = el('div', { class: 'topo-inner' }, [
        hostNode(),
        el('div', { class: 'dev-col' }, WB.DEVICES.filter((d) => !d.host && d.state !== 'revoked').map(devNode)),
      ]);
      topo.appendChild(inner);

      const spof = el('section', { class: 'panel' }, [
          el('div', { class: 'panel-body' }, [
            el('div', { class: 'h-title', html: svgIcon('alert', 14) + ' Single point of failure' }),
            el('p', { text: 'There is no redundant or failover host. If ' + H.machine + ' goes down, the mesh goes down with it. Sessions keep working — they just stop coordinating.' }),
          el('p', { text: 'The daemon is a background OS process: it survives the session that started it (that’s the “orphaned” state, and it’s legitimate).' }),
        ]),
      ]);
      const serverJson = el('section', { class: 'panel' }, [
        el('div', { class: 'panel-body' }, [
            el('div', { class: 'h-title', html: svgIcon('file-code', 14) + ' .workbench/mesh/server.json' }),
            kv('hostname', H.machine),
            kv('port', String(H.port)),
            kv('mode', H.mode),
            kv('lan_ips', '["' + H.lanIp + '"]'),
            kv('started_by', H.startedBy),
            el('div', { class: 'token-note', html: svgIcon('lock', 12) + '<span><span class="t-mono">local_token</span> is a live bearer secret. The dashboard reads named fields — it never renders this file wholesale.</span>' }),
        ]),
      ]);

      const auditPanel = el('section', { class: 'panel' }, [
        el('div', { class: 'panel-head' }, [
          el('h2', { html: svgIcon('shield', 14) + ' Audit' }),
          el('div', { class: 'spacer' }),
          el('span', { class: 't-mono', style: 'font-size:10px; color: var(--ink-4);', text: 'append-only' }),
        ]),
        (() => { const b = el('div', { class: 'panel-body', id: 'audit-body' }); renderAudit(b); return b; })(),
      ]);

      const grid = el('div', { class: 'host-grid' }, [
        topo,
        enrollPanel(),
        devicesPanel(),
        el('div', { class: 'three-col' }, [spof, serverJson, auditPanel]),
        el('div', { class: 'lan-note', html: svgIcon('shield', 11) + ' local + trusted-LAN surface · bearer tokens · LAN is TLS-pinned (self-signed), local is plain HTTP · no public exposure — by design' }),
      ]);

      container.appendChild(el('div', { class: 'host-wrap', 'data-screen-label': 'Host & topology' }, [grid]));
      requestAnimationFrame(() => drawLines(topo));
    },
    redrawTopo() {
      const topo = document.getElementById('topo');
      if (!topo) return;
      const inner = topo.querySelector('.topo-inner');
      const col = inner.querySelector('.dev-col');
      col.replaceChildren();
      WB.DEVICES.filter((d) => !d.host && d.state !== 'revoked').forEach((d) => col.appendChild(devNode(d)));
      requestAnimationFrame(() => drawLines(topo));
    },
  };

  window.addEventListener('resize', () => {
    const topo = document.getElementById('topo');
    if (topo) drawLines(topo);
  });
  // Live audit-panel refresh: a new invite/device/decision event lands in
  // WB.AUDIT via live.js's WS handler, which emits 'audit-update' right after
  // — re-render immediately if the panel is mounted (same document.getElementById
  // lookup convention used by setHold/revokeDevice/removeDevice above).
  WB.sim.on('audit-update', () => {
    const audit = document.getElementById('audit-body');
    if (audit) renderAudit(audit);
  });
  WB.sim.on('tick', (n) => {
    for (const inv of WB.INVITES) {
      const cell = document.querySelector('[data-inv-ttl="' + inv.id + '"]');
      if (cell) cell.textContent = fmtTtl(inv.ttl);
    }
    // Also refresh the audit panel every ~30s (tick fires every 1s) so its
    // relative timestamps ("3m ago") keep advancing even with no new events —
    // reuses the existing tick cadence instead of a second setInterval.
    if (n % 30 === 0) {
      const audit = document.getElementById('audit-body');
      if (audit) renderAudit(audit);
    }
  });
})(window.WB);
