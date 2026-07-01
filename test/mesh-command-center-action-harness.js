#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const root = path.resolve(__dirname, "..");
const html = fs.readFileSync(path.join(root, "crates/workbench-mesh/assets/index.html"), "utf8");
const app = fs.readFileSync(path.join(root, "crates/workbench-mesh/assets/app.js"), "utf8");

const expectedActions = [
  "send-message",
  "ask-status",
  "request-help",
  "create-invite",
  "revoke-invite",
  "approve-decision",
  "deny-decision",
  "reassign-task",
  "stop-job",
  "retry-job",
  "adopt-lead",
  "close-lead",
  "set-availability"
];

const actionNames = Array.from(html.matchAll(/\sdata-action="([^"]+)"/g)).map((match) => match[1]);
const missingActions = expectedActions.filter((action) => !actionNames.includes(action));
const duplicateActions = actionNames.filter((action, index) => actionNames.indexOf(action) !== index);

if (missingActions.length || duplicateActions.length) {
  fail(
    "HTML data-action surface changed",
    {
      missing: missingActions,
      duplicates: Array.from(new Set(duplicateActions)),
      found: actionNames
    }
  );
}

const elements = new Map();
const buttons = actionNames.map((action) => new StubElement("button:" + action, action));
const documentListeners = {};
const fetchCalls = [];
let nextSeq = 1;

const defaultValues = {
  "token-input": "",
  "room-input": "repo:harness",
  "actor-input": "ui:harness",
  "target-input": "worker:alpha",
  "message-input": "payload-marker",
  "availability-input": "busy",
  "invite-role": "operator",
  "task-input": "task-marker",
  "assignee-input": "worker:beta"
};

[
  "token-form",
  "token-input",
  "connection-state",
  "seq-state",
  "room-input",
  "actor-input",
  "target-input",
  "message-input",
  "availability-input",
  "invite-role",
  "task-input",
  "assignee-input",
  "invite-output",
  "toast",
  "event-list",
  "audit-list",
  "lead-matrix",
  "rooms-grid",
  "workers-body",
  "jobs-body",
  "tasks-body",
  "decisions-body",
  "refresh-button",
  "count-events",
  "count-actors",
  "count-rooms",
  "count-open"
].forEach((id) => {
  const element = new StubElement(id);
  element.value = Object.prototype.hasOwnProperty.call(defaultValues, id) ? defaultValues[id] : "";
  elements.set(id, element);
});

const context = {
  console,
  URLSearchParams,
  document: {
    addEventListener(type, handler) {
      documentListeners[type] = handler;
    },
    getElementById(id) {
      if (!elements.has(id)) {
        elements.set(id, new StubElement(id));
      }
      return elements.get(id);
    },
    querySelectorAll(selector) {
      if (selector === "[data-action]") {
        return buttons;
      }
      return [];
    }
  },
  fetch,
  WebSocket: StubWebSocket,
  window: {
    location: {
      search: "?token=harness-token",
      protocol: "http:",
      host: "127.0.0.1:65535"
    },
    localStorage: {
      values: new Map(),
      getItem(key) {
        return this.values.get(key) || "";
      },
      setItem(key, value) {
        this.values.set(key, value);
      }
    },
    clearTimeout() {},
    setTimeout(handler) {
      handler();
      return 1;
    }
  }
};
context.window.document = context.document;
context.window.fetch = fetch;
context.window.WebSocket = StubWebSocket;
context.window.URLSearchParams = URLSearchParams;

vm.runInNewContext(app, context, { filename: "app.js" });

const expectedPayloads = {
  "send-message": {
    url: "/api/events",
    body: {
      type: "message.sent",
      room: "repo:harness",
      from: "ui:harness",
      to: "worker:alpha",
      payload: { text: "message-send" }
    }
  },
  "ask-status": {
    url: "/api/events",
    body: {
      type: "message.request_status",
      room: "repo:harness",
      from: "ui:harness",
      to: "worker:alpha",
      payload: { text: "status requested" }
    }
  },
  "request-help": {
    url: "/api/events",
    body: {
      type: "message.help_request",
      room: "repo:harness",
      from: "ui:harness",
      to: "worker:alpha",
      payload: { text: "help-needed", priority: "operator" }
    }
  },
  "create-invite": {
    url: "/api/invites",
    body: {
      role: "operator",
      ttl_seconds: 3600,
      max_uses: 1
    },
    followup: {
      url: "/api/events",
      body: {
        type: "invite.created",
        room: "repo:harness",
        from: "ui:harness",
        payload: {
          role: "operator",
          expires_at: "2030-01-01T00:00:00Z",
          source: "command-center"
        }
      }
    }
  },
  "revoke-invite": {
    url: "/api/events",
    body: {
      type: "invite.revoked",
      room: "repo:harness",
      from: "ui:harness",
      to: "worker:alpha",
      payload: { token_hint: "invite-token", reason: "operator revoked" }
    }
  },
  "approve-decision": {
    url: "/api/events",
    body: {
      type: "decision.answer",
      room: "repo:harness",
      from: "ui:harness",
      to: "worker:alpha",
      payload: { decision: "decision-42", answer: "approved", approved: true }
    }
  },
  "deny-decision": {
    url: "/api/events",
    body: {
      type: "decision.answer",
      room: "repo:harness",
      from: "ui:harness",
      to: "worker:alpha",
      payload: { decision: "decision-42", answer: "denied", approved: false }
    }
  },
  "reassign-task": {
    url: "/api/events",
    body: {
      type: "task.reassigned",
      room: "repo:harness",
      from: "ui:harness",
      to: "worker:alpha",
      payload: { task: "task-42", assignee: "worker:beta" }
    }
  },
  "stop-job": {
    url: "/api/events",
    body: {
      type: "job.cancelled",
      room: "repo:harness",
      from: "ui:harness",
      to: "worker:alpha",
      payload: { job: "job-42", reason: "operator stopped" }
    }
  },
  "retry-job": {
    url: "/api/events",
    body: {
      type: "job.queued",
      room: "repo:harness",
      from: "ui:harness",
      to: "worker:alpha",
      payload: { job: "job-42", retry: true }
    }
  },
  "adopt-lead": {
    url: "/api/events",
    body: {
      type: "lead.adopted",
      room: "repo:harness",
      from: "ui:harness",
      to: "worker:alpha",
      payload: { lead: "worker:alpha", reason: "stale lead adopted" }
    }
  },
  "close-lead": {
    url: "/api/events",
    body: {
      type: "lead.closed",
      room: "repo:harness",
      from: "ui:harness",
      to: "worker:alpha",
      payload: { lead: "worker:alpha", reason: "operator closed" }
    }
  },
  "set-availability": {
    url: "/api/events",
    body: {
      type: "actor.status",
      room: "repo:harness",
      from: "ui:harness",
      to: "worker:alpha",
      payload: { intent: "availability.set", availability: "blocked" }
    }
  }
};

async function main() {
  documentListeners.DOMContentLoaded();
  await settle();
  fetchCalls.length = 0;

  for (const action of expectedActions) {
    configureInputs(action);
    const before = fetchCalls.length;
    clickAction(action);
    await settle();
    const actualCalls = fetchCalls.slice(before);
    assertActionFetch(action, actualCalls);
  }

  console.log("PASS: mesh command center UI action harness");
}

function configureInputs(action) {
  setValue("room-input", "repo:harness");
  setValue("actor-input", "ui:harness");
  setValue("target-input", "worker:alpha");
  setValue("message-input", "message-" + action);
  setValue("task-input", "task-marker");
  setValue("assignee-input", "worker:beta");
  setValue("availability-input", "busy");
  setValue("invite-role", "operator");

  if (action === "send-message") {
    setValue("message-input", "message-send");
  } else if (action === "request-help") {
    setValue("message-input", "help-needed");
  } else if (action === "revoke-invite") {
    setValue("message-input", "invite-token");
  } else if (action === "approve-decision" || action === "deny-decision") {
    setValue("message-input", "decision-42");
  } else if (action === "reassign-task") {
    setValue("message-input", "fallback-task");
    setValue("task-input", "task-42");
  } else if (action === "stop-job" || action === "retry-job") {
    setValue("message-input", "job-42");
  } else if (action === "set-availability") {
    setValue("availability-input", "blocked");
  }
}

function setValue(id, value) {
  elements.get(id).value = value;
}

function clickAction(action) {
  const button = buttons.find((item) => item.action === action);
  if (!button) {
    throw new Error("missing button for action " + action);
  }
  button.click();
}

function assertActionFetch(action, actualCalls) {
  const expected = expectedPayloads[action];
  const expectedCount = expected.followup ? 2 : 1;
  if (actualCalls.length !== expectedCount) {
    fail("unexpected fetch count for " + action, { expected: expectedCount, actual: actualCalls });
  }
  assertCall(action, actualCalls[0], expected);
  if (expected.followup) {
    assertCall(action + " followup", actualCalls[1], expected.followup);
  }
}

function assertCall(label, actual, expected) {
  if (!actual) {
    fail("missing fetch for " + label, {});
  }
  if (actual.url !== expected.url) {
    fail("wrong fetch URL for " + label, { expected: expected.url, actual: actual.url });
  }
  if (actual.method !== "POST") {
    fail("wrong fetch method for " + label, { expected: "POST", actual: actual.method });
  }
  if (actual.headers.Authorization !== "Bearer harness-token") {
    fail("missing bearer header for " + label, actual.headers);
  }
  if (actual.headers["Content-Type"] !== "application/json") {
    fail("missing JSON content type for " + label, actual.headers);
  }
  assertDeepEqual(label, actual.body, expected.body);
}

function assertDeepEqual(label, actual, expected) {
  const actualJson = JSON.stringify(sortObject(actual));
  const expectedJson = JSON.stringify(sortObject(expected));
  if (actualJson !== expectedJson) {
    fail("wrong JSON body for " + label, { expected, actual });
  }
}

function sortObject(value) {
  if (Array.isArray(value)) {
    return value.map(sortObject);
  }
  if (value && typeof value === "object") {
    return Object.keys(value).sort().reduce((sorted, key) => {
      sorted[key] = sortObject(value[key]);
      return sorted;
    }, {});
  }
  return value;
}

function settle() {
  return new Promise((resolve) => setImmediate(resolve));
}

function fetch(url, options = {}) {
  const method = options.method || "GET";
  if (method === "POST") {
    fetchCalls.push({
      url,
      method,
      headers: options.headers || {},
      body: JSON.parse(options.body)
    });
  }

  if (url === "/api/state") {
    return Promise.resolve(jsonResponse({ events: [], actors: [], last_seq: 0 }));
  }
  if (url === "/api/invites") {
    return Promise.resolve(jsonResponse({
      token: "invite-token",
      role: JSON.parse(options.body).role,
      expires_at: "2030-01-01T00:00:00Z"
    }));
  }
  if (url === "/api/events") {
    const event = JSON.parse(options.body);
    return Promise.resolve(jsonResponse(Object.assign({ seq: nextSeq++, ts: "2030-01-01T00:00:00Z" }, event)));
  }
  return Promise.resolve(jsonResponse({}));
}

function jsonResponse(body) {
  return {
    ok: true,
    status: 200,
    statusText: "OK",
    text() {
      return Promise.resolve(JSON.stringify(body));
    }
  };
}

function StubElement(id, action) {
  this.id = id;
  this.action = action || "";
  this.value = "";
  this.textContent = "";
  this.innerHTML = "";
  this.className = "";
  this.listeners = {};
  this.classList = {
    add() {},
    remove() {}
  };
}

StubElement.prototype.addEventListener = function addEventListener(type, handler) {
  this.listeners[type] = handler;
};

StubElement.prototype.getAttribute = function getAttribute(name) {
  if (name === "data-action") {
    return this.action;
  }
  return "";
};

StubElement.prototype.click = function click() {
  if (!this.listeners.click) {
    fail("button has no click listener", { action: this.action });
  }
  this.listeners.click();
};

function StubWebSocket() {
  this.addEventListener = function addEventListener() {};
}

function fail(message, details) {
  console.error("FAIL: " + message);
  if (details && Object.keys(details).length) {
    console.error(JSON.stringify(details, null, 2));
  }
  process.exit(1);
}

main().catch((error) => {
  fail(error.message, error.details || {});
});
