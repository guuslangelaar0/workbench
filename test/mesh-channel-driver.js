#!/usr/bin/env node
// Node driver for mesh-channel.test.sh: speaks newline-delimited JSON-RPC to
// scripts/mesh-channel.js the way Claude Code would, appends live events to
// the log, and asserts on what the channel emits.
"use strict";
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

const [project, eventsFile, meshStub] = process.argv.slice(2);
const server = spawn("node", [path.join(__dirname, "..", "scripts", "mesh-channel.js")], {
  env: {
    ...process.env,
    CLAUDE_PROJECT_DIR: project,
    WORKBENCH_MESH_ACTOR: "test-lead",
    WORKBENCH_MESH_SH: meshStub,
    WORKBENCH_CHANNEL_SENDERS: "ui:operator,critic-1",
  },
  stdio: ["pipe", "pipe", "inherit"],
});

let failures = 0;
function chk(label, ok, detail) {
  if (ok) console.log("ok: " + label);
  else { console.error("FAIL: " + label + (detail ? " — " + detail : "")); failures += 1; }
}

const inbox = [];
const responses = new Map();
let buf = "";
server.stdout.on("data", (d) => {
  buf += d.toString();
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i); buf = buf.slice(i + 1);
    if (!line.trim()) continue;
    const msg = JSON.parse(line);
    if (msg.id !== undefined) responses.set(msg.id, msg);
    else if (msg.method === "notifications/claude/channel") inbox.push(msg.params);
  }
});

function send(msg) { server.stdin.write(JSON.stringify(msg) + "\n"); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function waitFor(pred, ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (pred()) return true; await sleep(100); }
  return false;
}

(async () => {
  // 1. handshake
  send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2024-11-05" } });
  await waitFor(() => responses.has(1), 3000);
  const init = responses.get(1);
  chk("initialize declares claude/channel capability",
    !!(init && init.result && init.result.capabilities.experimental && init.result.capabilities.experimental["claude/channel"]));
  chk("initialize declares tools capability", !!(init && init.result.capabilities.tools));
  chk("initialize carries instructions mentioning mesh_reply",
    !!(init && /mesh_reply/.test(init.result.instructions || "")));
  send({ jsonrpc: "2.0", method: "notifications/initialized" });

  // 2. tools/list exposes mesh_reply
  send({ jsonrpc: "2.0", id: 2, method: "tools/list" });
  await waitFor(() => responses.has(2), 3000);
  const tools = responses.get(2).result.tools.map((t) => t.name);
  chk("tools/list exposes mesh_reply", tools.includes("mesh_reply"), tools.join(","));

  // 3. let the first poll pin the cursor at the tip, then append live events
  await sleep(2000);
  chk("history at startup is not injected", inbox.length === 0, JSON.stringify(inbox));
  fs.appendFileSync(eventsFile, [
    JSON.stringify({ seq: 2, type: "message.sent", room: "repo:demo", from: "ui:operator", payload: { text: "hello lead" } }),
    JSON.stringify({ seq: 3, type: "message.sent", room: "repo:demo", from: "test-lead", payload: { text: "self chatter must not loop" } }),
    JSON.stringify({ seq: 4, type: "output.chunk", room: "output:x", from: "x", payload: { kind: "message", summary: "not a message type" } }),
    JSON.stringify({ seq: 5, type: "message.sent", room: "repo:demo", from: "intruder", payload: { text: "not on the sender allowlist" } }),
    JSON.stringify({ seq: 6, type: "message.request_status", room: "presence", from: "critic-1", to: "test-lead", payload: { question: "status?" } }),
    // Non-empty payload text is deliberate: it ensures this only passes because
    // of the explicit ack-type exclusion below, not because of the unrelated
    // empty-payload `text` fallback that would filter an empty-payload ack anyway.
    JSON.stringify({ seq: 7, type: "message.delivered", room: "repo:demo", from: "critic-1", ack_of: 2, payload: { text: "delivered" } }),
    JSON.stringify({ seq: 8, type: "message.read", room: "repo:demo", from: "critic-1", ack_of: 2, payload: { text: "read" } }),
  ].join("\n") + "\n");

  await waitFor(() => inbox.length >= 2, 6000);
  await sleep(500); // let any (incorrect) extra bridged events for seq 7/8 land before asserting the count
  chk("exactly the two inbound events injected", inbox.length === 2, JSON.stringify(inbox));
  chk("channel event carries content and sender/room meta",
    inbox.some((n) => n.content === "hello lead" && n.meta.sender === "ui:operator" && n.meta.room === "repo:demo"));
  chk("direct ask injected with sender meta",
    inbox.some((n) => n.content === "status?" && n.meta.sender === "critic-1"));
  chk("ack events (message.delivered/message.read) are excluded, not merely empty-payload no-ops",
    !inbox.some((n) => n.meta.seq === "7" || n.meta.seq === "8"), JSON.stringify(inbox));

  // 4. reply tool round-trip through the stub
  send({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "mesh_reply", arguments: { target: "repo:demo", text: "Reply from the session" } } });
  await waitFor(() => responses.has(3), 5000);
  const call = responses.get(3);
  chk("mesh_reply returns sent confirmation",
    !!(call && call.result && !call.result.isError && /sent/.test(call.result.content[0].text)),
    JSON.stringify(call && call.result));

  // 5. unknown tool is rejected cleanly
  send({ jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "evil_tool", arguments: {} } });
  await waitFor(() => responses.has(4), 3000);
  chk("unknown tool rejected", !!responses.get(4).error);

  server.kill();
  process.exit(failures ? 1 : 0);
})();
