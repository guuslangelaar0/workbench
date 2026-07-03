// Board surface — one fixed lifecycle for every maturity level, visible
// swim lanes, and pointer-based drag & drop with a quick, real drop feel.
// Decisions stay a parallel, non-blocking rail.
window.WB = window.WB || {};
(function (WB) {
  const { el, chip, pulse, empty, leadName } = WB.ui;

  const COLS = ['backlog', 'in-development', 'in-review', 'verified', 'staged', 'shipped'];
  const COL_LABEL = {
    'backlog': 'Backlog', 'in-development': 'In development', 'in-review': 'In review',
    'verified': 'Verified', 'staged': 'Staged', 'shipped': 'Shipped',
  };
  const EMPTY_HINTS = {
    'staged': ['Nothing staged.', 'verified work waits here for the next release'],
    'shipped': ['Nothing shipped yet.', ''],
    'in-review': ['Review queue is clear.', ''],
    'backlog': ['Backlog is empty.', 'park ideas with /workbench:task'],
    'in-development': ['Nothing in flight.', ''],
    'verified': ['Nothing verified yet.', ''],
  };
  let droppedId = null;

  function boardCol(t) { return COLS.includes(t.col) ? t.col : 'verified'; }

  function card(t) {
    const a = t.agent ? WB.AGENTS.find((x) => x.id === t.agent) : null;
    const chips = el('div', { class: 'chips' }, [
      chip(t.track, 'ghost'),
      t.epic ? chip(t.epic) : null,
      t.blockedBy ? chip('blocked-by ' + t.blockedBy, 'rust') : null,
    ]);
    if (a) chips.appendChild(el('span', { class: 'who' }, [pulse(WB.eff.heat(a)), leadName(a.id)]));
    else if (t.who) chips.appendChild(el('span', { class: 'who', text: t.who }));
    const c = el('div', { class: 'tcard' + (droppedId === t.id ? ' dropped' : ''), 'data-task': t.id }, [
      el('div', { class: 'id', text: String(t.id) }),
      el('div', { class: 'title', text: t.title }),
      chips,
    ]);
    if (droppedId === t.id) droppedId = null;
    makeDraggable(c, t);
    return c;
  }

  /* ── drag & drop: lift, aim, drop, settle — quick, no ceremony ── */
  function makeDraggable(cardEl, task) {
    cardEl.addEventListener('pointerdown', (e) => {
      if (e.button !== 0) return;
      const startX = e.clientX, startY = e.clientY;
      const rect = cardEl.getBoundingClientRect();
      let clone = null, slot = null, hotCol = null;

      const move = (ev) => {
        if (!clone) {
          if (Math.hypot(ev.clientX - startX, ev.clientY - startY) < 6) return;
          clone = cardEl.cloneNode(true);
          clone.classList.add('drag-clone');
          clone.style.width = rect.width + 'px';
          clone.style.left = rect.left + 'px';
          clone.style.top = rect.top + 'px';
          document.body.appendChild(clone);
          cardEl.classList.add('drag-src');
          slot = el('div', { class: 'drop-slot' });
          slot.style.height = rect.height + 'px';
        }
        clone.style.transform = 'translate(' + (ev.clientX - startX) + 'px,' + (ev.clientY - startY) + 'px) rotate(1.2deg) scale(1.03)';
        const under = document.elementFromPoint(ev.clientX, ev.clientY);
        const colEl = under && under.closest ? under.closest('.col') : null;
        document.querySelectorAll('.col').forEach((c) => c.classList.toggle('drop-hot', c === colEl));
        if (colEl) {
          hotCol = colEl;
          const scroll = colEl.querySelector('.col-scroll');
          const cards = [...scroll.querySelectorAll('.tcard:not(.drag-src)')];
          let before = null;
          for (const c of cards) {
            const r = c.getBoundingClientRect();
            if (ev.clientY < r.top + r.height / 2) { before = c; break; }
          }
          if (before) scroll.insertBefore(slot, before);
          else scroll.appendChild(slot);
        } else {
          if (slot && slot.parentNode) slot.remove();
          hotCol = null;
        }
      };

      const up = () => {
        window.removeEventListener('pointermove', move);
        window.removeEventListener('pointerup', up);
        document.querySelectorAll('.col.drop-hot').forEach((c) => c.classList.remove('drop-hot'));
        if (!clone) return;
        if (hotCol && slot.parentNode) {
          const colKey = hotCol.getAttribute('data-col');
          const fromCol = task.col;
          // order: reinsert relative to the card after the slot
          const nextCard = slot.nextElementSibling && slot.nextElementSibling.classList.contains('tcard')
            ? Number(slot.nextElementSibling.getAttribute('data-task')) : null;
          WB.TASKS.splice(WB.TASKS.indexOf(task), 1);
          task.col = colKey;
          const idx = nextCard != null ? WB.TASKS.findIndex((t) => t.id === nextCard) : -1;
          if (idx >= 0) WB.TASKS.splice(idx, 0, task); else WB.TASKS.push(task);
          if (fromCol !== colKey && WB.api) WB.api.taskTransition(task.id, colKey);
          // animate the clone into the slot, then settle
          const sr = slot.getBoundingClientRect();
          clone.style.transition = 'transform 140ms cubic-bezier(0.2, 0.8, 0.2, 1)';
          clone.style.transform = 'translate(' + (sr.left - rect.left) + 'px,' + (sr.top - rect.top) + 'px) rotate(0deg) scale(1)';
          droppedId = task.id;
          setTimeout(() => {
            clone.remove();
            WB.app.rerenderSurface();
          }, 145);
        } else {
          clone.style.transition = 'transform 150ms var(--ease)';
          clone.style.transform = 'translate(0,0) rotate(0deg) scale(1)';
          setTimeout(() => {
            clone.remove();
            cardEl.classList.remove('drag-src');
            if (slot && slot.parentNode) slot.remove();
          }, 160);
        }
      };

      window.addEventListener('pointermove', move);
      window.addEventListener('pointerup', up);
    });
  }

  WB.surfaces = WB.surfaces || {};
  WB.surfaces.board = {
    render(container) {
      container.replaceChildren();
      const inReview = WB.TASKS.filter((t) => boardCol(t) === 'in-review').length;

      const head = el('div', { class: 'board-head' }, [
        el('div', { class: 'lvl-fact' }, [
          el('span', { class: 't-eyebrow', text: 'Lifecycle' }),
        ]),
        el('span', { class: 'head-note', text: 'drag a card between lanes — the transition posts to the room' }),
        el('div', { class: 'cap-meter' }, [
          el('span', { text: 'in-review ' + inReview + '/' + WB.IN_REVIEW_CAP }),
          el('span', { class: 'bar' }, [el('i', { style: 'width:' + Math.round((inReview / WB.IN_REVIEW_CAP) * 100) + '%' })]),
          el('span', { text: 'hard-drain at ' + (WB.IN_REVIEW_CAP - 3) }),
        ]),
      ]);

      const cols = el('div', { class: 'board-cols' }, COLS.map((c) => {
        const tasks = WB.TASKS.filter((t) => boardCol(t) === c);
        const scroll = el('div', { class: 'col-scroll' });
        if (tasks.length === 0) {
          const [txt, hint] = EMPTY_HINTS[c] || ['Empty.', ''];
          scroll.appendChild(empty('folder', txt, hint || null));
        } else {
          for (const t of tasks) scroll.appendChild(card(t));
        }
        return el('div', { class: 'col', 'data-col': c }, [
          el('div', { class: 'col-head' }, [
            el('span', { class: 't-eyebrow', text: COL_LABEL[c] }),
            el('span', { class: 'cnt', text: String(tasks.length) }),
          ]),
          scroll,
        ]);
      }));

      const drail = el('aside', { class: 'drail', id: 'drail' });
      drail.appendChild(el('div', { class: 't-eyebrow', text: 'Decisions' }));
      drail.appendChild(el('div', { class: 'drail-exp', text: 'Parallel and non-blocking — not a pipeline stage. The loop moves on and checks back here.' }));
      const cards = el('div', { id: 'drail-cards', style: 'display:flex; flex-direction:column; gap:10px;' });
      WB.renderForYou(cards, { noLabel: true, decisionsOnly: true });
      drail.appendChild(cards);

      container.appendChild(el('div', { class: 'board-wrap', 'data-screen-label': 'Board' }, [
        el('div', { class: 'board-main' }, [head, cols]),
        drail,
      ]));
    },
  };

  WB.sim.on('decision', () => {
    const cards = document.getElementById('drail-cards');
    if (cards) WB.renderForYou(cards, { noLabel: true, decisionsOnly: true });
  });
})(window.WB);
