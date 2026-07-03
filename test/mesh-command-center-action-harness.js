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

if (failures) {
  console.error(failures + " harness check(s) failed");
  process.exit(1);
}
console.log("PASS: command-center action harness");
