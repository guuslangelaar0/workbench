// Bench surface — stations on the bench, team chat, the for-you rail,
// and the per-agent session focus view.
window.WB = window.WB || {};
(function (WB) {
  const { el, chip, pulse, empty, clock, rel, confirm, toast, leadName, leadColor } = WB.ui;
  let roomFilter = 'all';
  WB.FEEDLOG = {};
  WB.SNAPSHOTS = {};
  WB.RECEIPTS = WB.RECEIPTS || {};

  const TOOL_ICON = { Bash: 'terminal', Edit: 'pencil', Read: 'file-code', Git: 'git', Test: 'check-circle', Screenshot: 'camera' };

  // Client-side reveal animation only — nothing here changes what data
  // crosses the wire (the tailer still only ever sends finished boundary
  // chunks, never token deltas). This just avoids dumping a whole chunk
  // into the DOM at once, so arrival feels like a continuous stream rather
  // than a bucket dropping in. ~28 chars/frame at 60fps ≈ natural reading pace.
  function revealText(el, text, opts) {
    const o = opts || {};
    const speed = o.charsPerFrame || 3;
    if (o.instant || !text) { el.textContent = text || ''; return; }
    let i = 0;
    el.textContent = '';
    el.classList.add('reveal-cursor');
    function step() {
      i = Math.min(text.length, i + speed);
      el.textContent = text.slice(0, i);
      if (i < text.length) { requestAnimationFrame(step); }
      else { el.classList.remove('reveal-cursor'); }
    }
    requestAnimationFrame(step);
  }

  function agent(id) { return WB.AGENTS.find((a) => a.id === id); }

  /* ── stations ── */
  function stationNode(a) {
    const heat = WB.eff.heat(a);
    const down = WB.state.hostState === 'down';
    const n = el('div', { class: 'station' + (down ? ' ghost' : ''), 'data-heat': heat, 'data-agent': a.id, onclick: () => { if (!down) WB.app.go('bench', a.id); } }, [
      el('div', { class: 'st-top' }, [
        pulse(heat),
        (() => { const s = leadName(a.id); s.className = 'st-name'; return s; })(),
        toolChip(a, heat),
      ]),
      el('div', { class: 'st-meta' }, [
        el('span', { text: a.provider + ' · ' + a.model }),
        (a.crew && a.crew.length) ? el('span', { class: 'st-crew', title: '1 lead + ' + a.crew.length + ' agents behind it', html: svgIcon('user', 10) + ' +' + a.crew.length + ' ' + svgIcon('bot', 10) }) : null,
      ]),
      el('div', { class: 'st-doing', text: a.doing }),
      el('div', { class: 'st-out t-mono', text: a.lastOutput }),
    ]);
    const note = WB.eff.note(a);
    if (note) n.appendChild(el('div', { class: 'st-note', text: note }));
    else if (heat === 'stale' && a.staleSince) n.appendChild(el('div', { class: 'st-note', text: 'last heartbeat ' + rel(Date.now() - a.staleSince) + ' ago' }));
    return n;
  }
  function toolChip(a, heat) {
    // fresh engagement beats the last-tool chip: reading/typing is what the
    // actor is doing RIGHT NOW, between messages
    const act = WB.eff.activity(a);
    if (act === 'typing') return el('span', { class: 'st-tool', html: svgIcon('pencil', 10) + ' typing…' });
    if (act === 'reading') return el('span', { class: 'st-tool', html: svgIcon('eye', 10) + ' reading' });
    if (heat === 'stale' || heat === 'dead') return el('span', { class: 'st-tool idle', html: svgIcon('moon', 10) + ' quiet' });
    if (!a.tool) return el('span', { class: 'st-tool idle', html: svgIcon('coffee', 10) + ' idle' });
    return el('span', { class: 'st-tool', html: svgIcon(TOOL_ICON[a.tool] || 'terminal', 10) + ' ' + WB.ui.esc(a.tool) });
  }

  /* ── chat ── */
  function receiptGlyph(m) {
    if (!m.seq) return null;
    const r = WB.RECEIPTS[m.seq];
    if (!r) return el('span', { class: 'tick tick-sent', title: 'sent', text: '✓' });
    if (r.seenBy && r.seenBy.size) return el('span', { class: 'tick tick-seen', title: 'seen', text: '✓✓' });
    if (r.deliveredBy && r.deliveredBy.size) return el('span', { class: 'tick tick-delivered', title: 'delivered', text: '✓✓' });
    if (r.serverReceivedAt) return el('span', { class: 'tick tick-received', title: 'sent', text: '✓' });
    return null;
  }
  function roomReceiptSummary(m) {
    if (!m.seq || m.to) return null; // room aggregate only applies to non-DM posts
    const r = WB.RECEIPTS[m.seq];
    const seenCount = r && r.seenBy ? r.seenBy.size : 0;
    if (!seenCount) return null;
    const total = WB.AGENTS.filter((a) => WB.eff.heat(a) !== 'dead').length || 1;
    return el('span', { class: 'seen-by', text: 'seen by ' + seenCount + '/' + total });
  }
  function msgNode(m) {
    if (m.kind === 'handoff') {
      return el('div', { class: 'sysline', html: svgIcon('arrow-right', 12) + ' <b>' + WB.ui.esc(m.who) + '</b>&nbsp;handoff — ' + WB.ui.esc(m.text) });
    }
    const me = m.who === 'you (operator)';
    const bubble = el('div', { class: 'bubble' + (m.kind === 'command' ? ' cmd' : '') });
    if (m.kind === 'ask') bubble.appendChild(el('span', { class: 'ask-chip', html: chip('status?', 'amber').outerHTML }));
    bubble.appendChild(el('span', { class: 'bubble-text', text: (m.kind === 'command' ? '$ ' : '') + m.text }));
    let tag;
    if (m.to) tag = '→ @' + m.to;
    else if (m.room === 'team') tag = '→ team' + (m.via ? ' · via ' + m.via : '');
    else tag = '→ ' + m.room + (me && m.via ? ' · via ' + m.via : '');
    const nameSpan = me ? el('span', { text: m.who }) : leadName(m.who);
    const tsRow = el('div', { class: 'ts' }, [document.createTextNode(clock(m.ts))]);
    if (me) {
      const glyph = receiptGlyph(m);
      if (glyph) tsRow.appendChild(glyph);
      const roomSummary = roomReceiptSummary(m);
      if (roomSummary) tsRow.appendChild(roomSummary);
    }
    return el('div', { class: 'msg' + (me ? ' me' : ''), 'data-seq': m.seq != null ? String(m.seq) : '' }, [
      el('div', { class: 'who' }, [nameSpan, el('span', { class: 'room-tag', text: ' ' + tag })]),
      bubble,
      tsRow,
    ]);
  }
  function chatMatches(m) { return roomFilter === 'all' || m.room === roomFilter || m.room === 'team'; }
  const CHAT_MOUNT_CAP = 150;
  function renderChatList(scroll, visibleCount) {
    scroll.replaceChildren();
    const matched = WB.CHAT.filter(chatMatches).slice().sort((a, b) => (a.seq ?? Infinity) - (b.seq ?? Infinity));
    const cap = visibleCount != null ? Math.min(visibleCount, CHAT_MOUNT_CAP) : CHAT_MOUNT_CAP;
    const page = matched.slice(-cap);
    for (const m of page) {
      const node = msgNode(m);
      node.classList.add('cv-row');
      scroll.appendChild(node);
    }
    scroll.scrollTop = scroll.scrollHeight;
  }
  // Routing: the host lead fronts everything by default; @name targets a
  // specific lead directly. Crew agents are never addressable from here.
  function routeFor(text) {
    const hit = text.match(/@([\w-]+)/);
    if (hit) {
      const a = WB.AGENTS.find((x) => x.id === hit[1] || x.id.startsWith(hit[1]));
      if (a) return { to: a.id };
    }
    const host = WB.AGENTS.find((a) => a.isHostSession);
    const hostLive = WB.state.hostState === 'healthy';
    return { via: hostLive && host ? host.id : null };
  }
  function routeHintText(r) {
    if (r.to) return ['direct → ', '@' + r.to, ''];
    const scope = roomFilter === 'all' ? 'everyone' : roomFilter;
    if (!r.via) return ['→ ' + scope + ' · ', 'no host session', ' — @mention a lead to target one directly'];
    return ['→ ' + scope + ' · ', r.via + ' (host)', ' leads by default — @name targets a lead directly'];
  }

  // @-mention autocomplete — CLI-style: match the token under the caret,
  // arrow keys to move, Enter/Tab to accept, Escape to dismiss. Rendered
  // as a fixed-position singleton in #overlay-root so the chat card's
  // rounded-corner overflow:hidden never clips it.
  const HEAT_ORDER = { hot: 0, idle: 1, stale: 2, dead: 3 };
  function atTokenAt(value, pos) {
    const upto = value.slice(0, pos);
    const m = upto.match(/(^|\s)@([\w-]*)$/);
    if (!m) return null;
    return { start: upto.length - m[2].length - 1, query: m[2] };
  }
  let atMenuEl = null;
  function getAtMenu() {
    if (!atMenuEl || !atMenuEl.isConnected) {
      atMenuEl = el('div', { class: 'at-menu' });
      atMenuEl.hidden = true;
      document.getElementById('overlay-root').appendChild(atMenuEl);
    }
    return atMenuEl;
  }
  function positionAtMenu(menu, inputEl) {
    const r = inputEl.getBoundingClientRect();
    menu.style.left = r.left + 'px';
    menu.style.width = r.width + 'px';
    menu.style.bottom = (window.innerHeight - r.top + 6) + 'px';
  }
  function chatCol() {
    const scroll = el('div', { class: 'chat-scroll', id: 'chat-scroll' });
    const roomIds = WB.ROOMS.filter((r) => !r.output && r.id !== 'presence').map((r) => r.id).slice(0, 4);
    const chips = el('div', { class: 'room-chips' },
      ['all'].concat(roomIds).map((r) =>
        el('button', { class: 'room-chip' + (roomFilter === r ? ' on' : ''), text: r, onclick: (e) => {
          roomFilter = r;
          e.target.parentNode.querySelectorAll('.room-chip').forEach((c) => c.classList.toggle('on', c === e.target));
          reseedWindow();
          updateHint();
        } })));
    const input = el('textarea', { rows: '1', placeholder: 'Message the team… (@name for one lead · shift+enter for a new line)' });
    const autoGrow = () => { input.style.height = 'auto'; input.style.height = Math.min(input.scrollHeight, 132) + 'px'; };
    input.addEventListener('input', autoGrow);
    const hint = el('div', { class: 'route-hint' });
    const menu = getAtMenu();
    let menuItems = [];
    let menuIndex = 0;

    function closeMenu() { menu.hidden = true; menu.replaceChildren(); menuItems = []; }
    function renderMenu() {
      menu.replaceChildren();
      menuItems.forEach((a, i) => {
        const row = el('div', { class: 'at-item' + (i === menuIndex ? ' on' : ''), onmousedown: (e) => { e.preventDefault(); pick(a); } }, [
          pulse(WB.eff.heat(a)),
          leadName(a.id),
          el('span', { class: 'at-doing', text: a.doing }),
        ]);
        menu.appendChild(row);
      });
    }
    function openMenuFor(query) {
      const q = query.toLowerCase();
      menuItems = WB.AGENTS.filter((a) => a.id.toLowerCase().startsWith(q))
        .sort((x, y) => HEAT_ORDER[WB.eff.heat(x)] - HEAT_ORDER[WB.eff.heat(y)]);
      if (!menuItems.length) { closeMenu(); return; }
      menuIndex = 0;
      positionAtMenu(menu, input);
      renderMenu();
      menu.hidden = false;
    }
    function pick(a) {
      const pos = input.selectionStart;
      const tok = atTokenAt(input.value, pos);
      if (!tok) { closeMenu(); return; }
      const before = input.value.slice(0, tok.start);
      const after = input.value.slice(pos);
      input.value = before + '@' + a.id + ' ' + after;
      const newPos = (before + '@' + a.id + ' ').length;
      closeMenu();
      input.focus();
      input.setSelectionRange(newPos, newPos);
      updateHint();
    }

    function updateHint() {
      const [pre, strong, post] = routeHintText(routeFor(input.value));
      hint.replaceChildren(
        el('span', { html: svgIcon('radio', 10) }),
        el('span', {}, [el('span', { text: pre }), el('b', { text: strong }), el('span', { text: post })]),
      );
    }
    input.addEventListener('input', () => {
      updateHint();
      const tok = atTokenAt(input.value, input.selectionStart);
      if (tok) openMenuFor(tok.query); else closeMenu();
    });
    input.addEventListener('keydown', (e) => {
      if (!menu.hidden && menuItems.length) {
        if (e.key === 'ArrowDown') { e.preventDefault(); menuIndex = (menuIndex + 1) % menuItems.length; renderMenu(); return; }
        if (e.key === 'ArrowUp') { e.preventDefault(); menuIndex = (menuIndex - 1 + menuItems.length) % menuItems.length; renderMenu(); return; }
        if (e.key === 'Enter' || e.key === 'Tab') { e.preventDefault(); pick(menuItems[menuIndex]); return; }
        if (e.key === 'Escape') { e.preventDefault(); closeMenu(); return; }
      }
      if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); }
    });
    input.addEventListener('blur', () => setTimeout(closeMenu, 120));
    const send = () => {
      const t = input.value.trim();
      if (!t) return;
      const r = routeFor(t);
      input.value = '';
      autoGrow();
      closeMenu();
      updateHint();
      // Direct sends use the CLI convention: an actor's direct room is named
      // after the actor (room_for_target), not whatever room it last posted in.
      const room = r.to ? r.to : (roomFilter === 'all' ? 'team' : roomFilter);
      const m = { room: room, who: 'you (operator)', kind: 'msg', text: t, ts: Date.now(), to: r.to || null, via: r.to ? null : r.via };
      WB.CHAT.push(m);
      const rm = WB.ROOMS.find((x) => x.id === room);
      if (rm) rm.events += 1;
      if (WB.api) WB.api.sendChat(m);
      if (chatMatches(m)) { scroll.appendChild(msgNode(m)); scroll.scrollTop = scroll.scrollHeight; }
    };
    const typing = el('div', { class: 'typing-line', id: 'typing-line' });
    const col = el('div', { class: 'chat-col' }, [
      el('div', { class: 'chat-head' }, [
        el('div', { class: 't-eyebrow', text: 'Team chat' }),
        chips,
      ]),
      scroll,
      typing,
      el('div', { class: 'composer' }, [
        input,
        el('button', { class: 'send', 'aria-label': 'Send', html: svgIcon('arrow-right', 15), onclick: send }),
      ]),
      hint,
    ]);
    let visibleCount = 0;
    let oldestLoadedSeq = null;
    let loadingOlder = false;
    // Seed (or re-seed after a room-filter switch) the pagination cursor and
    // visibleCount from the current chatMatches() result set.  Called once at
    // mount and again whenever roomFilter changes so oldestLoadedSeq always
    // refers to the active room's window, not a stale one from a previous room.
    function reseedWindow() {
      const seeded = WB.CHAT.filter(chatMatches).slice().sort((a, b) => (a.seq ?? Infinity) - (b.seq ?? Infinity));
      const seededWindow = seeded.length > 50 ? seeded.slice(-50) : seeded;
      visibleCount = Math.min(50, seeded.length);
      oldestLoadedSeq = seededWindow.length ? seededWindow[0].seq : null;
      renderChatList(scroll, visibleCount);
    }
    scroll.addEventListener('scroll', () => {
      if (loadingOlder || scroll.scrollTop > 150) return;
      if (oldestLoadedSeq == null) return;
      loadingOlder = true;
      const before = oldestLoadedSeq;
      const prevHeight = scroll.scrollHeight;
      const room = roomFilter === 'all' ? 'team' : roomFilter;
      WB.api.loadOlder(room, before).then((evs) => {
        loadingOlder = false;
        if (!evs.length) return;
        visibleCount += evs.length;
        oldestLoadedSeq = Math.min(...evs.map((e) => e.seq));
        renderChatList(scroll, visibleCount);
        scroll.scrollTop = scroll.scrollHeight - prevHeight; // preserve viewport position
      }).catch(() => { loadingOlder = false; });
    });
    updateHint();
    reseedWindow();
    renderTypingLine();
    return col;
  }

  /* ── for-you rail (shared with Board's decisions rail) ── */
  function decisionCard(d, after) {
    const card = el('div', { class: 'fy-card' }, [
      el('div', { class: 'fy-top' }, [
        el('span', { class: 'fy-id', text: 'decision ' + d.id }),
        el('span', { class: 'fy-age', text: 'queued ' + rel(Date.now() - d.ts) }),
      ]),
      el('div', { class: 'fy-title', text: d.title }),
      el('div', { class: 'fy-sub', text: d.context }),
      el('div', { class: 'fy-actions' }, [
        el('button', { class: 'btn', text: 'Approve', onclick: () => resolveDecision(d, 'approved', after) }),
        el('button', { class: 'btn quiet', text: 'Deny', onclick: () => resolveDecision(d, 'denied', after) }),
      ]),
    ]);
    return card;
  }
  function resolveDecision(d, outcome, after) {
    confirm({
      title: (outcome === 'approved' ? 'Approve' : 'Deny') + ' this decision?',
      body: 'This is the dashboard quick-action. The durable lifecycle transition is the CLI’s — the two agree on semantics.',
      target: 'decision ' + d.id + ' — ' + d.title,
      note: 'Stamped as: ' + outcome + ' by you (operator).',
      confirmLabel: outcome === 'approved' ? 'Approve' : 'Deny',
      danger: outcome === 'denied',
      onConfirm: () => {
        WB.DECISIONS.splice(WB.DECISIONS.indexOf(d), 1);
        if (WB.api) WB.api.resolveDecision(d.id, outcome === 'approved');
        toast('Decision ' + d.id + ' ' + outcome, '/workbench:decision resolve ' + d.id);
        after && after();
        WB.app.refreshChrome();
      },
    });
  }
  function staleLeadCards(after) {
    const cards = [];
    for (const l of WB.eff.leads()) {
      if (l.liveness !== 'stale') continue;
      cards.push(el('div', { class: 'fy-card' }, [
        el('div', { class: 'fy-top' }, [
          el('span', { class: 'fy-id', text: 'lead · ' + l.mode + ':' + l.scope }),
          el('span', { class: 'fy-age', text: l.staleFor + ' stale' }),
        ]),
        el('div', { class: 'fy-title', text: l.actor + ' has gone quiet' }),
        el('div', { class: 'fy-sub', text: (l.purpose || 'Held the ' + l.scope + ' track.') + ' Another session can adopt the lead.' }),
        el('div', { class: 'fy-actions' }, [
          el('button', { class: 'btn', text: 'Adopt lead', onclick: () => confirm({
            title: 'Adopt this stale lead?',
            body: 'Your session takes over the purpose and scope. The previous holder keeps nothing.',
            target: l.actor + ' · ' + l.mode + ':' + l.scope + ' · stale ' + l.staleFor,
            confirmLabel: 'Adopt',
            onConfirm: () => { l.liveness = 'adopted'; if (WB.api) WB.api.adoptLead(l.actor); toast('Lead adopted', '/workbench:lead adopt --as you'); after && after(); WB.app.refreshChrome(); },
          }) }),
        ]),
      ]));
    }
    return cards;
  }
  WB.renderForYou = function (container, opts) {
    const o = opts || {};
    const rerender = () => WB.renderForYou(container, opts);
    container.replaceChildren();
    if (!o.noLabel) container.appendChild(el('div', { class: 't-eyebrow', text: 'For you' }));
    let n = 0;
    for (const d of WB.DECISIONS) { container.appendChild(decisionCard(d, rerender)); n += 1; }
    if (!o.decisionsOnly) for (const c of staleLeadCards(rerender)) { container.appendChild(c); n += 1; }
    const inReview = WB.TASKS.filter((t) => t.col === 'in-review').length;
    if (!o.decisionsOnly && inReview >= WB.IN_REVIEW_CAP - 3) {
      container.appendChild(el('div', { class: 'fy-card' }, [
        el('div', { class: 'fy-top' }, [el('span', { class: 'fy-id', text: 'in-review pressure' })]),
        el('div', { class: 'fy-title', text: 'Review queue near hard-drain (' + inReview + '/' + WB.IN_REVIEW_CAP + ')' }),
        el('div', { class: 'fy-sub', text: 'The loop stops picking new work at cap−3 and drains reviews first.' }),
      ]));
      n += 1;
    }
    if (n === 0) {
      container.appendChild(empty('check-circle', 'Nothing needs you.', 'The loop keeps moving on its own.'));
    }
    if (o.footNote) container.appendChild(el('div', { class: 'fy-note', text: o.footNote }));
  };

  /* ── session focus ── */
  function seedFeed(a) {
    if (WB.FEEDLOG[a.id]) return WB.FEEDLOG[a.id];
    const log = [];
    const base = Date.now() - a.script.length * 42000;
    a.script.forEach((line, i) => log.push({ ts: base + i * 42000, line: line }));
    WB.FEEDLOG[a.id] = log;
    return log;
  }
  function feedLine(entry) {
    const line = entry.line;
    const kindCls = line.k === 'tool' ? 'k-tool' : line.k === 'test' ? 'k-test' : line.k === 'git' ? 'k-git' : 'k-msg';
    const kindLabel = line.k === 'msg' ? '·' : (line.tool || line.k);
    const iconName = line.k === 'msg' ? null : (TOOL_ICON[line.tool] || (line.k === 'test' ? 'check-circle' : 'terminal'));
    return el('div', { class: 'fl' + (line.dim ? ' dim' : '') }, [
      el('span', { class: 'fl-ts', text: clock(entry.ts) }),
      el('span', { class: 'fl-kind ' + kindCls, html: (iconName ? svgIcon(iconName, 11) + ' ' : '') + WB.ui.esc(kindLabel) }),
      el('span', { class: 'fl-text', text: line.t }),
    ]);
  }
  function focusView(a) {
    const heat = WB.eff.heat(a);
    const feed = el('div', { class: 'feed', id: 'focus-feed', 'data-agent': a.id });
    for (const entry of combinedEntries(a).slice(-60)) feed.appendChild(renderCombined(entry));

    const live = heat === 'hot' || heat === 'idle';
    const liveTag = live
      ? el('span', { class: 'feed-live' }, [pulse(heat), el('span', { text: 'streaming · output:' + a.id })])
      : el('span', { class: 'feed-live stale-note', text: 'no live output — last heartbeat ' + rel(Date.now() - (a.staleSince || Date.now() - 60000)) + ' ago' });
    const task = a.task ? WB.TASKS.find((t) => t.id === a.task) : null;
    const meta = el('aside', { class: 'session-meta' }, [
      el('div', { class: 'sm-card' }, [
        el('h4', { text: 'Session' }),
        kvRow('provider', a.provider), kvRow('model', a.model), kvRow('device', a.platform),
        kvRow('worktree', a.worktree), kvRow('room', a.room),
        kvRow('heartbeat', live ? 'just now' : rel(Date.now() - (a.staleSince || WB.HOST.orphanedSince || Date.now() - 60000)) + ' ago'),
      ]),
      el('div', { class: 'sm-card' }, [
        el('h4', { text: 'Dispatch capabilities' }),
        el('div', { class: 'cap-chips' }, a.caps.map((c) => chip(c, c === 'ios-simulator' ? 'amber' : 'ghost'))),
        el('div', { class: 'token-note', html: svgIcon('server', 12) + '<span>Platform-derived — ios-simulator only ever appears on macOS.</span>' }),
      ]),
      crewCard(a),
      task ? el('div', { class: 'sm-card' }, [
        el('h4', { text: 'Working on' }),
        el('div', { class: 'fy-id', text: String(task.id) }),
        el('div', { class: 'fy-title', text: task.title }),
        el('div', { style: 'margin-top:7px; display:flex; gap:5px;' }, [chip(task.track, 'ghost'), chip(task.col)]),
      ]) : null,
    ]);

    const wrap = el('div', { class: 'focus-wrap', 'data-screen-label': 'Session — ' + a.id }, [
      el('div', { class: 'focus-head' }, [
        el('button', { class: 'btn quiet', html: svgIcon('arrow-left', 13) + ' Bench', onclick: () => WB.app.go('bench') }),
        el('div', { class: 'focus-id' }, [
          el('div', { class: 'focus-name' }, [
            pulse(heat),
            leadName(a.id, 'font-size:15px; font-weight:600;'),
            el('span', { class: 'chips' }, [chip(a.provider, 'ghost'), chip(a.model, 'ghost'), chip(a.platform, 'ghost')]),
          ]),
          el('div', { class: 'focus-doing', text: a.doing }),
        ]),
        el('div', { class: 'focus-actions' }, [
          el('button', { class: 'btn', html: svgIcon('chat', 12) + ' Ask status', onclick: () => askStatus(a) }),
          el('button', { class: 'btn', html: svgIcon('arrow-right', 12) + ' Hand off', onclick: () => handOff(a) }),
        ]),
      ]),
      el('div', { class: 'focus-cols' }, [
        el('div', { class: 'feed-col' }, [
          el('div', { class: 'feed-head' }, [
            el('div', { class: 't-eyebrow', text: 'Live output' }),
            liveTag,
          ]),
          feed,
          termPrompt(a, feed),
        ]),
        meta,
      ]),
    ]);
    requestAnimationFrame(() => { feed.scrollTop = feed.scrollHeight; });
    return wrap;
  }
  function kvRow(k, v) {
    return el('div', { class: 'kv' }, [el('span', { class: 'k', text: k }), el('span', { class: 'v', text: v })]);
  }

  /* Direct message, merged straight into the terminal feed — click a lead,
     type, hit enter. No separate chat panel; it's the same scrollback. */
  function dmMatches(a, m) { return m.who === a.id || m.to === a.id; }
  function dmMsgList(a) { return WB.CHAT.filter((m) => dmMatches(a, m)); }
  function combinedEntries(a) {
    const toolEntries = seedFeed(a).map((e) => ({ ts: e.ts, tool: true, entry: e }));
    const chatEntries = dmMsgList(a).map((m) => ({ ts: m.ts, chat: true, msg: m }));
    return toolEntries.concat(chatEntries).sort((x, y) => x.ts - y.ts);
  }
  function chatTermLine(m) {
    const me = m.who === 'you (operator)';
    let who;
    if (me) { who = el('span', { text: 'you', style: 'font-weight:600; color:var(--ink-2);' }); }
    else { who = leadName(m.who); who.style.fontWeight = '600'; }
    return el('div', { class: 'fl fl-chat' }, [
      el('span', { class: 'fl-ts', text: clock(m.ts) }),
      el('span', { class: 'fl-kind k-chat', text: me ? '❯' : '❮' }),
      el('span', { class: 'fl-text' }, [who, document.createTextNode(': ' + m.text)]),
    ]);
  }
  function renderCombined(entry) { return entry.tool ? feedLine(entry.entry) : chatTermLine(entry.msg); }
  function termPrompt(a, feed) {
    const input = el('textarea', { rows: '1', placeholder: 'Message ' + a.id + '…' });
    const autoGrow = () => { input.style.height = 'auto'; input.style.height = Math.min(input.scrollHeight, 120) + 'px'; };
    input.addEventListener('input', autoGrow);
    const send = () => {
      const t = input.value.trim();
      if (!t) return;
      input.value = '';
      autoGrow();
      const m = { room: a.id, who: 'you (operator)', kind: 'msg', text: t, ts: Date.now(), to: a.id };
      WB.CHAT.push(m);
      const rm = WB.ROOMS.find((x) => x.id === a.id);
      if (rm) rm.events += 1;
      if (WB.api) WB.api.sendChat(m);
      feed.appendChild(chatTermLine(m));
      feed.scrollTop = feed.scrollHeight;
    };
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); }
    });
    return el('div', { class: 'term-prompt' }, [
      el('span', { class: 'term-caret', text: '❯' }),
      input,
      el('button', { class: 'term-send', 'aria-label': 'Send', html: svgIcon('arrow-right', 13), onclick: send }),
    ]);
  }

  /* Crew behind a lead — pull-based. The lead writes a snapshot to
     .workbench/mesh/agents/<lead>.json when asked; nothing streams. */
  function crewCard(a) {
    if (!a.crew || !a.crew.length) return null;
    const team = a.crew.filter((c) => c.kind === 'team').length;
    const sub = a.crew.length - team;
    const body = el('div', {});
    renderSnap(a, body);
    return el('div', { class: 'sm-card' }, [
      el('h4', { text: 'Crew — behind this lead' }),
      el('div', { style: 'display:flex; align-items:center; gap:6px; font-family:var(--font-mono); font-size:11px; color:var(--ink-2);', html: svgIcon('user', 11) + ' 1 lead · ' + svgIcon('bot', 11) + ' ' + team + ' team' + (sub ? ' + ' + sub + ' sub' : '') }),
      body,
      el('div', { class: 'token-note', html: svgIcon('radio', 12) + '<span>Crew agents never connect to the mesh — the lead answers for them, so the wire stays quiet.</span>' }),
    ]);
  }
  function renderSnap(a, body) {
    body.replaceChildren();
    const snap = WB.SNAPSHOTS[a.id];
    if (!snap) {
      const btn = el('button', { class: 'btn', style: 'font-size:11px; margin-top:9px;', html: svgIcon('arrow-right', 11) + ' Request crew snapshot' });
      btn.addEventListener('click', () => {
        btn.textContent = 'asking ' + a.id + '…';
        btn.setAttribute('disabled', 'disabled');
        WB.sim.pushEvent('crew.snapshot_requested', a.id + ' / you');
        setTimeout(() => {
          WB.SNAPSHOTS[a.id] = { ts: Date.now() };
          WB.sim.pushEvent('crew.snapshot_written', '.workbench/mesh/agents/' + a.id + '.json');
          renderSnap(a, body);
        }, 750);
      });
      body.appendChild(el('div', {}, [btn]));
      return;
    }
    const rows = a.crew.map((c) => el('div', { class: 'crew-row' }, [
      el('span', { class: 'cr-name', html: svgIcon('bot', 10) + ' ' + WB.ui.esc(c.name) }),
      el('span', { class: 'cr-role' }, [
        el('span', { text: c.role + (c.kind === 'sub' ? ' · subagent' : '') }),
        el('span', { class: 'cr-last', text: c.last }),
      ]),
      chip(c.state, c.state === 'working' ? 'amber' : c.state === 'done' ? 'green' : 'ghost'),
    ]));
    const foot = el('div', { class: 'snap-foot' }, [
      el('span', { text: 'as of ' + clock(snap.ts) + ' · .workbench/mesh/agents/' + a.id + '.json — written by the lead on request · ' }),
      el('a', { href: '#', text: 'refresh', style: 'color: var(--amber-deep);', onclick: (e) => { e.preventDefault(); WB.SNAPSHOTS[a.id] = null; renderSnap(a, body); } }),
    ]);
    body.appendChild(el('div', { style: 'margin-top:6px;' }, rows.concat([foot])));
  }
  function askStatus(a) {
    const m = { room: a.room, who: 'you (operator)', kind: 'ask', text: a.id + ' — status?', ts: Date.now(), to: a.id };
    WB.CHAT.push(m);
    if (WB.api) WB.api.sendChat(m);
    toast('Status requested in ' + a.room, 'mesh ask --to ' + a.id);
  }
  function handOff(a) {
    const t = a.task ? WB.TASKS.find((x) => x.id === a.task) : null;
    confirm({
      title: 'Hand off ' + (t ? 'task ' + t.id : a.id + '’s work') + '?',
      body: 'A task.handoff event posts to the room; the receiving session claims via wb-coord before it starts.',
      target: t ? t.id + ' — ' + t.title : a.doing,
      confirmLabel: 'Post handoff',
      onConfirm: () => {
        const m = { room: a.room, who: 'you (operator)', kind: 'handoff', text: (t ? t.id + ' ' : '') + '→ next available session', ts: Date.now() };
        WB.CHAT.push(m);
        if (WB.api) WB.api.post('task.handoff', a.room, { task_id: t ? String(t.id) : a.doing });
        toast('Handoff posted to ' + a.room, 'mesh handoff' + (t ? ' ' + t.id : ''));
      },
    });
  }

  /* ── surface ── */
  WB.surfaces = WB.surfaces || {};
  WB.surfaces.bench = {
    render(container) {
      container.replaceChildren();
      if (WB.state.focus) {
        const a = agent(WB.state.focus);
        if (a) { container.appendChild(focusView(a)); return; }
      }
      const order = { hot: 0, idle: 1, stale: 2, dead: 3 };
      const hostDev = (WB.DEVICES.find((d) => d.host) || {}).id;
      const devices = [];
      for (const a of WB.AGENTS) { if (!devices.includes(a.device)) devices.push(a.device); }
      devices.sort((x, y) => (x === hostDev ? -1 : 0) - (y === hostDev ? -1 : 0));
      const row = el('div', { class: 'bench-row' }, devices.map((dev) => {
        const leads = WB.AGENTS.filter((a) => a.device === dev)
          .sort((x, y) => order[WB.eff.heat(x)] - order[WB.eff.heat(y)]);
        return el('div', { class: 'bench-group' }, [
          el('div', { class: 'bg-tag', html: svgIcon('server', 10) + ' ' + WB.ui.esc(dev) + (dev === hostDev ? ' · host' : '') + ' · ' + leads.length + (leads.length === 1 ? ' lead' : ' leads') }),
          el('div', { class: 'bg-stations' }, leads.map(stationNode)),
        ]);
      }));
      const foryou = el('aside', { class: 'foryou', id: 'foryou' });
      WB.renderForYou(foryou, { footNote: 'Decisions queue here without blocking the loop — the lead moves on to unblocked work and checks back.' });
      const wrap = el('div', { class: 'bench-wrap', 'data-screen-label': 'Bench' }, [
        el('div', { class: 'bench-zone' }, [row]),
        el('div', { class: 'bench-below' }, [chatCol(), foryou]),
      ]);
      if (WB.state.hostState === 'down') {
        wrap.insertBefore(el('div', { style: 'padding: 10px 24px 0;' }, [
          empty('power', 'Nobody at the bench — the mesh is unreachable.', 'restart: /workbench:mesh start'),
        ]), wrap.firstChild);
      }
      container.appendChild(wrap);
    },
  };

  /* ── typing line: who is engaging right now, between messages ── */
  function renderTypingLine() {
    const line = document.getElementById('typing-line');
    if (!line) return;
    const engaged = WB.AGENTS.map((a) => ({ a, act: WB.eff.activity(a) })).filter((x) => x.act);
    line.replaceChildren();
    for (const { a, act } of engaged) {
      const n = leadName(a.id);
      n.style.fontWeight = '600';
      line.appendChild(el('span', { class: 'tl-item' }, [
        pulse(WB.eff.heat(a)),
        n,
        el('span', { text: ' is ' + (act === 'typing' ? 'typing…' : 'reading') }),
      ]));
    }
  }

  /* ── live wiring (guarded by DOM presence) ── */
  WB.sim.on('output', ({ agent: id, line }) => {
    const a = agent(id);
    if (WB.FEEDLOG[id]) WB.FEEDLOG[id].push({ ts: Date.now(), line: line });
    const st = document.querySelector('.station[data-agent="' + id + '"]');
    if (st) {
      const out = st.querySelector('.st-out');
      out.textContent = a.lastOutput;
      out.classList.remove('flash');
      void out.offsetWidth;
      out.classList.add('flash');
      const tc = st.querySelector('.st-tool');
      if (tc) tc.replaceWith(toolChip(a, WB.eff.heat(a)));
    }
    const feed = document.getElementById('focus-feed');
    if (feed && feed.getAttribute('data-agent') === id) {
      const pinned = feed.scrollTop + feed.clientHeight >= feed.scrollHeight - 48;
      const node = feedLine({ ts: Date.now(), line: line });
      feed.appendChild(node);
      const textEl = node.querySelector('.fl-text');
      if (textEl) { const full = textEl.textContent; revealText(textEl, full); }
      while (feed.children.length > 80) feed.removeChild(feed.firstChild);
      if (pinned) feed.scrollTop = feed.scrollHeight;
    }
  });
  WB.sim.on('receipt', (seq) => {
    // Update only the affected message's tick in-place — a full list re-render
    // would jump the viewport to the bottom on every ack, breaking the UX for
    // users scrolled up reading history.  If the message isn't in the current
    // mounted window (outside the paginated view) we no-op; its tick will be
    // correct the next time renderChatList renders it from WB.RECEIPTS.
    const scroll = document.getElementById('chat-scroll');
    if (!scroll) return;
    const row = scroll.querySelector('.msg[data-seq="' + seq + '"]');
    if (!row) return;
    const tsRow = row.querySelector('.ts');
    if (!tsRow) return;
    tsRow.querySelectorAll('.tick, .seen-by').forEach((n) => n.remove());
    const m = WB.CHAT.find((c) => c.seq === seq);
    if (!m) return;
    const glyph = receiptGlyph(m);
    if (glyph) tsRow.appendChild(glyph);
    const roomSummary = roomReceiptSummary(m);
    if (roomSummary) tsRow.appendChild(roomSummary);
  });
  WB.sim.on('chat', (m) => {
    const scroll = document.getElementById('chat-scroll');
    if (scroll && chatMatches(m)) {
      const pinned = scroll.scrollTop + scroll.clientHeight >= scroll.scrollHeight - 60;
      const node = msgNode(m);
      const isOwn = m.who === 'you (operator)';
      scroll.appendChild(node);
      if (!isOwn) {
        const bubble = node.querySelector('.bubble-text');
        if (bubble) {
          const full = bubble.textContent;
          revealText(bubble, full);
        }
      }
      if (pinned) scroll.scrollTop = scroll.scrollHeight;
    }
    const feed = document.getElementById('focus-feed');
    if (feed && WB.state.focus) {
      const a = agent(WB.state.focus);
      if (a && a.id === feed.getAttribute('data-agent') && dmMatches(a, m)) {
        const pinned = feed.scrollTop + feed.clientHeight >= feed.scrollHeight - 48;
        feed.appendChild(chatTermLine(m));
        if (pinned) feed.scrollTop = feed.scrollHeight;
      }
    }
  });
  WB.sim.on('decision', () => {
    const rail = document.getElementById('foryou');
    if (rail) WB.renderForYou(rail, { footNote: 'Decisions queue here without blocking the loop — the lead moves on to unblocked work and checks back.' });
  });
  WB.sim.on('heartbeat', (a) => {
    renderTypingLine();
    const st = document.querySelector('.station[data-agent="' + a.id + '"]');
    if (st) {
      const tc = st.querySelector('.st-tool');
      if (tc) tc.replaceWith(toolChip(a, WB.eff.heat(a)));
    }
  });
  WB.sim.on('tick', (t) => { if (t % 3 === 0) renderTypingLine(); });
})(window.WB);
