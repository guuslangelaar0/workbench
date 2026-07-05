#!/usr/bin/env node
"use strict";

// Static harness for the redesigned command center bundle:
// 1. every module parses (vm.Script) — catches syntax errors before embed;
// 2. index.html loads the modules in dependency order (live before surfaces);
// 3. the live data layer exposes the real-API action surface;
// 4. every surface action is wired to WB.api (not the old sim);
// 5. destructive actions stay confirm-gated;
// 6. no simulated-demo data ships in the real bundle.

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const root = path.resolve(__dirname, "..");
const assetDir = path.join(root, "crates/workbench-mesh/assets");
const bundleDir = path.join(assetDir, "command-center");

let failures = 0;
function chk(label, ok, detail) {
  if (ok) {
    console.log("ok: " + label);
  } else {
    console.error("FAIL: " + label + (detail ? " — " + detail : ""));
    failures += 1;
  }
}

const html = fs.readFileSync(path.join(assetDir, "index.html"), "utf8");

const MODULES = [
  "icons.js",
  "data.js",
  "ui.js",
  "live.js",
  "bench.js",
  "board.js",
  "host.js",
  "ops.js",
  "docs.js",
  "app.js",
];

const sources = {};
for (const name of MODULES) {
  const source = fs.readFileSync(path.join(bundleDir, name), "utf8");
  sources[name] = source;
  try {
    new vm.Script(source, { filename: name });
    chk(name + " parses", true);
  } catch (error) {
    chk(name + " parses", false, error.message);
  }
}

// Load order: live.js must precede every surface, app.js must come last.
const scriptOrder = Array.from(
  html.matchAll(/command-center\/([\w.-]+\.js)/g)
).map((m) => m[1]);
chk(
  "index.html loads all bundle modules",
  MODULES.every((m) => scriptOrder.includes(m)),
  "loaded: " + scriptOrder.join(", ")
);
chk(
  "live.js loads before the surfaces",
  scriptOrder.indexOf("live.js") < scriptOrder.indexOf("bench.js"),
  scriptOrder.join(", ")
);
chk(
  "app.js loads last",
  scriptOrder[scriptOrder.length - 1] === "app.js",
  scriptOrder.join(", ")
);
chk("sim.js does not ship", !scriptOrder.includes("sim.js"));

// Real-API surface in the live data layer.
const live = sources["live.js"];
const apiMethods = [
  "sendChat",
  "resolveDecision",
  "reassignTask",
  "taskTransition",
  "stopJob",
  "retryJob",
  "adoptLead",
  "closeLead",
  "createInvite",
  "revokeInvite",
  "revokeDevice",
];
for (const method of apiMethods) {
  chk("live.js exposes WB.api." + method, live.includes(method + "("));
}
for (const endpoint of ["/api/state", "/api/events", "/api/invites", "/api/invites/revoke", "/api/devices/revoke", "/ws?token="]) {
  chk("live.js talks to " + endpoint, live.includes(endpoint));
}
chk("live.js opens a WebSocket", live.includes("new WebSocket"));
chk(
  "live.js posts real event types",
  ["message.sent", "message.request_status", "decision.answer", "task.reassigned", "task.status", "job.cancelled", "job.queued", "lead.adopted", "lead.closed"].every((t) => live.includes("'" + t + "'"))
);
chk("live.js projects output.chunk feeds", live.includes("output.chunk") && live.includes("output:"));
chk("live.js reads provider/model presence", live.includes("p.provider") && live.includes("p.model"));
chk("live.js never renders server.json wholesale", !live.includes("local_token"));

// Surfaces route their actions through WB.api.
const wiring = {
  "bench.js": ["WB.api.sendChat", "WB.api.resolveDecision", "WB.api.adoptLead", "task.handoff"],
  "board.js": ["WB.api.taskTransition"],
  "host.js": ["WB.api.createInvite", "WB.api.revokeInvite", "WB.api.revokeDevice"],
  "ops.js": ["WB.api.stopJob", "WB.api.retryJob", "WB.api.adoptLead", "WB.api.closeLead", "WB.api.reassignTask"],
};
for (const [file, needles] of Object.entries(wiring)) {
  for (const needle of needles) {
    chk(file + " wires " + needle, sources[file].includes(needle));
  }
}

// Destructive actions stay confirm-gated, and confirms name their target.
for (const file of ["host.js", "ops.js", "bench.js"]) {
  chk(file + " confirm-gates destructive actions", sources[file].includes("confirm({"));
  chk(file + " confirms name a target", sources[file].includes("target:"));
}

// XSS hygiene: server-derived host fields flowing into an html: sink must be
// escaped. The send button interpolates WB.HOST.startedBy (from the --as flag).
const ui = sources["ui.js"];
chk(
  "ui.js escapes startedBy in the send button html",
  ui.includes("esc(WB.HOST.startedBy)") && !/'\s*Send to\s*'\s*\+\s*WB\.HOST\.startedBy/.test(ui),
  "send button must interpolate esc(WB.HOST.startedBy), not the raw field"
);

// The real bundle must not carry the design prototype's demo scenario.
chk("data.js carries no demo agents", !sources["data.js"].includes("forge-lead"));
chk("data.js starts with empty roster", sources["data.js"].includes("WB.AGENTS = []"));

// Invite roles: worker/operator/observer — never the retired "viewer".
chk("host.js offers observer role", sources["host.js"].includes("'observer'"));
chk("no retired viewer role", !MODULES.some((m) => sources[m].includes("'viewer'")));

// Live-update fixes (Important/Minor Fix 7): the sender's own chat tick and
// the Host audit panel must both update in place from live WS events, not
// only on the next full re-render/tab-switch/local action.
const bench = sources["bench.js"];
chk(
  "bench.js backfills data-seq once sendChat's server ack resolves",
  /WB\.api\.sendChat\(m\)\.then\(\(\)\s*=>\s*\{\s*\n\s*if\s*\(node\s*&&\s*m\.seq\s*!=\s*null\)\s*\{\s*\n\s*node\.dataset\.seq\s*=\s*String\(m\.seq\);/.test(bench),
  "expected send() to keep the optimistic node reference and patch node.dataset.seq once WB.api.sendChat(m) resolves"
);
chk(
  "bench.js re-emits 'receipt' after the data-seq patch so the tick glyph actually paints",
  /node\.dataset\.seq = String\(m\.seq\);\s*\n\s*WB\.sim\.emit\('receipt', m\.seq\);/.test(bench),
  "sim.emit('receipt', seq) already fires inside live.js's sendChat().then() before data-seq is patched, so the handler's querySelector no-ops the first time — re-emitting after the patch is required to actually render the tick"
);
chk(
  "bench.js creates the optimistic message node before awaiting sendChat",
  /let node = null;\s*\n\s*if \(chatMatches\(m\)\) \{ node = msgNode\(m\);/.test(bench),
  "node must exist before the .then() closure captures it"
);
chk(
  "live.js emits audit-update when a new audit entry lands",
  /WB\.AUDIT\.unshift\(\{[^}]*\}\);\s*\n\s*if \(WB\.AUDIT\.length > 40\) WB\.AUDIT\.pop\(\);\s*\n\s*sim\.emit\('audit-update'\);/.test(live),
  "expected sim.emit('audit-update') right after the WB.AUDIT.unshift/pop block"
);
chk(
  "host.js subscribes to audit-update and re-renders the mounted panel",
  /WB\.sim\.on\('audit-update', \(\) => \{\s*\n\s*const audit = document\.getElementById\('audit-body'\);\s*\n\s*if \(audit\) renderAudit\(audit\);/.test(sources["host.js"]),
  "expected WB.sim.on('audit-update', ...) to look up #audit-body and call renderAudit"
);
chk(
  "host.js also refreshes the audit panel on the periodic tick",
  /WB\.sim\.on\('tick', \(n\) => \{[\s\S]*?if \(n % 30 === 0\) \{\s*\n\s*const audit = document\.getElementById\('audit-body'\);\s*\n\s*if \(audit\) renderAudit\(audit\);/.test(sources["host.js"]),
  "expected the existing tick handler to periodically re-render #audit-body so timestamps keep advancing"
);

// "No response yet" 30s stuck-message hint (Important/Minor Fix 11): a
// message stuck at server-received with no delivery/read ack must surface a
// hint, and any hint/timer must clear once delivery/read does arrive.
chk(
  "bench.js arms a 30s stuck timer on server-received with no ack yet",
  /else if \(r && r\.serverReceivedAt && !r\._stuckTimer\) \{\s*\n\s*r\._stuckTimer = setTimeout\(\(\) => \{\s*\n\s*if \(!r\.deliveredBy\.size && !r\.seenBy\.size\) \{\s*\n\s*r\.stuck = true;/.test(bench),
  "expected the receipt handler to setTimeout(..., 30000) guarded by r.serverReceivedAt && !r._stuckTimer, re-checking deliveredBy/seenBy before marking stuck"
);
chk(
  "bench.js's stuck timer fires at 30000ms and renders .stuck-hint",
  /\}, 30000\);/.test(bench) && bench.includes("class: 'stuck-hint'"),
  "expected the stuck timer's setTimeout delay to be exactly 30000 and the fired callback to append a .stuck-hint span"
);
chk(
  "bench.js clears the stuck timer once delivery/read is acked",
  /if \(r && \(r\.deliveredBy\.size \|\| r\.seenBy\.size\)\) \{\s*\n(?:[^\n]*\n)*?\s*if \(r\._stuckTimer\) \{ clearTimeout\(r\._stuckTimer\); r\._stuckTimer = null; \}/.test(bench),
  "expected the receipt handler to clearTimeout(r._stuckTimer) as soon as deliveredBy/seenBy gains an entry, so a late ack can't be followed by a stale hint"
);
chk(
  "bench.js clears the durable stuck flag and reconciles the row on a late ack",
  /if \(r\.stuck\) \{ r\.stuck = false; \}\s*\n\s*syncStuckHint\(seq\);/.test(bench),
  "expected the ack branch to set r.stuck = false and call syncStuckHint(seq) so a mounted row drops the hint, instead of a one-shot DOM removal that can drift from state"
);
chk(
  "bench.js re-derives the .stuck-hint from WB.RECEIPTS state inside msgNode (survives re-render)",
  /if \(me && m\.seq != null && WB\.RECEIPTS\[m\.seq\] && WB\.RECEIPTS\[m\.seq\]\.stuck\) \{\s*\n\s*node\.appendChild\(stuckHint\(\)\);/.test(bench),
  "expected msgNode to append the stuck hint whenever WB.RECEIPTS[m.seq].stuck is true, so a full renderChatList (room-filter switch / pagination) re-derives it from state rather than losing it"
);
chk(
  "bench.js has a syncStuckHint reconcile helper driven by WB.RECEIPTS[seq].stuck",
  /function syncStuckHint\(seq\) \{[\s\S]*?const r = WB\.RECEIPTS\[seq\];[\s\S]*?if \(r && r\.stuck\) \{\s*\n\s*if \(!existing\) row\.appendChild\(stuckHint\(\)\);\s*\n\s*\} else if \(existing\) \{\s*\n\s*existing\.remove\(\);/.test(bench),
  "expected a syncStuckHint(seq) that adds/removes a mounted row's .stuck-hint to match WB.RECEIPTS[seq].stuck, keeping the timer-fire and ack paths deriving from the same state msgNode reads"
);
const surfacesCss = fs.readFileSync(path.join(bundleDir, "style-surfaces.css"), "utf8");
chk(
  "style-surfaces.css defines .stuck-hint",
  /\.stuck-hint\s*\{/.test(surfacesCss),
  "expected a .stuck-hint rule styling the 30s no-response-yet hint"
);

// Security hardening: a token handed off via ?token=... must not linger in
// the browser's address bar / history after it's cached in localStorage.
chk(
  "live.js scrubs a URL-supplied token via history.replaceState",
  /if \(tokenFromUrl && window\.history && window\.history\.replaceState\) \{\s*\n\s*window\.history\.replaceState\(null, '', window\.location\.pathname \+ window\.location\.hash\);/.test(live),
  "expected the token-capture block to call history.replaceState(null, '', pathname + hash) when the token came from the URL"
);
chk(
  "live.js does not re-derive the token from location.search after the URL is scrubbed",
  (live.match(/window\.location\.search/g) || []).length === 1,
  "location.search should only be read once, before the URL is scrubbed"
);

if (failures) {
  console.error(failures + " harness check(s) failed");
  process.exit(1);
}
console.log("PASS: command-center action harness");
