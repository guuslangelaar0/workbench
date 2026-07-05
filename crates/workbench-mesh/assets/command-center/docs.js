// Docs surface — what Workbench is/isn't, how it works, this project's
// current settings, the maturity ladder with non-destructive previews, the
// dial preset table, the C4 view, task-oriented guides, an FAQ, and the
// full command reference. One long scroll; the sidebar just anchors into it.
window.WB = window.WB || {};
(function (WB) {
  const { el, chip, empty, commandRow } = WB.ui;
  let previewTarget = null; // level id or null
  let c4Tab = 'l2';

  const ARCH_DEPTH = { solo: 0, pair: 1, crew: 2, fleet: 3 }; // none/context/containers/components
  const UNLOCKS = {
    solo: ['flat tasks', 'push-to-main'],
    pair: ['in-review lane', 'epics', 'context map'],
    crew: ['staged + shipped', 'CI gates', 'evolve summit'],
    fleet: ['release trains', 'federated repos', 'components (C4 L3)'],
  };

  // Nav is grouped so task-oriented titles ("Setting up mesh") show up as
  // their own line in the sidebar, not buried inside a generic "Guides".
  const NAV = [
    { label: 'Guide', items: [
      { id: 'overview', label: 'Overview', icon: 'book' },
      { id: 'how-it-works', label: 'How it works', icon: 'zap' },
      { id: 'this-project', label: 'This project', icon: 'server' },
    ] },
    { label: 'Growth', items: [
      { id: 'maturity', label: 'Maturity ladder', icon: 'trend' },
      { id: 'dials', label: 'Dials', icon: 'sliders' },
      { id: 'architecture', label: 'Architecture', icon: 'layers' },
    ] },
    { label: 'How-to', items: [
      { id: 'setup-mesh', label: 'Setting up mesh', icon: 'radio' },
      { id: 'invite-device', label: 'Inviting a device', icon: 'mail' },
      { id: 'orphaned-host', label: 'Recovering an orphaned host', icon: 'alert' },
      { id: 'change-level', label: 'Changing your level', icon: 'trend' },
    ] },
    { label: 'Reference', items: [
      { id: 'commands', label: 'Commands', icon: 'terminal' },
      { id: 'faq', label: 'FAQ', icon: 'help-circle' },
    ] },
  ];
  const FLAT_IDS = NAV.flatMap((g) => g.items.map((i) => i.id));

  /* ── overview ── */
  function overviewSection() {
    const linkRow = el('div', { style: 'display:flex; gap:8px;' }, [
      el('a', {
        class: 'btn', href: WB.REPO_URL || '#', target: '_blank', rel: 'noopener',
        html: svgIcon('external-link', 12) + ' GitHub',
        onclick: (e) => { if (!WB.REPO_URL) { e.preventDefault(); WB.ui.toast('Add your repo URL here — placeholder link'); } },
      }),
    ]);
    const lists = el('div', { class: 'whatis-cols' }, [
      el('div', { class: 'whatis-col' }, [
        el('h4', { html: svgIcon('check', 11) + ' What it is' }),
        el('ul', {}, WB.WHAT_IS.map((t) => el('li', { text: t }))),
      ]),
      el('div', { class: 'whatis-col' }, [
        el('h4', { html: svgIcon('x', 11) + ' What it isn’t' }),
        el('ul', {}, WB.WHAT_IS_NOT.map((t) => el('li', { text: t }))),
      ]),
    ]);
    return el('section', { class: 'doc-section', id: 'overview' }, [
      el('div', { class: 't-eyebrow', text: 'Docs' }),
      el('h1', { text: 'Workbench' }),
      el('p', { class: 'doc-lede', text: 'A Claude Code plugin that turns a repo into a place multiple Claude and Codex sessions coordinate as a team — a CLI-first orchestration layer, not a hosted product. This dashboard is a read on the same event log the CLI writes.' }),
      linkRow,
      lists,
    ]);
  }

  /* ── how it works ── */
  function howItWorksSection() {
    const steps = WB.HOW_IT_WORKS.map((s, i) => el('div', { class: 'flow-step' }, [
      el('div', { class: 'flow-num', text: String(i + 1) }),
      el('div', { class: 'flow-body' }, [
        el('div', { class: 'flow-t', text: s.t }),
        el('div', { class: 'flow-d', text: s.d }),
      ]),
    ]));
    return el('section', { class: 'doc-section', id: 'how-it-works' }, [
      el('h2', { text: 'How it works' }),
      el('p', { class: 'doc-lede', text: 'The dashboard is a window, not the engine. Every state change starts in a real session running a real command.' }),
      el('div', { class: 'flow-list' }, steps),
    ]);
  }

  /* ── this project (current settings snapshot) ── */
  function thisProjectSection(current, jump) {
    const L = WB.LEVELS[current];
    const idx = WB.LEVEL_ORDER.indexOf(current);
    const callouts = [
      { k: 'in_review_cap', v: WB.DIALS.find((d) => d.name === 'in_review_cap').vals[idx] },
      { k: 'verification', v: WB.DIALS.find((d) => d.name === 'verification').vals[idx] },
      { k: 'architecture', v: WB.DIALS.find((d) => d.name === 'architecture').vals[idx] },
      { k: 'evolve', v: WB.DIALS.find((d) => d.name === 'evolve').vals[idx] },
    ];
    return el('section', { class: 'doc-section', id: 'this-project' }, [
      el('div', { class: 't-eyebrow', text: 'Live from .workbench/config.json' }),
      el('h2', { text: 'This project, today' }),
      el('div', { class: 'proj-snap' }, [
        el('div', { class: 'proj-row' }, [
          chip(L.label, 'amber'),
          el('span', { text: L.blurb }),
        ]),
        el('div', { class: 'proj-callouts' }, callouts.map((c) => el('div', { class: 'proj-callout' }, [
          el('span', { class: 't-mono', style: 'color:var(--ink-4); font-size:9.5px; text-transform:uppercase; letter-spacing:0.06em;', text: c.k }),
          el('span', { class: 't-mono', style: 'color:var(--ink); font-size:13px;', text: c.v }),
        ]))),
        el('div', { class: 'proj-row' }, [
          el('span', { class: 't-mono', style: 'color:var(--ink-4); font-size:11px;', text: 'host mode' }),
          chip(WB.HOST.mode + ' · ' + WB.HOST.lanIp + ':' + WB.HOST.port, 'ghost'),
        ]),
      ]),
      el('div', { style: 'display:flex; gap:14px;' }, [
        el('a', { href: '#maturity', class: 'doc-jump', text: 'Explore other levels →', onclick: (e) => { e.preventDefault(); jump('maturity'); } }),
        el('a', { href: '#dials', class: 'doc-jump', text: 'See all dials →', onclick: (e) => { e.preventDefault(); jump('dials'); } }),
      ]),
    ]);
  }

  /* ── maturity ladder ── */
  function rungs(current, rerender) {
    return el('div', { class: 'rungs' }, WB.LEVEL_ORDER.map((id, idx) => {
      const L = WB.LEVELS[id];
      const isCur = id === current;
      const isPrev = id === previewTarget;
      const badge = isCur ? chip('current', 'amber') : (isPrev ? chip('previewing', 'ghost') : null);
      if (badge && isPrev) badge.style.background = 'var(--paper)'; // opaque — sits over the rung's own border, doesn't let it show through
      const activate = () => { previewTarget = isCur ? null : id; rerender(); };
      return el('div', {
        class: 'rung' + (isCur ? ' current' : '') + (isPrev ? ' previewing' : ''),
        tabindex: '0',
        role: 'button',
        onclick: activate,
        onkeydown: (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); activate(); } },
      }, [
        badge,
        el('div', { class: 'rung-steps' }, [0, 1, 2, 3].map((i) => el('i', { class: i <= idx ? 'on' : '' }))),
        el('div', { class: 'rung-name', text: L.label }),
        el('div', { class: 'rung-desc', text: L.blurb }),
        el('div', { class: 'rung-unlocks' }, UNLOCKS[id].map((u) => chip(u, 'ghost'))),
      ]);
    }));
  }

  function previewPanel(current, rerender) {
    const cur = WB.LEVELS[current];
    const tgt = WB.LEVELS[previewTarget];
    const curIdx = WB.LEVEL_ORDER.indexOf(current);
    const tgtIdx = WB.LEVEL_ORDER.indexOf(previewTarget);

    const dialRows = WB.DIALS.map((d) => {
      const from = d.vals[curIdx];
      const to = d.vals[tgtIdx];
      return el('div', { class: 'diff-row' + (from !== to ? ' changed' : '') }, [
        el('span', { class: 'd-name', text: d.name }),
        el('span', { class: 'd-from', text: from }),
        el('span', { html: svgIcon('arrow-right', 10), style: 'color: var(--ink-4); display:flex;' }),
        el('span', { class: 'd-to', text: to }),
      ]);
    });

    const added = tgt.dirs.filter((x) => !cur.dirs.includes(x));
    const removed = cur.dirs.filter((x) => !tgt.dirs.includes(x));
    const fsLines = [
      ...added.map((x) => el('div', { class: 'fs-line add', text: '+ ' + x })),
      ...removed.map((x) => el('div', { class: 'fs-line del', text: '− ' + x + '  (kept on disk, retired from the lifecycle)' })),
    ];
    if (!fsLines.length) fsLines.push(el('div', { class: 'fs-line', text: 'no filesystem changes' }));

    const stAdd = tgt.structure.filter((x) => !cur.structure.includes(x));
    const stDel = cur.structure.filter((x) => !tgt.structure.includes(x));
    const stLines = [
      ...stAdd.map((x) => el('div', { class: 'fs-line add', text: '+ ' + x })),
      ...stDel.map((x) => el('div', { class: 'fs-line del', text: '− ' + x })),
    ];
    if (!stLines.length) stLines.push(el('div', { class: 'fs-line', text: 'no structural changes' }));

    return el('section', { class: 'panel' }, [
      el('div', { class: 'panel-head' }, [
        el('h2', { html: svgIcon('trend', 14) + ' Preview: ' + cur.label + ' → ' + tgt.label }),
        el('div', { class: 'spacer' }),
        chip('recommend-only', 'ghost'),
      ]),
      el('div', { class: 'panel-body' }, [
        el('div', { class: 'preview-cols' }, [
          el('div', {}, [el('h4', { text: 'Dial changes' }), ...dialRows]),
          el('div', {}, [el('h4', { text: 'Filesystem' }), ...fsLines]),
          el('div', {}, [el('h4', { text: 'Repos & process' }), ...stLines]),
        ]),
        el('div', { class: 'preview-foot' }, [
          el('span', { class: 'note', text: 'Nothing applies from the dashboard — the real confirm/cancel lives in the session that runs it.' }),
          el('div', { class: 'btns' }, [
            el('button', { class: 'btn quiet', text: 'Dismiss', onclick: () => { previewTarget = null; rerender(); } }),
          ]),
        ]),
        el('div', { style: 'margin-top: 10px;' }, [commandRow('/workbench:level ' + previewTarget)]),
      ]),
    ]);
  }

  function maturitySection(current, rerender) {
    return el('section', { class: 'doc-section', id: 'maturity' }, [
      el('h2', { text: 'Maturity ladder' }),
      el('p', { class: 'doc-lede', text: 'A coordination surface, not a ranking of quality — how much ceremony this project needs to stay coherent as it grows. Click a rung to preview the exact diff; the board keeps showing today’s real level either way.' }),
      rungs(current, rerender),
      previewTarget ? previewPanel(current, rerender)
        : el('div', { style: 'font-size: 11.5px; color: var(--ink-4);', text: 'You’re at ' + WB.LEVELS[current].label + '. Previews here are read-only.' }),
    ]);
  }

  /* ── dials ── */
  function dialsSection(current) {
    const curIdx = WB.LEVEL_ORDER.indexOf(current);
    const table = el('table', { class: 'wb dials' });
    table.appendChild(el('tr', {}, [
      el('th', { text: 'Dial' }),
      ...WB.LEVEL_ORDER.map((id, i) => el('th', { class: i === curIdx ? 'cur' : '', text: WB.LEVELS[id].label })),
    ]));
    for (const d of WB.DIALS) {
      table.appendChild(el('tr', {}, [
        el('td', { text: d.name }),
        ...d.vals.map((v, i) => el('td', { class: i === curIdx ? 'cur' : '', text: v })),
      ]));
    }
    return el('section', { class: 'doc-section', id: 'dials' }, [
      el('h2', { text: 'Dials' }),
      el('p', { class: 'doc-lede', text: '7 dials × 4 presets. A single dial can differ from the preset without leaving it — dial_overrides in .workbench/config.json. This project runs the preset clean: no overrides.' }),
      el('section', { class: 'panel' }, [
        el('div', { class: 'panel-body', style: 'padding: 4px 6px 6px;' }, [table]),
        el('div', { class: 'panel-body', style: 'padding-top: 10px; border-top: 1px solid var(--line); font-size: 11px; color: var(--ink-3); line-height: 1.55;' }, [
          el('span', { html: '<b style="color:var(--ink-2);">Board note:</b> the lifecycle dial above is the real per-project column set the CLI writes to disk. This dashboard’s Board always renders the full backlog → shipped pipeline regardless of level, for legibility — a disclosed simplification, not a second source of truth.' }),
        ]),
      ]),
    ]);
  }

  /* ── architecture (C4) ── */
  function c4Panel(current, rerender) {
    const depth = ARCH_DEPTH[current];
    if (depth === 0) {
      return el('section', { class: 'panel' }, [
        el('div', { class: 'panel-head' }, [el('h2', { html: svgIcon('layers', 14) + ' Architecture (C4)' })]),
        el('div', { class: 'panel-body' }, [
          empty('layers', 'The architecture dial is off at Solo.', 'context unlocks at Pair · containers at Crew · components at Fleet'),
        ]),
      ]);
    }
    const tabs = [
      { id: 'l1', label: 'L1 · Context', need: 1 },
      { id: 'l2', label: 'L2 · Containers', need: 2 },
      { id: 'l3', label: 'L3 · Components', need: 3 },
    ];
    if (ARCH_DEPTH[current] < 2 && c4Tab === 'l2') c4Tab = 'l1';
    if (ARCH_DEPTH[current] < 3 && c4Tab === 'l3') c4Tab = ARCH_DEPTH[current] >= 2 ? 'l2' : 'l1';
    const tabRow = el('div', { class: 'c4-tabs' }, tabs.map((t) => {
      const locked = depth < t.need;
      return el('button', {
        class: 'c4-tab' + (c4Tab === t.id ? ' on' : '') + (locked ? ' locked' : ''),
        html: (locked ? svgIcon('lock', 11) + ' ' : '') + t.label + (locked ? ' <span class="t-mono" style="font-size:9px;">unlocks at ' + WB.LEVELS[WB.LEVEL_ORDER[t.need]].label + '</span>' : ''),
        onclick: () => { if (!locked) { c4Tab = t.id; rerender(); } },
      });
    }));

    let list;
    if (c4Tab === 'l1') {
      list = WB.C4.l1.map((x) => el('div', { class: 'c4-item' }, [
        el('span', { class: 'c4-name', text: x.name }),
        el('span', { class: 'c4-desc', text: x.desc }),
      ]));
    } else {
      const items = c4Tab === 'l3' ? WB.C4.l3 : WB.C4.l2;
      list = items.map((x) => el('div', { class: 'c4-item' }, [
        el('span', { class: 'c4-name', text: x.name }),
        el('span', { class: 'c4-desc' }, [
          el('span', { text: x.desc + ' ' }),
          x.planned ? chip('planned', 'ghost') : null,
        ]),
      ]));
    }

    const body = el('div', { class: 'panel-body' }, [tabRow, ...list]);
    if (c4Tab !== 'l1') {
      body.appendChild(el('div', { class: 'drift', html: svgIcon('alert', 13) + ' <span>' + WB.ui.esc(WB.C4.drift) + '</span>' }));
      body.appendChild(el('div', { style: 'margin-top: 10px;' }, [commandRow('/workbench:architecture drift')]));
    }
    return el('section', { class: 'panel' }, [
      el('div', { class: 'panel-head' }, [
        el('h2', { html: svgIcon('layers', 14) + ' Architecture (C4)' }),
        el('div', { class: 'spacer' }),
        el('span', { class: 't-mono', style: 'font-size:10px; color: var(--ink-4);', text: 'authored: .claude/architecture/*.md · reality: graphify' }),
      ]),
      body,
    ]);
  }
  function architectureSection(current, rerender) {
    return el('section', { class: 'doc-section', id: 'architecture' }, [
      el('h2', { text: 'Architecture' }),
      el('p', { class: 'doc-lede', text: 'The C4-style context backbone, scaled by the architecture dial. Drift compares authored intent against graphify’s extracted reality.' }),
      c4Panel(current, rerender),
    ]);
  }

  /* ── how-to guides ── */
  function guideSection(g) {
    const stepRows = g.steps.map((s) => el('div', { style: 'display:flex; flex-direction:column; gap:6px;' }, [
      commandRow(s.cmd),
      el('div', { class: 'guide-note', text: s.note }),
    ]));
    return el('section', { class: 'doc-section', id: g.id }, [
      el('h2', { text: g.title }),
      el('p', { class: 'doc-lede', text: g.body }),
      el('section', { class: 'panel' }, [
        el('div', { class: 'panel-body guide-steps' }, stepRows),
      ]),
    ]);
  }

  /* ── FAQ ── */
  function faqSection() {
    return el('section', { class: 'doc-section', id: 'faq' }, [
      el('h2', { text: 'FAQ' }),
      el('p', { class: 'doc-lede', text: 'The questions that come up once real teams start using the mesh.' }),
      el('div', { class: 'faq-list' }, WB.FAQ.map((f) => el('details', { class: 'faq-item' }, [
        el('summary', { class: 'faq-q' }, [
          el('span', { text: f.q }),
          el('span', { class: 'faq-chev', html: svgIcon('arrow-right', 12) }),
        ]),
        el('div', { class: 'faq-a', text: f.a }),
      ]))),
    ]);
  }

  /* ── commands ── */
  function copyCmd(cmd) {
    return () => WB.ui.toast('Copied', cmd);
  }
  function commandsSection() {
    return el('section', { class: 'doc-section', id: 'commands' }, [
      el('h2', { text: 'Commands' }),
      el('p', { class: 'doc-lede', text: 'Every /workbench:* command, grouped by concern. Click a row to copy it.' }),
      el('div', { class: 'cmd-groups' }, WB.COMMAND_GROUPS.map((g) => el('section', { class: 'panel cmd-group' }, [
        el('div', { class: 'panel-head' }, [el('h2', { text: g.group })]),
        el('div', { class: 'panel-body', style: 'padding: 4px 6px 6px;' }, g.items.map((it) => el('div', {
          class: 'cmd-item',
          tabindex: '0',
          role: 'button',
          onclick: copyCmd(it.cmd),
          onkeydown: (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); copyCmd(it.cmd)(); } },
        }, [
          el('span', { class: 'cmd-name', text: it.cmd }),
          el('span', { class: 'cmd-desc', text: it.desc }),
          el('span', { class: 'cmd-copy', html: svgIcon('copy', 11) }),
        ]))),
      ]))),
    ]);
  }

  /* ── surface ── */
  WB.surfaces = WB.surfaces || {};
  WB.surfaces.docs = {
    render(container) {
      const rerender = () => WB.surfaces.docs.render(container);
      container.replaceChildren();
      const current = WB.state.level;
      let scrollEl;
      let observer;
      function jump(id) {
        const target = scrollEl.querySelector('#' + id);
        if (target) scrollEl.scrollTop = target.offsetTop - 14;
      }
      const navLinks = {};
      const nav = el('nav', { class: 'docs-nav' }, NAV.map((g) => el('div', { class: 'docs-nav-group' }, [
        el('div', { class: 'docs-nav-label', text: g.label }),
        ...g.items.map((s) => {
          const a = el('a', {
            href: '#' + s.id, class: 'docs-nav-item', html: svgIcon(s.icon, 13) + ' <span>' + s.label + '</span>',
            onclick: (e) => { e.preventDefault(); jump(s.id); },
          });
          navLinks[s.id] = a;
          return a;
        }),
      ])));
      const content = el('div', { class: 'docs-content' }, [
        overviewSection(),
        howItWorksSection(),
        thisProjectSection(current, jump),
        maturitySection(current, rerender),
        dialsSection(current),
        architectureSection(current, rerender),
        ...WB.GUIDES.map(guideSection),
        commandsSection(),
        faqSection(),
      ]);
      scrollEl = content;
      container.appendChild(el('div', { class: 'docs-wrap', 'data-screen-label': 'Docs' }, [nav, content]));

      // Active-section highlight — tracks scroll (manual or jumped) via IO.
      requestAnimationFrame(() => {
        observer = new IntersectionObserver((entries) => {
          for (const entry of entries) {
            const link = navLinks[entry.target.id];
            if (link) link.classList.toggle('active', entry.isIntersecting);
          }
        }, { root: scrollEl, rootMargin: '-8% 0px -75% 0px', threshold: 0 });
        for (const id of FLAT_IDS) {
          const el2 = content.querySelector('#' + id);
          if (el2) observer.observe(el2);
        }
      });
    },
  };
})(window.WB);
