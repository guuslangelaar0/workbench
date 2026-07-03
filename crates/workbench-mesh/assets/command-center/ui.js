// Workbench Mesh — DOM helpers + shared components (vanilla, canonical DOM).
window.WB = window.WB || {};
(function (WB) {
  function el(tag, attrs, children) {
    const n = document.createElement(tag);
    if (attrs) {
      for (const [k, v] of Object.entries(attrs)) {
        if (v == null) continue;
        if (k === 'class') n.className = v;
        else if (k === 'text') n.textContent = v;
        else if (k === 'html') n.innerHTML = v;
        else if (k.startsWith('on')) n.addEventListener(k.slice(2), v);
        else n.setAttribute(k, v);
      }
    }
    if (children) for (const c of children) { if (c) n.appendChild(c); }
    return n;
  }

  function chip(text, variant, icon) {
    return el('span', { class: 'chip' + (variant ? ' ' + variant : ''), html: (icon ? svgIcon(icon, 10) : '') + esc(text) });
  }
  function pulse(heat) { return el('span', { class: 'pulse ' + heat }); }
  function esc(s) {
    return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  }

  function empty(icon, text, hint) {
    return el('div', { class: 'empty' }, [
      el('span', { html: svgIcon(icon, 20) }),
      el('p', { text: text }),
      hint ? el('span', { class: 'hint', text: hint }) : null,
    ]);
  }

  function clock(ts) {
    const d = new Date(ts);
    const p = (n) => String(n).padStart(2, '0');
    return p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
  }
  function rel(ms) {
    const s = Math.max(0, Math.round(ms / 1000));
    if (s < 60) return s + 's';
    const m = Math.round(s / 60);
    if (m < 60) return m + 'm';
    const h = Math.round(m / 60);
    if (h < 48) return h + 'h';
    return Math.round(h / 24) + 'd';
  }
  function dur(ms) {
    const m = Math.floor(ms / 60000);
    const h = Math.floor(m / 60);
    return h > 0 ? h + 'h' + String(m % 60).padStart(2, '0') + 'm' : m + 'm';
  }

  // Confirm modal — always names its target (revocation is one-way).
  function confirm({ title, body, target, confirmLabel, danger, note, onConfirm }) {
    const root = document.getElementById('overlay-root');
    const veil = el('div', { class: 'modal-veil', onclick: (e) => { if (e.target === veil) close(); } });
    function close() { veil.remove(); }
    const modal = el('div', { class: 'modal' }, [
      el('h3', { html: svgIcon(danger ? 'alert' : 'check-circle', 15) + ' ' + esc(title) }),
      el('p', { text: body }),
      target ? el('div', { class: 'modal-target', text: target }) : null,
      note ? el('p', { class: 'modal-note', text: note }) : null,
      el('div', { class: 'modal-actions' }, [
        el('button', { class: 'btn quiet', text: 'Cancel', onclick: close }),
        el('button', {
          class: 'btn ' + (danger ? 'danger' : 'primary'), text: confirmLabel,
          onclick: () => { close(); onConfirm && onConfirm(); },
        }),
      ]),
    ]);
    veil.appendChild(modal);
    root.appendChild(veil);
  }

  let rack = null;
  function toast(text, mono) {
    if (!rack || !rack.isConnected) {
      rack = el('div', { class: 'toast-rack' });
      document.getElementById('overlay-root').appendChild(rack);
    }
    const t = el('div', { class: 'toast' }, [
      el('span', { html: svgIcon('check', 13) }),
      el('span', { text: text }),
      mono ? el('span', { class: 't-mono', text: mono }) : null,
    ]);
    rack.appendChild(t);
    setTimeout(() => { t.classList.add('leaving'); setTimeout(() => t.remove(), 320); }, 3400);
  }

  // Command chip — the exact CLI command, copyable, and sendable to the
  // host session (the main lead) when it is alive to run it.
  function commandRow(cmd) {
    const live = WB.state.hostState === 'healthy';
    return el('div', { class: 'cmd-row' }, [
      el('code', {}, [el('span', { class: 'dollar', text: '$ ' }), document.createTextNode(cmd)]),
      el('button', { class: 'btn quiet', style: 'flex-shrink:0; font-size:11px;', html: svgIcon('copy', 11), title: 'Copy command', onclick: () => toast('Command copied', cmd) }),
      el('button', {
        class: 'btn primary', style: 'flex-shrink:0; font-size:11px;',
        html: svgIcon('send', 11) + ' Send to ' + WB.HOST.startedBy,
        title: live ? 'Posts the command into the host session — it runs there, not here' : 'Host session is gone — nobody is home to run it',
        disabled: live ? null : 'disabled',
        onclick: () => {
          const m = { room: 'repo:workbench', who: 'you (operator)', kind: 'command', to: WB.HOST.startedBy, text: cmd, ts: Date.now() };
          WB.CHAT.push(m);
          if (WB.api) WB.api.sendChat({ room: m.room, kind: 'msg', text: cmd, to: m.to });
          toast('Sent to ' + WB.HOST.startedBy + ' — runs in the host session', cmd);
        },
      }),
    ]);
  }

  // Consistent per-lead color — hashed from the actor id so it's stable
  // across reloads and shared across every surface (stations, chat, board,
  // ops). Hue-only identity; pulse colors still carry liveness semantics.
  const LEAD_HUES = 6;
  function leadColor(id) {
    if (!id) return null;
    let h = 0;
    for (let i = 0; i < id.length; i++) h = (h * 31 + id.charCodeAt(i)) >>> 0;
    return 'var(--lead-' + ((h % LEAD_HUES) + 1) + ')';
  }
  function leadName(id, extraStyle) {
    const c = leadColor(id);
    return el('span', { style: (c ? 'color:' + c + ';' : '') + (extraStyle || ''), text: id });
  }

  WB.ui = { el, chip, pulse, esc, empty, clock, rel, dur, confirm, toast, commandRow, leadColor, leadName };
})(window.WB);
