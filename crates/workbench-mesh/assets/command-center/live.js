// Workbench Mesh — live data layer. Replaces the design prototype's sim.js:
// same WB.sim event-bus interface, but every collection is projected from
// the real event log over the existing HTTP/WebSocket API, and every action
// posts a real event. The dashboard never originates state — it reflects it.
window.WB = window.WB || {};
(function (WB) {
  const SELF = 'ui:operator';
  const SELF_LABEL = 'you (operator)';

  /* ── event bus (same interface the surfaces already use) ── */
  const listeners = {};
  const sim = {
    t: 0,
    seq: 0,
    on(ev, fn) { (listeners[ev] = listeners[ev] || []).push(fn); },
    emit(ev, data) { (listeners[ev] || []).forEach((fn) => fn(data)); },
    // Local rail entry only — real wire posts go through WB.api.
    pushEvent(type, meta) {
      railPush({ seq: sim.seq, type: type, meta: meta, hb: false, local: true });
    },
    start() {
      loadState();
      setInterval(tick, 1000);
    },
  };
  WB.sim = sim;
  WB.RECEIPTS = WB.RECEIPTS || {};

  /* ── auth ── */
  const params = new URLSearchParams(window.location.search);
  let token = params.get('token') || window.localStorage.getItem('meshCommandToken') || '';
  if (token) window.localStorage.setItem('meshCommandToken', token);
  function headers(json) {
    const h = {};
    if (token) h.Authorization = 'Bearer ' + token;
    if (json) h['Content-Type'] = 'application/json';
    return h;
  }
  function requireOk(response) {
    return response.text().then((body) => {
      let parsed = null;
      try { parsed = JSON.parse(body); } catch (e) { parsed = null; }
      if (!response.ok) throw new Error((parsed && parsed.error) || response.status + ' ' + response.statusText);
      return parsed || {};
    });
  }

  /* ── state ── */
  const events = [];        // full envelopes, seq-ordered
  const seen = new Set();   // seqs already projected
  const pendingSelf = [];   // optimistic chat texts awaiting their echo
  let socket = null;
  let lastContact = 0;
  let firstLoad = true;
  let lastDerivedHostState = null; // last reachable state we derived, so live detection doesn't fight a manual tweak

  function setHostState(next) {
    if (WB.state && WB.state.hostState !== next) {
      WB.state.hostState = next;
      if (next === 'down') WB.HOST.downSince = lastContact || Date.now();
      if (WB.app) { WB.app.refreshChrome(); WB.app.rerenderSurface(); }
    }
  }

  // Reachable-state detection: reachability ('down') is owned by loadState/tick;
  // here we resolve the two reachable states — healthy vs orphaned — from live
  // presence. Orphaned = the daemon answers but the actor that started it (its
  // host session) has gone stale. Applied through setHostState so a transition
  // re-renders chrome + surface like any other. Only fires when the derived
  // value CHANGES, so the Tweaks panel can still override for exploration.
  function deriveHostState(now) {
    const reachable = lastContact && (now - lastContact) <= 30000;
    if (!reachable) { lastDerivedHostState = null; return; }
    const host = WB.HOST.startedBy && WB.AGENTS.find((a) => a.id === WB.HOST.startedBy);
    const derived = host && host.heat === 'stale' ? 'orphaned' : 'healthy';
    if (derived === lastDerivedHostState) return;
    lastDerivedHostState = derived;
    if (derived === 'orphaned') WB.HOST.orphanedSince = (host && host.staleSince) || now;
    setHostState(derived);
  }

  function loadState() {
    if (!token) { setHostState('down'); return; }
    fetch('/api/state', { headers: headers(false) })
      .then(requireOk)
      .then((data) => {
        lastContact = Date.now();
        if (data.host) projectHost(data.host);
        projectDevices(Array.isArray(data.devices) ? data.devices : []);
        const evs = Array.isArray(data.events) ? data.events : [];
        for (const ev of evs) ingest(ev, firstLoad);
        firstLoad = false;
        recomputeDerived(); // ends in deriveHostState — sets healthy/orphaned from live presence
        if (WB.app) { WB.app.refreshChrome(); WB.app.rerenderSurface(); }
        WB.live.subscribe(defaultRooms());
        connectSocket();
      })
      .catch(() => setHostState('down'));
  }

  let reconnectAttempt = 0;
  function backoffMs(attempt) {
    if (attempt === 0) return 250;
    const capped = Math.min(250 * Math.pow(2, Math.min(attempt, 6)), 5000);
    return capped + Math.random() * (capped / 5);
  }

  function connectSocket() {
    if (!token || socket) return;
    const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    socket = new WebSocket(proto + '//' + window.location.host + '/ws?token=' + encodeURIComponent(token) + '&last_seq=' + sim.seq);
    socket.addEventListener('open', () => {
      reconnectAttempt = 0;
      sendSubscribe();
    });
    socket.addEventListener('message', (e) => {
      lastContact = Date.now();
      let payload = null;
      try { payload = JSON.parse(e.data); } catch (err) { return; }
      if (!payload) return;
      if (payload.type === 'ack' || payload.type === 'pong') { handleControlFrame(payload); return; }
      if (payload.type === 'batch' && Array.isArray(payload.events)) {
        for (const ev of payload.events) { if (ev.seq) ingest(ev, false); }
        recomputeDerived();
        return;
      }
      if (!payload.seq) return;
      ingest(payload, false);
      recomputeDerived();
    });
    socket.addEventListener('close', () => {
      socket = null;
      const delay = backoffMs(reconnectAttempt);
      reconnectAttempt += 1;
      setTimeout(connectSocket, delay);
    });
  }

  function handleControlFrame(payload) {
    // ack: no-op here — optimistic-send reconciliation (Task 14) consumes it
    // pong: RTT measurement (Task 15) consumes it
  }

  let subscribedRooms = [];
  function sendSubscribe() {
    if (!socket || socket.readyState !== WebSocket.OPEN) return;
    socket.send(JSON.stringify({ v: 1, type: 'subscribe', rooms: subscribedRooms, actor: SELF }));
  }
  WB.live = WB.live || {};
  WB.live.subscribe = function (rooms) {
    subscribedRooms = rooms.slice();
    sendSubscribe();
  };

  function defaultRooms() {
    const rooms = new Set(['team', 'presence']);
    for (const r of WB.ROOMS) { if (!r.output) rooms.add(r.id); }
    rooms.add(SELF);
    return Array.from(rooms);
  }

  /* ── projection ── */
  const ts = (ev) => Date.parse(ev.ts) || Date.now();
  const railIcon = { 'invite.created': 'mail', 'invite.revoked': 'x', 'invite.accepted': 'users', 'invite.expired': 'mail', 'device.connected': 'users', 'device.revoked': 'x', 'decision.answer': 'check' };

  function railPush(entry) {
    WB.EVENTS.unshift(entry);
    if (WB.EVENTS.length > 60) WB.EVENTS.pop();
    sim.emit('event', entry);
  }

  function agentFor(id) {
    let a = WB.AGENTS.find((x) => x.id === id);
    if (!a) {
      a = {
        id: id, platform: 'unknown', provider: 'unknown', model: 'unknown',
        caps: [], heat: 'stale', availability: 'unknown', device: 'unknown',
        crew: [], doing: '', task: null, room: 'presence', worktree: '—',
        lastOutput: '', tool: null, script: [], lastSeen: 0,
      };
      WB.AGENTS.push(a);
    }
    return a;
  }

  function displayWho(from) { return from === SELF ? SELF_LABEL : from; }

  function ingest(ev, quiet) {
    if (seen.has(ev.seq)) return;
    seen.add(ev.seq);
    events.push(ev);
    sim.seq = Math.max(sim.seq, ev.seq);
    const p = ev.payload || {};
    const when = ts(ev);
    const type = ev.event_type || ev.type;

    // rail (heartbeats toggleable in Ops)
    railPush({ seq: ev.seq, type: type, meta: ev.room + ' / ' + ev.from, hb: type === 'presence.heartbeat' || type === 'actor.heartbeat' });

    // room registry
    if (ev.room) {
      let r = WB.ROOMS.find((x) => x.id === ev.room);
      if (!r) { r = { id: ev.room, events: 0, output: ev.room.startsWith('output:') }; WB.ROOMS.push(r); }
      r.events += 1;
    }

    // roster from presence
    if (type === 'presence.heartbeat' || type === 'presence.join' || type === 'actor.status') {
      const a = agentFor(ev.from);
      a.lastSeen = Math.max(a.lastSeen, when);
      if (p.availability) a.availability = p.availability;
      if (p.current_step) a.doing = p.current_step;
      if (p.platform) { a.platform = p.platform; a.device = p.platform; }
      if (Array.isArray(p.capabilities)) a.caps = p.capabilities;
      if (p.provider) a.provider = p.provider;
      if (p.model) a.model = p.model;
      if (p.activity) { a.activity = p.activity; a.activityTs = when; }
      if (!quiet) sim.emit('heartbeat', a);
    } else if (ev.from !== SELF) {
      // any non-presence activity still proves the actor is alive
      const existing = WB.AGENTS.find((x) => x.id === ev.from);
      if (existing) {
        existing.lastSeen = Math.max(existing.lastSeen, when);
        if (!ev.room.startsWith('output:') && ev.room !== 'presence') existing.room = ev.room;
      }
    }

    // team chat
    if (type === 'message.sent' || type === 'message.request_status' || type === 'message.help_request' || type === 'task.handoff') {
      const text = p.text || p.question || (p.task_id ? p.task_id + ' → ' + (ev.to || 'next available session') : '');
      if (ev.from === SELF) {
        const idx = pendingSelf.indexOf(text);
        if (idx >= 0) { pendingSelf.splice(idx, 1); return; } // optimistic copy already shown
      }
      const kind = type === 'message.request_status' ? 'ask' : type === 'task.handoff' ? 'handoff' : 'msg';
      const m = { room: ev.room, who: displayWho(ev.from), kind: kind, text: text, ts: when, to: ev.to || null, seq: ev.seq };
      WB.CHAT.push(m);
      if (!quiet) sim.emit('chat', m);
    }

    // delivery/seen receipts
    if ((type === 'message.delivered' || type === 'message.read') && ev.ack_of) {
      const r = WB.RECEIPTS[ev.ack_of] = WB.RECEIPTS[ev.ack_of] || { deliveredBy: new Set(), seenBy: new Set() };
      if (type === 'message.delivered') r.deliveredBy.add(ev.from);
      else r.seenBy.add(ev.from);
      if (!quiet) sim.emit('receipt', ev.ack_of);
    }

    // per-agent output feed
    if (type === 'output.chunk' && ev.room.startsWith('output:')) {
      const id = ev.room.slice('output:'.length);
      const a = agentFor(id);
      a.lastSeen = Math.max(a.lastSeen, when);
      const line = p.kind === 'tool_call'
        ? { k: 'tool', tool: p.tool || 'Bash', t: p.summary || '' }
        : { k: 'msg', t: p.summary || '', dim: true };
      a.lastOutput = line.t;
      if (line.k === 'tool') a.tool = line.tool;
      WB.FEEDLOG = WB.FEEDLOG || {};
      (WB.FEEDLOG[id] = WB.FEEDLOG[id] || []).push({ ts: when, line: line });
      if (WB.FEEDLOG[id].length > 200) WB.FEEDLOG[id].shift();
      if (!quiet) sim.emit('output', { agent: id, line: line });
    }

    // decisions — request opens, answer closes
    if (type === 'decision.request') {
      const id = p.decision || p.id || String(ev.seq);
      if (!WB.DECISIONS.find((d) => d.id === id)) {
        const d = { id: id, title: p.title || p.text || 'decision ' + id, context: p.context || '', ts: when };
        WB.DECISIONS.push(d);
        if (!quiet) sim.emit('decision', d);
      }
    }
    if (type === 'decision.answer') {
      const id = p.decision || p.id;
      const idx = WB.DECISIONS.findIndex((d) => d.id === id);
      if (idx >= 0) { WB.DECISIONS.splice(idx, 1); if (!quiet) sim.emit('decision', null); }
    }

    // jobs
    if (type.startsWith('job.')) {
      const id = p.job || p.name || 'job-' + ev.seq;
      let j = WB.JOBS.find((x) => x.id === id);
      if (!j) { j = { id: id, engine: p.engine || 'claude', task: p.task || null, state: 'queued', startedAt: when, via: p.via || ev.room }; WB.JOBS.unshift(j); }
      if (type === 'job.started' || type === 'job.output') j.state = 'running';
      else if (type === 'job.done') j.state = 'done';
      else if (type === 'job.failed') j.state = 'failed';
      else if (type === 'job.cancelled') j.state = 'stopped';
      else if (type === 'job.queued') j.state = p.retry ? 'queued (retry)' : 'queued';
      j.startedOff = Math.max(0, Math.round((Date.now() - j.startedAt) / 60000));
    }

    // leads
    if (type === 'lead.purpose_set') {
      const scope = p.scope || ev.room;
      let l = WB.LEADS.find((x) => x.actor === ev.from);
      if (!l) { l = { actor: ev.from, mode: p.mode || 'track', scope: scope, liveness: 'live' }; WB.LEADS.push(l); }
      l.purpose = p.purpose || p.text || l.purpose;
      l.isHost = ev.from === WB.HOST.startedBy;
    }
    if (type === 'lead.adopted') {
      const l = WB.LEADS.find((x) => x.actor === (p.lead || ev.to || ev.from));
      if (l) l.liveness = 'adopted';
    }
    if (type === 'lead.closed') {
      const idx = WB.LEADS.findIndex((x) => x.actor === (p.lead || ev.from));
      if (idx >= 0) WB.LEADS.splice(idx, 1);
    }

    // tasks (best-effort from the event stream — the durable board is on disk)
    if (type === 'task.claim' || type === 'task.status' || type === 'task.reassigned') {
      const id = p.task_id || p.task;
      if (id != null) {
        let t = WB.TASKS.find((x) => String(x.id) === String(id));
        if (!t) { t = { id: id, title: p.title || 'task ' + id, track: p.track || ev.room.replace(/^repo:/, ''), col: 'in-development' }; WB.TASKS.push(t); }
        if (p.status && WB.LEVELS.fleet.cols.includes(p.status)) t.col = p.status;
        if (type === 'task.reassigned') { t.agent = p.assignee || ev.to; t.who = null; }
        if (type === 'task.claim') t.agent = ev.from;
      }
    }

    // audit trail
    if (/^(invite|device)\./.test(type) || type === 'decision.answer') {
      WB.AUDIT.unshift({ off: Math.max(0, Math.round((Date.now() - when) / 60000)), icon: railIcon[type] || 'shield', text: type + ' — ' + (p.role || p.device || p.decision || '') + ' by ' + displayWho(ev.from) });
      if (WB.AUDIT.length > 40) WB.AUDIT.pop();
    }
  }

  function projectHost(h) {
    WB.HOST.machine = h.hostname || h.host || WB.HOST.machine;
    WB.HOST.port = h.port || WB.HOST.port;
    WB.HOST.mode = h.mode || WB.HOST.mode;
    WB.HOST.lanIp = (Array.isArray(h.lan_ips) && h.lan_ips[0]) || h.host || WB.HOST.lanIp;
    WB.HOST.startedBy = h.started_by || WB.HOST.startedBy;
    if (h.started_at) WB.HOST.startedAt = Date.parse(h.started_at) || WB.HOST.startedAt;
    const hostAgent = WB.AGENTS.find((a) => a.id === WB.HOST.startedBy);
    if (hostAgent) hostAgent.isHostSession = true;
  }

  function projectDevices(list) {
    WB.DEVICES.length = 0;
    for (const d of list) {
      const lastSeen = d.last_seen_at ? Date.parse(d.last_seen_at) : null;
      const off = lastSeen ? Math.max(0, (Date.now() - lastSeen) / 60000) : 9999;
      WB.DEVICES.push({
        id: d.device || '—',
        platform: d.platform || '—',
        transport: 'lan',
        ip: '',
        role: d.role || '—',
        enrolled: (d.accepted_at || '').replace('T', ' ').replace(/\..*$/, ''),
        lastSeenOff: off,
        stale: off > 24 * 60,
        state: d.revoked_at ? 'revoked' : 'enrolled',
      });
    }
  }

  function recomputeDerived() {
    const now = Date.now();
    for (const a of WB.AGENTS) {
      const age = now - (a.lastSeen || 0);
      const prev = a.heat;
      a.heat = age < 120000 ? 'hot' : age < 15 * 60000 ? 'idle' : 'stale';
      if (a.heat === 'stale') a.staleSince = a.lastSeen || now;
      a.isHostSession = a.id === WB.HOST.startedBy;
      if (prev !== a.heat && WB.app) WB.app.refreshChrome();
    }
    for (const l of WB.LEADS) {
      if (l.liveness === 'adopted') continue;
      const a = WB.AGENTS.find((x) => x.id === l.actor);
      const alive = a && a.heat !== 'stale';
      l.liveness = alive ? 'live' : 'stale';
      if (!alive && a) l.staleFor = WB.ui.rel(now - (a.staleSince || now));
      l.isHost = l.actor === WB.HOST.startedBy;
    }
    deriveHostState(now);
  }

  let tickN = 0;
  function tick() {
    tickN += 1;
    sim.t = tickN;
    // liveness: if nothing has been heard for 15s and the socket is gone, poll
    if (token && !socket && tickN % 2 === 0) loadState();
    if (token && lastContact && Date.now() - lastContact > 30000 && !socket) setHostState('down');
    recomputeDerived();
    sim.emit('tick', tickN);
    for (const inv of WB.INVITES) { if (inv.ttl > 0) inv.ttl -= 1; }
  }

  /* ── real actions ── */
  function post(type, room, payload, to) {
    const ev = { type: type, room: room, from: SELF, payload: payload || {} };
    if (to) ev.to = to;
    return fetch('/api/events', { method: 'POST', headers: headers(true), body: JSON.stringify(ev) })
      .then(requireOk)
      .then((data) => { lastContact = Date.now(); ingest(data, true); return data; })
      .catch((err) => { WB.ui.toast('Send failed: ' + err.message); throw err; });
  }

  WB.api = {
    post: post,
    sendChat(m) {
      pendingSelf.push(m.text);
      const type = m.kind === 'ask' ? 'message.request_status' : m.kind === 'handoff' ? 'task.handoff' : 'message.sent';
      const payload = m.kind === 'handoff' ? { task_id: m.text } : { text: m.text };
      return post(type, m.room === 'team' ? 'repo:workbench' : m.room, payload, m.to || undefined).then((data) => {
        if (data && data.seq) {
          // Backfill the real server-assigned seq onto the object already pushed
          // into WB.CHAT by bench.js's send(). Without this the optimistic entry
          // has seq=undefined and the sort comparator (using ?? Infinity) keeps it
          // pinned to the end forever — correct now but wrong once any later real
          // message arrives.
          m.seq = data.seq;
          WB.RECEIPTS[data.seq] = WB.RECEIPTS[data.seq] || { deliveredBy: new Set(), seenBy: new Set() };
          WB.RECEIPTS[data.seq].serverReceivedAt = Date.now();
          sim.emit('receipt', data.seq);
        }
        return data;
      });
    },
    loadOlder(room, beforeSeq) {
      const params = new URLSearchParams({ room: room, before: String(beforeSeq), limit: '50' });
      return fetch('/api/events?' + params.toString(), { headers: headers(false) })
        .then(requireOk)
        .then((data) => {
          const evs = Array.isArray(data.events) ? data.events : [];
          for (const ev of evs) ingest(ev, true); // quiet — no chat/heartbeat emits, just backfills WB.CHAT
          return evs;
        });
    },
    resolveDecision(id, approved) {
      return post('decision.answer', 'decisions', { decision: id, answer: approved ? 'approved' : 'denied', approved: approved });
    },
    reassignTask(taskId, assignee) {
      return post('task.reassigned', 'tasks', { task: String(taskId), assignee: assignee }, assignee);
    },
    taskTransition(taskId, col) {
      return post('task.status', 'tasks', { task: String(taskId), status: col });
    },
    stopJob(id) { return post('job.cancelled', 'jobs', { job: id, reason: 'operator stopped' }); },
    retryJob(id, task, engine) { return post('job.queued', 'jobs', { job: id, task: task, engine: engine, retry: true }); },
    adoptLead(actor) { return post('lead.adopted', 'presence', { lead: actor, reason: 'stale lead adopted' }, actor); },
    closeLead(actor) { return post('lead.closed', 'presence', { lead: actor, reason: 'operator closed' }, actor); },
    createInvite(role, ttlSeconds) {
      return fetch('/api/invites', {
        method: 'POST', headers: headers(true),
        body: JSON.stringify({ role: role, ttl_seconds: ttlSeconds, max_uses: 1 }),
      }).then(requireOk).then((data) => {
        post('invite.created', 'repo:workbench', { role: data.role, expires_at: data.expires_at, source: 'command-center' });
        return data;
      });
    },
    revokeInvite(tokenValue) {
      return fetch('/api/invites/revoke', {
        method: 'POST', headers: headers(true),
        body: JSON.stringify({ token: tokenValue }),
      }).then(requireOk).then(() => post('invite.revoked', 'repo:workbench', { token_hint: tokenValue.slice(0, 12) + '…', reason: 'operator revoked' }));
    },
    revokeDevice(device) {
      return fetch('/api/devices/revoke', {
        method: 'POST', headers: headers(true),
        body: JSON.stringify({ device: device }),
      }).then(requireOk);
    },
  };
})(window.WB);
